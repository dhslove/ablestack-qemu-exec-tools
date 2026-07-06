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

ftctl_dr_runtime_events_offset() {
  if [[ -f "${FTCTL_EVENTS_LOG}" ]]; then
    wc -l < "${FTCTL_EVENTS_LOG}" | tr -d '[:space:]'
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

ftctl_dr_runtime_state_get_from_path() {
  local path="${1-}" key="${2-}"
  ftctl_state_read_kv "${path}" "${key}" 2>/dev/null || true
}

ftctl_dr_runtime_path_set() {
  local path="${1-}"
  local tmp key value
  shift
  [[ -n "${path}" && -f "${path}" ]] || return 1
  tmp="$(mktemp -t ftctl.dr.state.set.XXXXXX)"
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
  mv -f "${tmp}" "${path}"
  chmod 0644 "${path}" 2>/dev/null || true
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
    explicit = record.get("sourceSnapshotRef") or record.get("restorePointRef")
    if explicit:
        return str(explicit)
    sequence = record.get("checkpointSequence")
    if sequence is not None:
        return f"ftctl:{plan}:{sequence}"
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
        str(record.get("checkpointSequence", "")),
        str(record.get("checkpoint", "")),
        str(record.get("manifest", "")),
        str(record.get("sourceSnapshotRef", "")),
        str(record.get("restorePointRef", "")),
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
    },
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
import sys

plan, run, active_path, session_path, selection_path, now = sys.argv[1:7]
session = {}
if os.path.exists(active_path):
    with open(active_path, "r", encoding="utf-8") as fh:
        session = json.load(fh)
restore = session.get("restorePoint") if isinstance(session.get("restorePoint"), dict) else {}
artifacts = session.get("testArtifacts") if isinstance(session.get("testArtifacts"), dict) else {}
artifact_path = artifacts.get("path") if isinstance(artifacts, dict) else ""
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
  local plan="${1-}" run="${2-}" session_path="${3-}" run_path="${4-}"
  local artifacts_dir artifacts_state_path rc=0
  local test_artifacts_state test_artifacts_path test_artifact_count

  artifacts_dir="$(ftctl_dr_runtime_test_artifacts_dir "${plan}" "${run}")"
  artifacts_state_path="$(mktemp -t ftctl.dr.test.artifacts.XXXXXX)"
  python3 - "${session_path}" "${artifacts_dir}" "${artifacts_state_path}" "$(ftctl_now_iso8601)" <<'PY' || rc=$?
import json
import os
import shutil
import subprocess
import sys

session_path, artifacts_dir, state_path, now = sys.argv[1:5]
with open(session_path, "r", encoding="utf-8") as fh:
    session = json.load(fh)

profile = session.get("profile") if isinstance(session.get("profile"), dict) else {}
target = profile.get("target") if isinstance(profile.get("target"), dict) else {}
mapping = profile.get("mapping") if isinstance(profile.get("mapping"), dict) else {}
checkpoint = session.get("checkpoint") if isinstance(session.get("checkpoint"), dict) else {}
manifest = checkpoint.get("manifest") if isinstance(checkpoint.get("manifest"), dict) else {}
disks = manifest.get("disks") or checkpoint.get("disks") or mapping.get("disks") or []
target_provider = str(target.get("provider") or "").upper()
records = []
state = "NO_DISKS"
os.makedirs(artifacts_dir, exist_ok=True)

if target_provider == "VMWARE":
    state = "METADATA_ONLY"
else:
    qemu_img = shutil.which("qemu-img")
    if disks and not qemu_img:
        sys.stderr.write("ERROR: qemu-img is required to create ABLESTACK test overlays\n")
        sys.exit(46)
    for index, disk in enumerate(disks):
        if not isinstance(disk, dict):
            continue
        target_path = disk.get("targetPath") or disk.get("targetDiskRef") or disk.get("targetDisk") or disk.get("target")
        if not target_path:
            records.append({"device": disk.get("device") or f"disk{index}", "state": "SKIPPED", "reason": "missing targetPath"})
            continue
        device = str(disk.get("device") or f"disk{index}").replace("/", "_").replace(" ", "_")
        target_format = str(disk.get("targetFormat") or disk.get("format") or "qcow2")
        overlay_path = os.path.join(artifacts_dir, f"{device}.qcow2")
        command = [qemu_img, "create", "-f", "qcow2", "-F", target_format, "-b", str(target_path), overlay_path]
        subprocess.run(command, check=True)
        records.append({
            "device": disk.get("device") or f"disk{index}",
            "state": "CREATED",
            "type": "qcow2-overlay",
            "backing": target_path,
            "path": overlay_path,
            "command": command,
        })
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
  local last_source last_target target_rpo target_power_state target_promotion_state

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
    explicit = record.get("sourceSnapshotRef") or record.get("restorePointRef")
    if explicit:
        return str(explicit)
    sequence = record.get("checkpointSequence")
    if sequence is not None:
        return f"ftctl:{plan}:{sequence}"
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
        str(record.get("checkpointSequence", "")),
        str(record.get("checkpoint", "")),
        str(record.get("manifest", "")),
        str(record.get("sourceSnapshotRef", "")),
        str(record.get("restorePointRef", "")),
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
target_power_state = "POWER_ON_DELEGATED"
target_promotion_state = "PROMOTED"
session = {
    "version": 1,
    "planUuid": plan,
    "runUuid": run,
    "sessionId": session_id,
    "state": "FAILED_OVER",
    "mode": mode or "planned",
    "activeSide": "TARGET",
    "startedAt": requested_at,
    "restorePointLockedAt": now,
    "targetPromoteStartedAt": now,
    "targetPowerOnAt": now,
    "completedAt": now,
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
    fh.write(f"target_power_on_at={now}\n")
    fh.write(f"failover_completed_at={now}\n")
    fh.write(f"rto_actual_seconds={seconds_between(requested_at, now)}\n")
    fh.write("active_side=TARGET\n")
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
  rm -f "${selection_path}" 2>/dev/null || true

  ftctl_dr_runtime_path_set "${run_path}" \
    "state=FAILED_OVER" \
    "step=active-side-switch" \
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
    "active_side=TARGET" \
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
  local final_sync rc=0 error_code now

  now="$(ftctl_now_iso8601)"
  ftctl_dr_runtime_path_set "${run_path}" \
    "state=RUNNING" \
    "step=pre-failover-check" \
    "progress=25" \
    "failover_requested_at=${now}" \
    "failover_mode=${mode}" \
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
        66) error_code="DR_UNSUPPORTED_DIRECTION" ;;
        *) error_code="DR_FINAL_CHECKPOINT_FAILED" ;;
      esac
      ftctl_dr_runtime_path_set "${run_path}" \
        "state=ERROR" \
        "step=final-delta-failed" \
        "progress=100" \
        "accepted=false" \
        "error_code=${error_code}" \
        "updated_at=$(ftctl_now_iso8601)" || true
      cp -f "${run_path}" "${status_path}" 2>/dev/null || true
      ftctl_log_event "dr-runtime" "dr.failover" "fail" "" "${error_code}" \
        "plan=${plan} run=${run} mode=${mode} rc=${rc}"
      return "${rc}"
    fi
  fi

  ftctl_dr_runtime_finalize_failover "${plan}" "${run}" "${profile_file}" "${restore_point}" "${mode}" "${run_path}" "${status_path}" || rc=$?
  if [[ "${rc}" != "0" ]]; then
    error_code="DR_RESTORE_POINT_NOT_FOUND"
    [[ "${rc}" == "45" ]] && error_code="DR_TARGET_NOT_READY"
    ftctl_dr_runtime_path_set "${run_path}" \
      "state=ERROR" \
      "step=target-promote-failed" \
      "progress=100" \
      "accepted=false" \
      "error_code=${error_code}" \
      "updated_at=$(ftctl_now_iso8601)" || true
    cp -f "${run_path}" "${status_path}" 2>/dev/null || true
    ftctl_log_event "dr-runtime" "dr.failover" "fail" "" "${error_code}" \
      "plan=${plan} run=${run} mode=${mode} restore_point=${restore_point:-} rc=${rc}"
    return "${rc}"
  fi

  ftctl_log_event "dr-runtime" "dr.failover" "ok" "" "" \
    "plan=${plan} run=${run} mode=${mode} restore_point=$(ftctl_dr_runtime_state_get_from_path "${run_path}" "failover_restore_point_ref")"
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
restore_ref = f"ftctl:{plan}:{sequence}" if sequence else f"ftctl:{plan}:latest"
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
  active_side="$(ftctl_dr_runtime_state_get_from_path "${status_path}" "active_side")"
  current_state="$(ftctl_dr_runtime_state_get_from_path "${status_path}" "state")"
  previous_checkpoint_sequence="$(ftctl_dr_runtime_state_get_from_path "${status_path}" "checkpoint_sequence")"
  if [[ "${active_side}" != "TARGET" && "${current_state}" != "FAILED_OVER" ]]; then
    ftctl_dr_runtime_path_set "${run_path}" \
      "state=ERROR" \
      "step=failback-not-eligible" \
      "progress=100" \
      "accepted=false" \
      "error_code=DR_FAILBACK_REQUIRES_TARGET_ACTIVE" \
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
  active_side="$(ftctl_dr_runtime_state_get_from_path "${status_path}" "active_side")"
  current_state="$(ftctl_dr_runtime_state_get_from_path "${status_path}" "state")"
  previous_checkpoint_sequence="$(ftctl_dr_runtime_state_get_from_path "${status_path}" "checkpoint_sequence")"
  if [[ "${active_side}" != "TARGET" && "${current_state}" != "FAILED_OVER" ]]; then
    ftctl_dr_runtime_path_set "${run_path}" \
      "state=ERROR" \
      "step=reprotect-not-eligible" \
      "progress=100" \
      "accepted=false" \
      "error_code=DR_REPROTECT_REQUIRES_TARGET_ACTIVE" \
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
  local offset="${1-}"
  local current line first="1" count="0" max_events start_line global_line
  [[ "${offset}" =~ ^[0-9]+$ ]] || offset="0"
  current="$(ftctl_dr_runtime_events_offset)"
  printf ',"events_offset":%s' "${current}"
  printf ',"events":['
  if [[ -f "${FTCTL_EVENTS_LOG}" ]]; then
    max_events="${FTCTL_DR_STATUS_MAX_EVENTS:-100}"
    [[ "${max_events}" =~ ^[0-9]+$ ]] || max_events="100"
    (( max_events > 0 )) || max_events="100"
    start_line="1"
    if [[ "${current}" =~ ^[0-9]+$ ]] && (( current > max_events )); then
      start_line=$((current - max_events + 1))
    fi
    while IFS= read -r line; do
      count=$((count + 1))
      global_line=$((start_line + count - 1))
      (( global_line > offset )) || continue
      [[ -n "${line}" ]] || continue
      [[ "${first}" == "1" ]] || printf ','
      first="0"
      printf '%s' "${line}"
    done < <(tail -n "${max_events}" "${FTCTL_EVENTS_LOG}" 2>/dev/null || true)
  fi
  printf ']'
}

