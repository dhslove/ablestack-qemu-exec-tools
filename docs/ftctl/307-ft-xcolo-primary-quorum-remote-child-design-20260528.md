# FT X-COLO Primary Quorum Remote Child Design

## Background

After the `primary.cont_before_migrate` fix, `r97-link-01` progressed further:

- primary generated domain started;
- secondary generated domain started;
- peer channels attached;
- all secondary NBD exports were created;
- primary network filters were attached;
- primary was explicitly continued before migration;
- primary `migrate` returned OK.

The final runtime still failed with:

```text
xcolo_runtime_validation_failed:runtime_convergence_timeout
primary status=finish-migrate, primary migrate=active
secondary status=inmigrate, secondary migrate=colo
```

This proved that the primary was no longer simply left stopped. The remaining issue was the block graph. Runtime evidence showed primary writes in the primary active overlay, while secondary active overlays stayed nearly empty. That means the primary graph did not reliably include the remote NBD replica child even though QMP commands returned success.

## Design Principle

For cloud-managed block-backed FT, the primary disk device must never be switched to a local-only COLO quorum and then patched later with `x-blockdev-change`.

The primary disk graph must be built as a complete graph from the start:

```text
guest disk device
  -> ftctl-colo-<disk> quorum
       -> ftctl-primary-active-<disk>
       -> nbd0-<disk>
```

The remote NBD child must exist before the primary disk device is replaced.

## Updated Handshake Order

For each protected disk:

1. Prepare primary/secondary overlay files.
2. Attach the secondary graph:
   - secondary hidden overlay;
   - secondary active overlay;
   - secondary replication node;
   - secondary quorum top node.
3. Start secondary NBD server and export each secondary quorum top node.
4. On primary, create the NBD client node for each exported secondary quorum.
5. On primary, create the primary active overlay.
6. On primary, create the primary quorum with both children already present:
   - local primary active overlay;
   - remote NBD child.
7. Replace the primary disk device with the completed quorum node.
8. Attach primary network filters.
9. Set migration capabilities and checkpoint delay.
10. `cont` primary.
11. Start primary migration.

The old `x-blockdev-change parent=ftctl-colo-<disk> node=nbd0-<disk>` path is not used for cloud-managed multi-disk cold conversion.

Before this order starts, the Cloud-created secondary target disks must already contain the primary disk baseline. That seed step is defined in [308. FT Cloud-Managed Baseline Seed Before X-COLO Design](308-ft-cloud-managed-baseline-seed-before-xcolo-design-20260528.md). The quorum remote-child fix only makes the runtime graph complete; it does not replace baseline disk materialization.

## Failure Handling

Any missing primary base node, qdev, primary overlay, or secondary export must fail before primary migration starts.

If runtime validation still fails after migration, qemu FTCTL must keep:

- `protection_state=error`
- `transport_state=failed`
- `last_error=xcolo_runtime_validation_failed:<reason>`
- `xcolo_last_runtime_error=xcolo_runtime_validation_failed:<reason>`

## Validation

Selftests must assert:

- secondary exports are created before primary migration;
- primary NBD client nodes are created for every disk;
- primary quorum nodes contain both `ftctl-primary-active-<disk>` and `nbd0-<disk>` at creation time;
- cloud-managed multi-disk cold conversion does not use `primary.x_blockdev_change.<disk>`;
- primary is continued before migration.
