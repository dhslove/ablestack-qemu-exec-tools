# V2K Linux bootstrap multi-disk LVM and driver capability design

## Background

The V2K Linux cutover path runs a bootstrap step against the migrated Linux
root disk before the Cloud/libvirt VM is registered. The step connects the
migrated disk through NBD, mounts the guest root filesystem, and rebuilds the
guest initramfs so the converted VM can boot on the target hypervisor.

Recent field tests exposed two separate but related failure classes in this
step.

First, a Rocky Linux 9.4 guest had multiple kernel versions under
`/lib/modules`. V2K selected the kernel version by lexicographically sorting
the directory names and taking the last value. That selected
`5.14.0-427.el9.x86_64` even though the actual booted/default kernel was
`5.14.0-427.13.1.el9_4.x86_64`. As a result, V2K rebuilt the wrong
initramfs. The follow-up verification logged all VirtIO drivers as missing,
which made the issue look like a missing-driver problem even though the
required kernel modules existed for the actual boot kernel.

Second, a CentOS 7 guest had two migrated disks and the guest `centos` VG was
spread across more than one PV. The old bootstrap code connected only disk0 as
one NBD device. LVM then reported the root VG as partial because another PV,
last seen as `/dev/sdb`, was missing. V2K could not mount the root LV and
failed with `root_partition_not_found` before reaching the initramfs rebuild.
The original VM layout showed `/boot` on `/dev/sda1`, the first LVM PV on
`/dev/sda2`, and the second disk `/dev/sdb` used directly as another PV without
a partition table. The `centos-root` LV was extended across both PVs and mounted
as `/`.

These cases show that Linux bootstrap needs to reason about the complete guest
disk set, the actual boot kernel, and the storage driver capability separately.

## Goals

- Connect all migrated Linux guest disks required for root discovery, not only
  disk0.
- Keep LVM scanning isolated to the current migration NBD devices and avoid
  host VG/LV collisions.
- Detect and report partial or missing-PV guest VGs explicitly.
- Select the kernel that the guest is expected to boot, instead of relying on
  plain string sorting of `/lib/modules`.
- Rebuild initramfs only for valid guest kernel candidates and always include
  the actual selected/default kernel.
- Add only storage drivers that exist as guest kernel modules or built-ins to
  dracut configuration.
- Distinguish kernel module availability, initramfs inclusion, and controller
  capability in logs.
- Choose a target disk controller policy from observed capability:
  VirtIO when possible, SATA when VirtIO is not viable, and IDE only as rescue
  guidance or explicit future rescue mode.

## Non-goals

- Install or update guest kernel packages automatically.
- Download RPMs, mount OS ISOs, or mutate guest package repositories.
- Rename guest VGs or rewrite guest LVM metadata.
- Make IDE the default operating controller.
- Change Windows WinPE driver injection behavior.
- Depend on `virt-customize` for the primary implementation path. It can remain
  a future optional fallback, but this design keeps the existing NBD/chroot
  model.

## Failure modes to address

### Wrong kernel initramfs rebuilt

Observed symptom:

```text
cmd_dracut: dracut --kver 5.14.0-427.el9.x86_64
initramfs_virtio_modules: present=[], missing=[virtio_pci, virtio_scsi, virtio_blk, scsi_mod]
```

Manual rescue boot later showed the actual kernel was:

```text
5.14.0-427.13.1.el9_4.x86_64
```

The old selection algorithm was not version-aware and did not consult boot
loader state.

### Multi-disk root VG partial

Observed symptom:

```text
WARNING: VG centos is missing PV ... (last written to /dev/sdb)
/dev/nbd8p2 ... centos
[unknown] ... centos
root centos -wi-----p- /dev/centos/root
root_partition_not_found
```

