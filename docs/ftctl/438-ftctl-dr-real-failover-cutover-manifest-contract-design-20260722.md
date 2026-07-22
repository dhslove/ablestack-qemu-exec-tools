# FTCTL DR Real Failover Cutover Manifest Contract Design

- Date: 2026-07-22
- Status: implementation design; read-only provider preflight verified
- Cloud normative design: `ablestack-cloud/docs/ftctl/567-cross-hypervisor-dr-real-failover-cutover-manifest-and-rollback-design-20260722.md`
- Scope: `lib/ftctl/guestprep.sh`, new manifest normalizer, DR runtime status, and self-tests

## 1. Problem

The real VMware-to-KVM Failover path currently builds guest-preparation input
from legacy JSON fields. On the verified Windows Plan this produced an empty
guest ID, zero disks, and file/qcow2 defaults even though the source was EFI
Secure Boot and the target had two RBD/raw disks.

Test Failover uses an artifact-derived manifest and therefore does not validate
the real Failover builder. Real Failover needs one schema-aware builder whose
input authorities and storage locator format are explicit.

## 2. FTCTL boundary

FTCTL owns:

- durable checkpoint selection and validation;
- provider-object validation;
- temporary RBD map/unmap needed by guest preparation;
- Linux or Windows guest preparation;
- typed `CUTOVER_READY` or terminal failure status.

FTCTL does not own:

- Cloud VM creation, start, stop, or deletion;
- Cloud network and offering selection;
- source-site operator fencing policy;
- Plan active-side promotion;
- V2K migration orchestration.

The V2K guest preparation and target-device helpers are reusable library
primitives. The V2K migration CLI and its Phase 1/Phase 2 workflow remain
unchanged.

## 3. Input authorities

`ftctl_guestprep_build_cutover_manifest` takes three documents and never scans
unrelated runtime files to fill missing values.

| Input | Authority |
|---|---|
| Plan profile | source guest/hardware identity and intended disk keys |
| selected checkpoint | immutable replicated data version |
| target disk map | provider locator bound to each source disk |

The selected checkpoint must be `TARGET_READY` with commit state
`LOCAL_DURABLE`. The disk map is joined by `sourceDiskKey`, with `device` used
as a consistency assertion. Display order and display name are not identity.

## 4. Manifest V2

The canonical output is `FTCTL_GUESTPREP_MANIFEST_V2`.

Required fields:

- Plan and Run UUID;
- checkpoint UUID/reference, sequence, state, and commit state;
- guest ID, derived guest family, firmware, and Secure Boot flag;
- target root disk controller, I/O policy, and I/O thread policy;
- one or more disks with stable source key, device, boot flag, size, provider
  type, format, and canonical locator.

Supported durable locators:

```text
rbd:<pool>/<image>
/absolute/file/path.qcow2
```

`/dev/rbd/<pool>/<image>` is accepted only as backward-compatible input and is
normalized to `rbd:<pool>/<image>`. It is never emitted or persisted as the
durable locator. A bare image/display name is rejected.

## 5. Code structure

### 5.1 New `lib/ftctl/guestprep_manifest.py`

This helper uses the standard JSON parser and has no provider side effects.

```text
build --profile <json> --checkpoint <json> --disk-map <json> --output <json>
validate --manifest <json>
```

Internal functions:

```python
def resolve_source_guest(profile): ...
def resolve_source_disks(profile): ...
def index_target_disks(target_map): ...
def canonicalize_locator(storage_type, locator): ...
def join_disks(source_disks, target_disks): ...
def validate_manifest_v2(manifest): ...
```

Resolution precedence is schema-versioned, not opportunistic:

1. `mapping.source.vm.guestId`
2. `mapping.source.hardware.guestId`
3. a documented compatibility path only when the profile schema is legacy

The builder rejects conflicting nonblank values instead of silently choosing
one. Firmware and Secure Boot receive the same conflict check.

### 5.2 `lib/ftctl/guestprep.sh`

Replace the embedded legacy extractor in
`ftctl_guestprep_prepare_cutover_target()` with these functions:

```bash
ftctl_guestprep_build_cutover_manifest PROFILE CHECKPOINT DISK_MAP OUTPUT
ftctl_guestprep_validate_manifest MANIFEST
ftctl_guestprep_validate_provider_objects MANIFEST
ftctl_guestprep_prepare_target_devices MANIFEST RUN_DIR
ftctl_guestprep_release_target_devices RUN_DIR
ftctl_guestprep_prepare_cutover_target MANIFEST RUN_DIR
```

