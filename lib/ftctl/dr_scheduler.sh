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
FTCTL_DR_SCHEDULER_HEARTBEAT_TIMEOUT_SEC="${FTCTL_DR_SCHEDULER_HEARTBEAT_TIMEOUT_SEC:-30}"
FTCTL_DR_CONTROL_PROTOCOL_VERSION="4"

ftctl_dr_scheduler_dir() {
  local plan="${1-}"
  printf '%s/scheduler\n' "$(ftctl_dr_runtime_plan_dir "${plan}")"
}

ftctl_dr_scheduler_launch_state_path() {
  local plan="${1-}"
  printf '%s/launch.state\n' "$(ftctl_dr_scheduler_dir "${plan}")"
}

ftctl_dr_scheduler_unit_name() {
  local plan="${1-}"
  [[ "${plan}" =~ ^[A-Za-z0-9_.:-]+$ ]] || return 2
  printf 'ablestack-vm-ftctl-dr@%s.service\n' "${plan}"
}

ftctl_dr_scheduler_systemd_available() {
  local plan="${1-}" unit load_state
  [[ -d /run/systemd/system ]] || return 1
  command -v systemctl >/dev/null 2>&1 || return 1
  unit="$(ftctl_dr_scheduler_unit_name "${plan}" 2>/dev/null || true)"
  [[ -n "${unit}" ]] || return 1
  load_state="$(systemctl show "${unit}" -p LoadState --value 2>/dev/null || true)"
  [[ "${load_state}" == "loaded" ]]
}

ftctl_dr_scheduler_process_cgroup() {
  local pid="${1-}"
  [[ "${pid}" =~ ^[0-9]+$ && -r "/proc/${pid}/cgroup" ]] || return 1
  awk -F: '$1 == "0" {print $3; exit}' "/proc/${pid}/cgroup" 2>/dev/null
}

ftctl_dr_scheduler_write_launch_state() {
  local plan="${1-}" run="${2-}" profile_file="${3-}" state_path="${4-}" status_path="${5-}" trigger="${6-START}"
  local launch_path session authority_sequence
  launch_path="$(ftctl_dr_scheduler_launch_state_path "${plan}")"
  session="$(ftctl_dr_scheduler_session_uuid "${plan}" "${profile_file}")"
  authority_sequence="$(ftctl_dr_scheduler_current_authority_sequence "${plan}")"
  ftctl_ensure_dir "$(dirname "${launch_path}")" "0755"
  ftctl_state_write_kv_all "${launch_path}" \
    "version=1" \
    "plan_uuid=${plan}" \
    "run_uuid=${run}" \
    "scheduler_session_uuid=${session}" \
    "profile_path=${profile_file}" \
    "state_path=${state_path}" \
    "status_path=${status_path}" \
    "desired_state=RUNNING" \
    "active_side=SOURCE" \
    "authority_sequence=${authority_sequence}" \
    "recovery_trigger=${trigger}" \
    "updated_at=$(ftctl_now_iso8601)"
}

ftctl_dr_scheduler_update_unit_projection() {
  local plan="${1-}" state_path="${2-}" status_path="${3-}" recovery_state="${4-NONE}" trigger="${5-}"
  local unit active_state sub_state cgroup main_pid
  unit="$(ftctl_dr_scheduler_unit_name "${plan}" 2>/dev/null || true)"
  active_state="$(systemctl show "${unit}" -p ActiveState --value 2>/dev/null || true)"
  sub_state="$(systemctl show "${unit}" -p SubState --value 2>/dev/null || true)"
  cgroup="$(systemctl show "${unit}" -p ControlGroup --value 2>/dev/null || true)"
  main_pid="$(systemctl show "${unit}" -p MainPID --value 2>/dev/null || true)"
  ftctl_dr_scheduler_update_state "${state_path}" "${status_path}" \
    "scheduler_desired_state=RUNNING" \
    "scheduler_service_unit=${unit}" \
    "scheduler_unit_active_state=${active_state}" \
    "scheduler_unit_sub_state=${sub_state}" \
    "scheduler_cgroup=${cgroup}" \
    "scheduler_unit_main_pid=${main_pid}" \
    "scheduler_recovery_state=${recovery_state}" \
    "scheduler_recovery_trigger=${trigger}" \
    "scheduler_launch_mode=systemd" \
    "updated_at=$(ftctl_now_iso8601)" || true
}

ftctl_dr_scheduler_launch_via_systemd() {
  local plan="${1-}" run="${2-}" profile_file="${3-}" state_path="${4-}" status_path="${5-}" trigger="${6-START}"
  local unit
  ftctl_dr_scheduler_systemd_available "${plan}" || return 69
  ftctl_dr_scheduler_write_launch_state "${plan}" "${run}" "${profile_file}" "${state_path}" "${status_path}" "${trigger}" || return $?
  unit="$(ftctl_dr_scheduler_unit_name "${plan}")"
  systemctl reset-failed "${unit}" >/dev/null 2>&1 || true
  systemctl start --no-block "${unit}" >/dev/null 2>&1 || return 69
  ftctl_dr_scheduler_update_unit_projection "${plan}" "${state_path}" "${status_path}" "RECOVERING" "${trigger}"
}

ftctl_dr_scheduler_run_from_launch() {
  local plan="${1-}" json="${2-0}" launch_path run profile_file state_path status_path rc=0
  ftctl_dr_runtime_require_plan "${plan}" || return 2
  launch_path="$(ftctl_dr_scheduler_launch_state_path "${plan}")"
  [[ -f "${launch_path}" ]] || {
    [[ "${json}" == "1" ]] && printf '{"command":"dr-scheduler-run","result":"not_found","plan_uuid":"%s","exit_code":2}\n' "$(ftctl__json_escape "${plan}")"
    return 2
  }
  run="$(ftctl_state_read_kv "${launch_path}" "run_uuid" 2>/dev/null || true)"
  profile_file="$(ftctl_state_read_kv "${launch_path}" "profile_path" 2>/dev/null || true)"
  state_path="$(ftctl_state_read_kv "${launch_path}" "state_path" 2>/dev/null || true)"
  status_path="$(ftctl_state_read_kv "${launch_path}" "status_path" 2>/dev/null || true)"
  [[ -n "${run}" && -f "${profile_file}" && -f "${state_path}" && -n "${status_path}" ]] || return 30
  export FTCTL_DR_RUNTIME_WORKER=1
  export FTCTL_DR_SCHEDULER_FOREGROUND=1
  ftctl_dr_scheduler_worker "${plan}" "${run}" "${profile_file}" "${state_path}" "${status_path}" || rc=$?
  if [[ "$(ftctl_dr_runtime_state_get_from_path "${status_path}" "nbd_teardown_state")" == "QUARANTINED" ]]; then
    return 0
  fi
  return "${rc}"
}

ftctl_dr_scheduler_recover_nbd_quarantine() {
  local plan="${1-}" state_path="${2-}" status_path="${3-}" mover rc=0
  [[ "$(ftctl_dr_runtime_state_get_from_path "${status_path}" "nbd_teardown_state")" == "QUARANTINED" ]] || return 0
  mover="$(ftctl_dr_vmware_resolve_mover 2>/dev/null || true)"
  [[ -n "${mover}" ]] || return 65
  "${mover}" --recover-nbd "${plan}" || rc=$?
  [[ "${rc}" == "0" ]] || return "${rc}"
  ftctl_dr_scheduler_update_state "${state_path}" "${status_path}" \
    "nbd_teardown_state=DRAINED" \
    "nbd_quarantined_device_count=0" \
    "nbd_teardown_error_code=" \
    "nbd_teardown_error_message=" \
    "scheduler_recovery_state=RECOVERING" \
    "error_code=" \
    "error_message=" \
    "updated_at=$(ftctl_now_iso8601)" || true
}

