#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
for library in common config logging libvirt_wrap state profile inventory cluster blockcopy dr_key standby xcolo fencing failover events dr_ablestack dr_vmware dr_scheduler guestprep dr_runtime verify orchestrator; do
  # shellcheck source=/dev/null
  source "${ROOT_DIR}/lib/ftctl/${library}.sh"
done

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT
FTCTL_RUN_DIR="${tmp_dir}/run"
FTCTL_LOG_DIR="${tmp_dir}/log"
FTCTL_EVENTS_LOG="${FTCTL_LOG_DIR}/events.log"
plan="plan-scope-smoke"
run="cleanup-run"
plan_dir="$(ftctl_dr_runtime_plan_dir "${plan}")"
run_path="$(ftctl_dr_runtime_run_path "${plan}" "${run}")"
status_path="$(ftctl_dr_runtime_status_path "${plan}")"
restore_points_path="${plan_dir}/restore-points.jsonl"
mkdir -p "$(dirname "${run_path}")" "${FTCTL_LOG_DIR}"
printf '{}\n' > "$(ftctl_dr_runtime_profile_path "${plan}")"
ftctl_state_write_kv_all "${run_path}" \
  "plan=${plan}" "run=${run}" "action=dr-test-cleanup" "state=READY" \
  "step=test-cleanup-completed" "progress=100" "restore_points_path=${restore_points_path}"
ftctl_state_write_kv_all "${status_path}" \
  "plan=${plan}" "action=dr-sync-start" "state=READY" "step=target-checkpoint-ready" \
  "progress=100" "restore_points_path=${restore_points_path}"
python3 - "${restore_points_path}" "${plan}" <<'PY'
import json
import sys

path, plan = sys.argv[1:3]
record = {
    "planUuid": plan,
    "runUuid": "sync-run",
    "producerRunUuid": "sync-run",
    "checkpointSequence": 7,
    "checkpointRef": f"ftctl:{plan}:sync-run:7",
    "cycleType": "incremental",
    "state": "READY",
    "sourceCheckpointAt": "2026-07-21T00:00:00Z",
    "targetDurableAt": "2026-07-21T00:00:02Z",
    "targetReadyRpoSeconds": 2,
    "requestedMode": "INCREMENTAL",
    "effectiveMode": "CBT_INCREMENTAL",
    "incrementalVerified": True,
    "metricsEstimated": False,
    "virtualBytes": 4096,
    "changedBytes": 512,
    "sourceReadBytes": 512,
    "targetWrittenBytes": 512,
    "transferPayloadBytes": 512,
    "changedExtentCount": 1,
    "durationMs": 10,
    "throughputBps": 51200,
    "baselineGeneration": 7,
    "cycleToken": f"{plan}:7",
}
with open(path, "w", encoding="utf-8") as fh:
    fh.write(json.dumps(record, separators=(",", ":")) + "\n")
PY

operation_json="$(ftctl_dr_runtime_status "${plan}" "${run}" 0 0 1)"
plan_json="$(ftctl_dr_runtime_status "${plan}" "" 0 0 1)"
jq -e '.status_scope == "OPERATION" and .run_uuid == "cleanup-run" and
  .latest_completed_checkpoint_sequence == 7 and .latest_completed_incremental_verified == true and
  .latest_completed_changed_bytes == 512 and .latest_completed_producer_run_uuid == "sync-run"' \
  <<< "${operation_json}" >/dev/null
jq -e '.status_scope == "PLAN_AUTHORITY" and (.run_uuid == null)' <<< "${plan_json}" >/dev/null
printf 'PASS: FTCTL DR status scopes preserve durable Plan checkpoint evidence\n'
