# FT XCOLO Primary Parent NBD QEMU User Permission Design

## Context

The KRBD primary parent adapter introduced in document 427 changed the
primary startup graph so QEMU no longer opens `/dev/rbd/...` parent images
directly. FTCTL starts a local read-only `qemu-nbd` unix-socket export and the
generated primary XML uses `driver=nbd` for the parent block node.

The first retest after that change moved past the previous KRBD `ENOENT`
class, but failed before primary listener startup:

```text
qemu-kvm: -blockdev driver=nbd,...server.path=/run/ablestack-vm-ftctl/xcolo-parent-nbd/i-2-197-VM/sda.sock,...:
Could not open image: Permission denied
```

Host smoke testing confirmed the cause:

- root can open the default `qemu-nbd` unix socket.
- the libvirt QEMU runtime user cannot open a root-owned socket with default
  `srwxr-xr-x` permissions.
- after granting socket access to the QEMU runtime user, the same qemu-user
  probe succeeds.

This is not a repeat of the old `/dev/rbd/...` missing-device failure. It is
the next permission boundary exposed by the local NBD adapter design.

## Design Principles

- Keep the KRBD local NBD adapter path. Do not fall back to native librbd.
- Keep the stable KRBD naming principle; do not make `/dev/rbdN` the long-term
  XML contract.
- Validate the resource using the same user model that libvirt QEMU will use,
  not only root.
- Fail before `virsh create` when the generated QEMU process cannot open the
  parent NBD socket.
- Do not modify existing successful RBD-to-RBD COLO runtime state while
  validating `r97-link-02`.

## AS-IS

| Layer | Behavior |
| --- | --- |
| Adapter startup | FTCTL starts `qemu-nbd` as root with a unix socket under `/run/ablestack-vm-ftctl/xcolo-parent-nbd/<vm>/`. |
| Adapter probe | FTCTL probes the socket as root with `qemu-img info`. |
| Runtime user | Generated primary QEMU runs under the libvirt QEMU runtime user. |
| Failure timing | The permission mismatch is detected only inside `virsh create`, causing `xcolo_primary_create_failed_before_listener`. |
| Error clarity | The state only shows a primary-create failure, while the real blocker is socket access. |

## TO-BE

| Layer | Behavior |
| --- | --- |
| QEMU identity | Resolve libvirt QEMU user/group from `/etc/libvirt/qemu.conf`, falling back to `qemu:qemu`. |
| Socket permission | After `qemu-nbd` creates the socket, grant the QEMU runtime user/group traverse and read/write access to the adapter directory and socket. |
| Adapter probe | Keep root probe and add qemu-user probe using `runuser -u <qemu-user> -- qemu-img info ...`. |
| Failure timing | If qemu-user probe fails, stop before `virsh create`. |
| Error clarity | Record `xcolo_primary_parent_nbd_permission_failed` and `xcolo.primary_parent_nbd.qemu_user_probe` evidence. |

## Code Changes

### `lib/ftctl/xcolo.sh`

Add helper functions:

- `ftctl_xcolo_libvirt_qemu_identity`
  - reads libvirt QEMU user/group from `/etc/libvirt/qemu.conf`
  - falls back to `qemu:qemu`
- `ftctl_xcolo_fix_parent_nbd_socket_permissions`
  - applies `chgrp`/`chmod` to the adapter base directory, VM directory, and
    socket
  - applies `setfacl` when available as a user-specific fallback
- `ftctl_xcolo_probe_parent_nbd_as_qemu_user`
  - probes both URI and image-opts NBD forms through `runuser -u <qemu-user>`
  - sets `last_error=xcolo_primary_parent_nbd_permission_failed` on failure

Update `ftctl_xcolo_start_primary_parent_nbd_adapter`:

1. start `qemu-nbd`
2. wait for the socket
3. fix socket permissions
4. root-probe the adapter
5. qemu-user-probe the adapter
6. only then expose the adapter map to generated XML assembly

### `bin/ablestack_vm_ftctl_selftest.sh`

Add a focused unit selftest:

- verifies qemu-user probe command construction
- verifies qemu-user probe failure sets
  `xcolo_primary_parent_nbd_permission_failed`

## Validation Plan

1. Syntax checks:
   - `bash -n lib/ftctl/xcolo.sh`
   - `bash -n bin/ablestack_vm_ftctl_selftest.sh`
2. Targeted selftest:
   - `FTCTL_SELFTEST_CASES=selftest_case_xcolo_primary_parent_nbd_qemu_user_probe bash bin/ablestack_vm_ftctl_selftest.sh`
3. Existing related selftests:
   - startup disk graph KRBD path tests
   - baseline primary NBD seed test
4. Host smoke after deployment:
   - create a temporary root-owned `qemu-nbd` unix socket
   - confirm qemu-user probe fails before permission adjustment
   - confirm qemu-user probe succeeds after the same permission model used by
     FTCTL
5. Retest `r97-link-02`:
   - expected to move past `Permission denied`
   - expected next milestone: `primary.create_generated.listeners=ok`

## Non-Goals

- Do not change the COLO network filter topology.
- Do not change the machine type or PCI manifest logic.
- Do not change the existing successful `r97-link-01` protection state.
- Do not introduce Cloud DB schema or VM-detail persistence for this adapter.
