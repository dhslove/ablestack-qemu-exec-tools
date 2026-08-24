# DR Final Checkpoint Runtime Path Resolution

## Scope

This change closes the terminal consistency gap observed after a successful
ABLESTACK RBD-to-RBD UEFI failover. It does not alter target VM creation,
firmware mapping, VMware inventory, or the validated replication data path.

## Root Cause

The final checkpoint was durable at sequence 5 and the target VM was already
running with UEFI firmware. The failover Run still selected sequence 4 because
the in-flight repair could not locate `restore-points.jsonl`.

During source quiesce, the Plan-level `status.state` can legitimately be a
pause projection without `restore_points_path`. The `dr-cutover-commit` CLI
context also does not always load the scheduler helper. The resolver therefore
returned an empty path and rejected otherwise complete final-checkpoint
evidence.

## Resolution Contract

`ftctl_dr_runtime_default_restore_points_path()` resolves in this order:

1. an explicit `restore_points_path` in the supplied state file;
2. `ftctl_dr_scheduler_restore_points_path()` when that helper is loaded;
3. the canonical Plan runtime path returned by
   `ftctl_dr_runtime_plan_dir(plan)/restore-points.jsonl`.

The third path is deterministic and Plan-scoped. It is only used to locate
evidence. Final checkpoint repair still requires exact Plan, Run, sequence,
`failover-final`, `TARGET_READY`, `LOCAL_DURABLE`, verified target writes, and
drained NBD endpoints before any selector is changed.

## Verification

The final checkpoint smoke test must cover the production shape where both the
status field and scheduler helper are unavailable. Baseline action-contract,
remote RBD, release tombstone, and reprotect terminal suites remain release
gates.

## AS-IS / TO-BE

| Area | AS-IS | TO-BE |
| --- | --- | --- |
| Runtime path | Empty when pause status omits the field | Canonical Plan path is the final fallback |
| Cutover | Valid sequence 5 rejected against stale sequence 4 | Exact durable final checkpoint repairs the selector |
| VM boot | UEFI target is already healthy but Run stays open | UEFI boot evidence and terminal state converge |
| Regression scope | Temptation to weaken checkpoint validation | Validation remains strict; only path discovery changes |
