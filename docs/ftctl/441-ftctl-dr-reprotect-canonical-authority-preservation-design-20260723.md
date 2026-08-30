# FTCTL DR Reprotect Canonical Authority Preservation Design

> 2026-08-03 latest contract:
> [446-ftctl-dr-transition-preflight-v2-and-release-tombstone-contract-design-20260803.md](446-ftctl-dr-transition-preflight-v2-and-release-tombstone-contract-design-20260803.md)
> adds the strict v2 preflight envelope, mixed-version capability gate, and
> authority-preserving release tombstone. Document 446 wins on conflict.

> 2026-07-31 addendum: Reprotect keeps TARGET production authority and SOURCE
> production isolation. It uses document 444 read-only preflight and never
> depends on a standalone fence-clear action.

- Date: 2026-07-23
- Status: code-level design; live read-only preflight verified
- Scope: `bin/ablestack_vm_ftctl.sh`, `lib/ftctl/dr_runtime.sh`,
  `lib/ftctl/dr_scheduler.sh`, Agent command transport, and FTCTL self-tests
- Cloud normative design:
  `ablestack-cloud/docs/ftctl/570-cross-hypervisor-dr-reprotect-canonical-authority-preservation-design-20260723.md`

## 1. Purpose

Reprotect must start reverse protection while the Cloud-managed target VM owns
service authority. Starting a finite asynchronous operation must never erase
the authority established by `dr-cutover-commit`.

This design separates three state classes:

1. Plan authority: which side may serve production I/O.
2. Operation state: the progress and result of one Run.
3. Replication state: checkpoint, scheduler, and reverse data-path state.

`status.state` is a projection for polling. It is not an authority store.

## 2. Verified failure

The failed Windows reprotect used:

- Plan `2514a846-64a2-4bc7-ba88-38a874410782`;
- Run `3448788d-ff01-47bc-a4a3-368e6d9e764b`;
- Cloud active side `TARGET`;
- committed cutover generation `1`;
- durable checkpoint sequence `439`;
- target VM id `256`.

Read-only preflight found:

| Source | Value |
|---|---|
| Cloud Plan | `ERROR`, `active_side=TARGET` |
| Cloud cutover session | `PROMOTED`, `POWERED_ON`, generation `1`, checkpoint `439` |
| saved FTCTL profile | `activeSide=TARGET` |
| `failovers/active.json` | `FAILED_OVER`, `activeSide=TARGET`, `PROMOTED`, generation `1` |
| REPROTECT Run status | `active_side=""`, `target_materialized=false`, checkpoint empty |
| terminal error | `DR_REPROTECT_REQUIRES_TARGET_ACTIVE` |

The engine accepted the action asynchronously, but no reverse checkpoint was
created.

## 3. Root cause

`ftctl_dr_runtime_action()` currently executes this order:

1. create a new Run with `ftctl_dr_runtime_write_state()`;
2. copy the new Run to Plan `status.state`;
3. start a background worker;
4. let `ftctl_dr_runtime_reprotect_worker()` read eligibility from the copied
   `status.state`.

The new Run contains only action/progress fields. The copy in step 2 destroys
the prior `active_side`, target promotion, target power, materialization, and
checkpoint fields. The worker therefore rejects a valid TARGET-authority Plan.

This is a time-of-check/time-of-use defect. Reading the saved profile only for
disk mappings does not restore the lost authority.

## 4. Invariants

1. `status.state` must never be the only authority source.
2. A Run may add transient fields but cannot overwrite Plan authority.
3. Reprotect requires a committed TARGET authority generation.
4. Cloud command authority is an expected-value assertion, not a unilateral
   local promotion.
5. Failed reprotect leaves TARGET authority and the serving target VM intact.
6. Reverse provider capability is validated before any reverse checkpoint or
   profile promotion.
7. A worker receives one immutable authority snapshot. It does not re-read a
   mutable global status after asynchronous handoff.

## 5. Canonical local authority

Add:

```text
<plan-dir>/authority.json
```

Schema:

```json
{
  "version": 1,
  "planUuid": "...",
  "activeSide": "TARGET",
  "authorityGeneration": 1,
  "cutoverSessionId": "...",
  "checkpointSequence": 439,
  "targetVmId": "256",
  "targetExternalRef": "...",
  "targetMaterialized": true,
  "targetPowerState": "POWERED_ON",
  "targetPromotionState": "PROMOTED",
  "bootValidationState": "POWER_STATE_VALIDATED",
  "sourceFenceState": "FENCED",
  "sourcePowerState": "POWERED_OFF",
  "updatedAt": "..."
}
```

