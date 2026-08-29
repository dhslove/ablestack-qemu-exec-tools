# FTCTL DR SharedMountPoint QCOW2 Push Backup Design

## 1. Scope

This design adds the ABLESTACK KVM `qcow2 -> qcow2` data plane for
cluster-scoped `SharedMountPoint` storage. It applies to the existing plan
`41886f03-c19e-4382-927d-89bc4d6ce8e9` and must not create another DR site or
plan.

The first validated path is:

| Role | Site | Storage |
| --- | --- | --- |
| Source | 13 ABLESTACK Cluster | `/mnt/glue-gfs`, GFS2, SharedMountPoint, qcow2 |
| Target/controller | 31 ABLESTACK Cluster | `/mnt/glue-gfs`, GFS2, SharedMountPoint, qcow2 |

The VMware-to-RBD and RBD-to-RBD providers remain unchanged behavioral
contracts. Provider selection happens from canonical disk capabilities, not
from plan direction alone.

## 2. Verified Runtime Contract

Read-only preflight on source VM `i-2-13-VM` verified QEMU 9.1 and libvirt
10.10. The active root node is qcow2 and QMP exposes persistent dirty bitmap,
NBD block export, and block backup commands. A throwaway qcow2 preflight also
verified `qemu:dirty-bitmap:<name>` metadata export.

The implementation uses QEMU's push-backup model rather than external snapshot
chains:

1. The target Agent creates or validates the Cloud-owned target qcow2 file.
2. The target Agent exports that file as writable NBD.
3. The source Agent adds the target NBD endpoint as a temporary QEMU block node.
4. Full seed first creates a recording persistent bitmap, or clears the
   existing healthy bitmap for an explicit reseed, and then starts
   `blockdev-backup sync=full`. Writes between these commands and while the
   backup runs remain marked for the next incremental cycle; copying an extent
   twice is safe, while losing an extent is not.
5. Incremental cycles use `blockdev-backup sync=incremental` with the same
   persistent bitmap. QEMU clears only committed bits and retains writes that
   occur while the job runs.
6. The temporary target node is removed after a terminal job result. The
   source VM disk graph and Cloud volume path are not changed.

This avoids unmanaged external overlays and preserves Cloud ownership and live
migration behavior.

## 3. Provider Boundary

| Source type | Target type | Tracker/writer |
| --- | --- | --- |
| `rbd` | `rbd` | Existing RBD snapshots and `rbd diff` |
| `rbd` | remote NBD | Existing RBD snapshot plus extent copier |
| `file/qcow2` | remote NBD backed by `file/qcow2` | New QMP persistent bitmap push backup |
| other | any | Explicit unsupported/preflight failure |

No file-backed request may enter an RBD snapshot function. No RBD request may
enter the qcow2 bitmap provider.

## 4. Bitmap and Job Rules

- Bitmap name is deterministic per plan and disk and is persisted in qcow2.
- The bitmap must be `recording=true`, `persistent=true`, `busy=false`, and
  `inconsistent=false` before an incremental cycle.
- A full reseed establishes the bitmap before copying. The full target is the
  durable base and any concurrent or boundary write remains marked for the
  following incremental cycle.
- An incremental failure does not clear the bitmap. The same cycle can be
  retried without losing changes.
- A successful job is accepted only from a terminal `query-jobs` record with no
  error. Request acceptance alone is not success.
- Target NBD reachability, target format, virtual size, source node identity,
  and bitmap health are mandatory preflight checks.
- Job timeout and cancellation are retryable engine failures; they do not
  silently fall back to an RBD or host-local path.

## 5. Target Export

`dr-target-export-start` accepts:

- existing `rbd` target: unchanged librbd-backed qemu-nbd invocation;
- `file` target: absolute SharedMountPoint path, qcow2 format, and valid size.

The file target is created with `qemu-img create -f qcow2` only when absent.

## Test failover artifact isolation

A SharedMountPoint target remains opened by the target-side replication writer.
`qemu-img create -b <target>` is therefore both lock-sensitive and unsafe for a
long-running test: later replication writes could change the backing data seen
by the test VM.

For `provider=FILE`, test failover now uses the following contract after the
scheduler pause and durable-checkpoint lease have completed:

1. Open the durable target read-only with `qemu-img info --force-share`.
2. Create an independent sparse qcow2 copy with
   `qemu-img convert --force-share -f <format> -O qcow2 -S 4k`.
