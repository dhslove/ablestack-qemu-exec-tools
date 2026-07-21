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

## 13. Implementation and deployment record (2026-07-21)

The compatibility implementation shipped in this iteration adds the durable
producer identity without breaking the current flat `dr-status` contract:

- restore-point records persist `producerRunUuid`;
- scheduler state persists `latest_completed_producer_run_uuid`;
- `dr-status` emits `latest_completed_producer_run_uuid` and advertises
  `dr-checkpoint-producer-v1`;
- the Cloud Agent maps the field into the latest completed-cycle snapshot;
- Cloud resolves cycle and restore-point ownership from that producer UUID,
  independently of the latest finite operation Run.

Validation completed with the deployed `0.9.1-1` RPM on `10.10.32.1/2/3`.
After deployment-safe scheduler restart, Plan
`c952cae5-11db-4e2a-807d-5ae1d3f9634d` advanced from sequence 152 to 153.
The new checkpoint reported producer Run
`faf53080-6832-4fbd-9d5a-77e3cc19461c`, `CBT_INCREMENTAL`, a healthy live
scheduler, and a consistent owner. Test artifacts remained cleaned.

The full nested v2 envelope remains a forward-compatible follow-up. The
producer field added here is the minimum compatible contract required to stop
cleanup Run attribution from corrupting protection projection.

## 14. Mandatory v2 correction after live regression - 2026-07-21

The minimum producer compatibility field is not sufficient as a terminal
design. Live Plan 37 showed that Cloud still queried `dr-status` with terminal
cleanup Run `308e9451-...`. The run-scoped flat response represented cleanup
success but omitted the latest incremental verification metric and exposed
stopped operation-local scheduler aliases. A Plan-only status query at the same
time exposed checkpoint sequence 154 as incrementally verified and the actual
protection scheduler as failed with `DR_SCHEDULER_OWNER_MISMATCH`.

Therefore `dr-status-envelope-v2` is mandatory, not an optional follow-up.

### 14.1 Scope contract

```text
dr-status --plan P
  scope=PLAN_AUTHORITY
  operation absent
  protection required

dr-status --plan P --run R
  scope=BOTH
  operation describes R
  protection is still read from Plan-scoped authority files
```

The requested Run may not affect these protection fields:

- scheduler identity, lease, health, heartbeat, and activity;
- Plan authority and cycle sequences;
- producer Run UUID;
- latest durable checkpoint and incremental verification;
- protection error and integrity state.

Top-level compatibility aliases are generated only after both typed envelopes
are complete. A missing operation metric cannot create a null protection alias.

### 14.2 Required emitter split

Refactor `ftctl_dr_runtime_emit_state_json()` into:

```bash
ftctl_dr_runtime_emit_operation_json plan run run_path
ftctl_dr_runtime_emit_protection_json plan status_path
ftctl_dr_runtime_emit_status_envelope_json scope operation_json protection_json
```

`ftctl_dr_runtime_emit_protection_json` resolves the latest completed cycle from
the durable cycle/restore-point record and validates its producer against the
checkpoint reference. It never reads `runs/<requested-run>.state` for
protection values.

### 14.3 Strict validation

The command returns exit 65 and `DR_STATUS_PROTECTION_INCOMPLETE` when a READY
protection envelope lacks any of:

```text
scheduler_session_uuid
scheduler_lease_epoch
authority_sequence
owner_matched
scheduler_health
latest_completed_sequence
latest_completed_producer_run_uuid
latest_completed_target_durable_at
latest_completed_incremental_verified
```

An ERROR/DEGRADED protection envelope may retain the last durable checkpoint,
but it must expose the current scheduler error independently of operation
success.

### 14.4 Compatibility and rollout

Advertise `dr-status-envelope-v2` only after nested output and all self-tests
pass. Cloud/Agent may use a two-query compatibility mode before that capability:
one Plan-only query for protection and one run-scoped query for operation. They
must never project authority from the run-scoped flat response.

### 14.5 Additional self-tests

1. cleanup Run succeeds while Plan protection reports OWNER_MISMATCH;
2. Plan-only and BOTH responses contain identical protection objects;
3. run-scoped operation omission cannot null latest incremental verification;
4. requested Run UUID never becomes producer fallback;
5. top-level aliases equal their typed-envelope source;
6. malformed/incomplete READY protection is rejected;
7. status reads do not create, resume, or replace a scheduler worker.

### 14.6 Corrected AS-IS / TO-BE

| Area | AS-IS after minimum fix | Required TO-BE |
|---|---|---|
| producer | cycle owner corrected | owner plus complete authority envelope |
| run query | finite Run still controls flat response | finite Run controls operation only |
| metrics | operation omission becomes null authority | latest cycle metrics always Plan-scoped |
| scheduler error | hidden by stale operation/cache | current protection error always emitted |
| rollout | v2 optional follow-up | v2 mandatory with bounded dual-query fallback |
