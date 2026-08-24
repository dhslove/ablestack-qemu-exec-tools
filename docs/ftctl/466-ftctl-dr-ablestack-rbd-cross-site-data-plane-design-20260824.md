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

## 14. Plan-Owner Checkpoint Evidence For Target-Side Transitions

`KVM_TO_KVM` replication and production failover final-delta transfer run on
the remote source worker. Test failover executes on the target worker because
it owns the replica RBD artifact. The source worker therefore owns the
canonical `restore-points.jsonl` and the production cutover engine session;
the target worker is not required to duplicate that source-local journal.

For these target-side transitions Cloud sends a versioned controller
checkpoint envelope selected from the latest `READY` `dr_restore_point`. The
envelope contains the Plan UUID, exact checkpoint reference and sequence,
cycle token/type, source-created and target-ready timestamps, target RPO,
effective mode, and readiness state. Test failover also carries the existing
artifact contract, whose checkpoint reference and sequence must match the
envelope.

FTCTL resolves a transition checkpoint in this order:

1. use an exact record from the local restore-point journal when present;
2. only for `KVM_TO_KVM`, accept the Plan Owner envelope when its version,
   Plan, selector, positive sequence, and `READY` state are valid;
3. for test failover, additionally require the artifact contract Plan/Run and
   checkpoint identity to match;
4. reject every mismatch as `DR_RESTORE_POINT_NOT_FOUND` or a typed checkpoint
   contract error before changing target resources.

This is metadata authority transfer, not data transfer. The replica RBD remains
the already durable target of the selected Cycle. VMware-origin paths continue
to use their validated local restore-point journal and are not eligible for the
controller-envelope fallback.

Cloud also sends `schedulerTransitionScope=REMOTE_SOURCE` for a remote
`KVM_TO_KVM` Plan. Test failover and test cleanup must not create, pause, or
resume a scheduler on the target coordinator. Their target RBD snapshot/clone
operation is atomic, while the source-site scheduler remains the sole writer
authority. Production failover remains a separate Plan-Owner orchestration:
The target export stays reachable while remote source FTCTL writes and durably
records the final delta. Cloud then pauses the source scheduler, stops the
source VM, drains the target export, and promotes the target VM.

### 14.1 AS-IS / TO-BE

| Area | AS-IS | TO-BE |
| --- | --- | --- |
| Checkpoint location | Source worker journal is searched on the target coordinator | Local journal first; validated Plan Owner envelope for remote KVM source |
| Test failover | Exact Cloud selector fails with exit 44 on target host | Selector, controller evidence, and artifact contract are cross-checked |
| Failover | Target worker cannot read the source RBD or canonical journal | Remote source owns final delta and cutover session; Cloud supplies immutable checkpoint evidence |
| Safety scope | A generic fallback could affect VMware | Fallback is explicitly limited to `KVM_TO_KVM` |
| Data authority | Missing local metadata appears to mean missing replica data | Cloud proves the durable Cycle; target FTCTL still verifies target artifacts |
| Test scheduler ownership | Target transition may create a duplicate local scheduler | Remote source remains the only scheduler; target performs artifact operations only |

## 15. Remote KVM Production Cutover Barrier

Production failover for a Plan owned by the target Cloud must not let target
FTCTL declare `FAILED_OVER` before Cloud has isolated the remote source and
started the Cloud-managed replica VM. This rule is limited to
`KVM_TO_KVM` profiles whose request carries
`schedulerTransitionScope=REMOTE_SOURCE`; local KVM and every validated
VMware-origin path retain their existing behavior.

For that scope FTCTL performs only the engine half of cutover:

1. lock the controller-selected durable checkpoint;
2. calculate a deterministic SHA-256 cutover manifest from the Plan UUID,
   direction, checkpoint identity, target identity, and canonical disk mapping;
3. publish `CUTOVER_READY / SOURCE / POWERED_OFF_PENDING` without claiming
   target authority;
4. wait for Cloud's typed `DR_CUTOVER_COMMIT_V2` envelope;
5. publish `FAILED_OVER / TARGET` only after Cloud reports the source fence,
   target VM power, boot validation, and matching manifest hash.

