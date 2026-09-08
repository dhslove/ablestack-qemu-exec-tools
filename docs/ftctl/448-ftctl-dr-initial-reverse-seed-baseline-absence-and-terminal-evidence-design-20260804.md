# 448. FTCTL DR Initial Reverse Seed Baseline Absence And Terminal Evidence Design

- Date: 2026-08-04
- Status: revision 3 code-level corrective design; live-runtime boundary implementation pending
- Scope: KVM-to-VMware initial reverse seed, failback worker terminal evidence, target-storage projection
- Parent design: [445-ftctl-dr-bidirectional-incremental-replication-and-reverse-guest-compatibility-design-20260801.md](445-ftctl-dr-bidirectional-incremental-replication-and-reverse-guest-compatibility-design-20260801.md)
- Cloud companion: `ablestack-cloud/docs/ftctl/591-cross-hypervisor-dr-failback-initial-reverse-seed-and-early-failure-convergence-design-20260804.md`
- Route envelope correction: [452](452-ftctl-dr-failback-route-envelope-and-cloud-lifecycle-boundary-design-20260805.md)

> Revision 3 live-runtime boundary:
> [449-ftctl-dr-live-runtime-observation-and-projection-boundary-design-20260804.md](449-ftctl-dr-live-runtime-observation-and-projection-boundary-design-20260804.md)
> defines FTCTL power fields as projection-only and requires a live KVM source
> domain before reverse data preflight can pass.
>
> Revision 4 RBD snapshot and terminal-causality correction:
> [450-ftctl-dr-reverse-rbd-snapshot-readonly-nbd-and-terminal-causality-design-20260805.md](450-ftctl-dr-reverse-rbd-snapshot-readonly-nbd-and-terminal-causality-design-20260805.md)
> is normative for read-only RBD snapshot attachment and engine-terminal error
> precedence.

## 1. Objective

The first KVM-to-VMware reverse cycle must treat an absent reverse baseline as
the expected input for `FULL_REVERSE_SEED`. It must transfer every source disk,
verify the VMware target write, and only then atomically create generation 1 of
the reverse baseline.

An early mover failure must also converge as a terminal, typed operation while
preserving TARGET authority and the last known durable forward-protection
evidence.

## 2. First verified failure

This section records the baseline-loader failure corrected by commit
`29ac3511e8b32cdb681cf5a8411d617513562a74`. Section 12 records the later
deployed failure that proved the operation-intent-to-cycle-mode selector was
still incomplete and supersedes any statement that the selector itself was
already correct.

The live Plan `7889e625-371a-48f9-b553-54e311481170` produced Failback Run
`7ed30e9b-da7a-4baa-bef9-be555b1464b5` with the following evidence:

| Evidence | Observed value |
|---|---|
| Cloud/Agent dispatch | accepted |
| FTCTL reverse profile | valid `KVM_TO_VMWARE`, two disks mapped |
| Selected reverse mode | `FULL_REVERSE_SEED` |
| Reverse baseline file | absent, as expected before generation 1 |
| Source RBD images | both present and attached to the active KVM VM |
| VMware source VM | powered off |
| KVM authority VM | running |
| Mover result | exit code `2` before disk transfer |
| Cloud error | generic `DR_FAILBACK_REVERSE_SYNC_FAILED` |
| Authority after failure | TARGET, safe |

The failing statement in `lib/ftctl/dr_kvm_vmware_mover.sh` is an unconditional
read of the absent baseline:

```bash
previous_snapshot="$(jq -r --argjson index "${index}" \
  '.disks[]? | select(.diskIndex == $index) | .snapshot' \
  "${baseline_path}" 2>/dev/null | head -n 1)"
```

Because the script uses `set -euo pipefail`, `jq` returns `2` for the missing
file and terminates the mover before the existing full-seed extent branch can
run. That incident was a baseline-loader violation. It did not prove that the
`failback-final` selector selected `FULL_REVERSE_SEED` in the deployed path.

## 3. Safety invariants

1. `FULL_REVERSE_SEED` plus a missing baseline is valid and yields an empty
   previous-snapshot value for every disk.
2. `REVERSE_INCREMENTAL` or `REVERSE_FINAL` requires a valid durable baseline;
   missing or malformed lineage is terminal and typed.
3. A new RBD snapshot is not a committed baseline until all VMware target
   writes are flushed and verified.
4. On any pre-commit failure, new snapshots are removed and the previous
   baseline remains unchanged.