The public preparation function receives the already validated V2 manifest.
It does not reopen the Plan profile and reinterpret fields.

### 5.3 RBD lifecycle

For every `rbd:` locator:

1. Run `rbd info` before mutation.
2. Map through the proven V2K target-device helper with Run ownership.
3. Write the mapped device and map token to `RUN_DIR/device-map.json`.
4. Pass only the mapped block device to WinPE/Linux preparation.
5. Unmap in the operation finalizer, including signal and error paths.

An existing foreign mapping is not unconditionally removed. The finalizer
unmaps only devices whose ownership token was created by the current Run.

### 5.4 Runtime integration

The DR runtime performs these steps before writing `CUTOVER_READY`:

1. resolve selected durable checkpoint;
2. load current target disk map;
3. build and validate V2 manifest;
4. verify tools, ISOs, and provider objects;
5. prepare and map target devices;
6. run guest preparation;
7. release temporary mappings;
8. atomically publish manifest, SHA-256, and terminal status.

The output manifest is written under the Cutover Session/Run directory, never
back into the immutable checkpoint. Publication uses temp-file plus rename.

## 6. Status contract

Successful preparation emits:

```json
{
  "phase": "CUTOVER_READY",
  "terminal": false,
  "manifestSchemaVersion": "FTCTL_GUESTPREP_MANIFEST_V2",
  "manifestSha256": "...",
  "checkpointSequence": 418,
  "targetDiskCount": 2,
  "guestFamily": "windows",
  "firmware": "efi",
  "secureBoot": true,
  "cleanupRequired": false
}
```

FTCTL does not report Failover success at this point. Cloud still has to start
the existing target VM and validate boot.

Failure emits a terminal operation envelope even if no long-running worker was
created. `worker_state=RUNNING` is forbidden when all recorded PIDs are absent.

Error codes:

- `DR_CUTOVER_MANIFEST_INVALID`
- `DR_GUEST_OS_UNRESOLVED`
- `DR_TARGET_DISK_MAP_MISSING`
- `DR_TARGET_DISK_LOCATOR_INVALID`
- `DR_TARGET_DISK_NOT_DURABLE`
- `DR_GUEST_PREP_RUNTIME_UNAVAILABLE`
- `DR_GUEST_PREPARATION_FAILED`

Each error includes `step`, `retryable`, `cleanupRequired`, and a nonblank human
message. The literal `OK` is never used as an error message.

## 7. Failure cleanup

Before Cloud target promotion, FTCTL failure cleanup is limited to resources
owned by the current Run:

- stop/remove the temporary guest-preparation helper domain;
- unmap Run-owned RBD mappings;
- remove temporary mount/work directories;
- preserve provider images and selected durable checkpoint;
- publish a terminal error and cleanup result.

FTCTL does not start the source VM, resume protection autonomously, or delete
the Cloud target VM. Cloud issues a separate recovery command after authority
and source safety are verified.

## 8. Read-only preflight evidence

The current failed Plan was normalized without mutating target data.

| Check | Result |
|---|---|
| Guest ID | `windows2019srvNext_64Guest` |
| Guest family | Windows |
| Firmware | EFI |
| Secure Boot | true |
| Disk count | 2 |
| Storage/format | RBD/raw |
| Canonical locators | two `rbd:rbd/...` locators |
| Provider objects | both passed `rbd info` |
| WinPE ISO | readable |
| VirtIO ISO | readable |
| Temporary artifacts | removed after preflight |

The first experimental normalization retained `/dev/rbd/...` and correctly
failed because those transient mappings did not exist. Canonicalization to
`rbd:` then passed provider validation. This proves that durable identity and
temporary device mapping must remain separate.

WinPE injection was not executed during design because it mutates target data.
It is an implementation acceptance test after the map/unmap lifecycle is in
place.

## 9. Self-tests

Add fixtures for the exact deployed profile/checkpoint/disk-map schema, with
secrets replaced by placeholders.

Required cases:

1. Windows EFI/Secure Boot plus two RBD/raw disks succeeds.
2. Linux BIOS plus file/qcow2 succeeds.
3. Unknown guest, zero disks, duplicate source key, and missing boot disk fail.
4. Display-only disk reference fails.
5. `/dev/rbd` compatibility input emits `rbd:` canonical output.
6. Missing RBD image fails before guest mutation.
7. Map failure, WinPE failure, signal, and success all run ownership cleanup.
8. Terminal setup failure never reports an active worker.
9. Manifest output is deterministic and its SHA-256 is stable.

Integrate the tests into the existing qemu GitHub Actions path. No binary ISO
or generated package is committed.

