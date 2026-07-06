# FT sync lock retry and reconcile lock scope design

## Background

During FT validation for a cloud-managed X-COLO VM, protection registration created the standby VM and volumes but failed before data transfer started. The Cloud async job failed while sending FTCTL `config` sync commands:

```text
{"command":"config","result":"locked","lock_file":"/run/ablestack-vm-ftctl/lock","holder_command":"reconcile","exit_code":20,"retryable":true}
```

The failure was transient. The lock holder was the periodic FTCTL `reconcile` timer, and no stale lock remained after the job failed.

## Design Principles

- Cloud owns VM, volume, and lifecycle provisioning for cloud-managed FT/HA/DR.
- qemu FTCTL owns runtime replication and failure handling.
- Periodic reconcile must not globally block unrelated Cloud-driven provisioning sync.
- A retryable FTCTL lock result is not a terminal protection failure.
- Existing HA/DR behavior must not be regressed while FT narrows lock contention.

## qemu FTCTL Changes

- `reconcile` no longer takes the top-level command lock.
- Reconcile continues to take a VM-specific lock before touching each VM state/profile.
- `reconcile --vm <name>` also uses the VM-specific lock, matching the multi-VM timer path.
- If a VM-specific reconcile lock cannot be acquired, reconcile records a skip event and exits successfully because the next timer tick can converge the state.

## Cloud Contract

Cloud must treat FTCTL sync commands the same way it already treats runtime actions when FTCTL reports a retryable lock:

- detect `exit_code=20`, `ftctlResult=locked`, or JSON output containing `"result":"locked"`;
- retry the same sync command for the configured lock retry window;
- fail only if the command remains locked beyond the retry window or returns a non-retryable error.

## Expected Result

Protection registration should not fail only because the FTCTL timer reconciled at the same moment. The steady-state path is:

1. Cloud creates the standby VM and volumes.
2. Cloud sends cluster/profile sync to the local host.
3. If reconcile is briefly holding the VM lock, Cloud retries sync.
4. qemu receives a consistent profile and starts the X-COLO runtime conversion.

## Validation

- qemu shell syntax check must pass for changed scripts.
- Cloud changed-module build must pass.
- A failed partial FT registration must be cleaned before retesting.
- Retest should verify that no active protection row remains in error and that X-COLO transfer starts after protection registration.

## 2026-07-06 DR runtime extension

The same retry contract applies to Cross Hypervisor DR runtime commands.

Observed DR lock example:

```json
{
  "command": "dr-sync-start",
  "result": "locked",
  "lock_file": "/run/ablestack-vm-ftctl/lock",
  "holder_pid": "3981802",
  "holder_command": "dr-sync-pause",
  "holder_age_sec": "14",
  "exit_code": 20,
  "retryable": true,
  "retry_after_sec": 2
}
```

Required behavior:

- `dr-sync-start` blocked by `dr-sync-pause` is engine busy, not a completed sync failure.
- Cloud must map this response to a retryable state such as `DR_ENGINE_BUSY_RETRYABLE`.
- The plan must not remain `SYNCING` unless the DR runtime accepted the sync run.
- A terminal failure must close all open run steps; stale `QUEUED` or `RUNNING` steps must not remain beside the final failed step.
- UI must show a user-level message such as "previous pause operation is still finishing" and keep the raw JSON only in the detail view.

`dr-status` is different from action commands. It must be a lock-free, bounded, read-only command:

- no global FTCTL lock acquisition;
- no background worker or scheduler start;
- no remote Mold, vCenter, qemu, libvirt, or blockjob probe;
- only read profile/status/run state files and a bounded event tail;
- return a timeout JSON such as `DR_STATUS_TIMEOUT` instead of spinning indefinitely.

Acceptance test:

1. Start or simulate `dr-sync-pause` holding the FTCTL lock.
2. Run `ablestack_vm_ftctl dr-sync-start --plan <plan> --run <run> --json`.
3. Verify `result=locked`, `retryable=true`, and `retry_after_sec` are present.
4. Run `ablestack_vm_ftctl dr-status --plan <plan> --json` repeatedly.
5. Verify every status command returns within the configured status timeout and leaves no orphan process.

## 2026-07-06 DR async worker self-lock extension

Observed additional DR failure:

```json
{"command":"dr-sync-start","result":"locked","lock_file":"/run/ablestack-vm-ftctl/lock","holder_command":"dr-sync-start","holder_age_sec":"0","exit_code":20,"retryable":true,"retry_after_sec":2}
```

This is not a user-visible target readiness failure by itself. It means the async parent accepted the run, then the background worker re-entered the same top-level `dr-sync-start` command and hit the global lock before doing real work.

Required ftctl changes:

- Split async parent commands from worker commands such as `dr-sync-worker`.
- Use the global lock only for short profile/run admission critical sections.
- Use a plan/run scoped worker lock for long DR worker execution.
- Persist worker admission state in the run and status files:
  - `worker_state=STARTING|RUNNING|RETRYING|FAILED|SUCCEEDED`
  - `worker_pid`
  - `worker_exit_code`
  - `retryable`
  - `retry_after_sec`
  - `holder_command`
  - `lock_scope`
- If the worker sees a retryable lock, write `worker_state=RETRYING` to `status.state` before exiting or sleeping.
- `dr-status` remains lock-free and read-only.

Required Cloud contract:

- `accepted=true` is not enough to mark a DR sync run successful.
- If status shows `worker_state=RETRYING` or `retryable=true`, Cloud must mark the run retryable and schedule retry.
- If status remains `sync-start-accepted` with no `worker_pid` or heartbeat beyond the accepted-stall threshold, Cloud must mark `DR_ENGINE_WORKER_STALLED` or retryable busy instead of leaving the run in plain `ACCEPTED`.
- Next-step readiness remains Fail until target VM, target storage, restore point, and durable checkpoint are confirmed.

## 2026-07-06 Implementation Update

Implemented the immediate self-lock recovery in the current command structure:

- The delegated parent action writes `worker_state=STARTING`, releases the global command lock, and then spawns the background worker.
- The spawned worker records `worker_state=RUNNING` when it enters the real action path and `worker_state=SUCCEEDED` or `FAILED` before it exits the startup path.
- DR command lock conflicts update the run/status files with `worker_state=RETRYING`, `retryable=true`, `retry_after_sec=2`, holder metadata, and `error_code=DR_ENGINE_BUSY_RETRYABLE`.
- `dr-status` emits worker and retry metadata so Cloud can distinguish target materialization from worker admission failure.
- The longer-term `dr-sync-worker` command split remains a valid cleanup direction, but the deployed mitigation removes the observed parent/worker self-lock without changing the Cloud action API.
