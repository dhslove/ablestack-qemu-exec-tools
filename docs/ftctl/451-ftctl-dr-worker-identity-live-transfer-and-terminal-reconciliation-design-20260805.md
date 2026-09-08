# 451. FTCTL DR Worker Identity, Live Transfer, And Terminal Reconciliation Design

- Date: 2026-08-05
- Status: implemented, packaged, deployed, and preflight verified
- Scope: asynchronous Failback worker identity, transfer heartbeat, status reconciliation, cleanup ownership
- Parent: [450](450-ftctl-dr-reverse-rbd-snapshot-readonly-nbd-and-terminal-causality-design-20260805.md)
- Cloud companion: `ablestack-cloud/docs/ftctl/594-cross-hypervisor-dr-live-worker-and-terminal-reconciliation-design-20260805.md`
- Post-transfer route correction: [452](452-ftctl-dr-failback-route-envelope-and-cloud-lifecycle-boundary-design-20260805.md)

## 1. Objective

Prevent a live KVM-to-VMware Failback transfer from being terminalized as a
dead worker. Worker identity, transfer activity, and terminal evidence must be
published by explicit owners and merged without shared-file write races.

The correction must preserve TARGET authority until Cloud receives an
authoritative `FAILBACK_DATA_READY` result and completes the Cloud-owned power
and authority transition.

## 2. Verified incident

Plan `7889e625-371a-48f9-b553-54e311481170` started Failback Run
`1d1a7766-dbc8-4394-8cfb-d559d59ff4d6` at 2026-08-05 12:08:47 KST.

| Evidence | Observed value |
|---|---|
| FTCTL Run file | `RUNNING`, `failback-transfer`, 55 percent |
| Plan status projection | `ERROR`, `failback-worker-exited` |
| Cloud Run | `FAILED`, `DR_TERMINAL_PUBLICATION_TIMEOUT` |
| Recorded worker PID | `1708929` |
| Actual PID start ticks | `9313301` |
| Recorded start ticks | `9313370` |
| Worker process | alive |
| Transfer processes | `dr_extent_patch.py`, read-only `qemu-nbd`, VDDK `nbdkit` alive |
| I/O proof | read/write counters increased about 2.75 GB in 20 seconds |
| KVM serving VM | running |
| VMware source VM | powered off |
| Authority | TARGET retained |

The watchdog treated the PID/start-tick mismatch as worker death even though
the owned transfer tree was active. Cloud then closed the Run and Failback
Session while the VDDK writer continued modifying the powered-off VMware disk.

## 3. Preflight conclusion

A standalone Bash probe of `BASHPID` and `/proc/<pid>/stat` produced matching
values. Therefore the defect is not explained by Bash command substitution
alone. It appears only in the real asynchronous path, where launcher, worker,
and status reconciliation publish overlapping fields.

The current implementation has three unsafe properties:

1. `ftctl_dr_runtime_start_failback()` and
   `ftctl_dr_runtime_failback_worker()` both publish worker identity.
2. `ftctl_dr_runtime_path_set()` atomically replaces one file, but has no
   generation check or writer ownership. Concurrent callers are last-writer
   wins and may overwrite a newer snapshot of the file.
3. `ftctl_dr_runtime_emit_state_json()` is a status reader but also writes
   `terminal_publication_pending` and `worker_pid_alive` into the Run file.

The design therefore removes shared mutable ownership instead of only
increasing the watchdog timeout.

## 4. Safety invariants

1. One Run has one immutable launch identity and one worker identity owner.
2. PID and start ticks are one tuple with one launch nonce and generation.
3. A status read never mutates Run, worker, progress, or terminal evidence.
4. A live owned transfer prevents watchdog terminalization.
5. A stale heartbeat is a suspect observation, not a failure by itself.
6. Only an engine terminal journal or confirmed dead-and-drained reconciliation
   may close a Run.
