# FT X-COLO Multi Writable Disk Graph Design

## Superseded Capability Note - 2026-06-05

Any `return-path` capability requirement in this historical design is
superseded by
[362. FT XCOLO QEMU 9.2.4 Return-Path Capability Conflict Design](362-ft-xcolo-qemu-924-return-path-capability-conflict-design-20260605.md).
Current FTCTL behavior must use `x-colo=true` with generic migration
`return-path=false`.

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

Later validation progressed past this multi-disk coverage gap but still timed out in `finish-migrate` / `inmigrate`. That follow-up found that the primary quorum was first created as local-only and then patched with `x-blockdev-change`. The current contract is updated by [307. FT X-COLO Primary Quorum Remote Child Design](307-ft-xcolo-primary-quorum-remote-child-design-20260528.md): in cloud-managed cold conversion the primary quorum must be created with both local and remote children already present.

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
2. Secondary x-colo capability with generic return-path disabled.
3. Secondary NBD server start.
4. For each disk, secondary NBD export add for that disk's base/parent node. Design 332 supersedes the earlier attempt to export the COLO quorum top node (`ftctl-colo-<target>`), because QEMU's COLO procedure exports `parent0` and the primary NBD client attaches that export under the primary quorum.
5. Primary QMP capabilities.
6. For each disk:
   - primary NBD client add against the same `ftctl-colo-<target>` export;
   - primary active overlay add;
   - primary quorum add with both children already present: `ftctl-primary-active-<target>` and `nbd0-<target>`;
   - primary disk device replacement to the completed quorum.
7. Primary network filter object attach.
8. Primary x-colo capability with generic return-path disabled.
9. Primary checkpoint parameter update.
10. Primary `cont`.
11. Primary migrate.

Primary `migrate` must not start while any writable disk is outside the COLO graph.

## Runtime Convergence Contract

Cloud-managed FT registration must not require the synchronous Cloud API call to wait until QEMU reports both peers as fully `running`.

After the disk graph, NBD exports, network filters, and migration channels are attached:

- if QEMU reports a terminal failure, qemu FTCTL must return failure and preserve `last_error`;
- if QEMU reports `primary migrate=active`, `secondary migrate=colo`, and both runtime XMLs contain the required COLO markers, qemu FTCTL must return success with:
  - `protection_state=pairing`
  - `transport_state=establishing`
  - `conversion_state=pending`
  - `conversion_stage=runtime_converging`
- later timer reconciliation must promote the pair to `colo_running / mirroring` when both peers converge, or to `error / failed` when QEMU reports a terminal failure.

This keeps Cloud's API call bounded while qemu FTCTL remains responsible for the actual FT runtime convergence.

## Validation

Selftest coverage must assert:

- generated primary XML rewrites all mapped disks;
- generated secondary XML rewrites all mapped disks;
- per-disk secondary block graph QMP commands use unique node names;
- per-disk primary block graph and NBD attach commands use unique node names;
- primary quorum creation includes both the local primary active child and the remote NBD child;
- all NBD exports are added before primary migration;
- secondary exports and primary NBD clients use `ftctl-colo-<target>` and never the `libvirt-*` base node for multi-disk COLO.
- cloud-managed multi-disk cold conversion does not depend on `x-blockdev-change` to patch the primary quorum after device replacement.
- device replacement preserves bootability without duplicating `bootindex`: only the boot/root LUN gets `bootindex`, and data disks omit it.
- runtime validation distinguishes terminal failures from pending convergence.

## Failure State Contract

Any per-disk attach failure must leave qemu FTCTL state in an explicit failure state:

- `conversion_stage=runtime_graph_failed`
- `conversion_state=error`
- `protection_state=error`
- `transport_state=failed`

This prevents Cloud from presenting a failed partial graph as `pairing/planned`.