`dr-cutover-commit` writes the cutover session and `authority.json` atomically.
An equal generation is idempotent. A lower generation fails. A higher
generation must match the same committed checkpoint and target identity.

For existing Plans without `authority.json`,
`ftctl_dr_runtime_resolve_authority()` backfills in this order:

1. `failovers/active.json` with a committed Cloud generation;
2. an active reprotect or failback session;
3. saved profile `activeSide` plus matching target identity;
4. legacy Plan status only when all required fields are present.

The resolver writes the backfilled `authority.json` only after all cross-field
checks pass.

## 6. Reprotect authority contract

Cloud sends a non-secret authority document through Agent:

```json
{
  "contractVersion": "2026-07-23",
  "planUuid": "...",
  "runUuid": "...",
  "expectedActiveSide": "TARGET",
  "authorityGeneration": 1,
  "cutoverSessionId": "...",
  "checkpointSequence": 439,
  "targetVmId": "256",
  "targetExternalRef": "...",
  "targetPowerState": "POWERED_ON",
  "targetMaterialized": true,
  "targetPromotionState": "PROMOTED",
  "bootValidationState": "POWER_STATE_VALIDATED"
}
```

The Agent writes the document to a temporary `0600` file and invokes:

```text
ablestack_vm_ftctl dr-reprotect \
  --plan <plan> \
  --run <run> \
  --authority-spec-json <path> \
  --profile-json <path> \
  --wait=false \
  --json
```

Add `CLI_AUTHORITY_SPEC_JSON` and preserve it when spawning the background
worker. The worker command must receive the persisted authority file, not the
Agent temporary path.

## 7. Runtime code structure

### 7.1 New helpers

Add to `lib/ftctl/dr_runtime.sh`:

```text
ftctl_dr_runtime_authority_path
ftctl_dr_runtime_validate_authority_spec
ftctl_dr_runtime_resolve_authority
ftctl_dr_runtime_begin_operation
ftctl_dr_runtime_publish_operation
ftctl_dr_runtime_restore_authority_projection
```

`ftctl_dr_runtime_begin_operation()` executes under the Plan lock:

1. resolve the canonical authority;
2. validate the Cloud expected generation, session, checkpoint, and target;
3. create the Run state;
4. copy a whitelist of authority fields into the Run operation envelope;
5. atomically publish the Run projection to `status.state`;
6. persist the authority-spec path for the background worker.

The preserved whitelist is:

```text
active_side
cloud_authority_generation
cloud_cutover_session_id
checkpoint_sequence
target_vm_id
target_external_ref
target_materialized
target_power_state
target_promotion_state
boot_validation_state
source_fence_state
source_power_state
```

Transient fields such as action, step, progress, worker PID, retry, lock, and
error are never copied into `authority.json`.

### 7.2 Worker eligibility

Change `ftctl_dr_runtime_reprotect_worker()` to accept the immutable authority
snapshot path. It must not derive eligibility from `status_path`.

Required predicate:

```text
activeSide == TARGET
targetMaterialized == true
targetPowerState == POWERED_ON
targetPromotionState == PROMOTED
bootValidationState in {POWER_STATE_VALIDATED, QGA_VALIDATED}
authorityGeneration == expected authorityGeneration
cutoverSessionId == expected cutoverSessionId
checkpointSequence == expected checkpointSequence
source is fenced or powered off
```

Mismatch errors are typed:

```text
DR_REPROTECT_AUTHORITY_NOT_FOUND
DR_REPROTECT_AUTHORITY_GENERATION_MISMATCH
DR_REPROTECT_CUTOVER_SESSION_MISMATCH
DR_REPROTECT_CHECKPOINT_MISMATCH
DR_REPROTECT_TARGET_IDENTITY_MISMATCH
DR_REPROTECT_TARGET_NOT_MATERIALIZED
DR_REPROTECT_TARGET_NOT_RUNNING
DR_REPROTECT_SOURCE_NOT_ISOLATED
```

### 7.3 Reverse provider preflight

Before `ftctl_dr_runtime_reverse_checkpoint()`:

1. build the reverse profile without replacing the active profile;
2. require `direction=KVM_TO_VMWARE` for the verified case;
3. validate every RBD source locator with librbd/read-only open;
4. validate the VMware target VM and VMDK mapping;
5. verify that the original VMware VM is powered off/fenced;
6. verify the VMware writer capability, VDDK libraries, and target-open mode;
7. fail before data mutation when reverse write is unsupported.