5. TARGET remains the authority, the VMware source remains powered off, and
   Cloud lifecycle cutback is not invoked before `FAILBACK_DATA_READY`.
6. An accepted command that later fails remains `accepted=true`; acceptance
   and operation outcome are independent facts.
7. A terminal worker never remains `RUNNING`, and a dead PID is never reported
   as alive.
8. Operation-local empty checkpoint fields do not erase Plan-level durable
   target-storage evidence.

## 4. State model

```text
REQUESTED
  -> REVERSE_PREFLIGHT
  -> FULL_REVERSE_SEED | REVERSE_INCREMENTAL | REVERSE_FINAL
  -> WRITER_FLUSHED
  -> WRITE_VERIFIED
  -> BASELINE_COMMITTED
  -> FAILBACK_DATA_READY

Any pre-commit failure
  -> FAILED
  -> active_side=TARGET
  -> source_power_state=POWERED_OFF
  -> target_power_state=POWERED_ON
```

The first cycle specifically follows:

```text
baseline=MISSING + requested=failback-final
  -> effective=FULL_REVERSE_SEED
  -> previousSnapshot=""
  -> full-disk extents
  -> VDDK write/flush/read-back verify
  -> baseline generation 1
```

## 5. Code-level design

### 5.1 `lib/ftctl/dr_kvm_vmware_mover.sh`

Add a baseline loader with an explicit cycle contract:

```bash
ftctl_kvm_vmware_load_previous_snapshot() {
  local baseline_path="${1-}" disk_index="${2-}" cycle_type="${3-}"
  local snapshot

  if [[ ! -s "${baseline_path}" ]]; then
    [[ "${cycle_type}" == "FULL_REVERSE_SEED" ]] || return 83
    printf '\n'
    return 0
  fi

  jq -e '.state == "LOCAL_DURABLE" and .direction == "KVM_TO_VMWARE" and (.disks | type == "array")' \
    "${baseline_path}" >/dev/null || return 84
  snapshot="$(jq -r --argjson index "${disk_index}" \
    '[.disks[] | select(.diskIndex == $index) | .snapshot][0] // ""' \
    "${baseline_path}")" || return 84
  [[ -n "${snapshot}" || "${cycle_type}" == "FULL_REVERSE_SEED" ]] || return 83
  printf '%s\n' "${snapshot}"
}
```

The snapshot preparation loop must call the helper without allowing `set -e`
to bypass typed handling:

```bash
previous_snapshot="$(ftctl_kvm_vmware_load_previous_snapshot \
  "${baseline_path}" "${index}" "${cycle_type}")" || rc=$?
[[ "${rc}" == "0" ]] || ftctl_kvm_vmware_die "${rc}" \
  "$([[ "${rc}" == "83" ]] && printf DR_REVERSE_BASELINE_REQUIRED || printf DR_REVERSE_BASELINE_INVALID)"
```

Additional changes:

- validate every `sourcePool/sourceImage` with `rbd info` before creating any
  snapshot;
- validate disk-index uniqueness and one-to-one VMDK mapping before transfer;
- create all new snapshots only after the full preflight passes;
- register an `EXIT` trap that removes only uncommitted snapshots;
- capture a redacted per-cycle diagnostic file containing phase, disk index,
  driver exit code, and writer-log tail, never credentials;
- write `baseline.json.tmp`, `fsync`, and `rename` only after all disks report
  `writerState=DURABLE` and `writeVerified=true`;
- remove previous snapshots only after the atomic baseline commit.

### 5.2 `lib/ftctl/dr_kvm_vmware.sh`

Split the cycle into explicit preflight and execution functions:

```text
ftctl_dr_kvm_vmware_preflight_cycle
ftctl_dr_kvm_vmware_replication_cycle
ftctl_dr_kvm_vmware_commit_cycle
```

`ftctl_dr_kvm_vmware_preflight_cycle` returns a compact contract:

```json
{
  "direction": "KVM_TO_VMWARE",
  "effectiveMode": "FULL_REVERSE_SEED",
  "baselineFileState": "MISSING_EXPECTED",
  "sourceDiskProbeState": "READY",
  "targetWriterProbeState": "READY",
  "targetVmPowerState": "POWERED_OFF"
}
```

The replication function must preserve the exact mover exit code and stderr
summary. It must not create manifest/checkpoint/metrics success artifacts when
the mover fails. The commit function alone publishes durable checkpoint paths.

Map driver exits as follows:

| Exit | Error code | Meaning |
|---:|---|---|
| 65 | `DR_REVERSE_MOVER_UNAVAILABLE` | required binary or map absent |
| 76 | `DR_REVERSE_TARGET_VM_NOT_STOPPED` | VMware target is not fenced |
| 82 | `DR_REVERSE_SOURCE_STORAGE_MISSING` | mapped RBD/QCOW2 source absent |
| 83 | `DR_REVERSE_BASELINE_REQUIRED` | incremental cycle has no prior snapshot |
| 84 | `DR_REVERSE_BASELINE_INVALID` | baseline schema or lineage invalid |
| 86 | `DR_REVERSE_SNAPSHOT_OR_NBD_FAILED` | snapshot or NBD allocation failed |
| 87 | `DR_REVERSE_WRITER_FAILED` | VDDK writer/patch failed |
| 88 | `DR_REVERSE_DURABILITY_VERIFY_FAILED` | flush/read-back/commit proof failed |

### 5.3 `lib/ftctl/dr_runtime.sh`

Create the local failback session before reverse profile execution:

```text
failbacks/<run>.json state=REQUESTED
active.json -> <run>.json
run state=RUNNING step=reverse-preflight worker_state=RUNNING
```

On early failure, update both Run and failback session:

```text
state=ERROR
failback_phase=FAILED
worker_state=FAILED
worker_exit_code=<driver rc>
worker_pid=
worker_pid_alive=false
accepted=true
error_code=<typed code>
error_message=<redacted phase and disk context>
failed_component=kvm-vmware-mover
active_side=TARGET
source_power_state=POWERED_OFF
target_power_state=POWERED_ON
```

`ftctl_dr_runtime_start_failback` records `worker_pid`, start ticks, and
heartbeat. Status generation validates `/proc/<pid>/stat`; a dead or reused PID
forces terminal reconciliation instead of retaining `worker_state=RUNNING`.

Do not copy a failback Run file over Plan status in a way that clears durable
forward evidence. Keep these namespaces separate:

```text
operation.*     current failback Run status
protection.*    latest completed protection checkpoint
materialized.* Cloud-owned target VM/disk/network evidence
```

`target_storage_present` is Plan materialization evidence. FTCTL may confirm it
from the canonical disk map and source image probes, but an empty failback
checkpoint path must never set it to false.

### 5.4 `lib/ftctl/dr_scheduler.sh`

The scheduler treats `baselineFileState=MISSING_EXPECTED` as a valid first
reverse seed. It blocks only:

- missing baseline for an incremental/final incremental request;
- malformed durable lineage;
- source disk identity drift;
- target writer or fencing failure.

Retries use the same Run idempotency key. If no baseline commit occurred, the
retry remains a full seed. If generation 1 committed, the next retry/cycle is
incremental.

## 6. Agent-facing status contract

FTCTL status adds or normalizes:

```json
{
  "accepted": true,
  "worker_state": "FAILED",
  "worker_pid_alive": false,
  "worker_exit_code": 84,
  "failure_phase": "REVERSE_PREFLIGHT",
  "failed_component": "kvm-vmware-mover",
  "baseline_file_state": "MISSING_EXPECTED",
  "source_disk_probe_state": "READY",
  "target_writer_probe_state": "READY",
  "error_code": "DR_REVERSE_BASELINE_INVALID",
  "error_message": "Reverse baseline validation failed before disk transfer",
  "active_side": "TARGET"
}
```

The payload is bounded and redacted. Full logs remain host-local.

## 7. Tests

### 7.1 Shell self-tests

Add the cases to `bin/ablestack_vm_ftctl_selftest.sh`; keep external-command
fakes and deterministic fixtures under the existing self-test work root.

1. missing baseline plus `FULL_REVERSE_SEED` returns an empty previous snapshot;
2. missing baseline plus incremental mode returns `83`;
3. malformed existing baseline returns `84`;
4. full seed writes both mapped disks and commits generation 1;
5. disk-2 failure removes all new snapshots and creates no baseline;
6. previous durable baseline survives an incremental writer failure;
7. mover exit and typed error survive runtime projection;
8. a dead failback worker cannot remain `RUNNING`;
9. empty operation checkpoint fields do not clear Plan storage presence.

### 7.2 Non-mutating preflight

Before live retry:

1. validate the reverse profile and disk-map schema;
2. confirm both source images with `rbd info`;
3. confirm the active KVM VM owns the mapped disks;
4. confirm VMware target power is off through vCenter;
5. confirm VDDK library and `nbdkit` writer availability;
6. report missing baseline as `MISSING_EXPECTED/FULL_REVERSE_SEED`.

