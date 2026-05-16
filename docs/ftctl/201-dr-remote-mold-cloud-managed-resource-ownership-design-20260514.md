# 201. DR Remote Mold Cloud-Managed Resource Ownership Design

Date: 2026-05-14

## 1. Purpose

DR remote Mold protection must preserve the ownership model already proven by the HA cloud-managed flow.

The current DR remote Mold implementation can resolve a remote Mold host and storage pool, then pass the selected remote path to qemu FTCTL. That leaves room for qemu FTCTL to create or format remote-nbd/RBD targets. This is not acceptable for Cloud-integrated DR because Cloud must own virtual machine and volume lifecycle.

This design changes DR remote Mold registration so the remote Cloud management system creates and owns the replica virtual machine and replica volumes. qemu FTCTL receives only the Cloud-created target paths and performs replication and Cloud-requested disaster-recovery data-plane actions.

Failback-time target Mold selection is defined separately in [206. DR Cloud-Managed Failback Target Mold Design](206-dr-cloud-managed-failback-target-mold-design-20260516.md). Registration-time remote Mold ownership does not imply that failback must return to the original source Mold.

## 2. Non-Negotiable Ownership Rules

- Cloud owns virtual machine and volume lifecycle.
- Source Cloud creates or requests creation of source-side and replica-side Cloud records.
- Remote Mold Cloud creates remote replica VM and remote replica volumes when `drpeersitetype=remote-mold`.
- Cloud may query asynchronous state from Cloud APIs, the database, qemu FTCTL events, qemu FTCTL logs, or Mold Agent responses.
- Mold Agent only delivers commands to qemu FTCTL and returns logs/status/events.
- qemu FTCTL owns replication, blockcopy, remote-nbd export handling, Cloud-requested failover data-plane checks, reverse sync, and failback data-plane work.
- Cloud owns Cloud-managed automatic fencing decisions and VM lifecycle orchestration. qemu FTCTL must not be the Cloud-managed automatic failover controller. See [202. Cloud-Managed HA/DR Automatic Fencing qemu Contract Design](202-cloud-managed-ha-dr-automatic-fencing-qemu-contract-design-20260514.md).
- qemu FTCTL must not create, define, attach, detach, start, stop, delete, or resize Cloud-managed VMs or Cloud-managed volumes.
- For `provisioningbackend=cloud-managed`, qemu FTCTL must never create or implicitly format a remote-nbd target. The target must already exist and must be supplied through an explicit disk map.
- Cloud registration defaults to `cloud-managed` for both local/current Mold and remote Mold. `libvirt-managed` remains an explicit legacy/standalone path, not the implicit Cloud UI/API behavior.

These rules apply equally to HA and DR, and to DR local/current Mold and DR remote Mold. DR remote Mold is not an exception.

## 3. Current Structural Gap

The existing Cloud path has the correct local Cloud-managed HA model:

1. Cloud allocates a standby root volume.
2. Cloud allocates a standby VM.
3. Cloud allocates and attaches standby data volumes.
4. Cloud persists protection and protection-volume records.
5. Cloud builds `disk_map` from Cloud volume paths.
6. qemu FTCTL mirrors into those existing targets.

The DR remote Mold path currently diverges:

1. Source Cloud treats the remote Mold target storage pool as lookup metadata.
2. Source Cloud does not ask remote Mold Cloud to create a replica VM and volumes.
3. Source Cloud can persist `secondarytargetdir` and remote host/storage details without remote Cloud-created volume mappings.
4. qemu remote-nbd can prepare target paths and, outside a strict Cloud-managed guard, create or format file/RBD targets.

That divergence violates the HA principle because the replica VM/volume lifecycle is effectively delegated to the qemu side.

## 4. Target Architecture

### 4.1 Same-Mold DR

When source and target sites use the same Mold service:

- Source Cloud uses the existing local Cloud-managed provisioning service.
- Local Cloud creates the replica VM and volumes.
- `ftctl_protection.secondary_vm_id` and `ftctl_protection_volume.secondary_volume_id` may continue to reference local Cloud DB IDs.
- qemu receives explicit Cloud-generated `disk_map`.

### 4.2 Remote-Mold DR

When source and target sites use different Mold services:

- Source Cloud validates the remote Mold connection and operator-selected remote host/storage/network inputs.
- Source Cloud calls a remote Mold Cloud API dedicated to FTCTL DR replica provisioning.
- Remote Mold Cloud creates the replica VM and volumes in its own Cloud DB.
- Remote Mold Cloud returns external identifiers and disk paths to source Cloud.
- Source Cloud persists only cross-site metadata and the source-side protection mapping.
- qemu receives explicit `disk_map` entries that point to remote Cloud-created target paths.

The remote Mold API key and secret remain transient request inputs. They are not persisted in source VM details, FTCTL profiles, host files, or logs.

