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

ftctl_dr_runtime_key() {
  local value="${1-}"
  ftctl_state_vm_key "${value}"
}

ftctl_dr_runtime_root() {
  printf '%s/dr-runtime\n' "${FTCTL_RUN_DIR}"
}

ftctl_dr_runtime_plan_dir() {
  local plan="${1-}"
  printf '%s/plans/%s\n' "$(ftctl_dr_runtime_root)" "$(ftctl_dr_runtime_key "${plan}")"
}

ftctl_dr_runtime_profile_path() {
  local plan="${1-}"
  printf '%s/profile.json\n' "$(ftctl_dr_runtime_plan_dir "${plan}")"
}

ftctl_dr_runtime_artifact_spec_path() {
  local plan="${1-}" run="${2-}"
  printf '%s/test-sessions/%s.artifact-spec.json\n' "$(ftctl_dr_runtime_plan_dir "${plan}")" "$(ftctl_dr_runtime_key "${run}")"
}

ftctl_dr_runtime_authority_spec_path() {
  local plan="${1-}" run="${2-}"
  printf '%s/%s.authority.json\n' "$(ftctl_dr_runtime_run_dir "${plan}")" "$(ftctl_dr_runtime_key "${run}")"
}

ftctl_dr_runtime_credential_path() {
  local plan="${1-}"
  printf '%s/credentials.json\n' "$(ftctl_dr_runtime_plan_dir "${plan}")"
}

ftctl_dr_runtime_status_path() {
  local plan="${1-}"
  printf '%s/status.state\n' "$(ftctl_dr_runtime_plan_dir "${plan}")"
}

ftctl_dr_runtime_run_dir() {
  local plan="${1-}"
  printf '%s/runs\n' "$(ftctl_dr_runtime_plan_dir "${plan}")"
}

ftctl_dr_runtime_run_path() {
  local plan="${1-}" run="${2-}"
  printf '%s/%s.state\n' "$(ftctl_dr_runtime_run_dir "${plan}")" "$(ftctl_dr_runtime_key "${run}")"
}

ftctl_dr_runtime_test_dir() {
  local plan="${1-}"
  printf '%s/test-sessions\n' "$(ftctl_dr_runtime_plan_dir "${plan}")"
}

ftctl_dr_runtime_test_session_path() {
  local plan="${1-}" run="${2-}"
  printf '%s/%s.json\n' "$(ftctl_dr_runtime_test_dir "${plan}")" "$(ftctl_dr_runtime_key "${run}")"
}

ftctl_dr_runtime_active_test_session_path() {
  local plan="${1-}"
  printf '%s/active.json\n' "$(ftctl_dr_runtime_test_dir "${plan}")"
}

ftctl_dr_runtime_test_artifacts_dir() {
  local plan="${1-}" run="${2-}"
  printf '%s/%s-artifacts\n' "$(ftctl_dr_runtime_test_dir "${plan}")" "$(ftctl_dr_runtime_key "${run}")"
}

ftctl_dr_runtime_failover_dir() {
  local plan="${1-}"
  printf '%s/failovers\n' "$(ftctl_dr_runtime_plan_dir "${plan}")"
}

ftctl_dr_runtime_failover_session_path() {
  local plan="${1-}" run="${2-}"
  printf '%s/%s.json\n' "$(ftctl_dr_runtime_failover_dir "${plan}")" "$(ftctl_dr_runtime_key "${run}")"
}

ftctl_dr_runtime_active_failover_session_path() {
  local plan="${1-}"
  printf '%s/active.json\n' "$(ftctl_dr_runtime_failover_dir "${plan}")"
}

ftctl_dr_runtime_capture_authority_context() {
  local plan="${1-}" run_path="${2-}" prior_status_path="${3-}" authority_spec_path="${4-}"
  local active_path snapshot_path active_side authority_state checkpoint_sequence
  local target_power_state target_promotion_state session_id authority_generation authority_source

  active_path="$(ftctl_dr_runtime_active_failover_session_path "${plan}")"
  snapshot_path="$(mktemp -t ftctl.dr.authority.XXXXXX)"
  if [[ -f "${active_path}" ]]; then
    python3 - "${active_path}" "${snapshot_path}" <<'PY' || true
import json
import sys

source, target = sys.argv[1:3]
try:
    with open(source, "r", encoding="utf-8") as fh:
        session = json.load(fh)
except (OSError, json.JSONDecodeError):
    session = {}

promotion = session.get("targetPromotion")
if not isinstance(promotion, dict):
    promotion = {}
restore_point = session.get("restorePoint")
if not isinstance(restore_point, dict):
    restore_point = {}

values = {
    "active_side": session.get("activeSide"),
    "authority_state": session.get("state"),
    "checkpoint_sequence": restore_point.get("checkpointSequence"),
    "target_power_state": promotion.get("powerState"),
    "target_promotion_state": promotion.get("state"),
    "cloud_cutover_session_id": session.get("sessionId"),
    "cloud_authority_generation": session.get("cloudAuthorityGeneration"),
}
with open(target, "w", encoding="utf-8") as fh:
    for key, value in values.items():
        fh.write(f"{key}={'' if value is None else value}\n")
PY
  fi

  active_side="$(ftctl_dr_runtime_state_get_from_path "${snapshot_path}" "active_side")"
  authority_state="$(ftctl_dr_runtime_state_get_from_path "${snapshot_path}" "authority_state")"
  checkpoint_sequence="$(ftctl_dr_runtime_state_get_from_path "${snapshot_path}" "checkpoint_sequence")"
  target_power_state="$(ftctl_dr_runtime_state_get_from_path "${snapshot_path}" "target_power_state")"
  target_promotion_state="$(ftctl_dr_runtime_state_get_from_path "${snapshot_path}" "target_promotion_state")"
  session_id="$(ftctl_dr_runtime_state_get_from_path "${snapshot_path}" "cloud_cutover_session_id")"
  authority_generation="$(ftctl_dr_runtime_state_get_from_path "${snapshot_path}" "cloud_authority_generation")"
  authority_source=""

  if [[ "${active_side}" == "TARGET" && "${authority_state}" == "FAILED_OVER" ]]; then
    authority_source="failover-session"
  else
    active_side="$(ftctl_dr_runtime_state_get_from_path "${prior_status_path}" "active_side")"
    authority_state="$(ftctl_dr_runtime_state_get_from_path "${prior_status_path}" "state")"
    checkpoint_sequence="$(ftctl_dr_runtime_state_get_from_path "${prior_status_path}" "checkpoint_sequence")"
    target_power_state="$(ftctl_dr_runtime_state_get_from_path "${prior_status_path}" "target_power_state")"
    target_promotion_state="$(ftctl_dr_runtime_state_get_from_path "${prior_status_path}" "target_promotion_state")"
    session_id="$(ftctl_dr_runtime_state_get_from_path "${prior_status_path}" "cloud_cutover_session_id")"
    authority_generation="$(ftctl_dr_runtime_state_get_from_path "${prior_status_path}" "cloud_authority_generation")"
    if [[ "${active_side}" == "TARGET" && "${authority_state}" == "FAILED_OVER" ]]; then
      authority_source="status-compat"
    fi
  fi

  if [[ -n "${authority_spec_path}" && -f "${authority_spec_path}" ]]; then
    local expected_side spec_generation spec_checkpoint spec_power spec_promotion spec_session
    expected_side="$(ftctl_dr_runtime_profile_value "${authority_spec_path}" "expectedActiveSide" 2>/dev/null || true)"
    spec_generation="$(ftctl_dr_runtime_profile_value "${authority_spec_path}" "authorityGeneration" 2>/dev/null || true)"
    spec_checkpoint="$(ftctl_dr_runtime_profile_value "${authority_spec_path}" "checkpointSequence" 2>/dev/null || true)"
    spec_power="$(ftctl_dr_runtime_profile_value "${authority_spec_path}" "targetPowerState" 2>/dev/null || true)"
    spec_promotion="$(ftctl_dr_runtime_profile_value "${authority_spec_path}" "targetPromotionState" 2>/dev/null || true)"
    spec_session="$(ftctl_dr_runtime_profile_value "${authority_spec_path}" "cutoverSessionId" 2>/dev/null || true)"
    if [[ -n "${active_side}" && "${active_side}" != "${expected_side}" ]]; then
      rm -f "${snapshot_path}" 2>/dev/null || true
      return 79
    fi
    if [[ -n "${authority_generation}" && -n "${spec_generation}" && "${authority_generation}" != "${spec_generation}" ]]; then
      rm -f "${snapshot_path}" 2>/dev/null || true
      return 79
    fi
    if [[ -n "${checkpoint_sequence}" && -n "${spec_checkpoint}" && "${checkpoint_sequence}" != "${spec_checkpoint}" ]]; then
      rm -f "${snapshot_path}" 2>/dev/null || true
      return 79
    fi
    [[ -n "${active_side}" ]] || active_side="${expected_side}"
    [[ -n "${authority_state}" ]] || authority_state="FAILED_OVER"
    [[ -n "${authority_generation}" ]] || authority_generation="${spec_generation}"
    [[ -n "${checkpoint_sequence}" ]] || checkpoint_sequence="${spec_checkpoint}"
    [[ -n "${target_power_state}" ]] || target_power_state="${spec_power}"
    [[ -n "${target_promotion_state}" ]] || target_promotion_state="${spec_promotion}"
    [[ -n "${session_id}" ]] || session_id="${spec_session}"
    [[ -n "${authority_source}" ]] || authority_source="cloud-command"
  fi
  rm -f "${snapshot_path}" 2>/dev/null || true

  ftctl_dr_runtime_path_set "${run_path}" \
    "authority_source=${authority_source}" \
    "authority_state=${authority_state}" \
    "active_side=${active_side}" \
    "checkpoint_sequence=${checkpoint_sequence}" \
    "target_power_state=${target_power_state}" \
    "target_promotion_state=${target_promotion_state}" \
    "cloud_cutover_session_id=${session_id}" \
    "cloud_authority_generation=${authority_generation}"
}

ftctl_dr_runtime_failback_dir() {
  local plan="${1-}"
  printf '%s/failbacks\n' "$(ftctl_dr_runtime_plan_dir "${plan}")"
}

ftctl_dr_runtime_failback_session_path() {
  local plan="${1-}" run="${2-}"
  printf '%s/%s.json\n' "$(ftctl_dr_runtime_failback_dir "${plan}")" "$(ftctl_dr_runtime_key "${run}")"
}

ftctl_dr_runtime_active_failback_session_path() {
  local plan="${1-}"
  printf '%s/active.json\n' "$(ftctl_dr_runtime_failback_dir "${plan}")"
}

ftctl_dr_runtime_reprotect_dir() {
  local plan="${1-}"
  printf '%s/reprotects\n' "$(ftctl_dr_runtime_plan_dir "${plan}")"
}

ftctl_dr_runtime_reprotect_session_path() {
  local plan="${1-}" run="${2-}"
  printf '%s/%s.json\n' "$(ftctl_dr_runtime_reprotect_dir "${plan}")" "$(ftctl_dr_runtime_key "${run}")"
}

ftctl_dr_runtime_active_reprotect_session_path() {
  local plan="${1-}"
  printf '%s/active.json\n' "$(ftctl_dr_runtime_reprotect_dir "${plan}")"
}

ftctl_dr_runtime_reverse_profile_dir() {
  local plan="${1-}"
  printf '%s/reverse-profiles\n' "$(ftctl_dr_runtime_plan_dir "${plan}")"
}

ftctl_dr_runtime_reverse_profile_path() {
  local plan="${1-}" run="${2-}" phase="${3-reverse}"
  printf '%s/%s-%s.json\n' \
    "$(ftctl_dr_runtime_reverse_profile_dir "${plan}")" \
    "$(ftctl_dr_runtime_key "${run}")" \
    "$(ftctl_dr_runtime_key "${phase}")"
}

ftctl_dr_runtime_reverse_restore_points_path() {
  local plan="${1-}"
  printf '%s/reverse-restore-points.jsonl\n' "$(ftctl_dr_runtime_plan_dir "${plan}")"
}

ftctl_dr_runtime_ensure_plan_dirs() {
  local plan="${1-}"
  ftctl_ensure_dir "$(ftctl_dr_runtime_plan_dir "${plan}")" "0755"
  ftctl_ensure_dir "$(ftctl_dr_runtime_run_dir "${plan}")" "0755"
  ftctl_ensure_dir "$(ftctl_dr_runtime_test_dir "${plan}")" "0755"
  ftctl_ensure_dir "$(ftctl_dr_runtime_failover_dir "${plan}")" "0755"
  ftctl_ensure_dir "$(ftctl_dr_runtime_failback_dir "${plan}")" "0755"
  ftctl_ensure_dir "$(ftctl_dr_runtime_reprotect_dir "${plan}")" "0755"
  ftctl_ensure_dir "$(ftctl_dr_runtime_reverse_profile_dir "${plan}")" "0755"
}

ftctl_dr_runtime_plan_events_path() {
  local plan="${1-}" key
  key="$(ftctl_dr_runtime_key "${plan}")"
  printf '%s/dr-runtime/plans/%s/events.jsonl\n' "${FTCTL_RUN_DIR}" "${key}"
}

ftctl_dr_runtime_events_offset() {
  local plan="${1-}" events_path
  events_path="$(ftctl_dr_runtime_plan_events_path "${plan}")"
  if [[ -f "${events_path}" ]]; then
    wc -l < "${events_path}" | tr -d '[:space:]'
  else
    printf '0\n'
  fi
}

ftctl_dr_runtime_validate_profile_file() {
  local profile_file="${1-}"
  [[ -n "${profile_file}" && -f "${profile_file}" ]] || return 2
  python3 - "${profile_file}" <<'PY' >/dev/null 2>&1
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as fh:
    data = json.load(fh)

if not isinstance(data, dict):
    sys.exit(3)
sys.exit(0)
PY
}

ftctl_dr_runtime_profile_value() {
  local profile_file="${1-}" field="${2-}"
  [[ -n "${profile_file}" && -f "${profile_file}" ]] || return 1
  python3 - "${profile_file}" "${field}" <<'PY' 2>/dev/null
import json
import sys

path, field = sys.argv[1], sys.argv[2]
with open(path, "r", encoding="utf-8") as fh:
    data = json.load(fh)

value = data
for part in field.split("."):
    if isinstance(value, dict) and part in value:
        value = value[part]
    else:
        sys.exit(1)

if value is None:
    sys.exit(1)
if isinstance(value, (dict, list)):
    print(json.dumps(value, separators=(",", ":")))
else:
    print(str(value))
PY
}

ftctl_dr_runtime_json_text_value() {
  local json_text="${1-}" field="${2-}"
  JSON_TEXT="${json_text}" python3 - "${field}" <<'PY' 2>/dev/null
import json
import os
import sys

field = sys.argv[1]
try:
    data = json.loads(os.environ.get("JSON_TEXT", "{}"))
except json.JSONDecodeError:
    sys.exit(1)
value = data
for part in field.split("."):
    if isinstance(value, dict) and part in value:
        value = value[part]
    else:
        print("")
        sys.exit(0)
if isinstance(value, bool):
    print("true" if value else "false")
elif value is None:
    print("")
else:
    print(str(value))
PY
}

ftctl_dr_runtime_redacted_profile_json() {
  local profile_file="${1-}"
  python3 - "${profile_file}" <<'PY'
import json
import sys

SECRET_PARTS = ("password", "secret", "token", "apikey", "api_key", "credential")

def redact(value):
    if isinstance(value, dict):
        out = {}
        for key, item in value.items():
            lower = str(key).lower()
            if any(part in lower for part in SECRET_PARTS):
                out[key] = "REDACTED"
            else:
                out[key] = redact(item)
        return out
    if isinstance(value, list):
        return [redact(item) for item in value]
    return value

with open(sys.argv[1], "r", encoding="utf-8") as fh:
    data = json.load(fh)

print(json.dumps(redact(data), separators=(",", ":"), sort_keys=True))
PY
}

ftctl_dr_runtime_save_credentials() {
  local plan="${1-}" profile_file="${2-}"
  local out_path tmp_path rc=0

  [[ -n "${profile_file}" && -f "${profile_file}" ]] || return 0
  out_path="$(ftctl_dr_runtime_credential_path "${plan}")"
  tmp_path="${out_path}.tmp.$$"
  python3 - "${profile_file}" "${tmp_path}" <<'PY' || rc=$?
import json
import os
import sys

profile_path, out_path = sys.argv[1], sys.argv[2]
with open(profile_path, "r", encoding="utf-8") as fh:
    profile = json.load(fh)
credentials = profile.get("credentials")
if not isinstance(credentials, dict) or not credentials:
    sys.exit(3)
payload = {
    "version": 1,
    "credentials": credentials,
}
with open(out_path, "w", encoding="utf-8") as fh:
    json.dump(payload, fh, sort_keys=True, separators=(",", ":"))
    fh.write("\n")
PY
  if [[ "${rc}" == "3" ]]; then
    rm -f "${tmp_path}" 2>/dev/null || true
    return 0
  fi
  [[ "${rc}" == "0" ]] || {
    rm -f "${tmp_path}" 2>/dev/null || true
    return "${rc}"
  }
  chmod 0600 "${tmp_path}" 2>/dev/null || true
  mv -f "${tmp_path}" "${out_path}"
  chmod 0600 "${out_path}" 2>/dev/null || true
}

ftctl_dr_runtime_save_profile() {
  local plan="${1-}" profile_file="${2-}"
  local redacted

  [[ -n "${profile_file}" ]] || return 0
  ftctl_dr_runtime_validate_profile_file "${profile_file}" || return $?
  ftctl_dr_runtime_ensure_plan_dirs "${plan}"
  ftctl_dr_runtime_save_credentials "${plan}" "${profile_file}" || return $?
  redacted="$(ftctl_dr_runtime_redacted_profile_json "${profile_file}")" || return $?
  ftctl_state_write_json_file "$(ftctl_dr_runtime_profile_path "${plan}")" "${redacted}"
}

ftctl_dr_runtime_save_artifact_spec() {
  local plan="${1-}" run="${2-}" spec_file="${3-}" out_path

  [[ -n "${spec_file}" && -f "${spec_file}" ]] || return 2
  out_path="$(ftctl_dr_runtime_artifact_spec_path "${plan}" "${run}")"
  ftctl_dr_runtime_ensure_plan_dirs "${plan}"
  python3 - "${spec_file}" "${plan}" "${run}" <<'PY' || return $?
import json
import sys

path, plan, run = sys.argv[1:4]
try:
    with open(path, "r", encoding="utf-8") as fh:
        spec = json.load(fh)
except (OSError, ValueError) as exc:
    sys.stderr.write(f"ERROR: invalid artifact spec JSON: {exc}\n")
    sys.exit(53)
if str(spec.get("contractVersion") or "") != "3":
    sys.stderr.write("ERROR: artifact contractVersion 3 is required\n")
    sys.exit(53)
if spec.get("planUuid") != plan or spec.get("runUuid") != run:
    sys.stderr.write("ERROR: artifact spec plan/run correlation mismatch\n")
    sys.exit(53)
disks = spec.get("disks")
if not isinstance(disks, list) or not disks:
    sys.stderr.write("ERROR: artifact spec requires at least one disk\n")
    sys.exit(53)
for index, disk in enumerate(disks):
    if not isinstance(disk, dict):
        sys.stderr.write(f"ERROR: artifact spec disk {index} is invalid\n")
        sys.exit(53)
    provider = str(disk.get("provider") or "").upper()
    locator = str(disk.get("canonicalLocator") or "")
    if provider == "RBD":
        if not locator.startswith("rbd:") or "/" not in locator[4:]:
            sys.stderr.write(f"ERROR: disk {index} requires rbd:pool/image\n")
            sys.exit(53)
    elif provider == "FILE":
        if not locator.startswith("file:/"):
            sys.stderr.write(f"ERROR: disk {index} requires file:/absolute/path\n")
            sys.exit(53)
    else:
        sys.stderr.write(f"ERROR: disk {index} provider {provider} is unsupported\n")
        sys.exit(54)
PY
  ftctl_state_write_json_file "${out_path}" "$(cat "${spec_file}")" || return $?
  chmod 0600 "${out_path}" 2>/dev/null || true
}

ftctl_dr_runtime_save_authority_spec() {
  local plan="${1-}" run="${2-}" spec_file="${3-}" out_path

  [[ -n "${spec_file}" && -f "${spec_file}" ]] || return 2
  out_path="$(ftctl_dr_runtime_authority_spec_path "${plan}" "${run}")"
  ftctl_dr_runtime_ensure_plan_dirs "${plan}"
  python3 - "${spec_file}" "${plan}" "${run}" <<'PY' || return $?
import json
import sys

path, plan, run = sys.argv[1:4]
try:
    with open(path, "r", encoding="utf-8") as fh:
        spec = json.load(fh)
except (OSError, ValueError) as exc:
    sys.stderr.write(f"ERROR: invalid authority spec JSON: {exc}\n")
    sys.exit(79)
if str(spec.get("contractVersion") or "") != "2026-07-23":
    sys.stderr.write("ERROR: authority contractVersion 2026-07-23 is required\n")
    sys.exit(79)
if spec.get("planUuid") != plan or spec.get("runUuid") != run:
    sys.stderr.write("ERROR: authority spec plan/run correlation mismatch\n")
    sys.exit(79)
if str(spec.get("expectedActiveSide") or "").upper() != "TARGET":
    sys.stderr.write("ERROR: authority spec requires TARGET active side\n")
    sys.exit(79)
for key in ("authorityGeneration", "checkpointSequence", "targetVmId"):
    try:
        if int(spec.get(key)) <= 0:
            raise ValueError
    except (TypeError, ValueError):
        sys.stderr.write(f"ERROR: authority spec requires positive {key}\n")
        sys.exit(79)
if not str(spec.get("cutoverSessionId") or "").strip():
    sys.stderr.write("ERROR: authority spec requires cutoverSessionId\n")
    sys.exit(79)
PY
  ftctl_state_write_json_file "${out_path}" "$(cat "${spec_file}")" || return $?
  chmod 0600 "${out_path}" 2>/dev/null || true
}

ftctl_dr_runtime_state_get_from_path() {
  local path="${1-}" key="${2-}"
  if [[ -n "${FTCTL_DR_RUNTIME_STATE_SNAPSHOT_PATH:-}" && "${path}" == "${FTCTL_DR_RUNTIME_STATE_SNAPSHOT_PATH}" ]]; then
    if [[ -n "${FTCTL_DR_RUNTIME_STATE_SNAPSHOT_VALUES[${key}]+x}" ]]; then
      printf '%s\n' "${FTCTL_DR_RUNTIME_STATE_SNAPSHOT_VALUES[${key}]}"
    fi
    return 0
  fi
  ftctl_state_read_kv "${path}" "${key}" 2>/dev/null || true
}

ftctl_dr_runtime_state_snapshot_begin() {
  local path="${1-}" key value
  FTCTL_DR_RUNTIME_STATE_SNAPSHOT_PATH="${path}"
  declare -gA FTCTL_DR_RUNTIME_STATE_SNAPSHOT_VALUES=()
  [[ -n "${path}" && -f "${path}" ]] || return 0
  while IFS='=' read -r key value; do
    [[ -n "${key}" ]] || continue
    FTCTL_DR_RUNTIME_STATE_SNAPSHOT_VALUES["${key}"]="${value}"
  done < "${path}"
}

ftctl_dr_runtime_state_snapshot_end() {
  FTCTL_DR_RUNTIME_STATE_SNAPSHOT_PATH=""
  unset FTCTL_DR_RUNTIME_STATE_SNAPSHOT_VALUES
}

ftctl_dr_runtime_atomic_copy() {
  local source="${1-}" target="${2-}" mode="${3-0644}" dir tmp
  [[ -n "${source}" && -f "${source}" && -n "${target}" ]] || return 1
  dir="$(dirname "${target}")"
  ftctl_ensure_dir "${dir}" "0755"
  tmp="$(mktemp "${dir}/.$(basename "${target}").tmp.XXXXXX")" || return 1
  if ! cp -f -- "${source}" "${tmp}"; then
    rm -f -- "${tmp}"
    return 1
  fi
  chmod "${mode}" "${tmp}" 2>/dev/null || true
  sync -f "${tmp}" 2>/dev/null || true
  if ! mv -f -- "${tmp}" "${target}"; then
    rm -f -- "${tmp}"
    return 1
  fi
  sync -f "${dir}" 2>/dev/null || true
}

ftctl_dr_runtime_path_set() {
  local path="${1-}"
  local dir tmp key value
  shift
  [[ -n "${path}" && -f "${path}" ]] || return 1
  dir="$(dirname "${path}")"
  tmp="$(mktemp "${dir}/.$(basename "${path}").set.XXXXXX")" || return 1
  cp -f "${path}" "${tmp}"
  while (($#)); do
    key="${1%%=*}"
    value="${1#*=}"
    if grep -q "^${key}=" "${tmp}"; then
      sed -i "s#^${key}=.*#${key}=${value}#" "${tmp}"
    else
      printf '%s=%s\n' "${key}" "${value}" >> "${tmp}"
    fi
    shift
  done
  chmod 0644 "${tmp}" 2>/dev/null || true
  sync -f "${tmp}" 2>/dev/null || true
  mv -f "${tmp}" "${path}"
  chmod 0644 "${path}" 2>/dev/null || true
  sync -f "${dir}" 2>/dev/null || true
}

ftctl_dr_runtime_record_lock_conflict() {
  local lock_file="${1-}" command_name="${2-}" holder_pid="${3-}" holder_command="${4-}" holder_age="${5-}" exit_code="${6-20}"
  local plan="${CLI_PLAN:-}" run="${CLI_RUN:-}" run_path status_path now

  [[ "${command_name}" == dr-* && -n "${plan}" && -n "${run}" ]] || return 0
  run_path="$(ftctl_dr_runtime_run_path "${plan}" "${run}")"
  status_path="$(ftctl_dr_runtime_status_path "${plan}")"
  [[ -f "${run_path}" ]] || return 0
  now="$(ftctl_now_iso8601)"
  ftctl_dr_runtime_path_set "${run_path}" \
    "worker_state=RETRYING" \
    "worker_pid=$$" \
    "worker_exit_code=${exit_code}" \
    "worker_updated_at=${now}" \
    "retryable=true" \
    "retry_after_sec=2" \
    "lock_file=${lock_file}" \
    "holder_pid=${holder_pid}" \
    "holder_command=${holder_command}" \
    "holder_age_sec=${holder_age}" \
    "error_code=DR_ENGINE_BUSY_RETRYABLE" \
    "updated_at=${now}" || true
  cp -f "${run_path}" "${status_path}" 2>/dev/null || true
  chmod 0644 "${status_path}" 2>/dev/null || true
}

ftctl_dr_runtime_json_string_field() {
  local key="${1-}" value="${2-}"
  printf ',"%s":"%s"' "${key}" "$(ftctl__json_escape "${value}")"
}

ftctl_dr_runtime_json_number_field() {
  local key="${1-}" value="${2-}"
  if [[ -n "${value}" && "${value}" =~ ^[0-9]+$ ]]; then
    printf ',"%s":%s' "${key}" "${value}"
  else
    printf ',"%s":null' "${key}"
  fi
}

ftctl_dr_runtime_json_boolean_field() {
  local key="${1-}" value="${2-}"
  case "${value,,}" in
    true|1|yes)
      printf ',"%s":true' "${key}"
      ;;
    false|0|no)
      printf ',"%s":false' "${key}"
      ;;
    "")
      return 0
      ;;
    *)
      return 65
      ;;
  esac
}

ftctl_dr_runtime_json_file_field_redacted() {
  local key="${1-}" path="${2-}"
  [[ -n "${key}" && -n "${path}" && -f "${path}" ]] || return 0
  python3 - "${key}" "${path}" <<'PY' || true
import json
import sys

SECRET_PARTS = ("password", "secret", "token", "apikey", "api_key", "credential")

def redact(value):
    if isinstance(value, dict):
        out = {}
        for key, item in value.items():
            lower = str(key).lower()
            if any(part in lower for part in SECRET_PARTS):
                out[key] = "REDACTED"
            else:
                out[key] = redact(item)
        return out
    if isinstance(value, list):
        return [redact(item) for item in value]
    return value

field, path = sys.argv[1], sys.argv[2]
with open(path, "r", encoding="utf-8") as fh:
    data = json.load(fh)
print("," + json.dumps(field, separators=(",", ":")) + ":" + json.dumps(redact(data), sort_keys=True, separators=(",", ":")), end="")
PY
}

ftctl_dr_runtime_rpo_from_target_at() {
  local target_at="${1-}"
  local target_epoch now_epoch
  [[ -n "${target_at}" ]] || return 1
  target_epoch="$(ftctl_iso_to_epoch "${target_at}" 2>/dev/null || true)"
  now_epoch="$(date +%s)"
  [[ "${target_epoch}" =~ ^[0-9]+$ && "${now_epoch}" =~ ^[0-9]+$ && "${now_epoch}" -ge "${target_epoch}" ]] || return 1
  printf '%s\n' "$((now_epoch - target_epoch))"
}

