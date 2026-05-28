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

ftctl_state_vm_key() {
  local vm="${1-}"
  echo "${vm//[^a-zA-Z0-9_.-]/_}"
}

ftctl_state_path() {
  local vm="${1-}"
  echo "${FTCTL_STATE_DIR}/$(ftctl_state_vm_key "${vm}").state"
}

ftctl_state_check_path() {
  local vm="${1-}"
  echo "$(ftctl_state_path "${vm}").check.json"
}

ftctl_state_health_path() {
  echo "${FTCTL_STATE_DIR}/health.json"
}

ftctl_state_read_kv() {
  local path="${1-}"
  local key="${2-}"
  [[ -f "${path}" ]] || return 1
  awk -F= -v k="${key}" '$1==k {sub(/^[^=]+=/,""); print; found=1; exit} END{if (!found) exit 1}' "${path}"
}

ftctl_state_write_kv_all() {
  local path="${1-}"
  shift
  local tmp
  tmp="$(mktemp -t ftctl.state.XXXXXX)"
  while (($#)); do
    printf "%s\n" "$1" >> "${tmp}"
    shift
  done
  mv -f "${tmp}" "${path}"
  chmod 0644 "${path}" 2>/dev/null || true
}

ftctl_state_write_json_file() {
  local path="${1-}"
  local json="${2-}"
  local tmp parent
  [[ -n "${path}" ]] || return 1
  parent="$(dirname "${path}")"
  [[ -d "${parent}" ]] || mkdir -p "${parent}" 2>/dev/null || true
  tmp="$(mktemp -t ftctl.state.json.XXXXXX)"
  printf "%s\n" "${json}" > "${tmp}"
  mv -f "${tmp}" "${path}"
  chmod 0644 "${path}" 2>/dev/null || true
}

ftctl_state_exists() {
  local vm="${1-}"
  [[ -f "$(ftctl_state_path "${vm}")" ]]
}

ftctl_state_init_vm() {
  local vm="${1-}"
  local path
  path="$(ftctl_state_path "${vm}")"
  ftctl_state_write_kv_all "${path}" \
    "vm=${vm}" \
    "mode=${FTCTL_PROFILE_MODE}" \
    "profile=${FTCTL_PROFILE_NAME}" \
    "provisioning_backend=${FTCTL_PROFILE_PROVISIONING_BACKEND}" \
    "provisioning_state=${FTCTL_PROFILE_PROVISIONING_STATE}" \
    "primary_uri=${FTCTL_PROFILE_PRIMARY_URI}" \
    "secondary_uri=${FTCTL_PROFILE_SECONDARY_URI}" \
    "active_side=primary" \
    "protection_state=pairing" \
    "transport_state=initializing" \
    "fencing_state=clear" \
    "admin_state=active" \
    "rearm_count=0" \
    "failover_count=0" \
    "last_healthy_ts=$(ftctl_now_iso8601)" \
    "last_sync_ts=" \
    "last_rearm_ts=" \
    "transport_loss_since=" \
    "last_reconcile_ts=" \
    "last_error="
}

ftctl_state_set() {
  local vm="${1-}"
  local path tmp key value
  shift
  path="$(ftctl_state_path "${vm}")"
  [[ -f "${path}" ]] || ftctl_state_init_vm "${vm}"
  tmp="$(mktemp -t ftctl.state.set.XXXXXX)"
  cp -f "${path}" "${tmp}"
  while (($#)); do
    key="${1%%=*}"
    value="${1#*=}"
    if grep -q "^${key}=" "${tmp}"; then
      sed -i "s#^${key}=.*#${key}=${value}#" "${tmp}"
    else
      printf "%s=%s\n" "${key}" "${value}" >> "${tmp}"
    fi
    shift
  done
  mv -f "${tmp}" "${path}"
  chmod 0644 "${path}" 2>/dev/null || true
}

ftctl_state_get() {
  local vm="${1-}"
  local key="${2-}"
  ftctl_state_read_kv "$(ftctl_state_path "${vm}")" "${key}"
}

ftctl_state_increment() {
  local vm="${1-}"
  local key="${2-}"
  local cur
  cur="$(ftctl_state_get "${vm}" "${key}" 2>/dev/null || echo "0")"
  [[ "${cur}" =~ ^[0-9]+$ ]] || cur="0"
  cur=$((cur + 1))
  ftctl_state_set "${vm}" "${key}=${cur}"
  echo "${cur}"
}

ftctl_state_pause_vm() {
  local vm="${1-}"
  ftctl_state_set "${vm}" "admin_state=paused"
  ftctl_log_event "state" "protection.pause" "ok" "${vm}" "" "admin_state=paused"
}

ftctl_state_resume_vm() {
  local vm="${1-}"
  ftctl_state_set "${vm}" "admin_state=active"
  ftctl_log_event "state" "protection.resume" "ok" "${vm}" "" "admin_state=active"
}

ftctl_state_qmp_block_job_devices() {
  local payload="${1-}"
  python3 -c 'import json,sys
try:
    data=json.load(sys.stdin)
except Exception:
    sys.exit(0)
for item in data.get("return", []) or []:
    device=item.get("device")
    if device:
        print(device)
' <<< "${payload}" 2>/dev/null || true
}

ftctl_state_qmp_payload_contains_path() {
  local payload="${1-}"
  local path="${2-}"
  [[ -n "${path}" ]] || return 1
  python3 -c 'import json
import sys

needle = sys.argv[1]

try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(1)

def contains(value):
    if isinstance(value, str):
        return needle in value
    if isinstance(value, dict):
        return any(contains(v) for v in value.values())
    if isinstance(value, list):
        return any(contains(v) for v in value)
    return False

sys.exit(0 if contains(data) else 1)
' "${path}" <<< "${payload}" >/dev/null 2>&1
}

ftctl_state_blockcopy_targets() {
  local vm="${1-}"
  local path line target

  path="$(ftctl_state_path "${vm}").blockcopy"
  [[ -f "${path}" ]] || return 0
  while IFS= read -r line; do
    [[ -n "${line}" ]] || continue
    target="${line%%|*}"
    [[ -n "${target}" ]] && printf '%s\n' "${target}"
  done < "${path}" | awk '!seen[$0]++'
}

ftctl_state_blockcopy_destinations() {
  local vm="${1-}"
  local path line dest

  for path in "$(ftctl_state_path "${vm}").blockcopy" "$(ftctl_state_path "${vm}").blockcopy.reverse"; do
    [[ -f "${path}" ]] || continue
    while IFS= read -r line; do
      [[ -n "${line}" ]] || continue
      IFS='|' read -r _ _ dest _ <<< "${line}"
      [[ -n "${dest}" ]] && printf '%s\n' "${dest}"
    done < "${path}"
  done | awk '!seen[$0]++'
}

ftctl_state_wait_block_jobs_released() {
  local vm="${1-}"
  local timeout_sec="${2:-${FTCTL_UNPROTECT_RELEASE_TIMEOUT_SEC:-180}}"
  local deadline now out="" err="" rc=0 remaining=""

  deadline=$(( $(ftctl_now_epoch) + timeout_sec ))
  while true; do
    ftctl_virsh "${FTCTL_BLOCKCOPY_WAIT_TIMEOUT_SEC:-30}" out err rc -- -c "${FTCTL_DEFAULT_PRIMARY_URI:-qemu:///system}" qemu-monitor-command "${vm}" --pretty '{"execute":"query-block-jobs"}' || true
    remaining="$(ftctl_state_qmp_block_job_devices "${out}")"
    if [[ -z "${remaining}" ]]; then
      ftctl_log_event "state" "protection.unprotect.block-jobs-released" "ok" "${vm}" "${rc}" ""
      return 0
    fi
    now="$(ftctl_now_epoch)"
    if (( now >= deadline )); then
      ftctl_log_event "state" "protection.unprotect.block-jobs-released" "timeout" "${vm}" "${rc}" "devices=$(tr '\n' ',' <<< "${remaining}" | sed 's/,$//')"
      echo "ERROR: block jobs still active for ${vm}: ${remaining}" >&2
      return 2
    fi
    sleep 1
  done
}

ftctl_state_wait_qmp_destinations_released() {
  local vm="${1-}"
  local timeout_sec="${2:-${FTCTL_UNPROTECT_RELEASE_TIMEOUT_SEC:-180}}"
  local deadline now out="" err="" rc=0 dest
  local -a destinations=()
  local -a pending=()

  mapfile -t destinations < <(ftctl_state_blockcopy_destinations "${vm}")
  ((${#destinations[@]})) || return 0

  deadline=$(( $(ftctl_now_epoch) + timeout_sec ))
  while true; do
    pending=()
    ftctl_virsh "${FTCTL_BLOCKCOPY_WAIT_TIMEOUT_SEC:-30}" out err rc -- -c "${FTCTL_DEFAULT_PRIMARY_URI:-qemu:///system}" qemu-monitor-command "${vm}" --pretty '{"execute":"query-named-block-nodes"}' || true
    for dest in "${destinations[@]}"; do
      [[ -n "${dest}" ]] || continue
      if ftctl_state_qmp_payload_contains_path "${out}" "${dest}"; then
        pending+=("${dest}")
      fi
    done
    if ((${#pending[@]} == 0)); then
      ftctl_log_event "state" "protection.unprotect.qmp-destinations-released" "ok" "${vm}" "${rc}" "count=${#destinations[@]}"
      return 0
    fi
    now="$(ftctl_now_epoch)"
    if (( now >= deadline )); then
      ftctl_log_event "state" "protection.unprotect.qmp-destinations-released" "timeout" "${vm}" "${rc}" "destinations=$(IFS=,; echo "${pending[*]}")"
      echo "ERROR: block nodes still reference FTCTL destinations for ${vm}: ${pending[*]}" >&2
      return 2
    fi
    sleep 1
  done
}

ftctl_state_unmap_local_krbd_destinations() {
  local vm="${1-}"
  local timeout_sec="${2:-${FTCTL_UNPROTECT_RELEASE_TIMEOUT_SEC:-180}}"
  local dest spec deadline now unmap_out unmap_count=0

  while IFS= read -r dest; do
    [[ "${dest}" == /dev/rbd/* ]] || continue
    spec="${dest#/dev/rbd/}"
    if [[ ! -b "${dest}" ]]; then
      ftctl_log_event "state" "protection.unprotect.rbd-unmap" "ok" "${vm}" "" "path=${dest} spec=${spec} already_unmapped=1"
      continue
    fi
    command -v rbd >/dev/null 2>&1 || {
      echo "ERROR: rbd CLI not found while releasing ${dest}" >&2
      return 2
    }
    deadline=$(( $(ftctl_now_epoch) + timeout_sec ))
    while [[ -b "${dest}" ]]; do
      unmap_out="$(rbd unmap "${dest}" 2>&1)" || true
      udevadm settle >/dev/null 2>&1 || true
      [[ ! -b "${dest}" ]] && break
      now="$(ftctl_now_epoch)"
      if (( now >= deadline )); then
        ftctl_log_event "state" "protection.unprotect.rbd-unmap" "timeout" "${vm}" "" "path=${dest} spec=${spec} message=${unmap_out}"
        echo "ERROR: unable to unmap FTCTL RBD destination ${dest}: ${unmap_out}" >&2
        return 2
      fi
      sleep 1
    done
    unmap_count=$((unmap_count + 1))
    ftctl_log_event "state" "protection.unprotect.rbd-unmap" "ok" "${vm}" "" "path=${dest} spec=${spec}"
  done < <(ftctl_state_blockcopy_destinations "${vm}")

  printf '%s\n' "${unmap_count}"
}

ftctl_state_cancel_block_jobs() {
  local vm="${1-}"
  local out="" err="" rc=0 device="" canceled=0

  ftctl_virsh "${FTCTL_BLOCKCOPY_WAIT_TIMEOUT_SEC:-30}" out err rc -- -c "${FTCTL_DEFAULT_PRIMARY_URI:-qemu:///system}" qemu-monitor-command "${vm}" --pretty '{"execute":"query-block-jobs"}' || true
  while IFS= read -r device; do
    [[ -n "${device}" ]] || continue
    canceled=$((canceled + 1))
    ftctl_virsh "${FTCTL_BLOCKCOPY_WAIT_TIMEOUT_SEC:-30}" out err rc -- -c "${FTCTL_DEFAULT_PRIMARY_URI:-qemu:///system}" qemu-monitor-command "${vm}" --pretty "{\"execute\":\"block-job-cancel\",\"arguments\":{\"device\":\"${device}\",\"force\":true}}" || true
    ftctl_log_event "state" "protection.unprotect.block-job-cancel" "$(ftctl_result_from_rc "${rc}")" "${vm}" "${rc}" "device=${device}"
  done < <(ftctl_state_qmp_block_job_devices "${out}")

  printf '%s\n' "${canceled}"
}

ftctl_state_release_remote_nbd_exports() {
  local vm="${1-}"

  [[ "${FTCTL_PROFILE_BACKEND_MODE:-}" == "remote-nbd" ]] || {
    printf 'false\n'
    return 0
  }
  if ! declare -F ftctl_blockcopy_stop_remote_nbd_exports >/dev/null 2>&1 ||
     ! declare -F ftctl_blockcopy_wait_remote_nbd_release >/dev/null 2>&1; then
    ftctl_state_set "${vm}" "last_error=remote_nbd_release_unsupported"
    ftctl_log_event "state" "protection.unprotect.remote-nbd-release" "fail" "${vm}" "" "reason=unsupported"
    echo "ERROR: remote-nbd release helpers are not available for ${vm}" >&2
    return 2
  fi

  ftctl_blockcopy_stop_remote_nbd_exports "${vm}" || {
    ftctl_state_set "${vm}" "last_error=remote_nbd_stop_failed"
    ftctl_log_event "state" "protection.unprotect.remote-nbd-stop" "fail" "${vm}" "" ""
    echo "ERROR: unable to stop remote-nbd exports for ${vm}" >&2
    return 2
  }
  ftctl_blockcopy_wait_remote_nbd_release "${vm}" || {
    ftctl_state_set "${vm}" "last_error=remote_nbd_release_timeout"
    ftctl_log_event "state" "protection.unprotect.remote-nbd-release" "fail" "${vm}" "" "reason=timeout"
    echo "ERROR: remote-nbd exports still active for ${vm}" >&2
    return 2
  }

  ftctl_log_event "state" "protection.unprotect.remote-nbd-release" "ok" "${vm}" "" ""
  printf 'true\n'
}

ftctl_state_remove_runtime_files() {
  local vm="${1-}"
  local key
  key="$(ftctl_state_vm_key "${vm}")"

  rm -f "$(ftctl_profile_path "${vm}")" 2>/dev/null || true
  rm -f "${FTCTL_STATE_DIR}/${key}.state" \
    "${FTCTL_STATE_DIR}/${key}.state.check.json" \
    "${FTCTL_STATE_DIR}/${key}.state.blockcopy" \
    "${FTCTL_STATE_DIR}/${key}.state.blockcopy.reverse" \
    "${FTCTL_STATE_DIR}/${key}.state.blockcopy.progress" \
    "${FTCTL_STATE_DIR}/${key}.state.blockcopy.progress.event" \
    "${FTCTL_STATE_DIR}/${key}.state.xcolo" 2>/dev/null || true
  rm -rf "${FTCTL_RUN_DIR}/debug/blockcopy/${key}" 2>/dev/null || true
  rm -f "${FTCTL_RUN_DIR}/xml/${key}-"*.xml 2>/dev/null || true
  rm -rf "${FTCTL_XML_BACKUP_DIR}/${key}" 2>/dev/null || true
  rm -f "${FTCTL_XML_BACKUP_DIR}/${key}-"*.xml 2>/dev/null || true
  rm -f /tmp/ftctl_* 2>/dev/null || true
}

ftctl_state_unprotect_add_warning() {
  local target_var="${1-}"
  local warning="${2-}"
  local current="${!target_var:-}"

  [[ -n "${target_var}" && -n "${warning}" ]] || return 0
  if [[ -n "${current}" ]]; then
    printf -v "${target_var}" '%s\n%s' "${current}" "${warning}"
  else
    printf -v "${target_var}" '%s' "${warning}"
  fi
}

ftctl_state_unprotect_warnings_json() {
  local warnings="${1-}"
  local line first="1"

  printf '['
  while IFS= read -r line; do
    [[ -n "${line}" ]] || continue
    [[ "${first}" == "1" ]] || printf ','
    first="0"
    printf '"%s"' "$(ftctl__json_escape "${line}")"
  done <<< "${warnings}"
  printf ']'
}

ftctl_state_unprotect_log_warnings() {
  local vm="${1-}"
  local warnings="${2-}"
  local line

  while IFS= read -r line; do
    [[ -n "${line}" ]] || continue
    ftctl_log_event "state" "protection.unprotect.force-cleanup-warning" "warn" "${vm}" "" "warning=${line}"
  done <<< "${warnings}"
}

ftctl_state_unprotect_vm() {
  local vm="${1-}"
  local json="${2-0}"
  local force_cleanup="${3-0}"
  local canceled unmapped remote_nbd_required remote_nbd_released result warnings rc forced_json warnings_json

  warnings=""
  canceled="$(ftctl_state_cancel_block_jobs "${vm}" 2>/dev/null || echo 0)"
  if ftctl_state_wait_block_jobs_released "${vm}"; then
    :
  else
    rc=$?
    if [[ "${force_cleanup}" == "1" ]]; then
      ftctl_state_unprotect_add_warning warnings "block_jobs_release_timeout"
    else
      return "${rc}"
    fi
  fi
  if ftctl_state_wait_qmp_destinations_released "${vm}"; then
    :
  else
    rc=$?
    if [[ "${force_cleanup}" == "1" ]]; then
      ftctl_state_unprotect_add_warning warnings "qmp_destinations_release_timeout"
    else
      return "${rc}"
    fi
  fi
  remote_nbd_required="false"
  [[ "${FTCTL_PROFILE_BACKEND_MODE:-}" == "remote-nbd" ]] && remote_nbd_required="true"
  if remote_nbd_released="$(ftctl_state_release_remote_nbd_exports "${vm}")"; then
    :
  else
    rc=$?
    if [[ "${force_cleanup}" == "1" ]]; then
      remote_nbd_released="false"
      ftctl_state_unprotect_add_warning warnings "remote_nbd_release_failed"
    else
      return "${rc}"
    fi
  fi
  if unmapped="$(ftctl_state_unmap_local_krbd_destinations "${vm}")"; then
    :
  else
    rc=$?
    if [[ "${force_cleanup}" == "1" ]]; then
      unmapped="0"
      ftctl_state_unprotect_add_warning warnings "rbd_unmap_failed"
    else
      return "${rc}"
    fi
  fi
  ftctl_state_remove_runtime_files "${vm}"
  result="ok"
  [[ -n "${warnings}" ]] && result="warn"
  [[ "${force_cleanup}" == "1" ]] && forced_json="true" || forced_json="false"
  warnings_json="$(ftctl_state_unprotect_warnings_json "${warnings}")"
  ftctl_state_unprotect_log_warnings "${vm}" "${warnings}"
  ftctl_log_event "state" "protection.unprotect" "${result}" "${vm}" "" "force_cleanup=${force_cleanup} block_jobs_cancelled=${canceled} rbd_unmapped=${unmapped} remote_nbd_required=${remote_nbd_required} remote_nbd_released=${remote_nbd_released}"

  if [[ "${json}" == "1" ]]; then
    printf '{"command":"unprotect","result":"%s","vm":"%s","forced":%s,"block_jobs_cancelled":%s,"rbd_unmapped":%s,"remote_nbd_required":%s,"remote_nbd_released":%s,"warnings":%s}\n' \
      "${result}" \
      "$(ftctl__json_escape "${vm}")" \
      "${forced_json}" \
      "${canceled}" \
      "${unmapped}" \
      "${remote_nbd_required}" \
      "${remote_nbd_released}" \
      "${warnings_json}"
  else
    printf '%s: protection runtime removed\n' "${vm}"
  fi
}

ftctl_state_get_elapsed_key_sec() {
  local vm="${1-}"
  local key="${2-}"
  local value
  value="$(ftctl_state_get "${vm}" "${key}" 2>/dev/null || true)"
  [[ -n "${value}" ]] || return 1
  ftctl_elapsed_since_iso "${value}"
}

ftctl_state_emit_json_fields() {
  local vm="${1-}"
  local path line first="1" key value fallback_error protection_state conversion_state transport_state
  path="$(ftctl_state_path "${vm}")"
  fallback_error=""
  protection_state="$(grep -E '^protection_state=' "${path}" 2>/dev/null | tail -n1 | cut -d= -f2- || true)"
  conversion_state="$(grep -E '^conversion_state=' "${path}" 2>/dev/null | tail -n1 | cut -d= -f2- || true)"
  transport_state="$(grep -E '^transport_state=' "${path}" 2>/dev/null | tail -n1 | cut -d= -f2- || true)"
  if [[ "${protection_state}" == "error" ||
        "${conversion_state}" == "error" ||
        "${transport_state}" == "failed" ]]; then
    fallback_error="$(grep -E '^xcolo_last_runtime_error=' "${path}" 2>/dev/null | tail -n1 | cut -d= -f2- || true)"
  fi
  while IFS= read -r line; do
    [[ -n "${line}" ]] || continue
    key="${line%%=*}"
    value="${line#*=}"
    if [[ "${key}" == "last_error" && -z "${value}" && -n "${fallback_error}" ]]; then
      value="${fallback_error}"
    fi
    if [[ "${first}" == "1" ]]; then
      first="0"
    else
      printf ","
    fi
    printf '"%s":"%s"' \
      "$(ftctl__json_escape "${key}")" \
      "$(ftctl__json_escape "${value}")"
  done < "${path}"
}

ftctl_state_emit_json_one() {
  local vm="${1-}"
  local result="${2-ok}"
  local progress_path progress_json
  printf '{"command":"status","result":"%s"' "$(ftctl__json_escape "${result}")"
  if [[ -f "$(ftctl_state_path "${vm}")" ]]; then
    printf ","
    ftctl_state_emit_json_fields "${vm}"
    progress_path="$(ftctl_state_path "${vm}").blockcopy.progress"
    if [[ -f "${progress_path}" ]]; then
      progress_json="$(cat "${progress_path}" 2>/dev/null || true)"
      if [[ -n "${progress_json}" ]] && python3 -m json.tool "${progress_path}" >/dev/null 2>&1; then
        printf ',"sync_progress":%s' "${progress_json}"
      fi
    fi
  else
    printf ',"vm":"%s"' "$(ftctl__json_escape "${vm}")"
  fi
  printf '}\n'
}

ftctl_state_emit_json_file_or_null() {
  local path="${1-}"
  if [[ -f "${path}" ]] && python3 -m json.tool "${path}" >/dev/null 2>&1; then
    cat "${path}"
  else
    printf 'null'
  fi
}

ftctl_state_emit_snapshot_one() {
  local vm="${1-}"
  local limit="${2-}"
  local line first count
  printf '{"command":"snapshot","result":"ok","vm":"%s","status":' "$(ftctl__json_escape "${vm}")"
  ftctl_state_emit_json_one "${vm}" "$([[ -f "$(ftctl_state_path "${vm}")" ]] && echo ok || echo not_found)" | tr -d '\r\n'
  printf ',"check":'
  ftctl_state_emit_json_file_or_null "$(ftctl_state_check_path "${vm}")" | tr -d '\r\n'
  printf ',"health":'
  ftctl_state_emit_json_file_or_null "$(ftctl_state_health_path)" | tr -d '\r\n'
  printf ',"events":['
  first="1"
  count=0
  while IFS= read -r line; do
    [[ -n "${line}" ]] || continue
    if [[ "${first}" == "1" ]]; then
      first="0"
    else
      printf ','
    fi
    printf '%s' "${line}"
    count=$((count + 1))
  done < <(ftctl_events_collect_lines "${vm}" "${limit}")
  printf '],"event_count":%s}\n' "${count}"
}

ftctl_state_print_snapshot() {
  local vm="${1-}"
  local json="${2-0}"
  local limit="${3-}"
  local f name first count

  if [[ "${json}" != "1" ]]; then
    if [[ -n "${vm}" ]]; then
      ftctl_state_print_one "${vm}" "0"
      printf 'check_snapshot=%s health_snapshot=%s\n' "$(ftctl_state_check_path "${vm}")" "$(ftctl_state_health_path)"
    else
      ftctl_state_print_status "" "0"
      printf 'health_snapshot=%s\n' "$(ftctl_state_health_path)"
    fi
    return 0
  fi

  if [[ -n "${vm}" ]]; then
    ftctl_state_emit_snapshot_one "${vm}" "${limit}"
    return 0
  fi

  shopt -s nullglob
  first="1"
  count=0
  printf '{"command":"snapshot","result":"ok","items":['
  for f in "${FTCTL_STATE_DIR}"/*.state; do
    name="$(basename "${f}" .state)"
    if [[ "${first}" == "1" ]]; then
      first="0"
    else
      printf ','
    fi
    ftctl_state_emit_snapshot_one "${name}" "${limit}" | tr -d '\r\n'
    count=$((count + 1))
  done
  printf '],"count":%s}\n' "${count}"
  shopt -u nullglob
}

ftctl_state_print_one() {
  local vm="${1-}"
  local json="${2-0}"
  local path
  path="$(ftctl_state_path "${vm}")"
  [[ -f "${path}" ]] || {
    if [[ "${json}" == "1" ]]; then
      ftctl_state_emit_json_one "${vm}" "not_found"
    else
      printf '%s: state not found\n' "${vm}"
    fi
    return 1
  }
  if [[ "${json}" == "1" ]]; then
    ftctl_state_emit_json_one "${vm}" "ok"
  else
    printf '%s mode=%s state=%s transport=%s active=%s admin=%s rearm_count=%s failover_count=%s\n' \
      "${vm}" \
      "$(ftctl_state_get "${vm}" "mode" || true)" \
      "$(ftctl_state_get "${vm}" "protection_state" || true)" \
      "$(ftctl_state_get "${vm}" "transport_state" || true)" \
      "$(ftctl_state_get "${vm}" "active_side" || true)" \
      "$(ftctl_state_get "${vm}" "admin_state" || true)" \
      "$(ftctl_state_get "${vm}" "rearm_count" || true)" \
      "$(ftctl_state_get "${vm}" "failover_count" || true)"
  fi
}

ftctl_state_print_status() {
  local vm="${1-}"
  local json="${2-0}"
  local f name first count
  if [[ -n "${vm}" ]]; then
    ftctl_state_print_one "${vm}" "${json}"
    return $?
  fi
  shopt -s nullglob
  if [[ "${json}" == "1" ]]; then
    first="1"
    count=0
    printf '{"command":"status","result":"ok","items":['
    for f in "${FTCTL_STATE_DIR}"/*.state; do
      name="$(basename "${f}" .state)"
      count=$((count + 1))
      if [[ "${first}" == "1" ]]; then
        first="0"
      else
        printf ','
      fi
      ftctl_state_emit_json_one "${name}" "ok" | tr -d '\r\n'
    done
    printf '],"count":%s}\n' "${count}"
    shopt -u nullglob
    return 0
  fi
  for f in "${FTCTL_STATE_DIR}"/*.state; do
    name="$(basename "${f}" .state)"
    ftctl_state_print_one "${name}" "0"
  done
  shopt -u nullglob
}