Add:

```text
ftctl_dr_scheduler_preflight_cycle <profile> <mode>
```

It returns a typed capability report and performs no write. `dr-reprotect`
continues only when `reverseWriteReady=true`.

### 7.4 Terminal behavior

On failure:

- Run becomes `ERROR/FAILED`;
- the exact error message is written;
- `authority.json` remains TARGET;
- the original active failover session remains committed;
- the active profile is not replaced;
- no reverse restore point is appended.

On success:

- one reverse seed checkpoint is durable;
- the reverse profile becomes active atomically;
- `authority.json.activeSide` remains `TARGET`;
- protection mode becomes `REVERSE`;
- the new scheduler starts from the target side;
- state becomes `READY`, not SOURCE.

## 8. Status contract

`dr-status` returns both objects:

```json
{
  "authority": {
    "active_side": "TARGET",
    "generation": 1,
    "target_power_state": "POWERED_ON"
  },
  "operation": {
    "action": "dr-reprotect",
    "state": "RUNNING",
    "step": "reverse-preflight"
  }
}
```

Legacy flat fields remain for one compatibility release, but are populated
from canonical authority plus operation state. Operation failure must not blank
authority fields.

## 9. Self-tests

Add exact regression coverage:

1. commit failover with TARGET, generation 1, checkpoint 439;
2. start `dr-reprotect --wait=false`;
3. assert the delegated Run and `status.state` retain TARGET authority;
4. assert the worker does not return code 47;
5. assert stale generation and wrong session are rejected;
6. assert profile fallback backfills authority for a legacy Plan;
7. assert failed reverse preflight preserves active profile and authority;
8. assert successful reverse seed promotes the reverse profile only after a
   durable checkpoint;
9. assert `dr-status` reports authority and operation independently;
10. repeat the preservation test for failback and sync recovery.

## 10. AS-IS / TO-BE

| Area | AS-IS | TO-BE |
|---|---|---|
| Authority store | mutable `status.state` | atomic Plan `authority.json` |
| Async start | new Run overwrites Plan fields | authority snapshot is embedded in the operation envelope |
| Worker input | re-reads global status | receives one immutable authority snapshot |
| Reprotect gate | active side or state only | generation, session, checkpoint, target, source isolation |
| Reverse preflight | profile build followed by cycle | non-mutating provider capability and target-open gate |
| Failure | status loses TARGET fields | operation fails, authority and serving VM remain intact |
| Success | reverse profile may replace early | replace only after durable reverse seed |
| Status | authority and progress mixed | separate authority and operation projections |

## 11. 2026-08-01 Bidirectional Data-Plane Correction

Canonical authority preservation is necessary but not sufficient for
Reprotect. A reversed profile must not be promoted merely because the endpoint
roles were swapped. For `KVM_TO_VMWARE`, promotion additionally requires all of
the following durable evidence:

1. a KVM-side baseline and change-tracker generation;
2. a committed KVM extent set read from that tracker;
3. a VDDK write transaction into the VMware staging disks;
4. reverse guest-compatibility preparation and isolated boot validation; and
5. a checkpoint owned by the actual Reprotect Run.

The current forward VMware mover and its global `vmware-disks.json` must never
be reused as reverse-transfer proof. The normative data-plane design is
[445-ftctl-dr-bidirectional-incremental-replication-and-reverse-guest-compatibility-design-20260801.md](445-ftctl-dr-bidirectional-incremental-replication-and-reverse-guest-compatibility-design-20260801.md).

## 12. 2026-08-06 Forward Target Locator Reuse Addendum

After Failback returns authority to VMware, the resumed `VMWARE_TO_KVM` path
must reuse the same canonical ABLESTACK target locator used by initial
protection. A missing forward target map may not fall back to a bare
`targetDiskRef`, and an allocated scheduler sequence is not proof that
protection resumed. Document 454 is normative for direction-scoped map roles,
RBD sync/runtime locator separation, atomic map regeneration, and the first
durable post-Failback forward-checkpoint gate.

## 13. 2026-08-23 REPROTECT Terminal Publication Addendum

A successful reverse checkpoint is not complete merely because the data worker
returns `reprotect-ready`. Before Cloud may terminalize the accepted Run, FTCTL
must atomically publish the Run terminal journal and project all of the
following fields:

- `worker_state=TERMINAL_PUBLISHED`
- `terminal_source=ENGINE_TERMINAL`
- `terminal_authoritative=true`
- `runtime_endpoints_drained=true`
- `control_request_run_uuid=<REPROTECT Run UUID>`

