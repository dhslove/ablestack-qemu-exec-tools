# FTCTL DR ABLESTACK RBD Cross-Site Data Plane Design

Date: 2026-08-24

The FTCTL data plane is authority-neutral. It accepts an immutable command
from the Plan Owner Cloud through the Cloud that owns the local Agent. Source
or target execution does not grant FTCTL ownership of the DR plan, Cloud VM,
or volume lifecycle. Every remote command is correlated by Plan UUID, Run UUID,
site role, and operation reference; FTCTL never calls a remote Cloud lifecycle
API on its own.

## 1. Scope And Invariants

This document defines the FTCTL data plane for `KVM_TO_KVM`, RBD to RBD,
without Ceph `rbd-mirror`.

- Cloud owns VM, volume, RBD image, network, and power lifecycle.
- FTCTL receives explicit Cloud-created `rbd:<pool>/<image>` mappings.
- A running VM uses krbd; replication reads/writes through QEMU or librbd.
- FTCTL never creates a Cloud-managed RBD image or VM.
- Existing VMware CBT/VDDK functions are not modified by this provider driver.

## 2. Provider Pair

`KVM_TO_KVM` resolves to the `ABLESTACK_RBD_REMOTE_NBD` provider pair when all
protected source and target disks are RBD. The profile contains immutable disk
identity and never relies on local numeric Cloud IDs.

```json
{
  "providerPair": "ABLESTACK_RBD_REMOTE_NBD",
  "replicationMode": "SCHEDULED_INCREMENTAL",
  "disks": [{
    "diskId": "root",
    "source": "rbd:source-pool/source-image",
    "target": "rbd:target-pool/target-image",
    "targetExport": "nbd://target-host:port/export",
    "virtualBytes": 64424509440
  }]
}
```

## 3. Scheduled Replication

### Full seed

1. Verify target image exists and is at least the source virtual size.
2. Target broker starts an NBD export backed by target librbd.
3. Source worker streams the source RBD image to the export.
4. Target flushes, drains, and closes the export.
5. FTCTL records transfer metrics and commits a durable baseline token.

### Incremental cycle

1. Create source snapshot `ftctl-<plan>-<sequence>`.
2. When no baseline exists, request a full seed.
3. Run `rbd diff --whole-object --from-snap <baseline>` and stream changed
   extents to the target export at their original offsets.
4. Flush and close the target export.
5. Atomically promote the new source snapshot and target checkpoint token.
6. Delete only the superseded source baseline after the new baseline is
   durable. Keep one valid baseline at all times.

An interrupted cycle keeps the previous baseline and is retryable. A changed
disk topology invalidates only that Plan's baseline and requires an explicit
reseed; it never silently continues with a partial mapping.

## 4. Near-Real-Time Mode

`LIVE_MIRROR` uses the running QEMU source disk and remote NBD target. QEMU
mirrors guest writes while the VM remains on its krbd source disk. The mirror
target is not pivoted into the source VM.

FTCTL periodically establishes a durable boundary by querying the block job,
requesting a guest or block flush according to policy, recording mirror-ready
evidence, and committing a target checkpoint. On broker loss the job is
cancelled or recovered without starting the target VM. The UI exposes this as
near-real-time protection, not synchronous zero-RPO.

## 5. Failover And Failback

- Test failover clones or snapshots only the durable target artifact. The live
  writer is never attached to the test VM.
- Planned failover performs a final durable cycle, drains the target writer,
  confirms source isolation, then lets target Cloud start the replica.
- Disaster failover may use the latest durable target checkpoint without
  contacting the destroyed source site.
- Failback swaps the provider endpoints. The target site's active RBD is read
  through its broker and changed extents are applied to a Cloud-owned source RBD.
- Reprotect commits the reverse baseline before scheduled or live forward
  protection resumes.

## 6. Broker And Runtime State

Every site action is keyed by `plan_uuid`, `run_uuid`, `action`, and
`site_role`. Runtime files and terminal journals must be idempotent across Agent
or management-server retries. `dr-status --run` returns transfer bytes,
sequence, baseline generation, NBD teardown state, and terminal evidence.

No API credential, Cloud secret, or SSH private key is written into Plan state,
runtime status, events, or debug output.

## 7. Preflight Evidence (2026-08-24)

The 22 source host exposes QEMU `drive_mirror`, block-job control, and NBD server
commands. The sampled 22 and 32 hosts provide `qemu-nbd`, `rbd`, and
`/dev/nbd16` through `/dev/nbd31`. The 32 host has the FTCTL NBD firewall range
installed. Full cross-site port and signed-broker probes remain release gates.

## 8. Regression Tests

