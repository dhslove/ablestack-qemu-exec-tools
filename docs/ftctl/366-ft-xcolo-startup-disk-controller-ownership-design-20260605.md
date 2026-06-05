# 366. FT X-COLO Startup Disk Controller Ownership Design

Date: 2026-06-05

## Trigger

Run 88 passed the previous native RBD backend and BlockBackend/node-name
validation, then failed while QEMU started the generated X-COLO XML:

```text
Bus 'scsi0.0' not found
```

The generated XML still contained the libvirt SCSI controller alias `scsi0`,
but the FT-controlled guest disks were appended through `qemu:commandline` as:

```text
-device scsi-hd,bus=scsi0.0,...,drive=ftctl-colo-sda-bb
```

This mixed ownership model is fragile: libvirt owns the controller topology,
while FTCTL owns the guest-visible disk devices and their COLO block graph.

## Design Principle

FT-controlled guest-visible disks must not depend on a libvirt-owned SCSI bus
after FTCTL removes the corresponding libvirt `<disk>` elements.

For the X-COLO cold conversion startup graph:

- libvirt may keep its original controllers for non-FT devices;
- FTCTL-owned COLO disks must use an FTCTL-owned controller created in the same
  `qemu:commandline` graph;
- all FTCTL-owned protected disk devices must attach to that controller;
- runtime `device_del` / `device_add` for protected disks remains forbidden.

## Startup Graph Contract

FTCTL now prepends the disk graph with:

```text
-device virtio-scsi-pci,id=ftctl-xcolo-scsi0
```

Protected disk devices then attach to:

```text
bus=ftctl-xcolo-scsi0.0
```

The block graph naming contract from document 365 still applies:

- Block node names are used by QMP graph operations.
- BlockBackend ids end in `-bb`.
- Guest disk devices use `drive=<BlockBackend id>`.
- Native RBD startup backends remain `file=rbd:<pool>/<image>`.

## Fail-Fast Validation

The startup argument validator must reject:

- identical `id=` and `node-name=` on any `-drive`;
- protected disk devices whose `drive=` does not reference a `-bb` backend;
- protected disk devices attached to a libvirt-owned `scsiN.0` bus;
- protected disk devices when the FTCTL-owned SCSI controller is missing;
- any leaked `/dev/rbd/` path in qemu commandline args.

The new classifier for this failure family is:

```text
xcolo_startup_disk_controller_mismatch
```

## Expected Retest Boundary

The next run must not repeat:

```text
Bus 'scsi0.0' not found
```

If it fails, the failure should move past generated primary/secondary startup
into channel attach, QMP block graph, migrate, or post-migrate protocol
validation.
