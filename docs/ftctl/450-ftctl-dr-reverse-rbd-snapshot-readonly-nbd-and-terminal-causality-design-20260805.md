# 450. FTCTL DR Reverse RBD Snapshot Read-Only NBD And Terminal Causality Design

- Date: 2026-08-05
- Status: read-only and terminal-grace baseline; worker identity reconciliation is superseded by document 451
- Scope: KVM-to-VMware reverse transfer, RBD snapshot NBD attachment, worker terminal evidence
- Parent: [448-ftctl-dr-initial-reverse-seed-baseline-absence-and-terminal-evidence-design-20260804.md](448-ftctl-dr-initial-reverse-seed-baseline-absence-and-terminal-evidence-design-20260804.md)
- Runtime boundary: [449-ftctl-dr-live-runtime-observation-and-projection-boundary-design-20260804.md](449-ftctl-dr-live-runtime-observation-and-projection-boundary-design-20260804.md)
- Cloud companion: `ablestack-cloud/docs/ftctl/593-cross-hypervisor-dr-failback-reverse-rbd-readonly-and-terminal-causality-design-20260805.md`
- Worker identity correction: [451](451-ftctl-dr-worker-identity-live-transfer-and-terminal-reconciliation-design-20260805.md)
- Route envelope correction: [452](452-ftctl-dr-failback-route-envelope-and-cloud-lifecycle-boundary-design-20260805.md)

## 1. Objective

The first KVM-to-VMware reverse seed must read a point-in-time RBD snapshot
through a read-only NBD attachment, write the selected extents through the
VMware VDDK writer, and publish one authoritative terminal result before any
watchdog or Cloud data gate can derive a secondary failure.

This design corrects two independent defects found in the same Failback Run:

1. the RBD snapshot was opened by `qemu-nbd` without `--read-only`; and
2. an early dead-PID observation was projected before the mover published its
   typed terminal result, allowing a generic worker error to hide the actual
   data-path error.

## 2. Verified live incident

Plan `7889e625-371a-48f9-b553-54e311481170` created Failback Run
`8e413a38-981a-4c64-8b93-f62140c6c986`.

| Evidence | Observed value |
|---|---|
| Cloud dispatch | asynchronous request accepted |
| Agent host | `10.10.32.2`, accepted |
| Operation intent | `FAILBACK_FINAL` |
| Requested mode | `AUTO` |
| Effective mode | `FULL_REVERSE_SEED` |
| Mode decision | `INITIAL_REVERSE_BASELINE_MISSING` |
| Source disk probe | `READY`, two RBD disks |
| VMware writer probe | `READY` |
| New RBD snapshots | created for both disks |
| Mover failure | exit `86`, `DR_REVERSE_SNAPSHOT_OR_NBD_FAILED` |
| Direct stderr | `rbd snapshots are read-only` |
| Synthetic status seen first | exit `70`, `DR_FAILBACK_WORKER_EXITED` |
| Authority after failure | TARGET retained |
| KVM VM | running |
| VMware VM | powered off |
| Residue | no RBD snapshot, NBD attachment, or block job remained |

The deployed failure is at
`lib/ftctl/dr_kvm_vmware_mover.sh:130`:

```bash
qemu-nbd --connect="${source_dev}" --format=raw "${source_uri}"
```

`source_uri` includes `@${new_snapshot}`. Ceph RBD snapshots are immutable, so
QEMU must open this source with read-only semantics.

## 3. Verified preflight result

A temporary snapshot of `rbd/w22-01-dr-disk-0` was attached on the deployed
host with:

```bash
qemu-nbd --read-only --connect=/dev/nbd15 --format=raw \
  rbd:rbd/w22-01-dr-disk-0@codex-ro-preflight-20260805
```

After udev settled, `/dev/nbd15` reported `107374182400` bytes, matching the
100 GiB source image. The NBD device was disconnected and the temporary
snapshot was removed. No residual process or snapshot remained.

This proves the required source-open mode in the actual package environment;
it does not by itself prove VDDK write completion or Failback success.

## 4. Safety invariants

1. Every RBD snapshot used as a reverse-transfer source is opened read-only.
2. A VMware VDDK target remains the only writable side of the mover pair.
3. NBD readiness requires the expected non-zero virtual size, not merely a
   successful `qemu-nbd` process start.
4. A newly created snapshot is uncommitted until every disk write is flushed
   and verified.
5. Any pre-commit failure disconnects both NBD roles, terminates the VDDK
   writer, removes only run-created snapshots, and preserves the prior durable
   baseline.
6. TARGET authority and the running KVM VM are preserved until
   `FAILBACK_DATA_READY` is durably published.
7. A typed mover terminal result is authoritative over a PID-derived fallback.
8. A status reader never synthesizes a terminal failure while the worker is
   still inside the terminal-publication grace window.
