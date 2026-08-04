# 448. FTCTL DR Initial Reverse Seed Baseline Absence And Terminal Evidence Design

- Date: 2026-08-04
- Status: code-level corrective design; implementation pending
- Scope: KVM-to-VMware initial reverse seed, failback worker terminal evidence, target-storage projection
- Parent design: [445-ftctl-dr-bidirectional-incremental-replication-and-reverse-guest-compatibility-design-20260801.md](445-ftctl-dr-bidirectional-incremental-replication-and-reverse-guest-compatibility-design-20260801.md)
- Cloud companion: `ablestack-cloud/docs/ftctl/591-cross-hypervisor-dr-failback-initial-reverse-seed-and-early-failure-convergence-design-20260804.md`

## 1. Objective

The first KVM-to-VMware reverse cycle must treat an absent reverse baseline as
the expected input for `FULL_REVERSE_SEED`. It must transfer every source disk,
verify the VMware target write, and only then atomically create generation 1 of
the reverse baseline.

An early mover failure must also converge as a terminal, typed operation while
preserving TARGET authority and the last known durable forward-protection
evidence.

## 2. Verified failure

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
run. The cycle selector is correct; the baseline loader violates its contract.

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
