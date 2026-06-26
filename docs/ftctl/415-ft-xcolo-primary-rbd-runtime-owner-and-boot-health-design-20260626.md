# 415. FT XCOLO Primary KRBD Owner And Boot Health Design

## Problem

The latest `r97-link-02` RBD to qcow2 experimental FT run reached the
pre-migrate XCOLO startup path, but the generated primary used native QEMU RBD
URI form:

```text
file=rbd:rbd/<image>
```

The run then failed before `migrate`:

```text
last_error=xcolo_primary_colo_boot_unhealthy:qga_timeout
```

That result is not a valid KRBD-path result.  It was produced after FTCTL
changed the RBD runtime backend away from ABLESTACK's stable KRBD path.  Before
continuing RBD to qcow2 validation, the primary startup graph must be restored
to the same RBD identity Cloud/libvirt uses:

```text
/dev/rbd/rbd/<image>
```

## Design Principles

- The default RBD-backed FT/XCOLO path is KRBD, not native `librbd`.
- `/dev/rbd/rbd/<image>` is the stable path in Cloud/libvirt/profile/disk-plan
  and generated XCOLO qemu commandline.
- `/dev/rbdN` is diagnostic only and must not become durable configuration.
- `file=rbd:` and `rbd:rbd/` are forbidden in default generated XCOLO args/XML.
- A primary boot failure must record RBD mapping, watcher, and lock evidence,
  but KRBD mappings are expected in KRBD mode and must not be reported as
  runtime owner conflicts.
- Explicit `librbd` remains only a guarded experiment.  In that mode, KRBD
  mappings are conflicts because native QEMU RBD owns the image.

## AS-IS

| Area | Current behavior | Risk |
|---|---|---|
| Backend default | Defaults to `librbd` | Violates ABLESTACK KRBD storage policy |
| Generated primary XML | Uses `file=rbd:<pool>/<image>` for RBD parents | Primary runtime path differs from Cloud/libvirt path |
| RBD owner evidence | Treats mapped KRBD as conflict only in librbd-gated paths | Default path can hide or misclassify storage evidence |
| Stable RBD contract | Backend-aware, but default selects native RBD | Correct KRBD contract is not exercised by default |
| Selftest | Default startup graph expects native RBD URI | Regression tests protect the wrong behavior |

## TO-BE

| Area | New behavior | Result |
|---|---|---|
| Backend default | Defaults to `krbd` | Default FT follows ABLESTACK RBD policy |
| Generated primary XML | Emits `file.filename=/dev/rbd/rbd/<image>` | Primary QEMU uses the stable KRBD path |
| Generated secondary XML | Uses stable KRBD for RBD destinations and file paths for qcow2 destinations | RBD to RBD and RBD to qcow2 are both explicit and inspectable |
| RBD owner evidence | Captured for every boot loop | Boot failures include `showmapped`, `status`, and `lock list` evidence |
| Failure classification | KRBD mapped is normal in KRBD mode; mapped KRBD is conflict only in explicit librbd mode | Avoids false storage-owner failures |
| Selftest | Default test asserts KRBD and rejects native RBD URI | CI prevents default backend regression |

## Implementation Plan

### qemu FTCTL

1. Change the normalized backend helper:
   - default: `krbd`;
   - supported explicit values: `krbd`, `librbd`;
   - invalid values fall back to `krbd`.
2. Change startup disk arg generation:
   - default RBD source: `file.filename=/dev/rbd/<pool>/<image>`;
   - explicit `librbd`: `file=rbd:<pool>/<image>`.
3. Change startup graph guards:
   - KRBD mode fails if generated args/XML contain `file=rbd:` or `rbd:rbd/`;
   - explicit librbd mode fails if generated args/XML contain `/dev/rbd/`.
4. Keep stable RBD contract KRBD-aware:
   - map local primary stable path before generated primary create;
   - map remote secondary stable path before secondary/incoming use;
   - verify both sides with `qemu-img info --force-share` against the stable
     KRBD path.
5. Record RBD evidence at storage/boot gates for all backends.
6. Classify remaining KRBD mapping as conflict only when the active backend is
   explicit `librbd`.

### Tests

- Default startup disk graph emits `file.filename=/dev/rbd/...`.
- Default startup disk graph does not emit `file=rbd:`.
- Explicit KRBD still emits stable KRBD.
- Explicit librbd remains available but opt-in.
- KRBD stable contract maps primary and secondary paths.
- Explicit librbd stable contract does not map primary KRBD.

## Retest Criteria

The next `r97-link-02` test is valid only if evidence shows:

```text
xcolo_rbd_commandline_backend=krbd
xcolo_startup_disk_backend=krbd-rbd-or-file
primary_qemu_args contains file.filename=/dev/rbd/rbd/<primary-image>
primary_qemu_args does not contain file=rbd:
```

If the primary still fails to boot, the new evidence must identify whether the
failure is:

- a missing KRBD map/path;
- an RBD lock/watcher issue;
- a QEMU block graph problem;
- a guest filesystem/boot issue unrelated to the backend selector.