9. One Run has one canonical terminal cause. Later derived checks may add
   diagnostics but cannot replace it.

## 5. Corrected data path

```text
Cloud start-only FAILBACK
  -> Agent accepts Run UUID
  -> FTCTL locks Plan and repeats reverse preflight
  -> AUTO + missing baseline => FULL_REVERSE_SEED
  -> create immutable RBD snapshot for each source disk
  -> allocate source NBD
  -> qemu-nbd --read-only opens rbd:<pool>/<image>@<snapshot>
  -> wait for expected virtual size
  -> start writable VDDK nbdkit target
  -> copy selected extents source NBD -> target NBD
  -> flush and verify every VMware disk
  -> atomically commit reverse baseline generation 1
  -> publish FAILBACK_DATA_READY terminal evidence
  -> Cloud performs power/authority transition
```

No Cloud or UI component opens RBD, NBD, VDDK, or VMware disks directly.

## 6. Code-level FTCTL design

### 6.1 `lib/ftctl/dr_kvm_vmware_mover.sh`

Introduce one source-only attachment helper:

```bash
ftctl_kvm_vmware_attach_snapshot_readonly() {
  local source_dev="$1" source_uri="$2" error_log="$3"
  local -a args=(
    --read-only
    --connect="${source_dev}"
    --format=raw
    --cache=none
    "${source_uri}"
  )
  qemu-nbd "${args[@]}" > /dev/null 2>"${error_log}"
}
```

`ftctl_kvm_vmware_patch_disk()` uses the helper instead of invoking
`qemu-nbd` directly. The helper is intentionally not shared with writable
target attachment code.

The function records:

```text
source_attach_mode=READ_ONLY
source_snapshot_ref=<pool>/<image>@<snapshot>
source_nbd_device=/dev/nbdN
source_nbd_expected_bytes=<virtualBytes>
source_nbd_observed_bytes=<blockdev result>
```

If attach fails, preserve the first stderr line in the Run log and return
`86`. If size remains zero or differs from the mapped disk size after the
existing readiness timeout, return `89` and classify it separately from an
open-mode failure.

### 6.2 Cleanup ownership

`ftctl_kvm_vmware_patch_disk()` owns temporary NBD and writer resources.
The outer cycle owns RBD snapshots and baseline commit.

Cleanup order is fixed:

1. disconnect target NBD client;
2. stop VDDK writer;
3. disconnect source `qemu-nbd`;
4. wait for kernel NBD drain;
5. release the NBD allocation lock;
6. remove run-created snapshots only after all devices are detached.

Cleanup emits typed fields instead of hiding failures:

```text
nbd_teardown_state=COMPLETED|FAILED
nbd_teardown_error_code=<typed code>
nbd_quarantined_device_count=<count>
```

Cleanup failure does not replace the transfer root cause.

### 6.3 `lib/ftctl/dr_runtime.sh`

The failback worker writes terminal fields atomically to the Run path before
the worker identity is cleared:

```text
state=ERROR
step=failback-reverse-sync-failed
worker_state=FAILED
worker_exit_code=86
driver_exit_code=86
error_code=DR_REVERSE_SNAPSHOT_OR_NBD_FAILED
failure_phase=REVERSE_TRANSFER
failed_component=kvm-vmware-mover
terminal_evidence_source=ENGINE
terminal_evidence_at=<timestamp>
terminal_evidence_version=1
```

The status path is replaced from the completed Run path only after that write
is durable.

### 6.4 Dead-worker reconciliation

`dr-status` must not immediately convert `STARTED` or `RUNNING` plus a missing
PID into a terminal result. It applies this order:

1. re-read the Run-specific state file;
2. return an existing engine terminal envelope unchanged;
3. if the PID is absent but the worker age is below
   `FTCTL_DR_WORKER_TERMINAL_GRACE_SEC` (default 10 seconds), return
   `RUNNING/terminal-publication-pending`;
4. re-read once after the grace window;
5. synthesize `DR_FAILBACK_WORKER_EXITED` only if no engine terminal envelope
   exists.

The synthetic result carries:

```text
terminal_evidence_source=WATCHDOG
retryable=true
retry_after_sec=2
```

An `ENGINE` terminal result always supersedes a previously observed
`WATCHDOG` result for the same Run.

### 6.5 Feature capability

Add `dr-reverse-rbd-snapshot-readonly-v1` to the supported feature list only
after the source helper and its tests are installed. Cloud uses this marker as
a rollout compatibility gate for KVM-to-VMware Failback.

## 7. Error taxonomy

