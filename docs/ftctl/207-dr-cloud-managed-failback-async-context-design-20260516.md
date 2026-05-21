# 207. DR Cloud-Managed Failback Async Context Design

Date: 2026-05-16

## 1. Purpose

This document fixes the DR-WIN failback behavior where the first failback request starts reverse sync, reverse sync reaches ready state, but Cloud does not continue the VM lifecycle cutback and the UI enables `Continue failback`.

This document applies to the source-controller failback model: the Mold receiving `failbackFtctlProtection` can still load the source-side `ftctl_protection` row and can reach the qemu FTCTL execution context for that protection. Full source Mold loss is handled by [208. DR Replica-Site Disaster Failback And Adoption Design](208-dr-replica-site-disaster-failback-and-adoption-design-20260517.md).

The observed state was:

```text
source VM dr-w22-01 / i-2-381-VM: Stopped
remote VM dr-w22-01-standby / i-2-29-VM: Running
protection_state=failing_back
transport_state=reverse_sync_ready
active_side=secondary
fencing_state=clear
```

qemu FTCTL and QMP both showed that reverse sync had completed:

```text
reverse_sync.progress 100%
reverse_sync.ready
QMP block jobs ready=true for all protected disks
```

The failure is therefore not a qemu reverse-sync failure. It is a Cloud failback orchestration gap.

## 2. Related Designs

This document extends and takes precedence over conflicting failback wording in:

- [201. DR Remote Mold Cloud-Managed Resource Ownership Design](201-dr-remote-mold-cloud-managed-resource-ownership-design-20260514.md)
- [202. Cloud-Managed HA/DR Automatic Fencing qemu Contract Design](202-cloud-managed-ha-dr-automatic-fencing-qemu-contract-design-20260514.md)
- [205. DR Fence Clear Re-arm And SSH Key Binding Design](205-dr-fence-clear-rearm-ssh-key-binding-design-20260515.md)
- [206. DR Cloud-Managed Failback Target Mold Design](206-dr-cloud-managed-failback-target-mold-design-20260516.md)
- [208. DR Replica-Site Disaster Failback And Adoption Design](208-dr-replica-site-disaster-failback-and-adoption-design-20260517.md)

Document 206 defines the source-controller target Mold capability model. Document 211 defines the operator-facing UI rule: the primary-side failback dialog does not expose a target-Mold selector for the currently implemented source-controller path. This document defines how the internal target context and remote Mold credentials survive a long-running reverse sync without being persisted.

Document 208 defines the separate replica-controller path for source Mold loss. That path uses a durable non-secret replica-site recovery session and does not rely on this source-controller in-memory context.

## 3. Root Cause

The current Cloud flow separates failback into two phases:

1. The operator submits `failbackFtctlProtection` with target/remote Mold credentials.
2. Cloud builds a request-scoped `FailbackTargetContext`.
3. Cloud sends `FAILBACK_SYNC` to qemu FTCTL and returns.
4. qemu FTCTL runs reverse sync asynchronously.
5. The Cloud failback monitor later detects `reverse_sync_ready`.
6. The monitor calls the cutback continuation with no `FailbackTargetContext`.

For remote-Mold DR, the cutback stage must stop the active remote replica VM through its owning Mold before qemu `FAILBACK_FINALIZE`.

Because remote Mold API key and secret are intentionally not persisted, the monitor has no credentials when reverse sync becomes ready. It correctly avoids persisting secrets, but incorrectly turns the original one-click failback into a two-click workflow.

The UI shows `Continue failback` because it sees:

```text
protection_state=failing_back
transport_state=reverse_sync_ready
active_side=secondary
fencing_state=clear
admin_state=active
```

That button must remain as a recovery fallback, but it must not be the normal path after a successful first failback request.

## 4. Design Principles

- Cloud owns Cloud-managed VM, volume, network, storage, host placement, and lifecycle APIs.
- Mold Agent only delivers explicit qemu FTCTL commands and returns qemu FTCTL status, logs, events, and command results.
- qemu FTCTL owns blockcopy, reverse sync, remote-NBD export handling, finalize, reprotect, and other Cloud-requested data-plane work.
- qemu FTCTL must not create, define, start, stop, delete, attach, detach, resize, or format Cloud-managed VMs or volumes.
- Remote Mold and target Mold API keys and secret keys must not be persisted in Cloud DB, VM details, qemu profiles, host files, durable logs, or event payloads.
- A bounded in-memory operation context is allowed while a failback operation is actively running.
- Loss of the in-memory context must be resumable through `Continue failback`; it must not mark reverse sync as failed.
- Already validated HA Cloud-managed behavior must not regress.

## 5. Target Behavior

### 5.1 Normal One-Click Failback

When the operator starts DR Cloud-managed failback and provides the required Mold context:

1. Cloud validates target and remote Mold inputs.
2. Cloud creates or validates the target primary resources according to document 206.
3. Cloud stores a short-lived in-memory failback operation context.
4. Cloud sends `FAILBACK_SYNC` to qemu FTCTL.
5. qemu FTCTL reverse-syncs into explicit Cloud-created target paths.
6. The Cloud failback monitor detects `reverse_sync_ready`.
7. Cloud retrieves the in-memory operation context.
8. Cloud stops the active DR replica VM through the owning Mold.
9. Cloud sends `FAILBACK_FINALIZE` to qemu FTCTL.
10. Cloud starts the target primary VM through the selected target Mold.
11. Cloud sends `FAILBACK_REPROTECT` to qemu FTCTL.
12. Cloud reaches `protected / mirroring / primary / clear`.

The operator should not have to click `Continue failback` in this normal path.

### 5.2 Recovery Fallback

`Continue failback` remains valid only when:

- reverse sync is already ready, and
- the in-memory operation context is missing, expired, or invalid, or
- the first failback request was interrupted after reverse sync started, or
- management service restarted during reverse sync, or
- the operator intentionally re-submits fresh target Mold information.

In that case Cloud must keep the state resumable:

```text
failing_back / reverse_sync_ready / secondary / clear
```

or:

```text
failing_back / reverse_sync_cutback_required / secondary / clear
```

Cloud must not convert a missing in-memory context into `error / failback_failed`.

## 6. In-Memory Failback Operation Context

Cloud adds a bounded in-memory context store keyed by protection id and failback session uuid.

Suggested context fields:

- protection id
- primary VM uuid and instance name
- active DR replica external uuid/name/instance name
- failback target Mold type, currently `original-primary` for the implemented primary-side source-controller UI
- remote active Mold API URL, API key, and secret key when needed to stop the active DR replica
- target Mold API URL, API key, and secret key when needed to start or validate the target primary
- non-secret target VM and volume identities
- creation timestamp
- last access timestamp
- expiry timestamp
- operation phase:
  - `sync_started`
  - `reverse_ready`
  - `cutback_running`
  - `finalized`
  - `expired`
- redacted request id or job id for troubleshooting

Secret-bearing fields are allowed only inside this memory object. They must be removed immediately when the operation reaches a terminal state.

The implementation must:

- never write API key or secret key to VM details, qemu profile files, events, management logs, or error text.
- log only redacted URL/site identity and context state.
- remove the context on success, forced release, protection removal, timeout, or management stop.
- treat context absence as a resumable condition.

## 7. Timeout And Expiry

The context TTL must be long enough for expected reverse sync duration and short enough to avoid accidental credential retention.

Recommended initial policy:

- default TTL: 2 hours.
- configurable TTL if a global configuration mechanism already exists for FTCTL operation timeouts.
- refresh the context access timestamp while the monitor observes active reverse sync progress.
- do not refresh past an absolute maximum TTL without explicit operator action.

On expiry:

1. remove secrets from memory.
2. keep non-secret failback state in Cloud DB.
3. preserve qemu reverse sync ready/progress state.
4. surface a UI message that failback can continue by re-entering target Mold credentials.

## 8. Backend State Machine

### 8.1 Start Failback

Input:

```text
active_side=secondary
protection_state=failed_over
transport_state=failed_over
fencing_state=clear
```

Backend sequence:

1. Resolve target Mold context per document 206.
2. Resolve active DR replica owning Mold context.
3. Provision or validate target primary resources.
4. Create `failbackSessionUuid`.
5. Store the in-memory operation context before sending qemu `FAILBACK_SYNC`.
6. Send `FAILBACK_SYNC`.
7. Return an action response showing failback is in progress.

If sending `FAILBACK_SYNC` fails, remove the context immediately.

### 8.2 Monitor Reverse Sync

Input:

```text
active_side=secondary
protection_state=failing_back
transport_state=reverse_syncing | reverse_sync_pending
```

Backend sequence:

1. Fetch qemu runtime status through Mold Agent.
2. Persist non-secret runtime state.
3. If reverse sync is not ready, do no lifecycle cutback.
4. If reverse sync becomes ready, load the in-memory context and continue cutback.

### 8.3 Automatic Cutback After Reverse Ready

Input:

```text
active_side=secondary
protection_state=failing_back
transport_state=reverse_sync_ready | reverse_sync_cutback_required
fencing_state=clear
```

Backend sequence:

1. Acquire a per-protection cutback lock.
2. Load the in-memory operation context.
3. If the context exists and is valid, continue automatically.
4. Stop the active DR replica VM through the Mold that owns that VM.
5. Send `FAILBACK_FINALIZE` to qemu FTCTL.
6. Start the target primary VM through the selected target Mold.
7. Send `FAILBACK_REPROTECT` to qemu FTCTL.
8. Update final Cloud state and clear the context.

