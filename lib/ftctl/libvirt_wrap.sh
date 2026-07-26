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

ftctl_lock_emit_conflict() {
  local lock_file="${1-}"
  local cmd="${CLI_COMMAND:-unknown}"
  local vm="${CLI_VM:-}"
  local result="locked"
  local holder_pid="" holder_age="" holder_command=""
  if [[ -f "${lock_file}.meta" ]]; then
    # shellcheck disable=SC1090
    source "${lock_file}.meta" 2>/dev/null || true
    holder_pid="${pid:-}"
    holder_command="${command:-}"
    if [[ -n "${started_epoch:-}" && "${started_epoch}" =~ ^[0-9]+$ ]]; then
      holder_age="$(( $(date +%s) - started_epoch ))"
    fi
  fi
  command -v ftctl_dr_runtime_record_lock_conflict >/dev/null 2>&1 &&
    ftctl_dr_runtime_record_lock_conflict "${lock_file}" "${cmd}" "${holder_pid}" "${holder_command}" "${holder_age}" "${EXIT_LOCKED:-20}" || true
  if [[ "${CLI_JSON:-0}" == "1" ]]; then
    printf '{"command":"%s","result":"%s","lock_file":"%s","vm":"%s","holder_pid":"%s","holder_command":"%s","holder_age_sec":"%s","exit_code":%s,"retryable":true,"retry_after_sec":2}\n' \
      "$(ftctl__json_escape "${cmd}")" \
      "${result}" \
      "$(ftctl__json_escape "${lock_file}")" \
      "$(ftctl__json_escape "${vm}")" \
      "$(ftctl__json_escape "${holder_pid}")" \
      "$(ftctl__json_escape "${holder_command}")" \
      "$(ftctl__json_escape "${holder_age}")" \
      "${EXIT_LOCKED:-20}"
  else
    printf 'ftctl.%s: %s (%s)\n' "${cmd}" "${result}" "${lock_file}"
  fi
}

FTCTL_HELD_LOCK_FILE=""

ftctl_lock_release() {
  local lock_file="${FTCTL_HELD_LOCK_FILE:-}"
  local meta_pid=""

  [[ -n "${lock_file}" ]] || return 0
  if [[ -f "${lock_file}.meta" ]]; then
    # shellcheck disable=SC1090
    source "${lock_file}.meta" 2>/dev/null || true
    meta_pid="${pid:-}"
  fi
  if [[ -z "${meta_pid}" || "${meta_pid}" == "$$" ]]; then
    rm -f -- "${lock_file}.meta" "${lock_file}" 2>/dev/null || true
  fi
  FTCTL_HELD_LOCK_FILE=""
}

ftctl_lock_path_for_command() {
  local command="${1-}"
  local vm="${2-}"
  case "${command}" in
    reconcile)
      if [[ -n "${vm}" ]]; then
        printf '%s/locks/%s.lock\n' "${FTCTL_RUN_DIR}" "$(ftctl_state_vm_key "${vm}")"
      else
        printf '%s\n' "${FTCTL_LOCK_FILE}"
      fi
      ;;
    *)
      if [[ -n "${vm}" ]]; then
        printf '%s/locks/%s.lock\n' "${FTCTL_RUN_DIR}" "$(ftctl_state_vm_key "${vm}")"
      else
        printf '%s\n' "${FTCTL_LOCK_FILE}"
      fi
      ;;
  esac
}

ftctl_lock_acquire() {
  local lock_file="${1-}"
  lock_file="${lock_file:-$(ftctl_lock_path_for_command "${CLI_COMMAND:-}" "${CLI_VM:-}")}"
  ftctl_ensure_dir "$(dirname "${lock_file}")" "0755"
  exec 201>"${lock_file}"
  if ! flock -n 201; then
    ftctl_log_event "lock" "lock.acquire" "skip" "" "${EXIT_LOCKED:-20}" \
      "reason=locked command=${CLI_COMMAND:-unknown} lock_file=${lock_file}"
    ftctl_lock_emit_conflict "${lock_file}"
    return "${EXIT_LOCKED:-20}"
  fi
  {
    printf 'pid=%q\n' "$$"
    printf 'command=%q\n' "${CLI_COMMAND:-unknown}"
    printf 'vm=%q\n' "${CLI_VM:-}"
    printf 'started_epoch=%q\n' "$(date +%s)"
  } > "${lock_file}.meta" 2>/dev/null || true
  FTCTL_HELD_LOCK_FILE="${lock_file}"
  trap ftctl_lock_release EXIT
  return 0
}