| Exit | Error code | Meaning | Retry policy |
|---|---|---|---|
| 86 | `DR_REVERSE_SNAPSHOT_OPEN_FAILED` | read-only RBD snapshot could not be attached | blocked until cause fixed |
| 89 | `DR_REVERSE_SOURCE_NBD_NOT_READY` | NBD attached but expected size was not observed | cleanup then retryable |
| 87 | `DR_REVERSE_WRITER_FAILED` | VMware writer failed after source readiness | depends on VDDK classification |
| 88 | `DR_REVERSE_DURABILITY_VERIFY_FAILED` | write/flush/baseline commit proof failed | non-retryable without review |
| 70 | `DR_FAILBACK_WORKER_EXITED` | watchdog fallback with no engine terminal evidence | short reconciliation retry |

For compatibility, exit `86` may continue to map to
`DR_REVERSE_SNAPSHOT_OR_NBD_FAILED` in v1 responses, but v2 status must expose
the more specific phase and attach mode.

## 8. Test design

### 8.1 Shell self-tests

Add focused tests that:

1. assert the exact `qemu-nbd` call contains `--read-only` and `--cache=none`;
2. reject any source-snapshot attachment without `--read-only`;
3. verify a full seed produces one extent covering the virtual disk;
4. verify both mapped disks are processed before baseline commit;
5. verify an attach failure removes every new snapshot;
6. verify a source NBD size timeout returns `89`;
7. verify transfer error survives a later cleanup error;
8. verify a dead PID inside the grace window remains pending;
9. verify a later engine terminal result supersedes a synthetic watchdog
   result;
10. verify no baseline generation is committed after any failed disk.

### 8.2 Package-host preflight

After RPM deployment, run a controlled administrator preflight against one
known RBD source:

1. create a uniquely named temporary snapshot;
2. allocate a verified free NBD device;
3. attach with `--read-only`;
4. wait until the expected virtual size is visible;
5. disconnect and verify no PID remains;
6. remove the exact temporary snapshot;
7. verify zero residual snapshots and NBD devices.

The normal UI Failback preflight remains non-mutating. It checks capability,
free NBD availability, source images, source domain, and writer readiness.

### 8.3 Live acceptance

The affected Windows Plan passes only when:

1. first reverse cycle selects `FULL_REVERSE_SEED`;
2. both RBD snapshots attach read-only;
3. 150 GiB virtual source coverage is reported across two disks;
4. VDDK writes and flushes are verified;
5. reverse baseline generation 1 is committed;
6. `FAILBACK_DATA_READY` is published;
7. Cloud stops the KVM VM and starts the VMware VM;
8. authority commits to SOURCE;
9. no NBD, snapshot, or worker residue remains;
10. the following reverse cycle can select incremental mode.

## 9. Recommended implementation order

1. P0: add the read-only source attachment helper.
2. P0: add exact argument, cleanup, and two-disk self-tests.
3. P0: make engine terminal publication atomic before PID clearing.
4. P0: add dead-worker grace and terminal-source precedence.
5. P1: add the capability marker and specific v2 error fields.
6. P1: build the RPM with GitHub Actions and deploy the same artifact to all
   participating workers.
7. P1: run the package-host read-only attachment preflight.
8. P1: clean only the failed Run/session artifacts while preserving TARGET
   authority and the serving KVM VM.
9. P1: execute one Failback retry and verify the complete live acceptance.

## 10. AS-IS / TO-BE

| Area | Error cause | AS-IS | TO-BE |
|---|---|---|---|
| RBD snapshot open | immutable snapshot opened writable | `qemu-nbd` exits with read-only error | source helper always uses `--read-only` |
| Source readiness | process start can precede size publication | first observation may be zero | wait for exact expected virtual size |
| Error identity | PID fallback races terminal write | exit `70` hides exit `86` | engine terminal evidence has highest precedence |
| Worker observation | dead PID is immediately terminal | false early failure possible | bounded terminal-publication grace and re-read |
| Cleanup | transfer and cleanup errors can mix | root cause can be obscured | transfer cause preserved; cleanup recorded separately |
| Capability | Cloud cannot distinguish fixed workers | Failback can be retried on an old package | feature marker gates retry availability |
| Testing | selector tests stop before real NBD semantics | package passes but live attach fails | exact argument test plus package-host preflight |

## 11. Completion criteria

This correction is complete only after the package self-tests, controlled host
preflight, and one real two-disk Failback all pass with matching FTCTL, Agent,
Cloud Run, FailbackSession, KVM, and VMware evidence.

## 12. 2026-08-05 Live Transfer Reconciliation Addendum

Live preflight after this document found a later Run whose transfer processes
and byte counters were advancing while Cloud had already classified the worker
as exited. A standalone `BASHPID` probe passed, so command substitution alone
is not the established cause. The corrective contract is the owner-specific
journal, immutable worker handshake, progress heartbeat, pure status merge, and
multi-signal terminal predicate in document 451.

Where this document permits terminalization after only a dead-PID observation
and bounded publication grace, document 451 takes precedence. Grace remains an
observation aid; it is not terminal proof when transfer activity, heartbeat, or
a Run-owned process is live.
