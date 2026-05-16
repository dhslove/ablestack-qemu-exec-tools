# 202. Cloud-Managed HA/DR Automatic Fencing qemu Contract Design

Date: 2026-05-14

## 1. Purpose

This document records the qemu-side contract for Cloud-managed HA/DR automatic fencing.

When `FTCTL_PROFILE_PROVISIONING_BACKEND=cloud-managed`, qemu FTCTL is not the automatic failover controller. Cloud owns the automatic fencing decision, VM lifecycle orchestration, host placement, target network/storage selection, and current/remote/new Mold API calls.

qemu FTCTL remains the replication and data-plane executor.

## 2. Corrected Boundary

For Cloud-managed HA/DR, qemu FTCTL may:

- perform SSH/libvirt/NBD preflight.
- run blockcopy, remote-nbd export handling, and reverse sync.
- validate explicit Cloud-created disk maps and target paths.
- produce events, progress, status, and heartbeat evidence.
- preserve manual-fence states requested by operator workflows.
- execute explicit Cloud-requested data-plane commands such as failover prepare/finalize.

For Cloud-managed HA/DR, qemu FTCTL must not:

- decide automatic failover from a single libvirt/domain probe.
- treat a missing transient standby domain as a Cloud resource failure before Cloud starts it.
- create, define, start, stop, delete, attach, detach, resize, or format Cloud-managed VMs or volumes.
- start a standby VM directly through libvirt as the Cloud-managed lifecycle mechanism.
- persist remote Mold API keys or secret keys.

## 3. Current Problem

The qemu reconciler currently has HA logic that can call `ftctl_failover_request` when the primary libvirt domain is missing.

That is unsafe as the Cloud-managed automatic model because:

- the standby VM is Cloud-owned and may be transient or stopped until Cloud starts it.
- the qemu timer on the failed source host may be unavailable in a real host failure.
- Cloud has the authoritative VM/host/agent/OOBM/resource state needed for a multi-signal decision.
- qemu already reports `cloud_managed_standby_start_pending` instead of starting the standby itself.

## 4. Required qemu Behavior

For `cloud-managed` profiles:

1. qemu must downgrade direct automatic failover to a candidate event, for example `cloud_managed_failover_candidate`, or disable it entirely.
2. qemu must keep manual/operator deferral behavior, including `failing_over`, `fencing_state=required|manual-fenced`, and `failover_ready` markers.
3. qemu must keep replication readiness checks and NBD release/finalize primitives.
4. qemu must expose enough status for Cloud to reconcile:
   - protection state
   - transport state
   - active side
   - admin state
   - fencing state
   - last error
   - failover-ready marker
   - blockcopy progress/freshness
5. qemu must accept Cloud-directed failover/failback commands after Cloud has completed fencing and VM lifecycle work.

For `libvirt-managed` standalone profiles, existing qemu-driven automatic behavior may remain if still required by standalone test coverage.

## 5. HA And DR Policy Split

qemu does not decide the policy split. It only reports and executes.

Cloud applies:

- HA strict fencing: do not auto-start standby unless fencing is confirmed.
- DR disaster-assumed fencing: after repeated multi-signal disaster classification, Cloud may record `ipmi_unknown_assumed_fenced` or `ipmi_failed_assumed_fenced` and start the replica.

qemu events should preserve these classifications when Cloud passes them as action context, but qemu must not invent them from local libvirt state alone.

## 6. Compatibility

This document supersedes any earlier qemu-side wording that implies qemu FTCTL owns Cloud-managed automatic failover or automatic fencing orchestration.

Manual HA/DR flows remain valid:

- qemu preserves manual failover state.
- Cloud UI collects operator confirmation.
- Cloud starts the standby/replica VM through local or remote Mold APIs.
- qemu finalizes the data-plane transition after Cloud lifecycle work is complete.

For DR failback, Cloud must also own target Mold selection and target primary VM lifecycle. The target Mold may be the current Mold, the original primary Mold, or a newly installed Mold, as defined in [206. DR Cloud-Managed Failback Target Mold Design](206-dr-cloud-managed-failback-target-mold-design-20260516.md).

## 7. Verification

Implementation verification must show:

- Cloud-managed qemu reconcile does not call automatic failover from one missing primary domain.
- Cloud-managed standby domain absence before Cloud start remains expected.
- manual-fence DR and HA flows still preserve failover state.
- qemu events show candidate/data-plane evidence only.
- Cloud starts Cloud-managed standby VMs through Cloud APIs, not through qemu libvirt lifecycle control.
- DR failback starts target primary VMs through the selected target Mold API, not through qemu libvirt lifecycle control.