3. Validate the copy with `qemu-img check -q`.
4. For a Cloud-managed file pool, place the copy directly under the validated
   target `storagePath`. The Plan/Run-owned filename starts with
   `ftctl-dr-test-`; this makes the artifact discoverable as a libvirt volume
   after the SharedMountPoint pool refresh. Runtime-private paths under `/run`
   must never be published as Cloud disk locators.
5. Publish the absolute `qcow2-copy` path together with `storageRoot` and
   `ownedByFtctl=true`, and attach only that path to the Cloud test VM.
6. Delete only the owned independent copy during Test Cleanup. Cleanup accepts
   an external file only when its parent is exactly `storageRoot`, its basename
   has the FTCTL test prefix, and the ownership flag is true.

The live durable target is never used as a mutable backing file. RBD continues
to use its validated snapshot/clone path unchanged.
Existing files are format- and size-validated. The export manifest records
`targetType` and `targetFormat` so Cloud and the source Agent can reject stale
or mismatched exports.

## 6. Failover, Failback, and Release

Target VM creation remains Cloud-owned. FTCTL prepares and transfers disk data
but does not create or delete Cloud VM/volume rows. Test failover, cleanup,
failover, failback, reprotect, release, and delete continue through the Cloud
orchestrator and Agent actions.

Failback reverses the same provider contract. A retained target qcow2 becomes
the source file and the original SharedMountPoint qcow2 becomes the exported
target. Resource disposition remains an explicit Cloud/UI choice.

## 7. Regression Gates

Before deployment:

1. Existing RBD remote and site-Agent smoke tests pass unchanged.
2. New file target export tests prove no RBD helper is called.
3. Bitmap job tests cover full, incremental, retry after failure, timeout, and
   inconsistent bitmap rejection.
4. Release tombstone and baseline action-contract suites pass.
5. The active UI is verified with the existing plan; no replacement plan is
   created.

## 8. Implementation Record

- `lib/ftctl/qcow2_bitmap_backup.py` resolves the active qcow2 QEMU node,
  maintains the persistent bitmap, attaches the target NBD node, runs the
  backup job, and writes the standard transfer-progress journal.
- `lib/ftctl/dr_ablestack.sh` dispatches only
  `file/qcow2 -> file/qcow2` site-Agent requests to that helper. Existing RBD
  functions and command lines remain intact.
- `tests/ftctl_qcow2_bitmap_backup_test.py` covers full, incremental,
  inconsistent, and missing-baseline contracts.
- `tests/ftctl_dr_ablestack_qcow2_shared_smoke.sh` proves the canonical provider
  selection while the existing remote-RBD and release-tombstone tests remain
  release gates.

Live read-only schema verification on `i-2-13-VM` confirmed the exact QEMU 9.1
arguments for `blockdev-add`, `blockdev-backup`, bitmap commands, `query-jobs`,
and job dismissal. The production bitmap is not created until the existing
plan starts its first full synchronization.

A destructive-to-temporary-resources live preflight then used a 64 MiB qcow2
disk on 13.1 and a 64 MiB qcow2 target on 31.2. The temporary source VM booted
a generated initramfs and issued a real 1 MiB guest write after full seed. The
persistent bitmap reported exactly 1 MiB, the incremental job completed as
`CBT_INCREMENTAL`, and independently materialized raw images on both hosts had
the same SHA-256:
`3b6a07d0d404fab4e23b6d34bc6696a6a312dd92821332385e5af7c01c421351`.
The test used the deployed FTCTL NBD firewall range (`10809..10872`); an
out-of-range port was correctly unreachable. All transient domain, bitmap,
NBD export, qcow2, initramfs, and raw comparison files were removed by the
preflight cleanup path.

## 9. AS-IS / TO-BE

| Area | AS-IS | TO-BE |
| --- | --- | --- |
| Remote KVM source format | SharedMountPoint volume reported as raw | Report qcow2 with absolute source path |
| Target export | RBD-only | RBD unchanged plus isolated file/qcow2 export |
| Incremental tracker | RBD snapshots only | RBD unchanged plus QMP persistent bitmap |
| Full seed consistency | `qemu-img --force-share` read of live file | QEMU push backup point-in-time job |
| Target ownership | Ambiguous before materialization | Cloud-owned file, volume, and VM throughout |
| Test object | New plan could hide old mapping defects | Existing plan UUID only |