The remote source runtime also persists `target_vm_id` and `target_external_ref` from
the profile so the commit cannot be redirected to another replica. Planned
failover requires `VERIFIED / POWERED_OFF`; disaster failover accepts only the
existing explicit `ACKNOWLEDGED / UNKNOWN|UNREACHABLE` contract. Test failover
never enters this barrier and keeps the source scheduler running.

### 15.1 AS-IS / TO-BE

| Area | AS-IS | TO-BE |
| --- | --- | --- |
| KVM target state | Target FTCTL immediately publishes `FAILED_OVER` | Remote-source KVM publishes `CUTOVER_READY` and waits for Cloud commit |
| Manifest | KVM cutover has no commit SHA | Deterministic checkpoint and mapping manifest is persisted and cross-checked |
| Target identity | Commit may lack target VM identity in runtime | VM ID and external reference are immutable commit inputs |
| Authority | Engine state can precede Cloud VM lifecycle | Cloud source fence and target boot evidence precede final engine authority |
| Regression boundary | Shared KVM behavior could change | Branch is exact `KVM_TO_KVM + REMOTE_SOURCE`; VMware and local KVM are unchanged |

## 16. Target Export Cutover Drain And Abort Resume

The target export is a transport endpoint, not the target VM's execution
device. It must remain `RUNNING` through the final delta and must be stopped
before Cloud starts the target VM. The Plan Owner therefore uses the following
contract:

1. `dr-target-export-start` persists a redacted canonical profile and fixed
   endpoint intent on the target worker;
2. remote source `dr-failover` uses those endpoints until it publishes durable
   `CUTOVER_READY`;
3. Cloud invokes `dr-target-export-stop` only after source isolation and before
   target VM power-on;
4. if promotion is aborted, Cloud invokes `dr-target-export-start` without a
   transient profile; FTCTL restores the persisted profile and the same fixed
   endpoints before source scheduling resumes;
5. successful cutover leaves export desired state `STOPPED`, preventing
   qemu-nbd and the target VM from writing the same RBD concurrently.

The persisted-profile fallback is accepted only for an existing Plan-owned
target export record. It does not synthesize storage mappings and does not
apply to VMware or local KVM paths.

### 16.1 AS-IS / TO-BE

| Area | AS-IS | TO-BE |
| --- | --- | --- |
| Final transfer | Export is stopped before remote final delta | Export remains reachable through durable `CUTOVER_READY` |
| VM start barrier | Export and target VM ownership can overlap or be ordered incorrectly | Export stop is a required pre-power-on barrier |
| Abort recovery | Stop loses the immediate restart input | Start reloads the persisted redacted profile and fixed endpoint intent |
| Scheduler recovery | Source may resume against a closed export | Export restore succeeds before remote scheduler resume |
| Existing paths | Shared changes could alter VMware behavior | Fallback is target-export-specific and remote `KVM_TO_KVM` gated by Cloud |

## 17. Final Delta Incremental Baseline Contract

`FAILOVER_FINAL` is a synchronization purpose, not a request to discard the
durable RBD baseline. For an ABLESTACK-to-ABLESTACK Plan, FTCTL must classify
both normal incremental cycles and the final cutover cycle as
incremental-capable when a Plan-owned target transport and source baseline are
present.

The execution order is:

1. read the last durable source snapshot from the per-Plan, per-disk baseline;
2. create the final source snapshot;
3. calculate and transfer only the RBD diff between those snapshots;
4. durably commit the target checkpoint and manifest;
5. replace the baseline only after target durability is confirmed;
6. fall back to Full Seed only for the existing typed
   `baseline_unavailable` condition.

This classification is local to the ABLESTACK RBD data-plane driver. VMware
VDDK/CBT cycle selection and every previously validated VMware-to-ABLESTACK
path remain unchanged.

### 17.1 AS-IS / TO-BE

| Area | AS-IS | TO-BE |
| --- | --- | --- |
| Final cycle type | `FAILOVER_FINAL` misses the `INCREMENTAL` string test | `FAILOVER_FINAL` is explicitly incremental-capable |
| Data moved | A 60 GiB replica can be rewritten for a small final delta | Only changed RBD extents are sent when a baseline exists |
| Baseline failure | Final cutover silently follows the normal Full Seed branch | Typed `baseline_unavailable` is the only Full Seed fallback |
| Regression scope | Shared cycle parsing could affect VMware | Change is contained in `dr_ablestack.sh` and covered by an RBD-only smoke gate |