ftctl_dr_runtime_default_restore_points_path() {
  local plan="${1-}" status_path="${2-}" restore_points_path
  restore_points_path="$(ftctl_dr_runtime_state_get_from_path "${status_path}" "restore_points_path")"
  if [[ -z "${restore_points_path}" ]] && command -v ftctl_dr_scheduler_restore_points_path >/dev/null 2>&1; then
    restore_points_path="$(ftctl_dr_scheduler_restore_points_path "${plan}")"
  fi
  printf '%s\n' "${restore_points_path}"
}

ftctl_dr_runtime_profile_bool_default() {
  local profile_file="${1-}" field="${2-}" default_value="${3-}"
  local value
  value="$(ftctl_dr_runtime_profile_value "${profile_file}" "${field}" 2>/dev/null | tr '[:upper:]' '[:lower:]' || true)"
  if [[ -z "${value}" ]]; then
    [[ "${default_value}" == "true" || "${default_value}" == "1" || "${default_value}" == "yes" ]]
    return
  fi
  [[ "${value}" == "true" || "${value}" == "1" || "${value}" == "yes" ]]
}

ftctl_dr_runtime_failover_mode() {
  local mode="${1-}" profile_file="${2-}"
  local request_mode disaster
  request_mode="$(ftctl_dr_runtime_profile_value "${profile_file}" "request.mode" 2>/dev/null | tr '[:upper:]' '[:lower:]' || true)"
  disaster="$(ftctl_dr_runtime_profile_value "${profile_file}" "request.disaster" 2>/dev/null | tr '[:upper:]' '[:lower:]' || true)"
  mode="$(tr '[:upper:]' '[:lower:]' <<< "${mode:-}")"
  if [[ "${mode}" == "disaster" || "${request_mode}" == "disaster" || "${disaster}" == "true" || "${disaster}" == "1" ]]; then
    printf 'disaster\n'
  else
    printf 'planned\n'
  fi
}

ftctl_dr_runtime_failover_next_sequence() {
  local status_path="${1-}" restore_points_path="${2-}" current
  current="$(ftctl_dr_runtime_state_get_from_path "${status_path}" "checkpoint_sequence")"
  if [[ ! "${current}" =~ ^[0-9]+$ && -n "${restore_points_path}" && -f "${restore_points_path}" ]]; then
    current="$(python3 - "${restore_points_path}" <<'PY' 2>/dev/null || true
import json
import sys

latest = 0
with open(sys.argv[1], "r", encoding="utf-8") as fh:
    for line in fh:
        try:
            value = json.loads(line).get("checkpointSequence")
        except Exception:
            continue
        try:
            latest = max(latest, int(value))
        except Exception:
            pass
print(latest)
PY
)"
  fi
  [[ "${current}" =~ ^[0-9]+$ ]] || current="0"
  printf '%s\n' "$((current + 1))"
}

ftctl_dr_runtime_build_reverse_profile() {
  local plan="${1-}" run="${2-}" source_profile="${3-}" out_profile="${4-}" operation="${5-reverse}"

  [[ -n "${source_profile}" && -f "${source_profile}" && -n "${out_profile}" ]] || return 2
  ftctl_ensure_dir "$(dirname "${out_profile}")" "0755"
  python3 - "${plan}" "${run}" "${source_profile}" "${out_profile}" "${operation}" <<'PY'
import copy
import json
import os
import sys

plan, run, source_profile, out_profile, operation = sys.argv[1:6]

with open(source_profile, "r", encoding="utf-8") as fh:
    profile = json.load(fh)

def obj(value):
    return value if isinstance(value, dict) else {}

def arr(value):
    return value if isinstance(value, list) else []

def first_str(*values):
    for value in values:
        if value is None or isinstance(value, (dict, list)):
            continue
        text = str(value).strip()
        if text:
            return text
    return ""

def value_at(data, *keys):
    if not isinstance(data, dict):
        return None
    for key in keys:
        if key in data:
            return data.get(key)
    return None

def reverse_direction(direction):
    normalized = str(direction or "").upper()
    return {
        "KVM_TO_KVM": "KVM_TO_KVM",
        "ABLESTACK_TO_ABLESTACK": "ABLESTACK_TO_ABLESTACK",
        "KVM_TO_VMWARE": "VMWARE_TO_KVM",
        "ABLESTACK_TO_VMWARE": "VMWARE_TO_ABLESTACK",
        "VMWARE_TO_KVM": "KVM_TO_VMWARE",
        "VMWARE_TO_ABLESTACK": "ABLESTACK_TO_VMWARE",
        "VMWARE_TO_VMWARE": "VMWARE_TO_VMWARE",
    }.get(normalized, normalized)

def endpoint_ref(item, endpoint, path_keys, disk_keys, vmdk_keys):
    endpoint_obj = obj(item.get(endpoint))
    return first_str(
        *(value_at(item, key) for key in path_keys),
        *(value_at(endpoint_obj, key) for key in ("path", "diskRef", "disk", "ref", "vmdkPath")),
        *(value_at(item, key) for key in disk_keys),
        *(value_at(item, key) for key in vmdk_keys),
    )

def reverse_disk(item, index):
    item = obj(item)
    source = obj(item.get("source"))
    target = obj(item.get("target"))
    old_source_ref = endpoint_ref(
        item, "source",
        ("sourcePath", "sourceDisk", "sourceRef"),
        ("sourceDiskRef",),
        ("sourceVmdkPath",),
    )
    old_target_ref = endpoint_ref(
        item, "target",
        ("targetPath", "targetDisk", "destination", "dest", "targetRef"),
        ("targetDiskRef",),
        ("targetVmdkPath",),
    )
    reversed_item = copy.deepcopy(item)
    reversed_item["device"] = first_str(
        value_at(item, "device", "targetDevice", "diskTarget", "unitNumber", "key"),
        value_at(source, "device", "targetDevice", "unitNumber", "key"),
        value_at(target, "device", "targetDevice", "unitNumber", "key"),
        f"disk{index}",
    )
    reversed_item["source"] = copy.deepcopy(target)
    reversed_item["target"] = copy.deepcopy(source)
    reversed_item["sourcePath"] = old_target_ref
    reversed_item["targetPath"] = old_source_ref
    reversed_item["sourceDiskRef"] = first_str(value_at(item, "targetDiskRef"), old_target_ref)
    reversed_item["targetDiskRef"] = first_str(value_at(item, "sourceDiskRef"), old_source_ref)
    reversed_item["sourceVmdkPath"] = first_str(value_at(item, "targetVmdkPath"), old_target_ref)
    reversed_item["targetVmdkPath"] = first_str(value_at(item, "sourceVmdkPath"), old_source_ref)
    reversed_item["sourceFormat"] = first_str(value_at(item, "targetFormat"), value_at(target, "format"), value_at(item, "format"))
    reversed_item["targetFormat"] = first_str(value_at(item, "sourceFormat"), value_at(source, "format"), value_at(item, "format"))
    if "targetType" in item:
        reversed_item["sourceType"] = item.get("targetType")
    if "sourceType" in item:
        reversed_item["targetType"] = item.get("sourceType")
    if "changeId" in reversed_item:
        reversed_item.pop("changeId", None)
    if "snapshotRef" in reversed_item:
        reversed_item.pop("snapshotRef", None)
    return reversed_item

def disk_items_from(profile):
    mapping = obj(profile.get("mapping"))
    for key in ("disks", "diskMappings", "volumes", "volumeMappings"):
        values = arr(mapping.get(key))
        if values:
            return key, values
    for key in ("disks", "diskMappings", "volumes"):
        values = arr(profile.get(key))
        if values:
            return key, values
    return "disks", []

source = obj(profile.get("source"))
target = obj(profile.get("target"))
mapping = copy.deepcopy(obj(profile.get("mapping")))
disk_key, disk_items = disk_items_from(profile)
reversed_disks = [reverse_disk(item, index) for index, item in enumerate(disk_items)]

reverse = copy.deepcopy(profile)
reverse["planUuid"] = plan or profile.get("planUuid", "")
reverse["runUuid"] = run or profile.get("runUuid", "")
reverse["direction"] = reverse_direction(profile.get("direction"))
reverse["source"] = copy.deepcopy(target)
reverse["target"] = copy.deepcopy(source)
reverse["originalDirection"] = profile.get("direction", "")
reverse["reverseDirection"] = reverse["direction"]
reverse["reverseOf"] = {
    "planUuid": profile.get("planUuid", ""),
    "runUuid": profile.get("runUuid", ""),
    "operation": operation,
}
request = copy.deepcopy(obj(profile.get("request")))
request["operation"] = operation
request["reverse"] = True
reverse["request"] = request
mapping[disk_key] = reversed_disks
reverse["mapping"] = mapping

tmp = out_profile + ".tmp"
with open(tmp, "w", encoding="utf-8") as fh:
    json.dump(reverse, fh, sort_keys=True, separators=(",", ":"))
    fh.write("\n")
os.replace(tmp, out_profile)
PY
}

ftctl_dr_runtime_reverse_checkpoint() {
  local plan="${1-}" run="${2-}" profile_file="${3-}" run_path="${4-}" status_path="${5-}" cycle_type="${6-reverse-sync}" phase="${7-reverse}"
  local restore_points_path sequence output rc=0 manifest_path checkpoint_path
  local source_at target_at rpo source_provider target_provider driver now

  command -v ftctl_dr_scheduler_run_cycle >/dev/null 2>&1 || return 0
  restore_points_path="$(ftctl_dr_runtime_reverse_restore_points_path "${plan}")"
  sequence="$(ftctl_dr_runtime_failover_next_sequence "${status_path}" "${restore_points_path}")"
  now="$(ftctl_now_iso8601)"
  ftctl_dr_runtime_path_set "${run_path}" \
    "state=RUNNING" \
    "step=${phase}-transfer" \
    "progress=55" \
    "checkpoint_sequence=${sequence}" \
    "reverse_restore_points_path=${restore_points_path}" \
    "updated_at=${now}" || true
  cp -f "${run_path}" "${status_path}" 2>/dev/null || true

  output="$(ftctl_dr_scheduler_run_cycle "${plan}" "${run}-${phase}" "${profile_file}" "${sequence}" "${cycle_type}")" || rc=$?
  [[ "${rc}" == "0" ]] || return "${rc}"
  manifest_path="$(awk -F '\t' 'NF >= 2 {print $1; exit}' <<< "${output}")"
  checkpoint_path="$(awk -F '\t' 'NF >= 2 {print $2; exit}' <<< "${output}")"
  source_at="$(ftctl_dr_scheduler_checkpoint_value "${checkpoint_path}" "sourceCheckpointAt" || true)"
  target_at="$(ftctl_dr_scheduler_checkpoint_value "${checkpoint_path}" "targetDurableAt" || true)"
  rpo="$(ftctl_dr_scheduler_checkpoint_value "${checkpoint_path}" "targetReadyRpoSeconds" || true)"
  source_provider="$(ftctl_dr_scheduler_profile_provider "${profile_file}" source)"
  target_provider="$(ftctl_dr_scheduler_profile_provider "${profile_file}" target)"
  driver="$(ftctl_dr_scheduler_driver_name "${source_provider}" "${target_provider}")"
  ftctl_dr_scheduler_append_restore_point "${restore_points_path}" "${plan}" "${run}-${phase}" "${sequence}" "${cycle_type}" "${driver}" "${manifest_path}" "${checkpoint_path}" || return $?
  now="$(ftctl_now_iso8601)"
  ftctl_dr_runtime_path_set "${run_path}" \
    "state=RUNNING" \
    "step=${phase}-target-ready" \
    "progress=80" \
    "scheduler_state=REVERSE_CHECKPOINT" \
    "driver=${driver}" \
    "driver_state=CHECKPOINT_READY" \
    "checkpoint_sequence=${sequence}" \
    "manifest_path=${manifest_path}" \
    "checkpoint_path=${checkpoint_path}" \
    "reverse_restore_points_path=${restore_points_path}" \
    "last_source_checkpoint_at=${source_at}" \
    "last_target_durable_at=${target_at}" \
    "target_ready_rpo_seconds=${rpo}" \
    "updated_at=${now}" || true
  cp -f "${run_path}" "${status_path}" 2>/dev/null || true
}

ftctl_dr_runtime_failover_final_checkpoint() {
  local plan="${1-}" run="${2-}" profile_file="${3-}" run_path="${4-}" status_path="${5-}"
  local restore_points_path sequence cycle_type output rc=0 manifest_path checkpoint_path
  local source_at target_at rpo source_provider target_provider driver now

  command -v ftctl_dr_scheduler_run_cycle >/dev/null 2>&1 || return 0
  restore_points_path="$(ftctl_dr_runtime_default_restore_points_path "${plan}" "${status_path}")"
  [[ -n "${restore_points_path}" ]] || return 0
  sequence="$(ftctl_dr_runtime_failover_next_sequence "${status_path}" "${restore_points_path}")"
  cycle_type="failover-final"
  now="$(ftctl_now_iso8601)"
  ftctl_dr_runtime_path_set "${run_path}" \
    "state=RUNNING" \
    "step=final-delta-capture" \
    "progress=45" \
    "checkpoint_sequence=${sequence}" \
    "updated_at=${now}" || true
  cp -f "${run_path}" "${status_path}" 2>/dev/null || true

  output="$(ftctl_dr_scheduler_run_cycle "${plan}" "${run}-final" "${profile_file}" "${sequence}" "${cycle_type}")" || rc=$?
  if [[ "${rc}" != "0" ]]; then
    case "${rc}" in
      65) return 65 ;;
      66) return 66 ;;
      *) return 67 ;;
    esac
  fi

  manifest_path="$(awk -F '\t' 'NF >= 2 {print $1; exit}' <<< "${output}")"
  checkpoint_path="$(awk -F '\t' 'NF >= 2 {print $2; exit}' <<< "${output}")"
  source_at="$(ftctl_dr_scheduler_checkpoint_value "${checkpoint_path}" "sourceCheckpointAt" || true)"
  target_at="$(ftctl_dr_scheduler_checkpoint_value "${checkpoint_path}" "targetDurableAt" || true)"
  rpo="$(ftctl_dr_scheduler_checkpoint_value "${checkpoint_path}" "targetReadyRpoSeconds" || true)"
  source_provider="$(ftctl_dr_scheduler_profile_provider "${profile_file}" source)"
  target_provider="$(ftctl_dr_scheduler_profile_provider "${profile_file}" target)"
  driver="$(ftctl_dr_scheduler_driver_name "${source_provider}" "${target_provider}")"
  ftctl_dr_scheduler_append_restore_point "${restore_points_path}" "${plan}" "${run}" "${sequence}" "${cycle_type}" "${driver}" "${manifest_path}" "${checkpoint_path}" || return $?
  now="$(ftctl_now_iso8601)"
  ftctl_dr_runtime_path_set "${run_path}" \
    "state=RUNNING" \
    "step=final-delta-apply" \
    "progress=70" \
    "driver=${driver}" \
    "driver_state=CHECKPOINT_READY" \
    "checkpoint_sequence=${sequence}" \
    "manifest_path=${manifest_path}" \
    "checkpoint_path=${checkpoint_path}" \
    "restore_points_path=${restore_points_path}" \
    "last_source_checkpoint_at=${source_at}" \
    "last_target_durable_at=${target_at}" \
    "target_ready_rpo_seconds=${rpo}" \
    "updated_at=${now}" || true
  cp -f "${run_path}" "${status_path}" 2>/dev/null || true
}

