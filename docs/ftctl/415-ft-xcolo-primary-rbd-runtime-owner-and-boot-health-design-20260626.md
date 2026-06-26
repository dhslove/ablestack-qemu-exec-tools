# 415. FT X-COLO Primary RBD Runtime Owner And Boot Health Design

## Problem

The `r97-link-02` RBD to qcow2 experimental FT run reached the pre-migrate X-COLO startup path:

- baseline seed completed;
- generated primary XML used native QEMU RBD command line, `file=rbd:<pool>/<image>`;
- generated secondary XML used qcow2 replication/quorum graph;
- channel, topology, firewall, and pre-migrate contract checks passed;
- primary was resumed before migration.

The run then failed before the `migrate` command:

```text
last_error=xcolo_primary_colo_boot_unhealthy:qga_timeout
```

This does not prove that X-COLO migration failed. It proves that the generated primary did not reach the required guest health state after the X-COLO disk graph was started.

Earlier RBD to RBD validation had a similar symptom where the guest appeared to fail boot while a RBD path/lock was still held by the wrong runtime owner. Therefore the primary boot gate must distinguish a true guest boot timeout from a RBD runtime owner conflict.

## Design Principles

- Do not change the already validated `r97-link-01` RBD to RBD success path.
- Do not mix `krbd` and native `librbd` ownership for the same primary runtime disk graph.
- Stable Cloud disk paths may still be `/dev/rbd/<pool>/<image>`, but that path is not always the runtime owner.
- In `librbd` command-line mode, QEMU must own the RBD image through `file=rbd:<pool>/<image>`.
- In `krbd` command-line mode, QEMU may own the image through `/dev/rbd/<pool>/<image>`.
- A primary boot failure must record RBD ownership evidence before it is reported as a generic QGA timeout.

## AS-IS

| Area | Current behavior | Risk |
|---|---|---|
| Stable RBD contract | Any primary `/dev/rbd/...` source is mapped with `ftctl_blockcopy_krbd_map_local`. | A `librbd` generated primary can later open the same image while KRBD mapping remains. |
| Primary generated XML | Default command line uses `file=rbd:<pool>/<image>`. | Correct for native RBD, but unsafe if KRBD still owns the image. |
| Boot health gate | Checks QMP block health, QEMU log tail, and QGA. | `qga_timeout` hides whether a RBD owner/lock conflict blocked guest boot. |
| Failure evidence | Debug includes QMP/log evidence. | No mandatory `rbd status`, `rbd lock list`, or `rbd showmapped` evidence tied to the boot gate. |

## TO-BE

| Area | New behavior | Result |
|---|---|---|
| Stable RBD contract | Backend-aware. `krbd` maps stable paths; `librbd` verifies native RBD backend without creating KRBD ownership. | The selected command-line backend owns the image consistently. |
| Primary create preflight | In `librbd` mode, release local KRBD mappings for primary RBD sources before generated primary create. | Prevents KRBD plus librbd dual ownership. |
| Boot health evidence | Each premigrate boot loop captures RBD status, lock list, and showmapped evidence. | A boot failure includes storage ownership context. |
| Failure classification | Remaining KRBD mapping in `librbd` mode fails as `xcolo_primary_rbd_runtime_owner_conflict`. | Avoids misleading generic `qga_timeout`. |

## Implementation Plan

### qemu FTCTL

1. Add normalized backend helper:
   - `ftctl_xcolo_rbd_commandline_backend`

2. Add primary RBD evidence helpers:
   - `ftctl_xcolo_local_rbd_showmapped_devices`
   - `ftctl_xcolo_capture_primary_rbd_owner_evidence`

3. Add primary ownership preparation:
   - `ftctl_xcolo_release_primary_krbd_maps_for_librbd`

4. Change `ftctl_xcolo_verify_stable_rbd_contract`:
   - `krbd`: keep existing KRBD mapping and `qemu-img info /dev/rbd/...` validation.
   - `librbd`: do not map; validate `qemu-img info rbd:<pool>/<image>`.

5. Change premigrate boot gate:
   - collect RBD owner evidence on each loop;
   - if KRBD mapping remains in `librbd` mode, fail with `xcolo_primary_rbd_runtime_owner_conflict`;
   - otherwise keep the existing guest/QGA timeout behavior.

### Tests

Add selftest coverage:

- `krbd` stable contract still maps primary and secondary paths.
- `librbd` stable contract does not call primary KRBD map.

## Expected Retest Outcome

If the previous boot failure was caused by a stale KRBD runtime owner, the next run should pass the primary boot gate and move to migration.

If the failure remains, the evidence will identify whether:

- KRBD mapping still exists unexpectedly;
- RBD lock/watchers are abnormal;
- QEMU block graph is healthy but the guest still does not boot;
- the remaining issue is specific to the RBD to qcow2 X-COLO graph rather than RBD ownership.