## 18. Dual-Engine Cutover Authority And Reverse Baseline

A remote `KVM_TO_KVM` Plan has one Cloud Plan Owner but two FTCTL runtime
projections. The source FTCTL owns forward replication and the final delta;
the target FTCTL owns the promoted VM and later executes reverse replication.
Production cutover is complete only when both projections acknowledge the same
typed commit envelope.

The target-side order is deliberately stricter than a normal target export
stop:

1. remote source FTCTL durably completes `FAILOVER_FINAL`;
2. target FTCTL stops the Plan-owned NBD export;
3. before the target VM is powered on, target FTCTL reverses the canonical disk
   map and creates one per-disk RBD snapshot as the reverse incremental
   baseline;
4. Cloud powers on and validates the target VM;
5. Cloud sends the same `DR_CUTOVER_COMMIT_V2` envelope to source role
   `coordinator` and target role `target`;
6. target FTCTL verifies the prepared baseline, suppresses its local forward
   scheduler, and publishes `FAILED_OVER / TARGET / STOPPED`;
7. Cloud changes Plan authority only after both acknowledgements succeed.

The target export stop is idempotent. A retry reuses the same Plan, Run, and
checkpoint identity and replaces only the matching prepared baseline. For a
Plan that was committed by an older build and therefore has no pre-power
baseline, target authority repair is allowed but records
`FULL_SEED_REQUIRED`; the first reverse cycle performs the existing typed Full
Seed fallback rather than claiming an unsafe incremental baseline.

The periodic target reconcile path must not start a forward scheduler when the
profile is exactly `KVM_TO_KVM`, `schedulerTransitionScope=REMOTE_SOURCE`, and
the source worker differs from the coordinator. It instead keeps the local
scheduler stopped and preserves target export or target authority state.
Because the same profile is present on both sites, profile fields alone are
not a sufficient local-role discriminator. Every non-dry-run Plan/action
dispatch persists `source`, `target`, or `coordinator` in a Plan-scoped worker
role journal. Scheduler suppression requires the journaled role to be exactly
`target`; the remote source role always remains eligible to produce forward
cycles.

### 18.1 AS-IS / TO-BE

| Area | AS-IS | TO-BE |
| --- | --- | --- |
| Engine commit | Only source FTCTL acknowledges cutover | Source and target acknowledge one immutable envelope |
| Reverse baseline | Target RBD has no snapshot at promotion | Baseline is created after export drain and before VM power-on |
| Target scheduler | Reconcile can start a duplicate forward scheduler | Remote-source profile plus persisted `target` role suppress only the target scheduler |
| Source scheduler | Profile-only suppression can also stop the producer | Persisted `source` role keeps the remote producer eligible |
| Failback preflight | Target reports empty authority and blocks Failback | Target reports `FAILED_OVER / TARGET` with the committed generation |
| Upgrade recovery | Missing historical target baseline is ambiguous | Authority repairs with typed `FULL_SEED_REQUIRED` fallback |
| Existing paths | Shared commit change can affect VMware | Dual projection requires remote `KVM_TO_KVM`; VMware and local KVM are unchanged |

## 19. Provider-Aware Reverse Preflight Contract

`dr-reverse-preflight` is a public engine contract and must dispatch by the
profile's provider pair. It must not infer the reverse target from the current
host or run a VMware backing resolver for an `ABLESTACK_TO_ABLESTACK` reverse
path.

For an ABLESTACK RBD Plan, the currently promoted target RBD is the reverse
source and the original source RBD is the remote reverse destination. The
target worker can validate only the local reverse source. Cloud and the remote
source-site Agent validate the destination writer when the failback Run is
accepted. The preflight response therefore uses the following rules:

1. canonicalize the original Plan profile and validate every target RBD locally;
2. report `READY / RBD_INCREMENTAL` only when the Plan-owned reverse baseline
   state is `READY`;
3. report `READY / FULL_RESEED` with `initial_seed_required=true` when an older
   Plan has no safe reverse baseline;
4. report `AGENT_VALIDATION_REQUIRED` for the remote destination writer instead
   of failing locally;
