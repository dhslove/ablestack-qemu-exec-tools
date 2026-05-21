# 208. DR Replica-Site Disaster Failback And Adoption Design

Date: 2026-05-17

## 1. Purpose

Documents 206 and 207 define DR failback when a Mold that can see the source-side `ftctl_protection` row is still available to orchestrate the workflow. That is not enough for a real disaster.

If the original source Mold or source site is destroyed, the operator cannot reliably issue failback from the original Mold. In that condition, the Mold that owns the running DR replica VM must be able to control recovery.

This document adds two replica-site authority paths:

- replica-site disaster failback to a restored or newly installed target Mold.
- replica-site forced protection release/adoption when the replica VM will run long term and the source site may never return.

## 2. Related Designs

This document extends and supersedes conflicting wording in:

- [201. DR Remote Mold Cloud-Managed Resource Ownership Design](201-dr-remote-mold-cloud-managed-resource-ownership-design-20260514.md)
- [202. Cloud-Managed HA/DR Automatic Fencing qemu Contract Design](202-cloud-managed-ha-dr-automatic-fencing-qemu-contract-design-20260514.md)
- [206. DR Cloud-Managed Failback Target Mold Design](206-dr-cloud-managed-failback-target-mold-design-20260516.md)
- [207. DR Cloud-Managed Failback Async Context Design](207-dr-cloud-managed-failback-async-context-design-20260516.md)

If an earlier document says that a remote Mold standby page is always read-only or that DR failback must be initiated by the source Mold, read that statement as applying only while the source Mold remains available and authoritative. After disaster failover, the replica Mold may become the active DR controller.

The adopted-replica re-protection follow-up is [209. DR Adopted Replica Re-protection Readiness Design](209-dr-adopted-replica-reprotect-readiness-design-20260519.md).

The operator-facing action model is refined by [211. DR Failback Action UX And Controller Model Design](211-dr-failback-action-ux-controller-model-design-20260521.md). In short, replica-site `Failback` and `Adopt replica` are distinct actions, while `Release replica protection` is not shown as a duplicate top-level action in the normal replica recovery view.

## 3. Non-Negotiable Principles

- Cloud owns Cloud-managed VM, volume, network, storage, host placement, and lifecycle APIs.
- qemu FTCTL owns replication, reverse copy, NBD/export handling, finalize, reprotect, and cleanup of qemu runtime state.
- Mold Agent relays explicit qemu FTCTL commands and returns status, events, logs, and command results.
- qemu FTCTL must not create, start, stop, delete, attach, detach, resize, or format Cloud-managed VMs or volumes.
- Source, replica, and target Mold API keys and secret keys are transient operator inputs unless an approved Cloud secret-reference mechanism is introduced. They must not be written to VM details, qemu profiles, host files, or durable logs.
- A running DR replica VM must not be deleted by replica-site forced release unless the operator explicitly chooses a destructive cleanup mode.
- Already validated HA and source-controller DR behavior must not regress.

## 4. Authority Model

### 4.1 Source-Controller Path

This is the model in documents 206 and 207.

The Mold that receives the failback command can access the source-side protection row and the source VM identity. It may fail back to:

- the original primary Mold.
- the current Mold.
- a newly installed target Mold.

The controller still starts from the source-side protection record.

### 4.2 Replica-Controller Path

This is the new disaster model.

The source Mold is unavailable, untrusted, or intentionally abandoned. The running replica VM's Mold becomes the DR controller.

The replica Mold must be able to:

- identify the DR replica workload from local sanitized metadata.
- validate that the replica VM is the active side or has been adopted as active after disaster failover.
- prepare a target Mold and target primary VM/volumes for disaster failback.
- instruct the replica-side qemu FTCTL host to copy data from the active replica disks to Cloud-created target disks.
- perform forced protection release/adoption without contacting the source Mold.

## 5. Durable Replica-Site Recovery Session

The remote Mold cannot depend only on source-side `ftctl_protection` rows. During DR registration or failover, the replica Mold must persist a non-secret recovery session.

