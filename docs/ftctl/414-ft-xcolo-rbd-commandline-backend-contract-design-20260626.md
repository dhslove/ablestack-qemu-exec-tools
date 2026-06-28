# FT XCOLO KRBD commandline backend contract - 2026-06-26

> Superseded for FT/XCOLO runtime by
> `430-ft-xcolo-native-rbd-runtime-backend-design-20260628.md`.
> This document is retained as historical context for the earlier KRBD-default
> decision.  Current FT runtime defaults to native librbd while Cloud/libvirt
> inventory and normal VM operation still use stable KRBD paths.

## Background

ABLESTACK manages RBD-backed VM disks through the stable KRBD path:

```text
/dev/rbd/<pool>/<image>
```

The generated FT/XCOLO runtime must preserve that identity.  A transient
`/dev/rbdN` device may be useful for diagnostics, but it is not a durable
contract.  Native QEMU RBD URI forms such as `rbd:<pool>/<image>` or
`file=rbd:<pool>/<image>` are not the default ABLESTACK FT path.

## Problem

Recent FT work changed the generated XCOLO qemu commandline default to native
`librbd`:

```text
file=rbd:rbd/<image>
```

That violated the ABLESTACK KRBD path principle and made RBD to qcow2 testing
ambiguous.  When the primary guest failed its pre-migrate boot gate, the run no
longer proved whether the failure belonged to COLO, qcow2, or the unintended
RBD backend change.

## Design Principles

- Keep Cloud/libvirt/profile/disk-plan/generate-commandline identity aligned on
  `/dev/rbd/<pool>/<image>` for default RBD-backed FT.
- Do not use `/dev/rbdN` in generated XML, generated qemu args, state profiles,
  or durable runtime records.
- Do not emit `file=rbd:` or `rbd:rbd/` in the default FT XCOLO RBD path.
- Keep explicit `FTCTL_XCOLO_RBD_COMMANDLINE_BACKEND=librbd` only as a guarded
  experiment path.  It is not the default and it must not be used silently.
- Preserve RBD owner evidence (`rbd showmapped`, `rbd status`, `rbd lock list`)
  at boot gates, but treat KRBD mappings as expected in KRBD mode.

## AS-IS

| Area | Current behavior | Issue |
|---|---|---|
| Backend default | `FTCTL_XCOLO_RBD_COMMANDLINE_BACKEND` defaults to `librbd` | Default path violates ABLESTACK KRBD policy |
| Generated commandline | `/dev/rbd/rbd/<image>` is converted to `file=rbd:rbd/<image>` | Cloud/libvirt disk identity and FT runtime disk identity diverge |
| Guard rules | KRBD mode rejects native URI, but default mode is native URI | Guard protects only an opt-in mode |
| Boot evidence | RBD owner evidence is captured mainly for `librbd` conflict detection | KRBD-mode failures can miss useful RBD evidence |
| Selftest | Default test expects `file=rbd:rbd/<image>` | Tests preserve the wrong contract |

## TO-BE

| Area | New behavior | Result |
|---|---|---|
| Backend default | `FTCTL_XCOLO_RBD_COMMANDLINE_BACKEND` defaults to `krbd` | Default FT path follows ABLESTACK storage policy |
| Generated commandline | RBD source is emitted as `file.filename=/dev/rbd/<pool>/<image>` | QEMU runtime uses the same stable KRBD identity as Cloud/libvirt |
| Guard rules | Default KRBD mode rejects `file=rbd:` and `rbd:rbd/` in generated args/XML | Backend drift is caught before VM create/migrate |
| Stable RBD contract | KRBD mode maps/verifies `/dev/rbd/<pool>/<image>` locally and remotely | Missing map/path issues fail before COLO handoff |
| Boot evidence | RBD owner evidence is captured for all backend modes | Boot failures include storage evidence without misclassifying KRBD mappings |
| Selftest | Default tests assert `file.filename=/dev/rbd/...` and reject `file=rbd:` | Regression tests enforce the correct default |

## Implementation

1. Normalize `ftctl_xcolo_rbd_commandline_backend` to return `krbd` unless an
   explicit supported value is supplied.
2. Pass `XCOLO_RBD_COMMANDLINE_BACKEND=krbd` into the qemu-arg generation
   helper by default.
3. Keep qemu-arg generation backend-aware:
   - `krbd`: `file.filename=/dev/rbd/<pool>/<image>`;
   - explicit `librbd`: `file=rbd:<pool>/<image>`.
4. Validate generated commandline and generated XML:
   - KRBD mode must not contain `file=rbd:` or `rbd:rbd/`;
   - explicit librbd mode must not contain `/dev/rbd/`.
5. Capture primary RBD evidence in every pre-migrate boot loop.  In KRBD mode,
   a mapped KRBD device is normal.  In explicit librbd mode, remaining KRBD
   ownership is a conflict.
6. Update selftests so the default startup disk graph proves KRBD and the
   explicit librbd path remains opt-in only.

## Deployment Verification

On every deployed host, verify:

```bash
grep -R "FTCTL_XCOLO_RBD_COMMANDLINE_BACKEND:-krbd" \
  /usr/local/lib/ablestack-qemu-exec-tools/ftctl/xcolo.sh
grep -R "xcolo_startup_krbd_uri_leaked" \
  /usr/local/lib/ablestack-qemu-exec-tools/ftctl/xcolo.sh
```

During the next RBD-backed FT test, generated XCOLO XML and state must show:

```text
xcolo_rbd_commandline_backend=krbd
file.filename=/dev/rbd/rbd/<image>
```

They must not show:

```text
file=rbd:
rbd:rbd/
/dev/rbdN
```