## 10. Test Artifact Consumer and Terminal Error Contract

The SharedMountPoint Test Failover producer publishes an independent
`qcow2-copy`. The guest-preparation manifest consumer must recognize that
artifact as the canonical immutable file-backed test disk. It applies the same
absolute-path, positive-size, `file/qcow2` validation used for a validated
file artifact; it must not reinterpret the copy as an overlay or enter an RBD
locator path.

Manifest construction failures are authoritative FTCTL operation failures.
The manifest helper's structured `errorCode`, `message`, and exit code are
written to the owning Run before the shell action terminates. The outer Test
Failover action preserves those fields instead of replacing them with the
generic guest-runtime error. Cloud can therefore project the exact terminal
failure and the UI can show the actionable cause while remaining asynchronous.

Regression coverage consumes the `qcow2-copy` session emitted by the existing
Test Failover materialization self-test and builds a real guest-preparation
manifest from it. Existing `rbd-clone` and `qcow2-overlay` validation remains
unchanged.

| Area | AS-IS | TO-BE |
| --- | --- | --- |
| FILE artifact producer | Publishes `qcow2-copy` | Unchanged |
| Guest-preparation consumer | Rejects `qcow2-copy` as unsupported | Accepts an absolute, positive-size `file/qcow2` copy |
| Shell error propagation | Collapses manifest exit 63 into exit 47 | Preserves structured code, message, and original exit code |
| Cloud/UI evidence | Accepted Run can hide a later FTCTL terminal error | Exact terminal evidence is available for asynchronous projection |
| Existing providers | Shared helper risks broad behavior changes | RBD and VMware contracts remain unchanged |
| SharedMountPoint locator | Runtime-private `/run/...` copy is invisible to the libvirt storage pool | Copy resides in the validated pool root and is imported by its absolute path |
| FILE cleanup | Session directory cleanup cannot remove a pool-root artifact safely | Exact owned file is removed using root, prefix, and ownership guards |

## 11. Native KVM Guest Compatibility Contract

SharedMountPoint qcow2 Test Failover for `KVM_TO_KVM` preserves the source
guest's native KVM compatibility. FTCTL still builds and validates the
guest-preparation manifest and validates every independent test artifact, but
it does not run the VMware-to-KVM initramfs or WinPE conversion routines.

The runtime records `guest_prep_state=SKIPPED` and
`guest_prep_reason=NATIVE_COMPATIBILITY_PRESERVED`. Cloud may then import the
validated absolute qcow2 artifact and own test VM creation and boot validation.
The `VMWARE_TO_KVM` path remains unchanged and must continue to run the Linux
initramfs or Windows WinPE preparation before Cloud materializes the VM.

| Provider path | Guest preparation |
| --- | --- |
| VMware to KVM | Required; existing v2k conversion path |
| ABLESTACK KVM to KVM | Skipped after manifest and artifact validation |

Regression coverage must prove that a KVM-to-KVM test session passes preflight
without a v2k conversion runtime, while a VMware-to-KVM session still fails
with `DR_GUEST_PREP_V2K_RUNTIME_MISSING` when that runtime is absent.

## 12. Immutable Per-Cycle Checkpoint and Boot-Readiness Contract

The test artifact is a consumer of one durable replication Cycle. It must not
be copied from the mutable target writer file while that writer is open, even
with `--force-share`. A qcow2 container check alone cannot prove guest
filesystem consistency; the failed live test showed valid qcow2 metadata with
an inconsistent XFS log in `/boot`.

For `KVM_TO_KVM` with `provider=FILE` only, Test Failover therefore uses this
ordered contract:

1. Cloud pauses the remote source scheduler and waits for its acknowledged
   idle state.
2. Cloud stops the Plan-owned target NBD export and waits for the writer to
   drain. This `TEST_FAILOVER` stop is idempotent and never prepares a reverse
   Failover baseline, even if an older controller supplies a checkpoint
   sequence. Reverse-baseline preparation remains exclusive to an actual
   Failover transition.
3. FTCTL acquires the selected durable checkpoint lease before reading any
   target disk.
