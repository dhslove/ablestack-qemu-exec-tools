# 360. FT XCOLO Directional Chardev Contract And Cloud-Managed Runtime Reconcile Design - 2026-06-05

> Superseded correction: the original version of this document treated every
> COLO chardev `frontend-open=false` as a pre-migrate hard failure. QEMU 9.2.4
> code-level review showed that this is too strict for output chardevs used by
> `filter-mirror` and `filter-redirector`. This document now defines the
> directional contract used by the implementation.

## Problem

Run 82 for `r97-link-01` moved beyond the previous Cloud API timeout problem
because protection is now started asynchronously. The run still failed during
XCOLO startup with:

```text
Primary QEMU: Received invalid message 0x0000 length 0x0000
Secondary QEMU: Can't receive COLO message: Input/output error
last_error=xcolo_filter_mirror_send_eperm
```

The important evidence was not only the post-migrate QEMU error. FTCTL recorded
that the pre-guest traffic contract was already closed:

```text
mirror_path_primary_mirror0=present_closed
compare_path_secondary_red1=present_closed
```

The previous design in
`358-ft-xcolo-qemu-doc-preguest-frontend-diagnostic-design-20260605.md`
allowed this state to proceed as diagnostic evidence when QEMU document topology
and socket checks passed. That was too permissive. Socket listen/established
state only proves transport reachability.

Run 83 then proved the opposite edge: failing before `primary.migrate` merely
because `mirror0` and `red1` reported `frontend-open=false` also blocks a QEMU
9.2.4-valid state. The important detail is direction:

- `mirror0` and `red1` are output chardevs. For these, FTCTL must prove the
  socket backend is connected.
- `red0` and `compare1` are input chardevs consumed by QEMU filters/compare.
  For these, FTCTL must prove `frontend-open=true`.

QEMU 9.2.4 `filter-mirror` writes guest TX data to its `outdev`; QEMU
`filter-redirector` consumes from `indev` and writes to `outdev` according to
the configured queue direction. `query-chardev.frontend-open` is therefore not
a symmetric "network ready" bit for every endpoint.

The same run also exposed a Cloud lifecycle mismatch after failure recovery:

```text
Cloud DB:  standby VM Running on host 1
libvirt:   failed to get domain 'i-2-138-VM' on 10.10.32.1
```

The cause is qemu-side recovery calling `ftctl_standby_deactivate()`, which
destroyed and undefined the secondary domain. For cloud-managed FT, that can
leave Cloud DB and libvirt runtime state inconsistent because Cloud owns VM
lifecycle state.

## Principles

1. Keep the QEMU COLO document startup order stable.
2. Do not repeat adjacent startup-order experiments after the same protocol
   symptom reappears.
3. Treat socket reachability and chardev frontend openness as separate
   contracts.
4. Do not let qemu-side failure recovery leave cloud-managed VM lifecycle state
   inconsistent with Cloud DB.
5. Preserve the stable RBD path contract: XML must continue to use
   `/dev/rbd/rbd/<image-id>`, not `/dev/rbdN`.

## Design

### Pre-Migrate Directional Chardev Gate

Before issuing primary `migrate`, FTCTL must verify both COLO network paths:

```text
primary:m0 -> mirror0 -> secondary:red0 -> f1
secondary:f2 -> red1 -> primary:compare1 -> comp0
```

The gate passes when direction-specific conditions are satisfied:

- primary `mirror0`: chardev exists and TCP backend is connected; do not
  require `frontend-open=true`
- secondary `red0`: chardev exists and `frontend-open=true`
- secondary `red1`: chardev exists and TCP backend is connected; do not require
  `frontend-open=true`
- primary `compare1`: chardev exists and `frontend-open=true`

If any direction-specific condition fails, FTCTL must not issue `migrate`.
If only the output chardevs are `present_closed` while their TCP backends are
connected, FTCTL must allow `migrate` to proceed.

Failure state:

```text
xcolo_pre_guest_traffic_gate=failed
xcolo_pre_guest_traffic_gate_policy=qemu_9_2_directional_chardev_contract
xcolo_pre_guest_traffic_frontend_contract=<no|unknown>
xcolo_protocol_failure_phase=pre_guest_traffic_contract
last_error=xcolo_pre_migrate_frontend_not_open
```

Diagnostic state:

```text
xcolo_chardev_contract_ready=<yes|no|unknown>
xcolo_chardev_contract_directional_ready=<yes|no|unknown>
xcolo_chardev_contract_strict_frontend_ready=<yes|no|unknown>
xcolo_chardev_contract_output_frontend_policy=backend_connected
```

`strict_frontend_ready=no` is expected when `mirror0` or `red1` are
`present_closed` but connected. It is no longer a failure by itself.

### Socket/Frontend Separation

`xcolo_socket_*` remains a transport diagnostic only. It may be `listen` or
`established` while the frontend contract is still failed.

Reports must distinguish:

```text
socket_contract=ok
directional_chardev_contract=<ok|failed>
strict_frontend_contract=<ok|failed>
```

This prevents firewall/connectivity analysis from being confused with QEMU
chardev frontend readiness. It also prevents output chardev `frontend-open`
semantics from being confused with peer connectivity.

### Cloud-Managed Standby Runtime Reconcile

For `provisioning_backend=cloud-managed` and `mode=ft`,
`ftctl_standby_deactivate()` must not use the generic libvirt-managed cleanup
path.

The cloud-managed recovery path:

1. Destroy the failed generated standby runtime if it exists.
2. Do not undefine the Cloud standby VM.
3. Recreate or start the standby from `standby.generated.xml` so libvirt has a
   domain corresponding to the Cloud DB `Running` row and the generated
   secondary name/disk mapping is preserved.
4. Verify `virsh domstate <secondary_vm_name>` succeeds and is not shut off.
5. If verification fails, record:

```text
cloud_runtime_state_mismatch=true
cloud_runtime_restore=failed
standby_state=runtime_restore_failed
```

If verification succeeds, record:

```text
cloud_runtime_state_mismatch=false
cloud_runtime_restore=ok
standby_state=running
peer_domain_expected=true
```

This is a qemu-side reconciliation guard. It does not change the ownership
principle: Cloud still owns Cloud DB rows and VM lifecycle APIs; qemu FTCTL only
prevents its own runtime cleanup from leaving Cloud-visible state incoherent.

## Retest Expectations

The next run may reach `primary.migrate` while `mirror0` or `red1` are
`present_closed`, but only if their TCP backend is connected and the input
endpoints `red0` and `compare1` are `present_open`.

Possible outcomes:

- If the directional contract passes, FTCTL proceeds to `migrate`.
- If the directional contract fails, FTCTL fails quickly with
  `xcolo_pre_migrate_frontend_not_open` and records which directed edge failed.
- If a later failure still occurs, the progress log must show whether it is a
  migration return-path/COLO control failure or a repeat of a directed chardev
  contract failure.

## Supersedes

This document supersedes:

- `358-ft-xcolo-qemu-doc-preguest-frontend-diagnostic-design-20260605.md`
