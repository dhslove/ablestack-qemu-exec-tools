# 364. FT X-COLO Native RBD Startup Backend Design

Date: 2026-06-05

## Trigger

Run 86 no longer hit the previous COLO invalid-message loop or the secondary
runtime disk hotplug crash. The new failure happened earlier, while QEMU was
starting from generated transient XML:

```text
Could not open '/dev/rbd/rbd/<image-id>': No such file or directory
```

The generated XML had already removed the protected libvirt `<disk>` entries
and moved the COLO disk graph into `qemu:commandline`. That means libvirt no
longer owns those protected disk paths as XML disks during startup.

## Principle

For FT/X-COLO:

- Cloud and FTCTL state keep `/dev/rbd/rbd/<image-id>` as the stable disk
  identity.
- FTCTL must not rewrite stable identities to `/dev/rbdN`.
- The generated QEMU startup graph must not depend on KRBD symlink visibility
  for protected disks that were removed from the generated XML.
- The generated QEMU startup graph must use QEMU's native RBD backend for RBD
  protected disks.

## Corrected Startup Backend Contract

When the protected source is:

```text
/dev/rbd/<pool>/<image>
```

FTCTL builds the startup graph base node as:

```text
file=rbd:<pool>/<image>
```

instead of:

```text
file.filename=/dev/rbd/<pool>/<image>
```

The same rule applies to both primary and secondary generated qemu commandline
disk graphs.

## Validation

Before `virsh create`, FTCTL validates each RBD-backed startup disk through:

1. `rbd info <pool>/<image>`
2. `qemu-img info --force-share --output=json rbd:<pool>/<image>`

Primary validation runs on the primary host. Secondary validation runs on the
secondary host. If validation fails, FTCTL fails before QEMU startup with a
startup-backend-specific error instead of surfacing as a listener timeout.

## Fail-Fast Errors

The implementation must expose distinct failures:

- `xcolo_startup_krbd_path_leaked`
  - generated qemu commandline still contains `/dev/rbd/`
- `xcolo_rbd_startup_backend_unavailable`
  - RBD image exists as a Cloud identity, but QEMU cannot open it through the
    native RBD backend

These errors are more actionable than the previous downstream symptom:

```text
xcolo_block_primary_listener_wait_failed
```

## Non-Goals

- Do not reintroduce runtime `device_del` / `device_add` disk replacement.
- Do not switch generated XML or FTCTL state to `/dev/rbdN`.
- Do not depend on qemu hooks to keep a KRBD symlink alive for protected disks
  that are no longer represented as libvirt XML `<disk>` devices.
