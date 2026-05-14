# 200. DR Remote Mold SSH Preflight And Key Setup Design

Date: 2026-05-13

## 1. Purpose

DR protection can replicate data to a remote site whose Mold management system is different from the source site. In that case, Cloud must be able to look up the remote host and storage from the remote Mold API, and the actual data transfer still runs from the source qemu FTCTL host to the remote qemu/libvirt/NBD path.

This document is limited to SSH, libvirt, and remote-NBD transfer preflight/key setup. Cloud-managed remote replica VM and volume ownership is specified by [201. DR Remote Mold Cloud-Managed Resource Ownership Design](201-dr-remote-mold-cloud-managed-resource-ownership-design-20260514.md). If this document appears to imply that qemu FTCTL may create Cloud-managed replica VMs, volumes, RBD images, or remote-nbd targets, the 201 ownership design supersedes that interpretation.

This design fixes the current DR-WIN failure mode where protection registration can create Cloud and host-side FTCTL state even though the source host cannot reach the remote host over non-interactive SSH or the remote NBD firewall path is not ready.

## 2. Current Failure Evidence

Target VM:

- Source VM: `dr-w22-01`
- Source instance: `i-2-381-VM`
- Source host: `10.10.22.3`
- Remote host selected from remote Mold: `10.10.32.1`
- Resolved peer URI: `qemu+ssh://root@10.10.32.1:22/system`

Observed state after failed registration:

- `ftctl_protection` row remained active with `protection_state=error`
- `transport_state=rearm_exhausted`
- `last_error=rearm_attempts_exhausted`
- source host state had `rearm_count=5`
- blockcopy targets were `missing` for `sda` and `sdb`
- 22-to-32 root SSH failed without an interactive password
- 32 hosts had `ablestack-vm-ftctl-remote-nbd.xml`, but the service was not attached to the active/permanent firewalld zone
- Cloud management log reported `remotepeersshuser`, `remotepeersshport`, and `remotepeersshoverride` as unknown parameters
- The implemented `validateRemoteExecutionPath` helper was not called in the registration flow

## 3. Design Principles

- Do not damage or regress the already validated HA flow.
- Keep the HA ownership model intact:
  - Cloud creates original/replica VM and disk resources through Cloud APIs and reads asynchronous state from events, logs, or the database.
  - Mold Agent delivers commands to qemu FTCTL and returns logs/status.
  - Actual HA/DR/FT actions remain in qemu FTCTL.
- Cloud must not directly SSH to qemu hosts, call host libvirt, or perform blockcopy itself.
- For Cloud-managed DR, qemu FTCTL must receive explicit Cloud-created target paths and must not create or format replica VM/volume/RBD/remote-nbd targets.
- Remote Mold API key and secret are lookup-only inputs and must not be persisted in VM details, FTCTL profiles, host files, or logs.
- DR registration must fail before creating durable protection state when the remote transfer path is not ready.
- Private SSH keys must not be uploaded to Cloud or stored in Cloud DB.

## 4. Target Operator Model

DR SSH preparation has two supported modes.

### 4.1 User-Prepared Mode

The operator prepares host-to-host non-interactive SSH outside Cloud.

Required condition:

- source qemu host can run `ssh -o BatchMode=yes -p <port> <user>@<remote-host> true`
- source qemu host can use `qemu+ssh://<user>@<remote-host>:<port>/system`
- remote NBD port range is open on the remote host firewall

Cloud/qemu only validates these conditions. It does not modify SSH keys or `known_hosts`.

### 4.2 Automatic Key Setup Mode

The operator can select an explicit DR SSH key auto-setup option in the UI.

In this mode:

- Source host generates a protection-scoped FTCTL DR SSH keypair.
- Private key stays only on the source host.
- Public key is passed through Cloud/Mold Agent to the selected remote host.
- Remote host installs the public key with a traceable FTCTL comment in `root`'s `authorized_keys`.
- Source host runs the same preflight after key installation.
- Protection release removes the installed public key from the remote host when it was installed by FTCTL.