ftctl_dr_runtime_prepare_test_session() {
  local plan="${1-}" run="${2-}" profile_file="${3-}" restore_point="${4-}" run_path="${5-}" status_path="${6-}"
  local session_path active_path selection_path restore_points_path profile_path
  local test_session_id test_restore_point_ref test_restore_point_sequence test_manifest_path test_checkpoint_path
  local last_source last_target target_rpo now rc=0

  ftctl_dr_runtime_ensure_plan_dirs "${plan}"
  session_path="$(ftctl_dr_runtime_test_session_path "${plan}" "${run}")"
  active_path="$(ftctl_dr_runtime_active_test_session_path "${plan}")"
  selection_path="$(mktemp -t ftctl.dr.test.selection.XXXXXX)"
  restore_points_path="$(ftctl_dr_runtime_default_restore_points_path "${plan}" "${status_path}")"
  profile_path="${profile_file}"
  [[ -n "${profile_path}" && -f "${profile_path}" ]] || profile_path="$(ftctl_dr_runtime_profile_path "${plan}")"
  now="$(ftctl_now_iso8601)"

  python3 - "${plan}" "${run}" "${profile_path}" "${restore_point}" "${status_path}" \
    "${restore_points_path}" "${session_path}" "${active_path}" "${selection_path}" "${now}" <<'PY' || rc=$?
import json
import os
import shutil
import sys

plan, run, profile_path, restore_selector, status_path, restore_points_path, session_path, active_path, selection_path, now = sys.argv[1:11]

def read_state(path):
    values = {}
    if path and os.path.exists(path):
        with open(path, "r", encoding="utf-8") as fh:
            for line in fh:
                line = line.rstrip("\n")
                if "=" in line:
                    key, value = line.split("=", 1)
                    values[key] = value
    return values

def read_json(path):
    if path and os.path.exists(path):
        with open(path, "r", encoding="utf-8") as fh:
            return json.load(fh)
    return {}

def read_restore_points(path):
    records = []
    if not path or not os.path.exists(path):
        return records
    with open(path, "r", encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                data = json.loads(line)
            except json.JSONDecodeError:
                continue
            if isinstance(data, dict):
                records.append(data)
    return records

def record_ref(record):
    explicit = record.get("checkpointRef") or record.get("sourceSnapshotRef") or record.get("restorePointRef")
    if explicit:
        return str(explicit)
    sequence = record.get("checkpointSequence")
    if sequence is not None:
        return f"ftctl:{plan}:{record.get('runUuid') or run}:{sequence}"
    checkpoint = record.get("checkpoint")
    if checkpoint:
        return str(checkpoint)
    return f"ftctl:{plan}:latest"

def record_sequence(record):
    sequence = record.get("checkpointSequence")
    if sequence is None:
        return None
    try:
        return int(sequence)
    except (TypeError, ValueError):
        return sequence

def matches(record, selector):
    if not selector:
        return False
    candidates = {
        record_ref(record),
        f"ftctl:{plan}:{record.get('checkpointSequence', '')}",
        str(record.get("checkpointSequence", "")),
        str(record.get("checkpoint", "")),
        str(record.get("manifest", "")),
        str(record.get("sourceSnapshotRef", "")),
        str(record.get("restorePointRef", "")),
        str(record.get("checkpointRef", "")),
    }
    return str(selector) in candidates

state = read_state(status_path)
profile = read_json(profile_path)
request = profile.get("request") if isinstance(profile.get("request"), dict) else {}
selector = restore_selector or request.get("restorePointRef") or request.get("restorePointId") or ""
records = read_restore_points(restore_points_path)
selected = None
if selector:
    selected = next((record for record in records if matches(record, str(selector))), None)
    if selected is None:
        sys.stderr.write(f"ERROR: restore point {selector} was not found\n")
        sys.exit(44)
elif records:
    selected = records[-1]

if selected is None:
    sequence = state.get("checkpoint_sequence")
    checkpoint_path = state.get("checkpoint_path")
    manifest_path = state.get("manifest_path")
    last_target = state.get("last_target_durable_at")
    if not (sequence or checkpoint_path or manifest_path or last_target):
        sys.stderr.write("ERROR: no target-ready restore point is available\n")
        sys.exit(45)
    selected = {
        "planUuid": plan,
        "runUuid": state.get("run"),
        "checkpointSequence": int(sequence) if str(sequence).isdigit() else sequence,
        "manifest": manifest_path,
        "checkpoint": checkpoint_path,
        "sourceCheckpointAt": state.get("last_source_checkpoint_at"),
        "targetDurableAt": last_target,
        "targetReadyRpoSeconds": state.get("target_ready_rpo_seconds"),
        "state": state.get("state"),
        "recordedAt": state.get("updated_at"),
    }

checkpoint = read_json(selected.get("checkpoint"))
source_at = selected.get("sourceCheckpointAt") or checkpoint.get("sourceCheckpointAt") or state.get("last_source_checkpoint_at")
target_at = selected.get("targetDurableAt") or checkpoint.get("targetDurableAt") or state.get("last_target_durable_at")
target_rpo = selected.get("targetReadyRpoSeconds") or checkpoint.get("targetReadyRpoSeconds") or state.get("target_ready_rpo_seconds")
manifest_path = selected.get("manifest") or state.get("manifest_path")
checkpoint_path = selected.get("checkpoint") or state.get("checkpoint_path")
session_id = f"{plan}:{run}"
restore_ref = record_ref(selected)
session = {
    "version": 1,
    "planUuid": plan,
    "runUuid": run,
    "sessionId": session_id,
    "state": "READY",
    "mode": "test-failover",
    "networkMode": request.get("networkMode", "isolated"),
    "startedAt": now,
    "restorePoint": {
        "ref": restore_ref,
        "checkpointSequence": record_sequence(selected),
        "manifest": manifest_path,
        "checkpoint": checkpoint_path,
        "sourceCheckpointAt": source_at,
        "targetDurableAt": target_at,
        "targetReadyRpoSeconds": target_rpo,
    },
    "profile": {
        "direction": profile.get("direction"),
        "source": profile.get("source"),
        "target": profile.get("target"),
        "mapping": profile.get("mapping"),
        "policy": profile.get("policy"),
    },
    "request": request,
    "checkpoint": checkpoint,
}
os.makedirs(os.path.dirname(session_path), exist_ok=True)
with open(session_path, "w", encoding="utf-8") as fh:
    json.dump(session, fh, sort_keys=True, separators=(",", ":"))
    fh.write("\n")
shutil.copyfile(session_path, active_path)
with open(selection_path, "w", encoding="utf-8") as fh:
    fh.write(f"test_session_id={session_id}\n")
    fh.write("test_session_state=READY\n")
    fh.write(f"test_restore_point_ref={restore_ref}\n")
    sequence = record_sequence(selected)
    fh.write(f"test_restore_point_sequence={'' if sequence is None else sequence}\n")
    fh.write(f"test_manifest_path={manifest_path or ''}\n")
    fh.write(f"test_checkpoint_path={checkpoint_path or ''}\n")
    fh.write(f"last_source_checkpoint_at={source_at or ''}\n")
    fh.write(f"last_target_durable_at={target_at or ''}\n")
    fh.write(f"target_ready_rpo_seconds={target_rpo or ''}\n")
    fh.write(f"restore_points_path={restore_points_path or ''}\n")
PY
  if [[ "${rc}" != "0" ]]; then
    rm -f "${selection_path}" 2>/dev/null || true
    return "${rc}"
  fi

  test_session_id="$(ftctl_dr_runtime_state_get_from_path "${selection_path}" "test_session_id")"
  test_restore_point_ref="$(ftctl_dr_runtime_state_get_from_path "${selection_path}" "test_restore_point_ref")"
  test_restore_point_sequence="$(ftctl_dr_runtime_state_get_from_path "${selection_path}" "test_restore_point_sequence")"
  test_manifest_path="$(ftctl_dr_runtime_state_get_from_path "${selection_path}" "test_manifest_path")"
  test_checkpoint_path="$(ftctl_dr_runtime_state_get_from_path "${selection_path}" "test_checkpoint_path")"
  last_source="$(ftctl_dr_runtime_state_get_from_path "${selection_path}" "last_source_checkpoint_at")"
  last_target="$(ftctl_dr_runtime_state_get_from_path "${selection_path}" "last_target_durable_at")"
  target_rpo="$(ftctl_dr_runtime_state_get_from_path "${selection_path}" "target_ready_rpo_seconds")"
  restore_points_path="$(ftctl_dr_runtime_state_get_from_path "${selection_path}" "restore_points_path")"
  rm -f "${selection_path}" 2>/dev/null || true

  ftctl_dr_runtime_path_set "${run_path}" \
    "state=TESTING" \
    "step=test-session-ready" \
    "progress=100" \
    "test_session_id=${test_session_id}" \
    "test_session_path=${session_path}" \
    "test_session_state=READY" \
    "test_restore_point_ref=${test_restore_point_ref}" \
    "test_restore_point_sequence=${test_restore_point_sequence}" \
    "test_manifest_path=${test_manifest_path}" \
    "test_checkpoint_path=${test_checkpoint_path}" \
    "last_source_checkpoint_at=${last_source}" \
    "last_target_durable_at=${last_target}" \
    "target_ready_rpo_seconds=${target_rpo}" \
    "restore_points_path=${restore_points_path}" \
    "updated_at=${now}"
}

ftctl_dr_runtime_cleanup_test_session() {
  local plan="${1-}" run="${2-}" run_path="${3-}" status_path="${4-}"
  local active_path session_path selection_path now rc=0
  local test_session_id test_restore_point_ref test_restore_point_sequence test_manifest_path test_checkpoint_path
  local last_source last_target target_rpo restore_points_path test_artifacts_state test_artifacts_path test_artifact_count

  ftctl_dr_runtime_ensure_plan_dirs "${plan}"
  active_path="$(ftctl_dr_runtime_active_test_session_path "${plan}")"
  session_path="$(ftctl_dr_runtime_test_session_path "${plan}" "${run}")"
  selection_path="$(mktemp -t ftctl.dr.test.cleanup.XXXXXX)"
  now="$(ftctl_now_iso8601)"
  python3 - "${plan}" "${run}" "${active_path}" "${session_path}" "${selection_path}" "${now}" <<'PY' || rc=$?
import json
import os
import shutil
import subprocess
import sys

plan, run, active_path, session_path, selection_path, now = sys.argv[1:7]
session = {}
if os.path.exists(active_path):
    with open(active_path, "r", encoding="utf-8") as fh:
        session = json.load(fh)
restore = session.get("restorePoint") if isinstance(session.get("restorePoint"), dict) else {}
artifacts = session.get("testArtifacts") if isinstance(session.get("testArtifacts"), dict) else {}
artifact_path = artifacts.get("path") if isinstance(artifacts, dict) else ""
test_domain = session.get("testDomain") if isinstance(session.get("testDomain"), dict) else {}
domain_name = test_domain.get("name") if isinstance(test_domain, dict) else ""
if domain_name:
    subprocess.run(["virsh", "destroy", str(domain_name)], check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    subprocess.run(["virsh", "undefine", str(domain_name), "--nvram"], check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    subprocess.run(["virsh", "undefine", str(domain_name)], check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
for record in artifacts.get("records", []) if isinstance(artifacts, dict) else []:
    if not isinstance(record, dict) or record.get("type") != "rbd-clone":
        continue
    mapped = record.get("mappedDevice")
    clone = str(record.get("clone") or "")
    backing = str(record.get("backing") or "")
    snapshot = str(record.get("snapshot") or "")
    if mapped:
        subprocess.run(["rbd", "unmap", str(mapped)], check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    manifest_path = session.get("guestPreparation", {}).get("manifest") if isinstance(session.get("guestPreparation"), dict) else None
    if manifest_path and os.path.exists(manifest_path):
        try:
            manifest = json.load(open(manifest_path, "r", encoding="utf-8"))
            runtime = manifest.get("runtime") if isinstance(manifest.get("runtime"), dict) else {}
            rbd_runtime = runtime.get("rbd") if isinstance(runtime.get("rbd"), dict) else {}
            for device in rbd_runtime.get("mapped", []) if isinstance(rbd_runtime.get("mapped"), list) else []:
                if device:
                    subprocess.run(["rbd", "unmap", str(device)], check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        except (OSError, ValueError, TypeError):
            pass
    if clone.startswith("rbd:"):
        subprocess.run(["rbd", "rm", clone[4:]], check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if backing.startswith("rbd:") and snapshot:
        snap_ref = backing[4:] + "@" + snapshot
        subprocess.run(["rbd", "snap", "unprotect", snap_ref], check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        subprocess.run(["rbd", "snap", "rm", snap_ref], check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
session_id = session.get("sessionId") or f"{plan}:{run}"
session["state"] = "CLEANED"
session["cleanupRunUuid"] = run
session["completedAt"] = now
if artifact_path:
    artifact_abs = os.path.abspath(artifact_path)
    session_root = os.path.abspath(os.path.dirname(active_path))
    if artifact_abs.startswith(session_root + os.sep) and os.path.isdir(artifact_abs):
        shutil.rmtree(artifact_abs)
        artifacts["state"] = "CLEANED"
        artifacts["cleanedAt"] = now
        session["testArtifacts"] = artifacts
os.makedirs(os.path.dirname(session_path), exist_ok=True)
with open(session_path, "w", encoding="utf-8") as fh:
    json.dump(session, fh, sort_keys=True, separators=(",", ":"))
    fh.write("\n")
if os.path.exists(active_path):
    os.unlink(active_path)
with open(selection_path, "w", encoding="utf-8") as fh:
    fh.write(f"test_session_id={session_id}\n")
    fh.write("test_session_state=CLEANED\n")
    fh.write(f"test_restore_point_ref={restore.get('ref', '')}\n")
    sequence = restore.get("checkpointSequence")
    fh.write(f"test_restore_point_sequence={'' if sequence is None else sequence}\n")
    fh.write(f"test_manifest_path={restore.get('manifest', '') or ''}\n")
    fh.write(f"test_checkpoint_path={restore.get('checkpoint', '') or ''}\n")
    fh.write(f"last_source_checkpoint_at={restore.get('sourceCheckpointAt', '') or ''}\n")
    fh.write(f"last_target_durable_at={restore.get('targetDurableAt', '') or ''}\n")
    fh.write(f"target_ready_rpo_seconds={restore.get('targetReadyRpoSeconds', '') or ''}\n")
    fh.write(f"test_artifacts_state={artifacts.get('state', '') if isinstance(artifacts, dict) else ''}\n")
    fh.write(f"test_artifacts_path={artifact_path or ''}\n")
    fh.write(f"test_artifact_count={artifacts.get('count', '') if isinstance(artifacts, dict) else ''}\n")
PY
  [[ "${rc}" == "0" ]] || {
    rm -f "${selection_path}" 2>/dev/null || true
    return "${rc}"
  }

  test_session_id="$(ftctl_dr_runtime_state_get_from_path "${selection_path}" "test_session_id")"
  test_restore_point_ref="$(ftctl_dr_runtime_state_get_from_path "${selection_path}" "test_restore_point_ref")"
  test_restore_point_sequence="$(ftctl_dr_runtime_state_get_from_path "${selection_path}" "test_restore_point_sequence")"
  test_manifest_path="$(ftctl_dr_runtime_state_get_from_path "${selection_path}" "test_manifest_path")"
  test_checkpoint_path="$(ftctl_dr_runtime_state_get_from_path "${selection_path}" "test_checkpoint_path")"
  last_source="$(ftctl_dr_runtime_state_get_from_path "${selection_path}" "last_source_checkpoint_at")"
  last_target="$(ftctl_dr_runtime_state_get_from_path "${selection_path}" "last_target_durable_at")"
  target_rpo="$(ftctl_dr_runtime_state_get_from_path "${selection_path}" "target_ready_rpo_seconds")"
  test_artifacts_state="$(ftctl_dr_runtime_state_get_from_path "${selection_path}" "test_artifacts_state")"
  test_artifacts_path="$(ftctl_dr_runtime_state_get_from_path "${selection_path}" "test_artifacts_path")"
  test_artifact_count="$(ftctl_dr_runtime_state_get_from_path "${selection_path}" "test_artifact_count")"
  restore_points_path="$(ftctl_dr_runtime_default_restore_points_path "${plan}" "${status_path}")"
  rm -f "${selection_path}" 2>/dev/null || true
  rm -f "$(ftctl_dr_runtime_artifact_spec_path "${plan}" "${run}")" 2>/dev/null || true

  ftctl_dr_runtime_path_set "${run_path}" \
    "state=READY" \
    "step=test-cleanup-completed" \
    "progress=100" \
    "test_session_id=${test_session_id}" \
    "test_session_state=CLEANED" \
    "test_restore_point_ref=${test_restore_point_ref}" \
    "test_restore_point_sequence=${test_restore_point_sequence}" \
    "test_manifest_path=${test_manifest_path}" \
    "test_checkpoint_path=${test_checkpoint_path}" \
    "last_source_checkpoint_at=${last_source}" \
    "last_target_durable_at=${last_target}" \
    "target_ready_rpo_seconds=${target_rpo}" \
    "restore_points_path=${restore_points_path}" \
    "test_artifacts_state=${test_artifacts_state}" \
    "test_artifacts_path=${test_artifacts_path}" \
    "test_artifact_count=${test_artifact_count}" \
    "updated_at=${now}"
}

ftctl_dr_runtime_materialize_test_artifacts() {
  local plan="${1-}" run="${2-}" session_path="${3-}" run_path="${4-}" artifact_spec_path="${5-}"
  local artifacts_dir artifacts_state_path rc=0
  local test_artifacts_state test_artifacts_path test_artifact_count artifact_error_code artifact_error_message

  artifacts_dir="$(ftctl_dr_runtime_test_artifacts_dir "${plan}" "${run}")"
  artifacts_state_path="$(mktemp -t ftctl.dr.test.artifacts.XXXXXX)"
  python3 - "${session_path}" "${artifacts_dir}" "${artifacts_state_path}" "$(ftctl_now_iso8601)" "${artifact_spec_path}" <<'PY' || rc=$?
import json
import os
import shutil
import subprocess
import sys

session_path, artifacts_dir, state_path, now, artifact_spec_path = sys.argv[1:6]
with open(session_path, "r", encoding="utf-8") as fh:
    session = json.load(fh)
try:
    with open(artifact_spec_path, "r", encoding="utf-8") as fh:
        artifact_spec = json.load(fh)
except (OSError, ValueError) as exc:
    sys.stderr.write(f"ERROR: unable to read artifact locator contract: {exc}\n")
    sys.exit(53)
if str(artifact_spec.get("contractVersion") or "") != "3":
    sys.stderr.write("ERROR: artifact contractVersion 3 is required\n")
    sys.exit(53)

profile = session.get("profile") if isinstance(session.get("profile"), dict) else {}
target = profile.get("target") if isinstance(profile.get("target"), dict) else {}
disks = artifact_spec.get("disks") if isinstance(artifact_spec.get("disks"), list) else []
target_provider = str(target.get("provider") or "").upper()
records = []
state = "NO_DISKS"
os.makedirs(artifacts_dir, exist_ok=True)

def rbd_spec(value):
    text = str(value or "")
    if text.startswith("rbd:"):
        return text[4:]
    if text.startswith("/dev/rbd/"):
        return text[len("/dev/rbd/"):]
    return ""

def safe_key(value):
    return "".join(ch if ch.isalnum() else "-" for ch in str(value)).strip("-")[:36]

def cleanup_records():
    for record in reversed(records):
        if not isinstance(record, dict):
            continue
        if record.get("type") == "rbd-clone":
            clone = str(record.get("clone") or "")
            backing = str(record.get("backing") or "")
            snapshot = str(record.get("snapshot") or "")
            if clone.startswith("rbd:"):
                subprocess.run(["rbd", "rm", clone[4:]], check=False,
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            if backing.startswith("rbd:") and snapshot:
                snap_ref = backing[4:] + "@" + snapshot
                subprocess.run(["rbd", "snap", "unprotect", snap_ref], check=False,
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                subprocess.run(["rbd", "snap", "rm", snap_ref], check=False,
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        path = str(record.get("path") or "")
        if record.get("type") == "qcow2-overlay" and path and os.path.isfile(path):
            os.unlink(path)

def fail(code, message):
    cleanup_records()
    session["testArtifacts"] = {
        "state": "FAILED",
        "path": artifacts_dir,
        "count": 0,
        "records": records,
        "errorCode": "DR_TEST_ARTIFACT_LOCATOR_INVALID" if code == 53 else "DR_TEST_ARTIFACT_PROVIDER_UNSUPPORTED" if code == 54 else "DR_TEST_MATERIALIZATION_FAILED",
        "errorMessage": message,
        "updatedAt": now,
    }
    with open(session_path, "w", encoding="utf-8") as fh:
        json.dump(session, fh, sort_keys=True, separators=(",", ":"))
        fh.write("\n")
    with open(state_path, "w", encoding="utf-8") as fh:
        fh.write("test_artifacts_state=FAILED\n")
        fh.write("test_artifacts_path=\n")
        fh.write("test_artifact_count=0\n")
        fh.write(f"artifact_error_code={session['testArtifacts']['errorCode']}\n")
        fh.write(f"artifact_error_message={message.replace(chr(10), ' ')}\n")
    sys.stderr.write(f"ERROR: {message}\n")
    sys.exit(code)

if target_provider == "VMWARE":
    state = "METADATA_ONLY"
else:
    qemu_img = shutil.which("qemu-img")
    for index, disk in enumerate(disks):
        if not isinstance(disk, dict):
            fail(53, f"artifact disk {index} is not an object")
        provider = str(disk.get("provider") or "").upper()
        locator = str(disk.get("canonicalLocator") or "")
        device = str(disk.get("device") or f"disk{index}").replace("/", "_").replace(" ", "_")
        target_format = str(disk.get("targetFormat") or disk.get("format") or "qcow2")
        if provider == "RBD":
            source_rbd = rbd_spec(locator)
            if shutil.which("rbd") is None:
                fail(46, "rbd is required to create ABLESTACK test clones")
            if "/" not in source_rbd:
                fail(53, f"invalid RBD locator {locator}; expected rbd:pool/image")
            pool, image = source_rbd.split("/", 1)
            suffix = safe_key(session.get("runUuid") or now)
            snapshot = f"ftctl-dr-test-{suffix}"
            clone_image = f"{image}-ftctl-test-{suffix}"
            clone_spec = f"{pool}/{clone_image}"
            snap_spec = f"{source_rbd}@{snapshot}"
            try:
                subprocess.run(["rbd", "info", source_rbd], check=True,
                               stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
                subprocess.run(["rbd", "snap", "create", snap_spec], check=True)
                records.append({
                    "device": disk.get("device") or f"disk{index}",
                    "state": "CREATING",
                    "type": "rbd-clone",
                    "backing": f"rbd:{source_rbd}",
                    "snapshot": snapshot,
                    "clone": f"rbd:{clone_spec}",
                    "path": f"rbd:{clone_spec}",
                    "sizeBytes": disk.get("sizeBytes") or disk.get("capacityBytes") or 0,
                })
                subprocess.run(["rbd", "snap", "protect", snap_spec], check=True)
                subprocess.run(["rbd", "clone", snap_spec, clone_spec], check=True)
                records[-1]["state"] = "CREATED"
            except subprocess.CalledProcessError as exc:
                stderr = (exc.stderr or "").strip() if isinstance(exc.stderr, str) else ""
                fail(46, f"RBD test clone failed for {source_rbd}: {stderr or exc}")
            continue
        if provider == "FILE":
            if not locator.startswith("file:/"):
                fail(53, f"invalid file locator {locator}; expected file:/absolute/path")
            target_path = locator[5:]
            if not os.path.isabs(target_path) or not os.path.isfile(target_path):
                fail(53, f"file-backed target does not exist: {target_path}")
            if not qemu_img:
                fail(46, "qemu-img is required to create ABLESTACK test overlays")
            overlay_path = os.path.join(artifacts_dir, f"{device}.qcow2")
            command = [qemu_img, "create", "-f", "qcow2", "-F", target_format, "-b", target_path, overlay_path]
            try:
                subprocess.run([qemu_img, "info", target_path], check=True,
                               stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
                subprocess.run(command, check=True)
            except subprocess.CalledProcessError as exc:
                stderr = (exc.stderr or "").strip() if isinstance(exc.stderr, str) else ""
                fail(46, f"file-backed test overlay failed for {target_path}: {stderr or exc}")
            records.append({
                "device": disk.get("device") or f"disk{index}",
                "state": "CREATED",
                "type": "qcow2-overlay",
                "backing": target_path,
                "path": overlay_path,
                "sizeBytes": disk.get("sizeBytes") or disk.get("capacityBytes") or 0,
                "command": command,
            })
            continue
        fail(54, f"unsupported test artifact provider {provider} for disk {index}")
    state = "CREATED" if any(record.get("state") == "CREATED" for record in records) else "NO_MATERIALIZED_DISKS"

session["testArtifacts"] = {
    "state": state,
    "path": artifacts_dir,
    "count": len([record for record in records if record.get("state") == "CREATED"]),
    "records": records,
    "updatedAt": now,
}
with open(session_path, "w", encoding="utf-8") as fh:
    json.dump(session, fh, sort_keys=True, separators=(",", ":"))
    fh.write("\n")
with open(state_path, "w", encoding="utf-8") as fh:
    fh.write(f"test_artifacts_state={state}\n")
    fh.write(f"test_artifacts_path={artifacts_dir}\n")
    fh.write(f"test_artifact_count={session['testArtifacts']['count']}\n")
PY
  [[ "${rc}" == "0" ]] || {
    artifact_error_code="$(ftctl_dr_runtime_state_get_from_path "${artifacts_state_path}" "artifact_error_code")"
    artifact_error_message="$(ftctl_dr_runtime_state_get_from_path "${artifacts_state_path}" "artifact_error_message")"
    ftctl_dr_runtime_path_set "${run_path}" \
      "test_artifacts_state=FAILED" \
      "error_code=${artifact_error_code}" \
      "error_message=${artifact_error_message}" \
      "updated_at=$(ftctl_now_iso8601)" || true
    rm -f "${artifacts_state_path}" 2>/dev/null || true
    return "${rc}"
  }

  test_artifacts_state="$(ftctl_dr_runtime_state_get_from_path "${artifacts_state_path}" "test_artifacts_state")"
  test_artifacts_path="$(ftctl_dr_runtime_state_get_from_path "${artifacts_state_path}" "test_artifacts_path")"
  test_artifact_count="$(ftctl_dr_runtime_state_get_from_path "${artifacts_state_path}" "test_artifact_count")"
  rm -f "${artifacts_state_path}" 2>/dev/null || true

  ftctl_dr_runtime_path_set "${run_path}" \
    "test_artifacts_state=${test_artifacts_state}" \
    "test_artifacts_path=${test_artifacts_path}" \
    "test_artifact_count=${test_artifact_count}"
}

ftctl_dr_runtime_finalize_failover() {
  local plan="${1-}" run="${2-}" profile_file="${3-}" restore_point="${4-}" mode="${5-}" run_path="${6-}" status_path="${7-}"
  local session_path active_path selection_path restore_points_path profile_path now rc=0
  local failover_session_id failover_restore_point_ref failover_restore_point_sequence
  local failover_manifest_path failover_checkpoint_path failover_requested_at restore_point_locked_at
  local target_promote_started_at target_power_on_at failover_completed_at rto_actual_seconds
  local last_source last_target target_rpo target_power_state target_promotion_state failover_runtime_state active_side

  ftctl_dr_runtime_ensure_plan_dirs "${plan}"
  session_path="$(ftctl_dr_runtime_failover_session_path "${plan}" "${run}")"
  active_path="$(ftctl_dr_runtime_active_failover_session_path "${plan}")"
  selection_path="$(mktemp -t ftctl.dr.failover.selection.XXXXXX)"
  restore_points_path="$(ftctl_dr_runtime_default_restore_points_path "${plan}" "${status_path}")"
  profile_path="${profile_file}"
  [[ -n "${profile_path}" && -f "${profile_path}" ]] || profile_path="$(ftctl_dr_runtime_profile_path "${plan}")"
  now="$(ftctl_now_iso8601)"

  python3 - "${plan}" "${run}" "${profile_path}" "${restore_point}" "${mode}" "${status_path}" \
    "${restore_points_path}" "${session_path}" "${active_path}" "${selection_path}" "${now}" <<'PY' || rc=$?
import json
import os
import shutil
import sys
from datetime import datetime, timezone

plan, run, profile_path, restore_selector, mode, status_path, restore_points_path, session_path, active_path, selection_path, now = sys.argv[1:12]

def read_state(path):
    values = {}
    if path and os.path.exists(path):
        with open(path, "r", encoding="utf-8") as fh:
            for line in fh:
                line = line.rstrip("\n")
                if "=" in line:
                    key, value = line.split("=", 1)
                    values[key] = value
    return values

def read_json(path):
    if path and os.path.exists(path):
        with open(path, "r", encoding="utf-8") as fh:
            return json.load(fh)
    return {}

def read_restore_points(path):
    records = []
    if not path or not os.path.exists(path):
        return records
    with open(path, "r", encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                data = json.loads(line)
            except json.JSONDecodeError:
                continue
            if isinstance(data, dict):
                records.append(data)
    return records

def record_ref(record):
    explicit = record.get("checkpointRef") or record.get("sourceSnapshotRef") or record.get("restorePointRef")
    if explicit:
        return str(explicit)
    sequence = record.get("checkpointSequence")
    if sequence is not None:
        return f"ftctl:{plan}:{record.get('runUuid') or run}:{sequence}"
    checkpoint = record.get("checkpoint")
    if checkpoint:
        return str(checkpoint)
    return f"ftctl:{plan}:latest"

def record_sequence(record):
    sequence = record.get("checkpointSequence")
    if sequence is None:
        return None
    try:
        return int(sequence)
    except (TypeError, ValueError):
        return sequence

def matches(record, selector):
    if not selector:
        return False
    candidates = {
        record_ref(record),
        f"ftctl:{plan}:{record.get('checkpointSequence', '')}",
        str(record.get("checkpointSequence", "")),
        str(record.get("checkpoint", "")),
        str(record.get("manifest", "")),
        str(record.get("sourceSnapshotRef", "")),
        str(record.get("restorePointRef", "")),
        str(record.get("checkpointRef", "")),
    }
    return str(selector) in candidates

def seconds_between(start, end):
    def parse(value):
        if not value:
            return None
        text = value.replace("Z", "+00:00")
        try:
            return datetime.fromisoformat(text)
        except ValueError:
            return None
    s = parse(start)
    e = parse(end)
    if s is None or e is None:
        return 0
    if s.tzinfo is None:
        s = s.replace(tzinfo=timezone.utc)
    if e.tzinfo is None:
        e = e.replace(tzinfo=timezone.utc)
    return max(0, int((e - s).total_seconds()))

state = read_state(status_path)
profile = read_json(profile_path)
request = profile.get("request") if isinstance(profile.get("request"), dict) else {}
selector = restore_selector or request.get("restorePointRef") or request.get("restorePointId") or ""
records = read_restore_points(restore_points_path)
selected = None
if selector:
    selected = next((record for record in records if matches(record, str(selector))), None)
    if selected is None:
        sys.stderr.write(f"ERROR: restore point {selector} was not found\n")
        sys.exit(44)
elif records:
    selected = records[-1]

if selected is None:
    sequence = state.get("checkpoint_sequence")
    checkpoint_path = state.get("checkpoint_path")
    manifest_path = state.get("manifest_path")
    last_target = state.get("last_target_durable_at")
    if not (sequence or checkpoint_path or manifest_path or last_target):
        sys.stderr.write("ERROR: no target-ready restore point is available\n")
        sys.exit(45)
    selected = {
        "planUuid": plan,
        "runUuid": state.get("run"),
        "checkpointSequence": int(sequence) if str(sequence).isdigit() else sequence,
        "manifest": manifest_path,
        "checkpoint": checkpoint_path,
        "sourceCheckpointAt": state.get("last_source_checkpoint_at"),
        "targetDurableAt": last_target,
        "targetReadyRpoSeconds": state.get("target_ready_rpo_seconds"),
        "state": state.get("state"),
        "recordedAt": state.get("updated_at"),
    }

checkpoint = read_json(selected.get("checkpoint"))
source_at = selected.get("sourceCheckpointAt") or checkpoint.get("sourceCheckpointAt") or state.get("last_source_checkpoint_at")
target_at = selected.get("targetDurableAt") or checkpoint.get("targetDurableAt") or state.get("last_target_durable_at")
target_rpo = selected.get("targetReadyRpoSeconds") or checkpoint.get("targetReadyRpoSeconds") or state.get("target_ready_rpo_seconds")
manifest_path = selected.get("manifest") or state.get("manifest_path")
checkpoint_path = selected.get("checkpoint") or state.get("checkpoint_path")
requested_at = state.get("failover_requested_at") or now
session_id = f"{plan}:{run}"
restore_ref = record_ref(selected)
cutover_ready = str(profile.get("direction") or "").upper() == "VMWARE_TO_KVM"
runtime_state = "CUTOVER_READY" if cutover_ready else "FAILED_OVER"
active_side = "SOURCE" if cutover_ready else "TARGET"
target_power_state = "POWERED_OFF" if cutover_ready else "POWER_ON_DELEGATED"
target_promotion_state = "CUTOVER_READY" if cutover_ready else "PROMOTED"
session = {
    "version": 1,
    "planUuid": plan,
    "runUuid": run,
    "sessionId": session_id,
    "state": runtime_state,
    "mode": mode or "planned",
    "activeSide": active_side,
    "startedAt": requested_at,
    "restorePointLockedAt": now,
    "targetPromoteStartedAt": now,
    "targetPowerOnAt": None if cutover_ready else now,
    "completedAt": None if cutover_ready else now,
    "rtoActualSeconds": seconds_between(requested_at, now),
    "restorePoint": {
        "ref": restore_ref,
        "checkpointSequence": record_sequence(selected),
        "manifest": manifest_path,
        "checkpoint": checkpoint_path,
        "sourceCheckpointAt": source_at,
        "targetDurableAt": target_at,
        "targetReadyRpoSeconds": target_rpo,
    },
    "targetPromotion": {
        "state": target_promotion_state,
        "powerState": target_power_state,
        "lifecycleOwner": "Cloud",
    },
    "profile": {
        "direction": profile.get("direction"),
        "source": profile.get("source"),
        "target": profile.get("target"),
        "mapping": profile.get("mapping"),
    },
    "checkpoint": checkpoint,
}
os.makedirs(os.path.dirname(session_path), exist_ok=True)
with open(session_path, "w", encoding="utf-8") as fh:
    json.dump(session, fh, sort_keys=True, separators=(",", ":"))
    fh.write("\n")
shutil.copyfile(session_path, active_path)
with open(selection_path, "w", encoding="utf-8") as fh:
    fh.write(f"failover_session_id={session_id}\n")
    fh.write(f"failover_mode={mode or 'planned'}\n")
    fh.write(f"failover_restore_point_ref={restore_ref}\n")
    sequence = record_sequence(selected)
    fh.write(f"failover_restore_point_sequence={'' if sequence is None else sequence}\n")
    fh.write(f"failover_manifest_path={manifest_path or ''}\n")
    fh.write(f"failover_checkpoint_path={checkpoint_path or ''}\n")
    fh.write(f"failover_requested_at={requested_at}\n")
    fh.write(f"restore_point_locked_at={now}\n")
    fh.write(f"target_promote_started_at={now}\n")
    fh.write(f"target_power_on_at={'' if cutover_ready else now}\n")
    fh.write(f"failover_completed_at={'' if cutover_ready else now}\n")
    fh.write(f"rto_actual_seconds={seconds_between(requested_at, now)}\n")
    fh.write(f"failover_runtime_state={runtime_state}\n")
    fh.write(f"active_side={active_side}\n")
    fh.write(f"target_power_state={target_power_state}\n")
    fh.write(f"target_promotion_state={target_promotion_state}\n")
    fh.write(f"last_source_checkpoint_at={source_at or ''}\n")
    fh.write(f"last_target_durable_at={target_at or ''}\n")
    fh.write(f"target_ready_rpo_seconds={target_rpo or ''}\n")
    fh.write(f"restore_points_path={restore_points_path or ''}\n")
PY
  [[ "${rc}" == "0" ]] || {
    rm -f "${selection_path}" 2>/dev/null || true
    return "${rc}"
  }

  failover_session_id="$(ftctl_dr_runtime_state_get_from_path "${selection_path}" "failover_session_id")"
  failover_restore_point_ref="$(ftctl_dr_runtime_state_get_from_path "${selection_path}" "failover_restore_point_ref")"
  failover_restore_point_sequence="$(ftctl_dr_runtime_state_get_from_path "${selection_path}" "failover_restore_point_sequence")"
  failover_manifest_path="$(ftctl_dr_runtime_state_get_from_path "${selection_path}" "failover_manifest_path")"
  failover_checkpoint_path="$(ftctl_dr_runtime_state_get_from_path "${selection_path}" "failover_checkpoint_path")"
  failover_requested_at="$(ftctl_dr_runtime_state_get_from_path "${selection_path}" "failover_requested_at")"
  restore_point_locked_at="$(ftctl_dr_runtime_state_get_from_path "${selection_path}" "restore_point_locked_at")"
  target_promote_started_at="$(ftctl_dr_runtime_state_get_from_path "${selection_path}" "target_promote_started_at")"
  target_power_on_at="$(ftctl_dr_runtime_state_get_from_path "${selection_path}" "target_power_on_at")"
  failover_completed_at="$(ftctl_dr_runtime_state_get_from_path "${selection_path}" "failover_completed_at")"
  rto_actual_seconds="$(ftctl_dr_runtime_state_get_from_path "${selection_path}" "rto_actual_seconds")"
  last_source="$(ftctl_dr_runtime_state_get_from_path "${selection_path}" "last_source_checkpoint_at")"
  last_target="$(ftctl_dr_runtime_state_get_from_path "${selection_path}" "last_target_durable_at")"
  target_rpo="$(ftctl_dr_runtime_state_get_from_path "${selection_path}" "target_ready_rpo_seconds")"
  restore_points_path="$(ftctl_dr_runtime_state_get_from_path "${selection_path}" "restore_points_path")"
  target_power_state="$(ftctl_dr_runtime_state_get_from_path "${selection_path}" "target_power_state")"
  target_promotion_state="$(ftctl_dr_runtime_state_get_from_path "${selection_path}" "target_promotion_state")"
  failover_runtime_state="$(ftctl_dr_runtime_state_get_from_path "${selection_path}" "failover_runtime_state")"
  active_side="$(ftctl_dr_runtime_state_get_from_path "${selection_path}" "active_side")"
  [[ -n "${failover_runtime_state}" ]] || failover_runtime_state="FAILED_OVER"
  [[ -n "${active_side}" ]] || active_side="TARGET"
  rm -f "${selection_path}" 2>/dev/null || true

  ftctl_dr_runtime_path_set "${run_path}" \
    "state=${failover_runtime_state}" \
    "step=$( [[ "${failover_runtime_state}" == "CUTOVER_READY" ]] && printf 'cutover-ready' || printf 'active-side-switch' )" \
    "progress=100" \
    "scheduler_state=STOPPED" \
    "failover_session_id=${failover_session_id}" \
    "failover_mode=${mode}" \
    "failover_restore_point_ref=${failover_restore_point_ref}" \
    "failover_restore_point_sequence=${failover_restore_point_sequence}" \
    "failover_manifest_path=${failover_manifest_path}" \
    "failover_checkpoint_path=${failover_checkpoint_path}" \
    "failover_requested_at=${failover_requested_at}" \
    "restore_point_locked_at=${restore_point_locked_at}" \
    "target_promote_started_at=${target_promote_started_at}" \
    "target_power_on_at=${target_power_on_at}" \
    "failover_completed_at=${failover_completed_at}" \
    "rto_actual_seconds=${rto_actual_seconds}" \
    "active_side=${active_side}" \
    "target_power_state=${target_power_state}" \
    "target_promotion_state=${target_promotion_state}" \
    "last_source_checkpoint_at=${last_source}" \
    "last_target_durable_at=${last_target}" \
    "target_ready_rpo_seconds=${target_rpo}" \
    "restore_points_path=${restore_points_path}" \
    "error_code=" \
    "updated_at=${failover_completed_at}"
  cp -f "${run_path}" "${status_path}" 2>/dev/null || true
  chmod 0644 "${status_path}" 2>/dev/null || true
}

ftctl_dr_runtime_failover_worker() {
  local plan="${1-}" run="${2-}" profile_file="${3-}" restore_point="${4-}" mode="${5-}" run_path="${6-}" status_path="${7-}"
  local final_sync rc=0 error_code now source_isolation_ack source_isolation_reason source_fence_state

  now="$(ftctl_now_iso8601)"
  source_isolation_ack="$(jq -r '.request.sourceIsolationAcknowledged // false' "${profile_file}" 2>/dev/null || echo false)"
  source_isolation_reason="$(jq -r '.request.sourceIsolationReason // empty' "${profile_file}" 2>/dev/null || true)"
  source_fence_state="REQUESTED"
  if [[ "${mode}" == "disaster" ]]; then
    if [[ "${source_isolation_ack}" != "true" || -z "${source_isolation_reason}" ]]; then
      ftctl_dr_runtime_path_set "${run_path}" \
        "state=ERROR" \
        "step=source-isolation-unconfirmed" \
        "progress=100" \
        "worker_state=FAILED" \
        "worker_pid=$$" \
        "worker_exit_code=78" \
        "source_fence_state=UNCONFIRMED" \
        "error_code=DR_SOURCE_ISOLATION_UNCONFIRMED" \
        "error_message=Disaster failover requires source isolation acknowledgement and a reason" \
        "updated_at=${now}" || true
      cp -f "${run_path}" "${status_path}" 2>/dev/null || true
      return 78
    fi
    source_fence_state="ACKNOWLEDGED"
  fi
  ftctl_dr_runtime_path_set "${run_path}" \
    "state=RUNNING" \
    "step=pre-failover-check" \
    "progress=25" \
    "worker_state=RUNNING" \
    "worker_pid=$$" \
    "failover_requested_at=${now}" \
    "failover_mode=${mode}" \
    "source_fence_state=${source_fence_state}" \
    "source_power_state=UNKNOWN" \
    "scheduler_recovery_state=STOPPED_PENDING_CUTOVER" \
    "updated_at=${now}" || true
  cp -f "${run_path}" "${status_path}" 2>/dev/null || true

  if command -v ftctl_dr_scheduler_control_set >/dev/null 2>&1; then
    ftctl_dr_scheduler_control_set "${plan}" "stop" || true
  fi

  final_sync="false"
  if [[ "${mode}" == "planned" ]] && ftctl_dr_runtime_profile_bool_default "${profile_file}" "request.finalSync" "true"; then
    final_sync="true"
  fi
  if [[ "${final_sync}" == "true" ]]; then
    ftctl_dr_runtime_failover_final_checkpoint "${plan}" "${run}" "${profile_file}" "${run_path}" "${status_path}" || rc=$?
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
        81) error_code="DR_VMWARE_SNAPSHOT_REF_UNRESOLVED" ;;
        66) error_code="DR_UNSUPPORTED_DIRECTION" ;;
        *) error_code="DR_FINAL_CHECKPOINT_FAILED" ;;
      esac
      ftctl_dr_runtime_path_set "${run_path}" \
        "state=ERROR" \
        "step=final-delta-failed" \
        "progress=100" \
        "accepted=false" \
        "worker_state=FAILED" \
        "worker_pid=$$" \
        "worker_exit_code=${rc}" \
        "error_code=${error_code}" \
        "updated_at=$(ftctl_now_iso8601)" || true
      cp -f "${run_path}" "${status_path}" 2>/dev/null || true
      ftctl_log_event "dr-runtime" "dr.failover" "fail" "" "${error_code}" \
        "plan=${plan} run=${run} mode=${mode} rc=${rc}"
      return "${rc}"
    fi
  fi

  local cutover_workdir direction
  direction="$(jq -r '.direction // ""' "${profile_file}" 2>/dev/null || true)"
  if [[ "${direction}" == "VMWARE_TO_KVM" ]]; then
    cutover_workdir="$(ftctl_dr_runtime_failover_dir "${plan}")/$(ftctl_dr_runtime_key "${run}")-guestprep"
    ftctl_dr_runtime_path_set "${run_path}" \
      "state=RUNNING" \
      "step=guest-preparation" \
      "progress=80" \
      "guest_prep_state=RUNNING" \
      "updated_at=$(ftctl_now_iso8601)" || true
    cp -f "${run_path}" "${status_path}" 2>/dev/null || true
    ftctl_guestprep_prepare_cutover_target "${profile_file}" "${run_path}" "${cutover_workdir}" \
      "${status_path}" "${restore_point}" || rc=$?
  else
    ftctl_dr_runtime_path_set "${run_path}" \
      "state=CUTOVER_READY" \
      "step=guest-preparation-not-required" \
      "progress=90" \
      "guest_prep_state=NOT_REQUIRED" \
      "updated_at=$(ftctl_now_iso8601)" || true
  fi
  if [[ "${rc}" != "0" ]]; then
    case "${rc}" in
      44) error_code="DR_RESTORE_POINT_NOT_FOUND" ;;
      60) error_code="DR_CUTOVER_MANIFEST_INVALID" ;;
      61) error_code="DR_GUEST_OS_UNRESOLVED" ;;
      62) error_code="DR_TARGET_DISK_MAP_MISSING" ;;
      63) error_code="DR_TARGET_DISK_LOCATOR_INVALID" ;;
      64) error_code="DR_TARGET_DISK_NOT_DURABLE" ;;
      47|65) error_code="DR_GUEST_PREP_RUNTIME_UNAVAILABLE" ;;
      48) error_code="DR_GUEST_OS_UNRESOLVED" ;;
      *) error_code="DR_GUEST_PREPARATION_FAILED" ;;
    esac
    ftctl_dr_runtime_path_set "${run_path}" \
      "state=ERROR" \
      "step=guest-preparation-failed" \
      "progress=100" \
      "accepted=false" \
      "worker_state=FAILED" \
      "worker_pid=$$" \
      "worker_exit_code=${rc}" \
      "guest_prep_state=FAILED" \
      "scheduler_recovery_state=REQUIRES_AUTHORIZED_RECOVERY" \
      "error_code=${error_code}" \
      "updated_at=$(ftctl_now_iso8601)" || true
    cp -f "${run_path}" "${status_path}" 2>/dev/null || true
    ftctl_log_event "dr-runtime" "dr.failover.guestprep" "fail" "" "${error_code}" \
      "plan=${plan} run=${run} mode=${mode} rc=${rc}"
    return "${rc}"
  fi
  cp -f "${run_path}" "${status_path}" 2>/dev/null || true

  ftctl_dr_runtime_finalize_failover "${plan}" "${run}" "${profile_file}" "${restore_point}" "${mode}" "${run_path}" "${status_path}" || rc=$?
  if [[ "${rc}" != "0" ]]; then
    error_code="DR_RESTORE_POINT_NOT_FOUND"
    [[ "${rc}" == "45" ]] && error_code="DR_TARGET_NOT_READY"
    ftctl_dr_runtime_path_set "${run_path}" \
      "state=ERROR" \
      "step=target-promote-failed" \
      "progress=100" \
      "accepted=false" \
      "worker_state=FAILED" \
      "worker_pid=$$" \
      "worker_exit_code=${rc}" \
      "error_code=${error_code}" \
      "updated_at=$(ftctl_now_iso8601)" || true
    cp -f "${run_path}" "${status_path}" 2>/dev/null || true
    ftctl_log_event "dr-runtime" "dr.failover" "fail" "" "${error_code}" \
      "plan=${plan} run=${run} mode=${mode} restore_point=${restore_point:-} rc=${rc}"
    return "${rc}"
  fi

  ftctl_log_event "dr-runtime" "dr.failover" "ok" "" "" \
    "plan=${plan} run=${run} mode=${mode} restore_point=$(ftctl_dr_runtime_state_get_from_path "${run_path}" "failover_restore_point_ref")"
  ftctl_dr_runtime_path_set "${run_path}" \
    "worker_state=SUCCEEDED" \
    "worker_pid=$$" \
    "worker_exit_code=0" \
    "worker_updated_at=$(ftctl_now_iso8601)" || true
  cp -f "${run_path}" "${status_path}" 2>/dev/null || true
}

ftctl_dr_runtime_start_failover() {
  local plan="${1-}" run="${2-}" profile_file="${3-}" restore_point="${4-}" mode="${5-}" run_path="${6-}" status_path="${7-}" wait_value="${8-}"
  local worker_profile pid log_path now

  worker_profile="${profile_file}"
  [[ -n "${worker_profile}" && -f "${worker_profile}" ]] || worker_profile="$(ftctl_dr_runtime_profile_path "${plan}")"
  mode="$(ftctl_dr_runtime_failover_mode "${mode}" "${worker_profile}")"

  if [[ "${wait_value}" != "false" || "${FTCTL_DR_FAILOVER_FOREGROUND:-0}" == "1" ]]; then
    ftctl_dr_runtime_failover_worker "${plan}" "${run}" "${worker_profile}" "${restore_point}" "${mode}" "${run_path}" "${status_path}"
    return $?
  fi

  log_path="${FTCTL_LOG_DIR}/dr-failover-$(ftctl_dr_runtime_key "${plan}")-$(ftctl_dr_runtime_key "${run}").log"
  (
    trap - EXIT
    unset FTCTL_HELD_LOCK_FILE
    ftctl_dr_runtime_failover_worker "${plan}" "${run}" "${worker_profile}" "${restore_point}" "${mode}" "${run_path}" "${status_path}"
  ) >> "${log_path}" 2>&1 &
  pid="$!"
  now="$(ftctl_now_iso8601)"
  ftctl_dr_runtime_path_set "${run_path}" \
    "state=RUNNING" \
    "step=failover-worker-started" \
    "progress=15" \
    "failover_mode=${mode}" \
    "failover_worker_pid=${pid}" \
    "updated_at=${now}" || true
}

ftctl_dr_runtime_write_operation_session() {
  local session_path="${1-}" active_path="${2-}" plan="${3-}" run="${4-}" operation="${5-}" state="${6-}" active_side="${7-}"
  local profile_file="${8-}" reverse_profile="${9-}" run_path="${10-}" requested_at="${11-}" completed_at="${12-}"

  ftctl_ensure_dir "$(dirname "${session_path}")" "0755"
  python3 - "${session_path}" "${active_path}" "${plan}" "${run}" "${operation}" "${state}" "${active_side}" \
    "${profile_file}" "${reverse_profile}" "${run_path}" "${requested_at}" "${completed_at}" <<'PY'
import json
import os
import shutil
import sys
from datetime import datetime, timezone

session_path, active_path, plan, run, operation, state, active_side, profile_file, reverse_profile, run_path, requested_at, completed_at = sys.argv[1:13]

def read_json(path):
    if path and os.path.exists(path):
        with open(path, "r", encoding="utf-8") as fh:
            return json.load(fh)
    return {}

def read_state(path):
    values = {}
    if path and os.path.exists(path):
        with open(path, "r", encoding="utf-8") as fh:
            for line in fh:
                line = line.rstrip("\n")
                if "=" in line:
                    key, value = line.split("=", 1)
                    values[key] = value
    return values

def seconds_between(start, end):
    def parse(value):
        if not value:
            return None
        try:
            return datetime.fromisoformat(value.replace("Z", "+00:00"))
        except ValueError:
            return None
    s = parse(start)
    e = parse(end)
    if s is None or e is None:
        return 0
    if s.tzinfo is None:
        s = s.replace(tzinfo=timezone.utc)
    if e.tzinfo is None:
        e = e.replace(tzinfo=timezone.utc)
    return max(0, int((e - s).total_seconds()))

runtime = read_state(run_path)
profile = read_json(profile_file)
reverse = read_json(reverse_profile)
sequence = runtime.get("checkpoint_sequence") or ""
restore_ref = runtime.get("checkpoint_ref") or (f"ftctl:{plan}:{run}:{sequence}" if sequence else f"ftctl:{plan}:latest")
session = {
    "version": 1,
    "planUuid": plan,
    "runUuid": run,
    "sessionId": f"{plan}:{run}",
    "operation": operation,
    "state": state,
    "activeSide": active_side,
    "startedAt": requested_at,
    "completedAt": completed_at,
    "rtoActualSeconds": seconds_between(requested_at, completed_at),
    "reverseDirection": reverse.get("direction"),
    "reverseProfilePath": reverse_profile,
    "restorePoint": {
        "ref": restore_ref,
        "checkpointSequence": int(sequence) if str(sequence).isdigit() else sequence,
        "manifest": runtime.get("manifest_path"),
        "checkpoint": runtime.get("checkpoint_path"),
        "sourceCheckpointAt": runtime.get("last_source_checkpoint_at"),
        "targetDurableAt": runtime.get("last_target_durable_at"),
        "targetReadyRpoSeconds": runtime.get("target_ready_rpo_seconds"),
    },
    "profile": {
        "originalDirection": profile.get("direction"),
        "reverseDirection": reverse.get("direction"),
        "source": reverse.get("source"),
        "target": reverse.get("target"),
        "mapping": reverse.get("mapping"),
    },
}
with open(session_path, "w", encoding="utf-8") as fh:
    json.dump(session, fh, sort_keys=True, separators=(",", ":"))
    fh.write("\n")
shutil.copyfile(session_path, active_path)
PY
}

ftctl_dr_runtime_failback_worker() {
  local plan="${1-}" run="${2-}" profile_file="${3-}" run_path="${4-}" status_path="${5-}"
  local worker_profile reverse_profile now requested_at completed_at rc=0 error_code
  local sequence manifest_path checkpoint_path reverse_restore_points_path reverse_direction rto_actual_seconds
  local active_side current_state previous_checkpoint_sequence

  worker_profile="${profile_file}"
  [[ -n "${worker_profile}" && -f "${worker_profile}" ]] || worker_profile="$(ftctl_dr_runtime_profile_path "${plan}")"
  active_side="$(ftctl_dr_runtime_state_get_from_path "${run_path}" "active_side")"
  current_state="$(ftctl_dr_runtime_state_get_from_path "${run_path}" "authority_state")"
  previous_checkpoint_sequence="$(ftctl_dr_runtime_state_get_from_path "${run_path}" "checkpoint_sequence")"
  if [[ "${active_side}" != "TARGET" && "${current_state}" != "FAILED_OVER" ]]; then
    ftctl_dr_runtime_path_set "${run_path}" \
      "state=ERROR" \
      "step=failback-not-eligible" \
      "progress=100" \
      "accepted=false" \
      "error_code=DR_FAILBACK_REQUIRES_TARGET_ACTIVE" \
      "error_message=Committed target authority was not available for failback" \
      "updated_at=$(ftctl_now_iso8601)" || true
    cp -f "${run_path}" "${status_path}" 2>/dev/null || true
    return 47
  fi

  requested_at="$(ftctl_now_iso8601)"
  reverse_profile="$(ftctl_dr_runtime_reverse_profile_path "${plan}" "${run}" "failback")"
  ftctl_dr_runtime_path_set "${run_path}" \
    "state=RUNNING" \
    "step=reverse-preflight" \
    "progress=20" \
    "failback_requested_at=${requested_at}" \
    "active_side=TARGET" \
    "checkpoint_sequence=${previous_checkpoint_sequence}" \
    "updated_at=${requested_at}" || true
  cp -f "${run_path}" "${status_path}" 2>/dev/null || true

  if command -v ftctl_dr_scheduler_control_set >/dev/null 2>&1; then
    ftctl_dr_scheduler_control_set "${plan}" "stop" || true
  fi
  ftctl_dr_runtime_build_reverse_profile "${plan}" "${run}" "${worker_profile}" "${reverse_profile}" "failback" || rc=$?
  if [[ "${rc}" == "0" ]]; then
    reverse_direction="$(ftctl_dr_runtime_profile_value "${reverse_profile}" "direction" 2>/dev/null || true)"
    ftctl_dr_runtime_path_set "${run_path}" \
      "reverse_profile_path=${reverse_profile}" \
      "reverse_direction=${reverse_direction}" || true
    ftctl_dr_runtime_reverse_checkpoint "${plan}" "${run}" "${reverse_profile}" "${run_path}" "${status_path}" "failback-final" "failback" || rc=$?
  fi
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
      81) error_code="DR_VMWARE_SNAPSHOT_REF_UNRESOLVED" ;;
      66) error_code="DR_UNSUPPORTED_DIRECTION" ;;
      47) error_code="DR_FAILBACK_REQUIRES_TARGET_ACTIVE" ;;
      *) error_code="DR_FAILBACK_REVERSE_SYNC_FAILED" ;;
    esac
    ftctl_dr_runtime_path_set "${run_path}" \
      "state=ERROR" \
      "step=failback-reverse-sync-failed" \
      "progress=100" \
      "accepted=false" \
      "error_code=${error_code}" \
      "updated_at=$(ftctl_now_iso8601)" || true
    cp -f "${run_path}" "${status_path}" 2>/dev/null || true
    ftctl_log_event "dr-runtime" "dr.failback" "fail" "" "${error_code}" \
      "plan=${plan} run=${run} rc=${rc}"
    return "${rc}"
  fi

  completed_at="$(ftctl_now_iso8601)"
  ftctl_dr_runtime_write_operation_session \
    "$(ftctl_dr_runtime_failback_session_path "${plan}" "${run}")" \
    "$(ftctl_dr_runtime_active_failback_session_path "${plan}")" \
    "${plan}" "${run}" "failback" "READY" "SOURCE" \
    "${worker_profile}" "${reverse_profile}" "${run_path}" "${requested_at}" "${completed_at}"
  sequence="$(ftctl_dr_runtime_state_get_from_path "${run_path}" "checkpoint_sequence")"
  manifest_path="$(ftctl_dr_runtime_state_get_from_path "${run_path}" "manifest_path")"
  checkpoint_path="$(ftctl_dr_runtime_state_get_from_path "${run_path}" "checkpoint_path")"
  reverse_restore_points_path="$(ftctl_dr_runtime_state_get_from_path "${run_path}" "reverse_restore_points_path")"
  reverse_direction="$(ftctl_dr_runtime_state_get_from_path "${run_path}" "reverse_direction")"
  rto_actual_seconds="$(python3 - "${requested_at}" "${completed_at}" <<'PY'
