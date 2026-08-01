# 445. FTCTL DR Bidirectional Incremental Replication And Reverse Guest Compatibility Design

- Date: 2026-08-01
- Status: code-level design; implementation pending
- Scope: VMware <-> KVM continuous replication, Reprotect, planned Failback, Windows guest compatibility
- Normative priority: this document supersedes any earlier text that treats a reversed profile plus the forward VMware mover as a valid KVM-to-VMware data path

## 1. Goal

Cross-hypervisor DR is complete only when both authority directions have a real
incremental data path:

| Active authority | Replication direction | Change tracker | Target writer |
|---|---|---|---|
| VMware | VMware -> KVM | VMware CBT | RBD/QCOW2 writer |
| KVM | KVM -> VMware | RBD diff or persistent QEMU bitmap | VDDK VMDK writer |

Failover changes authority. Reprotect starts continuous replication from the
new authority. Failback is the final planned cutback after that reverse
protection is healthy; it is not a command that merely powers the old VM on.

## 2. Verified failure and feasibility evidence

The live Windows Plan `2514a846-64a2-4bc7-ba88-38a874410782` proved the current
reverse path invalid:

- Failback Run `f858f559-b6e4-4136-983b-79e675357696` completed as SUCCEEDED.
- The generated profile said `KVM_TO_VMWARE`.
- Checkpoint sequence `1495` still advanced VMware CBT change IDs.
- It reported `effectiveMode=NO_CHANGE`, `sourceReadBytes=0`, and
  `targetWrittenBytes=0`.
- Cloud then stopped the KVM VM and started the original VMware VM.
- The corresponding DB cycle was associated with the old protection Run, not
  the Failback Run.

The non-mutating 2026-08-01 preflight also established:

| Probe | Result |
|---|---|
| RBD images | `rbd/w22-01-dr-disk-0`, `rbd/w22-01-dr-disk-1` exist |
| RBD features | `exclusive-lock`, `object-map`, and `fast-diff` are enabled |
| RBD cutover snapshots | none |
| FTCTL KVM-to-VMware writer | not implemented |
| v2k reverse Windows preparation | not implemented |
| `rbd diff --from-snap` | available |
| VDDK library | exports `VixDiskLib_Read` and `VixDiskLib_Write` |
| nbdkit VDDK plugin | supports writable mode when `-r` is omitted |

The platform primitives are sufficient, but the DR transaction and evidence
contract do not yet exist.

## 3. Root cause

### 3.1 Global forward disk map reuse

`ftctl_dr_vmware_replication_cycle()` always selects:

```text
<plan-dir>/vmware-disks.json
```

and canonicalizes the supplied profile only when that file does not exist. A
reverse profile therefore reuses the committed forward VMware CBT map.

### 3.2 Provider selection is based on presence, not direction

`ftctl_dr_scheduler_run_cycle()` calls the same VMware replication function
when either endpoint is VMware. It does not distinguish `VMWARE_TO_KVM` from
`KVM_TO_VMWARE`.

### 3.3 Cycle type falls through to CBT

The mover maps every cycle type except `full-seed` and `full-reseed` to
`CBT_INCREMENTAL`. Therefore `failback-final` queries the original VMware VM
instead of reading changed KVM blocks.

### 3.4 No KVM baseline lineage

The failover transaction does not preserve a per-disk RBD snapshot or
persistent dirty bitmap that represents the final forward checkpoint before
the KVM guest is prepared and started.

### 3.5 Guest preparation is one-way

The implemented Windows path injects VirtIO support for VMware-to-KVM cutover.
There is no reverse preparation that verifies VMware storage drivers, BCD,
firmware, Secure Boot, NIC model, and VMware bootability before cutback.

## 4. Safety invariants

1. A provider pair is selected by explicit direction, never by endpoint presence.
2. VMware CBT is valid only while VMware is the change-tracked source.
3. KVM changes are never inferred from VMware CBT change IDs.
4. Every incremental cycle references one immutable baseline ID and generation.
5. The first reverse cycle without a valid KVM baseline is `FULL_REVERSE_SEED`.
6. Reverse writes target a staging VMDK/VM, never the only known-good source disk.
7. Cloud powers off the active KVM VM only after a final reverse checkpoint is durable.
8. Windows data readiness and Windows VMware boot readiness are separate gates.
9. Zero-byte transfer is valid only when the selected KVM tracker proves no changed extents.
10. Authority changes only after data, guest compatibility, power, and engine ACK are durable.