This indicates that disk0 contained one PV of the root VG, while another
required PV was on a different migrated disk that was not connected during
bootstrap. In the observed VM, the missing PV was not `/dev/sdb1`; it was the
whole `/dev/sdb` disk. The design therefore must support both partition PVs
such as `/dev/sda2` and whole-disk PVs such as `/dev/sdb`.

### Driver inventory and dracut module confusion

`virtio_pci`, `virtio_blk`, and `virtio_scsi` are kernel driver modules, not
dracut modules. They must not be written to `add_dracutmodules`.

Correct dracut knobs:

```text
add_drivers+=" <kernel drivers> "
force_drivers+=" <kernel drivers> "
```

Wrong knob for kernel drivers:

```text
add_dracutmodules+=" virtio_pci virtio_blk virtio_scsi "
```

V2K should also avoid blindly forcing drivers that are absent from the selected
guest kernel. Missing drivers should be logged and excluded from the generated
dracut config.

### Built-in kernel drivers misreported as missing

Some guests expose important storage drivers as built-ins instead of loadable
`.ko` files. For example, a Rocky Linux 9.4 guest showed:

```text
modinfo virtio_pci
filename: (builtin)
```

In that state, `find /lib/modules/<kver> -name virtio_pci.ko*` does not return
anything and `lsinitrd` does not need to show a `virtio_pci.ko` file. The driver
is still usable because it is already compiled into the kernel.

The old V2K verification path only inspected `lsinitrd` output:

```bash
lsinitrd /boot/initramfs-${kver}.img | grep -E 'virtio_(pci|blk|scsi)|scsi_mod'
```

This can misreport a built-in transport driver as missing. If all checked names
are built-in or represented differently in the initramfs output, the bootstrap
can also fail with `initramfs_verify_failed` even though the guest kernel is
capable of using the controller.

The improved design must treat built-in drivers as present for capability
decisions and as `not_required` for initramfs copy verification.

### VirtIO PCI transport not exposed as `virtio_pci`

Another Rocky Linux 8.10 guest migrated and booted successfully with
VirtIO-SCSI even though:

```text
find /lib/modules/$KVER -type f -name "virtio*.ko*"
modinfo virtio_pci
modinfo: ERROR: Module virtio_pci not found.
```

The guest still had `virtio_scsi.ko.xz`, `virtio_blk.ko.xz`,
`virtio_console.ko.xz`, and `virtio_net.ko.xz`, and the post-migration VM was
able to use the VirtIO-SCSI controller. This means `modinfo virtio_pci` failure
alone must not be treated as proof that VirtIO transport is unavailable.

For older RHEL/Rocky kernels, VirtIO PCI transport can be represented by kernel
configuration, built-in code, aliases, or split implementation details rather
than a loadable `virtio_pci.ko` module. The capability model therefore needs a
separate `virtio_pci_transport` concept instead of relying only on a driver
named `virtio_pci`.

## Design

### Bootstrap disk attachment

Linux bootstrap receives the full migrated disk map from the manifest. It
connects each disk to an available NBD device:

```text
disk0 -> /dev/nbd8
disk1 -> /dev/nbd9
disk2 -> /dev/nbd10
...
```

The root disk remains first in the attachment order, but root discovery is no
longer limited to that disk. The attachment result is recorded:

```json
{
  "event": "bootstrap_nbd_map",
  "detail": {
    "disks": [
      {"disk_id": "scsi0:0", "target": "/mnt/glue-gfs/vm-disk0.qcow2", "nbd": "/dev/nbd8"},
      {"disk_id": "scsi0:1", "target": "/mnt/glue-gfs/vm-disk1.qcow2", "nbd": "/dev/nbd9"}
    ]
  }
}
```

Cleanup disconnects every NBD device that was connected by this bootstrap run.
Failure during later attachment must trigger cleanup of already connected
devices.

### LVM isolation for multiple NBD devices

The existing single-NBD LVM isolation is generalized to an NBD set. Each NBD
base device and each partition under that device must be allowed. This is
required because Linux guests can extend a root VG with either a partition PV
(`/dev/sda2`) or a whole-disk PV (`/dev/sdb`).

