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