## 5. Directional provider architecture

```text
VMWARE_TO_KVM
  VMwareCbtChangeTracker
  -> VddkReadSource
  -> ExtentNormalizer
  -> RbdOrQcow2TargetWriter

KVM_TO_VMWARE
  RbdDiffChangeTracker | QemuPersistentBitmapTracker
  -> LibrbdOrQemuSourceReader
  -> ExtentNormalizer
  -> VddkStagingTargetWriter
```

Add a provider-pair registry:

```bash
ftctl_dr_provider_pair_for_direction PROFILE
ftctl_dr_provider_preflight PROFILE MODE
ftctl_dr_provider_run_cycle PLAN RUN PROFILE SEQUENCE MODE
```

Supported pair keys:

```text
VMWARE_CBT__RBD
VMWARE_CBT__QCOW2
RBD_DIFF__VMWARE_VDDK
QCOW2_BITMAP__VMWARE_VDDK
VMWARE_CBT__VMWARE_VDDK
RBD_DIFF__RBD
QCOW2_BITMAP__QCOW2
```

Unknown pairs fail with `DR_PROVIDER_PAIR_UNSUPPORTED` before mutation.

## 6. Baseline lineage

### 6.1 Canonical baseline record

Each disk baseline is stored as JSON and projected to Cloud:

```json
{
  "schemaVersion": 1,
  "baselineId": "uuid",
  "planUuid": "uuid",
  "direction": "KVM_TO_VMWARE",
  "authoritySide": "TARGET",
  "generation": 1496,
  "diskKey": "2000",
  "sourceIdentity": "rbd:rbd/w22-01-dr-disk-0",
  "targetIdentity": "vmdk:vm-4486:2000",
  "trackerType": "RBD_FAST_DIFF",
  "trackerRef": "rbd/w22-01-dr-disk-0@ftctl-dr-cutover-1495-2000",
  "state": "LOCAL_DURABLE",
  "createdFromCheckpoint": 1495,
  "createdAt": "2026-08-01T00:00:00Z"
}
```

The record is immutable. A new committed cycle produces the next generation.

### 6.2 Cutover baseline timing

For VMware-to-KVM Failover:

1. complete the final VMware CBT cycle;
2. flush and verify every KVM target disk;
3. create the KVM cutover baseline before guest preparation;
4. run Windows/Linux guest preparation against the active KVM disk;
5. start and validate the KVM VM;
6. commit TARGET authority.

This timing makes driver injection and all KVM runtime writes visible relative
to the baseline.

### 6.3 RBD tracker

Add `lib/ftctl/dr_kvm_change_tracker.sh`:

```bash
ftctl_dr_rbd_baseline_preflight IMAGE
ftctl_dr_rbd_baseline_create PLAN GENERATION DISK_KEY IMAGE
ftctl_dr_rbd_diff_query IMAGE FROM_SNAP OUT_JSON
ftctl_dr_rbd_baseline_advance IMAGE OLD_SNAP NEW_SNAP
ftctl_dr_rbd_baseline_release IMAGE SNAP
```

Requirements:

- `exclusive-lock`, `object-map`, and `fast-diff` are enabled;
- snapshot names include Plan, generation, and disk key;
- `rbd diff --from-snap --format json` is normalized to byte extents;
- zero and discard extents remain typed operations;
- the previous snapshot is deleted only after target write, flush, metadata
  commit, and new baseline creation succeed;
- an active failback/test lease prevents baseline deletion.

### 6.4 QCOW2 tracker

For file-backed KVM disks, use a persistent QEMU dirty bitmap:

```bash
ftctl_dr_qcow2_bitmap_preflight DOMAIN DISK
ftctl_dr_qcow2_bitmap_create DOMAIN DISK BITMAP
ftctl_dr_qcow2_bitmap_export DOMAIN DISK BITMAP OUT_JSON
ftctl_dr_qcow2_bitmap_clear_after_commit DOMAIN DISK BITMAP GENERATION
```

