# 457. FTCTL DR Failback Terminal, Late ACK, Plan Authority Convergence Design

- Date: 2026-08-11
- Status: implementation contract
- Scope: VMware to ABLESTACK Failback terminal publication and plan authority

## 1. Purpose

Successful reverse transfer is necessary, but it is not the terminal result. A
Failback Run is successful only after Cloud authority commit, scheduler ACK,
one post-failback forward checkpoint, and Cloud Run/session convergence.

The companion Cloud design is
`ablestack-cloud/docs/ftctl/603-cross-hypervisor-dr-failback-terminal-late-ack-plan-authority-convergence-design-20260811.md`.

## 2. Observed Failure

Plan `ef73f5f3-9740-4bbd-8c9a-74a972e5f19f` completed reverse incremental
transfer and restored the VMware VM. FTCTL later recorded an acknowledged
commit and completed post-failback checkpoint, but Cloud Run 160 remained
`FAILED` with `DR_FAILBACK_COMMIT_ACK_PENDING` and Failback session 18 remained
`PROTECTION_RESUMING`.

Two races caused the mismatch:

1. The reverse-transfer worker terminal journal could be exposed as
   `ENGINE_TERMINAL` while the failback lifecycle was still `COMMIT_VERIFYING`.
2. A later forward scheduler cycle copied its Run state over `status.state`,
   removing the completed failback authority fields required by Cloud.

## 3. Terminal Contract

### 3.1 Data terminal

`DATA_READY` or a terminal reverse-transfer journal means only that reverse
data is durable. It must not set `terminal_authoritative=true` while
`failback_phase` is `COMMIT_VERIFYING` or `PROTECTION_RESUMING`.

### 3.2 Lifecycle terminal

Failback is authoritative terminal only when all conditions are true:

- `active_side=SOURCE`
- `source_power_state=POWERED_ON`
- `target_power_state=POWERED_OFF`
- `engine_ack_state=ACKNOWLEDGED`
- `failback_commit_outcome=ACKNOWLEDGED`
- scheduler state is `RUNNING` and health is `HEALTHY`
- `latest_completed_checkpoint_sequence` is at least the required post-failback sequence
- active failback session state is `COMPLETED`

### 3.3 Sticky plan authority

`failbacks/active.json` is the durable failback authority sidecar. After ACK or
completion, a normal forward sync may update transfer and checkpoint fields,
but it must retain the authority fields from that sidecar. A new Failover or a
Run explicitly declaring `active_side=TARGET` takes precedence and disables
the overlay.

The retained fields are the failback session and phase, active side,
source/target power states, engine ACK, commit outcome, completion time, and
post-failback checkpoint sequence.

## 4. Implementation

`ftctl_dr_runtime_publish_status()` performs an atomic Run-to-status copy and
then applies the durable failback authority overlay. The overlay is accepted
only for `PROTECTION_RESUMING` or `COMPLETED` active sessions and is rejected
for Failover/Reprotect or target-active Runs.

Live preflight also exposed a publish-order race: a forward cycle can publish
immediately before the durable failback sidecar reaches `COMPLETED`.
`ftctl_dr_runtime_status()` therefore applies the same overlay immediately
before a plan-level status response. This is a read-repair of already durable
authority, not a new lifecycle transition, and it is not applied to a
run-specific status query.

`ftctl_dr_runtime_emit_state_json()` emits
`post_failback_checkpoint_sequence`. It also normalizes data-worker terminal
markers to non-authoritative while the Cloud lifecycle remains pending.

Repeated status publication is idempotent. The patch does not recreate
snapshots, restart transfer, or change the established RBD and VDDK data paths.

## 5. Verification

Automated FTCTL tests must prove:

1. a completed active failback survives a subsequent forward status publish;
2. a plan-level status read repairs the forward-publish/failback-complete race;
3. pending commit state cannot be authoritative terminal even with a data-worker terminal journal;
4. the post-failback checkpoint sequence is emitted;
5. existing reverse incremental and baseline tests remain green.

Runtime PASS requires one Failover to Failback cycle where VMware is powered
on, the ABLESTACK serving VM is powered off, reverse transfer is incremental,
FTCTL is `READY/SOURCE`, and Cloud Run, Failback session, Plan, and replica all
share the same successful terminal outcome.

## 6. AS-IS / TO-BE

| Area | AS-IS | TO-BE |
|---|---|---|
| Worker terminal | Reverse data terminal may look lifecycle-terminal | Pending commit/resume is explicitly non-terminal |
| Plan authority | Forward Run copy removes failback authority fields | Durable active failback fields survive normal forward publication |
| Publish-order race | Sidecar completion after publish waits for another write | Plan-level status read immediately repairs the projection |
| Sequence evidence | Post-failback sequence exists only in sidecar | Sequence is emitted in plan authority JSON |
| Cloud convergence | Late ACK can leave Run/session failed or pending | Cloud receives durable evidence and converges all records |
| PASS decision | VM and bytes can look successful independently | VM, bytes, FTCTL, Run, session, Plan, and replica must all agree |

## 7. Reverse Evidence Owner Follow-up

Sticky lifecycle authority also needs a sticky reverse-evidence owner. The
completed Failback Run UUID precedence, legacy session fallback, and regression
test are defined in
`458-ftctl-dr-completed-failback-reverse-evidence-retention-design-20260812.md`.
