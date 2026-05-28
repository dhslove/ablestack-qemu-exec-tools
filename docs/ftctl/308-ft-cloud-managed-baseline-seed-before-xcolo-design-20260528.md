# FT Cloud-Managed Baseline Seed Before X-COLO Design

## Background

The `r97-link-01` cloud-managed FT test progressed past the primary quorum remote-child fix:

- generated primary started;
- generated secondary started;
- secondary NBD exports were created;
- primary quorum nodes were created with local and remote children;
- primary was continued before migrate;
- primary migrate returned OK.

Runtime still timed out in `finish-migrate` / `inmigrate`. Inspection showed the Cloud-created secondary target disks were still near-empty qcow2 files, around 197 KiB, while the guest console waited on the data volume. That means the standby VM was not a baseline clone before X-COLO started.

This is not a UI problem. FT requires the secondary to be a clone of the primary at disk and VM state level. X-COLO checkpointing cannot converge when the secondary disk baseline is empty or unrelated.

## Design Principle

For cloud-managed block-backed FT, Cloud owns VM and volume lifecycle, but qemu FTCTL owns data-plane preparation.

Cloud must create the standby VM and target volumes. qemu FTCTL must then seed the target volumes with the primary disk baseline before starting the generated secondary and before attaching the X-COLO runtime graph.

The order is:

1. Cloud creates standby VM and target volumes.
2. qemu FTCTL stops the primary for cold conversion.
3. qemu FTCTL seeds every secondary target disk from the matching primary disk.
4. qemu FTCTL verifies the seeded target virtual size.
5. qemu FTCTL starts generated primary and generated secondary.
6. qemu FTCTL attaches overlays, NBD exports, primary quorum, filters, and migration.

## Seed Transport

The seed transport is primary read-only NBD:

1. The primary host opens a temporary read-only `qemu-nbd` export for the stopped primary disk.
2. The secondary host runs `qemu-img convert` from `nbd://<primary-host>:<seed-port>/<export>` to the Cloud-created target path.
3. For file targets, conversion writes to a temporary file in the same directory and then atomically replaces the target path.
4. For block targets, conversion writes directly to the target block device.
5. The temporary NBD export and transient firewall opening are removed after each disk.

The seed step uses the existing host transfer network assumption. It does not create or delete Cloud VM/volume records.

## Failure Handling

If any disk seed fails:

- stop the temporary seed NBD export;
- restore the primary from the backed-up Cloud XML path;
- set `conversion_stage=baseline_seed_failed`;
- set `protection_state=error`;
- set `transport_state=failed`;
- set `last_error=xcolo_baseline_seed_failed:<target>`.

The generated secondary must not be started if baseline seed fails.

## Validation

Selftests must assert:

- qemu FTCTL starts a read-only primary `qemu-nbd` seed export;
- secondary seed uses `qemu-img convert` from the primary NBD URI;
- file targets are seeded through a temporary file and moved into place;
- the per-disk seeded state marker is written before runtime graph assembly.

Runtime validation must confirm that Cloud-created secondary target disks are no longer empty placeholder qcow2 files before X-COLO migration starts.
