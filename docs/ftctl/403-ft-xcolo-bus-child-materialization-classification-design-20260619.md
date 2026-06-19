# FT XCOLO Bus Child Materialization Classification Design - 2026-06-19

## Background

The `r97-link-01` FT validation reached the strongest COLO state so far after
the Cloud/FTCTL machine type contract was applied:

- primary and secondary both used `pc-i440fx-9.2`;
- COLO channels were established;
- secondary `migrate-incoming` succeeded;
- primary and secondary migration status entered `colo`;
- the previous `Received invalid message 0x0000` path did not recur.

The run then failed at the post-migrate materialization gate:

```text
xcolo_materialization_failure_layer=pci_missing
xcolo_materialization_first_missing_id=scsi0-0-0-0
xcolo_materialization_first_missing_driver=scsi-hd
xcolo_materialization_first_missing_path=generated:True,argv:True,qtree:True,pci:False
last_error=xcolo_post_migrate_pci_materialization_failed
```

## Root Cause

The materialization pipeline treated every generated device as if it must appear
directly in HMP `info pci`.

That is correct for PCI endpoints, bridges, and controllers, but it is not
correct for bus child devices. `scsi-hd` is a child device under a SCSI
controller such as `virtio-scsi-pci`; it is expected to appear in `info qtree`,
not as a direct PCI endpoint in `info pci`.

Therefore the previous gate produced a false hard failure when:

```text
generated=True, argv=True, qtree=True, pci=False
```

for a non-PCI bus child.

## Design Decision

Materialization validation must classify expected devices before deciding which
runtime evidence is mandatory.

| Device class | Examples | Required evidence |
| --- | --- | --- |
| PCI endpoint/controller/bridge | `virtio-scsi-pci`, `virtio-net-pci`, `pcie-root-port`, `pcie-pci-bridge` | generated, argv, qtree, direct `info pci`, assigned PCI resources |
| Bus child | `scsi-hd`, `scsi-cd`, `ide-cd`, `virtserialport`, `usb-tablet`, `isa-serial` | generated, argv, qtree, and parent controller where applicable |
| Block graph node | COLO quorum/NBD/filter block graph nodes | QMP block graph evidence, not direct PCI evidence |
| COLO transport object | chardev, net filter, compare object | QMP chardev/socket/QOM evidence, not direct PCI evidence |

For `scsi-hd`, the hard gate is the existence and materialization of its parent
SCSI controller. The disk child itself must not be required to appear in
`info pci`.

## Updated Runtime Contract

1. Keep the hard PCI/mtree gate from design 401 for real PCI endpoints and
   bridges.
2. Demote `pci=False` to `pci:not_applicable` for bus child devices when both
   sides have the device in `qtree`.
3. For bus child devices with explicit parents, require the parent controller
   in `qtree`; for SCSI disks this means an owning `scsi*` controller such as
   `virtio-scsi-pci`.
4. Fail with `qtree_parent_missing` when a bus child exists but its parent
   controller is absent.
5. Preserve `pci_missing`, `pci_unassigned`, and `mtree_unmapped` as hard
   failures for PCI devices.

## Implementation Plan

- Extend `ftctl_xcolo_analyze_materialization_pipeline()` with device class
  detection.
- Record `device_class`, parent evidence, and adjusted checks in
  `materialization-pipeline-<phase>.json`.
- Add `qtree_parent_missing` as a hard materialization failure.
- Add a selftest where `scsi-hd` is present in generated manifest, argv, and
  qtree, while only its `virtio-scsi-pci` parent appears in `info pci`; this
  must pass.
- Keep existing selftests proving that missing argv and unassigned PCI bridge
  still fail.

## Retest Expectation

The next retest should not fail solely because `scsi0-0-0-0` has no direct
`info pci` row. If it fails, the next evidence must identify either:

- a real PCI endpoint/controller mismatch;
- a missing SCSI parent controller;
- a block graph or COLO transport failure after materialization classification
  passes.

This is progress, not a reset to the older COLO socket issue, unless the
previous QEMU log pair returns:

```text
Primary QEMU: Received invalid message 0x0000 length 0x0000
Secondary QEMU: Can't receive COLO message: Input/output error
```
