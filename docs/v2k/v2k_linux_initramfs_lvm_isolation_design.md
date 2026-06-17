# V2K Linux initramfs LVM isolation design

## Background

The V2K Linux bootstrap step mounts the migrated root disk and rebuilds the
guest initramfs so that VirtIO storage drivers are available after cutover.
For LVM-based Linux guests, the bootstrap host has to activate the guest VG/LV
temporarily through an NBD mapping.

Two host-side conditions make this risky unless the LVM path is tightly
isolated:

- The conversion host and the guest can both use the same VG/LV names, for
  example `rl/root` exposed as `/dev/mapper/rl-root`.
- RHEL/Rocky 9 systems can enable `devices/use_devicesfile = 1`, which makes
  LVM consult `/etc/lvm/devices/system.devices` before scanning new devices.

If V2K only trusts `/dev/<vg>/<lv>` names, a host `rl-root` can be selected by
mistake. If V2K only uses `filter` without disabling the devices file, the
temporary `/dev/nbdXpN` PV may not be visible to LVM at all.

## Goals

- During Linux bootstrap, LVM commands must only see the current bootstrap NBD
  device and its partitions.
- The host LVM devices file must not hide the temporary NBD PV.
- A selected root LV must be proven to belong to the current NBD mapping before
  it is mounted.
- After mount, the actual mounted source must be revalidated against the same
  NBD mapping.
- Cleanup must remain scoped to the current NBD device and must not sweep
  unrelated host or concurrent migration LVs.

## Non-goals

- Rename guest VGs.
- Modify host `/etc/lvm/lvm.conf` or `/etc/lvm/devices/system.devices`.
- Globally remove `/dev/mapper/rl-*` or other host device-mapper nodes.
- Change Windows WinPE bootstrap behavior.

## Design

### LVM command configuration

V2K uses a single helper to produce an LVM config string for a bootstrap NBD:

```bash
devices {
  use_devicesfile=0
  global_filter=[ "a|^/dev/nbdX$|", "a|^/dev/nbdXp[0-9]+$|", "r|.*|" ]
  filter=[ "a|^/dev/nbdX$|", "a|^/dev/nbdXp[0-9]+$|", "r|.*|" ]
}
```

`use_devicesfile=0` is intentionally included in every bootstrap LVM command.
This keeps V2K independent from the host `system.devices` allow-list without
changing host configuration.

### Temporary LVM system directory

After the bootstrap NBD is connected, V2K creates a private `LVM_SYSTEM_DIR`
with a matching `lvm.conf` and an empty `devices/` directory. This prevents the
bootstrap scan cache from sharing host state. The original `LVM_SYSTEM_DIR` is
restored during cleanup.

### Root LV ownership guard

V2K no longer treats `/dev/<vg>/<lv>` as sufficient proof. Before mounting an
LV candidate, V2K verifies that the candidate block device appears in the
`lsblk` tree of the current NBD device by comparing `MAJ:MIN` values.

The same guard is applied again after mount by checking `findmnt -o SOURCE`.
This protects against same-name host paths such as `/dev/rl/root` and
`/dev/mapper/rl-root`.

### Candidate enumeration

LVM root candidates are enumerated with:

```bash
lvm lvs --separator '|' -o vg_name,lv_name,lv_path,devices
```

The `devices` column is used as an early filter, and the block-tree guard is
the final authority before and after mount.

### Failure policy

If V2K cannot prove that a candidate root LV belongs to the current NBD, the
candidate is skipped. If no safe candidate is found, Linux bootstrap fails
rather than risking a host disk write. Existing cutover fallback behavior can
then handle the bootstrap failure according to the selected policy.

## Validation

The implementation is covered by smoke tests for:

- LVM config generation with `use_devicesfile=0`.
- NBD allow/reject patterns in generated LVM config.
- NBD ownership guard behavior using mocked `lsblk`.
- LVM candidate filtering logic using mocked `lvm`, `mount`, and `findmnt`.