import sys
from datetime import datetime, timezone
def parse(value):
    if not value:
        return None
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
s = parse(sys.argv[1])
e = parse(sys.argv[2])
if s is None or e is None:
    print(0)
else:
    if s.tzinfo is None:
        s = s.replace(tzinfo=timezone.utc)
    if e.tzinfo is None:
        e = e.replace(tzinfo=timezone.utc)
    print(max(0, int((e - s).total_seconds())))
PY
)"
  ftctl_dr_runtime_path_set "${run_path}" \
    "state=READY" \
    "step=active-side-restore" \
    "progress=100" \
    "scheduler_state=STOPPED" \
    "failback_session_id=${plan}:${run}" \
    "failback_mode=planned" \
    "failback_restore_point_ref=ftctl:${plan}:${sequence}" \
    "failback_restore_point_sequence=${sequence}" \
    "failback_manifest_path=${manifest_path}" \
    "failback_checkpoint_path=${checkpoint_path}" \
    "failback_requested_at=${requested_at}" \
    "reverse_sync_started_at=${requested_at}" \
    "reverse_target_ready_at=${completed_at}" \
    "source_promote_started_at=${completed_at}" \
    "source_power_on_at=${completed_at}" \
    "failback_completed_at=${completed_at}" \
    "failback_rto_actual_seconds=${rto_actual_seconds}" \
    "rto_actual_seconds=${rto_actual_seconds}" \
    "active_side=SOURCE" \
    "source_power_state=POWER_ON_DELEGATED" \
    "source_promotion_state=PROMOTED" \
    "reverse_direction=${reverse_direction}" \
    "reverse_profile_path=${reverse_profile}" \
    "reverse_restore_points_path=${reverse_restore_points_path}" \
    "error_code=" \
    "updated_at=${completed_at}"
  cp -f "${run_path}" "${status_path}" 2>/dev/null || true
  chmod 0644 "${status_path}" 2>/dev/null || true
  ftctl_log_event "dr-runtime" "dr.failback" "ok" "" "" \
    "plan=${plan} run=${run} restore_point=ftctl:${plan}:${sequence} active_side=SOURCE"
}

ftctl_dr_runtime_start_failback() {
  local plan="${1-}" run="${2-}" profile_file="${3-}" run_path="${4-}" status_path="${5-}" wait_value="${6-}"
  local pid log_path now

  if [[ "${wait_value}" != "false" || "${FTCTL_DR_FAILBACK_FOREGROUND:-0}" == "1" ]]; then
    ftctl_dr_runtime_failback_worker "${plan}" "${run}" "${profile_file}" "${run_path}" "${status_path}"
    return $?
  fi

  log_path="${FTCTL_LOG_DIR}/dr-failback-$(ftctl_dr_runtime_key "${plan}")-$(ftctl_dr_runtime_key "${run}").log"
  (
    trap - EXIT
    unset FTCTL_HELD_LOCK_FILE
    ftctl_dr_runtime_failback_worker "${plan}" "${run}" "${profile_file}" "${run_path}" "${status_path}"
  ) >> "${log_path}" 2>&1 &
  pid="$!"
  now="$(ftctl_now_iso8601)"
  ftctl_dr_runtime_path_set "${run_path}" \
    "state=RUNNING" \
    "step=failback-worker-started" \
    "progress=15" \
    "failback_worker_pid=${pid}" \
    "updated_at=${now}" || true
}

ftctl_dr_runtime_reprotect_worker() {
  local plan="${1-}" run="${2-}" profile_file="${3-}" run_path="${4-}" status_path="${5-}"
  local worker_profile reverse_profile now requested_at completed_at rc=0 error_code
  local sequence manifest_path checkpoint_path reverse_restore_points_path reverse_direction rto_actual_seconds
  local active_side current_state previous_checkpoint_sequence

  worker_profile="${profile_file}"
  [[ -n "${worker_profile}" && -f "${worker_profile}" ]] || worker_profile="$(ftctl_dr_runtime_profile_path "${plan}")"
  active_side="$(ftctl_dr_runtime_state_get_from_path "${run_path}" "active_side")"
  current_state="$(ftctl_dr_runtime_state_get_from_path "${run_path}" "authority_state")"
  previous_checkpoint_sequence="$(ftctl_dr_runtime_state_get_from_path "${run_path}" "checkpoint_sequence")"
  if [[ "${active_side}" != "TARGET" && "${current_state}" != "FAILED_OVER" ]]; then
    ftctl_dr_runtime_path_set "${run_path}" \
      "state=ERROR" \
      "step=reprotect-not-eligible" \
      "progress=100" \
      "accepted=false" \
      "error_code=DR_REPROTECT_REQUIRES_TARGET_ACTIVE" \
      "error_message=Committed target authority was not available for reprotect" \
      "updated_at=$(ftctl_now_iso8601)" || true
    cp -f "${run_path}" "${status_path}" 2>/dev/null || true
    return 47
  fi

  requested_at="$(ftctl_now_iso8601)"
  reverse_profile="$(ftctl_dr_runtime_reverse_profile_path "${plan}" "${run}" "reprotect")"
  ftctl_dr_runtime_path_set "${run_path}" \
    "state=RUNNING" \
    "step=reprotect-preflight" \
    "progress=20" \
    "reprotect_requested_at=${requested_at}" \
    "active_side=TARGET" \
    "checkpoint_sequence=${previous_checkpoint_sequence}" \
    "updated_at=${requested_at}" || true
  cp -f "${run_path}" "${status_path}" 2>/dev/null || true

  ftctl_dr_runtime_build_reverse_profile "${plan}" "${run}" "${worker_profile}" "${reverse_profile}" "reprotect" || rc=$?
  if [[ "${rc}" == "0" ]]; then
    reverse_direction="$(ftctl_dr_runtime_profile_value "${reverse_profile}" "direction" 2>/dev/null || true)"
    ftctl_dr_runtime_path_set "${run_path}" \
      "reverse_profile_path=${reverse_profile}" \
      "reverse_direction=${reverse_direction}" || true
    ftctl_dr_runtime_reverse_checkpoint "${plan}" "${run}" "${reverse_profile}" "${run_path}" "${status_path}" "reprotect-seed" "reprotect" || rc=$?
  fi
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
      81) error_code="DR_VMWARE_SNAPSHOT_REF_UNRESOLVED" ;;
      66) error_code="DR_UNSUPPORTED_DIRECTION" ;;
      47) error_code="DR_REPROTECT_REQUIRES_TARGET_ACTIVE" ;;
      *) error_code="DR_REPROTECT_REVERSE_SYNC_FAILED" ;;
    esac
    ftctl_dr_runtime_path_set "${run_path}" \
      "state=ERROR" \
      "step=reprotect-reverse-sync-failed" \
      "progress=100" \
      "accepted=false" \
      "error_code=${error_code}" \
      "updated_at=$(ftctl_now_iso8601)" || true
    cp -f "${run_path}" "${status_path}" 2>/dev/null || true
    ftctl_log_event "dr-runtime" "dr.reprotect" "fail" "" "${error_code}" \
      "plan=${plan} run=${run} rc=${rc}"
    return "${rc}"
  fi

  completed_at="$(ftctl_now_iso8601)"
  ftctl_dr_runtime_write_operation_session \
    "$(ftctl_dr_runtime_reprotect_session_path "${plan}" "${run}")" \
    "$(ftctl_dr_runtime_active_reprotect_session_path "${plan}")" \
    "${plan}" "${run}" "reprotect" "READY" "TARGET" \
    "${worker_profile}" "${reverse_profile}" "${run_path}" "${requested_at}" "${completed_at}"
  cp -f "${reverse_profile}" "$(ftctl_dr_runtime_profile_path "${plan}")" 2>/dev/null || true
  sequence="$(ftctl_dr_runtime_state_get_from_path "${run_path}" "checkpoint_sequence")"
  manifest_path="$(ftctl_dr_runtime_state_get_from_path "${run_path}" "manifest_path")"
  checkpoint_path="$(ftctl_dr_runtime_state_get_from_path "${run_path}" "checkpoint_path")"
  reverse_restore_points_path="$(ftctl_dr_runtime_state_get_from_path "${run_path}" "reverse_restore_points_path")"
  reverse_direction="$(ftctl_dr_runtime_state_get_from_path "${run_path}" "reverse_direction")"
  rto_actual_seconds="$(python3 - "${requested_at}" "${completed_at}" <<'PY'
import sys
from datetime import datetime, timezone
def parse(value):
    if not value:
        return None
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
s = parse(sys.argv[1])
e = parse(sys.argv[2])
if s is None or e is None:
    print(0)
else:
    if s.tzinfo is None:
        s = s.replace(tzinfo=timezone.utc)
    if e.tzinfo is None:
        e = e.replace(tzinfo=timezone.utc)
    print(max(0, int((e - s).total_seconds())))
PY
)"
  ftctl_dr_runtime_path_set "${run_path}" \
    "state=READY" \
    "step=reprotect-ready" \
    "progress=100" \
    "scheduler_state=READY" \
    "reprotect_session_id=${plan}:${run}" \
    "reprotect_mode=reverse" \
    "reprotect_restore_point_ref=ftctl:${plan}:${sequence}" \
    "reprotect_restore_point_sequence=${sequence}" \
    "reprotect_manifest_path=${manifest_path}" \
    "reprotect_checkpoint_path=${checkpoint_path}" \
    "reprotect_requested_at=${requested_at}" \
    "reprotect_completed_at=${completed_at}" \
    "reprotect_rto_actual_seconds=${rto_actual_seconds}" \
    "rto_actual_seconds=${rto_actual_seconds}" \
    "active_side=TARGET" \
    "target_power_state=POWER_ON_DELEGATED" \
    "target_promotion_state=PROMOTED" \
    "reverse_direction=${reverse_direction}" \
    "reverse_profile_path=${reverse_profile}" \
    "reverse_restore_points_path=${reverse_restore_points_path}" \
    "error_code=" \
    "updated_at=${completed_at}"
  cp -f "${run_path}" "${status_path}" 2>/dev/null || true
  chmod 0644 "${status_path}" 2>/dev/null || true
  ftctl_log_event "dr-runtime" "dr.reprotect" "ok" "" "" \
    "plan=${plan} run=${run} restore_point=ftctl:${plan}:${sequence} active_side=TARGET"
}

ftctl_dr_runtime_start_reprotect() {
  local plan="${1-}" run="${2-}" profile_file="${3-}" run_path="${4-}" status_path="${5-}" wait_value="${6-}"
  local pid log_path now

  if [[ "${wait_value}" != "false" || "${FTCTL_DR_REPROTECT_FOREGROUND:-0}" == "1" ]]; then
    ftctl_dr_runtime_reprotect_worker "${plan}" "${run}" "${profile_file}" "${run_path}" "${status_path}"
    return $?
  fi

  log_path="${FTCTL_LOG_DIR}/dr-reprotect-$(ftctl_dr_runtime_key "${plan}")-$(ftctl_dr_runtime_key "${run}").log"
  (
    trap - EXIT
    unset FTCTL_HELD_LOCK_FILE
    ftctl_dr_runtime_reprotect_worker "${plan}" "${run}" "${profile_file}" "${run_path}" "${status_path}"
  ) >> "${log_path}" 2>&1 &
  pid="$!"
  now="$(ftctl_now_iso8601)"
  ftctl_dr_runtime_path_set "${run_path}" \
    "state=RUNNING" \
    "step=reprotect-worker-started" \
    "progress=15" \
    "reprotect_worker_pid=${pid}" \
    "updated_at=${now}" || true
}

ftctl_dr_runtime_emit_events_since() {
  local plan="${1-}" offset="${2-0}" limit="${3-20}" events_path
  [[ "${offset}" =~ ^[0-9]+$ ]] || offset="0"
  [[ "${limit}" =~ ^[0-9]+$ ]] || limit="20"
  (( limit <= 100 )) || limit="100"
  events_path="$(ftctl_dr_runtime_plan_events_path "${plan}")"
  python3 - "${events_path}" "${offset}" "${limit}" <<'PY'
import json
import os
import sys

path, offset, limit = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
lines = []
if os.path.isfile(path):
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        lines = fh.readlines()
current = len(lines)
candidates = list(enumerate(lines, start=1))
candidates = [(seq, line) for seq, line in candidates if seq > offset]
truncated = limit == 0 and bool(candidates)
if limit == 0:
    candidates = []
elif len(candidates) > limit:
    candidates = candidates[-limit:]
    truncated = True
events = []
invalid = 0
for seq, line in candidates:
    try:
        value = json.loads(line)
        if not isinstance(value, dict):
            raise ValueError("event is not an object")
        events.append(value)
    except Exception:
        invalid += 1
payload = {
    "events_offset": current,
    "events_next_offset": current,
    "events_truncated": truncated,
    "events_invalid_count": invalid,
    "events": events,
}
encoded = json.dumps(payload, sort_keys=True, separators=(",", ":"))
sys.stdout.write("," + encoded[1:-1])
PY
}