ftctl_dr_runtime_emit_state_json() {
  local command="${1-}" result="${2-ok}" plan="${3-}" run="${4-}" state_path="${5-}" events_offset="${6-}"
  local action state step progress external_job_ref error_code last_source last_target target_rpo updated accepted
  local runtime_exists profile_exists run_exists
  local driver driver_state disk_map_path manifest_path checkpoint_path
  local scheduler_state worker_pid worker_state worker_started_at worker_updated_at worker_exit_code
  local retryable retry_after_sec lock_file holder_pid holder_command holder_age_sec
  local checkpoint_sequence restore_points_path dynamic_rpo
  local test_session_id test_session_state test_restore_point_ref test_restore_point_sequence
  local test_manifest_path test_checkpoint_path
  local test_artifacts_state test_artifacts_path test_artifact_count
  local failover_session_id failover_mode failover_restore_point_ref failover_restore_point_sequence
  local failover_manifest_path failover_checkpoint_path failover_requested_at restore_point_locked_at
  local target_promote_started_at target_power_on_at failover_completed_at rto_actual_seconds
  local active_side target_power_state target_promotion_state failover_worker_pid
  local failback_session_id failback_mode failback_restore_point_ref failback_restore_point_sequence
  local failback_manifest_path failback_checkpoint_path failback_requested_at reverse_sync_started_at
  local reverse_target_ready_at source_promote_started_at source_power_on_at failback_completed_at
  local failback_rto_actual_seconds source_power_state source_promotion_state failback_worker_pid
  local reprotect_session_id reprotect_mode reprotect_restore_point_ref reprotect_restore_point_sequence
  local reprotect_manifest_path reprotect_checkpoint_path reprotect_requested_at reprotect_completed_at
  local reprotect_rto_actual_seconds reverse_direction reverse_profile_path reverse_restore_points_path reprotect_worker_pid
  local target_vm_id target_external_ref target_materialized target_vm_present target_storage_present target_network_present restore_point_present

  action="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "action")"
  state="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "state")"
  step="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "step")"
  progress="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "progress")"
  external_job_ref="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "external_job_ref")"
  error_code="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "error_code")"
  last_source="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "last_source_checkpoint_at")"
  last_target="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "last_target_durable_at")"
  target_rpo="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "target_ready_rpo_seconds")"
  updated="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "updated_at")"
  accepted="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "accepted")"
  [[ -f "${state_path}" ]] && runtime_exists="true" || runtime_exists="false"
  [[ -f "$(ftctl_dr_runtime_profile_path "${plan}")" ]] && profile_exists="true" || profile_exists="false"
  [[ -n "${run}" && -f "$(ftctl_dr_runtime_run_path "${plan}" "${run}")" ]] && run_exists="true" || run_exists="false"
  driver="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "driver")"
  driver_state="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "driver_state")"
  disk_map_path="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "disk_map_path")"
  manifest_path="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "manifest_path")"
  checkpoint_path="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "checkpoint_path")"
  scheduler_state="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "scheduler_state")"
  worker_pid="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "worker_pid")"
  worker_state="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "worker_state")"
  worker_started_at="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "worker_started_at")"
  worker_updated_at="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "worker_updated_at")"
  worker_exit_code="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "worker_exit_code")"
  retryable="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "retryable")"
  retry_after_sec="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "retry_after_sec")"
  lock_file="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "lock_file")"
  holder_pid="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "holder_pid")"
  holder_command="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "holder_command")"
  holder_age_sec="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "holder_age_sec")"
  checkpoint_sequence="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "checkpoint_sequence")"
  restore_points_path="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "restore_points_path")"
  test_session_id="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "test_session_id")"
  test_session_state="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "test_session_state")"
  test_restore_point_ref="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "test_restore_point_ref")"
  test_restore_point_sequence="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "test_restore_point_sequence")"
  test_manifest_path="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "test_manifest_path")"
  test_checkpoint_path="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "test_checkpoint_path")"
  test_artifacts_state="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "test_artifacts_state")"
  test_artifacts_path="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "test_artifacts_path")"
  test_artifact_count="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "test_artifact_count")"
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

  printf '{"command":"%s","result":"%s"' \
    "$(ftctl__json_escape "${command}")" \
    "$(ftctl__json_escape "${result}")"
  ftctl_dr_runtime_json_string_field "plan_uuid" "${plan}"
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
  printf ',"target_materialized":%s' "${target_materialized}"
  printf ',"target_vm_present":%s' "${target_vm_present}"
  printf ',"target_storage_present":%s' "${target_storage_present}"
  printf ',"target_network_present":%s' "${target_network_present}"
  printf ',"restore_point_present":%s' "${restore_point_present}"
  ftctl_dr_runtime_json_string_field "target_vm_id" "${target_vm_id}"
  ftctl_dr_runtime_json_string_field "target_external_ref" "${target_external_ref}"
  ftctl_dr_runtime_json_string_field "error_code" "${error_code}"
  ftctl_dr_runtime_json_string_field "updated_at" "${updated}"
  ftctl_dr_runtime_json_string_field "driver" "${driver}"
  ftctl_dr_runtime_json_string_field "driver_state" "${driver_state}"
  ftctl_dr_runtime_json_string_field "disk_map_path" "${disk_map_path}"
  ftctl_dr_runtime_json_string_field "manifest_path" "${manifest_path}"
  ftctl_dr_runtime_json_string_field "checkpoint_path" "${checkpoint_path}"
  ftctl_dr_runtime_json_string_field "scheduler_state" "${scheduler_state}"
  ftctl_dr_runtime_json_number_field "worker_pid" "${worker_pid}"
  ftctl_dr_runtime_json_string_field "worker_state" "${worker_state}"
  ftctl_dr_runtime_json_string_field "worker_started_at" "${worker_started_at}"
  ftctl_dr_runtime_json_string_field "worker_updated_at" "${worker_updated_at}"
  ftctl_dr_runtime_json_number_field "worker_exit_code" "${worker_exit_code}"
  [[ -n "${retryable}" ]] && printf ',"retryable":%s' "${retryable}"
  ftctl_dr_runtime_json_number_field "retry_after_sec" "${retry_after_sec}"
  ftctl_dr_runtime_json_string_field "lock_file" "${lock_file}"
  ftctl_dr_runtime_json_number_field "holder_pid" "${holder_pid}"
  ftctl_dr_runtime_json_string_field "holder_command" "${holder_command}"
  ftctl_dr_runtime_json_number_field "holder_age_sec" "${holder_age_sec}"
  ftctl_dr_runtime_json_number_field "checkpoint_sequence" "${checkpoint_sequence}"
  ftctl_dr_runtime_json_string_field "restore_points_path" "${restore_points_path}"
  ftctl_dr_runtime_json_string_field "test_session_id" "${test_session_id}"
  ftctl_dr_runtime_json_string_field "test_session_state" "${test_session_state}"
  ftctl_dr_runtime_json_string_field "test_restore_point_ref" "${test_restore_point_ref}"
  ftctl_dr_runtime_json_number_field "test_restore_point_sequence" "${test_restore_point_sequence}"
  ftctl_dr_runtime_json_string_field "test_manifest_path" "${test_manifest_path}"
  ftctl_dr_runtime_json_string_field "test_checkpoint_path" "${test_checkpoint_path}"
  ftctl_dr_runtime_json_string_field "test_artifacts_state" "${test_artifacts_state}"
  ftctl_dr_runtime_json_string_field "test_artifacts_path" "${test_artifacts_path}"
  ftctl_dr_runtime_json_number_field "test_artifact_count" "${test_artifact_count}"
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
  ftctl_dr_runtime_emit_events_since "${events_offset}"
  printf ',"exit_code":0}\n'
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
    dr-sync-pause) printf 'PAUSED|sync-paused|100\n' ;;
    dr-sync-resume) printf 'SYNCING|sync-resumed|1\n' ;;
    dr-test-failover) printf 'TESTING|test-failover-accepted|1\n' ;;
    dr-test-cleanup) printf 'READY|test-cleanup-completed|100\n' ;;
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
  wait_lower="$(printf '%s' "${wait_value}" | tr '[:upper:]' '[:lower:]')"
  [[ "${wait_lower}" == "false" || "${wait_lower}" == "0" || "${wait_lower}" == "no" ]] || return 1

  case "${action}" in
    dr-sync-start|dr-test-failover|dr-failover|dr-failback|dr-reprotect) return 0 ;;
    *) return 1 ;;
  esac
}

