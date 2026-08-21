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

## 10. Reverse Writer Current-Backing Resolution

### 10.1 Incident

After a successful forward failover, the Ubuntu failback attempted to open
`utest1-000004.vmdk`. That path was the forward replication snapshot leaf
captured in the original plan. Snapshot cleanup had already consolidated the
VM back to `utest1.vmdk`, which was the backing currently attached to virtual
disk key `2000`. VDDK rejected the stale leaf and FTCTL surfaced
`DR_REVERSE_SNAPSHOT_OPEN_FAILED`.

The DR plan remains the durable identity and placement contract, but a VMware
snapshot leaf is not a durable target locator. The stable locator for reverse
writes is the target VM MoRef plus virtual disk device key. The VMDK backing
path is execution-time inventory derived from that pair.

### 10.2 Required Contract

Before reverse preflight succeeds and again immediately before the reverse
writer starts, FTCTL must:

1. query the target VM through vCenter using the registered site credential;
2. match every reverse disk to the current VM device graph by device key;
3. validate that the current disk capacity matches the committed plan size;
4. replace only the generated runtime map's `targetVmdkPath` atomically;
5. reject missing, duplicate, or size-mismatched matches with
   `DR_REVERSE_TARGET_BACKING_UNRESOLVED` before creating an RBD delta snapshot
   or opening a VDDK writer.

The Cloud plan mapping and the forward VMware-to-RBD source contract are not
rewritten. This preserves the proven forward path while making reverse writes
safe across VMware snapshot create, delete, and consolidation cycles.

Because the durable plan remains in the original `VMWARE_TO_KVM` direction,
the reverse writer must take its VMware VM MoRef from the generated reverse
disk map before consulting the plan target. The plan target is the KVM replica
and must never be used for a vCenter inventory lookup.

### 10.3 AS-IS / TO-BE

| Area | AS-IS | TO-BE |
|---|---|---|
| VMware reverse target locator | Plan-time VMDK leaf path | VM MoRef + device key, resolved to current backing at execution time |
| Snapshot cleanup effect | A removed leaf can remain in the reverse map | Current device graph replaces stale runtime path atomically |
| Preflight | Tool availability and target power only | Current backing identity and capacity are also mandatory |
| Failure timing | VDDK writer fails after the reverse delta snapshot is created | Resolution failure blocks before the writer and data mutation |
| Forward success path | Shared mapping logic can be disturbed by a reverse fix | VMware-to-RBD mover and committed CBT baseline remain unchanged |

### 10.4 Regression Tests

- A stale `*-000004.vmdk` path with matching device key resolves to the current
  base backing and preserves size.
- An unknown key plus a stale path fails with exit code `90` and does not start
  the writer.
- Existing reverse maps whose current path is already valid remain unchanged
  apart from resolution evidence.
- Forward VMware-to-RBD and RBD source snapshot tests continue to pass.