The data path is unchanged. Terminal publication occurs only after the reverse
manifest and checkpoint are durable. If an older package completed that data
path without publishing its terminal journal, `dr-status --run` may repair only
a `READY / reprotect-ready / 100%` Run with no error and with both durable files
present. This read repair must not restart or repeat the reverse transfer.

## 14. 2026-08-31 Continuous reverse protection barrier

A durable reverse seed is necessary but is not sufficient to declare a TARGET
authority protected. Before publishing a successful Reprotect terminal, FTCTL
promotes the reverse profile, creates a distinct scheduler-owner Run, starts
the continuous reverse scheduler, and verifies its lease ownership and control
ACK. The accepted Reprotect Run remains the finite Cloud operation; the new
scheduler-owner Run owns subsequent reverse incremental Cycles.

If the reverse scheduler does not reach an owned `RUNNING / HEALTHY` state,
Reprotect terminates with `DR_REPROTECT_SCHEDULER_START_FAILED`. TARGET remains
the serving authority and no VM, storage, or network resource is mutated. This
prevents a one-time reverse seed from being presented as ongoing protection.

Regression coverage is provided by
`tests/ftctl_dr_reprotect_terminal_smoke.sh`.

### 14.1 systemd asynchronous ownership publication

The systemd scheduler launcher uses `systemctl start --no-block`. It does not
publish the legacy Run-specific PID file before returning; the service writes
the canonical Plan-owned `active.pid`, lease, and control ACK after acquiring
ownership. Therefore a missing Run PID is an immediate failure only for the
shell-owned background launcher. The systemd path must wait for the canonical
ownership barrier and may declare success only when all of these agree:

- the Plan scheduler session and lease epoch;
- `active.pid` process identity and start ticks;
- the requested control generation and `RUNNING` ACK;
- the scheduler-owner Run UUID.

This rule applies to every provider pair because scheduler ownership is a
shared control-plane contract; it does not change VMware, RBD, or qcow2 data
movement. `tests/ftctl_dr_systemd_async_start_smoke.sh` guards the race where
systemd has accepted the start but the legacy Run PID is intentionally absent.
## 14.2 Idempotent retry after a live reverse scheduler (2026-08-31)

An `ABLESTACK_TO_ABLESTACK` Reprotect retry may arrive after the previous Run
created a durable reverse baseline and started continuous reverse protection,
but before Cloud accepted its terminal projection. Re-running the reverse full
seed in this state is unnecessary and extends the recovery window.

FTCTL may adopt existing protection only when the current profile belongs to
the same Plan, is `KVM_TO_KVM`, has `activeSide=TARGET`, the active Reprotect
session is `READY`, and its reverse profile still exists. The canonical
scheduler lease must be live, its RUNNING ACK must be owner-matched, and the
latest completed sequence must be at or beyond both the session and Reprotect
baseline sequences with existing manifest/checkpoint files.

The retry hydrates its Run from that latest durable Cycle, marks
`reprotect_idempotent_adopted=true`, rotates scheduler ownership through the
normal activation and ACK barrier, and writes a fresh authoritative success
terminal. Missing evidence falls back to the unchanged full-seed path. This is
deliberately limited to ABLESTACK-to-ABLESTACK so VMware mover behavior and the
first Reprotect attempt retain their validated contracts.

## 14.3 Reprotect scheduler authority inheritance (2026-08-31)

The reverse scheduler created after Reprotect is a new process owner, not a new
Cloud authority owner. Its state inherits the immutable cutover generation,
sequence floor, cutover session, target power/promotion, and source isolation
fields from the accepted Reprotect Run. Scheduler Cycle publication preserves
these fields.

For already deployed partial Reprotect results, transition preflight may read
the same Plan's `READY/TARGET` active Reprotect session and immutable authority
snapshot when the live scheduler is `RUNNING/HEALTHY`, owner-matched, and
protected. This compatibility recovery is read-only and accepts only an exact
Cloud generation match. It does not weaken authority validation or change the
VMware-to-RBD path.

The canonical Plan profile keeps its configured source-to-target orientation;
Reprotect must not rewrite that profile merely to express runtime authority.
Idempotent adoption therefore validates `TARGET` authority from the accepted
Reprotect Run state, while provider pair, direction, and Plan identity remain
profile-scoped. This prevents a retry from starting a redundant full reverse
seed after a healthy reverse scheduler has already advanced durable cycles.
