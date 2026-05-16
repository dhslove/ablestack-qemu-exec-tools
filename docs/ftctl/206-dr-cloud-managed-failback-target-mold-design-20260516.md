# 206. DR Cloud-Managed Failback Target Mold Design

Date: 2026-05-16

## 1. Purpose

This document defines the Cloud-managed DR failback model when the failback target Mold may be different from both the original primary Mold and the current disaster-recovery Mold.

The immediate DR-WIN failure showed a protection stuck at:

```text
mode=dr
protection_state=failing_back
transport_state=reverse_sync_ready
active_side=secondary
fencing_state=clear
```

qemu FTCTL had completed reverse sync and reported 100 percent ready, but Cloud did not run the follow-up cutback. The direct code cause was that the Cloud-managed failback monitor accepted only `mode=ha`. The broader design gap is that DR failback was still modeled as returning to the original primary Mold. That is not valid for disaster recovery.

In DR, the original primary Mold may be unavailable, rebuilt, replaced, or intentionally bypassed. Failback must therefore accept an explicit target Mold at failback time.

## 2. Related Designs

This document extends and supersedes conflicting failback wording in:

- [201. DR Remote Mold Cloud-Managed Resource Ownership Design](201-dr-remote-mold-cloud-managed-resource-ownership-design-20260514.md)
- [202. Cloud-Managed HA/DR Automatic Fencing qemu Contract Design](202-cloud-managed-ha-dr-automatic-fencing-qemu-contract-design-20260514.md)
- [205. DR Fence Clear Re-arm And SSH Key Binding Design](205-dr-fence-clear-rearm-ssh-key-binding-design-20260515.md)

If an earlier document implies that Cloud-managed DR failback must return to the original source Mold or may use local secondary VM database IDs for remote-Mold DR cutback, this document supersedes that interpretation.

## 3. Non-Negotiable Principles

- DR failback always has an explicit failback target Mold context.
- The failback target Mold may be the current Mold, the original primary Mold, or a newly installed Mold.
- Cloud owns VM, volume, network, storage, host placement, and lifecycle APIs.
- Mold Agent delivers explicit FTCTL commands and returns qemu FTCTL status, logs, events, and command results.
- qemu FTCTL owns blockcopy, reverse sync, remote-NBD export handling, finalize, reprotect, and other data-plane actions requested by Cloud.
- qemu FTCTL must not create, define, start, stop, delete, attach, detach, resize, or format Cloud-managed VMs or volumes.
- Remote or target Mold API keys and secret keys are transient operator inputs. They must not be persisted in Cloud DB, VM details, qemu profiles, host files, or logs.
- Already validated HA Cloud-managed behavior must not be regressed.

## 4. Failback Target Mold Types

### 4.1 Original Primary Mold

The original primary Mold is still available and continues to own the original primary VM and volumes.

Cloud behavior:

- Reuse the existing primary VM and source-side volumes when they are intact.
- Start the existing primary VM only after qemu finalize has completed.
- Preserve existing local Cloud-managed HA failback behavior where applicable.

qemu behavior:

- Reverse-sync data from the active DR side into the existing Cloud-created primary volumes.
- Finalize and reprotect only when Cloud requests it.

### 4.2 Current Mold

The failback target is managed by the same Mold service that receives the failback request, but it may be a different site, zone, host, network, or storage pool.

Cloud behavior:

- Select target host, storage, and network from the current Mold.
- Create a new target primary VM and target primary volumes if the original primary VM cannot be reused.
- Store only current Mold local IDs for resources created in the current Mold.

qemu behavior:

- Use explicit Cloud-created disk maps.
- Do not assume the target host is the original primary host.

### 4.3 New Primary Mold

The original primary Mold is not available or is no longer trusted. The operator supplies a new Mold at failback time.

Cloud behavior:

- Validate the new Mold with transient API credentials.
- Query target zone, host, storage pool, network, service offering, and disk offering from the new Mold.
- Ask the new Mold to create a stopped target primary VM and target primary volumes.
- Persist only non-secret external identities in the current control context.
- Transfer the post-failback protection authority to the new Mold after successful reprotect, or leave a documented handoff record if full transfer is implemented later.

qemu behavior:

- Treat the new Mold target volumes as Cloud-created paths.
- Reverse-sync from the active DR replica into those target paths.
- Reprotect using the new target primary as the primary side after Cloud lifecycle work has completed.

## 5. Logical Identity Model

DR failback must not use one VM UUID or one local DB ID as the entire identity.

Track these identities separately:

- `logicalProtectedVmUuid`: stable logical VM identity for the protected workload.
- `currentActiveVmUuid`: VM currently running on the DR side.
- `targetPrimaryVmUuid`: VM that will become primary after failback.
- `sourceProtectionUuid`: source-side or current-controller protection row.
- `targetProtectionUuid`: target-side protection row after transfer or reprotect.
- `failbackSessionUuid`: one cross-Mold failback operation.

For remote or new Mold resources, store external UUIDs, names, and instance names. Do not store them as local numeric `secondary_vm_id` or `secondary_volume_id`.

## 6. UI Contract

For DR Cloud-managed failback, the UI must open a failback target dialog.

The dialog collects:

- target Mold type:
  - current Mold
  - original primary Mold
  - new Mold
- target Mold API URL when not using the current authenticated Mold.
- target Mold API key and secret key.
- target zone, if more than one valid zone is returned.
- target host.
- target storage pool.
- target network or networks.
- service offering and disk offering policy when defaults cannot be resolved.

Single-result lookup fields may be auto-selected and hidden or shown read-only to reduce noise.

UI action labels:

- `Failback` for `failed_over / failed_over / secondary / clear`.
- `Continue failback` for `failing_back / reverse_sync_ready / secondary / clear`.
- `Continue failback` for `failing_back / reverse_sync_cutback_required / secondary / clear`.

The UI must not require a cleanup/re-register cycle when reverse sync is already ready.

## 7. Backend State Machine

### 7.1 Start Failback

Input state:

```text
active_side=secondary
protection_state=failed_over
transport_state=failed_over
fencing_state=clear
```

Backend sequence:

1. Resolve and validate the failback target Mold context.
2. Provision or validate target primary VM and target volumes through the target Mold.
3. Build explicit disk maps for qemu.
4. Send `FAILBACK_SYNC` to the correct qemu FTCTL execution host.
5. Persist non-secret failback session metadata.

### 7.2 Continue Failback After Reverse Sync

Input state:

```text
active_side=secondary
protection_state=failing_back
transport_state=reverse_sync_ready | reverse_sync_cutback_required
fencing_state=clear
```

Backend sequence:

1. Re-resolve the failback target Mold context.
2. If target credentials are unavailable or expired, keep the state and ask the UI to collect credentials again.
3. Stop the current active DR replica VM through its owning Mold.
4. Send `FAILBACK_FINALIZE` to qemu FTCTL.
5. Start the target primary VM through the target Mold.
6. Send `FAILBACK_REPROTECT` to qemu FTCTL.
7. Update the protection state to `protected / mirroring / primary / clear`.
8. Mark the old active DR resources as standby, transferred, or cleanup candidates according to the selected policy.

### 7.3 Failure Handling

- If target Mold credentials are missing, expired, or invalid, do not mark qemu reverse sync as failed.
- Preserve `reverse_sync_ready` or transition to `reverse_sync_cutback_required`.
- Allow the operator to run `Continue failback` with fresh target Mold credentials.
- Only mark `error / failback_failed` when a Cloud-owned lifecycle action or qemu finalization/reprotect action actually fails.

## 8. Backend Implementation Boundaries

Required backend changes:

- Expand Cloud-managed failback candidate selection from HA-only to HA and DR.
- Split failback continuation by mode and target Mold type:
  - HA/local Cloud path.
  - DR current/original Mold path.
  - DR remote/new Mold path.
- Do not call local `resolveSecondaryVmForManualFailover()` for DR remote/new Mold cutback.
- Do not call local NIC DAO handoff for DR remote/new Mold VM pairs. Local NIC handoff is valid only when both VMs are in the same Mold DB.
- Add remote/new Mold VM stop, start, and job polling helpers.
- Add target primary provisioning or validation helpers.
- Keep remote/new Mold credentials request-scoped or in a short-lived in-memory failback context only.

The current stuck-row bug is fixed by two changes:

1. `isCloudManagedFailbackCandidate()` must accept `mode=dr`.
2. `continueCloudManagedFailbackAfterReverseSync()` must route DR remote/new Mold to the remote/new target cutback path instead of the HA local-secondary path.

## 9. qemu FTCTL Contract

qemu FTCTL must support these Cloud-requested actions:

- prepare reverse-NBD/export paths on the active DR side.
- reverse-sync into explicit Cloud-created target paths.
- report reverse progress and `reverse_sync_ready`.
- finalize after Cloud has stopped the active DR replica VM.
- reprotect after Cloud has started the target primary VM.

qemu FTCTL must not:

- choose the failback target Mold.
- create target primary VMs or volumes.
- start or stop Cloud-managed VMs.
- store target Mold credentials.
- infer new Mold transfer policy from libvirt state.

## 10. Credential Handling

Credentials are accepted at failback time because DR assumes disaster and replacement-site scenarios.

Allowed:

- use API URL, API key, and secret key to list target resources.
- use credentials to create or validate target primary resources.
- use credentials to stop/start VMs during the same failback request.
- keep credentials in a bounded in-memory context while an async cutback is actively running.

Forbidden:

- persist API key or secret key in VM details.
- write API key or secret key into qemu profiles.
- include API key, secret key, or signed URLs in events, logs, or error text.
- assume registration-time remote Mold credentials are still valid at failback time.

## 11. Existing Stuck State Recovery

A protection already stuck at:

```text
failing_back / reverse_sync_ready / secondary / clear
```

is recoverable without cleanup when:

- reverse progress is 100 percent and ready.
- active DR VM is running.
- target primary volumes exist and match the failback disk map.
- qemu status still reports a healthy failback session.

After implementation, the UI must expose `Continue failback`, collect target Mold context, and run the cutback stage from the existing state.

## 12. Verification Plan

Unit and component checks:

- HA Cloud-managed failback candidate behavior remains unchanged.
- DR Cloud-managed failback candidate includes `mode=dr`.
- DR remote/new Mold failback never uses local secondary numeric DB IDs as the remote VM identity.
- missing target credentials results in a resumable `reverse_sync_ready` or `reverse_sync_cutback_required` state.
- API key and secret key are not persisted or logged.

Runtime checks:

- Current-Mold DR failback can start and continue.
- Original-primary-Mold DR failback can reuse the original primary VM when available.
- New-Mold DR failback can provision a target primary VM and continue to cutback.
- A stuck `reverse_sync_ready` DR row can continue without cleanup.
- Remote active replica VM is stopped through its owning Mold.
- Target primary VM is started through the target Mold.
- Final state is `protected / mirroring / primary / clear`.

Regression checks:

- HA failback still follows the validated local Cloud-managed path.
- DR registration still follows document 201 resource ownership.
- Fence clear still follows document 205 and does not auto-rearm through qemu.