7. TARGET remains authoritative while reverse data is transferring or status
   is reconciling.
8. A second Failback cannot start while an owned worker, mover, NBD endpoint,
   or reconciliation obligation exists.
9. Cleanup is idempotent and removes only resources tagged with the Run UUID.
10. A lower-ranked watchdog observation cannot replace engine terminal proof.

## 5. Runtime journal layout

Replace the multi-writer Run state contract with owner-specific journals:

```text
runs/<run>/launch.state       launcher-owned, immutable after acceptance
runs/<run>/worker.state       worker-owned identity and heartbeat
runs/<run>/progress.state     mover supervisor-owned progress
runs/<run>/terminal.state     engine-owned, immutable terminal envelope
runs/<run>/observation.state  reconciler-owned liveness observation
runs/<run>/cleanup.state      cleanup controller-owned resource proof
```

Every write uses temporary-file plus `fsync` plus rename. Each file contains
`plan_uuid`, `run_uuid`, `launch_nonce`, `generation`, `writer_role`, and
`written_at`. A writer cannot update another role's journal.

The legacy `runs/<run>.state` remains a compatibility projection during one
release but is generated from the journals by a single materializer. New code
must not use it as an ownership record.

## 6. Worker identity contract

### 6.1 Launch handshake

`ftctl_dr_runtime_start_failback()` performs:

1. generate `launch_nonce` and monotonic `worker_generation`;
2. write `launch.state` with `ACCEPTED`;
3. fork the worker and retain `$!` only as an expected PID;
4. wait up to two seconds for `worker.state` acknowledgement;
5. validate Run UUID, nonce, generation, PID, start ticks, and command line;
6. return asynchronous acceptance only after the identity acknowledgement.

The launcher does not write `worker_pid` or `worker_start_ticks` into mutable
Run state.

### 6.2 Worker self-publication

At worker entry:

```bash
ftctl_dr_runtime_worker_identity_publish() {
  local plan="$1" run="$2" nonce="$3" generation="$4"
  local pid="${BASHPID:-$$}" start_ticks
  start_ticks="$(ftctl_dr_scheduler_process_start_ticks "${pid}")" || return 1
  ftctl_dr_runtime_worker_journal_write \
    "${plan}" "${run}" "${nonce}" "${generation}" \
    "${pid}" "${start_ticks}" "STARTING" "$(ftctl_now_iso8601)"
}
```

The same local `pid` value is used for both PID publication and start-tick
lookup. The function validates the tuple immediately after atomic rename.

### 6.3 Identity states

```text
STARTING -> RUNNING -> TERMINAL_PUBLISHED -> EXITED
                  \-> CANCELING -> CANCELED
```

Identity state is not the operation terminal state. `EXITED` without a
terminal journal creates a reconciliation obligation.

## 7. Transfer heartbeat and ownership

The worker starts the mover as a supervised child. While the mover is alive,
the supervisor updates every two seconds:

```text
worker_heartbeat_at
transfer_activity=ACTIVE
transfer_disk_index
source_read_bytes
target_written_bytes
transfer_payload_bytes
owned_process_count
source_nbd_devices
target_nbd_devices
vddk_writer_pids
```

`dr_extent_patch.py` exposes progress through an atomic metrics path or a
dedicated progress file descriptor. Status code must not infer progress from
process names alone.

The supervisor waits for the child, captures the exact exit status, completes
NBD/VDDK cleanup, publishes `terminal.state`, and only then marks the worker
identity `TERMINAL_PUBLISHED`.

## 8. Liveness classifier

Introduce:

```text
ALIVE
SUSPECT
DEAD_CONFIRMED
TERMINAL
```

Classification rules:

| Evidence | Classification |
|---|---|
| terminal journal exists | `TERMINAL` |
| PID/ticks match and heartbeat fresh | `ALIVE` |
| owned mover or transfer bytes are advancing | `ALIVE` |
| one identity mismatch or stale heartbeat | `SUSPECT` |
| three negative probes over grace, no owned process, no byte advance | `DEAD_CONFIRMED` |

