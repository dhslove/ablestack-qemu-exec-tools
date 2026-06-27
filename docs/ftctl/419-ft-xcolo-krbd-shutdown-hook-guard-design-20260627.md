# FT XCOLO KRBD Shutdown Hook Guard Design - 2026-06-27

## Problem

The `r97-link-02` FT retest failed after baseline seed succeeded and XCOLO
bootstrap reached generation 2. Primary and secondary generated domains were
created far enough for listener bootstrap, but primary QEMU exited before
channel attach:

```text
qemu-kvm: -drive ... file.filename=/dev/rbd/rbd/<image>,driver=raw:
Could not open '/dev/rbd/rbd/<image>': No such file or directory
```

ABLESTACK qemu hooks intentionally unmap KRBD paths on VM shutdown. FTCTL
shuts down the cloud-managed primary VM before starting the generated XCOLO
primary. That means the hook can race with the FTCTL remap/check path and can
remove `/dev/rbd/rbd/<image>` before QEMU actually opens the base disk.

This is not a storage-type mismatch. It is a lifecycle ownership issue between:

- Cloud/libvirt shutdown hook RBD cleanup; and
- FTCTL cold conversion reuse of the same stable KRBD paths.

## Principle

FTCTL must explicitly own primary KRBD mappings during the conversion window.

The conversion window starts before primary shutdown and ends only after either:

- generated primary QEMU has opened its disks; or
- rollback has restored the original primary runtime.

During this window FTCTL must:

1. expose a guard contract that host hooks can read;
2. keep the actual KRBD block devices open with file descriptors;
3. wait for shutdown hook activity to settle;
4. verify stable paths immediately before QEMU create; and
5. avoid delaying disk open behind blocking COLO chardev listeners.

## AS-IS / TO-BE

| Area | AS-IS | TO-BE |
|---|---|---|
| Hook coordination | FTCTL remaps after shutdown but does not mark ownership for hooks. | FTCTL writes `/run/ablestack-vm-ftctl/krbd-guard/<vm>/` before shutdown. |
| KRBD hold | Hold files are informational only. | FTCTL starts fd pin processes that keep each primary KRBD block device open. |
| Shutdown race | Hook may unmap after FTCTL's map/check. | FTCTL pins before shutdown, waits for hook settle, remaps/pins again if needed. |
| QEMU create order | Primary qemu commandline emits blocking chardev listeners before disk graph. | Primary disk graph args are emitted before COLO network args, so disk open happens before listener wait. |
| Create validation | Path existence and qemu user access are checked. | Add qemu-img openability evidence and pin state to the same phase. |
| Rollback | Destroy failure can block restore when generated domain is already gone. | If destroy fails, verify domstate; `unknown/shutoff` continues restore. |
| Partial guard failure | A failed pre-shutdown check can leave temporary runtime files. | Guard startup failure releases pins and removes guard files before returning. |

## Code Changes

### 1. KRBD guard contract

Add:

```bash
ftctl_xcolo_primary_krbd_guard_dir(vm)
ftctl_xcolo_begin_primary_krbd_shutdown_guard(vm, xml, phase)
ftctl_xcolo_end_primary_krbd_shutdown_guard(vm, reason)
```

Guard files:

```text
/run/ablestack-vm-ftctl/krbd-guard/<vm>/enabled
/run/ablestack-vm-ftctl/krbd-guard/<vm>/paths
/run/ablestack-vm-ftctl/krbd-guard/<vm>/token
/run/ablestack-vm-ftctl/krbd-guard/<vm>/created
/run/ablestack-vm-ftctl/krbd-guard/<vm>/expires
```

External qemu hooks can skip or defer unmap when `enabled` exists, the path is
listed in `paths`, and `expires` has not passed.

### 2. Primary KRBD fd pin

Add:

```bash
ftctl_xcolo_pin_primary_krbd_runtime_path(vm, path, phase)
ftctl_xcolo_release_primary_krbd_pins(vm, reason)
```

Each pin opens the resolved block device and sleeps until FTCTL releases it.
This prevents normal `rbd unmap` from removing the mapping while QEMU create is
waiting on COLO listener sockets.

### 3. Hook settle and openability check

Enhance `ftctl_xcolo_prepare_primary_krbd_runtime_path`:

- map the stable KRBD path if missing;
- wait for udev settle and stable path visibility;
- verify qemu user read/write access;
- verify `qemu-img info --force-share` can open the path when available;
- start/update the fd pin for the path.

### 4. Commandline order

Change `ftctl_xcolo_apply_startup_disk_graphs` primary ordering from:

```text
network args + disk args
```

to:

```text
disk args + network args
```

Secondary ordering remains unchanged because the secondary redirection sockets
are non-blocking reconnect clients and the current path has already reached
secondary startup.

### 5. Rollback hardening

Update `ftctl_xcolo_force_primary_restore_from_backup` so a failed destroy is
non-fatal when libvirt reports the generated domain is already absent or shut
off. Restore then continues through the original XML path.

### 6. Partial guard cleanup

If any KRBD path fails prepare/open/pin while guard startup is in progress,
FTCTL immediately releases already-created pins and removes the guard directory.
The primary VM has not been shut down yet in this phase, so this is a clean
preflight failure rather than a partial conversion.

## Success Criteria

- After primary shutdown, KRBD paths stay available until generated primary
  QEMU opens them.
- If a hook still unmaps a path, failure is classified as KRBD ownership loss
  with guard/pin evidence.
- Primary generated QEMU no longer blocks at COLO chardev listeners before
  opening disk graph paths.
- Rollback leaves primary libvirt runtime restored instead of Cloud DB saying
  `Running` while libvirt has no domain.
- A guard prepare failure leaves no stale `krbd-guard` or `krbd-pin` directory.