ftctl_command_requires_lock() {
  local command="${1-}"
  local action="${2-}"
  case "${command}" in
    reconcile)
      return 1
      ;;
    status|check|health|events|protect-start|preflight-remote|dr-key-ensure|dr-key-install|dr-key-remove|dr-status|dr-capabilities|dr-target-materialized|dr-cutover-commit|dr-failback-commit|dr-failback-abort)
      return 1
      ;;
    dr-plan-apply|dr-sync-start|dr-sync-pause|dr-sync-resume|dr-test-failover|dr-test-cleanup|dr-test-prepare|dr-test-artifact-cleanup|dr-failover|dr-failback|dr-reprotect|dr-release|dr-cancel)
      # DR commands coordinate through plan-scoped transition/cycle locks. The
      # legacy global lock is retained for FT/HA commands only.
      return 1
      ;;
    config)
      case "${action}" in
        show|host-list|profile-show)
          return 1
          ;;
        *)
          return 0
          ;;
      esac
      ;;
    "")
      return 1
      ;;
    *)
      return 0
      ;;
  esac
}

ftctl_cmd_run() {
  local timeout_sec="${1-3}"
  local -n _out="${2}"
  local -n _err="${3}"
  local -n _rc="${4}"
  shift 4
  [[ "${1-}" == "--" ]] || {
    _out=""
    _err="invalid_args"
    _rc=2
    return 2
  }
  shift

  local tmp_out tmp_err
  tmp_out="$(mktemp -t ftctl.out.XXXXXX)"
  tmp_err="$(mktemp -t ftctl.err.XXXXXX)"
  # shellcheck disable=SC2064
  trap "rm -f -- '${tmp_out}' '${tmp_err}' 2>/dev/null || true" RETURN

  if command -v timeout >/dev/null 2>&1; then
    (
      exec 201>&- 2>/dev/null || true
      timeout --preserve-status "${timeout_sec}" "$@"
    ) >"${tmp_out}" 2>"${tmp_err}" || _rc=$?
    : "${_rc:=0}"
  else
    (
      exec 201>&- 2>/dev/null || true
      "$@"
    ) >"${tmp_out}" 2>"${tmp_err}" || _rc=$?
    : "${_rc:=0}"
  fi

  _out="$(cat "${tmp_out}" 2>/dev/null || true)"
  _err="$(cat "${tmp_err}" 2>/dev/null || true)"
  trap - RETURN
  rm -f -- "${tmp_out}" "${tmp_err}" 2>/dev/null || true
  return "${_rc}"
}

ftctl_result_from_rc() {
  local rc="${1-}"
  if [[ "${rc}" == "0" ]]; then
    echo "ok"
  elif [[ "${rc}" == "124" ]]; then
    echo "timeout"
  else
    echo "fail"
  fi
}

ftctl_virsh() {
  local timeout_sec="${1-3}"
  local out_var="${2}"
  local err_var="${3}"
  local rc_var="${4}"
  local args=()
  local i profile effective_uri
  shift 4
  [[ "${1-}" == "--" ]] && shift
  args=("$@")
  if [[ "${FTCTL_PROFILE_MODE:-}" == "dr" ]] && declare -F ftctl_dr_key_uri_with_keyfile >/dev/null 2>&1; then
    profile="${CLI_PROFILE:-${CLI_VM:-}}"
    for ((i = 0; i < ${#args[@]} - 1; i++)); do
      if [[ "${args[$i]}" == "-c" && "${args[$((i + 1))]}" == qemu+ssh://* ]]; then
        effective_uri="$(ftctl_dr_key_uri_with_keyfile "${args[$((i + 1))]}" "${profile}")"
        args[i + 1]="${effective_uri}"
      fi
    done
  fi
  ftctl_cmd_run "${timeout_sec}" "${out_var}" "${err_var}" "${rc_var}" -- env LC_ALL=C LANG=C virsh "${args[@]}" || return $?
}

ftctl_local_health() {
  local json="${1-0}"
  local vm="${2-}"
  local out err rc result snapshot
  out=""
  err=""
  rc=0
  ftctl_virsh "${FTCTL_HEALTH_INTERVAL_SEC}" out err rc -- -c "${FTCTL_DEFAULT_PRIMARY_URI}" list --name || true
  : "${out}${err}"
  result="$(ftctl_result_from_rc "${rc}")"
  ftctl_log_event "health" "libvirt.local" "${result}" "${vm}" "${rc}" "uri=${FTCTL_DEFAULT_PRIMARY_URI}"
  snapshot="$(printf '{"command":"health","result":"%s","uri":"%s","rc":%s,"updated":"%s"}' \
    "$(ftctl__json_escape "${result}")" \
    "$(ftctl__json_escape "${FTCTL_DEFAULT_PRIMARY_URI}")" \
    "${rc}" \
    "$(ftctl__json_escape "$(ftctl_now_iso8601)")")"
  ftctl_state_write_json_file "$(ftctl_state_health_path)" "${snapshot}"
  if [[ "${json}" == "1" ]]; then
    printf '%s\n' "${snapshot}"
  else
    printf 'libvirt.local: %s (%s)\n' "${result}" "${FTCTL_DEFAULT_PRIMARY_URI}"
  fi
  [[ "${rc}" == "0" ]]
}