ftctl_dr_scheduler_recover() {
  local plan="${1-}" run="${2-}" profile_file="${3-}" state_path="${4-}" status_path="${5-}" trigger="${6-MANUAL}"
  local state active_side control_state transition_state
  [[ -f "${profile_file}" && -f "${status_path}" ]] || return 2
  state="$(ftctl_dr_runtime_state_get_from_path "${status_path}" "state")"
  active_side="$(ftctl_dr_runtime_state_get_from_path "${status_path}" "active_side")"
  control_state="$(ftctl_dr_runtime_state_get_from_path "${status_path}" "control_state")"
  transition_state="$(ftctl_dr_runtime_state_get_from_path "${status_path}" "transition_state")"
  [[ "${active_side^^}" != "TARGET" && "${state}" != "FAILED_OVER" ]] || return 41
  [[ "${control_state}" != "PAUSED" && "${control_state}" != "STOPPED" ]] || return 42
  case "${transition_state}" in
    ""|IDLE|COMPLETED|SUCCEEDED) ;;
    *) return 43 ;;
  esac
  ftctl_dr_scheduler_recover_nbd_quarantine "${plan}" "${state_path}" "${status_path}" || return $?
  if ftctl_dr_scheduler_active_worker_valid "${plan}" ""; then
    return 0
  fi
  ftctl_dr_scheduler_update_state "${state_path}" "${status_path}" \
    "scheduler_state=RECOVERING" \
    "scheduler_health=RECOVERING" \
    "scheduler_recovery_state=RECOVERING" \
    "scheduler_recovery_trigger=${trigger}" \
    "replication_activity=RECOVERING" \
    "protection_state=DEGRADED" \
    "error_code=" \
    "error_message=" \
    "updated_at=$(ftctl_now_iso8601)" || true
  ftctl_dr_scheduler_launch_via_systemd "${plan}" "${run}" "${profile_file}" "${state_path}" "${status_path}" "${trigger}"
}

ftctl_dr_scheduler_reconcile_plan() {
  local plan="${1-}" profile_file status_path state active_side control_state transition_state run state_path
  profile_file="$(ftctl_dr_runtime_profile_path "${plan}")"
  status_path="$(ftctl_dr_runtime_status_path "${plan}")"
  [[ -f "${profile_file}" && -f "${status_path}" ]] || return 0
  if ftctl_dr_scheduler_active_worker_valid "${plan}" ""; then
    return 0
  fi
  state="$(ftctl_dr_runtime_state_get_from_path "${status_path}" "state")"
  active_side="$(ftctl_dr_runtime_state_get_from_path "${status_path}" "active_side")"
  control_state="$(ftctl_dr_runtime_state_get_from_path "${status_path}" "control_state")"
  transition_state="$(ftctl_dr_runtime_state_get_from_path "${status_path}" "transition_state")"
  [[ "${state}" == "READY" || "${state}" == "SYNCING" ||
    "$(ftctl_dr_runtime_state_get_from_path "${status_path}" "nbd_teardown_state")" == "QUARANTINED" ]] || return 0
  [[ "${active_side^^}" != "TARGET" ]] || return 0
  [[ "${control_state}" == "RUNNING" ]] || return 0
  case "${transition_state}" in
    ""|IDLE|COMPLETED|SUCCEEDED) ;;
    *) return 0 ;;
  esac
  run="$(ftctl_dr_runtime_state_get_from_path "${status_path}" "latest_completed_producer_run_uuid")"
  [[ -n "${run}" ]] || run="$(ftctl_dr_runtime_state_get_from_path "${status_path}" "run")"
  [[ -n "${run}" ]] || return 0
  state_path="$(ftctl_dr_runtime_run_path "${plan}" "${run}")"
  [[ -f "${state_path}" ]] || state_path="${status_path}"
  ftctl_dr_scheduler_recover "${plan}" "${run}" "${profile_file}" "${state_path}" "${status_path}" "LOCAL_RECONCILE"
}

