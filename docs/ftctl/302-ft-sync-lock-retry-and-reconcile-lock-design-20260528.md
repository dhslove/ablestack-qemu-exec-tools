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

## 2026-07-07 DR run-aware status and target driver diagnostics extension

The VMware to ABLESTACK sync test found a terminal runtime failure that Cloud did not project:

- plan: `b0522fc5-047f-4dc6-9cd7-b43a17daae45`
- run: `bdbea146-ac2d-4ab1-9e6e-6a004a5173cc`
- runtime state: `ERROR`
- runtime step: `ablestack-driver-failed`
- error code: `DR_ABLESTACK_DRIVER_FAILED`
- worker state: `FAILED`
- worker exit code: `32`

Required ftctl updates:

- `dr-status --plan <plan> --run <run> --json` must read the run state first and return terminal runtime status even when the status command itself exits successfully.
- status JSON must include `state`, `step`, `error_code`, `error_message`, `driver`, `driver_state`, `worker_state`, `worker_exit_code`, target presence flags, and checkpoint timestamps.
- ABLESTACK target preparation must persist exact sub-error codes instead of only returning exit code `32`.
- VMware source disk ids such as `2000` must not be treated as local qemu file paths for size detection. Disk size must come from VMware/VDDK metadata, Cloud guided inventory, or explicit UI target size.
- ABLESTACK RBD target storage must normalize to `targetType=rbd`; a profile with RBD storage and `targetType=file` must fail preflight.

Required Cloud contract:

- Cloud agent wrappers must pass `--run` when the latest run UUID is known.
- Backend projection must treat runtime `state=ERROR`, `worker_state=FAILED`, or non-empty `error_code` as terminal failure.
- Plan/run/step/replica/disk projection must move atomically to failure so UI cannot show `SYNCING` or `ACCEPTED` after FTCTL has failed.

The paired Cloud-side design is documented in `docs/ftctl/536-cross-hypervisor-dr-terminal-projection-and-target-driver-contract-design-20260707.md` in the `ablestack-cloud` repository.

## 2026-07-07 Serving process and source/target disk-map contract extension

The follow-up VMware to ABLESTACK sync validation found a second structural
failure mode after terminal projection had been added:

- Cloud changed classes were deployed on disk, but an old Java process still
  owned listener port `8080`.
- FTCTL runtime state reported `disk_map_path=.../vmware-disks.json` while the
  ABLESTACK target-preparation driver required the target contract in
  `ablestack-disks.json`.
- The UI/API therefore could show `SYNCING`/`ACCEPTED` even though the host run
  had already reached `ERROR` with `DR_TARGET_DISK_TYPE_INVALID`.

Required qemu/FTCTL updates:

1. Keep `vmware-disks.json` and `ablestack-disks.json` as separate first-class
   artifacts.
2. Add `source_disk_map_path`, `target_disk_map_path`, and `disk_map_role` to
   `runs/<run>.state`, `status.state`, and `dr-status --json` output.
3. For an ABLESTACK target, compatibility `disk_map_path` must point to
   `target_disk_map_path`.
4. `ftctl_dr_vmware_sync_start` must write VMware source metadata without
   overwriting the target map authority.
5. `ftctl_dr_ablestack_sync_start` must canonicalize `profile.json` into
   `ablestack-disks.json`, set it as the target map, and validate the map before
   target materialization.
6. VMware disk ids such as `2000` must be treated as source inventory refs, not
   local qemu paths. Disk size must come from Cloud guided inventory,
   VMware/VDDK metadata, or an explicit operator target-size override.
7. Missing or inconsistent target disk type, target storage, target network,
   target offering, or target disk size must fail preflight before the run is
   considered ready for the next step.

Implemented qemu/FTCTL changes:

- `dr_runtime.sh` emits source/target disk-map metadata and preserves the
  caller's `--config` path when spawning a background worker.
- Foreground self-test overrides are explicit per action, so regression tests can
  assert final state without changing production async behavior.
- `dr_vmware.sh` writes VMware source disk inventory as source metadata and uses
  ABLESTACK target disk metadata only when the target provider is ABLESTACK.
- `dr_ablestack.sh` canonicalizes target placement into the target disk-map
  contract, validates target type/storage/size before materialization, and
  returns specific target-map error codes instead of accepting an impossible
  sync run.
- `ablestack_vm_ftctl_selftest.sh` includes target placement and target disk
  offering data in ABLESTACK target profiles and verifies the missing-map case
  as an immediate, explicit preflight failure.

Required deployment validation:

- After changed-class deployment, management `mold.service` `MainPID` must match
  the PID owning listener port `8080`.
- A stale serving process is a deployment failure, not a DR runtime failure.
- DR retest must not start until the active API response exposes the latest
  runtime/effective projection fields.

The paired Cloud-side layered design is documented in
`docs/ftctl/537-cross-hypervisor-dr-serving-process-and-disk-map-contract-design-20260707.md`
in the `ablestack-cloud` repository.

## 2026-07-07 VMware source disk size and projection follow-up

The next VMware to ABLESTACK validation used plan
`05527cbe-974e-4ca8-b65e-f844cb3420e7` and run
`79f4a7b9-778b-4279-a4bd-3aa7af38ed53`. FTCTL correctly failed the run before
target materialization:

- `state=ERROR`
- `step=ablestack-target-map-invalid`
- `error_code=DR_TARGET_DISK_SIZE_UNRESOLVED`
- `worker_state=FAILED`
- `target_disk_invalid_count=1`
- `vmware-disks.json` and `ablestack-disks.json` both had disk `2000` with
  `sizeBytes=0`

Required qemu/FTCTL contract extension:

1. VMware source disks must carry a positive size before an ABLESTACK target
   map can be considered execution-ready.
2. `dr_vmware.sh` should classify missing source disk size as a source-map
   readiness problem when it can detect it before the ABLESTACK target driver.
3. `dr_ablestack.sh` must keep rejecting `VMWARE_TO_KVM` target maps with
   `sizeBytes <= 0`; this is a correct final safety gate.
4. RBD target storage should be normalized to `targetType=rbd` and canonical
   raw block target semantics before materialization.
5. `dr-status --plan --run --json` must expose the terminal error fields so
   Cloud projection can atomically fail `dr_plan`, `dr_run`, `dr_replica`, and
   `dr_replica_disk`.

The paired Cloud-side design is documented in
`docs/ftctl/538-cross-hypervisor-dr-vmware-to-kvm-disk-size-and-projection-hardening-design-20260707.md`
in the `ablestack-cloud` repository.
