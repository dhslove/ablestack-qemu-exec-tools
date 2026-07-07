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
  local pid_path="${1-}" pid
  [[ -n "${pid_path}" && -f "${pid_path}" ]] || return 1
  pid="$(tr -d '[:space:]' < "${pid_path}" 2>/dev/null || true)"
  [[ "${pid}" =~ ^[0-9]+$ ]] || return 1
  kill -0 "${pid}" >/dev/null 2>&1
}

ftctl_dr_scheduler_profile_has_data_plane() {
  local profile_file="${1-}"
  local source_provider target_provider
  source_provider="$(ftctl_dr_scheduler_profile_provider "${profile_file}" source)"
  target_provider="$(ftctl_dr_scheduler_profile_provider "${profile_file}" target)"
  [[ "${source_provider}" == "ABLESTACK" || "${target_provider}" == "ABLESTACK" ||
      "${source_provider}" == "VMWARE" || "${target_provider}" == "VMWARE" ]]
}

ftctl_dr_scheduler_control_set() {
  local plan="${1-}" command="${2-}"
  local control_path
  control_path="$(ftctl_dr_scheduler_control_path "${plan}")"
  ftctl_ensure_dir "$(dirname "${control_path}")" "0755"
  ftctl_state_write_kv_all "${control_path}" \
    "command=${command}" \
    "updated_at=$(ftctl_now_iso8601)"
}

ftctl_dr_scheduler_control_command() {
  local plan="${1-}"
  local control_path
  control_path="$(ftctl_dr_scheduler_control_path "${plan}")"
  ftctl_state_read_kv "${control_path}" "command" 2>/dev/null || true
}

ftctl_dr_scheduler_update_state() {
  local state_path="${1-}" status_path="${2-}"
  shift 2
  ftctl_dr_runtime_path_set "${state_path}" "$@" || return $?
  cp -f "${state_path}" "${status_path}" 2>/dev/null || true
  chmod 0644 "${status_path}" 2>/dev/null || true
}

