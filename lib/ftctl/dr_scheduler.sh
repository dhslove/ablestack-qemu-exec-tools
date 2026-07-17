#!/usr/bin/env bash
# ---------------------------------------------------------------------
# Copyright 2026 ABLECLOUD
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
# ---------------------------------------------------------------------

FTCTL_DR_SCHEDULER_INTERVAL_SEC="${FTCTL_DR_SCHEDULER_INTERVAL_SEC:-60}"
FTCTL_DR_SCHEDULER_MAX_CYCLES="${FTCTL_DR_SCHEDULER_MAX_CYCLES:-0}"
FTCTL_DR_SCHEDULER_DISABLE="${FTCTL_DR_SCHEDULER_DISABLE:-0}"
FTCTL_DR_CONTROL_ACK_TIMEOUT_SEC="${FTCTL_DR_CONTROL_ACK_TIMEOUT_SEC:-600}"
FTCTL_DR_TRANSITION_LOCK_TIMEOUT_SEC="${FTCTL_DR_TRANSITION_LOCK_TIMEOUT_SEC:-5}"
FTCTL_DR_CONTROL_PROTOCOL_VERSION="2"

ftctl_dr_scheduler_dir() {
  local plan="${1-}"
  printf '%s/scheduler\n' "$(ftctl_dr_runtime_plan_dir "${plan}")"
}

ftctl_dr_scheduler_pid_path() {
  local plan="${1-}" run="${2-}"
  printf '%s/%s.pid\n' "$(ftctl_dr_scheduler_dir "${plan}")" "$(ftctl_dr_runtime_key "${run}")"
}

ftctl_dr_scheduler_control_path() {
  local plan="${1-}"
  printf '%s/control.state\n' "$(ftctl_dr_scheduler_dir "${plan}")"
}

ftctl_dr_scheduler_control_ack_path() {
  local plan="${1-}"
  printf '%s/control.ack\n' "$(ftctl_dr_scheduler_dir "${plan}")"
}

ftctl_dr_scheduler_lock_dir() {
  local plan="${1-}"
  printf '%s/locks\n' "$(ftctl_dr_runtime_plan_dir "${plan}")"
}

ftctl_dr_scheduler_lock_path() {
  local plan="${1-}" scope="${2-}"
  printf '%s/%s.lock\n' "$(ftctl_dr_scheduler_lock_dir "${plan}")" "$(ftctl_dr_runtime_key "${scope}")"
}

ftctl_dr_scheduler_checkpoint_lease_path() {
  local plan="${1-}" sequence="${2-}"
  printf '%s/checkpoint-%s.lease\n' "$(ftctl_dr_scheduler_lock_dir "${plan}")" "$(ftctl_dr_runtime_key "${sequence:-latest}")"
}

ftctl_dr_scheduler_lock_acquire() {
  local plan="${1-}" scope="${2-}" fd="${3-}" timeout_sec="${4-0}" owner="${5-unknown}"
  local lock_path
  [[ "${fd}" =~ ^[0-9]+$ ]] || return 2
  lock_path="$(ftctl_dr_scheduler_lock_path "${plan}" "${scope}")"
  ftctl_ensure_dir "$(dirname "${lock_path}")" "0755"
  eval "exec ${fd}>\"${lock_path}\""
  if ! flock -w "${timeout_sec}" "${fd}"; then
    eval "exec ${fd}>&-"
    return 20
  fi
  {
    printf 'pid=%s\n' "$$"
    printf 'owner=%s\n' "${owner}"
    printf 'scope=%s\n' "${scope}"
    printf 'started_at=%s\n' "$(ftctl_now_iso8601)"
  } > "${lock_path}.meta" 2>/dev/null || true
}

ftctl_dr_scheduler_lock_release() {
  local plan="${1-}" scope="${2-}" fd="${3-}"
  local lock_path
  [[ "${fd}" =~ ^[0-9]+$ ]] || return 0
  lock_path="$(ftctl_dr_scheduler_lock_path "${plan}" "${scope}")"
  flock -u "${fd}" 2>/dev/null || true
  eval "exec ${fd}>&-" 2>/dev/null || true
  rm -f "${lock_path}.meta" 2>/dev/null || true
}

ftctl_dr_scheduler_restore_points_path() {
  local plan="${1-}"
  printf '%s/restore-points.jsonl\n' "$(ftctl_dr_runtime_plan_dir "${plan}")"
}

ftctl_dr_scheduler_log_path() {
  local plan="${1-}" run="${2-}"
  printf '%s/dr-scheduler-%s-%s.log\n' "${FTCTL_LOG_DIR}" "$(ftctl_dr_runtime_key "${plan}")" "$(ftctl_dr_runtime_key "${run}")"
}

ftctl_dr_scheduler_profile_provider() {
  local profile_file="${1-}" endpoint="${2-}"
  ftctl_dr_runtime_profile_value "${profile_file}" "${endpoint}.provider" 2>/dev/null | tr '[:lower:]' '[:upper:]' || true
}