Generated LVM config:

```text
devices {
  use_devicesfile=0
  global_filter=[
    "a|^/dev/nbd8$|", "a|^/dev/nbd8p[0-9]+$|",
    "a|^/dev/nbd9$|", "a|^/dev/nbd9p[0-9]+$|",
    "r|.*|"
  ]
  filter=[
    "a|^/dev/nbd8$|", "a|^/dev/nbd8p[0-9]+$|",
    "a|^/dev/nbd9$|", "a|^/dev/nbd9p[0-9]+$|",
    "r|.*|"
  ]
}
```

The private `LVM_SYSTEM_DIR` approach remains mandatory. Its `lvm.conf` uses
the same NBD set allow-list and disables `use_devicesfile`.

### Root filesystem discovery

Root discovery tries direct partitions and LVM candidates after all NBD devices
are connected and partition probes have settled.

Direct partition path:

- Enumerate partitions under every connected NBD.
- Try read-only mount.
- Accept only if guest identity markers exist, for example `/etc/os-release`,
  `/etc/redhat-release`, `/etc/fstab`, `/boot`, and `/lib/modules`.
- Validate the mounted source belongs to one of the current NBD trees.

LVM path:

- Run `pvscan --cache --activate ay` with the multi-NBD LVM config.
- Include both whole NBD devices and their partitions in PV discovery. A valid
  PV can appear as `/dev/nbd9` as well as `/dev/nbd8p2`.
- Enumerate `pvs`, `vgs`, and `lvs` with explicit columns.
- Detect partial VGs or missing PV warnings.
- Enumerate LV candidates with:

```bash
lvm lvs --separator '|' -o vg_name,lv_name,lv_path,lv_attr,devices
```

- Reject partial root LV candidates unless all required PVs are present in the
  current NBD set.
- Validate the selected LV block device belongs to the current NBD set by
  `MAJ:MIN` ownership, not by name alone.
- Revalidate the mounted source with `findmnt`.

New events:

```text
root_direct_partition_candidate
root_lvm_candidate
root_vg_missing_pvs
root_lv_partial
root_lv_not_on_target_nbd
mounted_source_not_on_target_nbd
root_mounted
```

The Bigdata Smartmap type of failure should become:

```text
root_vg_missing_pvs: VG centos requires whole-disk PV last seen on /dev/sdb
```

instead of the ambiguous:

```text
root_partition_not_found
```

### Kernel candidate resolution

Kernel selection is moved into a dedicated resolver. It returns:

- selected kernel version
- selection source
- candidate list
- rejected candidates with reasons

Selection priority:

1. `chroot <root> grubby --default-kernel`, mapped from `/boot/vmlinuz-<kver>`
   to `<kver>`.
2. BLS entries under `/boot/loader/entries` combined with saved/default boot
   state from `grubenv` when available.
3. Default or first Linux menuentry in `/boot/grub2/grub.cfg` or
   `/boot/efi/EFI/*/grub.cfg`.
4. Kernels for which both `/boot/vmlinuz-<kver>` and `/lib/modules/<kver>`
   exist.
5. Final fallback: version-sort valid module directories with `sort -V` and
   select the last one.

Plain `sort | tail -n1` must not be used for kernel version ordering.

New events:

```text
kernel_candidates_detected
kernel_selected
kernel_selection_fallback
kernel_candidate_rejected
```

Example:

```json
{
  "event": "kernel_selected",
  "detail": {
    "selected": "5.14.0-427.13.1.el9_4.x86_64",
    "source": "grubby_default_kernel",
    "candidates": [
      "5.14.0-427.13.1.el9_4.x86_64",
      "5.14.0-427.el9.x86_64"
    ]
  }
}
```

### Driver inventory

V2K builds a storage driver inventory for the selected kernel before writing
dracut config.