ftctl_dr_scheduler_checkpoint_value() {
  local checkpoint_path="${1-}" field="${2-}"
  [[ -n "${checkpoint_path}" && -f "${checkpoint_path}" ]] || return 1
  python3 - "${checkpoint_path}" "${field}" <<'PY' 2>/dev/null
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as fh:
    data = json.load(fh)
value = data.get(sys.argv[2])
if value is None:
    print("")
else:
    print(str(value))
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
  local sequence="${1-}"
  if [[ "${sequence}" == "1" ]]; then
    printf 'full-seed\n'
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

ftctl_dr_scheduler_worker() {
  local plan="${1-}" run="${2-}" profile_file="${3-}" state_path="${4-}" status_path="${5-}"
  local pid_path restore_points_path interval max_cycles sequence=0 command cycle_type source_provider target_provider driver
  local output rc manifest_path checkpoint_path source_at target_at rpo now error_code

  [[ -n "${plan}" && -n "${run}" && -f "${profile_file}" && -f "${state_path}" ]] || return 2
  ftctl_ensure_dir "$(ftctl_dr_scheduler_dir "${plan}")" "0755"
  pid_path="$(ftctl_dr_scheduler_pid_path "${plan}" "${run}")"
  restore_points_path="$(ftctl_dr_scheduler_restore_points_path "${plan}")"
  interval="$(ftctl_dr_scheduler_interval "${profile_file}")"
  max_cycles="$(ftctl_dr_scheduler_max_cycles "${profile_file}")"
  source_provider="$(ftctl_dr_scheduler_profile_provider "${profile_file}" source)"
  target_provider="$(ftctl_dr_scheduler_profile_provider "${profile_file}" target)"
  driver="$(ftctl_dr_scheduler_driver_name "${source_provider}" "${target_provider}")"

  printf '%s\n' "$$" > "${pid_path}"
  ftctl_dr_scheduler_control_set "${plan}" "run"
  now="$(ftctl_now_iso8601)"
  ftctl_dr_scheduler_update_state "${state_path}" "${status_path}" \
    "scheduler_state=RUNNING" \
    "worker_pid=$$" \
    "restore_points_path=${restore_points_path}" \
    "driver=${driver}" \
    "updated_at=${now}" || true
  ftctl_log_event "dr-runtime" "dr.scheduler.start" "ok" "" "" \
    "plan=${plan} run=${run} driver=${driver} interval=${interval} max_cycles=${max_cycles}"

  while true; do
    command="$(ftctl_dr_scheduler_control_command "${plan}")"
    if [[ "${command}" == "stop" ]]; then
      now="$(ftctl_now_iso8601)"
      ftctl_dr_scheduler_update_state "${state_path}" "${status_path}" \
        "state=CANCELED" \
        "step=scheduler-stopped" \
        "progress=100" \
        "scheduler_state=STOPPED" \
        "updated_at=${now}" || true
      break
    fi

    if [[ "${command}" == "pause" ]]; then
      now="$(ftctl_now_iso8601)"
      ftctl_dr_scheduler_update_state "${state_path}" "${status_path}" \
        "state=PAUSED" \
        "step=sync-paused" \
        "scheduler_state=PAUSED" \
        "updated_at=${now}" || true
      sleep 1
      continue
    fi

    sequence=$((sequence + 1))
    cycle_type="$(ftctl_dr_scheduler_cycle_type "${sequence}")"
    now="$(ftctl_now_iso8601)"
    ftctl_dr_scheduler_update_state "${state_path}" "${status_path}" \
      "state=SYNCING" \
      "step=${cycle_type}-transfer" \
      "progress=40" \
      "scheduler_state=RUNNING" \
      "checkpoint_sequence=${sequence}" \
      "updated_at=${now}" || true

    rc=0
    output="$(ftctl_dr_scheduler_run_cycle "${plan}" "${run}" "${profile_file}" "${sequence}" "${cycle_type}")" || rc=$?
    if [[ "${rc}" != "0" ]]; then
      case "${rc}" in
        65) error_code="DR_VMWARE_MOVER_UNAVAILABLE" ;;
        68) error_code="DR_VMWARE_MOVER_FAILED" ;;
        69) error_code="DR_VMWARE_NBDKIT_FAILED" ;;
        70) error_code="DR_VDDK_LIBDIR_UNRESOLVED" ;;
        71) error_code="DR_VDDK_LIBRARY_LOAD_FAILED" ;;
        66) error_code="DR_UNSUPPORTED_DIRECTION" ;;
        *) error_code="DR_REPLICATION_CYCLE_FAILED" ;;
      esac
      now="$(ftctl_now_iso8601)"
      ftctl_dr_scheduler_update_state "${state_path}" "${status_path}" \
        "state=ERROR" \
        "step=replication-cycle-failed" \
        "progress=100" \
        "accepted=false" \
        "scheduler_state=ERROR" \
        "error_code=${error_code}" \
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
    ftctl_dr_scheduler_append_restore_point "${restore_points_path}" "${plan}" "${run}" "${sequence}" "${cycle_type}" "${driver}" "${manifest_path}" "${checkpoint_path}" || return $?
    now="$(ftctl_now_iso8601)"
    ftctl_dr_scheduler_update_state "${state_path}" "${status_path}" \
      "state=SYNCING" \
      "step=target-checkpoint-ready" \
      "progress=100" \
      "accepted=true" \
      "scheduler_state=RUNNING" \
      "driver=${driver}" \
      "driver_state=CHECKPOINT_READY" \
      "checkpoint_sequence=${sequence}" \
      "manifest_path=${manifest_path}" \
      "checkpoint_path=${checkpoint_path}" \
      "restore_points_path=${restore_points_path}" \
      "last_source_checkpoint_at=${source_at}" \
      "last_target_durable_at=${target_at}" \
      "target_ready_rpo_seconds=${rpo}" \
      "error_code=" \
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

    ftctl_dr_scheduler_sleep_or_stop "${plan}" "${interval}" || true
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
  if ftctl_dr_scheduler_pid_alive "${pid_path}"; then
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
  local action="${1-}" plan="${2-}" run_path="${3-}" status_path="${4-}"
  local command now
  case "${action}" in
    dr-sync-pause) command="pause" ;;
    dr-sync-resume) command="run" ;;
    dr-release|dr-cancel) command="stop" ;;
    *) return 0 ;;
  esac
  ftctl_dr_scheduler_control_set "${plan}" "${command}"
  now="$(ftctl_now_iso8601)"
  case "${command}" in
    pause)
      ftctl_dr_scheduler_update_state "${run_path}" "${status_path}" \
        "scheduler_state=PAUSED" \
        "updated_at=${now}" || true
      ;;
    run)
      ftctl_dr_scheduler_update_state "${run_path}" "${status_path}" \
        "scheduler_state=RUNNING" \
        "updated_at=${now}" || true
      ;;
    stop)
      ftctl_dr_scheduler_update_state "${run_path}" "${status_path}" \
        "scheduler_state=STOPPING" \
        "updated_at=${now}" || true
      ;;
  esac
}