ftctl_dr_scheduler_profile_int() {
  local profile_file="${1-}" field="${2-}" default_value="${3-}"
  local value
  value="$(ftctl_dr_runtime_profile_value "${profile_file}" "${field}" 2>/dev/null || true)"
  if [[ "${value}" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "${value}"
  else
    printf '%s\n' "${default_value}"
  fi
}

ftctl_dr_scheduler_interval() {
  local profile_file="${1-}"
  local interval
  interval="$(ftctl_dr_scheduler_profile_int "${profile_file}" "schedule.intervalSeconds" "${FTCTL_DR_SCHEDULER_INTERVAL_SEC}")"
  [[ "${interval}" =~ ^[0-9]+$ ]] || interval="${FTCTL_DR_SCHEDULER_INTERVAL_SEC}"
  printf '%s\n' "${interval}"
}

ftctl_dr_scheduler_max_cycles() {
  local profile_file="${1-}"
  local max_cycles
  max_cycles="$(ftctl_dr_scheduler_profile_int "${profile_file}" "request.maxCycles" "${FTCTL_DR_SCHEDULER_MAX_CYCLES}")"
  [[ "${max_cycles}" =~ ^[0-9]+$ ]] || max_cycles="${FTCTL_DR_SCHEDULER_MAX_CYCLES}"
  printf '%s\n' "${max_cycles}"
}

ftctl_dr_scheduler_pid_alive() {
  local pid_path="${1-}" expected_plan="${2-}" expected_run="${3-}" pid cmdline
  [[ -n "${pid_path}" && -f "${pid_path}" ]] || return 1
  pid="$(tr -d '[:space:]' < "${pid_path}" 2>/dev/null || true)"
  [[ "${pid}" =~ ^[0-9]+$ ]] || return 1
  kill -0 "${pid}" >/dev/null 2>&1 || return 1
  if [[ -n "${expected_plan}" || -n "${expected_run}" ]]; then
    cmdline="$(tr '\0' ' ' < "/proc/${pid}/cmdline" 2>/dev/null || true)"
    [[ -z "${expected_plan}" || "${cmdline}" == *"--plan ${expected_plan}"* ]] || return 1
    [[ -z "${expected_run}" || "${cmdline}" == *"--run ${expected_run}"* ]] || return 1
  fi
  return 0
}

ftctl_dr_scheduler_profile_has_data_plane() {
  local profile_file="${1-}"
  local source_provider target_provider
  source_provider="$(ftctl_dr_scheduler_profile_provider "${profile_file}" source)"
  target_provider="$(ftctl_dr_scheduler_profile_provider "${profile_file}" target)"
  [[ "${source_provider}" == "ABLESTACK" || "${target_provider}" == "ABLESTACK" ||
      "${source_provider}" == "VMWARE" || "${target_provider}" == "VMWARE" ]]
}

ftctl_dr_scheduler_control_generation() {
  local plan="${1-}" control_path generation
  control_path="$(ftctl_dr_scheduler_control_path "${plan}")"
  generation="$(ftctl_state_read_kv "${control_path}" "generation" 2>/dev/null || true)"
  [[ "${generation}" =~ ^[0-9]+$ ]] || generation=0
  printf '%s\n' "${generation}"
}

ftctl_dr_scheduler_control_set() {
  local plan="${1-}" command="${2-}" reason="${3-operator}" owner_run="${4-}" resume_after_cleanup="${5-false}"
  local control_path generation
  control_path="$(ftctl_dr_scheduler_control_path "${plan}")"
  ftctl_ensure_dir "$(dirname "${control_path}")" "0755"
  ftctl_dr_scheduler_lock_acquire "${plan}" "plan" 204 "${FTCTL_DR_TRANSITION_LOCK_TIMEOUT_SEC}" "control:${command}:${owner_run}" || return $?
  generation=$(( $(ftctl_dr_scheduler_control_generation "${plan}") + 1 ))
  if ! ftctl_state_write_kv_all "${control_path}" \
    "version=${FTCTL_DR_CONTROL_PROTOCOL_VERSION}" \
    "generation=${generation}" \
    "command=${command}" \
    "reason=${reason}" \
    "owner_run=${owner_run}" \
    "resume_after_cleanup=${resume_after_cleanup}" \
    "requested_at=$(ftctl_now_iso8601)" \
    "updated_at=$(ftctl_now_iso8601)"; then
    ftctl_dr_scheduler_lock_release "${plan}" "plan" 204
    return 2
  fi
  ftctl_dr_scheduler_lock_release "${plan}" "plan" 204
  printf '%s\n' "${generation}"
}

ftctl_dr_scheduler_control_command() {
  local plan="${1-}"
  local control_path
  control_path="$(ftctl_dr_scheduler_control_path "${plan}")"
  ftctl_state_read_kv "${control_path}" "command" 2>/dev/null || true
}

ftctl_dr_scheduler_control_value() {
  local plan="${1-}" key="${2-}" control_path
  control_path="$(ftctl_dr_scheduler_control_path "${plan}")"
  ftctl_state_read_kv "${control_path}" "${key}" 2>/dev/null || true
}

ftctl_dr_scheduler_control_ack() {
  local plan="${1-}" generation="${2-}" state="${3-}" cycle_state="${4-IDLE}" owner_run="${5-}"
  local ack_path
  ack_path="$(ftctl_dr_scheduler_control_ack_path "${plan}")"
  ftctl_ensure_dir "$(dirname "${ack_path}")" "0755"
  ftctl_state_write_kv_all "${ack_path}" \
    "version=${FTCTL_DR_CONTROL_PROTOCOL_VERSION}" \
    "generation=${generation}" \
    "state=${state}" \
    "cycle_state=${cycle_state}" \
    "owner_run=${owner_run}" \
    "acknowledged_at=$(ftctl_now_iso8601)"
}

ftctl_dr_scheduler_wait_for_ack() {
  local plan="${1-}" generation="${2-}" expected_state="${3-}" timeout_sec="${4-${FTCTL_DR_CONTROL_ACK_TIMEOUT_SEC}}"
  local ack_path deadline ack_generation ack_state
  ack_path="$(ftctl_dr_scheduler_control_ack_path "${plan}")"
  [[ "${timeout_sec}" =~ ^[0-9]+$ ]] || timeout_sec="${FTCTL_DR_CONTROL_ACK_TIMEOUT_SEC}"
  deadline=$(( $(date +%s) + timeout_sec ))
  while (( $(date +%s) <= deadline )); do
    ack_generation="$(ftctl_state_read_kv "${ack_path}" "generation" 2>/dev/null || true)"
    ack_state="$(ftctl_state_read_kv "${ack_path}" "state" 2>/dev/null || true)"
    if [[ "${ack_generation}" == "${generation}" && "${ack_state}" == "${expected_state}" ]]; then
      return 0
    fi
    sleep 1
  done
  return 21
}

ftctl_dr_scheduler_has_live_worker() {
  local plan="${1-}" pid_path
  shopt -s nullglob
  for pid_path in "$(ftctl_dr_scheduler_dir "${plan}")"/*.pid; do
    if ftctl_dr_scheduler_pid_alive "${pid_path}"; then
      shopt -u nullglob
      return 0
    fi
  done
  shopt -u nullglob
  return 1
}

ftctl_dr_scheduler_request_and_wait() {
  local plan="${1-}" command="${2-}" expected_state="${3-}" reason="${4-operator}" owner_run="${5-}" resume_after_cleanup="${6-false}"
  local generation
  generation="$(ftctl_dr_scheduler_control_set "${plan}" "${command}" "${reason}" "${owner_run}" "${resume_after_cleanup}")" || return $?
  if ! ftctl_dr_scheduler_has_live_worker "${plan}" && [[ "${command}" != "run" ]]; then
    ftctl_dr_scheduler_control_ack "${plan}" "${generation}" "${expected_state}" "IDLE" "${owner_run}"
  fi
  ftctl_dr_scheduler_wait_for_ack "${plan}" "${generation}" "${expected_state}" || return $?
  printf '%s\n' "${generation}"
}

ftctl_dr_scheduler_ensure_running() {
  local plan="${1-}" run="${2-}" profile_file="${3-}" state_path="${4-}" status_path="${5-}"
  local pid_path generation now

  [[ -n "${plan}" && -n "${run}" && -f "${profile_file}" && -f "${state_path}" ]] || return 2
  pid_path="$(ftctl_dr_scheduler_pid_path "${plan}" "${run}")"
  if ftctl_dr_scheduler_pid_alive "${pid_path}" "${plan}" "${run}"; then
    return 0
  fi

  now="$(ftctl_now_iso8601)"
  generation=$(( $(ftctl_dr_scheduler_control_generation "${plan}") + 1 ))
  ftctl_dr_scheduler_update_state "${state_path}" "${status_path}" \
    "scheduler_state=RECOVERING" \
    "scheduler_pid_alive=false" \
    "runtime_generation=${generation}" \
    "worker_pid=" \
    "updated_at=${now}" || return $?
  rm -f "${pid_path}" 2>/dev/null || true
  ftctl_dr_scheduler_start "${plan}" "${run}" "${profile_file}" "${state_path}" "${status_path}" "false" || return $?

  # Background start writes the owned PID before returning. A missing PID here
  # means the profile is not schedulable (or startup was suppressed), so do
  # not spend the full control ACK timeout pretending recovery is in progress.
  if [[ ! -s "${pid_path}" ]]; then
    ftctl_dr_scheduler_update_state "${state_path}" "${status_path}" \
      "scheduler_state=ERROR" \
      "scheduler_pid_alive=false" \
      "error_code=DR_SCHEDULER_NOT_RUNNING" \
      "error_message=Scheduler did not create an owned PID" \
      "updated_at=$(ftctl_now_iso8601)" || true
    return 22
  fi

  local deadline=$(( $(date +%s) + FTCTL_DR_CONTROL_ACK_TIMEOUT_SEC ))
  while (( $(date +%s) <= deadline )); do
    if ftctl_dr_scheduler_pid_alive "${pid_path}" "${plan}" "${run}"; then
      ftctl_dr_scheduler_update_state "${state_path}" "${status_path}" \
        "scheduler_state=RUNNING" \
        "scheduler_pid_alive=true" \
        "updated_at=$(ftctl_now_iso8601)" || true
      return 0
    fi
    sleep 1
  done

  ftctl_dr_scheduler_update_state "${state_path}" "${status_path}" \
    "scheduler_state=ERROR" \
    "scheduler_pid_alive=false" \
    "error_code=DR_SCHEDULER_NOT_RUNNING" \
    "error_message=Scheduler process ownership could not be established" \
    "updated_at=$(ftctl_now_iso8601)" || true
  return 22
}

ftctl_dr_scheduler_checkpoint_lease_acquire() {
  local plan="${1-}" sequence="${2-}" run="${3-}" ref="${4-}" lease_path
  lease_path="$(ftctl_dr_scheduler_checkpoint_lease_path "${plan}" "${sequence}")"
  ftctl_ensure_dir "$(dirname "${lease_path}")" "0755"
  ftctl_state_write_kv_all "${lease_path}" \
    "plan=${plan}" \
    "run=${run}" \
    "checkpoint_sequence=${sequence}" \
    "checkpoint_ref=${ref}" \
    "state=LEASED" \
    "leased_at=$(ftctl_now_iso8601)"
  printf '%s\n' "${lease_path}"
}

ftctl_dr_scheduler_checkpoint_lease_release() {
  local plan="${1-}" sequence="${2-}"
  rm -f "$(ftctl_dr_scheduler_checkpoint_lease_path "${plan}" "${sequence}")" 2>/dev/null || true
}

ftctl_dr_scheduler_transition_begin() {
  local plan="${1-}" run="${2-}" action="${3-}" run_path="${4-}" status_path="${5-}"
  local generation now
  ftctl_dr_scheduler_lock_acquire "${plan}" "transition" 203 "${FTCTL_DR_TRANSITION_LOCK_TIMEOUT_SEC}" "${action}:${run}" || return $?
  FTCTL_DR_TRANSITION_LOCK_HELD=1
  generation="$(ftctl_dr_scheduler_request_and_wait "${plan}" "pause" "PAUSED" "${action}" "${run}" "true")" || {
    ftctl_dr_scheduler_transition_end "${plan}"
    return 21
  }
  now="$(ftctl_now_iso8601)"
  ftctl_dr_scheduler_update_state "${run_path}" "${status_path}" \
    "control_protocol_version=${FTCTL_DR_CONTROL_PROTOCOL_VERSION}" \
    "control_generation=${generation}" \
    "control_ack_generation=${generation}" \
    "control_state=PAUSED" \
    "cycle_state=IDLE" \
    "transition_state=QUIESCED" \
    "transition_action=${action}" \
    "transition_quiesced_at=${now}" \
    "updated_at=${now}" || true
}

ftctl_dr_scheduler_transition_end() {
  local plan="${1-}"
  if [[ "${FTCTL_DR_TRANSITION_LOCK_HELD:-0}" == "1" ]]; then
    ftctl_dr_scheduler_lock_release "${plan}" "transition" 203
  fi
  FTCTL_DR_TRANSITION_LOCK_HELD=0
}

ftctl_dr_scheduler_resume_after_transition() {
  local plan="${1-}" run="${2-}" reason="${3-transition-complete}" run_path="${4-}" status_path="${5-}"
  local generation now
  generation="$(ftctl_dr_scheduler_request_and_wait "${plan}" "run" "RUNNING" "${reason}" "${run}" "false")" || return $?
  now="$(ftctl_now_iso8601)"
  ftctl_dr_scheduler_update_state "${run_path}" "${status_path}" \
    "control_protocol_version=${FTCTL_DR_CONTROL_PROTOCOL_VERSION}" \
    "control_generation=${generation}" \
    "control_ack_generation=${generation}" \
    "control_state=RUNNING" \
    "cycle_state=IDLE" \
    "transition_state=COMPLETED" \
    "updated_at=${now}" || true
}

ftctl_dr_scheduler_update_state() {
  local state_path="${1-}" status_path="${2-}"
  shift 2
  ftctl_dr_runtime_path_set "${state_path}" "$@" || return $?
  cp -f "${state_path}" "${status_path}" 2>/dev/null || true
  chmod 0644 "${status_path}" 2>/dev/null || true
}

ftctl_dr_scheduler_checkpoint_value() {
  local checkpoint_path="${1-}" field="${2-}" expected_type="${3-string}"
  [[ -n "${checkpoint_path}" && -f "${checkpoint_path}" ]] || return 1
  python3 - "${checkpoint_path}" "${field}" "${expected_type}" <<'PY' 2>/dev/null
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as fh:
    data = json.load(fh)
value = data.get(sys.argv[2])
expected = sys.argv[3]
if value is None:
    print("")
elif expected == "boolean":
    if not isinstance(value, bool):
        raise SystemExit(65)
    print("true" if value else "false")
elif expected == "integer":
    if isinstance(value, bool) or not isinstance(value, int):
        raise SystemExit(65)
    print(value)
elif expected == "string":
    if not isinstance(value, str):
        raise SystemExit(65)
    print(value)
else:
    raise SystemExit(65)
PY
}

ftctl_dr_scheduler_append_restore_point() {
  local restore_points_path="${1-}" plan="${2-}" run="${3-}" sequence="${4-}" cycle_type="${5-}" driver="${6-}" manifest_path="${7-}" checkpoint_path="${8-}"
  ftctl_ensure_dir "$(dirname "${restore_points_path}")" "0755"
  python3 - "${restore_points_path}" "${plan}" "${run}" "${sequence}" "${cycle_type}" "${driver}" "${manifest_path}" "${checkpoint_path}" "$(ftctl_now_iso8601)" <<'PY'
import json
import os
import sys

restore_path, plan, run, sequence, cycle_type, driver, manifest_path, checkpoint_path, now = sys.argv[1:10]
checkpoint = {}
if os.path.exists(checkpoint_path):
    with open(checkpoint_path, "r", encoding="utf-8") as fh:
        checkpoint = json.load(fh)
record = {
    "planUuid": plan,
    "runUuid": run,
    "checkpointSequence": int(sequence),
    "checkpointRef": f"ftctl:{plan}:{run}:{sequence}",
    "cycleType": cycle_type,
    "driver": driver,
    "manifest": manifest_path,
    "checkpoint": checkpoint_path,
    "sourceCheckpointAt": checkpoint.get("sourceCheckpointAt"),
    "targetDurableAt": checkpoint.get("targetDurableAt"),
    "targetReadyRpoSeconds": checkpoint.get("targetReadyRpoSeconds"),
    "state": checkpoint.get("state"),
    "recordedAt": now,
}
metrics = checkpoint.get("cycleMetrics") or {}
if metrics:
    record["cycleMetrics"] = metrics
    for key in (
        "cycleUuid", "cycleToken", "requestedMode", "effectiveMode",
        "automaticReseed", "modeDecisionCode", "reseedReason", "invalidBaselineDiskCount",
        "incrementalVerified", "baselineGeneration", "cycleCommitState",
        "virtualBytes", "changedBytes", "sourceReadBytes", "targetWrittenBytes",
        "transferPayloadBytes", "changedExtentCount", "durationMs", "throughputBps",
    ):
        if key in metrics:
            record[key] = metrics[key]
with open(restore_path, "a", encoding="utf-8") as fh:
    fh.write(json.dumps(record, sort_keys=True, separators=(",", ":")) + "\n")
PY
}

ftctl_dr_scheduler_driver_name() {
  local source_provider="${1-}" target_provider="${2-}"
  if [[ "${source_provider}" == "ABLESTACK" && "${target_provider}" == "ABLESTACK" ]]; then
    printf 'ABLESTACK\n'
  elif [[ "${source_provider}" == "VMWARE" && "${target_provider}" == "VMWARE" ]]; then
    printf 'VMWARE\n'
  else
    printf 'MIXED\n'
  fi
}

ftctl_dr_scheduler_cycle_type() {
  local sequence="${1-}" source_provider="${2-}" state_path="${3-}" disk_map=""
  if [[ "${sequence}" == "1" ]]; then
    printf 'full-seed\n'
  elif [[ "${source_provider}" == "VMWARE" ]]; then
    disk_map="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "source_disk_map_path")"
    if [[ -n "${disk_map}" && -f "${disk_map}" ]] &&
        jq -e '.disks | [
          .[] | select(
            (.changeId // .cbtChangeId // "") == ""
            or ((.baselineState // "") != "" and .baselineState != "LOCAL_DURABLE")
            or (.baselineGeneration // 0) <= 0
          )
        ] | length > 0' "${disk_map}" >/dev/null 2>&1; then
      printf 'full-reseed\n'
    else
      printf 'incremental\n'
    fi
  else
    printf 'incremental\n'
  fi
}

ftctl_dr_scheduler_run_cycle() {
  local plan="${1-}" run="${2-}" profile_file="${3-}" sequence="${4-}" cycle_type="${5-}"
  local source_provider target_provider
  source_provider="$(ftctl_dr_scheduler_profile_provider "${profile_file}" source)"
  target_provider="$(ftctl_dr_scheduler_profile_provider "${profile_file}" target)"
  if [[ "${source_provider}" == "ABLESTACK" && "${target_provider}" == "ABLESTACK" ]]; then
    ftctl_dr_ablestack_replication_cycle "${plan}" "${run}" "${profile_file}" "${sequence}" "${cycle_type}"
    return $?
  fi
  if [[ "${source_provider}" == "VMWARE" || "${target_provider}" == "VMWARE" ]]; then
    ftctl_dr_vmware_replication_cycle "${plan}" "${run}" "${profile_file}" "${sequence}" "${cycle_type}"
    return $?
  fi
  return 66
}

ftctl_dr_scheduler_sleep_or_stop() {
  local plan="${1-}" interval="${2-}"
  local slept=0 command
  [[ "${interval}" =~ ^[0-9]+$ ]] || interval="0"
  while (( slept < interval )); do
    command="$(ftctl_dr_scheduler_control_command "${plan}")"
    [[ "${command}" != "stop" && "${command}" != "pause" ]] || return 1
    sleep 1
    slept=$((slept + 1))
  done
  return 0
}

ftctl_dr_scheduler_last_sequence() {
  local restore_points_path="${1-}" plan="${2-}" run="${3-}"
  [[ -f "${restore_points_path}" ]] || {
    printf '0\n'
    return 0
  }
  python3 - "${restore_points_path}" "${plan}" "${run}" <<'PY'
import json
import sys

path, plan, run = sys.argv[1:4]
latest = 0
with open(path, "r", encoding="utf-8") as fh:
    for line in fh:
        try:
            record = json.loads(line)
        except (TypeError, ValueError):
            continue
        if record.get("planUuid") != plan or record.get("runUuid") != run:
            continue
        try:
            latest = max(latest, int(record.get("checkpointSequence") or 0))
        except (TypeError, ValueError):
            pass
print(latest)
PY
}

ftctl_dr_scheduler_iso_from_epoch() {
  local epoch="${1-}"
  [[ "${epoch}" =~ ^[0-9]+$ ]] || return 1
  date -u -d "@${epoch}" '+%Y-%m-%dT%H:%M:%SZ'
}

ftctl_dr_scheduler_worker() {
  local plan="${1-}" run="${2-}" profile_file="${3-}" state_path="${4-}" status_path="${5-}"
  local pid_path restore_points_path interval max_cycles sequence=0 command cycle_type source_provider target_provider driver
  local output rc manifest_path checkpoint_path source_at target_at rpo now error_code error_message data_commit_state cycle_retry_mode checkpoint_ref
  local requested_mode effective_mode automatic_reseed mode_decision_code reseed_reason invalid_baseline_disk_count
  local incremental_verified metrics_estimated virtual_bytes changed_bytes source_read_bytes target_written_bytes transfer_payload_bytes changed_extent_count duration_ms throughput_bps baseline_generation cycle_token cycle_metrics_path
  local cycle_started_epoch next_cycle_epoch next_cycle_at wait_seconds control_generation

  [[ -n "${plan}" && -n "${run}" && -f "${profile_file}" && -f "${state_path}" ]] || return 2
  ftctl_ensure_dir "$(ftctl_dr_scheduler_dir "${plan}")" "0755"
  pid_path="$(ftctl_dr_scheduler_pid_path "${plan}" "${run}")"
  restore_points_path="$(ftctl_dr_scheduler_restore_points_path "${plan}")"
  sequence="$(ftctl_dr_scheduler_last_sequence "${restore_points_path}" "${plan}" "${run}" || printf '0')"
  [[ "${sequence}" =~ ^[0-9]+$ ]] || sequence=0
  interval="$(ftctl_dr_scheduler_interval "${profile_file}")"
  max_cycles="$(ftctl_dr_scheduler_max_cycles "${profile_file}")"
  source_provider="$(ftctl_dr_scheduler_profile_provider "${profile_file}" source)"
  target_provider="$(ftctl_dr_scheduler_profile_provider "${profile_file}" target)"
  driver="$(ftctl_dr_scheduler_driver_name "${source_provider}" "${target_provider}")"

  printf '%s\n' "$$" > "${pid_path}"
  control_generation="$(ftctl_dr_scheduler_control_set "${plan}" "run" "scheduler-start" "${run}")"
  ftctl_dr_scheduler_control_ack "${plan}" "${control_generation}" "RUNNING" "IDLE" "${run}"
  now="$(ftctl_now_iso8601)"
  ftctl_dr_scheduler_update_state "${state_path}" "${status_path}" \
    "scheduler_state=RUNNING" \
    "control_protocol_version=${FTCTL_DR_CONTROL_PROTOCOL_VERSION}" \
    "control_generation=${control_generation}" \
    "control_ack_generation=${control_generation}" \
    "control_state=RUNNING" \
    "cycle_state=IDLE" \
    "worker_pid=$$" \
    "restore_points_path=${restore_points_path}" \
    "driver=${driver}" \
    "updated_at=${now}" || true
  ftctl_log_event "dr-runtime" "dr.scheduler.start" "ok" "" "" \
    "plan=${plan} run=${run} driver=${driver} interval=${interval} max_cycles=${max_cycles}"

  while true; do
    command="$(ftctl_dr_scheduler_control_command "${plan}")"
    control_generation="$(ftctl_dr_scheduler_control_value "${plan}" "generation")"
    if [[ "${command}" == "stop" ]]; then
      now="$(ftctl_now_iso8601)"
      ftctl_dr_scheduler_control_ack "${plan}" "${control_generation}" "STOPPED" "IDLE" "${run}"
      ftctl_dr_scheduler_update_state "${state_path}" "${status_path}" \
        "state=CANCELED" \
        "step=scheduler-stopped" \
        "progress=100" \
        "scheduler_state=STOPPED" \
        "control_generation=${control_generation}" \
        "control_ack_generation=${control_generation}" \
        "control_state=STOPPED" \
        "cycle_state=IDLE" \
        "updated_at=${now}" || true
      break
    fi

    if [[ "${command}" == "pause" ]]; then
      now="$(ftctl_now_iso8601)"
      ftctl_dr_scheduler_control_ack "${plan}" "${control_generation}" "PAUSED" "IDLE" "${run}"
      ftctl_dr_scheduler_update_state "${state_path}" "${status_path}" \
        "state=PAUSED" \
        "step=sync-paused" \
        "scheduler_state=PAUSED" \
        "control_generation=${control_generation}" \
        "control_ack_generation=${control_generation}" \
        "control_state=PAUSED" \
        "cycle_state=IDLE" \
        "updated_at=${now}" || true
      sleep 1
      continue
    fi

    ftctl_dr_scheduler_control_ack "${plan}" "${control_generation}" "RUNNING" "IDLE" "${run}"
    ftctl_dr_scheduler_update_state "${state_path}" "${status_path}" \
      "scheduler_state=RUNNING" \
      "control_generation=${control_generation}" \
      "control_ack_generation=${control_generation}" \
      "control_state=RUNNING" \
      "cycle_state=IDLE" \
      "updated_at=$(ftctl_now_iso8601)" || true

    sequence=$((sequence + 1))
    cycle_type="$(ftctl_dr_scheduler_cycle_type "${sequence}" "${source_provider}" "${state_path}")"
    checkpoint_ref="ftctl:${plan}:${run}:${sequence}"
    cycle_started_epoch="$(date +%s)"
    now="$(ftctl_now_iso8601)"
    if ! ftctl_dr_scheduler_lock_acquire "${plan}" "cycle" 202 0 "${run}:${sequence}"; then
      sequence=$((sequence - 1))
      sleep 1
      continue
    fi
    ftctl_dr_scheduler_update_state "${state_path}" "${status_path}" \
      "state=SYNCING" \
      "step=${cycle_type}-transfer" \
      "progress=40" \
      "scheduler_state=RUNNING" \
      "control_generation=${control_generation}" \
      "control_ack_generation=${control_generation}" \
      "control_state=RUNNING" \
      "cycle_state=RUNNING" \
      "checkpoint_sequence=${sequence}" \
      "checkpoint_cycle_type=${cycle_type}" \
      "checkpoint_ref=${checkpoint_ref}" \
      "current_checkpoint_sequence=${sequence}" \
      "current_checkpoint_cycle_type=${cycle_type}" \
      "current_checkpoint_requested_mode=$([[ "${cycle_type}" == "full-seed" ]] && printf FULL_SEED || { [[ "${cycle_type}" == "full-reseed" ]] && printf FULL_RESEED || printf CBT_INCREMENTAL; })" \
      "current_checkpoint_effective_mode=" \
      "current_checkpoint_mode_decision_code=" \
      "current_checkpoint_automatic_reseed=false" \
      "current_checkpoint_invalid_baseline_disk_count=0" \
      "current_checkpoint_ref=${checkpoint_ref}" \
      "current_checkpoint_state=TRANSFERRING" \
      "runtime_generation=${sequence}" \
      "baseline_state=$([[ "${cycle_type}" == "full-reseed" ]] && printf REBUILDING || printf COMMITTED)" \
      "reseed_reason=$([[ "${cycle_type}" == "full-reseed" ]] && printf MISSING_OR_INVALID_COMMITTED_BASELINE || printf '')" \
      "updated_at=${now}" || true

    rc=0
    output="$(ftctl_dr_scheduler_run_cycle "${plan}" "${run}" "${profile_file}" "${sequence}" "${cycle_type}")" || rc=$?
    ftctl_dr_scheduler_lock_release "${plan}" "cycle" 202
    if [[ "${rc}" != "0" ]]; then
      case "${rc}" in
        65) error_code="DR_VMWARE_MOVER_UNAVAILABLE" ;;
        68) error_code="DR_VMWARE_MOVER_FAILED" ;;
        69) error_code="DR_VMWARE_NBDKIT_FAILED" ;;
        70) error_code="DR_VDDK_LIBDIR_UNRESOLVED" ;;
        71) error_code="DR_VDDK_LIBRARY_LOAD_FAILED" ;;
        72) error_code="DR_VMWARE_MOVER_SOURCE_GRAPH_INVALID" ;;
        73) error_code="DR_VMWARE_VDDK_CONNECT_INVALID" ;;
        74) error_code="DR_VMWARE_VDDK_EXPORT_UNAVAILABLE" ;;
        75) error_code="DR_VMWARE_VDDK_SOURCE_LOCKED" ;;
        76) error_code="DR_VMWARE_VDDK_OPEN_DENIED" ;;
        77) error_code="DR_VMWARE_VDDK_THUMBPRINT_UNRESOLVED" ;;
        80) error_code="DR_VMWARE_CBT_DISK_ID_UNRESOLVED" ;;
        81) error_code="DR_VMWARE_SNAPSHOT_REF_UNRESOLVED" ;;
        82) error_code="DR_CBT_QUERY_FAILED" ;;
        83) error_code="DR_CBT_BASELINE_INVALID" ;;
        84) error_code="DR_CBT_EXTENT_INVALID" ;;
        85) error_code="DR_CBT_RESEED_REQUIRED" ;;
        86) error_code="DR_CBT_PATCH_FAILED" ;;
        87) error_code="DR_CBT_METRICS_INVALID" ;;
        88) error_code="DR_CBT_LOCAL_COMMIT_FAILED" ;;
        89) error_code="DR_TARGET_NBD_SIZE_NOT_READY" ;;
        90) error_code="DR_CBT_RESEED_LOOP_DETECTED" ;;
        91) error_code="DR_CBT_BASELINE_NOT_DURABLE" ;;
        66) error_code="DR_UNSUPPORTED_DIRECTION" ;;
        *) error_code="DR_REPLICATION_CYCLE_FAILED" ;;
      esac
      case "${error_code}" in
        DR_CBT_METRICS_INVALID)
          error_message="Disk data was copied, but the cycle metrics could not be validated"
          data_commit_state="DATA_COPIED_METADATA_FAILED"
          cycle_retry_mode="RESEED_REQUIRED"
          ;;
        DR_CBT_LOCAL_COMMIT_FAILED)
          error_message="Disk data was copied, but the local cycle metadata commit failed"
          data_commit_state="LOCAL_COMMIT_FAILED"
          cycle_retry_mode="RESEED_REQUIRED"
          ;;
        DR_CBT_RESEED_LOOP_DETECTED|DR_CBT_BASELINE_NOT_DURABLE)
          error_message="Automatic reseed was blocked until the CBT baseline is repaired or explicitly reset"
          data_commit_state="BLOCKED"
          cycle_retry_mode="OPERATOR_REPAIR_REQUIRED"
          ;;
        *)
          error_message="FTCTL DR replication cycle failed"
          data_commit_state="FAILED"
          cycle_retry_mode="FULL_RETRY"
          ;;
      esac
      now="$(ftctl_now_iso8601)"
      ftctl_dr_scheduler_update_state "${state_path}" "${status_path}" \
        "state=ERROR" \
        "step=replication-cycle-failed" \
        "progress=100" \
        "accepted=false" \
        "scheduler_state=ERROR" \
        "cycle_state=FAILED" \
        "current_checkpoint_sequence=${sequence}" \
        "current_checkpoint_cycle_type=${cycle_type}" \
        "current_checkpoint_ref=${checkpoint_ref}" \
        "current_checkpoint_state=FAILED" \
        "current_checkpoint_mode_decision_code=${error_code}" \
        "runtime_generation=${sequence}" \
        "error_code=${error_code}" \
        "error_message=${error_message}" \
        "failed_component=vmware-mover" \
        "data_commit_state=${data_commit_state}" \
        "data_copied=$([[ "${data_commit_state}" == "DATA_COPIED_METADATA_FAILED" || "${data_commit_state}" == "LOCAL_COMMIT_FAILED" ]] && printf true || printf false)" \
        "metadata_committed=false" \
        "target_durable=false" \
        "cycle_retry_mode=${cycle_retry_mode}" \
        "updated_at=${now}" || true
      ftctl_log_event "dr-runtime" "dr.scheduler.cycle" "fail" "" "${rc}" \
        "plan=${plan} run=${run} sequence=${sequence} error=${error_code}"
      rm -f "${pid_path}" 2>/dev/null || true
      return "${rc}"
    fi

    manifest_path="$(awk -F '\t' 'NF >= 2 {print $1; exit}' <<< "${output}")"
    checkpoint_path="$(awk -F '\t' 'NF >= 2 {print $2; exit}' <<< "${output}")"
    source_at="$(ftctl_dr_scheduler_checkpoint_value "${checkpoint_path}" "sourceCheckpointAt" || true)"
    target_at="$(ftctl_dr_scheduler_checkpoint_value "${checkpoint_path}" "targetDurableAt" || true)"
    rpo="$(ftctl_dr_scheduler_checkpoint_value "${checkpoint_path}" "targetReadyRpoSeconds" || true)"
    effective_mode="$(ftctl_dr_scheduler_checkpoint_value "${checkpoint_path}" "effectiveMode" || true)"
    requested_mode="$(ftctl_dr_scheduler_checkpoint_value "${checkpoint_path}" "requestedMode" || true)"
    automatic_reseed="$(ftctl_dr_scheduler_checkpoint_value "${checkpoint_path}" "automaticReseed" boolean || true)"
    mode_decision_code="$(ftctl_dr_scheduler_checkpoint_value "${checkpoint_path}" "modeDecisionCode" || true)"
    reseed_reason="$(ftctl_dr_scheduler_checkpoint_value "${checkpoint_path}" "reseedReason" || true)"
    invalid_baseline_disk_count="$(ftctl_dr_scheduler_checkpoint_value "${checkpoint_path}" "invalidBaselineDiskCount" integer || true)"
    incremental_verified="$(ftctl_dr_scheduler_checkpoint_value "${checkpoint_path}" "incrementalVerified" boolean || true)"
    metrics_estimated="$(ftctl_dr_scheduler_checkpoint_value "${checkpoint_path}" "metricsEstimated" boolean || true)"
    virtual_bytes="$(ftctl_dr_scheduler_checkpoint_value "${checkpoint_path}" "virtualBytes" integer || true)"
    changed_bytes="$(ftctl_dr_scheduler_checkpoint_value "${checkpoint_path}" "changedBytes" integer || true)"
    source_read_bytes="$(ftctl_dr_scheduler_checkpoint_value "${checkpoint_path}" "sourceReadBytes" integer || true)"
    target_written_bytes="$(ftctl_dr_scheduler_checkpoint_value "${checkpoint_path}" "targetWrittenBytes" integer || true)"
    transfer_payload_bytes="$(ftctl_dr_scheduler_checkpoint_value "${checkpoint_path}" "transferPayloadBytes" integer || true)"
    changed_extent_count="$(ftctl_dr_scheduler_checkpoint_value "${checkpoint_path}" "changedExtentCount" integer || true)"
    duration_ms="$(ftctl_dr_scheduler_checkpoint_value "${checkpoint_path}" "durationMs" integer || true)"
    throughput_bps="$(ftctl_dr_scheduler_checkpoint_value "${checkpoint_path}" "throughputBps" integer || true)"
    baseline_generation="$(ftctl_dr_scheduler_checkpoint_value "${checkpoint_path}" "baselineGeneration" integer || true)"
    cycle_token="$(ftctl_dr_scheduler_checkpoint_value "${checkpoint_path}" "cycleToken" || true)"
    cycle_metrics_path="$(ftctl_dr_scheduler_checkpoint_value "${checkpoint_path}" "cycleMetricsPath" || true)"
    ftctl_dr_scheduler_append_restore_point "${restore_points_path}" "${plan}" "${run}" "${sequence}" "${cycle_type}" "${driver}" "${manifest_path}" "${checkpoint_path}" || return $?
    now="$(ftctl_now_iso8601)"
    ftctl_dr_scheduler_update_state "${state_path}" "${status_path}" \
      "state=SYNCING" \
      "step=target-checkpoint-ready" \
      "progress=100" \
      "accepted=true" \
      "scheduler_state=RUNNING" \
      "cycle_state=IDLE" \
      "driver=${driver}" \
      "driver_state=CHECKPOINT_READY" \
      "checkpoint_sequence=${sequence}" \
      "checkpoint_cycle_type=${cycle_type}" \
      "checkpoint_ref=${checkpoint_ref}" \
      "current_checkpoint_sequence=${sequence}" \
      "current_checkpoint_cycle_type=${cycle_type}" \
      "current_checkpoint_requested_mode=${requested_mode}" \
      "current_checkpoint_effective_mode=${effective_mode}" \
      "current_checkpoint_mode_decision_code=${mode_decision_code}" \
      "current_checkpoint_automatic_reseed=${automatic_reseed:-false}" \
      "current_checkpoint_invalid_baseline_disk_count=${invalid_baseline_disk_count:-0}" \
      "current_checkpoint_ref=${checkpoint_ref}" \
      "current_checkpoint_state=COMPLETED" \
      "runtime_generation=${sequence}" \
      "latest_completed_checkpoint_sequence=${sequence}" \
      "latest_completed_checkpoint_cycle_type=${cycle_type}" \
      "latest_completed_requested_mode=${requested_mode}" \
      "latest_completed_checkpoint_ref=${checkpoint_ref}" \
      "latest_completed_checkpoint_state=READY" \
      "latest_completed_source_checkpoint_at=${source_at}" \
      "latest_completed_target_durable_at=${target_at}" \
      "latest_completed_target_ready_rpo_seconds=${rpo}" \
      "latest_completed_manifest_path=${manifest_path}" \
      "latest_completed_checkpoint_path=${checkpoint_path}" \
      "manifest_path=${manifest_path}" \
      "checkpoint_path=${checkpoint_path}" \
      "restore_points_path=${restore_points_path}" \
      "last_source_checkpoint_at=${source_at}" \
      "last_target_durable_at=${target_at}" \
      "target_ready_rpo_seconds=${rpo}" \
      "latest_completed_effective_mode=${effective_mode}" \
      "latest_completed_mode_decision_code=${mode_decision_code}" \
      "latest_completed_reseed_reason=${reseed_reason}" \
      "latest_completed_automatic_reseed=${automatic_reseed:-false}" \
      "latest_completed_invalid_baseline_disk_count=${invalid_baseline_disk_count:-0}" \
      "consecutive_automatic_reseed_count=$([[ "${automatic_reseed:-false}" == "true" ]] && printf 1 || printf 0)" \
      "latest_completed_incremental_verified=${incremental_verified}" \
      "latest_completed_metrics_estimated=${metrics_estimated}" \
      "latest_completed_virtual_bytes=${virtual_bytes}" \
      "latest_completed_changed_bytes=${changed_bytes}" \
      "latest_completed_source_read_bytes=${source_read_bytes}" \
      "latest_completed_target_written_bytes=${target_written_bytes}" \
      "latest_completed_transfer_payload_bytes=${transfer_payload_bytes}" \
      "latest_completed_changed_extent_count=${changed_extent_count}" \
      "latest_completed_duration_ms=${duration_ms}" \
      "latest_completed_throughput_bps=${throughput_bps}" \
      "latest_completed_baseline_generation=${baseline_generation}" \
      "latest_completed_cycle_token=${cycle_token}" \
      "latest_completed_cycle_metrics_path=${cycle_metrics_path}" \
      "data_commit_state=LOCAL_DURABLE" \
      "data_copied=true" \
      "metadata_committed=true" \
      "target_durable=true" \
      "cycle_retry_mode=NONE" \
      "baseline_state=LOCAL_DURABLE" \
      "reseed_reason=${reseed_reason}" \
      "error_code=" \
      "error_message=" \
      "failed_component=" \
      "updated_at=${now}" || true
    ftctl_log_event "dr-runtime" "dr.scheduler.cycle" "ok" "" "" \
      "plan=${plan} run=${run} sequence=${sequence} type=${cycle_type} checkpoint=${checkpoint_path} rpo=${rpo}"

    if [[ "${max_cycles}" =~ ^[1-9][0-9]*$ && "${sequence}" -ge "${max_cycles}" ]]; then
      now="$(ftctl_now_iso8601)"
      ftctl_dr_scheduler_update_state "${state_path}" "${status_path}" \
        "state=READY" \
        "step=scheduler-completed" \
        "progress=100" \
        "scheduler_state=COMPLETED" \
        "updated_at=${now}" || true
      break
    fi

    next_cycle_epoch=$((cycle_started_epoch + interval))
    wait_seconds=$((next_cycle_epoch - $(date +%s)))
    (( wait_seconds < 0 )) && wait_seconds=0
    next_cycle_at="$(ftctl_dr_scheduler_iso_from_epoch "${next_cycle_epoch}" 2>/dev/null || true)"
    ftctl_dr_scheduler_update_state "${state_path}" "${status_path}" \
      "next_cycle_at=${next_cycle_at}" \
      "next_cycle_wait_seconds=${wait_seconds}" \
      "updated_at=$(ftctl_now_iso8601)" || true
    ftctl_dr_scheduler_sleep_or_stop "${plan}" "${wait_seconds}" || true
  done

  rm -f "${pid_path}" 2>/dev/null || true
}

ftctl_dr_scheduler_start() {
  local plan="${1-}" run="${2-}" profile_file="${3-}" state_path="${4-}" status_path="${5-}" wait_value="${6-}"
  local pid_path log_path pid driver_state now

  [[ "${FTCTL_DR_SCHEDULER_DISABLE}" == "1" ]] && return 0
  [[ -n "${profile_file}" && -f "${profile_file}" ]] || return 0
  ftctl_dr_scheduler_profile_has_data_plane "${profile_file}" || return 0
  driver_state="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "driver_state")"
  case "${driver_state}" in
    WAITING_*|MISSING_*) return 0 ;;
  esac

  ftctl_ensure_dir "$(ftctl_dr_scheduler_dir "${plan}")" "0755"
  pid_path="$(ftctl_dr_scheduler_pid_path "${plan}" "${run}")"
  if ftctl_dr_scheduler_pid_alive "${pid_path}" "${plan}" "${run}"; then
    pid="$(tr -d '[:space:]' < "${pid_path}")"
    ftctl_dr_runtime_path_set "${state_path}" "scheduler_state=RUNNING" "worker_pid=${pid}" || true
    return 0
  fi

  if [[ "${wait_value}" != "false" || "${FTCTL_DR_SCHEDULER_FOREGROUND:-0}" == "1" ]]; then
    ftctl_dr_scheduler_worker "${plan}" "${run}" "${profile_file}" "${state_path}" "${status_path}"
    return $?
  fi

  log_path="$(ftctl_dr_scheduler_log_path "${plan}" "${run}")"
  (
    trap - EXIT
    unset FTCTL_HELD_LOCK_FILE
    ftctl_dr_scheduler_worker "${plan}" "${run}" "${profile_file}" "${state_path}" "${status_path}"
  ) >> "${log_path}" 2>&1 &
  pid="$!"
  printf '%s\n' "${pid}" > "${pid_path}"
  now="$(ftctl_now_iso8601)"
  ftctl_dr_scheduler_update_state "${state_path}" "${status_path}" \
    "step=sync-worker-started" \
    "progress=10" \
    "scheduler_state=STARTED" \
    "worker_pid=${pid}" \
    "restore_points_path=$(ftctl_dr_scheduler_restore_points_path "${plan}")" \
    "updated_at=${now}" || true
}

ftctl_dr_scheduler_control_action() {
  local action="${1-}" plan="${2-}" run_path="${3-}" status_path="${4-}" profile_file="${5-}"
  local command expected_state now generation
  case "${action}" in
    dr-sync-pause) command="pause"; expected_state="PAUSED" ;;
    dr-sync-resume) command="run"; expected_state="RUNNING" ;;
    dr-release|dr-cancel) command="stop"; expected_state="STOPPED" ;;
    *) return 0 ;;
  esac
  if [[ "${action}" == "dr-sync-resume" ]]; then
    ftctl_dr_scheduler_ensure_running "${plan}" "$(ftctl_dr_runtime_state_get_from_path "${run_path}" run)" \
      "${profile_file}" "${run_path}" "${status_path}" || return $?
  fi
  generation="$(ftctl_dr_scheduler_request_and_wait "${plan}" "${command}" "${expected_state}" "${action}" "$(ftctl_dr_runtime_state_get_from_path "${run_path}" run)" "false")" || return $?
  now="$(ftctl_now_iso8601)"
  case "${command}" in
    pause)
      ftctl_dr_scheduler_update_state "${run_path}" "${status_path}" \
        "scheduler_state=PAUSED" \
        "control_protocol_version=${FTCTL_DR_CONTROL_PROTOCOL_VERSION}" \
        "control_generation=${generation}" \
        "control_ack_generation=${generation}" \
        "control_state=PAUSED" \
        "cycle_state=IDLE" \
        "updated_at=${now}" || true
      ;;
    run)
      ftctl_dr_scheduler_update_state "${run_path}" "${status_path}" \
        "scheduler_state=RUNNING" \
        "control_protocol_version=${FTCTL_DR_CONTROL_PROTOCOL_VERSION}" \
        "control_generation=${generation}" \
        "control_ack_generation=${generation}" \
        "control_state=RUNNING" \
        "updated_at=${now}" || true
      ;;
    stop)
      ftctl_dr_scheduler_update_state "${run_path}" "${status_path}" \
        "scheduler_state=STOPPED" \
        "control_protocol_version=${FTCTL_DR_CONTROL_PROTOCOL_VERSION}" \
        "control_generation=${generation}" \
        "control_ack_generation=${generation}" \
        "control_state=STOPPED" \
        "cycle_state=IDLE" \
        "updated_at=${now}" || true
      ;;
  esac
}
