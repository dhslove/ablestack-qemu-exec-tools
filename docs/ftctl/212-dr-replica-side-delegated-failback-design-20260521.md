# 212. DR Replica-Side Delegated Failback Design

Date: 2026-05-21

## 1. Purpose

This document defines the first implemented replica-side `Failback` path for remote-Mold DR.

The full replica-controller disaster failback in document 208 is still the long-term model for a destroyed source Mold or a newly installed target Mold. That workflow must create or validate target VM, volume, network, storage, and host resources through the target Mold before qemu FTCTL copies data into those target disks.

The immediate missing behavior is narrower:

- the operator is viewing the running DR replica VM in the replica Mold.
- the original/source Mold is still reachable.
- the source-side `ftctl_protection` row still exists in that source Mold.
- the operator wants to start the already validated source-controller failback without switching to the source Mold UI.

For that case, the replica Mold can act as a thin delegator. It does not become the data-plane failback controller.

## 2. Related Designs

This document refines:

- [206. DR Cloud-Managed Failback Target Mold Design](206-dr-cloud-managed-failback-target-mold-design-20260516.md)
- [207. DR Cloud-Managed Failback Async Context Design](207-dr-cloud-managed-failback-async-context-design-20260516.md)
- [208. DR Replica-Site Disaster Failback And Adoption Design](208-dr-replica-site-disaster-failback-and-adoption-design-20260517.md)
- [211. DR Failback Action UX And Controller Model Design](211-dr-failback-action-ux-controller-model-design-20260521.md)

If older text says replica-side `Failback` is entirely unavailable until the full replica-controller workflow exists, read that as superseded for the delegated source-controller case only.

## 3. Controller Split

### 3.1 Delegated Source-Controller Failback

Implemented in this change.

The replica Mold:

- validates that the local VM is a running remote-Mold DR replica.
- uses non-secret replica metadata to identify the original/source VM UUID and name.
- accepts one-time target/source Mold credentials.
- calls the target/source Mold `getFtctlProtection` and verifies that the source VM still has an active DR primary protection view.
- calls the target/source Mold `failbackFtctlProtection`.

The source Mold remains the real controller. It owns:

- the source-side protection row.
- reverse-sync start and continuation state.
- the existing bounded in-memory failback operation context from document 207.
- Cloud lifecycle calls for the source-side VM.
- passing qemu FTCTL commands through Mold Agent.

### 3.2 Full Replica-Controller Disaster Failback

Not implemented by this delegated change.

Use this model when:

- the source Mold is destroyed or unavailable.
- the target is a newly installed Mold.
- the source-side protection row no longer exists.
- the recovery target VM/volumes must be newly provisioned.

That path remains governed by document 208 and must not be faked by creating local duplicate protection rows or by asking qemu FTCTL to create Cloud-managed resources.

## 4. UI Contract

When a remote-Mold DR replica is running and the replica view is in recovery mode, the UI exposes:

- `Failback`
- `Adopt replica`

`Failback` opens a replica-side delegated failback dialog.

The dialog collects two transient credential sets:

- **Target/source Mold credentials**: used by the replica Mold to call `getFtctlProtection` and `failbackFtctlProtection` on the Mold that still owns the source-side protection row.
- **Current replica Mold credentials**: passed through to the source-controller failback request as remote Mold credentials so the source Mold can stop the active replica VM during cutback.

No API key or secret key is persisted. The source Mold API URL may be shown as a non-secret hint when it was captured during replica provisioning.

## 5. Backend API

Add:

```text
failbackFtctlDrReplica
```

Required parameters:

```text
virtualmachineid
targetmoldapiurl
targetmoldapikey
targetmoldsecretkey
replicamoldapiurl
replicamoldapikey
replicamoldsecretkey
```

Backend sequence:

1. Validate the requested VM is a remote-Mold DR replica and is `Running`.
2. Resolve the original/source VM UUID or name from replica VM details.
3. Call target/source Mold `listVirtualMachines` to resolve the source VM.
4. Call target/source Mold `getFtctlProtection` and require:
   - `protectionrole=primary`
   - `mode=dr`
   - `enabled=true`
5. Call target/source Mold `failbackFtctlProtection` with:
   - `virtualmachineid=<source VM UUID>`
   - `failbacktargetmoldtype=original-primary`
   - `remotemoldapiurl=<current replica Mold API URL>`
   - `remotemoldapikey=<current replica Mold API key>`
   - `remotemoldsecretkey=<current replica Mold secret key>`
6. Return a local action response showing that the operation was delegated and, when available, include the remote source Mold job id in the output.

If step 3 or 4 fails, the API must fail clearly:

```text
Replica-side FTCTL DR failback requires an existing source VM and source protection row on the target/source Mold.
New or rebuilt Mold failback is not available in this delegated build.
```

## 6. qemu FTCTL Contract

This delegated path adds no new qemu action.

The source Mold eventually sends the same qemu FTCTL commands already used by source-controller failback:

- reverse sync.
- finalize.
- reprotect.
- session cleanup where applicable.

qemu FTCTL still must not:

- create Cloud-managed VMs or volumes.
- store Mold credentials.
- infer the source or target Mold from runtime state.

## 7. Consistency Rules

- HA and source-controller DR failback must not regress.
- Cloud owns all Cloud-managed VM, volume, network, storage, host placement, and lifecycle actions.
- Mold Agent only relays explicit qemu FTCTL commands and returns status/log/event results.
- qemu FTCTL owns data-plane replication and failback work only after Cloud has created or selected the target resources.
- The replica-side delegated API is a convenience controller handoff, not full disaster failback.

## 8. Verification

Build-time checks:

- Cloud backend compiles with the new API command registered.
- UI unit tests cover the replica recovery action list and delegated failback parameter submission.
- English and Korean locale keys have matching behavior.

Runtime checks:

- From the running replica VM view, `Failback` is enabled when `failbackFtctlDrReplica` is available and the replica is `failed_over / failed_over / secondary / clear`.
- The delegated call reaches the source Mold and starts the source-side `failbackFtctlProtection` job.
- The source Mold continues the already validated failback path.
- If the source protection row is absent, the error tells the operator that full replica-controller recovery is required.