`SUSPECT` projects `RECONCILIATION_REQUIRED`, remains retryable for status
polling, and cannot create an operation failure. `DEAD_CONFIRMED` may create a
watchdog terminal only after cleanup proves that no writer remains.

## 9. Pure status projection

`ftctl_dr_runtime_emit_state_json()` becomes read-only. It loads all journals,
validates matching Run UUID, nonce, and generation, and emits a merged view.

New fields:

```json
{
  "worker_identity_state": "VALID|MISMATCH|MISSING",
  "worker_liveness_state": "ALIVE|SUSPECT|DEAD_CONFIRMED|TERMINAL",
  "worker_launch_nonce": "...",
  "worker_generation": 12,
  "worker_heartbeat_at": "...",
  "transfer_activity": "ACTIVE|IDLE|DRAINING|COMPLETE",
  "transfer_payload_bytes": 94749327360,
  "owned_process_count": 5,
  "reconciliation_required": false,
  "terminal_authoritative": false
}
```

`WATCHDOG_DERIVED` is provisional until `DEAD_CONFIRMED` and resource drain
proof are both present. It cannot be emitted while transfer activity is
`ACTIVE`.

## 10. Cancellation and cleanup

Cancellation is a separate command with the same Run UUID and launch nonce.
It performs:

1. mark `CANCEL_REQUESTED`;
2. signal the worker supervisor, not arbitrary process-name matches;
3. stop the mover and wait;
4. disconnect target NBD, stop VDDK writer, disconnect source NBD;
5. remove only Run-owned RBD snapshots;
6. verify VMware VM remains powered off and TARGET remains authoritative;
7. publish `CANCELED` or typed cleanup failure.

An already Cloud-terminalized but still active transfer is not manually
retried. It enters `RECONCILIATION_REQUIRED` and uses this controlled cleanup
path before a new Run is admitted.

## 11. Code changes

### `lib/ftctl/dr_runtime.sh`

- replace dual identity publication in
  `ftctl_dr_runtime_start_failback()` and
  `ftctl_dr_runtime_failback_worker()` with the launch handshake;
- make `ftctl_dr_runtime_emit_state_json()` side-effect free;
- add journal merge and liveness classification;
- publish terminal before identity exit;
- prevent retry while active transfer or reconciliation exists.

### `lib/ftctl/dr_kvm_vmware_mover.sh`

- publish per-disk transfer metrics;
- register NBD and VDDK processes by Run UUID;
- emit final byte and durability proof before return.

### `lib/ftctl/dr_extent_patch.py`

- add atomic progress output with byte counters and current extent;
- preserve the existing copy and verify exit semantics.

### `lib/ftctl/dr_scheduler.sh`

- reuse process start-tick validation through the worker journal;
- do not treat scheduler ownership and one-shot Failback ownership as the same
  mutable file.

## 12. Test design

1. asynchronous launch publishes one matching PID/start-tick tuple;
2. launcher and worker cannot overwrite each other's journals;
3. 1,000 concurrent status reads cannot change worker state;
4. a long-running mover beyond the terminal grace remains `ALIVE`;
5. PID/tick mismatch plus advancing bytes is `SUSPECT`, not terminal;
6. dead worker plus active VDDK writer remains reconciliation-required;
7. dead worker plus drained resources becomes `DEAD_CONFIRMED`;
8. engine terminal is visible before worker identity exits;
9. cancellation removes all and only Run-owned resources;
10. a second Failback is rejected while reconciliation is open.

The package-host preflight starts a harmless sleep-based worker through the
real launcher, polls status concurrently, and verifies stable identity and
heartbeat. It does not attach NBD or write VMware disks.

## 13. Current incident recovery gate

Before retest:

1. do not submit another Failback;
2. wait for or explicitly cancel the existing owned transfer;
3. verify all VDDK/NBD processes and Run snapshots are drained;
4. verify VMware remains powered off;
5. treat the partially written VMware disks as non-durable;
6. preserve TARGET KVM authority and VM power;
7. reconcile Cloud Run/Session as historical failure without clearing audit;
8. run a new full reverse seed because no committed reverse baseline exists.

## 14. Implementation priority

1. P0: single-writer worker identity journal and launch acknowledgement.
2. P0: pure read-only status merge and liveness classifier.
3. P0: transfer heartbeat, byte counters, and owned-process proof.
4. P0: block retry while active transfer or reconciliation exists.
5. P0: controlled cleanup for the current orphaned transfer.
6. P1: Cloud/Agent typed reconciliation contract from companion document 594.
7. P1: self-tests, package build, deployment, and host preflight.
8. P1: clean full reverse seed retest and authority transition verification.

## 15. AS-IS / TO-BE

| Area | Error cause | AS-IS | TO-BE |
|---|---|---|---|
| Worker identity | overlapping publishers | PID and ticks can disagree | one worker-owned immutable tuple |
| Run state | shared last-writer-wins file | status/worker updates can overwrite | owner-specific atomic journals |
| Status read | reader mutates Run file | observation changes evidence | pure merge with no writes |
| Liveness | one tuple mismatch | immediate dead-worker path | multi-signal `ALIVE/SUSPECT/DEAD_CONFIRMED` |
| Progress | no heartbeat during long copy | worker appears stale | heartbeat and byte counters every two seconds |
| Terminal | watchdog closes active copy | Cloud fails while VDDK writes continue | engine terminal or drained dead-worker proof only |
| Retry | DB has no active Run after false failure | duplicate Failback can be admitted | active transfer/reconciliation blocks retry |
| Cleanup | process-name-oriented residue handling | partial VMDK write can remain | Run-owned idempotent cancellation and drain proof |

## 16. Completion criteria

The correction is complete only when a real two-disk full reverse seed stays
RUNNING for the entire transfer, reports advancing bytes, publishes
`FAILBACK_DATA_READY`, completes Cloud authority transition, leaves no NBD or
VDDK residue, and all FTCTL, Agent, API, DB, KVM, and VMware states agree.

## 17. Implementation and deployment verification

- Source commit: `4eeae9408b3bad15349d4979b3201c871c1f83e1`
- GitHub Actions run: `30975645481` (`success`)
- RPM: `ablestack_vm_ftctl-0.9.1-1.noarch`
- RPM SHA256: `404541ae9fe3ddd3fd39b423bf5677f5ed0f20c8d2c21f3b2266733a4b0310d1`
- Deployment targets: `10.10.32.1`, `10.10.32.2`, `10.10.32.3`
- Host verification: package installed, `ablestack-vm-ftctl.timer` active, and
  `mold-agent` active on all three hosts.
- Engine verification: worker identity reconciliation, transfer progress JSON,
  terminal authority, and endpoint-drain markers are present in the installed
  scripts.
- Self-tests: authoritative terminal publication grace and live worker journal
  conflict recovery both passed.
- Retest cleanup: the failed Failback Run was aborted through the FTCTL command,
  all Run-owned NBD/VDDK processes and NBD endpoints were drained, and the Plan
  returned to `FAILED_OVER` with TARGET authority.

## 18. Route Envelope Addendum

The subsequent live Run reached authoritative `FAILBACK_DATA_READY`, proving
the worker and transfer correction. Its route status still exposed
provider-style `reverse_direction=ABLESTACK_TO_VMWARE` without a complete
canonical tuple, while the reverse profile topology was `KVM_TO_VMWARE`.
Document 452 is normative for route-contract v2, compatibility aliases, and
Cloud-invoked idempotent abort/drain. It does not change the proven mover;
it makes the successful evidence unambiguous to Cloud.