## 5. Required Cloud Model Changes

### 5.1 Provisioning Strategy Split

Add a provisioning strategy boundary under the existing FTCTL provisioning service:

- `LocalCloudManagedProvisioningStrategy`
  - Existing HA/local-Mold behavior.
  - Uses local Cloud services and local Cloud DB IDs.

- `RemoteMoldDrProvisioningStrategy`
  - New DR remote Mold behavior.
  - Uses signed remote Mold API calls.
  - Receives remote object UUIDs and disk paths.
  - Does not use local Cloud DB numeric IDs for remote VM/volume identity.

`registerFtctlProtection` should route to the remote strategy when:

- `mode=dr`
- `drpeersitetype=remote-mold`
- `provisioningbackend=cloud-managed`
- `backendmode=remote-nbd`

### 5.2 Remote Mold Provisioning API

Add a remote Mold-side FTCTL API, for example:

`prepareFtctlDrReplicaResources`

The command runs inside the remote Mold management service and performs Cloud-owned lifecycle work:

- Resolve target zone, host, storage pool, service offering, disk offering, and network inputs.
- Create a stopped replica VM with FTCTL marker details.
- Create a replica root volume with the same or larger virtual size as the source root volume.
- Create replica data volumes for every protected source data disk.
- Attach replica volumes using the matching device IDs.
- Return remote VM identity, remote volume identities, and resolved disk paths.

The response must include enough information for source Cloud to build a qemu disk map without guessing:

- `remotevirtualmachineid`
- `remotevirtualmachinename`
- `remotevirtualmachineinstancename`
- `remotevolumes[]`
  - `sourcevolumeid` or stable source disk label
  - `sourcedisktarget`
  - `remotevolumeid`
  - `remotevolumename`
  - `remotevolumepath`
  - `deviceid`
  - `type`

For RBD, `remotevolumepath` must resolve to the path qemu can open on the remote host, such as `/dev/rbd/<pool>/<image>`, after Cloud has created the backing image.

### 5.3 Source Cloud Metadata

Remote Mold resources must not be stored as local DB IDs.

Add one of the following:

- new nullable external identity columns in FTCTL tables, or
- a new FTCTL remote-resource mapping table.

Required source-side metadata:

- remote Mold site/API URL identity
- remote VM UUID/name/instance name
- remote volume UUID/name/path per source volume
- remote host UUID/address/libvirt URI
- remote target storage pool UUID/name/type/path
- qemu disk target to remote Cloud-created path mapping

`FtctlProtectionResponse` should expose remote replica VM and volume information even when local `secondary_vm_id` and `secondary_volume_id` are null.

## 6. Revised Registration Sequence

For `mode=dr`, `drpeersitetype=remote-mold`, `provisioningbackend=cloud-managed`, and `backendmode=remote-nbd`:

1. Validate the source VM and reject registration unless it is Running.
2. Validate remote Mold connection with transient remote API credentials.
3. Resolve and validate remote host, storage pool, network, and offering inputs.
4. Resolve SSH user, SSH port, libvirt URI, and remote NBD export address.
5. If automatic SSH setup is enabled, install the source public key through Mold Agent/qemu paths.
6. Run source-host to remote-host SSH/libvirt/NBD preflight through Mold Agent/qemu FTCTL.
7. Call remote Mold Cloud API to create the replica VM and replica volumes.
8. Poll/query remote Mold until all replica volume paths are ready.
9. Persist source-side FTCTL protection records and remote external-resource mappings.
10. Build explicit `disk_map` from remote Cloud-created paths.
11. Sync the qemu FTCTL profile to the source host.
12. Send qemu FTCTL `protect`.

If steps 5 or 6 fail, Cloud must not create durable protection state or remote replica resources.

If steps 7 or 8 fail, Cloud must clean up any remote replica resources it created or leave a clear Cloud-owned cleanup record with remote IDs.

If steps 11 or 12 fail after remote resources exist, Cloud must preserve remote object IDs in the error state so release/forced-release can clean them through Cloud APIs.

## 7. qemu FTCTL Guard Changes

For `FTCTL_PROFILE_PROVISIONING_BACKEND=cloud-managed` and `FTCTL_PROFILE_BACKEND_MODE=remote-nbd`:

- `FTCTL_PROFILE_DISK_MAP` is mandatory.
- `FTCTL_PROFILE_DISK_MAP=auto` is invalid.
- every protected source disk target must have an explicit destination mapping.
- every destination must be an absolute Cloud-created path.
- qemu may map an existing RBD device if needed for access.
- qemu may verify path existence, size, and format.
- qemu may start and stop qemu-nbd exports for existing target devices/files.
- qemu must not call `qemu-img create` for a missing target.
- qemu must not call `qemu-img create` to reformat an existing Cloud-managed block target.
- qemu must not create RBD images, logical volumes, directories-as-targets, or standby VM definitions for Cloud-managed DR.

