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
  local path line first="1"
  path="$(ftctl_state_path "${vm}")"
  while IFS= read -r line; do
    [[ -n "${line}" ]] || continue
    if [[ "${first}" == "1" ]]; then
      first="0"
    else
      printf ","
    fi
    printf '"%s":"%s"' \
      "$(ftctl__json_escape "${line%%=*}")" \
      "$(ftctl__json_escape "${line#*=}")"
  done < "${path}"
}

ftctl_state_emit_json_one() {
  local vm="${1-}"
  local result="${2-ok}"
  printf '{"command":"status","result":"%s"' "$(ftctl__json_escape "${result}")"
  if [[ -f "$(ftctl_state_path "${vm}")" ]]; then
    printf ","
    ftctl_state_emit_json_fields "${vm}"
  else
    printf ',"vm":"%s"' "$(ftctl__json_escape "${vm}")"
  fi
  printf '}\n'
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
