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

## 8. vCenter Certificate Rollover Recovery

A recovered vCenter can present a new certificate while an existing DR profile
still contains a thumbprint previously obtained with
`thumbprintSource=backend-auto`. Snapshot creation and CBT query can succeed,
but VDDK rejects the data-plane open with an SSL thumbprint mismatch and may
surface it as `VixDiskLib_Open: Unknown error`.

FTCTL refreshes the endpoint thumbprint before each source open only when the
configured source is `backend-auto`. An operator-supplied `runtime` thumbprint
remains pinned and is never replaced implicitly. If automatic refresh is
temporarily unavailable, the previous automatically obtained value remains the
fallback for that attempt.

Source-open evidence records `backend-auto-refreshed` when the endpoint
certificate changed. The scheduler can then resume the durable CBT baseline
after snapshot cleanup without forcing a full seed.

After an incremental VDDK source opens successfully, FTCTL rewrites
`vmware-source-open.json` as a successful observation. This prevents a durable
incremental cycle from coexisting with stale source-open failure evidence left
by an earlier vCenter outage or certificate rollover.

The mover repeats that successful evidence write only after all disks have
completed and the cycle journal reaches `LOCAL_DURABLE`. This final barrier is
required for `NO_CHANGE`, full-seed, incremental, and multi-disk cycles alike;
therefore a stale source-open failure cannot survive a successful durable cycle
even when no per-disk CBT patch function was invoked.

## 9. Test Release Verification

- Source commit: `4900bd78ad3dae46b3bf5ca2318de4bf367f7eb8`
- GitHub Actions run: `32469879056`
- RPM: `ablestack_vm_ftctl-0.9.5-1.noarch.rpm`
- RPM SHA256: `651a2508ae0bd69d1aee4d9add9b0adb68a2013d897792daedd5094e7c014cc2`
- Installed mover SHA256 on all six compute hosts:
  `5262a2862cc3c93375d63d336892f01a0d14d60874a309f71244149961534fe6`

The package was installed on `10.10.32.1/2/3` with `aspkg` and on
`10.10.22.1/2/3` with native `rpm`. All FTCTL timers remained active. The
Rocky, Windows, and Ubuntu plans then completed automatic cycles 1932, 2827,
and 1806 respectively. Every cycle was `LOCAL_DURABLE`, `READY`, and
incrementally verified; Ubuntu transferred 1,769,472 bytes by CBT while Rocky
and Windows correctly reported `NO_CHANGE`.

For all three plans, `vmware-source-open.json` is now `ready=true` with an
empty error code and the message `VMware source cycle completed`.
`vmware-source-snapshot.json` is `CLEANED` with no active snapshot reference,
and a direct vCenter `snapshot.tree` query returns no snapshots for the three
source VMs.