Driver groups:

```text
VirtIO transport:
  virtio, virtio_ring, virtio_pci

VirtIO storage:
  virtio_blk, virtio_scsi

VirtIO services:
  virtio_console, virtio_net

SATA/SCSI:
  ahci, libata, scsi_mod, sd_mod

IDE rescue:
  ata_piix, ata_generic, pata_acpi, pata_legacy
```

For each candidate, detect one of:

```text
module_file
builtin
missing
```

Detection sources:

- `/lib/modules/<kver>/**/*.ko`
- `/lib/modules/<kver>/**/*.ko.xz`
- `/lib/modules/<kver>/**/*.ko.zst`
- `/boot/config-<kver>`
- `/lib/modules/<kver>/modules.builtin`
- `/lib/modules/<kver>/modules.builtin.modinfo`
- `/lib/modules/<kver>/modules.alias`
- `chroot <root> modinfo <driver>` with `filename: (builtin)` as a fallback

Only drivers that are `module_file` are written to dracut config. Drivers that
are `builtin` must be treated as present for capability decisions, but they do
not need to be copied into initramfs and should not be required to appear in
`lsinitrd` output. Missing drivers are logged and excluded from the generated
dracut config.

Recommended helper:

```text
v2k_linux_bootstrap_driver_state <rootmnt> <kver> <driver>
```

The helper returns one of:

```text
module_file
builtin
missing
```

`builtin` detection should be attempted through both static files and guest
tools:

```text
/boot/config-<kver>
modules.builtin
modules.builtin.modinfo
modules.alias
modinfo <driver> -> filename: (builtin)
```

The evidence sources are not equal. Kernel config and built-in metadata are
stronger than `modinfo` for transport detection because some RHEL/Rocky kernels
can have `CONFIG_VIRTIO_PCI=y` while `modinfo virtio_pci` still reports
`Module virtio_pci not found`.

The inventory must also expose a higher-level transport capability:

```text
virtio_pci_transport
```

`virtio_pci_transport` is considered available when any of the following is
true:

1. `/boot/config-<kver>` contains `CONFIG_VIRTIO_PCI=y`. This is a definitive
   built-in transport signal.
2. `modules.builtin` or `modules.builtin.modinfo` contains `virtio_pci.ko`,
   `virtio_pci_modern_dev.ko`, or related VirtIO PCI entries. This is also a
   definitive built-in transport signal.
3. `/boot/config-<kver>` contains `CONFIG_VIRTIO_PCI=m` and a loadable
   `virtio_pci` module exists.
4. `modules.alias` contains VirtIO PCI transport aliases. This is supporting
   evidence and should not be required when config or built-in metadata already
   proves support.
5. `modinfo virtio_pci` reports a module file or `filename: (builtin)`. This is
   a useful fallback, but failure is not fatal when earlier evidence proves
   transport support.

This keeps Rocky 8 style kernels from being incorrectly rejected only because
`modinfo virtio_pci` cannot find a module by that exact name.

If `/boot/config-<kver>` reports `CONFIG_VIRTIO_PCI=y`, then
`virtio_pci_transport` must be `available_builtin` even when:

```text
modinfo virtio_pci -> Module virtio_pci not found
modules.alias has no matching virtio-pci line
```

If `/boot/config-<kver>` reports `CONFIG_VIRTIO_PCI=m`, then V2K must verify a
loadable module or equivalent alias before marking transport as available.
If the config file is missing, V2K falls back to built-in metadata, module
files, aliases, and `modinfo` in that order.

New event:

```text
kernel_storage_driver_inventory
virtio_transport_capability
```

Example:

```json
{
  "kver": "5.14.0-427.13.1.el9_4.x86_64",
  "drivers": {
    "virtio_pci": "builtin",
    "virtio_scsi": "module_file",
    "ahci": "module_file",
    "ata_piix": "module_file"
  },
  "capabilities": {
    "virtio_pci_transport": "available_builtin",
    "virtio_pci_transport_source": "boot_config"
  }
}
```