Bitmap loss, disablement, or disk identity mismatch requires
`FULL_REVERSE_RESEED`; it must never silently report `NO_CHANGE`.

## 7. VMware target writer

Add `lib/ftctl/dr_vmware_writer.sh`. Do not add reverse behavior to the current
read-oriented mover.

```bash
ftctl_dr_vmware_writer_preflight PROFILE TARGET_SPEC
ftctl_dr_vmware_writer_stage_create PROFILE RUN
ftctl_dr_vmware_writer_open TARGET_SPEC MODE
ftctl_dr_vmware_writer_apply_extents SOURCE EXTENTS TARGET
ftctl_dr_vmware_writer_flush TARGET
ftctl_dr_vmware_writer_verify TARGET EXPECTED
ftctl_dr_vmware_writer_stage_commit STAGE_REF
ftctl_dr_vmware_writer_stage_abort STAGE_REF
```

The writer contract requires:

- original VMware VM is powered off and fenced;
- a dedicated staging VMDK or snapshot-backed candidate exists;
- VDDK is opened writable without the mover's `-r` flag;
- source and target virtual sizes match;
- every extent records requested, read, written, and verified bytes;
- flush completes before checkpoint commit;
- retry uses an extent journal and never assumes an uncertain write succeeded;
- the original VMDK remains recoverable until Cloud commits cutback.

The first reverse seed may clone the original VMDK into staging and patch all
blocks from the KVM source. Later cycles patch only RBD/QCOW2 changed extents.

## 8. Windows reverse guest preparation

Add `lib/ftctl/guestprep_reverse.sh` and reuse only stable v2k compatibility
helpers. Do not invoke the v2k migration orchestration as the DR engine.

```bash
ftctl_guestprep_reverse_preflight PROFILE STAGE_MANIFEST
ftctl_guestprep_reverse_windows_prepare STAGE_MANIFEST
ftctl_guestprep_reverse_linux_prepare STAGE_MANIFEST
ftctl_guestprep_reverse_verify STAGE_MANIFEST RESULT
```

Windows preparation must:

1. preserve user data and OS identity;
2. detect original VMware root/data controllers from inventory;
3. verify or stage boot-critical VMware PVSCSI/LSI SAS/SATA/NVMe drivers;
4. verify the corresponding service and CriticalDeviceDatabase start policy;
5. preserve VirtIO drivers unless removal is explicitly required;
6. reconcile BCD, EFI partition, Secure Boot, and TPM policy;
7. prepare VMXNET3 or the selected VMware NIC while preserving network intent;
8. emit an offline mutation manifest with hashes and changed byte ranges;
9. run an isolated VMware boot validation before authority commit.

`POWER_STATE_VALIDATED` alone is insufficient. Valid modes are:

```text
POWER_STATE_VALIDATED
VMWARE_TOOLS_HEARTBEAT_VALIDATED
GUEST_HEARTBEAT_VALIDATED
APPLICATION_PROBE_VALIDATED
```

Windows Failback requires at least VMware Tools or guest heartbeat unless an
operator explicitly selects and acknowledges a lower validation policy.

## 9. Reprotect and Failback state model

```text
FAILED_OVER_UNPROTECTED
  -> REVERSE_PREFLIGHT
  -> REVERSE_SEEDING
  -> REVERSE_PROTECTED
  -> REVERSE_INCREMENTAL

REVERSE_PROTECTED
  -> FAILBACK_QUIESCING
  -> FAILBACK_FINAL_DELTA
  -> REVERSE_GUEST_PREPARING
  -> VMWARE_BOOT_VALIDATING
  -> FAILBACK_DATA_READY
  -> CLOUD_CUTBACK_COMMITTING
  -> SOURCE_PROTECTED
```

Failback is not eligible from `FAILED_OVER_UNPROTECTED`. The operator first
runs Reprotect, waits for `REVERSE_PROTECTED`, and then runs Failback. For a
legacy Plan without a reverse baseline, Reprotect performs the explicit full
reverse seed asynchronously.

