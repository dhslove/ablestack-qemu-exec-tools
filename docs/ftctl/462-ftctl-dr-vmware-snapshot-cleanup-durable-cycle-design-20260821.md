# FTCTL DR VMware Snapshot Cleanup And Durable Cycle Design

## 1. Purpose

Preserve a successfully committed VMware to ABLESTACK replication cycle when
the temporary VMware snapshot cleanup fails, and retry cleanup without losing
the immutable snapshot identity or advancing the retry sequence.

## 2. Confirmed Failure

After vCenter recovery, the three protected VMs completed controlled
`FULL_RESEED` cycles with `LOCAL_DURABLE` metadata and durable target writes.
The EXIT cleanup then failed. The next cycle copied its requested snapshot name
into `lastSnapshotName` while retaining the previous `lastSnapshotRef`. This
created an invalid name/ref pair, left the completed snapshot in vCenter, and
blocked subsequent incremental cycles as `DR_CBT_QUERY_FAILED`.

## 3. Contract

| Area | AS-IS | TO-BE |
|---|---|---|
| Snapshot identity | name can be replaced while ref is retained | immutable `(vmRef, snapshotRef, snapshotName, cycle)` |
| Removal | remove by caller-provided name | validate ownership and remove by MoRef, including owned retry descendants |
| Durable cycle | EXIT cleanup can replace exit 0 with exit 1 | `LOCAL_DURABLE` remains successful; cleanup is a separate barrier |
| Cleanup retry | next sequence is created and fails terminally | same sequence and owner Run wait in `WAITING_CLEANUP` |
| Error code | cleanup pending is reported as CBT query failure | `DR_VMWARE_SNAPSHOT_CLEANUP_PENDING`, retryable |
| Cloud projection | current scheduler failure can hide a newer durable cycle | latest completed cycle sequence is projected independently |

## 4. FTCTL Flow

```text
transfer -> metadata commit -> LOCAL_DURABLE
  -> snapshot cleanup succeeds -> cycle success
  -> snapshot cleanup fails -> cycle success + cleanupRequired

next scheduled cycle
  -> cleanupRequired
  -> resolve immutable snapshot subtree by snapshotRef
  -> verify every descendant belongs to the same FTCTL run prefix
  -> cleanup succeeds -> continue same cycle
  -> cleanup still fails -> WAITING_CLEANUP, same sequence, backoff
```

The EXIT trap preserves the mover's original exit status. Snapshot cleanup is
still attempted on every exit, but a post-commit cleanup failure cannot regress
the durable data cycle. Before a new VMware snapshot is created, the mover must
finish any pending cleanup. The scheduler stores `pending_cleanup_sequence`,
cycle type, owner Run and retry counters so process restarts do not create
additional cycles.

## 5. Cloud Projection

Cloud uses `latest_completed_cycle_sequence` first and falls back to the legacy
`latest_completed_checkpoint_sequence`. A latest completed cycle is projected
even when the current scheduler state is `WAITING_CLEANUP` or `ERROR`; current
maintenance state and last durable recovery point are independent facts.

## 6. Recovery Of The 2026-08-21 Test Plans

1. Deploy the patched FTCTL package to both test clusters.
2. For the three 32-cluster plans, resolve retained refs `snapshot-26005`,
   `snapshot-26006`, and `snapshot-26004` to their actual names.
3. Remove only those verified snapshots and atomically mark cleanup `CLEANED`.
4. Restart each failed scheduler without resetting its committed disk map.
5. Verify the first automatic cycle is `CBT_INCREMENTAL` or `NO_CHANGE`, Cloud
   projects the new latest completed sequence, and no FTCTL source snapshot is
   left behind.

## 7. Verification

- Mismatched stored name/ref resolves and removes the object selected by ref.
- Duplicate retry names are removed by MoRef only when the full subtree is FTCTL-owned.
- A foreign descendant blocks recursive cleanup and remains retryable.
- Missing snapshot is treated as idempotently cleaned.
- Cleanup failure preserves the original mover return code after durable commit.
- rc 99 remains retryable and reuses the same sequence.
- Cloud projects a latest completed cycle supplied only through the explicit
  latest-cycle sequence alias.
- Existing VMware to RBD transfer and CBT patch paths are unchanged.
