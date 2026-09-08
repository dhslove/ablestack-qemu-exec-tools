# FT XCOLO Premigrate Frontend Open Before Migrate Design - 2026-06-05

## Background

Run 79 proved two things at the same time:

- The generated QEMU COLO command-line topology is now audited and correct:
  - `xcolo_qemu_doc_topology=ok`
  - `xcolo_qemu_doc_primary_qom_ready=yes`
  - `xcolo_qemu_doc_primary_cmdline_ready=yes`
  - `xcolo_qemu_doc_secondary_cmdline_ready=yes`
- The runtime chardev frontends still failed before primary `migrate`:
  - `mirror_path_primary_mirror0=present_closed`
  - `compare_path_secondary_red1=present_closed`
  - primary QEMU logged `filter mirror send failed(Operation not permitted)`

This means the next problem is not the shape of the documented COLO topology.
It is the startup ordering between primary active filters and the secondary
chardev peers.

## Correct Boundary

Primary `migrate` is not a harmless preparation command. In the QEMU COLO
procedure it is the command that starts the COLO runtime. Once `migrate` is
issued, memory/device state replication and the network compare/mirror path are
expected to become active.

Therefore it is not correct to issue `migrate` first and then wait for
`mirror0` or `red1` to become ready. FTCTL must prove the mirror and compare
frontends are usable before primary `migrate`.

## QEMU Sample Difference

The QEMU sample uses:

- primary `mirror0`: `server=on,wait=off`
- primary `compare1`: `server=on,wait=on`

That is suitable for the documented manual startup procedure, where the user can
launch both QEMU processes and observe their command-line flow directly.

FTCTL's cloud-managed path is different:

- primary and secondary are created through libvirt
- primary starts with startup-active `filter-mirror m0`
- primary creation is asynchronous because `compare1 wait=on` may block until
  secondary `red1` connects
- the guest is paused with `-S`, but QEMU can still initialize the active
  network filter path before FTCTL reaches the later pre-migrate gate

Run 79 showed that `mirror0 wait=off` lets primary QEMU pass the mirror listener
before the secondary `red0` peer is attached. In this environment, the active
`m0` filter can then hit the mirror path early and QEMU logs:

- `filter mirror send failed(Operation not permitted)`

## Design Decision

For FTCTL's libvirt-orchestrated path, change the generated primary mirror
listener to:

- `mirror0 server=on,wait=on`

Keep:

- `compare1 server=on,wait=on`
- startup-active `m0`, `redire0`, `redire1`, and `comp0`
- no normal-path `status=off`
- no post-migrate staged `qom-set status=on`

This is an intentional orchestration extension over the QEMU sample. It is not a
return to staged filter activation. The purpose is to make primary QEMU block on
the mirror peer before it can pass startup initialization with an unattached
`mirror0` path.

## Deadlock Handling

Earlier designs avoided `mirror0 wait=on` because a synchronous `virsh create`
could deadlock: primary waited for secondary, but secondary was not started yet.

The current implementation no longer uses that synchronous model:

1. Start primary generated XML asynchronously.
2. Wait until the primary mirror listener is visible.
3. Start the secondary generated XML.
4. Wait for primary `9003` and `9004` peer connections.
5. Finish the primary create operation.
6. Run pre-migrate QMP setup.
7. Prove frontend readiness.
8. Only then issue primary `migrate`.

Because the primary create is asynchronous, `mirror0 wait=on` no longer blocks
FTCTL from starting the secondary.

## New Guard

Add a pre-migrate mirror-send guard:

- record the primary QEMU log line count before generated primary startup
- scan only log lines after that baseline
- if `filter mirror send failed(...)` appears before primary `migrate`, fail
  with:
  - `last_error=xcolo_filter_mirror_send_before_migrate`
  - `xcolo_protocol_failure_phase=premigrate_filter_mirror_send`
  - `xcolo_premigrate_filter_mirror_send_failed=yes`
  - `xcolo_premigrate_filter_mirror_send_errno=<normalized errno>`

Run this guard:

- after primary peer channels attach
- after primary create completes
- immediately before primary `migrate`

## Retest Interpretation

The next run must be interpreted as follows:

- If `xcolo_filter_mirror_send_before_migrate` occurs, the new mirror wait
  policy still does not prevent early primary filter send, and the next fix must
  suppress primary guest/NIC TX earlier than QEMU filter startup.
- Superseded by
  `358-ft-xcolo-qemu-doc-preguest-frontend-diagnostic-design-20260605.md`:
  if QEMU document topology, socket snapshot, stable RBD contract, and
  pre-migrate mirror-send guard pass, `frontend-open=false` before migrate is
  diagnostic evidence and must not block primary `migrate`.
- If the pre-migrate contract passes and primary `migrate` starts, this change
  moved the boundary forward and the next validation point is COLO steady-state
  convergence.

## Supersedes

This design supersedes the default `mirror0 wait=off` assumption in:

- [303. FT X-COLO Primary-First Listener Wait Design](303-ft-xcolo-primary-first-listener-wait-design-20260528.md)
- [304. FT X-COLO Channel Attach Before Migrate Design](304-ft-xcolo-channel-attach-before-migrate-design-20260528.md)
- [355. FT XCOLO QEMU Doc Hard Topology Audit Design](355-ft-xcolo-qemu-doc-hard-topology-audit-design-20260605.md)

Those documents remain useful historical context, but the active
cloud-managed/libvirt orchestration contract is now:

- QEMU sample topology shape
- FTCTL mirror listener peer-before-send extension
- migrate only after frontend readiness
