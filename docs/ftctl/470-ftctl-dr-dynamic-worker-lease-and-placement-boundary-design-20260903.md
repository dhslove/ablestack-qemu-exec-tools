# FTCTL DR Dynamic Worker Lease and Placement Boundary Design

## 1. Scope

This is the FTCTL counterpart of Cloud design
`627-dr-dynamic-placement-and-transparent-worker-scheduling-design-20260903.md`.
It defines how FTCTL preserves checkpoint and operation identity when Cloud
changes coordinator, transfer worker, or VM control Agent at runtime.

It applies to VMware-to-RBD, RBD-to-RBD, and SharedMountPoint
qcow2-to-qcow2. Existing provider transfer algorithms remain unchanged.

This design is not a data-plane or lifecycle redesign. Existing successful
sync, checkpoint, Test Failover, cleanup, Failover, Failback, Reprotect, and
release behavior is authoritative. The only corrected boundary is how Cloud
chooses the Agent that receives an existing command and how FTCTL validates
that runtime assignment.

It must not change VM Details, disk maps, provider selection, checkpoint
ordering, authority transitions, target materialization, or terminal rules. It
must not trigger a full reseed or recreate an existing replica.

The Cross-Mold Test Cleanup authority refinement is defined in
`471-ftctl-dr-remote-source-test-cleanup-authority-design-20260905.md`.

## 2. Non-negotiable Rules

- A Plan profile must not make a VM host UUID durable routing authority.
- `sourceWorkerHostUuid`, `sourceHostUuid`, coordinator host, and target worker
  host are not prerequisites for provider-independent status or recovery.
- An inventory observation must not be promoted into persistent Plan routing.
- A stopped VM is valid for offline file/block checkpoint production.
- SharedMountPoint file transfer is scheduled on any eligible storage-capable
  worker, independent of VM placement.
- Disaster Failover, Test Failover from a durable checkpoint, cleanup, and
  release must not require source Agent reachability.
- FTCTL must not infer that a missing VM host means missing source data.

## 3. Runtime Lease Contract

The implemented Cloud phase stores the selected host only in the existing
`dr_resource_lease` row as `HOST:<id>:<operation-class>`. The lease belongs to
the Run, expires, and is revalidated against live site inventory before reuse.
It is not copied into the Plan or profile. FTCTL commands continue to use their
existing Plan UUID, Run UUID, role, and provider contracts, so this correction
does not change the wire schema or data-plane behavior.

When a lease expires or its Agent is no longer eligible, Cloud selects another
worker and redispatches the same idempotent Run/Cycle contract. Plan identity,
Cycle token, checkpoint sequence, disk-set identity, and authority generation
do not change merely because the worker changed.

An explicit lease UUID/epoch command envelope may be added later as an
additive protocol version. It is not required for this compatibility phase and
must not be claimed as deployed until both Cloud and FTCTL validate it.

Host UUID may appear in runtime evidence for audit, but it is never read from
the durable profile to authorize a future command.

## 4. Role Separation

| Role | FTCTL responsibility | Placement lifetime |
| --- | --- | --- |
| Coordinator | serialize action and Cycle ownership | Run lease |
| Transfer worker | move one Cycle/disk set | Cycle lease |
| VM control Agent | perform QMP or local lifecycle helper | one command |

The roles may share a host but FTCTL must not assume that they do.

For SharedMountPoint qcow2, the transfer worker validates the canonical mount,
source/target path containment, file accessibility, provider tools, and writer
ownership. It does not validate that the source VM runs on the same host.

## 5. Placement Change Handling

VM-local commands include the placement observation generation supplied by
Cloud. A stale placement returns a structured retryable result:

```text
DR_VM_PLACEMENT_CHANGED
```

FTCTL performs no fallback to a persisted host. Cloud re-queries Mold/vCenter
and redispatches idempotently. Once a durable checkpoint is published, later
VM migration does not invalidate that checkpoint or an independent transfer
lease.

A disconnected transfer worker returns `DR_WORKER_LEASE_LOST`. The next worker
continues from the same durable Cycle contract or retries the Cycle according
to provider semantics; it never creates a second logical Cycle solely because
the host changed.

### 5.1 VMware source contract

FTCTL accepts VMware sources in both `POWERED_ON` and `POWERED_OFF` states.
Power state selects the capture path and is not a general availability gate:

- a powered-on VM uses the established snapshot/CBT consistency path;
- a powered-off VM permits a stable-chain Full Seed;
- a powered-off VM with a valid CBT baseline/change ID permits incremental or
  `NO_CHANGE` completion without an automatic power operation;
- `CBT_PENDING_ACTIVATION` is a typed incremental-readiness state, not a reason
  to invalidate an existing durable recovery point or block checkpoint-based
  recovery;
- disaster Failover does not require vCenter, the source VM, or the source ESXi
  host to be reachable.

The ESXi identity returned by vCenter is never a worker binding. VMware
inventory and disk locators are refreshed for each capture attempt so vMotion
or DRS placement changes are handled without rewriting the Plan. The VDDK
process runs on a Cloud-selected KVM data-plane worker with a Run/Cycle lease;
the user does not select this worker and FTCTL does not persist it as future
authority.

## 6. Capability Contract

`dr-capabilities` describes the installed FTCTL package on the Agent receiving
the probe. It is not VM state and must not query libvirt for a workload host.
Cloud probes candidates by site and role, then selects an eligible worker.

Provider-independent commands such as `dr-status` and release tombstone status
remain available without a live source profile. Action capability failures are
scoped to the role/site required by that action and cannot be expanded into a
global Plan failure.

## 7. Compatibility

Legacy host fields remain accepted in profiles for rolling upgrade but are
treated as non-authoritative hints. They must not:

- gate command parsing;
- select a local provider path;
- override a runtime lease;
- change checkpoint or disk mapping identity;
- prevent status, cleanup, release, or disaster recovery.

No provider implementation may be modified merely to implement dynamic
scheduling. Cloud selects the worker; FTCTL validates the selected worker's
actual capabilities and preserves provider-specific safety contracts.

## 8. Regression Gates

1. `dr-capabilities` succeeds on an eligible host without a running VM.
2. SharedMountPoint full/incremental sync succeeds when source VM `host_id` is
   null and the files are accessible.
3. A coordinator lease moves to another host without changing Cycle identity.
4. A transfer lease moves after worker failure and preserves checkpoint
   sequence/token.
5. VM migration causes `DR_VM_PLACEMENT_CHANGED`, live re-resolution, and one
   idempotent command result.
6. Disaster Failover succeeds with source site unavailable and a valid durable
   checkpoint.
7. Test cleanup and both release dispositions require only their owning
   target/controller roles.
8. Existing VMware/VDDK, RBD, and SharedMountPoint provider smoke suites pass.
9. VMware source powered off permits Full Seed and valid-baseline incremental
   or `NO_CHANGE` without starting the VM.
10. vMotion/DRS placement change refreshes the VMware locator and does not
    mutate Plan routing authority.
11. Source-unreachable disaster Failover remains available from the last
    durable checkpoint.
12. Static checks reject durable-profile reads of host UUID for dispatch or
   action capability decisions.

## 9. AS-IS / TO-BE

| Area | AS-IS | TO-BE |
| --- | --- | --- |
| Worker identity | Persisted Plan field | Runtime lease with epoch |
| VM host | Reused as source worker | Command-time placement observation only |
| Shared storage | Coupled to VM placement | Any eligible mounted worker |
| Migration | Stale host blocks every action | Re-resolve and idempotently retry VM-local command |
| Recovery | Source lookup required globally | Target and durable evidence are sufficient where applicable |
| VMware source power | Power observation can be confused with capture eligibility | Powered on and off are valid; CBT activation is a typed state, not global failure |
| VMware VDDK worker | Plan-selected host reused as a durable route | Cloud-selected Run/Cycle lease from the live VDDK-capable pool |

## 10. Release Smoke Barrier

The FTCTL package release job must run the complete DR action contract before
building the RPM. The barrier covers Full Sync, incremental/NO_CHANGE,
pause/resume, Test Failover, Test Cleanup, planned and disaster Failover,
Failback, Reprotect, release-retain, release-delete, cancellation, restart
recovery, terminal journal, and release tombstone behavior.

The same suite is parameterized for VMware-to-RBD, RBD-to-RBD, and
SharedMountPoint qcow2-to-qcow2. It additionally asserts that a stopped source
does not make file/block replication unavailable, a missing source does not
block checkpoint-based disaster recovery, no command consumes a Plan-persisted
worker as authority, and all disk sets remain atomic. A failed case blocks RPM
publication and therefore blocks test-site deployment.