ftctl_dr_runtime_emit_state_json() {
  local command="${1-}" result="${2-ok}" plan="${3-}" run="${4-}" state_path="${5-}" events_offset="${6-}" events_limit="${7-20}"
  local action state step progress external_job_ref error_code error_message failed_component data_commit_state data_copied metadata_committed target_durable cycle_retry_mode driver_exit_code last_source last_target target_rpo updated accepted
  local runtime_exists profile_exists run_exists
  local driver driver_state disk_map_path source_disk_map_path target_disk_map_path disk_map_role
  local target_disk_count target_disk_invalid_count manifest_path checkpoint_path cbt_status_path source_open_status_path source_snapshot_status_path
  local scheduler_state worker_pid worker_state worker_started_at worker_updated_at worker_exit_code
  local runtime_generation scheduler_pid_alive baseline_state reseed_reason consecutive_automatic_reseed_count
  local control_protocol_version control_generation control_ack_generation control_state cycle_state
  local scheduler_session_uuid scheduler_lease_epoch authority_sequence plan_cycle_sequence scheduler_health
  local replication_activity protection_state active_worker_run_uuid active_worker_pid active_worker_start_ticks
  local worker_heartbeat_at control_request_run_uuid owner_matched
  local scheduler_desired_state scheduler_service_unit scheduler_unit_active_state scheduler_unit_sub_state
  local scheduler_unit_main_pid scheduler_cgroup scheduler_recovery_state scheduler_recovery_trigger scheduler_recovered_at
  local transition_state transition_action transition_quiesced_at checkpoint_lease_state checkpoint_lease_path
  local retryable retry_after_sec lock_file holder_pid holder_command holder_age_sec
  local checkpoint_sequence restore_points_path dynamic_rpo
  local current_checkpoint_sequence current_checkpoint_cycle_type current_checkpoint_requested_mode current_checkpoint_effective_mode
  local current_checkpoint_mode_decision_code current_checkpoint_automatic_reseed current_checkpoint_invalid_baseline_disk_count
  local current_checkpoint_ref current_checkpoint_state
  local latest_completed_checkpoint_sequence latest_completed_checkpoint_cycle_type latest_completed_checkpoint_ref latest_completed_checkpoint_state
  local latest_completed_producer_run_uuid
  local latest_completed_source_checkpoint_at latest_completed_target_durable_at latest_completed_target_ready_rpo_seconds
  local latest_completed_manifest_path latest_completed_checkpoint_path
  local latest_completed_requested_mode latest_completed_effective_mode latest_completed_mode_decision_code latest_completed_reseed_reason
  local latest_completed_automatic_reseed latest_completed_invalid_baseline_disk_count
  local latest_completed_incremental_verified latest_completed_metrics_estimated latest_completed_virtual_bytes
  local latest_completed_changed_bytes latest_completed_source_read_bytes latest_completed_target_written_bytes
  local latest_completed_transfer_payload_bytes latest_completed_changed_extent_count latest_completed_duration_ms
  local latest_completed_throughput_bps latest_completed_baseline_generation latest_completed_cycle_token latest_completed_cycle_metrics_path
  local nbd_teardown_state nbd_quarantined_device_count nbd_teardown_error_code nbd_teardown_error_message
  local latest_completed_nbd_teardown_state latest_completed_nbd_teardown_started_at_ms
  local latest_completed_nbd_teardown_completed_at_ms latest_completed_nbd_teardown_duration_ms
  local latest_completed_nbd_source_device_count latest_completed_nbd_target_device_count
  local latest_completed_nbd_quarantined_device_count latest_completed_nbd_teardown_error_code
  local latest_completed_nbd_teardown_error_message
  local -a completed_checkpoint_fields=()
  local test_session_id test_session_path test_session_state test_restore_point_ref test_restore_point_sequence
  local test_manifest_path test_checkpoint_path
  local test_artifacts_state test_artifacts_path test_artifact_count
  local failover_session_id failover_mode failover_restore_point_ref failover_restore_point_sequence
  local failover_manifest_path failover_checkpoint_path failover_requested_at restore_point_locked_at
  local target_promote_started_at target_power_on_at failover_completed_at rto_actual_seconds
  local active_side target_power_state target_promotion_state failover_worker_pid
  local boot_validation_state cloud_cutover_session_id cloud_authority_generation engine_ack_state engine_ack_at
  local guest_prep_state guest_family guestprep_manifest_path manifest_schema_version manifest_sha256
  local guestprep_checkpoint_sequence source_fence_state scheduler_recovery_state
  local test_domain_name test_domain_state test_boot_validation_mode
  local failback_session_id failback_mode failback_restore_point_ref failback_restore_point_sequence
  local failback_manifest_path failback_checkpoint_path failback_requested_at reverse_sync_started_at
  local reverse_target_ready_at source_promote_started_at source_power_on_at failback_completed_at
  local failback_rto_actual_seconds source_power_state source_promotion_state failback_worker_pid
  local reprotect_session_id reprotect_mode reprotect_restore_point_ref reprotect_restore_point_sequence
  local reprotect_manifest_path reprotect_checkpoint_path reprotect_requested_at reprotect_completed_at
  local reprotect_rto_actual_seconds reverse_direction reverse_profile_path reverse_restore_points_path reprotect_worker_pid
  local target_vm_id target_external_ref target_materialized target_vm_present target_storage_present target_network_present restore_point_present
  local status_scope profile_path source_firmware="" source_secure_boot="" source_hardware_fingerprint=""
  local target_boot_type="" target_boot_mode="" target_io_policy="" target_iothreads=""

  ftctl_dr_runtime_state_snapshot_begin "${state_path}"
  action="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "action")"
  state="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "state")"
  step="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "step")"
  progress="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "progress")"
  external_job_ref="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "external_job_ref")"
  error_code="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "error_code")"
  error_message="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "error_message")"
  failed_component="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "failed_component")"
  data_commit_state="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "data_commit_state")"
  data_copied="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "data_copied")"
  metadata_committed="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "metadata_committed")"
  target_durable="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "target_durable")"
  cycle_retry_mode="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "cycle_retry_mode")"
  driver_exit_code="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "driver_exit_code")"
  last_source="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "last_source_checkpoint_at")"
  last_target="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "last_target_durable_at")"
  target_rpo="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "target_ready_rpo_seconds")"
  updated="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "updated_at")"
  accepted="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "accepted")"
  [[ -f "${state_path}" ]] && runtime_exists="true" || runtime_exists="false"
  profile_path="$(ftctl_dr_runtime_profile_path "${plan}")"
  [[ -f "${profile_path}" ]] && profile_exists="true" || profile_exists="false"
  [[ -n "${run}" && -f "$(ftctl_dr_runtime_run_path "${plan}" "${run}")" ]] && run_exists="true" || run_exists="false"
  if [[ "${profile_exists}" == "true" ]]; then
    source_firmware="$(jq -r '.mapping.source.hardware.firmware // empty' "${profile_path}" 2>/dev/null || true)"
    source_secure_boot="$(jq -r '.mapping.source.hardware.secureBoot // empty' "${profile_path}" 2>/dev/null || true)"
    source_hardware_fingerprint="$(jq -r '.mapping.source.hardware.fingerprint // empty' "${profile_path}" 2>/dev/null || true)"
    target_boot_type="$(jq -r '.mapping.target.hardware.bootType // empty' "${profile_path}" 2>/dev/null || true)"
    target_boot_mode="$(jq -r '.mapping.target.hardware.bootMode // empty' "${profile_path}" 2>/dev/null || true)"
    target_io_policy="$(jq -r '.mapping.target.hardware.ioPolicy // empty' "${profile_path}" 2>/dev/null || true)"
    target_iothreads="$(jq -r '.mapping.target.hardware.ioThreadsEnabled // empty' "${profile_path}" 2>/dev/null || true)"
  fi
  driver="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "driver")"
  driver_state="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "driver_state")"
  disk_map_path="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "disk_map_path")"
  source_disk_map_path="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "source_disk_map_path")"
  target_disk_map_path="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "target_disk_map_path")"
  disk_map_role="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "disk_map_role")"
  target_disk_count="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "target_disk_count")"
  target_disk_invalid_count="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "target_disk_invalid_count")"
  manifest_path="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "manifest_path")"
  checkpoint_path="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "checkpoint_path")"
  cbt_status_path="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "cbt_status_path")"
  source_open_status_path="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "source_open_status_path")"
  source_snapshot_status_path="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "source_snapshot_status_path")"
  scheduler_state="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "scheduler_state")"
  runtime_generation="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "runtime_generation")"
  baseline_state="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "baseline_state")"
  reseed_reason="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "reseed_reason")"
  consecutive_automatic_reseed_count="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "consecutive_automatic_reseed_count")"
  control_protocol_version="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "control_protocol_version")"
  control_generation="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "control_generation")"
  control_ack_generation="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "control_ack_generation")"
  control_state="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "control_state")"
  cycle_state="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "cycle_state")"
  scheduler_session_uuid="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "scheduler_session_uuid")"
  scheduler_lease_epoch="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "scheduler_lease_epoch")"
  authority_sequence="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "authority_sequence")"
  plan_cycle_sequence="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "plan_cycle_sequence")"
  scheduler_health="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "scheduler_health")"
  replication_activity="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "replication_activity")"
  protection_state="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "protection_state")"
  active_worker_run_uuid="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "active_worker_run_uuid")"
  active_worker_pid="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "active_worker_pid")"
  active_worker_start_ticks="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "active_worker_start_ticks")"
  worker_heartbeat_at="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "worker_heartbeat_at")"
  control_request_run_uuid="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "control_request_run_uuid")"
  owner_matched="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "owner_matched")"
  scheduler_desired_state="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "scheduler_desired_state")"
  scheduler_service_unit="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "scheduler_service_unit")"
  scheduler_unit_active_state="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "scheduler_unit_active_state")"
  scheduler_unit_sub_state="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "scheduler_unit_sub_state")"
  scheduler_unit_main_pid="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "scheduler_unit_main_pid")"
  scheduler_cgroup="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "scheduler_cgroup")"
  scheduler_recovery_state="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "scheduler_recovery_state")"
  scheduler_recovery_trigger="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "scheduler_recovery_trigger")"
  scheduler_recovered_at="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "scheduler_recovered_at")"
  nbd_teardown_state="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "nbd_teardown_state")"
  nbd_quarantined_device_count="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "nbd_quarantined_device_count")"
  nbd_teardown_error_code="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "nbd_teardown_error_code")"
  nbd_teardown_error_message="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "nbd_teardown_error_message")"
  transition_state="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "transition_state")"
  transition_action="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "transition_action")"
  transition_quiesced_at="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "transition_quiesced_at")"
  checkpoint_lease_state="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "checkpoint_lease_state")"
  checkpoint_lease_path="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "checkpoint_lease_path")"
  worker_pid="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "worker_pid")"
  worker_state="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "worker_state")"
  worker_started_at="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "worker_started_at")"
  worker_updated_at="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "worker_updated_at")"
  worker_exit_code="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "worker_exit_code")"
  scheduler_pid_alive="false"
  if ftctl_dr_scheduler_active_worker_valid "${plan}" ""; then
    scheduler_pid_alive="true"
    scheduler_state="RUNNING"
    scheduler_health="HEALTHY"
    owner_matched="true"
    scheduler_session_uuid="$(ftctl_dr_scheduler_active_value "${plan}" "scheduler_session_uuid")"
    scheduler_lease_epoch="$(ftctl_dr_scheduler_active_value "${plan}" "lease_epoch")"
    active_worker_run_uuid="$(ftctl_dr_scheduler_active_value "${plan}" "worker_run_uuid")"
    active_worker_pid="$(ftctl_dr_scheduler_active_value "${plan}" "pid")"
    active_worker_start_ticks="$(ftctl_dr_scheduler_active_value "${plan}" "start_ticks")"
    worker_heartbeat_at="$(ftctl_dr_scheduler_active_value "${plan}" "heartbeat_at")"
    scheduler_cgroup="$(ftctl_dr_scheduler_process_cgroup "${active_worker_pid}" 2>/dev/null || true)"
    if ftctl_dr_scheduler_systemd_available "${plan}"; then
      scheduler_service_unit="$(ftctl_dr_scheduler_unit_name "${plan}" 2>/dev/null || true)"
      scheduler_unit_active_state="$(systemctl show "${scheduler_service_unit}" -p ActiveState --value 2>/dev/null || true)"
      scheduler_unit_sub_state="$(systemctl show "${scheduler_service_unit}" -p SubState --value 2>/dev/null || true)"
      scheduler_unit_main_pid="$(systemctl show "${scheduler_service_unit}" -p MainPID --value 2>/dev/null || true)"
    fi
  elif [[ -f "$(ftctl_dr_scheduler_active_pid_path "${plan}")" ]]; then
    scheduler_pid_alive="false"
    scheduler_health="DEAD"
    owner_matched="false"
  elif [[ -z "${scheduler_health}" ]]; then
    scheduler_health="STOPPED"
    owner_matched="false"
  fi
  authority_sequence="$(ftctl_dr_scheduler_current_authority_sequence "${plan}")"
  plan_cycle_sequence="$(ftctl_state_read_kv "$(ftctl_dr_scheduler_sequence_path "${plan}")" "plan_cycle_sequence" 2>/dev/null || true)"
  control_request_run_uuid="$(ftctl_dr_scheduler_control_value "${plan}" "owner_run")"
  [[ -n "${replication_activity}" ]] || replication_activity="IDLE"
  [[ -n "${protection_state}" ]] || protection_state="${state}"
  retryable="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "retryable")"
  retry_after_sec="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "retry_after_sec")"
  lock_file="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "lock_file")"
  holder_pid="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "holder_pid")"
  holder_command="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "holder_command")"
  holder_age_sec="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "holder_age_sec")"
  checkpoint_sequence="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "checkpoint_sequence")"
  restore_points_path="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "restore_points_path")"
  [[ -n "${restore_points_path}" ]] || restore_points_path="$(ftctl_dr_runtime_plan_dir "${plan}")/restore-points.jsonl"
  current_checkpoint_sequence="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "current_checkpoint_sequence")"
  current_checkpoint_cycle_type="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "current_checkpoint_cycle_type")"
  current_checkpoint_requested_mode="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "current_checkpoint_requested_mode")"
  current_checkpoint_effective_mode="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "current_checkpoint_effective_mode")"
  current_checkpoint_mode_decision_code="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "current_checkpoint_mode_decision_code")"
  current_checkpoint_automatic_reseed="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "current_checkpoint_automatic_reseed")"
  current_checkpoint_invalid_baseline_disk_count="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "current_checkpoint_invalid_baseline_disk_count")"
  current_checkpoint_ref="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "current_checkpoint_ref")"
  current_checkpoint_state="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "current_checkpoint_state")"
  latest_completed_checkpoint_sequence="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "latest_completed_checkpoint_sequence")"
  latest_completed_checkpoint_cycle_type="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "latest_completed_checkpoint_cycle_type")"
  latest_completed_checkpoint_ref="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "latest_completed_checkpoint_ref")"
  latest_completed_checkpoint_state="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "latest_completed_checkpoint_state")"
  latest_completed_producer_run_uuid="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "latest_completed_producer_run_uuid")"
  latest_completed_source_checkpoint_at="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "latest_completed_source_checkpoint_at")"
  latest_completed_target_durable_at="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "latest_completed_target_durable_at")"
  latest_completed_target_ready_rpo_seconds="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "latest_completed_target_ready_rpo_seconds")"
  latest_completed_manifest_path="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "latest_completed_manifest_path")"
  latest_completed_checkpoint_path="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "latest_completed_checkpoint_path")"
  latest_completed_requested_mode="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "latest_completed_requested_mode")"
  latest_completed_effective_mode="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "latest_completed_effective_mode")"
  latest_completed_mode_decision_code="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "latest_completed_mode_decision_code")"
  latest_completed_reseed_reason="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "latest_completed_reseed_reason")"
  latest_completed_automatic_reseed="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "latest_completed_automatic_reseed")"
  latest_completed_invalid_baseline_disk_count="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "latest_completed_invalid_baseline_disk_count")"
  latest_completed_incremental_verified="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "latest_completed_incremental_verified")"
  latest_completed_metrics_estimated="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "latest_completed_metrics_estimated")"
  latest_completed_virtual_bytes="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "latest_completed_virtual_bytes")"
  latest_completed_changed_bytes="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "latest_completed_changed_bytes")"
  latest_completed_source_read_bytes="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "latest_completed_source_read_bytes")"
  latest_completed_target_written_bytes="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "latest_completed_target_written_bytes")"
  latest_completed_transfer_payload_bytes="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "latest_completed_transfer_payload_bytes")"
  latest_completed_changed_extent_count="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "latest_completed_changed_extent_count")"
  latest_completed_duration_ms="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "latest_completed_duration_ms")"
  latest_completed_throughput_bps="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "latest_completed_throughput_bps")"
  latest_completed_baseline_generation="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "latest_completed_baseline_generation")"
  latest_completed_cycle_token="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "latest_completed_cycle_token")"
  latest_completed_cycle_metrics_path="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "latest_completed_cycle_metrics_path")"
  latest_completed_nbd_teardown_state="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "latest_completed_nbd_teardown_state")"
  latest_completed_nbd_teardown_started_at_ms="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "latest_completed_nbd_teardown_started_at_ms")"
  latest_completed_nbd_teardown_completed_at_ms="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "latest_completed_nbd_teardown_completed_at_ms")"
  latest_completed_nbd_teardown_duration_ms="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "latest_completed_nbd_teardown_duration_ms")"
  latest_completed_nbd_source_device_count="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "latest_completed_nbd_source_device_count")"
  latest_completed_nbd_target_device_count="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "latest_completed_nbd_target_device_count")"
  latest_completed_nbd_quarantined_device_count="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "latest_completed_nbd_quarantined_device_count")"
  latest_completed_nbd_teardown_error_code="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "latest_completed_nbd_teardown_error_code")"
  latest_completed_nbd_teardown_error_message="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "latest_completed_nbd_teardown_error_message")"
  if [[ -z "${latest_completed_checkpoint_sequence}" && -s "${restore_points_path}" ]]; then
    mapfile -t completed_checkpoint_fields < <(python3 - "${restore_points_path}" <<'PY' 2>/dev/null
import json
import sys

latest = None
with open(sys.argv[1], "r", encoding="utf-8") as fh:
    for line in fh:
        try:
            candidate = json.loads(line)
        except (TypeError, ValueError):
            continue
        if candidate.get("checkpointSequence") is not None:
            latest = candidate
if latest:
    for key in (
        "checkpointSequence", "cycleType", "checkpointRef", "state",
        "sourceCheckpointAt", "targetDurableAt", "targetReadyRpoSeconds",
        "manifest", "checkpoint", "producerRunUuid",
        "requestedMode", "effectiveMode", "modeDecisionCode", "reseedReason",
        "automaticReseed", "invalidBaselineDiskCount", "incrementalVerified",
        "metricsEstimated", "virtualBytes", "changedBytes", "sourceReadBytes",
        "targetWrittenBytes", "transferPayloadBytes", "changedExtentCount",
        "durationMs", "throughputBps", "baselineGeneration", "cycleToken",
    ):
        value = latest.get(key)
        print("" if value is None else value)
PY
    )
    if (( ${#completed_checkpoint_fields[@]} >= 28 )); then
      latest_completed_checkpoint_sequence="${completed_checkpoint_fields[0]}"
      latest_completed_checkpoint_cycle_type="${completed_checkpoint_fields[1]}"
      latest_completed_checkpoint_ref="${completed_checkpoint_fields[2]}"
      latest_completed_checkpoint_state="${completed_checkpoint_fields[3]:-READY}"
      latest_completed_source_checkpoint_at="${completed_checkpoint_fields[4]}"
      latest_completed_target_durable_at="${completed_checkpoint_fields[5]}"
      latest_completed_target_ready_rpo_seconds="${completed_checkpoint_fields[6]}"
      latest_completed_manifest_path="${completed_checkpoint_fields[7]}"
      latest_completed_checkpoint_path="${completed_checkpoint_fields[8]}"
      latest_completed_producer_run_uuid="${completed_checkpoint_fields[9]}"
      latest_completed_requested_mode="${completed_checkpoint_fields[10]}"
      latest_completed_effective_mode="${completed_checkpoint_fields[11]}"
      latest_completed_mode_decision_code="${completed_checkpoint_fields[12]}"
      latest_completed_reseed_reason="${completed_checkpoint_fields[13]}"
      latest_completed_automatic_reseed="${completed_checkpoint_fields[14]}"
      latest_completed_invalid_baseline_disk_count="${completed_checkpoint_fields[15]}"
      latest_completed_incremental_verified="${completed_checkpoint_fields[16]}"
      latest_completed_metrics_estimated="${completed_checkpoint_fields[17]}"
      latest_completed_virtual_bytes="${completed_checkpoint_fields[18]}"
      latest_completed_changed_bytes="${completed_checkpoint_fields[19]}"
      latest_completed_source_read_bytes="${completed_checkpoint_fields[20]}"
      latest_completed_target_written_bytes="${completed_checkpoint_fields[21]}"
      latest_completed_transfer_payload_bytes="${completed_checkpoint_fields[22]}"
      latest_completed_changed_extent_count="${completed_checkpoint_fields[23]}"
      latest_completed_duration_ms="${completed_checkpoint_fields[24]}"
      latest_completed_throughput_bps="${completed_checkpoint_fields[25]}"
      latest_completed_baseline_generation="${completed_checkpoint_fields[26]}"
      latest_completed_cycle_token="${completed_checkpoint_fields[27]}"
    fi
  fi
  if [[ -z "${latest_completed_producer_run_uuid}" && "${latest_completed_checkpoint_ref}" == ftctl:* ]]; then
    latest_completed_producer_run_uuid="$(awk -F: '{print $(NF-1)}' <<< "${latest_completed_checkpoint_ref}")"
  fi
  [[ -n "${latest_completed_producer_run_uuid}" ]] || latest_completed_producer_run_uuid="${active_worker_run_uuid}"
  [[ -n "${current_checkpoint_sequence}" ]] || current_checkpoint_sequence="${checkpoint_sequence}"
  test_session_id="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "test_session_id")"
  test_session_path="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "test_session_path")"
  test_session_state="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "test_session_state")"
  test_restore_point_ref="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "test_restore_point_ref")"
  test_restore_point_sequence="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "test_restore_point_sequence")"
  test_manifest_path="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "test_manifest_path")"
  test_checkpoint_path="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "test_checkpoint_path")"
  test_artifacts_state="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "test_artifacts_state")"
  test_artifacts_path="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "test_artifacts_path")"
  test_artifact_count="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "test_artifact_count")"
  guest_prep_state="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "guest_prep_state")"
  guest_family="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "guest_family")"
  guestprep_manifest_path="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "guestprep_manifest_path")"
  manifest_schema_version="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "manifest_schema_version")"
  manifest_sha256="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "manifest_sha256")"
  guestprep_checkpoint_sequence="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "guestprep_checkpoint_sequence")"
  source_fence_state="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "source_fence_state")"
  scheduler_recovery_state="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "scheduler_recovery_state")"
  test_domain_name="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "test_domain_name")"
  test_domain_state="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "test_domain_state")"
  test_boot_validation_mode="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "test_boot_validation_mode")"
  failover_session_id="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "failover_session_id")"
  failover_mode="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "failover_mode")"
  failover_restore_point_ref="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "failover_restore_point_ref")"
  failover_restore_point_sequence="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "failover_restore_point_sequence")"
  failover_manifest_path="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "failover_manifest_path")"
  failover_checkpoint_path="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "failover_checkpoint_path")"
  failover_requested_at="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "failover_requested_at")"
  restore_point_locked_at="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "restore_point_locked_at")"
  target_promote_started_at="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "target_promote_started_at")"
  target_power_on_at="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "target_power_on_at")"
  failover_completed_at="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "failover_completed_at")"
  rto_actual_seconds="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "rto_actual_seconds")"
  active_side="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "active_side")"
  target_power_state="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "target_power_state")"
  target_promotion_state="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "target_promotion_state")"
  boot_validation_state="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "boot_validation_state")"
  cloud_cutover_session_id="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "cloud_cutover_session_id")"
  cloud_authority_generation="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "cloud_authority_generation")"
  engine_ack_state="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "engine_ack_state")"
  engine_ack_at="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "engine_ack_at")"
  failover_worker_pid="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "failover_worker_pid")"
  failback_session_id="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "failback_session_id")"
  failback_mode="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "failback_mode")"
  failback_restore_point_ref="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "failback_restore_point_ref")"
  failback_restore_point_sequence="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "failback_restore_point_sequence")"
  failback_manifest_path="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "failback_manifest_path")"
  failback_checkpoint_path="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "failback_checkpoint_path")"
  failback_requested_at="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "failback_requested_at")"
  reverse_sync_started_at="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "reverse_sync_started_at")"
  reverse_target_ready_at="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "reverse_target_ready_at")"
  source_promote_started_at="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "source_promote_started_at")"
  source_power_on_at="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "source_power_on_at")"
  failback_completed_at="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "failback_completed_at")"
  failback_rto_actual_seconds="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "failback_rto_actual_seconds")"
  source_power_state="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "source_power_state")"
  source_promotion_state="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "source_promotion_state")"
  failback_worker_pid="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "failback_worker_pid")"
  reprotect_session_id="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "reprotect_session_id")"
  reprotect_mode="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "reprotect_mode")"
  reprotect_restore_point_ref="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "reprotect_restore_point_ref")"
  reprotect_restore_point_sequence="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "reprotect_restore_point_sequence")"
  reprotect_manifest_path="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "reprotect_manifest_path")"
  reprotect_checkpoint_path="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "reprotect_checkpoint_path")"
  reprotect_requested_at="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "reprotect_requested_at")"
  reprotect_completed_at="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "reprotect_completed_at")"
  reprotect_rto_actual_seconds="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "reprotect_rto_actual_seconds")"
  reverse_direction="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "reverse_direction")"
  reverse_profile_path="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "reverse_profile_path")"
  reverse_restore_points_path="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "reverse_restore_points_path")"
  reprotect_worker_pid="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "reprotect_worker_pid")"
  target_vm_id="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "target_vm_id")"
  target_external_ref="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "target_external_ref")"
  dynamic_rpo="$(ftctl_dr_runtime_rpo_from_target_at "${last_target}" 2>/dev/null || true)"
  [[ -n "${dynamic_rpo}" ]] && target_rpo="${dynamic_rpo}"
  target_vm_present="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "target_vm_present")"
  [[ -n "${target_vm_present}" ]] || {
    if [[ -n "${target_vm_id}" || -n "${target_external_ref}" ]]; then
      target_vm_present="true"
    else
      target_vm_present="false"
    fi
  }
  target_storage_present="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "target_storage_present")"
  [[ -n "${target_storage_present}" ]] || {
    if [[ -n "${last_target}" || -n "${checkpoint_path}" || -n "${manifest_path}" ]]; then
      target_storage_present="true"
    else
      target_storage_present="false"
    fi
  }
  restore_point_present="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "restore_point_present")"
  [[ -n "${restore_point_present}" ]] || {
    if [[ -n "${last_target}" || ( -n "${restore_points_path}" && -s "${restore_points_path}" ) ]]; then
      restore_point_present="true"
    else
      restore_point_present="false"
    fi
  }
  target_network_present="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "target_network_present")"
  [[ -n "${target_network_present}" ]] || target_network_present="${target_vm_present}"
  target_materialized="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "target_materialized")"
  [[ -n "${target_materialized}" ]] || {
    if [[ "${target_vm_present}" == "true" && "${target_storage_present}" == "true" && "${target_network_present}" == "true" && "${restore_point_present}" == "true" ]]; then
      target_materialized="true"
    else
      target_materialized="false"
    fi
  }

  [[ -n "${run}" ]] && status_scope="OPERATION" || status_scope="PLAN_AUTHORITY"
  printf '{"command":"%s","result":"%s"' \
    "$(ftctl__json_escape "${command}")" \
    "$(ftctl__json_escape "${result}")"
  ftctl_dr_runtime_json_string_field "plan_uuid" "${plan}"
  ftctl_dr_runtime_json_string_field "status_scope" "${status_scope}"
  [[ -n "${run}" ]] && ftctl_dr_runtime_json_string_field "run_uuid" "${run}"
  ftctl_dr_runtime_json_string_field "action" "${action}"
  ftctl_dr_runtime_json_string_field "state" "${state:-PLANNED}"
  ftctl_dr_runtime_json_string_field "step" "${step:-planned}"
  ftctl_dr_runtime_json_number_field "progress" "${progress:-0}"
  ftctl_dr_runtime_json_string_field "external_job_ref" "${external_job_ref:-${run}}"
  printf ',"runtime_exists":%s,"profile_exists":%s,"run_exists":%s' "${runtime_exists}" "${profile_exists}" "${run_exists}"
  ftctl_dr_runtime_json_string_field "last_source_checkpoint_at" "${last_source}"
  ftctl_dr_runtime_json_string_field "last_target_durable_at" "${last_target}"
  ftctl_dr_runtime_json_number_field "target_ready_rpo_seconds" "${target_rpo}"
  ftctl_dr_runtime_json_boolean_field "target_materialized" "${target_materialized}" || return $?
  ftctl_dr_runtime_json_boolean_field "target_vm_present" "${target_vm_present}" || return $?
  ftctl_dr_runtime_json_boolean_field "target_storage_present" "${target_storage_present}" || return $?
  ftctl_dr_runtime_json_boolean_field "target_network_present" "${target_network_present}" || return $?
  ftctl_dr_runtime_json_boolean_field "restore_point_present" "${restore_point_present}" || return $?
  ftctl_dr_runtime_json_string_field "target_vm_id" "${target_vm_id}"
  ftctl_dr_runtime_json_string_field "target_external_ref" "${target_external_ref}"
  ftctl_dr_runtime_json_string_field "source_firmware" "${source_firmware}"
  ftctl_dr_runtime_json_boolean_field "source_secure_boot" "${source_secure_boot}" || return $?
  ftctl_dr_runtime_json_string_field "source_hardware_fingerprint" "${source_hardware_fingerprint}"
  ftctl_dr_runtime_json_string_field "target_boot_type" "${target_boot_type}"
  ftctl_dr_runtime_json_string_field "target_boot_mode" "${target_boot_mode}"
  ftctl_dr_runtime_json_string_field "target_io_policy" "${target_io_policy}"
  ftctl_dr_runtime_json_boolean_field "target_iothreads" "${target_iothreads}" || return $?
  ftctl_dr_runtime_json_string_field "error_code" "${error_code}"
  ftctl_dr_runtime_json_string_field "error_message" "${error_message}"
  ftctl_dr_runtime_json_string_field "failed_component" "${failed_component:-ftctl}"
  ftctl_dr_runtime_json_string_field "data_commit_state" "${data_commit_state}"
  ftctl_dr_runtime_json_boolean_field "data_copied" "${data_copied}" || return $?
  ftctl_dr_runtime_json_boolean_field "metadata_committed" "${metadata_committed}" || return $?
  ftctl_dr_runtime_json_boolean_field "target_durable" "${target_durable}" || return $?
  ftctl_dr_runtime_json_string_field "cycle_retry_mode" "${cycle_retry_mode}"
  ftctl_dr_runtime_json_number_field "driver_exit_code" "${driver_exit_code}"
  ftctl_dr_runtime_json_string_field "updated_at" "${updated}"
  ftctl_dr_runtime_json_string_field "driver" "${driver}"
  ftctl_dr_runtime_json_string_field "driver_state" "${driver_state}"
  ftctl_dr_runtime_json_string_field "disk_map_path" "${disk_map_path}"
  ftctl_dr_runtime_json_string_field "source_disk_map_path" "${source_disk_map_path}"
  ftctl_dr_runtime_json_string_field "target_disk_map_path" "${target_disk_map_path}"
  ftctl_dr_runtime_json_string_field "disk_map_role" "${disk_map_role}"
  ftctl_dr_runtime_json_number_field "target_disk_count" "${target_disk_count}"
  ftctl_dr_runtime_json_number_field "target_disk_invalid_count" "${target_disk_invalid_count}"
  ftctl_dr_runtime_json_string_field "manifest_path" "${manifest_path}"
  ftctl_dr_runtime_json_string_field "checkpoint_path" "${checkpoint_path}"
  ftctl_dr_runtime_json_string_field "cbt_status_path" "${cbt_status_path}"
  ftctl_dr_runtime_json_file_field_redacted "cbt_status" "${cbt_status_path}"
  ftctl_dr_runtime_json_string_field "source_open_status_path" "${source_open_status_path}"
  ftctl_dr_runtime_json_file_field_redacted "source_open" "${source_open_status_path}"
  ftctl_dr_runtime_json_string_field "source_snapshot_status_path" "${source_snapshot_status_path}"
  ftctl_dr_runtime_json_file_field_redacted "source_snapshot" "${source_snapshot_status_path}"
  ftctl_dr_runtime_json_string_field "scheduler_state" "${scheduler_state}"
  ftctl_dr_runtime_json_number_field "runtime_generation" "${runtime_generation}"
  ftctl_dr_runtime_json_boolean_field "scheduler_pid_alive" "${scheduler_pid_alive}" || return $?
  ftctl_dr_runtime_json_string_field "scheduler_session_uuid" "${scheduler_session_uuid}"
  ftctl_dr_runtime_json_number_field "scheduler_lease_epoch" "${scheduler_lease_epoch}"
  ftctl_dr_runtime_json_number_field "authority_sequence" "${authority_sequence}"
  ftctl_dr_runtime_json_number_field "plan_cycle_sequence" "${plan_cycle_sequence}"
  ftctl_dr_runtime_json_string_field "scheduler_health" "${scheduler_health}"
  ftctl_dr_runtime_json_string_field "scheduler_desired_state" "${scheduler_desired_state}"
  ftctl_dr_runtime_json_string_field "scheduler_service_unit" "${scheduler_service_unit}"
  ftctl_dr_runtime_json_string_field "scheduler_unit_active_state" "${scheduler_unit_active_state}"
  ftctl_dr_runtime_json_string_field "scheduler_unit_sub_state" "${scheduler_unit_sub_state}"
  ftctl_dr_runtime_json_number_field "scheduler_unit_main_pid" "${scheduler_unit_main_pid}"
  ftctl_dr_runtime_json_string_field "scheduler_cgroup" "${scheduler_cgroup}"
  ftctl_dr_runtime_json_string_field "scheduler_recovery_state" "${scheduler_recovery_state}"
  ftctl_dr_runtime_json_string_field "scheduler_recovery_trigger" "${scheduler_recovery_trigger}"
  ftctl_dr_runtime_json_string_field "scheduler_recovered_at" "${scheduler_recovered_at}"
  ftctl_dr_runtime_json_string_field "nbd_teardown_state" "${nbd_teardown_state}"
  ftctl_dr_runtime_json_number_field "nbd_quarantined_device_count" "${nbd_quarantined_device_count}"
  ftctl_dr_runtime_json_string_field "nbd_teardown_error_code" "${nbd_teardown_error_code}"
  ftctl_dr_runtime_json_string_field "nbd_teardown_error_message" "${nbd_teardown_error_message}"
  ftctl_dr_runtime_json_string_field "replication_activity" "${replication_activity}"
  ftctl_dr_runtime_json_string_field "protection_state" "${protection_state}"
  ftctl_dr_runtime_json_string_field "active_worker_run_uuid" "${active_worker_run_uuid}"
  ftctl_dr_runtime_json_number_field "active_worker_pid" "${active_worker_pid}"
  ftctl_dr_runtime_json_number_field "active_worker_start_ticks" "${active_worker_start_ticks}"
  ftctl_dr_runtime_json_string_field "worker_heartbeat_at" "${worker_heartbeat_at}"
  ftctl_dr_runtime_json_string_field "control_request_run_uuid" "${control_request_run_uuid}"
  ftctl_dr_runtime_json_boolean_field "owner_matched" "${owner_matched}" || return $?
  ftctl_dr_runtime_json_string_field "baseline_state" "${baseline_state}"
  ftctl_dr_runtime_json_string_field "reseed_reason" "${reseed_reason}"
  ftctl_dr_runtime_json_number_field "consecutive_automatic_reseed_count" "${consecutive_automatic_reseed_count}"
  ftctl_dr_runtime_json_number_field "control_protocol_version" "${control_protocol_version}"
  ftctl_dr_runtime_json_number_field "control_generation" "${control_generation}"
  ftctl_dr_runtime_json_number_field "control_ack_generation" "${control_ack_generation}"
  ftctl_dr_runtime_json_string_field "control_state" "${control_state}"
  ftctl_dr_runtime_json_string_field "cycle_state" "${cycle_state}"
  ftctl_dr_runtime_json_string_field "transition_state" "${transition_state}"
  ftctl_dr_runtime_json_string_field "transition_action" "${transition_action}"
  ftctl_dr_runtime_json_string_field "transition_quiesced_at" "${transition_quiesced_at}"
  ftctl_dr_runtime_json_string_field "checkpoint_lease_state" "${checkpoint_lease_state}"
  ftctl_dr_runtime_json_string_field "checkpoint_lease_path" "${checkpoint_lease_path}"
  ftctl_dr_runtime_json_number_field "worker_pid" "${worker_pid}"
  ftctl_dr_runtime_json_string_field "worker_state" "${worker_state}"
  ftctl_dr_runtime_json_string_field "worker_started_at" "${worker_started_at}"
  ftctl_dr_runtime_json_string_field "worker_updated_at" "${worker_updated_at}"
  ftctl_dr_runtime_json_number_field "worker_exit_code" "${worker_exit_code}"
  ftctl_dr_runtime_json_boolean_field "retryable" "${retryable}" || return $?
  ftctl_dr_runtime_json_number_field "retry_after_sec" "${retry_after_sec}"
  ftctl_dr_runtime_json_string_field "lock_file" "${lock_file}"
  ftctl_dr_runtime_json_number_field "holder_pid" "${holder_pid}"
  ftctl_dr_runtime_json_string_field "holder_command" "${holder_command}"
  ftctl_dr_runtime_json_number_field "holder_age_sec" "${holder_age_sec}"
  ftctl_dr_runtime_json_number_field "checkpoint_sequence" "${checkpoint_sequence}"
  ftctl_dr_runtime_json_number_field "current_checkpoint_sequence" "${current_checkpoint_sequence}"
  ftctl_dr_runtime_json_string_field "current_checkpoint_cycle_type" "${current_checkpoint_cycle_type}"
  ftctl_dr_runtime_json_string_field "current_checkpoint_requested_mode" "${current_checkpoint_requested_mode}"
  ftctl_dr_runtime_json_string_field "current_checkpoint_effective_mode" "${current_checkpoint_effective_mode}"
  ftctl_dr_runtime_json_string_field "current_checkpoint_mode_decision_code" "${current_checkpoint_mode_decision_code}"
  ftctl_dr_runtime_json_boolean_field "current_checkpoint_automatic_reseed" "${current_checkpoint_automatic_reseed:-false}" || return $?
  ftctl_dr_runtime_json_number_field "current_checkpoint_invalid_baseline_disk_count" "${current_checkpoint_invalid_baseline_disk_count}"
  ftctl_dr_runtime_json_string_field "current_checkpoint_ref" "${current_checkpoint_ref}"
  ftctl_dr_runtime_json_string_field "current_checkpoint_state" "${current_checkpoint_state}"
  ftctl_dr_runtime_json_number_field "latest_completed_checkpoint_sequence" "${latest_completed_checkpoint_sequence}"
  ftctl_dr_runtime_json_string_field "latest_completed_checkpoint_cycle_type" "${latest_completed_checkpoint_cycle_type}"
  ftctl_dr_runtime_json_string_field "latest_completed_checkpoint_ref" "${latest_completed_checkpoint_ref}"
  ftctl_dr_runtime_json_string_field "latest_completed_checkpoint_state" "${latest_completed_checkpoint_state}"
  ftctl_dr_runtime_json_string_field "latest_completed_producer_run_uuid" "${latest_completed_producer_run_uuid}"
  ftctl_dr_runtime_json_string_field "latest_completed_source_checkpoint_at" "${latest_completed_source_checkpoint_at}"
  ftctl_dr_runtime_json_string_field "latest_completed_target_durable_at" "${latest_completed_target_durable_at}"
  ftctl_dr_runtime_json_number_field "latest_completed_target_ready_rpo_seconds" "${latest_completed_target_ready_rpo_seconds}"
  ftctl_dr_runtime_json_string_field "latest_completed_manifest_path" "${latest_completed_manifest_path}"
  ftctl_dr_runtime_json_string_field "latest_completed_checkpoint_path" "${latest_completed_checkpoint_path}"
  ftctl_dr_runtime_json_string_field "latest_completed_requested_mode" "${latest_completed_requested_mode}"
  ftctl_dr_runtime_json_string_field "latest_completed_effective_mode" "${latest_completed_effective_mode}"
  ftctl_dr_runtime_json_string_field "latest_completed_mode_decision_code" "${latest_completed_mode_decision_code}"
  ftctl_dr_runtime_json_string_field "latest_completed_reseed_reason" "${latest_completed_reseed_reason}"
  ftctl_dr_runtime_json_boolean_field "latest_completed_automatic_reseed" "${latest_completed_automatic_reseed:-false}" || return $?
  ftctl_dr_runtime_json_number_field "latest_completed_invalid_baseline_disk_count" "${latest_completed_invalid_baseline_disk_count}"
  ftctl_dr_runtime_json_boolean_field "latest_completed_incremental_verified" "${latest_completed_incremental_verified}" || return $?
  ftctl_dr_runtime_json_boolean_field "latest_completed_metrics_estimated" "${latest_completed_metrics_estimated}" || return $?
  ftctl_dr_runtime_json_number_field "latest_completed_virtual_bytes" "${latest_completed_virtual_bytes}"
  ftctl_dr_runtime_json_number_field "latest_completed_changed_bytes" "${latest_completed_changed_bytes}"
  ftctl_dr_runtime_json_number_field "latest_completed_source_read_bytes" "${latest_completed_source_read_bytes}"
  ftctl_dr_runtime_json_number_field "latest_completed_target_written_bytes" "${latest_completed_target_written_bytes}"
  ftctl_dr_runtime_json_number_field "latest_completed_transfer_payload_bytes" "${latest_completed_transfer_payload_bytes}"
  ftctl_dr_runtime_json_number_field "latest_completed_changed_extent_count" "${latest_completed_changed_extent_count}"
  ftctl_dr_runtime_json_number_field "latest_completed_duration_ms" "${latest_completed_duration_ms}"
  ftctl_dr_runtime_json_number_field "latest_completed_throughput_bps" "${latest_completed_throughput_bps}"
  ftctl_dr_runtime_json_number_field "latest_completed_baseline_generation" "${latest_completed_baseline_generation}"
  ftctl_dr_runtime_json_string_field "latest_completed_cycle_token" "${latest_completed_cycle_token}"
  ftctl_dr_runtime_json_string_field "latest_completed_cycle_metrics_path" "${latest_completed_cycle_metrics_path}"
  ftctl_dr_runtime_json_string_field "latest_completed_nbd_teardown_state" "${latest_completed_nbd_teardown_state}"
  ftctl_dr_runtime_json_number_field "latest_completed_nbd_teardown_started_at_ms" "${latest_completed_nbd_teardown_started_at_ms}"
  ftctl_dr_runtime_json_number_field "latest_completed_nbd_teardown_completed_at_ms" "${latest_completed_nbd_teardown_completed_at_ms}"
  ftctl_dr_runtime_json_number_field "latest_completed_nbd_teardown_duration_ms" "${latest_completed_nbd_teardown_duration_ms}"
  ftctl_dr_runtime_json_number_field "latest_completed_nbd_source_device_count" "${latest_completed_nbd_source_device_count}"
  ftctl_dr_runtime_json_number_field "latest_completed_nbd_target_device_count" "${latest_completed_nbd_target_device_count}"
  ftctl_dr_runtime_json_number_field "latest_completed_nbd_quarantined_device_count" "${latest_completed_nbd_quarantined_device_count}"
  ftctl_dr_runtime_json_string_field "latest_completed_nbd_teardown_error_code" "${latest_completed_nbd_teardown_error_code}"
  ftctl_dr_runtime_json_string_field "latest_completed_nbd_teardown_error_message" "${latest_completed_nbd_teardown_error_message}"
  ftctl_dr_runtime_json_file_field_redacted "latest_completed_cycle_metrics" "${latest_completed_cycle_metrics_path}"
  ftctl_dr_runtime_json_string_field "restore_points_path" "${restore_points_path}"
  ftctl_dr_runtime_json_string_field "test_session_id" "${test_session_id}"
  ftctl_dr_runtime_json_string_field "test_session_path" "${test_session_path}"
  ftctl_dr_runtime_json_file_field_redacted "test_session" "${test_session_path}"
  ftctl_dr_runtime_json_string_field "test_session_state" "${test_session_state}"
  ftctl_dr_runtime_json_string_field "test_restore_point_ref" "${test_restore_point_ref}"
  ftctl_dr_runtime_json_number_field "test_restore_point_sequence" "${test_restore_point_sequence}"
  ftctl_dr_runtime_json_string_field "test_manifest_path" "${test_manifest_path}"
  ftctl_dr_runtime_json_string_field "test_checkpoint_path" "${test_checkpoint_path}"
  ftctl_dr_runtime_json_string_field "test_artifacts_state" "${test_artifacts_state}"
  ftctl_dr_runtime_json_string_field "test_artifacts_path" "${test_artifacts_path}"
  ftctl_dr_runtime_json_number_field "test_artifact_count" "${test_artifact_count}"
  ftctl_dr_runtime_json_string_field "guest_prep_state" "${guest_prep_state}"
  ftctl_dr_runtime_json_string_field "guest_family" "${guest_family}"
  ftctl_dr_runtime_json_string_field "guestprep_manifest_path" "${guestprep_manifest_path}"
  ftctl_dr_runtime_json_string_field "manifest_schema_version" "${manifest_schema_version}"
  ftctl_dr_runtime_json_string_field "manifest_sha256" "${manifest_sha256}"
  ftctl_dr_runtime_json_number_field "guestprep_checkpoint_sequence" "${guestprep_checkpoint_sequence}"
  ftctl_dr_runtime_json_string_field "source_fence_state" "${source_fence_state}"
  ftctl_dr_runtime_json_string_field "scheduler_recovery_state" "${scheduler_recovery_state}"
  ftctl_dr_runtime_json_string_field "test_domain_name" "${test_domain_name}"
  ftctl_dr_runtime_json_string_field "test_domain_state" "${test_domain_state}"
  ftctl_dr_runtime_json_string_field "test_boot_validation_mode" "${test_boot_validation_mode}"
  ftctl_dr_runtime_json_string_field "failover_session_id" "${failover_session_id}"
  ftctl_dr_runtime_json_string_field "failover_mode" "${failover_mode}"
  ftctl_dr_runtime_json_string_field "failover_restore_point_ref" "${failover_restore_point_ref}"
  ftctl_dr_runtime_json_number_field "failover_restore_point_sequence" "${failover_restore_point_sequence}"
  ftctl_dr_runtime_json_string_field "failover_manifest_path" "${failover_manifest_path}"
  ftctl_dr_runtime_json_string_field "failover_checkpoint_path" "${failover_checkpoint_path}"
  ftctl_dr_runtime_json_string_field "failover_requested_at" "${failover_requested_at}"
  ftctl_dr_runtime_json_string_field "restore_point_locked_at" "${restore_point_locked_at}"
  ftctl_dr_runtime_json_string_field "target_promote_started_at" "${target_promote_started_at}"
  ftctl_dr_runtime_json_string_field "target_power_on_at" "${target_power_on_at}"
  ftctl_dr_runtime_json_string_field "failover_completed_at" "${failover_completed_at}"
  ftctl_dr_runtime_json_number_field "rto_actual_seconds" "${rto_actual_seconds}"
  ftctl_dr_runtime_json_string_field "active_side" "${active_side}"
  ftctl_dr_runtime_json_string_field "target_power_state" "${target_power_state}"
  ftctl_dr_runtime_json_string_field "target_promotion_state" "${target_promotion_state}"
  ftctl_dr_runtime_json_string_field "boot_validation_state" "${boot_validation_state}"
  ftctl_dr_runtime_json_string_field "cloud_cutover_session_id" "${cloud_cutover_session_id}"
  ftctl_dr_runtime_json_number_field "cloud_authority_generation" "${cloud_authority_generation}"
  ftctl_dr_runtime_json_string_field "engine_ack_state" "${engine_ack_state}"
  ftctl_dr_runtime_json_string_field "engine_ack_at" "${engine_ack_at}"
  ftctl_dr_runtime_json_number_field "failover_worker_pid" "${failover_worker_pid}"
  ftctl_dr_runtime_json_string_field "failback_session_id" "${failback_session_id}"
  ftctl_dr_runtime_json_string_field "failback_mode" "${failback_mode}"
  ftctl_dr_runtime_json_string_field "failback_restore_point_ref" "${failback_restore_point_ref}"
  ftctl_dr_runtime_json_number_field "failback_restore_point_sequence" "${failback_restore_point_sequence}"
  ftctl_dr_runtime_json_string_field "failback_manifest_path" "${failback_manifest_path}"
  ftctl_dr_runtime_json_string_field "failback_checkpoint_path" "${failback_checkpoint_path}"
  ftctl_dr_runtime_json_string_field "failback_requested_at" "${failback_requested_at}"
  ftctl_dr_runtime_json_string_field "reverse_sync_started_at" "${reverse_sync_started_at}"
  ftctl_dr_runtime_json_string_field "reverse_target_ready_at" "${reverse_target_ready_at}"
  ftctl_dr_runtime_json_string_field "source_promote_started_at" "${source_promote_started_at}"
  ftctl_dr_runtime_json_string_field "source_power_on_at" "${source_power_on_at}"
  ftctl_dr_runtime_json_string_field "failback_completed_at" "${failback_completed_at}"
  ftctl_dr_runtime_json_number_field "failback_rto_actual_seconds" "${failback_rto_actual_seconds}"
  ftctl_dr_runtime_json_string_field "source_power_state" "${source_power_state}"
  ftctl_dr_runtime_json_string_field "source_promotion_state" "${source_promotion_state}"
  ftctl_dr_runtime_json_number_field "failback_worker_pid" "${failback_worker_pid}"
  ftctl_dr_runtime_json_string_field "reprotect_session_id" "${reprotect_session_id}"
  ftctl_dr_runtime_json_string_field "reprotect_mode" "${reprotect_mode}"
  ftctl_dr_runtime_json_string_field "reprotect_restore_point_ref" "${reprotect_restore_point_ref}"
  ftctl_dr_runtime_json_number_field "reprotect_restore_point_sequence" "${reprotect_restore_point_sequence}"
  ftctl_dr_runtime_json_string_field "reprotect_manifest_path" "${reprotect_manifest_path}"
  ftctl_dr_runtime_json_string_field "reprotect_checkpoint_path" "${reprotect_checkpoint_path}"
  ftctl_dr_runtime_json_string_field "reprotect_requested_at" "${reprotect_requested_at}"
  ftctl_dr_runtime_json_string_field "reprotect_completed_at" "${reprotect_completed_at}"
  ftctl_dr_runtime_json_number_field "reprotect_rto_actual_seconds" "${reprotect_rto_actual_seconds}"
  ftctl_dr_runtime_json_string_field "reverse_direction" "${reverse_direction}"
  ftctl_dr_runtime_json_string_field "reverse_profile_path" "${reverse_profile_path}"
  ftctl_dr_runtime_json_string_field "reverse_restore_points_path" "${reverse_restore_points_path}"
  ftctl_dr_runtime_json_number_field "reprotect_worker_pid" "${reprotect_worker_pid}"
  if [[ "${accepted}" == "false" ]]; then
    printf ',"accepted":false'
  else
    printf ',"accepted":true'
  fi
  ftctl_dr_runtime_emit_events_since "${plan}" "${events_offset}" "${events_limit:-20}"
  printf ',"exit_code":0}\n'
  ftctl_dr_runtime_state_snapshot_end
}

ftctl_dr_runtime_emit_error_json() {
  local command="${1-}" plan="${2-}" run="${3-}" error_code="${4-}" message="${5-}" rc="${6-10}"
  printf '{"command":"%s","result":"error","plan_uuid":"%s"' \
    "$(ftctl__json_escape "${command}")" \
    "$(ftctl__json_escape "${plan}")"
  [[ -n "${run}" ]] && printf ',"run_uuid":"%s"' "$(ftctl__json_escape "${run}")"
  printf ',"accepted":false,"state":"ERROR","step":"error","progress":100,"error_code":"%s","message":"%s","exit_code":%s}\n' \
    "$(ftctl__json_escape "${error_code}")" \
    "$(ftctl__json_escape "${message}")" \
    "${rc}"
}

ftctl_dr_runtime_write_state() {
  local path="${1-}" plan="${2-}" run="${3-}" action="${4-}" state="${5-}" step="${6-}" progress="${7-}" external_ref="${8-}" error_code="${9-}"
  local now
  now="$(ftctl_now_iso8601)"
  ftctl_ensure_dir "$(dirname "${path}")" "0755"
  ftctl_state_write_kv_all "${path}" \
    "plan=${plan}" \
    "run=${run}" \
    "action=${action}" \
    "state=${state}" \
    "step=${step}" \
    "progress=${progress}" \
    "accepted=true" \
    "external_job_ref=${external_ref}" \
    "last_source_checkpoint_at=${now}" \
    "last_target_durable_at=" \
    "target_ready_rpo_seconds=" \
    "error_code=${error_code}" \
    "updated_at=${now}"
}

ftctl_dr_runtime_action_state() {
  local action="${1-}"
  case "${action}" in
    dr-sync-start) printf 'SYNCING|sync-start-accepted|1\n' ;;
    dr-sync-recover) printf 'SYNCING|scheduler-recovery-accepted|1\n' ;;
    dr-sync-pause) printf 'PAUSED|sync-paused|100\n' ;;
    dr-sync-resume) printf 'SYNCING|sync-resumed|1\n' ;;
    dr-test-failover) printf 'TESTING|test-failover-accepted|1\n' ;;
    dr-test-prepare) printf 'TESTING|test-artifact-prepare-accepted|1\n' ;;
    dr-test-cleanup|dr-test-artifact-cleanup) printf 'READY|test-cleanup-completed|100\n' ;;
    dr-failover) printf 'RUNNING|failover-accepted|1\n' ;;
    dr-failback) printf 'RUNNING|failback-accepted|1\n' ;;
    dr-reprotect) printf 'RUNNING|reprotect-accepted|1\n' ;;
    dr-release) printf 'RELEASED|release-completed|100\n' ;;
    *) printf 'RUNNING|accepted|1\n' ;;
  esac
}