### 7.3 Live acceptance

1. fail over and write known data on KVM;
2. run failback initial reverse seed;
3. verify non-zero bytes for every disk and generation 1 commit;
4. boot VMware in isolation and verify known data;
5. return to KVM authority for another write;
6. run reverse incremental and verify bytes are less than virtual disk size;
7. verify a no-change cycle reports zero bytes only with durable lineage proof;
8. complete failback and prove post-failback forward protection resumes.

## 8. Recommended implementation order

1. P0: baseline loader and typed mover exits.
2. P0: uncommitted snapshot cleanup and atomic baseline commit tests.
3. P0: early failback session and terminal worker reconciliation.
4. P1: Plan/operation/materialization status namespace separation.
5. P1: Agent status contract and Cloud error propagation.
6. P1: automated shell tests and package build.
7. P2: non-mutating preflight in the deployed environment.
8. P2: clean live full-seed and second-cycle incremental acceptance.

## 9. AS-IS / TO-BE

| Area | Error cause | AS-IS | TO-BE |
|---|---|---|---|
| Initial baseline | unconditional `jq` under `pipefail` | missing file exits `2` | missing is valid for full seed |
| Cycle mode | selector and loader disagree | selects full seed but loader demands lineage | one explicit cycle contract |
| Error identity | raw rc collapses at runtime | generic reverse-sync failure | typed phase/component/exit |
| Session evidence | session written after data-ready | early failure has no session | session exists from REQUESTED |
| Worker state | background PID is not reconciled | dead worker can remain RUNNING | PID/start-ticks terminal check |
| Storage presence | inferred from current Run checkpoint | real RBD can display absent | Plan materialization evidence retained |
| Baseline commit | partially implicit cleanup | failure semantics are hard to prove | transactional snapshot/verify/rename |
| Authority | safe only through current ordering | TARGET happened to remain active | TARGET retention is invariant and tested |

## 10. Completion criteria

The correction is complete only when the original failing shape passes a clean
initial reverse full seed, the next cycle passes as a real incremental transfer,
all terminal state is consistent across FTCTL and Cloud, and no failure before
Cloud commit can stop the TARGET authority VM or power on VMware.

## 11. Implementation result (2026-08-04)

Implemented in commit `29ac3511e8b32cdb681cf5a8411d617513562a74`:

- `dr_kvm_vmware_mover.sh` accepts an absent baseline only for
  `FULL_REVERSE_SEED`, validates an existing lineage before transfer, and emits
  typed exits `83` and `84` for required/invalid lineage;
- `dr_runtime.sh` writes a REQUESTED failback session before reverse transfer,
  records worker PID/start ticks and typed phase/component/driver evidence, and
  writes a terminal FAILED session before the worker exits;
- status projection retains Plan materialization evidence and converts a stale
  RUNNING record with a dead PID identity into `DR_FAILBACK_WORKER_EXITED`;
- the runtime records baseline, source-disk probe, and target-writer probe states
  without exposing credentials or unbounded logs;
- shell self-tests cover missing, required, invalid, and durable baseline cases.

Local verification completed:

```text
bash -n: PASS
selftest_case_dr_kvm_vmware_initial_seed_accepts_missing_baseline: PASS
selftest_case_dr_kvm_vmware_reverse_route_and_baseline_contract: PASS
```

## 12. Revision 2: failback intent and reverse cycle mode separation

### 12.1 Follow-up live evidence

The subsequent deployed Failback for Plan
`7889e625-371a-48f9-b553-54e311481170` and Run
`3a6357e1-9092-47c9-9d5b-e72f4a543fc0` failed in four seconds with the
following evidence:

| Evidence | Observed value |
|---|---|
| Runtime request | `failback-final` |
| Current effective mode | `REVERSE_FINAL` |
| Reverse baseline | `MISSING_EXPECTED` |
| Reverse disk map | `READY`, two disks |
| Source RBD images | `READY`, 100 GiB and 50 GiB |
| VMware destination power | `poweredOff` |
| Required commands | all present |
| nbdkit VDDK plugin | available, version `1.38.5` |
| Mover result | exit `83`, `DR_REVERSE_BASELINE_REQUIRED` |
| Authority after failure | TARGET retained; KVM on, VMware off |

The non-mutating deployed-host probe reproduced the selector defect directly:

```text
current_effective_mode=REVERSE_FINAL
baseline=MISSING_EXPECTED
proposed_effective_mode=FULL_REVERSE_SEED
disk_map_validation=READY
```

