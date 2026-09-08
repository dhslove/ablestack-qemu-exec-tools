# FTCTL DR qcow2 transfer progress v2 contract

## Problem

SharedMountPoint qcow2 backup writes live progress with schema version 1 while
the Cloud UI accepts only the canonical version 2 transfer contract. The data
copy continues correctly, but the UI reports the workflow as 100 percent and
shows that transfer information is still being prepared.

## Contract

- Every live transfer producer writes `schemaVersion=2`.
- The journal includes immutable `planUuid`, `runUuid`, and `cycleSequence`
  ownership fields.
- `diskIndex` is zero-based and `diskCount` is the immutable number of disks in
  the cycle. Producers never publish an index outside `0..diskCount-1`.
- For Full Seed and reseed, `bytesTotal` is the immutable sum of every disk's
  virtual size. `bytesProcessed` includes all completed disks plus the active
  disk, so both values describe the cycle rather than one disk.
- `percent`, throughput, ETA, disk position, transfer mode, and sample sequence
  are derived from that cycle aggregate. A non-final disk may not publish a
  cycle-level `COMPLETED` sample or 100 percent.
- Incremental transfer keeps its changed-byte accounting; disk position still
  follows the same zero-based contract.
- A terminal sample is published only after the target file is durable and the
  bitmap backup job has concluded successfully.
- Existing VMware and RBD producers keep their validated transfer behavior.
- UI clamping of malformed historical disk positions is a display safeguard,
  not a replacement for this producer contract.

## Verification

- Unit test the qcow2 writer contract and owner fields.
- Run the SharedMountPoint qcow2 smoke suite and existing action contract gate.
- Deploy FTCTL to both source and target clusters.
- Validate from the Cloud UI that a running failback shows data bytes,
  throughput, ETA, and a non-terminal whole-operation percentage until the
  transfer is complete.