ftctl_dr_runtime_require_plan() {
  local plan="${1-}"
  [[ -n "${plan}" ]] || {
    echo "ERROR: --plan is required" >&2
    return 2
  }
}

ftctl_dr_runtime_require_run() {
  local run="${1-}"
  [[ -n "${run}" ]] || {
    echo "ERROR: --run is required" >&2
    return 2
  }
}

ftctl_dr_runtime_plan_apply() {
  local plan="${1-}" profile_file="${2-}" role="${3-}" dry_run="${4-0}" json="${5-0}"
  local profile_plan direction now status_path capable error_code details_json vmware_capable

  ftctl_dr_runtime_require_plan "${plan}" || return 2
  ftctl_dr_runtime_validate_profile_file "${profile_file}" || {
    [[ "${json}" == "1" ]] && ftctl_dr_runtime_emit_error_json "dr-plan-apply" "${plan}" "" "profile_invalid" "profile JSON is missing or invalid" 2
    return 2
  }

  profile_plan="$(ftctl_dr_runtime_profile_value "${profile_file}" "planUuid" || true)"
  direction="$(ftctl_dr_runtime_profile_value "${profile_file}" "direction" || true)"
  if [[ -n "${profile_plan}" && "${profile_plan}" != "${plan}" ]]; then
    [[ "${json}" == "1" ]] && ftctl_dr_runtime_emit_error_json "dr-plan-apply" "${plan}" "" "plan_mismatch" "profile planUuid does not match --plan" 2
    return 2
  fi

  capable="true"
  error_code=""
  details_json=""
  if command -v ftctl_dr_vmware_preflight_json >/dev/null 2>&1 &&
      ftctl_dr_vmware_profile_involves_vmware "${profile_file}"; then
    details_json="$(ftctl_dr_vmware_preflight_json "${plan}" "${profile_file}" "${role}" "${dry_run}")"
    vmware_capable="$(ftctl_dr_runtime_json_text_value "${details_json}" "capable")"
    if [[ "${vmware_capable}" != "true" ]]; then
      capable="false"
      error_code="$(ftctl_dr_runtime_json_text_value "${details_json}" "error_code")"
      [[ -n "${error_code}" ]] || error_code="DR_VMWARE_PREFLIGHT_FAILED"
    fi
  fi

  if [[ "${dry_run}" != "1" && "${capable}" == "true" ]]; then
    ftctl_dr_runtime_save_profile "${plan}" "${profile_file}" || return $?
    now="$(ftctl_now_iso8601)"
    status_path="$(ftctl_dr_runtime_status_path "${plan}")"
    ftctl_state_write_kv_all "${status_path}" \
      "plan=${plan}" \
      "run=" \
      "action=dr-plan-apply" \
      "state=PLANNED" \
      "step=profile-applied" \
      "progress=0" \
      "accepted=true" \
      "external_job_ref=" \
      "last_source_checkpoint_at=" \
      "last_target_durable_at=" \
      "target_ready_rpo_seconds=" \
      "error_code=" \
      "updated_at=${now}"
    ftctl_log_event "dr-runtime" "dr.plan.apply" "ok" "" "" \
      "plan=${plan} role=${role:-} direction=${direction:-} dry_run=0"
  elif [[ "${dry_run}" != "1" ]]; then
    ftctl_log_event "dr-runtime" "dr.plan.apply" "fail" "" "${error_code}" \
      "plan=${plan} role=${role:-} direction=${direction:-} dry_run=0 capable=false"
  else
    if [[ "${capable}" == "true" ]]; then
      ftctl_log_event "dr-runtime" "dr.plan.apply" "ok" "" "" \
        "plan=${plan} role=${role:-} direction=${direction:-} dry_run=1"
    else
      ftctl_log_event "dr-runtime" "dr.plan.apply" "fail" "" "${error_code}" \
        "plan=${plan} role=${role:-} direction=${direction:-} dry_run=1 capable=false"
    fi
  fi

  if [[ "${json}" == "1" ]]; then
    printf '{"command":"dr-plan-apply","result":"ok","capable":%s,"plan_uuid":"%s","role":"%s","direction":"%s","dry_run":%s' \
      "${capable}" \
      "$(ftctl__json_escape "${plan}")" \
      "$(ftctl__json_escape "${role}")" \
      "$(ftctl__json_escape "${direction}")" \
      "$([[ "${dry_run}" == "1" ]] && printf true || printf false)"
    [[ -n "${error_code}" ]] && ftctl_dr_runtime_json_string_field "error_code" "${error_code}"
    [[ -n "${details_json}" ]] && printf ',"details":%s' "${details_json}"
    printf ',"exit_code":0}\n'
  else
    if [[ -n "${error_code}" ]]; then
      printf 'dr-plan-apply: %s capable=%s direction=%s error=%s\n' "${plan}" "${capable}" "${direction:-unknown}" "${error_code}"
    else
      printf 'dr-plan-apply: %s capable=%s direction=%s\n' "${plan}" "${capable}" "${direction:-unknown}"
    fi
  fi
}

