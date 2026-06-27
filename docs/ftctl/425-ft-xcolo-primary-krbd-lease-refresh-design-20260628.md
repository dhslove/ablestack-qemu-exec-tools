# 425. FT XCOLO Primary KRBD Lease Refresh Design - 2026-06-28

## Problem

The latest `r97-link-02` FT/XCOLO run moved past secondary replication
blockdev creation, but primary generated QEMU failed while opening the KRBD
stable path:

```text
Could not open /dev/rbd/rbd/<image>: No such file or directory
```

This means the existing pre-create KRBD map check was not enough. In the
QEMU COLO startup path, primary generated QEMU may wait on blocking chardev
listeners before materializing the blockdev graph. During that wait window,
ABLESTACK qemu hook cleanup or another RBD cleanup path can remove the
`/dev/rbd/rbd/<image>` stable path even though FTCTL already mapped it.

## Design Principle

FT cloud-managed KRBD must keep using the stable path
`/dev/rbd/rbd/<image>` as the long-lived contract. FTCTL must not switch the
XML or QEMU commandline contract to `/dev/rbdN`, and must not fall back to
librbd for this path. The fix is lifecycle ownership, not a storage backend
change.

## AS-IS / TO-BE

| Area | AS-IS | TO-BE |
| --- | --- | --- |
| Primary KRBD prepare | Map once before `virsh create`. | Map before create, then refresh during listener and peer attach waits until QEMU materializes the graph. |
| Stable path ownership | A pin process holds the resolved `/dev/rbdN`, but the stable path can still disappear. | Keep the pin as a helper, but treat `/dev/rbd/rbd/<image>` visibility as the required contract and remap it if it disappears. |
| Hook coordination | Hook guard exists, but FTCTL does not continuously verify the stable path during QEMU wait windows. | Hook must respect `/run/ablestack-vm-ftctl/krbd-guard/<vm>` and FTCTL refresh must repair stable paths before QEMU open. |
| Failure classification | Some failures collapse into channel/listener create failures. | KRBD ENOENT is classified as `xcolo_primary_krbd_path_lost_at_create`; refresh failure is `xcolo_primary_krbd_refresh_failed`. |
| Retry | Internal create retry was opt-in. | KRBD ENOENT retry is enabled by default as a fallback after refresh/guard. |

## Code Contract

### qemu FTCTL

`lib/ftctl/xcolo.sh` adds:

```bash
ftctl_xcolo_refresh_primary_krbd_runtime_paths_from_xml(vm, generated_xml, phase)
```

The function:

1. extracts all `/dev/rbd/...` paths from the generated primary XML and
   qemu commandline args;
2. checks whether each stable path is currently a block device;
3. if a path is missing, calls `ftctl_xcolo_prepare_primary_krbd_runtime_path`
   to remap, settle udev, apply qemu access, and re-pin;
4. if a path is present, refreshes the pin;
5. records `xcolo_primary_krbd_refresh_*` state keys and emits
   `xcolo.primary_krbd_runtime_refresh` events.

Refresh is called in these phases:

- `wait_listener`: every primary generated listener wait loop iteration;
- `listener_ready`: immediately before primary KRBD namespace verification;
- `wait_peer_attach`: every primary peer attach wait loop iteration;
- `peer_attached`: immediately after mirror/compare peer channels are detected.

`FTCTL_XCOLO_PRIMARY_INTERNAL_CREATE_RETRY` defaults to `1` so a KRBD ENOENT
from the generated QEMU create path triggers one remap/retry cycle. This is a
fallback only; the primary guard remains continuous refresh during wait windows.

### Cloud qemu hook

The Cloud hook consumer must keep respecting the qemu-side guard contract:

```text
/run/ablestack-vm-ftctl/krbd-guard/<vm>/enabled
/run/ablestack-vm-ftctl/krbd-guard/<vm>/paths
/run/ablestack-vm-ftctl/krbd-guard/<vm>/expires
```

If a shutdown/unmap hook sees a guarded path, it must skip or defer unmap.
The active Cloud commit `b4a9acc449` already implements this consumer and must
be deployed together with the qemu FTCTL package when validating this change.

## Validation

New selftests cover:

- primary listener wait refreshes KRBD paths before accepting the listener gate;
- primary peer attach wait refreshes KRBD paths before declaring channels ready.

Live validation must confirm all of the following in the same run window:

- no new primary QEMU `Could not open /dev/rbd/rbd/...` ENOENT after refresh;
- `xcolo.primary_krbd_runtime_refresh` events appear for listener/peer phases;
- generated primary reaches blockdev materialization;
- if the run still fails, `last_error` points to the next layer rather than the
  generic channel attach failure.
