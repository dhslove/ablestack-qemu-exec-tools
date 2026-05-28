# FT X-COLO Multi Writable Disk Graph Design

## Background

After deferring primary network filter attach, FT registration for `r97-link-01` progressed through:

- primary and secondary generated runtime creation;
- primary/secondary channel attach;
- secondary block graph attach;
- primary block graph attach;
- QMP `object-add` for primary redirectors, `colo-compare`, and `filter-mirror`;
- primary `migrate`.

The remaining failure was:

```text
primary query-migrate: failed
Received invalid message 0x0000 length 0x0000
secondary log: Can't receive COLO message: Input/output error
```

Runtime inspection showed the COLO replication graph was built only for the root disk. The data disk stayed outside the COLO graph on both primary and secondary. That violates the FT goal: secondary must be a clone of the primary at the VM state level, not only a VM with one replicated disk.

## Design Principle

FT x-colo must treat every writable guest disk as part of the protected VM identity.

For cloud-managed cold conversion:

1. Cloud continues to create the standby VM and volumes.
2. qemu FTCTL collects all primary disk targets from libvirt inventory.
3. qemu FTCTL requires `FTCTL_PROFILE_DISK_MAP` to contain every primary disk target.
4. qemu FTCTL rewrites generated primary XML for all disks as read-only shareable runtime sources.
5. qemu FTCTL rewrites generated secondary XML for all disks to the Cloud-created standby destinations.
6. qemu FTCTL creates a distinct COLO block graph for every disk before running primary migration.

## Disk Graph Contract

For each disk target, qemu FTCTL creates unique runtime names:

- primary active overlay: `primary-active-<target>.qcow2`
- secondary hidden overlay: `secondary-hidden-<target>.qcow2`
- secondary active overlay: `secondary-active-<target>.qcow2`
- primary active node: `ftctl-primary-active-<target>`
- secondary hidden node: `ftctl-hidden-<target>`
- secondary active node: `ftctl-active-<target>`
- secondary replication node: `ftctl-childs-<target>`
- COLO quorum node: `ftctl-colo-<target>`
- primary NBD node: `nbd0-<target>`

The first disk remains backward-compatible with the previous state summary keys, but runtime attach and migration readiness must use the full disk plan.

## Handshake Order

The handshake order becomes:

1. Secondary QMP capabilities.
2. Secondary x-colo/return-path capabilities.
3. Secondary NBD server start.
4. For each disk, secondary NBD export add for that disk's COLO quorum top node (`ftctl-colo-<target>`), not the original libvirt base node.
5. Primary QMP capabilities.
6. For each disk:
   - primary NBD client add against the same `ftctl-colo-<target>` export;
   - primary `x-blockdev-change` to attach the NBD child to that disk's COLO quorum.
7. Primary network filter object attach.
8. Primary x-colo/return-path capabilities.
9. Primary checkpoint parameter update.
10. Primary migrate.

Primary `migrate` must not start while any writable disk is outside the COLO graph.

## Validation

Selftest coverage must assert:

- generated primary XML rewrites all mapped disks;
- generated secondary XML rewrites all mapped disks;
- per-disk secondary block graph QMP commands use unique node names;
- per-disk primary block graph and NBD attach commands use unique node names;
- all NBD exports are added before primary migration;
- secondary exports and primary NBD clients use `ftctl-colo-<target>` and never the `libvirt-*` base node for multi-disk COLO.
- device replacement preserves bootability without duplicating `bootindex`: only the boot/root LUN gets `bootindex`, and data disks omit it.

## Failure State Contract

Any per-disk attach failure must leave qemu FTCTL state in an explicit failure state:

- `conversion_stage=runtime_graph_failed`
- `conversion_state=error`
- `protection_state=error`
- `transport_state=failed`

This prevents Cloud from presenting a failed partial graph as `pairing/planned`.