ftctl_dr_runtime_start_background_worker() {
  local action="${1-}" plan="${2-}" run="${3-}" role="${4-}" mode="${5-}" restore_point="${6-}" force="${7-0}" dry_run="${8-0}" log_path ftctl_bin profile_path
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
  [[ -n "${mode}" ]] && worker_cmd+=("--mode" "${mode}")
  [[ -n "${restore_point}" ]] && worker_cmd+=("--restore-point" "${restore_point}")
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
  local action="${1-}" plan="${2-}" run="${3-}" profile_file="${4-}" role="${5-}" mode="${6-}" restore_point="${7-}" force="${8-0}" dry_run="${9-0}" wait_value="${10-}" json="${11-0}"
  local state_tuple state step progress run_path status_path external_ref rc error_code
  local target_vm_id target_external_ref

  ftctl_dr_runtime_require_plan "${plan}" || return 2
  ftctl_dr_runtime_require_run "${run}" || return 2
  if [[ -n "${profile_file}" ]]; then
    ftctl_dr_runtime_save_profile "${plan}" "${profile_file}" || {
      [[ "${json}" == "1" ]] && ftctl_dr_runtime_emit_error_json "${action}" "${plan}" "${run}" "profile_invalid" "profile JSON is missing or invalid" 2
      return 2
    }
  fi

  state_tuple="$(ftctl_dr_runtime_action_state "${action}")"
  IFS='|' read -r state step progress <<< "${state_tuple}"
  external_ref="${run}"
  run_path="$(ftctl_dr_runtime_run_path "${plan}" "${run}")"
  status_path="$(ftctl_dr_runtime_status_path "${plan}")"
  ftctl_dr_runtime_write_state "${run_path}" "${plan}" "${run}" "${action}" "${state}" "${step}" "${progress}" "${external_ref}" ""
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

  if ftctl_dr_runtime_should_delegate_action "${action}" "${wait_value}" "${dry_run}"; then
    cp -f "${run_path}" "${status_path}"
    chmod 0644 "${status_path}" 2>/dev/null || true
    command -v ftctl_lock_release >/dev/null 2>&1 && ftctl_lock_release || true
    ftctl_dr_runtime_start_background_worker "${action}" "${plan}" "${run}" "${role}" "${mode}" "${restore_point}" "${force}" "${dry_run}"
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
        ftctl_dr_scheduler_control_action "${action}" "${plan}" "${run_path}" "${status_path}" || true
      fi
      ;;
    dr-test-failover)
      rc=0
      ftctl_dr_runtime_prepare_test_session "${plan}" "${run}" "${profile_file}" "${restore_point}" "${run_path}" "${status_path}" || rc=$?
      if [[ "${rc}" == "0" ]]; then
        ftctl_dr_runtime_materialize_test_artifacts "${plan}" "${run}" "$(ftctl_dr_runtime_test_session_path "${plan}" "${run}")" "${run_path}" || rc=$?
        cp -f "$(ftctl_dr_runtime_test_session_path "${plan}" "${run}")" "$(ftctl_dr_runtime_active_test_session_path "${plan}")" 2>/dev/null || true
      fi
      if [[ "${rc}" != "0" ]]; then
        error_code="DR_RESTORE_POINT_NOT_FOUND"
        [[ "${rc}" == "45" ]] && error_code="DR_TARGET_NOT_READY"
        [[ "${rc}" == "46" ]] && error_code="DR_TEST_MATERIALIZATION_FAILED"
        local failed_step="test-session-restore-point-missing"
        [[ "${rc}" == "46" ]] && failed_step="test-materialization-failed"
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
        if [[ "${json}" == "1" ]]; then
          ftctl_dr_runtime_emit_state_json "${action}" "error" "${plan}" "${run}" "${run_path}" "0"
        else
          printf '%s: plan=%s run=%s restore point unavailable error=%s\n' "${action}" "${plan}" "${run}" "${error_code}" >&2
        fi
        return "${rc}"
      fi
      ftctl_log_event "dr-runtime" "dr.test.failover" "ok" "" "" \
        "plan=${plan} run=${run} restore_point=$(ftctl_dr_runtime_state_get_from_path "${run_path}" "test_restore_point_ref")"
      ;;
    dr-test-cleanup)
      rc=0
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
        if [[ "${json}" == "1" ]]; then
          ftctl_dr_runtime_emit_state_json "${action}" "error" "${plan}" "${run}" "${run_path}" "0"
        else
          printf '%s: plan=%s run=%s cleanup failed rc=%s\n' "${action}" "${plan}" "${run}" "${rc}" >&2
        fi
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
      ftctl_dr_runtime_path_set "${run_path}" \
        "state=ERROR" \
        "step=ablestack-driver-failed" \
        "progress=100" \
        "accepted=false" \
        "error_code=DR_ABLESTACK_DRIVER_FAILED" \
        "updated_at=$(ftctl_now_iso8601)" || true
      cp -f "${run_path}" "${status_path}" 2>/dev/null || true
      chmod 0644 "${status_path}" 2>/dev/null || true
      ftctl_dr_runtime_mark_worker_terminal "${run_path}" "${status_path}" "FAILED" "${rc}" "DR_ABLESTACK_DRIVER_FAILED" "false" ""
      ftctl_log_event "dr-runtime" "dr.ablestack.driver" "fail" "" "${rc}" \
        "plan=${plan} run=${run} action=${action}"
      if [[ "${json}" == "1" ]]; then
        ftctl_dr_runtime_emit_state_json "${action}" "error" "${plan}" "${run}" "${run_path}" "0"
      else
        printf '%s: plan=%s run=%s ablestack driver failed rc=%s\n' "${action}" "${plan}" "${run}" "${rc}" >&2
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

ftctl_dr_runtime_status() {
  local plan="${1-}" run="${2-}" events_offset="${3-0}" json="${4-0}"
  local path result="ok"

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
          "$(ftctl_dr_runtime_events_offset)"
      else
        printf 'dr-status: plan=%s not found\n' "${plan}" >&2
      fi
      return 2
    fi
  fi

  [[ -n "${run}" && ! -f "$(ftctl_dr_runtime_run_path "${plan}" "${run}")" ]] && result="run_not_found"
  if [[ "${json}" == "1" ]]; then
    ftctl_dr_runtime_emit_state_json "dr-status" "${result}" "${plan}" "${run}" "${path}" "${events_offset}"
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
