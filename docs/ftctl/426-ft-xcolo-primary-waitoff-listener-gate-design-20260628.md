# FT XCOLO Primary wait=off Listener Gate Design - 2026-06-28

## Background

During the `r97-link-02` FT retest, FTCTL improved the KRBD startup path enough to create both primary and secondary generated domains, but the COLO channel attach phase still failed.

Observed evidence:

- Primary QEMU command line opened `compare1` on port `9104` with `server=on,wait=on` before `mirror0` appeared later in the command line.
- Primary host had `9104` in LISTEN state, but `9103` was not listening.
- Secondary attempted `red0 -> 9103` and failed with connection refused.
- Secondary had a partial `red1 -> 9104` connection that later moved to `CLOSE-WAIT`.
- FTCTL ended with `xcolo_primary_create_failed_before_channel_attach`.

The failure is not a storage-path regression. The previous KRBD fix was effective: primary generated QEMU was using `host_device` blockdev sources against `/dev/rbd/rbd/<image>` stable KRBD paths instead of `rbd:<pool>/<image>` librbd syntax. The new blocker is the order and blocking behavior of external COLO chardev listeners.

## QEMU COLO Document Comparison

QEMU's COLO sample command lines use socket chardevs for the mirror and compare paths. In a hand-run two-terminal sample, `wait=on` can be used deliberately because the operator controls both sides and can block one process until its peer connects.

FTCTL's environment is different:

- `virsh create` is used under Cloud/FTCTL orchestration.
- FTCTL must inspect generated domains, KRBD visibility, QMP state, and Cloud state after the process starts.
- Blocking inside QEMU command-line parsing prevents later command-line objects from being materialized.

### Previous Difference

| Area | QEMU sample expectation | Previous FTCTL behavior | Failure |
| --- | --- | --- | --- |
| Primary `compare1` | May block only when operator-controlled order guarantees the peer exists | Emitted before `mirror0` with `wait=on` | QEMU stopped parsing before `mirror0` listener was created |
| Primary `mirror0` | Listener must exist before secondary `red0` connects | Appeared after blocking `compare1` | Secondary `red0` got connection refused |
| Readiness gate | Human/operator or simple script controls order | FTCTL treated partial listener readiness as `compare_bootstrap` | One external listener was allowed to pass even when the data path was absent |

### New Contract

| Area | To-be |
| --- | --- |
| Primary external listeners | `mirror0` and `compare1` are always emitted as `server=on,wait=off` |
| QEMU parsing | Primary generated QEMU must finish materializing command-line objects without blocking on peer connection |
| FTCTL primary listener gate | FTCTL waits until both primary external listener ports are LISTEN |
| FTCTL secondary attach gate | FTCTL waits until both red0/mirror and red1/compare paths are attached before migrate |
| Failure diagnostics | Listener and attach failures record which port/path is missing instead of reporting only a generic timeout |

## Implementation Plan

1. Primary generated QEMU arguments
   - Force `mirror0` and `compare1` to `wait=off` in `ftctl_xcolo_build_primary_qemu_args()`.
   - Ignore legacy `FTCTL_XCOLO_MIRROR_WAIT` and `FTCTL_XCOLO_COMPARE_WAIT` overrides in the managed libvirt path.
   - Keep COLO network filters active at startup. This change only removes socket listener blocking, not the filter objects.

2. Runtime command-line validation
   - Update `ftctl_xcolo_collect_primary_filter_cmdline_state()` to expect `wait=off` for both primary external listener chardevs.
   - Keep compare loopback sockets as `wait=off`.

3. Primary listener gate
   - Remove `compare_bootstrap`, `mirror_bootstrap`, and any partial listener success path.
   - Accept readiness only when both `mirror0` and `compare1` ports are listening.
   - Record `xcolo_primary_listener_wait_policy=wait_off_qmp_gated`.

4. Channel attach diagnostics
   - On attach timeout, capture the COLO chardev contract for primary and secondary.
   - Classify failures as secondary red0/red1 not connected when contract evidence points there.

5. Selftest
   - Generated primary XML must contain `wait=off` for `mirror0` and `compare1`.
   - Generated primary XML must not contain `wait=on` for either external listener.
   - VNET header selftest must verify the same listener wait policy.

## Non-goals

- Do not change KRBD stable path handling.
- Do not switch back to librbd syntax.
- Do not alter primary/secondary disk graph construction or PCI topology materialization in this change.
- Do not change Cloud-side UI/API behavior.

## Smoke Criteria

Before deployment:

- `bash -n lib/ftctl/xcolo.sh`
- `bash -n bin/ablestack_vm_ftctl_selftest.sh`
- targeted selftest for generated XML listener wait policy
- `git diff --check`

After deployment:

- Installed host script contains `xcolo_primary_listener_wait_policy=wait_off_qmp_gated` and `listener_pair_wait_off`.
- `ablestack_vm_ftctl --help` starts without syntax/runtime loader failure.
- Cleanup leaves `r97-link-02` primary running and no active FTCTL protection row for the failed standby test.