### Controller capability decision

Driver inventory is converted into storage and service capability.

VirtIO storage is viable when:

```text
virtio_pci_transport is available
and either virtio_scsi or virtio_blk is module_file or builtin
```

QGA over virtio-serial is viable when:

```text
virtio_pci_transport is available
and virtio_console is module_file or builtin
```

SATA is viable when:

```text
ahci and libata exist
and scsi_mod or sd_mod exists
```

IDE rescue is viable when:

```text
ata_piix or ata_generic or pata_* exists
and libata exists
```

New event:

```text
storage_controller_capability
```

Example:

```json
{
  "virtio": false,
  "qga": false,
  "sata": true,
  "ide_rescue": true,
  "recommended_controller": "sata",
  "reason": "virtio_transport_unavailable"
}
```

### Dracut configuration

The dracut config is generated from available drivers only.

Template:

```text
hostonly="no"
add_drivers+=" <available storage drivers> "
force_drivers+=" <available storage drivers> "
```

`add_dracutmodules` is not used for kernel driver names.

The selected driver list should include available drivers from all viable or
rescue-relevant groups, but only when they are loadable module files. Built-in
drivers are intentionally omitted from `add_drivers` and `force_drivers`.

For example, if `virtio_pci` is built into the kernel and SATA/IDE drivers are
loadable modules:

```text
hostonly="no"
add_drivers+=" ahci libata scsi_mod sd_mod ata_piix "
force_drivers+=" ahci libata scsi_mod sd_mod ata_piix "
```

The corresponding inventory still reports `virtio_pci` as usable:

```text
virtio_pci: builtin, initramfs copy not required
```

If `virtio_pci` cannot be queried by `modinfo` but
`virtio_pci_transport` is available from kernel config, built-in metadata, or
aliases, VirtIO remains a valid controller candidate. If transport is truly
unavailable but SATA/IDE drivers exist:

```text
hostonly="no"
add_drivers+=" ahci libata scsi_mod sd_mod ata_piix "
force_drivers+=" ahci libata scsi_mod sd_mod ata_piix "
```

New event:

```text
dracut_driver_config_written
```

### Initramfs rebuild and verification

V2K rebuilds the selected/default kernel initramfs first:

```bash
dracut -f -v --kver "${selected_kver}" "/boot/initramfs-${selected_kver}.img"
```

Optional best-effort behavior may rebuild additional valid kernels, but
failure of a non-default kernel should not fail the whole bootstrap unless it
is the only bootable kernel.

Verification is split into separate reports:

```text
kernel_module_inventory
initramfs_driver_inventory
storage_controller_capability
initramfs_storage_driver_summary
```

The initramfs verification state for each driver is:

```text
present
not_required_builtin
missing_from_initramfs
```

`not_required_builtin` is used when the kernel inventory state is `builtin`.
Such a driver must not cause `initramfs_verify_failed` simply because no `.ko`
file appears in `lsinitrd`.

`missing: all` is allowed only when a driver is absent from:

- guest kernel module files
- guest built-in module lists
- `modinfo <driver>` built-in fallback
- rebuilt initramfs

The old interpretation of `present=[]` as "drivers do not exist" is removed.

Example report for a kernel with built-in `virtio_pci`:

```json
{
  "kver": "5.14.0-427.13.1.el9_4.x86_64",
  "drivers": {
    "virtio_pci": {
      "kernel": "builtin",
      "initramfs": "not_required_builtin"
    },
    "virtio_scsi": {
      "kernel": "module_file",
      "initramfs": "present"
    },
    "virtio_blk": {
      "kernel": "module_file",
      "initramfs": "present"
    }
  }
}
```

### Cutover policy integration

Linux bootstrap produces a result object:

```json
{
  "bootstrap": "success",
  "selected_kernel": "5.14.0-427.13.1.el9_4.x86_64",
  "recommended_controller": "sata",
  "virtio": false,
  "sata": true,
  "ide_rescue": true,
  "qga": false
}
```

Cutover uses this result as follows:

- If VirtIO is viable and initramfs includes or has built-in VirtIO storage,
  use VirtIO-SCSI or the existing preferred VirtIO policy.
- If VirtIO is not viable but SATA is viable, register the VM with SATA.
- If bootstrap fails before capability can be determined and SATA fallback is
  allowed by policy, register with SATA and log the bootstrap failure.
- If only IDE rescue is viable, do not silently choose IDE as normal operation.
  Emit a clear event and user-facing guidance. IDE can later become an explicit
  rescue option.
- If no viable storage controller exists, fail cutover and instruct the
  operator to boot through IDE/SATA if possible and reinstall or restore the
  matching kernel module packages manually.

New events:

```text
linux_bootstrap_result
cutover_controller_policy_resolved
cutover_ide_rescue_required
```

## Manual validation workflow

Before relying on the automated change, a failing guest can be validated
manually:

1. Boot the converted VM with IDE if VirtIO/SATA boot fails.
2. Check the actual boot kernel:

```bash
uname -r
```

3. Inventory storage drivers for that kernel:

```bash
KVER="$(uname -r)"
grep -E 'CONFIG_VIRTIO|CONFIG_VIRTIO_PCI|CONFIG_VIRTIO_BLK|CONFIG_SCSI_VIRTIO' \
  /boot/config-$KVER 2>/dev/null || true
find /lib/modules/$KVER -type f \( \
  -name "virtio*.ko*" -o \
  -name "ahci.ko*" -o \
  -name "ata_piix.ko*" -o \
  -name "libata.ko*" -o \
  -name "scsi_mod.ko*" -o \
  -name "sd_mod.ko*" \
\) | sort
grep -E "virtio|ahci|ata_piix|libata|scsi_mod|sd_mod" \
  /lib/modules/$KVER/modules.builtin 2>/dev/null || true
grep -E "virtio.*pci|virtio_pci|virtio-pci" \
  /lib/modules/$KVER/modules.alias 2>/dev/null || true
modinfo virtio_pci 2>/dev/null | sed -n '1,8p'
```

4. On a successfully booted target VM, confirm the runtime driver binding:

```bash
lspci -nnk | egrep -A4 -i 'virtio|scsi|storage|ethernet'
lsmod | egrep 'virtio|scsi|sd_mod' || true
```

`virtio_pci` may be absent from `lsmod` when it is built into the kernel. The
runtime `Kernel driver in use` output is the stronger evidence after boot.

5. If needed, rebuild initramfs with only available drivers:

```bash
cat >/etc/dracut.conf.d/v2k-storage.conf <<'EOF'
hostonly="no"
add_drivers+=" ahci ata_piix libata scsi_mod sd_mod "
force_drivers+=" ahci ata_piix libata scsi_mod sd_mod "
EOF
dracut -f -v --kver "$KVER" "/boot/initramfs-$KVER.img"
```

6. Test SATA first when VirtIO transport is uncertain. Test VirtIO when
   `virtio_pci_transport` is available and `virtio_scsi` or `virtio_blk` are
   available as modules or built-ins.

## Test plan

### Smoke tests

- Kernel selection chooses `5.14.0-427.13.1.el9_4.x86_64` over
  `5.14.0-427.el9.x86_64` when it is the bootloader default.
- Kernel fallback uses `sort -V`, not plain `sort`.
- Driver inventory marks absent `virtio_pci` as missing and does not include it
  in generated dracut config.
- Driver inventory marks `virtio_pci` as `builtin` when `modinfo virtio_pci`
  reports `filename: (builtin)`, even when no `virtio_pci.ko*` file exists.