Suggested durable fields:

- `recoverySessionUuid`
- `logicalProtectedVmUuid`
- source VM UUID, display name, and instance name
- replica VM UUID, display name, and instance name
- replica host UUID/name/address snapshot
- disk label to replica volume UUID/name/path map
- original source volume UUIDs and disk labels
- backend mode, target storage scope, and transfer network endpoint metadata
- current DR role: `standby`, `active-replica`, `adopted`
- last known protection state and transport state
- fencing result/reason snapshot
- source Mold API URL as a non-secret display/lookup hint when available
- source protection UUID or external protection id when available
- timestamps for registration, failover, adoption, release, and failback attempts

Forbidden durable fields:

- API key
- secret key
- signed request
- private SSH key material unless stored through an approved encrypted key mechanism

## 6. Replica-Site Disaster Failback

### 6.1 UI Contract

When a remote Mold VM is marked as an FTCTL DR replica, the UI normally shows a projection view. After the replica is running and the source side is unavailable, the UI must offer a controlled disaster-recovery action set:

- `Failback`
- `Adopt replica as primary`

`Failback` is the replica-controller data-copy recovery path to a restored original Mold or newly installed Mold. It is not implemented by adopting the replica.

`Adopt replica as primary` keeps the current replica VM as the production workload and removes FTCTL standby semantics so it can be protected again later.

Forced protection release is an advanced recovery policy, not a duplicate top-level action beside adoption. It may be exposed inside an explicit recovery/release dialog only when the operator chooses to abandon the source relationship without using the replica as a protected production workload.

The replica-site failback dialog collects:

- target Mold type:
  - current Mold
  - restored original Mold
  - newly installed Mold
- target Mold API URL/API key/secret key when the target is not the current authenticated Mold.
- target zone, host, storage pool, and network IDs.
- service offering and disk offering choices when no safe default exists.
- optional source Mold information for best-effort reconciliation only.

Single-result lookups may be auto-selected or shown read-only. Target network selection remains mandatory when Cloud-managed VM creation needs a network.

### 6.2 Backend Sequence

Input state:

```text
replica_role=active-replica
replica_vm_state=Running
source_mold_reachable=false | unknown
```

Sequence:

1. Load the replica-site recovery session from the replica Mold.
2. Validate that the requested VM is the active DR replica or an adopted replica.
3. Resolve and validate target Mold credentials and target resource selections.
4. Ask the target Mold to create or validate a stopped target primary VM and target volumes.
5. Build an explicit disk map from active replica disks to target Cloud-created paths.
6. Ask the replica-side qemu FTCTL execution host to run disaster reverse copy into the target paths.
7. Monitor progress through qemu events/status, projected by the replica Mold.
8. Stop the active replica VM through the replica Mold when reverse copy is ready.
9. Ask qemu FTCTL to finalize the target disks.
10. Start the target primary VM through the target Mold.
11. Write a target-side protection/adoption handoff record.
12. Mark the replica-site session as `failed_back_to_target` or `reprotected`.

The source Mold is optional in this flow. If it later returns, reconciliation is best-effort and must not block the completed disaster failback.

## 7. Replica-Site Forced Protection Release And Adoption

Long disaster recovery may intentionally keep the replica VM as the production VM for days, weeks, or permanently. Operators need an exit path that does not require source Mold recovery.

### 7.1 Release Modes

`releaseFtctlDrReplicaProtection` should support these logical modes:

- `adopt`: keep the replica VM and volumes, remove FTCTL standby/replica semantics, and mark it as an independent production VM.
- `abandon-source`: close the recovery session and record that the original source protection has been abandoned.
- `cleanup-transport`: remove qemu NBD exports, locks, temporary state, profiles, and generated SSH keys for the DR session.
- `cleanup-source-best-effort`: if source Mold credentials are supplied and reachable, mark the source-side protection released or archived.

Default behavior must be non-destructive:

```text
preserveReplicaVm=true
preserveReplicaVolumes=true
abandonSource=true
cleanupTransport=true
```

### 7.2 Backend Sequence

1. Load the replica-site recovery session.
2. Verify the requested VM is the replica or already adopted active workload.
3. If `cleanupTransport=true`, ask qemu FTCTL on the replica execution host to release session-specific NBD exports, locks, temporary state, and generated key material.
4. Remove or archive `ftctl.remote.replica.*` and `ftctl.standby.vm` markers from the replica VM according to the chosen policy.
5. Preserve replica VM NICs, volumes, account ownership, service offering, and Cloud lifecycle state.
6. Close the recovery session as `adopted` or `released`, then let Cloud remove protection-blocking `ftctl.*` VM details from the replica VM so it is immediately eligible for a new protection registration.
7. Optionally call the source Mold to mark its protection row released. Failure to reach source Mold records `source_abandoned` but does not fail the adoption.

The operation must not call `destroyVirtualMachine`, `expunge`, `deleteVolume`, or detach replica volumes unless the operator explicitly selected a destructive cleanup mode.

Adoption/release is terminal for the old DR relationship. qemu cleanup must remove only old session transport/runtime state; Cloud must not keep stale `ftctl.last.*` VM details that make the adopted VM appear protected when no active protection row exists.

## 8. qemu FTCTL Contract

qemu FTCTL needs explicit replica-controller commands, separate from the source-controller failback commands:

- prepare target-side NBD/export access when requested by Cloud.
- copy from active replica disks to explicit target Mold-created paths.
- report disaster reverse-copy progress.
- finalize target disks after Cloud stops the active replica VM.
- clean only session-specific qemu runtime state for forced release/adoption.

qemu FTCTL must not:

- infer target Mold, target host, or target network.
- create or delete Cloud-managed VMs or volumes.
- persist Mold API credentials.
- delete the active replica VM or its disks.
- assume source Mold reachability.

## 9. State Model

Replica-site DR adds these durable states:

- `standby`: replica exists but has not taken over.
- `failed_over`: replica is active after failover.
- `source_unavailable`: source Mold/site cannot be used for orchestration.
- `disaster_failback_target_prepared`: target primary resources exist.
- `reverse_syncing_to_target`: replica host is copying into target disks.
- `reverse_sync_ready`: target disks are ready for cutback.
- `cutback_in_progress`: replica stop, qemu finalize, and target start are running.
- `failed_back_to_target`: target primary is running.
- `adopt_requested`: operator chose long-term replica operation.
- `adopted`: replica VM is independent production VM.
- `released`: protection relationship has ended.
- `release_failed`: cleanup/adoption failed, but replica VM is preserved.

## 10. Conflict Resolution

This document changes the interpretation of target-side standby projection:

- Before failover, remote standby pages remain read-only projections.
- After failover or source unavailability, the replica Mold may expose disaster action buttons.
- The replica Mold still must not create a fake local source-side protection row merely to satisfy old UI logic.
- Any local target-side row or session is a replica recovery/adoption session, not a duplicate of the source `ftctl_protection` authority.

Documents 206 and 207 remain valid for source-controller failback. They do not cover full source Mold loss.

## 11. Verification Plan

Design-level verification:

- source-controller DR failback still follows documents 206 and 207.
- remote standby page is read-only while `standby` and source protection is healthy.
- after failover/source unavailable, remote standby page exposes failback and adoption actions without presenting adoption and release as duplicate primary buttons.
- replica-site disaster failback creates target VM/volumes through target Mold APIs.
- qemu events show only data-plane copy/finalize/cleanup work.
- replica adoption preserves the running replica VM and volumes.
- forced replica release, when explicitly selected as an advanced recovery policy, preserves the running replica VM and volumes unless destructive cleanup is explicitly chosen.
- adopted/released replica VM can be protected again as a normal primary candidate.
- source Mold credentials are optional and best-effort during adoption.
- no API key or secret key is persisted.