The release workflow runs `tests/ftctl_dr_full_lifecycle_smoke.sh` before every
provider-specific smoke script. It executes every `selftest_case_dr_*` case in
the FTCTL self-test and asserts that representative cases for status/cancel,
pause/resume control, Full Sync, scheduled incremental sync, Test Failover and
cleanup, Failover, Failback, Reprotect, and offline reverse preflight exist.
The provider scripts are additional data-path gates and are not substitutes
for it. RPM construction starts only after both layers pass. HA/XCOLO tests are
outside this DR release gate and remain in their own validation workflow.

Self-test cases must mock VM inventory, libvirt, network, and storage evidence
explicitly. A lifecycle test must never inherit a GitHub runner's empty
libvirt inventory or wait for a real probe timeout, because that can select an
unrelated failover branch and make the release gate nondeterministic.

For KVM-to-VMware Failback and Reprotect, `source_domain_probe_state` is
`NOT_REQUIRED`. The promoted replica's domain may be stopped or absent on the
worker selected for an offline transfer. Eligibility is derived from the
committed TARGET authority, canonical disk-set mapping, readable source RBD or
SharedMountPoint artifacts, durable checkpoint/baseline evidence, and a
writable dynamically resolved VMware target. `virsh dominfo` and `virsh
domstate` are operation observations only and must never gate reverse transfer.

SharedMountPoint qcow2 forward transfer follows the same power-independent
contract. If a source domain is running, QMP may rebind a stale locator to the
unique active backing file. If the domain is stopped, unavailable, or
destroyed, QMP is not an eligibility gate: FTCTL accepts only the command-time
Cloud locator whose absolute source file exists and whose format is confirmed
as qcow2 by `qemu-img info`. Missing, ambiguous, or non-qcow2 source artifacts
remain hard failures.

For Full Seed, acceptance of that locator selects a distinct offline producer;
it does not call a QMP helper with a known-missing domain. The dynamically
leased SharedMountPoint worker first verifies the entire disk set has no
writable holder, prepares all persistent bitmap baselines, and then copies to
the already leased target exports without `--force-share`. A concurrent start
or placement change is a retryable command-time race, never a durable Plan host
binding. QMP, offline ownership, bitmap, and transfer errors use the dedicated
qcow2 error namespace in design 468 and cannot trigger VMware/NBD cleanup.

The same power-independent rule applies to subsequent scheduler Cycles. A
running source keeps the existing QMP incremental path. A stopped source opens
the qcow2 files through a temporary `qemu-storage-daemon` block graph and uses
the same persistent dirty bitmap with `blockdev-backup`. Zero dirty extents
produce `NO_CHANGE`; non-zero extents produce `CBT_INCREMENTAL`. Normal power
state must never promote a valid incremental baseline to Full Seed. Treating
normal VM power state as `DR_QCOW2_SOURCE_RUNTIME_UNAVAILABLE` is forbidden;
that error is reserved for a command-time loss after a live QMP producer was
selected.

Full Seed remains limited to initial protection, an explicit operator Full
Resync, or provider evidence that the durable baseline is absent or invalid.
The provider decision matrix is therefore:

| Provider | Running source | Stopped source | Full Seed trigger |
| --- | --- | --- | --- |
| SharedMountPoint qcow2 | live QMP bitmap | offline storage-daemon bitmap | missing/invalid bitmap or explicit request |
| RBD | RBD snapshot diff | RBD snapshot diff | missing baseline snapshot or explicit request |
| VMware | snapshot + CBT changeId | snapshot + CBT changeId | CBT epoch/changeId invalid or explicit request |

Power state selects only the qcow2 bitmap access adapter. It is not a transfer
mode or capability decision for any provider.

## Relocated SharedMountPoint Incremental Transport Ordering

The worker-local canonical disk map is disposable placement cache. It is not
durable replication authority and may legitimately be absent after live
migration selects a different source worker. Before an incremental-capable
Cycle chooses its transport, FTCTL must reconstruct the canonical disk map
from the recovery profile, refresh the current Cloud locator, and rebind the
live QMP source when the domain is running.

