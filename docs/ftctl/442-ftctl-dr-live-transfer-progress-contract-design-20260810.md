# FTCTL DR Live Transfer Progress Contract Design

- Date: 2026-08-10
- Status: corrective build and deployment complete; live acceptance pending
- Scope: VMware to ABLESTACK and ABLESTACK to VMware synchronization
- Related: `441-ftctl-dr-vmware-cbt-activation-evidence-design-20260810.md`

## 1. Purpose

An operator must be able to distinguish a healthy long-running transfer from a
stalled worker. The current operation progress remains at a phase constant
while a VMware full seed is copying data. Completed cycle metrics are accurate,
but they arrive only after the copy has finished.

This design makes live transfer progress an FTCTL engine contract. Cloud may
cache and display it, but must not estimate engine progress from elapsed time,
RBD allocation, or a fixed workflow step.

## 2. Confirmed Evidence And Root Cause

Live validation used plan `ef73f5f3-9740-4bbd-8c9a-74a972e5f19f`, run
`7b094458-9973-4874-bca3-3bee46c5d054`.

During the first 100 GiB full seed:

- `qemu-img convert --force-share -p` was alive and consuming CPU;
- target RBD allocation increased while the process ran;
- the FTCTL scheduler stayed at `full-seed-transfer`, progress `40`;
- `transfer_activity_state` was `UNKNOWN`;
- `transfer_payload_bytes` was `0`;
- no progress journal existed below the plan runtime directory.

After completion, cycle 1 correctly recorded:

```text
effectiveMode=FULL_SEED
virtualBytes=107374182400
transferPayloadBytes=107374182400
durationMs=248894
```

Cycle 2 correctly recorded a 5,701,632 byte CBT incremental transfer. The
terminal metrics path is therefore correct; the missing part is the live path.

The first implementation added the journal and status fields, but live
validation of full-reseed run `8aa9d51f-3d29-4236-9c5b-c7427bee4675`
identified two corrective defects:

1. `dr_qemu_img_progress.py` reads only child `stderr`. On the deployed qemu
   build, the `-p` stream is observable through inherited `stdout`, so only the
   initial and terminal samples are persisted. Inherited output can also enter
   an outer command-substitution channel and corrupt the expected JSON result.
2. `dr_vmware_mover.sh` calculates the aggregate with `jq` without raw output.
   Disk-plan `virtualBytes` values are strings, so the result includes quotes,
   fails the integer regular expression, and is reset to `0`.

The copy itself completed successfully: cycle 25 transferred
`107374182400` bytes in about 269 seconds. The defect is live telemetry, not
the VMware/VDDK to RBD data path.

## 3. Authority And Semantics

FTCTL is authoritative for the following live facts:

- current cycle identity and transfer mode;
- logical bytes expected for this cycle;
- logical bytes successfully processed;
- current disk and aggregate disk progress;
- transfer heartbeat and worker identity;
- terminal completion or failure.

The terms have these meanings:

| Field | Meaning |
| --- | --- |
| `bytesTotal` | Logical bytes that this cycle must process |
| `bytesProcessed` | Logical bytes read and successfully handed to the target writer |
| `bytesWritten` | Logical bytes confirmed written by the target writer |
| `payloadBytes` | Data payload processed by the mover; terminal value matches cycle metrics |
| `percent` | `bytesProcessed / bytesTotal * 100`, clamped to 0..100 |
| `throughputBps` | Moving-window logical payload rate, not RBD allocated growth |
| `etaSeconds` | Remaining logical bytes divided by the moving-window rate |

RBD allocated bytes are diagnostic only. Sparse writes and overwrites can make
allocation stay flat or change non-linearly, so `rbd du` must never be used as
the canonical progress percentage.

## 4. Versioned Progress Journal

Each cycle owns one file:

```text
/run/ablestack-vm-ftctl/dr-runtime/plans/<plan>/progress/<run>-cycle-<sequence>.json
```

The scheduler stores this path in `transfer_progress_path` and passes it to the
cycle driver as `FTCTL_DR_TRANSFER_PROGRESS_PATH`. The file is written through
temporary-file, `fsync`, and `os.replace` so readers never observe partial JSON.

Schema version 2:

```json
{
  "schemaVersion": 2,
  "planUuid": "plan-uuid",
  "runUuid": "run-uuid",
  "cycleSequence": 1,
  "sampleSequence": 17,
  "direction": "VMWARE_TO_KVM",
  "mode": "FULL_SEED",
  "phase": "TRANSFER",
  "state": "COPYING",
  "diskIndex": 0,
  "diskCount": 1,
  "diskLabel": "Disk 1",
  "bytesTotal": 107374182400,
  "bytesProcessed": 25032704000,
  "sourceReadBytes": 25032704000,
  "targetWrittenBytes": 25032704000,
  "payloadBytes": 25032704000,
  "verifiedBytes": 0,
  "percent": 23.31,
  "throughputBps": 418381824,
  "etaSeconds": 197,
  "estimated": true,
  "source": "QEMU_IMG_PROGRESS",
  "workerPid": 12345,
  "workerStartTicks": 987654,
  "sampledAtEpochMs": 1786332000000,
  "heartbeatAtEpochMs": 1786332000000
}
```

Allowed `state` values are `PREPARING`, `COPYING`, `VERIFYING`, `COMMITTING`,
`COMPLETE`, `FAILED`, and `STALE`. `sampleSequence` is strictly increasing
within one cycle. A reader rejects a sample whose plan, run, or cycle identity
does not match the active authority.

## 5. FTCTL Code-Level Changes

### 5.1 `lib/ftctl/dr_scheduler.sh`

Add `ftctl_dr_scheduler_cycle_progress_path(plan, run, sequence)` and create the
parent directory with mode `0755` before starting a cycle.

At cycle start:

1. write an initial `PREPARING` journal with sample sequence 1;
2. persist `transfer_progress_path` in plan and run state;
3. invoke `ftctl_dr_scheduler_run_cycle` with
   `FTCTL_DR_TRANSFER_PROGRESS_PATH=<path>`;
4. project live journal values into `status.state` on each `dr-status` read;
5. preserve the last valid sample on failure instead of resetting bytes to 0.

The existing operation progress `40` becomes only a fallback for an engine that
does not advertise `dr-live-transfer-progress-v2`. It is not the displayed data
transfer percentage.

### 5.2 New `lib/ftctl/dr_qemu_img_progress.py`

This helper owns the full-seed child process. It receives the complete
`qemu-img` argument vector without shell re-evaluation, merges child stdout and
stderr into one parser pipe, and relays that pipe to the wrapper's stderr.
Wrapper stdout remains reserved for machine-readable JSON. The helper parses
the `-p` carriage-return stream with a bounded expression equivalent to:

```python
r"\(?\s*(\d+(?:\.\d+)?)\s*/\s*100%\s*\)?"
```

For every accepted sample it:

- rejects regressions within the same disk;
- converts percentage to logical bytes using the disk virtual size;
- computes a 10-second exponentially weighted throughput;
- leaves throughput and ETA null until at least two non-zero samples spanning
  one second exist, and leaves ETA null whenever the measured rate is zero;
- writes no more than one journal update per second unless state changes;
- publishes a heartbeat at the configured interval even when no new percent
  token arrives;
- forwards non-progress stderr to the mover log;
- returns the exact child exit code;
- writes `FAILED` before returning a non-zero exit code;
- writes `COMPLETE` only after `qemu-img` exits zero.

No credential, VDDK password-file path, or full image-options string is written
to the progress journal.

### 5.3 `lib/ftctl/dr_vmware_mover.sh`

Extend `ftctl_vmware_mover_convert_disk` with progress identity, disk index,
disk count, virtual bytes, and base bytes. Replace the direct `qemu-img`
invocation with `dr_qemu_img_progress.py --progress-json ... -- qemu-img ...`.

For CBT incremental copies, pass these existing helper arguments:

```text
--progress-json "$FTCTL_DR_TRANSFER_PROGRESS_PATH"
--progress-base-bytes <completed-prior-disks>
--progress-disk-index <index>
```

Before copying, normalize every `virtualBytes` value with `tonumber?`, request
raw `jq -r` output, and calculate `bytesTotal` as:

- full seed/reseed: sum of selected disk virtual bytes;
- CBT incremental: sum of normalized changed extent lengths;
- no change: 0, with a direct `COMPLETE` sample.

### 5.4 `lib/ftctl/dr_extent_patch.py`

Upgrade the existing writer to schema version 2 and accept plan, run, cycle,
mode, disk count, total bytes, and base bytes. Publish after a successful write,
not merely after a source read. During verification, keep transfer percentage at
100 and publish a separate verification percentage/byte count.

The same helper contract is used by VMware to KVM and KVM to VMware. Direction
changes the provider-specific mover, not the progress schema.

### 5.5 `lib/ftctl/dr_runtime.sh`

Extend `dr-status` with:

```text
transfer_progress_schema_version
transfer_cycle_sequence
transfer_sample_sequence
transfer_phase
transfer_activity_state
transfer_mode
transfer_bytes_total
transfer_bytes_processed
transfer_source_read_bytes
transfer_target_written_bytes
transfer_payload_bytes
transfer_verified_bytes
transfer_percent
transfer_throughput_bps
transfer_eta_seconds
transfer_current_disk_index
transfer_disk_count
transfer_progress_estimated
transfer_progress_sampled_at_epoch_ms
transfer_progress_stale
```

Staleness is true when an active transfer sample is older than
`max(15 seconds, 3 * publication interval)`. If the worker PID/start ticks no
longer match and no terminal journal exists, status becomes `STALE`, not
`COMPLETE` and not an immediate destructive retry.

At terminal completion, use committed cycle metrics to force an exact 100%
sample. Full-seed `estimated=true` means the in-flight byte count was derived
from `qemu-img` logical percentage; terminal metrics remain authoritative.
The transfer may reach 100% while target flush, verification, and checkpoint
commit are still running. In that state raw transfer stays at 100%, while the
whole-operation progress remains below 100 until the terminal commit succeeds.

## 6. Multi-Disk Aggregation

Percentages are weighted by logical bytes:

```text
aggregateProcessed = completedPriorDiskBytes + currentDiskProcessed
aggregatePercent = aggregateProcessed / aggregateTotal * 100
```

An arithmetic average of disk percentages is forbidden because a 1 GiB disk
and a 1 TiB disk do not have equal weight. Disk indices are zero-based in the
engine contract and rendered one-based by the UI.

## 7. Operation Progress Mapping

Transfer progress and whole-operation progress are separate values. FTCTL emits
raw transfer progress; Cloud maps it into a workflow range:

| Operation phase | Whole-operation range |
| --- | --- |
| prepare and preflight | 0-10 |
| snapshot and CBT evidence | 10-20 |
| target preparation | 20-30 |
| data transfer | 30-85 |
| verification | 85-92 |
| checkpoint commit | 92-97 |
| target materialization | 97-100 |

For example, 50% transfer means 57.5% whole-operation progress. The UI must
also show the raw 50% transfer value and bytes so the operator is not forced to
interpret the workflow mapping.

## 8. Validation

Unit and integration tests must cover:

1. qemu-img samples `0.00/100%`, `42.50/100%`, and `100.00/100%` separated by
   carriage returns on either stdout or stderr;
2. malformed and unrelated stderr lines;
3. child failure with exact exit-code propagation and last-byte preservation;
4. atomic journal reads during concurrent writes;
5. monotonic sample and byte enforcement;
6. weighted multi-disk aggregation;
7. full seed, CBT incremental, no-change, verify, and terminal samples;
8. stale heartbeat and PID reuse detection;
9. absence of credentials and image-option secrets;
10. compatibility fallback when schema version 2 is absent.

Live acceptance requires one new full seed and one later CBT incremental cycle.
During both transfers, at least three increasing samples must be observed before
completion. The completed journal bytes must match the committed cycle metrics.

## 9. Implementation Priority

1. **P0**: scheduler-owned progress path and forward mover publication.
2. **P0**: qemu-img parser, extent-helper schema v2, and strict identity.
3. **P0**: `dr-status` fields, staleness, and terminal reconciliation.
4. **P1**: Agent/Cloud transport and UI presentation defined in the paired
   Cloud document.
5. **P1**: full-seed and incremental live acceptance tests.
6. **P2**: optional long-term throughput trend analytics; not required for
   correct live progress.

## 10. AS-IS / TO-BE

| Area | AS-IS | TO-BE |
| --- | --- | --- |
| Full seed | `qemu-img -p` output is not consumed | Dedicated parser publishes atomic progress samples |
| Forward CBT | Extent helper called without a progress path | Existing progress writer receives full cycle identity and totals |
| Reverse path | Partial live journal only | Same versioned schema in both directions |
| Transfer percent | Fixed scheduler phase value `40` | Logical-byte weighted live percentage |
| Transfer bytes | Zero while active, accurate only after completion | Monotonic processed/written bytes while active and exact terminal metrics |
| Throughput/ETA | Not available | Moving-window throughput and bounded ETA |
| Liveness | Worker and transfer evidence can disagree | Journal heartbeat plus PID/start-ticks identity |
| Stalled transfer | Indistinguishable from slow transfer | Explicit stale state with last valid progress preserved |
| RBD allocation | Tempting but misleading proxy | Diagnostic only; never progress authority |