## 10. FTCTL code changes

### 10.1 `lib/ftctl/dr_scheduler.sh`

- replace endpoint-presence routing with the provider-pair registry;
- reject `ftctl_dr_vmware_replication_cycle()` unless source provider is VMware;
- add `ftctl_dr_kvm_to_vmware_replication_cycle()`;
- make cycle mode direction-specific;
- include direction and authority generation in scheduler lease identity.

### 10.2 `lib/ftctl/dr_runtime.sh`

- build a direction-specific disk map under
  `disk-maps/<direction>/<generation>.json`;
- never reuse global `vmware-disks.json` for a reversed profile;
- preserve KVM baseline references when building a reverse profile;
- require `reverseDataPlaneReady=true` before `dr-reprotect` or `dr-failback`;
- make `dr-failback` consume a committed reverse checkpoint, not create a
  forward CBT checkpoint under a new name;
- retain TARGET authority on every pre-commit failure.

### 10.3 New runtime paths

```text
<plan>/baselines/<direction>/<generation>/<disk>.json
<plan>/disk-maps/<direction>/<generation>.json
<plan>/extent-journals/<cycle>.json
<plan>/writer-stages/<run>.json
<plan>/guestprep/reverse/<run>/manifest.json
<plan>/guestprep/reverse/<run>/result.json
```

### 10.4 Status fields

```text
replication_direction
authority_side
provider_pair
transfer_mode
baseline_id
baseline_generation
baseline_state
source_tracker_type
target_writer_type
reverse_write_ready
staging_target_ref
changed_bytes
source_read_bytes
target_written_bytes
write_verified_bytes
reverse_guest_prep_state
boot_validation_state
```

## 11. Typed errors

```text
DR_PROVIDER_PAIR_UNSUPPORTED
DR_REVERSE_BASELINE_MISSING
DR_REVERSE_BASELINE_INVALID
DR_REVERSE_FULL_SEED_REQUIRED
DR_RBD_FAST_DIFF_UNAVAILABLE
DR_QCOW2_BITMAP_UNAVAILABLE
DR_KVM_SOURCE_NOT_QUIESCED
DR_VMWARE_WRITER_UNAVAILABLE
DR_VMWARE_TARGET_LOCKED
DR_VMWARE_STAGE_CREATE_FAILED
DR_VMWARE_EXTENT_WRITE_FAILED
DR_VMWARE_WRITE_VERIFY_FAILED
DR_REVERSE_GUEST_PREP_UNSUPPORTED
DR_REVERSE_GUEST_PREP_FAILED
DR_VMWARE_BOOT_VALIDATION_FAILED
DR_REVERSE_EVIDENCE_MISMATCH
```

## 12. Crash and retry behavior

- A failed source read does not advance the baseline.
- A partial VMDK write leaves the staging candidate quarantined.
- A writer retry resumes from the durable extent journal or recreates staging.
- A failed guest preparation recreates the candidate from the last durable
  data checkpoint.
- A failed VMware boot validation keeps KVM authority and power available.
- Cloud commit uncertainty is resolved by authority generation and staging
  promotion ID, never by repeating data writes blindly.

## 13. Self-tests and live acceptance

### 13.1 FTCTL self-tests

1. a reverse profile cannot reuse forward `vmware-disks.json`;
2. `KVM_TO_VMWARE` cannot call the CBT source mover;
3. missing RBD baseline selects `FULL_REVERSE_SEED`;
4. RBD diff normalizes data, zero, and discard extents;
5. target write failure preserves the old baseline and TARGET authority;
6. successful write plus flush advances exactly one generation;
7. zero-byte cycle requires tracker proof;
8. Windows reverse preparation is required before data-ready;
9. legacy Plan cannot run incremental Failback without a reverse seed;
10. source/target disk identity mismatch is terminal and typed.

### 13.2 Live acceptance