4. FTCTL seals each selected disk to
   `<storageRoot>/.ftctl-dr-checkpoints/<plan>/<sequence>/<device>.qcow2`.
   A temporary file is converted and checked, file and directory data are
   synced, and only then is it atomically renamed. Metadata binds plan,
   sequence, checkpoint reference, source path, virtual size, and contract
   SHA-256.
5. A disposable overlay backed by the sealed checkpoint is inspected with
   libguestfs. Filesystem discovery and read-only mount must succeed. Where a
   journal replay is required, it occurs only in the disposable overlay; the
   sealed checkpoint is never modified.
6. The published test disk is a separate writable qcow2 overlay backed by the
   sealed checkpoint. Cloud may create the test VM only after the integrity
   state is `PASSED`.
7. Test Cleanup removes the test overlay and its Cloud VM. Cloud then restores
   the target export and resumes the remote source scheduler. The sealed Cycle
   remains available for deterministic retry and is retired only by an
   explicit retention policy.

The selected sequence in the controller artifact contract, FTCTL session,
lease, sealed metadata, and UI evidence must be identical. Any mismatch is a
terminal `DR_TEST_CHECKPOINT_SEQUENCE_MISMATCH`. A failed filesystem probe is
`DR_TEST_CHECKPOINT_GUEST_FS_INCONSISTENT`; missing inspection tools are
`DR_TEST_CHECKPOINT_INSPECTOR_UNAVAILABLE`.

RBD and VMware providers do not enter this lifecycle. Their existing
snapshot/clone and VDDK contracts are unchanged.

| Area | AS-IS | TO-BE |
| --- | --- | --- |
| Writer ordering | Copy mutable target, acquire lease later | Pause, drain writer, acquire lease, then seal |
| Cycle identity | Artifact path is unrelated to checkpoint sequence | Plan/sequence/device is the canonical immutable identity |
| Test disk | Independent copy of a mutable source | Writable overlay of a sealed checkpoint |
| Integrity gate | `qemu-img check` only | qcow2 check plus disposable guest-filesystem probe |
| UI evidence | VM creation can start without checkpoint proof | Sequence, seal, and integrity PASS precede VM creation |
| Cleanup | Removes only test copy | Removes test overlay, restores export, resumes scheduler |

The action intent is a hard safety boundary. FTCTL reads
`request.actionIntent` from the command profile before it evaluates a supplied
checkpoint sequence. `TEST_FAILOVER` returns `STOPPED` after the writer drain
with `reverse_baseline_state=NOT_REQUESTED`; `FAILOVER` preserves the existing
sequence-bound reverse-baseline behavior. This prevents immutable-checkpoint
preparation from being rejected by an unrelated RBD reverse-baseline probe and
does not alter the validated RBD or VMware transfer paths.

## Checkpoint publication invariance hardening (2026-08-29)

The first UI retest exposed a gap in the earlier seal contract. The Cloud Run,
test session, qcow2 container check, OS discovery, and power-state validation
all succeeded, but the guest entered emergency mode. Direct inspection proved
that the sealed checkpoint had an inconsistent `/boot` XFS filesystem while a
fresh QMP backup of the source and the drained canonical target mounted
normally. The sealed image also differed from the canonical target beginning
at byte offset 69632.

For `provider=FILE` the following conditions are now publication barriers:

1. The target canonical file has no local writable file descriptor. The
   controller's `DRAINED` claim is necessary but is not accepted as sufficient
   evidence by itself.
2. File and parent-directory data are synchronized before source metadata is
   captured.
3. Because this path is qcow2 to qcow2, the qcow2 container is copied into an
   unpublished temporary file with sparse/reflink preservation. Image-format
   conversion is forbidden at this checkpoint boundary.
4. `qemu-img check` must pass and `qemu-img compare` must prove byte-for-byte
   equivalence with the drained canonical target.
5. A disposable overlay is inspected before the immutable file is published.
   Linux guests must permit read-only inspection of `/etc/fstab` and `/boot`;
   mount warnings such as `Structure needs cleaning` are terminal integrity
   failures.
6. Only after every gate passes are the checkpoint and its version-2 metadata
   atomically published. Metadata binds source file size and nanosecond mtime
   in addition to the existing Plan, sequence, reference, path, format, and
   virtual-size contract.
7. Reuse of an existing per-cycle checkpoint repeats the content comparison
   and guest-filesystem gate. Metadata equality alone never authorizes reuse.