ftctl_dr_scheduler_reconcile_all() {
  local json="${1-0}" root profile plan recovered=0 failed=0 rc
  root="$(ftctl_dr_runtime_root)/plans"
  [[ -d "${root}" ]] || {
    [[ "${json}" == "1" ]] && printf '{"command":"dr-reconcile","result":"ok","recovered":0,"failed":0}\n'
    return 0
  }
  for profile in "${root}"/*/profile.json; do
    [[ -f "${profile}" ]] || continue
    plan="$(basename "$(dirname "${profile}")")"
    rc=0
    ftctl_dr_scheduler_reconcile_plan "${plan}" || rc=$?
    if [[ "${rc}" == "0" ]]; then
      if [[ "$(ftctl_dr_runtime_state_get_from_path "$(ftctl_dr_runtime_status_path "${plan}")" "scheduler_recovery_trigger")" == "LOCAL_RECONCILE" ]]; then
        recovered=$((recovered + 1))
      fi
    else
      failed=$((failed + 1))
    fi
  done
  [[ "${json}" == "1" ]] && printf '{"command":"dr-reconcile","result":"ok","recovered":%s,"failed":%s}\n' "${recovered}" "${failed}"
  [[ "${failed}" == "0" ]]
}

ftctl_dr_scheduler_pid_path() {
  local plan="${1-}" run="${2-}"
  printf '%s/%s.pid\n' "$(ftctl_dr_scheduler_dir "${plan}")" "$(ftctl_dr_runtime_key "${run}")"
}

ftctl_dr_scheduler_owner_lock_path() {
  local plan="${1-}"
  printf '%s/owner.lock\n' "$(ftctl_dr_scheduler_dir "${plan}")"
}

ftctl_dr_scheduler_lease_path() {
  local plan="${1-}"
  printf '%s/lease.state\n' "$(ftctl_dr_scheduler_dir "${plan}")"
}

ftctl_dr_scheduler_active_pid_path() {
  local plan="${1-}"
  printf '%s/active.pid\n' "$(ftctl_dr_scheduler_dir "${plan}")"
}

ftctl_dr_scheduler_sequence_path() {
  local plan="${1-}"
  printf '%s/sequence.state\n' "$(ftctl_dr_scheduler_dir "${plan}")"
}

ftctl_dr_scheduler_session_uuid() {
  local plan="${1-}" profile_file="${2-}" session=""
  if [[ -n "${profile_file}" && -f "${profile_file}" ]]; then
    session="$(ftctl_dr_runtime_profile_value "${profile_file}" "schedulerSessionUuid" 2>/dev/null || true)"
  fi
  [[ -n "${session}" ]] || session="${plan}"
  printf '%s\n' "${session}"
}

ftctl_dr_scheduler_process_start_ticks() {
  local pid="${1-}"
  [[ "${pid}" =~ ^[0-9]+$ && -r "/proc/${pid}/stat" ]] || return 1
  awk '{print $22}' "/proc/${pid}/stat" 2>/dev/null
}

ftctl_dr_scheduler_active_value() {
  local plan="${1-}" key="${2-}"
  ftctl_state_read_kv "$(ftctl_dr_scheduler_active_pid_path "${plan}")" "${key}" 2>/dev/null || true
}

ftctl_dr_scheduler_lease_value() {
  local plan="${1-}" key="${2-}"
  ftctl_state_read_kv "$(ftctl_dr_scheduler_lease_path "${plan}")" "${key}" 2>/dev/null || true
}

ftctl_dr_scheduler_active_worker_valid() {
  local plan="${1-}" expected_session="${2-}"
  local pid start_ticks recorded_start session cmdline
  pid="$(ftctl_dr_scheduler_active_value "${plan}" "pid")"
  recorded_start="$(ftctl_dr_scheduler_active_value "${plan}" "start_ticks")"
  session="$(ftctl_dr_scheduler_active_value "${plan}" "scheduler_session_uuid")"
  [[ "${pid}" =~ ^[0-9]+$ ]] || return 1
  kill -0 "${pid}" >/dev/null 2>&1 || return 1
  start_ticks="$(ftctl_dr_scheduler_process_start_ticks "${pid}" 2>/dev/null || true)"
  [[ -n "${recorded_start}" && "${start_ticks}" == "${recorded_start}" ]] || return 1
  [[ -z "${expected_session}" || "${session}" == "${expected_session}" ]] || return 1
  cmdline="$(tr '\0' ' ' < "/proc/${pid}/cmdline" 2>/dev/null || true)"
  [[ "${cmdline}" == *"--plan ${plan}"* ]] || return 1
  return 0
}

ftctl_dr_scheduler_repair_self_ownership() {
  local plan="${1-}" session="${2-}" epoch="${3-}" run="${4-}" pid="${5-}" start_ticks="${6-}"
  local actual_start lease_epoch active_pid active_start active_session active_epoch
  [[ "${pid}" == "$$" && "${pid}" =~ ^[0-9]+$ ]] || return 1
  actual_start="$(ftctl_dr_scheduler_process_start_ticks "${pid}" 2>/dev/null || true)"
  [[ "${start_ticks}" =~ ^[0-9]+$ && "${actual_start}" == "${start_ticks}" ]] || return 1

  # The caller owns the Plan scheduler flock while this repair runs. A newer
  # lease is the only durable evidence that this worker has lost authority.
  lease_epoch="$(ftctl_dr_scheduler_current_lease_epoch "${plan}")"
  [[ "${lease_epoch}" =~ ^[0-9]+$ && "${epoch}" =~ ^[0-9]+$ ]] || return 1
  (( lease_epoch <= epoch )) || return 1

  active_pid="$(ftctl_dr_scheduler_active_value "${plan}" "pid")"
  active_start="$(ftctl_dr_scheduler_active_value "${plan}" "start_ticks")"
  active_session="$(ftctl_dr_scheduler_active_value "${plan}" "scheduler_session_uuid")"
  active_epoch="$(ftctl_dr_scheduler_active_value "${plan}" "lease_epoch")"
  if [[ "${active_pid}" =~ ^[0-9]+$ && "${active_pid}" != "${pid}" ]] \
      && kill -0 "${active_pid}" >/dev/null 2>&1 \
      && [[ "$(ftctl_dr_scheduler_process_start_ticks "${active_pid}" 2>/dev/null || true)" == "${active_start}" ]] \
      && [[ "${active_session}" != "${session}" || "${active_epoch}" -gt "${epoch}" ]]; then
    return 1
  fi

  ftctl_dr_scheduler_write_heartbeat "${plan}" "${session}" "${epoch}" "${run}" "${pid}" "${start_ticks}" || return 1
  ftctl_dr_scheduler_active_worker_valid "${plan}" "${session}"
}

ftctl_dr_scheduler_current_lease_epoch() {
  local plan="${1-}" epoch
  epoch="$(ftctl_dr_scheduler_lease_value "${plan}" "lease_epoch")"
  [[ "${epoch}" =~ ^[0-9]+$ ]] || epoch=0
  printf '%s\n' "${epoch}"
}

ftctl_dr_scheduler_current_authority_sequence() {
  local plan="${1-}" sequence
  sequence="$(ftctl_state_read_kv "$(ftctl_dr_scheduler_sequence_path "${plan}")" "authority_sequence" 2>/dev/null || true)"
  [[ "${sequence}" =~ ^[0-9]+$ ]] || sequence=0
  printf '%s\n' "${sequence}"
}

ftctl_dr_scheduler_next_authority_sequence() {
  local plan="${1-}" sequence_path cycle_sequence authority_sequence
  sequence_path="$(ftctl_dr_scheduler_sequence_path "${plan}")"
  ftctl_ensure_dir "$(dirname "${sequence_path}")" "0755"
  cycle_sequence="$(ftctl_state_read_kv "${sequence_path}" "plan_cycle_sequence" 2>/dev/null || true)"
  authority_sequence="$(ftctl_dr_scheduler_current_authority_sequence "${plan}")"
  [[ "${cycle_sequence}" =~ ^[0-9]+$ ]] || cycle_sequence=0
  authority_sequence=$((authority_sequence + 1))
  ftctl_state_write_kv_all "${sequence_path}" \
    "plan_cycle_sequence=${cycle_sequence}" \
    "authority_sequence=${authority_sequence}"
  printf '%s\n' "${authority_sequence}"
}

ftctl_dr_scheduler_record_plan_sequence() {
  local plan="${1-}" cycle_sequence="${2-}" sequence_path authority_sequence
  sequence_path="$(ftctl_dr_scheduler_sequence_path "${plan}")"
  ftctl_ensure_dir "$(dirname "${sequence_path}")" "0755"
  authority_sequence="$(ftctl_dr_scheduler_current_authority_sequence "${plan}")"
  authority_sequence=$((authority_sequence + 1))
  ftctl_state_write_kv_all "${sequence_path}" \
    "plan_cycle_sequence=${cycle_sequence}" \
    "authority_sequence=${authority_sequence}"
  printf '%s\n' "${authority_sequence}"
}

ftctl_dr_scheduler_write_heartbeat() {
  local plan="${1-}" session="${2-}" epoch="${3-}" run="${4-}" pid="${5-}" start_ticks="${6-}" now
  now="$(ftctl_now_iso8601)"
  ftctl_state_write_kv_all "$(ftctl_dr_scheduler_active_pid_path "${plan}")" \
    "pid=${pid}" \
    "start_ticks=${start_ticks}" \
    "scheduler_session_uuid=${session}" \
    "lease_epoch=${epoch}" \
    "worker_run_uuid=${run}" \
    "heartbeat_at=${now}"
  ftctl_state_write_kv_all "$(ftctl_dr_scheduler_lease_path "${plan}")" \
    "version=1" \
    "plan_uuid=${plan}" \
    "scheduler_session_uuid=${session}" \
    "lease_epoch=${epoch}" \
    "worker_pid=${pid}" \
    "worker_start_ticks=${start_ticks}" \
    "worker_run_uuid=${run}" \
    "heartbeat_at=${now}" \
    "state=ACTIVE"
}

ftctl_dr_scheduler_mark_lease_stopped() {
  local plan="${1-}" session="${2-}" epoch="${3-}" run="${4-}" pid="${5-}" start_ticks="${6-}"
  ftctl_state_write_kv_all "$(ftctl_dr_scheduler_lease_path "${plan}")" \
    "version=1" \
    "plan_uuid=${plan}" \
    "scheduler_session_uuid=${session}" \
    "lease_epoch=${epoch}" \
    "worker_pid=${pid}" \
    "worker_start_ticks=${start_ticks}" \
    "worker_run_uuid=${run}" \
    "heartbeat_at=$(ftctl_now_iso8601)" \
    "state=STOPPED" || true
  rm -f "$(ftctl_dr_scheduler_active_pid_path "${plan}")" 2>/dev/null || true
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
  local plan="${1-}" generation="${2-}" state="${3-}" cycle_state="${4-IDLE}" worker_run="${5-}"
  local session="${6-}" lease_epoch="${7-}" worker_pid="${8-}" worker_start_ticks="${9-}"
  local ack_path request_run
  ack_path="$(ftctl_dr_scheduler_control_ack_path "${plan}")"
  ftctl_ensure_dir "$(dirname "${ack_path}")" "0755"
  request_run="$(ftctl_dr_scheduler_control_value "${plan}" "owner_run")"
  [[ -n "${session}" ]] || session="$(ftctl_dr_scheduler_active_value "${plan}" "scheduler_session_uuid")"
  [[ -n "${lease_epoch}" ]] || lease_epoch="$(ftctl_dr_scheduler_active_value "${plan}" "lease_epoch")"
  [[ -n "${worker_pid}" ]] || worker_pid="$(ftctl_dr_scheduler_active_value "${plan}" "pid")"
  [[ -n "${worker_start_ticks}" ]] || worker_start_ticks="$(ftctl_dr_scheduler_active_value "${plan}" "start_ticks")"
  ftctl_state_write_kv_all "${ack_path}" \
    "version=${FTCTL_DR_CONTROL_PROTOCOL_VERSION}" \
    "generation=${generation}" \
    "state=${state}" \
    "cycle_state=${cycle_state}" \
    "owner_run=${request_run}" \
    "request_run_uuid=${request_run}" \
    "active_worker_run_uuid=${worker_run}" \
    "scheduler_session_uuid=${session}" \
    "lease_epoch=${lease_epoch}" \
    "worker_pid=${worker_pid}" \
    "worker_start_ticks=${worker_start_ticks}" \
    "owner_matched=true" \
    "acknowledged_at=$(ftctl_now_iso8601)"
}

ftctl_dr_scheduler_wait_for_ack() {
  local plan="${1-}" generation="${2-}" expected_state="${3-}" timeout_sec="${4-${FTCTL_DR_CONTROL_ACK_TIMEOUT_SEC}}"
  local expected_request_run="${5-}" expected_session="${6-}" expected_epoch="${7-}"
  local expected_pid="${8-}" expected_start_ticks="${9-}"
  local ack_path deadline ack_generation ack_state ack_request_run ack_session ack_epoch ack_pid ack_start_ticks
  ack_path="$(ftctl_dr_scheduler_control_ack_path "${plan}")"
  [[ "${timeout_sec}" =~ ^[0-9]+$ ]] || timeout_sec="${FTCTL_DR_CONTROL_ACK_TIMEOUT_SEC}"
  deadline=$(( $(date +%s) + timeout_sec ))
  while (( $(date +%s) <= deadline )); do
    ack_generation="$(ftctl_state_read_kv "${ack_path}" "generation" 2>/dev/null || true)"
    ack_state="$(ftctl_state_read_kv "${ack_path}" "state" 2>/dev/null || true)"
    ack_request_run="$(ftctl_state_read_kv "${ack_path}" "request_run_uuid" 2>/dev/null || true)"
    ack_session="$(ftctl_state_read_kv "${ack_path}" "scheduler_session_uuid" 2>/dev/null || true)"
    ack_epoch="$(ftctl_state_read_kv "${ack_path}" "lease_epoch" 2>/dev/null || true)"
    ack_pid="$(ftctl_state_read_kv "${ack_path}" "worker_pid" 2>/dev/null || true)"
    ack_start_ticks="$(ftctl_state_read_kv "${ack_path}" "worker_start_ticks" 2>/dev/null || true)"
    if [[ "${ack_generation}" == "${generation}" && "${ack_state}" == "${expected_state}" \
          && ( -z "${expected_request_run}" || "${ack_request_run}" == "${expected_request_run}" ) \
          && ( -z "${expected_session}" || "${ack_session}" == "${expected_session}" ) \
          && ( -z "${expected_epoch}" || "${ack_epoch}" == "${expected_epoch}" ) \
          && ( -z "${expected_pid}" || "${ack_pid}" == "${expected_pid}" ) \
          && ( -z "${expected_start_ticks}" || "${ack_start_ticks}" == "${expected_start_ticks}" ) ]]; then
      # STOPPED is a terminal acknowledgement. The worker exits immediately
      # after writing it, so requiring a live active.pid here creates a race
      # where a valid fence is reported as a timeout.
      if [[ "${expected_state}" == "STOPPED" ]]; then
        return 0
      fi
      if [[ "${ack_epoch}" == "$(ftctl_dr_scheduler_active_value "${plan}" "lease_epoch")" \
            && "${ack_pid}" == "$(ftctl_dr_scheduler_active_value "${plan}" "pid")" \
            && "${ack_start_ticks}" == "$(ftctl_dr_scheduler_active_value "${plan}" "start_ticks")" ]] \
            && ftctl_dr_scheduler_active_worker_valid "${plan}" "${expected_session}"; then
        return 0
      fi
    fi
    sleep 1
  done
  return 21
}

ftctl_dr_scheduler_has_live_worker() {
  local plan="${1-}" pid_path
  if ftctl_dr_scheduler_active_worker_valid "${plan}" ""; then
    return 0
  fi
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
  local generation session lease_epoch worker_pid worker_start_ticks
  session="$(ftctl_dr_scheduler_active_value "${plan}" "scheduler_session_uuid")"
  lease_epoch="$(ftctl_dr_scheduler_active_value "${plan}" "lease_epoch")"
  worker_pid="$(ftctl_dr_scheduler_active_value "${plan}" "pid")"
  worker_start_ticks="$(ftctl_dr_scheduler_active_value "${plan}" "start_ticks")"
  generation="$(ftctl_dr_scheduler_control_set "${plan}" "${command}" "${reason}" "${owner_run}" "${resume_after_cleanup}")" || return $?
  if ! ftctl_dr_scheduler_has_live_worker "${plan}" && [[ "${command}" != "run" ]]; then
    ftctl_dr_scheduler_control_ack "${plan}" "${generation}" "${expected_state}" "IDLE" "${owner_run}"
    printf '%s\n' "${generation}"
    return 0
  fi
  ftctl_dr_scheduler_wait_for_ack "${plan}" "${generation}" "${expected_state}" \
    "${FTCTL_DR_CONTROL_ACK_TIMEOUT_SEC}" "${owner_run}" "${session}" \
    "${lease_epoch}" "${worker_pid}" "${worker_start_ticks}" || return $?
  printf '%s\n' "${generation}"
}

ftctl_dr_scheduler_ensure_running() {
  local plan="${1-}" run="${2-}" profile_file="${3-}" state_path="${4-}" status_path="${5-}"
  local pid_path generation now session

  [[ -n "${plan}" && -n "${run}" && -f "${profile_file}" && -f "${state_path}" ]] || return 2
  session="$(ftctl_dr_scheduler_session_uuid "${plan}" "${profile_file}")"
  if ftctl_dr_scheduler_active_worker_valid "${plan}" "${session}"; then
    return 0
  fi
  pid_path="$(ftctl_dr_scheduler_pid_path "${plan}" "${run}")"
  if ftctl_dr_scheduler_pid_alive "${pid_path}" "${plan}" "${run}"; then
    return 0
  fi
  if ftctl_dr_scheduler_has_live_worker "${plan}"; then
    ftctl_dr_scheduler_update_state "${state_path}" "${status_path}" \
      "scheduler_state=ERROR" \
      "scheduler_health=DUPLICATE_WORKER" \
      "owner_matched=false" \
      "error_code=DR_SCHEDULER_DUPLICATE_WORKER" \
      "error_message=Another run owns a live scheduler for this Plan" \
      "updated_at=$(ftctl_now_iso8601)" || true
    return 23
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
    if ftctl_dr_scheduler_active_worker_valid "${plan}" "${session}"; then
      local active_pid lease_epoch authority_sequence start_ticks
      active_pid="$(ftctl_dr_scheduler_active_value "${plan}" "pid")"
      start_ticks="$(ftctl_dr_scheduler_active_value "${plan}" "start_ticks")"
      lease_epoch="$(ftctl_dr_scheduler_active_value "${plan}" "lease_epoch")"
      authority_sequence="$(ftctl_dr_scheduler_current_authority_sequence "${plan}")"
      ftctl_dr_scheduler_update_state "${state_path}" "${status_path}" \
        "scheduler_state=RUNNING" \
        "scheduler_health=HEALTHY" \
        "scheduler_pid_alive=true" \
        "scheduler_session_uuid=${session}" \
        "scheduler_lease_epoch=${lease_epoch}" \
        "authority_sequence=${authority_sequence}" \
        "active_worker_run_uuid=${run}" \
        "active_worker_pid=${active_pid}" \
        "active_worker_start_ticks=${start_ticks}" \
        "owner_matched=true" \
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

ftctl_dr_scheduler_checkpoint_lease_release_owned() {
  local plan="${1-}" sequence="${2-}" run="${3-}" lease_path owner
  [[ -n "${plan}" && -n "${sequence}" && -n "${run}" ]] || return 2
  lease_path="$(ftctl_dr_scheduler_checkpoint_lease_path "${plan}" "${sequence}")"
  [[ -f "${lease_path}" ]] || return 0
  owner="$(ftctl_state_read_kv "${lease_path}" "run" 2>/dev/null || true)"
  [[ "${owner}" == "${run}" ]] || return 3
  rm -f "${lease_path}"
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
  local generation now profile_file scheduler_run scheduler_run_path producer_run session
  local wait_rc=0 ack_generation control_generation control_command control_state="RUNNING"
  profile_file="$(ftctl_dr_runtime_profile_path "${plan}")"
  scheduler_run="${run}"
  scheduler_run_path="${run_path}"
  if ! ftctl_dr_scheduler_has_live_worker "${plan}"; then
    producer_run="$(ftctl_dr_scheduler_latest_producer_run "$(ftctl_dr_scheduler_restore_points_path "${plan}")" "${plan}")"
    if [[ -n "${producer_run}" && -f "$(ftctl_dr_runtime_run_path "${plan}" "${producer_run}")" ]]; then
      scheduler_run="${producer_run}"
      scheduler_run_path="$(ftctl_dr_runtime_run_path "${plan}" "${producer_run}")"
    fi
  fi
  session="$(ftctl_dr_scheduler_session_uuid "${plan}" "${profile_file}")"
  generation="$(ftctl_dr_scheduler_control_set "${plan}" "run" "${reason}" "${run}" "false")" || return $?
  ftctl_dr_scheduler_ensure_running "${plan}" "${scheduler_run}" "${profile_file}" "${scheduler_run_path}" "${status_path}" || return $?
  ftctl_dr_scheduler_wait_for_ack "${plan}" "${generation}" "RUNNING" \
    "${FTCTL_DR_CONTROL_ACK_TIMEOUT_SEC}" "${run}" "${session}" || wait_rc=$?
  if [[ "${wait_rc}" != "0" ]]; then
    control_generation="$(ftctl_dr_scheduler_control_generation "${plan}")"
    control_command="$(ftctl_dr_scheduler_control_command "${plan}")"
    if [[ "${wait_rc}" != "21" || "${control_generation}" != "${generation}" ||
          "${control_command}" != "run" ]] ||
        ! ftctl_dr_scheduler_active_worker_valid "${plan}" "${session}"; then
      return "${wait_rc}"
    fi
    # A running worker can finish an in-flight RPO cycle before acknowledging
    # the new generation. The live lease and unchanged RUN request prove that
    # source protection is active while the protocol ACK converges.
    control_state="RUNNING_PENDING_ACK"
  fi
  ack_generation="$(ftctl_state_read_kv "$(ftctl_dr_scheduler_control_ack_path "${plan}")" \
    "generation" 2>/dev/null || true)"
  [[ "${ack_generation}" =~ ^[0-9]+$ ]] || ack_generation=0
  now="$(ftctl_now_iso8601)"
  ftctl_dr_scheduler_update_state "${run_path}" "${status_path}" \
    "control_protocol_version=${FTCTL_DR_CONTROL_PROTOCOL_VERSION}" \
    "control_generation=${generation}" \
    "control_ack_generation=${ack_generation}" \
    "control_state=${control_state}" \
    "cycle_state=IDLE" \
    "transition_state=COMPLETED" \
    "updated_at=${now}" || true
}

ftctl_dr_scheduler_update_state() {
  local state_path="${1-}" status_path="${2-}"
  shift 2
  ftctl_dr_runtime_path_set "${state_path}" "$@" || return $?
  ftctl_dr_runtime_atomic_copy "${state_path}" "${status_path}" "0644" || return $?
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
    "producerRunUuid": run,
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
        "nbdTeardownState", "nbdTeardownStartedAtEpochMs", "nbdTeardownCompletedAtEpochMs",
        "nbdTeardownDurationMs", "nbdSourceDeviceCount", "nbdTargetDeviceCount",
        "nbdQuarantinedDeviceCount", "nbdTeardownErrorCode", "nbdTeardownErrorMessage",
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
  local plan="${1-}" interval="${2-}" expected_generation="${3-}"
  local slept=0 command generation session epoch run pid start_ticks
  [[ "${interval}" =~ ^[0-9]+$ ]] || interval="0"
  while (( slept < interval )); do
    command="$(ftctl_dr_scheduler_control_command "${plan}")"
    generation="$(ftctl_dr_scheduler_control_generation "${plan}")"
    [[ "${command}" != "stop" && "${command}" != "pause" ]] || return 1
    if [[ "${expected_generation}" =~ ^[0-9]+$ && "${generation}" != "${expected_generation}" ]]; then
      return 1
    fi
    if ftctl_dr_scheduler_active_worker_valid "${plan}" ""; then
      session="$(ftctl_dr_scheduler_active_value "${plan}" "scheduler_session_uuid")"
      epoch="$(ftctl_dr_scheduler_active_value "${plan}" "lease_epoch")"
      run="$(ftctl_dr_scheduler_active_value "${plan}" "worker_run_uuid")"
      pid="$(ftctl_dr_scheduler_active_value "${plan}" "pid")"
      start_ticks="$(ftctl_dr_scheduler_active_value "${plan}" "start_ticks")"
      ftctl_dr_scheduler_write_heartbeat "${plan}" "${session}" "${epoch}" "${run}" "${pid}" "${start_ticks}" || true
    fi
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
  python3 - "${restore_points_path}" "${plan}" <<'PY'
import json
import sys

path, plan = sys.argv[1:3]
latest = 0
with open(path, "r", encoding="utf-8") as fh:
    for line in fh:
        try:
            record = json.loads(line)
        except (TypeError, ValueError):
            continue
        if record.get("planUuid") != plan:
            continue
        try:
            latest = max(latest, int(record.get("checkpointSequence") or 0))
        except (TypeError, ValueError):
            pass
print(latest)
PY
}

ftctl_dr_scheduler_latest_producer_run() {
  local restore_points_path="${1-}" plan="${2-}"
  [[ -f "${restore_points_path}" ]] || return 0
  python3 - "${restore_points_path}" "${plan}" <<'PY'
import json
import sys

path, plan = sys.argv[1:3]
latest = None
with open(path, "r", encoding="utf-8") as fh:
    for line in fh:
        try:
            record = json.loads(line)
        except (TypeError, ValueError):
            continue
        if record.get("planUuid") == plan and record.get("runUuid"):
            latest = record
if latest:
    print(latest["runUuid"])
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
  local nbd_teardown_state nbd_teardown_started_at_ms nbd_teardown_completed_at_ms nbd_teardown_duration_ms
  local nbd_source_device_count nbd_target_device_count nbd_quarantined_device_count nbd_teardown_error_code nbd_teardown_error_message
  local cycle_started_epoch next_cycle_epoch next_cycle_at wait_seconds control_generation
  local session lease_epoch authority_sequence start_ticks owner_lock_path

  [[ -n "${plan}" && -n "${run}" && -f "${profile_file}" && -f "${state_path}" ]] || return 2
  ftctl_ensure_dir "$(ftctl_dr_scheduler_dir "${plan}")" "0755"
  session="$(ftctl_dr_scheduler_session_uuid "${plan}" "${profile_file}")"
  owner_lock_path="$(ftctl_dr_scheduler_owner_lock_path "${plan}")"
  exec 205>"${owner_lock_path}"
  if ! flock -n 205; then
    ftctl_dr_scheduler_update_state "${state_path}" "${status_path}" \
      "scheduler_state=ERROR" \
      "scheduler_health=DUPLICATE_WORKER" \
      "owner_matched=false" \
      "error_code=DR_SCHEDULER_DUPLICATE_WORKER" \
      "error_message=Plan scheduler owner lock is already held" \
      "updated_at=$(ftctl_now_iso8601)" || true
    exec 205>&-
    return 23
  fi
  lease_epoch=$(( $(ftctl_dr_scheduler_current_lease_epoch "${plan}") + 1 ))
  start_ticks="$(ftctl_dr_scheduler_process_start_ticks "$$" 2>/dev/null || true)"
  [[ "${start_ticks}" =~ ^[0-9]+$ ]] || start_ticks=0
  ftctl_dr_scheduler_write_heartbeat "${plan}" "${session}" "${lease_epoch}" "${run}" "$$" "${start_ticks}"
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
  control_generation="$(ftctl_dr_scheduler_control_generation "${plan}")"
  if [[ "$(ftctl_dr_scheduler_control_command "${plan}")" != "run" || ! "${control_generation}" =~ ^[1-9][0-9]*$ ]]; then
    control_generation="$(ftctl_dr_scheduler_control_set "${plan}" "run" "scheduler-start" "${run}")"
  fi
  ftctl_dr_scheduler_control_ack "${plan}" "${control_generation}" "RUNNING" "IDLE" "${run}" \
    "${session}" "${lease_epoch}" "$$" "${start_ticks}"
  authority_sequence="$(ftctl_dr_scheduler_next_authority_sequence "${plan}")"
  now="$(ftctl_now_iso8601)"
  ftctl_dr_scheduler_update_state "${state_path}" "${status_path}" \
    "scheduler_state=RUNNING" \
    "scheduler_health=HEALTHY" \
    "replication_activity=IDLE" \
    "protection_state=$([[ "${sequence}" -gt 0 ]] && printf READY || printf SYNCING)" \
    "control_protocol_version=${FTCTL_DR_CONTROL_PROTOCOL_VERSION}" \
    "control_generation=${control_generation}" \
    "control_ack_generation=${control_generation}" \
    "control_state=RUNNING" \
    "cycle_state=IDLE" \
    "worker_pid=$$" \
    "scheduler_session_uuid=${session}" \
    "scheduler_lease_epoch=${lease_epoch}" \
    "authority_sequence=${authority_sequence}" \
    "active_worker_run_uuid=${run}" \
    "active_worker_pid=$$" \
    "active_worker_start_ticks=${start_ticks}" \
    "worker_heartbeat_at=${now}" \
    "owner_matched=true" \
    "restore_points_path=${restore_points_path}" \
    "driver=${driver}" \
    "updated_at=${now}" || true
  ftctl_log_event "dr-runtime" "dr.scheduler.start" "ok" "" "" \
    "plan=${plan} run=${run} driver=${driver} interval=${interval} max_cycles=${max_cycles}"

  while true; do
    if ! ftctl_dr_scheduler_active_worker_valid "${plan}" "${session}" \
        && ! ftctl_dr_scheduler_repair_self_ownership "${plan}" "${session}" "${lease_epoch}" "${run}" "$$" "${start_ticks}"; then
      ftctl_dr_scheduler_update_state "${state_path}" "${status_path}" \
        "state=ERROR" \
        "scheduler_state=ERROR" \
        "scheduler_health=OWNER_MISMATCH" \
        "replication_activity=STOPPED" \
        "owner_matched=false" \
        "error_code=DR_SCHEDULER_OWNER_MISMATCH" \
        "error_message=Scheduler lease no longer belongs to this worker" \
        "updated_at=$(ftctl_now_iso8601)" || true
      break
    fi
    ftctl_dr_scheduler_write_heartbeat "${plan}" "${session}" "${lease_epoch}" "${run}" "$$" "${start_ticks}" || true
    command="$(ftctl_dr_scheduler_control_command "${plan}")"
    control_generation="$(ftctl_dr_scheduler_control_value "${plan}" "generation")"
    if [[ "${command}" == "stop" ]]; then
      now="$(ftctl_now_iso8601)"
      ftctl_dr_scheduler_control_ack "${plan}" "${control_generation}" "STOPPED" "IDLE" "${run}" \
        "${session}" "${lease_epoch}" "$$" "${start_ticks}"
      ftctl_dr_scheduler_update_state "${state_path}" "${status_path}" \
        "state=CANCELED" \
        "step=scheduler-stopped" \
        "progress=100" \
        "scheduler_state=STOPPED" \
        "scheduler_health=STOPPED" \
        "replication_activity=STOPPED" \
        "control_generation=${control_generation}" \
        "control_ack_generation=${control_generation}" \
        "control_state=STOPPED" \
        "cycle_state=IDLE" \
        "updated_at=${now}" || true
      break
    fi

    if [[ "${command}" == "pause" ]]; then
      now="$(ftctl_now_iso8601)"
      ftctl_dr_scheduler_control_ack "${plan}" "${control_generation}" "PAUSED" "IDLE" "${run}" \
        "${session}" "${lease_epoch}" "$$" "${start_ticks}"
      ftctl_dr_scheduler_update_state "${state_path}" "${status_path}" \
        "state=PAUSED" \
        "step=sync-paused" \
        "scheduler_state=PAUSED" \
        "scheduler_health=HEALTHY" \
        "replication_activity=PAUSED" \
        "protection_state=PAUSED" \
        "control_generation=${control_generation}" \
        "control_ack_generation=${control_generation}" \
        "control_state=PAUSED" \
        "cycle_state=IDLE" \
        "updated_at=${now}" || true
      sleep 1
      continue
    fi

    ftctl_dr_scheduler_control_ack "${plan}" "${control_generation}" "RUNNING" "IDLE" "${run}" \
      "${session}" "${lease_epoch}" "$$" "${start_ticks}"
    ftctl_dr_scheduler_update_state "${state_path}" "${status_path}" \
      "scheduler_state=RUNNING" \
      "scheduler_health=HEALTHY" \
      "replication_activity=IDLE" \
      "protection_state=$([[ "${sequence}" -gt 0 ]] && printf READY || printf SYNCING)" \
      "control_generation=${control_generation}" \
      "control_ack_generation=${control_generation}" \
      "control_state=RUNNING" \
      "cycle_state=IDLE" \
      "updated_at=$(ftctl_now_iso8601)" || true

    sequence=$((sequence + 1))
    authority_sequence="$(ftctl_dr_scheduler_record_plan_sequence "${plan}" "${sequence}")"
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
      "state=$([[ "${sequence}" -gt 1 ]] && printf READY || printf SYNCING)" \
      "step=${cycle_type}-transfer" \
      "progress=40" \
      "scheduler_state=RUNNING" \
      "control_generation=${control_generation}" \
      "control_ack_generation=${control_generation}" \
      "control_state=RUNNING" \
      "cycle_state=RUNNING" \
      "replication_activity=TRANSFERRING" \
      "protection_state=$([[ "${sequence}" -gt 1 ]] && printf READY || printf SYNCING)" \
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
      "runtime_generation=${authority_sequence}" \
      "scheduler_session_uuid=${session}" \
      "scheduler_lease_epoch=${lease_epoch}" \
      "authority_sequence=${authority_sequence}" \
      "plan_cycle_sequence=${sequence}" \
      "scheduler_health=HEALTHY" \
      "owner_matched=true" \
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
        92) error_code="DR_NBD_TEARDOWN_TIMEOUT" ;;
        93) error_code="DR_NBD_DISCONNECT_FAILED" ;;
        94) error_code="DR_NBD_DEVICE_BUSY" ;;
        95) error_code="DR_NBD_DEVICE_QUARANTINED" ;;
        96) error_code="DR_NBD_TARGET_FLUSH_FAILED" ;;
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
        DR_NBD_TEARDOWN_TIMEOUT|DR_NBD_DISCONNECT_FAILED|DR_NBD_DEVICE_BUSY|DR_NBD_DEVICE_QUARANTINED)
          error_message="Target data may be durable, but NBD cleanup did not complete"
          data_commit_state="TARGET_DURABLE_CLEANUP_PENDING"
          cycle_retry_mode="CLEANUP_ONLY"
          ;;
        DR_NBD_TARGET_FLUSH_FAILED)
          error_message="Target data flush failed before cycle commit"
          data_commit_state="FAILED"
          cycle_retry_mode="FULL_RETRY"
          ;;
        *)
          error_message="FTCTL DR replication cycle failed"
          data_commit_state="FAILED"
          cycle_retry_mode="FULL_RETRY"
          ;;
      esac
      now="$(ftctl_now_iso8601)"
      authority_sequence="$(ftctl_dr_scheduler_next_authority_sequence "${plan}")"
      ftctl_dr_scheduler_update_state "${state_path}" "${status_path}" \
        "state=ERROR" \
        "step=replication-cycle-failed" \
        "progress=100" \
        "accepted=false" \
        "scheduler_state=ERROR" \
        "scheduler_health=$([[ "${cycle_retry_mode}" == "CLEANUP_ONLY" ]] && printf RECOVERY_REQUIRED || printf DEAD)" \
        "cycle_state=FAILED" \
        "replication_activity=STOPPED" \
        "protection_state=DEGRADED" \
        "current_checkpoint_sequence=${sequence}" \
        "current_checkpoint_cycle_type=${cycle_type}" \
        "current_checkpoint_ref=${checkpoint_ref}" \
        "current_checkpoint_state=FAILED" \
        "current_checkpoint_mode_decision_code=${error_code}" \
        "runtime_generation=${authority_sequence}" \
        "scheduler_session_uuid=${session}" \
        "scheduler_lease_epoch=${lease_epoch}" \
        "authority_sequence=${authority_sequence}" \
        "plan_cycle_sequence=${sequence}" \
        "owner_matched=false" \
        "error_code=${error_code}" \
        "error_message=${error_message}" \
        "failed_component=vmware-mover" \
        "data_commit_state=${data_commit_state}" \
        "data_copied=$([[ "${data_commit_state}" == "DATA_COPIED_METADATA_FAILED" || "${data_commit_state}" == "LOCAL_COMMIT_FAILED" ]] && printf true || printf false)" \
        "metadata_committed=false" \
        "target_durable=false" \
        "cycle_retry_mode=${cycle_retry_mode}" \
        "nbd_teardown_state=$([[ "${cycle_retry_mode}" == "CLEANUP_ONLY" ]] && printf QUARANTINED || printf FAILED)" \
        "nbd_quarantined_device_count=$([[ "${cycle_retry_mode}" == "CLEANUP_ONLY" ]] && printf 1 || printf 0)" \
        "nbd_teardown_error_code=${error_code}" \
        "nbd_teardown_error_message=${error_message}" \
        "scheduler_recovery_state=$([[ "${cycle_retry_mode}" == "CLEANUP_ONLY" ]] && printf REQUIRED || printf FAILED)" \
        "updated_at=${now}" || true
      ftctl_log_event "dr-runtime" "dr.scheduler.cycle" "fail" "" "${rc}" \
        "plan=${plan} run=${run} sequence=${sequence} error=${error_code}"
      rm -f "${pid_path}" 2>/dev/null || true
      ftctl_dr_scheduler_mark_lease_stopped "${plan}" "${session}" "${lease_epoch}" "${run}" "$$" "${start_ticks}"
      flock -u 205 2>/dev/null || true
      exec 205>&-
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
    nbd_teardown_state="$(ftctl_dr_scheduler_checkpoint_value "${checkpoint_path}" "nbdTeardownState" || true)"
    nbd_teardown_started_at_ms="$(ftctl_dr_scheduler_checkpoint_value "${checkpoint_path}" "nbdTeardownStartedAtEpochMs" integer || true)"
    nbd_teardown_completed_at_ms="$(ftctl_dr_scheduler_checkpoint_value "${checkpoint_path}" "nbdTeardownCompletedAtEpochMs" integer || true)"
    nbd_teardown_duration_ms="$(ftctl_dr_scheduler_checkpoint_value "${checkpoint_path}" "nbdTeardownDurationMs" integer || true)"
    nbd_source_device_count="$(ftctl_dr_scheduler_checkpoint_value "${checkpoint_path}" "nbdSourceDeviceCount" integer || true)"
    nbd_target_device_count="$(ftctl_dr_scheduler_checkpoint_value "${checkpoint_path}" "nbdTargetDeviceCount" integer || true)"
    nbd_quarantined_device_count="$(ftctl_dr_scheduler_checkpoint_value "${checkpoint_path}" "nbdQuarantinedDeviceCount" integer || true)"
    nbd_teardown_error_code="$(ftctl_dr_scheduler_checkpoint_value "${checkpoint_path}" "nbdTeardownErrorCode" || true)"
    nbd_teardown_error_message="$(ftctl_dr_scheduler_checkpoint_value "${checkpoint_path}" "nbdTeardownErrorMessage" || true)"
    ftctl_dr_scheduler_append_restore_point "${restore_points_path}" "${plan}" "${run}" "${sequence}" "${cycle_type}" "${driver}" "${manifest_path}" "${checkpoint_path}" || return $?
    now="$(ftctl_now_iso8601)"
    authority_sequence="$(ftctl_dr_scheduler_next_authority_sequence "${plan}")"
    ftctl_dr_scheduler_update_state "${state_path}" "${status_path}" \
      "state=READY" \
      "step=target-checkpoint-ready" \
      "progress=100" \
      "accepted=true" \
      "scheduler_state=RUNNING" \
      "scheduler_health=HEALTHY" \
      "cycle_state=IDLE" \
      "replication_activity=IDLE" \
      "protection_state=READY" \
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
      "runtime_generation=${authority_sequence}" \
      "scheduler_session_uuid=${session}" \
      "scheduler_lease_epoch=${lease_epoch}" \
      "authority_sequence=${authority_sequence}" \
      "plan_cycle_sequence=${sequence}" \
      "active_worker_run_uuid=${run}" \
      "active_worker_pid=$$" \
      "active_worker_start_ticks=${start_ticks}" \
      "worker_heartbeat_at=${now}" \
      "owner_matched=true" \
      "latest_completed_checkpoint_sequence=${sequence}" \
      "latest_completed_checkpoint_cycle_type=${cycle_type}" \
      "latest_completed_requested_mode=${requested_mode}" \
      "latest_completed_checkpoint_ref=${checkpoint_ref}" \
      "latest_completed_checkpoint_state=READY" \
      "latest_completed_producer_run_uuid=${run}" \
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
      "latest_completed_nbd_teardown_state=${nbd_teardown_state}" \
      "latest_completed_nbd_teardown_started_at_ms=${nbd_teardown_started_at_ms}" \
      "latest_completed_nbd_teardown_completed_at_ms=${nbd_teardown_completed_at_ms}" \
      "latest_completed_nbd_teardown_duration_ms=${nbd_teardown_duration_ms}" \
      "latest_completed_nbd_source_device_count=${nbd_source_device_count}" \
      "latest_completed_nbd_target_device_count=${nbd_target_device_count}" \
      "latest_completed_nbd_quarantined_device_count=${nbd_quarantined_device_count:-0}" \
      "latest_completed_nbd_teardown_error_code=${nbd_teardown_error_code}" \
      "latest_completed_nbd_teardown_error_message=${nbd_teardown_error_message}" \
      "nbd_teardown_state=${nbd_teardown_state}" \
      "nbd_quarantined_device_count=${nbd_quarantined_device_count:-0}" \
      "nbd_teardown_error_code=${nbd_teardown_error_code}" \
      "nbd_teardown_error_message=${nbd_teardown_error_message}" \
      "scheduler_recovery_state=SUCCEEDED" \
      "scheduler_recovered_at=${now}" \
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
    ftctl_dr_scheduler_sleep_or_stop "${plan}" "${wait_seconds}" "${control_generation}" || true
  done

  ftctl_dr_scheduler_mark_lease_stopped "${plan}" "${session}" "${lease_epoch}" "${run}" "$$" "${start_ticks}"
  rm -f "${pid_path}" "$(ftctl_dr_scheduler_active_pid_path "${plan}")" 2>/dev/null || true
  flock -u 205 2>/dev/null || true
  exec 205>&-
}

ftctl_dr_scheduler_start() {
  local plan="${1-}" run="${2-}" profile_file="${3-}" state_path="${4-}" status_path="${5-}" wait_value="${6-}"
  local pid_path log_path pid driver_state now session lease_epoch authority_sequence start_ticks

  [[ "${FTCTL_DR_SCHEDULER_DISABLE}" == "1" ]] && return 0
  [[ -n "${profile_file}" && -f "${profile_file}" ]] || return 0
  ftctl_dr_scheduler_profile_has_data_plane "${profile_file}" || return 0
  driver_state="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "driver_state")"
  case "${driver_state}" in
    WAITING_*|MISSING_*) return 0 ;;
  esac

  ftctl_ensure_dir "$(ftctl_dr_scheduler_dir "${plan}")" "0755"
  session="$(ftctl_dr_scheduler_session_uuid "${plan}" "${profile_file}")"
  if ftctl_dr_scheduler_active_worker_valid "${plan}" "${session}"; then
    pid="$(ftctl_dr_scheduler_active_value "${plan}" "pid")"
    start_ticks="$(ftctl_dr_scheduler_active_value "${plan}" "start_ticks")"
    lease_epoch="$(ftctl_dr_scheduler_active_value "${plan}" "lease_epoch")"
    authority_sequence="$(ftctl_dr_scheduler_current_authority_sequence "${plan}")"
    ftctl_dr_scheduler_update_state "${state_path}" "${status_path}" \
      "scheduler_state=RUNNING" \
      "scheduler_health=HEALTHY" \
      "scheduler_pid_alive=true" \
      "scheduler_session_uuid=${session}" \
      "scheduler_lease_epoch=${lease_epoch}" \
      "authority_sequence=${authority_sequence}" \
      "active_worker_run_uuid=$(ftctl_dr_scheduler_active_value "${plan}" "worker_run_uuid")" \
      "active_worker_pid=${pid}" \
      "active_worker_start_ticks=${start_ticks}" \
      "owner_matched=true" \
      "updated_at=$(ftctl_now_iso8601)" || true
    return 0
  fi
  pid_path="$(ftctl_dr_scheduler_pid_path "${plan}" "${run}")"
  if ftctl_dr_scheduler_pid_alive "${pid_path}" "${plan}" "${run}"; then
    pid="$(tr -d '[:space:]' < "${pid_path}")"
    ftctl_dr_runtime_path_set "${state_path}" "scheduler_state=RUNNING" "worker_pid=${pid}" || true
    return 0
  fi

  if [[ "${FTCTL_DR_SCHEDULER_FOREGROUND:-0}" == "1" ]] \
      || { [[ "${wait_value}" != "false" ]] && [[ "${FTCTL_DR_RUNTIME_WORKER:-0}" != "1" ]]; }; then
    ftctl_dr_scheduler_worker "${plan}" "${run}" "${profile_file}" "${state_path}" "${status_path}"
    return $?
  fi

  if ftctl_dr_scheduler_systemd_available "${plan}"; then
    ftctl_dr_scheduler_launch_via_systemd "${plan}" "${run}" "${profile_file}" "${state_path}" "${status_path}" "SYNC_START"
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
