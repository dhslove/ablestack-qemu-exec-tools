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

## Commandline Controller Reproduction

Run 94 proved that leaving the libvirt `<controller type="scsi">` in generated
XML and adding protected `scsi-hd` devices through `qemu:commandline` is not
reliable. QEMU failed secondary startup with:

```text
Bus 'scsi0.0' not found
```

The generated XML contained the libvirt SCSI controller alias, but raw
`qemu:commandline` devices could not attach to that libvirt-created bus.

The corrected model is still immutable topology, but the controller ownership
within the generated transient XML must be consistent:

- read the original libvirt SCSI controller alias and PCI address;
- remove the libvirt SCSI controller from generated XML after protected disks
  are removed, provided no remaining SCSI disk uses it;
- add an equivalent commandline controller before protected disk devices, for
  example:

```text
-device virtio-scsi-pci,id=scsi0,bus=pcie.0,addr=0x9,num_queues=2
-device scsi-hd,bus=scsi0.0,channel=0,scsi-id=0,lun=0,...
```

This is not an FTCTL-owned new topology. It is the original Cloud/libvirt
controller reproduced at the same guest-visible PCI location so that QEMU raw
commandline disk devices can attach to it deterministically.

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

## Libvirt QEMU Log Property Parity

Run 95 proved that reproducing the original SCSI controller name and PCI
address is still not sufficient. The generated domains reached migration, but
the secondary QEMU crashed while loading migration state:

```text
qemu-kvm: ../system/memory.c:2666: memory_region_add_subregion_common:
Assertion '!subregion->container' failed.
```

The primary host's `/var/log/libvirt/qemu/<domain>.log` contains the exact QEMU
argv that libvirt used for the normal Cloud-managed VM. This log must be used as
the guest-visible device property reference before FTCTL replaces only the block
backend graph.

For `r97-link-01`, the normal libvirt argv contained protected disk devices such
as:

```text
-device '{"driver":"virtio-scsi-pci","id":"scsi0","num_queues":2,
          "bus":"pcie.0","addr":"0x9"}'
-device '{"driver":"scsi-hd","bus":"scsi0.0","channel":0,"scsi-id":0,
          "lun":0,"device_id":"...","drive":"libvirt-3-storage",
          "id":"scsi0-0-0-0","bootindex":3,
          "write-cache":"on","serial":"..."}'
```

The FT generated argv previously emitted the same ids and bus but omitted
migration-visible properties such as `write-cache=on` and used the rewritten XML
boot order instead of the normal libvirt bootindex. The corrected rule is:

- parse the latest normal, non-FT libvirt QEMU argv block from
  `/var/log/libvirt/qemu/<domain>.log`;
- use it as the preferred source for protected disk `serial`, `device_id`,
  `bootindex`, `write-cache`, and `share-rw`;
- fall back to XML-derived values only when the log reference is unavailable;
- validate the generated commandline before `virsh create` and fail fast if
  required guest-visible disk properties are missing.

The log reference is not copied wholesale. Runtime-only values such as file
descriptors, monitor sockets, VNC display, secret paths, and libvirt block node
names remain generated by libvirt/FTCTL for the current run. Only
migration-visible guest device properties are used for parity.

## Primary Canonical Runtime Shape

Run 96 proved that disk property parity alone is not enough. The generated FT
argv fixed the Run 95 disk gaps (`bootindex=3`, `write-cache=on`), but the
secondary still crashed while receiving migration state:

```text
qemu-kvm: ../system/memory.c:2666: memory_region_add_subregion_common:
Assertion `!subregion->container' failed.
```

This means the remaining problem is the full migration ABI, not an individual
disk option. COLO uses the same device-state loading constraints as live
migration. The secondary must therefore be a primary-shaped migration target,
not an independently shaped Cloud standby VM with later corrections.

The corrected runtime model is:

- Cloud still creates and owns the standby VM and volume lifecycle.
- FTCTL still uses the standby VM name and standby volumes for management and
  block targets.
- The FT transient secondary XML must be cloned from the primary normal XML,
  then renamed to the standby domain name.
- Guest-visible identity and topology are preserved from the primary:
  - UUID;
  - MAC address;
  - PCI/controller layout;
  - SCSI controller and disk qdev identity;
  - CPU, memory, machine, and native iothread declarations.
- Role-specific runtime overlays are the only allowed differences:
  - primary COLO chardev/filter/compare objects;
  - secondary red0/red1/filter/incoming objects;
  - role-specific block graph backends and source paths.

The standby seed XML is still required as evidence that Cloud provisioned the
managed standby object. It is no longer used as the guest-visible FT runtime
shape source.

## Guest ABI Manifest Gate

Before `virsh create`, FTCTL must compare the generated primary and secondary
guest ABI manifests after the final startup disk graph and qemu commandline
have been applied.

The manifest intentionally includes:

- domain-level migration-visible configuration;
- native device XML order and attributes;
- generated `-device` qemu arguments for guest-visible devices such as
  `virtio-scsi-pci` and `scsi-hd`.

The manifest intentionally excludes role-local runtime data:

- domain name and transient libvirt id;
- `qemu:commandline` chardev/filter/incoming objects;
- block backend `-drive` graph internals;
- monitor, VNC/graphics/listen, socket, pid, and file descriptor paths.

FT generated XML must also normalize host-local graphics endpoints before the
manifest gate:

- Primary and secondary VNC `listen` values must be rewritten to `0.0.0.0`.
- A host-specific Cloud console bind address such as `10.10.32.3` is not COLO
  guest ABI and must not cause `xcolo_guest_abi_manifest_mismatch`.
- The normalization does not apply to guest NIC identity; NIC model, MAC, PCI
  address, and guest-visible network device topology remain strict ABI inputs.

If the primary and secondary manifest hashes differ, FTCTL must fail before
starting migration:

```text
last_error=xcolo_guest_abi_manifest_mismatch
xcolo_protocol_failure_phase=guest_abi_manifest
```

This prevents QEMU from reaching the lower-level assertion first and records
the exact remaining difference for the next correction.

## Validation Contract

Before `virsh create`, FTCTL must validate:

- generated XML rewrite has preserved the protected disk topology fields needed
  to rebuild the commandline disk device:
  - `<target bus="scsi">`
  - `<alias name="scsiX-Y-Z-N">`
  - `<address type="drive" controller="X" bus="Y" target="Z" unit="N">`
- no generated commandline contains `ftctl-xcolo-pci0`;
- no generated commandline contains `ftctl-xcolo-scsi0`;
- generated XML no longer contains the libvirt SCSI controller used only by
  protected disks;
- generated commandline contains the original SCSI controller reproduced as
  `virtio-scsi-pci,id=scsiX,bus=<original-pci-bus>,addr=<original-pci-slot>`;
- every protected disk `scsi-hd` uses an original libvirt SCSI bus such as
  `scsi0.0`;
- every protected disk qdev id follows the original topology such as
  `scsi0-0-0-0`;
- every protected disk `scsi-hd` contains the normal libvirt guest-visible
  properties required for migration compatibility, including `write-cache=on`
  when the normal Cloud argv has it;
- primary and secondary generated disk qdev fingerprints match.
- primary and secondary generated guest ABI manifests match after the final
  startup disk graph has been applied.
- startup gate failures must destroy any secondary transient runtime domain and
  restore the primary from backup without recreating the cloud-managed standby
  runtime, because protection has not yet reached a stable FT state.

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