The immutable path remains
`.ftctl-dr-checkpoints/<plan>/<sequence>/<device>.qcow2`. A failed temporary
checkpoint is removed before returning an error; a previously published but
invalid checkpoint is not silently overwritten. It is retired only after the
failed test session is cleaned and no lease references it.

| Condition | Error |
| --- | --- |
| canonical target still writable | `DR_TEST_CHECKPOINT_WRITER_NOT_DRAINED` |
| copied guest-visible bytes differ | `DR_TEST_CHECKPOINT_CONTENT_MISMATCH` |
| guest filesystem mount or inspection fails | `DR_TEST_CHECKPOINT_GUEST_FS_INCONSISTENT` |
| same sequence resolves to changed source metadata | `DR_TEST_CHECKPOINT_SEQUENCE_MISMATCH` |

This hardening is intentionally scoped to SharedMountPoint FILE checkpoints.
The validated RBD clone and VMware/VDDK paths do not call this publisher and
remain behaviorally unchanged.

## SharedMountPoint cutover reverse baseline contract (2026-08-29)

An actual FILE-provider Failover must establish the reverse incremental
baseline before Cloud starts the promoted target VM. The former implementation
called the RBD snapshot baseline helper unconditionally from
`dr-target-export-stop`; a SharedMountPoint qcow2 path therefore returned exit
32 after the writer was drained and left the Cloud Run at `final-delta-apply`.

The provider-specific contract is now:

1. Canonicalize a relative Cloud volume path beneath the source
   `SharedMountPoint` storage root. Paths outside that root are rejected.
2. Stop the Plan-owned NBD export and prove that the promoted qcow2 has no
   writable file descriptor.
3. Add or verify one persistent, enabled QEMU dirty bitmap whose identity is
   derived from `(plan, disk)`. The operation is idempotent for projection
   retries.
4. Persist the reverse baseline state only after every disk has a valid qcow2
   container and matching bitmap granularity.
5. Permit Cloud target-VM start and authority commit only after this barrier.
   Writes made after promotion are then accumulated by the embedded bitmap and
   are eligible for incremental reprotect/failback.
6. `dr-reverse-preflight` reports `QCOW2_INCREMENTAL` only when the retained
   source file and every persistent bitmap pass validation. Missing or
   inconsistent evidence requires a full reseed; it must not be labelled as an
   RBD baseline.

RBD disks continue to use the established paired snapshot baseline functions.
`TEST_FAILOVER` continues to skip reverse-baseline preparation. No FILE helper
is reachable from VMware/VDDK or RBD provider dispatch.

| Area | AS-IS | TO-BE |
| --- | --- | --- |
| provider dispatch | every cutover uses RBD snapshots | RBD snapshots or FILE persistent bitmap |
| relative source locator | unresolved Cloud volume path | canonical path below SharedMountPoint root |
| retry | repeated exit 32 after export drain | idempotent bitmap verification and completion |
| failback mode | RBD label or full seed | `QCOW2_INCREMENTAL` with durable bitmap evidence |

### Package deployment firewall invariant

Installing or upgrading FTCTL must not call `firewall-cmd --reload`. A reload
removes libvirt's dynamic `libvirt-out` and per-interface filter chains while
existing guests continue to run, causing the next promoted VM start to fail.
The package helper writes the permanent service definition and applies the
service, or its explicit ports when the runtime definition is not yet known,
to active zones without reloading firewalld. The no-reload smoke test is a
release gate.

## Reprotect Authority Contract Compatibility (2026-08-29)

The existing 13-to-31 SharedMountPoint plan exposed a rolling contract mismatch
after Failover. Cloud emitted Reprotect authority contract `2026-08-26`, while
the FTCTL authority persistence gate accepted only `2026-07-23`. Both versions
carry the same fields consumed by FTCTL: target active side, authority
generation, cutover session, checkpoint sequence, and target VM identity.

FTCTL therefore owns one explicit compatible-version list and uses it for both
authority persistence and the `dr-capabilities` response. The older value
remains accepted for previously validated VMware/RBD and RBD/RBD plans, while
the newer value allows the current Cloud producer to reach the same strict
field validation. Cloud must select a writer version advertised by the
coordinator before dispatch. Unknown versions remain rejected with exit code
79. This change does not alter checkpoint selection, qcow2 bitmap baseline,
transfer ordering, target materialization, or authority generation.