5. fail with `DR_REVERSE_SOURCE_STORAGE_MISSING` when a promoted target RBD is
   absent;
6. leave the VMware VDDK target-backing resolver and its result contract
   unchanged.

All optional fields emitted by either preflight path have explicit defaults.
An early error must produce a typed JSON response and must never terminate due
to Bash `set -u` expansion.

### 19.1 AS-IS / TO-BE

| Area | AS-IS | TO-BE |
| --- | --- | --- |
| CLI dispatch | Every reverse preflight invokes the KVM-to-VMware resolver | Provider pair selects the ABLESTACK RBD or VMware implementation |
| Reverse source | Target RBD is interpreted as a VMware backing | Promoted target RBD is validated as the local reverse source |
| Remote writer | Local worker tries to resolve the remote source-site target | Cloud/Agent validation is explicitly deferred with a typed state |
| Missing baseline | Missing historical metadata blocks failback ambiguously | Preflight remains ready with the existing typed Full Seed fallback |
| Error output | Early failure can expand unset status variables | Every schema field is initialized before validation |
| VMware regression | Shared preflight changes can alter the validated path | VMware resolver logic is unchanged apart from output safety defaults |

## 20. Plan-Owned Reverse RBD Export Contract

An ABLESTACK-to-ABLESTACK Failback keeps the DR Plan Owner as the only control
authority. The Plan Owner does not hand SSH credentials to FTCTL and does not
move Plan ownership to the original site. It asks the original site's Mold
Agent to expose the original RBD image as a temporary, Plan-owned NBD writer
and injects only the returned typed export endpoints into the Failback command.

The ordered data-plane contract is:

1. Cloud sends `TARGET_EXPORT_START` to the registered original-site worker
   through the remote Agent broker with `request.reverseTargetExport=true`;
2. FTCTL builds the reverse profile, canonicalizes bare ABLESTACK RBD image
   names to `rbd:<pool>/<image>`, and exports only the reverse destination;
3. the active target worker reads the promoted RBD locally and writes to the
   Agent-returned NBD endpoints using the existing site-agent transport;
4. after durable reverse data evidence, Cloud stops the active target VM;
5. Cloud sends `TARGET_EXPORT_STOP` to the same original-site Agent and waits
   for an acknowledgement before starting the original VM;
6. only then may the authority and scheduler commit return to `SOURCE`.

The reverse worker map swaps source and target. The temporary export role is
`reverse-target`, so preparing an original-site writer cannot accidentally
publish target scheduler authority. Error evidence names the provider-specific
`ablestack-rbd-mover`; VMware Failback retains `kvm-vmware-mover`.

### 20.1 Regression gates

- the branch is enabled only for a remote `KVM_TO_KVM` Plan whose active side
  is `TARGET` and whose action is `FAILBACK`;
- VMware-to-ABLESTACK and ABLESTACK-to-VMware commands are unaffected by
  reverse export preparation;
- no API key, secret key, password, or SSH credential is persisted in the
  FTCTL profile, export intent, event log, or command result;
- the original VM cannot start while its reverse destination export is still
  running;
- retry reuses the Plan-scoped export and cleanup remains idempotent.

### 20.2 AS-IS / TO-BE

| Area | AS-IS | TO-BE |
| --- | --- | --- |
| Controller | Failback is accepted locally but no original-site writer is prepared | The 32-site Plan Owner prepares the 22-site writer through Agent RPC |
| Reverse source | Bare target image name is inferred as a file | RBD source is canonical `rbd:<pool>/<image>` |
| Reverse destination | Original RBD has no typed transport endpoint | Original Agent returns a Plan-owned NBD endpoint |
| Power barrier | Original VM start is independent of export drain | Export stop acknowledgement precedes original VM start |
| Diagnostics | Every failure is labeled `kvm-vmware-mover` | ABLESTACK pair reports `ablestack-rbd-mover` |
| Existing success path | Shared reverse logic can regress VMware | Provider and action guards isolate the new RBD branch |

## 21. KVM Firmware Evidence Boundary

FTCTL does not select a Cloud VM firmware mode. The Plan Owner Cloud resolves
the source firmware contract and Cloud creates the target VM with that
contract. FTCTL receives the resulting immutable source hardware fingerprint
and materialization manifest and must reject a target whose manifest no longer
matches the Plan.