The automatic path is optional. It exists to reduce operator preparation work without moving private keys into Cloud.

## 5. UI Changes

The DR protection dialog keeps the current remote Mold behavior and adds one optional SSH preparation section.

Controls:

- `Use remote Mold`: existing remote Mold selector.
- `Customize remote SSH connection`: existing toggle that enables SSH user, SSH port, and libvirt URI editing.
- `Prepare DR SSH key automatically`: new optional toggle.

Visibility rules:

- SSH user/port/libvirt URI inputs remain disabled or hidden until the user chooses to customize SSH connection values.
- Automatic key setup is shown only for DR + remote Mold.
- Automatic key setup requires a selected remote host.

Validation:

- SSH port must be `1..65535`.
- Automatic key setup cannot accept a private key upload.
- UI text must clearly say that the private key remains on the source host.

Submitted fields:

- existing remote Mold lookup fields
- existing remote host/storage fields
- `remotepeersshuser`
- `remotepeersshport`
- `remotepeersshoverride`
- `remotepeerlibvirturi`
- new `remotepeersshautosetup`

## 6. Cloud Backend Changes

### 6.1 API Parameter Recognition

`RegisterFtctlProtectionCmd` must expose and accept:

- `remotepeersshuser`
- `remotepeersshport`
- `remotepeersshoverride`
- `remotepeerlibvirturi`
- `remotepeersshautosetup`

Deployment verification must fail if management logs show these as unknown parameters.

### 6.2 Registration Order

For `mode=dr`, `drpeersitetype=remote-mold`, `provisioningbackend=cloud-managed`, and `backendmode=remote-nbd`, the transfer-preflight portion of registration becomes:

1. Validate remote Mold lookup fields.
2. Resolve remote host and storage information.
3. Resolve SSH user, SSH port, libvirt URI, and remote NBD export address.
4. If automatic key setup is enabled, send key setup commands through source and remote Mold Agent paths.
5. Run source-host remote execution preflight through Mold Agent/qemu FTCTL.
6. Only after preflight succeeds, Cloud calls remote Mold Cloud provisioning to create the replica VM and replica volumes.
7. Cloud waits for remote Cloud-created replica volume paths and builds an explicit disk map.
8. Cloud creates or updates source-side protection rows, protection volume mappings, VM details, and host FTCTL profile.
9. Cloud sends qemu FTCTL `protect`.

If steps 4 or 5 fail, Cloud must return a clear API error and must not leave active FTCTL protection state or remote replica resources.

If steps 6 or 7 fail after remote resources are partially created, cleanup must be performed through Cloud APIs or the failure state must preserve enough remote Cloud object IDs for a later Cloud-owned cleanup.

### 6.3 Agent Command Path

Cloud sends commands only through Mold Agent:

- source host: generate/read source public key and run preflight
- remote host: install/remove public key and apply firewall service

Cloud does not run SSH or libvirt locally.

Mold Agent does not create replica VMs or volumes. Remote replica VM and volume lifecycle is handled by Cloud APIs as described in document 201.

### 6.4 Error Mapping

Preflight and setup errors should be preserved in API responses:

- `remote_ssh_auth_failed`
- `remote_ssh_host_key_mismatch`
- `remote_ssh_port_refused`
- `remote_libvirt_unreachable`
- `remote_nbd_firewall_closed`
- `remote_key_install_failed`
- `remote_key_remove_failed`

The UI should show the source host, remote host, SSH user, SSH port, and failed check.

## 7. qemu FTCTL Changes

### 7.1 Preflight

`ablestack_vm_ftctl preflight-remote` must verify:

- peer URI parse result, including explicit SSH user and port
- non-interactive SSH to the remote host
- remote libvirt access through the resolved URI
- remote NBD export address format
- remote NBD port reachability or firewalld state when a remote helper is available

It must return JSON with a stable `reason` field on failure.

### 7.2 SSH Key Management

New qemu FTCTL commands:

- `dr-key-ensure`
  - creates a protection-scoped keypair on the source host when missing
  - returns public key only
  - stores private key under a root-only FTCTL path, for example `/root/.ssh/ftctl-dr/<protection-uuid>/id_ed25519`