If the context is missing:

- keep or set `reverse_sync_cutback_required`.
- keep `active_side=secondary`.
- keep `fencing_state=clear`.
- do not stop/start VMs.
- do not call qemu `FAILBACK_FINALIZE`.
- expose `Continue failback`.

### 8.4 Continue Failback

When the operator clicks `Continue failback`, Cloud treats the request as a fresh credential-bearing continuation:

1. Re-resolve target/remote Mold context.
2. Validate that qemu still reports reverse sync ready.
3. Recreate a short-lived in-memory context for the cutback stage.
4. Run the same cutback sequence as automatic cutback.

This is a recovery path, not the expected steady-state path.

## 9. Same-Mold And Remote-Mold Coverage

The same source-controller async model applies to all DR peer-site types when the source-side protection row is still available:

- current Mold DR
- original-primary Mold failback
- remote Mold DR
- new Mold failback

It does not apply when the source Mold is destroyed or cannot act as the controller. In that case the replica Mold must use the recovery-session model from document 208.

For same/current Mold cases, the context may contain no remote secret credentials because the current authenticated Cloud session or local service calls can own lifecycle operations. The state machine remains the same.

For remote/new Mold capability cases, the context may contain one-time API credentials for:

- stopping the active DR replica through its owning Mold.
- validating or starting the target primary through the selected target Mold.

Remote/new Mold credentials remain transient and must be absent from durable state.

The current primary-side UI supplies only remote replica Mold credentials for remote-Mold DR cutback. It must not duplicate the same operator input into `targetmold*` fields unless a future target-Mold provisioning path explicitly needs those credentials.

## 10. UI Contract

The UI keeps two labels:

- `Failback`: starts failback from `failed_over / failed_over / secondary / clear`.
- `Continue failback`: resumes cutback from `failing_back / reverse_sync_ready|reverse_sync_cutback_required / secondary / clear`.

However, after the user clicks `Failback`, the UI should expect automatic continuation if the management service keeps the in-memory context alive.

Recommended UI behavior:

- During reverse sync, show progress and a failback-in-progress state.
- When reverse sync becomes ready but no user action is needed, keep showing a blocking or in-progress failback state.
- Show `Continue failback` only when the backend response indicates `cutback_required` or credential context is missing/expired.
- If `Continue failback` is shown, require the same target/remote Mold dialog as the failback start action.

## 11. Implementation Notes

Cloud backend:

- Add a `ConcurrentMap` or equivalent managed store for failback operation contexts.
- Create the context before `FAILBACK_SYNC`.
- Let the failback monitor consume the context when reverse sync becomes ready.
- Keep the existing per-protection cutback lock.
- Split missing context from real lifecycle/qemu errors.
- Redact all credential-bearing fields in logs and exceptions.
- Clear context in `finally` for terminal states.

qemu FTCTL:

- No credential handling changes are required.
- Continue to report reverse progress and `reverse_sync_ready`.
- Continue to run only Cloud-requested data-plane actions.
- Do not receive or persist Mold API credentials.

## 12. Failure Handling

Missing or expired context:

- state remains resumable.
- UI enables `Continue failback`.
- no qemu failure is recorded.

Invalid credentials during automatic cutback:

- mark the cutback as needing operator continuation.
- preserve reverse sync ready.
- surface a redacted error.

Failure to stop the active DR replica:

- do not call qemu `FAILBACK_FINALIZE`.
- preserve reverse sync ready when safe.
- require operator correction or retry.

Failure after active DR replica stop:

- preserve precise last action and error.
- do not hide the state behind a generic reverse-sync failure.
- allow an idempotent retry where Cloud and qemu state make that safe.

## 13. Verification Plan

Unit checks:

- first DR failback request creates an in-memory context.
- context is not persisted in VM details or qemu profile material.
- monitor uses the context when reverse sync reaches ready.
- missing context leaves `reverse_sync_ready` or `reverse_sync_cutback_required` resumable.
- `Continue failback` recreates context and uses the same cutback path.
- HA Cloud-managed failback behavior remains unchanged.

Runtime checks:

- Start DR remote-Mold failback once and do not click `Continue failback`.
- Confirm qemu reverse sync reaches ready.
- Confirm Cloud automatically stops the active remote replica VM through remote Mold.
- Confirm Cloud sends `FAILBACK_FINALIZE`.
- Confirm Cloud starts the target primary VM through the selected target Mold.
- Confirm Cloud sends `FAILBACK_REPROTECT`.
- Confirm final state is `protected / mirroring / primary / clear`.

Negative checks:

- restart management during reverse sync and verify `Continue failback` becomes the recovery path.
- expire the context and verify no secret remains in memory after cleanup.
- verify no API key or secret key appears in DB, VM details, qemu profiles, host files, management logs, or qemu events.