| Area | AS-IS | TO-BE |
|---|---|---|
| FTCTL contract gate | Parser owns an isolated literal | One runtime list drives parser and capabilities |
| Existing plans | Depend on the old literal | Old literal remains valid |
| Current Cloud | Reprotect rejected before authority capture | New literal reaches the same field checks |
| Unknown contract | Rejected | Still rejected fail-closed |

The release gate must consume the advertised list, exercise every supported
version and reject one unsupported version before packaging. It must also run
the VMware-to-RBD action contract and ABLESTACK RBD-to-RBD reverse transport
smokes. Runtime PASS still requires the existing 31 UI plan to complete
Reprotect and then Failback; unit acceptance alone is insufficient.

### Capability publication invariant

`dr-capabilities` is the sole pre-action compatibility contract consumed by
Cloud. The authority parser and the published
`reprotect_authority_contract_versions` array are generated from the same
FTCTL variable, so adding a reader version cannot update one surface while
leaving the other stale. The Agent wrapper validates only command/spec equality
and mandatory fields; it does not own another date literal.

Cloud may cache the response briefly for menu rendering, but FTCTL repeats the
same validation at execution to protect against a rolling upgrade between menu
render and submission. Package creation runs the advertised-version smoke plus
the existing VMware-to-RBD, remote RBD-to-RBD, and SharedMountPoint gates.

## Live reverse-source preflight contract (2026-08-29)

After failover, the promoted SharedMountPoint qcow2 is normally opened for
write by the running target VM. Failback readiness therefore must not use a
metadata probe that requires an exclusive or shared write lock.

1. Verify that the canonical source locator is an existing regular file below
   the declared SharedMountPoint root.
2. Read its format through the common bounded
   `qemu-img info --force-share --output=json` helper.
3. Report `DR_REVERSE_SOURCE_STORAGE_MISSING` only when the file is absent or
   inaccessible. A live-writer lock is not missing storage.
4. Reject an accessible non-qcow2 file as an incompatible reverse source; do
   not silently reinterpret it as qcow2.

The Cloud/Agent profile remains forward-oriented. Consequently the promoted
`mapping.disks[].targetPath` below `target.storagePath` is the reverse source
for this check. The original `sourcePath` may be absent after loss of the
original site and must not block Failback. This is the same locator invariant
used by the RBD branch and the runtime reverse-profile builder.

Provider selection follows the same authority boundary. Forward qcow2 transfer
requires both source and target capabilities, while reverse preflight classifies
the promoted source exclusively from `targetType=file` and
`targetFormat=qcow2`. A missing original file must not erase the retained target
format and route the check through the RBD probe.

This preflight is the read-only capability gate used before the Failback menu
submits a Run. The execution path repeats the same invariant as a final TOCTOU
guard. VMware and RBD locators keep their existing provider-specific probes.

### Plan authority projection invariant

An accepted authority contract is operation evidence and Plan capability
evidence at the same time. FTCTL persists `cloud_authority_generation` and
`cloud_authority_sequence_floor` in both the operation Run and the Plan status,
using a monotonic maximum so a delayed or retried command cannot lower either
value. Plan-scoped `dr-status` and Cloud pre-action capability evaluation must
therefore observe the same floor that the execution guard accepted.

This prevents a completed Run from disappearing before menu evaluation and
making the Plan fall back to an older scheduler sequence. The execution guard
remains mandatory as a final time-of-check/time-of-use validation, but it is no
longer the first place where an incompatible action is discovered.

## Cloud VM Detail authority boundary

For `KVM_TO_KVM`, Cloud and the source Mold API own VM Detail capture and
target VM Detail restoration. FTCTL must not infer firmware, TPM, controller,
or I/O policy from the guest OS and must not translate Cloud's `UEFI` Detail
into private `bootType` or `bootMode` keys. FTCTL transports and seals disk
checkpoints; Cloud materializes the VM from the source Detail snapshot.

The only FTCTL-visible requirement is ordering: Cloud completes its read-only
source Detail preflight before checkpoint consumption, and it verifies the
materialized VM Detail manifest before allowing test failover or failover to
cross the boot gate. This keeps the existing VMware-to-RBD transport and
RBD-to-RBD checkpoint contracts unchanged while applying one VM metadata rule
to both SharedMountPoint qcow2 and RBD ABLESTACK targets.