## 10. AS-IS / TO-BE

| Area | AS-IS | TO-BE |
|---|---|---|
| Parser | embedded legacy field extraction | schema-aware tested Python normalizer |
| Guest data | empty guest ID can reach preparation | required guest identity with conflict checks |
| Disk join | display/path fallbacks | stable source key plus device assertion |
| RBD identity | transient `/dev/rbd` may be persisted | canonical `rbd:` locator |
| Device access | assumes mapping exists | provider preflight and Run-owned JIT mapping |
| V2K reuse | real path diverges from proven primitives | reuse helper libraries, not migration workflow |
| Success point | guest preparation may look like Failover completion | `CUTOVER_READY`; Cloud owns boot and promotion |
| Failure | stale running worker and ambiguous cleanup | terminal typed status and ownership cleanup |
| Checkpoint | runtime latest may be implied | explicit target-ready, locally durable selection |

## 11. Implementation and package verification (2026-07-22)

- Added `guestprep_manifest.py` to join the authoritative Plan profile,
  durable restore point, and runtime disk map into
  `FTCTL_GUESTPREP_MANIFEST_V2`.
- Canonicalized RBD locators to `rbd:pool/image`, rejected display-only
  locators, preserved VMware EFI/Secure Boot, and emitted `io_uring` plus
  per-disk I/O-thread metadata.
- Added provider validation, typed exit codes, terminal worker-state cleanup,
  source-isolation verification, and manifest/checkpoint fields in status.
- Targeted self-tests passed for VMware boot-contract preservation, V2 disk-map
  normalization, and planned-failover checkpoint promotion.
- GitHub Actions run `29891374059`, job `build-ftctl-rpm`, completed
  successfully from commit `a0656f8`.
- Package: `ablestack_vm_ftctl-0.9.1-1.noarch.rpm`.
- SHA-256:
  `2cb386ec636015d592df21224ff40d22102ad2900e6b7e40fc72ac6df5f21bfe`.
- Package content inspection confirmed `dr_runtime.sh`, `guestprep.sh`, and
  `guestprep_manifest.py` are present.

## 12. Live deployment and preflight verification (2026-07-22)

- Host connectivity was restored and the package was installed on
  `10.10.32.1/2/3` with `aspkg`.
- `mold-agent` and `ablestack-vm-ftctl.timer` are active on all three hosts.
- Installed runtime files contain `guestprep_manifest.py` and the
  `cutover-manifest-v2` capability.
- A live manifest was built and validated from Plan
  `2514a846-64a2-4bc7-ba88-38a874410782` at durable checkpoint 418.
- The manifest preserved Windows guest identity, EFI/Secure Boot, four CPUs,
  8192 MiB memory, `io_uring`, I/O threads, and two canonical RBD locators.
- Provider validation confirmed the 100 GiB and 50 GiB RBD images exist and
  exactly match the manifest sizes.
- Recovery cycle 419 completed as a full reseed and the immediately following
  cycle 420 completed through the CBT incremental path.
- The scheduler remains `RUNNING/HEALTHY`, replication is idle between cycles,
  and no FTCTL runtime error is present.

Live deployment and cutover-manifest preflight are therefore PASS. The next
operator action is a new planned failover run using the restored Plan state;
that mutable action is intentionally left for the retest itself.

## 13. Cloud promotion acknowledgement contract

### 13.1 Boundary clarified by live failover

The live planned failover reached `CUTOVER_READY` at checkpoint 439 and Cloud
successfully started the existing target VM. FTCTL correctly did not control
the Cloud VM lifecycle, but its Plan authority state remained
`active_side=SOURCE` and `target_power_state=POWERED_OFF` after Cloud committed
`FAILED_OVER/TARGET`. This stale mirror is unsafe for diagnostics and for the
next failback/reprotect transition.

FTCTL therefore needs a post-promotion acknowledgement command. The command
does not promote or start the VM; it records a Cloud authority decision that
has already been committed.

### 13.2 CLI and capability

Add this command to `ablestack_vm_ftctl`:

```text
dr-cutover-commit
  --plan UUID
  --run UUID
  --checkpoint-sequence N
  --manifest-sha256 HEX
  --authority-generation N
  --active-side TARGET
  --target-power-state POWERED_ON
  --boot-validation-state SUCCEEDED
  --target-power-on-at ISO8601
  --failover-completed-at ISO8601
  --json
```

Advertise command support and `cloud-cutover-commit-v1` through
`dr-capabilities`. Bump the action contract version. Older packages cause Cloud
to keep the Run at `engine-state-reconciliation`; they must not cause Cloud to
power off a successfully started target.