1. complete VMware-to-KVM protection and Failover;
2. confirm the cutover RBD baseline exists before KVM first boot;
3. write a known file and checksum while Windows runs on KVM;
4. run Reprotect and observe non-zero KVM-to-VMware bytes;
5. run a no-change reverse cycle and observe zero bytes with valid proof;
6. change another known file and verify a second incremental reverse cycle;
7. run planned Failback and isolated VMware boot validation;
8. verify both files and checksums on VMware;
9. write data on VMware and verify forward CBT catches it after protection resumes;
10. verify EFI, Secure Boot, storage controller, NIC, and guest heartbeat in both directions.

## 14. Recommended implementation order

1. Block unsafe `KVM_TO_VMWARE` Failback when reverse writer evidence is absent.
2. Add direction-specific provider selection and disk-map namespaces.
3. Add baseline schema, files, leases, and projection fields.
4. Implement RBD fast-diff and QCOW2 persistent-bitmap trackers.
5. Implement staging VDDK writer and extent journal.
6. Implement full reverse seed and writer verification.
7. Implement continuous reverse incremental scheduler through Reprotect.
8. Implement Windows/Linux reverse guest preparation.
9. Add isolated VMware boot validation and Cloud cutback gate.
10. Add DB/API/Agent/UI evidence projection.
11. Run automated build and self-tests.
12. Run the bidirectional live acceptance chain from a clean Plan.

## 15. AS-IS / TO-BE

| Area | Error cause | AS-IS | TO-BE |
|---|---|---|---|
| Provider routing | any VMware endpoint selects one mover | forward CBT mover reused in reverse | explicit provider pair per direction |
| Reverse baseline | no KVM lineage | old VMware CBT ID reused | RBD snapshot or persistent bitmap generation |
| Reverse transfer | `failback-final` falls through to CBT | false `NO_CHANGE` and 0-byte success | full reverse seed or proven KVM incremental |
| VMware target | no writer transaction | original VM is merely powered on | staging VMDK writer, flush, verify, promote |
| Windows | one-way VirtIO preparation | KVM disk may not boot safely on VMware | reverse driver/BCD/EFI preparation and boot validation |
| Failback | performs data and cutback ambiguously | success can mean only power transition | requires healthy reverse protection and final delta |
| Evidence | cycle belongs to forward Run | DB cannot prove reverse bytes | direction/run/baseline/writer evidence is durable |
| Failure safety | TARGET may be stopped after false data-ready | potential KVM-only data loss | TARGET authority retained until all gates pass |

## 16. Completion criteria

This design is complete only when the same Windows Plan demonstrates:

- non-zero KVM-to-VMware incremental transfer after a KVM-side write;
- zero-byte no-change only with a valid KVM tracker baseline;
- VMware boot with the KVM-side data present;
- subsequent VMware-to-KVM CBT incremental transfer;
- monotonic authority and baseline generations across the round trip;
- no direct UI-to-engine call and no synchronous long-running API request.

## 17. Implementation update (2026-08-01)

Implemented source boundaries:

- `lib/ftctl/dr_kvm_vmware.sh`: explicit `ABLESTACK_TO_VMWARE` provider-pair routing, direction-scoped disk map, baseline, manifest, and checkpoint contract;
- `lib/ftctl/dr_kvm_vmware_mover.sh`: RBD snapshot tracker, `rbd diff` incremental extents, writable VDDK target, deterministic NBD drain, and post-write byte verification;
- `lib/ftctl/dr_extent_patch.py`: optional read-after-write verification and verified byte metrics;
- `lib/ftctl/dr_scheduler.sh`: forward CBT reader and reverse VDDK writer are selected independently;
- `lib/ftctl/dr_runtime.sh`: reverse baseline, tracker, writer, write verification, and guest compatibility evidence are projected before `FAILBACK_DATA_READY`.

The first reverse cycle is always `FULL_REVERSE_SEED`. Later cycles use `REVERSE_INCREMENTAL`; the previous RBD baseline snapshot is removed only after VDDK flush, read-after-write verification, and atomic local baseline commit. A failed cycle keeps the previous baseline and target authority.

Live acceptance remains mandatory before production qualification. It must prove a non-zero KVM-to-VMware delta, a verified no-change cycle, VMware guest heartbeat, and a subsequent forward CBT cycle.
