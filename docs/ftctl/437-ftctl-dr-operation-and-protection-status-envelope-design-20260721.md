# FTCTL DR Operation And Protection Status Envelope Design

- Date: 2026-07-21
- Cloud normative design: `ablestack-cloud/docs/ftctl/565-cross-hypervisor-dr-post-test-cleanup-protection-projection-convergence-design-20260721.md`
- Scope: `lib/ftctl/dr_runtime.sh`, `lib/ftctl/dr_scheduler.sh`, CLI/Agent status contract, self-tests

## 1. Purpose

`dr-status --run <operation>` currently emits one flat object containing both
the requested operation's immutable state and the Plan's live scheduler state.
After Test Cleanup, the request Run is terminal while the producer scheduler
continues to create checkpoints. This document separates those status domains
without changing the existing automatic scheduler resume algorithm.

## 2. Verified runtime behavior

Read-only preflight for Plan `c952cae5-11db-4e2a-807d-5ae1d3f9634d`
confirmed:

- cleanup Run `308e9451-...` completed;
- control generation 4 requested `run` with reason `test-cleanup`;
- ACK generation 4 reported `RUNNING`;
- active producer remained `faf53080-...`;
- scheduler session matched the Plan and lease epoch remained 1;
- checkpoint lease was released and transition completed;
- authority advanced to 292;
- completed checkpoint advanced from 142 to 145;
- Cloud continued requesting status with the cleanup Run UUID.

Automatic resume succeeded. The status contract was ambiguous because:

- top-level operation timestamps remained at the cleanup checkpoint;
- live scheduler fields came from the producer;
- `latestCompletedCycle.runUuid` was copied from the cleanup request Run;
- checkpoint reference correctly embedded the producer Run.

## 3. Invariants

1. The status request Run identifies the operation envelope only.
2. The Plan scheduler lease identifies protection authority.
3. `active_worker_run_uuid` identifies the producer worker.
4. A completed checkpoint identifies its own producer from the durable record.
5. Operation files are not rewritten to impersonate the producer.
6. Flat compatibility fields are aliases, not an independent source.
7. `dr-status` is read-only and never starts or resumes a worker.
8. Cleanup resume remains in the cleanup action path.

## 4. Target JSON contract

Capability: `dr-status-envelope-v2`.

```json
{
  "command": "dr-status",
  "result": "ok",
  "plan_uuid": "c952cae5-...",
  "run_uuid": "308e9451-...",
  "operation": {
    "run_uuid": "308e9451-...",
    "action": "dr-test-artifact-cleanup",
    "state": "READY",
    "step": "test-cleanup-completed",
    "progress": 100,
    "terminal": true,
    "updated_at": "2026-07-21T07:05:39+09:00"
  },
  "protection": {
    "producer_run_uuid": "faf53080-...",
    "scheduler_session_uuid": "c952cae5-...",
    "scheduler_lease_epoch": 1,
    "authority_sequence": 292,
    "plan_cycle_sequence": 146,
    "scheduler_state": "RUNNING",
    "scheduler_health": "HEALTHY",
    "owner_matched": true,
    "control": {
      "generation": 4,
      "ack_generation": 4,
      "state": "RUNNING",
      "request_run_uuid": "308e9451-..."
    },
    "transition": {
      "state": "COMPLETED",
      "action": "dr-test-artifact-cleanup",
      "checkpoint_lease_state": "RELEASED"
    },
    "latest_completed_cycle": {
      "plan_uuid": "c952cae5-...",
      "producer_run_uuid": "faf53080-...",
      "sequence": 145,
      "cycle_token": "c952cae5-...:145",
      "state": "TARGET_READY",
      "target_durable_at": "2026-07-21T07:16:59+09:00"
    }
  }
}
```

## 5. `dr_runtime.sh` code design

### 5.1 Snapshot readers

Split `ftctl_dr_runtime_emit_state_json()` input collection into helpers:

```bash
ftctl_dr_runtime_read_operation_snapshot PLAN RUN OP_ARRAY
ftctl_dr_runtime_read_protection_snapshot PLAN PROTECTION_ARRAY
ftctl_dr_runtime_read_latest_completed_cycle PLAN CYCLE_ARRAY
ftctl_dr_runtime_validate_status_envelopes OP_ARRAY PROTECTION_ARRAY CYCLE_ARRAY
```

The helpers read under the existing state snapshot boundary and return values
through associative arrays. JSON output happens only after all snapshots are
validated.

### 5.2 Operation envelope

Operation fields come only from:

```text
plans/<plan>/runs/<requested-run>.state
```

If no Run was requested, the operation object is omitted. A missing requested
Run returns the existing typed not-found result without fabricating a producer
operation.

### 5.3 Protection envelope

Protection fields come from Plan-scoped files:

```text
scheduler/lease.state
scheduler/active.pid
scheduler/control.state
scheduler/control.ack
scheduler/transition.state
scheduler/sequence.state
status.state
restore-points.jsonl
```