A missing worker-local map alone must never promote a requested incremental
Cycle to Full Seed. The first Cycle after relocation must remain
`CBT_INCREMENTAL` or `NO_CHANGE` when the durable bitmap epoch is valid. Full
Seed fallback is allowed only after provider evidence proves that the bitmap
or baseline epoch is missing or invalid, or when the operator explicitly
requests Full Resync.

The persistent bitmap embedded in each qcow2 image is the durable baseline
authority. A worker-local `baseline-*.bitmap` sidecar under `/run` is cache and
may be absent after scheduler relocation or process restart. Offline sync must
first validate the expected bitmap name, granularity, and flags from the qcow2
metadata. Only after that validation succeeds may it atomically reconstruct
the missing sidecar. A missing sidecar alone is never
`DR_QCOW2_BASELINE_NOT_DURABLE` and must not reset or recreate the bitmap.

Regression gates must exercise one and multiple disks in both modes: a running
domain retains the existing QMP producer, while a stopped domain selects the
offline producer. The same release must continue to pass the VMware-to-RBD and
RBD-to-RBD lifecycle suites before deployment.

## Planned Failover From An Already Stopped File Source

A planned SharedMountPoint qcow2 Failover has two valid source-quiesce modes.
`QMP_STOP` remains the unchanged path for a running source domain. When the
controller reads the source VM as `POWERED_OFF` immediately before dispatch,
it may instead request `SOURCE_ALREADY_STOPPED` and include that observation in
both the request and recovery profile.

FTCTL must never infer `SOURCE_ALREADY_STOPPED` from a missing libvirt domain or
failed QMP lookup. Those conditions can also mean that the VM migrated or that
the storage worker is not the current VM host. The offline mode is accepted
only when the controller supplied `sourceRuntimeObservedPowerState=POWERED_OFF`.
FTCTL then refreshes the command-time disk map, validates the complete qcow2
disk set and every persistent bitmap baseline, and atomically freezes the map
under the Failover Run UUID. It performs no QMP `stop` or `cont` operation.

The resulting immutable evidence is:

* `source_runtime_quiesce_state=OFFLINE`
* `source_runtime_quiesce_mode=SOURCE_ALREADY_STOPPED`
* a Run-owned `cutover_source_disk_map_sha256`
* `source_power_state=POWERED_OFF`

Cloud may accept either this evidence or the existing `PAUSED/QMP_STOP`
evidence as cutover-ready. Before target promotion, Cloud rechecks source power
through the source Mold and requires `POWERED_OFF`; a changed or unknown state
fails the transition instead of promoting from a questionable checkpoint.
Release of an offline quiesce lease only terminalizes the lease and must not
start the source VM.

Regression coverage must prove that the running QMP path is unchanged, the
already-stopped path completes without QMP, domain absence without the explicit
controller observation is rejected, and migrated-worker domain absence is not
misclassified as offline. VMware-to-RBD and RBD-to-RBD provider behavior stays
unchanged and remains in the shared lifecycle smoke gate.

## Target Cutover Projection Profile Ownership

Cross-Mold KVM Failover commits authority at both sites. The source commit
acknowledges the Run-owned final checkpoint; the target commit records TARGET
authority beside the materialized replica. These acknowledgements use the same
Cloud commit envelope but do not share worker-local `/run` state.

The target worker resolves its projection contract from the transient runtime
profile when present, then from the Plan-owned redacted export profile under
`/var/lib/ablestack-vm-ftctl/dr-target-exports/<plan>/profile.json`. The
persisted profile remains valid after target exports are stopped and contains
the direction, transition scope, target identity, and selected target worker
needed to validate the commit. It must not contain credentials.

A command whose role is `target` must never fall through to the source commit
implementation. If neither profile proves a Cloud-managed KVM target
transition, FTCTL returns `DR_CUTOVER_TARGET_ROLE_INVALID`. It does not return a
misleading source `DR_CUTOVER_SESSION_NOT_FOUND` and does not mutate authority.
The target commit owns creation of its Plan-scoped `cutover-commits` directory;
an older Plan is not required to have created that directory before the target
projection, and failure to create it fails the commit before acknowledgement.

Regression coverage executes target commit with no transient runtime profile,
using only the Plan-owned export profile, and proves terminal TARGET authority
plus an acknowledged commit journal. The shared VMware-to-RBD, RBD-to-RBD, and
SharedMountPoint lifecycle gates remain unchanged.
