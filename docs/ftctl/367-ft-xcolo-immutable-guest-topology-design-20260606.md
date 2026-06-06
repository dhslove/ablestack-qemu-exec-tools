# 367. FT X-COLO Immutable Guest Topology Design

Date: 2026-06-06

## Trigger

Run 92 reached farther than the previous startup commandline failures:

- generated primary and secondary XML contained both COLO network args and disk
  graph args;
- primary and secondary domains started;
- `9003/9004` channels connected;
- primary `migrate` was accepted;
- post-migrate startup-active channel validation initially passed.

The secondary QEMU process then crashed with the same QEMU assertion that was
seen in Run 85:

```text
qemu-kvm: ../system/memory.c:2666: memory_region_add_subregion_common:
Assertion '!subregion->container' failed.
```

Run 85 was caused by runtime guest-visible disk device replacement. The runtime
hotplug path was removed, but Run 92 proves that adding FTCTL-owned
guest-visible PCI/SCSI topology at startup can still break QEMU's incoming
migration device-state load.

## Source-Level Interpretation

In QEMU 9.2.4, `memory_region_add_subregion_common()` asserts that the subregion
being added does not already belong to a container:

```c
assert(!subregion->container);
```

This is a low-level memory topology invariant. It is commonly reached through
PCI BAR or bridge-window remapping paths when device state is loaded or PCI
configuration changes are applied.

For COLO, incoming migration transfers more than RAM. It also transfers
guest-visible device state, including PCI configuration and MMIO mapping state.
Therefore, the secondary must already have a guest-visible topology compatible
with the primary before migration begins.

## Corrected Principle

FTCTL must not add new guest-visible PCI/SCSI topology for protected disks.

The following are forbidden for protected FT startup:

- `ftctl-xcolo-pci0`
- `ftctl-xcolo-scsi0`
- any FTCTL-owned guest-visible PCI/SCSI controller
- any protected disk attached to a different guest-visible controller or bus
  than the original Cloud/libvirt disk

The guest-visible topology must remain the Cloud/libvirt topology:

- same PCI controller layout;
- same SCSI controller;
- same SCSI bus/channel/target/lun;
- same qdev id where QEMU/libvirt would have produced one;
- same serial/device identity when present.

Only the backend block graph is replaced with the COLO graph.

## Implementation Direction

When building generated transient XML:

1. Read the original protected `<disk>` entries before removing them.
2. Extract the original guest-visible SCSI attachment:
   - `target bus`
   - `target dev`
   - `address controller`
   - `address bus`
   - `address target`
   - `address unit`
   - disk serial
   - boot order
3. Remove the protected `<disk>` entries from generated XML to avoid duplicate
   libvirt block backends.
4. Add qemu commandline block graph args.
5. Recreate each protected disk as `scsi-hd` on the original SCSI bus, for
   example:

```text
-device scsi-hd,bus=scsi0.0,channel=0,scsi-id=0,lun=0,
        drive=ftctl-colo-sda-bb,id=scsi0-0-0-0,serial=<original>
```

The COLO block graph node names remain FTCTL-owned. The guest-visible qdev does
not.

## Validation Contract

Before `virsh create`, FTCTL must validate:

- generated XML rewrite has preserved the protected disk topology fields needed
  to rebuild the commandline disk device:
  - `<target bus="scsi">`
  - `<alias name="scsiX-Y-Z-N">`
  - `<address type="drive" controller="X" bus="Y" target="Z" unit="N">`
- no generated commandline contains `ftctl-xcolo-pci0`;
- no generated commandline contains `ftctl-xcolo-scsi0`;
- every protected disk `scsi-hd` uses an original libvirt SCSI bus such as
  `scsi0.0`;
- every protected disk qdev id follows the original topology such as
  `scsi0-0-0-0`;
- primary and secondary generated disk qdev fingerprints match.

Before `primary.migrate`, FTCTL should also collect a QMP topology fingerprint
from both sides and fail before migration if guest-visible PCI/SCSI topology is
not compatible.

## Failure Classification

If QEMU logs:

```text
memory_region_add_subregion_common: Assertion '!subregion->container' failed
```

FTCTL must classify it as:

```text
xcolo_secondary_qemu_assert_memory_region_container
```

The later downstream symptom `primary_not_running` must not hide this first
cause.

## Relationship To Earlier Designs

This design supersedes the controller ownership section of:

- `366-ft-xcolo-startup-disk-controller-ownership-design-20260605.md`

It preserves the valid parts of:

- `363-ft-xcolo-startup-disk-graph-no-hotplug-design-20260605.md`
- `364-ft-xcolo-native-rbd-startup-backend-design-20260605.md`
- `365-ft-xcolo-block-node-backend-naming-design-20260605.md`

The preserved rule is: no runtime protected disk hotplug. The corrected rule is:
no new guest-visible protected disk topology at startup either.

## Run 93 Correction

Run 93 failed earlier than Run 92 with:

```text
xcolo_guest_topology_mismatch
```

The failure was not a QEMU migration crash. The generated XML still contained
ordinary libvirt `<disk>` entries and the `qemu:commandline` contained only the
network COLO arguments. The startup disk graph was not applied because the
earlier block-runtime XML rewrite removed `<alias>` and `<address>` from the
protected disks. FTCTL then could not extract the original qdev identity before
removing the disks and rebuilding them as commandline `scsi-hd` devices.

The corrected implementation must preserve `<alias>` and `<address>` during the
block-runtime rewrite. If either field is missing before startup disk graph
application, FTCTL must fail with:

```text
xcolo_startup_disk_topology_missing
```

This is distinct from `xcolo_guest_topology_mismatch`, which means primary and
secondary topology fingerprints exist but do not match.
