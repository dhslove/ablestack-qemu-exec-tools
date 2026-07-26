# 211. DR Failback Action UX And Controller Model Design

Date: 2026-05-21

## 1. Purpose

This document reconciles the DR failback UI with the controller model in documents 206, 207, and 208.

The observed confusion is:

- the primary-side `Failback` dialog offers `current Mold`, `original primary Mold`, and `new Mold`, even though primary-side source-controller failback currently returns to the source/original primary context.
- the replica-side recovery view shows both `Adopt replica` and `Release replica protection`, which look like duplicate ways to keep the replica running.
- true replica-site failback to a restored or newly installed Mold is a separate replica-controller workflow and must not be represented by the adoption action.
- replica-side failback has two different meanings that must not be mixed: delegated source-controller failback when the source Mold still owns the source protection row, and full replica-controller disaster failback when the source Mold is gone or replaced.

## 2. Related Designs

This document refines operator-facing behavior from:

- [201. DR Remote Mold Cloud-Managed Resource Ownership Design](201-dr-remote-mold-cloud-managed-resource-ownership-design-20260514.md)
- [206. DR Cloud-Managed Failback Target Mold Design](206-dr-cloud-managed-failback-target-mold-design-20260516.md)
- [207. DR Cloud-Managed Failback Async Context Design](207-dr-cloud-managed-failback-async-context-design-20260516.md)
- [208. DR Replica-Site Disaster Failback And Adoption Design](208-dr-replica-site-disaster-failback-and-adoption-design-20260517.md)
- [209. DR Adopted Replica Re-protection Readiness Design](209-dr-adopted-replica-reprotect-readiness-design-20260519.md)
- [212. DR Replica-Side Delegated Failback Design](212-dr-replica-side-delegated-failback-design-20260521.md)

If earlier wording implies that the current UI should always expose a target-Mold selector, this document supersedes that UI interpretation. The backend capability model may still keep target-Mold types for future workflows.

## 3. Controller Model

### 3.1 Source-Controller Failback

The source Mold can still load the source-side `ftctl_protection` row and owns the failback command.

Operator-facing rules:

- The primary/source-side `Failback` dialog must not show `current Mold`, `original primary Mold`, and `new Mold` as choices.
- For remote-Mold DR, the dialog asks only for one-time credentials for the replica Mold so Cloud can stop the active replica VM during cutback.
- The request may keep the internal target type as `original-primary` for compatibility, but that is not presented as an operator choice.
- Target Mold API credential fields must not be duplicated as both remote and target credentials unless the future target-Mold provisioning path needs them.

Cloud rules:

- Cloud controls source and replica VM lifecycle through the Mold that owns each VM.
- Credentials remain request-scoped or bounded in-memory operation context only.
- qemu FTCTL performs reverse copy, finalize, and reprotect only after Cloud requests those data-plane actions.

### 3.2 Replica-Side Delegated Source-Controller Failback

The operator is viewing the running replica VM in the replica Mold, but the original/source Mold is reachable and still owns the active source-side `ftctl_protection` row.

Operator-facing rules:

- The replica-side view may expose `Failback`.
- The dialog must not ask the operator to choose between `current Mold`, `original Mold`, and `new Mold`.
- The dialog collects target/source Mold credentials plus current replica Mold credentials.
- Target/source credentials let the replica Mold start `failbackFtctlProtection` on the source Mold.
- Current replica credentials are passed to the source Mold so the existing source-controller cutback can stop the active replica VM.

Cloud rules:

- The replica Mold is only a delegator.
- The source Mold remains the failback controller.
- If the source VM or source protection row cannot be validated, this delegated path must fail with an explicit message directing the operator to full replica-controller recovery.

### 3.3 Full Replica-Controller Failback

The source Mold is destroyed, unavailable, or intentionally abandoned. The Mold that owns the running replica VM becomes the recovery controller.

Operator-facing rules:

- The replica-side view should expose `Failback` and `Adopt replica`.
- `Failback` means copy data from the active replica to a target VM/volume set managed by the restored original Mold or a newly installed Mold.
- `Adopt replica` means keep the current replica VM as production and remove FTCTL standby semantics so it can be protected again later.
- `Release replica protection` is not a separate primary action beside `Adopt replica`; it is an advanced/destructive recovery policy only when the operator explicitly wants to abandon the source relationship without adopting the VM as the production workload.

Cloud rules:

- Full replica-controller failback needs its own backend API and recovery-session workflow.
- The target Mold must create or validate target VM, target volumes, host, storage, and network selections through Cloud APIs before qemu FTCTL receives disk paths.
- New-Mold failback is not implemented by `Adopt replica`; adoption is an exit path, not a data-copy failback.

## 4. Current Implementation Boundary

The current implemented source-controller failback path can:

- start reverse sync from the primary/source-side UI.
- use transient remote Mold credentials to stop the active remote replica VM during cutback.
- automatically continue cutback when the in-memory operation context is still valid.
- expose `Continue failback` only as a recovery path after context loss or restart.

The current UI must therefore:

- hide the primary-side target-Mold selector.
- send `failbacktargetmoldtype=original-primary` as an internal compatibility value.
- send only `remotemoldapiurl`, `remotemoldapikey`, and `remotemoldsecretkey` for remote-Mold DR failback.
- show replica-side `Failback` when the delegated source-controller backend command is available.
- make the replica-side `Failback` dialog collect both target/source Mold credentials and current replica Mold credentials.
- reject delegated replica-side failback when the target/source Mold does not have an active source-side DR protection row.
- keep `Adopt replica` as the active long-term operation conversion path.

## 5. Verification Requirements

- Primary-side remote-Mold failback request does not include duplicate `targetmold*` parameters.
- Primary-side failback modal has no target-Mold selector.
- Replica-side recovery view does not show two main buttons that both appear to release protection.
- Replica-side `Adopt replica` still runs the existing non-destructive adoption command.
- Replica-side `Failback` is visibly distinct from adoption and calls only the delegated source-controller path unless the future full replica-controller workflow is implemented.
- Missing source protection on the target/source Mold produces an actionable error instead of silently treating adoption as failback.
- English and Korean locale keys describe the same behavior.

## 6. 2026-07-25 Registered-Site UX Addendum

The registered DR Site credential model replaces the remaining one-time
credential fields described in sections 3 and 4 for normal source-controller
failback.

The operator-facing failback modal now shows:

- the current active Site;
- the registered original/source destination Site;
- Site health and credential validation summaries;
- latest durable synchronization evidence;
- reason and acknowledgement.

It does not show:

- `current`, `original-primary`, or `new`;
- remote Mold API URL/key/secret;
- target Mold API URL/key/secret;
- internal credential references.

Cloud resolves provider-specific credentials from the Plan's registered Sites.
A replacement or newly installed Site must first be registered and validated,
then used by a separate replica-controller recovery workflow. It is not an
option inside the normal source-controller failback modal.

This addendum supersedes lines that require the primary-side or delegated
normal failback UI to collect one-time Mold credentials. The controller
boundary remains unchanged: source-controller failback, delegated
source-controller failback, replica-controller disaster recovery, and adopt
remain distinct workflows.
