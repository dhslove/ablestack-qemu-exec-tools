# 427. FT XCOLO KRBD Local NBD Parent Adapter Design - 2026-06-28

## Problem

The FT primary generated XML removes libvirt-managed disk elements and injects
the protected disk graph through `qemu:commandline`. For KRBD-backed primary
disks this currently creates a parent node like:

```text
-blockdev driver=host_device,node-name=ftctl-primary-parent-sda-host,filename=/dev/rbd/rbd/<image>
-blockdev driver=raw,node-name=ftctl-primary-parent-sda,file=ftctl-primary-parent-sda-host
```

FTCTL can map and pin that stable KRBD path before `virsh create`, but the new
QEMU process can still fail before opening XCOLO listener sockets:

```text
Could not open '/dev/rbd/rbd/<image>': No such file or directory
```

That means the system remains in the repeated KRBD ENOENT class even after the
primary listener `wait=off` correction. Re-mapping and pinning the KRBD path is
necessary, but it is not sufficient when generated QEMU cannot open that path
from its own execution context.

## Principle

This is not a native librbd fallback.

- RBD access remains KRBD-owned by FTCTL.
- Generated QEMU must not use `file.driver=rbd` or `rbd:<pool>/<image>`.
- No Cloud DB schema change is required.
- No VM detail key is added.
- The adapter lifecycle is local FTCTL runtime state and events only.

## To-Be Flow

For primary KRBD parent disks:

1. FTCTL maps and pins `/dev/rbd/<pool>/<image>` as before.
2. FTCTL starts a local read-only `qemu-nbd` adapter on a unix socket:

```text
/dev/rbd/rbd/<image>
  -> qemu-nbd --socket /run/ablestack-vm-ftctl/xcolo-parent-nbd/<vm>/<target>.sock
  -> nbd unix export ftctl-primary-parent-<target>
```

3. FTCTL probes the socket with `qemu-img info nbd+unix:///...`.
4. Generated primary QEMU uses the local NBD parent:

```text
-blockdev driver=nbd,node-name=ftctl-primary-parent-sda-nbd,server.type=unix,server.path=/run/.../sda.sock,export=ftctl-primary-parent-sda
-blockdev driver=raw,node-name=ftctl-primary-parent-sda,file=ftctl-primary-parent-sda-nbd
```

5. Rollback, forced cleanup, or normal release stops the adapter before KRBD pins
   are released.

## Code Changes

### `lib/ftctl/xcolo.sh`

- Add local parent adapter helpers:
  - `ftctl_xcolo_primary_parent_nbd_dir`
  - `ftctl_xcolo_stop_primary_parent_nbd_adapters`
  - `ftctl_xcolo_probe_primary_parent_nbd_adapter`
  - `ftctl_xcolo_start_primary_parent_nbd_adapter`
  - `ftctl_xcolo_prepare_primary_parent_nbd_adapters`
- Extend `ftctl_xcolo_build_startup_disk_args` so primary KRBD sources can be
  emitted as `driver=nbd` nodes when an adapter map is present.
- Extend startup graph validation:
  - KRBD mode rejects native librbd URIs.
  - Primary adapter mode rejects direct primary `/dev/rbd/` host-device leakage.
  - Secondary KRBD remains on the existing host-device path until a separate
    secondary adapter requirement is proven.
- Stop adapters during rollback and KRBD guard release paths.

### `bin/ablestack_vm_ftctl_selftest.sh`

- Update KRBD startup graph tests to expect primary NBD parent adapter output.
- Keep secondary KRBD host-device expectations unchanged.
- Assert that primary adapter output does not contain native librbd or a direct
  primary KRBD host-device parent node.

## Runtime Evidence

Expected state keys:

```text
xcolo_primary_parent_nbd_adapter=enabled
xcolo_primary_parent_nbd_adapter_count=<N>
xcolo_primary_parent_nbd_adapter_map=<krbd>|<socket>|<export>;...
xcolo_startup_disk_parent_backend=krbd-nbd-adapter
```

Expected failure keys:

```text
last_error=xcolo_parent_nbd_adapter_start_failed
last_error=xcolo_parent_nbd_adapter_probe_failed
last_error=xcolo_parent_nbd_adapter_socket_missing
```

## Success Criteria

This change is successful when a KRBD primary generated XML no longer fails at
`virsh create` with `/dev/rbd/... No such file or directory`. If the next failure
is in listener attach, secondary connection, migration, or guest health, that is
progress because the repeated KRBD ENOENT class has been removed.