ftctl_dr_runtime_run_log_path() {
  local plan="${1-}" run="${2-}"
  ftctl_dr_runtime_ensure_plan_dirs "${plan}"
  printf '%s/runs/%s.log' "$(ftctl_dr_runtime_plan_dir "${plan}")" "${run}"
}

ftctl_dr_runtime_should_delegate_action() {
  local action="${1-}" wait_value="${2-}" dry_run="${3-0}"
  local wait_lower

  [[ "${dry_run}" != "1" ]] || return 1
  [[ "${FTCTL_DR_RUNTIME_WORKER:-0}" != "1" ]] || return 1
  case "${action}" in
    dr-sync-start)
      [[ "${FTCTL_DR_SYNC_FOREGROUND:-0}" != "1" ]] || return 1
      [[ "${FTCTL_DR_SCHEDULER_FOREGROUND:-0}" != "1" ]] || return 1
      ;;
    dr-test-failover|dr-test-prepare)
      [[ "${FTCTL_DR_TEST_FAILOVER_FOREGROUND:-0}" != "1" ]] || return 1
      ;;
    dr-failover)
      [[ "${FTCTL_DR_FAILOVER_FOREGROUND:-0}" != "1" ]] || return 1
      ;;
    dr-failback)
      [[ "${FTCTL_DR_FAILBACK_FOREGROUND:-0}" != "1" ]] || return 1
      ;;
    dr-reprotect)
      [[ "${FTCTL_DR_REPROTECT_FOREGROUND:-0}" != "1" ]] || return 1
      ;;
    dr-sync-pause|dr-sync-resume|dr-test-cleanup|dr-test-artifact-cleanup|dr-release)
      ;;
  esac
  wait_lower="$(printf '%s' "${wait_value}" | tr '[:upper:]' '[:lower:]')"
  [[ "${wait_lower}" == "false" || "${wait_lower}" == "0" || "${wait_lower}" == "no" ]] || return 1

  case "${action}" in
    dr-sync-start|dr-sync-recover|dr-sync-pause|dr-sync-resume|dr-test-failover|dr-test-prepare|dr-test-cleanup|dr-test-artifact-cleanup|dr-failover|dr-failback|dr-reprotect|dr-release) return 0 ;;
    *) return 1 ;;
  esac
}

ftctl_dr_runtime_start_background_worker() {
  local action="${1-}" plan="${2-}" run="${3-}" role="${4-}" mode="${5-}" restore_point="${6-}" force="${7-0}" dry_run="${8-0}" artifact_spec_path="${9-}" authority_spec_path="${10-}" log_path ftctl_bin profile_path
  local run_path status_path now worker_pid
  local -a worker_cmd

  log_path="$(ftctl_dr_runtime_run_log_path "${plan}" "${run}")"
  profile_path="$(ftctl_dr_runtime_profile_path "${plan}")"
  run_path="$(ftctl_dr_runtime_run_path "${plan}" "${run}")"
  status_path="$(ftctl_dr_runtime_status_path "${plan}")"
  now="$(ftctl_now_iso8601)"
  ftctl_dr_runtime_path_set "${run_path}" \
    "worker_state=STARTING" \
    "worker_pid=" \
    "worker_started_at=${now}" \
    "worker_updated_at=${now}" \
    "worker_exit_code=" \
    "retryable=false" \
    "retry_after_sec=" \
    "lock_file=" \
    "holder_pid=" \
    "holder_command=" \
    "holder_age_sec=" || true
  cp -f "${run_path}" "${status_path}" 2>/dev/null || true
  chmod 0644 "${status_path}" 2>/dev/null || true
  ftctl_bin="${FTCTL_DR_RUNTIME_WORKER_COMMAND:-$(command -v ablestack_vm_ftctl 2>/dev/null || true)}"
  [[ -n "${ftctl_bin}" ]] || ftctl_bin="${0}"
  worker_cmd=("${ftctl_bin}" "${action}" "--plan" "${plan}" "--run" "${run}" "--profile-json" "${profile_path}" "--role" "${role:-coordinator}")
  [[ -n "${FTCTL_CONFIG_PATH:-}" ]] && worker_cmd+=("--config" "${FTCTL_CONFIG_PATH}")
  [[ -n "${mode}" ]] && worker_cmd+=("--mode" "${mode}")
  [[ -n "${restore_point}" ]] && worker_cmd+=("--restore-point" "${restore_point}")
  [[ -n "${artifact_spec_path}" && -f "${artifact_spec_path}" ]] && worker_cmd+=("--artifact-spec-json" "${artifact_spec_path}")
  [[ -n "${authority_spec_path}" && -f "${authority_spec_path}" ]] && worker_cmd+=("--authority-spec-json" "${authority_spec_path}")
  [[ "${force}" == "1" ]] && worker_cmd+=("--force")
  [[ "${dry_run}" == "1" ]] && worker_cmd+=("--dry-run")
  worker_cmd+=("--wait=true" "--json")

  (
    export FTCTL_DR_RUNTIME_WORKER=1
    exec nohup "${worker_cmd[@]}" >>"${log_path}" 2>&1
  ) >/dev/null 2>&1 &
  worker_pid="$!"
  now="$(ftctl_now_iso8601)"
  ftctl_dr_runtime_path_set "${run_path}" \
    "worker_state=STARTED" \
    "worker_pid=${worker_pid}" \
    "worker_updated_at=${now}" || true
  cp -f "${run_path}" "${status_path}" 2>/dev/null || true
  chmod 0644 "${status_path}" 2>/dev/null || true
}

ftctl_dr_runtime_mark_worker_terminal() {
  local run_path="${1-}" status_path="${2-}" state="${3-}" exit_code="${4-0}" error_code="${5-}" retryable="${6-false}" retry_after="${7-}"
  local now

  [[ "${FTCTL_DR_RUNTIME_WORKER:-0}" == "1" && -n "${run_path}" && -f "${run_path}" ]] || return 0
  now="$(ftctl_now_iso8601)"
  ftctl_dr_runtime_path_set "${run_path}" \
    "worker_state=${state}" \
    "worker_pid=$$" \
    "worker_exit_code=${exit_code}" \
    "worker_updated_at=${now}" \
    "retryable=${retryable}" \
    "retry_after_sec=${retry_after}" \
    "error_code=${error_code}" || true
  [[ -n "${status_path}" ]] && cp -f "${run_path}" "${status_path}" 2>/dev/null || true
  [[ -n "${status_path}" ]] && chmod 0644 "${status_path}" 2>/dev/null || true
}

ftctl_dr_runtime_action() {
  local action="${1-}" plan="${2-}" run="${3-}" profile_file="${4-}" role="${5-}" mode="${6-}" restore_point="${7-}" force="${8-0}" dry_run="${9-0}" wait_value="${10-}" json="${11-0}" artifact_spec_file="${12-}" authority_spec_file="${13-}"
  local state_tuple state step progress run_path status_path external_ref rc error_code
  local target_vm_id target_external_ref checkpoint_lease_path test_sequence persisted_artifact_spec="" persisted_authority_spec=""

  ftctl_dr_runtime_require_plan "${plan}" || return 2
  ftctl_dr_runtime_require_run "${run}" || return 2
  if [[ -n "${profile_file}" ]]; then
    ftctl_dr_runtime_save_profile "${plan}" "${profile_file}" || {
      [[ "${json}" == "1" ]] && ftctl_dr_runtime_emit_error_json "${action}" "${plan}" "${run}" "profile_invalid" "profile JSON is missing or invalid" 2
      return 2
    }
  fi
  if [[ "${action}" == "dr-test-prepare" ]]; then
    ftctl_dr_runtime_save_artifact_spec "${plan}" "${run}" "${artifact_spec_file}" || {
      rc=$?
      error_code="DR_TEST_ARTIFACT_LOCATOR_INVALID"
      [[ "${rc}" == "54" ]] && error_code="DR_TEST_ARTIFACT_PROVIDER_UNSUPPORTED"
      [[ "${json}" == "1" ]] && ftctl_dr_runtime_emit_error_json "${action}" "${plan}" "${run}" "artifact_spec_invalid" "artifact locator contract is missing or invalid" "${rc}"
      return "${rc}"
    }
    persisted_artifact_spec="$(ftctl_dr_runtime_artifact_spec_path "${plan}" "${run}")"
  fi
  if [[ "${action}" == "dr-reprotect" && -n "${authority_spec_file}" ]]; then
    ftctl_dr_runtime_save_authority_spec "${plan}" "${run}" "${authority_spec_file}" || {
      rc=$?
      [[ "${json}" == "1" ]] && ftctl_dr_runtime_emit_error_json "${action}" "${plan}" "${run}" \
        "DR_REPROTECT_AUTHORITY_INVALID" "committed authority contract is missing or invalid" "${rc}"
      return "${rc}"
    }
    persisted_authority_spec="$(ftctl_dr_runtime_authority_spec_path "${plan}" "${run}")"
  fi

  state_tuple="$(ftctl_dr_runtime_action_state "${action}")"
  IFS='|' read -r state step progress <<< "${state_tuple}"
  external_ref="${run}"
  run_path="$(ftctl_dr_runtime_run_path "${plan}" "${run}")"
  status_path="$(ftctl_dr_runtime_status_path "${plan}")"
  ftctl_dr_runtime_write_state "${run_path}" "${plan}" "${run}" "${action}" "${state}" "${step}" "${progress}" "${external_ref}" ""
  case "${action}" in
    dr-failback|dr-reprotect)
      ftctl_dr_runtime_capture_authority_context "${plan}" "${run_path}" "${status_path}" "${persisted_authority_spec}" || {
        [[ "${json}" == "1" ]] && ftctl_dr_runtime_emit_error_json "${action}" "${plan}" "${run}" \
          "DR_REPROTECT_AUTHORITY_CONFLICT" "committed authority state does not match FTCTL runtime" 79
        return 79
      }
      ;;
  esac
  if [[ -n "${profile_file}" && -f "${profile_file}" ]]; then
    target_vm_id="$(ftctl_dr_runtime_profile_value "${profile_file}" "target.vmId" || true)"
    [[ -n "${target_vm_id}" ]] || target_vm_id="$(ftctl_dr_runtime_profile_value "${profile_file}" "target.id" || true)"
    target_external_ref="$(ftctl_dr_runtime_profile_value "${profile_file}" "target.externalRef" || true)"
    [[ -n "${target_external_ref}" ]] || target_external_ref="$(ftctl_dr_runtime_profile_value "${profile_file}" "target.vmRef" || true)"
    [[ -n "${target_external_ref}" ]] || target_external_ref="$(ftctl_dr_runtime_profile_value "${profile_file}" "target.uuid" || true)"
    ftctl_dr_runtime_path_set "${run_path}" \
      "target_vm_id=${target_vm_id}" \
      "target_external_ref=${target_external_ref}" \
      "target_vm_present=$([[ -n "${target_vm_id}${target_external_ref}" ]] && printf true || printf false)" \
      "target_network_present=$([[ -n "${target_vm_id}${target_external_ref}" ]] && printf true || printf false)" || true
  fi

  if [[ "${action}" == "dr-sync-recover" && "${dry_run}" != "1" ]]; then
    rc=0
    ftctl_dr_scheduler_recover "${plan}" "${run}" "$(ftctl_dr_runtime_profile_path "${plan}")" \
      "${run_path}" "${status_path}" "MANUAL" || rc=$?
    if [[ "${rc}" != "0" ]]; then
      case "${rc}" in
        41) error_code="DR_RECOVERY_SUPPRESSED_TARGET" ;;
        42) error_code="DR_RECOVERY_SUPPRESSED_CONTROL_STATE" ;;
        43) error_code="DR_RECOVERY_TRANSITION_ACTIVE" ;;
        69) error_code="DR_RECOVERY_UNIT_START_FAILED" ;;
        92) error_code="DR_NBD_TEARDOWN_TIMEOUT" ;;
        93) error_code="DR_NBD_DISCONNECT_FAILED" ;;
        94) error_code="DR_NBD_DEVICE_BUSY" ;;
        95) error_code="DR_NBD_DEVICE_QUARANTINED" ;;
        96) error_code="DR_NBD_TARGET_FLUSH_FAILED" ;;
        *) error_code="DR_RECOVERY_FAILED" ;;
      esac
      ftctl_dr_runtime_path_set "${run_path}" \
        "state=ERROR" \
        "step=scheduler-recovery-failed" \
        "progress=100" \
        "accepted=false" \
        "scheduler_recovery_state=FAILED" \
        "error_code=${error_code}" \
        "updated_at=$(ftctl_now_iso8601)" || true
      [[ "${json}" == "1" ]] && ftctl_dr_runtime_emit_state_json "${action}" "error" "${plan}" "${run}" "${run_path}" "0"
      return "${rc}"
    fi
    ftctl_log_event "dr-runtime" "dr.scheduler.recovery" "ok" "" "" \
      "plan=${plan} run=${run} trigger=MANUAL"
    if [[ "${json}" == "1" ]]; then
      ftctl_dr_runtime_emit_state_json "${action}" "accepted" "${plan}" "${run}" "${run_path}" "0"
    else
      printf '%s: plan=%s run=%s accepted\n' "${action}" "${plan}" "${run}"
    fi
    return 0
  fi

  if ftctl_dr_runtime_should_delegate_action "${action}" "${wait_value}" "${dry_run}"; then
    cp -f "${run_path}" "${status_path}"
    chmod 0644 "${status_path}" 2>/dev/null || true
    command -v ftctl_lock_release >/dev/null 2>&1 && ftctl_lock_release || true
    ftctl_dr_runtime_start_background_worker "${action}" "${plan}" "${run}" "${role}" "${mode}" "${restore_point}" "${force}" "${dry_run}" "${persisted_artifact_spec}" "${persisted_authority_spec}"
    ftctl_log_event "dr-runtime" "dr.action.accepted" "ok" "" "" \
      "plan=${plan} run=${run} action=${action} role=${role:-} mode=${mode:-} restore_point=${restore_point:-} force=${force} dry_run=${dry_run} wait=${wait_value:-} delegated=1"
    if [[ "${json}" == "1" ]]; then
      ftctl_dr_runtime_emit_state_json "${action}" "accepted" "${plan}" "${run}" "${run_path}" "0"
    else
      printf '%s: plan=%s run=%s accepted state=%s step=%s delegated=1\n' "${action}" "${plan}" "${run}" "${state}" "${step}"
    fi
    return 0
  fi

  if [[ "${FTCTL_DR_RUNTIME_WORKER:-0}" == "1" && "${dry_run}" != "1" ]]; then
    ftctl_dr_runtime_path_set "${run_path}" \
      "worker_state=RUNNING" \
      "worker_pid=$$" \
      "worker_started_at=$(ftctl_now_iso8601)" \
      "worker_updated_at=$(ftctl_now_iso8601)" \
      "worker_exit_code=" \
      "retryable=false" \
      "retry_after_sec=" || true
    cp -f "${run_path}" "${status_path}" 2>/dev/null || true
    chmod 0644 "${status_path}" 2>/dev/null || true
  fi

  case "${action}" in
    dr-sync-pause|dr-sync-resume|dr-release)
      if command -v ftctl_dr_scheduler_control_action >/dev/null 2>&1; then
        rc=0
        ftctl_dr_scheduler_control_action "${action}" "${plan}" "${run_path}" "${status_path}" \
          "$(ftctl_dr_runtime_profile_path "${plan}")" || rc=$?
        if [[ "${rc}" != "0" && "${action}" == "dr-sync-resume" ]]; then
          ftctl_dr_runtime_path_set "${run_path}" \
            "state=ERROR" \
            "step=scheduler-recovery-failed" \
            "progress=100" \
            "accepted=false" \
            "scheduler_state=ERROR" \
            "error_code=DR_SCHEDULER_NOT_RUNNING" \
            "error_message=Scheduler recovery did not establish a live worker" \
            "updated_at=$(ftctl_now_iso8601)" || true
          cp -f "${run_path}" "${status_path}" 2>/dev/null || true
          ftctl_dr_runtime_mark_worker_terminal "${run_path}" "${status_path}" "FAILED" "${rc}" "DR_SCHEDULER_NOT_RUNNING" "true" "2"
          [[ "${json}" == "1" ]] && ftctl_dr_runtime_emit_state_json "${action}" "error" "${plan}" "${run}" "${run_path}" "0"
          return "${rc}"
        fi
      fi
      ;;
    dr-test-failover|dr-test-prepare)
      rc=0
      if command -v ftctl_dr_scheduler_transition_begin >/dev/null 2>&1; then
        ftctl_dr_scheduler_transition_begin "${plan}" "${run}" "${action}" "${run_path}" "${status_path}" || rc=$?
      fi
      if [[ "${rc}" != "0" ]]; then
        error_code="DR_SYNC_QUIESCE_TIMEOUT"
        [[ "${rc}" == "20" ]] && error_code="DR_TRANSITION_BUSY_RETRYABLE"
        ftctl_dr_runtime_path_set "${run_path}" \
          "state=ERROR" \
          "step=test-quiesce-failed" \
          "progress=100" \
          "accepted=false" \
          "retryable=$([[ "${rc}" == "20" ]] && printf true || printf false)" \
          "retry_after_sec=$([[ "${rc}" == "20" ]] && printf 2 || printf '')" \
          "error_code=${error_code}" \
          "updated_at=$(ftctl_now_iso8601)" || true
        cp -f "${run_path}" "${status_path}" 2>/dev/null || true
        ftctl_dr_runtime_mark_worker_terminal "${run_path}" "${status_path}" "FAILED" "${rc}" "${error_code}" "$([[ "${rc}" == "20" ]] && printf true || printf false)" "$([[ "${rc}" == "20" ]] && printf 2 || printf '')"
        [[ "${json}" == "1" ]] && ftctl_dr_runtime_emit_state_json "${action}" "error" "${plan}" "${run}" "${run_path}" "0"
        return "${rc}"
      fi
      ftctl_dr_runtime_prepare_test_session "${plan}" "${run}" "${profile_file}" "${restore_point}" "${run_path}" "${status_path}" || rc=$?
      if [[ "${rc}" == "0" ]]; then
        ftctl_dr_runtime_materialize_test_artifacts "${plan}" "${run}" "$(ftctl_dr_runtime_test_session_path "${plan}" "${run}")" "${run_path}" \
          "$(ftctl_dr_runtime_artifact_spec_path "${plan}" "${run}")" || rc=$?
      fi
      if [[ "${rc}" == "0" ]]; then
        if [[ "${action}" == "dr-test-prepare" ]]; then
          ftctl_guestprep_prepare_artifacts "$(ftctl_dr_runtime_test_session_path "${plan}" "${run}")" "${run_path}" || rc=$?
        else
          ftctl_guestprep_prepare_and_start "$(ftctl_dr_runtime_test_session_path "${plan}" "${run}")" "${run_path}" || rc=$?
        fi
        cp -f "$(ftctl_dr_runtime_test_session_path "${plan}" "${run}")" "$(ftctl_dr_runtime_active_test_session_path "${plan}")" 2>/dev/null || true
        test_sequence="$(ftctl_dr_runtime_state_get_from_path "${run_path}" "test_restore_point_sequence")"
        checkpoint_lease_path="$(ftctl_dr_scheduler_checkpoint_lease_acquire "${plan}" "${test_sequence}" "${run}" "$(ftctl_dr_runtime_state_get_from_path "${run_path}" "test_restore_point_ref")")"
        ftctl_dr_runtime_path_set "${run_path}" \
          "checkpoint_lease_state=LEASED" \
          "checkpoint_lease_path=${checkpoint_lease_path}" \
          "transition_state=TEST_ACTIVE" \
          "updated_at=$(ftctl_now_iso8601)" || true
      fi
      if [[ "${rc}" != "0" ]]; then
        ftctl_dr_runtime_cleanup_test_session "${plan}" "${run}" "${run_path}" "${status_path}" >/dev/null 2>&1 || true
        error_code="DR_RESTORE_POINT_NOT_FOUND"
        [[ "${rc}" == "45" ]] && error_code="DR_TARGET_NOT_READY"
        [[ "${rc}" == "46" ]] && error_code="DR_TEST_MATERIALIZATION_FAILED"
        [[ "${rc}" == "47" ]] && error_code="DR_GUEST_PREP_RUNTIME_UNAVAILABLE"
        [[ "${rc}" == "48" ]] && error_code="DR_GUEST_OS_UNSUPPORTED"
        [[ "${rc}" == "49" ]] && error_code="DR_GUEST_PREPARATION_FAILED"
        [[ "${rc}" == "50" ]] && error_code="DR_TEST_DOMAIN_DEFINE_FAILED"
        [[ "${rc}" == "51" ]] && error_code="DR_TEST_BOOT_TIMEOUT"
        [[ "${rc}" == "52" ]] && error_code="DR_TEST_QGA_UNAVAILABLE"
        [[ "${rc}" == "53" ]] && error_code="DR_TEST_ARTIFACT_LOCATOR_INVALID"
        [[ "${rc}" == "54" ]] && error_code="DR_TEST_ARTIFACT_PROVIDER_UNSUPPORTED"
        local failed_step="test-session-restore-point-missing"
        [[ "${rc}" == "46" ]] && failed_step="test-materialization-failed"
        [[ "${rc}" -ge 47 ]] && failed_step="test-guest-preparation-failed"
        ftctl_dr_runtime_path_set "${run_path}" \
          "state=ERROR" \
          "step=${failed_step}" \
          "progress=100" \
          "accepted=false" \
          "error_code=${error_code}" \
          "updated_at=$(ftctl_now_iso8601)" || true
        cp -f "${run_path}" "${status_path}" 2>/dev/null || true
        chmod 0644 "${status_path}" 2>/dev/null || true
        ftctl_log_event "dr-runtime" "dr.test.failover" "fail" "" "${error_code}" \
          "plan=${plan} run=${run} restore_point=${restore_point:-} rc=${rc}"
        command -v ftctl_dr_scheduler_resume_after_transition >/dev/null 2>&1 && \
          ftctl_dr_scheduler_resume_after_transition "${plan}" "${run}" "test-failover-rollback" "${run_path}" "${status_path}" || true
        command -v ftctl_dr_scheduler_transition_end >/dev/null 2>&1 && ftctl_dr_scheduler_transition_end "${plan}"
        if [[ "${json}" == "1" ]]; then
          ftctl_dr_runtime_emit_state_json "${action}" "error" "${plan}" "${run}" "${run_path}" "0"
        else
          printf '%s: plan=%s run=%s restore point unavailable error=%s\n' "${action}" "${plan}" "${run}" "${error_code}" >&2
        fi
        return "${rc}"
      fi
      command -v ftctl_dr_scheduler_transition_end >/dev/null 2>&1 && ftctl_dr_scheduler_transition_end "${plan}"
      ftctl_log_event "dr-runtime" "dr.test.failover" "ok" "" "" \
        "plan=${plan} run=${run} restore_point=$(ftctl_dr_runtime_state_get_from_path "${run_path}" "test_restore_point_ref")"
      ;;
    dr-test-cleanup|dr-test-artifact-cleanup)
      rc=0
      if command -v ftctl_dr_scheduler_transition_begin >/dev/null 2>&1; then
        ftctl_dr_scheduler_transition_begin "${plan}" "${run}" "${action}" "${run_path}" "${status_path}" || rc=$?
      fi
      if [[ "${rc}" != "0" ]]; then
        error_code="DR_SYNC_QUIESCE_TIMEOUT"
        [[ "${rc}" == "20" ]] && error_code="DR_TRANSITION_BUSY_RETRYABLE"
        ftctl_dr_runtime_path_set "${run_path}" \
          "state=ERROR" \
          "step=test-cleanup-quiesce-failed" \
          "progress=100" \
          "accepted=false" \
          "retryable=$([[ "${rc}" == "20" ]] && printf true || printf false)" \
          "retry_after_sec=$([[ "${rc}" == "20" ]] && printf 2 || printf '')" \
          "error_code=${error_code}" \
          "updated_at=$(ftctl_now_iso8601)" || true
        cp -f "${run_path}" "${status_path}" 2>/dev/null || true
        ftctl_dr_runtime_mark_worker_terminal "${run_path}" "${status_path}" "FAILED" "${rc}" "${error_code}" "$([[ "${rc}" == "20" ]] && printf true || printf false)" "$([[ "${rc}" == "20" ]] && printf 2 || printf '')"
        command -v ftctl_dr_scheduler_transition_end >/dev/null 2>&1 && ftctl_dr_scheduler_transition_end "${plan}"
        [[ "${json}" == "1" ]] && ftctl_dr_runtime_emit_state_json "${action}" "error" "${plan}" "${run}" "${run_path}" "0"
        return "${rc}"
      fi
      ftctl_dr_runtime_cleanup_test_session "${plan}" "${run}" "${run_path}" "${status_path}" || rc=$?
      if [[ "${rc}" != "0" ]]; then
        ftctl_dr_runtime_path_set "${run_path}" \
          "state=ERROR" \
          "step=test-cleanup-failed" \
          "progress=100" \
          "accepted=false" \
          "error_code=DR_TEST_CLEANUP_FAILED" \
          "updated_at=$(ftctl_now_iso8601)" || true
        cp -f "${run_path}" "${status_path}" 2>/dev/null || true
        chmod 0644 "${status_path}" 2>/dev/null || true
        ftctl_log_event "dr-runtime" "dr.test.cleanup" "fail" "" "${rc}" \
          "plan=${plan} run=${run}"
        command -v ftctl_dr_scheduler_transition_end >/dev/null 2>&1 && ftctl_dr_scheduler_transition_end "${plan}"
        if [[ "${json}" == "1" ]]; then
          ftctl_dr_runtime_emit_state_json "${action}" "error" "${plan}" "${run}" "${run_path}" "0"
        else
          printf '%s: plan=%s run=%s cleanup failed rc=%s\n' "${action}" "${plan}" "${run}" "${rc}" >&2
        fi
        return "${rc}"
      fi
      test_sequence="$(ftctl_dr_runtime_state_get_from_path "${run_path}" "test_restore_point_sequence")"
      [[ -n "${test_sequence}" ]] && ftctl_dr_scheduler_checkpoint_lease_release "${plan}" "${test_sequence}"
      ftctl_dr_runtime_path_set "${run_path}" "checkpoint_lease_state=RELEASED" "checkpoint_lease_path=" || true
      if command -v ftctl_dr_scheduler_resume_after_transition >/dev/null 2>&1; then
        ftctl_dr_scheduler_resume_after_transition "${plan}" "${run}" "test-cleanup" "${run_path}" "${status_path}" || rc=$?
      fi
      command -v ftctl_dr_scheduler_transition_end >/dev/null 2>&1 && ftctl_dr_scheduler_transition_end "${plan}"
      if [[ "${rc}" != "0" ]]; then
        ftctl_dr_runtime_path_set "${run_path}" \
          "state=ERROR" \
          "step=test-cleanup-resume-failed" \
          "accepted=false" \
          "error_code=DR_SYNC_RESUME_TIMEOUT" \
          "updated_at=$(ftctl_now_iso8601)" || true
        cp -f "${run_path}" "${status_path}" 2>/dev/null || true
        [[ "${json}" == "1" ]] && ftctl_dr_runtime_emit_state_json "${action}" "error" "${plan}" "${run}" "${run_path}" "0"
        return "${rc}"
      fi
      ftctl_log_event "dr-runtime" "dr.test.cleanup" "ok" "" "" \
        "plan=${plan} run=${run}"
      ;;
    dr-failover)
      rc=0
      ftctl_dr_runtime_start_failover "${plan}" "${run}" "$(ftctl_dr_runtime_profile_path "${plan}")" \
        "${restore_point}" "${mode}" "${run_path}" "${status_path}" "${wait_value}" || rc=$?
      if [[ "${rc}" != "0" ]]; then
        error_code="$(ftctl_dr_runtime_state_get_from_path "${run_path}" "error_code")"
        [[ -n "${error_code}" ]] || error_code="DR_FAILOVER_FAILED"
        if [[ "${json}" == "1" ]]; then
          ftctl_dr_runtime_emit_state_json "${action}" "error" "${plan}" "${run}" "${run_path}" "0"
        else
          printf '%s: plan=%s run=%s failover failed error=%s rc=%s\n' "${action}" "${plan}" "${run}" "${error_code}" "${rc}" >&2
        fi
        return "${rc}"
      fi
      ;;
    dr-failback)
      rc=0
      ftctl_dr_runtime_start_failback "${plan}" "${run}" "$(ftctl_dr_runtime_profile_path "${plan}")" \
        "${run_path}" "${status_path}" "${wait_value}" || rc=$?
      if [[ "${rc}" != "0" ]]; then
        error_code="$(ftctl_dr_runtime_state_get_from_path "${run_path}" "error_code")"
        [[ -n "${error_code}" ]] || error_code="DR_FAILBACK_FAILED"
        if [[ "${json}" == "1" ]]; then
          ftctl_dr_runtime_emit_state_json "${action}" "error" "${plan}" "${run}" "${run_path}" "0"
        else
          printf '%s: plan=%s run=%s failback failed error=%s rc=%s\n' "${action}" "${plan}" "${run}" "${error_code}" "${rc}" >&2
        fi
        return "${rc}"
      fi
      ;;
    dr-reprotect)
      rc=0
      ftctl_dr_runtime_start_reprotect "${plan}" "${run}" "$(ftctl_dr_runtime_profile_path "${plan}")" \
        "${run_path}" "${status_path}" "${wait_value}" || rc=$?
      if [[ "${rc}" != "0" ]]; then
        error_code="$(ftctl_dr_runtime_state_get_from_path "${run_path}" "error_code")"
        [[ -n "${error_code}" ]] || error_code="DR_REPROTECT_FAILED"
        if [[ "${json}" == "1" ]]; then
          ftctl_dr_runtime_emit_state_json "${action}" "error" "${plan}" "${run}" "${run_path}" "0"
        else
          printf '%s: plan=%s run=%s reprotect failed error=%s rc=%s\n' "${action}" "${plan}" "${run}" "${error_code}" "${rc}" >&2
        fi
        return "${rc}"
      fi
      ;;
  esac

  if [[ "${action}" == "dr-sync-start" && "${dry_run}" != "1" ]] &&
      command -v ftctl_dr_vmware_sync_start >/dev/null 2>&1; then
    rc=0
    ftctl_dr_vmware_sync_start "${plan}" "${run}" "${profile_file}" "${run_path}" "${wait_value}" || rc=$?
    if [[ "${rc}" != "0" ]]; then
      error_code="$(ftctl_dr_runtime_state_get_from_path "${run_path}" "error_code")"
      [[ -n "${error_code}" ]] || error_code="DR_VMWARE_DRIVER_FAILED"
      ftctl_dr_runtime_path_set "${run_path}" \
        "state=ERROR" \
        "accepted=false" \
        "error_code=${error_code}" \
        "updated_at=$(ftctl_now_iso8601)" || true
      cp -f "${run_path}" "${status_path}" 2>/dev/null || true
      chmod 0644 "${status_path}" 2>/dev/null || true
      ftctl_dr_runtime_mark_worker_terminal "${run_path}" "${status_path}" "FAILED" "${rc}" "${error_code}" "false" ""
      ftctl_log_event "dr-runtime" "dr.vmware.driver" "fail" "" "${rc}" \
        "plan=${plan} run=${run} action=${action} error=${error_code}"
      if [[ "${json}" == "1" ]]; then
        ftctl_dr_runtime_emit_state_json "${action}" "error" "${plan}" "${run}" "${run_path}" "0"
      else
        printf '%s: plan=%s run=%s vmware driver failed rc=%s error=%s\n' "${action}" "${plan}" "${run}" "${rc}" "${error_code}" >&2
      fi
      return "${rc}"
    fi
  fi

  if [[ "${action}" == "dr-sync-start" && "${dry_run}" != "1" ]] &&
      command -v ftctl_dr_ablestack_sync_start >/dev/null 2>&1; then
    rc=0
    ftctl_dr_ablestack_sync_start "${plan}" "${run}" "${profile_file}" "${run_path}" "${wait_value}" || rc=$?
    if [[ "${rc}" != "0" ]]; then
      error_code="$(ftctl_dr_runtime_state_get_from_path "${run_path}" "error_code")"
      [[ -n "${error_code}" ]] || error_code="DR_ABLESTACK_DRIVER_FAILED"
      step="$(ftctl_dr_runtime_state_get_from_path "${run_path}" "step")"
      [[ -n "${step}" ]] || step="ablestack-driver-failed"
      ftctl_dr_runtime_path_set "${run_path}" \
        "state=ERROR" \
        "step=${step}" \
        "progress=100" \
        "accepted=false" \
        "error_code=${error_code}" \
        "updated_at=$(ftctl_now_iso8601)" || true
      cp -f "${run_path}" "${status_path}" 2>/dev/null || true
      chmod 0644 "${status_path}" 2>/dev/null || true
      ftctl_dr_runtime_mark_worker_terminal "${run_path}" "${status_path}" "FAILED" "${rc}" "${error_code}" "false" ""
      ftctl_log_event "dr-runtime" "dr.ablestack.driver" "fail" "" "${rc}" \
        "plan=${plan} run=${run} action=${action} error=${error_code}"
      if [[ "${json}" == "1" ]]; then
        ftctl_dr_runtime_emit_state_json "${action}" "error" "${plan}" "${run}" "${run_path}" "0"
      else
        printf '%s: plan=%s run=%s ablestack driver failed rc=%s error=%s\n' "${action}" "${plan}" "${run}" "${rc}" "${error_code}" >&2
      fi
      return "${rc}"
    fi
  fi

  if [[ "${action}" == "dr-sync-start" && "${dry_run}" != "1" ]] &&
      command -v ftctl_dr_scheduler_start >/dev/null 2>&1; then
    rc=0
    ftctl_dr_scheduler_start "${plan}" "${run}" "$(ftctl_dr_runtime_profile_path "${plan}")" "${run_path}" "${status_path}" "${wait_value}" || rc=$?
    if [[ "${rc}" != "0" ]]; then
      error_code="$(ftctl_dr_runtime_state_get_from_path "${run_path}" "error_code")"
      [[ -n "${error_code}" ]] || error_code="DR_SCHEDULER_FAILED"
      ftctl_dr_runtime_path_set "${run_path}" \
        "state=ERROR" \
        "step=scheduler-failed" \
        "progress=100" \
        "accepted=false" \
        "scheduler_state=ERROR" \
        "error_code=${error_code}" \
        "updated_at=$(ftctl_now_iso8601)" || true
      cp -f "${run_path}" "${status_path}" 2>/dev/null || true
      chmod 0644 "${status_path}" 2>/dev/null || true
      ftctl_dr_runtime_mark_worker_terminal "${run_path}" "${status_path}" "FAILED" "${rc}" "${error_code}" "false" ""
      ftctl_log_event "dr-runtime" "dr.scheduler" "fail" "" "${rc}" \
        "plan=${plan} run=${run} action=${action} error=${error_code}"
      if [[ "${json}" == "1" ]]; then
        ftctl_dr_runtime_emit_state_json "${action}" "error" "${plan}" "${run}" "${run_path}" "0"
      else
        printf '%s: plan=%s run=%s scheduler failed rc=%s error=%s\n' "${action}" "${plan}" "${run}" "${rc}" "${error_code}" >&2
      fi
      return "${rc}"
    fi

    # systemd now owns the live Plan projection. Keep the dispatch Run
    # terminal for Cloud accounting, but never copy its older snapshot back
    # over status.kv after the scheduler unit has been accepted.
    if [[ "$(ftctl_dr_runtime_state_get_from_path "${run_path}" "scheduler_launch_mode")" == "systemd" ]]; then
      ftctl_dr_runtime_path_set "${run_path}" \
        "worker_state=SUCCEEDED" \
        "worker_pid=$$" \
        "worker_exit_code=0" \
        "worker_error_code=" \
        "worker_retryable=false" \
        "worker_retry_after_sec=" \
        "worker_updated_at=$(ftctl_now_iso8601)" || true
      ftctl_log_event "dr-runtime" "dr.action.accepted" "ok" "" "" \
        "plan=${plan} run=${run} action=${action} scheduler_owner=systemd"
      if [[ "${json}" == "1" ]]; then
        ftctl_dr_runtime_emit_state_json "${action}" "accepted" "${plan}" "${run}" "${run_path}" "0"
      else
        printf '%s: plan=%s run=%s accepted scheduler_owner=systemd\n' "${action}" "${plan}" "${run}"
      fi
      return 0
    fi
  fi

  ftctl_dr_runtime_mark_worker_terminal "${run_path}" "${status_path}" "SUCCEEDED" "0" "" "false" ""
  cp -f "${run_path}" "${status_path}"
  chmod 0644 "${status_path}" 2>/dev/null || true
  ftctl_log_event "dr-runtime" "dr.action.accepted" "ok" "" "" \
    "plan=${plan} run=${run} action=${action} role=${role:-} mode=${mode:-} restore_point=${restore_point:-} force=${force} dry_run=${dry_run} wait=${wait_value:-}"

  if [[ "${json}" == "1" ]]; then
    ftctl_dr_runtime_emit_state_json "${action}" "accepted" "${plan}" "${run}" "${run_path}" "0"
  else
    printf '%s: plan=%s run=%s accepted state=%s step=%s\n' "${action}" "${plan}" "${run}" "${state}" "${step}"
  fi
}