- one-disk RBD full seed and no-change incremental;
- changed-extents incremental and baseline rotation;
- interrupted incremental preserving the old baseline;
- live mirror start/checkpoint/stop and broker reconnect;
- test failover and cleanup while protection resumes;
- planned/disaster failover, failback, and reprotect;
- release with retain/delete resource dispositions;
- profile tombstone status after process restart;
- unchanged VMware-to-ABLESTACK contract suite.

## 9. Scheduler Recovery Contract

Cross-site recovery uses the target export as a prerequisite and the source
scheduler as the operation authority. After the Plan Owner has prepared the
target export, the source FTCTL performs these steps in order:

1. inspect Plan status for an NBD quarantine;
2. invoke the installed deterministic NBD recovery tool by an explicit path;
3. clear quarantine fields only after the tool succeeds;
4. rewrite the scheduler launch journal with the recovery Run identity;
5. start the Plan-scoped systemd unit and publish `RECOVERING`.

The recovery tool is shared by VMware and ABLESTACK providers because it owns
kernel NBD lifecycle, not source-disk semantics. An absent quarantine directory
is an idempotent success. A failed recovery publishes the failed stage and
original return code; it never collapses the result into an untyped success.

`dr-status` has two result dimensions. Top-level `result=ok` means the status
query succeeded. The requested Run is accepted only when `accepted=true`, its
state is not `ERROR`, `FAILED`, or `REJECTED`, and `error_code` is empty. Agent
and Cloud tests cover this distinction, target-before-source ordering, missing
recovery-tool failure, successful scheduler relaunch, and the unchanged
VMware-to-ABLESTACK baseline contracts.

## 10. Durable Target Export Reconciliation

`site-agent-nbd` is a Plan Owner controlled transport. The target Agent must
not treat the `qemu-nbd` process created by `dr-target-export-start` as the
durable contract. Package replacement, Agent restart, host reboot, or an
unexpected exporter exit may remove that process while the Cloud-owned target
RBD image remains valid.

For `KVM_TO_KVM` plus `site-agent-nbd`, the target FTCTL persists a redacted,
Plan-scoped export intent under
`/var/lib/ablestack-vm-ftctl/dr-target-exports/<plan>/`. The intent contains the
canonical disk map, fixed export names and ports, target RBD locators, and
`desiredState=RUNNING`; it contains no Mold credential or API secret. Periodic
FTCTL reconcile validates each PID and listener and recreates only missing
Plan-owned exporters with the recorded fixed ports. It atomically replaces the
volatile manifest only after all disks are ready.

`dr-target-export-stop` first commits `desiredState=STOPPED`, then terminates
the exporters and removes the active manifest. Release or failover therefore
cannot race with the timer and resurrect a deliberately stopped export.

The source scheduler treats an unavailable target export as a resource wait,
not as a completed transfer and not as NBD teardown failure. It preserves the
last durable baseline and source snapshot, publishes
`DR_TARGET_EXPORT_UNAVAILABLE / WAITING_RESOURCE`, and retries the same pending
Cycle with bounded exponential backoff. It must not allocate a new Cycle every
few seconds. After target reconciliation restores the fixed endpoint, the same
Cycle resumes and only a durable target commit may advance the baseline.

This contract is limited to `site-agent-nbd`. VMware VDDK, existing remote-SSH
NBD, shared block-copy, local RBD, and file-backed paths retain their validated
behavior.

### 10.1 AS-IS / TO-BE

| Area | AS-IS | TO-BE |
| --- | --- | --- |
| Target exporter lifetime | Volatile `qemu-nbd` PID and `/run` manifest | Durable redacted desired-state plus periodic idempotent reconciliation |
| Endpoint allocation | Port may be selected again after process loss | Initial fixed port is persisted and reused; collision is a typed wait |
| Package/host restart | Export silently disappears | Reconcile recreates the Plan-owned export without recreating the VM or RBD image |
| Source failure classification | Connection refusal can become teardown timeout and create retry cycles rapidly | `DR_TARGET_EXPORT_UNAVAILABLE`, same pending Cycle, bounded backoff |
| Baseline safety | Repeated failed Cycles obscure the last durable point | Baseline and source snapshot advance only after target durable commit |

## 11. Canonical Completed-Cycle Evidence

The ABLESTACK replication driver must publish the same completed-cycle identity
contract as the validated VMware mover. Every scheduler-owned full or
incremental Cycle writes the following fields into its final checkpoint before
the scheduler advances `latest_completed_cycle_sequence`:

- `sequence` and `baselineGeneration` equal the scheduler Cycle sequence;
- `cycleToken` is exactly `<plan_uuid>:<sequence>`;
- `cycleUuid` is the deterministic UUIDv5 of `ablestack-dr:<plan_uuid>:<sequence>`;
- `cycleCommitState` is `LOCAL_DURABLE` only after the target write is durable;
- incremental Cycles publish `nbdTeardownState=DRAINED` after every Plan-owned
  source and target NBD attachment has been disconnected;