- VirtIO transport capability is available when `/boot/config-<kver>` reports
  `CONFIG_VIRTIO_PCI=y`, even if `modinfo virtio_pci` fails and
  `modules.alias` has no matching line.
- VirtIO transport capability from `CONFIG_VIRTIO_PCI=y` is reported as
  `available_builtin` with source `boot_config`.
- VirtIO transport capability from `modules.builtin` entries such as
  `kernel/drivers/virtio/virtio_pci.ko` or
  `kernel/drivers/virtio/virtio_pci_modern_dev.ko` is reported as
  `available_builtin`.
- If `/boot/config-<kver>` reports `CONFIG_VIRTIO_PCI=m`, capability requires a
  loadable module or equivalent alias and must not be inferred from config
  alone.
- VirtIO transport capability can be inferred from `modules.alias` or built-in
  metadata and must not depend solely on a loadable `virtio_pci.ko*` file.
- Built-in drivers are considered present for controller capability but are not
  required to appear in `lsinitrd`.
- Driver inventory recommends SATA when `virtio_pci` is missing but `ahci`,
  `libata`, `scsi_mod`, and `sd_mod` exist.
- Generated dracut config uses `add_drivers` and `force_drivers`, never
  `add_dracutmodules` for kernel driver names.
- Generated dracut config excludes built-in drivers from `add_drivers` and
  `force_drivers`.
- Multi-disk LVM root VG test connects disk0 and disk1, builds a multi-NBD LVM
  allow-list, and accepts a root LV only when all PVs are present.
- Whole-disk PV test models `/boot` on `disk0p1`, the first root VG PV on
  `disk0p2`, and an extended root VG PV directly on `disk1` with no partition
  suffix. The LVM allow-list must include both `/dev/nbd9` and `/dev/nbd9p*`,
  and root ownership checks must accept the LV only when the whole-disk PV is
  part of the current NBD set.
- Partial VG test emits `root_vg_missing_pvs` instead of generic
  `root_partition_not_found`.

### Regression tests

- Same-name host and guest VG/LV paths remain protected by NBD ownership
  checks.
- `use_devicesfile=1` on the conversion host does not hide guest NBD PVs.
- Single-disk LVM guests continue to bootstrap.
- Direct-partition Linux guests continue to bootstrap.
- Bootstrap cleanup disconnects all NBD devices attached by the run.

## Implementation notes

Recommended helper boundaries:

```text
v2k_linux_bootstrap_connect_disk_set
v2k_linux_bootstrap_disconnect_disk_set
v2k_linux_bootstrap_lvm_cfg_for_nbd_set
v2k_linux_bootstrap_setup_lvm_system_dir_for_nbd_set
v2k_linux_bootstrap_resolve_default_kernel
v2k_linux_bootstrap_collect_driver_inventory
v2k_linux_bootstrap_resolve_controller_capability
v2k_linux_bootstrap_write_dracut_driver_config
v2k_linux_bootstrap_verify_initramfs_drivers
```

The code should preserve the existing conservative safety rule: never mount or
write to an LV unless ownership under the current NBD set is proven.

## Expected outcome

For the Rocky 9.4 case, logs should show that V2K selected the actual default
kernel and rebuilt the matching initramfs:

```text
kernel_selected: 5.14.0-427.13.1.el9_4.x86_64
cmd_dracut: dracut --kver 5.14.0-427.13.1.el9_4.x86_64
storage_controller_capability: recommended_controller=sata or virtio
```

For the CentOS multi-disk LVM case, logs should show both migrated disks
attached and the `centos` VG scanned with all required PVs present, including
whole-disk PVs. If a PV is still missing, the failure should explicitly name
the missing-PV condition and whether the missing source was last seen as a
whole disk or a partition.

Together, these changes make Linux cutover failures diagnosable and allow V2K
to choose the safest viable controller instead of assuming that VirtIO is always
available.
