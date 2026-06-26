# FT XCOLO Primary Listener And Rollback Hard Gate Design

Date: 2026-06-26

## Problem

The `r97-link-02` FT experiment progressed past the previous RBD command-line backend issue. The primary generated QEMU command now uses the stable KRBD path form, and baseline seeding completes for both root and data disks.

The new failure occurs later:

- primary create starts with XCOLO listener chardevs;
- the first create can still fail after listener bootstrap because `/dev/rbd/rbd/<image>` is not visible to QEMU at open time;
- secondary is then allowed to start and attempts `red0/red1` connections;
- secondary receives `Connection refused` for `10.10.32.3:9103/9104`;
- rollback can leave Cloud DB and libvirt runtime inconsistent, for example primary is `Running` in Cloud DB but missing from primary libvirt, while secondary remains `paused`.

This means the issue is no longer raw/qcow2 or KRBD/librbd selection. It is the ordering and failure isolation around primary generated QEMU startup, listener readiness, secondary attach, and rollback.

## Superseded Gate Note

The listener pair gate in this document was corrected by
`417-ft-xcolo-bootstrap-state-machine-restore-design-20260626.md`.
The primary generated QEMU command can block at `compare1 server=on,wait=on`
before `mirror0` is created. Therefore `compare_bootstrap` is the valid first
readiness gate, and the full mirror/compare channel pair must be verified after
secondary startup, not before it.

## Principles

- Keep the stable KRBD contract: XCOLO command-line RBD paths must use `/dev/rbd/rbd/<image>` and must not fall back to `rbd:<pool>/<image>` unless explicitly configured.
- Do not start the secondary until the primary generated QEMU process is alive and the first blocking external COLO listener is ready. When `compare1` precedes `mirror0` with `wait=on`, this means `compare_bootstrap`; the full listener/channel pair is verified after secondary startup.
- A primary create retry must stay inside the primary-create phase. It must not overlap with secondary creation.
- Cloud-managed rollback after a failed FT setup must not re-create or re-start the standby runtime. It should clean the transient runtime and mark runtime reconciliation evidence.
- Failure evidence must explain whether the failure was KRBD visibility, listener readiness, peer connection, firewall/network, or restore mismatch.

## Code-Level Design

| Area | AS-IS | TO-BE |
|---|---|---|
| KRBD startup readiness | KRBD is mapped and `udevadm settle` is called once. | Add a settle loop that verifies every `/dev/rbd/rbd/<image>` path remains a block device for multiple probes before primary create starts. |
| Primary listener gate | When both listener chardevs use `wait=on`, one visible port can be accepted as bootstrap readiness. | Use `compare_bootstrap` as the valid first gate when `compare1` is the first blocking listener; `listener_pair` remains a fast path only. |
| Secondary attach | Secondary can start after a partial primary listener observation. | Secondary starts after the first valid bootstrap listener and then must complete the full mirror/compare channel attach gate before migrate. |
| Channel attach timeout | Timeout records only the high-level error. | Capture primary and secondary socket snapshots, chardev state, QEMU log tails, and classify whether listener disappeared or peer connection never happened. |
| Cloud-managed rollback | `ftctl_standby_deactivate_cloud_managed()` destroys secondary and then may start/create it again to restore runtime. | Add a rollback-only cleanup path that destroys secondary candidates and verifies no active secondary runtime remains without re-creating it. |
| Primary restore mismatch | Primary restore failure can leave Cloud DB/libvirt mismatch under a generic error. | Record explicit `primary_domain_missing` / `cloud_runtime_state_mismatch` evidence when restore verification fails. |

## Expected Result

If the primary generated QEMU cannot safely open stable KRBD paths, the flow must fail before secondary creation. If the first blocking primary listener does not open, the flow must fail before secondary creation. If secondary cannot attach and complete both mirror/compare channels, the failure must include socket and QEMU evidence. In all failure cases, rollback must not leave a paused secondary runtime or a silent primary DB/libvirt mismatch.
