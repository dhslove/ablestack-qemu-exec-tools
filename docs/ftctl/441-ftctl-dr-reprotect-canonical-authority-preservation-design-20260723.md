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