The environment and mapping are ready. The selected transfer mode is not.

### 12.2 Root cause

`ftctl_dr_runtime_start_failback()` passes `failback-final` to
`ftctl_dr_runtime_reverse_checkpoint()`. The scheduler routes the reversed
ABLESTACK-to-VMware profile to `ftctl_dr_kvm_vmware_replication_cycle()`, where
`ftctl_dr_kvm_vmware_cycle_type()` currently contains:

```bash
case "${requested}" in
  failback-final|reverse-final) printf 'REVERSE_FINAL\n' ;;
  reprotect-seed|full-reverse-seed) printf 'FULL_REVERSE_SEED\n' ;;
  # ...
esac
```

This conflates two independent concepts:

- operation intent: final data synchronization before Failback;
- data mode: full reverse seed, reverse incremental, or reverse final delta.

`failback-final` describes the operation intent. It cannot imply an
incremental mode unless a valid durable reverse baseline already exists.

### 12.3 Normative selector contract

Replace the string-only selector with a probe plus decision result. The
functions remain shell-callable but return one compact JSON object:

```bash
ftctl_dr_kvm_vmware_probe_baseline() {
  # MISSING_EXPECTED, LOCAL_DURABLE, or INVALID
}

ftctl_dr_kvm_vmware_select_cycle_mode() {
  local plan="$1" operation_intent="$2" requested_mode="${3-AUTO}"
  # Emits requestedMode, effectiveMode, baselineFileState,
  # modeDecisionCode, and initialSeedRequired.
}
```

Required decision table:

| Operation intent | Requested mode | Baseline | Effective mode | Result |
|---|---|---|---|---|
| `FAILBACK_FINAL` | `AUTO` | missing | `FULL_REVERSE_SEED` | ready |
| `FAILBACK_FINAL` | `AUTO` | durable | `REVERSE_FINAL` | ready |
| `REPROTECT` | `AUTO` | missing | `FULL_REVERSE_SEED` | ready |
| `REPROTECT` | `AUTO` | durable | `REVERSE_INCREMENTAL` | ready |
| any | explicit incremental/final | missing | none | exit `83` |
| any | any non-forced mode | invalid | none | exit `84` |

The mode decision JSON is persisted before the mover starts:

```json
{
  "operationIntent": "FAILBACK_FINAL",
  "requestedMode": "AUTO",
  "effectiveMode": "FULL_REVERSE_SEED",
  "baselineFileState": "MISSING_EXPECTED",
  "modeDecisionCode": "INITIAL_REVERSE_BASELINE_ABSENT",
  "initialSeedRequired": true
}
```

`dr_kvm_vmware_mover.sh` receives only `effectiveMode`; it does not reinterpret
operation intent. Its existing exit `83` check remains a final defensive
guard, not the normal first-seed path.

### 12.4 Non-mutating reverse preflight

Add the FTCTL command:

```text
ablestack-vm-ftctl dr-reverse-preflight \
  --plan <uuid> --operation-intent failback-final \
  --requested-mode auto --json
```

It performs no snapshot creation and no target writes. It validates:

1. direction and provider pair are `KVM_TO_VMWARE` and
   `ABLESTACK_TO_VMWARE`;
2. disk indexes are unique and every RBD/QCOW2 source maps to one VMDK;
3. every source image/file exists and matches the active KVM domain;
4. the VMware destination VM is powered off;
5. vCenter credentials, VM reference, VDDK library, nbdkit plugin, and required
   helper commands are usable;
6. the baseline state and effective mode obey the decision table.

Success output includes:

```json
{
  "ready": true,
  "operationIntent": "FAILBACK_FINAL",
  "requestedMode": "AUTO",
  "effectiveMode": "FULL_REVERSE_SEED",
  "baselineFileState": "MISSING_EXPECTED",
  "modeDecisionCode": "INITIAL_REVERSE_BASELINE_ABSENT",
  "sourceDiskProbeState": "READY",
  "sourceDiskCount": 2,
  "targetWriterProbeState": "READY",
  "targetVmPowerState": "POWERED_OFF"
}
```

The writer probe may load libraries, authenticate, inspect the powered-off VM,
and open/close the target through a no-write capability probe. It must not
create snapshots, write sectors, or advance a baseline.

### 12.5 Runtime, checkpoint, and failure precedence

`ftctl_dr_runtime_reverse_checkpoint()` accepts separate
`operation_intent` and `requested_mode` parameters. It writes these fields to
the Run and failback session before dispatch:

