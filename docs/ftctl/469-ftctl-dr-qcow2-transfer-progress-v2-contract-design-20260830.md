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
- `bytesTotal`, `bytesProcessed`, `percent`, throughput, ETA, disk position,
  transfer mode, and sample sequence remain monotonic for one cycle.
- A terminal sample is published only after the target file is durable and the
  bitmap backup job has concluded successfully.
- Existing VMware and RBD producers keep their validated transfer behavior.

## Verification

- Unit test the qcow2 writer contract and owner fields.
- Run the SharedMountPoint qcow2 smoke suite and existing action contract gate.
- Deploy FTCTL to both source and target clusters.
- Validate from the Cloud UI that a running failback shows data bytes,
  throughput, ETA, and a non-terminal whole-operation percentage until the
  transfer is complete.
