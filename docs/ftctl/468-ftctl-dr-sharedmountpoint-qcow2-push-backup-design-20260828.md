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