ftctl_dr_runtime_target_materialized() {
  local plan="${1-}" run="${2-}" target_vm_id="${3-}" target_external_ref="${4-}" target_vm_name="${5-}" target_network_id="${6-}"
  local target_volume_map_json="${7-}" target_ready_rpo_seconds="${8-}" json="${9-0}"
  local run_path status_path now updates

  ftctl_dr_runtime_require_plan "${plan}" || return 2
  ftctl_dr_runtime_require_run "${run}" || return 2
  if [[ -z "${target_vm_id}${target_external_ref}" ]]; then
    [[ "${json}" == "1" ]] && ftctl_dr_runtime_emit_error_json "dr-target-materialized" "${plan}" "${run}" "target_reference_required" "target VM id or external ref is required" 2
    [[ "${json}" == "1" ]] || printf 'dr-target-materialized: plan=%s run=%s target reference is required\n' "${plan}" "${run}" >&2
    return 2
  fi

  ftctl_dr_runtime_ensure_plan_dirs "${plan}"
  run_path="$(ftctl_dr_runtime_run_path "${plan}" "${run}")"
  status_path="$(ftctl_dr_runtime_status_path "${plan}")"
  if [[ ! -f "${run_path}" ]]; then
    if [[ -f "${status_path}" ]]; then
      cp -f "${status_path}" "${run_path}"
    else
      ftctl_dr_runtime_write_state "${run_path}" "${plan}" "${run}" "dr-target-materialized" "READY" "target-ready" "100" "${run}" ""
    fi
  fi

  now="$(ftctl_now_iso8601)"
  updates=(
    "action=dr-target-materialized"
    "state=READY"
    "step=target-ready"
    "progress=100"
    "accepted=true"
    "target_vm_id=${target_vm_id}"
    "target_external_ref=${target_external_ref}"
    "target_vm_name=${target_vm_name}"
    "target_network_id=${target_network_id}"
    "target_volume_map_json=${target_volume_map_json}"
    "target_vm_present=true"
    "target_storage_present=true"
    "target_network_present=true"
    "restore_point_present=true"
    "target_materialized=true"
    "worker_state=SUCCEEDED"
    "worker_exit_code=0"
    "worker_updated_at=${now}"
    "retryable=false"
    "retry_after_sec="
    "error_code="
    "error_message="
    "updated_at=${now}"
  )
  [[ -n "${target_ready_rpo_seconds}" ]] && updates+=("target_ready_rpo_seconds=${target_ready_rpo_seconds}")
  ftctl_dr_runtime_path_set "${run_path}" "${updates[@]}" || return 2
  cp -f "${run_path}" "${status_path}"
  chmod 0644 "${status_path}" 2>/dev/null || true
  ftctl_log_event "dr-runtime" "dr.target.materialized" "ok" "" "" \
    "plan=${plan} run=${run} target_vm_id=${target_vm_id:-} target_external_ref=${target_external_ref:-}"

  if [[ "${json}" == "1" ]]; then
    ftctl_dr_runtime_emit_state_json "dr-target-materialized" "ok" "${plan}" "${run}" "${run_path}" "0"
  else
    printf 'dr-target-materialized: plan=%s run=%s target=%s state=READY\n' "${plan}" "${run}" "${target_vm_id:-${target_external_ref}}"
  fi
}

ftctl_dr_runtime_cutover_commit() {
  local plan="${1-}" run="${2-}" session_id="${3-}" checkpoint_sequence="${4-}"
  local authority_generation="${5-}" target_power_state="${6-}" boot_validation_state="${7-}" json="${8-0}"
  local run_path status_path active_path session_path state current_session current_checkpoint current_generation now

  ftctl_dr_runtime_require_plan "${plan}" || return 2
  ftctl_dr_runtime_require_run "${run}" || return 2
  if [[ -z "${session_id}" || ! "${checkpoint_sequence}" =~ ^[0-9]+$ || ! "${authority_generation}" =~ ^[0-9]+$ ]]; then
    [[ "${json}" == "1" ]] && ftctl_dr_runtime_emit_error_json "dr-cutover-commit" "${plan}" "${run}" \
      "DR_CUTOVER_COMMIT_INVALID" "session id, checkpoint sequence, and authority generation are required" 2
    [[ "${json}" == "1" ]] || printf 'dr-cutover-commit: invalid commit contract\n' >&2
    return 2
  fi
  if [[ "${target_power_state}" != "POWERED_ON" ]]; then
    [[ "${json}" == "1" ]] && ftctl_dr_runtime_emit_error_json "dr-cutover-commit" "${plan}" "${run}" \
      "DR_TARGET_NOT_RUNNING" "Cloud target power state must be POWERED_ON" 78
    return 78
  fi
  case "${boot_validation_state}" in
    POWER_STATE_VALIDATED|GUEST_HEARTBEAT_VALIDATED) ;;
    *)
      [[ "${json}" == "1" ]] && ftctl_dr_runtime_emit_error_json "dr-cutover-commit" "${plan}" "${run}" \
        "DR_BOOT_VALIDATION_INCOMPLETE" "Cloud target boot validation is incomplete" 78
      return 78
      ;;
  esac

  run_path="$(ftctl_dr_runtime_run_path "${plan}" "${run}")"
  status_path="$(ftctl_dr_runtime_status_path "${plan}")"
  active_path="$(ftctl_dr_runtime_active_failover_session_path "${plan}")"
  session_path="$(ftctl_dr_runtime_failover_session_path "${plan}" "${run}")"
  [[ -f "${run_path}" && -f "${status_path}" ]] || {
    [[ "${json}" == "1" ]] && ftctl_dr_runtime_emit_error_json "dr-cutover-commit" "${plan}" "${run}" \
      "DR_CUTOVER_SESSION_NOT_FOUND" "FTCTL cutover runtime was not found" 44
    return 44
  }

  state="$(ftctl_dr_runtime_state_get_from_path "${run_path}" "state")"
  current_session="$(ftctl_dr_runtime_state_get_from_path "${run_path}" "failover_session_id")"
  current_checkpoint="$(ftctl_dr_runtime_state_get_from_path "${run_path}" "failover_restore_point_sequence")"
  current_generation="$(ftctl_dr_runtime_state_get_from_path "${run_path}" "cloud_authority_generation")"
  [[ "${current_session}" == "${session_id}" ]] || {
    [[ "${json}" == "1" ]] && ftctl_dr_runtime_emit_error_json "dr-cutover-commit" "${plan}" "${run}" \
      "DR_CUTOVER_SESSION_MISMATCH" "Cloud cutover session does not match FTCTL runtime" 79
    return 79
  }
  [[ "${current_checkpoint}" == "${checkpoint_sequence}" ]] || {
    [[ "${json}" == "1" ]] && ftctl_dr_runtime_emit_error_json "dr-cutover-commit" "${plan}" "${run}" \
      "DR_CUTOVER_CHECKPOINT_MISMATCH" "Cloud checkpoint does not match FTCTL cutover checkpoint" 79
    return 79
  }
  if [[ -n "${current_generation}" && "${authority_generation}" -lt "${current_generation}" ]]; then
    [[ "${json}" == "1" ]] && ftctl_dr_runtime_emit_error_json "dr-cutover-commit" "${plan}" "${run}" \
      "DR_CUTOVER_GENERATION_STALE" "Cloud authority generation is older than the committed generation" 79
    return 79
  fi
  if [[ "${state}" != "CUTOVER_READY" && "${state}" != "FAILED_OVER" ]]; then
    [[ "${json}" == "1" ]] && ftctl_dr_runtime_emit_error_json "dr-cutover-commit" "${plan}" "${run}" \
      "DR_CUTOVER_STATE_INVALID" "FTCTL runtime is not ready for Cloud promotion commit" 79
    return 79
  fi

  now="$(ftctl_now_iso8601)"
  ftctl_dr_runtime_path_set "${run_path}" \
    "action=dr-cutover-commit" \
    "state=FAILED_OVER" \
    "step=cloud-promotion-committed" \
    "progress=100" \
    "active_side=TARGET" \
    "target_power_state=POWERED_ON" \
    "target_promotion_state=PROMOTED" \
    "boot_validation_state=${boot_validation_state}" \
    "cloud_cutover_session_id=${session_id}" \
    "cloud_authority_generation=${authority_generation}" \
    "engine_ack_state=ACKNOWLEDGED" \
    "engine_ack_at=${now}" \
    "failover_completed_at=${now}" \
    "worker_state=SUCCEEDED" \
    "worker_exit_code=0" \
    "accepted=true" \
    "retryable=false" \
    "error_code=" \
    "error_message=" \
    "updated_at=${now}" || return 2
  cp -f "${run_path}" "${status_path}"
  chmod 0644 "${status_path}" 2>/dev/null || true

  if [[ -f "${session_path}" ]]; then
    python3 - "${session_path}" "${active_path}" "${authority_generation}" "${boot_validation_state}" "${now}" <<'PY' || return 2
import json
import os
import shutil
import sys

path, active_path, generation, validation_state, now = sys.argv[1:6]
with open(path, "r", encoding="utf-8") as fh:
    session = json.load(fh)
session["state"] = "FAILED_OVER"
session["activeSide"] = "TARGET"
session["completedAt"] = now
session["cloudAuthorityGeneration"] = int(generation)
session["bootValidationState"] = validation_state
promotion = session.setdefault("targetPromotion", {})
promotion["state"] = "PROMOTED"
promotion["powerState"] = "POWERED_ON"
promotion["committedAt"] = now
promotion["authorityOwner"] = "Cloud"
with open(path, "w", encoding="utf-8") as fh:
    json.dump(session, fh, sort_keys=True, separators=(",", ":"))
    fh.write("\n")
os.makedirs(os.path.dirname(active_path), exist_ok=True)
shutil.copyfile(path, active_path)
PY
  fi

  ftctl_log_event "dr-runtime" "dr.cutover.commit" "ok" "" "" \
    "plan=${plan} run=${run} session=${session_id} generation=${authority_generation}"
  if [[ "${json}" == "1" ]]; then
    ftctl_dr_runtime_emit_state_json "dr-cutover-commit" "ok" "${plan}" "${run}" "${run_path}" "0"
  else
    printf 'dr-cutover-commit: plan=%s run=%s state=FAILED_OVER active_side=TARGET\n' "${plan}" "${run}"
  fi
}

ftctl_dr_runtime_capabilities() {
  local json="${1-0}" version="${PROG_VERSION:-unknown}"
  local schema="20260722" action_contract="2026-07-22"
  local commands=(
    "dr-plan-apply"
    "dr-sync-start"
    "dr-sync-recover"
    "dr-sync-pause"
    "dr-sync-resume"
    "dr-test-failover"
    "dr-test-cleanup"
    "dr-test-prepare"
    "dr-test-artifact-cleanup"
    "dr-failover"
    "dr-failback"
    "dr-reprotect"
    "dr-target-materialized"
    "dr-cutover-commit"
    "dr-release"
    "dr-status"
    "dr-reconcile"
    "dr-cancel"
  )
  local first="1" command

  if [[ "${json}" == "1" ]]; then
    printf '{"command":"dr-capabilities","result":"ok","ftctl_version":"%s","runtime_schema_version":"%s","action_contract_version":"%s","supported_commands":[' \
      "$(ftctl__json_escape "${version}")" "$(ftctl__json_escape "${schema}")" "$(ftctl__json_escape "${action_contract}")"
    for command in "${commands[@]}"; do
      [[ "${first}" == "1" ]] || printf ','
      first="0"
      printf '"%s"' "$(ftctl__json_escape "${command}")"
    done
    printf '],"supported_features":["async-run","status-projection","status-scope-v2","target-materialized-notify","target-materialized-idempotent","hardware-contract-projection","control-protocol-v2","control-protocol-v3","dr-scheduler-singleton-v1","dr-scheduler-self-owner-repair-v1","dr-scheduler-systemd-unit-v1","dr-sync-recover-v1","dr-local-reconcile-fence-v1","dr-checkpoint-producer-v1","dr-nbd-deterministic-drain-v1","dr-nbd-cleanup-recovery-v1","plan-scoped-locks","cycle-scoped-lock","quiesce-before-test-failover","checkpoint-lease","guest-preparation-v1","guest-preparation-v2","test-domain-lifecycle-v1","test-artifact-lifecycle-v2","cloud-managed-test-vm-v1","cutover-ready-v1","cutover-manifest-v2","cutover-preflight-v1","cloud-cutover-commit-v1"]}\n'
    return 0
  fi

  printf 'FTCTL_DR capabilities (version=%s schema=%s)\n' "${version}" "${schema}"
  for command in "${commands[@]}"; do
    printf '  %s\n' "${command}"
  done
}

ftctl_dr_runtime_status() {
  local plan="${1-}" run="${2-}" events_offset="${3-0}" events_limit="${4-20}" json="${5-0}"
  local path result="ok" payload payload_bytes max_payload_bytes

  ftctl_dr_runtime_require_plan "${plan}" || return 2
  if [[ -n "${run}" && -f "$(ftctl_dr_runtime_run_path "${plan}" "${run}")" ]]; then
    path="$(ftctl_dr_runtime_run_path "${plan}" "${run}")"
  else
    path="$(ftctl_dr_runtime_status_path "${plan}")"
  fi

  if [[ ! -f "${path}" ]]; then
    if [[ -f "$(ftctl_dr_runtime_profile_path "${plan}")" ]]; then
      ftctl_dr_runtime_ensure_plan_dirs "${plan}"
      path="$(ftctl_dr_runtime_status_path "${plan}")"
      ftctl_dr_runtime_write_state "${path}" "${plan}" "" "dr-status" "PLANNED" "profile-present" "0" "" ""
    else
      if [[ "${json}" == "1" ]]; then
        printf '{"command":"dr-status","result":"not_found","plan_uuid":"%s","state":"UNKNOWN","step":"not-found","progress":0,"accepted":false,"error_code":"not_found","events_offset":%s,"exit_code":2}\n' \
          "$(ftctl__json_escape "${plan}")" \
          "$(ftctl_dr_runtime_events_offset "${plan}")"
      else
        printf 'dr-status: plan=%s not found\n' "${plan}" >&2
      fi
      return 2
    fi
  fi

  [[ -n "${run}" && ! -f "$(ftctl_dr_runtime_run_path "${plan}" "${run}")" ]] && result="run_not_found"
  if [[ "${json}" == "1" ]]; then
    payload="$(ftctl_dr_runtime_emit_state_json "dr-status" "${result}" "${plan}" "${run}" "${path}" "${events_offset}" "${events_limit}")" || payload=""
    max_payload_bytes="${FTCTL_DR_STATUS_MAX_BYTES:-262144}"
    [[ "${max_payload_bytes}" =~ ^[1-9][0-9]*$ ]] || max_payload_bytes="262144"
    payload_bytes="$(printf '%s' "${payload}" | wc -c | tr -d '[:space:]')"
    if [[ -n "${payload}" && "${payload_bytes}" =~ ^[0-9]+$ && "${payload_bytes}" -le "${max_payload_bytes}" ]] \
      && printf '%s' "${payload}" | python3 -c 'import json,sys; value=json.load(sys.stdin); raise SystemExit(0 if isinstance(value, dict) else 1)' 2>/dev/null; then
      printf '%s\n' "${payload}"
    else
      printf '{"command":"dr-status","result":"error","plan_uuid":"%s","run_uuid":"%s","state":"ERROR","step":"status-validation","progress":0,"accepted":false,"error_code":"DR_STATUS_JSON_INVALID","error_message":"FTCTL DR status failed strict JSON validation","events_offset":%s,"events":[],"exit_code":65}\n' \
        "$(ftctl__json_escape "${plan}")" "$(ftctl__json_escape "${run}")" "$(ftctl_dr_runtime_events_offset "${plan}")"
      return 65
    fi
  else
    printf 'dr-status: plan=%s state=%s step=%s progress=%s\n' \
      "${plan}" \
      "$(ftctl_dr_runtime_state_get_from_path "${path}" state)" \
      "$(ftctl_dr_runtime_state_get_from_path "${path}" step)" \
      "$(ftctl_dr_runtime_state_get_from_path "${path}" progress)"
  fi
}

ftctl_dr_runtime_cancel() {
  local plan="${1-}" run="${2-}" force="${3-0}" json="${4-0}"
  local run_path status_path

  ftctl_dr_runtime_require_plan "${plan}" || return 2
  ftctl_dr_runtime_require_run "${run}" || return 2
  ftctl_dr_runtime_ensure_plan_dirs "${plan}"
  run_path="$(ftctl_dr_runtime_run_path "${plan}" "${run}")"
  status_path="$(ftctl_dr_runtime_status_path "${plan}")"
  ftctl_dr_runtime_write_state "${run_path}" "${plan}" "${run}" "dr-cancel" "CANCELED" "canceled" "100" "${run}" ""
  if command -v ftctl_dr_scheduler_control_action >/dev/null 2>&1; then
    ftctl_dr_scheduler_control_action "dr-cancel" "${plan}" "${run_path}" "${status_path}" || true
  fi
  cp -f "${run_path}" "${status_path}"
  chmod 0644 "${status_path}" 2>/dev/null || true
  ftctl_log_event "dr-runtime" "dr.cancel" "ok" "" "" \
    "plan=${plan} run=${run} force=${force}"

  if [[ "${json}" == "1" ]]; then
    printf '{"command":"dr-cancel","result":"canceled","accepted":true,"plan_uuid":"%s","run_uuid":"%s","error_code":"","exit_code":0}\n' \
      "$(ftctl__json_escape "${plan}")" \
      "$(ftctl__json_escape "${run}")"
  else
    printf 'dr-cancel: plan=%s run=%s canceled\n' "${plan}" "${run}"
  fi
}
