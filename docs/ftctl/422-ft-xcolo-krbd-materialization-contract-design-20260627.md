# FT XCOLO KRBD materialization contract design

Date: 2026-06-27

## Problem

FT XCOLO with KRBD must keep the long-lived ABLESTACK disk identity as
`/dev/rbd/rbd/<image>`.  The previous generated startup XML removed native
libvirt `<disk>` entries and injected the COLO disk graph only through
`qemu:commandline`.  That avoided duplicate guest disks, but it also meant
libvirt and the qemu hook could no longer infer the protected KRBD devices from
native disk XML.  The retest failed at `xcolo_primary_krbd_qemu_namespace_invisible`.

The important finding is that path visibility alone is not the correct success
criterion.  When QEMU opens the KRBD block device successfully, the process may
hold an fd such as `/dev/rbd2` while the stable symlink path is not visible in
the private `/dev` namespace at the exact gate check.  The correct KRBD proof is
therefore the materialization contract plus the QEMU-opened block fd and, when
available, the QMP block graph.

## Design principle

Do not switch FT XCOLO back to `librbd`.  The KRBD path is the required storage
contract.

Do not keep two guest-visible disk definitions.  Native libvirt `<disk>` and
`qemu:commandline` COLO `-drive/-device` definitions cannot both expose the same
SCSI target to the guest.  The guest-visible disk remains the COLO startup graph
in `qemu:commandline`.

Instead, FTCTL must preserve an explicit KRBD materialization contract before it
removes native disk XML:

- target name, such as `sda`
- role, primary or secondary
- stable path, such as `/dev/rbd/rbd/<image>`
- resolved runtime path, such as `/dev/rbd2`
- block major/minor identity

This contract lets FTCTL and host-side diagnostics distinguish a real KRBD
failure from a harmless stable-symlink namespace mismatch.

## Code-level changes

| Area | As-is | To-be |
|---|---|---|
| Startup graph application | `ftctl_xcolo_apply_startup_disk_graphs()` removes native protected disks and only stores qemu args | Before removal, call `ftctl_xcolo_record_krbd_materialization_contract()` and persist the KRBD contract under `/run/ablestack-vm-ftctl/krbd-contract/<vm>.env` plus state keys |
| KRBD validation | `ftctl_xcolo_verify_primary_krbd_qemu_namespace()` fails when `/proc/<pid>/root/dev/rbd/rbd/<image>` is absent | Validate stable path visibility or matching QEMU fd major/minor. Missing namespace path with an open matching fd is accepted and recorded as `visible=fd` |
| QMP validation | Not considered in this gate | If `query-named-block-nodes` is available and does not show the expected stable path, fail with `xcolo_primary_krbd_qmp_node_missing`; if QMP is temporarily unavailable at listener bootstrap, keep fd evidence and continue |
| Failure code | `xcolo_primary_krbd_qemu_namespace_invisible` | Real missing open device becomes `xcolo_primary_krbd_open_fd_missing`; QMP mismatch becomes `xcolo_primary_krbd_qmp_node_missing` |
| Existing success path | Earlier `r97-link-01` success remains untouched | The new logic is KRBD-specific evidence gating and does not reintroduce `librbd` |

## Expected runtime evidence

A healthy KRBD FT XCOLO listener bootstrap should record at least one of these
per protected disk:

- `xcolo_primary_krbd_qemu_namespace_visible_paths=/dev/rbd/rbd/<image>`
- or `xcolo_primary_krbd_qemu_fd_open_paths=/dev/rbd/rbd/<image>-><fd>->/dev/rbdN`

If the stable namespace path is missing but the fd is open, FTCTL records:

- `xcolo_primary_krbd_qemu_namespace_visible=fd`
- `xcolo_primary_krbd_qemu_fd_open=yes`

That is a valid KRBD materialization state because QEMU has already opened the
kernel block device represented by the stable path.

## Follow-up

The qemu hook should continue to respect `/run/ablestack-vm-ftctl/krbd-guard`.
If hook cleanup behavior later needs richer diagnostics, it can also read the
new `/run/ablestack-vm-ftctl/krbd-contract/<vm>.env` file.  The immediate retest
failure, however, is resolved in the FTCTL listener gate where the false path-only
failure occurred.