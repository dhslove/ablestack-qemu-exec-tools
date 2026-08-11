# 456. FTCTL DR Cutover Reverse Baseline And Terminal Convergence Design

> Follow-up: `457-ftctl-dr-failback-terminal-late-ack-plan-authority-convergence-design-20260811.md`
> defines late-ACK handling and sticky plan-authority publication after the
> post-failback checkpoint.

- Date: 2026-08-11
- Status: implementation contract
- Scope: VMware to ABLESTACK Failover, KVM to VMware Failback, scheduler terminal publication

## 1. Problem

The forward VMware CBT path completed correctly, but Failover did not create a
KVM-side baseline. The first Failback therefore selected
`FULL_REVERSE_SEED / INITIAL_REVERSE_BASELINE_MISSING` and copied the complete
virtual disk. After the required forward checkpoint completed, scheduler state
became healthy while the owner Run and status file remained
`SYNCING / protection-resuming`.

These are two independent consistency defects:

1. the reverse data path had no immutable cutover baseline;
2. the terminal state was published to scheduler state but not atomically
   projected to Run, status, commit journal, and Failback session.

## 2. Invariants

1. Final forward CBT data is durable before the reverse baseline is created.
2. The baseline is created before guest preparation or target VM power-on.
3. Every mapped RBD disk receives one read-only snapshot in the same generation.
4. `baseline.json` is replaced atomically only after all snapshots exist.
5. Old snapshots are removed only after the new baseline commit.
6. A baseline failure aborts Failover before TARGET authority is committed.
7. The first patched Failback uses `REVERSE_FINAL`, not `FULL_REVERSE_SEED`.
8. A completed post-Failback forward checkpoint terminalizes every FTCTL artifact.

## 3. Failover Baseline Algorithm

`ftctl_dr_kvm_vmware_seed_cutover_baseline(plan, run, profile, sequence)`:

1. canonicalize the forward profile into the KVM-to-VMware disk identity map;
2. validate any existing baseline and treat an identical run/generation as an
   idempotent retry;
3. create `ftctl-dr-<plan>-cutover-<sequence>-<run>-<disk>` on each RBD image;
4. write a temporary JSON document with `origin=FAILOVER_CUTOVER`,
   `state=LOCAL_DURABLE`, disk identity hash, snapshot, and generation;
5. `fsync` and atomically replace `baseline.json`;
6. remove superseded snapshots after the commit;
7. on failure, remove only snapshots created by this attempt and return a typed
   `DR_REVERSE_BASELINE_SEED_FAILED` failure.

The Failover worker inserts this stage after final forward sync and before
guest preparation. It publishes `reverse_baseline_state`,
`reverse_baseline_generation`, and `reverse_baseline_origin`.

## 4. Failback Mode Decision

```text
FAILOVER_CUTOVER baseline present + FAILBACK_FINAL + AUTO
  -> REVERSE_FINAL
  -> rbd diff from cutover snapshot
  -> VDDK extent writes only

legacy baseline absent + FAILBACK_FINAL + AUTO
  -> FULL_REVERSE_SEED
  -> compatibility path, explicitly reported
```

Acceptance requires `initial_seed_required=false`, a baseline generation equal
to the Failover cutover generation, and transfer payload bytes lower than
virtual bytes after a bounded guest write.

## 5. Terminal Convergence

When scheduler checkpoint `completed >= minimum_completed_checkpoint_sequence`
for `immediate_cycle_owner_run`, FTCTL writes:

- Run: `READY / completed / 100`, `failback_phase=COMPLETED`;
- status: `READY / target-checkpoint-ready / 100`;
- commit journal: `phase=COMPLETED`;
- Failback session: `state=COMPLETED`, completed checkpoint and timestamp;
- common evidence: `terminal_authoritative=true`,
  `terminal_source=ENGINE_TERMINAL`, `transfer_activity_state=IDLE`, and
  `immediate_cycle_pending=false`.

The operation is idempotent and is ignored unless SOURCE authority, source-on,
target-off, and engine ACK invariants all hold.

## 6. Verification

Automated tests cover cutover snapshot creation, baseline JSON, first-Failback
mode selection, and terminal convergence across all state artifacts. Live
acceptance is:

1. Failover succeeds and baseline origin is `FAILOVER_CUTOVER`;
2. write a small identifiable payload in the KVM guest;
3. Failback preflight reports `REVERSE_FINAL` and no initial seed;
4. transferred bytes are non-zero and lower than virtual bytes;
5. VMware boots with the payload;
6. FTCTL and Cloud both converge to `READY / COMPLETED`;
7. the next VMware-to-KVM CBT cycle is incremental.

## 7. AS-IS / TO-BE

| Area | AS-IS | TO-BE |
|---|---|---|
| Reverse baseline | Created by first Failback full seed | Created during Failover cutover |
| First Failback | `FULL_REVERSE_SEED` | `REVERSE_FINAL` |
| Baseline failure | Discovered after authority transition | Blocks Failover before target activation |
| Terminal state | Scheduler complete, Run/status still `SYNCING` | Run/status/journal/session terminalized together |
| Validation | Success state only | Mode, baseline lineage, bytes, boot, and next CBT verified |
