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

ftctl_xcolo_state_path() {
  local vm="${1-}"
  echo "$(ftctl_state_path "${vm}").xcolo"
}

ftctl_xcolo_state_write() {
  local vm="${1-}"
  shift
  local path tmp line
  path="$(ftctl_xcolo_state_path "${vm}")"
  tmp="$(mktemp -t ftctl.xcolo.XXXXXX)"
  for line in "$@"; do
    printf "%s\n" "${line}" >> "${tmp}"
  done
  mv -f "${tmp}" "${path}"
  chmod 0644 "${path}" 2>/dev/null || true
}

ftctl_xcolo_parse_tcp_endpoint() {
  local endpoint="${1-}"
  local host_var="${2}"
  local port_var="${3}"
  local rest host port
  [[ "${endpoint}" == tcp:* ]] || {
    echo "ERROR: x-colo endpoint must start with tcp:" >&2
    return 2
  }
  rest="${endpoint#tcp:}"
  host="${rest%:*}"
  port="${rest##*:}"
  [[ -n "${host}" && -n "${port}" ]] || {
    echo "ERROR: invalid x-colo endpoint: ${endpoint}" >&2
    return 2
  }
  printf -v "${host_var}" '%s' "${host}"
  printf -v "${port_var}" '%s' "${port}"
}

ftctl_xcolo_qmp() {
  local uri="${1-}"
  local vm="${2-}"
  local payload="${3-}"
  local out_var="${4}"
  local rc_var="${5}"
  local qmp_out qmp_err qmp_rc

  qmp_out=""
  qmp_err=""
  qmp_rc=0
  ftctl_cmd_run "${FTCTL_XCOLO_QMP_TIMEOUT_SEC}" qmp_out qmp_err qmp_rc -- \
    virsh -c "${uri}" qemu-monitor-command "${vm}" --pretty "${payload}" || true
  : "${qmp_err}"
  printf -v "${out_var}" '%s' "${qmp_out}"
  printf -v "${rc_var}" '%s' "${qmp_rc}"
  return 0
}

ftctl_xcolo_qmp_require_ok() {
  local uri="${1-}"
  local vm="${2-}"
  local payload="${3-}"
  local stage="${4-}"
  local event="${5-}"
  local out rc allow_already_negotiated has_error error_desc

  if [[ "${FTCTL_DRY_RUN}" == "1" ]]; then
    ftctl_log_event "${stage}" "${event}" "skip" "${vm}" "" "reason=dry_run"
    return 0
  fi

  out=""
  rc=0
  ftctl_xcolo_qmp "${uri}" "${vm}" "${payload}" out rc
  allow_already_negotiated="0"
  if [[ "${payload}" == '{"execute":"qmp_capabilities"}' ]]; then
    allow_already_negotiated="1"
  fi
  has_error="0"
  error_desc="$(python3 - <<'PY' "${out}"
import json, sys
raw = sys.argv[1]
if not raw.strip():
    raise SystemExit(0)
try:
    data = json.loads(raw)
except Exception:
    raise SystemExit(0)
if isinstance(data, dict) and "error" in data:
    err = data.get("error") or {}
    print((err.get("desc") or "").strip())
    raise SystemExit(10)
raise SystemExit(0)
PY
)" || {
    rc="$?"
    if [[ "${rc}" == "10" ]]; then
      has_error="1"
      rc=0
    fi
  }
  if [[ "${has_error}" == "1" && "${allow_already_negotiated}" == "1" ]]; then
    if [[ "${error_desc}" == *"Capabilities negotiation is already complete"* ]]; then
      has_error="0"
      error_desc=""
    fi
  fi
  if [[ "${rc}" != "0" || "${has_error}" == "1" ]]; then
    ftctl_log_event "${stage}" "${event}" "fail" "${vm}" "${rc}" "uri=${uri} desc=${error_desc:-qmp_error}"
    [[ "${rc}" == "0" ]] && rc=1
    return "${rc}"
  fi
  ftctl_log_event "${stage}" "${event}" "ok" "${vm}" "" "uri=${uri}"
}

ftctl_xcolo_qmp_optional() {
  local uri="${1-}"
  local vm="${2-}"
  local payload="${3-}"
  local stage="${4-}"
  local event="${5-}"
  local out rc error_desc

  if [[ "${FTCTL_DRY_RUN}" == "1" ]]; then
    ftctl_log_event "${stage}" "${event}" "skip" "${vm}" "" "reason=dry_run"
    return 0
  fi

  out=""
  rc=0
  ftctl_xcolo_qmp "${uri}" "${vm}" "${payload}" out rc
  error_desc="$(python3 - <<'PY' "${out}"
import json, sys
raw = sys.argv[1]
try:
    data = json.loads(raw) if raw.strip() else {}
except Exception:
    data = {}
err = data.get("error") if isinstance(data, dict) else None
print(((err or {}).get("desc") or "").strip())
PY
)" || error_desc=""
  if [[ "${rc}" != "0" || -n "${error_desc}" ]]; then
    ftctl_log_event "${stage}" "${event}" "skip" "${vm}" "${rc}" \
      "uri=${uri} desc=${error_desc:-qmp_optional_failed}"
    return 0
  fi
  ftctl_log_event "${stage}" "${event}" "ok" "${vm}" "" "uri=${uri}"
}

ftctl_xcolo_qmp_require_ok_or_exists() {
  local uri="${1-}"
  local vm="${2-}"
  local payload="${3-}"
  local stage="${4-}"
  local event="${5-}"
  local out rc error_desc has_error

  if [[ "${FTCTL_DRY_RUN}" == "1" ]]; then
    ftctl_log_event "${stage}" "${event}" "skip" "${vm}" "" "reason=dry_run"
    return 0
  fi

  out=""
  rc=0
  ftctl_xcolo_qmp "${uri}" "${vm}" "${payload}" out rc
  has_error="0"
  error_desc="$(python3 - <<'PY' "${out}"
import json, sys
raw = sys.argv[1]
try:
    data = json.loads(raw) if raw.strip() else {}
except Exception:
    data = {}
err = data.get("error") if isinstance(data, dict) else None
if err:
    print((err.get("desc") or "").strip())
    raise SystemExit(10)
PY
)" || {
    if [[ "$?" == "10" ]]; then
      has_error="1"
      rc=0
    fi
  }
  if [[ "${has_error}" == "1" ]]; then
    case "${error_desc}" in
      *Duplicate*|*duplicate*|*already\ exists*|*exists*)
        ftctl_log_event "${stage}" "${event}" "ok" "${vm}" "" \
          "uri=${uri} desc=${error_desc}"
        return 0
        ;;
    esac
  fi
  if [[ "${rc}" != "0" || "${has_error}" == "1" ]]; then
    ftctl_log_event "${stage}" "${event}" "fail" "${vm}" "${rc}" \
      "uri=${uri} desc=${error_desc:-qmp_error}"
    [[ "${rc}" == "0" ]] && rc=1
    return "${rc}"
  fi
  ftctl_log_event "${stage}" "${event}" "ok" "${vm}" "" "uri=${uri}"
}

ftctl_xcolo_collect_primary_disk_binding() {
  local vm="${1-}"
  local source_path="${2-}"
  local node_var="${3}"
  local qdev_var="${4}"
  local out rc payload

  out=""
  rc=0
  ftctl_xcolo_qmp "${FTCTL_PROFILE_PRIMARY_URI}" "${vm}" '{"execute":"query-block"}' out rc
  if [[ "${rc}" != "0" || -z "${out}" ]]; then
    return 1
  fi

  payload="$(python3 - <<'PY' "${source_path}" "${out}"
import json, sys
source = sys.argv[1]
raw = sys.argv[2]
try:
    data = json.loads(raw)
except Exception:
    print("|")
    raise SystemExit(0)
for item in data.get("return", []):
    ins = item.get("inserted") or {}
    image = ins.get("image") or {}
    filename = image.get("filename", "")
    node = ins.get("node-name", "")
    qdev = item.get("qdev", "")
    if filename == source:
        print(f"{node}|{qdev}")
        break
else:
    print("|")
PY
)" || payload="|"

  printf -v "${node_var}" '%s' "${payload%%|*}"
  printf -v "${qdev_var}" '%s' "${payload##*|}"
  [[ -n "${payload%%|*}" ]]
}

ftctl_xcolo_query_running_flag() {
  local uri="${1-}"
  local vm="${2-}"
  local running_var="${3}"
  local out rc payload

  out=""
  rc=0
  ftctl_xcolo_qmp "${uri}" "${vm}" '{"execute":"query-status"}' out rc
  if [[ "${rc}" != "0" || -z "${out}" ]]; then
    printf -v "${running_var}" '%s' ""
    return 1
  fi
  payload="$(python3 - <<'PY' "${out}"
import json, sys
raw = sys.argv[1]
try:
    data = json.loads(raw)
except Exception:
    print("")
    raise SystemExit(0)
ret = data.get("return") if isinstance(data, dict) else {}
running = ret.get("running")
if isinstance(running, bool):
    print("true" if running else "false")
else:
    print("")
PY
)" || payload=""
  printf -v "${running_var}" '%s' "${payload}"
  [[ "${payload}" == "true" || "${payload}" == "false" ]]
}

ftctl_xcolo_query_status_name() {
  local uri="${1-}"
  local vm="${2-}"
  local status_var="${3}"
  local out rc payload

  out=""
  rc=0
  ftctl_xcolo_qmp "${uri}" "${vm}" '{"execute":"query-status"}' out rc
  if [[ "${rc}" != "0" || -z "${out}" ]]; then
    printf -v "${status_var}" '%s' ""
    return 1
  fi
  payload="$(python3 - <<'PY' "${out}"
import json, sys
raw = sys.argv[1]
try:
    data = json.loads(raw)
except Exception:
    print("")
    raise SystemExit(0)
ret = data.get("return") if isinstance(data, dict) else {}
print(ret.get("status", "") if isinstance(ret, dict) else "")
PY
)" || payload=""
  printf -v "${status_var}" '%s' "${payload}"
  [[ -n "${payload}" ]]
}

ftctl_xcolo_query_colo_mode() {
  local uri="${1-}"
  local vm="${2-}"
  local mode_var="${3}"
  local out rc payload

  out=""
  rc=0
  ftctl_xcolo_qmp "${uri}" "${vm}" '{"execute":"query-colo-status"}' out rc
  if [[ "${rc}" != "0" || -z "${out}" ]]; then
    printf -v "${mode_var}" '%s' ""
    return 1
  fi
  payload="$(python3 - <<'PY' "${out}"
import json, sys
raw = sys.argv[1]
try:
    data = json.loads(raw)
except Exception:
    print("")
    raise SystemExit(0)
ret = data.get("return") if isinstance(data, dict) else {}
print(ret.get("mode", "") if isinstance(ret, dict) else "")
PY
)" || payload=""
  printf -v "${mode_var}" '%s' "${payload}"
  [[ -n "${payload}" ]]
}

ftctl_xcolo_query_migrate_status() {
  local uri="${1-}"
  local vm="${2-}"
  local status_var="${3}"
  local out rc payload

  out=""
  rc=0
  ftctl_xcolo_qmp "${uri}" "${vm}" '{"execute":"query-migrate"}' out rc
  if [[ "${rc}" != "0" || -z "${out}" ]]; then
    printf -v "${status_var}" '%s' ""
    return 1
  fi
  payload="$(python3 - <<'PY' "${out}"
import json, sys
raw = sys.argv[1]
try:
    data = json.loads(raw)
except Exception:
    print("")
    raise SystemExit(0)
ret = data.get("return") if isinstance(data, dict) else {}
print(ret.get("status", "") if isinstance(ret, dict) else "")
PY
)" || payload=""
  printf -v "${status_var}" '%s' "${payload}"
  [[ -n "${payload}" ]]
}

ftctl_xcolo_query_migrate_error_desc() {
  local uri="${1-}"
  local vm="${2-}"
  local desc_var="${3}"
  local out rc payload

  out=""
  rc=0
  ftctl_xcolo_qmp "${uri}" "${vm}" '{"execute":"query-migrate"}' out rc
  if [[ "${rc}" != "0" || -z "${out}" ]]; then
    printf -v "${desc_var}" '%s' ""
    return 1
  fi
  payload="$(python3 - <<'PY' "${out}"
import json, sys
raw = sys.argv[1]
try:
    data = json.loads(raw)
except Exception:
    print("")
    raise SystemExit(0)
if not isinstance(data, dict):
    print("")
    raise SystemExit(0)
ret = data.get("return") if isinstance(data.get("return"), dict) else {}
err = data.get("error") if isinstance(data.get("error"), dict) else {}
print((ret.get("error-desc") or err.get("desc") or "").strip())
PY
)" || payload=""
  printf -v "${desc_var}" '%s' "${payload}"
  [[ -n "${payload}" ]]
}

ftctl_xcolo_query_migrate_capability_state() {
  local uri="${1-}"
  local vm="${2-}"
  local capability="${3-}"
  local state_var="${4}"
  local out rc payload

  out=""
  rc=0
  ftctl_xcolo_qmp "${uri}" "${vm}" '{"execute":"query-migrate-capabilities"}' out rc
  if [[ "${rc}" != "0" || -z "${out}" ]]; then
    printf -v "${state_var}" '%s' "unknown"
    return 1
  fi
  payload="$(python3 - <<'PY' "${capability}" "${out}"
import json
import sys

name = sys.argv[1]
raw = sys.argv[2]
try:
    data = json.loads(raw)
except Exception:
    print("unknown")
    raise SystemExit(0)

ret = data.get("return") if isinstance(data, dict) else []
if isinstance(ret, list):
    for item in ret:
        if isinstance(item, dict) and item.get("capability") == name:
            state = item.get("state")
            if isinstance(state, bool):
                print("yes" if state else "no")
                raise SystemExit(0)
print("unknown")
PY
)" || payload="unknown"
  printf -v "${state_var}" '%s' "${payload}"
  [[ "${payload}" == "yes" ]]
}

ftctl_xcolo_set_and_verify_migrate_capabilities() {
  local uri="${1-}"
  local domain="${2-}"
  local vm="${3-}"
  local role="${4-}"
  local stage_prefix="${5-}"
  local cap_xcolo="unknown" cap_return_path="unknown"

  ftctl_xcolo_qmp_require_ok "${uri}" "${domain}" \
    '{"execute":"migrate-set-capabilities","arguments":{"capabilities":[{"capability":"return-path","state":true},{"capability":"x-colo","state":true}]}}' \
    "colo" "${stage_prefix}.migrate_set_capabilities" || return 1

  ftctl_xcolo_query_migrate_capability_state "${uri}" "${domain}" "x-colo" cap_xcolo || true
  ftctl_xcolo_query_migrate_capability_state "${uri}" "${domain}" "return-path" cap_return_path || true
  ftctl_state_set "${vm}" \
    "xcolo_${role}_capability_x_colo=${cap_xcolo}" \
    "xcolo_${role}_capability_return_path=${cap_return_path}"

  if [[ "${cap_xcolo}" != "yes" || "${cap_return_path}" != "yes" ]]; then
    ftctl_state_set "${vm}" \
      "last_error=${role}_colo_migrate_capability_missing"
    ftctl_log_event "colo" "${stage_prefix}.migrate_capabilities" "fail" "${vm}" "" \
      "domain=${domain} x_colo=${cap_xcolo} return_path=${cap_return_path}"
    return 1
  fi

  ftctl_log_event "colo" "${stage_prefix}.migrate_capabilities" "ok" "${vm}" "" \
    "domain=${domain} x_colo=${cap_xcolo} return_path=${cap_return_path}"
}

ftctl_xcolo_colo_mode_active() {
  local mode="${1-}"
  [[ -n "${mode}" && "${mode}" != "none" ]]
}

ftctl_xcolo_colo_role_pending_reason() {
  local primary_colo="${1-}"
  local secondary_colo="${2-}"
  local reason_var="${3}"
  local primary_active="0" secondary_active="0" reason

  if ftctl_xcolo_colo_mode_active "${primary_colo}"; then
    primary_active="1"
  fi
  if ftctl_xcolo_colo_mode_active "${secondary_colo}"; then
    secondary_active="1"
  fi

  if [[ "${primary_active}" == "1" && "${secondary_active}" == "1" ]]; then
    reason="runtime_converging"
  elif [[ "${primary_active}" != "1" && "${secondary_active}" == "1" ]]; then
    reason="primary_colo_role_not_entered"
  elif [[ "${primary_active}" == "1" && "${secondary_active}" != "1" ]]; then
    reason="secondary_colo_role_not_entered"
  else
    reason="colo_role_not_entered"
  fi

  printf -v "${reason_var}" '%s' "${reason}"
}

ftctl_xcolo_query_guest_ping() {
  local uri="${1-}"
  local vm="${2-}"
  local qga_var="${3}"
  local out="" err="" rc=0

  ftctl_virsh "${FTCTL_XCOLO_QGA_TIMEOUT_SEC:-5}" out err rc -- \
    -c "${uri}" qemu-agent-command "${vm}" '{"execute":"guest-ping"}' || true
  : "${out}${err}"
  if [[ "${rc}" == "0" ]]; then
    printf -v "${qga_var}" '%s' "yes"
    return 0
  fi
  printf -v "${qga_var}" '%s' "no"
  return 1
}

ftctl_xcolo_preserve_runtime_error() {
  local vm="${1-}"
  local last_error sticky_error protection_state conversion_state transport_state

  last_error="$(ftctl_state_get "${vm}" "last_error" 2>/dev/null || true)"
  [[ -z "${last_error}" ]] || return 0
  sticky_error="$(ftctl_state_get "${vm}" "xcolo_last_runtime_error" 2>/dev/null || true)"
  [[ -n "${sticky_error}" ]] || return 0
  protection_state="$(ftctl_state_get "${vm}" "protection_state" 2>/dev/null || true)"
  conversion_state="$(ftctl_state_get "${vm}" "conversion_state" 2>/dev/null || true)"
  transport_state="$(ftctl_state_get "${vm}" "transport_state" 2>/dev/null || true)"

  if [[ "${protection_state}" == "error" ||
        "${conversion_state}" == "error" ||
        "${transport_state}" == "failed" ]]; then
    ftctl_state_set "${vm}" "last_error=${sticky_error}"
  fi
}

ftctl_xcolo_capture_runtime_snapshot() {
  local vm="${1-}"
  local prefix="${2-}"
  local secondary_vm="${3:-$vm}"
  local primary_running="" secondary_running=""
  local primary_status="" secondary_status=""
  local primary_colo="" secondary_colo=""
  local primary_migrate="" secondary_migrate=""

  ftctl_xcolo_query_running_flag "${FTCTL_PROFILE_PRIMARY_URI}" "${vm}" primary_running || true
  ftctl_xcolo_query_running_flag "${FTCTL_PROFILE_SECONDARY_URI}" "${secondary_vm}" secondary_running || true
  ftctl_xcolo_query_status_name "${FTCTL_PROFILE_PRIMARY_URI}" "${vm}" primary_status || true
  ftctl_xcolo_query_status_name "${FTCTL_PROFILE_SECONDARY_URI}" "${secondary_vm}" secondary_status || true
  ftctl_xcolo_query_colo_mode "${FTCTL_PROFILE_PRIMARY_URI}" "${vm}" primary_colo || true
  ftctl_xcolo_query_colo_mode "${FTCTL_PROFILE_SECONDARY_URI}" "${secondary_vm}" secondary_colo || true
  ftctl_xcolo_query_migrate_status "${FTCTL_PROFILE_PRIMARY_URI}" "${vm}" primary_migrate || true
  ftctl_xcolo_query_migrate_status "${FTCTL_PROFILE_SECONDARY_URI}" "${secondary_vm}" secondary_migrate || true

  if [[ -n "${prefix}" ]]; then
    ftctl_state_set "${vm}" \
      "${prefix}_primary_running=${primary_running}" \
      "${prefix}_secondary_running=${secondary_running}" \
      "${prefix}_primary_status=${primary_status}" \
      "${prefix}_secondary_status=${secondary_status}" \
      "${prefix}_primary_colo_mode=${primary_colo}" \
      "${prefix}_secondary_colo_mode=${secondary_colo}" \
      "${prefix}_primary_migrate_status=${primary_migrate}" \
      "${prefix}_secondary_migrate_status=${secondary_migrate}"
  else
    ftctl_state_set "${vm}" \
      "xcolo_primary_running=${primary_running}" \
      "xcolo_secondary_running=${secondary_running}" \
      "xcolo_primary_status=${primary_status}" \
      "xcolo_secondary_status=${secondary_status}" \
      "xcolo_primary_colo_mode=${primary_colo}" \
      "xcolo_secondary_colo_mode=${secondary_colo}" \
      "xcolo_primary_migrate_status=${primary_migrate}" \
      "xcolo_secondary_migrate_status=${secondary_migrate}"
  fi
}

ftctl_xcolo_debug_dir() {
  local vm="${1-}"
  printf '%s\n' "${FTCTL_RUN_DIR}/debug/xcolo/$(ftctl_state_vm_key "${vm}")"
}

ftctl_xcolo_write_debug_file() {
  local vm="${1-}"
  local name="${2-}"
  local content="${3-}"
  local dir path

  dir="$(ftctl_xcolo_debug_dir "${vm}")"
  ftctl_ensure_dir "${dir}" "0755"
  path="${dir}/${name}"
  printf '%s\n' "${content}" > "${path}"
  chmod 0644 "${path}" 2>/dev/null || true
}

ftctl_xcolo_qmp_debug_snapshot_one() {
  local vm="${1-}"
  local uri="${2-}"
  local domain="${3-}"
  local prefix="${4-}"
  local cmd payload out rc safe_cmd
  local path prop spec

  [[ -n "${uri}" && -n "${domain}" ]] || return 0
  for cmd in \
    query-status \
    query-migrate \
    query-colo-status \
    query-migrate-capabilities \
    query-migrate-parameters \
    query-named-block-nodes \
    query-chardev \
    query-iothreads; do
    payload="{\"execute\":\"${cmd}\"}"
    out=""
    rc=0
    ftctl_xcolo_qmp "${uri}" "${domain}" "${payload}" out rc
    safe_cmd="${cmd//[^a-zA-Z0-9_.-]/_}"
    ftctl_xcolo_write_debug_file "${vm}" "${prefix}-${safe_cmd}.stdout.json" "${out}"
    ftctl_xcolo_write_debug_file "${vm}" "${prefix}-${safe_cmd}.rc" "${rc}"
  done

  for path in /objects /objects/m0 /objects/redire0 /objects/redire1 /objects/comp0 /objects/f1 /objects/f2 /objects/rew0; do
    payload="{\"execute\":\"qom-list\",\"arguments\":{\"path\":\"${path}\"}}"
    out=""
    rc=0
    ftctl_xcolo_qmp "${uri}" "${domain}" "${payload}" out rc
    safe_cmd="qom-list-${path//\//_}"
    ftctl_xcolo_write_debug_file "${vm}" "${prefix}-${safe_cmd}.stdout.json" "${out}"
    ftctl_xcolo_write_debug_file "${vm}" "${prefix}-${safe_cmd}.rc" "${rc}"
  done

  for spec in \
    /objects/m0:netdev \
    /objects/m0:queue \
    /objects/m0:outdev \
    /objects/m0:status \
    /objects/m0:insert \
    /objects/m0:position \
    /objects/redire0:netdev \
    /objects/redire0:queue \
    /objects/redire0:indev \
    /objects/redire0:outdev \
    /objects/redire0:status \
    /objects/redire0:insert \
    /objects/redire0:position \
    /objects/redire1:netdev \
    /objects/redire1:queue \
    /objects/redire1:indev \
    /objects/redire1:outdev \
    /objects/redire1:status \
    /objects/redire1:insert \
    /objects/redire1:position \
    /objects/comp0:primary_in \
    /objects/comp0:secondary_in \
    /objects/comp0:outdev \
    /objects/comp0:iothread \
    /objects/f1:netdev \
    /objects/f1:queue \
    /objects/f1:indev \
    /objects/f1:status \
    /objects/f1:insert \
    /objects/f1:position \
    /objects/f2:netdev \
    /objects/f2:queue \
    /objects/f2:outdev \
    /objects/f2:status \
    /objects/f2:insert \
    /objects/f2:position \
    /objects/rew0:netdev \
    /objects/rew0:queue \
    /objects/rew0:status \
    /objects/rew0:insert \
    /objects/rew0:position; do
    path="${spec%%:*}"
    prop="${spec#*:}"
    payload="{\"execute\":\"qom-get\",\"arguments\":{\"path\":\"${path}\",\"property\":\"${prop}\"}}"
    out=""
    rc=0
    ftctl_xcolo_qmp "${uri}" "${domain}" "${payload}" out rc
    safe_cmd="qom-get-${path//\//_}-${prop//[^a-zA-Z0-9_.-]/_}"
    ftctl_xcolo_write_debug_file "${vm}" "${prefix}-${safe_cmd}.stdout.json" "${out}"
    ftctl_xcolo_write_debug_file "${vm}" "${prefix}-${safe_cmd}.rc" "${rc}"
  done
}

ftctl_xcolo_query_primary_qmp_diag_value() {
  local vm="${1-}"
  local cmd="${2-}"
  local expr="${3-}"
  local out rc value

  out=""
  rc=0
  ftctl_xcolo_qmp "${FTCTL_PROFILE_PRIMARY_URI}" "${vm}" "{\"execute\":\"${cmd}\"}" out rc
  if [[ "${rc}" != "0" || -z "${out}" ]]; then
    printf '%s\n' "unknown"
    return 0
  fi
  value="$(python3 - <<'PY' "${expr}" "${out}"
import json
import sys

expr = sys.argv[1]
raw = sys.argv[2]
try:
    data = json.loads(raw)
except Exception:
    print("unknown")
    raise SystemExit(0)

ret = data.get("return") if isinstance(data, dict) else None

if expr.startswith("cap:"):
    name = expr.split(":", 1)[1]
    if isinstance(ret, list):
        for item in ret:
            if isinstance(item, dict) and item.get("capability") == name:
                state = item.get("state")
                if isinstance(state, bool):
                    print("yes" if state else "no")
                    raise SystemExit(0)
    print("unknown")
elif expr.startswith("param:"):
    name = expr.split(":", 1)[1]
    if isinstance(ret, dict) and name in ret:
        value = ret.get(name)
        if value is None:
            print("no")
        else:
            print("yes")
    else:
        print("unknown")
else:
    print("unknown")
PY
)" || value="unknown"
  printf '%s\n' "${value}"
}

ftctl_xcolo_query_primary_checkpoint_delay_value() {
  local vm="${1-}"
  local out="" rc=0 value

  ftctl_xcolo_qmp "${FTCTL_PROFILE_PRIMARY_URI}" "${vm}" '{"execute":"query-migrate-parameters"}' out rc
  if [[ "${rc}" != "0" || -z "${out}" ]]; then
    printf '%s\n' "unknown"
    return 0
  fi

  value="$(python3 - <<'PY' "${out}"
import json
import sys

raw = sys.argv[1]
try:
    data = json.loads(raw)
except Exception:
    print("unknown")
    raise SystemExit(0)

ret = data.get("return") if isinstance(data, dict) else {}
value = ret.get("x-checkpoint-delay") if isinstance(ret, dict) else None
if value is None:
    print("no")
else:
    print(value)
PY
)" || value="unknown"
  printf '%s\n' "${value}"
}

ftctl_xcolo_collect_primary_chardev_binding_state() {
  local vm="${1-}"
  local phase="${2:-strict}"
  local out rc payload state_args=()

  out=""
  rc=0
  ftctl_xcolo_qmp "${FTCTL_PROFILE_PRIMARY_URI}" "${vm}" '{"execute":"query-chardev"}' out rc
  if [[ "${rc}" != "0" || -z "${out}" ]]; then
    ftctl_state_set "${vm}" \
      "xcolo_primary_filter_chardev_ready=unknown" \
      "xcolo_primary_filter_chardev_reason=query_chardev_failed"
    return 1
  fi

  payload="$(python3 - "${out}" "${phase}" \
    "$(ftctl_state_get "${vm}" "xcolo_channel_mirror_established" 2>/dev/null || true)" \
    "$(ftctl_state_get "${vm}" "xcolo_channel_mirror_listen" 2>/dev/null || true)" \
    "$(ftctl_state_get "${vm}" "xcolo_channel_compare_established" 2>/dev/null || true)" \
    "$(ftctl_state_get "${vm}" "xcolo_channel_compare_listen" 2>/dev/null || true)" \
    "$(ftctl_state_get "${vm}" "xcolo_channel_compare_out_established" 2>/dev/null || true)" <<'PY'
import json
import re
import sys

required = ["mirror0", "compare1", "compare0", "compare0-0", "compare_out", "compare_out0"]
phase = sys.argv[2] if len(sys.argv) > 2 else "strict"
channel = {
    "mirror_established": sys.argv[3] if len(sys.argv) > 3 else "",
    "mirror_listen": sys.argv[4] if len(sys.argv) > 4 else "",
    "compare_established": sys.argv[5] if len(sys.argv) > 5 else "",
    "compare_listen": sys.argv[6] if len(sys.argv) > 6 else "",
    "compare_out_established": sys.argv[7] if len(sys.argv) > 7 else "",
}

def pre_migrate_accepts_closed(label):
    if phase != "pre_migrate":
        return False
    if label == "mirror0":
        return channel["mirror_established"] == "yes" or channel["mirror_listen"] == "yes"
    if label == "compare0":
        return channel["compare_established"] == "yes" or channel["compare_listen"] == "yes"
    if label == "compare_out0":
        return channel["compare_out_established"] == "yes"
    return False

try:
    data = json.loads(sys.argv[1])
except Exception:
    print("ready=unknown")
    print("reason=query_chardev_parse_failed")
    raise SystemExit(0)

items = {}
for item in data.get("return", []):
    label = item.get("label")
    if label:
        items[label] = item

ready = True
reasons = []
for label in required:
    item = items.get(label)
    key = re.sub(r"[^A-Za-z0-9_.-]", "_", label)
    if item is None:
        ready = False
        reasons.append(f"{label}:missing")
        print(f"{key}=missing")
        continue
    opened = item.get("frontend-open")
    if opened is True:
        print(f"{key}=yes")
    elif opened is False:
        if pre_migrate_accepts_closed(label):
            print(f"{key}=accepted_closed")
        else:
            ready = False
            reasons.append(f"{label}:frontend_closed")
            print(f"{key}=no")
    else:
        ready = False
        reasons.append(f"{label}:frontend_unknown")
        print(f"{key}=unknown")

print(f"ready={'yes' if ready else 'no'}")
print("reason=" + (",".join(reasons) if reasons else ""))
PY
)" || payload="ready=unknown"$'\n'"reason=query_chardev_parse_failed"

  while IFS= read -r line; do
    [[ -n "${line}" ]] || continue
    case "${line}" in
      ready=*)
        state_args+=("xcolo_primary_filter_chardev_ready=${line#ready=}")
        ;;
      reason=*)
        state_args+=("xcolo_primary_filter_chardev_reason=${line#reason=}")
        ;;
      *=*)
        state_args+=("xcolo_primary_chardev_${line}")
        ;;
    esac
  done <<< "${payload}"
  state_args+=("xcolo_primary_filter_chardev_phase=${phase}")
  ftctl_state_set "${vm}" "${state_args[@]}"
  [[ "$(ftctl_state_get "${vm}" "xcolo_primary_filter_chardev_ready" 2>/dev/null || true)" == "yes" ]]
}

ftctl_xcolo_qom_get_property() {
  local uri="${1-}"
  local vm="${2-}"
  local path="${3-}"
  local prop="${4-}"
  local out_var="${5-}"
  local out rc qom_value

  out=""
  rc=0
  ftctl_xcolo_qmp "${uri}" "${vm}" \
    "{\"execute\":\"qom-get\",\"arguments\":{\"path\":\"${path}\",\"property\":\"${prop}\"}}" out rc
  if [[ "${rc}" != "0" || -z "${out}" ]]; then
    printf -v "${out_var}" '%s' "unknown"
    return 1
  fi

  qom_value="$(python3 - <<'PY' "${out}"
import json
import sys

try:
    data = json.loads(sys.argv[1])
except Exception:
    print("unknown")
    raise SystemExit(1)

if not isinstance(data, dict) or "error" in data:
    print("unknown")
    raise SystemExit(1)

value = data.get("return")
if value is None:
    print("")
elif isinstance(value, bool):
    print("true" if value else "false")
else:
    print(str(value))
PY
)" || {
    printf -v "${out_var}" '%s' "unknown"
    return 1
  }

  printf -v "${out_var}" '%s' "${qom_value}"
  return 0
}

ftctl_xcolo_qom_list_names() {
  local uri="${1-}"
  local vm="${2-}"
  local path="${3-}"
  local names_var="${4-}"
  local out rc payload

  out=""
  rc=0
  ftctl_xcolo_qmp "${uri}" "${vm}" \
    "{\"execute\":\"qom-list\",\"arguments\":{\"path\":\"${path}\"}}" out rc
  if [[ "${rc}" != "0" || -z "${out}" ]]; then
    printf -v "${names_var}" '%s' ""
    return 1
  fi

  payload="$(python3 - <<'PY' "${out}"
import json
import sys

try:
    data = json.loads(sys.argv[1])
except Exception:
    raise SystemExit(1)
if not isinstance(data, dict) or "error" in data:
    raise SystemExit(1)
items = data.get("return")
if not isinstance(items, list):
    raise SystemExit(1)
for item in items:
    if isinstance(item, dict) and item.get("name"):
        print(item.get("name"))
PY
)" || payload=""
  printf -v "${names_var}" '%s' "${payload}"
  [[ -n "${payload}" ]]
}

ftctl_xcolo_qom_child_path() {
  local uri="${1-}"
  local vm="${2-}"
  local object_id="${3-}"
  local path_var="${4-}"
  local objects names

  objects=""
  if ftctl_xcolo_qom_list_names "${uri}" "${vm}" "/objects" objects &&
      printf '%s\n' "${objects}" | grep -Fxq "${object_id}"; then
    printf -v "${path_var}" '%s' "/objects/${object_id}"
    return 0
  fi

  names=""
  if ftctl_xcolo_qom_list_names "${uri}" "${vm}" "/objects/${object_id}" names; then
    printf -v "${path_var}" '%s' "/objects/${object_id}"
    return 0
  fi

  printf -v "${path_var}" '%s' ""
  return 1
}

ftctl_xcolo_qom_path_has_property() {
  local uri="${1-}"
  local vm="${2-}"
  local path="${3-}"
  local prop="${4-}"
  local names

  names=""
  ftctl_xcolo_qom_list_names "${uri}" "${vm}" "${path}" names || return 1
  printf '%s\n' "${names}" | grep -Fxq "${prop}"
}

ftctl_xcolo_net_model_requires_vnet_hdr() {
  local model="${1-}"
  model="${model,,}"
  [[ "${model}" == virtio* ]]
}

ftctl_xcolo_vnet_hdr_required() {
  local vm="${1-}"
  local primary_model secondary_model

  primary_model="$(ftctl_state_get "${vm}" "xcolo_primary_netdev_model" 2>/dev/null || true)"
  secondary_model="$(ftctl_state_get "${vm}" "xcolo_secondary_netdev_model" 2>/dev/null || true)"
  ftctl_xcolo_net_model_requires_vnet_hdr "${primary_model}" ||
    ftctl_xcolo_net_model_requires_vnet_hdr "${secondary_model}"
}

ftctl_xcolo_update_vnet_hdr_state() {
  local vm="${1-}"
  local required="off"
  local reason="not_required"
  local primary_model secondary_model

  primary_model="$(ftctl_state_get "${vm}" "xcolo_primary_netdev_model" 2>/dev/null || true)"
  secondary_model="$(ftctl_state_get "${vm}" "xcolo_secondary_netdev_model" 2>/dev/null || true)"
  if ftctl_xcolo_net_model_requires_vnet_hdr "${primary_model}" ||
      ftctl_xcolo_net_model_requires_vnet_hdr "${secondary_model}"; then
    required="on"
    reason="virtio_net_model"
  fi

  ftctl_state_set "${vm}" \
    "xcolo_net_vnet_hdr_support=${required}" \
    "xcolo_net_vnet_hdr_support_reason=${reason}" \
    "xcolo_net_vnet_hdr_primary_model=${primary_model}" \
    "xcolo_net_vnet_hdr_secondary_model=${secondary_model}"
}

ftctl_xcolo_vnet_hdr_arg() {
  local vm="${1-}"
  if ftctl_xcolo_vnet_hdr_required "${vm}"; then
    printf '%s' ",vnet_hdr_support=on"
  fi
}

ftctl_xcolo_firewall_probe_cmd() {
  cat <<'EOF'
set -euo pipefail
missing=""
state="unknown"
service="unknown"
if ! command -v firewall-cmd >/dev/null 2>&1; then
  echo "state=missing"
  echo "service=unknown"
  echo "missing_ports="
  echo "ready=unknown"
  exit 0
fi
if ! systemctl is-active --quiet firewalld 2>/dev/null; then
  echo "state=inactive"
  echo "service=unknown"
  echo "missing_ports="
  echo "ready=yes"
  exit 0
fi
state="active"
service="missing"
if firewall-cmd --query-service=ablestack-vm-ftctl-remote-nbd >/dev/null 2>&1; then
  service="present"
fi
for port in 9000 9003 9004 9998; do
  if [[ "${service}" == "present" ]] || firewall-cmd --query-port="${port}/tcp" >/dev/null 2>&1; then
    :
  else
    missing="${missing}${missing:+,}${port}/tcp"
  fi
done
if [[ "${service}" == "present" ]] || firewall-cmd --query-port=10809-10872/tcp >/dev/null 2>&1 || firewall-cmd --query-port=10809/tcp >/dev/null 2>&1; then
  :
else
  missing="${missing}${missing:+,}10809-10872/tcp"
fi
echo "state=${state}"
echo "service=${service}"
echo "missing_ports=${missing}"
if [[ -z "${missing}" ]]; then
  echo "ready=yes"
else
  echo "ready=no"
fi
EOF
}

ftctl_xcolo_parse_probe_field() {
  local payload="${1-}"
  local key="${2-}"
  printf '%s\n' "${payload}" | awk -F= -v k="${key}" '$1 == k {print substr($0, length(k) + 2); exit}'
}

ftctl_xcolo_firewall_probe_local() {
  local out_var="${1}"
  local err_var="${2}"
  local rc_var="${3}"
  local cmd out="" err="" rc=0

  cmd="$(ftctl_xcolo_firewall_probe_cmd)"
  ftctl_cmd_run "${FTCTL_BLOCKCOPY_WAIT_TIMEOUT_SEC:-15}" out err rc -- bash -lc "${cmd}" || true
  printf -v "${out_var}" '%s' "${out}"
  printf -v "${err_var}" '%s' "${err}"
  printf -v "${rc_var}" '%s' "${rc}"
}

ftctl_xcolo_firewall_probe_remote() {
  local host="${1-}"
  local user="${2-}"
  local out_var="${3}"
  local err_var="${4}"
  local rc_var="${5}"
  local cmd out="" err="" rc=0

  cmd="$(ftctl_xcolo_firewall_probe_cmd)"
  ftctl_blockcopy_remote_exec "${host}" "${user}" out err rc "${cmd}" || true
  printf -v "${out_var}" '%s' "${out}"
  printf -v "${err_var}" '%s' "${err}"
  printf -v "${rc_var}" '%s' "${rc}"
}

ftctl_xcolo_preflight_firewall_contract() {
  local vm="${1-}"
  local host="" user="" primary_out="" primary_err="" secondary_out="" secondary_err=""
  local primary_rc=0 secondary_rc=0
  local primary_state primary_service primary_missing primary_ready
  local secondary_state secondary_service secondary_missing secondary_ready
  local missing_summary="" ready="yes"

  [[ -n "${vm}" ]] || return 1
  ftctl_xcolo_firewall_probe_local primary_out primary_err primary_rc
  primary_state="$(ftctl_xcolo_parse_probe_field "${primary_out}" state)"
  primary_service="$(ftctl_xcolo_parse_probe_field "${primary_out}" service)"
  primary_missing="$(ftctl_xcolo_parse_probe_field "${primary_out}" missing_ports)"
  primary_ready="$(ftctl_xcolo_parse_probe_field "${primary_out}" ready)"
  [[ -n "${primary_state}" ]] || primary_state="probe_failed"
  [[ -n "${primary_service}" ]] || primary_service="unknown"
  [[ -n "${primary_ready}" ]] || primary_ready="unknown"

  if ftctl_blockcopy_remote_target_host_user host user; then
    ftctl_xcolo_firewall_probe_remote "${host}" "${user}" secondary_out secondary_err secondary_rc
    secondary_state="$(ftctl_xcolo_parse_probe_field "${secondary_out}" state)"
    secondary_service="$(ftctl_xcolo_parse_probe_field "${secondary_out}" service)"
    secondary_missing="$(ftctl_xcolo_parse_probe_field "${secondary_out}" missing_ports)"
    secondary_ready="$(ftctl_xcolo_parse_probe_field "${secondary_out}" ready)"
    [[ -n "${secondary_state}" ]] || secondary_state="probe_failed"
    [[ -n "${secondary_service}" ]] || secondary_service="unknown"
    [[ -n "${secondary_ready}" ]] || secondary_ready="unknown"
  else
    secondary_state="target_unresolved"
    secondary_service="unknown"
    secondary_missing=""
    secondary_ready="unknown"
  fi

  if [[ "${primary_ready}" == "no" ]]; then
    ready="no"
    missing_summary="${missing_summary}${missing_summary:+;}primary:${primary_missing:-unknown}"
  fi
  if [[ "${secondary_ready}" == "no" ]]; then
    ready="no"
    missing_summary="${missing_summary}${missing_summary:+;}secondary:${secondary_missing:-unknown}"
  fi

  ftctl_state_set "${vm}" \
    "xcolo_firewall_primary_state=${primary_state}" \
    "xcolo_firewall_primary_service=${primary_service}" \
    "xcolo_firewall_primary_missing_ports=${primary_missing}" \
    "xcolo_firewall_primary_ready=${primary_ready}" \
    "xcolo_firewall_primary_probe_rc=${primary_rc}" \
    "xcolo_firewall_secondary_state=${secondary_state}" \
    "xcolo_firewall_secondary_service=${secondary_service}" \
    "xcolo_firewall_secondary_missing_ports=${secondary_missing}" \
    "xcolo_firewall_secondary_ready=${secondary_ready}" \
    "xcolo_firewall_secondary_probe_rc=${secondary_rc}" \
    "xcolo_firewall_ready=${ready}" \
    "xcolo_firewall_missing_ports=${missing_summary}"

  if [[ "${ready}" == "no" ]]; then
    ftctl_state_set "${vm}" "last_error=xcolo_firewall_ports_missing"
    ftctl_log_event "colo" "xcolo.firewall_preflight" "fail" "${vm}" "" \
      "primary_state=${primary_state} primary_missing=${primary_missing} secondary_state=${secondary_state} secondary_missing=${secondary_missing}"
    return 1
  fi

  ftctl_log_event "colo" "xcolo.firewall_preflight" "ok" "${vm}" "" \
    "primary_state=${primary_state} primary_ready=${primary_ready} secondary_state=${secondary_state} secondary_ready=${secondary_ready}"
  return 0
}

ftctl_xcolo_vnet_hdr_qmp_bool_arg() {
  local vm="${1-}"
  if ftctl_xcolo_vnet_hdr_required "${vm}"; then
    printf '%s' ',"vnet_hdr_support":true'
  fi
}

ftctl_xcolo_collect_primary_filter_vnet_hdr_qom_state() {
  local vm="${1-}"
  local required value ready="yes" reason=""
  local m0_path redire0_path redire1_path comp0_path
  local -a state_args=()

  required="$(ftctl_state_get "${vm}" "xcolo_net_vnet_hdr_support" 2>/dev/null || true)"
  [[ -n "${required}" ]] || required="off"

  m0_path="$(ftctl_state_get "${vm}" "xcolo_primary_filter_qom_m0_path" 2>/dev/null || true)"
  redire0_path="$(ftctl_state_get "${vm}" "xcolo_primary_filter_qom_redire0_path" 2>/dev/null || true)"
  redire1_path="$(ftctl_state_get "${vm}" "xcolo_primary_filter_qom_redire1_path" 2>/dev/null || true)"
  comp0_path="$(ftctl_state_get "${vm}" "xcolo_primary_filter_qom_comp0_path" 2>/dev/null || true)"

  _ftctl_xcolo_collect_vnet_hdr_prop() {
    local path="${1-}"
    local key="${2-}"
    value=""
    if [[ -z "${path}" ]]; then
      value="missing"
      [[ "${required}" == "on" ]] && ready="no" && reason="${reason}${reason:+,}${key}:missing"
    elif ftctl_xcolo_qom_get_property "${FTCTL_PROFILE_PRIMARY_URI}" "${vm}" "${path}" "vnet_hdr_support" value; then
      case "${value}" in
        true|on|yes|1) value="on" ;;
        false|off|no|0|"") value="off" ;;
      esac
      if [[ "${required}" == "on" && "${value}" != "on" ]]; then
        ready="no"
        reason="${reason}${reason:+,}${key}:${value:-off}"
      fi
    else
      value="unknown"
      if [[ "${required}" == "on" ]]; then
        ready="unknown"
        reason="${reason}${reason:+,}${key}:unknown"
      fi
    fi
    state_args+=("xcolo_primary_filter_qom_${key}_vnet_hdr_support=${value}")
  }

  _ftctl_xcolo_collect_vnet_hdr_prop "${m0_path}" "m0"
  _ftctl_xcolo_collect_vnet_hdr_prop "${redire0_path}" "redire0"
  _ftctl_xcolo_collect_vnet_hdr_prop "${redire1_path}" "redire1"
  _ftctl_xcolo_collect_vnet_hdr_prop "${comp0_path}" "comp0"

  ftctl_state_set "${vm}" \
    "xcolo_primary_filter_qom_vnet_hdr_required=${required}" \
    "xcolo_primary_filter_qom_vnet_hdr_ready=${ready}" \
    "xcolo_primary_filter_qom_vnet_hdr_reason=${reason}" \
    "${state_args[@]}"
  [[ "${ready}" != "no" ]]
}

ftctl_xcolo_collect_primary_filter_qom_state() {
  local vm="${1-}"
  local expected_status="${2:-on}"
  local ready="yes"
  local inconclusive="no"
  local reasons=()
  local value expected_netdev path m0_path redire0_path redire1_path comp0_path
  local -a state_args=()

  case "${expected_status}" in
    on|off) ;;
    *) expected_status="on" ;;
  esac
  expected_netdev="$(ftctl_state_get "${vm}" "xcolo_primary_netdev_id" 2>/dev/null || true)"
  expected_netdev="${expected_netdev:-hostnet0}"

  _ftctl_xcolo_expect_qom() {
    local path="${1-}"
    local prop="${2-}"
    local expected="${3-}"
    local key="${4-}"

    value=""
    if ! ftctl_xcolo_qom_get_property "${FTCTL_PROFILE_PRIMARY_URI}" "${vm}" "${path}" "${prop}" value; then
      inconclusive="yes"
      reasons+=("${key}:unknown")
    elif [[ -n "${expected}" && -z "${value}" ]]; then
      inconclusive="yes"
      reasons+=("${key}:empty")
    elif [[ "${value}" != "${expected}" ]]; then
      ready="no"
      reasons+=("${key}:${value:-empty}")
    fi
    state_args+=("xcolo_primary_filter_qom_${key}=${value}")
  }

  m0_path=""
  redire0_path=""
  redire1_path=""
  comp0_path=""
  ftctl_xcolo_qom_child_path "${FTCTL_PROFILE_PRIMARY_URI}" "${vm}" "m0" m0_path || true
  ftctl_xcolo_qom_child_path "${FTCTL_PROFILE_PRIMARY_URI}" "${vm}" "redire0" redire0_path || true
  ftctl_xcolo_qom_child_path "${FTCTL_PROFILE_PRIMARY_URI}" "${vm}" "redire1" redire1_path || true
  ftctl_xcolo_qom_child_path "${FTCTL_PROFILE_PRIMARY_URI}" "${vm}" "comp0" comp0_path || true

  state_args+=(
    "xcolo_primary_filter_qom_expected_netdev=${expected_netdev}"
    "xcolo_primary_filter_qom_expected_status=${expected_status}"
    "xcolo_primary_filter_qom_m0_path=${m0_path}"
    "xcolo_primary_filter_qom_redire0_path=${redire0_path}"
    "xcolo_primary_filter_qom_redire1_path=${redire1_path}"
    "xcolo_primary_filter_qom_comp0_path=${comp0_path}"
  )

  for path in \
    "m0:${m0_path}" \
    "redire0:${redire0_path}" \
    "redire1:${redire1_path}" \
    "comp0:${comp0_path}"; do
    if [[ -z "${path#*:}" ]]; then
      ready="no"
      reasons+=("${path%%:*}:missing")
    fi
  done

  _ftctl_xcolo_expect_qom "${m0_path}" "netdev" "${expected_netdev}" "m0_netdev"
  _ftctl_xcolo_expect_qom "${m0_path}" "queue" "tx" "m0_queue"
  _ftctl_xcolo_expect_qom "${m0_path}" "outdev" "mirror0" "m0_outdev"
  _ftctl_xcolo_expect_qom "${m0_path}" "status" "${expected_status}" "m0_status"
  _ftctl_xcolo_expect_qom "${m0_path}" "insert" "behind" "m0_insert"
  _ftctl_xcolo_expect_qom "${m0_path}" "position" "tail" "m0_position"

  _ftctl_xcolo_expect_qom "${redire0_path}" "netdev" "${expected_netdev}" "redire0_netdev"
  _ftctl_xcolo_expect_qom "${redire0_path}" "queue" "rx" "redire0_queue"
  _ftctl_xcolo_expect_qom "${redire0_path}" "indev" "compare_out" "redire0_indev"
  _ftctl_xcolo_expect_qom "${redire0_path}" "outdev" "" "redire0_outdev"
  _ftctl_xcolo_expect_qom "${redire0_path}" "status" "${expected_status}" "redire0_status"
  _ftctl_xcolo_expect_qom "${redire0_path}" "insert" "behind" "redire0_insert"
  _ftctl_xcolo_expect_qom "${redire0_path}" "position" "tail" "redire0_position"

  _ftctl_xcolo_expect_qom "${redire1_path}" "netdev" "${expected_netdev}" "redire1_netdev"
  _ftctl_xcolo_expect_qom "${redire1_path}" "queue" "rx" "redire1_queue"
  _ftctl_xcolo_expect_qom "${redire1_path}" "indev" "" "redire1_indev"
  _ftctl_xcolo_expect_qom "${redire1_path}" "outdev" "compare0" "redire1_outdev"
  _ftctl_xcolo_expect_qom "${redire1_path}" "status" "${expected_status}" "redire1_status"
  _ftctl_xcolo_expect_qom "${redire1_path}" "insert" "behind" "redire1_insert"
  _ftctl_xcolo_expect_qom "${redire1_path}" "position" "tail" "redire1_position"

  _ftctl_xcolo_expect_qom "${comp0_path}" "primary_in" "compare0-0" "comp0_primary_in"
  _ftctl_xcolo_expect_qom "${comp0_path}" "secondary_in" "compare1" "comp0_secondary_in"
  _ftctl_xcolo_expect_qom "${comp0_path}" "outdev" "compare_out0" "comp0_outdev"

  ftctl_xcolo_qom_get_property "${FTCTL_PROFILE_PRIMARY_URI}" "${vm}" "${comp0_path}" "iothread" value || value="unknown"
  if [[ -z "${value}" || "${value}" == "unknown" ]]; then
    inconclusive="yes"
    reasons+=("comp0_iothread:${value:-empty}")
  elif [[ "${value}" != "/objects/iothread1" && "${value}" != "iothread1" ]]; then
    ready="no"
    reasons+=("comp0_iothread:${value:-empty}")
  fi
  state_args+=("xcolo_primary_filter_qom_comp0_iothread=${value}")

  if [[ "${ready}" == "yes" && "${inconclusive}" == "yes" ]]; then
    ready="unknown"
  fi

  local reason_text
  reason_text="$(IFS=,; printf '%s' "${reasons[*]}")"
  ftctl_state_set "${vm}" \
    "xcolo_primary_filter_qom_ready=${ready}" \
    "xcolo_primary_filter_qom_reason=${reason_text}" \
    "${state_args[@]}"
  ftctl_xcolo_collect_primary_filter_vnet_hdr_qom_state "${vm}" || true
  [[ "${ready}" == "yes" ]]
}

ftctl_xcolo_record_pre_migrate_evidence() {
  local vm="${1-}"
  local expected_filter_status="${2:-on}"
  local cap_xcolo cap_return_path checkpoint_delay
  local filter_qom filter_qom_reason filter_cmdline filter_cmdline_reason chardev chardev_reason
  local channel_mirror channel_compare channel_compare_local channel_compare_out
  local ts

  [[ -n "${vm}" ]] || return 1

  ts="$(ftctl_now_iso8601)"
  ftctl_xcolo_capture_primary_channel_state "${vm}" || true
  ftctl_xcolo_capture_socket_snapshot "${vm}" "pre_migrate" || true
  ftctl_xcolo_collect_primary_chardev_binding_state "${vm}" "pre_migrate" || true
  ftctl_xcolo_collect_primary_filter_qom_state "${vm}" "${expected_filter_status}" || true
  ftctl_xcolo_collect_primary_filter_cmdline_state "${vm}" || true

  cap_xcolo="$(ftctl_xcolo_query_primary_qmp_diag_value "${vm}" "query-migrate-capabilities" "cap:x-colo")"
  cap_return_path="$(ftctl_xcolo_query_primary_qmp_diag_value "${vm}" "query-migrate-capabilities" "cap:return-path")"
  checkpoint_delay="$(ftctl_xcolo_query_primary_qmp_diag_value "${vm}" "query-migrate-parameters" "param:x-checkpoint-delay")"
  filter_qom="$(ftctl_state_get "${vm}" "xcolo_primary_filter_qom_ready" 2>/dev/null || true)"
  filter_qom_reason="$(ftctl_state_get "${vm}" "xcolo_primary_filter_qom_reason" 2>/dev/null || true)"
  filter_cmdline="$(ftctl_state_get "${vm}" "xcolo_primary_filter_cmdline_ready" 2>/dev/null || true)"
  filter_cmdline_reason="$(ftctl_state_get "${vm}" "xcolo_primary_filter_cmdline_reason" 2>/dev/null || true)"
  chardev="$(ftctl_state_get "${vm}" "xcolo_primary_filter_chardev_ready" 2>/dev/null || true)"
  chardev_reason="$(ftctl_state_get "${vm}" "xcolo_primary_filter_chardev_reason" 2>/dev/null || true)"
  channel_mirror="$(ftctl_state_get "${vm}" "xcolo_channel_mirror_established" 2>/dev/null || true)"
  channel_compare="$(ftctl_state_get "${vm}" "xcolo_channel_compare_established" 2>/dev/null || true)"
  channel_compare_local="$(ftctl_state_get "${vm}" "xcolo_channel_compare_local_established" 2>/dev/null || true)"
  channel_compare_out="$(ftctl_state_get "${vm}" "xcolo_channel_compare_out_established" 2>/dev/null || true)"

  ftctl_state_set "${vm}" \
    "xcolo_premigrate_evidence_ts=${ts}" \
    "xcolo_premigrate_vnet_hdr_support=$(ftctl_state_get "${vm}" "xcolo_net_vnet_hdr_support" 2>/dev/null || true)" \
    "xcolo_premigrate_primary_filter_qom_vnet_hdr_ready=$(ftctl_state_get "${vm}" "xcolo_primary_filter_qom_vnet_hdr_ready" 2>/dev/null || true)" \
    "xcolo_premigrate_primary_filter_qom_vnet_hdr_reason=$(ftctl_state_get "${vm}" "xcolo_primary_filter_qom_vnet_hdr_reason" 2>/dev/null || true)" \
    "xcolo_premigrate_primary_capability_x_colo=${cap_xcolo}" \
    "xcolo_premigrate_primary_capability_return_path=${cap_return_path}" \
    "xcolo_premigrate_primary_checkpoint_delay=${checkpoint_delay}" \
    "xcolo_premigrate_primary_checkpoint_delay_ready=$(ftctl_state_get "${vm}" "xcolo_primary_checkpoint_delay_ready" 2>/dev/null || true)" \
    "xcolo_premigrate_primary_checkpoint_delay_expected=$(ftctl_state_get "${vm}" "xcolo_primary_checkpoint_delay_expected" 2>/dev/null || true)" \
    "xcolo_premigrate_primary_checkpoint_delay_actual=$(ftctl_state_get "${vm}" "xcolo_primary_checkpoint_delay_actual" 2>/dev/null || true)" \
    "xcolo_premigrate_primary_filter_qom_ready=${filter_qom}" \
    "xcolo_premigrate_primary_filter_qom_reason=${filter_qom_reason}" \
    "xcolo_premigrate_primary_filter_qom_expected_status=${expected_filter_status}" \
    "xcolo_premigrate_primary_filter_cmdline_ready=${filter_cmdline}" \
    "xcolo_premigrate_primary_filter_cmdline_reason=${filter_cmdline_reason}" \
    "xcolo_premigrate_primary_filter_chardev_ready=${chardev}" \
    "xcolo_premigrate_primary_filter_chardev_reason=${chardev_reason}" \
    "xcolo_premigrate_channel_mirror_established=${channel_mirror}" \
    "xcolo_premigrate_channel_compare_established=${channel_compare}" \
    "xcolo_premigrate_channel_compare_local_established=${channel_compare_local}" \
    "xcolo_premigrate_channel_compare_out_established=${channel_compare_out}" \
    "xcolo_premigrate_primary_filter_qom_expected_netdev=$(ftctl_state_get "${vm}" "xcolo_primary_filter_qom_expected_netdev" 2>/dev/null || true)" \
    "xcolo_premigrate_primary_filter_qom_m0_netdev=$(ftctl_state_get "${vm}" "xcolo_primary_filter_qom_m0_netdev" 2>/dev/null || true)" \
    "xcolo_premigrate_primary_filter_qom_m0_outdev=$(ftctl_state_get "${vm}" "xcolo_primary_filter_qom_m0_outdev" 2>/dev/null || true)" \
    "xcolo_premigrate_primary_filter_qom_redire0_indev=$(ftctl_state_get "${vm}" "xcolo_primary_filter_qom_redire0_indev" 2>/dev/null || true)" \
    "xcolo_premigrate_primary_filter_qom_redire1_outdev=$(ftctl_state_get "${vm}" "xcolo_primary_filter_qom_redire1_outdev" 2>/dev/null || true)" \
    "xcolo_premigrate_primary_filter_qom_comp0_primary_in=$(ftctl_state_get "${vm}" "xcolo_primary_filter_qom_comp0_primary_in" 2>/dev/null || true)" \
    "xcolo_premigrate_primary_filter_qom_comp0_secondary_in=$(ftctl_state_get "${vm}" "xcolo_primary_filter_qom_comp0_secondary_in" 2>/dev/null || true)" \
    "xcolo_premigrate_primary_filter_qom_comp0_outdev=$(ftctl_state_get "${vm}" "xcolo_primary_filter_qom_comp0_outdev" 2>/dev/null || true)"

  ftctl_log_event "colo" "primary.pre_migrate_evidence" "ok" "${vm}" "" \
    "x_colo=${cap_xcolo} return_path=${cap_return_path} checkpoint_delay=${checkpoint_delay} checkpoint_ready=$(ftctl_state_get "${vm}" "xcolo_primary_checkpoint_delay_ready" 2>/dev/null || true) checkpoint_expected=$(ftctl_state_get "${vm}" "xcolo_primary_checkpoint_delay_expected" 2>/dev/null || true) checkpoint_actual=$(ftctl_state_get "${vm}" "xcolo_primary_checkpoint_delay_actual" 2>/dev/null || true) vnet_hdr=$(ftctl_state_get "${vm}" "xcolo_net_vnet_hdr_support" 2>/dev/null || true) filter_status=${expected_filter_status} filter_qom=${filter_qom} filter_cmdline=${filter_cmdline} chardev=${chardev} mirror=${channel_mirror} compare=${channel_compare} compare_local=${channel_compare_local} compare_out=${channel_compare_out}"
}

ftctl_xcolo_primary_filter_qom_ready() {
  local vm="${1-}"
  [[ "$(ftctl_state_get "${vm}" "xcolo_primary_filter_qom_ready" 2>/dev/null || true)" == "yes" ]]
}

ftctl_xcolo_require_primary_filter_qom_ready() {
  local vm="${1-}"
  local phase="${2:-pre_migrate}"
  local expected_status="${3:-on}"
  local reason

  if ftctl_xcolo_collect_primary_filter_qom_state "${vm}" "${expected_status}"; then
    ftctl_log_event "colo" "primary.filter_qom_topology" "ok" "${vm}" "" \
      "phase=${phase} expected_status=${expected_status} m0=$(ftctl_state_get "${vm}" "xcolo_primary_filter_qom_m0_path" 2>/dev/null || true) redire0=$(ftctl_state_get "${vm}" "xcolo_primary_filter_qom_redire0_path" 2>/dev/null || true) redire1=$(ftctl_state_get "${vm}" "xcolo_primary_filter_qom_redire1_path" 2>/dev/null || true) comp0=$(ftctl_state_get "${vm}" "xcolo_primary_filter_qom_comp0_path" 2>/dev/null || true)"
    return 0
  fi

  reason="$(ftctl_state_get "${vm}" "xcolo_primary_filter_qom_reason" 2>/dev/null || true)"
  [[ -n "${reason}" ]] || reason="unknown"
  ftctl_state_set "${vm}" \
    "xcolo_primary_net_filters_attached=false" \
    "xcolo_primary_filter_qom_topology_failed_reason=${reason}" \
    "last_error=primary_filter_qom_topology_missing"
  ftctl_log_event "colo" "primary.filter_qom_topology" "fail" "${vm}" "" \
    "phase=${phase} expected_status=${expected_status} reason=${reason} m0=$(ftctl_state_get "${vm}" "xcolo_primary_filter_qom_m0_path" 2>/dev/null || true) redire0=$(ftctl_state_get "${vm}" "xcolo_primary_filter_qom_redire0_path" 2>/dev/null || true) redire1=$(ftctl_state_get "${vm}" "xcolo_primary_filter_qom_redire1_path" 2>/dev/null || true) comp0=$(ftctl_state_get "${vm}" "xcolo_primary_filter_qom_comp0_path" 2>/dev/null || true)"
  return 1
}

ftctl_xcolo_collect_primary_block_graph_state() {
  local vm="${1-}"
  local plan="${2-}"
  local out rc payload state_args=()

  out=""
  rc=0
  ftctl_xcolo_qmp "${FTCTL_PROFILE_PRIMARY_URI}" "${vm}" '{"execute":"query-named-block-nodes"}' out rc
  if [[ "${rc}" != "0" || -z "${out}" ]]; then
    ftctl_state_set "${vm}" \
      "xcolo_primary_block_graph_ready=unknown" \
      "xcolo_primary_block_graph_reason=query_named_block_nodes_failed"
    return 1
  fi

  payload="$(python3 - <<'PY' "${plan}" "${FTCTL_PROFILE_XCOLO_NBD_NODE:-ftctl-nbd}" "${out}"
import json
import re
import sys

plan = sys.argv[1]
nbd_base = sys.argv[2] or "ftctl-nbd"
raw = sys.argv[3]
targets = []
for entry in plan.split(";"):
    if not entry:
        continue
    target = entry.split("|", 1)[0]
    if target:
        targets.append(target)
if not targets:
    targets = ["root"]

def suffix(target):
    return re.sub(r"[^A-Za-z0-9_.-]", "_", target or "root")

try:
    data = json.loads(raw)
except Exception:
    print("ready=unknown")
    print("reason=query_named_block_nodes_parse_failed")
    raise SystemExit(0)

nodes = {item.get("node-name") for item in data.get("return", []) if item.get("node-name")}
ready = True
reasons = []
for target in targets:
    s = suffix(target)
    required = [f"ftctl-colo-{s}", f"ftctl-primary-active-{s}", f"{nbd_base}-{s}"]
    for node in required:
        key = re.sub(r"[^A-Za-z0-9_.-]", "_", node)
        if node in nodes:
            print(f"{key}=yes")
        else:
            ready = False
            reasons.append(f"{node}:missing")
            print(f"{key}=missing")

print(f"ready={'yes' if ready else 'no'}")
print("reason=" + (",".join(reasons) if reasons else ""))
PY
)" || payload="ready=unknown"$'\n'"reason=query_named_block_nodes_parse_failed"

  while IFS= read -r line; do
    [[ -n "${line}" ]] || continue
    case "${line}" in
      ready=*)
        state_args+=("xcolo_primary_block_graph_ready=${line#ready=}")
        ;;
      reason=*)
        state_args+=("xcolo_primary_block_graph_reason=${line#reason=}")
        ;;
      *=*)
        state_args+=("xcolo_primary_block_node_${line}")
        ;;
    esac
  done <<< "${payload}"
  ftctl_state_set "${vm}" "${state_args[@]}"
  [[ "$(ftctl_state_get "${vm}" "xcolo_primary_block_graph_ready" 2>/dev/null || true)" == "yes" ]]
}

ftctl_xcolo_collect_secondary_block_graph_state() {
  local vm="${1-}"
  local secondary_vm="${2:-$vm}"
  local plan="${3-}"
  local nodes_out nodes_rc block_out block_rc payload state_args=()

  if [[ -z "${plan}" ]]; then
    ftctl_state_set "${vm}" \
      "xcolo_secondary_block_graph_ready=not_applicable" \
      "xcolo_secondary_block_graph_reason=no_disk_plan"
    return 0
  fi

  nodes_out=""
  nodes_rc=0
  ftctl_xcolo_qmp "${FTCTL_PROFILE_SECONDARY_URI}" "${secondary_vm}" '{"execute":"query-named-block-nodes"}' nodes_out nodes_rc
  block_out=""
  block_rc=0
  ftctl_xcolo_qmp "${FTCTL_PROFILE_SECONDARY_URI}" "${secondary_vm}" '{"execute":"query-block"}' block_out block_rc
  if [[ "${nodes_rc}" != "0" || -z "${nodes_out}" || "${block_rc}" != "0" || -z "${block_out}" ]]; then
    ftctl_state_set "${vm}" \
      "xcolo_secondary_block_graph_ready=unknown" \
      "xcolo_secondary_block_graph_reason=query_block_graph_failed"
    return 1
  fi

  payload="$(python3 - <<'PY' "${plan}" "${nodes_out}" "${block_out}"
import json
import re
import sys

plan = sys.argv[1]
nodes_raw = sys.argv[2]
block_raw = sys.argv[3]
targets = []
for entry in plan.split(";"):
    if not entry:
        continue
    target = entry.split("|", 1)[0]
    if target:
        targets.append(target)

def suffix(target):
    return re.sub(r"[^A-Za-z0-9_.-]", "_", target or "root")

try:
    nodes_data = json.loads(nodes_raw)
    block_data = json.loads(block_raw)
except Exception:
    print("ready=unknown")
    print("reason=query_block_graph_parse_failed")
    raise SystemExit(0)

nodes = {item.get("node-name") for item in nodes_data.get("return", []) if item.get("node-name")}
qdev_nodes = {}
for item in block_data.get("return", []):
    inserted = item.get("inserted")
    node = inserted.get("node-name") if isinstance(inserted, dict) else ""
    qdev = item.get("qdev") or item.get("device") or ""
    if node:
        qdev_nodes[node] = qdev

ready = True
reasons = []
for target in targets:
    s = suffix(target)
    required_nodes = [
        f"ftctl-colo-{s}",
        f"ftctl-childs-{s}",
        f"ftctl-active-{s}",
        f"ftctl-hidden-{s}",
    ]
    for node in required_nodes:
        key = re.sub(r"[^A-Za-z0-9_.-]", "_", node)
        if node in nodes:
            print(f"{key}=yes")
        else:
            ready = False
            reasons.append(f"{node}:missing")
            print(f"{key}=missing")
    colo = f"ftctl-colo-{s}"
    qdev = qdev_nodes.get(colo, "")
    qkey = re.sub(r"[^A-Za-z0-9_.-]", "_", f"{colo}_qdev")
    if qdev:
        print(f"{qkey}={qdev}")
    else:
        ready = False
        reasons.append(f"{colo}:qdev_missing")
        print(f"{qkey}=missing")

print(f"ready={'yes' if ready else 'no'}")
print("reason=" + (",".join(reasons) if reasons else ""))
PY
)" || payload="ready=unknown"$'\n'"reason=query_block_graph_parse_failed"

  while IFS= read -r line; do
    [[ -n "${line}" ]] || continue
    case "${line}" in
      ready=*)
        state_args+=("xcolo_secondary_block_graph_ready=${line#ready=}")
        ;;
      reason=*)
        state_args+=("xcolo_secondary_block_graph_reason=${line#reason=}")
        ;;
      *=*)
        state_args+=("xcolo_secondary_block_graph_${line}")
        ;;
    esac
  done <<< "${payload}"

  ftctl_state_set "${vm}" "${state_args[@]}"
  [[ "$(ftctl_state_get "${vm}" "xcolo_secondary_block_graph_ready" 2>/dev/null || true)" == "yes" ]]
}

ftctl_xcolo_capture_qemu_cmdline_local() {
  local domain="${1-}"
  local out_var="${2}"
  local err_var="${3}"
  local rc_var="${4}"
  local out err rc

  out=""
  err=""
  rc=0
  # shellcheck disable=SC2016
  ftctl_cmd_run "${FTCTL_BLOCKCOPY_WAIT_TIMEOUT_SEC:-15}" out err rc -- \
    bash -c '
vm="$1"
for proc_cmd in /proc/[0-9]*/cmdline; do
  [[ -r "${proc_cmd}" ]] || continue
  cmdline="$(tr "\0" " " < "${proc_cmd}" 2>/dev/null || true)"
  [[ "${cmdline}" == *"${vm}"* ]] || continue
  [[ "${cmdline}" == *qemu* ]] || continue
  printf "%s\n" "${cmdline}"
done
' _ "${domain}" || true
  printf -v "${out_var}" '%s' "${out}"
  printf -v "${err_var}" '%s' "${err}"
  printf -v "${rc_var}" '%s' "${rc}"
}

ftctl_xcolo_capture_primary_qemu_cmdline() {
  local vm="${1-}"
  local out="" err="" rc=0

  ftctl_xcolo_capture_qemu_cmdline_local "${vm}" out err rc || true
  : "${err}${rc}"
  ftctl_xcolo_write_debug_file "${vm}" "primary-qemu-process-cmdline.txt" "${out}"
}

ftctl_xcolo_capture_secondary_qemu_cmdline() {
  local vm="${1-}"
  local secondary_vm="${2:-$vm}"
  local host="" user="" out="" err="" rc=0 remote_cmd="" q_secondary=""

  if ftctl_blockcopy_secondary_uri_is_local_system; then
    ftctl_xcolo_capture_qemu_cmdline_local "${secondary_vm}" out err rc || true
  elif ftctl_blockcopy_remote_target_host_user host user; then
    printf -v q_secondary '%q' "${secondary_vm}"
    remote_cmd="domain=${q_secondary}
for proc_cmd in /proc/[0-9]*/cmdline; do
  [[ -r \"\${proc_cmd}\" ]] || continue
  cmdline=\"\$(tr '\0' ' ' < \"\${proc_cmd}\" 2>/dev/null || true)\"
  [[ \"\${cmdline}\" == *\"\${domain}\"* ]] || continue
  [[ \"\${cmdline}\" == *qemu* ]] || continue
  printf '%s\n' \"\${cmdline}\"
done"
    ftctl_blockcopy_remote_exec "${host}" "${user}" out err rc "${remote_cmd}" || true
  else
    err="target_unresolved"
    rc=2
  fi

  : "${err}"
  ftctl_xcolo_write_debug_file "${vm}" "secondary-qemu-process-cmdline.txt" "${out}"
  ftctl_state_set "${vm}" \
    "xcolo_secondary_qemu_cmdline_rc=${rc}" \
    "xcolo_secondary_qemu_cmdline_captured=$([[ -n "${out}" ]] && printf yes || printf no)"
}

ftctl_xcolo_capture_qemu_log_tail_local() {
  local domain="${1-}"
  local out_var="${2}"
  local err_var="${3}"
  local rc_var="${4}"
  local out="" err="" rc=0

  # shellcheck disable=SC2016
  ftctl_cmd_run "${FTCTL_BLOCKCOPY_WAIT_TIMEOUT_SEC:-15}" out err rc -- \
    bash -c 'domain="$1"; tail -n 360 "/var/log/libvirt/qemu/${domain}.log" 2>/dev/null || true' _ "${domain}" || true
  printf -v "${out_var}" '%s' "${out}"
  printf -v "${err_var}" '%s' "${err}"
  printf -v "${rc_var}" '%s' "${rc}"
}

ftctl_xcolo_capture_qemu_log_tails() {
  local vm="${1-}"
  local secondary_vm="${2:-$vm}"
  local host="" user="" out="" err="" rc=0 remote_cmd="" q_secondary=""

  ftctl_xcolo_capture_qemu_log_tail_local "${vm}" out err rc || true
  : "${err}${rc}"
  ftctl_xcolo_write_debug_file "${vm}" "primary-qemu-log-tail.txt" "${out}"

  out=""
  err=""
  rc=0
  if ftctl_blockcopy_secondary_uri_is_local_system; then
    ftctl_xcolo_capture_qemu_log_tail_local "${secondary_vm}" out err rc || true
  elif ftctl_blockcopy_remote_target_host_user host user; then
    printf -v q_secondary '%q' "${secondary_vm}"
    remote_cmd="domain=${q_secondary}
tail -n 360 \"/var/log/libvirt/qemu/\${domain}.log\" 2>/dev/null || true"
    ftctl_blockcopy_remote_exec "${host}" "${user}" out err rc "${remote_cmd}" || true
  else
    err="target_unresolved"
    rc=2
  fi
  : "${err}"
  ftctl_xcolo_write_debug_file "${vm}" "secondary-qemu-log-tail.txt" "${out}"
  ftctl_state_set "${vm}" \
    "xcolo_qemu_log_tail_captured=yes" \
    "xcolo_secondary_qemu_log_tail_rc=${rc}"
}

ftctl_xcolo_primary_filter_mirror_send_errno() {
  local vm="${1-}"
  local out="" err="" rc=0

  [[ -n "${vm}" ]] || return 1
  # shellcheck disable=SC2016
  ftctl_cmd_run "${FTCTL_BLOCKCOPY_WAIT_TIMEOUT_SEC:-15}" out err rc -- \
    bash -c '
domain="$1"
line="$(tail -n 720 "/var/log/libvirt/qemu/${domain}.log" 2>/dev/null |
  grep -F "filter mirror send failed(" | tail -n 1 || true)"
if [[ -z "${line}" ]]; then
  exit 1
fi
reason="${line##*filter mirror send failed(}"
reason="${reason%%)*}"
case "${reason}" in
  "Operation not permitted") printf "%s\n" "eperm" ;;
  "Input/output error") printf "%s\n" "eio" ;;
  "") printf "%s\n" "unknown" ;;
  *) printf "%s\n" "${reason//[^A-Za-z0-9_.-]/_}" | tr "[:upper:]" "[:lower:]" ;;
esac
' _ "${vm}" || true
  : "${err}"
  [[ "${rc}" == "0" && -n "${out}" ]] || return 1
  printf '%s\n' "${out%%$'\n'*}"
}

ftctl_xcolo_chardev_label_state() {
  local payload="${1-}"
  local label="${2-}"
  local value

  value="$(python3 - "${payload}" "${label}" <<'PY'
import json
import sys

raw = sys.argv[1] if len(sys.argv) > 1 else ""
target = sys.argv[2] if len(sys.argv) > 2 else ""
try:
    data = json.loads(raw)
except Exception:
    print("unknown")
    raise SystemExit(0)
for item in data.get("return", []):
    if item.get("label") != target:
        continue
    opened = item.get("frontend-open")
    if opened is True:
        print("present_open")
    elif opened is False:
        print("present_closed")
    else:
        print("present_unknown")
    raise SystemExit(0)
print("missing")
PY
)" || value="unknown"
  printf '%s\n' "${value}"
}

ftctl_xcolo_capture_failure_chardev_snapshot() {
  local vm="${1-}"
  local secondary_vm="${2:-$vm}"
  local phase="${3:-post-migrate-failure}"
  local primary_out="" primary_rc=0 secondary_out="" secondary_rc=0

  [[ -n "${vm}" && -n "${secondary_vm}" ]] || return 0
  ftctl_xcolo_qmp "${FTCTL_PROFILE_PRIMARY_URI}" "${vm}" '{"execute":"query-chardev"}' primary_out primary_rc
  ftctl_xcolo_qmp "${FTCTL_PROFILE_SECONDARY_URI}" "${secondary_vm}" '{"execute":"query-chardev"}' secondary_out secondary_rc

  ftctl_xcolo_write_debug_file "${vm}" "primary-query-chardev-${phase}.json" "${primary_out}" || true
  ftctl_xcolo_write_debug_file "${vm}" "secondary-query-chardev-${phase}.json" "${secondary_out}" || true

  ftctl_state_set "${vm}" \
    "xcolo_failure_chardev_phase=${phase}" \
    "xcolo_failure_primary_chardev_rc=${primary_rc}" \
    "xcolo_failure_secondary_chardev_rc=${secondary_rc}" \
    "xcolo_failure_primary_chardev_mirror0=$(ftctl_xcolo_chardev_label_state "${primary_out}" "mirror0")" \
    "xcolo_failure_primary_chardev_compare1=$(ftctl_xcolo_chardev_label_state "${primary_out}" "compare1")" \
    "xcolo_failure_primary_chardev_compare0=$(ftctl_xcolo_chardev_label_state "${primary_out}" "compare0")" \
    "xcolo_failure_primary_chardev_compare_out=$(ftctl_xcolo_chardev_label_state "${primary_out}" "compare_out")" \
    "xcolo_failure_secondary_chardev_red0=$(ftctl_xcolo_chardev_label_state "${secondary_out}" "red0")" \
    "xcolo_failure_secondary_chardev_red1=$(ftctl_xcolo_chardev_label_state "${secondary_out}" "red1")"
}

ftctl_xcolo_policy_snapshot_cmd() {
  cat <<'EOF'
set -euo pipefail
echo "== time =="; date -Is; date -u -Is
echo "== selinux =="; getenforce 2>/dev/null || true
echo "== firewalld =="; systemctl is-active firewalld 2>/dev/null || true; firewall-cmd --state 2>/dev/null || true; firewall-cmd --list-ports 2>/dev/null || true
echo "== nft ft ports =="; nft list ruleset 2>/dev/null | grep -En '9000|9001|9003|9004|9005|9998|10809|reject|drop|deny' | head -220 || true
echo "== iptables ft ports =="; iptables-save 2>/dev/null | grep -En '9000|9001|9003|9004|9005|9998|10809|REJECT|DROP' | head -220 || true
echo "== audit denied tail =="; grep -Ei 'avc:|type=AVC|denied|qemu|svirt|virt|9003|9004|9998' /var/log/audit/audit.log 2>/dev/null | tail -160 || true
EOF
}

ftctl_xcolo_capture_policy_snapshot() {
  local vm="${1-}"
  local phase="${2:-post-migrate-failure}"
  local host="" user="" cmd="" out="" err="" rc=0

  [[ -n "${vm}" ]] || return 0
  cmd="$(ftctl_xcolo_policy_snapshot_cmd)"
  ftctl_cmd_run "${FTCTL_BLOCKCOPY_WAIT_TIMEOUT_SEC:-15}" out err rc -- bash -lc "${cmd}" || true
  : "${err}"
  ftctl_xcolo_write_debug_file "${vm}" "primary-policy-${phase}.txt" "${out}" || true

  out=""
  err=""
  rc=0
  if ftctl_blockcopy_remote_target_host_user host user; then
    ftctl_blockcopy_remote_exec "${host}" "${user}" out err rc "${cmd}" || true
  else
    out="target_unresolved"
    rc=2
  fi
  : "${err}"
  ftctl_xcolo_write_debug_file "${vm}" "secondary-policy-${phase}.txt" "${out}" || true
  ftctl_state_set "${vm}" \
    "xcolo_policy_snapshot_phase=${phase}" \
    "xcolo_policy_snapshot_captured=yes" \
    "xcolo_policy_snapshot_secondary_rc=${rc}"
}

ftctl_xcolo_classify_startup_active_stream_failure() {
  local vm="${1-}"
  local secondary_vm="${2:-$vm}"
  local errno="" reason="qemu_return_path_invalid_zero_header"
  local last_error="xcolo_startup_active_filter_stream_failed"

  [[ -n "${vm}" && -n "${secondary_vm}" ]] || return 0
  ftctl_xcolo_collect_runtime_failure_diagnostics "${vm}" "${secondary_vm}" || true
  ftctl_xcolo_capture_socket_snapshot "${vm}" "post_migrate_failure" || true
  ftctl_xcolo_capture_failure_chardev_snapshot "${vm}" "${secondary_vm}" "post-migrate-failure" || true
  ftctl_xcolo_capture_policy_snapshot "${vm}" "post-migrate-failure" || true

  if errno="$(ftctl_xcolo_primary_filter_mirror_send_errno "${vm}")"; then
    reason="filter_mirror_send_failed"
    last_error="xcolo_filter_mirror_send_failed"
    if [[ "${errno}" == "eperm" ]]; then
      reason="filter_mirror_send_eperm"
      last_error="xcolo_filter_mirror_send_eperm"
    fi
    ftctl_state_set "${vm}" \
      "xcolo_filter_mirror_send_failed=yes" \
      "xcolo_filter_mirror_send_errno=${errno}" \
      "xcolo_filter_mirror_send_path=primary:m0->mirror0->secondary:red0"
  fi

  ftctl_state_set "${vm}" \
    "xcolo_repeated_protocol_invalid_message=yes" \
    "xcolo_protocol_invalid_message_reason=${reason}" \
    "xcolo_protocol_invalid_message_scope=post_migrate_startup_active_filter" \
    "xcolo_protocol_failure_phase=post_migrate_startup_active_filter" \
    "xcolo_protocol_steady_state_required=true" \
    "xcolo_protocol_expected_primary_role=primary" \
    "xcolo_protocol_expected_secondary_role=secondary" \
    "last_error=${last_error}"

  ftctl_log_event "colo" "xcolo.startup_active_stream_failure" "fail" "${vm}" "" \
    "reason=${reason} errno=${errno:-none} path=primary:m0->mirror0->secondary:red0"
}

ftctl_xcolo_collect_primary_netdev_vhost_state() {
  local vm="${1-}"
  local out err rc expected_netdev state reason_text

  out=""
  err=""
  rc=0
  # shellcheck disable=SC2016
  ftctl_cmd_run "${FTCTL_BLOCKCOPY_WAIT_TIMEOUT_SEC:-15}" out err rc -- \
    bash -c '
vm="$1"
expected_netdev="$2"
for proc_cmd in /proc/[0-9]*/cmdline; do
  [[ -r "${proc_cmd}" ]] || continue
  cmdline="$(tr "\0" " " < "${proc_cmd}" 2>/dev/null || true)"
  [[ "${cmdline}" == *"${vm}"* ]] || continue
  [[ "${cmdline}" == *qemu* ]] || continue
  if [[ -z "${expected_netdev}" || "${cmdline}" == *"${expected_netdev}"* ]]; then
    printf "%s\n" "${cmdline}"
    exit 0
  fi
  fallback="${cmdline}"
done
if [[ -n "${fallback:-}" ]]; then
  printf "%s\n" "${fallback}"
fi
' _ "${vm}" "$(ftctl_state_get "${vm}" "xcolo_primary_netdev_id" 2>/dev/null || true)" || true
  : "${err}${rc}"

  expected_netdev="$(ftctl_state_get "${vm}" "xcolo_primary_netdev_id" 2>/dev/null || true)"
  expected_netdev="${expected_netdev:-hostnet0}"
  if [[ -z "${out}" ]]; then
    state="unknown"
    reason_text="primary_qemu_process_not_found"
  elif [[ "${out}" == *"vhostfd"* ||
          "${out}" == *'"vhost":true'* ||
          "${out}" == *"vhost=on"* ||
          "${out}" == *"vhost=true"* ]]; then
    state="on"
    reason_text="vhost_marker_present"
  else
    state="off"
    reason_text=""
  fi

  ftctl_xcolo_write_debug_file "${vm}" "primary-qemu-netdev-vhost-cmdline.txt" "${out}" || true
  ftctl_state_set "${vm}" \
    "xcolo_primary_netdev_vhost=${state}" \
    "xcolo_primary_netdev_vhost_expected_netdev=${expected_netdev}" \
    "xcolo_primary_netdev_vhost_reason=${reason_text}"
  ftctl_log_event "colo" "primary.netdev.vhost" "ok" "${vm}" "" \
    "state=${state} expected_netdev=${expected_netdev} reason=${reason_text:-none}"
  [[ "${state}" == "off" ]]
}

ftctl_xcolo_require_primary_netdev_vhost_off() {
  local vm="${1-}"
  local state reason_text

  ftctl_xcolo_collect_primary_netdev_vhost_state "${vm}" || true
  state="$(ftctl_state_get "${vm}" "xcolo_primary_netdev_vhost" 2>/dev/null || true)"
  reason_text="$(ftctl_state_get "${vm}" "xcolo_primary_netdev_vhost_reason" 2>/dev/null || true)"
  case "${state}" in
    off)
      return 0
      ;;
    on)
      ftctl_state_set "${vm}" \
        "conversion_stage=primary_vhost_guard_failed" \
        "conversion_state=error" \
        "protection_state=error" \
        "transport_state=failed" \
        "last_error=primary_netdev_vhost_enabled"
      ftctl_log_event "colo" "primary.netdev.vhost_guard" "fail" "${vm}" "" \
        "state=${state} reason=${reason_text:-vhost_marker_present}"
      return 1
      ;;
    *)
      ftctl_state_set "${vm}" \
        "conversion_stage=primary_vhost_guard_failed" \
        "conversion_state=error" \
        "protection_state=error" \
        "transport_state=failed" \
        "last_error=primary_netdev_vhost_unknown"
      ftctl_log_event "colo" "primary.netdev.vhost_guard" "fail" "${vm}" "" \
        "state=${state:-unknown} reason=${reason_text:-unknown}"
      return 1
      ;;
  esac
}

ftctl_xcolo_collect_primary_filter_cmdline_state() {
  local vm="${1-}"
  local out err rc ready reason_text expected_netdev
  local -a reasons=()

  out=""
  err=""
  rc=0
  # shellcheck disable=SC2016
  ftctl_cmd_run "${FTCTL_BLOCKCOPY_WAIT_TIMEOUT_SEC:-15}" out err rc -- \
    bash -c '
vm="$1"
for proc_cmd in /proc/[0-9]*/cmdline; do
  [[ -r "${proc_cmd}" ]] || continue
  cmdline="$(tr "\0" " " < "${proc_cmd}" 2>/dev/null || true)"
  [[ "${cmdline}" == *"${vm}"* ]] || continue
  [[ "${cmdline}" == *qemu* ]] || continue
  printf "%s\n" "${cmdline}"
done
' _ "${vm}" || true
  : "${err}${rc}"

  if [[ -z "${out}" ]]; then
    ftctl_state_set "${vm}" \
      "xcolo_primary_filter_cmdline_ready=unknown" \
      "xcolo_primary_filter_cmdline_reason=primary_qemu_process_not_found"
    return 1
  fi

  expected_netdev="$(ftctl_state_get "${vm}" "xcolo_primary_netdev_id" 2>/dev/null || true)"
  expected_netdev="${expected_netdev:-hostnet0}"
  ftctl_xcolo_update_vnet_hdr_state "${vm}" || true
  ready="yes"
  _ftctl_xcolo_expect_cmdline_token() {
    local token="${1-}"
    local key="${2-}"
    if [[ "${out}" != *"${token}"* ]]; then
      ready="no"
      reasons+=("${key}:missing")
    fi
  }

  _ftctl_xcolo_expect_cmdline_token "filter-mirror,id=m0" "m0"
  _ftctl_xcolo_expect_cmdline_token "filter-redirector,id=redire0" "redire0"
  _ftctl_xcolo_expect_cmdline_token "filter-redirector,id=redire1" "redire1"
  _ftctl_xcolo_expect_cmdline_token "colo-compare,id=comp0" "comp0"
  _ftctl_xcolo_expect_cmdline_token "netdev=${expected_netdev}" "primary_netdev"
  if [[ "${out}" == *"status=off"* ]]; then
    ready="no"
    reasons+=("startup_status_off:present")
  fi
  _ftctl_xcolo_expect_cmdline_token "outdev=mirror0" "mirror0"
  _ftctl_xcolo_expect_cmdline_token "indev=compare_out" "compare_out_in"
  _ftctl_xcolo_expect_cmdline_token "outdev=compare0" "compare0_out"
  _ftctl_xcolo_expect_cmdline_token "primary_in=compare0-0" "compare0_primary_in"
  _ftctl_xcolo_expect_cmdline_token "secondary_in=compare1" "compare1_secondary_in"
  _ftctl_xcolo_expect_cmdline_token "outdev=compare_out0" "compare_out0"
  if [[ "$(ftctl_state_get "${vm}" "xcolo_net_vnet_hdr_support" 2>/dev/null || true)" == "on" ]]; then
    _ftctl_xcolo_expect_cmdline_token "vnet_hdr_support" "vnet_hdr_support"
  fi

  reason_text="$(IFS=,; printf '%s' "${reasons[*]}")"
  if [[ "${reason_text}" == *"vnet_hdr_support:missing"* ]]; then
    ftctl_state_set "${vm}" "last_error=xcolo_vnet_hdr_support_missing"
  fi
  ftctl_state_set "${vm}" \
    "xcolo_primary_filter_cmdline_ready=${ready}" \
    "xcolo_primary_filter_cmdline_expected_netdev=${expected_netdev}" \
    "xcolo_primary_filter_cmdline_reason=${reason_text}" \
    "xcolo_primary_filter_cmdline_vnet_hdr_required=$(ftctl_state_get "${vm}" "xcolo_net_vnet_hdr_support" 2>/dev/null || true)"
  [[ "${ready}" == "yes" ]]
}

ftctl_xcolo_require_primary_filter_cmdline_ready() {
  local vm="${1-}"
  local phase="${2:-pre_migrate}"
  local reason_text

  if ftctl_xcolo_collect_primary_filter_cmdline_state "${vm}"; then
    ftctl_log_event "colo" "primary.filter_cmdline_topology" "ok" "${vm}" "" \
      "phase=${phase} expected_netdev=$(ftctl_state_get "${vm}" "xcolo_primary_filter_cmdline_expected_netdev" 2>/dev/null || true)"
    return 0
  fi

  reason_text="$(ftctl_state_get "${vm}" "xcolo_primary_filter_cmdline_reason" 2>/dev/null || true)"
  [[ -n "${reason_text}" ]] || reason_text="unknown"
  ftctl_state_set "${vm}" \
    "xcolo_primary_net_filters_attached=false" \
    "xcolo_primary_filter_cmdline_topology_failed_reason=${reason_text}"
  if [[ "${reason_text}" == *"vnet_hdr_support:missing"* ]]; then
    ftctl_state_set "${vm}" "last_error=xcolo_vnet_hdr_support_missing"
  else
    ftctl_state_set "${vm}" "last_error=primary_filter_cmdline_topology_missing"
  fi
  ftctl_log_event "colo" "primary.filter_cmdline_topology" "fail" "${vm}" "" \
    "phase=${phase} reason=${reason_text}"
  return 1
}

ftctl_xcolo_collect_secondary_filter_cmdline_state() {
  local vm="${1-}"
  local secondary_vm="${2:-$vm}"
  local out="" ready="yes" reason_text="" expected_netdev
  local -a reasons=()

  ftctl_xcolo_capture_secondary_qemu_cmdline "${vm}" "${secondary_vm}" || true
  out="$(ftctl_xcolo_debug_dir "${vm}")/secondary-qemu-process-cmdline.txt"
  if [[ -f "${out}" ]]; then
    out="$(cat "${out}" 2>/dev/null || true)"
  else
    out=""
  fi

  if [[ -z "${out}" ]]; then
    ftctl_state_set "${vm}" \
      "xcolo_secondary_filter_cmdline_ready=unknown" \
      "xcolo_secondary_filter_cmdline_reason=secondary_qemu_process_not_found"
    return 1
  fi

  expected_netdev="$(ftctl_state_get "${vm}" "xcolo_secondary_netdev_id" 2>/dev/null || true)"
  expected_netdev="${expected_netdev:-hostnet0}"

  _ftctl_xcolo_expect_secondary_cmdline_token() {
    local token="${1-}"
    local key="${2-}"
    if [[ "${out}" != *"${token}"* ]]; then
      ready="no"
      reasons+=("${key}:missing")
    fi
  }

  _ftctl_xcolo_expect_secondary_cmdline_token "socket,id=red0" "red0"
  _ftctl_xcolo_expect_secondary_cmdline_token "socket,id=red1" "red1"
  _ftctl_xcolo_expect_secondary_cmdline_token "filter-redirector,id=f1" "f1"
  _ftctl_xcolo_expect_secondary_cmdline_token "filter-redirector,id=f2" "f2"
  _ftctl_xcolo_expect_secondary_cmdline_token "filter-rewriter,id=rew0" "rew0"
  _ftctl_xcolo_expect_secondary_cmdline_token "netdev=${expected_netdev}" "secondary_netdev"
  _ftctl_xcolo_expect_secondary_cmdline_token "queue=tx" "f1_tx"
  _ftctl_xcolo_expect_secondary_cmdline_token "indev=red0" "f1_indev"
  _ftctl_xcolo_expect_secondary_cmdline_token "queue=rx" "f2_rx"
  _ftctl_xcolo_expect_secondary_cmdline_token "outdev=red1" "f2_outdev"
  _ftctl_xcolo_expect_secondary_cmdline_token "queue=all" "rew0_all"
  _ftctl_xcolo_expect_secondary_cmdline_token "-incoming" "incoming"
  if [[ "$(ftctl_state_get "${vm}" "xcolo_net_vnet_hdr_support" 2>/dev/null || true)" == "on" ]]; then
    _ftctl_xcolo_expect_secondary_cmdline_token "vnet_hdr_support" "vnet_hdr_support"
  fi

  reason_text="$(IFS=,; printf '%s' "${reasons[*]}")"
  ftctl_state_set "${vm}" \
    "xcolo_secondary_filter_cmdline_ready=${ready}" \
    "xcolo_secondary_filter_cmdline_expected_netdev=${expected_netdev}" \
    "xcolo_secondary_filter_cmdline_reason=${reason_text}" \
    "xcolo_secondary_filter_cmdline_vnet_hdr_required=$(ftctl_state_get "${vm}" "xcolo_net_vnet_hdr_support" 2>/dev/null || true)"
  [[ "${ready}" == "yes" ]]
}

ftctl_xcolo_require_topology_audit_ready() {
  local vm="${1-}"
  local secondary_vm="${2:-$vm}"
  local phase="${3:-pre_migrate}"
  local primary_qom primary_qom_reason primary_cmd primary_cmd_reason
  local secondary_cmd secondary_cmd_reason reason_text
  local -a reasons=()

  ftctl_xcolo_collect_primary_filter_qom_state "${vm}" "on" || true
  ftctl_xcolo_collect_primary_filter_cmdline_state "${vm}" || true
  ftctl_xcolo_collect_secondary_filter_cmdline_state "${vm}" "${secondary_vm}" || true
  ftctl_xcolo_capture_qemu_log_tails "${vm}" "${secondary_vm}" || true

  primary_qom="$(ftctl_state_get "${vm}" "xcolo_primary_filter_qom_ready" 2>/dev/null || true)"
  primary_qom_reason="$(ftctl_state_get "${vm}" "xcolo_primary_filter_qom_reason" 2>/dev/null || true)"
  primary_cmd="$(ftctl_state_get "${vm}" "xcolo_primary_filter_cmdline_ready" 2>/dev/null || true)"
  primary_cmd_reason="$(ftctl_state_get "${vm}" "xcolo_primary_filter_cmdline_reason" 2>/dev/null || true)"
  secondary_cmd="$(ftctl_state_get "${vm}" "xcolo_secondary_filter_cmdline_ready" 2>/dev/null || true)"
  secondary_cmd_reason="$(ftctl_state_get "${vm}" "xcolo_secondary_filter_cmdline_reason" 2>/dev/null || true)"

  if [[ "${primary_qom}" != "yes" && "${primary_cmd}" != "yes" ]]; then
    reasons+=("primary:${primary_qom_reason:-${primary_cmd_reason:-unknown}}")
  fi
  if [[ "${secondary_cmd}" != "yes" ]]; then
    reasons+=("secondary:${secondary_cmd_reason:-unknown}")
  fi

  reason_text="$(IFS=,; printf '%s' "${reasons[*]}")"
  if [[ "${#reasons[@]}" -eq 0 ]]; then
    ftctl_state_set "${vm}" \
      "xcolo_topology_audit=ok" \
      "xcolo_topology_audit_phase=${phase}" \
      "xcolo_topology_audit_reason=" \
      "xcolo_topology_primary_ready=yes" \
      "xcolo_topology_secondary_ready=yes"
    ftctl_log_event "colo" "xcolo.topology_audit" "ok" "${vm}" "" \
      "phase=${phase} primary_qom=${primary_qom} primary_cmdline=${primary_cmd} secondary_cmdline=${secondary_cmd}"
    return 0
  fi

  ftctl_state_set "${vm}" \
    "xcolo_topology_audit=failed" \
    "xcolo_topology_audit_phase=${phase}" \
    "xcolo_topology_audit_reason=${reason_text}" \
    "xcolo_topology_primary_ready=$([[ "${primary_qom}" == "yes" || "${primary_cmd}" == "yes" ]] && printf yes || printf no)" \
    "xcolo_topology_secondary_ready=$([[ "${secondary_cmd}" == "yes" ]] && printf yes || printf no)" \
    "last_error=xcolo_topology_audit_failed"
  ftctl_log_event "colo" "xcolo.topology_audit" "fail" "${vm}" "" \
    "phase=${phase} reason=${reason_text}"
  return 1
}

ftctl_xcolo_collect_runtime_failure_diagnostics() {
  local vm="${1-}"
  local secondary_vm="${2:-$vm}"
  local debug_dir cap_xcolo cap_return_path checkpoint_delay

  [[ "${FTCTL_DRY_RUN}" != "1" ]] || return 0

  debug_dir="$(ftctl_xcolo_debug_dir "${vm}")"
  ftctl_state_set "${vm}" "xcolo_debug_dir=${debug_dir}"

  ftctl_xcolo_qmp_debug_snapshot_one "${vm}" "${FTCTL_PROFILE_PRIMARY_URI}" "${vm}" "primary" || true
  ftctl_xcolo_qmp_debug_snapshot_one "${vm}" "${FTCTL_PROFILE_SECONDARY_URI}" "${secondary_vm}" "secondary" || true
  ftctl_xcolo_capture_primary_qemu_cmdline "${vm}" || true
  ftctl_xcolo_capture_secondary_qemu_cmdline "${vm}" "${secondary_vm}" || true
  ftctl_xcolo_capture_qemu_log_tails "${vm}" "${secondary_vm}" || true
  ftctl_xcolo_collect_primary_netdev_vhost_state "${vm}" || true
  ftctl_xcolo_collect_primary_filter_cmdline_state "${vm}" || true
  ftctl_xcolo_collect_secondary_filter_cmdline_state "${vm}" "${secondary_vm}" || true
  ftctl_xcolo_collect_primary_chardev_binding_state "${vm}" || true
  ftctl_xcolo_collect_primary_filter_qom_state "${vm}" || true
  ftctl_xcolo_collect_primary_block_graph_state "${vm}" "$(ftctl_state_get "${vm}" "xcolo_disk_plan" 2>/dev/null || true)" || true

  cap_xcolo="$(ftctl_xcolo_query_primary_qmp_diag_value "${vm}" "query-migrate-capabilities" "cap:x-colo")"
  cap_return_path="$(ftctl_xcolo_query_primary_qmp_diag_value "${vm}" "query-migrate-capabilities" "cap:return-path")"
  checkpoint_delay="$(ftctl_xcolo_query_primary_qmp_diag_value "${vm}" "query-migrate-parameters" "param:x-checkpoint-delay")"
  ftctl_state_set "${vm}" \
    "xcolo_primary_capability_x_colo=${cap_xcolo}" \
    "xcolo_primary_capability_return_path=${cap_return_path}" \
    "xcolo_primary_checkpoint_delay_set=${checkpoint_delay}"
  ftctl_log_event "colo" "xcolo.runtime_diagnostics" "ok" "${vm}" "" \
    "debug_dir=${debug_dir} x_colo=${cap_xcolo} return_path=${cap_return_path} checkpoint_delay=${checkpoint_delay}"
}

ftctl_xcolo_refine_primary_role_failure_reason() {
  local vm="${1-}"
  local reason="${2-}"
  local cap_xcolo cap_return_path checkpoint_delay filters_attached filter_qom_ready filter_cmdline_ready
  local netdev_ready filter_qom_reason filter_cmdline_reason
  local primary_status secondary_status primary_colo secondary_colo primary_migrate secondary_migrate
  local channel_mirror channel_compare channel_compare_local channel_compare_out disk_plan secondary_block_graph

  [[ "${reason}" == "primary_colo_role_not_entered" ]] || {
    printf '%s\n' "${reason}"
    return 0
  }

  cap_xcolo="$(ftctl_state_get "${vm}" "xcolo_primary_capability_x_colo" 2>/dev/null || true)"
  cap_return_path="$(ftctl_state_get "${vm}" "xcolo_primary_capability_return_path" 2>/dev/null || true)"
  checkpoint_delay="$(ftctl_state_get "${vm}" "xcolo_primary_checkpoint_delay_set" 2>/dev/null || true)"
  filters_attached="$(ftctl_state_get "${vm}" "xcolo_primary_net_filters_attached" 2>/dev/null || true)"
  filter_qom_ready="$(ftctl_state_get "${vm}" "xcolo_primary_filter_qom_ready" 2>/dev/null || true)"
  filter_cmdline_ready="$(ftctl_state_get "${vm}" "xcolo_primary_filter_cmdline_ready" 2>/dev/null || true)"
  netdev_ready="$(ftctl_state_get "${vm}" "xcolo_primary_netdev_ready" 2>/dev/null || true)"
  filter_qom_reason="$(ftctl_state_get "${vm}" "xcolo_primary_filter_qom_reason" 2>/dev/null || true)"
  filter_cmdline_reason="$(ftctl_state_get "${vm}" "xcolo_primary_filter_cmdline_reason" 2>/dev/null || true)"
  primary_status="$(ftctl_state_get "${vm}" "xcolo_primary_status" 2>/dev/null || true)"
  secondary_status="$(ftctl_state_get "${vm}" "xcolo_secondary_status" 2>/dev/null || true)"
  primary_colo="$(ftctl_state_get "${vm}" "xcolo_primary_colo_mode" 2>/dev/null || true)"
  secondary_colo="$(ftctl_state_get "${vm}" "xcolo_secondary_colo_mode" 2>/dev/null || true)"
  primary_migrate="$(ftctl_state_get "${vm}" "xcolo_primary_migrate_status" 2>/dev/null || true)"
  secondary_migrate="$(ftctl_state_get "${vm}" "xcolo_secondary_migrate_status" 2>/dev/null || true)"
  channel_mirror="$(ftctl_state_get "${vm}" "xcolo_channel_mirror_established" 2>/dev/null || true)"
  channel_compare="$(ftctl_state_get "${vm}" "xcolo_channel_compare_established" 2>/dev/null || true)"
  channel_compare_local="$(ftctl_state_get "${vm}" "xcolo_channel_compare_local_established" 2>/dev/null || true)"
  channel_compare_out="$(ftctl_state_get "${vm}" "xcolo_channel_compare_out_established" 2>/dev/null || true)"
  disk_plan="$(ftctl_state_get "${vm}" "xcolo_disk_plan" 2>/dev/null || true)"
  secondary_block_graph="$(ftctl_state_get "${vm}" "xcolo_secondary_block_graph_ready" 2>/dev/null || true)"

  if [[ "${cap_xcolo}" == "no" ]]; then
    printf '%s\n' "primary_colo_capability_missing"
  elif [[ "${cap_return_path}" == "no" ]]; then
    printf '%s\n' "primary_return_path_capability_missing"
  elif [[ "${checkpoint_delay}" == "no" ]]; then
    printf '%s\n' "primary_checkpoint_parameter_missing"
  elif [[ "${netdev_ready}" == "no" ]]; then
    printf '%s\n' "primary_filter_netdev_id_unresolved"
  elif [[ "${filter_cmdline_reason}" == *"primary_netdev:missing"* ||
          "${filter_qom_reason}" == *"_netdev:"* ]]; then
    printf '%s\n' "primary_filter_netdev_not_found"
  elif [[ "${filters_attached}" != "true" && "${filter_cmdline_ready}" != "yes" ]]; then
    printf '%s\n' "primary_colo_filter_objects_not_attached"
  elif [[ "${primary_status}" == "finish-migrate" &&
          "${secondary_status}" == "inmigrate" &&
          "${primary_migrate}" == "active" &&
          "${secondary_migrate}" == "colo" &&
          "${primary_colo}" != "primary" &&
          "${secondary_colo}" == "secondary" ]] &&
        ftctl_xcolo_runtime_primary_topology_ready "ok" "${filter_qom_ready}" "${filter_cmdline_ready}" \
          "${channel_mirror}" "${channel_compare}" "${channel_compare_local}" "${channel_compare_out}" \
          "${disk_plan}" "${secondary_block_graph}"; then
    printf '%s\n' "primary_finish_migrate_colo_role_not_entered"
  elif [[ "$(ftctl_state_get "${vm}" "xcolo_primary_filter_chardev_ready" 2>/dev/null || true)" == "no" ]]; then
    printf '%s\n' "primary_filter_chardev_frontend_incomplete"
  elif [[ "${filter_qom_ready}" == "no" && "${filter_cmdline_ready}" != "yes" ]]; then
    printf '%s\n' "primary_colo_filter_qom_incomplete"
  elif [[ "$(ftctl_state_get "${vm}" "xcolo_primary_block_graph_ready" 2>/dev/null || true)" == "no" ]]; then
    printf '%s\n' "primary_block_graph_incomplete"
  else
    printf '%s\n' "primary_qemu_colo_role_transition_failed"
  fi
}

ftctl_xcolo_primary_log_has_filter_mirror_send_failure() {
  local vm="${1-}"
  local out="" err="" rc=0

  [[ -n "${vm}" ]] || return 1
  # shellcheck disable=SC2016
  ftctl_cmd_run "${FTCTL_BLOCKCOPY_WAIT_TIMEOUT_SEC:-15}" out err rc -- \
    bash -c 'tail -n 240 "/var/log/libvirt/qemu/${1}.log" 2>/dev/null | grep -Fq "filter mirror send failed"' _ "${vm}" || true
  : "${out}${err}"
  [[ "${rc}" == "0" ]]
}

ftctl_xcolo_domain_xml_has_runtime_markers() {
  local uri="${1-}"
  local vm="${2-}"
  local role="${3-}"
  local out="" err="" rc=0

  ftctl_virsh "${FTCTL_BLOCKCOPY_WAIT_TIMEOUT_SEC}" out err rc -- -c "${uri}" dumpxml --security-info "${vm}" || true
  : "${err}"
  [[ "${rc}" == "0" && -n "${out}" ]] || return 1

  case "${role}" in
    primary)
      [[ "${out}" == *"qemu:commandline"* &&
         "${out}" == *"socket,id=mirror0"* &&
         "${out}" == *"socket,id=compare1"* &&
         "${out}" == *"socket,id=compare_out"* &&
         "${out}" == *"filter-mirror,id=m0"* &&
         "${out}" == *"filter-redirector,id=redire0"* &&
         "${out}" == *"filter-redirector,id=redire1"* &&
         "${out}" == *"colo-compare,id=comp0"* ]]
      ;;
    secondary)
      [[ "${out}" == *"qemu:commandline"* &&
         "${out}" == *"filter-redirector"* &&
         "${out}" == *"filter-rewriter"* &&
         "${out}" == *"-incoming"* ]]
      ;;
    *)
      return 2
      ;;
  esac
}

ftctl_xcolo_domain_xml_has_primary_chardev_markers() {
  local uri="${1-}"
  local vm="${2-}"
  local out="" err="" rc=0

  ftctl_virsh "${FTCTL_BLOCKCOPY_WAIT_TIMEOUT_SEC}" out err rc -- -c "${uri}" dumpxml --security-info "${vm}" || true
  : "${err}"
  [[ "${rc}" == "0" && -n "${out}" ]] || return 1

  [[ "${out}" == *"qemu:commandline"* &&
     "${out}" == *"socket,id=mirror0"* &&
     "${out}" == *"socket,id=compare1"* &&
     "${out}" == *"socket,id=compare0"* &&
     "${out}" == *"socket,id=compare0-0"* &&
     "${out}" == *"socket,id=compare_out"* &&
     "${out}" == *"socket,id=compare_out0"* ]]
}

ftctl_xcolo_runtime_primary_topology_ready() {
  local primary_xml="${1-}"
  local primary_filter_qom="${2-}"
  local primary_filter_cmdline="${3-}"
  local channel_mirror="${4-}"
  local channel_compare="${5-}"
  local channel_compare_local="${6-}"
  local channel_compare_out="${7-}"
  local disk_plan="${8-}"
  local secondary_block_graph="${9-}"

  [[ ( "${primary_filter_cmdline}" == "yes" ||
        "${primary_filter_qom}" == "yes" ||
        ( "${primary_xml}" == "ok" &&
          "${primary_filter_cmdline}" != "no" &&
          "${primary_filter_qom}" != "no" ) ) &&
     "${channel_mirror}" == "yes" &&
     "${channel_compare}" == "yes" &&
     "${channel_compare_local}" == "yes" &&
     "${channel_compare_out}" == "yes" &&
     ( -z "${disk_plan}" || "${secondary_block_graph}" == "yes" || "${secondary_block_graph}" == "not_applicable" ) ]]
}

ftctl_xcolo_repeated_invalid_message_evidence_ready() {
  local vm="${1-}"
  local primary_filter_qom="${2-}"
  local primary_filter_cmdline="${3-}"
  local channel_mirror="${4-}"
  local channel_compare="${5-}"
  local channel_compare_local="${6-}"
  local channel_compare_out="${7-}"
  local secondary_block_graph="${8-}"
  local pre_chardev pre_filter_qom pre_filter_cmdline
  local pre_mirror pre_compare pre_compare_local pre_compare_out
  local firewall_ready runtime_socket_captured storage_symmetry

  [[ -n "${vm}" ]] || return 1
  pre_chardev="$(ftctl_state_get "${vm}" "xcolo_premigrate_primary_filter_chardev_ready" 2>/dev/null || true)"
  pre_filter_qom="$(ftctl_state_get "${vm}" "xcolo_premigrate_primary_filter_qom_ready" 2>/dev/null || true)"
  pre_filter_cmdline="$(ftctl_state_get "${vm}" "xcolo_premigrate_primary_filter_cmdline_ready" 2>/dev/null || true)"
  pre_mirror="$(ftctl_state_get "${vm}" "xcolo_premigrate_channel_mirror_established" 2>/dev/null || true)"
  pre_compare="$(ftctl_state_get "${vm}" "xcolo_premigrate_channel_compare_established" 2>/dev/null || true)"
  pre_compare_local="$(ftctl_state_get "${vm}" "xcolo_premigrate_channel_compare_local_established" 2>/dev/null || true)"
  pre_compare_out="$(ftctl_state_get "${vm}" "xcolo_premigrate_channel_compare_out_established" 2>/dev/null || true)"
  firewall_ready="$(ftctl_state_get "${vm}" "xcolo_firewall_ready" 2>/dev/null || true)"
  runtime_socket_captured="$(ftctl_state_get "${vm}" "xcolo_socket_runtime_captured" 2>/dev/null || true)"
  storage_symmetry="$(ftctl_state_get "${vm}" "xcolo_storage_symmetry" 2>/dev/null || true)"

  [[ "${pre_chardev}" == "yes" ]] || return 1
  [[ "${pre_filter_qom}" == "yes" || "${pre_filter_cmdline}" == "yes" ||
     "${primary_filter_qom}" == "yes" || "${primary_filter_cmdline}" == "yes" ]] || return 1
  [[ "${pre_mirror}" == "yes" || "${channel_mirror}" == "yes" ]] || return 1
  [[ "${pre_compare}" == "yes" || "${channel_compare}" == "yes" ]] || return 1
  [[ "${pre_compare_local}" == "yes" || "${channel_compare_local}" == "yes" ]] || return 1
  [[ "${pre_compare_out}" == "yes" || "${channel_compare_out}" == "yes" ]] || return 1
  [[ "${secondary_block_graph}" == "yes" || "${secondary_block_graph}" == "not_applicable" ]] || return 1
  [[ -z "${firewall_ready}" || "${firewall_ready}" == "yes" ]] || return 1
  [[ -z "${runtime_socket_captured}" || "${runtime_socket_captured}" == "yes" ]] || return 1

  ftctl_state_set "${vm}" \
    "xcolo_repeated_protocol_invalid_message_evidence=premigrate_ready" \
    "xcolo_repeated_protocol_invalid_message_storage_symmetry=${storage_symmetry}"
  return 0
}

ftctl_xcolo_invalid_message_protocol_reason() {
  local vm="${1-}"
  local primary_filter_qom="${2-}"
  local primary_filter_cmdline="${3-}"
  local channel_mirror="${4-}"
  local channel_compare="${5-}"
  local channel_compare_local="${6-}"
  local channel_compare_out="${7-}"
  local secondary_block_graph="${8-}"
  local primary_migrate="${9-}"
  local secondary_migrate="${10-}"
  local primary_colo="${11-}"
  local secondary_colo="${12-}"
  local firewall_ready storage_symmetry runtime_socket_captured
  local topology_audit startup_primary_9998 failure_primary_9998
  local pre_chardev pre_filter_qom pre_filter_cmdline

  firewall_ready="$(ftctl_state_get "${vm}" "xcolo_firewall_ready" 2>/dev/null || true)"
  storage_symmetry="$(ftctl_state_get "${vm}" "xcolo_storage_symmetry" 2>/dev/null || true)"
  runtime_socket_captured="$(ftctl_state_get "${vm}" "xcolo_socket_runtime_captured" 2>/dev/null || true)"
  topology_audit="$(ftctl_state_get "${vm}" "xcolo_topology_audit" 2>/dev/null || true)"
  startup_primary_9998="$(ftctl_state_get "${vm}" "xcolo_socket_post_migrate_startup_active_validation_primary_9998" 2>/dev/null || true)"
  failure_primary_9998="$(ftctl_state_get "${vm}" "xcolo_socket_failure_primary_9998" 2>/dev/null || true)"
  pre_chardev="$(ftctl_state_get "${vm}" "xcolo_premigrate_primary_filter_chardev_ready" 2>/dev/null || true)"
  pre_filter_qom="$(ftctl_state_get "${vm}" "xcolo_premigrate_primary_filter_qom_ready" 2>/dev/null || true)"
  pre_filter_cmdline="$(ftctl_state_get "${vm}" "xcolo_premigrate_primary_filter_cmdline_ready" 2>/dev/null || true)"

  if [[ "${firewall_ready}" == "no" ]]; then
    printf '%s\n' "firewall_not_ready"
  elif [[ -n "${storage_symmetry}" && "${storage_symmetry}" != "ok" ]]; then
    printf '%s\n' "storage_symmetry_not_ok"
  elif [[ "${pre_chardev}" != "yes" ]]; then
    printf '%s\n' "premigrate_chardev_not_ready"
  elif [[ "${pre_filter_qom}" != "yes" && "${pre_filter_cmdline}" != "yes" &&
          "${primary_filter_qom}" != "yes" && "${primary_filter_cmdline}" != "yes" ]]; then
    printf '%s\n' "premigrate_filter_topology_not_ready"
  elif [[ "${channel_mirror}" != "yes" ||
          "${channel_compare}" != "yes" ||
          "${channel_compare_local}" != "yes" ||
          "${channel_compare_out}" != "yes" ]]; then
    printf '%s\n' "runtime_channel_not_ready"
  elif [[ "${secondary_block_graph}" != "yes" && "${secondary_block_graph}" != "not_applicable" ]]; then
    printf '%s\n' "secondary_block_graph_not_ready"
  elif [[ -n "${runtime_socket_captured}" && "${runtime_socket_captured}" != "yes" ]]; then
    printf '%s\n' "runtime_socket_snapshot_missing"
  elif [[ "${topology_audit}" == "failed" ]]; then
    printf '%s\n' "topology_audit_failed"
  elif [[ "${primary_migrate}" == "failed" &&
          ( "${secondary_migrate}" == "colo" || "${secondary_colo}" == "secondary" ) &&
          "${startup_primary_9998}" == "established" &&
          "${failure_primary_9998}" == "closed" ]]; then
    printf '%s\n' "return_path_protocol_closed_after_startup_active"
  elif [[ "${primary_migrate}" == "failed" &&
          "${secondary_migrate}" == "colo" &&
          "${primary_colo}" == "none" &&
          "${secondary_colo}" == "secondary" ]]; then
    printf '%s\n' "primary_role_not_entered_after_migrate"
  else
    printf '%s\n' "qemu_return_path_invalid_zero_header"
  fi
}

ftctl_xcolo_validate_pair_runtime() {
  local vm="${1-}"
  local secondary_vm="${2:-$vm}"
  local primary_running="" secondary_running=""
  local primary_status="" secondary_status=""
  local primary_colo="" secondary_colo=""
  local primary_migrate="" secondary_migrate=""
  local primary_migrate_error_desc="" secondary_migrate_error_desc=""
  local primary_qga="" secondary_qga="" qga_policy
  local primary_xml="missing" secondary_xml="missing"
  local channel_mirror="" channel_compare="" channel_compare_local="" channel_compare_out=""
  local primary_filter_qom="unknown" primary_filter_qom_reason=""
  local primary_filter_cmdline="unknown" primary_filter_cmdline_reason=""
  local primary_chardev="unknown" primary_chardev_reason=""
  local disk_plan="" secondary_block_graph="unknown" secondary_block_graph_reason=""
  local reason="" timeout i pending_since pending_elapsed pending_max pending_reason protocol_reason
  local socket_runtime_captured="no" last_error_value

  if [[ "${FTCTL_DRY_RUN}" == "1" ]]; then
    ftctl_log_event "colo" "xcolo.runtime_validate" "skip" "${vm}" "" "reason=dry_run"
    return 0
  fi

  timeout="${FTCTL_XCOLO_RUNTIME_VALIDATE_TIMEOUT_SEC:-45}"
  [[ "${timeout}" =~ ^[0-9]+$ && "${timeout}" -gt 0 ]] || timeout="45"
  qga_policy="${FTCTL_PROFILE_QGA_POLICY:-optional}"
  disk_plan="$(ftctl_state_get "${vm}" "xcolo_disk_plan" 2>/dev/null || true)"

  for ((i=0; i<timeout; i++)); do
    reason=""
    primary_running=""
    secondary_running=""
    primary_status=""
    secondary_status=""
    primary_colo=""
    secondary_colo=""
    primary_migrate=""
    secondary_migrate=""
    primary_migrate_error_desc=""
    secondary_migrate_error_desc=""
    primary_qga=""
    secondary_qga=""
    primary_xml="missing"
    secondary_xml="missing"
    channel_mirror=""
    channel_compare=""
    channel_compare_local=""
    channel_compare_out=""
    primary_filter_qom="unknown"
    primary_filter_qom_reason=""
    primary_filter_cmdline="unknown"
    primary_filter_cmdline_reason=""
    primary_chardev="unknown"
    primary_chardev_reason=""
    secondary_block_graph="unknown"
    secondary_block_graph_reason=""

    ftctl_xcolo_query_running_flag "${FTCTL_PROFILE_PRIMARY_URI}" "${vm}" primary_running || true
    ftctl_xcolo_query_running_flag "${FTCTL_PROFILE_SECONDARY_URI}" "${secondary_vm}" secondary_running || true
    ftctl_xcolo_query_status_name "${FTCTL_PROFILE_PRIMARY_URI}" "${vm}" primary_status || true
    ftctl_xcolo_query_status_name "${FTCTL_PROFILE_SECONDARY_URI}" "${secondary_vm}" secondary_status || true
    ftctl_xcolo_query_colo_mode "${FTCTL_PROFILE_PRIMARY_URI}" "${vm}" primary_colo || true
    ftctl_xcolo_query_colo_mode "${FTCTL_PROFILE_SECONDARY_URI}" "${secondary_vm}" secondary_colo || true
    ftctl_xcolo_query_migrate_status "${FTCTL_PROFILE_PRIMARY_URI}" "${vm}" primary_migrate || true
    ftctl_xcolo_query_migrate_status "${FTCTL_PROFILE_SECONDARY_URI}" "${secondary_vm}" secondary_migrate || true
    if [[ "${primary_migrate}" == "failed" ]]; then
      ftctl_xcolo_query_migrate_error_desc "${FTCTL_PROFILE_PRIMARY_URI}" "${vm}" primary_migrate_error_desc || true
    fi
    if [[ "${secondary_migrate}" == "failed" ]]; then
      ftctl_xcolo_query_migrate_error_desc "${FTCTL_PROFILE_SECONDARY_URI}" "${secondary_vm}" secondary_migrate_error_desc || true
    fi
    if [[ "${qga_policy}" == "off" ]]; then
      primary_qga="off"
      secondary_qga="off"
    else
      ftctl_xcolo_query_guest_ping "${FTCTL_PROFILE_PRIMARY_URI}" "${vm}" primary_qga || true
      ftctl_xcolo_query_guest_ping "${FTCTL_PROFILE_SECONDARY_URI}" "${secondary_vm}" secondary_qga || true
    fi

    if ftctl_xcolo_domain_xml_has_runtime_markers "${FTCTL_PROFILE_PRIMARY_URI}" "${vm}" primary ||
        ftctl_xcolo_domain_xml_has_primary_chardev_markers "${FTCTL_PROFILE_PRIMARY_URI}" "${vm}"; then
      primary_xml="ok"
    fi
    if ftctl_xcolo_domain_xml_has_runtime_markers "${FTCTL_PROFILE_SECONDARY_URI}" "${secondary_vm}" secondary; then
      secondary_xml="ok"
    fi
    ftctl_xcolo_capture_primary_channel_state "${vm}" || true
    channel_mirror="$(ftctl_state_get "${vm}" "xcolo_channel_mirror_established" 2>/dev/null || true)"
    channel_compare="$(ftctl_state_get "${vm}" "xcolo_channel_compare_established" 2>/dev/null || true)"
    channel_compare_local="$(ftctl_state_get "${vm}" "xcolo_channel_compare_local_established" 2>/dev/null || true)"
    channel_compare_out="$(ftctl_state_get "${vm}" "xcolo_channel_compare_out_established" 2>/dev/null || true)"
    ftctl_xcolo_collect_primary_filter_qom_state "${vm}" || true
    primary_filter_qom="$(ftctl_state_get "${vm}" "xcolo_primary_filter_qom_ready" 2>/dev/null || true)"
    primary_filter_qom_reason="$(ftctl_state_get "${vm}" "xcolo_primary_filter_qom_reason" 2>/dev/null || true)"
    ftctl_xcolo_collect_primary_filter_cmdline_state "${vm}" || true
    primary_filter_cmdline="$(ftctl_state_get "${vm}" "xcolo_primary_filter_cmdline_ready" 2>/dev/null || true)"
    primary_filter_cmdline_reason="$(ftctl_state_get "${vm}" "xcolo_primary_filter_cmdline_reason" 2>/dev/null || true)"
    ftctl_xcolo_collect_primary_chardev_binding_state "${vm}" || true
    primary_chardev="$(ftctl_state_get "${vm}" "xcolo_primary_filter_chardev_ready" 2>/dev/null || true)"
    primary_chardev_reason="$(ftctl_state_get "${vm}" "xcolo_primary_filter_chardev_reason" 2>/dev/null || true)"
    ftctl_xcolo_collect_secondary_block_graph_state "${vm}" "${secondary_vm}" "${disk_plan}" || true
    secondary_block_graph="$(ftctl_state_get "${vm}" "xcolo_secondary_block_graph_ready" 2>/dev/null || true)"
    secondary_block_graph_reason="$(ftctl_state_get "${vm}" "xcolo_secondary_block_graph_reason" 2>/dev/null || true)"

    if [[ "${socket_runtime_captured}" != "yes" &&
          ( "${primary_migrate}" == "active" || "${primary_migrate}" == "failed" || "${secondary_migrate}" == "colo" ) ]]; then
      ftctl_xcolo_capture_socket_snapshot "${vm}" "runtime" || true
      ftctl_state_set "${vm}" "xcolo_socket_runtime_captured=yes"
      socket_runtime_captured="yes"
    fi

    if [[ "${primary_migrate}" == "failed" ]]; then
      ftctl_xcolo_capture_socket_snapshot "${vm}" "failure" || true
      if [[ "${primary_migrate_error_desc}" == *"Received invalid message"* ]] &&
          ftctl_xcolo_repeated_invalid_message_evidence_ready "${vm}" "${primary_filter_qom}" "${primary_filter_cmdline}" \
            "${channel_mirror}" "${channel_compare}" "${channel_compare_local}" "${channel_compare_out}" \
            "${secondary_block_graph}"; then
        ftctl_xcolo_collect_runtime_failure_diagnostics "${vm}" "${secondary_vm}" || true
        reason="repeated_protocol_invalid_message"
        protocol_reason="$(ftctl_xcolo_invalid_message_protocol_reason "${vm}" "${primary_filter_qom}" "${primary_filter_cmdline}" \
          "${channel_mirror}" "${channel_compare}" "${channel_compare_local}" "${channel_compare_out}" \
          "${secondary_block_graph}" "${primary_migrate}" "${secondary_migrate}" "${primary_colo}" "${secondary_colo}")"
        ftctl_state_set "${vm}" \
          "xcolo_repeated_protocol_invalid_message=yes" \
          "xcolo_protocol_invalid_message_reason=${protocol_reason}" \
          "xcolo_protocol_failure_phase=$(ftctl_state_get "${vm}" "xcolo_protocol_failure_phase" 2>/dev/null || printf '%s' post_filter_activation)" \
          "xcolo_protocol_invalid_message_scope=post_migrate_steady_state" \
          "xcolo_protocol_steady_state_required=true" \
          "xcolo_protocol_expected_primary_role=primary" \
          "xcolo_protocol_expected_secondary_role=secondary"
      elif [[ "${primary_migrate_error_desc}" == *"Received invalid message"* ]] &&
          ftctl_xcolo_primary_log_has_filter_mirror_send_failure "${vm}"; then
        reason="primary_filter_mirror_send_failed"
        ftctl_state_set "${vm}" "xcolo_primary_filter_mirror_send_failed=yes"
      else
        reason="primary_migrate_failed"
      fi
      break
    elif [[ "${secondary_migrate}" == "failed" ]]; then
      ftctl_xcolo_capture_socket_snapshot "${vm}" "failure" || true
      reason="secondary_migrate_failed"
      break
    elif [[ "${primary_xml}" == "ok" &&
            "${secondary_xml}" == "ok" &&
            "${primary_migrate}" == "active" &&
            "${secondary_migrate}" == "colo" &&
            "${primary_colo}" == "primary" &&
            "${secondary_colo}" == "secondary" &&
            ( "${qga_policy}" != "required" || "${primary_qga}" == "yes" ) ]] &&
          ftctl_xcolo_runtime_primary_topology_ready "${primary_xml}" "${primary_filter_qom}" "${primary_filter_cmdline}" \
            "${channel_mirror}" "${channel_compare}" "${channel_compare_local}" "${channel_compare_out}" \
            "${disk_plan}" "${secondary_block_graph}" &&
          ftctl_xcolo_colo_mode_active "${primary_colo}" &&
          ftctl_xcolo_colo_mode_active "${secondary_colo}"; then
      ftctl_state_set "${vm}" \
        "xcolo_primary_running=${primary_running}" \
        "xcolo_secondary_running=${secondary_running}" \
        "xcolo_primary_status=${primary_status}" \
        "xcolo_secondary_status=${secondary_status}" \
        "xcolo_primary_colo_mode=${primary_colo}" \
        "xcolo_secondary_colo_mode=${secondary_colo}" \
        "xcolo_primary_migrate_status=${primary_migrate}" \
        "xcolo_secondary_migrate_status=${secondary_migrate}" \
        "xcolo_primary_qga=${primary_qga}" \
        "xcolo_secondary_qga=${secondary_qga}" \
        "xcolo_primary_runtime_xml=${primary_xml}" \
        "xcolo_secondary_runtime_xml=${secondary_xml}" \
        "xcolo_primary_filter_qom_ready=${primary_filter_qom}" \
        "xcolo_primary_filter_qom_reason=${primary_filter_qom_reason}" \
        "xcolo_primary_filter_cmdline_ready=${primary_filter_cmdline}" \
        "xcolo_primary_filter_cmdline_reason=${primary_filter_cmdline_reason}" \
        "xcolo_primary_filter_chardev_ready=${primary_chardev}" \
        "xcolo_primary_filter_chardev_reason=${primary_chardev_reason}" \
        "xcolo_channel_mirror_established=${channel_mirror}" \
        "xcolo_channel_compare_established=${channel_compare}" \
        "xcolo_channel_compare_local_established=${channel_compare_local}" \
        "xcolo_channel_compare_out_established=${channel_compare_out}" \
        "xcolo_secondary_block_graph_ready=${secondary_block_graph}" \
        "xcolo_secondary_block_graph_reason=${secondary_block_graph_reason}"
      ftctl_log_event "colo" "xcolo.runtime_validate" "ok" "${vm}" "" \
        "reason=colo_role_active primary_running=${primary_running} secondary_running=${secondary_running} primary_status=${primary_status} secondary_status=${secondary_status} primary_colo=${primary_colo} secondary_colo=${secondary_colo} primary_migrate=${primary_migrate} secondary_migrate=${secondary_migrate} primary_qga=${primary_qga} secondary_qga=${secondary_qga} filter_qom=${primary_filter_qom} filter_cmdline=${primary_filter_cmdline} chardev=${primary_chardev} mirror=${channel_mirror} compare=${channel_compare} compare_local=${channel_compare_local} compare_out=${channel_compare_out} secondary_block_graph=${secondary_block_graph} attempts=$((i + 1))"
      return 0
    fi

    sleep 1
  done

  if [[ -z "${reason}" ]]; then
    if [[ "${primary_xml}" == "ok" &&
          "${secondary_xml}" == "ok" &&
          "${primary_migrate}" == "active" &&
          "${secondary_migrate}" == "colo" ]]; then
      ftctl_xcolo_colo_role_pending_reason "${primary_colo}" "${secondary_colo}" pending_reason
      pending_max="${FTCTL_XCOLO_RUNTIME_PENDING_MAX_SEC:-180}"
      [[ "${pending_max}" =~ ^[0-9]+$ && "${pending_max}" -gt 0 ]] || pending_max="180"
      pending_since="$(ftctl_state_get "${vm}" "xcolo_runtime_pending_since" 2>/dev/null || true)"
      pending_elapsed="0"
      if [[ -n "${pending_since}" ]]; then
        pending_elapsed="$(ftctl_elapsed_since_iso "${pending_since}" 2>/dev/null || echo "0")"
        [[ "${pending_elapsed}" =~ ^[0-9]+$ ]] || pending_elapsed="0"
      fi
      if [[ "${primary_status}" == "finish-migrate" &&
            "${secondary_status}" == "inmigrate" &&
            -n "${pending_since}" &&
            "${pending_elapsed}" -ge "${pending_max}" ]]; then
        if [[ "${qga_policy}" == "required" && "${primary_qga}" != "yes" ]]; then
          reason="primary_guest_boot_unhealthy"
        elif [[ "${primary_filter_cmdline}" == "no" && "${primary_filter_qom}" == "no" ]]; then
          reason="primary_colo_filter_topology_missing"
        elif [[ "${channel_mirror}" != "yes" ||
                "${channel_compare}" != "yes" ||
                "${channel_compare_local}" != "yes" ||
                "${channel_compare_out}" != "yes" ]]; then
          reason="$(ftctl_xcolo_primary_channel_failure_reason "${vm}")"
        elif [[ -n "${disk_plan}" && "${secondary_block_graph}" != "yes" && "${secondary_block_graph}" != "not_applicable" ]]; then
          reason="secondary_block_graph_not_ready"
        elif [[ "${primary_colo}" != "primary" && "${secondary_colo}" == "secondary" ]]; then
          pending_reason="colo_activation_stalled"
          ftctl_state_set "${vm}" \
            "xcolo_primary_running=${primary_running}" \
            "xcolo_secondary_running=${secondary_running}" \
            "xcolo_primary_status=${primary_status}" \
            "xcolo_secondary_status=${secondary_status}" \
            "xcolo_primary_colo_mode=${primary_colo}" \
            "xcolo_secondary_colo_mode=${secondary_colo}" \
            "xcolo_primary_migrate_status=${primary_migrate}" \
            "xcolo_secondary_migrate_status=${secondary_migrate}" \
            "xcolo_primary_qga=${primary_qga}" \
            "xcolo_secondary_qga=${secondary_qga}" \
            "xcolo_primary_runtime_xml=${primary_xml}" \
            "xcolo_secondary_runtime_xml=${secondary_xml}" \
            "xcolo_primary_filter_qom_ready=${primary_filter_qom}" \
            "xcolo_primary_filter_qom_reason=${primary_filter_qom_reason}" \
            "xcolo_primary_filter_cmdline_ready=${primary_filter_cmdline}" \
            "xcolo_primary_filter_cmdline_reason=${primary_filter_cmdline_reason}" \
            "xcolo_primary_filter_chardev_ready=${primary_chardev}" \
            "xcolo_primary_filter_chardev_reason=${primary_chardev_reason}" \
            "xcolo_channel_mirror_established=${channel_mirror}" \
            "xcolo_channel_compare_established=${channel_compare}" \
            "xcolo_channel_compare_local_established=${channel_compare_local}" \
            "xcolo_channel_compare_out_established=${channel_compare_out}" \
            "xcolo_secondary_block_graph_ready=${secondary_block_graph}" \
            "xcolo_secondary_block_graph_reason=${secondary_block_graph_reason}" \
            "xcolo_runtime_pending_since=${pending_since}" \
            "xcolo_pending_reason=${pending_reason}" \
            "last_error=xcolo_activation_stalled"
          ftctl_log_event "colo" "xcolo.runtime_validate" "pending" "${vm}" "" \
            "reason=${pending_reason} primary_running=${primary_running} secondary_running=${secondary_running} primary_status=${primary_status} secondary_status=${secondary_status} primary_colo=${primary_colo} secondary_colo=${secondary_colo} primary_migrate=${primary_migrate} secondary_migrate=${secondary_migrate} primary_qga=${primary_qga} secondary_qga=${secondary_qga} filter_qom=${primary_filter_qom} filter_qom_reason=${primary_filter_qom_reason} filter_cmdline=${primary_filter_cmdline} filter_cmdline_reason=${primary_filter_cmdline_reason} chardev=${primary_chardev} chardev_reason=${primary_chardev_reason} mirror=${channel_mirror} compare=${channel_compare} compare_local=${channel_compare_local} compare_out=${channel_compare_out} secondary_block_graph=${secondary_block_graph} elapsed=${pending_elapsed} max=${pending_max} attempts=${timeout}"
          return 10
        else
          reason="${pending_reason}"
        fi
      else
        [[ -n "${pending_since}" ]] || pending_since="$(ftctl_now_iso8601)"
        if ftctl_xcolo_runtime_primary_topology_ready "${primary_xml}" "${primary_filter_qom}" "${primary_filter_cmdline}" \
            "${channel_mirror}" "${channel_compare}" "${channel_compare_local}" "${channel_compare_out}" \
            "${disk_plan}" "${secondary_block_graph}"; then
          pending_reason="colo_established_candidate"
          if [[ "${primary_status}" == "finish-migrate" &&
                "${secondary_status}" == "inmigrate" &&
                "${primary_colo}" != "primary" &&
                "${pending_elapsed}" -ge "${pending_max}" ]]; then
            pending_reason="colo_activation_stalled"
          fi
        fi
        ftctl_state_set "${vm}" \
          "xcolo_primary_running=${primary_running}" \
          "xcolo_secondary_running=${secondary_running}" \
          "xcolo_primary_status=${primary_status}" \
          "xcolo_secondary_status=${secondary_status}" \
          "xcolo_primary_colo_mode=${primary_colo}" \
          "xcolo_secondary_colo_mode=${secondary_colo}" \
          "xcolo_primary_migrate_status=${primary_migrate}" \
          "xcolo_secondary_migrate_status=${secondary_migrate}" \
          "xcolo_primary_qga=${primary_qga}" \
          "xcolo_secondary_qga=${secondary_qga}" \
          "xcolo_primary_runtime_xml=${primary_xml}" \
          "xcolo_secondary_runtime_xml=${secondary_xml}" \
          "xcolo_primary_filter_qom_ready=${primary_filter_qom}" \
          "xcolo_primary_filter_qom_reason=${primary_filter_qom_reason}" \
          "xcolo_primary_filter_cmdline_ready=${primary_filter_cmdline}" \
          "xcolo_primary_filter_cmdline_reason=${primary_filter_cmdline_reason}" \
          "xcolo_primary_filter_chardev_ready=${primary_chardev}" \
          "xcolo_primary_filter_chardev_reason=${primary_chardev_reason}" \
          "xcolo_channel_mirror_established=${channel_mirror}" \
          "xcolo_channel_compare_established=${channel_compare}" \
          "xcolo_channel_compare_local_established=${channel_compare_local}" \
          "xcolo_channel_compare_out_established=${channel_compare_out}" \
          "xcolo_secondary_block_graph_ready=${secondary_block_graph}" \
          "xcolo_secondary_block_graph_reason=${secondary_block_graph_reason}" \
          "xcolo_runtime_pending_since=${pending_since}" \
          "xcolo_pending_reason=${pending_reason}" \
          "last_error="
        ftctl_log_event "colo" "xcolo.runtime_validate" "pending" "${vm}" "" \
          "reason=${pending_reason} primary_running=${primary_running} secondary_running=${secondary_running} primary_status=${primary_status} secondary_status=${secondary_status} primary_colo=${primary_colo} secondary_colo=${secondary_colo} primary_migrate=${primary_migrate} secondary_migrate=${secondary_migrate} primary_qga=${primary_qga} secondary_qga=${secondary_qga} filter_qom=${primary_filter_qom} filter_qom_reason=${primary_filter_qom_reason} filter_cmdline=${primary_filter_cmdline} filter_cmdline_reason=${primary_filter_cmdline_reason} chardev=${primary_chardev} chardev_reason=${primary_chardev_reason} mirror=${channel_mirror} compare=${channel_compare} compare_local=${channel_compare_local} compare_out=${channel_compare_out} secondary_block_graph=${secondary_block_graph} elapsed=${pending_elapsed} max=${pending_max} attempts=${timeout}"
        return 10
      fi
    fi
  fi

  if [[ -z "${reason}" ]]; then
    if [[ "${primary_xml}" == "ok" &&
          "${secondary_xml}" == "ok" &&
          "${primary_migrate}" == "active" &&
          "${secondary_migrate}" == "colo" ]]; then
      ftctl_state_set "${vm}" \
        "xcolo_primary_running=${primary_running}" \
        "xcolo_secondary_running=${secondary_running}" \
        "xcolo_primary_status=${primary_status}" \
        "xcolo_secondary_status=${secondary_status}" \
        "xcolo_primary_colo_mode=${primary_colo}" \
        "xcolo_secondary_colo_mode=${secondary_colo}" \
        "xcolo_primary_migrate_status=${primary_migrate}" \
        "xcolo_secondary_migrate_status=${secondary_migrate}" \
        "xcolo_primary_qga=${primary_qga}" \
        "xcolo_secondary_qga=${secondary_qga}" \
        "xcolo_primary_runtime_xml=${primary_xml}" \
        "xcolo_secondary_runtime_xml=${secondary_xml}" \
        "xcolo_primary_filter_qom_ready=${primary_filter_qom}" \
        "xcolo_primary_filter_qom_reason=${primary_filter_qom_reason}" \
        "xcolo_primary_filter_cmdline_ready=${primary_filter_cmdline}" \
        "xcolo_primary_filter_cmdline_reason=${primary_filter_cmdline_reason}" \
        "xcolo_primary_filter_chardev_ready=${primary_chardev}" \
        "xcolo_primary_filter_chardev_reason=${primary_chardev_reason}" \
        "xcolo_channel_mirror_established=${channel_mirror}" \
        "xcolo_channel_compare_established=${channel_compare}" \
        "xcolo_channel_compare_local_established=${channel_compare_local}" \
        "xcolo_channel_compare_out_established=${channel_compare_out}"
      if [[ "${qga_policy}" == "required" && "${primary_qga}" != "yes" ]]; then
        reason="primary_guest_boot_unhealthy"
      elif [[ "${primary_filter_cmdline}" == "no" && "${primary_filter_qom}" == "no" ]]; then
        reason="primary_colo_filter_topology_missing"
      elif [[ "${channel_mirror}" != "yes" ||
              "${channel_compare}" != "yes" ||
              "${channel_compare_local}" != "yes" ||
              "${channel_compare_out}" != "yes" ]]; then
        reason="$(ftctl_xcolo_primary_channel_failure_reason "${vm}")"
      elif [[ -n "${disk_plan}" && "${secondary_block_graph}" != "yes" && "${secondary_block_graph}" != "not_applicable" ]]; then
        reason="secondary_block_graph_not_ready"
      elif [[ "${primary_status}" == "finish-migrate" &&
              "${secondary_status}" == "inmigrate" &&
              "${primary_colo}" != "primary" &&
              "${secondary_colo}" == "secondary" ]]; then
        reason="primary_finish_migrate_colo_role_not_entered"
      else
        ftctl_xcolo_colo_role_pending_reason "${primary_colo}" "${secondary_colo}" reason
        if [[ "${reason}" == "runtime_converging" ]]; then
          reason="runtime_convergence_timeout"
        fi
      fi
    elif [[ "${primary_running}" != "true" ]]; then
      reason="primary_not_running"
    elif [[ "${secondary_running}" != "true" ]]; then
      reason="secondary_not_running"
    elif [[ "${primary_xml}" != "ok" ]]; then
      reason="primary_runtime_xml_missing_colo_markers"
    elif [[ "${secondary_xml}" != "ok" ]]; then
      reason="secondary_runtime_xml_missing_colo_markers"
    elif [[ "${secondary_migrate}" != "colo" ]]; then
      reason="secondary_not_in_colo_migration"
    fi
  fi

  if [[ -n "${reason}" ]]; then
    if [[ "${reason}" == "primary_colo_role_not_entered" ]]; then
      ftctl_xcolo_collect_runtime_failure_diagnostics "${vm}" "${secondary_vm}" || true
      reason="$(ftctl_xcolo_refine_primary_role_failure_reason "${vm}" "${reason}")"
    fi
    last_error_value="xcolo_runtime_validation_failed:${reason}"
    if [[ "${reason}" == "repeated_protocol_invalid_message" ]]; then
      last_error_value="xcolo_repeated_protocol_invalid_message"
      protocol_reason="$(ftctl_state_get "${vm}" "xcolo_protocol_invalid_message_reason" 2>/dev/null || true)"
      [[ -n "${protocol_reason}" ]] || protocol_reason="qemu_colo_protocol_invalid_message"
    fi
    ftctl_state_set "${vm}" \
      "xcolo_primary_running=${primary_running}" \
      "xcolo_secondary_running=${secondary_running}" \
      "xcolo_primary_status=${primary_status}" \
      "xcolo_secondary_status=${secondary_status}" \
      "xcolo_primary_colo_mode=${primary_colo}" \
      "xcolo_secondary_colo_mode=${secondary_colo}" \
      "xcolo_primary_migrate_status=${primary_migrate}" \
      "xcolo_secondary_migrate_status=${secondary_migrate}" \
      "xcolo_primary_migrate_error_desc=${primary_migrate_error_desc}" \
      "xcolo_secondary_migrate_error_desc=${secondary_migrate_error_desc}" \
      "xcolo_primary_qga=${primary_qga}" \
      "xcolo_secondary_qga=${secondary_qga}" \
      "xcolo_primary_runtime_xml=${primary_xml}" \
      "xcolo_secondary_runtime_xml=${secondary_xml}" \
      "xcolo_primary_filter_qom_ready=${primary_filter_qom}" \
      "xcolo_primary_filter_qom_reason=${primary_filter_qom_reason}" \
      "xcolo_primary_filter_cmdline_ready=${primary_filter_cmdline}" \
      "xcolo_primary_filter_cmdline_reason=${primary_filter_cmdline_reason}" \
      "xcolo_primary_filter_chardev_ready=${primary_chardev}" \
      "xcolo_primary_filter_chardev_reason=${primary_chardev_reason}" \
      "xcolo_channel_mirror_established=${channel_mirror}" \
      "xcolo_channel_compare_established=${channel_compare}" \
      "xcolo_channel_compare_local_established=${channel_compare_local}" \
      "xcolo_channel_compare_out_established=${channel_compare_out}" \
      "xcolo_secondary_block_graph_ready=${secondary_block_graph}" \
      "xcolo_secondary_block_graph_reason=${secondary_block_graph_reason}" \
      "xcolo_steady_state_gate=failed" \
      "last_error=${last_error_value}"
    ftctl_log_event "colo" "xcolo.runtime_validate" "fail" "${vm}" "" \
      "reason=${reason} protocol_reason=${protocol_reason:-} primary_running=${primary_running} secondary_running=${secondary_running} primary_status=${primary_status} secondary_status=${secondary_status} primary_colo=${primary_colo} secondary_colo=${secondary_colo} primary_xml=${primary_xml} secondary_xml=${secondary_xml} primary_migrate=${primary_migrate} primary_migrate_error_desc=${primary_migrate_error_desc} secondary_migrate=${secondary_migrate} secondary_migrate_error_desc=${secondary_migrate_error_desc} primary_qga=${primary_qga} secondary_qga=${secondary_qga} filter_qom=${primary_filter_qom} filter_qom_reason=${primary_filter_qom_reason} filter_cmdline=${primary_filter_cmdline} filter_cmdline_reason=${primary_filter_cmdline_reason} chardev=${primary_chardev} chardev_reason=${primary_chardev_reason} mirror=${channel_mirror} compare=${channel_compare} compare_local=${channel_compare_local} compare_out=${channel_compare_out} secondary_block_graph=${secondary_block_graph} attempts=${timeout}"
    return 1
  fi
}

ftctl_xcolo_recover_runtime_convergence_failure() {
  local vm="${1-}"
  local reason="${2:-xcolo_runtime_convergence_failed}"
  local out err rc

  if [[ "${FTCTL_DRY_RUN}" == "1" ]]; then
    ftctl_state_set "${vm}" \
      "conversion_stage=runtime_validation_failed" \
      "conversion_state=error" \
      "protection_state=error" \
      "transport_state=failed" \
      "xcolo_last_runtime_error=${reason}" \
      "last_error=${reason}"
    ftctl_log_event "colo" "xcolo.runtime_recover" "skip" "${vm}" "" \
      "reason=dry_run cause=${reason}"
    return 0
  fi

  ftctl_standby_deactivate "${vm}" || {
    ftctl_log_event "colo" "xcolo.runtime_recover.secondary_stop" "warn" "${vm}" "" \
      "cause=${reason}"
  }

  out=""
  err=""
  rc=0
  ftctl_virsh "${FTCTL_FENCING_TIMEOUT_SEC:-15}" out err rc -- -c "${FTCTL_PROFILE_PRIMARY_URI}" destroy "${vm}" || true
  : "${out}${err}${rc}"
  ftctl_log_event "colo" "xcolo.runtime_recover.primary_destroy" "$(ftctl_result_from_rc "${rc}")" "${vm}" "${rc}" \
    "cause=${reason}"

  ftctl_primary_activate_from_backup "${vm}" || {
    ftctl_state_set "${vm}" \
      "conversion_stage=runtime_recover_failed" \
      "conversion_state=error" \
      "protection_state=error" \
      "transport_state=failed" \
      "xcolo_last_runtime_error=${reason}:primary_restore_failed" \
      "last_error=${reason}:primary_restore_failed"
    ftctl_log_event "colo" "xcolo.runtime_recover" "fail" "${vm}" "" \
      "cause=${reason} restore=failed"
    return 1
  }

  ftctl_state_set "${vm}" \
    "conversion_stage=runtime_validation_failed" \
    "conversion_state=error" \
    "protection_state=error" \
    "transport_state=failed" \
    "active_side=primary" \
    "standby_state=stopped" \
    "xcolo_last_runtime_error=${reason}" \
    "last_error=${reason}"
  ftctl_log_event "colo" "xcolo.runtime_recover" "ok" "${vm}" "" \
    "cause=${reason}"
}

ftctl_xcolo_recover_block_handshake_failure() {
  local vm="${1-}"
  local reason="${2:-xcolo_block_handshake_failed}"
  local rc=0 current_error

  ftctl_xcolo_recover_runtime_convergence_failure "${vm}" "${reason}" || rc=$?
  if [[ "${rc}" != "0" ]]; then
    current_error="$(ftctl_state_get "${vm}" "last_error" 2>/dev/null || true)"
    [[ -n "${current_error}" ]] || current_error="${reason}:runtime_recover_failed"
    ftctl_state_set "${vm}" \
      "conversion_stage=handshake_recover_failed" \
      "conversion_state=error" \
      "protection_state=error" \
      "transport_state=failed" \
      "xcolo_last_runtime_error=${current_error}" \
      "last_error=${current_error}"
    ftctl_log_event "colo" "block_conversion.handshake_recover" "fail" "${vm}" "${rc}" \
      "cause=${reason} error=${current_error}"
    return "${rc}"
  fi

  ftctl_state_set "${vm}" \
    "conversion_stage=handshake_failed" \
    "conversion_state=error" \
    "protection_state=error" \
    "transport_state=failed" \
    "xcolo_last_runtime_error=${reason}" \
    "last_error=${reason}"
  ftctl_log_event "colo" "block_conversion.handshake_recover" "ok" "${vm}" "" \
    "cause=${reason}"
}

ftctl_xcolo_mark_runtime_pending() {
  local vm="${1-}"
  local stage="${2:-runtime_converging}"
  local pending_since

  pending_since="$(ftctl_state_get "${vm}" "xcolo_runtime_pending_since" 2>/dev/null || true)"
  [[ -n "${pending_since}" ]] || pending_since="$(ftctl_now_iso8601)"
  ftctl_state_set "${vm}" \
    "conversion_stage=${stage}" \
    "conversion_state=pending" \
    "protection_state=pairing" \
    "transport_state=establishing" \
    "active_side=primary" \
    "xcolo_runtime_pending_since=${pending_since}" \
    "last_error="
}

ftctl_xcolo_runtime_candidate_observe_sec() {
  local threshold="${FTCTL_XCOLO_RUNTIME_CANDIDATE_OBSERVE_SEC:-}"
  if [[ -z "${threshold}" ]]; then
    threshold="${FTCTL_XCOLO_RUNTIME_CANDIDATE_PROMOTE_SEC:-}"
  fi
  if [[ -z "${threshold}" ]]; then
    threshold="${FTCTL_XCOLO_RUNTIME_PENDING_MAX_SEC:-180}"
  fi
  [[ "${threshold}" =~ ^[0-9]+$ && "${threshold}" -gt 0 ]] || threshold="180"
  printf '%s\n' "${threshold}"
}

ftctl_xcolo_candidate_observation_ready() {
  local vm="${1-}"
  local pending_reason pending_since elapsed threshold
  local primary_status="" secondary_status="" primary_migrate="" secondary_migrate=""
  local primary_colo="" secondary_colo=""
  local secondary_vm
  local filter_qom filter_cmdline mirror compare compare_local compare_out
  local secondary_block_graph
  local primary_chardev

  pending_reason="$(ftctl_state_get "${vm}" "xcolo_pending_reason" 2>/dev/null || true)"
  [[ "${pending_reason}" == "colo_established_candidate" || "${pending_reason}" == "colo_activation_stalled" ]] || return 1

  pending_since="$(ftctl_state_get "${vm}" "xcolo_runtime_pending_since" 2>/dev/null || true)"
  [[ -n "${pending_since}" ]] || return 1
  elapsed="$(ftctl_elapsed_since_iso "${pending_since}" 2>/dev/null || echo "0")"
  [[ "${elapsed}" =~ ^[0-9]+$ ]] || elapsed="0"
  threshold="$(ftctl_xcolo_runtime_candidate_observe_sec)"
  ftctl_state_set "${vm}" \
    "xcolo_candidate_observe_elapsed=${elapsed}" \
    "xcolo_candidate_observe_threshold=${threshold}"
  (( elapsed >= threshold )) || return 1

  secondary_vm="$(ftctl_profile_secondary_vm_name_resolved "${vm}")"
  [[ -n "${secondary_vm}" ]] || secondary_vm="${vm}"
  ftctl_xcolo_query_status_name "${FTCTL_PROFILE_PRIMARY_URI}" "${vm}" primary_status || true
  ftctl_xcolo_query_status_name "${FTCTL_PROFILE_SECONDARY_URI}" "${secondary_vm}" secondary_status || true
  ftctl_xcolo_query_migrate_status "${FTCTL_PROFILE_PRIMARY_URI}" "${vm}" primary_migrate || true
  ftctl_xcolo_query_migrate_status "${FTCTL_PROFILE_SECONDARY_URI}" "${secondary_vm}" secondary_migrate || true
  ftctl_xcolo_query_colo_mode "${FTCTL_PROFILE_PRIMARY_URI}" "${vm}" primary_colo || true
  ftctl_xcolo_query_colo_mode "${FTCTL_PROFILE_SECONDARY_URI}" "${secondary_vm}" secondary_colo || true

  [[ "${primary_status}" == "finish-migrate" ]] || return 1
  [[ "${secondary_status}" == "inmigrate" ]] || return 1
  [[ "${primary_migrate}" == "active" ]] || return 1
  [[ "${secondary_migrate}" == "colo" ]] || return 1
  [[ "${primary_colo}" != "primary" ]] || return 1
  [[ "${secondary_colo}" == "secondary" ]] || return 1

  ftctl_xcolo_capture_primary_channel_state "${vm}" || true
  mirror="$(ftctl_state_get "${vm}" "xcolo_channel_mirror_established" 2>/dev/null || true)"
  compare="$(ftctl_state_get "${vm}" "xcolo_channel_compare_established" 2>/dev/null || true)"
  compare_local="$(ftctl_state_get "${vm}" "xcolo_channel_compare_local_established" 2>/dev/null || true)"
  compare_out="$(ftctl_state_get "${vm}" "xcolo_channel_compare_out_established" 2>/dev/null || true)"
  [[ "${mirror}" == "yes" && "${compare}" == "yes" && "${compare_local}" == "yes" && "${compare_out}" == "yes" ]] || return 1

  filter_qom="$(ftctl_state_get "${vm}" "xcolo_primary_filter_qom_ready" 2>/dev/null || true)"
  filter_cmdline="$(ftctl_state_get "${vm}" "xcolo_primary_filter_cmdline_ready" 2>/dev/null || true)"
  [[ "${filter_qom}" == "yes" || "${filter_cmdline}" == "yes" ]] || return 1
  primary_chardev="$(ftctl_state_get "${vm}" "xcolo_primary_filter_chardev_ready" 2>/dev/null || true)"
  [[ "${primary_chardev}" == "yes" ]] || return 1
  secondary_block_graph="$(ftctl_state_get "${vm}" "xcolo_secondary_block_graph_ready" 2>/dev/null || true)"
  [[ "${secondary_block_graph}" == "yes" || "${secondary_block_graph}" == "not_applicable" ]] || return 1

  ftctl_state_set "${vm}" \
    "xcolo_candidate_primary_status=${primary_status}" \
    "xcolo_candidate_secondary_status=${secondary_status}" \
    "xcolo_candidate_primary_colo=${primary_colo}" \
    "xcolo_candidate_secondary_colo=${secondary_colo}" \
    "xcolo_candidate_primary_migrate=${primary_migrate}" \
    "xcolo_candidate_secondary_migrate=${secondary_migrate}" \
    "xcolo_candidate_observe_ready=yes"
  return 0
}

ftctl_xcolo_mark_candidate_observed() {
  local vm="${1-}"
  local source="${2:-runtime_reconcile}"
  local pending_reason stage transport error result

  pending_reason="$(ftctl_state_get "${vm}" "xcolo_pending_reason" 2>/dev/null || true)"
  stage="handshake_candidate_established"
  transport="candidate_established"
  error=""
  result="pending"
  if [[ "${pending_reason}" == "colo_activation_stalled" ]]; then
    stage="activation_stalled"
    transport="activation_stalled"
    error="xcolo_activation_stalled"
    result="warn"
  fi
  ftctl_state_set "${vm}" \
    "conversion_stage=${stage}" \
    "conversion_state=pending" \
    "protection_state=pairing" \
    "transport_state=${transport}" \
    "active_side=primary" \
    "xcolo_candidate_observed=true" \
    "xcolo_candidate_observed_by=${source}" \
    "last_healthy_ts=$(ftctl_now_iso8601)" \
    "last_error=${error}"
  ftctl_log_event "colo" "xcolo.runtime_candidate" "${result}" "${vm}" "" \
    "source=${source} reason=${pending_reason} elapsed=$(ftctl_state_get "${vm}" "xcolo_candidate_observe_elapsed" 2>/dev/null || true) threshold=$(ftctl_state_get "${vm}" "xcolo_candidate_observe_threshold" 2>/dev/null || true)"
}

ftctl_xcolo_reconcile_pending_runtime() {
  local vm="${1-}"
  local secondary_vm
  local rc recover_reason

  secondary_vm="$(ftctl_profile_secondary_vm_name_resolved "${vm}")"
  [[ -n "${secondary_vm}" ]] || secondary_vm="$(ftctl_state_get "${vm}" "secondary_vm_name" 2>/dev/null || true)"
  [[ -n "${secondary_vm}" ]] || secondary_vm="${vm}"

  rc=0
  ftctl_xcolo_validate_pair_runtime "${vm}" "${secondary_vm}" || rc=$?
  case "${rc}" in
    0)
      ftctl_xcolo_verify_checkpoint_delay_after_start "${vm}" || \
        ftctl_log_event "colo" "primary.migrate_set_parameters.post_start" "warn" "${vm}" "" \
          "checkpoint_delay=${FTCTL_PROFILE_XCOLO_CHECKPOINT_DELAY:-}"
      ftctl_state_set "${vm}" \
        "conversion_stage=handshake_complete" \
        "conversion_state=colo_running" \
        "protection_state=colo_running" \
        "transport_state=mirroring" \
        "active_side=primary" \
        "last_sync_ts=$(ftctl_now_iso8601)" \
        "last_error="
      ftctl_log_event "colo" "xcolo.runtime_reconcile" "ok" "${vm}" "" \
        "secondary_vm=${secondary_vm}"
      return 0
      ;;
    10)
      if ftctl_xcolo_candidate_observation_ready "${vm}"; then
        ftctl_xcolo_mark_candidate_observed "${vm}" "runtime_reconcile"
        ftctl_log_event "colo" "xcolo.runtime_reconcile" "pending" "${vm}" "" \
          "secondary_vm=${secondary_vm} reason=$(ftctl_state_get "${vm}" "xcolo_pending_reason" 2>/dev/null || true)"
      else
        ftctl_xcolo_mark_runtime_pending "${vm}" "runtime_converging"
        ftctl_state_set "${vm}" "last_healthy_ts=$(ftctl_now_iso8601)"
        ftctl_log_event "colo" "xcolo.runtime_reconcile" "pending" "${vm}" "" \
          "secondary_vm=${secondary_vm}"
      fi
      return 0
      ;;
    *)
      recover_reason="$(ftctl_state_get "${vm}" "last_error" 2>/dev/null || true)"
      [[ -n "${recover_reason}" ]] || recover_reason="xcolo_runtime_validation_failed"
      ftctl_xcolo_recover_runtime_convergence_failure "${vm}" "${recover_reason}" || true
      ftctl_state_set "${vm}" \
        "xcolo_last_runtime_error=${recover_reason}" \
        "last_error=${recover_reason}"
      ftctl_xcolo_preserve_runtime_error "${vm}"
      ftctl_log_event "colo" "xcolo.runtime_reconcile" "fail" "${vm}" "" \
        "secondary_vm=${secondary_vm} rc=${rc}"
      return 0
      ;;
  esac
}

ftctl_xcolo_wait_pair_running() {
  local vm="${1-}"
  local timeout="${2:-30}"
  local secondary_vm="${3:-$vm}"
  local i primary_running secondary_running

  for ((i=0; i<timeout; i++)); do
    primary_running=""
    secondary_running=""
    ftctl_xcolo_query_running_flag "${FTCTL_PROFILE_PRIMARY_URI}" "${vm}" primary_running || true
    ftctl_xcolo_query_running_flag "${FTCTL_PROFILE_SECONDARY_URI}" "${secondary_vm}" secondary_running || true
    if [[ "${primary_running}" == "true" && "${secondary_running}" == "true" ]]; then
      return 0
    fi
    sleep 1
  done
  return 1
}

ftctl_xcolo_prebuilt_secondary_stage() {
  local vm="${1-}"
  local nbd_host="${2-}"
  local nbd_port="${3-}"

  ftctl_xcolo_qmp_require_ok "${FTCTL_PROFILE_SECONDARY_URI}" "${vm}" \
    '{"execute":"qmp_capabilities"}' "colo" "secondary.qmp_capabilities" || return 1
  ftctl_xcolo_set_and_verify_migrate_capabilities "${FTCTL_PROFILE_SECONDARY_URI}" "${vm}" "${vm}" "secondary" "secondary" || return 1
  ftctl_xcolo_qmp_require_ok "${FTCTL_PROFILE_SECONDARY_URI}" "${vm}" \
    "{\"execute\":\"nbd-server-start\",\"arguments\":{\"addr\":{\"type\":\"inet\",\"data\":{\"host\":\"${nbd_host}\",\"port\":\"${nbd_port}\"}}}}" \
    "colo" "secondary.nbd_server_start" || return 1
  ftctl_xcolo_qmp_require_ok "${FTCTL_PROFILE_SECONDARY_URI}" "${vm}" \
    "{\"execute\":\"nbd-server-add\",\"arguments\":{\"device\":\"${FTCTL_PROFILE_XCOLO_PRIMARY_DISK_NODE}\",\"writable\":true}}" \
    "colo" "secondary.nbd_server_add" || return 1
}

ftctl_xcolo_prebuilt_primary_stage() {
  local vm="${1-}"
  local nbd_host="${2-}"
  local nbd_port="${3-}"

  ftctl_xcolo_qmp_require_ok "${FTCTL_PROFILE_PRIMARY_URI}" "${vm}" \
    '{"execute":"qmp_capabilities"}' "colo" "primary.qmp_capabilities" || return 1
  ftctl_xcolo_qmp_require_ok "${FTCTL_PROFILE_PRIMARY_URI}" "${vm}" \
    "{\"execute\":\"blockdev-add\",\"arguments\":{\"driver\":\"nbd\",\"node-name\":\"${FTCTL_PROFILE_XCOLO_NBD_NODE}\",\"server\":{\"type\":\"inet\",\"host\":\"${nbd_host}\",\"port\":\"${nbd_port}\"},\"export\":\"${FTCTL_PROFILE_XCOLO_PRIMARY_DISK_NODE}\",\"detect-zeroes\":\"on\"}}" \
    "colo" "primary.blockdev_add" || return 1
  ftctl_xcolo_qmp_require_ok "${FTCTL_PROFILE_PRIMARY_URI}" "${vm}" \
    "{\"execute\":\"x-blockdev-change\",\"arguments\":{\"parent\":\"${FTCTL_PROFILE_XCOLO_PARENT_BLOCK_NODE}\",\"node\":\"${FTCTL_PROFILE_XCOLO_NBD_NODE}\"}}" \
    "colo" "primary.x_blockdev_change" || return 1
  ftctl_xcolo_set_and_verify_migrate_capabilities "${FTCTL_PROFILE_PRIMARY_URI}" "${vm}" "${vm}" "primary" "primary" || return 1
  ftctl_xcolo_require_checkpoint_delay_before_migrate "${vm}" || return 1
  ftctl_xcolo_record_pre_migrate_evidence "${vm}" "on" || true
  ftctl_xcolo_preflight_firewall_contract "${vm}" || return 1
  ftctl_xcolo_qmp_require_ok "${FTCTL_PROFILE_PRIMARY_URI}" "${vm}" \
    "{\"execute\":\"migrate\",\"arguments\":{\"uri\":\"${FTCTL_PROFILE_XCOLO_MIGRATE_URI}\"}}" \
    "colo" "primary.migrate" || return 1
  ftctl_xcolo_activate_primary_filters_after_migrate "${vm}" "${vm}" || return 1
}

ftctl_xcolo_primary_domain_state() {
  local vm="${1-}"
  local out err rc

  out=""
  err=""
  rc=0
  ftctl_virsh "${FTCTL_XCOLO_QMP_TIMEOUT_SEC}" out err rc -- -c "${FTCTL_PROFILE_PRIMARY_URI}" domstate "${vm}" || true
  : "${err}"
  if [[ "${rc}" != "0" ]]; then
    printf '%s\n' "unknown"
    return 0
  fi
  printf '%s\n' "$(printf '%s' "${out}" | tr -d '\r' | xargs)"
}

ftctl_xcolo_local_record() {
  local out_var="${1}"
  local item=""
  ftctl_cluster_load || return 1
  ftctl_cluster_find_record_by_host_id "${FTCTL_LOCAL_HOST_ID}" item || return 1
  printf -v "${out_var}" '%s' "${item}"
}

ftctl_xcolo_primary_listen_host() {
  local port_hint="${1-}"
  local record="" host_id="" role="" mgmt_ip="" libvirt_uri="" blockcopy_ip="" xcolo_ctrl="" xcolo_data=""
  local peer_host="" peer_port="" out err rc
  if ftctl_xcolo_local_record record; then
    ftctl_cluster_parse_record "${record}" host_id role mgmt_ip libvirt_uri blockcopy_ip xcolo_ctrl xcolo_data
    case "${port_hint}" in
      control)
        if [[ -n "${xcolo_ctrl}" ]]; then
          printf '%s\n' "${xcolo_ctrl}"
          return 0
        fi
        ;;
      data)
        if [[ -n "${xcolo_data}" ]]; then
          printf '%s\n' "${xcolo_data}"
          return 0
        fi
        ;;
    esac
    if [[ -n "${mgmt_ip}" ]]; then
      printf '%s\n' "${mgmt_ip}"
      return 0
    fi
  fi

  ftctl_xcolo_parse_tcp_endpoint "${FTCTL_PROFILE_XCOLO_PROXY_ENDPOINT}" peer_host peer_port || true
  if [[ -n "${peer_host}" && "${peer_host}" != "0.0.0.0" ]]; then
    out=""
    err=""
    rc=0
    ftctl_cmd_run "${FTCTL_XCOLO_QMP_TIMEOUT_SEC}" out err rc -- ip route get "${peer_host}" || true
    if [[ "${rc}" == "0" ]]; then
      peer_host="$(awk '{for (i=1;i<=NF;i++) if ($i=="src" && i+1<=NF) {print $(i+1); exit}}' <<< "${out}")"
      if [[ -n "${peer_host}" ]]; then
        printf '%s\n' "${peer_host}"
        return 0
      fi
    fi
  fi

  printf '%s\n' "0.0.0.0"
}

ftctl_xcolo_xml_resolve_netdev_id() {
  local xml_path="${1-}"
  local role="${2-}"
  local vm="${3-}"
  local out_var="${4-}"
  local payload rc status netdev alias target model reason

  [[ -n "${xml_path}" && -f "${xml_path}" ]] || {
    ftctl_state_set "${vm}" \
      "xcolo_${role}_netdev_ready=no" \
      "xcolo_${role}_netdev_reason=xml_missing" \
      "last_error=xcolo_${role}_netdev_id_unresolved"
    return 1
  }
  command -v python3 >/dev/null 2>&1 || {
    ftctl_state_set "${vm}" \
      "xcolo_${role}_netdev_ready=no" \
      "xcolo_${role}_netdev_reason=python3_missing" \
      "last_error=xcolo_${role}_netdev_id_unresolved"
    return 1
  }

  payload="$(XML_PATH="${xml_path}" python3 - <<'PY'
import os
import re
import sys
import xml.etree.ElementTree as ET

xml_path = os.environ["XML_PATH"]

def local_name(tag):
    return tag.rsplit("}", 1)[-1] if "}" in tag else tag

def first_child(node, name):
    for child in list(node):
        if local_name(child.tag) == name:
            return child
    return None

try:
    tree = ET.parse(xml_path)
except Exception as exc:
    print("status=fail")
    print(f"reason=parse_failed:{exc}")
    raise SystemExit(0)

root = tree.getroot()
devices = first_child(root, "devices")
if devices is None:
    print("status=fail")
    print("reason=devices_missing")
    raise SystemExit(0)

interfaces = [child for child in list(devices) if local_name(child.tag) == "interface"]
if not interfaces:
    print("status=fail")
    print("reason=interface_missing")
    raise SystemExit(0)

chosen = None
for iface in interfaces:
    model = first_child(iface, "model")
    if model is not None and model.get("type") == "virtio":
        chosen = iface
        break
if chosen is None:
    chosen = interfaces[0]

idx = interfaces.index(chosen)
alias_node = first_child(chosen, "alias")
target_node = first_child(chosen, "target")
model_node = first_child(chosen, "model")
alias = alias_node.get("name", "") if alias_node is not None else ""
target = target_node.get("dev", "") if target_node is not None else ""
model = model_node.get("type", "") if model_node is not None else ""

netdev_idx = idx
match = re.fullmatch(r"net([0-9]+)", alias)
if match:
    netdev_idx = int(match.group(1))

print("status=ok")
print(f"netdev=hostnet{netdev_idx}")
print(f"alias={alias}")
print(f"target={target}")
print(f"model={model}")
print(f"index={idx}")
PY
)"
  rc=$?
  [[ "${rc}" == "0" ]] || payload=""

  status=""
  netdev=""
  alias=""
  target=""
  model=""
  reason=""
  while IFS= read -r line; do
    case "${line}" in
      status=*) status="${line#status=}" ;;
      netdev=*) netdev="${line#netdev=}" ;;
      alias=*) alias="${line#alias=}" ;;
      target=*) target="${line#target=}" ;;
      model=*) model="${line#model=}" ;;
      reason=*) reason="${line#reason=}" ;;
    esac
  done <<< "${payload}"

  if [[ "${status}" != "ok" || -z "${netdev}" ]]; then
    reason="${reason:-netdev_unresolved}"
    ftctl_state_set "${vm}" \
      "xcolo_${role}_netdev_ready=no" \
      "xcolo_${role}_netdev_reason=${reason}" \
      "last_error=xcolo_${role}_netdev_id_unresolved"
    ftctl_log_event "colo" "xcolo.${role}.netdev" "fail" "${vm}" "" \
      "reason=${reason} xml=${xml_path}"
    return 1
  fi

  ftctl_state_set "${vm}" \
    "xcolo_${role}_netdev_ready=yes" \
    "xcolo_${role}_netdev_id=${netdev}" \
    "xcolo_${role}_netdev_alias=${alias}" \
    "xcolo_${role}_netdev_target=${target}" \
    "xcolo_${role}_netdev_model=${model}" \
    "xcolo_${role}_netdev_reason="
  ftctl_log_event "colo" "xcolo.${role}.netdev" "ok" "${vm}" "" \
    "netdev=${netdev} alias=${alias:-none} target=${target:-none} model=${model:-unknown}"
  printf -v "${out_var}" '%s' "${netdev}"
}

ftctl_xcolo_build_primary_qemu_args() {
  local netdev_id="${1:-hostnet0}"
  local vm="${2:-${FTCTL_CURRENT_VM:-}}"
  local proxy_host proxy_port nbd_host nbd_port
  local mirror_port compare_port compare_local_port compare_out_port
  local mirror_wait compare_wait
  local vnet_hdr_arg=""

  [[ "${netdev_id}" =~ ^[A-Za-z0-9_.-]+$ ]] || netdev_id="hostnet0"
  if [[ -n "${vm}" ]]; then
    ftctl_xcolo_update_vnet_hdr_state "${vm}" || true
    vnet_hdr_arg="$(ftctl_xcolo_vnet_hdr_arg "${vm}")"
  fi
  ftctl_xcolo_parse_tcp_endpoint "${FTCTL_PROFILE_XCOLO_PROXY_ENDPOINT}" proxy_host proxy_port
  ftctl_xcolo_parse_tcp_endpoint "${FTCTL_PROFILE_XCOLO_NBD_ENDPOINT}" nbd_host nbd_port
  mirror_port="${FTCTL_XCOLO_MIRROR_PORT:-9003}"
  compare_port="${FTCTL_XCOLO_COMPARE_PORT:-9004}"
  compare_local_port="${FTCTL_XCOLO_COMPARE_LOCAL_PORT:-9001}"
  compare_out_port="${FTCTL_XCOLO_COMPARE_OUT_PORT:-9005}"
  mirror_wait="${FTCTL_XCOLO_MIRROR_WAIT:-off}"
  compare_wait="${FTCTL_XCOLO_COMPARE_WAIT:-on}"
  case "${mirror_wait}" in
    on|off) ;;
    *) mirror_wait="off" ;;
  esac
  case "${compare_wait}" in
    on|off) ;;
    *) compare_wait="on" ;;
  esac

  # Keep the primary COLO network topology in the generated QEMU startup
  # commandline. QMP remains a fallback only when startup markers are absent.
  printf '%s\n' "-S;-chardev;socket,id=mirror0,host=0.0.0.0,port=${mirror_port},server=on,wait=${mirror_wait};-chardev;socket,id=compare1,host=0.0.0.0,port=${compare_port},server=on,wait=${compare_wait};-chardev;socket,id=compare0,host=127.0.0.1,port=${compare_local_port},server=on,wait=off;-chardev;socket,id=compare0-0,host=127.0.0.1,port=${compare_local_port};-chardev;socket,id=compare_out,host=127.0.0.1,port=${compare_out_port},server=on,wait=off;-chardev;socket,id=compare_out0,host=127.0.0.1,port=${compare_out_port};-object;filter-mirror,id=m0,netdev=${netdev_id},queue=tx,outdev=mirror0,insert=behind,position=tail${vnet_hdr_arg};-object;filter-redirector,id=redire0,netdev=${netdev_id},queue=rx,indev=compare_out,insert=behind,position=tail${vnet_hdr_arg};-object;filter-redirector,id=redire1,netdev=${netdev_id},queue=rx,outdev=compare0,insert=behind,position=tail${vnet_hdr_arg};-object;colo-compare,id=comp0,primary_in=compare0-0,secondary_in=compare1,outdev=compare_out0,iothread=iothread1${vnet_hdr_arg}"
}

ftctl_xcolo_build_secondary_qemu_args() {
  local netdev_id="${1:-hostnet0}"
  local vm="${2:-${FTCTL_CURRENT_VM:-}}"
  local connect_ctrl connect_data proxy_host proxy_port nbd_host nbd_port
  local mirror_port compare_port
  local vnet_hdr_arg=""

  [[ "${netdev_id}" =~ ^[A-Za-z0-9_.-]+$ ]] || netdev_id="hostnet0"
  if [[ -n "${vm}" ]]; then
    ftctl_xcolo_update_vnet_hdr_state "${vm}" || true
    vnet_hdr_arg="$(ftctl_xcolo_vnet_hdr_arg "${vm}")"
  fi
  ftctl_xcolo_parse_tcp_endpoint "${FTCTL_PROFILE_XCOLO_PROXY_ENDPOINT}" proxy_host proxy_port
  ftctl_xcolo_parse_tcp_endpoint "${FTCTL_PROFILE_XCOLO_NBD_ENDPOINT}" nbd_host nbd_port
  connect_ctrl="$(ftctl_xcolo_primary_listen_host control)"
  connect_data="$(ftctl_xcolo_primary_listen_host data)"
  mirror_port="${FTCTL_XCOLO_MIRROR_PORT:-9003}"
  compare_port="${FTCTL_XCOLO_COMPARE_PORT:-9004}"

  # Match the QEMU COLO startup procedure: the secondary does not use -S during startup.
  printf '%s\n' "-chardev;socket,id=red0,host=${connect_ctrl},port=${mirror_port},reconnect-ms=1000;-chardev;socket,id=red1,host=${connect_data},port=${compare_port},reconnect-ms=1000;-object;filter-redirector,id=f1,netdev=${netdev_id},queue=tx,indev=red0${vnet_hdr_arg};-object;filter-redirector,id=f2,netdev=${netdev_id},queue=rx,outdev=red1${vnet_hdr_arg};-object;filter-rewriter,id=rew0,netdev=${netdev_id},queue=all${vnet_hdr_arg};-incoming;${FTCTL_PROFILE_XCOLO_MIGRATE_URI}"
}

ftctl_xcolo_doc_alignment_summary() {
  cat <<'EOF'
COLO startup alignment checklist
1. Primary startup:
   - mirror0 server wait=off
   - compare1 server wait=on
   - compare0 / compare0-0 / compare_out / compare_out0 loopback sockets
   - primary filter objects are attached by QMP after block graph readiness
   - root disk on if=ide quorum node
   - startup paused with -S
2. Secondary startup:
   - red0 / red1 reconnect sockets toward primary
   - filter-redirector / filter-rewriter objects present
   - parent0 / childs0 / colo-disk0 disk graph present
   - incoming migration URI present
   - no -S on secondary startup
3. Protect QMP sequence:
   - secondary qmp_capabilities
   - secondary migrate-set-capabilities x-colo
   - secondary nbd-server-start
   - secondary nbd-server-add for the COLO base/parent node
   - primary qmp_capabilities
   - primary blockdev-add nbd0
   - primary x-blockdev-change parent=colo-disk0 node=nbd0
   - primary migrate-set-capabilities x-colo
   - primary migrate
   - primary migrate-set-parameters x-checkpoint-delay after COLO starts
EOF
}

ftctl_xcolo_backup_prebuilt_pair_xml() {
  local vm="${1-}"
  local bundle_dir primary_xml standby_xml meta_file out err rc checksum persistence

  bundle_dir="$(ftctl_inventory_xml_backup_path "${vm}")"
  ftctl_ensure_dir "${bundle_dir}" "0755"
  primary_xml="${bundle_dir}/primary.xml"
  standby_xml="${bundle_dir}/standby.xml"
  meta_file="${bundle_dir}/meta"

  out=""
  err=""
  rc=0
  ftctl_virsh "${FTCTL_BLOCKCOPY_WAIT_TIMEOUT_SEC}" out err rc -- -c "${FTCTL_PROFILE_PRIMARY_URI}" dumpxml --security-info "${vm}" || true
  : "${err}"
  [[ "${rc}" == "0" ]] || return "${rc}"
  printf '%s\n' "${out}" > "${primary_xml}"

  out=""
  err=""
  rc=0
  ftctl_virsh "${FTCTL_BLOCKCOPY_WAIT_TIMEOUT_SEC}" out err rc -- -c "${FTCTL_PROFILE_SECONDARY_URI}" dumpxml --security-info "${vm}" || true
  : "${err}"
  [[ "${rc}" == "0" ]] || return "${rc}"
  printf '%s\n' "${out}" > "${standby_xml}"

  persistence="no"
  checksum=""
  if command -v sha256sum >/dev/null 2>&1; then
    checksum="$(sha256sum "${primary_xml}" | awk '{print $1}')"
  fi
  cat > "${meta_file}" <<EOF
vm=${vm}
primary_uri=${FTCTL_PROFILE_PRIMARY_URI}
secondary_uri=${FTCTL_PROFILE_SECONDARY_URI}
primary_xml=${primary_xml}
standby_xml=${standby_xml}
persistent=${persistence}
xml_sha256=${checksum}
EOF
  chmod 0644 "${primary_xml}" "${standby_xml}" "${meta_file}" 2>/dev/null || true
  ftctl_state_set "${vm}" \
    "xml_bundle_dir=${bundle_dir}" \
    "primary_xml_backup=${primary_xml}" \
    "standby_xml_seed=${standby_xml}" \
    "primary_persistence=${persistence}"
}

ftctl_xcolo_prepare_block_generated_xmls() {
  local vm="${1-}"
  local primary_xml_backup="${2-}"
  local standby_xml_seed="${3-}"
  local primary_source="${4-}"
  local secondary_dest="${5-}"
  local disk_format="${6-}"
  local primary_args="${7-}"
  local secondary_args="${8-}"
  local primary_disk_map="${9-}"
  local primary_disk_metadata="${10-}"
  local primary_generated_xml standby_generated_xml standby_vm_name disk_metadata=""

  ftctl_xcolo_prepare_block_generated_xmls_fail() {
    local reason="${1-}"
    local details="${2-}"
    [[ -n "${reason}" ]] || reason="xcolo_block_generated_xml_prepare_failed"
    ftctl_state_set "${vm}" "last_error=${reason}"
    ftctl_log_event "colo" "xcolo.prepare_block_generated_xmls" "fail" "${vm}" "" \
      "reason=${reason} ${details}"
    return 1
  }

  [[ -n "${primary_xml_backup}" && -f "${primary_xml_backup}" ]] || return 1
  [[ -n "${standby_xml_seed}" && -f "${standby_xml_seed}" ]] || return 1

  primary_generated_xml="$(ftctl_primary_generated_xml_path "${vm}")"
  standby_generated_xml="$(ftctl_standby_generated_xml_path "${vm}")"
  standby_vm_name="$(ftctl_profile_secondary_vm_name_resolved "${vm}")"

  ftctl_ensure_dir "$(dirname "${primary_generated_xml}")" "0755"
  ftctl_ensure_dir "$(dirname "${standby_generated_xml}")" "0755"

  cp -f "${primary_xml_backup}" "${primary_generated_xml}"
  cp -f "${standby_xml_seed}" "${standby_generated_xml}"

  ftctl_standby__rewrite_domain_name "${standby_generated_xml}" "${standby_vm_name}"

  ftctl_xml_remove_qemu_commandline "${primary_generated_xml}" || true
  ftctl_xml_remove_qemu_commandline "${standby_generated_xml}" || true
  if [[ -n "${primary_disk_map}" ]]; then
    ftctl_xml_rewrite_disk_map_block_runtime "${primary_generated_xml}" "${primary_disk_map}" "${disk_format}" "ro-shareable" "9" "${primary_disk_metadata}" ||
      ftctl_xcolo_prepare_block_generated_xmls_fail "xcolo_primary_disk_rewrite_failed" "path=${primary_generated_xml}" || return 1
  else
    ftctl_xml_rewrite_first_disk_block_runtime "${primary_generated_xml}" "${primary_source}" "${disk_format}" "ro-shareable" "9" ||
      ftctl_xcolo_prepare_block_generated_xmls_fail "xcolo_primary_disk_rewrite_failed" "path=${primary_generated_xml}" || return 1
  fi
  if [[ "${FTCTL_PROFILE_DISK_MAP}" == "auto" ]]; then
    ftctl_xml_rewrite_first_disk_block_runtime "${standby_generated_xml}" "${secondary_dest}" "${disk_format}" "rw" "9" ||
      ftctl_xcolo_prepare_block_generated_xmls_fail "xcolo_standby_disk_rewrite_failed" "path=${standby_generated_xml}" || return 1
  else
    ftctl_xcolo_disk_map_runtime_metadata "${FTCTL_PROFILE_DISK_MAP}" disk_metadata "${vm}" ||
      ftctl_xcolo_prepare_block_generated_xmls_fail "xcolo_standby_disk_metadata_failed" "path=${standby_generated_xml}" || return 1
    ftctl_xml_rewrite_disk_map_block_runtime "${standby_generated_xml}" "${FTCTL_PROFILE_DISK_MAP}" "${disk_format}" "rw" "9" "${disk_metadata}" ||
      ftctl_xcolo_prepare_block_generated_xmls_fail "xcolo_standby_disk_rewrite_failed" "path=${standby_generated_xml}" || return 1
    ftctl_xml_validate_disk_map_sources "${standby_generated_xml}" "${FTCTL_PROFILE_DISK_MAP}" ||
      ftctl_xcolo_prepare_block_generated_xmls_fail "xcolo_standby_disk_source_mismatch" "path=${standby_generated_xml}" || return 1
  fi
  ftctl_xml_apply_xcolo_network_runtime "${primary_generated_xml}" ||
    ftctl_xcolo_prepare_block_generated_xmls_fail "xcolo_primary_network_xml_failed" "path=${primary_generated_xml}" || return 1
  ftctl_xml_apply_xcolo_network_runtime "${standby_generated_xml}" ||
    ftctl_xcolo_prepare_block_generated_xmls_fail "xcolo_standby_network_xml_failed" "path=${standby_generated_xml}" || return 1
  ftctl_xml_apply_standby_host_runtime "${standby_generated_xml}" ||
    ftctl_xcolo_prepare_block_generated_xmls_fail "xcolo_standby_host_xml_failed" "path=${standby_generated_xml}" || return 1
  ftctl_xml_ensure_iothread_id "${primary_generated_xml}" "1" ||
    ftctl_xcolo_prepare_block_generated_xmls_fail "xcolo_primary_iothread_xml_failed" "path=${primary_generated_xml}" || return 1
  ftctl_xml_apply_qemu_commandline "${primary_generated_xml}" "${primary_args}" ||
    ftctl_xcolo_prepare_block_generated_xmls_fail "xcolo_primary_qemu_commandline_xml_failed" "path=${primary_generated_xml}" || return 1
  ftctl_xml_apply_qemu_commandline "${standby_generated_xml}" "${secondary_args}" ||
    ftctl_xcolo_prepare_block_generated_xmls_fail "xcolo_standby_qemu_commandline_xml_failed" "path=${standby_generated_xml}" || return 1
  ftctl_xml_validate_unique_disk_targets "${primary_generated_xml}" ||
    ftctl_xcolo_prepare_block_generated_xmls_fail "xcolo_primary_disk_targets_xml_failed" "path=${primary_generated_xml}" || return 1
  ftctl_xml_validate_unique_disk_targets "${standby_generated_xml}" ||
    ftctl_xcolo_prepare_block_generated_xmls_fail "xcolo_standby_disk_targets_xml_failed" "path=${standby_generated_xml}" || return 1
  ftctl_xml_validate_xcolo_iothread_contract "${primary_generated_xml}" ||
    ftctl_xcolo_prepare_block_generated_xmls_fail "xcolo_primary_iothread_contract_failed" "path=${primary_generated_xml}" || return 1

  ftctl_state_set "${vm}" \
    "primary_xml_generated=${primary_generated_xml}" \
    "standby_xml_generated=${standby_generated_xml}" \
    "secondary_vm_name=${standby_vm_name}"
}

ftctl_xcolo_block_runtime_dir() {
  local vm="${1-}"
  printf '%s\n' "${FTCTL_BLOCKCOPY_TARGET_BASE_DIR}/$(ftctl_state_vm_key "${vm}")/xcolo"
}

ftctl_xcolo_disk_suffix() {
  local target="${1-}"
  target="${target:-root}"
  printf '%s\n' "${target}" | sed 's/[^A-Za-z0-9_.-]/_/g'
}

ftctl_xcolo_primary_active_overlay_path() {
  local vm="${1-}"
  local target="${2-}" suffix
  if [[ -z "${target}" ]]; then
    printf '%s\n' "$(ftctl_xcolo_block_runtime_dir "${vm}")/primary-active.qcow2"
    return 0
  fi
  suffix="$(ftctl_xcolo_disk_suffix "${target}")"
  printf '%s\n' "$(ftctl_xcolo_block_runtime_dir "${vm}")/primary-active-${suffix}.qcow2"
}

ftctl_xcolo_secondary_hidden_overlay_path() {
  local vm="${1-}"
  local target="${2-}" suffix
  if [[ -z "${target}" ]]; then
    printf '%s\n' "$(ftctl_xcolo_block_runtime_dir "${vm}")/secondary-hidden.qcow2"
    return 0
  fi
  suffix="$(ftctl_xcolo_disk_suffix "${target}")"
  printf '%s\n' "$(ftctl_xcolo_block_runtime_dir "${vm}")/secondary-hidden-${suffix}.qcow2"
}

ftctl_xcolo_secondary_active_overlay_path() {
  local vm="${1-}"
  local target="${2-}" suffix
  if [[ -z "${target}" ]]; then
    printf '%s\n' "$(ftctl_xcolo_block_runtime_dir "${vm}")/secondary-active.qcow2"
    return 0
  fi
  suffix="$(ftctl_xcolo_disk_suffix "${target}")"
  printf '%s\n' "$(ftctl_xcolo_block_runtime_dir "${vm}")/secondary-active-${suffix}.qcow2"
}

ftctl_xcolo_prepare_primary_overlay() {
  local vm="${1-}"
  local target="${2-}"
  local size_bytes="${3-}"
  local path current_size=""
  if [[ -z "${size_bytes}" ]]; then
    size_bytes="${target}"
    target=""
  fi
  path="$(ftctl_xcolo_primary_active_overlay_path "${vm}" "${target}")"
  ftctl_ensure_dir "$(dirname "${path}")" "0755"
  [[ -n "${size_bytes}" ]] || return 1
  if [[ -f "${path}" ]]; then
    current_size="$(ftctl_xcolo_disk_virtual_size_bytes "${path}" 2>/dev/null || true)"
  fi
  if [[ ! -f "${path}" || "${current_size}" != "${size_bytes}" ]]; then
    rm -f -- "${path}" 2>/dev/null || true
    qemu-img create -f qcow2 "${path}" "${size_bytes}" >/dev/null || return 1
  fi
  printf '%s\n' "${path}"
}

ftctl_xcolo_prepare_secondary_overlays() {
  local vm="${1-}"
  local target="${2-}"
  local size_bytes="${3-}"
  local host user dir hidden active remote_cmd out err rc

  if [[ -z "${size_bytes}" ]]; then
    size_bytes="${target}"
    target=""
  fi

  ftctl_blockcopy_remote_target_host_user host user || return 1
  dir="$(ftctl_xcolo_block_runtime_dir "${vm}")"
  hidden="$(ftctl_xcolo_secondary_hidden_overlay_path "${vm}" "${target}")"
  active="$(ftctl_xcolo_secondary_active_overlay_path "${vm}" "${target}")"
  [[ -n "${size_bytes}" ]] || return 1
  remote_cmd="$(cat <<EOF
set -euo pipefail
mkdir -p '${dir}'
current_hidden=""
current_active=""
if [[ -f '${hidden}' ]]; then
  current_hidden="\$(qemu-img info --output=json '${hidden}' | python3 -c 'import json,sys; print(json.load(sys.stdin).get(\"virtual-size\",\"\"))' 2>/dev/null || true)"
fi
if [[ -f '${active}' ]]; then
  current_active="\$(qemu-img info --output=json '${active}' | python3 -c 'import json,sys; print(json.load(sys.stdin).get(\"virtual-size\",\"\"))' 2>/dev/null || true)"
fi
if [[ ! -f '${hidden}' || "\${current_hidden}" != '${size_bytes}' ]]; then
  rm -f -- '${hidden}' >/dev/null 2>&1 || true
  qemu-img create -f qcow2 '${hidden}' '${size_bytes}' >/dev/null
fi
if [[ ! -f '${active}' || "\${current_active}" != '${size_bytes}' ]]; then
  rm -f -- '${active}' >/dev/null 2>&1 || true
  qemu-img create -f qcow2 '${active}' '${size_bytes}' >/dev/null
fi
EOF
)"
  out=""
  err=""
  rc=0
  ftctl_blockcopy_remote_exec "${host}" "${user}" out err rc "${remote_cmd}" || true
  : "${out}${err}"
  [[ "${rc}" == "0" ]] || return 1
  printf '%s|%s\n' "${hidden}" "${active}"
}

ftctl_xcolo_disk_map_infer_cloud_managed_rbd_metadata() {
  local disk_map="${1-}"
  local out_var="${2}"
  local vm="${3-}"
  local entry target path layout symmetry metadata=""
  local -a entries=()

  [[ "${FTCTL_PROFILE_PROVISIONING_BACKEND:-}" == "cloud-managed" ]] || return 1
  [[ -n "${disk_map}" && "${disk_map}" != "auto" ]] || return 1

  IFS=';' read -r -a entries <<<"${disk_map}"
  [[ "${#entries[@]}" -gt 0 ]] || return 1
  symmetry="$(ftctl_state_get "${vm}" "xcolo_storage_symmetry" 2>/dev/null || true)"

  for entry in "${entries[@]}"; do
    [[ -n "${entry}" ]] || continue
    [[ "${entry}" == *"="* ]] || return 1
    target="${entry%%=*}"
    path="${entry#*=}"
    target="$(printf '%s' "${target}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    path="$(printf '%s' "${path}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    [[ -n "${target}" && -n "${path}" ]] || return 1
    [[ "${path}" == /dev/rbd/* ]] || return 1

    layout="$(ftctl_state_get "${vm}" "xcolo_disk_${target}_secondary_layout" 2>/dev/null || true)"
    if [[ "${layout}" != "block/raw" && "${symmetry}" != "ok" ]]; then
      return 1
    fi
    metadata="${metadata}${metadata:+;}${target}=${path}|raw|dev|block"
  done

  [[ -n "${metadata}" ]] || return 1
  printf -v "${out_var}" '%s' "${metadata}"
}

ftctl_xcolo_disk_map_runtime_metadata() {
  local disk_map="${1-}"
  local out_var="${2}"
  local vm="${3-}"
  local host="" user="" out="" err="" rc=0 remote_cmd="" q_disk_map=""

  [[ -n "${disk_map}" && "${disk_map}" != "auto" ]] || return 1
  if [[ -n "${FTCTL_PROFILE_XCOLO_DISK_MAP_METADATA:-}" ]]; then
    printf -v "${out_var}" '%s' "${FTCTL_PROFILE_XCOLO_DISK_MAP_METADATA}"
    return 0
  fi
  if ftctl_xcolo_disk_map_infer_cloud_managed_rbd_metadata "${disk_map}" "${out_var}" "${vm}"; then
    return 0
  fi

  ftctl_blockcopy_remote_target_host_user host user || return 1
  printf -v q_disk_map '%q' "${disk_map}"
  remote_cmd="$(cat <<EOF
set -euo pipefail
disk_map=${q_disk_map}
python3 - <<'PY' "\${disk_map}"
import shlex
import subprocess
import sys

disk_map = sys.argv[1]
entries = [entry for entry in disk_map.split(";") if entry]
for entry in entries:
    if "=" not in entry:
        raise SystemExit(f"invalid disk map entry: {entry}")
    target, path = entry.split("=", 1)
    if not target or not path:
        raise SystemExit(f"invalid disk map entry: {entry}")

    info = subprocess.run(
        ["qemu-img", "info", "--force-share", "--output=json", path],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if info.returncode != 0:
        sys.stderr.write(info.stderr)
        raise SystemExit(info.returncode)
    fmt = subprocess.run(
        ["python3", "-c", "import json,sys; print(json.load(sys.stdin).get('format',''))"],
        input=info.stdout,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if fmt.returncode != 0:
        sys.stderr.write(fmt.stderr)
        raise SystemExit(fmt.returncode)
    disk_format = fmt.stdout.strip() or "raw"

    stat = subprocess.run(["test", "-b", path])
    if stat.returncode == 0:
        disk_type = "block"
        source_attr = "dev"
    else:
        disk_type = "file"
        source_attr = "file"
    print(f"{target}={path}|{disk_format}|{source_attr}|{disk_type}")
PY
EOF
)"
  ftctl_blockcopy_remote_exec "${host}" "${user}" out err rc "${remote_cmd}" || true
  if [[ "${rc}" != "0" ]]; then
    echo "ERROR: remote disk image metadata probe failed: ${err}" >&2
    return "${rc}"
  fi
  out="$(printf '%s\n' "${out}" | sed '/^[[:space:]]*$/d' | paste -sd ';' -)"
  [[ -n "${out}" ]] || return 1
  printf -v "${out_var}" '%s' "${out}"
}

ftctl_xcolo_disk_virtual_size_bytes() {
  local path="${1-}"
  local out err rc
  out=""
  err=""
  rc=0
  ftctl_cmd_run "${FTCTL_BLOCKCOPY_WAIT_TIMEOUT_SEC}" out err rc -- qemu-img info --force-share --output=json "${path}" || true
  : "${err}"
  if [[ "${rc}" != "0" || -z "${out}" ]]; then
    return 1
  fi
  python3 - <<'PY' "${out}"
import json, sys
data = json.loads(sys.argv[1])
print(data.get("virtual-size", ""))
PY
}

ftctl_xcolo_collect_block_disk_plan() {
  local vm="${1-}"
  local plan_var="${2}"
  local primary_map_var="${3}"
  local primary_metadata_var="${4}"
  local disks=()
  local plan="" primary_map="" primary_metadata=""
  local entry rest target source format dtype secondary_dest source_attr disk_type

  ftctl_inventory_collect_vm_disks_detailed "${vm}" disks || return 1
  for entry in "${disks[@]}"; do
    target="${entry%%|*}"
    rest="${entry#*|}"
    source="${rest%%|*}"
    rest="${rest#*|}"
    format="${rest%%|*}"
    dtype="${rest##*|}"
    [[ -n "${format}" ]] || format="raw"
    secondary_dest="$(ftctl_profile_lookup_map_value "${FTCTL_PROFILE_DISK_MAP}" "${target}" 2>/dev/null || true)"
    if [[ -z "${secondary_dest}" ]]; then
      ftctl_log_event "colo" "xcolo.protect.block_cold_conversion" "fail" "${vm}" "" \
        "reason=secondary_dest_missing target=${target}"
      return 1
    fi
    case "${dtype}" in
      block)
        source_attr="dev"
        disk_type="block"
        ;;
      file)
        source_attr="file"
        disk_type="file"
        ;;
      *)
        ftctl_log_event "colo" "xcolo.protect.block_cold_conversion" "fail" "${vm}" "" \
          "reason=unsupported_disk_type target=${target} type=${dtype}"
        return 1
        ;;
    esac
    plan+="${plan:+;}${target}|${source}|${format}|${dtype}|${secondary_dest}"
    primary_map+="${primary_map:+;}${target}=${source}"
    primary_metadata+="${primary_metadata:+;}${target}=${source}|${format}|${source_attr}|${disk_type}"
  done

  [[ -n "${plan}" ]] || return 1
  printf -v "${plan_var}" '%s' "${plan}"
  printf -v "${primary_map_var}" '%s' "${primary_map}"
  printf -v "${primary_metadata_var}" '%s' "${primary_metadata}"
}

ftctl_xcolo_record_storage_symmetry() {
  local vm="${1-}"
  local plan="${2-}"
  local entry rest target primary_source primary_format primary_dtype secondary_dest
  local secondary_layout primary_layout=""
  local layouts="" secondary_layouts="" symmetry="ok" reason=""
  local suffix result="ok"
  local -a _ftctl_xcolo_symmetry_entries=()

  [[ -n "${vm}" && -n "${plan}" ]] || return 1
  IFS=';' read -r -a _ftctl_xcolo_symmetry_entries <<< "${plan}"
  for entry in "${_ftctl_xcolo_symmetry_entries[@]}"; do
    [[ -n "${entry}" ]] || continue
    target="${entry%%|*}"
    rest="${entry#*|}"
    primary_source="${rest%%|*}"
    rest="${rest#*|}"
    primary_format="${rest%%|*}"
    rest="${rest#*|}"
    primary_dtype="${rest%%|*}"
    secondary_dest="${rest#*|}"
    [[ -n "${primary_format}" ]] || primary_format="raw"
    case "${secondary_dest}" in
      /dev/*) secondary_layout="block/raw" ;;
      *) secondary_layout="file/qcow2" ;;
    esac
    primary_layout="${primary_dtype}/${primary_format}"
    layouts="${layouts}${layouts:+,}${target}:${primary_layout}"
    secondary_layouts="${secondary_layouts}${secondary_layouts:+,}${target}:${secondary_layout}"
    suffix="$(ftctl_xcolo_disk_suffix "${target}")"
    ftctl_state_set "${vm}" \
      "xcolo_disk_${suffix}_primary_layout=${primary_layout}" \
      "xcolo_disk_${suffix}_secondary_layout=${secondary_layout}" \
      "xcolo_disk_${suffix}_primary_source=${primary_source}" \
      "xcolo_disk_${suffix}_secondary_dest=${secondary_dest}"
    if [[ "${primary_layout}" != "${secondary_layout}" ]]; then
      symmetry="warning"
      reason="${reason}${reason:+,}${target}:primary_${primary_layout}_secondary_${secondary_layout}"
    fi
  done

  ftctl_state_set "${vm}" \
    "xcolo_storage_primary_layouts=${layouts}" \
    "xcolo_storage_secondary_layouts=${secondary_layouts}" \
    "xcolo_storage_symmetry=${symmetry}" \
    "xcolo_storage_symmetry_reason=${reason}"
  [[ "${symmetry}" == "warning" ]] && result="warn"
  ftctl_log_event "colo" "xcolo.storage_symmetry" "${result}" "${vm}" "" \
    "primary=${layouts} secondary=${secondary_layouts} reason=${reason}"
  return 0
}

ftctl_xcolo_storage_symmetry_strict_enabled() {
  case "${FTCTL_XCOLO_ALLOW_STORAGE_MISMATCH:-0}" in
    1|true|yes|on) return 1 ;;
    *) return 0 ;;
  esac
}

ftctl_xcolo_require_storage_symmetry() {
  local vm="${1-}"
  local symmetry reason primary_layouts secondary_layouts

  [[ -n "${vm}" ]] || return 1
  symmetry="$(ftctl_state_get "${vm}" "xcolo_storage_symmetry" 2>/dev/null || true)"
  reason="$(ftctl_state_get "${vm}" "xcolo_storage_symmetry_reason" 2>/dev/null || true)"
  primary_layouts="$(ftctl_state_get "${vm}" "xcolo_storage_primary_layouts" 2>/dev/null || true)"
  secondary_layouts="$(ftctl_state_get "${vm}" "xcolo_storage_secondary_layouts" 2>/dev/null || true)"

  if [[ "${symmetry}" != "warning" ]]; then
    ftctl_log_event "colo" "xcolo.storage_compatibility" "ok" "${vm}" "" \
      "symmetry=${symmetry:-unknown} primary=${primary_layouts} secondary=${secondary_layouts}"
    return 0
  fi

  if ! ftctl_xcolo_storage_symmetry_strict_enabled; then
    ftctl_state_set "${vm}" \
      "xcolo_storage_compatibility=experimental" \
      "xcolo_storage_mismatch_override=true"
    ftctl_log_event "colo" "xcolo.storage_compatibility" "warn" "${vm}" "" \
      "override=FTCTL_XCOLO_ALLOW_STORAGE_MISMATCH reason=${reason} primary=${primary_layouts} secondary=${secondary_layouts}"
    return 0
  fi

  ftctl_state_set "${vm}" \
    "xcolo_storage_compatibility=blocked" \
    "xcolo_storage_mismatch_override=false" \
    "protection_state=error" \
    "transport_state=planned" \
    "conversion_stage=storage_compatibility_failed" \
    "conversion_state=error" \
    "last_error=xcolo_storage_backend_mismatch"
  ftctl_log_event "colo" "xcolo.storage_compatibility" "fail" "${vm}" "" \
    "reason=${reason} primary=${primary_layouts} secondary=${secondary_layouts}"
  return 1
}

ftctl_xcolo_remote_disk_virtual_size_bytes() {
  local host="${1-}"
  local user="${2-}"
  local path="${3-}"
  local out="" err="" rc=0 cmd=""

  cmd="$(cat <<EOF
set -euo pipefail
qemu-img info --force-share --output=json $(printf '%q' "${path}") | python3 -c 'import json,sys; print(json.load(sys.stdin).get("virtual-size",""))'
EOF
)"
  ftctl_blockcopy_remote_exec "${host}" "${user}" out err rc "${cmd}" || true
  : "${err}"
  [[ "${rc}" == "0" ]] || return 1
  printf '%s\n' "$(printf '%s' "${out}" | tr -d '\r' | xargs)"
}

ftctl_xcolo_primary_connect_host() {
  local host="" record="" host_id="" role="" mgmt_ip="" libvirt_uri="" blockcopy_ip="" xcolo_ctrl="" xcolo_data=""

  host="$(ftctl_xcolo_primary_listen_host data 2>/dev/null || true)"
  if [[ -n "${host}" && "${host}" != "0.0.0.0" ]]; then
    printf '%s\n' "${host}"
    return 0
  fi

  if ftctl_xcolo_local_record record 2>/dev/null; then
    ftctl_cluster_parse_record "${record}" host_id role mgmt_ip libvirt_uri blockcopy_ip xcolo_ctrl xcolo_data
    : "${host_id}${role}${libvirt_uri}${blockcopy_ip}${xcolo_ctrl}"
    if [[ -n "${xcolo_data}" ]]; then
      printf '%s\n' "${xcolo_data}"
      return 0
    fi
    if [[ -n "${mgmt_ip}" ]]; then
      printf '%s\n' "${mgmt_ip}"
      return 0
    fi
  fi

  hostname -I 2>/dev/null | awk '{print $1; exit}'
}

ftctl_xcolo_baseline_seed_port() {
  local vm="${1-}"
  local target="${2-}"
  local out_var="${3}"
  local seed offset base count

  base="${FTCTL_REMOTE_NBD_PORT_BASE:-10809}"
  count="${FTCTL_REMOTE_NBD_PORT_COUNT:-64}"
  seed="$(printf '%s:xcolo-seed:%s' "${vm}" "${target}" | cksum | awk '{print $1}')"
  offset=$((seed % count))
  printf -v "${out_var}" '%s' "$((base + count + offset))"
}

ftctl_xcolo_stop_seed_nbd() {
  local pid_file="${1-}"
  local export_name="${2-}"
  local pid=""
  local stale_pid=""
  local proc_cmd="" cmdline=""

  if [[ -n "${pid_file}" ]]; then
    pid="$(cat "${pid_file}" 2>/dev/null || true)"
    if [[ -n "${pid}" && "${pid}" =~ ^[0-9]+$ ]]; then
      kill "${pid}" >/dev/null 2>&1 || true
    fi
    rm -f -- "${pid_file}" 2>/dev/null || true
  fi

  [[ -n "${export_name}" ]] || return 0
  for proc_cmd in /proc/[0-9]*/cmdline; do
    [[ -r "${proc_cmd}" ]] || continue
    stale_pid="${proc_cmd#/proc/}"
    stale_pid="${stale_pid%%/*}"
    [[ -n "${stale_pid}" && "${stale_pid}" =~ ^[0-9]+$ ]] || continue
    [[ "${stale_pid}" != "$$" ]] || continue
    cmdline="$(tr '\0' ' ' < "${proc_cmd}" 2>/dev/null || true)"
    [[ "${cmdline}" == *qemu-nbd* ]] || continue
    [[ "${cmdline}" == *"--export-name ${export_name}"* ]] || continue
    kill "${stale_pid}" >/dev/null 2>&1 || true
  done
}

ftctl_xcolo_compact_log_value() {
  printf '%s' "${1-}" | tr '\r\n\t ' '____' | cut -c1-500
}

ftctl_xcolo_prepare_baseline_seed_source() {
  local vm="${1-}"
  local target="${2-}"
  local source="${3-}"
  local source_format="${4-raw}"
  local out="" err="" rc=0 map_msg="" info_msg="" source_kind="file"

  [[ -n "${vm}" && -n "${target}" && -n "${source}" ]] || return 1
  [[ -n "${source_format}" ]] || source_format="raw"

  if ftctl_blockcopy_is_krbd_path "${source}"; then
    source_kind="krbd"
    map_msg="$(ftctl_blockcopy_krbd_map_local "${source}" 2>&1)" || {
      ftctl_log_event "colo" "block_conversion.baseline_seed.source_ready" "fail" "${vm}" "" \
        "target=${target} source=${source} source_kind=${source_kind} reason=krbd_map_failed error=$(ftctl_xcolo_compact_log_value "${map_msg}")"
      return 1
    }
  elif [[ "${source}" == /dev/* ]]; then
    source_kind="block"
  fi

  ftctl_cmd_run "${FTCTL_XCOLO_QMP_TIMEOUT_SEC:-3}" out err rc -- test -e "${source}" || true
  if [[ "${rc}" != "0" ]]; then
    ftctl_log_event "colo" "block_conversion.baseline_seed.source_ready" "fail" "${vm}" "${rc}" \
      "target=${target} source=${source} source_kind=${source_kind} reason=source_missing error=$(ftctl_xcolo_compact_log_value "${err:-${out}}")"
    return 1
  fi

  out=""
  err=""
  rc=0
  ftctl_cmd_run "${FTCTL_XCOLO_QMP_TIMEOUT_SEC:-3}" out err rc -- \
    qemu-img info --force-share --output=json "${source}" || true
  if [[ "${rc}" != "0" ]]; then
    ftctl_log_event "colo" "block_conversion.baseline_seed.source_ready" "fail" "${vm}" "${rc}" \
      "target=${target} source=${source} source_kind=${source_kind} reason=qemu_img_info_failed error=$(ftctl_xcolo_compact_log_value "${err:-${out}}")"
    return 1
  fi

  info_msg="$(ftctl_xcolo_compact_log_value "${out}")"
  ftctl_log_event "colo" "block_conversion.baseline_seed.source_ready" "ok" "${vm}" "" \
    "target=${target} source=${source} source_kind=${source_kind} source_format=${source_format} info=${info_msg}"
}

ftctl_xcolo_baseline_seed_retry_delay() {
  local attempt="${1:-1}"
  case "${attempt}" in
    1) printf '%s\n' "${FTCTL_XCOLO_BASELINE_SEED_RETRY_DELAY_1_SEC:-5}" ;;
    2) printf '%s\n' "${FTCTL_XCOLO_BASELINE_SEED_RETRY_DELAY_2_SEC:-15}" ;;
    *) printf '%s\n' "${FTCTL_XCOLO_BASELINE_SEED_RETRY_DELAY_3_SEC:-30}" ;;
  esac
}

ftctl_xcolo_baseline_seed_is_ssh_failure() {
  local rc="${1-}"
  local detail="${2-}"
  [[ "${rc}" == "255" ]] && return 0
  printf '%s' "${detail}" | grep -Eiq \
    'ssh_transport|MaxStartups|Connection (closed|reset|refused|timed out)|kex_exchange_identification|Broken pipe|No route to host|Could not resolve hostname|Permission denied|Host key verification failed'
}

ftctl_xcolo_baseline_seed_cleanup_remote_tmp() {
  local host="${1-}"
  local user="${2-}"
  local dest="${3-}"
  local q_dest="" out="" err="" rc=0 remote_cmd=""

  [[ -n "${host}" && -n "${dest}" ]] || return 0
  [[ "${dest}" != /dev/* ]] || return 0
  printf -v q_dest '%q' "${dest}"
  remote_cmd="$(cat <<EOF
set -euo pipefail
dest=${q_dest}
rm -f -- "\${dest}".ftctl-seed.* >/dev/null 2>&1 || true
EOF
)"
  ftctl_blockcopy_remote_exec "${host}" "${user}" out err rc "${remote_cmd}" || true
  : "${out}${err}${rc}"
}

ftctl_xcolo_seed_secondary_baseline_disk() {
  local vm="${1-}"
  local target="${2-}"
  local source="${3-}"
  local source_format="${4-raw}"
  local secondary_dest="${5-}"
  local expected_size="${6-}"
  local suffix primary_host port export_name pid_file src_uri target_format
  local remote_host="" remote_user="" remote_cmd="" out="" err="" rc=0
  local q_src_uri q_dest q_target_format q_source_format q_expected_size
  local q_target q_cloud_managed
  local timeout_sec saved_timeout firewall_added="0" bind_host
  local attempts attempt detail retry_delay last_failure_class

  [[ -n "${vm}" && -n "${target}" && -n "${source}" && -n "${secondary_dest}" ]] || return 1
  [[ -n "${source_format}" ]] || source_format="raw"
  suffix="$(ftctl_xcolo_disk_suffix "${target}")"
  primary_host="$(ftctl_xcolo_primary_connect_host)"
  [[ -n "${primary_host}" ]] || return 1
  bind_host="${primary_host}"
  ftctl_xcolo_baseline_seed_port "${vm}" "${target}" port
  export_name="ftctl-xcolo-seed-${vm}-${suffix}"
  pid_file="${FTCTL_RUN_DIR}/xcolo-seed-${vm}-${suffix}.pid"
  src_uri="$(ftctl_blockcopy_remote_nbd_uri "${primary_host}" "${port}" "${export_name}")"
  ftctl_blockcopy_remote_nbd_target_format "${secondary_dest}" "${source_format}" target_format
  ftctl_blockcopy_remote_target_host_user remote_host remote_user || return 1

  ftctl_log_event "colo" "block_conversion.baseline_seed.start" "ok" "${vm}" "" \
    "target=${target} source=${source} secondary_dest=${secondary_dest} source_format=${source_format} target_format=${target_format} primary_host=${primary_host} port=${port}"

  ftctl_xcolo_stop_seed_nbd "${pid_file}" "${export_name}"
  ftctl_xcolo_prepare_baseline_seed_source "${vm}" "${target}" "${source}" "${source_format}" || {
    ftctl_state_set "${vm}" "last_error=xcolo_baseline_source_not_ready:${target}"
    return 1
  }

  if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld 2>/dev/null; then
    firewall-cmd --quiet --add-port="${port}/tcp" >/dev/null 2>&1 && firewall_added="1"
  fi

  out=""
  err=""
  rc=0
  ftctl_cmd_run "${FTCTL_XCOLO_QMP_TIMEOUT_SEC:-3}" out err rc -- \
    qemu-nbd --fork --persistent --read-only --shared=8 \
      --bind "${bind_host}" \
      --port "${port}" \
      --export-name "${export_name}" \
      --format "${source_format}" \
      --pid-file "${pid_file}" \
      "${source}" || true
  if [[ "${rc}" != "0" ]]; then
    if [[ "${firewall_added}" == "1" ]]; then
      firewall-cmd --quiet --remove-port="${port}/tcp" >/dev/null 2>&1 || true
    fi
    ftctl_log_event "colo" "block_conversion.baseline_seed.nbd_start" "fail" "${vm}" "${rc}" \
      "target=${target} source=${source} port=${port} export=${export_name} error=$(ftctl_xcolo_compact_log_value "${err:-${out}}")"
    ftctl_state_set "${vm}" "last_error=xcolo_baseline_nbd_start_failed:${target}"
    return 1
  fi
  ftctl_log_event "colo" "block_conversion.baseline_seed.nbd_start" "ok" "${vm}" "" \
    "target=${target} uri=${src_uri}"

  printf -v q_src_uri '%q' "${src_uri}"
  printf -v q_dest '%q' "${secondary_dest}"
  printf -v q_target_format '%q' "${target_format}"
  printf -v q_source_format '%q' "raw"
  printf -v q_expected_size '%q' "${expected_size}"
  printf -v q_target '%q' "${target}"
  printf -v q_cloud_managed '%q' "${FTCTL_PROFILE_PROVISIONING_BACKEND:-}"
  remote_cmd="$(cat <<EOF
set -euo pipefail
src_uri=${q_src_uri}
dest=${q_dest}
target=${q_target}
target_format=${q_target_format}
source_format=${q_source_format}
expected_size=${q_expected_size}
provisioning_backend=${q_cloud_managed}
seed_dest="\${dest}"
mapped_device=""
mapped_by_ftctl=0
if [[ "\${provisioning_backend}" == "cloud-managed" && "\${dest}" == /dev/rbd/* ]]; then
  rest="\${dest#/dev/rbd/}"
  pool="\${rest%%/*}"
  image="\${rest#*/}"
  if [[ -z "\${pool}" || -z "\${image}" || "\${pool}" == "\${image}" ]]; then
    echo "baseline_rbd_path_invalid:\${target}:\${dest}" >&2
    exit 97
  fi
  if [[ ! -b "\${dest}" ]]; then
    rbd_ref="\${pool}/\${image}"
    map_out="\$(rbd map "\${rbd_ref}" 2>&1)" || {
      map_rc="\$?"
      echo "baseline_rbd_map_failed:\${target}:\${rbd_ref}:rc=\${map_rc}:\${map_out}" >&2
      exit 97
    }
    mapped_by_ftctl=1
    mapped_device="\$(printf '%s\n' "\${map_out}" | tail -n1)"
    if [[ -b "\${dest}" ]]; then
      seed_dest="\${dest}"
      mapped_device="\${dest}"
    elif [[ -n "\${mapped_device}" && -b "\${mapped_device}" ]]; then
      seed_dest="\${mapped_device}"
    else
      mapped_device="\$(rbd device list --format json 2>/dev/null | python3 -c 'import json,sys; pool=sys.argv[1]; image=sys.argv[2]; data=json.load(sys.stdin); print(next((str(item.get("device","")) for item in data if str(item.get("pool","")) == pool and str(item.get("name","")) == image), ""))' "\${pool}" "\${image}")"
      if [[ -n "\${mapped_device}" && -b "\${mapped_device}" ]]; then
        seed_dest="\${mapped_device}"
      fi
    fi
  fi
  if [[ ! -b "\${seed_dest}" ]]; then
    echo "baseline_rbd_device_missing:\${target}:\${dest}:mapped=\${mapped_device}" >&2
    if [[ "\${mapped_by_ftctl}" == "1" && -n "\${mapped_device}" ]]; then
      rbd unmap "\${mapped_device}" >/dev/null 2>&1 || true
    fi
    exit 98
  fi
  if [[ "\${mapped_by_ftctl}" == "1" && -n "\${mapped_device}" ]]; then
    trap 'rbd unmap "\${mapped_device}" >/dev/null 2>&1 || true' EXIT
  fi
elif [[ ! -e "\${dest}" ]]; then
  echo "baseline_target_missing:\${target}:\${dest}" >&2
  exit 95
fi
if [[ "\${dest}" == /dev/* ]]; then
  qemu-img convert -p -f "\${source_format}" -O "\${target_format}" "\${src_uri}" "\${seed_dest}"
  info="\$(qemu-img info --force-share --output=json "\${seed_dest}" | python3 -c 'import json,sys; d=json.load(sys.stdin); print("format=%s virtual=%s actual=%s" % (d.get("format",""), d.get("virtual-size",""), d.get("actual-size","")))' )"
  if [[ "\${mapped_by_ftctl}" == "1" && -n "\${mapped_device}" ]]; then
    trap - EXIT
    rbd unmap "\${mapped_device}" >/dev/null 2>&1 || {
      unmap_rc="\$?"
      echo "baseline_rbd_unmap_failed:\${target}:\${mapped_device}:rc=\${unmap_rc}" >&2
      exit 99
    }
  fi
  echo "\${info}"
else
  mkdir -p "\$(dirname "\${dest}")"
  tmp="\${dest}.ftctl-seed.\$\$"
  rm -f -- "\${tmp}" >/dev/null 2>&1 || true
  qemu-img convert -p -f "\${source_format}" -O "\${target_format}" "\${src_uri}" "\${tmp}"
  if [[ -n "\${expected_size}" ]]; then
    tmp_size="\$(qemu-img info --force-share --output=json "\${tmp}" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("virtual-size",""))')"
    if [[ "\${tmp_size}" != "\${expected_size}" ]]; then
      echo "baseline_size_mismatch:\${tmp_size}:\${expected_size}" >&2
      rm -f -- "\${tmp}" >/dev/null 2>&1 || true
      exit 96
    fi
  fi
  mv -f -- "\${tmp}" "\${dest}"
  qemu-img info --force-share --output=json "\${dest}" | python3 -c 'import json,sys; d=json.load(sys.stdin); print("format=%s virtual=%s actual=%s" % (d.get("format",""), d.get("virtual-size",""), d.get("actual-size","")))'
fi
EOF
)"

  timeout_sec="${FTCTL_XCOLO_BASELINE_SEED_TIMEOUT_SEC:-7200}"
  attempts="${FTCTL_XCOLO_BASELINE_SEED_RETRY_ATTEMPTS:-3}"
  [[ "${attempts}" =~ ^[0-9]+$ && "${attempts}" -gt 0 ]] || attempts="3"
  saved_timeout="${FTCTL_BLOCKCOPY_WAIT_TIMEOUT_SEC:-30}"
  FTCTL_BLOCKCOPY_WAIT_TIMEOUT_SEC="${timeout_sec}"
  out=""
  err=""
  rc=0
  last_failure_class=""
  for ((attempt = 1; attempt <= attempts; attempt++)); do
    ftctl_log_event "colo" "block_conversion.baseline_seed.copy.attempt" "ok" "${vm}" "" \
      "target=${target} secondary_dest=${secondary_dest} attempt=${attempt}/${attempts} remote_host=${remote_host}"
    out=""
    err=""
    rc=0
    ftctl_blockcopy_remote_exec "${remote_host}" "${remote_user}" out err rc "${remote_cmd}" || true
    detail="$(ftctl_xcolo_compact_log_value "${err:-${out}}")"
    if [[ "${rc}" == "0" ]]; then
      last_failure_class=""
      break
    fi
    if [[ "${detail}" == baseline_size_mismatch:* ]]; then
      last_failure_class="size_mismatch"
      break
    fi
    case "${detail}" in
      baseline_rbd_map_failed:*)
        last_failure_class="rbd_map"
        break
        ;;
      baseline_rbd_device_missing:*)
        last_failure_class="rbd_device_missing"
        break
        ;;
      baseline_rbd_unmap_failed:*)
        last_failure_class="rbd_unmap"
        break
        ;;
    esac
    if ftctl_xcolo_baseline_seed_is_ssh_failure "${rc}" "${detail}"; then
      last_failure_class="ssh"
      ftctl_log_event "colo" "block_conversion.baseline_seed.copy.ssh_fail" "fail" "${vm}" "${rc}" \
        "target=${target} secondary_dest=${secondary_dest} attempt=${attempt}/${attempts} remote_host=${remote_host} error=${detail}"
      if (( attempt < attempts )); then
        ftctl_xcolo_baseline_seed_cleanup_remote_tmp "${remote_host}" "${remote_user}" "${secondary_dest}"
        retry_delay="$(ftctl_xcolo_baseline_seed_retry_delay "${attempt}")"
        ftctl_log_event "colo" "block_conversion.baseline_seed.copy.retry" "ok" "${vm}" "" \
          "target=${target} secondary_dest=${secondary_dest} attempt=${attempt}/${attempts} next_attempt=$((attempt + 1)) sleep=${retry_delay}"
        sleep "${retry_delay}"
        continue
      fi
      break
    fi
    last_failure_class="copy"
    break
  done
  FTCTL_BLOCKCOPY_WAIT_TIMEOUT_SEC="${saved_timeout}"
  ftctl_xcolo_stop_seed_nbd "${pid_file}" "${export_name}"
  if [[ "${firewall_added}" == "1" ]]; then
    firewall-cmd --quiet --remove-port="${port}/tcp" >/dev/null 2>&1 || true
  fi

  if [[ "${rc}" != "0" ]]; then
    detail="$(ftctl_xcolo_compact_log_value "${err:-${out}}")"
    ftctl_log_event "colo" "block_conversion.baseline_seed.copy.final_fail" "fail" "${vm}" "${rc}" \
      "target=${target} secondary_dest=${secondary_dest} attempts=${attempts} failure_class=${last_failure_class:-copy} error=${detail}"
    ftctl_log_event "colo" "block_conversion.baseline_seed.copy" "fail" "${vm}" "${rc}" \
      "target=${target} secondary_dest=${secondary_dest} error=${detail}"
    case "${last_failure_class}" in
      ssh)
        ftctl_state_set "${vm}" "last_error=xcolo_baseline_seed_ssh_failed:${target}"
        ;;
      size_mismatch)
        ftctl_state_set "${vm}" "last_error=xcolo_baseline_seed_size_mismatch:${target}"
        ;;
      rbd_map)
        ftctl_state_set "${vm}" "last_error=xcolo_baseline_seed_rbd_map_failed:${target}"
        ;;
      rbd_device_missing)
        ftctl_state_set "${vm}" "last_error=xcolo_baseline_seed_rbd_device_missing:${target}"
        ;;
      rbd_unmap)
        ftctl_state_set "${vm}" "last_error=xcolo_baseline_seed_rbd_unmap_failed:${target}"
        ;;
      *)
        ftctl_state_set "${vm}" "last_error=xcolo_baseline_seed_copy_failed:${target}"
        ;;
    esac
    return 1
  fi

  ftctl_state_set "${vm}" "xcolo_disk_${suffix}_baseline_seeded=true"
  ftctl_log_event "colo" "block_conversion.baseline_seed.copy" "ok" "${vm}" "" \
    "target=${target} secondary_dest=${secondary_dest} attempt=${attempt}/${attempts} info=$(printf '%s' "${out}" | tail -n1 | tr ' ' '_')"
}

ftctl_xcolo_collect_disk_binding_on_uri() {
  local uri="${1-}"
  local vm="${2-}"
  local source_path="${3-}"
  local node_var="${4}"
  local qdev_var="${5}"
  local out rc payload

  out=""
  rc=0
  ftctl_xcolo_qmp "${uri}" "${vm}" '{"execute":"query-block"}' out rc
  if [[ "${rc}" != "0" || -z "${out}" ]]; then
    return 1
  fi

  payload="$(python3 - <<'PY' "${source_path}" "${out}"
import json, sys
source = sys.argv[1]
raw = sys.argv[2]
try:
    data = json.loads(raw)
except Exception:
    print("|")
    raise SystemExit(0)
for item in data.get("return", []):
    ins = item.get("inserted") or {}
    image = ins.get("image") or {}
    filename = image.get("filename", "")
    node = ins.get("node-name", "")
    qdev = item.get("qdev", "")
    if filename == source:
        print(f"{node}|{qdev}")
        break
else:
    print("|")
PY
)" || payload="|"

  printf -v "${node_var}" '%s' "${payload%%|*}"
  printf -v "${qdev_var}" '%s' "${payload##*|}"
  [[ -n "${payload%%|*}" ]]
}

ftctl_xcolo_scsi_qdev_to_device_args() {
  local qdev="${1-}"
  local drive="${2-}"
  local id="${3-}"
  local out_var="${4}"
  local controller channel scsi_id lun payload

  [[ -n "${qdev}" && -n "${drive}" && -n "${id}" ]] || return 2
  [[ "${qdev}" =~ ^([A-Za-z0-9_.-]+)-([0-9]+)-([0-9]+)-([0-9]+)$ ]] || return 2

  controller="${BASH_REMATCH[1]}"
  channel="${BASH_REMATCH[2]}"
  scsi_id="${BASH_REMATCH[3]}"
  lun="${BASH_REMATCH[4]}"
  payload="$(python3 - <<'PY' "${controller}" "${channel}" "${scsi_id}" "${lun}" "${drive}" "${id}"
import json
import sys

controller, channel, scsi_id, lun, drive, dev_id = sys.argv[1:]
payload = {
    "driver": "scsi-hd",
    "bus": f"{controller}.0",
    "channel": int(channel),
    "scsi-id": int(scsi_id),
    "lun": int(lun),
    "drive": drive,
    "id": dev_id,
}
if int(lun) == 0:
    payload["bootindex"] = 1
print(json.dumps(payload, separators=(",", ":")))
PY
)"
  printf -v "${out_var}" '%s' "${payload}"
}

ftctl_xcolo_qdev_present_on_uri() {
  local uri="${1-}"
  local vm="${2-}"
  local qdev="${3-}"
  local out="" rc=0

  [[ -n "${qdev}" ]] || return 1
  ftctl_xcolo_qmp "${uri}" "${vm}" '{"execute":"query-block"}' out rc
  [[ "${rc}" == "0" && -n "${out}" ]] || return 1
  python3 - <<'PY' "${qdev}" "${out}"
import json
import sys

qdev = sys.argv[1]
try:
    data = json.loads(sys.argv[2])
except Exception:
    raise SystemExit(1)
for item in data.get("return", []):
    if item.get("qdev") == qdev:
        raise SystemExit(0)
raise SystemExit(1)
PY
}

ftctl_xcolo_wait_qdev_removed() {
  local uri="${1-}"
  local vm="${2-}"
  local qdev="${3-}"
  local i

  if [[ "${FTCTL_DRY_RUN}" == "1" ]]; then
    return 0
  fi

  for ((i=0; i<10; i++)); do
    if ! ftctl_xcolo_qdev_present_on_uri "${uri}" "${vm}" "${qdev}"; then
      return 0
    fi
    sleep 1
  done
  return 1
}

ftctl_xcolo_replace_scsi_disk_device() {
  local uri="${1-}"
  local vm="${2-}"
  local qdev="${3-}"
  local drive="${4-}"
  local device_id="${5-}"
  local stage="${6-}"
  local prefix="${7-}"
  local args

  ftctl_xcolo_scsi_qdev_to_device_args "${qdev}" "${drive}" "${device_id}" args || {
    ftctl_log_event "${stage}" "${prefix}.device_replace_prepare" "fail" "${vm}" "" \
      "qdev=${qdev} reason=unsupported_qdev"
    return 1
  }

  ftctl_xcolo_qmp_require_ok "${uri}" "${vm}" \
    "{\"execute\":\"device_del\",\"arguments\":{\"id\":\"${qdev}\"}}" \
    "${stage}" "${prefix}.device_del_existing_root" || return 1
  ftctl_xcolo_wait_qdev_removed "${uri}" "${vm}" "${qdev}" || {
    ftctl_log_event "${stage}" "${prefix}.device_del_existing_root" "fail" "${vm}" "" \
      "qdev=${qdev} reason=still_present"
    return 1
  }
  ftctl_xcolo_qmp_require_ok "${uri}" "${vm}" \
    "{\"execute\":\"device_add\",\"arguments\":${args}}" \
    "${stage}" "${prefix}.device_add_colo_root" || return 1
}

ftctl_xcolo_attach_secondary_block_graph() {
  local vm="${1-}"
  local base_node="${2-}"
  local hidden="${3-}"
  local active="${4-}"
  local qdev="${5-}"
  local target="${6-}"
  local suffix hidden_node active_node child_node colo_node device_id

  suffix="$(ftctl_xcolo_disk_suffix "${target}")"
  hidden_node="ftctl-hidden-${suffix}"
  active_node="ftctl-active-${suffix}"
  child_node="ftctl-childs-${suffix}"
  colo_node="ftctl-colo-${suffix}"
  device_id="ftctl-colo-${suffix}"

  ftctl_xcolo_qmp_require_ok "${FTCTL_PROFILE_SECONDARY_URI}" "${vm}" \
    "{\"execute\":\"blockdev-add\",\"arguments\":{\"driver\":\"qcow2\",\"node-name\":\"${hidden_node}\",\"file\":{\"driver\":\"file\",\"filename\":\"${hidden}\"},\"backing\":\"${base_node}\"}}" \
    "colo" "secondary.blockdev_add_hidden" || return 1
  ftctl_xcolo_qmp_require_ok "${FTCTL_PROFILE_SECONDARY_URI}" "${vm}" \
    "{\"execute\":\"blockdev-add\",\"arguments\":{\"driver\":\"qcow2\",\"node-name\":\"${active_node}\",\"file\":{\"driver\":\"file\",\"filename\":\"${active}\"},\"backing\":\"${hidden_node}\"}}" \
    "colo" "secondary.blockdev_add_active" || return 1
  ftctl_xcolo_qmp_require_ok "${FTCTL_PROFILE_SECONDARY_URI}" "${vm}" \
    "{\"execute\":\"blockdev-add\",\"arguments\":{\"driver\":\"replication\",\"node-name\":\"${child_node}\",\"mode\":\"secondary\",\"top-id\":\"${colo_node}\",\"file\":\"${active_node}\"}}" \
    "colo" "secondary.blockdev_add_replication" || return 1
  ftctl_xcolo_qmp_require_ok "${FTCTL_PROFILE_SECONDARY_URI}" "${vm}" \
    "{\"execute\":\"blockdev-add\",\"arguments\":{\"driver\":\"quorum\",\"node-name\":\"${colo_node}\",\"read-pattern\":\"fifo\",\"vote-threshold\":1,\"children\":[\"${child_node}\"]}}" \
    "colo" "secondary.blockdev_add_quorum" || return 1
  ftctl_xcolo_replace_scsi_disk_device "${FTCTL_PROFILE_SECONDARY_URI}" "${vm}" "${qdev}" \
    "${colo_node}" "${device_id}" "colo" "secondary" || return 1
}

ftctl_xcolo_attach_primary_block_graph() {
  local vm="${1-}"
  local base_node="${2-}"
  local active="${3-}"
  local qdev="${4-}"
  local target="${5-}"
  local suffix active_node colo_node device_id

  suffix="$(ftctl_xcolo_disk_suffix "${target}")"
  active_node="ftctl-primary-active-${suffix}"
  colo_node="ftctl-colo-${suffix}"
  device_id="ftctl-colo-${suffix}"

  ftctl_xcolo_qmp_require_ok "${FTCTL_PROFILE_PRIMARY_URI}" "${vm}" \
    "{\"execute\":\"blockdev-add\",\"arguments\":{\"driver\":\"qcow2\",\"node-name\":\"${active_node}\",\"file\":{\"driver\":\"file\",\"filename\":\"${active}\"},\"backing\":\"${base_node}\"}}" \
    "colo" "primary.blockdev_add_active" || return 1
  ftctl_xcolo_qmp_require_ok "${FTCTL_PROFILE_PRIMARY_URI}" "${vm}" \
    "{\"execute\":\"blockdev-add\",\"arguments\":{\"driver\":\"quorum\",\"node-name\":\"${colo_node}\",\"read-pattern\":\"fifo\",\"vote-threshold\":1,\"children\":[\"${active_node}\"]}}" \
    "colo" "primary.blockdev_add_quorum" || return 1
  ftctl_xcolo_replace_scsi_disk_device "${FTCTL_PROFILE_PRIMARY_URI}" "${vm}" "${qdev}" \
    "${colo_node}" "${device_id}" "colo" "primary" || return 1
}

ftctl_xcolo_attach_primary_block_graph_with_remote() {
  local vm="${1-}"
  local base_node="${2-}"
  local active="${3-}"
  local qdev="${4-}"
  local target="${5-}"
  local nbd_node="${6-}"
  local suffix active_node colo_node device_id

  suffix="$(ftctl_xcolo_disk_suffix "${target}")"
  active_node="ftctl-primary-active-${suffix}"
  colo_node="ftctl-colo-${suffix}"
  device_id="ftctl-colo-${suffix}"

  [[ -n "${nbd_node}" ]] || return 1

  ftctl_xcolo_qmp_require_ok "${FTCTL_PROFILE_PRIMARY_URI}" "${vm}" \
    "{\"execute\":\"blockdev-add\",\"arguments\":{\"driver\":\"qcow2\",\"node-name\":\"${active_node}\",\"file\":{\"driver\":\"file\",\"filename\":\"${active}\"},\"backing\":\"${base_node}\"}}" \
    "colo" "primary.blockdev_add_active.${suffix}" || return 1
  ftctl_xcolo_qmp_require_ok "${FTCTL_PROFILE_PRIMARY_URI}" "${vm}" \
    "{\"execute\":\"blockdev-add\",\"arguments\":{\"driver\":\"quorum\",\"node-name\":\"${colo_node}\",\"read-pattern\":\"fifo\",\"vote-threshold\":1,\"children\":[\"${active_node}\"]}}" \
    "colo" "primary.blockdev_add_quorum.${suffix}" || return 1
  ftctl_xcolo_replace_scsi_disk_device "${FTCTL_PROFILE_PRIMARY_URI}" "${vm}" "${qdev}" \
    "${colo_node}" "${device_id}" "colo" "primary" || return 1
  ftctl_xcolo_qmp_require_ok "${FTCTL_PROFILE_PRIMARY_URI}" "${vm}" \
    "{\"execute\":\"x-blockdev-change\",\"arguments\":{\"parent\":\"${colo_node}\",\"node\":\"${nbd_node}\"}}" \
    "colo" "primary.x_blockdev_change.${suffix}" || return 1
}

ftctl_xcolo_primary_net_filters_qmp_rebuild() {
  local vm="${1-}"
  local source="${2:-runtime_repair}"
  local netdev_id mirror_port compare_port compare_local_port compare_out_port
  local vnet_hdr_qmp

  netdev_id="$(ftctl_state_get "${vm}" "xcolo_primary_netdev_id" 2>/dev/null || true)"
  netdev_id="${netdev_id:-hostnet0}"
  ftctl_xcolo_update_vnet_hdr_state "${vm}" || true
  vnet_hdr_qmp="$(ftctl_xcolo_vnet_hdr_qmp_bool_arg "${vm}")"
  mirror_port="${FTCTL_XCOLO_MIRROR_PORT:-9003}"
  compare_port="${FTCTL_XCOLO_COMPARE_PORT:-9004}"
  compare_local_port="${FTCTL_XCOLO_COMPARE_LOCAL_PORT:-9001}"
  compare_out_port="${FTCTL_XCOLO_COMPARE_OUT_PORT:-9005}"

  ftctl_log_event "colo" "primary.net_filters.rebuild" "start" "${vm}" "" \
    "source=${source} netdev=${netdev_id}"

  ftctl_xcolo_qmp_optional "${FTCTL_PROFILE_PRIMARY_URI}" "${vm}" \
    '{"execute":"object-del","arguments":{"id":"m0"}}' \
    "colo" "primary.object_del_filter_mirror"
  ftctl_xcolo_qmp_optional "${FTCTL_PROFILE_PRIMARY_URI}" "${vm}" \
    '{"execute":"object-del","arguments":{"id":"redire0"}}' \
    "colo" "primary.object_del_redirector_in"
  ftctl_xcolo_qmp_optional "${FTCTL_PROFILE_PRIMARY_URI}" "${vm}" \
    '{"execute":"object-del","arguments":{"id":"redire1"}}' \
    "colo" "primary.object_del_redirector_out"
  ftctl_xcolo_qmp_optional "${FTCTL_PROFILE_PRIMARY_URI}" "${vm}" \
    '{"execute":"object-del","arguments":{"id":"comp0"}}' \
    "colo" "primary.object_del_colo_compare"

  for chardev_id in mirror0 compare1 compare0 compare0-0 compare_out compare_out0; do
    ftctl_xcolo_qmp_optional "${FTCTL_PROFILE_PRIMARY_URI}" "${vm}" \
      "{\"execute\":\"chardev-remove\",\"arguments\":{\"id\":\"${chardev_id}\"}}" \
      "colo" "primary.chardev_remove.${chardev_id}"
  done

  ftctl_xcolo_qmp_require_ok_or_exists "${FTCTL_PROFILE_PRIMARY_URI}" "${vm}" \
    "{\"execute\":\"chardev-add\",\"arguments\":{\"id\":\"mirror0\",\"backend\":{\"type\":\"socket\",\"data\":{\"addr\":{\"type\":\"inet\",\"data\":{\"host\":\"0.0.0.0\",\"port\":\"${mirror_port}\"}},\"server\":true,\"wait\":false}}}}" \
    "colo" "primary.chardev_add.mirror0" || return 1
  ftctl_xcolo_qmp_require_ok_or_exists "${FTCTL_PROFILE_PRIMARY_URI}" "${vm}" \
    "{\"execute\":\"chardev-add\",\"arguments\":{\"id\":\"compare1\",\"backend\":{\"type\":\"socket\",\"data\":{\"addr\":{\"type\":\"inet\",\"data\":{\"host\":\"0.0.0.0\",\"port\":\"${compare_port}\"}},\"server\":true,\"wait\":false}}}}" \
    "colo" "primary.chardev_add.compare1" || return 1
  ftctl_xcolo_qmp_require_ok_or_exists "${FTCTL_PROFILE_PRIMARY_URI}" "${vm}" \
    "{\"execute\":\"chardev-add\",\"arguments\":{\"id\":\"compare0\",\"backend\":{\"type\":\"socket\",\"data\":{\"addr\":{\"type\":\"inet\",\"data\":{\"host\":\"127.0.0.1\",\"port\":\"${compare_local_port}\"}},\"server\":true,\"wait\":false}}}}" \
    "colo" "primary.chardev_add.compare0" || return 1
  ftctl_xcolo_qmp_require_ok_or_exists "${FTCTL_PROFILE_PRIMARY_URI}" "${vm}" \
    "{\"execute\":\"chardev-add\",\"arguments\":{\"id\":\"compare0-0\",\"backend\":{\"type\":\"socket\",\"data\":{\"addr\":{\"type\":\"inet\",\"data\":{\"host\":\"127.0.0.1\",\"port\":\"${compare_local_port}\"}},\"server\":false,\"reconnect-ms\":1000}}}}" \
    "colo" "primary.chardev_add.compare0_client" || return 1
  ftctl_xcolo_qmp_require_ok_or_exists "${FTCTL_PROFILE_PRIMARY_URI}" "${vm}" \
    "{\"execute\":\"chardev-add\",\"arguments\":{\"id\":\"compare_out\",\"backend\":{\"type\":\"socket\",\"data\":{\"addr\":{\"type\":\"inet\",\"data\":{\"host\":\"127.0.0.1\",\"port\":\"${compare_out_port}\"}},\"server\":true,\"wait\":false}}}}" \
    "colo" "primary.chardev_add.compare_out" || return 1
  ftctl_xcolo_qmp_require_ok_or_exists "${FTCTL_PROFILE_PRIMARY_URI}" "${vm}" \
    "{\"execute\":\"chardev-add\",\"arguments\":{\"id\":\"compare_out0\",\"backend\":{\"type\":\"socket\",\"data\":{\"addr\":{\"type\":\"inet\",\"data\":{\"host\":\"127.0.0.1\",\"port\":\"${compare_out_port}\"}},\"server\":false,\"reconnect-ms\":1000}}}}" \
    "colo" "primary.chardev_add.compare_out_client" || return 1

  ftctl_xcolo_qmp_require_ok_or_exists "${FTCTL_PROFILE_PRIMARY_URI}" "${vm}" \
    "{\"execute\":\"object-add\",\"arguments\":{\"qom-type\":\"filter-mirror\",\"id\":\"m0\",\"netdev\":\"${netdev_id}\",\"queue\":\"tx\",\"outdev\":\"mirror0\",\"insert\":\"behind\",\"position\":\"tail\"${vnet_hdr_qmp}}}" \
    "colo" "primary.object_add_filter_mirror" || return 1
  ftctl_xcolo_qmp_require_ok_or_exists "${FTCTL_PROFILE_PRIMARY_URI}" "${vm}" \
    "{\"execute\":\"object-add\",\"arguments\":{\"qom-type\":\"filter-redirector\",\"id\":\"redire0\",\"netdev\":\"${netdev_id}\",\"queue\":\"rx\",\"indev\":\"compare_out\",\"insert\":\"behind\",\"position\":\"tail\"${vnet_hdr_qmp}}}" \
    "colo" "primary.object_add_redirector_in" || return 1
  ftctl_xcolo_qmp_require_ok_or_exists "${FTCTL_PROFILE_PRIMARY_URI}" "${vm}" \
    "{\"execute\":\"object-add\",\"arguments\":{\"qom-type\":\"filter-redirector\",\"id\":\"redire1\",\"netdev\":\"${netdev_id}\",\"queue\":\"rx\",\"outdev\":\"compare0\",\"insert\":\"behind\",\"position\":\"tail\"${vnet_hdr_qmp}}}" \
    "colo" "primary.object_add_redirector_out" || return 1
  ftctl_xcolo_qmp_require_ok_or_exists "${FTCTL_PROFILE_PRIMARY_URI}" "${vm}" \
    "{\"execute\":\"object-add\",\"arguments\":{\"qom-type\":\"colo-compare\",\"id\":\"comp0\",\"primary_in\":\"compare0-0\",\"secondary_in\":\"compare1\",\"outdev\":\"compare_out0\",\"iothread\":\"iothread1\"${vnet_hdr_qmp}}}" \
    "colo" "primary.object_add_colo_compare" || return 1

  ftctl_xcolo_collect_primary_chardev_binding_state "${vm}" || true
  ftctl_xcolo_require_primary_filter_qom_ready "${vm}" "qmp-rebuild" "on" || return 1
  ftctl_state_set "${vm}" \
    "xcolo_primary_net_filters_attached=true" \
    "xcolo_primary_net_filters_attach_mode=qmp-rebuild" \
    "xcolo_primary_net_filters_netdev=${netdev_id}" \
    "xcolo_primary_filter_qmp_attach_order=qemu-doc-primary" \
    "xcolo_primary_filter_runtime_repair_attempted=yes" \
    "xcolo_primary_filter_runtime_repair_source=${source}" \
    "xcolo_primary_net_filters_activated=true" \
    "xcolo_primary_filter_runtime_status=on" \
    "xcolo_primary_net_filters_activation_mode=startup-active"
  ftctl_log_event "colo" "primary.net_filters.rebuild" "ok" "${vm}" "" \
    "source=${source} netdev=${netdev_id}"
}

ftctl_xcolo_primary_net_filters_qmp_attach_objects() {
  local vm="${1-}"
  local source="${2:-qmp-object-attach}"
  local netdev_id
  local vnet_hdr_qmp

  netdev_id="$(ftctl_state_get "${vm}" "xcolo_primary_netdev_id" 2>/dev/null || true)"
  netdev_id="${netdev_id:-hostnet0}"
  ftctl_xcolo_update_vnet_hdr_state "${vm}" || true
  vnet_hdr_qmp="$(ftctl_xcolo_vnet_hdr_qmp_bool_arg "${vm}")"

  ftctl_log_event "colo" "primary.net_filters.qmp_objects" "start" "${vm}" "" \
    "source=${source} netdev=${netdev_id}"

  ftctl_xcolo_qmp_optional "${FTCTL_PROFILE_PRIMARY_URI}" "${vm}" \
    '{"execute":"object-del","arguments":{"id":"m0"}}' \
    "colo" "primary.object_del_filter_mirror"
  ftctl_xcolo_qmp_optional "${FTCTL_PROFILE_PRIMARY_URI}" "${vm}" \
    '{"execute":"object-del","arguments":{"id":"redire0"}}' \
    "colo" "primary.object_del_redirector_in"
  ftctl_xcolo_qmp_optional "${FTCTL_PROFILE_PRIMARY_URI}" "${vm}" \
    '{"execute":"object-del","arguments":{"id":"redire1"}}' \
    "colo" "primary.object_del_redirector_out"
  ftctl_xcolo_qmp_optional "${FTCTL_PROFILE_PRIMARY_URI}" "${vm}" \
    '{"execute":"object-del","arguments":{"id":"comp0"}}' \
    "colo" "primary.object_del_colo_compare"

  ftctl_xcolo_qmp_require_ok_or_exists "${FTCTL_PROFILE_PRIMARY_URI}" "${vm}" \
    "{\"execute\":\"object-add\",\"arguments\":{\"qom-type\":\"filter-mirror\",\"id\":\"m0\",\"netdev\":\"${netdev_id}\",\"queue\":\"tx\",\"outdev\":\"mirror0\",\"insert\":\"behind\",\"position\":\"tail\"${vnet_hdr_qmp}}}" \
    "colo" "primary.object_add_filter_mirror" || return 1
  ftctl_xcolo_qmp_require_ok_or_exists "${FTCTL_PROFILE_PRIMARY_URI}" "${vm}" \
    "{\"execute\":\"object-add\",\"arguments\":{\"qom-type\":\"filter-redirector\",\"id\":\"redire0\",\"netdev\":\"${netdev_id}\",\"queue\":\"rx\",\"indev\":\"compare_out\",\"insert\":\"behind\",\"position\":\"tail\"${vnet_hdr_qmp}}}" \
    "colo" "primary.object_add_redirector_in" || return 1
  ftctl_xcolo_qmp_require_ok_or_exists "${FTCTL_PROFILE_PRIMARY_URI}" "${vm}" \
    "{\"execute\":\"object-add\",\"arguments\":{\"qom-type\":\"filter-redirector\",\"id\":\"redire1\",\"netdev\":\"${netdev_id}\",\"queue\":\"rx\",\"outdev\":\"compare0\",\"insert\":\"behind\",\"position\":\"tail\"${vnet_hdr_qmp}}}" \
    "colo" "primary.object_add_redirector_out" || return 1
  ftctl_xcolo_qmp_require_ok_or_exists "${FTCTL_PROFILE_PRIMARY_URI}" "${vm}" \
    "{\"execute\":\"object-add\",\"arguments\":{\"qom-type\":\"colo-compare\",\"id\":\"comp0\",\"primary_in\":\"compare0-0\",\"secondary_in\":\"compare1\",\"outdev\":\"compare_out0\",\"iothread\":\"iothread1\"${vnet_hdr_qmp}}}" \
    "colo" "primary.object_add_colo_compare" || return 1

  ftctl_xcolo_collect_primary_chardev_binding_state "${vm}" || true
  ftctl_xcolo_require_primary_filter_qom_ready "${vm}" "qmp-objects" "on" || return 1
  ftctl_state_set "${vm}" \
    "xcolo_primary_net_filters_attached=true" \
    "xcolo_primary_net_filters_attach_mode=qmp-objects" \
    "xcolo_primary_net_filters_netdev=${netdev_id}" \
    "xcolo_primary_filter_qmp_attach_order=qemu-doc-primary" \
    "xcolo_primary_filter_runtime_repair_attempted=no" \
    "xcolo_primary_filter_runtime_repair_source=${source}" \
    "xcolo_primary_net_filters_activated=true" \
    "xcolo_primary_filter_runtime_status=on" \
    "xcolo_primary_net_filters_activation_mode=startup-active"
  ftctl_log_event "colo" "primary.net_filters.qmp_objects" "ok" "${vm}" "" \
    "source=${source} netdev=${netdev_id}"
}

ftctl_xcolo_capture_filter_activation_step_state() {
  local vm="${1-}"
  local secondary_vm="${2-}"
  local step="${3-}"
  local primary_migrate="" secondary_migrate="" primary_colo="" secondary_colo=""
  local primary_migrate_error_desc="" secondary_migrate_error_desc=""
  local invalid_message="no"

  [[ -n "${vm}" && -n "${secondary_vm}" && -n "${step}" ]] || return 0

  ftctl_xcolo_query_migrate_status "${FTCTL_PROFILE_PRIMARY_URI}" "${vm}" primary_migrate || true
  ftctl_xcolo_query_migrate_status "${FTCTL_PROFILE_SECONDARY_URI}" "${secondary_vm}" secondary_migrate || true
  ftctl_xcolo_query_colo_mode "${FTCTL_PROFILE_PRIMARY_URI}" "${vm}" primary_colo || true
  ftctl_xcolo_query_colo_mode "${FTCTL_PROFILE_SECONDARY_URI}" "${secondary_vm}" secondary_colo || true
  if [[ "${primary_migrate}" == "failed" ]]; then
    ftctl_xcolo_query_migrate_error_desc "${FTCTL_PROFILE_PRIMARY_URI}" "${vm}" primary_migrate_error_desc || true
  fi
  if [[ "${secondary_migrate}" == "failed" ]]; then
    ftctl_xcolo_query_migrate_error_desc "${FTCTL_PROFILE_SECONDARY_URI}" "${secondary_vm}" secondary_migrate_error_desc || true
  fi
  if [[ "${primary_migrate_error_desc}" == *"Received invalid message"* ]] || ftctl_xcolo_primary_invalid_message_observed "${vm}"; then
    invalid_message="yes"
  fi

  ftctl_xcolo_capture_socket_snapshot "${vm}" "filter_activation_${step}" || true
  ftctl_state_set "${vm}" \
    "xcolo_filter_activation_step=${step}" \
    "xcolo_filter_activation_${step}_primary_migrate_status=${primary_migrate}" \
    "xcolo_filter_activation_${step}_secondary_migrate_status=${secondary_migrate}" \
    "xcolo_filter_activation_${step}_primary_colo_mode=${primary_colo}" \
    "xcolo_filter_activation_${step}_secondary_colo_mode=${secondary_colo}" \
    "xcolo_filter_activation_${step}_primary_migrate_error_desc=${primary_migrate_error_desc}" \
    "xcolo_filter_activation_${step}_secondary_migrate_error_desc=${secondary_migrate_error_desc}" \
    "xcolo_filter_activation_${step}_invalid_message=${invalid_message}"
  ftctl_log_event "colo" "xcolo.filter_activation_step" "ok" "${vm}" "" \
    "step=${step} primary_migrate=${primary_migrate} secondary_migrate=${secondary_migrate} primary_colo=${primary_colo} secondary_colo=${secondary_colo} invalid_message=${invalid_message}"
}

ftctl_xcolo_gate_before_redire1_activation_reason() {
  local vm="${1-}"
  local primary_migrate="${2-}"
  local secondary_migrate="${3-}"
  local invalid_message="${4-}"

  if [[ "${invalid_message}" == "yes" ]]; then
    printf '%s\n' "invalid_message_before_redire1"
  elif [[ "${primary_migrate}" != "active" ]]; then
    printf '%s\n' "primary_migrate_not_active"
  elif [[ "${secondary_migrate}" != "active" && "${secondary_migrate}" != "colo" ]]; then
    printf '%s\n' "secondary_migrate_not_active_or_colo"
  elif [[ "$(ftctl_state_get "${vm}" "xcolo_channel_mirror_established" 2>/dev/null || true)" != "yes" ]]; then
    printf '%s\n' "mirror_channel_not_established"
  elif [[ "$(ftctl_state_get "${vm}" "xcolo_channel_compare_established" 2>/dev/null || true)" != "yes" ]]; then
    printf '%s\n' "compare_channel_not_established"
  elif [[ "$(ftctl_state_get "${vm}" "xcolo_channel_compare_local_established" 2>/dev/null || true)" != "yes" ]]; then
    printf '%s\n' "compare_local_channel_not_established"
  elif [[ "$(ftctl_state_get "${vm}" "xcolo_channel_compare_out_established" 2>/dev/null || true)" != "yes" ]]; then
    printf '%s\n' "compare_out_channel_not_established"
  else
    printf '%s\n' ""
  fi
}

ftctl_xcolo_gate_before_redire1_activation() {
  local vm="${1-}"
  local secondary_vm="${2-}"
  local primary_migrate secondary_migrate primary_colo secondary_colo
  local primary_migrate_error_desc="" secondary_migrate_error_desc=""
  local invalid_message chardev_ready chardev_reason reason

  [[ -n "${vm}" && -n "${secondary_vm}" ]] || return 0

  ftctl_log_event "colo" "xcolo.pre_redire1_gate" "start" "${vm}" "" \
    "mode=fast_cached_post_migrate"

  primary_migrate="$(ftctl_state_get "${vm}" "xcolo_post_migrate_pre_activation_primary_migrate_status" 2>/dev/null || true)"
  secondary_migrate="$(ftctl_state_get "${vm}" "xcolo_post_migrate_pre_activation_secondary_migrate_status" 2>/dev/null || true)"
  primary_colo="$(ftctl_state_get "${vm}" "xcolo_post_migrate_pre_activation_primary_colo_mode" 2>/dev/null || true)"
  secondary_colo="$(ftctl_state_get "${vm}" "xcolo_post_migrate_pre_activation_secondary_colo_mode" 2>/dev/null || true)"
  primary_migrate_error_desc="$(ftctl_state_get "${vm}" "xcolo_post_migrate_pre_activation_primary_migrate_error_desc" 2>/dev/null || true)"
  secondary_migrate_error_desc="$(ftctl_state_get "${vm}" "xcolo_post_migrate_pre_activation_secondary_migrate_error_desc" 2>/dev/null || true)"
  invalid_message="$(ftctl_state_get "${vm}" "xcolo_post_migrate_pre_activation_invalid_message" 2>/dev/null || true)"
  [[ -n "${invalid_message}" ]] || invalid_message="no"
  chardev_ready="$(ftctl_state_get "${vm}" "xcolo_primary_filter_chardev_ready" 2>/dev/null || true)"
  chardev_reason="$(ftctl_state_get "${vm}" "xcolo_primary_filter_chardev_reason" 2>/dev/null || true)"
  reason="$(ftctl_xcolo_gate_before_redire1_activation_reason "${vm}" "${primary_migrate}" "${secondary_migrate}" "${invalid_message}")"

  ftctl_state_set "${vm}" \
    "xcolo_pre_redire1_gate_attempts=1" \
    "xcolo_pre_redire1_gate_mode=fast_cached_post_migrate" \
    "xcolo_pre_redire1_primary_migrate_status=${primary_migrate}" \
    "xcolo_pre_redire1_secondary_migrate_status=${secondary_migrate}" \
    "xcolo_pre_redire1_primary_colo_mode=${primary_colo}" \
    "xcolo_pre_redire1_secondary_colo_mode=${secondary_colo}" \
    "xcolo_pre_redire1_primary_migrate_error_desc=${primary_migrate_error_desc}" \
    "xcolo_pre_redire1_secondary_migrate_error_desc=${secondary_migrate_error_desc}" \
    "xcolo_pre_redire1_invalid_message=${invalid_message}" \
    "xcolo_pre_redire1_chardev_ready=${chardev_ready}" \
    "xcolo_pre_redire1_chardev_reason=${chardev_reason}" \
    "xcolo_pre_redire1_strict_chardev_deferred=yes" \
    "xcolo_pre_redire1_channel_mirror_established=$(ftctl_state_get "${vm}" "xcolo_channel_mirror_established" 2>/dev/null || true)" \
    "xcolo_pre_redire1_channel_compare_established=$(ftctl_state_get "${vm}" "xcolo_channel_compare_established" 2>/dev/null || true)" \
    "xcolo_pre_redire1_channel_compare_local_established=$(ftctl_state_get "${vm}" "xcolo_channel_compare_local_established" 2>/dev/null || true)" \
    "xcolo_pre_redire1_channel_compare_out_established=$(ftctl_state_get "${vm}" "xcolo_channel_compare_out_established" 2>/dev/null || true)" \
    "xcolo_pre_redire1_gate_reason=${reason}"

  if [[ -z "${reason}" ]]; then
    ftctl_state_set "${vm}" "xcolo_pre_redire1_gate=ready"
    ftctl_log_event "colo" "xcolo.pre_redire1_gate" "ok" "${vm}" "" \
      "mode=fast_cached_post_migrate primary_migrate=${primary_migrate} secondary_migrate=${secondary_migrate} secondary_colo=${secondary_colo} chardev_deferred=yes"
    return 0
  fi

  ftctl_state_set "${vm}" \
    "xcolo_pre_redire1_gate=failed" \
    "xcolo_protocol_failure_phase=pre_redire1_fast_gate" \
    "xcolo_filter_activation_failed_step=redire1" \
    "xcolo_primary_filter_activation_failed_reason=redire1_fast_prerequisite_${reason}" \
    "last_error=xcolo_redire1_fast_activation_prerequisite_failed"
  ftctl_log_event "colo" "xcolo.pre_redire1_gate" "fail" "${vm}" "" \
    "mode=fast_cached_post_migrate reason=${reason} primary_migrate=${primary_migrate} secondary_migrate=${secondary_migrate}"
  return 1
}

ftctl_xcolo_activate_primary_net_filters() {
  local vm="${1-}"
  local source="${2:-cmdline}"
  local secondary_vm="${3-}"
  local reason step path entry invalid_message primary_migrate primary_migrate_error_desc
  local -a activation_steps=(
    "redire1:/objects/redire1"
    "m0:/objects/m0"
    "redire0:/objects/redire0"
  )

  [[ -n "${vm}" ]] || return 1

  ftctl_log_event "colo" "primary.net_filters.activate" "start" "${vm}" "" \
    "source=${source} order=redire1,m0,redire0"

  ftctl_xcolo_require_primary_filter_qom_ready "${vm}" "pre_activation" "off" || {
    reason="$(ftctl_state_get "${vm}" "xcolo_primary_filter_qom_reason" 2>/dev/null || true)"
    [[ -n "${reason}" ]] || reason="startup_status_not_off"
    ftctl_state_set "${vm}" \
      "xcolo_primary_net_filters_activated=false" \
      "xcolo_primary_filter_startup_status=unexpected" \
      "xcolo_primary_filter_activation_failed_reason=${reason}" \
      "last_error=primary_filter_activation_failed"
    ftctl_log_event "colo" "primary.net_filters.activate" "fail" "${vm}" "" \
      "phase=pre_activation reason=${reason}"
    return 1
  }

  ftctl_state_set "${vm}" \
    "xcolo_primary_filter_startup_status=off" \
    "xcolo_primary_net_filters_activation_order=redire1,m0,redire0"

  for entry in "${activation_steps[@]}"; do
    step="${entry%%:*}"
    path="${entry#*:}"
    ftctl_state_set "${vm}" "xcolo_filter_activation_step=${step}"
    if [[ "${step}" == "redire1" ]]; then
      ftctl_xcolo_gate_before_redire1_activation "${vm}" "${secondary_vm}" || return 1
    fi
    ftctl_xcolo_qmp_require_ok "${FTCTL_PROFILE_PRIMARY_URI}" "${vm}" \
      "{\"execute\":\"qom-set\",\"arguments\":{\"path\":\"${path}\",\"property\":\"status\",\"value\":\"on\"}}" \
      "colo" "primary.filter_status_on.${step}" || {
        ftctl_state_set "${vm}" \
          "xcolo_primary_net_filters_activated=false" \
          "xcolo_filter_activation_failed_step=${step}" \
          "xcolo_primary_filter_activation_failed_reason=${step}_qom_set_failed" \
          "last_error=primary_filter_activation_failed"
        return 1
      }

    ftctl_xcolo_capture_filter_activation_step_state "${vm}" "${secondary_vm}" "${step}" || true
    invalid_message="$(ftctl_state_get "${vm}" "xcolo_filter_activation_${step}_invalid_message" 2>/dev/null || true)"
    primary_migrate="$(ftctl_state_get "${vm}" "xcolo_filter_activation_${step}_primary_migrate_status" 2>/dev/null || true)"
    primary_migrate_error_desc="$(ftctl_state_get "${vm}" "xcolo_filter_activation_${step}_primary_migrate_error_desc" 2>/dev/null || true)"
    if [[ "${invalid_message}" == "yes" ]]; then
      ftctl_state_set "${vm}" \
        "xcolo_primary_net_filters_activated=false" \
        "xcolo_filter_activation_failed_step=${step}" \
        "xcolo_primary_filter_activation_failed_reason=${step}_broke_colo_stream" \
        "xcolo_protocol_failure_phase=filter_activation_${step}" \
        "last_error=xcolo_filter_activation_${step}_broke_colo_stream"
      ftctl_log_event "colo" "primary.net_filters.activate" "fail" "${vm}" "" \
        "phase=filter_activation step=${step} reason=invalid_message primary_migrate=${primary_migrate}"
      return 1
    fi
    if [[ "${primary_migrate}" == "failed" ]]; then
      ftctl_state_set "${vm}" \
        "xcolo_primary_net_filters_activated=false" \
        "xcolo_filter_activation_failed_step=${step}" \
        "xcolo_primary_filter_activation_failed_reason=${step}_migration_failed" \
        "xcolo_protocol_failure_phase=filter_activation_${step}" \
        "last_error=xcolo_filter_activation_${step}_migration_failed"
      ftctl_log_event "colo" "primary.net_filters.activate" "fail" "${vm}" "" \
        "phase=filter_activation step=${step} reason=migration_failed error_desc=${primary_migrate_error_desc}"
      return 1
    fi
  done

  if ! ftctl_xcolo_require_primary_filter_qom_ready "${vm}" "post_activation" "on"; then
    reason="$(ftctl_state_get "${vm}" "xcolo_primary_filter_qom_reason" 2>/dev/null || true)"
    [[ -n "${reason}" ]] || reason="runtime_status_not_on"
    ftctl_state_set "${vm}" \
      "xcolo_primary_net_filters_activated=false" \
      "xcolo_primary_filter_runtime_status=unexpected" \
      "xcolo_primary_filter_activation_failed_reason=${reason}" \
      "xcolo_protocol_failure_phase=filter_activation_post_verify" \
      "last_error=primary_filter_activation_failed"
    ftctl_log_event "colo" "primary.net_filters.activate" "fail" "${vm}" "" \
      "phase=post_activation reason=${reason}"
    return 1
  fi

  ftctl_state_set "${vm}" \
    "xcolo_primary_net_filters_activation_mode=qom-set-status" \
    "xcolo_primary_net_filters_activation_order=redire1,m0,redire0" \
    "xcolo_primary_net_filters_activated=true" \
    "xcolo_primary_filter_runtime_status=on"
  ftctl_log_event "colo" "primary.net_filters.activate" "ok" "${vm}" "" \
    "source=${source} mode=qom-set-status order=redire1,m0,redire0"
}

ftctl_xcolo_attach_primary_net_filters() {
  local vm="${1-}"
  local netdev_id attach_mode chardev_ready chardev_reason

  ftctl_xcolo_qmp_require_ok "${FTCTL_PROFILE_PRIMARY_URI}" "${vm}" \
    '{"execute":"stop"}' "colo" "primary.stop_before_filter_attach" || return 1

  if ftctl_xcolo_domain_xml_has_runtime_markers "${FTCTL_PROFILE_PRIMARY_URI}" "${vm}" primary; then
    ftctl_xcolo_validate_primary_channel_paths "${vm}" || return 1
    ftctl_xcolo_require_primary_filter_cmdline_ready "${vm}" "pre_migrate_xml_runtime" || return 1
    ftctl_xcolo_require_primary_filter_qom_ready "${vm}" "pre_migrate_xml_runtime" "on" || return 1
    ftctl_xcolo_observe_primary_filter_chardev_binding "${vm}" || true
    chardev_ready="$(ftctl_state_get "${vm}" "xcolo_primary_filter_chardev_ready" 2>/dev/null || true)"
    attach_mode="cmdline"
    ftctl_state_set "${vm}" \
      "xcolo_primary_net_filters_attached=true" \
      "xcolo_primary_net_filters_attach_mode=${attach_mode}" \
      "xcolo_primary_net_filters_netdev=$(ftctl_state_get "${vm}" "xcolo_primary_netdev_id" 2>/dev/null || printf '%s' hostnet0)" \
      "xcolo_primary_filter_qmp_attach_order=qemu-doc-primary" \
      "xcolo_primary_filter_runtime_repair_attempted=no" \
      "xcolo_primary_filter_runtime_repair_source=cmdline" \
      "xcolo_primary_net_filters_activated=true" \
      "xcolo_primary_filter_runtime_status=on" \
      "xcolo_primary_net_filters_activation_mode=startup-active" \
      "xcolo_primary_filter_activation_stage=premigrate_active" \
      "xcolo_primary_filter_status_pre_migrate=on" \
      "xcolo_primary_filter_startup_status=on"
    ftctl_log_event "colo" "primary.net_filters" "ok" "${vm}" "" \
      "mode=${attach_mode} chardev_initial=${chardev_ready:-unknown} activation=startup-active"
    return 0
  fi

  if ftctl_xcolo_domain_xml_has_primary_chardev_markers "${FTCTL_PROFILE_PRIMARY_URI}" "${vm}"; then
    ftctl_xcolo_validate_primary_channel_paths "${vm}" || return 1
    ftctl_xcolo_primary_net_filters_qmp_attach_objects "${vm}" "pre_migrate_xml_chardev_only" || return 1
    ftctl_xcolo_validate_primary_channel_paths "${vm}" || return 1
    netdev_id="$(ftctl_state_get "${vm}" "xcolo_primary_netdev_id" 2>/dev/null || true)"
    netdev_id="${netdev_id:-hostnet0}"
    ftctl_state_set "${vm}" \
      "xcolo_primary_net_filters_attached=true" \
      "xcolo_primary_net_filters_attach_mode=qmp-objects" \
      "xcolo_primary_net_filters_netdev=${netdev_id}" \
      "xcolo_primary_filter_activation_stage=premigrate_active" \
      "xcolo_primary_filter_status_pre_migrate=on" \
      "xcolo_primary_net_filters_activated=true" \
      "xcolo_primary_filter_runtime_status=on" \
      "xcolo_primary_net_filters_activation_mode=startup-active"
    ftctl_log_event "colo" "primary.net_filters" "ok" "${vm}" "" \
      "mode=qmp-objects activation=startup-active"
    return 0
  fi

  ftctl_xcolo_primary_net_filters_qmp_rebuild "${vm}" "pre_migrate_no_xml_markers" || return 1
  netdev_id="$(ftctl_state_get "${vm}" "xcolo_primary_netdev_id" 2>/dev/null || true)"
  netdev_id="${netdev_id:-hostnet0}"
  ftctl_xcolo_validate_primary_channel_paths "${vm}" || return 1
  ftctl_xcolo_observe_primary_filter_chardev_binding "${vm}" || true
  ftctl_state_set "${vm}" \
    "xcolo_primary_net_filters_attached=true" \
    "xcolo_primary_net_filters_attach_mode=qmp-rebuild" \
    "xcolo_primary_net_filters_netdev=${netdev_id}" \
    "xcolo_primary_filter_activation_stage=premigrate_active" \
    "xcolo_primary_filter_status_pre_migrate=on" \
    "xcolo_primary_net_filters_activated=true" \
    "xcolo_primary_filter_runtime_status=on" \
    "xcolo_primary_net_filters_activation_mode=startup-active"
  ftctl_log_event "colo" "primary.net_filters" "ok" "${vm}" "" \
    "mode=qmp-rebuild activation=startup-active"
}

ftctl_xcolo_resume_primary_before_migrate() {
  local vm="${1-}"

  ftctl_xcolo_qmp_require_ok "${FTCTL_PROFILE_PRIMARY_URI}" "${vm}" \
    '{"execute":"cont"}' "colo" "primary.cont_before_migrate" || return 1
  ftctl_state_set "${vm}" "xcolo_primary_cont_before_migrate=true"
}

ftctl_xcolo_require_checkpoint_delay_before_migrate() {
  local vm="${1-}"
  local checkpoint_delay actual_delay

  checkpoint_delay="${FTCTL_PROFILE_XCOLO_CHECKPOINT_DELAY:-}"
  [[ -n "${checkpoint_delay}" && "${checkpoint_delay}" =~ ^[0-9]+$ ]] || return 0

  ftctl_xcolo_qmp_require_ok "${FTCTL_PROFILE_PRIMARY_URI}" "${vm}" \
    "{\"execute\":\"migrate-set-parameters\",\"arguments\":{\"x-checkpoint-delay\":${checkpoint_delay}}}" \
    "colo" "primary.migrate_set_parameters.pre_migrate" || {
      ftctl_state_set "${vm}" \
        "xcolo_primary_checkpoint_delay_ready=no" \
        "xcolo_primary_checkpoint_delay_expected=${checkpoint_delay}" \
        "xcolo_primary_checkpoint_delay_reason=set_failed" \
        "last_error=primary_checkpoint_parameter_set_failed"
      ftctl_log_event "colo" "primary.checkpoint_delay.pre_migrate_gate" "fail" "${vm}" "" \
        "expected=${checkpoint_delay} reason=set_failed"
      return 1
    }

  actual_delay="$(ftctl_xcolo_query_primary_checkpoint_delay_value "${vm}")"
  ftctl_state_set "${vm}" \
    "xcolo_primary_checkpoint_delay_expected=${checkpoint_delay}" \
    "xcolo_primary_checkpoint_delay_actual=${actual_delay}"
  if [[ "${actual_delay}" != "${checkpoint_delay}" ]]; then
    ftctl_state_set "${vm}" \
      "xcolo_primary_checkpoint_delay_ready=no" \
      "xcolo_primary_checkpoint_delay_reason=verify_failed" \
      "last_error=primary_checkpoint_parameter_set_failed"
    ftctl_log_event "colo" "primary.checkpoint_delay.pre_migrate_gate" "fail" "${vm}" "" \
      "expected=${checkpoint_delay} actual=${actual_delay} reason=verify_failed"
    return 1
  fi

  ftctl_state_set "${vm}" \
    "xcolo_primary_checkpoint_delay_ready=yes" \
    "xcolo_primary_checkpoint_delay_reason=" \
    "xcolo_primary_checkpoint_delay_pre_migrate=${checkpoint_delay}"
  ftctl_log_event "colo" "primary.checkpoint_delay.pre_migrate_gate" "ok" "${vm}" "" \
    "expected=${checkpoint_delay} actual=${actual_delay}"
}

ftctl_xcolo_verify_checkpoint_delay_after_start() {
  local vm="${1-}"
  local checkpoint_delay actual_delay

  checkpoint_delay="${FTCTL_PROFILE_XCOLO_CHECKPOINT_DELAY:-}"
  [[ -n "${checkpoint_delay}" && "${checkpoint_delay}" =~ ^[0-9]+$ ]] || return 0

  actual_delay="$(ftctl_xcolo_query_primary_checkpoint_delay_value "${vm}")"
  ftctl_state_set "${vm}" \
    "xcolo_primary_checkpoint_delay_post_start_actual=${actual_delay}"
  [[ "${actual_delay}" == "${checkpoint_delay}" ]]
}

ftctl_xcolo_primary_invalid_message_observed() {
  local vm="${1-}"
  local desc=""

  ftctl_xcolo_query_migrate_error_desc "${FTCTL_PROFILE_PRIMARY_URI}" "${vm}" desc || true
  [[ "${desc}" == *"Received invalid message"* ]]
}

ftctl_xcolo_capture_post_migrate_transition_state() {
  local vm="${1-}"
  local secondary_vm="${2-}"
  local phase="${3:-pre_activation}"
  local expected_filter_status="${4:-off}"
  local primary_migrate="" secondary_migrate="" primary_colo="" secondary_colo=""
  local primary_migrate_error_desc="" secondary_migrate_error_desc=""
  local invalid_message="no"

  ftctl_xcolo_query_migrate_status "${FTCTL_PROFILE_PRIMARY_URI}" "${vm}" primary_migrate || true
  ftctl_xcolo_query_migrate_status "${FTCTL_PROFILE_SECONDARY_URI}" "${secondary_vm}" secondary_migrate || true
  ftctl_xcolo_query_colo_mode "${FTCTL_PROFILE_PRIMARY_URI}" "${vm}" primary_colo || true
  ftctl_xcolo_query_colo_mode "${FTCTL_PROFILE_SECONDARY_URI}" "${secondary_vm}" secondary_colo || true
  if [[ "${primary_migrate}" == "failed" ]]; then
    ftctl_xcolo_query_migrate_error_desc "${FTCTL_PROFILE_PRIMARY_URI}" "${vm}" primary_migrate_error_desc || true
  fi
  if [[ "${secondary_migrate}" == "failed" ]]; then
    ftctl_xcolo_query_migrate_error_desc "${FTCTL_PROFILE_SECONDARY_URI}" "${secondary_vm}" secondary_migrate_error_desc || true
  fi
  if [[ "${primary_migrate_error_desc}" == *"Received invalid message"* ]] || ftctl_xcolo_primary_invalid_message_observed "${vm}"; then
    invalid_message="yes"
  fi

  ftctl_xcolo_collect_primary_filter_qom_state "${vm}" "${expected_filter_status}" || true
  ftctl_xcolo_capture_socket_snapshot "${vm}" "post_migrate_${phase}" || true
  ftctl_state_set "${vm}" \
    "xcolo_post_migrate_${phase}_primary_migrate_status=${primary_migrate}" \
    "xcolo_post_migrate_${phase}_secondary_migrate_status=${secondary_migrate}" \
    "xcolo_post_migrate_${phase}_primary_colo_mode=${primary_colo}" \
    "xcolo_post_migrate_${phase}_secondary_colo_mode=${secondary_colo}" \
    "xcolo_post_migrate_${phase}_primary_migrate_error_desc=${primary_migrate_error_desc}" \
    "xcolo_post_migrate_${phase}_secondary_migrate_error_desc=${secondary_migrate_error_desc}" \
    "xcolo_post_migrate_${phase}_invalid_message=${invalid_message}" \
    "xcolo_post_migrate_${phase}_filter_expected_status=${expected_filter_status}" \
    "xcolo_post_migrate_${phase}_filter_qom_ready=$(ftctl_state_get "${vm}" "xcolo_primary_filter_qom_ready" 2>/dev/null || true)" \
    "xcolo_post_migrate_${phase}_filter_qom_reason=$(ftctl_state_get "${vm}" "xcolo_primary_filter_qom_reason" 2>/dev/null || true)"
  ftctl_log_event "colo" "xcolo.post_migrate_transition" "ok" "${vm}" "" \
    "phase=${phase} filter_expected=${expected_filter_status} primary_migrate=${primary_migrate} secondary_migrate=${secondary_migrate} primary_colo=${primary_colo} secondary_colo=${secondary_colo} invalid_message=${invalid_message}"
}

ftctl_xcolo_gate_post_migrate_before_filter_activation() {
  local vm="${1-}"
  local secondary_vm="${2-}"
  local timeout="${FTCTL_XCOLO_POST_MIGRATE_PRE_ACTIVATION_WAIT_SEC:-5}"
  local i primary_migrate secondary_migrate invalid_message

  [[ "${timeout}" =~ ^[0-9]+$ && "${timeout}" -gt 0 ]] || timeout="5"

  ftctl_state_set "${vm}" \
    "xcolo_primary_filter_activation_stage=post_migrate_pre_activation" \
    "xcolo_primary_filter_status_pre_activation=off"

  for ((i=0; i<timeout; i++)); do
    ftctl_xcolo_capture_post_migrate_transition_state "${vm}" "${secondary_vm}" "pre_activation" "off"
    primary_migrate="$(ftctl_state_get "${vm}" "xcolo_post_migrate_pre_activation_primary_migrate_status" 2>/dev/null || true)"
    secondary_migrate="$(ftctl_state_get "${vm}" "xcolo_post_migrate_pre_activation_secondary_migrate_status" 2>/dev/null || true)"
    invalid_message="$(ftctl_state_get "${vm}" "xcolo_post_migrate_pre_activation_invalid_message" 2>/dev/null || true)"
    if [[ "${invalid_message}" == "yes" ]]; then
      ftctl_state_set "${vm}" \
        "xcolo_protocol_failure_phase=pre_filter_activation" \
        "last_error=xcolo_migrate_stream_failed_before_filter_activation"
      ftctl_log_event "colo" "xcolo.post_migrate_pre_activation_gate" "fail" "${vm}" "" \
        "reason=invalid_message_before_filter_activation primary_migrate=${primary_migrate} secondary_migrate=${secondary_migrate}"
      return 1
    fi
    if [[ "${primary_migrate}" == "active" && ( "${secondary_migrate}" == "colo" || "${secondary_migrate}" == "active" ) ]]; then
      ftctl_log_event "colo" "xcolo.post_migrate_pre_activation_gate" "ok" "${vm}" "" \
        "primary_migrate=${primary_migrate} secondary_migrate=${secondary_migrate}"
      return 0
    fi
    sleep 1
  done

  ftctl_state_set "${vm}" \
    "xcolo_protocol_failure_phase=role_transition_pre_activation_timeout" \
    "last_error=xcolo_post_migrate_pre_activation_timeout"
  ftctl_log_event "colo" "xcolo.post_migrate_pre_activation_gate" "fail" "${vm}" "" \
    "reason=timeout primary_migrate=$(ftctl_state_get "${vm}" "xcolo_post_migrate_pre_activation_primary_migrate_status" 2>/dev/null || true) secondary_migrate=$(ftctl_state_get "${vm}" "xcolo_post_migrate_pre_activation_secondary_migrate_status" 2>/dev/null || true)"
  return 1
}

ftctl_xcolo_activate_primary_filters_after_migrate() {
  local vm="${1-}"
  local secondary_vm="${2-}"
  local reason invalid_message

  ftctl_xcolo_capture_post_migrate_transition_state "${vm}" "${secondary_vm}" "startup_active_validation" "on"
  if ! ftctl_xcolo_require_primary_filter_qom_ready "${vm}" "post_migrate_startup_active" "on"; then
    reason="$(ftctl_state_get "${vm}" "xcolo_primary_filter_qom_reason" 2>/dev/null || true)"
    [[ -n "${reason}" ]] || reason="startup_active_filter_not_on"
    ftctl_state_set "${vm}" \
      "xcolo_primary_net_filters_activated=false" \
      "xcolo_primary_filter_activation_failed_reason=${reason}" \
      "xcolo_protocol_failure_phase=post_migrate_startup_active_filter_validation" \
      "last_error=xcolo_startup_active_filter_validation_failed"
    ftctl_log_event "colo" "xcolo.post_migrate_filter_activation" "fail" "${vm}" "" \
      "mode=startup-active reason=${reason}"
    return 1
  fi

  ftctl_xcolo_wait_primary_filter_chardev_binding "${vm}" || true
  ftctl_xcolo_capture_post_migrate_transition_state "${vm}" "${secondary_vm}" "post_activation_validation" "on"
  ftctl_state_set "${vm}" \
    "xcolo_primary_filter_activation_stage=premigrate_active" \
    "xcolo_primary_filter_status_pre_migrate=on" \
    "xcolo_primary_filter_status_post_migrate=on" \
    "xcolo_primary_filter_status_post_activation=on" \
    "xcolo_primary_net_filters_activation_mode=startup-active" \
    "xcolo_primary_net_filters_activation_order=premigrate-active" \
    "xcolo_primary_net_filters_activated=true" \
    "xcolo_primary_filter_runtime_status=on"
  invalid_message="$(ftctl_state_get "${vm}" "xcolo_post_migrate_post_activation_validation_invalid_message" 2>/dev/null || true)"
  if [[ "${invalid_message}" == "yes" ]]; then
    ftctl_xcolo_classify_startup_active_stream_failure "${vm}" "${secondary_vm}" || true
    ftctl_log_event "colo" "xcolo.post_migrate_filter_activation" "fail" "${vm}" "" \
      "mode=startup-active reason=$(ftctl_state_get "${vm}" "xcolo_protocol_invalid_message_reason" 2>/dev/null || printf '%s' invalid_message_after_migrate)"
    return 1
  fi

  ftctl_log_event "colo" "xcolo.post_migrate_filter_activation" "ok" "${vm}" "" \
    "mode=startup-active action=validate-only"
}

ftctl_xcolo_execute_handshake_with_nodes() {
  local vm="${1-}"
  local secondary_vm="${2-}"
  local export_node="${3-}"
  local nbd_host nbd_port

  ftctl_xcolo_parse_tcp_endpoint "${FTCTL_PROFILE_XCOLO_NBD_ENDPOINT}" nbd_host nbd_port

  ftctl_xcolo_qmp_require_ok "${FTCTL_PROFILE_SECONDARY_URI}" "${secondary_vm}" \
    '{"execute":"qmp_capabilities"}' "colo" "secondary.qmp_capabilities" || return 1
  ftctl_xcolo_set_and_verify_migrate_capabilities "${FTCTL_PROFILE_SECONDARY_URI}" "${secondary_vm}" "${vm}" "secondary" "secondary" || return 1
  ftctl_xcolo_qmp_require_ok "${FTCTL_PROFILE_SECONDARY_URI}" "${secondary_vm}" \
    "{\"execute\":\"nbd-server-start\",\"arguments\":{\"addr\":{\"type\":\"inet\",\"data\":{\"host\":\"${nbd_host}\",\"port\":\"${nbd_port}\"}}}}" \
    "colo" "secondary.nbd_server_start" || return 1
  ftctl_xcolo_qmp_require_ok "${FTCTL_PROFILE_SECONDARY_URI}" "${secondary_vm}" \
    "{\"execute\":\"nbd-server-add\",\"arguments\":{\"device\":\"${export_node}\",\"writable\":true}}" \
    "colo" "secondary.nbd_server_add" || return 1

  ftctl_xcolo_qmp_require_ok "${FTCTL_PROFILE_PRIMARY_URI}" "${vm}" \
    '{"execute":"qmp_capabilities"}' "colo" "primary.qmp_capabilities" || return 1
  ftctl_xcolo_qmp_require_ok "${FTCTL_PROFILE_PRIMARY_URI}" "${vm}" \
    "{\"execute\":\"blockdev-add\",\"arguments\":{\"driver\":\"nbd\",\"node-name\":\"${FTCTL_PROFILE_XCOLO_NBD_NODE}\",\"server\":{\"type\":\"inet\",\"host\":\"${nbd_host}\",\"port\":\"${nbd_port}\"},\"export\":\"${export_node}\",\"detect-zeroes\":\"on\"}}" \
    "colo" "primary.blockdev_add" || return 1
  ftctl_xcolo_qmp_require_ok "${FTCTL_PROFILE_PRIMARY_URI}" "${vm}" \
    "{\"execute\":\"x-blockdev-change\",\"arguments\":{\"parent\":\"colo-disk0\",\"node\":\"${FTCTL_PROFILE_XCOLO_NBD_NODE}\"}}" \
    "colo" "primary.x_blockdev_change" || return 1
  ftctl_xcolo_attach_primary_net_filters "${vm}" || return 1
  ftctl_xcolo_set_and_verify_migrate_capabilities "${FTCTL_PROFILE_PRIMARY_URI}" "${vm}" "${vm}" "primary" "primary" || return 1
  ftctl_xcolo_require_checkpoint_delay_before_migrate "${vm}" || return 1
  ftctl_xcolo_record_pre_migrate_evidence "${vm}" "on" || true
  ftctl_xcolo_preflight_firewall_contract "${vm}" || return 1
  ftctl_xcolo_require_primary_filter_cmdline_ready "${vm}" "pre_migrate" || return 1
  ftctl_xcolo_require_topology_audit_ready "${vm}" "${secondary_vm}" "pre_migrate" || return 1
  ftctl_xcolo_qmp_require_ok "${FTCTL_PROFILE_PRIMARY_URI}" "${vm}" \
    "{\"execute\":\"migrate\",\"arguments\":{\"uri\":\"${FTCTL_PROFILE_XCOLO_MIGRATE_URI}\"}}" \
    "colo" "primary.migrate" || return 1
  ftctl_xcolo_activate_primary_filters_after_migrate "${vm}" "${secondary_vm}" || return 1
}

ftctl_xcolo_execute_handshake_with_disk_plan() {
  local vm="${1-}"
  local secondary_vm="${2-}"
  local disk_plan="${3-}"
  local nbd_host nbd_port entry rest target primary_source primary_format primary_dtype secondary_dest
  local suffix primary_base_node primary_qdev primary_overlay secondary_base_node nbd_node colo_node export_node
  local -a _ftctl_xcolo_plan_entries=()

  ftctl_xcolo_parse_tcp_endpoint "${FTCTL_PROFILE_XCOLO_NBD_ENDPOINT}" nbd_host nbd_port

  ftctl_xcolo_qmp_require_ok "${FTCTL_PROFILE_SECONDARY_URI}" "${secondary_vm}" \
    '{"execute":"qmp_capabilities"}' "colo" "secondary.qmp_capabilities" || return 1
  ftctl_xcolo_set_and_verify_migrate_capabilities "${FTCTL_PROFILE_SECONDARY_URI}" "${secondary_vm}" "${vm}" "secondary" "secondary" || return 1
  ftctl_xcolo_qmp_require_ok "${FTCTL_PROFILE_SECONDARY_URI}" "${secondary_vm}" \
    "{\"execute\":\"nbd-server-start\",\"arguments\":{\"addr\":{\"type\":\"inet\",\"data\":{\"host\":\"${nbd_host}\",\"port\":\"${nbd_port}\"}}}}" \
    "colo" "secondary.nbd_server_start" || return 1

  IFS=';' read -r -a _ftctl_xcolo_plan_entries <<< "${disk_plan}"
  for entry in "${_ftctl_xcolo_plan_entries[@]}"; do
    [[ -n "${entry}" ]] || continue
    target="${entry%%|*}"
    rest="${entry#*|}"
    primary_source="${rest%%|*}"
    rest="${rest#*|}"
    primary_format="${rest%%|*}"
    rest="${rest#*|}"
    primary_dtype="${rest%%|*}"
    secondary_dest="${rest#*|}"
    : "${primary_source}${primary_format}${primary_dtype}${secondary_dest}"
    suffix="$(ftctl_xcolo_disk_suffix "${target}")"
    secondary_base_node="$(ftctl_state_get "${vm}" "xcolo_disk_${suffix}_secondary_base_node" 2>/dev/null || true)"
    export_node="${secondary_base_node}"
    [[ -n "${secondary_base_node}" ]] || return 1
    ftctl_xcolo_qmp_require_ok "${FTCTL_PROFILE_SECONDARY_URI}" "${secondary_vm}" \
      "{\"execute\":\"nbd-server-add\",\"arguments\":{\"device\":\"${export_node}\",\"writable\":true}}" \
      "colo" "secondary.nbd_server_add.${suffix}" || return 1
    ftctl_state_set "${vm}" "xcolo_disk_${suffix}_secondary_export_node=${export_node}"
  done

  ftctl_xcolo_qmp_require_ok "${FTCTL_PROFILE_PRIMARY_URI}" "${vm}" \
    '{"execute":"qmp_capabilities"}' "colo" "primary.qmp_capabilities" || return 1

  for entry in "${_ftctl_xcolo_plan_entries[@]}"; do
    [[ -n "${entry}" ]] || continue
    target="${entry%%|*}"
    suffix="$(ftctl_xcolo_disk_suffix "${target}")"
    primary_base_node="$(ftctl_state_get "${vm}" "xcolo_disk_${suffix}_primary_base_node" 2>/dev/null || true)"
    primary_qdev="$(ftctl_state_get "${vm}" "xcolo_disk_${suffix}_primary_base_qdev" 2>/dev/null || true)"
    primary_overlay="$(ftctl_state_get "${vm}" "xcolo_disk_${suffix}_primary_overlay" 2>/dev/null || true)"
    secondary_base_node="$(ftctl_state_get "${vm}" "xcolo_disk_${suffix}_secondary_base_node" 2>/dev/null || true)"
    nbd_node="${FTCTL_PROFILE_XCOLO_NBD_NODE}-${suffix}"
    colo_node="ftctl-colo-${suffix}"
    export_node="${secondary_base_node}"
    [[ -n "${primary_base_node}" && -n "${primary_qdev}" && -n "${primary_overlay}" && -n "${secondary_base_node}" ]] || return 1
    ftctl_xcolo_qmp_require_ok "${FTCTL_PROFILE_PRIMARY_URI}" "${vm}" \
      "{\"execute\":\"blockdev-add\",\"arguments\":{\"driver\":\"nbd\",\"node-name\":\"${nbd_node}\",\"server\":{\"type\":\"inet\",\"host\":\"${nbd_host}\",\"port\":\"${nbd_port}\"},\"export\":\"${export_node}\",\"detect-zeroes\":\"on\"}}" \
      "colo" "primary.blockdev_add.${suffix}" || return 1
    ftctl_xcolo_attach_primary_block_graph_with_remote "${vm}" "${primary_base_node}" "${primary_overlay}" "${primary_qdev}" "${target}" "${nbd_node}" || return 1
  done

  ftctl_xcolo_attach_primary_net_filters "${vm}" || return 1
  ftctl_xcolo_set_and_verify_migrate_capabilities "${FTCTL_PROFILE_PRIMARY_URI}" "${vm}" "${vm}" "primary" "primary" || return 1
  ftctl_xcolo_require_checkpoint_delay_before_migrate "${vm}" || return 1
  ftctl_xcolo_record_pre_migrate_evidence "${vm}" "on" || true
  ftctl_xcolo_preflight_firewall_contract "${vm}" || return 1
  ftctl_xcolo_require_primary_filter_cmdline_ready "${vm}" "pre_migrate" || return 1
  ftctl_xcolo_require_topology_audit_ready "${vm}" "${secondary_vm}" "pre_migrate" || return 1
  ftctl_xcolo_qmp_require_ok "${FTCTL_PROFILE_PRIMARY_URI}" "${vm}" \
    "{\"execute\":\"migrate\",\"arguments\":{\"uri\":\"${FTCTL_PROFILE_XCOLO_MIGRATE_URI}\"}}" \
    "colo" "primary.migrate" || return 1
  ftctl_xcolo_activate_primary_filters_after_migrate "${vm}" "${secondary_vm}" || return 1
}

ftctl_xcolo_shutdown_primary_for_conversion() {
  local vm="${1-}"
  local out err rc state i action_timeout

  state="$(ftctl_xcolo_primary_domain_state "${vm}" 2>/dev/null || echo "unknown")"
  case "${state}" in
    shut\ off|shutoff|unknown) return 0 ;;
  esac

  action_timeout="${FTCTL_FENCING_TIMEOUT_SEC:-15}"
  if [[ -z "${action_timeout}" || ! "${action_timeout}" =~ ^[0-9]+$ || "${action_timeout}" -lt 15 ]]; then
    action_timeout=15
  fi

  out=""
  err=""
  rc=0
  ftctl_virsh "${action_timeout}" out err rc -- -c "${FTCTL_PROFILE_PRIMARY_URI}" shutdown "${vm}" || true
  : "${out}${err}"
  ftctl_log_event "colo" "primary.shutdown_for_conversion" "$(ftctl_result_from_rc "${rc}")" "${vm}" "${rc}" "state=${state}"

  for ((i=0; i<30; i++)); do
    state="$(ftctl_xcolo_primary_domain_state "${vm}" 2>/dev/null || echo "unknown")"
    case "${state}" in
      shut\ off|shutoff|unknown) return 0 ;;
    esac
    sleep 1
  done

  out=""
  err=""
  rc=0
  ftctl_virsh "${action_timeout}" out err rc -- -c "${FTCTL_PROFILE_PRIMARY_URI}" destroy "${vm}" || true
  : "${out}${err}"
  ftctl_log_event "colo" "primary.destroy_for_conversion" "$(ftctl_result_from_rc "${rc}")" "${vm}" "${rc}" ""
  state="$(ftctl_xcolo_primary_domain_state "${vm}" 2>/dev/null || echo "unknown")"
  case "${state}" in
    shut\ off|shutoff|unknown) return 0 ;;
    *) return 1 ;;
  esac
}

ftctl_xcolo_create_primary_generated() {
  local vm="${1-}"
  local generated_xml="${2-}"
  local out err rc

  [[ -n "${generated_xml}" && -f "${generated_xml}" ]] || return 1
  ftctl_xml_validate_xcolo_iothread_contract "${generated_xml}" || {
    ftctl_log_event "colo" "primary.create_generated.iothread-contract" "fail" "${vm}" "" "path=${generated_xml}"
    return 1
  }
  ftctl_primary_map_local_krbd_paths_from_xml "${vm}" "${generated_xml}" || {
    ftctl_log_event "colo" "primary.create_generated.rbd-map" "fail" "${vm}" "" "path=${generated_xml}"
    return 1
  }
  out=""
  err=""
  rc=0
  ftctl_virsh "$(ftctl_xcolo_domain_create_timeout_sec)" out err rc -- -c "${FTCTL_PROFILE_PRIMARY_URI}" create "${generated_xml}" || true
  : "${out}${err}"
  if [[ "${rc}" != "0" ]]; then
    ftctl_log_event "colo" "primary.create_generated" "fail" "${vm}" "${rc}" "path=${generated_xml}"
    return "${rc}"
  fi
  ftctl_log_event "colo" "primary.create_generated" "ok" "${vm}" "" "path=${generated_xml}"
}

ftctl_xcolo_domain_create_timeout_sec() {
  local timeout_sec="${FTCTL_XCOLO_DOMAIN_CREATE_TIMEOUT_SEC:-45}"
  if [[ -z "${timeout_sec}" || ! "${timeout_sec}" =~ ^[0-9]+$ || "${timeout_sec}" -lt 15 ]]; then
    timeout_sec=45
  fi
  printf '%s\n' "${timeout_sec}"
}

ftctl_xcolo_local_tcp_listen_port_ready() {
  local port="${1-}"
  [[ -n "${port}" && "${port}" =~ ^[0-9]+$ ]] || return 1
  command -v ss >/dev/null 2>&1 || return 2
  ss -H -ltn 2>/dev/null | awk -v p=":${port}" '
    $4 == p || $4 ~ p "$" { found=1 }
    END { exit found ? 0 : 1 }
  '
}

ftctl_xcolo_local_tcp_established_port_ready() {
  local port="${1-}"
  [[ -n "${port}" && "${port}" =~ ^[0-9]+$ ]] || return 1
  command -v ss >/dev/null 2>&1 || return 2
  ss -H -tn 2>/dev/null | awk -v p=":${port}" '
    $1 == "ESTAB" && ($4 == p || $4 ~ p "$") { found=1 }
    END { exit found ? 0 : 1 }
  '
}

ftctl_xcolo_local_tcp_state_bool() {
  local check="${1-}"
  local port="${2-}"
  local out_var="${3}"
  local value="no"

  case "${check}" in
    listen)
      if ftctl_xcolo_local_tcp_listen_port_ready "${port}"; then
        value="yes"
      fi
      ;;
    established)
      if ftctl_xcolo_local_tcp_established_port_ready "${port}"; then
        value="yes"
      fi
      ;;
    *)
      return 1
      ;;
  esac
  printf -v "${out_var}" '%s' "${value}"
}

ftctl_xcolo_socket_summary_from_ss() {
  local payload="${1-}"
  local port="${2-}"
  local state="closed"

  [[ -n "${port}" ]] || {
    printf '%s\n' "unknown"
    return 0
  }
  if printf '%s\n' "${payload}" | awk -v p=":${port}" '$1 ~ /^LISTEN/ && ($4 == p || $4 ~ p "$") {found=1} END {exit found ? 0 : 1}'; then
    state="listen"
  elif printf '%s\n' "${payload}" | awk -v p=":${port}" '$1 == "ESTAB" && ($4 == p || $4 ~ p "$" || $5 == p || $5 ~ p "$") {found=1} END {exit found ? 0 : 1}'; then
    state="established"
  elif ! command -v ss >/dev/null 2>&1; then
    state="unknown"
  fi
  printf '%s\n' "${state}"
}

ftctl_xcolo_socket_snapshot_cmd() {
  cat <<'EOF'
set -euo pipefail
if command -v ss >/dev/null 2>&1; then
  ss -H -tanp 2>/dev/null | awk '$4 ~ /:(9000|9001|9002|9003|9004|9005|9998|10809)$/ || $5 ~ /:(9000|9001|9002|9003|9004|9005|9998|10809)$/ {print}'
else
  echo "ss_missing"
fi
EOF
}

ftctl_xcolo_socket_snapshot_local() {
  local out_var="${1}"
  local err_var="${2}"
  local rc_var="${3}"
  local cmd out="" err="" rc=0

  cmd="$(ftctl_xcolo_socket_snapshot_cmd)"
  ftctl_cmd_run "${FTCTL_BLOCKCOPY_WAIT_TIMEOUT_SEC:-15}" out err rc -- bash -lc "${cmd}" || true
  printf -v "${out_var}" '%s' "${out}"
  printf -v "${err_var}" '%s' "${err}"
  printf -v "${rc_var}" '%s' "${rc}"
}

ftctl_xcolo_socket_snapshot_remote() {
  local host="${1-}"
  local user="${2-}"
  local out_var="${3}"
  local err_var="${4}"
  local rc_var="${5}"
  local cmd out="" err="" rc=0

  cmd="$(ftctl_xcolo_socket_snapshot_cmd)"
  ftctl_blockcopy_remote_exec "${host}" "${user}" out err rc "${cmd}" || true
  printf -v "${out_var}" '%s' "${out}"
  printf -v "${err_var}" '%s' "${err}"
  printf -v "${rc_var}" '%s' "${rc}"
}

ftctl_xcolo_capture_socket_snapshot() {
  local vm="${1-}"
  local phase="${2:-runtime}"
  local host="" user=""
  local primary_out="" primary_err="" secondary_out="" secondary_err=""
  local primary_rc=0 secondary_rc=0
  local ctrl_port mirror_port compare_port compare_local_port compare_out_port nbd_port

  [[ -n "${vm}" ]] || return 1
  ctrl_port="${FTCTL_XCOLO_CTRL_PORT:-9998}"
  mirror_port="${FTCTL_XCOLO_MIRROR_PORT:-9003}"
  compare_port="${FTCTL_XCOLO_COMPARE_PORT:-9004}"
  compare_local_port="${FTCTL_XCOLO_COMPARE_LOCAL_PORT:-9001}"
  compare_out_port="${FTCTL_XCOLO_COMPARE_OUT_PORT:-9005}"
  nbd_port="${FTCTL_PROFILE_XCOLO_NBD_ENDPOINT##*:}"
  [[ "${nbd_port}" =~ ^[0-9]+$ ]] || nbd_port="${FTCTL_REMOTE_NBD_PORT_BASE:-10809}"

  ftctl_xcolo_socket_snapshot_local primary_out primary_err primary_rc
  if ftctl_blockcopy_remote_target_host_user host user; then
    ftctl_xcolo_socket_snapshot_remote "${host}" "${user}" secondary_out secondary_err secondary_rc
  else
    secondary_out=""
    secondary_err="target_unresolved"
    secondary_rc=2
  fi
  : "${primary_err}${secondary_err}"

  ftctl_state_set "${vm}" \
    "xcolo_socket_${phase}_primary_rc=${primary_rc}" \
    "xcolo_socket_${phase}_secondary_rc=${secondary_rc}" \
    "xcolo_socket_${phase}_primary_9998=$(ftctl_xcolo_socket_summary_from_ss "${primary_out}" "${ctrl_port}")" \
    "xcolo_socket_${phase}_primary_9003=$(ftctl_xcolo_socket_summary_from_ss "${primary_out}" "${mirror_port}")" \
    "xcolo_socket_${phase}_primary_9004=$(ftctl_xcolo_socket_summary_from_ss "${primary_out}" "${compare_port}")" \
    "xcolo_socket_${phase}_primary_9001=$(ftctl_xcolo_socket_summary_from_ss "${primary_out}" "${compare_local_port}")" \
    "xcolo_socket_${phase}_primary_9005=$(ftctl_xcolo_socket_summary_from_ss "${primary_out}" "${compare_out_port}")" \
    "xcolo_socket_${phase}_primary_nbd=$(ftctl_xcolo_socket_summary_from_ss "${primary_out}" "${nbd_port}")" \
    "xcolo_socket_${phase}_secondary_9998=$(ftctl_xcolo_socket_summary_from_ss "${secondary_out}" "${ctrl_port}")" \
    "xcolo_socket_${phase}_secondary_9003=$(ftctl_xcolo_socket_summary_from_ss "${secondary_out}" "${mirror_port}")" \
    "xcolo_socket_${phase}_secondary_9004=$(ftctl_xcolo_socket_summary_from_ss "${secondary_out}" "${compare_port}")" \
    "xcolo_socket_${phase}_secondary_nbd=$(ftctl_xcolo_socket_summary_from_ss "${secondary_out}" "${nbd_port}")" \
    "xcolo_socket_${phase}_loopback_9001=$(ftctl_xcolo_socket_summary_from_ss "${primary_out}" "${compare_local_port}")" \
    "xcolo_socket_${phase}_loopback_9005=$(ftctl_xcolo_socket_summary_from_ss "${primary_out}" "${compare_out_port}")"

  ftctl_log_event "colo" "xcolo.socket_snapshot" "ok" "${vm}" "" \
    "phase=${phase} primary_rc=${primary_rc} secondary_rc=${secondary_rc} primary_9003=$(ftctl_xcolo_socket_summary_from_ss "${primary_out}" "${mirror_port}") primary_9004=$(ftctl_xcolo_socket_summary_from_ss "${primary_out}" "${compare_port}") secondary_9003=$(ftctl_xcolo_socket_summary_from_ss "${secondary_out}" "${mirror_port}") secondary_9004=$(ftctl_xcolo_socket_summary_from_ss "${secondary_out}" "${compare_port}")"
}

ftctl_xcolo_capture_primary_channel_state() {
  local vm="${1-}"
  local mirror_port compare_port compare_local_port compare_out_port
  local mirror_established compare_established compare_local_established compare_out_established
  local mirror_listen compare_listen compare_local_listen compare_out_listen

  mirror_port="${FTCTL_XCOLO_MIRROR_PORT:-9003}"
  compare_port="${FTCTL_XCOLO_COMPARE_PORT:-9004}"
  compare_local_port="${FTCTL_XCOLO_COMPARE_LOCAL_PORT:-9001}"
  compare_out_port="${FTCTL_XCOLO_COMPARE_OUT_PORT:-9005}"

  ftctl_xcolo_local_tcp_state_bool established "${mirror_port}" mirror_established || mirror_established="unknown"
  ftctl_xcolo_local_tcp_state_bool established "${compare_port}" compare_established || compare_established="unknown"
  ftctl_xcolo_local_tcp_state_bool established "${compare_local_port}" compare_local_established || compare_local_established="unknown"
  ftctl_xcolo_local_tcp_state_bool established "${compare_out_port}" compare_out_established || compare_out_established="unknown"
  ftctl_xcolo_local_tcp_state_bool listen "${mirror_port}" mirror_listen || mirror_listen="unknown"
  ftctl_xcolo_local_tcp_state_bool listen "${compare_port}" compare_listen || compare_listen="unknown"
  ftctl_xcolo_local_tcp_state_bool listen "${compare_local_port}" compare_local_listen || compare_local_listen="unknown"
  ftctl_xcolo_local_tcp_state_bool listen "${compare_out_port}" compare_out_listen || compare_out_listen="unknown"

  ftctl_state_set "${vm}" \
    "xcolo_channel_mirror_port=${mirror_port}" \
    "xcolo_channel_compare_port=${compare_port}" \
    "xcolo_channel_compare_local_port=${compare_local_port}" \
    "xcolo_channel_compare_out_port=${compare_out_port}" \
    "xcolo_channel_mirror_established=${mirror_established}" \
    "xcolo_channel_compare_established=${compare_established}" \
    "xcolo_channel_compare_local_established=${compare_local_established}" \
    "xcolo_channel_compare_out_established=${compare_out_established}" \
    "xcolo_channel_mirror_listen=${mirror_listen}" \
    "xcolo_channel_compare_listen=${compare_listen}" \
    "xcolo_channel_compare_local_listen=${compare_local_listen}" \
    "xcolo_channel_compare_out_listen=${compare_out_listen}"
}

ftctl_xcolo_primary_channels_ready() {
  local vm="${1-}"
  ftctl_xcolo_capture_primary_channel_state "${vm}"
  [[ "$(ftctl_state_get "${vm}" "xcolo_channel_mirror_established" 2>/dev/null || true)" == "yes" &&
     "$(ftctl_state_get "${vm}" "xcolo_channel_compare_established" 2>/dev/null || true)" == "yes" &&
     "$(ftctl_state_get "${vm}" "xcolo_channel_compare_local_established" 2>/dev/null || true)" == "yes" &&
     "$(ftctl_state_get "${vm}" "xcolo_channel_compare_out_established" 2>/dev/null || true)" == "yes" ]]
}

ftctl_xcolo_primary_channels_premigrate_ready() {
  local vm="${1-}"
  local mirror_established mirror_listen compare_established compare_listen

  ftctl_xcolo_capture_primary_channel_state "${vm}"
  mirror_established="$(ftctl_state_get "${vm}" "xcolo_channel_mirror_established" 2>/dev/null || true)"
  mirror_listen="$(ftctl_state_get "${vm}" "xcolo_channel_mirror_listen" 2>/dev/null || true)"
  compare_established="$(ftctl_state_get "${vm}" "xcolo_channel_compare_established" 2>/dev/null || true)"
  compare_listen="$(ftctl_state_get "${vm}" "xcolo_channel_compare_listen" 2>/dev/null || true)"

  [[ ( "${mirror_established}" == "yes" || "${mirror_listen}" == "yes" ) &&
     ( "${compare_established}" == "yes" || "${compare_listen}" == "yes" ) &&
     "$(ftctl_state_get "${vm}" "xcolo_channel_compare_local_established" 2>/dev/null || true)" == "yes" &&
     "$(ftctl_state_get "${vm}" "xcolo_channel_compare_out_established" 2>/dev/null || true)" == "yes" ]]
}

ftctl_xcolo_primary_channel_failure_reason() {
  local vm="${1-}"
  local reason="colo_compare_channel_not_established"

  case "$(ftctl_state_get "${vm}" "xcolo_channel_mirror_established" 2>/dev/null || true)" in
    yes) ;;
    *) reason="colo_mirror_channel_not_established" ;;
  esac
  if [[ "${reason}" == "colo_compare_channel_not_established" ]]; then
    case "$(ftctl_state_get "${vm}" "xcolo_channel_compare_established" 2>/dev/null || true)" in
      yes) ;;
      *) reason="colo_compare_peer_channel_not_established" ;;
    esac
  fi
  if [[ "${reason}" == "colo_compare_channel_not_established" ]]; then
    case "$(ftctl_state_get "${vm}" "xcolo_channel_compare_local_established" 2>/dev/null || true)" in
      yes) ;;
      *) reason="colo_compare_loopback_in_not_established" ;;
    esac
  fi
  if [[ "${reason}" == "colo_compare_channel_not_established" ]]; then
    case "$(ftctl_state_get "${vm}" "xcolo_channel_compare_out_established" 2>/dev/null || true)" in
      yes) ;;
      *) reason="colo_compare_loopback_out_not_established" ;;
    esac
  fi
  printf '%s\n' "${reason}"
}

ftctl_xcolo_primary_premigrate_channel_failure_reason() {
  local vm="${1-}"
  local reason="colo_premigrate_channel_not_ready"
  local mirror_established mirror_listen compare_established compare_listen

  mirror_established="$(ftctl_state_get "${vm}" "xcolo_channel_mirror_established" 2>/dev/null || true)"
  mirror_listen="$(ftctl_state_get "${vm}" "xcolo_channel_mirror_listen" 2>/dev/null || true)"
  compare_established="$(ftctl_state_get "${vm}" "xcolo_channel_compare_established" 2>/dev/null || true)"
  compare_listen="$(ftctl_state_get "${vm}" "xcolo_channel_compare_listen" 2>/dev/null || true)"

  if [[ "${mirror_established}" != "yes" && "${mirror_listen}" != "yes" ]]; then
    reason="colo_mirror_channel_not_listening"
  elif [[ "${compare_established}" != "yes" && "${compare_listen}" != "yes" ]]; then
    reason="colo_compare_channel_not_listening"
  elif [[ "$(ftctl_state_get "${vm}" "xcolo_channel_compare_local_established" 2>/dev/null || true)" != "yes" ]]; then
    reason="colo_compare_loopback_in_not_established"
  elif [[ "$(ftctl_state_get "${vm}" "xcolo_channel_compare_out_established" 2>/dev/null || true)" != "yes" ]]; then
    reason="colo_compare_loopback_out_not_established"
  fi

  printf '%s\n' "${reason}"
}

ftctl_xcolo_validate_primary_channel_paths() {
  local vm="${1-}"
  local reason

  if ftctl_xcolo_primary_channels_premigrate_ready "${vm}"; then
    ftctl_log_event "colo" "primary.channel_paths" "ok" "${vm}" "" \
      "mode=pre_migrate mirror_port=$(ftctl_state_get "${vm}" "xcolo_channel_mirror_port" 2>/dev/null || true) compare_port=$(ftctl_state_get "${vm}" "xcolo_channel_compare_port" 2>/dev/null || true) compare_local_port=$(ftctl_state_get "${vm}" "xcolo_channel_compare_local_port" 2>/dev/null || true) compare_out_port=$(ftctl_state_get "${vm}" "xcolo_channel_compare_out_port" 2>/dev/null || true) mirror_listen=$(ftctl_state_get "${vm}" "xcolo_channel_mirror_listen" 2>/dev/null || true) compare_listen=$(ftctl_state_get "${vm}" "xcolo_channel_compare_listen" 2>/dev/null || true)"
    return 0
  fi

  reason="$(ftctl_xcolo_primary_premigrate_channel_failure_reason "${vm}")"
  ftctl_state_set "${vm}" "last_error=${reason}"
  ftctl_log_event "colo" "primary.channel_paths" "fail" "${vm}" "" \
    "mode=pre_migrate reason=${reason} mirror=$(ftctl_state_get "${vm}" "xcolo_channel_mirror_established" 2>/dev/null || true) mirror_listen=$(ftctl_state_get "${vm}" "xcolo_channel_mirror_listen" 2>/dev/null || true) compare=$(ftctl_state_get "${vm}" "xcolo_channel_compare_established" 2>/dev/null || true) compare_listen=$(ftctl_state_get "${vm}" "xcolo_channel_compare_listen" 2>/dev/null || true) compare_local=$(ftctl_state_get "${vm}" "xcolo_channel_compare_local_established" 2>/dev/null || true) compare_out=$(ftctl_state_get "${vm}" "xcolo_channel_compare_out_established" 2>/dev/null || true)"
  return 1
}

ftctl_xcolo_wait_primary_filter_chardev_binding() {
  local vm="${1-}"
  local timeout="${FTCTL_XCOLO_FILTER_BIND_WAIT_SEC:-5}"
  local interval="${FTCTL_XCOLO_FILTER_BIND_INTERVAL_SEC:-1}"
  local i attempts reason

  if [[ -z "${timeout}" || ! "${timeout}" =~ ^[0-9]+$ || "${timeout}" -lt 1 ]]; then
    timeout=5
  fi
  if [[ -z "${interval}" || ! "${interval}" =~ ^[0-9]+$ || "${interval}" -lt 1 ]]; then
    interval=1
  fi
  attempts=$(( (timeout + interval - 1) / interval ))
  [[ "${attempts}" -gt 0 ]] || attempts=1

  for ((i=0; i<attempts; i++)); do
    if ftctl_xcolo_collect_primary_chardev_binding_state "${vm}" "pre_migrate"; then
      ftctl_log_event "colo" "primary.filter_chardev_binding" "ok" "${vm}" "" \
        "attempts=$((i + 1)) phase=pre_migrate topology_aware=yes"
      return 0
    fi
    sleep "${interval}"
  done

  reason="$(ftctl_state_get "${vm}" "xcolo_primary_filter_chardev_reason" 2>/dev/null || true)"
  [[ -n "${reason}" ]] || reason="unknown"
  ftctl_state_set "${vm}" \
    "last_error=primary_filter_chardev_frontend_incomplete" \
    "xcolo_primary_filter_chardev_binding_failed_reason=${reason}"
  ftctl_log_event "colo" "primary.filter_chardev_binding" "fail" "${vm}" "" \
    "reason=${reason} attempts=${attempts} phase=pre_migrate topology_aware=yes"
  return 1
}

ftctl_xcolo_observe_primary_filter_chardev_binding() {
  local vm="${1-}"
  local timeout="${FTCTL_XCOLO_FILTER_BIND_WAIT_SEC:-5}"
  local interval="${FTCTL_XCOLO_FILTER_BIND_INTERVAL_SEC:-1}"
  local i attempts reason

  if [[ -z "${timeout}" || ! "${timeout}" =~ ^[0-9]+$ || "${timeout}" -lt 1 ]]; then
    timeout=5
  fi
  if [[ -z "${interval}" || ! "${interval}" =~ ^[0-9]+$ || "${interval}" -lt 1 ]]; then
    interval=1
  fi
  attempts=$(( (timeout + interval - 1) / interval ))
  [[ "${attempts}" -gt 0 ]] || attempts=1

  for ((i=0; i<attempts; i++)); do
    if ftctl_xcolo_collect_primary_chardev_binding_state "${vm}" "pre_migrate"; then
      ftctl_log_event "colo" "primary.filter_chardev_binding" "ok" "${vm}" "" \
        "attempts=$((i + 1)) phase=pre_cont topology_aware=yes"
      return 0
    fi
    sleep "${interval}"
  done

  reason="$(ftctl_state_get "${vm}" "xcolo_primary_filter_chardev_reason" 2>/dev/null || true)"
  [[ -n "${reason}" ]] || reason="unknown"
  ftctl_state_set "${vm}" \
    "xcolo_primary_filter_chardev_binding_deferred_reason=${reason}"
  ftctl_log_event "colo" "primary.filter_chardev_binding" "defer" "${vm}" "" \
    "reason=${reason} attempts=${attempts} phase=pre_cont topology_aware=yes"
  return 0
}

ftctl_xcolo_primary_create_async_done() {
  local handle="${1-}"
  local pid="" rc_file="" out_file="" err_file="" tmp_dir=""
  IFS='|' read -r pid rc_file out_file err_file tmp_dir <<< "${handle}"
  : "${pid}${out_file}${err_file}${tmp_dir}"
  [[ -n "${rc_file}" && -s "${rc_file}" ]]
}

ftctl_xcolo_start_primary_generated_async() {
  local vm="${1-}"
  local generated_xml="${2-}"
  local out_handle_var="${3-}"
  local timeout_sec tmp_dir out_file err_file rc_file pid

  [[ -n "${generated_xml}" && -f "${generated_xml}" ]] || return 1
  if [[ "${FTCTL_DRY_RUN}" == "1" ]]; then
    printf -v "${out_handle_var}" '%s' "dry-run||||"
    ftctl_log_event "colo" "primary.create_generated.async_start" "skip" "${vm}" "" "path=${generated_xml} reason=dry_run"
    return 0
  fi
  ftctl_xml_validate_xcolo_iothread_contract "${generated_xml}" || {
    ftctl_log_event "colo" "primary.create_generated.iothread-contract" "fail" "${vm}" "" "path=${generated_xml}"
    return 1
  }
  ftctl_primary_map_local_krbd_paths_from_xml "${vm}" "${generated_xml}" || {
    ftctl_log_event "colo" "primary.create_generated.rbd-map" "fail" "${vm}" "" "path=${generated_xml}"
    return 1
  }

  timeout_sec="$(ftctl_xcolo_domain_create_timeout_sec)"
  tmp_dir="$(mktemp -d "${FTCTL_RUN_DIR:-/run/ablestack-vm-ftctl}/xcolo-primary-create.${vm}.XXXXXX")" || return 1
  out_file="${tmp_dir}/stdout"
  err_file="${tmp_dir}/stderr"
  rc_file="${tmp_dir}/rc"
  (
    local create_rc=0
    if command -v timeout >/dev/null 2>&1; then
      timeout --preserve-status "${timeout_sec}" env LC_ALL=C LANG=C \
        virsh -c "${FTCTL_PROFILE_PRIMARY_URI}" create "${generated_xml}" \
        >"${out_file}" 2>"${err_file}" || create_rc=$?
    else
      env LC_ALL=C LANG=C virsh -c "${FTCTL_PROFILE_PRIMARY_URI}" create "${generated_xml}" \
        >"${out_file}" 2>"${err_file}" || create_rc=$?
    fi
    printf '%s\n' "${create_rc}" > "${rc_file}"
    exit "${create_rc}"
  ) &
  pid="$!"
  printf -v "${out_handle_var}" '%s|%s|%s|%s|%s' "${pid}" "${rc_file}" "${out_file}" "${err_file}" "${tmp_dir}"
  ftctl_log_event "colo" "primary.create_generated.async_start" "ok" "${vm}" "" \
    "path=${generated_xml} timeout=${timeout_sec} pid=${pid}"
}

ftctl_xcolo_wait_primary_generated_listeners() {
  local vm="${1-}"
  local handle="${2-}"
  local timeout_sec mirror_port compare_port compare_wait i
  local pid="" rc_file="" out_file="" err_file="" tmp_dir=""
  local create_rc

  IFS='|' read -r pid rc_file out_file err_file tmp_dir <<< "${handle}"
  : "${pid}${out_file}${err_file}${tmp_dir}"
  if [[ "${pid}" == "dry-run" ]]; then
    return 0
  fi

  timeout_sec="$(ftctl_xcolo_domain_create_timeout_sec)"
  mirror_port="${FTCTL_XCOLO_MIRROR_PORT:-9003}"
  compare_port="${FTCTL_XCOLO_COMPARE_PORT:-9004}"
  compare_wait="${FTCTL_XCOLO_COMPARE_WAIT:-on}"
  case "${compare_wait}" in
    on|off) ;;
    *) compare_wait="on" ;;
  esac
  for ((i=0; i<timeout_sec; i++)); do
    if ftctl_xcolo_local_tcp_listen_port_ready "${mirror_port}" &&
       { [[ "${compare_wait}" == "on" ]] || ftctl_xcolo_local_tcp_listen_port_ready "${compare_port}"; }; then
      ftctl_log_event "colo" "primary.create_generated.listeners" "ok" "${vm}" "" \
        "mirror_port=${mirror_port} compare_port=${compare_port} compare_wait=${compare_wait}"
      return 0
    fi
    if ftctl_xcolo_primary_create_async_done "${handle}"; then
      create_rc="$(cat "${rc_file}" 2>/dev/null || printf '1')"
      if [[ "${create_rc}" != "0" ]]; then
        ftctl_log_event "colo" "primary.create_generated.listeners" "fail" "${vm}" "${create_rc}" \
          "reason=create_exited_before_listen mirror_port=${mirror_port} compare_port=${compare_port} log_dir=${tmp_dir}"
        return 1
      fi
    fi
    sleep 1
  done
  ftctl_log_event "colo" "primary.create_generated.listeners" "fail" "${vm}" "" \
    "reason=timeout mirror_port=${mirror_port} compare_port=${compare_port} compare_wait=${compare_wait} log_dir=${tmp_dir}"
  return 1
}

ftctl_xcolo_channel_connect_timeout_sec() {
  local timeout_sec="${FTCTL_XCOLO_CHANNEL_CONNECT_TIMEOUT_SEC:-}"
  if [[ -z "${timeout_sec}" || ! "${timeout_sec}" =~ ^[0-9]+$ || "${timeout_sec}" -lt 5 ]]; then
    timeout_sec="$(ftctl_xcolo_domain_create_timeout_sec)"
  fi
  printf '%s\n' "${timeout_sec}"
}

ftctl_xcolo_wait_primary_peer_connections() {
  local vm="${1-}"
  local handle="${2-}"
  local timeout_sec mirror_port compare_port i
  local pid="" rc_file="" out_file="" err_file="" tmp_dir=""
  local create_rc

  IFS='|' read -r pid rc_file out_file err_file tmp_dir <<< "${handle}"
  : "${pid}${out_file}${err_file}${tmp_dir}"
  if [[ "${pid}" == "dry-run" ]]; then
    return 0
  fi

  timeout_sec="$(ftctl_xcolo_channel_connect_timeout_sec)"
  mirror_port="${FTCTL_XCOLO_MIRROR_PORT:-9003}"
  compare_port="${FTCTL_XCOLO_COMPARE_PORT:-9004}"
  for ((i=0; i<timeout_sec; i++)); do
    if ftctl_xcolo_local_tcp_established_port_ready "${mirror_port}" &&
       ftctl_xcolo_local_tcp_established_port_ready "${compare_port}"; then
      ftctl_log_event "colo" "primary.create_generated.channel_attach" "ok" "${vm}" "" \
        "mirror_port=${mirror_port} compare_port=${compare_port} attempts=$((i + 1))"
      return 0
    fi
    if ftctl_xcolo_primary_create_async_done "${handle}"; then
      create_rc="$(cat "${rc_file}" 2>/dev/null || printf '1')"
      if [[ "${create_rc}" != "0" ]]; then
        ftctl_log_event "colo" "primary.create_generated.channel_attach" "fail" "${vm}" "${create_rc}" \
          "reason=create_exited_before_channel_attach mirror_port=${mirror_port} compare_port=${compare_port} log_dir=${tmp_dir}"
        return 1
      fi
    fi
    sleep 1
  done

  ftctl_log_event "colo" "primary.create_generated.channel_attach" "fail" "${vm}" "" \
    "reason=timeout mirror_port=${mirror_port} compare_port=${compare_port} log_dir=${tmp_dir}"
  ftctl_state_set "${vm}" "last_error=xcolo_channel_attach_timeout"
  return 1
}

ftctl_xcolo_abort_primary_generated_async() {
  local vm="${1-}"
  local handle="${2-}"
  local pid="" rc_file="" out_file="" err_file="" tmp_dir=""
  local out err rc
  IFS='|' read -r pid rc_file out_file err_file tmp_dir <<< "${handle}"
  : "${rc_file}${out_file}${err_file}${tmp_dir}"
  [[ -n "${pid}" && "${pid}" != "dry-run" ]] || return 0
  if ! ftctl_xcolo_primary_create_async_done "${handle}"; then
    kill "${pid}" >/dev/null 2>&1 || true
    wait "${pid}" >/dev/null 2>&1 || true
  fi
  if [[ -n "${vm}" ]]; then
    out=""
    err=""
    rc=0
    ftctl_virsh "10" out err rc -- -c "${FTCTL_PROFILE_PRIMARY_URI}" destroy "${vm}" || true
    : "${out}${err}${rc}"
  fi
}

ftctl_xcolo_finish_primary_generated_async() {
  local vm="${1-}"
  local generated_xml="${2-}"
  local handle="${3-}"
  local pid="" rc_file="" out_file="" err_file="" tmp_dir=""
  local rc err_summary

  IFS='|' read -r pid rc_file out_file err_file tmp_dir <<< "${handle}"
  : "${out_file}"
  if [[ "${pid}" == "dry-run" ]]; then
    ftctl_log_event "colo" "primary.create_generated" "ok" "${vm}" "" "path=${generated_xml} dry_run=1"
    return 0
  fi

  wait "${pid}" >/dev/null 2>&1 || true
  rc="$(cat "${rc_file}" 2>/dev/null || printf '1')"
  if [[ "${rc}" != "0" ]]; then
    err_summary="$(tr '\n' ' ' < "${err_file}" 2>/dev/null | cut -c1-180 || true)"
    ftctl_log_event "colo" "primary.create_generated" "fail" "${vm}" "${rc}" \
      "path=${generated_xml} log_dir=${tmp_dir} error=${err_summary}"
    return "${rc}"
  fi
  ftctl_log_event "colo" "primary.create_generated" "ok" "${vm}" "" \
    "path=${generated_xml} log_dir=${tmp_dir}"
}

ftctl_xcolo_rollback_block_primary_create_failure() {
  local vm="${1-}"
  local reason="${2-xcolo_block_primary_create_failed}"
  local rollback_stage="rollback_after_primary_create_failed"

  if [[ "${FTCTL_DRY_RUN}" == "1" ]]; then
    ftctl_log_event "colo" "block_conversion.rollback" "skip" "${vm}" "" "reason=dry_run cause=${reason}"
    return 0
  fi

  case "${reason}" in
    xcolo_baseline_seed_failed:*|xcolo_baseline_source_not_ready:*|xcolo_baseline_nbd_start_failed:*|xcolo_baseline_copy_failed:*)
      rollback_stage="rollback_after_baseline_seed_failed"
      ;;
  esac

  ftctl_standby_deactivate "${vm}" || {
    ftctl_log_event "colo" "block_conversion.rollback.secondary_stop" "warn" "${vm}" "" "cause=${reason}"
  }
  ftctl_xcolo_unmap_secondary_runtime_rbd "${vm}" || {
    ftctl_log_event "colo" "block_conversion.rollback.secondary_rbd_unmap" "warn" "${vm}" "" "cause=${reason}"
  }
  ftctl_primary_activate_from_backup "${vm}" || {
    ftctl_log_event "colo" "block_conversion.rollback.primary_restore" "warn" "${vm}" "" "cause=${reason}"
    return 1
  }
  ftctl_state_set "${vm}" \
    "conversion_stage=${rollback_stage}" \
    "conversion_state=error" \
    "protection_state=error" \
    "transport_state=failed" \
    "active_side=primary" \
    "standby_state=stopped" \
    "peer_domain_expected=false" \
    "xcolo_last_runtime_error=${reason}" \
    "last_error=${reason}"
  ftctl_log_event "colo" "block_conversion.rollback" "ok" "${vm}" "" "cause=${reason}"
}

ftctl_xcolo_rewrite_disk_source_for_runtime() {
  local xml_path="${1-}"
  local target="${2-}"
  local runtime_path="${3-}"

  command -v python3 >/dev/null 2>&1 || {
    echo "ERROR: python3 is required for secondary runtime XML rewrite" >&2
    return 2
  }
  [[ -n "${xml_path}" && -f "${xml_path}" && -n "${target}" && -n "${runtime_path}" ]] || return 2

  XML_PATH="${xml_path}" DISK_TARGET="${target}" RUNTIME_PATH="${runtime_path}" python3 - <<'PY'
import os
import sys
import xml.etree.ElementTree as ET

xml_path = os.environ["XML_PATH"]
disk_target = os.environ["DISK_TARGET"]
runtime_path = os.environ["RUNTIME_PATH"]

tree = ET.parse(xml_path)
root = tree.getroot()
devices = root.find("devices")
if devices is None:
    print("missing devices", file=sys.stderr)
    raise SystemExit(2)

rewritten = False
for disk in devices.findall("disk"):
    if disk.get("device") != "disk":
        continue
    target = disk.find("target")
    if target is None or target.get("dev") != disk_target:
        continue
    source = disk.find("source")
    if source is None:
        source = ET.Element("source")
        disk.insert(1, source)
    disk.set("type", "block")
    source.attrib.clear()
    source.set("dev", runtime_path)
    rewritten = True
    break

if not rewritten:
    print(f"disk target not found: {disk_target}", file=sys.stderr)
    raise SystemExit(2)

tree.write(xml_path, encoding="unicode")
PY
}

ftctl_xcolo_prepare_secondary_runtime_rbd_disk() {
  local vm="${1-}"
  local xml_path="${2-}"
  local target="${3-}"
  local secondary_dest="${4-}"
  local host="" user="" out="" err="" rc=0 remote_cmd="" q_target="" q_dest=""
  local runtime_device="" mapped_by_ftctl="" state_key suffix
  local runtime_target="" runtime_dest=""

  [[ "${FTCTL_PROFILE_PROVISIONING_BACKEND:-libvirt-managed}" == "cloud-managed" ]] || return 0
  [[ "${secondary_dest}" == /dev/rbd/* ]] || return 0

  ftctl_blockcopy_remote_target_host_user host user || return $?
  printf -v q_target '%q' "${target}"
  printf -v q_dest '%q' "${secondary_dest}"
  remote_cmd="$(cat <<EOF
set -euo pipefail
target=${q_target}
dest=${q_dest}
rest="\${dest#/dev/rbd/}"
pool="\${rest%%/*}"
image="\${rest#*/}"
if [[ -z "\${pool}" || -z "\${image}" || "\${pool}" == "\${image}" ]]; then
  echo "runtime_rbd_path_invalid:\${target}:\${dest}" >&2
  exit 97
fi
mapped_by_ftctl=0
runtime_device=""
if [[ -b "\${dest}" ]]; then
  runtime_device="\${dest}"
else
  runtime_device="\$(rbd device list --format json 2>/dev/null | python3 -c 'import json,sys; pool=sys.argv[1]; image=sys.argv[2]; data=json.load(sys.stdin); print(next((str(item.get("device","")) for item in data if str(item.get("pool","")) == pool and str(item.get("name","")) == image), ""))' "\${pool}" "\${image}")"
  if [[ -z "\${runtime_device}" || ! -b "\${runtime_device}" ]]; then
    map_out="\$(rbd map "\${pool}/\${image}" 2>&1)" || {
      map_rc="\$?"
      echo "runtime_rbd_map_failed:\${target}:\${pool}/\${image}:rc=\${map_rc}:\${map_out}" >&2
      exit 98
    }
    mapped_by_ftctl=1
    runtime_device="\$(printf '%s\n' "\${map_out}" | tail -n1)"
    udevadm settle >/dev/null 2>&1 || true
    if [[ -b "\${dest}" ]]; then
      runtime_device="\${dest}"
    elif [[ -z "\${runtime_device}" || ! -b "\${runtime_device}" ]]; then
      runtime_device="\$(rbd device list --format json 2>/dev/null | python3 -c 'import json,sys; pool=sys.argv[1]; image=sys.argv[2]; data=json.load(sys.stdin); print(next((str(item.get("device","")) for item in data if str(item.get("pool","")) == pool and str(item.get("name","")) == image), ""))' "\${pool}" "\${image}")"
    fi
  fi
fi
if [[ -z "\${runtime_device}" || ! -b "\${runtime_device}" ]]; then
  echo "runtime_rbd_device_missing:\${target}:\${dest}:device=\${runtime_device}" >&2
  exit 99
fi
printf '%s|%s|%s|%s\n' "\${target}" "\${dest}" "\${runtime_device}" "\${mapped_by_ftctl}"
EOF
)"

  out=""
  err=""
  rc=0
  ftctl_blockcopy_remote_exec "${host}" "${user}" out err rc "${remote_cmd}" || true
  if [[ "${rc}" != "0" ]]; then
    case "${err}" in
      runtime_rbd_map_failed:*)
        ftctl_state_set "${vm}" "last_error=xcolo_secondary_runtime_rbd_map_failed:${target}"
        ;;
      runtime_rbd_device_missing:*)
        ftctl_state_set "${vm}" "last_error=xcolo_secondary_runtime_rbd_device_missing:${target}"
        ;;
      *)
        ftctl_state_set "${vm}" "last_error=xcolo_secondary_runtime_rbd_prepare_failed:${target}"
        ;;
    esac
    ftctl_log_event "colo" "block_conversion.secondary_runtime_rbd_prepare" "fail" "${vm}" "${rc}" \
      "target=${target} dest=${secondary_dest} error=$(printf '%s %s' "${out}" "${err}" | tr '\n' ' ' | cut -c1-220)"
    return "${rc}"
  fi

  IFS='|' read -r runtime_target runtime_dest runtime_device mapped_by_ftctl <<< "$(printf '%s\n' "${out}" | tail -n1)"
  : "${runtime_target}${runtime_dest}"
  if [[ -z "${runtime_device}" ]]; then
    ftctl_state_set "${vm}" "last_error=xcolo_secondary_runtime_rbd_device_missing:${target}"
    ftctl_log_event "colo" "block_conversion.secondary_runtime_rbd_prepare" "fail" "${vm}" "" \
      "target=${target} dest=${secondary_dest} reason=empty_runtime_device"
    return 1
  fi

  ftctl_xcolo_rewrite_disk_source_for_runtime "${xml_path}" "${target}" "${runtime_device}" || {
    ftctl_state_set "${vm}" "last_error=xcolo_secondary_runtime_xml_rewrite_failed:${target}"
    ftctl_log_event "colo" "block_conversion.secondary_runtime_xml_rewrite" "fail" "${vm}" "" \
      "target=${target} runtime_device=${runtime_device} path=${xml_path}"
    return 1
  }

  suffix="$(ftctl_xcolo_disk_suffix "${target}")"
  state_key="xcolo_secondary_runtime_rbd_${suffix}"
  ftctl_state_set "${vm}" \
    "${state_key}=${secondary_dest}|${runtime_device}|${mapped_by_ftctl}" \
    "xcolo_secondary_runtime_rbd_prepared=true"
  ftctl_log_event "colo" "block_conversion.secondary_runtime_rbd_prepare" "ok" "${vm}" "" \
    "target=${target} dest=${secondary_dest} runtime_device=${runtime_device} mapped_by_ftctl=${mapped_by_ftctl}"
}

ftctl_xcolo_prepare_secondary_runtime_rbd() {
  local vm="${1-}"
  local xml_path="${2-}"
  local disk_plan="${3-}"
  local entry rest target primary_source primary_format primary_dtype secondary_dest
  local -a runtime_disk_entries=()

  [[ "${FTCTL_PROFILE_PROVISIONING_BACKEND:-libvirt-managed}" == "cloud-managed" ]] || return 0
  [[ -n "${xml_path}" && -f "${xml_path}" && -n "${disk_plan}" ]] || return 0

  IFS=';' read -r -a runtime_disk_entries <<< "${disk_plan}"
  for entry in "${runtime_disk_entries[@]}"; do
    [[ -n "${entry}" ]] || continue
    target="${entry%%|*}"
    rest="${entry#*|}"
    primary_source="${rest%%|*}"
    rest="${rest#*|}"
    primary_format="${rest%%|*}"
    rest="${rest#*|}"
    primary_dtype="${rest%%|*}"
    secondary_dest="${rest#*|}"
    : "${primary_source}${primary_format}${primary_dtype}"
    ftctl_xcolo_prepare_secondary_runtime_rbd_disk "${vm}" "${xml_path}" "${target}" "${secondary_dest}" || return $?
  done
}

ftctl_xcolo_secondary_runtime_disk_source() {
  local vm="${1-}"
  local target="${2-}"
  local fallback="${3-}"
  local suffix value runtime_dest runtime_device mapped_by_ftctl

  suffix="$(ftctl_xcolo_disk_suffix "${target}")"
  value="$(ftctl_state_get "${vm}" "xcolo_secondary_runtime_rbd_${suffix}" 2>/dev/null || true)"
  if [[ -n "${value}" ]]; then
    IFS='|' read -r runtime_dest runtime_device mapped_by_ftctl <<< "${value}"
    : "${runtime_dest}${mapped_by_ftctl}"
    if [[ -n "${runtime_device}" ]]; then
      printf '%s\n' "${runtime_device}"
      return 0
    fi
  fi
  printf '%s\n' "${fallback}"
}

ftctl_xcolo_unmap_secondary_runtime_rbd() {
  local vm="${1-}"
  local host="" user="" line key value dest runtime_device mapped_by_ftctl out="" err="" rc=0 q_device remote_cmd
  local unmap_failed=0 state_path

  state_path="$(ftctl_state_path "${vm}")"
  [[ -f "${state_path}" ]] || return 0

  while IFS= read -r line; do
    case "${line}" in
      xcolo_secondary_runtime_rbd_*=*) ;;
      *) continue ;;
    esac
    key="${line%%=*}"
    [[ "${key}" != "xcolo_secondary_runtime_rbd_prepared" ]] || continue
    value="${line#*=}"
    IFS='|' read -r dest runtime_device mapped_by_ftctl <<< "${value}"
    : "${dest}"
    [[ "${mapped_by_ftctl}" == "1" && -n "${runtime_device}" ]] || continue
    if [[ -z "${host}" ]]; then
      ftctl_blockcopy_remote_target_host_user host user || {
        unmap_failed=1
        break
      }
    fi
    printf -v q_device '%q' "${runtime_device}"
    remote_cmd="$(cat <<EOF
set -euo pipefail
device=${q_device}
if [[ -b "\${device}" ]]; then
  rbd unmap "\${device}"
  udevadm settle >/dev/null 2>&1 || true
fi
EOF
)"
    out=""
    err=""
    rc=0
    ftctl_blockcopy_remote_exec "${host}" "${user}" out err rc "${remote_cmd}" || true
    if [[ "${rc}" == "0" ]]; then
      ftctl_log_event "colo" "block_conversion.secondary_runtime_rbd_unmap" "ok" "${vm}" "" \
        "key=${key} device=${runtime_device}"
    else
      ftctl_log_event "colo" "block_conversion.secondary_runtime_rbd_unmap" "fail" "${vm}" "${rc}" \
        "key=${key} device=${runtime_device} error=$(printf '%s %s' "${out}" "${err}" | tr '\n' ' ' | cut -c1-220)"
      unmap_failed=1
    fi
  done < "${state_path}"

  [[ "${unmap_failed}" == "0" ]]
}

ftctl_xcolo_execute_block_cold_conversion() {
  local vm="${1-}"
  local primary_generated_xml standby_generated_xml primary_source secondary_dest
  local primary_overlay secondary_pair secondary_hidden secondary_active
  local primary_base_node primary_qdev secondary_base_node secondary_qdev
  local secondary_vm primary_size secondary_size host user out err rc primary_create_handle
  local disk_plan entry rest target primary_format primary_dtype suffix seed_error runtime_prepare_error
  local secondary_runtime_source
  local -a disk_entries=()

  primary_generated_xml="$(ftctl_state_get "${vm}" "primary_xml_generated" 2>/dev/null || true)"
  standby_generated_xml="$(ftctl_state_get "${vm}" "standby_xml_generated" 2>/dev/null || true)"
  primary_source="$(ftctl_state_get "${vm}" "primary_disk_source" 2>/dev/null || true)"
  secondary_dest="$(ftctl_state_get "${vm}" "secondary_block_dest" 2>/dev/null || true)"
  disk_plan="$(ftctl_state_get "${vm}" "xcolo_disk_plan" 2>/dev/null || true)"
  secondary_vm="$(ftctl_profile_secondary_vm_name_resolved "${vm}")"

  [[ -n "${primary_generated_xml}" && -n "${standby_generated_xml}" && -n "${primary_source}" && -n "${secondary_dest}" ]] || return 1
  [[ -n "${disk_plan}" ]] || disk_plan="$(ftctl_state_get "${vm}" "primary_disk_target" 2>/dev/null || true)|${primary_source}|$(ftctl_state_get "${vm}" "primary_disk_format" 2>/dev/null || true)|$(ftctl_state_get "${vm}" "primary_disk_type" 2>/dev/null || true)|${secondary_dest}"

  ftctl_log_event "colo" "block_conversion.start" "ok" "${vm}" "" \
    "primary_generated=${primary_generated_xml} standby_generated=${standby_generated_xml}"

  ftctl_xcolo_shutdown_primary_for_conversion "${vm}" || {
    ftctl_log_event "colo" "block_conversion.primary_stop" "fail" "${vm}" "" \
      "reason=shutdown_failed"
    ftctl_state_set "${vm}" "last_error=xcolo_block_shutdown_failed"
    return 1
  }

  ftctl_state_set "${vm}" "conversion_stage=primary_stopped"
  ftctl_log_event "colo" "block_conversion.primary_stop" "ok" "${vm}" "" ""

  ftctl_state_set "${vm}" "conversion_stage=baseline_seeding"
  IFS=';' read -r -a disk_entries <<< "${disk_plan}"
  for entry in "${disk_entries[@]}"; do
    [[ -n "${entry}" ]] || continue
    target="${entry%%|*}"
    rest="${entry#*|}"
    primary_source="${rest%%|*}"
    rest="${rest#*|}"
    primary_format="${rest%%|*}"
    rest="${rest#*|}"
    primary_dtype="${rest%%|*}"
    secondary_dest="${rest#*|}"
    : "${primary_dtype}"
    primary_size="$(ftctl_xcolo_disk_virtual_size_bytes "${primary_source}" 2>/dev/null || true)"
    ftctl_xcolo_seed_secondary_baseline_disk "${vm}" "${target}" "${primary_source}" "${primary_format}" "${secondary_dest}" "${primary_size}" || {
      ftctl_log_event "colo" "block_conversion.baseline_seed" "fail" "${vm}" "" \
        "target=${target} source=${primary_source} secondary_dest=${secondary_dest}"
      ftctl_state_set "${vm}" \
        "conversion_stage=baseline_seed_failed" \
        "conversion_state=error" \
        "protection_state=error" \
        "transport_state=failed" \
        "last_error=xcolo_baseline_seed_failed:${target}"
      seed_error="$(ftctl_state_get "${vm}" "last_error" 2>/dev/null || true)"
      [[ -n "${seed_error}" ]] || seed_error="xcolo_baseline_seed_failed:${target}"
      ftctl_xcolo_rollback_block_primary_create_failure "${vm}" "${seed_error}" || true
      ftctl_state_set "${vm}" "xcolo_last_runtime_error=${seed_error}" "last_error=${seed_error}"
      return 1
    }
  done
  ftctl_state_set "${vm}" "conversion_stage=baseline_seeded"
  ftctl_log_event "colo" "block_conversion.baseline_seed" "ok" "${vm}" "" \
    "disk_count=${#disk_entries[@]}"

  ftctl_state_set "${vm}" "conversion_stage=secondary_runtime_rbd_preparing"
  ftctl_xcolo_prepare_secondary_runtime_rbd "${vm}" "${standby_generated_xml}" "${disk_plan}" || {
    runtime_prepare_error="$(ftctl_state_get "${vm}" "last_error" 2>/dev/null || true)"
    [[ -n "${runtime_prepare_error}" ]] || runtime_prepare_error="xcolo_secondary_runtime_rbd_prepare_failed"
    ftctl_state_set "${vm}" \
      "conversion_stage=secondary_runtime_rbd_prepare_failed" \
      "conversion_state=error" \
      "protection_state=error" \
      "transport_state=failed" \
      "last_error=${runtime_prepare_error}"
    ftctl_xcolo_rollback_block_primary_create_failure "${vm}" "${runtime_prepare_error}" || true
    ftctl_state_set "${vm}" "xcolo_last_runtime_error=${runtime_prepare_error}" "last_error=${runtime_prepare_error}"
    return 1
  }
  ftctl_state_set "${vm}" "conversion_stage=secondary_runtime_rbd_prepared"

  ftctl_log_event "colo" "block_conversion.primary_create" "ok" "${vm}" "" \
    "path=${primary_generated_xml}"
  primary_create_handle=""
  ftctl_xcolo_start_primary_generated_async "${vm}" "${primary_generated_xml}" primary_create_handle || {
    ftctl_log_event "colo" "block_conversion.primary_create" "fail" "${vm}" "" \
      "path=${primary_generated_xml}"
    ftctl_state_set "${vm}" "last_error=xcolo_block_primary_create_failed"
    ftctl_xcolo_rollback_block_primary_create_failure "${vm}" "xcolo_block_primary_create_failed" || true
    return 1
  }
  ftctl_state_set "${vm}" "conversion_stage=primary_create_started"
  ftctl_xcolo_wait_primary_generated_listeners "${vm}" "${primary_create_handle}" || {
    ftctl_xcolo_abort_primary_generated_async "${vm}" "${primary_create_handle}"
    ftctl_log_event "colo" "block_conversion.primary_create" "fail" "${vm}" "" \
      "path=${primary_generated_xml} reason=listener_wait_failed"
    ftctl_state_set "${vm}" "last_error=xcolo_block_primary_listener_wait_failed"
    ftctl_xcolo_rollback_block_primary_create_failure "${vm}" "xcolo_block_primary_listener_wait_failed" || true
    return 1
  }
  ftctl_state_set "${vm}" "conversion_stage=primary_listening"

  ftctl_log_event "colo" "block_conversion.secondary_create" "ok" "${vm}" "" \
    "path=${standby_generated_xml}"
  ftctl_standby_activate "${vm}" || {
    ftctl_xcolo_abort_primary_generated_async "${vm}" "${primary_create_handle}"
    ftctl_log_event "colo" "block_conversion.secondary_create" "fail" "${vm}" "" \
      "path=${standby_generated_xml}"
    ftctl_state_set "${vm}" "last_error=xcolo_block_secondary_create_failed"
    ftctl_xcolo_rollback_block_primary_create_failure "${vm}" "xcolo_block_secondary_create_failed" || true
    return 1
  }
  ftctl_state_set "${vm}" "conversion_stage=secondary_created"
  ftctl_log_event "colo" "block_conversion.secondary_create" "ok" "${vm}" "" \
    "vm=${secondary_vm}"

  ftctl_xcolo_wait_primary_peer_connections "${vm}" "${primary_create_handle}" || {
    ftctl_xcolo_abort_primary_generated_async "${vm}" "${primary_create_handle}"
    ftctl_log_event "colo" "block_conversion.channel_attach" "fail" "${vm}" "" \
      "primary=${vm} secondary=${secondary_vm}"
    ftctl_state_set "${vm}" \
      "conversion_stage=channel_attach_failed" \
      "conversion_state=error" \
      "protection_state=error" \
      "transport_state=failed" \
      "last_error=xcolo_channel_attach_timeout"
    ftctl_xcolo_rollback_block_primary_create_failure "${vm}" "xcolo_channel_attach_timeout" || true
    return 1
  }
  ftctl_state_set "${vm}" "conversion_stage=channels_attached"

  ftctl_xcolo_finish_primary_generated_async "${vm}" "${primary_generated_xml}" "${primary_create_handle}" || {
    ftctl_log_event "colo" "block_conversion.primary_create" "fail" "${vm}" "" \
      "path=${primary_generated_xml}"
    ftctl_state_set "${vm}" "last_error=xcolo_block_primary_create_failed"
    ftctl_xcolo_rollback_block_primary_create_failure "${vm}" "xcolo_block_primary_create_failed" || true
    return 1
  }
  ftctl_state_set "${vm}" "conversion_stage=primary_created"
  ftctl_log_event "colo" "block_conversion.primary_create" "ok" "${vm}" "" ""

  ftctl_xcolo_require_primary_netdev_vhost_off "${vm}" || {
    ftctl_xcolo_abort_primary_generated_async "${vm}" "${primary_create_handle}"
    ftctl_xcolo_rollback_block_primary_create_failure "${vm}" "$(ftctl_state_get "${vm}" "last_error" 2>/dev/null || printf '%s' primary_netdev_vhost_enabled)" || true
    return 1
  }
  ftctl_state_set "${vm}" "conversion_stage=primary_vhost_guard_passed"

  host=""
  user=""
  out=""
  err=""
  rc=0
  ftctl_blockcopy_remote_target_host_user host user || true
  IFS=';' read -r -a disk_entries <<< "${disk_plan}"
  for entry in "${disk_entries[@]}"; do
    [[ -n "${entry}" ]] || continue
    target="${entry%%|*}"
    rest="${entry#*|}"
    primary_source="${rest%%|*}"
    rest="${rest#*|}"
    primary_format="${rest%%|*}"
    rest="${rest#*|}"
    primary_dtype="${rest%%|*}"
    secondary_dest="${rest#*|}"
    secondary_runtime_source="$(ftctl_xcolo_secondary_runtime_disk_source "${vm}" "${target}" "${secondary_dest}")"
    : "${primary_format}${primary_dtype}"
    suffix="$(ftctl_xcolo_disk_suffix "${target}")"

    primary_size="$(ftctl_xcolo_disk_virtual_size_bytes "${primary_source}" 2>/dev/null || true)"
    secondary_size=""
    if [[ -n "${host}" ]]; then
      secondary_size="$(ftctl_xcolo_remote_disk_virtual_size_bytes "${host}" "${user}" "${secondary_runtime_source}" 2>/dev/null || true)"
    fi
    if [[ -n "${secondary_size}" && -n "${primary_size}" && "${secondary_size}" != "${primary_size}" ]]; then
      ftctl_log_event "colo" "block_conversion.size_validation" "fail" "${vm}" "" \
        "target=${target} primary_size=${primary_size} secondary_size=${secondary_size}"
      ftctl_state_set "${vm}" "last_error=xcolo_block_preflight_size_mismatch"
      return 1
    fi
    if [[ -z "${secondary_size}" ]]; then
      secondary_size="${primary_size}"
    fi

    primary_overlay="$(ftctl_xcolo_prepare_primary_overlay "${vm}" "${target}" "${primary_size}")" || {
      ftctl_log_event "colo" "block_conversion.primary_overlay" "fail" "${vm}" "" "target=${target}"
      ftctl_state_set "${vm}" "last_error=xcolo_block_primary_overlay_prepare_failed"
      return 1
    }
    secondary_pair="$(ftctl_xcolo_prepare_secondary_overlays "${vm}" "${target}" "${secondary_size}")" || {
      ftctl_log_event "colo" "block_conversion.secondary_overlay" "fail" "${vm}" "" "target=${target}"
      ftctl_state_set "${vm}" "last_error=xcolo_block_secondary_overlay_prepare_failed"
      return 1
    }
    secondary_hidden="${secondary_pair%%|*}"
    secondary_active="${secondary_pair##*|}"
    ftctl_log_event "colo" "block_conversion.overlay_prepare" "ok" "${vm}" "" \
      "target=${target} primary_overlay=${primary_overlay} secondary_hidden=${secondary_hidden} secondary_active=${secondary_active}"

    ftctl_xcolo_collect_disk_binding_on_uri "${FTCTL_PROFILE_PRIMARY_URI}" "${vm}" "${primary_source}" primary_base_node primary_qdev || {
      ftctl_log_event "colo" "block_conversion.primary_binding" "fail" "${vm}" "" \
        "target=${target} source=${primary_source}"
      ftctl_state_set "${vm}" "last_error=xcolo_block_primary_binding_missing"
      return 1
    }
    ftctl_xcolo_collect_disk_binding_on_uri "${FTCTL_PROFILE_SECONDARY_URI}" "$(ftctl_profile_secondary_vm_name_resolved "${vm}")" "${secondary_runtime_source}" secondary_base_node secondary_qdev || {
      ftctl_log_event "colo" "block_conversion.secondary_binding" "fail" "${vm}" "" \
        "target=${target} source=${secondary_runtime_source} cloud_source=${secondary_dest}"
      ftctl_state_set "${vm}" "last_error=xcolo_block_secondary_binding_missing"
      return 1
    }
    ftctl_state_set "${vm}" \
      "xcolo_disk_${suffix}_primary_base_node=${primary_base_node}" \
      "xcolo_disk_${suffix}_primary_base_qdev=${primary_qdev}" \
      "xcolo_disk_${suffix}_secondary_base_node=${secondary_base_node}" \
      "xcolo_disk_${suffix}_secondary_base_qdev=${secondary_qdev}" \
      "xcolo_disk_${suffix}_primary_overlay=${primary_overlay}" \
      "xcolo_disk_${suffix}_secondary_hidden=${secondary_hidden}" \
      "xcolo_disk_${suffix}_secondary_active=${secondary_active}"
    ftctl_log_event "colo" "block_conversion.binding" "ok" "${vm}" "" \
      "target=${target} primary_base=${primary_base_node} secondary_base=${secondary_base_node}"

    ftctl_xcolo_attach_secondary_block_graph "${secondary_vm}" "${secondary_base_node}" "${secondary_hidden}" "${secondary_active}" "${secondary_qdev}" "${target}" || {
      ftctl_log_event "colo" "block_conversion.secondary_attach" "fail" "${vm}" "" \
        "target=${target} base=${secondary_base_node} qdev=${secondary_qdev}"
      ftctl_state_set "${vm}" \
        "conversion_stage=runtime_graph_failed" \
        "conversion_state=error" \
        "protection_state=error" \
        "transport_state=failed" \
        "last_error=xcolo_block_secondary_attach_failed"
      return 1
    }
    ftctl_log_event "colo" "block_conversion.secondary_attach" "ok" "${vm}" "" \
      "target=${target} base=${secondary_base_node} qdev=${secondary_qdev}"
    ftctl_log_event "colo" "block_conversion.primary_attach" "skip" "${vm}" "" \
      "target=${target} base=${primary_base_node} qdev=${primary_qdev} reason=await_remote_nbd"
  done

  ftctl_xcolo_execute_handshake_with_disk_plan "${vm}" "${secondary_vm}" "${disk_plan}" || {
    local handshake_error
    handshake_error="$(ftctl_state_get "${vm}" "last_error" 2>/dev/null || true)"
    [[ -n "${handshake_error}" ]] || handshake_error="xcolo_block_handshake_failed"
    ftctl_log_event "colo" "block_conversion.handshake" "fail" "${vm}" "" \
      "disk_count=${#disk_entries[@]} reason=${handshake_error}"
    ftctl_xcolo_recover_block_handshake_failure "${vm}" "${handshake_error}" || true
    return 1
  }
  ftctl_state_set "${vm}" \
    "xcolo_handshake_command_state=accepted" \
    "xcolo_steady_state_gate=pending"
  ftctl_log_event "colo" "block_conversion.handshake" "ok" "${vm}" "" \
    "disk_count=${#disk_entries[@]} state=commands_accepted steady_state=pending"

  ftctl_xcolo_state_write "${vm}" \
    "mode=cold-conversion" \
    "conversion_policy=block-backed-cold-restart" \
    "conversion_required=yes" \
    "primary_disk_source=${primary_source}" \
    "secondary_block_dest=${secondary_dest}" \
    "primary_base_node=${primary_base_node}" \
    "primary_base_qdev=${primary_qdev}" \
    "secondary_base_node=${secondary_base_node}" \
    "secondary_base_qdev=${secondary_qdev}" \
    "primary_overlay=${primary_overlay}" \
    "secondary_hidden=${secondary_hidden}" \
    "secondary_active=${secondary_active}" \
    "xcolo_disk_plan=${disk_plan}" \
    "primary_disk_node=${secondary_base_node}" \
    "parent_block_node=colo-disk0" \
    "nbd_node=${FTCTL_PROFILE_XCOLO_NBD_NODE}" \
    "proxy_endpoint=${FTCTL_PROFILE_XCOLO_PROXY_ENDPOINT}" \
    "nbd_endpoint=${FTCTL_PROFILE_XCOLO_NBD_ENDPOINT}" \
    "migrate_uri=${FTCTL_PROFILE_XCOLO_MIGRATE_URI}"

  ftctl_xcolo_capture_runtime_snapshot "${vm}" "xcolo_after_handshake" "${secondary_vm}"
  local validate_rc=0 validate_error
  ftctl_log_event "colo" "block_conversion.steady_state_gate" "start" "${vm}" "" \
    "disk_count=${#disk_entries[@]}"
  ftctl_xcolo_validate_pair_runtime "${vm}" "${secondary_vm}" || validate_rc=$?
  case "${validate_rc}" in
    0)
      ftctl_state_set "${vm}" "xcolo_steady_state_gate=ok"
      ftctl_log_event "colo" "block_conversion.steady_state_gate" "ok" "${vm}" "" \
        "primary_colo=$(ftctl_state_get "${vm}" "xcolo_primary_colo_mode" 2>/dev/null || true) secondary_colo=$(ftctl_state_get "${vm}" "xcolo_secondary_colo_mode" 2>/dev/null || true)"
      ftctl_xcolo_verify_checkpoint_delay_after_start "${vm}" || \
        ftctl_log_event "colo" "primary.migrate_set_parameters.post_start" "warn" "${vm}" "" \
          "checkpoint_delay=${FTCTL_PROFILE_XCOLO_CHECKPOINT_DELAY:-}"
      ;;
    10)
      ftctl_state_set "${vm}" "xcolo_steady_state_gate=pending"
      ftctl_log_event "colo" "block_conversion.steady_state_gate" "pending" "${vm}" "" \
        "reason=$(ftctl_state_get "${vm}" "xcolo_pending_reason" 2>/dev/null || true)"
      if ftctl_xcolo_candidate_observation_ready "${vm}"; then
        ftctl_xcolo_mark_candidate_observed "${vm}" "block_cold_conversion"
        ftctl_log_event "colo" "xcolo.block_cold_conversion.execute" "pending" "${vm}" "" \
          "reason=$(ftctl_state_get "${vm}" "xcolo_pending_reason" 2>/dev/null || true) primary_base=${primary_base_node} secondary_base=${secondary_base_node}"
      else
        ftctl_xcolo_mark_runtime_pending "${vm}" "runtime_converging"
        ftctl_log_event "colo" "xcolo.block_cold_conversion.execute" "pending" "${vm}" "" \
          "primary_base=${primary_base_node} secondary_base=${secondary_base_node}"
      fi
      return 0
      ;;
    *)
      validate_error="$(ftctl_state_get "${vm}" "last_error" 2>/dev/null || true)"
      [[ -n "${validate_error}" ]] || validate_error="xcolo_runtime_validation_failed"
      ftctl_state_set "${vm}" "xcolo_steady_state_gate=failed"
      ftctl_log_event "colo" "block_conversion.steady_state_gate" "fail" "${vm}" "" \
        "reason=${validate_error} protocol_reason=$(ftctl_state_get "${vm}" "xcolo_protocol_invalid_message_reason" 2>/dev/null || true)"
      ftctl_xcolo_recover_runtime_convergence_failure "${vm}" "${validate_error}" || true
      ftctl_state_set "${vm}" \
        "xcolo_last_runtime_error=${validate_error}" \
        "last_error=${validate_error}"
      ftctl_xcolo_preserve_runtime_error "${vm}"
      return 1
      ;;
  esac

  ftctl_state_set "${vm}" \
    "conversion_stage=handshake_complete" \
    "conversion_state=colo_running" \
    "protection_state=colo_running" \
    "transport_state=mirroring" \
    "active_side=primary" \
    "last_sync_ts=$(ftctl_now_iso8601)" \
    "last_error="
  ftctl_log_event "colo" "xcolo.block_cold_conversion.execute" "ok" "${vm}" "" \
    "primary_base=${primary_base_node} secondary_base=${secondary_base_node}"
  return 0
}

ftctl_xcolo_detect_block_backed_ft() {
  local vm="${1-}"
  local out_kind_var="${2}"
  local out_target_var="${3}"
  local out_source_var="${4}"
  local out_format_var="${5}"
  local disks=()
  local first target source format dtype

  printf -v "${out_kind_var}" '%s' "unknown"
  printf -v "${out_target_var}" '%s' ""
  printf -v "${out_source_var}" '%s' ""
  printf -v "${out_format_var}" '%s' ""

  ftctl_inventory_collect_vm_disks_detailed "${vm}" disks || return 1
  first="${disks[0]}"
  target="${first%%|*}"
  first="${first#*|}"
  source="${first%%|*}"
  first="${first#*|}"
  format="${first%%|*}"
  dtype="${first##*|}"

  printf -v "${out_target_var}" '%s' "${target}"
  printf -v "${out_source_var}" '%s' "${source}"
  printf -v "${out_format_var}" '%s' "${format}"
  printf -v "${out_kind_var}" '%s' "${dtype}"
  [[ "${dtype}" == "block" ]]
}

ftctl_xcolo_plan_protect_prebuilt() {
  local vm="${1-}"
  local nbd_host nbd_port
  local primary_xml_backup standby_xml_seed

  ftctl_xcolo_parse_tcp_endpoint "${FTCTL_PROFILE_XCOLO_NBD_ENDPOINT}" nbd_host nbd_port
  primary_xml_backup="$(ftctl_state_get "${vm}" "primary_xml_backup" 2>/dev/null || true)"
  standby_xml_seed="$(ftctl_state_get "${vm}" "standby_xml_seed" 2>/dev/null || true)"
  if [[ -z "${primary_xml_backup}" || -z "${standby_xml_seed}" || ! -f "${primary_xml_backup}" || ! -f "${standby_xml_seed}" ]]; then
    ftctl_xcolo_backup_prebuilt_pair_xml "${vm}" || return 1
    primary_xml_backup="$(ftctl_state_get "${vm}" "primary_xml_backup" 2>/dev/null || true)"
    standby_xml_seed="$(ftctl_state_get "${vm}" "standby_xml_seed" 2>/dev/null || true)"
  fi

  ftctl_state_set "${vm}" \
    "protection_state=colo_preparing" \
    "transport_state=planned" \
    "xcolo_protect_stage=secondary-stage" \
    "last_error="

  if [[ "${FTCTL_DRY_RUN}" != "1" ]] && ! ftctl_xcolo_validate_prebuilt_file_pair_sizes "${vm}"; then
    ftctl_state_set "${vm}" \
      "protection_state=error" \
      "transport_state=planned" \
      "last_error=xcolo_preflight_size_mismatch"
    ftctl_log_event "colo" "xcolo.protect" "fail" "${vm}" "" \
      "reason=preflight_size_mismatch"
    return 1
  fi

  ftctl_xcolo_prebuilt_secondary_stage "${vm}" "${nbd_host}" "${nbd_port}" || return 1
  ftctl_xcolo_capture_runtime_snapshot "${vm}" "xcolo_after_secondary"
  ftctl_state_set "${vm}" "xcolo_protect_stage=primary-stage"
  ftctl_xcolo_prebuilt_primary_stage "${vm}" "${nbd_host}" "${nbd_port}" || return 1
  ftctl_xcolo_capture_runtime_snapshot "${vm}" "xcolo_after_primary"

  ftctl_xcolo_state_write "${vm}" \
    "proxy_endpoint=${FTCTL_PROFILE_XCOLO_PROXY_ENDPOINT}" \
    "nbd_endpoint=${FTCTL_PROFILE_XCOLO_NBD_ENDPOINT}" \
    "migrate_uri=${FTCTL_PROFILE_XCOLO_MIGRATE_URI}" \
    "primary_disk_node=${FTCTL_PROFILE_XCOLO_PRIMARY_DISK_NODE}" \
    "parent_block_node=${FTCTL_PROFILE_XCOLO_PARENT_BLOCK_NODE}" \
    "nbd_node=${FTCTL_PROFILE_XCOLO_NBD_NODE}"

  ftctl_state_set "${vm}" "xcolo_protect_stage=wait-running"
  ftctl_xcolo_capture_runtime_snapshot "${vm}"
  if [[ "${FTCTL_DRY_RUN}" != "1" ]] && ! ftctl_xcolo_wait_pair_running "${vm}" "20" "${vm}"; then
    ftctl_xcolo_capture_runtime_snapshot "${vm}"
    ftctl_state_set "${vm}" \
      "protection_state=error" \
      "transport_state=planned" \
      "last_error=xcolo_protect_not_running"
    ftctl_log_event "colo" "xcolo.protect" "fail" "${vm}" "" \
      "reason=pair_not_running"
    return 1
  fi
  local validate_rc=0 validate_error
  ftctl_xcolo_validate_pair_runtime "${vm}" "${vm}" || validate_rc=$?
  case "${validate_rc}" in
    0)
      ftctl_xcolo_verify_checkpoint_delay_after_start "${vm}" || \
        ftctl_log_event "colo" "primary.migrate_set_parameters.post_start" "warn" "${vm}" "" \
          "checkpoint_delay=${FTCTL_PROFILE_XCOLO_CHECKPOINT_DELAY:-}"
      ;;
    10)
      if ftctl_xcolo_candidate_observation_ready "${vm}"; then
        ftctl_xcolo_mark_candidate_observed "${vm}" "protect_prebuilt"
        ftctl_log_event "colo" "xcolo.protect" "pending" "${vm}" "" \
          "reason=$(ftctl_state_get "${vm}" "xcolo_pending_reason" 2>/dev/null || true)"
      else
        ftctl_xcolo_mark_runtime_pending "${vm}" "runtime_converging"
        ftctl_log_event "colo" "xcolo.protect" "pending" "${vm}" "" \
          "reason=runtime_converging"
      fi
      return 0
      ;;
    *)
      validate_error="$(ftctl_state_get "${vm}" "last_error" 2>/dev/null || true)"
      [[ -n "${validate_error}" ]] || validate_error="xcolo_runtime_validation_failed"
      ftctl_xcolo_recover_runtime_convergence_failure "${vm}" "${validate_error}" || true
      ftctl_state_set "${vm}" \
        "xcolo_last_runtime_error=${validate_error}" \
        "last_error=${validate_error}"
      ftctl_xcolo_preserve_runtime_error "${vm}"
      ftctl_log_event "colo" "xcolo.protect" "fail" "${vm}" "" \
        "reason=runtime_validation_failed"
      return 1
      ;;
  esac
  ftctl_state_set "${vm}" \
    "protection_state=colo_running" \
    "transport_state=mirroring" \
    "last_sync_ts=$(ftctl_now_iso8601)" \
    "last_error="
  ftctl_log_event "colo" "xcolo.protect" "ok" "${vm}" "" \
    "qmp_timeout=${FTCTL_XCOLO_QMP_TIMEOUT_SEC}"
}

ftctl_xcolo_plan_protect_block_cold_conversion() {
  local vm="${1-}"
  local disk_kind primary_target primary_source primary_format current_node current_qdev
  local primary_xml_backup standby_xml_seed
  local primary_generated_xml standby_generated_xml
  local xml_bundle_dir persistence secondary_dest primary_state
  local primary_qemu_args secondary_qemu_args
  local primary_netdev_id secondary_netdev_id
  local xcolo_disk_plan primary_disk_map primary_disk_metadata

  ftctl_xcolo_detect_block_backed_ft "${vm}" disk_kind primary_target primary_source primary_format || return 1
  current_node=""
  current_qdev=""
  primary_xml_backup="$(ftctl_state_get "${vm}" "primary_xml_backup" 2>/dev/null || true)"
  standby_xml_seed="$(ftctl_state_get "${vm}" "standby_xml_seed" 2>/dev/null || true)"
  primary_generated_xml=""
  standby_generated_xml=""
  xml_bundle_dir=""
  persistence="$(ftctl_state_get "${vm}" "primary_persistence" 2>/dev/null || true)"
  secondary_dest=""
  primary_state="$(ftctl_xcolo_primary_domain_state "${vm}" 2>/dev/null || echo "unknown")"
  primary_qemu_args=""
  secondary_qemu_args=""
  primary_netdev_id=""
  secondary_netdev_id=""
  xcolo_disk_plan=""
  primary_disk_map=""
  primary_disk_metadata=""

  if [[ -z "${primary_xml_backup}" || -z "${standby_xml_seed}" || ! -f "${primary_xml_backup}" || ! -f "${standby_xml_seed}" ]]; then
    ftctl_inventory_backup_domain_xml "${vm}" xml_bundle_dir primary_xml_backup standby_xml_seed persistence || {
      ftctl_state_set "${vm}" \
        "protection_state=error" \
        "transport_state=planned" \
        "last_error=xcolo_block_xml_backup_failed"
      return 1
    }
    ftctl_state_set "${vm}" \
      "primary_xml_backup=${primary_xml_backup}" \
      "standby_xml_seed=${standby_xml_seed}" \
      "primary_persistence=${persistence}"
  fi

  ftctl_xcolo_xml_resolve_netdev_id "${primary_xml_backup}" "primary" "${vm}" primary_netdev_id || {
    ftctl_state_set "${vm}" \
      "protection_state=error" \
      "transport_state=planned" \
      "last_error=xcolo_primary_netdev_id_unresolved"
    return 1
  }
  ftctl_xcolo_xml_resolve_netdev_id "${standby_xml_seed}" "secondary" "${vm}" secondary_netdev_id || {
    ftctl_state_set "${vm}" \
      "protection_state=error" \
      "transport_state=planned" \
      "last_error=xcolo_secondary_netdev_id_unresolved"
    return 1
  }
  ftctl_xcolo_update_vnet_hdr_state "${vm}" || true
  ftctl_log_event "colo" "xcolo.net_vnet_hdr" "ok" "${vm}" "" \
    "required=$(ftctl_state_get "${vm}" "xcolo_net_vnet_hdr_support" 2>/dev/null || true) reason=$(ftctl_state_get "${vm}" "xcolo_net_vnet_hdr_support_reason" 2>/dev/null || true) primary_model=$(ftctl_state_get "${vm}" "xcolo_net_vnet_hdr_primary_model" 2>/dev/null || true) secondary_model=$(ftctl_state_get "${vm}" "xcolo_net_vnet_hdr_secondary_model" 2>/dev/null || true)"
  primary_qemu_args="$(ftctl_xcolo_build_primary_qemu_args "${primary_netdev_id}" "${vm}")"
  secondary_qemu_args="$(ftctl_xcolo_build_secondary_qemu_args "${secondary_netdev_id}" "${vm}")"

  if [[ "${FTCTL_PROFILE_DISK_MAP}" == "auto" ]]; then
    ftctl_state_set "${vm}" \
      "protection_state=error" \
      "transport_state=planned" \
      "last_error=xcolo_block_explicit_disk_map_required"
    ftctl_log_event "colo" "xcolo.protect.block_cold_conversion" "fail" "${vm}" "" \
      "reason=explicit_disk_map_required target=${primary_target}"
    return 1
  fi

  ftctl_xcolo_collect_block_disk_plan "${vm}" xcolo_disk_plan primary_disk_map primary_disk_metadata || {
    ftctl_state_set "${vm}" \
      "protection_state=error" \
      "transport_state=planned" \
      "last_error=xcolo_block_disk_plan_failed"
    return 1
  }
  ftctl_xcolo_record_storage_symmetry "${vm}" "${xcolo_disk_plan}" || true
  ftctl_xcolo_require_storage_symmetry "${vm}" || return 1

  secondary_dest="$(ftctl_profile_lookup_map_value "${FTCTL_PROFILE_DISK_MAP}" "${primary_target}" 2>/dev/null || true)"
  if [[ -z "${secondary_dest}" ]]; then
    ftctl_state_set "${vm}" \
      "protection_state=error" \
      "transport_state=planned" \
      "last_error=xcolo_block_secondary_dest_missing"
    ftctl_log_event "colo" "xcolo.protect.block_cold_conversion" "fail" "${vm}" "" \
      "reason=secondary_dest_missing target=${primary_target}"
    return 1
  fi

  if [[ -n "${primary_xml_backup}" && -f "${primary_xml_backup}" ]]; then
    ftctl_xcolo_prepare_block_generated_xmls "${vm}" \
      "${primary_xml_backup}" "${standby_xml_seed}" "${primary_source}" "${secondary_dest}" \
      "${primary_format}" "${primary_qemu_args}" "${secondary_qemu_args}" \
      "${primary_disk_map}" "${primary_disk_metadata}" || {
      ftctl_state_set "${vm}" \
        "protection_state=error" \
        "transport_state=planned" \
        "last_error=xcolo_block_generated_xml_prepare_failed"
      return 1
    }
    primary_generated_xml="$(ftctl_state_get "${vm}" "primary_xml_generated" 2>/dev/null || true)"
    standby_generated_xml="$(ftctl_state_get "${vm}" "standby_xml_generated" 2>/dev/null || true)"
  fi

  ftctl_xcolo_collect_primary_disk_binding "${vm}" "${primary_source}" current_node current_qdev || {
    ftctl_log_event "colo" "primary.block_binding" "fail" "${vm}" "" \
      "source=${primary_source}"
    ftctl_state_set "${vm}" \
      "protection_state=error" \
      "transport_state=planned" \
      "last_error=xcolo_block_binding_not_found"
    return 1
  }

  ftctl_xcolo_state_write "${vm}" \
    "mode=cold-conversion" \
    "conversion_policy=block-backed-cold-restart" \
    "conversion_required=yes" \
    "primary_disk_type=${disk_kind}" \
    "primary_disk_target=${primary_target}" \
    "primary_disk_source=${primary_source}" \
    "primary_disk_format=${primary_format}" \
    "current_primary_node=${current_node}" \
    "current_primary_qdev=${current_qdev}" \
    "xcolo_primary_netdev_id=${primary_netdev_id}" \
    "xcolo_secondary_netdev_id=${secondary_netdev_id}" \
    "primary_xml_backup=${primary_xml_backup}" \
    "standby_xml_seed=${standby_xml_seed}" \
    "primary_xml_generated=${primary_generated_xml}" \
    "standby_xml_generated=${standby_generated_xml}" \
    "primary_qemu_args=${primary_qemu_args}" \
    "secondary_qemu_args=${secondary_qemu_args}" \
    "primary_runtime_disk_mode=ro-shareable" \
    "secondary_runtime_disk_mode=rw" \
    "secondary_block_dest=${secondary_dest}" \
    "xcolo_disk_plan=${xcolo_disk_plan}" \
    "xcolo_primary_disk_map=${primary_disk_map}" \
    "xcolo_primary_disk_metadata=${primary_disk_metadata}" \
    "proxy_endpoint=${FTCTL_PROFILE_XCOLO_PROXY_ENDPOINT}" \
    "nbd_endpoint=${FTCTL_PROFILE_XCOLO_NBD_ENDPOINT}" \
    "migrate_uri=${FTCTL_PROFILE_XCOLO_MIGRATE_URI}" \
    "primary_disk_node=${FTCTL_PROFILE_XCOLO_PRIMARY_DISK_NODE}" \
    "parent_block_node=${FTCTL_PROFILE_XCOLO_PARENT_BLOCK_NODE}" \
    "nbd_node=${FTCTL_PROFILE_XCOLO_NBD_NODE}"

  ftctl_log_event "colo" "xcolo.protect.block_cold_conversion" "warn" "${vm}" "" \
    "source=${primary_source} node=${current_node} qdev=${current_qdev} secondary_dest=${secondary_dest} disk_plan=${xcolo_disk_plan} policy=cold_restart stage=runtime_xml_generated"
  ftctl_state_set "${vm}" \
    "primary_disk_type=${disk_kind}" \
    "primary_disk_target=${primary_target}" \
    "primary_disk_source=${primary_source}" \
    "primary_disk_format=${primary_format}" \
    "current_primary_node=${current_node}" \
    "current_primary_qdev=${current_qdev}" \
    "secondary_block_dest=${secondary_dest}" \
    "xcolo_primary_netdev_id=${primary_netdev_id}" \
    "xcolo_secondary_netdev_id=${secondary_netdev_id}" \
    "xcolo_disk_plan=${xcolo_disk_plan}" \
    "protection_state=pairing" \
    "transport_state=planned" \
    "conversion_stage=runtime_xml_generated" \
    "conversion_state=shutdown_required" \
    "primary_domain_state=${primary_state}" \
    "last_error="

  if [[ "${FTCTL_DRY_RUN}" == "1" ]]; then
    ftctl_state_set "${vm}" "last_error=xcolo_block_cold_conversion_handshake_not_implemented"
    return 0
  fi

  ftctl_xcolo_execute_block_cold_conversion "${vm}" || return 1
  return 0
}

ftctl_xcolo_plan_protect() {
  local vm="${1-}"
  local disk_kind primary_target primary_source primary_format

  if ftctl_xcolo_detect_block_backed_ft "${vm}" disk_kind primary_target primary_source primary_format; then
    ftctl_xcolo_plan_protect_block_cold_conversion "${vm}"
    return $?
  fi

  ftctl_xcolo_plan_protect_prebuilt "${vm}"
}

ftctl_xcolo_rearm() {
  local vm="${1-}"
  local count
  count="$(ftctl_state_increment "${vm}" "rearm_count")"
  ftctl_state_set "${vm}" \
    "protection_state=colo_rearming" \
    "transport_state=rearm_pending" \
    "last_rearm_ts=$(ftctl_now_iso8601)" \
    "last_error="

  ftctl_xcolo_qmp_require_ok "${FTCTL_PROFILE_SECONDARY_URI}" "${vm}" \
    '{"execute":"nbd-server-stop"}' "rearm" "secondary.nbd_server_stop" || true
  ftctl_xcolo_plan_protect "${vm}" || {
    ftctl_state_set "${vm}" \
      "protection_state=error" \
      "transport_state=rearm_failed" \
      "last_error=xcolo_rearm_failed"
    return 1
  }
  ftctl_log_event "rearm" "xcolo.rearm" "ok" "${vm}" "" \
    "rearm_count=${count}"
}

ftctl_xcolo_failover() {
  local vm="${1-}"
  local secondary_vm=""

  secondary_vm="$(ftctl_state_get "${vm}" "secondary_vm_name" 2>/dev/null || true)"
  [[ -n "${secondary_vm}" ]] || secondary_vm="${vm}"

  if [[ "${FTCTL_DRY_RUN}" == "1" ]]; then
    ftctl_state_set "${vm}" \
      "protection_state=failed_over" \
      "active_side=secondary" \
      "transport_state=colo_failover_dry_run"
    ftctl_log_event "failover" "xcolo.failover" "skip" "${vm}" "" "reason=dry_run"
    return 0
  fi

  ftctl_xcolo_qmp_require_ok "${FTCTL_PROFILE_SECONDARY_URI}" "${secondary_vm}" \
    '{"execute":"nbd-server-stop"}' "failover" "secondary.nbd_server_stop" || true
  ftctl_xcolo_qmp_require_ok "${FTCTL_PROFILE_SECONDARY_URI}" "${secondary_vm}" \
    '{"execute":"x-colo-lost-heartbeat"}' "failover" "secondary.x_colo_lost_heartbeat" || return 1

  ftctl_state_set "${vm}" \
    "protection_state=failed_over" \
    "active_side=secondary" \
    "transport_state=colo_failover"
  ftctl_log_event "failover" "xcolo.failover" "ok" "${vm}" "" "active_side=secondary"
}

ftctl_xcolo_failback_policy() {
  local vm="${1-}"
  local disk_kind primary_target primary_source primary_format
  disk_kind="$(ftctl_state_get "${vm}" "primary_disk_type" 2>/dev/null || true)"
  if [[ "${disk_kind}" == "block" ]]; then
    printf '%s\n' "block-ft-cold-cutback"
    return 0
  fi
  if ftctl_xcolo_detect_block_backed_ft "${vm}" disk_kind primary_target primary_source primary_format; then
    printf '%s\n' "block-ft-cold-cutback"
  else
    printf '%s\n' "file-ft-runtime-cutback"
  fi
}

ftctl_xcolo_failback_record_state() {
  local vm="${1-}"
  local policy="${2-}"
  local stage="${3-}"
  local transport="${4-}"
  local reason="${5-}"
  local prev_transport

  prev_transport="$(ftctl_state_get "${vm}" "transport_state" 2>/dev/null || echo "unknown")"
  ftctl_state_set "${vm}" \
    "protection_state=failing_back" \
    "transport_state=${transport}" \
    "last_error=${reason}" \
    "xcolo_failback_policy=${policy}" \
    "xcolo_failback_stage=${stage}" \
    "xcolo_failback_prev_transport=${prev_transport}"
}

ftctl_xcolo_collect_disks_on_uri() {
  local uri="${1-}"
  local vm="${2-}"
  local out_array_name="${3}"
  local out err rc
  local -n _out_array="${out_array_name}"
  local line dtype device target source

  _out_array=()
  out=""
  err=""
  rc=0
  ftctl_virsh "${FTCTL_BLOCKCOPY_WAIT_TIMEOUT_SEC}" out err rc -- -c "${uri}" domblklist "${vm}" --details || true
  if [[ "${rc}" != "0" ]]; then
    return "${rc}"
  fi

  while IFS= read -r line; do
    [[ -n "${line}" ]] || continue
    case "${line}" in
      Type*|----*) continue ;;
    esac
    dtype="$(awk '{print $1}' <<< "${line}")"
    device="$(awk '{print $2}' <<< "${line}")"
    target="$(awk '{print $3}' <<< "${line}")"
    source="$(awk '{print $4}' <<< "${line}")"
    [[ "${device}" == "disk" ]] || continue
    [[ -n "${target}" && -n "${source}" && "${source}" != "-" ]] || continue
    _out_array+=("${target}|${source}|${dtype}")
  done <<< "${out}"
  ((${#_out_array[@]} > 0))
}

ftctl_xcolo_collect_disks_from_xml() {
  local xml_path="${1-}"
  local out_array_name="${2}"
  local -n _out_array="${out_array_name}"

  _out_array=()
  [[ -n "${xml_path}" && -f "${xml_path}" ]] || return 1

  mapfile -t _out_array < <(python3 - <<'PY' "${xml_path}"
import sys, xml.etree.ElementTree as ET
xml_path = sys.argv[1]
root = ET.parse(xml_path).getroot()
for disk in root.findall("./devices/disk"):
    if disk.get("device") != "disk":
        continue
    target = disk.find("target")
    source = disk.find("source")
    if target is None or source is None:
        continue
    dev = target.get("dev", "")
    path = source.get("file") or source.get("dev") or ""
    if dev and path:
        print(f"{dev}|{path}|xml")
PY
)
  ((${#_out_array[@]} > 0))
}

ftctl_xcolo_collect_prebuilt_file_pair_paths() {
  local vm="${1-}"
  local primary_parent_var="${2}"
  local secondary_active_var="${3}"
  local primary_xml secondary_xml payload

  primary_xml="$(ftctl_state_get "${vm}" "primary_xml_backup" 2>/dev/null || true)"
  secondary_xml="$(ftctl_state_get "${vm}" "standby_xml_seed" 2>/dev/null || true)"
  [[ -n "${primary_xml}" && -f "${primary_xml}" && -n "${secondary_xml}" && -f "${secondary_xml}" ]] || return 1

  payload="$(python3 - <<'PY' "${primary_xml}" "${secondary_xml}"
import sys, xml.etree.ElementTree as ET
qns = {'qemu': 'http://libvirt.org/schemas/domain/qemu/1.0'}
primary_xml, secondary_xml = sys.argv[1], sys.argv[2]

def collect(xml_path):
    root = ET.parse(xml_path).getroot()
    vals = []
    for node in root.findall('.//qemu:arg', qns):
        v = node.get('value', '')
        if v:
            vals.append(v)
    return vals

primary_args = collect(primary_xml)
secondary_args = collect(secondary_xml)
primary_parent = ''
secondary_active = ''
for v in primary_args:
    if 'id=parent0' in v and 'file.filename=' in v:
        part = v.split('file.filename=', 1)[1]
        primary_parent = part.split(',', 1)[0]
        break
    if 'id=colo-disk0' in v and 'children.0.file.filename=' in v:
        part = v.split('children.0.file.filename=', 1)[1]
        primary_parent = part.split(',', 1)[0]
        break
for v in secondary_args:
    if 'file.file.filename=' in v:
        part = v.split('file.file.filename=', 1)[1]
        secondary_active = part.split(',', 1)[0]
        break
print(primary_parent + '|' + secondary_active)
PY
)" || payload="|"

  printf -v "${primary_parent_var}" '%s' "${payload%%|*}"
  printf -v "${secondary_active_var}" '%s' "${payload##*|}"
  [[ -n "${payload%%|*}" && -n "${payload##*|}" ]]
}

ftctl_xcolo_collect_prebuilt_file_pair_detail() {
  local vm="${1-}"
  local primary_parent_var="${2}"
  local secondary_parent_var="${3}"
  local secondary_hidden_var="${4}"
  local secondary_active_var="${5}"
  local primary_xml secondary_xml payload

  primary_xml="$(ftctl_state_get "${vm}" "primary_xml_backup" 2>/dev/null || true)"
  secondary_xml="$(ftctl_state_get "${vm}" "standby_xml_seed" 2>/dev/null || true)"
  [[ -n "${primary_xml}" && -f "${primary_xml}" && -n "${secondary_xml}" && -f "${secondary_xml}" ]] || return 1

  payload="$(python3 - <<'PY' "${primary_xml}" "${secondary_xml}"
import sys, xml.etree.ElementTree as ET
qns = {'qemu': 'http://libvirt.org/schemas/domain/qemu/1.0'}
primary_xml, secondary_xml = sys.argv[1], sys.argv[2]

def collect(xml_path):
    root = ET.parse(xml_path).getroot()
    vals = []
    for node in root.findall('.//qemu:arg', qns):
        v = node.get('value', '')
        if v:
            vals.append(v)
    return vals

primary_args = collect(primary_xml)
secondary_args = collect(secondary_xml)
primary_parent = ''
secondary_parent = ''
secondary_hidden = ''
secondary_active = ''

for v in primary_args:
    if 'id=parent0' in v and 'file.filename=' in v:
        part = v.split('file.filename=', 1)[1]
        primary_parent = part.split(',', 1)[0]
        break
    if 'id=colo-disk0' in v and 'children.0.file.filename=' in v:
        part = v.split('children.0.file.filename=', 1)[1]
        primary_parent = part.split(',', 1)[0]
        break

for v in secondary_args:
    if 'id=parent0' in v and 'file.filename=' in v:
        part = v.split('file.filename=', 1)[1]
        secondary_parent = part.split(',', 1)[0]
    if 'file.file.filename=' in v:
        part = v.split('file.file.filename=', 1)[1]
        secondary_active = part.split(',', 1)[0]
    if 'file.backing.file.filename=' in v:
        part = v.split('file.backing.file.filename=', 1)[1]
        secondary_hidden = part.split(',', 1)[0]

print("|".join([primary_parent, secondary_parent, secondary_hidden, secondary_active]))
PY
)" || payload="|||"

  printf -v "${primary_parent_var}" '%s' "${payload%%|*}"
  payload="${payload#*|}"
  printf -v "${secondary_parent_var}" '%s' "${payload%%|*}"
  payload="${payload#*|}"
  printf -v "${secondary_hidden_var}" '%s' "${payload%%|*}"
  printf -v "${secondary_active_var}" '%s' "${payload##*|}"
  [[ -n "${!primary_parent_var}" && -n "${!secondary_parent_var}" && -n "${!secondary_hidden_var}" && -n "${!secondary_active_var}" ]]
}

ftctl_xcolo_validate_prebuilt_file_pair_sizes() {
  local vm="${1-}"
  local primary_parent="" secondary_parent="" secondary_hidden="" secondary_active=""
  local primary_size="" secondary_parent_size="" secondary_hidden_size="" secondary_active_size=""
  local secondary_host="" secondary_user=""

  ftctl_xcolo_collect_prebuilt_file_pair_detail "${vm}" primary_parent secondary_parent secondary_hidden secondary_active || return 1
  ftctl_blockcopy_remote_target_host_user secondary_host secondary_user || return 1

  primary_size="$(ftctl_xcolo_disk_virtual_size_bytes "${primary_parent}" 2>/dev/null || true)"
  secondary_parent_size="$(ftctl_xcolo_remote_disk_virtual_size_bytes "${secondary_host}" "${secondary_user}" "${secondary_parent}" 2>/dev/null || true)"
  secondary_hidden_size="$(ftctl_xcolo_remote_disk_virtual_size_bytes "${secondary_host}" "${secondary_user}" "${secondary_hidden}" 2>/dev/null || true)"
  secondary_active_size="$(ftctl_xcolo_remote_disk_virtual_size_bytes "${secondary_host}" "${secondary_user}" "${secondary_active}" 2>/dev/null || true)"

  ftctl_state_set "${vm}" \
    "xcolo_primary_source_path=${primary_parent}" \
    "xcolo_secondary_parent_path=${secondary_parent}" \
    "xcolo_secondary_hidden_path=${secondary_hidden}" \
    "xcolo_secondary_active_path=${secondary_active}" \
    "xcolo_primary_source_size=${primary_size}" \
    "xcolo_secondary_parent_size=${secondary_parent_size}" \
    "xcolo_secondary_hidden_size=${secondary_hidden_size}" \
    "xcolo_secondary_active_size=${secondary_active_size}"

  [[ -n "${primary_size}" && -n "${secondary_parent_size}" && -n "${secondary_hidden_size}" && -n "${secondary_active_size}" ]] || return 1
  [[ "${primary_size}" == "${secondary_parent_size}" ]] || return 1
  [[ "${primary_size}" == "${secondary_hidden_size}" ]] || return 1
  [[ "${primary_size}" == "${secondary_active_size}" ]]
}

ftctl_xcolo_remote_copy_file_to_primary() {
  local vm="${1-}"
  local target="${2-}"
  local secondary_source="${3-}"
  local primary_dest="${4-}"
  local format="${5-}"
  local host="" user="" primary_host="" primary_user="" out="" err="" rc=0
  local tmp_dest="" remote_cmd=""

  [[ -n "${secondary_source}" && -n "${primary_dest}" ]] || return 1
  ftctl_blockcopy_remote_target_host_user host user || return 1
  if ! ftctl_blockcopy_primary_target_host_user primary_host primary_user 2>/dev/null || [[ -z "${primary_host}" ]]; then
    primary_host="$(ftctl_xcolo_primary_listen_host control 2>/dev/null || true)"
    primary_user="${FTCTL_PROFILE_FENCING_SSH_USER:-root}"
  fi
  [[ -n "${primary_host}" ]] || return 1
  tmp_dest="${primary_dest}.ftfb.tmp"

  remote_cmd="$(cat <<EOF
set -euo pipefail
src=$(printf '%q' "${secondary_source}")
dst=$(printf '%q' "${primary_dest}")
tmp_dst=$(printf '%q' "${tmp_dest}")
primary_host=$(printf '%q' "${primary_host}")
primary_user=$(printf '%q' "${primary_user}")
stage=\$(mktemp /tmp/${vm}-${target}-ftfb.XXXXXX.${format})
cleanup() {
  rm -f "\${stage}" >/dev/null 2>&1 || true
}
trap cleanup EXIT
qemu-img convert --force-share -p -f $(printf '%q' "${format}") -O $(printf '%q' "${format}") "\${src}" "\${stage}"
scp -o BatchMode=yes -o StrictHostKeyChecking=no "\${stage}" "\${primary_user}@\${primary_host}:\${tmp_dst}"
ssh -o BatchMode=yes -o StrictHostKeyChecking=no "\${primary_user}@\${primary_host}" "mv -f \${tmp_dst} \${dst}"
EOF
)"
  out=""
  err=""
  rc=0
  ftctl_blockcopy_remote_exec "${host}" "${user}" out err rc "${remote_cmd}" || true
  : "${out}${err}"
  [[ "${rc}" == "0" ]]
}

ftctl_xcolo_file_failback_sync_disks() {
  local vm="${1-}"
  local primary_source secondary_active format

  ftctl_xcolo_collect_prebuilt_file_pair_paths "${vm}" primary_source secondary_active || return 1
  format=""
  ftctl_inventory_detect_disk_format "${primary_source}" format
  ftctl_xcolo_remote_copy_file_to_primary "${vm}" "vda" "${secondary_active}" "${primary_source}" "${format:-qcow2}" || return 1
}

ftctl_xcolo_copy_block_active_back_to_primary() {
  local vm="${1-}"
  local secondary_active="${2-}"
  local primary_dest="${3-}"
  local secondary_host="" secondary_user=""
  local remote_stage="" local_stage="" remote_cmd="" out="" err="" rc=0

  [[ -n "${secondary_active}" && -n "${primary_dest}" ]] || return 1
  ftctl_blockcopy_remote_target_host_user secondary_host secondary_user || return 1

  remote_stage="/tmp/${vm}-block-failback.qcow2"
  local_stage="/tmp/${vm}-block-failback.qcow2"

  remote_cmd="$(cat <<EOF
set -euo pipefail
rm -f $(printf '%q' "${remote_stage}")
qemu-img convert -p -f qcow2 -O qcow2 $(printf '%q' "${secondary_active}") $(printf '%q' "${remote_stage}")
EOF
)"
  out=""
  err=""
  rc=0
  ftctl_blockcopy_remote_exec "${secondary_host}" "${secondary_user}" out err rc "${remote_cmd}" || true
  : "${out}${err}"
  [[ "${rc}" == "0" ]] || return 1

  out=""
  err=""
  rc=0
  ftctl_cmd_run "${FTCTL_BLOCKCOPY_WAIT_TIMEOUT_SEC}" out err rc -- \
    scp -o BatchMode=yes -o StrictHostKeyChecking=no "${secondary_user}@${secondary_host}:${remote_stage}" "${local_stage}" || true
  : "${out}${err}"
  if [[ "${rc}" != "0" ]]; then
    ftctl_blockcopy_remote_exec "${secondary_host}" "${secondary_user}" out err rc "rm -f $(printf '%q' "${remote_stage}")" || true
    return 1
  fi

  out=""
  err=""
  rc=0
  ftctl_cmd_run "${FTCTL_BLOCKCOPY_WAIT_TIMEOUT_SEC}" out err rc -- \
    qemu-img convert -p -f qcow2 -O qcow2 "${local_stage}" "${primary_dest}" || true
  : "${out}${err}"

  rm -f -- "${local_stage}" >/dev/null 2>&1 || true
  ftctl_blockcopy_remote_exec "${secondary_host}" "${secondary_user}" out err rc "rm -f $(printf '%q' "${remote_stage}")" || true

  [[ "${rc}" == "0" ]]
}

ftctl_xcolo_activate_secondary_seed_same_name() {
  local vm="${1-}"
  local seed content_b64 host="" user="" remote_cmd out="" err="" rc=0

  seed="$(ftctl_state_get "${vm}" "standby_xml_seed" 2>/dev/null || true)"
  [[ -n "${seed}" && -f "${seed}" ]] || return 1
  ftctl_blockcopy_remote_target_host_user host user || return 1
  content_b64="$(base64 -w0 "${seed}")"
  remote_cmd="$(cat <<EOF
set -euo pipefail
xml_path="/tmp/${vm}-ft-failback.xml"
printf '%s' '${content_b64}' | base64 -d > "\${xml_path}"
virsh destroy ${vm@Q} >/dev/null 2>&1 || true
virsh undefine ${vm@Q} >/dev/null 2>&1 || true
virsh create "\${xml_path}"
EOF
)"
  ftctl_blockcopy_remote_exec "${host}" "${user}" out err rc "${remote_cmd}" || true
  : "${out}${err}"
  [[ "${rc}" == "0" ]]
}

ftctl_xcolo_failback_file() {
  local vm="${1-}"
  local primary_generated out err rc

  primary_generated="$(ftctl_primary_generated_xml_path "${vm}")"

  ftctl_standby_materialize_primary_xml "${vm}" || {
    ftctl_xcolo_failback_record_state "${vm}" \
      "file-ft-runtime-cutback" \
      "materialize-primary-failed" \
      "ft_reverse_syncing" \
      "xcolo_file_failback_primary_xml_failed"
    return 1
  }

  ftctl_xcolo_failback_record_state "${vm}" \
    "file-ft-runtime-cutback" \
    "reverse-sync-copy" \
    "ft_reverse_syncing" \
    ""

  if ! ftctl_xcolo_file_failback_sync_disks "${vm}"; then
    ftctl_xcolo_failback_record_state "${vm}" \
      "file-ft-runtime-cutback" \
      "reverse-sync-copy-failed" \
      "ft_reverse_syncing" \
      "xcolo_file_failback_copy_failed"
    return 1
  fi

  ftctl_xcolo_failback_record_state "${vm}" \
    "file-ft-runtime-cutback" \
    "cutback-switching" \
    "ft_cutback_switching" \
    ""

  ftctl_xcolo_qmp_require_ok "${FTCTL_PROFILE_SECONDARY_URI}" "${vm}" \
    '{"execute":"nbd-server-stop"}' "failback" "secondary.nbd_server_stop" || true

  if ! ftctl_xcolo_activate_secondary_seed_same_name "${vm}"; then
    ftctl_xcolo_failback_record_state "${vm}" \
      "file-ft-runtime-cutback" \
      "secondary-activate-failed" \
      "ft_cutback_switching" \
      "xcolo_file_failback_secondary_activate_failed"
    return 1
  fi

  if ! ftctl_activate_domain_from_xml "${FTCTL_PROFILE_PRIMARY_URI}" "${vm}" "${primary_generated}"; then
    ftctl_xcolo_failback_record_state "${vm}" \
      "file-ft-runtime-cutback" \
      "primary-activate-failed" \
      "ft_cutback_switching" \
      "xcolo_file_failback_primary_activate_failed"
    return 1
  fi

  if ! ftctl_xcolo_plan_protect_prebuilt "${vm}"; then
    ftctl_xcolo_failback_record_state "${vm}" \
      "file-ft-runtime-cutback" \
      "reprotect-failed" \
      "ft_cutback_switching" \
      "xcolo_file_failback_reprotect_failed"
    return 1
  fi

  if ! ftctl_xcolo_wait_pair_running "${vm}" "20" "${vm}"; then
    ftctl_xcolo_failback_record_state "${vm}" \
      "file-ft-runtime-cutback" \
      "reprotect-not-running" \
      "ft_cutback_switching" \
      "xcolo_file_failback_reprotect_not_running"
    return 1
  fi

  ftctl_state_set "${vm}" \
    "active_side=primary" \
    "protection_state=colo_running" \
    "transport_state=mirroring" \
    "last_error="
  ftctl_log_event "failback" "xcolo.failback.file" "ok" "${vm}" "" \
    "reason=cutback_complete"
  return 0
}

ftctl_xcolo_failback_block() {
  local vm="${1-}"
  local primary_source="" secondary_active=""

  primary_source="$(ftctl_state_get "${vm}" "primary_disk_source" 2>/dev/null || true)"
  secondary_active="$(ftctl_xcolo_secondary_active_overlay_path "${vm}")"
  [[ -n "${primary_source}" && -n "${secondary_active}" ]] || {
    ftctl_xcolo_failback_record_state "${vm}" \
      "block-ft-cold-cutback" \
      "missing-paths" \
      "ft_reverse_syncing" \
      "xcolo_block_failback_missing_paths"
    return 1
  }

  ftctl_xcolo_failback_record_state "${vm}" \
    "block-ft-cold-cutback" \
    "secondary-stop" \
    "ft_reverse_syncing" \
    ""
  if ! ftctl_standby_deactivate "${vm}"; then
    ftctl_xcolo_failback_record_state "${vm}" \
      "block-ft-cold-cutback" \
      "secondary-stop-failed" \
      "ft_reverse_syncing" \
      "xcolo_block_failback_secondary_stop_failed"
    return 1
  fi

  ftctl_xcolo_failback_record_state "${vm}" \
    "block-ft-cold-cutback" \
    "reverse-sync-copy" \
    "ft_reverse_syncing" \
    ""
  if ! ftctl_xcolo_copy_block_active_back_to_primary "${vm}" "${secondary_active}" "${primary_source}"; then
    ftctl_xcolo_failback_record_state "${vm}" \
      "block-ft-cold-cutback" \
      "reverse-sync-copy-failed" \
      "ft_reverse_syncing" \
      "xcolo_block_failback_copy_failed"
    return 1
  fi

  ftctl_xcolo_failback_record_state "${vm}" \
    "block-ft-cold-cutback" \
    "primary-activate" \
    "ft_cutback_switching" \
    ""
  if ! ftctl_primary_activate_from_backup "${vm}"; then
    ftctl_xcolo_failback_record_state "${vm}" \
      "block-ft-cold-cutback" \
      "primary-activate-failed" \
      "ft_cutback_switching" \
      "xcolo_block_failback_primary_activate_failed"
    return 1
  fi

  ftctl_xcolo_failback_record_state "${vm}" \
    "block-ft-cold-cutback" \
    "reprotect" \
    "ft_cutback_switching" \
    ""
  if ! ftctl_xcolo_plan_protect_block_cold_conversion "${vm}"; then
    ftctl_xcolo_failback_record_state "${vm}" \
      "block-ft-cold-cutback" \
      "reprotect-failed" \
      "ft_cutback_switching" \
      "xcolo_block_failback_reprotect_failed"
    return 1
  fi

  ftctl_state_set "${vm}" \
    "active_side=primary" \
    "protection_state=colo_running" \
    "transport_state=mirroring" \
    "last_error="
  ftctl_log_event "failback" "xcolo.failback.block" "ok" "${vm}" "" \
    "reason=cold_cutback_complete"
  return 0
}

ftctl_xcolo_failback() {
  local vm="${1-}"
  local policy transport

  policy="$(ftctl_xcolo_failback_policy "${vm}")"
  transport="$(ftctl_state_get "${vm}" "transport_state" 2>/dev/null || echo "unknown")"

  if ! ftctl_verify_xcolo_failback_ready "${vm}"; then
    ftctl_state_set "${vm}" \
      "protection_state=error" \
      "last_error=xcolo_failback_precheck_failed"
    return 1
  fi

  case "${policy}" in
    file-ft-runtime-cutback)
      ftctl_log_event "failback" "xcolo.failback" "warn" "${vm}" "" \
        "policy=${policy} transport=${transport} dispatch=file"
      ftctl_xcolo_failback_file "${vm}"
      ;;
    block-ft-cold-cutback)
      ftctl_log_event "failback" "xcolo.failback" "warn" "${vm}" "" \
        "policy=${policy} transport=${transport} dispatch=block"
      ftctl_xcolo_failback_block "${vm}"
      ;;
    *)
      ftctl_xcolo_failback_record_state "${vm}" \
        "${policy}" \
        "invalid-policy" \
        "ft_reverse_syncing" \
        "xcolo_failback_unknown_policy"
      ftctl_log_event "failback" "xcolo.failback" "fail" "${vm}" "" \
        "policy=${policy} transport=${transport} reason=unknown_policy"
      return 1
      ;;
  esac
}