For ABLESTACK KVM inventory, Cloud detail `UEFI=<LEGACY|SECURE>` is normalized
to `bootType=UEFI` plus the corresponding boot mode. FTCTL must not reinterpret
the value `LEGACY` as BIOS. Existing VMware govc firmware discovery remains
unchanged.

Before cutover, the materialization contract requires a stopped target VM whose
Cloud details and runtime domain agree with the Plan boot type. A mismatch is a
typed readiness failure; FTCTL must not attempt guest preparation or power-on
as a workaround. This preserves the separation between Cloud-owned VM
lifecycle and FTCTL-owned replication.

| Area | AS-IS | TO-BE |
| --- | --- | --- |
| Firmware input | Ambiguous string may reach the manifest | Cloud supplies normalized boot type and mode |
| FTCTL behavior | Incorrect BIOS target can reach cutover | Manifest mismatch blocks cutover before power-on |
| Provider isolation | Shared code could affect VDDK | Rule is scoped to `KVM_TO_KVM`; VMware evidence is unchanged |

## 22. Target-Controlled Initial Seed Ownership Barrier

For a remote ABLESTACK source controlled from the DR site, Cloud persists the
replica and replica-disk ownership skeleton before target materialization
creates volumes or a VM. Cloud then persists the generated target references
before dispatching FTCTL.

FTCTL receives only the resulting durable target storage and profile contract.
It does not create Cloud VM inventory or compensate for a missing `dr_replica`
row. This preserves the established split: Cloud owns VM, volume, network,
firmware, and authority state; FTCTL owns data transfer and runtime evidence.

## 23. Ceph CLI-Compatible Reverse Baseline Verification

The target worker verifies a reverse baseline with
`rbd snap ls --format json <pool>/<image>` and an exact snapshot-name match.
It must not use `rbd snap info`, because that subcommand is unavailable in the
Ceph CLI shipped by the supported ABLESTACK clusters. A created reverse
baseline becomes `READY` only when its exact name is present in the JSON list.

This rule is limited to the ABLESTACK RBD reverse-baseline path. It does not
change VMware-to-ABLESTACK inventory, transfer, or cutover behavior.

| Area | AS-IS | TO-BE |
| --- | --- | --- |
| Snapshot probe | Unsupported `rbd snap info` always fails | Exact-name lookup in `rbd snap ls --format json` |
| Cutover | Reverse baseline creation loops at 45% | Baseline becomes `READY`, then promotion continues |
| Regression scope | Test stub accepts the unsupported command | Test rejects `snap info` and requires `snap ls` |

## 24. Planned Failover Final Checkpoint Canonicalization

A planned Failover that requests a final synchronization has exactly one
cutover checkpoint authority. After `FAILOVER_FINAL` becomes durable, FTCTL
must replace the previously selected restore-point reference with the final
checkpoint reference before guest preparation, cutover-session creation, and
Cloud commit validation.

The final checkpoint function records both
`failover_final_checkpoint_sequence` and
`failover_final_restore_point_ref=ftctl:<plan>:<run>:<sequence>` only after the
manifest, checkpoint, and restore-point record are durable. The Failover worker
then uses that immutable reference for every remaining stage. A missing final
reference is a typed final-checkpoint failure; it must not silently reuse the
pre-Failover checkpoint.

This rule applies only when planned Failover final synchronization actually
produced a new checkpoint. Disaster Failover and explicit no-final-sync flows
retain the existing selected restore point. VMware transfer and ABLESTACK RBD
transfer algorithms are unchanged.

| Area | AS-IS | TO-BE |
| --- | --- | --- |
| Final synchronization | Produces sequence N+1 but leaves the selected reference at N | Publishes one canonical reference for N+1 |
| Guest preparation | Can carry the stale pre-Failover reference | Uses the final durable reference |
| Cutover session | `checkpoint_sequence` and `failover_restore_point_sequence` can diverge | Both identify the same final checkpoint |
| Cloud commit | Rejects with `DR_CUTOVER_CHECKPOINT_MISMATCH` after the VM boots | Validates the immutable final checkpoint and terminalizes |
| Regression scope | A broad selector change could affect disaster Failover | Override occurs only after successful planned final sync |