```text
operation_intent=FAILBACK_FINAL
requested_mode=AUTO
effective_mode=FULL_REVERSE_SEED
mode_decision_code=INITIAL_REVERSE_BASELINE_ABSENT
baseline_file_state=MISSING_EXPECTED
replication_direction=KVM_TO_VMWARE
provider_pair=ABLESTACK_TO_VMWARE
```

After all VMDKs are flushed and verified, the full seed atomically commits
`baseline.json` generation 1 and a reverse checkpoint. Only then may FTCTL
publish `FAILBACK_DATA_READY`. A retry before that commit remains a full seed;
a retry after commit selects `REVERSE_FINAL`.

The first typed terminal error wins. A later Cloud data-gate projection must
not replace `DR_REVERSE_BASELINE_REQUIRED`, writer failure, or durability
failure with a secondary direction mismatch.

### 12.6 Self-test additions

Add deterministic tests for:

1. `failback-final + missing + AUTO -> FULL_REVERSE_SEED`;
2. `failback-final + durable + AUTO -> REVERSE_FINAL`;
3. explicit `REVERSE_FINAL + missing -> 83`;
4. invalid baseline never silently reseeds;
5. preflight is read-only and emits exactly one JSON object;
6. Run status records requested/effective mode before mover execution;
7. successful first seed commits generation 1 for every disk;
8. first terminal error remains unchanged during later reconciliation.

### 12.7 Revision 2 implementation priority

1. P0: replace the `failback-final` fixed mapping with the decision table.
2. P0: add read-only reverse preflight and exact JSON self-tests.
3. P0: persist requested/effective mode and provider pair before transfer.
4. P0: prove full reverse seed generation 1 on both mapped disks.
5. P1: normalize Agent status and Cloud error precedence.
6. P1: retain Cloud-owned target VM/volume materialization evidence.
7. P2: package, paired deploy, clean retry, then second-cycle incremental
   acceptance.

### 12.8 Revision 2 AS-IS / TO-BE

| Area | Error cause | AS-IS | TO-BE |
|---|---|---|---|
| Intent/mode | one string carries two meanings | `failback-final` forces `REVERSE_FINAL` | intent and mode are separate fields |
| First reverse seed | no baseline exists | deterministic exit `83` | `AUTO` selects `FULL_REVERSE_SEED` |
| Preflight | checks transition but not data mode | reports ready before selector failure | returns effective mode and probe states |
| Runtime evidence | mode fields remain empty | root cause appears only after exit | decision persisted before mover start |
| Baseline | generation 1 cannot be reached | no reverse lineage | atomic full seed creates generation 1 |
| Retry | same fixed selector repeats failure | retry is not useful | pre-commit retry remains full seed |
| Error identity | later gate can replace root cause | direction mismatch obscures exit `83` | first typed terminal error wins |

## 13. Transition preflight strict-output correction

Package verification for the preceding implementation is performed by the
branch GitHub Actions release workflow and the deployed-host checks described
in section 7.3.

The deployed retry preflight exposed a second early-failure boundary. After a
clean runtime removal, `dr-transition-preflight --json` correctly returned
`DR_TRANSITION_PREFLIGHT_STATE_MISSING`, but unset local variables also emitted
shell diagnostics to stderr. The Agent all-lines parser therefore received more
than one payload and rejected the response as invalid JSON.

The runtime now initializes every optional transition field before checking the
status file. Missing state emits exactly one typed JSON object, exit `79`, and no
stderr noise. `selftest_case_dr_transition_preflight_is_read_only` covers both
the ready and missing-state forms. The corrected focused self-test set passes:

```text
selftest_case_dr_transition_preflight_is_read_only: PASS
selftest_case_dr_kvm_vmware_initial_seed_accepts_missing_baseline: PASS
selftest_case_dr_kvm_vmware_reverse_route_and_baseline_contract: PASS
```

## 14. Revision 4: read-only snapshot attachment and terminal causality

The next live retry correctly selected `FULL_REVERSE_SEED` and created both
RBD snapshots, but `qemu-nbd` opened the immutable snapshot without
`--read-only` and failed with exit `86`. A concurrent dead-worker projection
published synthetic exit `70` before the mover's typed terminal result became
visible.

Document 450 supersedes the source NBD attachment and failure precedence parts
of this document. The source snapshot attachment is read-only, the worker gets
a bounded terminal-publication grace period, and an engine terminal envelope
has higher precedence than watchdog or Cloud data-gate derivations.