- `nbdSourceDeviceCount`, `nbdTargetDeviceCount`, and teardown timestamps are
  recorded even when a transport uses zero local NBD devices.

The scheduler copies these fields into the Plan authority state as one terminal
publication. Cloud continues to reject incomplete evidence; it must not infer a
successful Cycle from transfer bytes alone. Initial target preparation
checkpoints are not scheduler terminal evidence and therefore do not receive a
synthetic sequence.

This change is scoped to `dr_ablestack.sh`. VMware VDDK cycle metrics and all
previously validated VMware-to-ABLESTACK action contracts remain unchanged.

### 11.1 AS-IS / TO-BE

| Area | AS-IS | TO-BE |
| --- | --- | --- |
| Cycle identity | ABLESTACK final checkpoint omits token and generation | Deterministic token, UUID, sequence, and generation are persisted before completion |
| Incremental cleanup | NBD devices are disconnected but teardown evidence is omitted | Disconnect completion is published as `DRAINED` with device counts and timestamps |
| Cloud projection | Strict validator returns `DR_STATUS_CYCLE_EVIDENCE_INCOMPLETE` | The unchanged validator accepts complete ABLESTACK evidence and projects `READY` |
| Regression scope | Transfer success can pass without status-contract coverage | Full seed, incremental, and zero-device transport tests assert canonical terminal evidence |

## 12. Repeated Target Materialization Ownership Identity

Cloud may revalidate an already materialized target for a later sync Run. The
signed materialization manifest contains the current `runUuid` and observed VM
power state, so its transport SHA changes even when the owned VM and disks do
not. FTCTL must therefore separate transport integrity from ownership identity.

- `materialization_spec_sha256` validates the exact manifest received for the
  current Run.
- `materialization_ownership_fingerprint_sha256` is calculated from contract
  version, plan UUID, replica ID, ownership generation, target VM ID/external
  reference, and the canonical target disk map.
- A new Run UUID or changed observed power state is accepted at the same
  ownership generation when the ownership fingerprint is unchanged.
- A VM, replica, or disk-map change at the same generation is rejected with
  `DR_MATERIALIZATION_GENERATION_CONFLICT`.
- A status written before this field was introduced is migrated only when the
  stored replica, VM, external reference, and disk-map digest all match.

| Area | AS-IS | TO-BE |
| --- | --- | --- |
| Retry identity | Full manifest SHA includes Run UUID | Stable ownership fingerprint excludes Run and observation fields |
| Revalidation | New sync Run conflicts at the same generation | Same target ownership is idempotently accepted |
| Ownership guard | Transport digest doubles as ownership identity | Transport SHA and ownership fingerprint have separate roles |
| Upgrade | Old status has no fingerprint | Exact legacy resource match performs one-way migration |

## 13. Target Export Process Ownership

The durable export intent is not sufficient when reconciliation starts the
exporter from the periodic `ablestack-vm-ftctl.service`. That unit is oneshot;
a forked `qemu-nbd` remains in the unit cgroup and is terminated when the
reconcile invocation exits. A successful command return therefore does not
prove that the fixed endpoint survived.

For `site-agent-nbd`, every Plan-owned target export runs in a dedicated
transient systemd service named from the Plan and disk identity. The service:

- executes `qemu-nbd` in the foreground with the existing librbd locator;
- owns restart-on-failure and stop semantics independently of the reconcile
  oneshot and Mold Agent process;
- writes the existing PID file and publishes the unit name in the export
  manifest;
- is accepted as ready only after both PID liveness and TCP reachability pass;
- is stopped through its unit before release, failover, or rollback removes
  the manifest.

The non-systemd fallback retains the validated forked process behavior for
test harnesses and minimal environments. This change does not alter VMware
VDDK, source RBD snapshot selection, NBD attachment ranges, or target VM krbd
execution. RBD synchronization continues to open the target image through
`qemu-nbd` and librbd; krbd remains the Cloud/libvirt VM execution path.

| Area | AS-IS | TO-BE |
| --- | --- | --- |
| Reconcile ownership | Exporter is a child of the periodic oneshot cgroup | Dedicated transient systemd service owns each Plan/disk exporter |
| Readiness | Successful launch command is treated as ready | PID and fixed TCP endpoint must both remain reachable |
| Restart | Intent is retried but the recreated child is killed at oneshot exit | Restart-on-failure service survives reconcile and Agent restarts |
| Stop | PID-only best effort | Unit stop plus PID fallback, followed by manifest removal |