Non-Cloud-managed qemu standalone tests may keep their existing target creation behavior, but that behavior must be unreachable from Cloud-managed DR profiles.

## 8. DR Action Ownership

### 8.1 Protection

- Cloud creates replica VM/volumes.
- qemu starts forward replication into Cloud-created paths.
- Cloud reads qemu events/progress through backend/Mold Agent paths.

### 8.2 Failover

- qemu performs Cloud-requested data-plane checks and remote-nbd export release/finalization.
- Cloud starts the remote replica VM through remote Mold API.
- Source Cloud exposes remote VM state by querying remote Mold or cached remote metadata.

qemu must not start the remote Cloud-owned replica VM through libvirt as the primary lifecycle mechanism.

For automatic Cloud-managed failover, Cloud must also own the fencing decision and standby/replica VM start orchestration. qemu may report a candidate/runtime evidence event, but it must not decide automatic failover from a single libvirt/domain observation.

### 8.3 Failback

- DR failback must receive an explicit target Mold context at failback time.
- The target Mold may be the current Mold, the original primary Mold, or a newly installed Mold.
- qemu performs reverse sync and data-plane finalization into explicit Cloud-created target paths.
- Cloud controls VM stop/start transitions through the Mold that owns each VM.
- For remote or new Mold targets, Cloud must use external UUID/name/instance identifiers rather than local numeric secondary VM IDs.
- Cloud remains responsible for cleanup or transfer of Cloud-created replica resources.

The detailed failback state machine, target Mold credential handling, and new-primary-Mold handoff rules are specified in document 206.

## 9. UI Impact

The DR protection dialog must make remote Mold resource ownership explicit without exposing qemu-only target creation controls for Cloud-managed DR.

Required behavior:

- `Use remote Mold` remains optional because different datacenters can share one Mold service.
- When remote Mold is enabled, the UI collects remote Mold connection details for lookup/provisioning.
- Remote host and remote storage selection remain remote Mold API results.
- Cloud-managed DR must not ask the user for an arbitrary qemu `secondarytargetdir` as the source of replica disk creation.
- SSH customization remains optional and is enabled only when the user chooses to edit SSH fields.
- Automatic SSH key setup remains optional and keeps the private key only on the source host.

Additional remote Cloud provisioning inputs may be required:

- remote zone
- remote network
- remote service offering or FTCTL hidden offering policy
- remote disk offering policy
- remote account/domain mapping policy

If defaults are used, the defaults must be resolved by Cloud and shown as Cloud-managed choices, not hidden qemu behavior.

## 10. Compatibility

- HA cloud-managed registration must keep the existing validated behavior.
- HA must not receive DR remote Mold parameters.
- DR local Mold must continue to work without remote Mold credentials.
- qemu standalone remote-nbd tests can continue to validate qemu-created targets when `provisioningbackend` is not `cloud-managed`.
- Cloud-managed DR must always use Cloud-created replica resources and explicit disk maps.
- Cloud-managed DR failback must not assume that the original source Mold is the failback target.

## 11. Verification Plan

Cloud unit and integration checks:

- remote Mold DR registration routes to `RemoteMoldDrProvisioningStrategy`.
- remote Mold credentials are not persisted.
- registration fails if remote Cloud does not return a complete VM/volume/disk-map response.
- `FtctlProtectionResponse` includes remote replica VM/volume metadata with null local secondary IDs.
- release/forced-release cleans remote Cloud-created resources through Cloud APIs.
- HA/local-Mold tests continue to pass unchanged.

qemu checks:

- cloud-managed remote-nbd rejects missing disk map.
- cloud-managed remote-nbd rejects `disk_map=auto`.
- cloud-managed remote-nbd rejects a missing destination mapping.
- cloud-managed remote-nbd fails when the Cloud-created target path is absent.
- cloud-managed remote-nbd does not execute `qemu-img create` for existing block/RBD targets.
- cloud-managed qemu reconcile does not own automatic failover from a single missing domain.
- non-cloud-managed remote-nbd keeps existing standalone behavior.

End-to-end DR-WIN checks:

- remote Mold DB shows replica VM and volumes before qemu `protect`.
- source Cloud DB stores remote external resource mappings.
- qemu profile contains explicit disk map to remote Cloud-created paths.
- qemu events show replication/progress only, not VM/volume creation.
- failover starts the remote VM through remote Mold Cloud lifecycle.

## 12. Immediate Test Consequence

Any DR-WIN protection registered before this ownership correction should be treated as structurally suspect. Before continuing failover/failback testing:

1. Inspect source Cloud FTCTL rows and remote Mold resources.
2. Confirm whether remote replica VM and volumes were created by Cloud.
3. If qemu-created or qemu-derived targets were used, release/clean the protection state.
4. Re-register only after the Cloud-managed remote resource model is implemented.
