# FTCTL DR remote-source Test Cleanup authority

## Problem

For a Cross-Mold `KVM_TO_KVM` Plan, the target coordinator receives
`schedulerTransitionScope=REMOTE_SOURCE` but cannot resolve the source compute
host in its local Mold inventory. The previous runtime gate also required
`workers.source`, so the target coordinator incorrectly started a local
replication scheduler after Test Cleanup. That scheduler could only fail while
trying to open source disks that do not exist at the target site.

## Contract

- `schedulerTransitionScope=REMOTE_SOURCE` is a Cloud-issued site authority
  contract, not a host-placement hint.
- A target or coordinator executing Test Cleanup removes only test artifacts,
  releases the checkpoint lease, and records `CLEANED`.
- It must not start or resume a local replication scheduler.
- Cloud resumes protection through the source Mold. The source Mold selects a
  live storage-capable worker at execution time.
- A source worker UUID is optional observation data and must never be required
  to recognize a remote-source transition.
- Without an explicit transition scope, FTCTL does not infer remote authority
  from worker UUIDs.

## Regression gate

The ABLESTACK remote RBD smoke test covers both forms of the profile: with a
source worker observation and with no `workers.source`. Both must recognize
`REMOTE_SOURCE`; a profile without the scope must not.

This change does not alter disk transfer, checkpoint sealing, failover, or
failback data paths.

## Operation creation boundary

An operation status query can arrive after Cloud persists the Run but before
FTCTL creates the Run state file. In that interval, dr-status --run must not
copy the Plan status file's action, cycle error, worker identity, or terminal
metadata into the operation response.

FTCTL returns a minimal operation-scoped envelope:

- result=run_not_found
- status_scope=OPERATION
- state=QUEUED, step=run-pending
- run_exists=false, error_code=not_found
- terminal_authoritative=false

The response is a retry boundary, not an operation failure. Once the Run file
exists, the normal operation state replaces it. A completed operation keeps
using its Run journal, so this rule cannot hide a durable terminal failure.