`producer_run_uuid` precedence:

1. validated `scheduler/active.pid.worker_run_uuid`;
2. validated `scheduler/lease.state.worker_run_uuid`;
3. producer UUID stored in the latest completed checkpoint record.

The status request Run is never a producer fallback.

### 5.4 Completed-cycle producer

Extend restore-point/checkpoint JSONL records with an explicit
`producer_run_uuid` if not already present. For compatibility, parse the
producer from a checkpoint ref of the form:

```text
ftctl:<plan>:<producer-run>:<sequence>
```

Reject the completed snapshot with
`DR_STATUS_CHECKPOINT_PRODUCER_INCOHERENT` when the explicit producer and
checkpoint-ref producer disagree.

### 5.5 Compatibility aliases

For one release:

- top-level `action/state/step/progress/updated_at` alias `operation.*`;
- top-level scheduler/control fields alias `protection.*`;
- top-level `latest_completed_*` alias
  `protection.latest_completed_cycle.*`;
- `latestCompletedCycle.runUuid` in the Agent DTO maps to the producer, not the
  request Run.

Top-level `last_target_durable_at` remains an operation compatibility field.
Cloud protection projection must use `latest_completed_target_durable_at`.

## 6. `dr_scheduler.sh` code design

### 6.1 Durable cycle record

When a cycle reaches `TARGET_READY`, write these fields atomically before
advancing latest-completed state:

```bash
producer_run_uuid="${active_worker_run_uuid}"
scheduler_session_uuid="${scheduler_session_uuid}"
scheduler_lease_epoch="${lease_epoch}"
authority_sequence="${authority_sequence}"
plan_cycle_sequence="${sequence}"
```

The cycle append and latest-completed pointer update remain under the Plan
cycle lock.

### 6.2 Cleanup resume

Retain the existing order:

```text
artifact cleanup
-> checkpoint lease release
-> resume_after_transition
-> identity-bearing RUNNING ACK
-> transition COMPLETED
```

Do not add a second timer- or status-driven Resume command. The next normal
scheduler cycle is the proof of resumed data protection.

## 7. Validation rules

The status command returns a successful operation envelope and a failed
protection integrity result separately when appropriate. Protection is
coherent only when:

```text
plan UUID == scheduler session UUID
lease epoch == active worker lease epoch
owner matched == true
producer UUID == active worker UUID
completed cycle Plan UUID == requested Plan UUID
completed cycle producer == checkpoint-ref producer
completed sequence <= plan cycle sequence
```

An operation may be `SUCCEEDED` while protection integrity is invalid. Cloud
must preserve operation history and mark protection `DEGRADED`.

## 8. Agent mapping contract

The Agent wrapper maps:

```text
operation.*  -> operation DTO fields
protection.* -> authority/control/transition DTO fields
protection.latest_completed_cycle -> FtctlDrCycleSnapshot
```

The request Run remains `answer.runUuid`; the completed cycle exposes
`producerRunUuid`. These fields must not be overloaded.

## 9. Self-tests

Add cases to `ftctl-vm` self-tests:

1. status requested with cleanup Run reports cleanup operation;
2. protection producer remains original sync Run;
3. latest completed cycle uses producer Run;
4. checkpoint-ref producer mismatch is rejected;
5. cleanup ACK generation/session/epoch/worker identity all match;
6. next cycle sequence exceeds the leased test sequence;
7. flat aliases match the new envelopes;
8. status read does not create a worker or change control generation;
9. missing requested Run does not erase Plan protection status;
10. JSON output contains no credentials.

## 10. Rollout

1. Add envelope generation and self-tests.
2. Publish `dr-status-envelope-v2` capability.
3. Deploy FTCTL and Agent before Cloud begins requiring the capability.
4. Cloud reads v2 envelopes when available and retains a bounded flat-field
   compatibility path.
5. After all hosts report v2, remove request-Run producer fallback from Cloud.

## 11. AS-IS / TO-BE

| Area | AS-IS | TO-BE |
|---|---|---|
| status scope | operation and Plan protection mixed in one flat object | explicit operation and protection envelopes |
| request Run | leaks into completed-cycle `runUuid` | identifies operation only |
| cycle owner | may become cleanup Run | durable producer Run |
| cleanup | resume succeeds but proof is ambiguous | ACK plus newer durable cycle is explicit |
| timestamp | stale operation durable time can be mistaken for RPO | latest completed-cycle durable time is canonical |
| compatibility | flat fields interpreted independently | flat fields are generated aliases |

## 12. Completion gate

- Cleanup Run can be queried without changing producer identity.
- `protection.producer_run_uuid` equals the validated live worker owner.
- `latest_completed_cycle.producer_run_uuid` equals the checkpoint producer.
- Control ACK and checkpoint lease state prove transition completion.
- A post-cleanup cycle advances normally without a manual Resume.
- Cloud can project authority and cycles without interpreting the request Run as
  protection ownership.