### 13.3 Validation and idempotency

`ftctl_dr_runtime_cutover_commit()` loads the existing failover state and
requires:

- matching Plan and failover Run UUIDs;
- state `CUTOVER_READY` or an acknowledgement state for idempotent replay;
- matching `guestprep_checkpoint_sequence`;
- matching 64-character `manifest_sha256`;
- `active-side=TARGET`, `target-power-state=POWERED_ON`, and a successful boot
  validation result;
- a Cloud authority generation greater than or equal to the stored generation.

Reject mismatches with typed errors:

```text
DR_CUTOVER_SESSION_MISMATCH
DR_CUTOVER_CHECKPOINT_MISMATCH
DR_CUTOVER_MANIFEST_MISMATCH
DR_CLOUD_AUTHORITY_STALE
DR_BOOT_VALIDATION_NOT_SUCCEEDED
```

An equal generation with identical values returns success without rewriting
history. An equal generation with different values is a conflict. A newer
generation is applied atomically with a temporary file plus rename.

### 13.4 Persisted runtime result

On success, update both the failover Run state and Plan authority state:

```text
action=dr-cutover-commit
state=FAILED_OVER_ACKNOWLEDGED
step=cloud-promotion-acknowledged
progress=100
active_side=TARGET
target_power_state=POWERED_ON
target_promotion_state=PROMOTED
boot_validation_state=SUCCEEDED
cloud_authority_generation=<N>
target_power_on_at=<time>
failover_completed_at=<time>
scheduler_state=STOPPED
scheduler_health=STOPPED_AFTER_CUTOVER
scheduler_recovery_state=STOPPED_AFTER_CUTOVER
worker_state=SUCCEEDED
error_code=
error_message=
```

Preserve the latest durable checkpoint, baseline metadata, restore-point
history, and source-isolation evidence. Do not restart the forward scheduler.
Do not call libvirt, `virsh`, Mold, or vCenter from this command.

### 13.5 Status semantics

`dr-status` continues to expose the engine preparation phase separately from
the Cloud acknowledgement:

- `cutover_engine_state=CUTOVER_READY`;
- `cloud_promotion_state=PROMOTED`;
- `engine_ack_state=ACKNOWLEDGED`;
- `protection_state=FAILED_OVER_UNPROTECTED`;
- `active_side=TARGET`.

`FAILED_OVER_UNPROTECTED` is not an error. It means the target is active and
the old forward scheduler is intentionally stopped while reverse protection is
not yet established. The RPO age of the old forward direction must not be used
as a live health failure after acknowledgement.

### 13.6 Agent transport contract

Cloud sends the acknowledgement through `FtctlDrActionCommand.Action` as
`CUTOVER_COMMIT`. The KVM wrapper adds the CLI arguments above from non-secret
command context. Existing timeout and output-size limits apply. The Agent
returns the typed JSON result unchanged; it does not inspect or modify VM state.

### 13.7 Self-tests

Add FTCTL self-tests for:

1. valid CUTOVER_READY to acknowledged transition;
2. exact idempotent replay;
3. stale Cloud generation rejection;
4. checkpoint mismatch rejection;
5. manifest hash mismatch rejection;
6. boot-validation failure rejection;
7. preservation of checkpoint/baseline/restore-point files;
8. no scheduler restart and no libvirt command execution;
9. `dr-status` separation of engine, Cloud promotion, and protection states.

Cloud wrapper tests verify every CLI argument and capability mismatch. The live
Plan `2514a846-64a2-4bc7-ba88-38a874410782` is the read-only preflight fixture:
checkpoint 439, Windows V2 manifest, two RBD disks, source powered off, target
Running, and FTCTL CUTOVER_READY.

### 13.8 AS-IS / TO-BE

| Area | AS-IS | TO-BE |
|---|---|---|
| Lifecycle ownership | FTCTL stops at CUTOVER_READY | unchanged; Cloud remains the sole target VM owner |
| Final authority mirror | SOURCE/POWERED_OFF remains in runtime | Cloud promotion is acknowledged as TARGET/POWERED_ON |
| Command model | no post-promotion command | idempotent `dr-cutover-commit` |
| Protection state | stopped scheduler appears degraded | explicit `FAILED_OVER_UNPROTECTED` |
| RPO | forward checkpoint age continues growing | cutover RPO freezes until reverse protection starts |
| Retry | no durable acknowledgement cursor | monotonic Cloud authority generation |
| Safety | later actions infer from stale fields | failback/reprotect receive a reconciled target-active profile |