- `dr-key-install`
  - installs a public key on the target host's `authorized_keys`
  - uses a stable comment such as `ftctl-dr:<protection-uuid>:<source-host-id>`
  - is idempotent
- `dr-key-remove`
  - removes only keys with the matching FTCTL comment
  - is idempotent

Private keys must never be printed to stdout, events, profiles, or Cloud logs.

### 7.3 Firewall

`ablestack_vm_ftctl_firewalld` must support:

- `apply`
  - ensure service definition `ablestack-vm-ftctl-remote-nbd`
  - attach it to the active/permanent zone used by host interfaces
  - reload firewalld when needed
- `remove`
  - remove the service from runtime/permanent zone only when FTCTL owns it
- `status`
  - report service definition, runtime zone membership, permanent zone membership, and opened port range

The service must include `10809-10872/tcp`.

## 8. Cleanup Semantics

Protection release must clean up:

- qemu block jobs
- remote NBD exports
- FTCTL profile/state files
- Cloud DB rows/details
- remote Cloud-created replica VM/volume resources through Cloud APIs when remote Mold DR used Cloud-managed provisioning
- automatically installed SSH public key, only when auto setup was used

If key removal fails during forced release, the warning must be explicit and include the target host and key comment. It must not remove unrelated `authorized_keys` content.

## 9. Deployment Verification

Cloud management verification:

- `/client/` returns HTTP 200.
- `WEB-INF` remains present.
- active UI bundle contains SSH auto-setup labels.
- API metadata recognizes `remotepeersshuser`, `remotepeersshport`, `remotepeersshoverride`, `remotepeerlibvirturi`, and `remotepeersshautosetup`.
- management log has no `unknown parameters` warning for those fields.

Cloud agent verification:

- source and remote host Mold Agent jars include the command classes used for preflight and key setup.
- `mold-agent` is active after restart.

qemu verification:

- installed qemu FTCTL has `preflight-remote`, `dr-key-ensure`, `dr-key-install`, `dr-key-remove`.
- `ablestack_vm_ftctl_firewalld status` reports `10809-10872/tcp` runtime/permanent availability.
- a negative preflight fails before creating protection rows.
- a positive preflight proceeds to `protect`.
- Cloud-managed remote-nbd rejects missing or `auto` disk maps and does not create or format Cloud-managed targets.

## 10. Test Plan

Negative tests:

- wrong SSH port: registration fails before Cloud protection rows are created.
- missing SSH trust with auto setup disabled: registration fails before Cloud protection rows are created.
- host key mismatch: registration fails with `remote_ssh_host_key_mismatch`.
- remote NBD firewall closed: registration fails with `remote_nbd_firewall_closed`.

Positive tests:

- user-prepared SSH path: preflight succeeds, remote Cloud provisioning creates replica resources, registration reaches mirroring.
- automatic key setup path: key is generated, public key installed, preflight succeeds, remote Cloud provisioning creates replica resources, registration reaches mirroring.
- release after automatic key setup removes only the FTCTL public key comment.

Regression tests:

- HA registration and HA manual-block flow still use the existing validated path.
- HA must not receive DR remote Mold SSH fields.
- DR local Mold path must continue to work without remote Mold credentials.

## 11. Implementation Order

1. Fix Cloud registration order and actually call remote preflight before durable protection state is created.
2. Add API parameter and deployment metadata verification for SSH fields.
3. Add remote Mold Cloud-managed replica VM/volume provisioning per document 201.
4. Add qemu cloud-managed remote-nbd guards so qemu never creates or formats Cloud-managed targets.
5. Add qemu FTCTL key management commands.
6. Add Cloud/Mold Agent commands for source key creation and remote public key install/remove.
7. Harden `ablestack_vm_ftctl_firewalld apply/status` for the remote NBD service.
8. Build, deploy, and verify both clusters.
9. Clean the current failed `dr-w22-01` protection state.
10. Re-run DR-WIN registration first with negative preflight, then with automatic key setup enabled.