## 11. Implementation Result

Implemented on `feature/ftctl-cloud-integration` as follows:

- `dr_qemu_img_progress.py` owns full-seed `qemu-img` execution, parses its
  carriage-return progress stream, and atomically publishes schema-version 2
  samples without logging credentials or source options;
- `dr_extent_patch.py` publishes the same schema during CBT extent transfer;
- `dr_vmware_mover.sh` supplies plan, run, cycle, disk, total-byte, and
  completed-byte identity to both transfer paths and writes an exact terminal
  sample after all disks complete;
- `dr_scheduler.sh` creates a run-scoped progress path and persists it in the
  runtime state; `dr_vmware.sh` forwards it to the mover;
- `dr_runtime.sh` projects the complete transfer snapshot and marks a sample
  stale when its heartbeat is older than the configured threshold.

Static verification includes Python compilation, shell syntax checks, GitHub
Actions RPM packaging, and a controlled 1 MiB full-copy parser smoke test that
produced a terminal schema-version 2 sample with `percent=100` and
`bytesProcessed=1048576`. The repository-wide self-test reached shellcheck but
did not provide an independent PASS because existing unrelated shellcheck
warnings remain; those diagnostics are not treated as a live-progress failure.

Live acceptance remains deliberately separate from build acceptance. The next
operator test must create a new plan, observe at least three increasing samples
during the initial full seed, then modify source data and confirm the following
CBT cycle reports a smaller exact payload. Failover testing must not start until
Agent, Cloud DB/API, and UI all agree with the FTCTL journal for both cycles.

### 11.1 Corrective implementation after run 8aa9d51f

- child stdout and stderr are consumed through one bounded parser pipe;
- all child output is relayed to stderr so wrapper stdout cannot corrupt JSON;
- progress publication includes interval heartbeats and monotonic percentage
  rejection;
- aggregate full-seed bytes use raw numeric `jq` conversion;
- unit coverage exercises stdout progress, stderr progress, exact child exit
  propagation, non-zero totals, and monotonic observed samples.

The corrective patch is not accepted until the installed helper produces at
least three increasing samples with `bytesTotal=107374182400` during a new
full resynchronization.

### 11.2 Corrective build and deployment evidence

- GitHub Actions run `31360367860` built commit `5da8126` successfully;
- the resulting `ablestack_vm_ftctl-0.9.5-1.noarch.rpm` has SHA-256
  `645dc0ef06be593e025700ea4e2530907b5f22614ef41335c5df3d38f782ce66`;
- that exact RPM was installed on `10.10.32.1`, `10.10.32.2`, and
  `10.10.32.3`, and every `mold-agent` returned `active` after restart;
- installed files on all three hosts contain merged stdout/stderr capture and
  raw numeric `virtualBytes` aggregation;
- an installed-helper smoke test on every host produced a schema-version 2
  `COMPLETE` sample with a non-zero `bytesTotal` while wrapper stdout remained
  empty.

This proves package and host-level contract deployment. It does not replace
the operator-started full-resynchronization acceptance test, which must still
demonstrate several increasing samples during a real 100 GiB transfer.

### 11.3 Post-deployment periodic-cycle finding

The first periodic CBT cycle after deployment copied 16,646,144 bytes and
published a valid schema-version 2 terminal sample. Its subsequent VMware
snapshot-reference fallback received an empty `govc snapshot.tree -json`
payload even though `govc` returned success. The resolver previously attempted
to parse that empty file and emitted a Python traceback, while the cycle itself
continued and committed successfully.

The resolver now requires a non-empty file and catches file, encoding, and JSON
decode failures. An empty or malformed optional snapshot tree therefore selects
the existing fallback path without polluting service logs; a valid tree still
returns the matching managed-object reference. Focused tests cover both cases.

### 11.4 Final corrective deployment verification

GitHub Actions run `31362359087` built and uploaded the RPM for commit
`2a9f778`; only its optional GitHub Release publication step failed because of
a GitHub secondary rate limit. The uploaded Actions artifact has SHA-256
`d5da081c05e81dab5327c288a353feb7c9c79572991fdd958f617702efe9e4bd`
and was installed on all three DR compute hosts.

After restarting the plan scheduler on `10.10.32.2`, periodic cycle 36 copied
1,638,400 bytes in `CBT_INCREMENTAL` mode and published a schema-version 2
`COMPLETE` sample. No snapshot-tree traceback was emitted. This validates the
fallback correction in a real periodic cycle; full-resynchronization live
progress acceptance remains the next operator test.
