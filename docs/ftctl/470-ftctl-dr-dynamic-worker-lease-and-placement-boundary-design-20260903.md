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

Regression gates must exercise one and multiple disks in both modes: a running
domain retains the existing QMP producer, while a stopped domain selects the
offline producer. The same release must continue to pass the VMware-to-RBD and
RBD-to-RBD lifecycle suites before deployment.
