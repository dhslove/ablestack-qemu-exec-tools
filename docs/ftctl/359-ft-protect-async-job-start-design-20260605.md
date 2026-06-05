# 359. FT Protect Async Job Start Design - 2026-06-05

## Problem

`registerFtctlProtection` previously sent a Cloud KVM agent `FtctlActionCommand(PROTECT)` and waited for the host wrapper to finish `ablestack_vm_ftctl protect`.

That is unsafe for FT/XCOLO. The host wrapper uses Cloud `Script`, and a timeout does not only stop waiting. It forcibly destroys the direct `ablestack_vm_ftctl` process. FT protection can legitimately run longer than the wrapper default because it may redefine the primary domain, seed RBD baseline data, start the secondary incoming side, migrate runtime state, and validate the COLO network/block graph.

The failure mode is:

1. Cloud starts a synchronous host-side `protect`.
2. The wrapper timeout expires.
3. Cloud `Script` returns `timeout` and forcibly destroys the direct ftctl process.
4. QEMU, libvirt, lock, state, and profile artifacts can be left in a partial state.

## Principle

Cloud must own Cloud resources and initiate the operation, but qemu FTCTL must own the long-running FT action and its event/state stream.

The Cloud API result for protection registration must mean "the qemu FTCTL protection job was accepted", not "FT protection is fully established".

## Design

### qemu FTCTL

Add `ablestack_vm_ftctl protect-start`.

`protect-start`:

- validates the VM profile just like `protect`;
- does not take the VM runtime lock itself;
- starts a detached background `ablestack_vm_ftctl protect` worker;
- redirects the worker output to `/var/log/ablestack-vm-ftctl/jobs/<job-id>.log`;
- records job metadata in the normal state file:
  - `protect_job_id`
  - `protect_job_pid`
  - `protect_job_state`
  - `protect_job_started_at`
  - `protect_job_log`
- returns quickly with JSON result `accepted`.

The detached worker runs the existing foreground `protect` path and therefore keeps all current XCOLO validation, events, and failure classification behavior. The worker records `protect_job_state=running`, then `done` or `failed`.

If an accepted or running job already exists for the VM and its process is alive, `protect-start` returns the existing job id instead of starting a duplicate.

### Cloud

`registerFtctlProtection` sends `FtctlActionCommand.Action.PROTECT_START` instead of `PROTECT`.

Cloud continues to:

- create or validate Cloud-managed resources;
- write VM details and protection rows;
- sync cluster/profile context to qemu FTCTL.

Cloud no longer waits for the whole FT protection workflow. It only waits for the qemu host to accept the job start request.

### UI / Status Model

The registration response is not a final protected state. UI status must continue to come from `getFtctlProtection`, `status`, and `events.log`.

Expected progression:

- `pairing` / `initializing`
- `mirroring` or FT-specific setup phases
- `protected`
- or `error` with qemu-side `last_error`

## Safety Rules

- Do not increase the synchronous Cloud wrapper timeout as the primary fix.
- Do not run long FT protect work as a direct child of Cloud `Script`.
- Do not hide qemu-side errors behind Cloud API timeout text.
- Foreground `protect` remains available for direct host debugging.

## Validation

- `registerFtctlProtection` must return before long XCOLO setup completes.
- No Cloud wrapper timeout should forcibly terminate the long protect worker.
- `status --json` must expose job metadata and qemu-side state.
- If the worker fails, the visible failure must be qemu-side `last_error`, not Cloud `timeout`.
