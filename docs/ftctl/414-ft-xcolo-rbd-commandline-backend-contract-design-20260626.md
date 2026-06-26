# FT XCOLO RBD commandline backend contract - 2026-06-26

## Background

`r97-link-01` preserved the first successful cloud-managed RBD to RBD FT/XCOLO
path.  Read-only verification of that preserved state showed two different
layers:

| Layer | Observed path form |
|---|---|
| Cloud/libvirt source XML, FTCTL profile, disk plan | `/dev/rbd/rbd/<image>` stable KRBD path |
| Generated XCOLO qemu commandline and live QEMU argv | `file=rbd:rbd/<image>` librbd URI |

Therefore the existing RBD to RBD success path is not a pure generated-commandline
KRBD runtime.  It is a KRBD-managed Cloud/profile path that is translated to the
QEMU native librbd URI form for the generated XCOLO startup graph.

## Problem

Recent KRBD visibility changes tried to keep `/dev/rbd/rbd/<image>` all the way
into the generated XCOLO qemu commandline.  That created a different runtime
path from the preserved `r97-link-01` success and exposed primary-create
visibility and timeout failures before the RBD to QCOW2 protocol experiment
could be evaluated.

The test program now needs two separate validations:

1. preserve the existing KRBD-managed RBD to RBD success path;
2. continue explicit experiments for generated-commandline KRBD, including RBD
   to QCOW2, without changing the default path.

## Design

Add an explicit runtime backend selector:

```bash
FTCTL_XCOLO_RBD_COMMANDLINE_BACKEND=librbd|krbd
```

Default:

```bash
FTCTL_XCOLO_RBD_COMMANDLINE_BACKEND=librbd
```

The names are intentionally explicit:

| Mode | Input identity | Generated qemu commandline | Purpose |
|---|---|---|---|
| `librbd` | stable KRBD path from Cloud/profile/disk plan | `file=rbd:<pool>/<image>` | Preserve the known RBD to RBD success path |
| `krbd` | stable KRBD path from Cloud/profile/disk plan | `file.filename=/dev/rbd/<pool>/<image>` | Explicit experimental runtime validation |

## Guard Rules

| Mode | Must reject |
|---|---|
| `librbd` | `/dev/rbd/` leaked into generated qemu commandline/XML |
| `krbd` | `file=rbd:` / `rbd:rbd/` leaked into generated qemu commandline/XML |

The stable KRBD contract remains separate from the generated commandline
backend.  FTCTL still maps/verifies stable KRBD paths before startup and records
stable path readiness in state.  The commandline backend selector controls only
how those verified RBD identities are materialized in the generated XCOLO graph.

## Test Expectations

- RBD to RBD default tests must continue to produce `file=rbd:rbd/<image>` in
  generated XCOLO qemu args.
- Explicit KRBD runtime tests must produce
  `file.filename=/dev/rbd/rbd/<image>` and must not emit `file=rbd:`.
- RBD to QCOW2 experiments must use the default preserved backend unless the
  experiment explicitly sets `FTCTL_XCOLO_RBD_COMMANDLINE_BACKEND=krbd`.
- Existing `r97-link-01` preserved state must not be modified by this change.

## Deployment Verification

After deployment, verify:

```bash
grep -R "FTCTL_XCOLO_RBD_COMMANDLINE_BACKEND" /usr/local/lib/ablestack-qemu-exec-tools/ftctl /etc/ablestack/ablestack-vm-ftctl.conf
```

For default mode, generated XCOLO XML for RBD-backed FT must contain
`file=rbd:rbd/<image>` and must not contain `/dev/rbd/rbd/<image>` inside the
qemu commandline args.
