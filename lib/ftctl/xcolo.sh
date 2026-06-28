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

ftctl_xcolo_machine_value_normalize() {
  local value="${1-}"
  value="${value%%,*}"
  value="${value//\"/}"
  value="${value//\'/}"
  printf '%s\n' "${value}"
}

ftctl_xcolo_machine_from_xml_text() {
  local xml_text="${1-}"
  [[ -n "${xml_text}" ]] || return 1
  XML_TEXT="${xml_text}" python3 - <<'PY'
import os
import sys
import xml.etree.ElementTree as ET

text = os.environ.get("XML_TEXT", "")
try:
    root = ET.fromstring(text)
except Exception:
    sys.exit(1)
os_type = root.find("./os/type")
machine = os_type.get("machine", "") if os_type is not None else ""
if not machine:
    sys.exit(1)
print(machine.split(",", 1)[0])
PY
}

ftctl_xcolo_machine_from_qemu_args_text() {
  local args_text="${1-}"
  [[ -n "${args_text}" ]] || return 1
  ARGS_TEXT="${args_text}" python3 - <<'PY'
import os
import re
import shlex
import sys

text = os.environ.get("ARGS_TEXT", "")
try:
    tokens = shlex.split(text)
except Exception:
    tokens = text.split()

for index, token in enumerate(tokens):
    if token == "-machine" and index + 1 < len(tokens):
        print(tokens[index + 1].split(",", 1)[0])
        sys.exit(0)
    if token.startswith("-machine="):
        print(token.split("=", 1)[1].split(",", 1)[0])
        sys.exit(0)

match = re.search(r"(?:^|\s)-machine\s+([^\s]+)", text)
if match:
    print(match.group(1).split(",", 1)[0].strip("'\""))
    sys.exit(0)
sys.exit(1)
PY
}

ftctl_xcolo_primary_qemu_log_path() {
  local vm="${1-}"
  printf '/var/log/libvirt/qemu/%s.log\n' "${vm}"
}

ftctl_xcolo_resolve_primary_machine_type() {
  local vm="${1-}"
  local machine_var="${2}"
  local source_var="${3}"
  local out err rc xml_machine="" log_machine="" proc_machine="" log_path log_text proc_line

  printf -v "${machine_var}" '%s' ""
  printf -v "${source_var}" '%s' ""

  out=""
  err=""
  rc=0
  ftctl_virsh "${FTCTL_BLOCKCOPY_WAIT_TIMEOUT_SEC}" out err rc -- -c "${FTCTL_PROFILE_PRIMARY_URI}" dumpxml "${vm}" || true
  : "${err}"
  if [[ "${rc}" == "0" ]]; then
    xml_machine="$(ftctl_xcolo_machine_from_xml_text "${out}" 2>/dev/null || true)"
    xml_machine="$(ftctl_xcolo_machine_value_normalize "${xml_machine}")"
  fi

  log_path="$(ftctl_xcolo_primary_qemu_log_path "${vm}")"
  if [[ -r "${log_path}" ]]; then
    log_text="$(tail -n 80 "${log_path}" 2>/dev/null || true)"
    log_machine="$(ftctl_xcolo_machine_from_qemu_args_text "${log_text}" 2>/dev/null || true)"
    log_machine="$(ftctl_xcolo_machine_value_normalize "${log_machine}")"
  fi

  proc_line="$(pgrep -af "qemu.*guest=${vm}" 2>/dev/null | tail -n 1 || true)"
  if [[ -n "${proc_line}" ]]; then
    proc_machine="$(ftctl_xcolo_machine_from_qemu_args_text "${proc_line}" 2>/dev/null || true)"
    proc_machine="$(ftctl_xcolo_machine_value_normalize "${proc_machine}")"
  fi

  if [[ "${proc_machine}" == pc-i440fx-* ]]; then
    printf -v "${machine_var}" '%s' "${proc_machine}"
    printf -v "${source_var}" '%s' "process-argv"
    return 0
  fi
  if [[ "${log_machine}" == pc-i440fx-* ]]; then
    printf -v "${machine_var}" '%s' "${log_machine}"
    printf -v "${source_var}" '%s' "qemu-log"
    return 0
  fi
  if [[ "${xml_machine}" == pc-i440fx-* ]]; then
    printf -v "${machine_var}" '%s' "${xml_machine}"
    printf -v "${source_var}" '%s' "libvirt-xml"
    return 0
  fi

  if [[ -n "${proc_machine}" ]]; then
    printf -v "${machine_var}" '%s' "${proc_machine}"
    printf -v "${source_var}" '%s' "process-argv"
    return 0
  fi
  if [[ -n "${log_machine}" ]]; then
    printf -v "${machine_var}" '%s' "${log_machine}"
    printf -v "${source_var}" '%s' "qemu-log"
    return 0
  fi
  if [[ -n "${xml_machine}" ]]; then
    printf -v "${machine_var}" '%s' "${xml_machine}"
    printf -v "${source_var}" '%s' "libvirt-xml"
    return 0
  fi

  return 1
}

ftctl_xcolo_require_supported_machine_contract() {
  local vm="${1-}"
  local machine="" source="" reason=""

  ftctl_xcolo_resolve_primary_machine_type "${vm}" machine source || true
  machine="$(ftctl_xcolo_machine_value_normalize "${machine}")"
  [[ -n "${source}" ]] || source="unknown"

  if [[ "${machine}" == pc-i440fx-* ]]; then
    ftctl_state_set "${vm}" \
      "ft_machine_type_supported=yes" \
      "ft_machine_type_effective=${machine}" \
      "ft_machine_type_contract_source=${source}" \
      "ft_colo_return_path=false"
    ftctl_log_event "colo" "xcolo.machine_contract" "ok" "${vm}" "" \
      "machine=${machine} source=${source} return_path=false"
    return 0
  fi

  if [[ -z "${machine}" ]]; then
    reason="unknown"
  elif [[ "${machine}" == q35 || "${machine}" == pc-q35-* ]]; then
    reason="q35"
  else
    reason="unsupported"
  fi

  ftctl_state_set "${vm}" \
    "conversion_stage=machine_contract_failed" \
    "conversion_state=error" \
    "protection_state=error" \
    "transport_state=failed" \
    "ft_machine_type_supported=no" \
    "ft_machine_type_effective=${machine}" \
    "ft_machine_type_contract_source=${source}" \
    "xcolo_protocol_failure_phase=machine_contract" \
    "last_error=ft_unsupported_machine_type"
  ftctl_log_event "colo" "xcolo.machine_contract" "fail" "${vm}" "" \
    "machine=${machine} source=${source} reason=${reason} supported=pc-i440fx-*"
  return 1
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
    if [[ "${error_desc}" == *"Node '"* && "${error_desc}" == *" is busy"* ]]; then
      ftctl_state_set "${vm}" \
        "xcolo_block_graph_busy=yes" \
        "xcolo_block_graph_busy_event=${event}" \
        "xcolo_block_graph_busy_desc=${error_desc}" \
        "xcolo_protocol_failure_phase=block_graph_busy" \
        "last_error=xcolo_block_graph_busy"
    fi
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
    '{"execute":"migrate-set-capabilities","arguments":{"capabilities":[{"capability":"return-path","state":false},{"capability":"x-colo","state":true}]}}' \
    "colo" "${stage_prefix}.migrate_set_capabilities" || return 1

  ftctl_xcolo_query_migrate_capability_state "${uri}" "${domain}" "x-colo" cap_xcolo || true
  ftctl_xcolo_query_migrate_capability_state "${uri}" "${domain}" "return-path" cap_return_path || true
  ftctl_state_set "${vm}" \
    "xcolo_${role}_capability_x_colo=${cap_xcolo}" \
    "xcolo_${role}_capability_return_path=${cap_return_path}"

  if [[ "${cap_xcolo}" != "yes" || ( "${cap_return_path}" != "no" && "${cap_return_path}" != "unknown" ) ]]; then
    ftctl_state_set "${vm}" \
      "last_error=${role}_colo_migrate_capability_missing"
    ftctl_log_event "colo" "${stage_prefix}.migrate_capabilities" "fail" "${vm}" "" \
      "domain=${domain} x_colo=${cap_xcolo} return_path=${cap_return_path} expected_return_path=no"
    return 1
  fi

  ftctl_log_event "colo" "${stage_prefix}.migrate_capabilities" "ok" "${vm}" "" \
    "domain=${domain} x_colo=${cap_xcolo} return_path=${cap_return_path} expected_return_path=no"
}

ftctl_xcolo_secondary_accept_deferred_incoming() {
  local vm="${1-}"
  local secondary_vm="${2-}"
  local phase="${3:-pre_migrate}"
  local uri="${FTCTL_PROFILE_XCOLO_MIGRATE_URI}"
  local payload status migrate_status migrate_error

  [[ -n "${vm}" && -n "${secondary_vm}" && -n "${uri}" ]] || return 1
  payload="$(printf '{"execute":"migrate-incoming","arguments":{"uri":"%s"}}' "${uri}")"

  ftctl_state_set "${vm}" \
    "xcolo_secondary_incoming_mode=defer" \
    "xcolo_secondary_incoming_uri=${uri}" \
    "xcolo_secondary_migrate_incoming_phase=${phase}"
  ftctl_log_event "colo" "secondary.migrate_incoming" "start" "${vm}" "" \
    "secondary=${secondary_vm} uri=${uri} phase=${phase}"

  ftctl_xcolo_qmp_require_ok "${FTCTL_PROFILE_SECONDARY_URI}" "${secondary_vm}" \
    "${payload}" "colo" "secondary.migrate_incoming" || {
    ftctl_xcolo_query_status_name "${FTCTL_PROFILE_SECONDARY_URI}" "${secondary_vm}" status || true
    ftctl_xcolo_query_migrate_status "${FTCTL_PROFILE_SECONDARY_URI}" "${secondary_vm}" migrate_status || true
    ftctl_xcolo_query_migrate_error_desc "${FTCTL_PROFILE_SECONDARY_URI}" "${secondary_vm}" migrate_error || true
    ftctl_state_set "${vm}" \
      "xcolo_secondary_migrate_incoming=failed" \
      "xcolo_secondary_migrate_incoming_status=${status}" \
      "xcolo_secondary_migrate_incoming_migrate_status=${migrate_status}" \
      "xcolo_secondary_migrate_incoming_error=$(ftctl_xcolo_compact_log_value "${migrate_error}")" \
      "xcolo_protocol_failure_phase=secondary_migrate_incoming" \
      "last_error=xcolo_secondary_migrate_incoming_failed"
    ftctl_log_event "colo" "secondary.migrate_incoming" "fail" "${vm}" "" \
      "secondary=${secondary_vm} status=${status} migrate_status=${migrate_status} error=$(ftctl_xcolo_compact_log_value "${migrate_error}")"
    return 1
  }

  status=""
  migrate_status=""
  migrate_error=""
  ftctl_xcolo_query_status_name "${FTCTL_PROFILE_SECONDARY_URI}" "${secondary_vm}" status || true
  ftctl_xcolo_query_migrate_status "${FTCTL_PROFILE_SECONDARY_URI}" "${secondary_vm}" migrate_status || true
  ftctl_xcolo_query_migrate_error_desc "${FTCTL_PROFILE_SECONDARY_URI}" "${secondary_vm}" migrate_error || true
  if [[ -n "${migrate_error}" ]]; then
    ftctl_state_set "${vm}" \
      "xcolo_secondary_migrate_incoming=failed" \
      "xcolo_secondary_migrate_incoming_status=${status}" \
      "xcolo_secondary_migrate_incoming_migrate_status=${migrate_status}" \
      "xcolo_secondary_migrate_incoming_error=$(ftctl_xcolo_compact_log_value "${migrate_error}")" \
      "xcolo_protocol_failure_phase=secondary_migrate_incoming" \
      "last_error=xcolo_secondary_migrate_incoming_failed"
    ftctl_log_event "colo" "secondary.migrate_incoming" "fail" "${vm}" "" \
      "secondary=${secondary_vm} status=${status} migrate_status=${migrate_status} error=$(ftctl_xcolo_compact_log_value "${migrate_error}")"
    return 1
  fi

  ftctl_state_set "${vm}" \
    "xcolo_secondary_migrate_incoming=ok" \
    "xcolo_secondary_migrate_incoming_status=${status}" \
    "xcolo_secondary_migrate_incoming_migrate_status=${migrate_status}"
  ftctl_log_event "colo" "secondary.migrate_incoming" "ok" "${vm}" "" \
    "secondary=${secondary_vm} status=${status:-unknown} migrate_status=${migrate_status:-unknown}"
}

ftctl_xcolo_require_pre_migrate_receiver_ready() {
  local vm="${1-}"
  local secondary_vm="${2-}"
  local phase="${3:-pre_migrate_receiver}"
  local status="" migrate_status="" migrate_error="" running=""

  [[ -n "${vm}" && -n "${secondary_vm}" ]] || return 1
  [[ "${FTCTL_DRY_RUN}" != "1" ]] || return 0

  ftctl_xcolo_query_status_name "${FTCTL_PROFILE_SECONDARY_URI}" "${secondary_vm}" status || true
  ftctl_xcolo_query_running_flag "${FTCTL_PROFILE_SECONDARY_URI}" "${secondary_vm}" running || true
  ftctl_xcolo_query_migrate_status "${FTCTL_PROFILE_SECONDARY_URI}" "${secondary_vm}" migrate_status || true
  ftctl_xcolo_query_migrate_error_desc "${FTCTL_PROFILE_SECONDARY_URI}" "${secondary_vm}" migrate_error || true

  if [[ -n "${migrate_error}" || "${migrate_status}" == "failed" || "${migrate_status}" == "cancelled" ]]; then
    ftctl_state_set "${vm}" \
      "xcolo_pre_migrate_receiver_ready=failed" \
      "xcolo_pre_migrate_receiver_phase=${phase}" \
      "xcolo_pre_migrate_receiver_status=${status}" \
      "xcolo_pre_migrate_receiver_running=${running}" \
      "xcolo_pre_migrate_receiver_migrate_status=${migrate_status}" \
      "xcolo_pre_migrate_receiver_error=$(ftctl_xcolo_compact_log_value "${migrate_error}")" \
      "xcolo_protocol_failure_phase=pre_migrate_receiver" \
      "last_error=xcolo_pre_migrate_receiver_not_ready"
    ftctl_log_event "colo" "xcolo.pre_migrate_receiver" "fail" "${vm}" "" \
      "secondary=${secondary_vm} status=${status:-unknown} running=${running:-unknown} migrate_status=${migrate_status:-unknown} error=$(ftctl_xcolo_compact_log_value "${migrate_error}")"
    return 1
  fi

  ftctl_state_set "${vm}" \
    "xcolo_pre_migrate_receiver_ready=ok" \
    "xcolo_pre_migrate_receiver_phase=${phase}" \
    "xcolo_pre_migrate_receiver_status=${status}" \
    "xcolo_pre_migrate_receiver_running=${running}" \
    "xcolo_pre_migrate_receiver_migrate_status=${migrate_status}" \
    "xcolo_protocol_failure_phase="
  ftctl_log_event "colo" "xcolo.pre_migrate_receiver" "ok" "${vm}" "" \
    "secondary=${secondary_vm} status=${status:-unknown} running=${running:-unknown} migrate_status=${migrate_status:-unknown}"
}

ftctl_xcolo_record_pre_migrate_materialization_result() {
  local vm="${1-}"
  local gate_state

  [[ -n "${vm}" ]] || return 0
  gate_state="$(ftctl_state_get "${vm}" "xcolo_pre_migrate_topology_gate_state" 2>/dev/null || true)"
  case "${gate_state}" in
    deferred)
      ftctl_state_set "${vm}" \
        "xcolo_secondary_incoming_materialization=failed" \
        "xcolo_secondary_incoming_materialization_phase=before_migrate" \
        "xcolo_protocol_failure_phase=pre_migrate_materialization" \
        "last_error=xcolo_pre_migrate_secondary_pci_resource_unmaterialized"
      ;;
    *)
      ftctl_state_set "${vm}" \
        "xcolo_secondary_incoming_materialization=ok" \
        "xcolo_secondary_incoming_materialization_phase=before_migrate"
      ;;
  esac
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

ftctl_xcolo_capture_primary_qga_baseline() {
  local vm="${1-}"
  local qga_policy="${FTCTL_PROFILE_QGA_POLICY:-optional}"
  local baseline="unavailable" qga="" now

  now="$(ftctl_now_iso8601)"
  if [[ "${qga_policy}" == "off" ]]; then
    baseline="off"
  else
    ftctl_xcolo_query_guest_ping "${FTCTL_PROFILE_PRIMARY_URI}" "${vm}" qga || true
    if [[ "${qga}" == "yes" ]]; then
      baseline="available"
    fi
  fi

  ftctl_state_set "${vm}" \
    "xcolo_primary_qga_baseline=${baseline}" \
    "xcolo_primary_qga_baseline_policy=${qga_policy}" \
    "xcolo_primary_qga_baseline_ts=${now}" \
    "xcolo_primary_guest_health_qga_success_count=0" \
    "xcolo_primary_guest_health_pending_since=" \
    "xcolo_primary_guest_health_elapsed=0" \
    "xcolo_primary_guest_health_reason=baseline_${baseline}"
  ftctl_log_event "colo" "xcolo.primary_qga_baseline" "ok" "${vm}" "" \
    "baseline=${baseline} policy=${qga_policy}"
  return 0
}

ftctl_xcolo_primary_migrate_state_ok() {
  local status="${1-}"
  [[ "${status}" == "active" || "${status}" == "colo" ]]
}

ftctl_xcolo_primary_qemu_log_path() {
  local vm="${1-}"
  printf '%s\n' "/var/log/libvirt/qemu/${vm}.log"
}

ftctl_xcolo_capture_primary_qemu_log_baseline() {
  local vm="${1-}"
  local log_path offset="0" now

  log_path="$(ftctl_xcolo_primary_qemu_log_path "${vm}")"
  if [[ -e "${log_path}" ]]; then
    offset="$(stat -c '%s' "${log_path}" 2>/dev/null || echo "0")"
  fi
  [[ "${offset}" =~ ^[0-9]+$ ]] || offset="0"
  now="$(ftctl_now_iso8601)"
  ftctl_state_set "${vm}" \
    "xcolo_primary_qemu_log_health_path=${log_path}" \
    "xcolo_primary_qemu_log_health_offset=${offset}" \
    "xcolo_primary_qemu_log_health_baseline_ts=${now}" \
    "xcolo_primary_qemu_log_health_window=baseline"
  ftctl_log_event "colo" "xcolo.primary_qemu_log_baseline" "ok" "${vm}" "" \
    "path=${log_path} offset=${offset}"
  return 0
}

ftctl_xcolo_primary_qemu_log_tail() {
  local vm="${1-}"
  local out_var="${2}"
  local log_path out="" offset="" size="" start_byte lines

  log_path="$(ftctl_xcolo_primary_qemu_log_path "${vm}")"
  lines="${FTCTL_XCOLO_PRIMARY_HEALTH_LOG_TAIL_LINES:-500}"
  [[ "${lines}" =~ ^[0-9]+$ && "${lines}" -gt 0 ]] || lines="500"
  if [[ -r "${log_path}" ]]; then
    offset="$(ftctl_state_get "${vm}" "xcolo_primary_qemu_log_health_offset" 2>/dev/null || true)"
    size="$(stat -c '%s' "${log_path}" 2>/dev/null || echo "")"
    if [[ "${offset}" =~ ^[0-9]+$ && "${size}" =~ ^[0-9]+$ && "${size}" -ge "${offset}" ]]; then
      start_byte=$((offset + 1))
      out="$(tail -c +"${start_byte}" "${log_path}" 2>/dev/null | tail -n "${lines}" 2>/dev/null || true)"
      ftctl_state_set "${vm}" \
        "xcolo_primary_qemu_log_health_window=offset" \
        "xcolo_primary_qemu_log_health_size=${size}"
    else
      out="$(tail -n "${lines}" "${log_path}" 2>/dev/null || true)"
      ftctl_state_set "${vm}" \
        "xcolo_primary_qemu_log_health_window=fallback_tail" \
        "xcolo_primary_qemu_log_health_size=${size:-unknown}"
    fi
  fi
  printf -v "${out_var}" '%s' "${out}"
}

ftctl_xcolo_primary_storage_failure_reason_from_text() {
  local text="${1-}"
  local reason_var="${2}"
  local detected_reason=""

  if printf '%s\n' "${text}" | grep -Eiq 'blk_update_request'; then
    detected_reason="qemu_log_block_request_error"
  elif printf '%s\n' "${text}" | grep -Eiq 'Buffer I/O error|end_request.*I/O error|block.*(Input/output error|I/O error)|No space left on device'; then
    detected_reason="qemu_log_block_io_error"
  elif printf '%s\n' "${text}" | grep -Eiq 'rbd.*(error|failed|denied|not permitted)|((error|failed|denied|not permitted).*)rbd'; then
    detected_reason="qemu_log_rbd_error"
  fi

  printf -v "${reason_var}" '%s' "${detected_reason}"
  [[ -z "${detected_reason}" ]]
}

ftctl_xcolo_primary_protocol_notice_from_text() {
  local text="${1-}"
  local notice_var="${2}"
  local detected_notice=""

  if printf '%s\n' "${text}" | grep -Eiq "Can't receive COLO message"; then
    detected_notice="colo_message_io_error"
  elif printf '%s\n' "${text}" | grep -Eiq 'Received invalid message'; then
    detected_notice="colo_invalid_message"
  elif printf '%s\n' "${text}" | grep -Eiq 'filter mirror send failed'; then
    detected_notice="filter_mirror_send_failed"
  fi

  printf -v "${notice_var}" '%s' "${detected_notice}"
  [[ -z "${detected_notice}" ]]
}

ftctl_xcolo_primary_guest_failure_reason_from_text() {
  local text="${1-}"
  local reason_var="${2}"
  local detected_reason=""

  if printf '%s\n' "${text}" | grep -Eiq 'Failed to mount /sysroot'; then
    detected_reason="sysroot_mount_failed"
  elif printf '%s\n' "${text}" | grep -Eiq 'Entering emergency mode'; then
    detected_reason="guest_entered_emergency_mode"
  elif printf '%s\n' "${text}" | grep -Eiq 'XFS .*metadata I/O error|Uncorrected metadata errors'; then
    detected_reason="guest_filesystem_metadata_io_error"
  elif printf '%s\n' "${text}" | grep -Eiq 'dracut-initqueue.*timeout'; then
    detected_reason="guest_dracut_initqueue_timeout"
  fi

  printf -v "${reason_var}" '%s' "${detected_reason}"
  [[ -z "${detected_reason}" ]]
}

ftctl_xcolo_validate_primary_storage_health() {
  local vm="${1-}"
  local reason_var="${2}"
  local disk_plan="${3-}"
  local out="" rc=0 log_tail="" reason="" protocol_notice="" rbd_conflict="" rbd_targets=""
  [[ -n "${disk_plan}" ]] || disk_plan="$(ftctl_state_get "${vm}" "xcolo_disk_plan" 2>/dev/null || true)"

  ftctl_xcolo_qmp "${FTCTL_PROFILE_PRIMARY_URI}" "${vm}" '{"execute":"query-block"}' out rc
  ftctl_xcolo_write_debug_file "${vm}" "primary-health-query-block.stdout.json" "${out}" || true
  ftctl_xcolo_write_debug_file "${vm}" "primary-health-query-block.rc" "${rc}" || true
  if [[ "${rc}" != "0" ]]; then
    reason="query_block_failed"
  elif printf '%s\n' "${out}" | grep -Eiq '"io-status"[[:space:]]*:[[:space:]]*"failed"'; then
    reason="primary_block_io_status_failed"
  fi

  out=""
  rc=0
  ftctl_xcolo_qmp "${FTCTL_PROFILE_PRIMARY_URI}" "${vm}" '{"execute":"query-named-block-nodes"}' out rc
  ftctl_xcolo_write_debug_file "${vm}" "primary-health-query-named-block-nodes.stdout.json" "${out}" || true
  ftctl_xcolo_write_debug_file "${vm}" "primary-health-query-named-block-nodes.rc" "${rc}" || true
  if [[ -z "${reason}" && "${rc}" != "0" ]]; then
    reason="query_named_block_nodes_failed"
  fi

  out=""
  rc=0
  ftctl_xcolo_qmp "${FTCTL_PROFILE_PRIMARY_URI}" "${vm}" '{"execute":"query-blockstats"}' out rc
  ftctl_xcolo_write_debug_file "${vm}" "primary-health-query-blockstats.stdout.json" "${out}" || true
  ftctl_xcolo_write_debug_file "${vm}" "primary-health-query-blockstats.rc" "${rc}" || true
  if [[ -z "${reason}" && "${rc}" != "0" ]]; then
    reason="query_blockstats_failed"
  fi

  ftctl_xcolo_primary_qemu_log_tail "${vm}" log_tail || true
  ftctl_xcolo_write_debug_file "${vm}" "primary-health-qemu-log-tail.txt" "${log_tail}" || true
  if [[ -n "${log_tail}" ]]; then
    ftctl_xcolo_primary_protocol_notice_from_text "${log_tail}" protocol_notice || true
    if [[ -n "${protocol_notice}" ]]; then
      ftctl_state_set "${vm}" \
        "xcolo_primary_protocol_log_notice=${protocol_notice}" \
        "xcolo_primary_protocol_log_notice_window=$(ftctl_state_get "${vm}" "xcolo_primary_qemu_log_health_window" 2>/dev/null || true)"
      ftctl_log_event "colo" "xcolo.primary_protocol_log_notice" "warn" "${vm}" "" \
        "notice=${protocol_notice} window=$(ftctl_state_get "${vm}" "xcolo_primary_qemu_log_health_window" 2>/dev/null || true)"
    else
      ftctl_state_set "${vm}" \
        "xcolo_primary_protocol_log_notice=" \
        "xcolo_primary_protocol_log_notice_window=$(ftctl_state_get "${vm}" "xcolo_primary_qemu_log_health_window" 2>/dev/null || true)"
    fi
  else
    ftctl_state_set "${vm}" \
      "xcolo_primary_protocol_log_notice=" \
      "xcolo_primary_protocol_log_notice_window=$(ftctl_state_get "${vm}" "xcolo_primary_qemu_log_health_window" 2>/dev/null || true)"
  fi
  if [[ -z "${reason}" && -n "${log_tail}" ]]; then
    ftctl_xcolo_primary_storage_failure_reason_from_text "${log_tail}" reason || true
  fi
  if [[ -z "${reason}" && -n "${disk_plan}" ]]; then
    ftctl_xcolo_capture_primary_rbd_owner_evidence "${vm}" "${disk_plan}" "storage_health" || true
    rbd_conflict="$(ftctl_state_get "${vm}" "xcolo_primary_storage_health_rbd_runtime_owner_conflict" 2>/dev/null || true)"
    rbd_targets="$(ftctl_state_get "${vm}" "xcolo_primary_storage_health_rbd_runtime_owner_conflict_targets" 2>/dev/null || true)"
    if [[ "${rbd_conflict}" == "yes" ]]; then
      reason="primary_rbd_runtime_owner_conflict${rbd_targets:+:${rbd_targets}}"
    fi
  fi

  if [[ -n "${reason}" ]]; then
    ftctl_state_set "${vm}" \
      "xcolo_primary_storage_health_gate=failed" \
      "xcolo_primary_storage_health_reason=${reason}" \
      "xcolo_primary_storage_health_log_window=$(ftctl_state_get "${vm}" "xcolo_primary_qemu_log_health_window" 2>/dev/null || true)"
    ftctl_log_event "colo" "xcolo.primary_storage_health" "fail" "${vm}" "" \
      "reason=${reason} window=$(ftctl_state_get "${vm}" "xcolo_primary_qemu_log_health_window" 2>/dev/null || true)"
    printf -v "${reason_var}" '%s' "xcolo_primary_storage_unhealthy:${reason}"
    return 1
  fi

  ftctl_state_set "${vm}" \
    "xcolo_primary_storage_health_gate=ok" \
    "xcolo_primary_storage_health_reason=ok" \
    "xcolo_primary_storage_health_log_window=$(ftctl_state_get "${vm}" "xcolo_primary_qemu_log_health_window" 2>/dev/null || true)"
  ftctl_log_event "colo" "xcolo.primary_storage_health" "ok" "${vm}" "" \
    "window=$(ftctl_state_get "${vm}" "xcolo_primary_qemu_log_health_window" 2>/dev/null || true) protocol_notice=${protocol_notice}"
  printf -v "${reason_var}" '%s' ""
  return 0
}

ftctl_xcolo_validate_primary_guest_health() {
  local vm="${1-}"
  local primary_qga="${2-}"
  local reason_var="${3}"
  local policy="${FTCTL_XCOLO_PRIMARY_GUEST_HEALTH_POLICY:-required}"
  local log_tail="" reason="" gate="ok"
  local pending_since="" pending_elapsed="0" pending_timeout
  local stable_required success_count now baseline

  case "${policy}" in
    required|observe|off) ;;
    *) policy="required" ;;
  esac

  pending_timeout="${FTCTL_XCOLO_PRIMARY_GUEST_HEALTH_TIMEOUT_SEC:-180}"
  [[ "${pending_timeout}" =~ ^[0-9]+$ && "${pending_timeout}" -gt 0 ]] || pending_timeout="180"
  stable_required="${FTCTL_XCOLO_PRIMARY_GUEST_HEALTH_STABLE_COUNT:-2}"
  [[ "${stable_required}" =~ ^[0-9]+$ && "${stable_required}" -gt 0 ]] || stable_required="2"
  baseline="$(ftctl_state_get "${vm}" "xcolo_primary_qga_baseline" 2>/dev/null || true)"
  [[ -n "${baseline}" ]] || baseline="unknown"

  if [[ "${policy}" == "off" ]]; then
    ftctl_state_set "${vm}" \
      "xcolo_primary_guest_health_gate=off" \
      "xcolo_primary_guest_health_policy=${policy}" \
      "xcolo_primary_guest_health_reason=policy_off" \
      "xcolo_primary_guest_health_timeout=${pending_timeout}"
    printf -v "${reason_var}" '%s' ""
    return 0
  fi

  ftctl_xcolo_primary_qemu_log_tail "${vm}" log_tail || true
  if [[ -n "${log_tail}" ]]; then
    ftctl_xcolo_primary_guest_failure_reason_from_text "${log_tail}" reason || true
  fi

  if [[ -n "${reason}" ]]; then
    ftctl_state_set "${vm}" \
      "xcolo_primary_guest_health_gate=failed" \
      "xcolo_primary_guest_health_policy=${policy}" \
      "xcolo_primary_guest_health_reason=${reason}" \
      "xcolo_primary_guest_health_timeout=${pending_timeout}" \
      "xcolo_primary_guest_health_qga_success_count=0"
    ftctl_log_event "colo" "xcolo.primary_guest_health" "fail" "${vm}" "" \
      "policy=${policy} qga=${primary_qga} baseline=${baseline} reason=${reason}"
    printf -v "${reason_var}" '%s' "xcolo_primary_guest_boot_unhealthy:${reason}"
    return 1
  fi

  if [[ "${policy}" == "observe" && "${primary_qga}" != "yes" ]]; then
    gate="observe"
    reason="qga_unavailable_observed"
    ftctl_state_set "${vm}" \
      "xcolo_primary_guest_health_gate=${gate}" \
      "xcolo_primary_guest_health_policy=${policy}" \
      "xcolo_primary_guest_health_reason=${reason}" \
      "xcolo_primary_guest_health_timeout=${pending_timeout}" \
      "xcolo_primary_guest_health_qga_success_count=0"
    ftctl_log_event "colo" "xcolo.primary_guest_health" "ok" "${vm}" "" \
      "policy=${policy} qga=${primary_qga} baseline=${baseline} gate=${gate} reason=${reason}"
    printf -v "${reason_var}" '%s' ""
    return 0
  fi

  if [[ "${primary_qga}" == "yes" ]]; then
    success_count="$(ftctl_state_get "${vm}" "xcolo_primary_guest_health_qga_success_count" 2>/dev/null || true)"
    [[ "${success_count}" =~ ^[0-9]+$ ]] || success_count="0"
    success_count=$((success_count + 1))
    if (( success_count < stable_required )); then
      ftctl_state_set "${vm}" \
        "xcolo_primary_guest_health_gate=pending" \
        "xcolo_primary_guest_health_policy=${policy}" \
        "xcolo_primary_guest_health_reason=qga_stabilizing" \
        "xcolo_primary_guest_health_timeout=${pending_timeout}" \
        "xcolo_primary_guest_health_stable_required=${stable_required}" \
        "xcolo_primary_guest_health_qga_success_count=${success_count}" \
        "xcolo_pending_reason=primary_guest_health_pending:qga_stabilizing"
      ftctl_log_event "colo" "xcolo.primary_guest_health" "pending" "${vm}" "" \
        "policy=${policy} qga=${primary_qga} baseline=${baseline} reason=qga_stabilizing success_count=${success_count} stable_required=${stable_required}"
      printf -v "${reason_var}" '%s' "xcolo_primary_guest_health_pending:qga_stabilizing"
      return 10
    fi

    ftctl_state_set "${vm}" \
      "xcolo_primary_guest_health_gate=ok" \
      "xcolo_primary_guest_health_policy=${policy}" \
      "xcolo_primary_guest_health_reason=ok" \
      "xcolo_primary_guest_health_timeout=${pending_timeout}" \
      "xcolo_primary_guest_health_stable_required=${stable_required}" \
      "xcolo_primary_guest_health_qga_success_count=${success_count}" \
      "xcolo_primary_guest_health_pending_since=" \
      "xcolo_primary_guest_health_elapsed=0"
    ftctl_log_event "colo" "xcolo.primary_guest_health" "ok" "${vm}" "" \
      "policy=${policy} qga=${primary_qga} baseline=${baseline} gate=ok reason=ok success_count=${success_count} stable_required=${stable_required}"
    printf -v "${reason_var}" '%s' ""
    return 0
  fi

  if [[ "${policy}" == "required" ]]; then
    pending_since="$(ftctl_state_get "${vm}" "xcolo_primary_guest_health_pending_since" 2>/dev/null || true)"
    now="$(ftctl_now_iso8601)"
    [[ -n "${pending_since}" ]] || pending_since="${now}"
    pending_elapsed="$(ftctl_elapsed_since_iso "${pending_since}" 2>/dev/null || echo "0")"
    [[ "${pending_elapsed}" =~ ^[0-9]+$ ]] || pending_elapsed="0"

    if (( pending_elapsed < pending_timeout )); then
      ftctl_state_set "${vm}" \
        "xcolo_primary_guest_health_gate=pending" \
        "xcolo_primary_guest_health_policy=${policy}" \
        "xcolo_primary_guest_health_reason=qga_transient_wait" \
        "xcolo_primary_guest_health_pending_since=${pending_since}" \
        "xcolo_primary_guest_health_elapsed=${pending_elapsed}" \
        "xcolo_primary_guest_health_timeout=${pending_timeout}" \
        "xcolo_primary_guest_health_stable_required=${stable_required}" \
        "xcolo_primary_guest_health_qga_success_count=0" \
        "xcolo_pending_reason=primary_guest_health_pending:qga_transient_wait"
      ftctl_log_event "colo" "xcolo.primary_guest_health" "pending" "${vm}" "" \
        "policy=${policy} qga=${primary_qga} baseline=${baseline} reason=qga_transient_wait elapsed=${pending_elapsed} timeout=${pending_timeout}"
      printf -v "${reason_var}" '%s' "xcolo_primary_guest_health_pending:qga_transient_wait"
      return 10
    fi

    reason="qga_timeout"
    ftctl_state_set "${vm}" \
      "xcolo_primary_guest_health_gate=failed" \
      "xcolo_primary_guest_health_policy=${policy}" \
      "xcolo_primary_guest_health_reason=${reason}" \
      "xcolo_primary_guest_health_pending_since=${pending_since}" \
      "xcolo_primary_guest_health_elapsed=${pending_elapsed}" \
      "xcolo_primary_guest_health_timeout=${pending_timeout}" \
      "xcolo_primary_guest_health_qga_success_count=0"
    ftctl_log_event "colo" "xcolo.primary_guest_health" "fail" "${vm}" "" \
      "policy=${policy} qga=${primary_qga} baseline=${baseline} reason=${reason} elapsed=${pending_elapsed} timeout=${pending_timeout}"
    printf -v "${reason_var}" '%s' "xcolo_primary_guest_boot_unhealthy:${reason}"
    return 1
  fi

  gate="ok"
  reason="ok"
  ftctl_state_set "${vm}" \
    "xcolo_primary_guest_health_gate=${gate}" \
    "xcolo_primary_guest_health_policy=${policy}" \
    "xcolo_primary_guest_health_reason=${reason}" \
    "xcolo_primary_guest_health_timeout=${pending_timeout}"
  ftctl_log_event "colo" "xcolo.primary_guest_health" "ok" "${vm}" "" \
    "policy=${policy} qga=${primary_qga} baseline=${baseline} gate=${gate} reason=${reason}"
  printf -v "${reason_var}" '%s' ""
  return 0
}

ftctl_xcolo_primary_premigrate_boot_timeout_sec() {
  local timeout_sec="${FTCTL_XCOLO_PRIMARY_PREMIGRATE_BOOT_TIMEOUT_SEC:-${FTCTL_XCOLO_PRIMARY_GUEST_HEALTH_TIMEOUT_SEC:-180}}"
  if [[ -z "${timeout_sec}" || ! "${timeout_sec}" =~ ^[0-9]+$ || "${timeout_sec}" -lt 30 ]]; then
    timeout_sec=180
  fi
  printf '%s\n' "${timeout_sec}"
}

ftctl_xcolo_capture_primary_premigrate_boot_evidence() {
  local vm="${1-}"
  local disk_plan="${2-}"
  local phase="${3:-premigrate_boot}"
  local out="" rc=0 log_tail=""

  ftctl_xcolo_qmp "${FTCTL_PROFILE_PRIMARY_URI}" "${vm}" '{"execute":"query-status"}' out rc
  ftctl_xcolo_write_debug_file "${vm}" "primary-${phase}-query-status.json" "${out}" || true
  ftctl_xcolo_write_debug_file "${vm}" "primary-${phase}-query-status.rc" "${rc}" || true

  out=""; rc=0
  ftctl_xcolo_qmp "${FTCTL_PROFILE_PRIMARY_URI}" "${vm}" '{"execute":"query-block"}' out rc
  ftctl_xcolo_write_debug_file "${vm}" "primary-${phase}-query-block.json" "${out}" || true
  ftctl_xcolo_write_debug_file "${vm}" "primary-${phase}-query-block.rc" "${rc}" || true

  out=""; rc=0
  ftctl_xcolo_qmp "${FTCTL_PROFILE_PRIMARY_URI}" "${vm}" '{"execute":"query-named-block-nodes"}' out rc
  ftctl_xcolo_write_debug_file "${vm}" "primary-${phase}-query-named-block-nodes.json" "${out}" || true
  ftctl_xcolo_write_debug_file "${vm}" "primary-${phase}-query-named-block-nodes.rc" "${rc}" || true

  ftctl_xcolo_collect_primary_block_graph_state "${vm}" "${disk_plan}" || true
  ftctl_xcolo_capture_primary_rbd_owner_evidence "${vm}" "${disk_plan}" "${phase}" || true
  ftctl_xcolo_primary_qemu_log_tail "${vm}" log_tail || true
  ftctl_xcolo_write_debug_file "${vm}" "primary-${phase}-qemu-log-tail.txt" "${log_tail}" || true
}

ftctl_xcolo_wait_primary_premigrate_boot_ready() {
  local vm="${1-}"
  local secondary_vm="${2-}"
  local disk_plan="${3-}"
  local timeout_sec interval start_ts elapsed qga="" storage_reason="" guest_reason="" log_tail=""
  local baseline policy block_ready block_reason

  [[ -n "${vm}" ]] || return 1
  if [[ "${FTCTL_DRY_RUN}" == "1" ]]; then
    ftctl_log_event "colo" "xcolo.primary_premigrate_boot" "skip" "${vm}" "" "reason=dry_run"
    return 0
  fi

  timeout_sec="$(ftctl_xcolo_primary_premigrate_boot_timeout_sec)"
  interval="${FTCTL_XCOLO_PRIMARY_PREMIGRATE_BOOT_INTERVAL_SEC:-5}"
  [[ "${interval}" =~ ^[0-9]+$ && "${interval}" -gt 0 ]] || interval=5
  baseline="$(ftctl_state_get "${vm}" "xcolo_primary_qga_baseline" 2>/dev/null || true)"
  [[ -n "${baseline}" ]] || baseline="unknown"
  policy="${FTCTL_XCOLO_PRIMARY_PREMIGRATE_BOOT_POLICY:-required}"
  case "${policy}" in
    required|observe|off) ;;
    *) policy="required" ;;
  esac

  start_ts="$(ftctl_now_iso8601)"
  ftctl_state_set "${vm}" \
    "xcolo_primary_premigrate_boot_gate=pending" \
    "xcolo_primary_premigrate_boot_started_at=${start_ts}" \
    "xcolo_primary_premigrate_boot_timeout=${timeout_sec}" \
    "xcolo_primary_premigrate_boot_policy=${policy}" \
    "xcolo_primary_premigrate_boot_qga_baseline=${baseline}" \
    "xcolo_primary_premigrate_boot_secondary=${secondary_vm}"

  while :; do
    elapsed="$(ftctl_elapsed_since_iso "${start_ts}" 2>/dev/null || echo 0)"
    [[ "${elapsed}" =~ ^[0-9]+$ ]] || elapsed=0

    ftctl_xcolo_capture_primary_premigrate_boot_evidence "${vm}" "${disk_plan}" "premigrate_boot" || true
    block_ready="$(ftctl_state_get "${vm}" "xcolo_primary_block_graph_ready" 2>/dev/null || true)"
    block_reason="$(ftctl_state_get "${vm}" "xcolo_primary_block_graph_reason" 2>/dev/null || true)"
    if [[ "${block_ready}" != "yes" && "${block_ready}" != "not_applicable" ]]; then
      ftctl_state_set "${vm}" \
        "xcolo_primary_premigrate_boot_gate=failed" \
        "xcolo_primary_premigrate_boot_reason=primary_block_graph_not_ready" \
        "xcolo_primary_premigrate_boot_elapsed=${elapsed}" \
        "xcolo_protocol_failure_phase=primary_premigrate_boot" \
        "last_error=xcolo_primary_colo_boot_graph_invalid"
      ftctl_log_event "colo" "xcolo.primary_premigrate_boot" "fail" "${vm}" "" \
        "reason=primary_block_graph_not_ready block_ready=${block_ready:-unknown} block_reason=${block_reason:-unknown} elapsed=${elapsed}"
      return 1
    fi

    storage_reason=""
    if ! ftctl_xcolo_validate_primary_storage_health "${vm}" storage_reason "${disk_plan}"; then
      ftctl_state_set "${vm}" \
        "xcolo_primary_premigrate_boot_gate=failed" \
        "xcolo_primary_premigrate_boot_reason=${storage_reason}" \
        "xcolo_primary_premigrate_boot_elapsed=${elapsed}" \
        "xcolo_protocol_failure_phase=primary_premigrate_boot" \
        "last_error=${storage_reason}"
      ftctl_log_event "colo" "xcolo.primary_premigrate_boot" "fail" "${vm}" "" \
        "reason=${storage_reason} elapsed=${elapsed}"
      return 1
    fi

    ftctl_xcolo_query_guest_ping "${FTCTL_PROFILE_PRIMARY_URI}" "${vm}" qga || true
    if [[ "${qga}" == "yes" ]]; then
      ftctl_state_set "${vm}" \
        "xcolo_primary_premigrate_boot_gate=ok" \
        "xcolo_primary_premigrate_boot_reason=ok" \
        "xcolo_primary_premigrate_boot_elapsed=${elapsed}" \
        "xcolo_primary_premigrate_boot_qga=yes"
      ftctl_log_event "colo" "xcolo.primary_premigrate_boot" "ok" "${vm}" "" \
        "qga=yes elapsed=${elapsed} block_ready=${block_ready} baseline=${baseline}"
      return 0
    fi

    ftctl_xcolo_primary_qemu_log_tail "${vm}" log_tail || true
    guest_reason=""
    if [[ -n "${log_tail}" ]]; then
      ftctl_xcolo_primary_guest_failure_reason_from_text "${log_tail}" guest_reason || true
    fi
    if [[ -n "${guest_reason}" ]]; then
      ftctl_state_set "${vm}" \
        "xcolo_primary_premigrate_boot_gate=failed" \
        "xcolo_primary_premigrate_boot_reason=${guest_reason}" \
        "xcolo_primary_premigrate_boot_elapsed=${elapsed}" \
        "xcolo_primary_premigrate_boot_qga=no" \
        "xcolo_protocol_failure_phase=primary_premigrate_boot" \
        "last_error=xcolo_primary_colo_boot_unhealthy:${guest_reason}"
      ftctl_log_event "colo" "xcolo.primary_premigrate_boot" "fail" "${vm}" "" \
        "reason=${guest_reason} qga=no elapsed=${elapsed} baseline=${baseline}"
      return 1
    fi

    if [[ "${policy}" == "off" || "${policy}" == "observe" || "${baseline}" != "available" ]]; then
      ftctl_state_set "${vm}" \
        "xcolo_primary_premigrate_boot_gate=observe" \
        "xcolo_primary_premigrate_boot_reason=qga_unavailable_observed" \
        "xcolo_primary_premigrate_boot_elapsed=${elapsed}" \
        "xcolo_primary_premigrate_boot_qga=no"
      ftctl_log_event "colo" "xcolo.primary_premigrate_boot" "ok" "${vm}" "" \
        "policy=${policy} baseline=${baseline} qga=no elapsed=${elapsed} block_ready=${block_ready}"
      return 0
    fi

    if (( elapsed >= timeout_sec )); then
      if [[ -n "${disk_plan}" ]]; then
        ftctl_xcolo_capture_primary_rbd_owner_evidence "${vm}" "${disk_plan}" "premigrate_boot_timeout" || true
        if [[ "$(ftctl_state_get "${vm}" "xcolo_primary_premigrate_boot_timeout_rbd_runtime_owner_conflict" 2>/dev/null || true)" == "yes" ]]; then
          guest_reason="primary_rbd_runtime_owner_conflict:$(ftctl_state_get "${vm}" "xcolo_primary_premigrate_boot_timeout_rbd_runtime_owner_conflict_targets" 2>/dev/null || true)"
          ftctl_state_set "${vm}" \
            "xcolo_primary_premigrate_boot_gate=failed" \
            "xcolo_primary_premigrate_boot_reason=${guest_reason}" \
            "xcolo_primary_premigrate_boot_elapsed=${elapsed}" \
            "xcolo_primary_premigrate_boot_qga=no" \
            "xcolo_protocol_failure_phase=primary_premigrate_boot" \
            "last_error=xcolo_primary_colo_boot_unhealthy:${guest_reason}"
          ftctl_log_event "colo" "xcolo.primary_premigrate_boot" "fail" "${vm}" "" \
            "reason=${guest_reason} qga=no elapsed=${elapsed} timeout=${timeout_sec} baseline=${baseline} block_ready=${block_ready}"
          return 1
        fi
      fi
      ftctl_state_set "${vm}" \
        "xcolo_primary_premigrate_boot_gate=failed" \
        "xcolo_primary_premigrate_boot_reason=qga_timeout" \
        "xcolo_primary_premigrate_boot_elapsed=${elapsed}" \
        "xcolo_primary_premigrate_boot_qga=no" \
        "xcolo_protocol_failure_phase=primary_premigrate_boot" \
        "last_error=xcolo_primary_colo_boot_unhealthy:qga_timeout"
      ftctl_log_event "colo" "xcolo.primary_premigrate_boot" "fail" "${vm}" "" \
        "reason=qga_timeout qga=no elapsed=${elapsed} timeout=${timeout_sec} baseline=${baseline} block_ready=${block_ready}"
      return 1
    fi

    ftctl_state_set "${vm}" \
      "xcolo_primary_premigrate_boot_gate=pending" \
      "xcolo_primary_premigrate_boot_reason=qga_wait" \
      "xcolo_primary_premigrate_boot_elapsed=${elapsed}" \
      "xcolo_primary_premigrate_boot_qga=no" \
      "xcolo_pending_reason=primary_premigrate_boot_pending:qga_wait"
    ftctl_log_event "colo" "xcolo.primary_premigrate_boot" "pending" "${vm}" "" \
      "qga=no elapsed=${elapsed} timeout=${timeout_sec} baseline=${baseline} block_ready=${block_ready}"
    sleep "${interval}"
  done
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
  local nodes_out nodes_rc block_out block_rc payload state_args=()

  if [[ -z "${plan}" ]]; then
    ftctl_state_set "${vm}" \
      "xcolo_primary_block_graph_ready=not_applicable" \
      "xcolo_primary_block_graph_reason=no_disk_plan"
    return 0
  fi

  nodes_out=""
  nodes_rc=0
  ftctl_xcolo_qmp "${FTCTL_PROFILE_PRIMARY_URI}" "${vm}" '{"execute":"query-named-block-nodes"}' nodes_out nodes_rc
  ftctl_xcolo_write_debug_file "${vm}" "primary-premigrate-query-named-block-nodes.json" "${nodes_out}" || true
  ftctl_xcolo_write_debug_file "${vm}" "primary-premigrate-query-named-block-nodes.rc" "${nodes_rc}" || true

  block_out=""
  block_rc=0
  ftctl_xcolo_qmp "${FTCTL_PROFILE_PRIMARY_URI}" "${vm}" '{"execute":"query-block"}' block_out block_rc
  ftctl_xcolo_write_debug_file "${vm}" "primary-premigrate-query-block.json" "${block_out}" || true
  ftctl_xcolo_write_debug_file "${vm}" "primary-premigrate-query-block.rc" "${block_rc}" || true

  if [[ "${nodes_rc}" != "0" || -z "${nodes_out}" || "${block_rc}" != "0" || -z "${block_out}" ]]; then
    ftctl_state_set "${vm}" \
      "xcolo_primary_block_graph_ready=unknown" \
      "xcolo_primary_block_graph_reason=query_block_graph_failed"
    return 1
  fi

  payload="$(python3 - <<'PY' "${plan}" "${FTCTL_PROFILE_XCOLO_NBD_NODE:-ftctl-nbd}" "${nodes_out}" "${block_out}"
import json
import re
import sys

plan = sys.argv[1]
nbd_base = sys.argv[2] or "ftctl-nbd"
nodes_raw = sys.argv[3]
block_raw = sys.argv[4]
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

node_items = {}
for item in nodes_data.get("return", []):
    name = item.get("node-name")
    if name:
        node_items[name] = item

qdev_nodes = {}
for item in block_data.get("return", []):
    inserted = item.get("inserted") if isinstance(item, dict) else None
    node = inserted.get("node-name") if isinstance(inserted, dict) else ""
    qdev = item.get("qdev") or item.get("device") or ""
    if node:
        qdev_nodes[node] = qdev

ready = True
reasons = []
for target in targets:
    s = suffix(target)
    colo = f"ftctl-colo-{s}"
    active = f"ftctl-primary-active-{s}"
    nbd = f"{nbd_base}-{s}"
    expected_drivers = {
        colo: "quorum",
        active: "qcow2",
        nbd: "nbd",
    }
    for node, expected in expected_drivers.items():
        key = re.sub(r"[^A-Za-z0-9_.-]", "_", node)
        item = node_items.get(node)
        if not item:
            ready = False
            reasons.append(f"{node}:missing")
            print(f"{key}=missing")
            continue
        drv = item.get("drv") or item.get("driver") or ""
        print(f"{key}=yes")
        print(f"{key}_driver={drv}")
        if expected and drv and drv != expected:
            ready = False
            reasons.append(f"{node}:driver:{drv}")
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

ftctl_xcolo_qemu_argv_device_count() {
  local argv="${1-}"
  printf '%s\n' "${argv}" | awk '$0 == "-device" { count++ } END { print count + 0 }'
}

ftctl_xcolo_capture_qemu_proc_args_local() {
  local domain="${1-}"
  local out_var="${2}"
  local meta_var="${3}"
  local rc_var="${4}"
  local out="" err="" rc=0 payload args meta

  ftctl_cmd_run "${FTCTL_BLOCKCOPY_WAIT_TIMEOUT_SEC:-15}" out err rc -- \
    python3 - "${domain}" <<'PY' || true
import json
import os
import sys

domain = sys.argv[1]
records = []

def read_cmdline(pid):
    try:
        raw = open(f"/proc/{pid}/cmdline", "rb").read()
    except Exception:
        return []
    return [part.decode("utf-8", "replace") for part in raw.split(b"\0") if part]

def is_qemu_exe(pid, args):
    exe = ""
    try:
        exe = os.readlink(f"/proc/{pid}/exe")
    except Exception:
        exe = args[0] if args else ""
    base = os.path.basename(exe)
    return base == "qemu-kvm" or base.startswith("qemu-system")

def score_args(args):
    score = 0
    guest = ""
    for idx, arg in enumerate(args):
        if arg == "-name" and idx + 1 < len(args):
            guest = args[idx + 1]
        elif arg.startswith("guest="):
            guest = arg
    if guest.startswith(f"guest={domain},") or guest == f"guest={domain}":
        score += 100
    if any(f"/domain-" in arg and domain in arg for arg in args):
        score += 50
    if any(arg == domain or domain in arg for arg in args):
        score += 10
    return score, guest

for name in os.listdir("/proc"):
    if not name.isdigit():
        continue
    args = read_cmdline(name)
    if not args or not is_qemu_exe(name, args):
        continue
    score, guest = score_args(args)
    if score <= 0:
        continue
    records.append({
        "pid": int(name),
        "score": score,
        "guest": guest,
        "exe": args[0],
        "device_count": sum(1 for arg in args if arg == "-device"),
        "domain_path_match": any(f"/domain-" in arg and domain in arg for arg in args),
        "arg_count": len(args),
        "args": args,
    })

records.sort(key=lambda item: (item["score"], item["device_count"], item["pid"]), reverse=True)
selected = records[0] if records else None
payload = {
    "domain": domain,
    "selected_pid": selected["pid"] if selected else None,
    "selected_score": selected["score"] if selected else 0,
    "selected_guest": selected["guest"] if selected else "",
    "selected_device_count": selected["device_count"] if selected else 0,
    "candidates": [
        {k: v for k, v in item.items() if k != "args"}
        for item in records
    ],
    "args": selected["args"] if selected else [],
}
print(json.dumps(payload, sort_keys=True, separators=(",", ":")))
raise SystemExit(0 if selected else 1)
PY
  payload="${out}"
  args="$(python3 - <<'PY' "${payload}"
import json
import sys
try:
    data = json.loads(sys.argv[1])
except Exception:
    data = {}
print("\n".join(data.get("args") or []))
PY
)"
  meta="$(python3 - <<'PY' "${payload}" "${err}"
import json
import sys
try:
    data = json.loads(sys.argv[1])
except Exception:
    data = {"parse_error": True, "raw": sys.argv[1]}
if sys.argv[2]:
    data["stderr"] = sys.argv[2]
data.pop("args", None)
print(json.dumps(data, indent=2, sort_keys=True))
PY
)"
  printf -v "${out_var}" '%s' "${args}"
  printf -v "${meta_var}" '%s' "${meta}"
  printf -v "${rc_var}" '%s' "${rc}"
}

ftctl_xcolo_capture_qemu_log_args_local() {
  local domain="${1-}"
  local out_var="${2}"
  local meta_var="${3}"
  local rc_var="${4}"
  local out="" err="" rc=0 payload args meta

  ftctl_cmd_run "${FTCTL_BLOCKCOPY_WAIT_TIMEOUT_SEC:-15}" out err rc -- \
    python3 - "${domain}" "/var/log/libvirt/qemu/${domain}.log" <<'PY' || true
import json
import os
import shlex
import sys

domain = sys.argv[1]
path = sys.argv[2]
try:
    lines = open(path, "r", encoding="utf-8", errors="replace").read().splitlines()
except Exception as exc:
    print(json.dumps({"domain": domain, "path": path, "error": str(exc), "args": []}, sort_keys=True))
    raise SystemExit(1)

starts = [idx for idx, line in enumerate(lines) if line.startswith("/usr/libexec/qemu-kvm") or line.startswith("/usr/bin/qemu-system")]
if not starts:
    print(json.dumps({"domain": domain, "path": path, "error": "qemu_command_not_found", "args": []}, sort_keys=True))
    raise SystemExit(1)

start = starts[-1]
block = []
for line in lines[start:]:
    stripped = line.rstrip()
    if not stripped:
        break
    if block and not (stripped.startswith("-") or stripped.startswith("/") or stripped.startswith("{") or stripped.startswith("'") or stripped.startswith('"')):
        break
    cont = stripped.endswith("\\")
    if cont:
        stripped = stripped[:-1].rstrip()
    block.append(stripped)
    if not cont and len(block) > 1:
        break

args = []
for line in block:
    try:
        args.extend(shlex.split(line))
    except Exception:
        args.append(line)

payload = {
    "domain": domain,
    "path": path,
    "start_line": start + 1,
    "line_count": len(block),
    "device_count": sum(1 for arg in args if arg == "-device"),
    "args": args,
}
print(json.dumps(payload, sort_keys=True, separators=(",", ":")))
raise SystemExit(0 if args else 1)
PY
  payload="${out}"
  args="$(python3 - <<'PY' "${payload}"
import json
import sys
try:
    data = json.loads(sys.argv[1])
except Exception:
    data = {}
print("\n".join(data.get("args") or []))
PY
)"
  meta="$(python3 - <<'PY' "${payload}" "${err}"
import json
import sys
try:
    data = json.loads(sys.argv[1])
except Exception:
    data = {"parse_error": True, "raw": sys.argv[1]}
if sys.argv[2]:
    data["stderr"] = sys.argv[2]
data.pop("args", None)
print(json.dumps(data, indent=2, sort_keys=True))
PY
)"
  printf -v "${out_var}" '%s' "${args}"
  printf -v "${meta_var}" '%s' "${meta}"
  printf -v "${rc_var}" '%s' "${rc}"
}

ftctl_xcolo_capture_qemu_proc_args_pair() {
  local vm="${1-}"
  local secondary_vm="${2-}"
  local phase="${3:-before_migrate}"
  local host="" user="" out="" rc=0 err="" remote_cmd="" q_secondary="" meta="" source=""
  local primary_count secondary_count fallback_out fallback_meta fallback_rc primary_source secondary_source
  local primary_var="${4}"
  local secondary_var="${5}"

  ftctl_xcolo_capture_qemu_proc_args_local "${vm}" out meta rc || true
  ftctl_xcolo_write_debug_file "${vm}" "primary-qemu-pid-candidates-${phase}.txt" "${meta}" || true
  source="proc"
  primary_count="$(ftctl_xcolo_qemu_argv_device_count "${out}")"
  if [[ "${primary_count}" == "0" ]]; then
    fallback_out=""
    fallback_meta=""
    fallback_rc=0
    ftctl_xcolo_capture_qemu_log_args_local "${vm}" fallback_out fallback_meta fallback_rc || true
    ftctl_xcolo_write_debug_file "${vm}" "primary-qemu-log-argv-fallback-${phase}.txt" "${fallback_meta}" || true
    if [[ "$(ftctl_xcolo_qemu_argv_device_count "${fallback_out}")" != "0" ]]; then
      out="${fallback_out}"
      rc="${fallback_rc}"
      source="qemu_log_fallback"
      primary_count="$(ftctl_xcolo_qemu_argv_device_count "${out}")"
    fi
  fi
  ftctl_xcolo_write_debug_file "${vm}" "primary-live-qemu-argv-${phase}.txt" "${out}" || true
  ftctl_xcolo_write_debug_file "${vm}" "primary-live-qemu-argv-source-${phase}.txt" "${source}" || true
  primary_source="${source}"
  printf -v "${primary_var}" '%s' "${out}"

  out=""
  rc=0
  meta=""
  source="proc"
  if ftctl_blockcopy_secondary_uri_is_local_system; then
    ftctl_xcolo_capture_qemu_proc_args_local "${secondary_vm}" out meta rc || true
  elif ftctl_blockcopy_remote_target_host_user host user; then
    printf -v q_secondary '%q' "${secondary_vm}"
    remote_cmd="domain=${q_secondary}
python3 - \"\${domain}\" <<'PY'
import json
import os
import sys

domain = sys.argv[1]
records = []

def read_cmdline(pid):
    try:
        raw = open(f\"/proc/{pid}/cmdline\", \"rb\").read()
    except Exception:
        return []
    return [part.decode(\"utf-8\", \"replace\") for part in raw.split(b\"\\0\") if part]

def is_qemu_exe(pid, args):
    exe = \"\"
    try:
        exe = os.readlink(f\"/proc/{pid}/exe\")
    except Exception:
        exe = args[0] if args else \"\"
    base = os.path.basename(exe)
    return base == \"qemu-kvm\" or base.startswith(\"qemu-system\")

def score_args(args):
    score = 0
    guest = \"\"
    for idx, arg in enumerate(args):
        if arg == \"-name\" and idx + 1 < len(args):
            guest = args[idx + 1]
        elif arg.startswith(\"guest=\"):
            guest = arg
    if guest.startswith(f\"guest={domain},\") or guest == f\"guest={domain}\":
        score += 100
    if any(f\"/domain-\" in arg and domain in arg for arg in args):
        score += 50
    if any(arg == domain or domain in arg for arg in args):
        score += 10
    return score, guest

for name in os.listdir(\"/proc\"):
    if not name.isdigit():
        continue
    args = read_cmdline(name)
    if not args or not is_qemu_exe(name, args):
        continue
    score, guest = score_args(args)
    if score <= 0:
        continue
    records.append({
        \"pid\": int(name),
        \"score\": score,
        \"guest\": guest,
        \"exe\": args[0],
        \"device_count\": sum(1 for arg in args if arg == \"-device\"),
        \"domain_path_match\": any(f\"/domain-\" in arg and domain in arg for arg in args),
        \"arg_count\": len(args),
        \"args\": args,
    })

records.sort(key=lambda item: (item[\"score\"], item[\"device_count\"], item[\"pid\"]), reverse=True)
selected = records[0] if records else None
payload = {
    \"domain\": domain,
    \"selected_pid\": selected[\"pid\"] if selected else None,
    \"selected_score\": selected[\"score\"] if selected else 0,
    \"selected_guest\": selected[\"guest\"] if selected else \"\",
    \"selected_device_count\": selected[\"device_count\"] if selected else 0,
    \"candidates\": [
        {k: v for k, v in item.items() if k != \"args\"}
        for item in records
    ],
    \"args\": selected[\"args\"] if selected else [],
}
print(json.dumps(payload, sort_keys=True, separators=(\",\", \":\")))
raise SystemExit(0 if selected else 1)
PY"
    ftctl_blockcopy_remote_exec "${host}" "${user}" out err rc "${remote_cmd}" || true
    meta="$(python3 - <<'PY' "${out}" "${err}"
import json
import sys
try:
    data = json.loads(sys.argv[1])
except Exception:
    data = {"parse_error": True, "raw": sys.argv[1]}
if sys.argv[2]:
    data["stderr"] = sys.argv[2]
data.pop("args", None)
print(json.dumps(data, indent=2, sort_keys=True))
PY
)"
    out="$(python3 - <<'PY' "${out}"
import json
import sys
try:
    data = json.loads(sys.argv[1])
except Exception:
    data = {}
print("\n".join(data.get("args") or []))
PY
)"
  else
    rc=2
    meta='{"error":"target_unresolved"}'
  fi
  : "${err}"
  ftctl_xcolo_write_debug_file "${vm}" "secondary-qemu-pid-candidates-${phase}.txt" "${meta}" || true
  secondary_count="$(ftctl_xcolo_qemu_argv_device_count "${out}")"
  if [[ "${secondary_count}" == "0" ]]; then
    fallback_out=""
    fallback_meta=""
    fallback_rc=0
    if ftctl_blockcopy_secondary_uri_is_local_system; then
      ftctl_xcolo_capture_qemu_log_args_local "${secondary_vm}" fallback_out fallback_meta fallback_rc || true
    elif [[ -n "${host}" && -n "${user}" ]]; then
      remote_cmd="domain=${q_secondary}
python3 - \"\${domain}\" \"/var/log/libvirt/qemu/\${domain}.log\" <<'PY'
import json
import shlex
import sys

domain = sys.argv[1]
path = sys.argv[2]
try:
    lines = open(path, \"r\", encoding=\"utf-8\", errors=\"replace\").read().splitlines()
except Exception as exc:
    print(json.dumps({\"domain\": domain, \"path\": path, \"error\": str(exc), \"args\": []}, sort_keys=True))
    raise SystemExit(1)

starts = [idx for idx, line in enumerate(lines) if line.startswith(\"/usr/libexec/qemu-kvm\") or line.startswith(\"/usr/bin/qemu-system\")]
if not starts:
    print(json.dumps({\"domain\": domain, \"path\": path, \"error\": \"qemu_command_not_found\", \"args\": []}, sort_keys=True))
    raise SystemExit(1)

start = starts[-1]
block = []
for line in lines[start:]:
    stripped = line.rstrip()
    if not stripped:
        break
    if block and not (stripped.startswith(\"-\") or stripped.startswith(\"/\") or stripped.startswith(\"{\") or stripped.startswith(\"'\") or stripped.startswith('\"')):
        break
    cont = stripped.endswith(\"\\\\\")
    if cont:
        stripped = stripped[:-1].rstrip()
    block.append(stripped)
    if not cont and len(block) > 1:
        break

args = []
for line in block:
    try:
        args.extend(shlex.split(line))
    except Exception:
        args.append(line)

payload = {
    \"domain\": domain,
    \"path\": path,
    \"start_line\": start + 1,
    \"line_count\": len(block),
    \"device_count\": sum(1 for arg in args if arg == \"-device\"),
    \"args\": args,
}
print(json.dumps(payload, sort_keys=True, separators=(\",\", \":\")))
raise SystemExit(0 if args else 1)
PY"
      ftctl_blockcopy_remote_exec "${host}" "${user}" fallback_out err fallback_rc "${remote_cmd}" || true
      fallback_meta="$(python3 - <<'PY' "${fallback_out}" "${err}"
import json
import sys
try:
    data = json.loads(sys.argv[1])
except Exception:
    data = {"parse_error": True, "raw": sys.argv[1]}
if sys.argv[2]:
    data["stderr"] = sys.argv[2]
data.pop("args", None)
print(json.dumps(data, indent=2, sort_keys=True))
PY
)"
      fallback_out="$(python3 - <<'PY' "${fallback_out}"
import json
import sys
try:
    data = json.loads(sys.argv[1])
except Exception:
    data = {}
print("\n".join(data.get("args") or []))
PY
)"
    fi
    ftctl_xcolo_write_debug_file "${vm}" "secondary-qemu-log-argv-fallback-${phase}.txt" "${fallback_meta}" || true
    if [[ "$(ftctl_xcolo_qemu_argv_device_count "${fallback_out}")" != "0" ]]; then
      out="${fallback_out}"
      rc="${fallback_rc}"
      source="qemu_log_fallback"
      secondary_count="$(ftctl_xcolo_qemu_argv_device_count "${out}")"
    fi
  fi
  ftctl_xcolo_write_debug_file "${vm}" "secondary-live-qemu-argv-${phase}.txt" "${out}" || true
  ftctl_xcolo_write_debug_file "${vm}" "secondary-live-qemu-argv-source-${phase}.txt" "${source}" || true
  secondary_source="${source}"
  printf -v "${secondary_var}" '%s' "${out}"

  ftctl_state_set "${vm}" \
    "xcolo_live_runtime_${phase}_primary_proc_argv_captured=$([[ -n "${!primary_var}" ]] && printf yes || printf no)" \
    "xcolo_live_runtime_${phase}_primary_argv_source=${primary_source}" \
    "xcolo_live_runtime_${phase}_primary_device_count=${primary_count}" \
    "xcolo_live_runtime_${phase}_secondary_proc_argv_captured=$([[ -n "${out}" ]] && printf yes || printf no)" \
    "xcolo_live_runtime_${phase}_secondary_argv_source=${secondary_source}" \
    "xcolo_live_runtime_${phase}_secondary_device_count=${secondary_count}" \
    "xcolo_live_runtime_${phase}_secondary_proc_argv_rc=${rc}"
}

ftctl_xcolo_hmp() {
  local uri="${1-}"
  local vm="${2-}"
  local command_line="${3-}"
  local out_var="${4}"
  local rc_var="${5}"
  local payload

  payload="$(python3 - <<'PY' "${command_line}"
import json
import sys
print(json.dumps({
    "execute": "human-monitor-command",
    "arguments": {"command-line": sys.argv[1]},
}, separators=(",", ":")))
PY
)"
  ftctl_xcolo_qmp "${uri}" "${vm}" "${payload}" "${out_var}" "${rc_var}"
}

ftctl_xcolo_extract_hmp_return() {
  local raw="${1-}"
  python3 - <<'PY' "${raw}"
import json
import sys
raw = sys.argv[1]
try:
    data = json.loads(raw) if raw.strip() else {}
except Exception:
    print(raw)
    raise SystemExit(0)
ret = data.get("return") if isinstance(data, dict) else ""
if isinstance(ret, str):
    print(ret.rstrip())
else:
    print(json.dumps(ret, sort_keys=True, ensure_ascii=False))
PY
}

ftctl_xcolo_capture_live_runtime_topology_one() {
  local vm="${1-}"
  local uri="${2-}"
  local domain="${3-}"
  local prefix="${4-}"
  local phase="${5:-before_migrate}"
  local out="" rc=0 text=""
  local err=""

  ftctl_virsh "${FTCTL_BLOCKCOPY_WAIT_TIMEOUT_SEC:-15}" out err rc -- -c "${uri}" dumpxml "${domain}" || true
  : "${err}"
  ftctl_xcolo_write_debug_file "${vm}" "${prefix}-live-dumpxml-${phase}.xml" "${out}" || true

  ftctl_xcolo_qmp "${uri}" "${domain}" '{"execute":"query-status"}' out rc
  ftctl_xcolo_write_debug_file "${vm}" "${prefix}-live-query-status-${phase}.json" "${out}" || true
  ftctl_xcolo_qmp "${uri}" "${domain}" '{"execute":"query-chardev"}' out rc
  ftctl_xcolo_write_debug_file "${vm}" "${prefix}-live-query-chardev-${phase}.json" "${out}" || true
  ftctl_xcolo_qmp "${uri}" "${domain}" '{"execute":"query-block"}' out rc
  ftctl_xcolo_write_debug_file "${vm}" "${prefix}-live-query-block-${phase}.json" "${out}" || true
  ftctl_xcolo_qmp "${uri}" "${domain}" '{"execute":"query-named-block-nodes"}' out rc
  ftctl_xcolo_write_debug_file "${vm}" "${prefix}-live-query-named-block-nodes-${phase}.json" "${out}" || true

  ftctl_xcolo_hmp "${uri}" "${domain}" "info pci" out rc
  text="$(ftctl_xcolo_extract_hmp_return "${out}")"
  ftctl_xcolo_write_debug_file "${vm}" "${prefix}-info-pci-${phase}.txt" "${text}" || true
  ftctl_xcolo_hmp "${uri}" "${domain}" "info qtree" out rc
  text="$(ftctl_xcolo_extract_hmp_return "${out}")"
  ftctl_xcolo_write_debug_file "${vm}" "${prefix}-info-qtree-${phase}.txt" "${text}" || true
  ftctl_xcolo_hmp "${uri}" "${domain}" "info mtree" out rc
  text="$(ftctl_xcolo_extract_hmp_return "${out}")"
  ftctl_xcolo_write_debug_file "${vm}" "${prefix}-info-mtree-${phase}.txt" "${text}" || true
}

ftctl_xcolo_analyze_materialization_pipeline() {
  local vm="${1-}"
  local phase="${2:-before_migrate}"
  local context="${3:-live_runtime}"
  local debug_dir="" payload="" rc=0
  local state="" layer="" first_id="" first_driver="" first_path="" missing_count="" first_reason=""

  [[ -n "${vm}" ]] || return 0
  debug_dir="$(ftctl_xcolo_debug_dir "${vm}")"

  payload="$(DEBUG_DIR="${debug_dir}" PHASE="${phase}" CONTEXT="${context}" python3 - <<'PY'
import glob
import json
import os
import re

debug_dir = os.environ.get("DEBUG_DIR", "")
phase = os.environ.get("PHASE", "")
context = os.environ.get("CONTEXT", "")

def read_text(name):
    path = os.path.join(debug_dir, name)
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as handle:
            return handle.read()
    except FileNotFoundError:
        return ""

def load_manifest(role):
    preferred = os.path.join(debug_dir, f"{role}-generated-pci-manifest-startup_disk_graph.json")
    paths = [preferred] if os.path.exists(preferred) else []
    paths.extend(sorted(glob.glob(os.path.join(debug_dir, f"{role}-generated-pci-manifest-*.json"))))
    seen = set()
    for path in paths:
        if path in seen:
            continue
        seen.add(path)
        try:
            with open(path, "r", encoding="utf-8", errors="replace") as handle:
                return path, json.load(handle)
        except Exception:
            continue
    return "", {}

def compact(value, limit=500):
    value = str(value).replace("\n", " ").replace("\t", " ")
    value = re.sub(r"\s+", " ", value).strip()
    return value[:limit]

def parse_qemu_device_arg(value):
    value = value.strip()
    if not value:
        return None
    if value.startswith("{"):
        try:
            data = json.loads(value)
        except Exception:
            return {"id": "", "driver": value, "raw": value, "opts": {}}
        driver = str(data.get("driver", ""))
        opts = {str(k): str(v) for k, v in data.items() if k != "driver"}
        return {"id": opts.get("id", ""), "driver": driver, "raw": value, "opts": dict(sorted(opts.items()))}
    parts = value.split(",")
    driver = parts[0]
    opts = {}
    flags = []
    for item in parts[1:]:
        if not item:
            continue
        if "=" in item:
            key, val = item.split("=", 1)
            opts[key] = val
        else:
            flags.append(item)
    return {"id": opts.get("id", ""), "driver": driver, "raw": value, "opts": dict(sorted(opts.items())), "flags": sorted(flags)}

def parse_argv_devices(raw):
    args = [line for line in raw.splitlines() if line]
    by_id = {}
    ordered = []
    for idx, arg in enumerate(args):
        if arg != "-device" or idx + 1 >= len(args):
            continue
        parsed = parse_qemu_device_arg(args[idx + 1])
        if not parsed:
            continue
        dev_id = parsed.get("id", "")
        if dev_id:
            by_id[dev_id] = parsed
        ordered.append(parsed)
    return by_id, ordered

def manifest_devices(payload):
    by_id = {}
    ordered = []
    for row in payload.get("qemu_guest_devices", []) if isinstance(payload, dict) else []:
        opts = row.get("opts", {}) if isinstance(row, dict) else {}
        dev_id = str(opts.get("id", ""))
        driver = str(row.get("driver", ""))
        if not dev_id:
            continue
        item = {"id": dev_id, "driver": driver, "source": "qemu_guest_devices", "raw": row}
        by_id[dev_id] = item
        ordered.append(item)
    for row in payload.get("controllers", []) if isinstance(payload, dict) else []:
        if not isinstance(row, dict):
            continue
        dev_id = str(row.get("alias", ""))
        driver = str(row.get("model", "") or row.get("model_attrs", {}).get("name", ""))
        if not dev_id or dev_id in by_id:
            continue
        if driver not in {"pcie-root-port", "pci-bridge", "pcie-pci-bridge", "virtio-scsi"}:
            continue
        item = {"id": dev_id, "driver": driver, "source": "controllers", "raw": row}
        by_id[dev_id] = item
        ordered.append(item)
    return by_id, ordered

QTREE_DEV_RE = re.compile(r'^dev:\s*([^,]+)(?:,\s*id\s*"([^"]+)")?')

def qtree_devices(raw):
    by_id = {}
    for line in raw.splitlines():
        text = re.sub(r"\s+", " ", line.strip())
        match = QTREE_DEV_RE.match(text)
        if not match:
            continue
        driver = match.group(1).strip()
        dev_id = (match.group(2) or "").strip()
        if dev_id:
            by_id[dev_id] = {"id": dev_id, "driver": driver, "raw": text}
    return by_id

PCI_HEADER_RE = re.compile(r"^Bus\s+([0-9a-fA-F]+),\s*device\s+([0-9a-fA-F]+),\s*function\s+([0-9a-fA-F]+):$")

def pci_devices(raw):
    by_id = {}
    current = None
    for line in raw.splitlines():
        text = re.sub(r"\s+", " ", line.strip())
        if not text:
            continue
        match = PCI_HEADER_RE.match(text)
        if match:
            if current and current.get("id"):
                by_id[current["id"]] = current
            current = {
                "addr": f"bus={int(match.group(1), 10)} device={int(match.group(2), 10)} function={int(match.group(3), 10)}",
                "class": "",
                "id": "",
                "raw": [text],
                "resource_unassigned": False,
            }
            continue
        if current is None:
            continue
        current["raw"].append(text)
        if ": PCI device " in text and not current["class"]:
            current["class"] = text
        if text.startswith("id "):
            current["id"] = text[3:].strip().strip('"')
        if "(not mapped)" in text or text.startswith("secondary bus 0.") or text.startswith("subordinate bus 0."):
            current["resource_unassigned"] = True
    if current and current.get("id"):
        by_id[current["id"]] = current
    return by_id

ZERO_RANGE_RE = re.compile(r"^0+0-0+0 ")

def zero_pci_aliases(raw):
    rows = []
    for line in raw.splitlines():
        text = re.sub(r"\s+", " ", line.strip())
        if ZERO_RANGE_RE.match(text) and ("alias pci_bridge_" in text or "alias pcie" in text):
            rows.append(text)
    return rows

def path_string(parts):
    return ",".join(f"{key}:{value}" for key, value in parts)

PCI_DRIVER_HINTS = (
    "-pci",
    "pci-bridge",
    "pcie-root-port",
    "pcie-pci-bridge",
    "pcie-root",
    "qemu-xhci",
    "ich9-intel-hda",
    "cirrus-vga",
    "VGA",
)
BUS_CHILD_PARENT_PREFIXES = {
    "scsi-hd": "scsi",
    "scsi-cd": "scsi",
    "scsi-generic": "scsi",
    "virtserialport": "virtio-serial",
    "virtconsole": "virtio-serial",
}
BUS_CHILD_DRIVERS = {
    "ide-cd",
    "ide-hd",
    "isa-serial",
    "usb-tablet",
    "usb-kbd",
    "usb-mouse",
    "hda-duplex",
    "hda-micro",
    "hda-output",
}

def device_class(dev_id, driver, primary_pci, secondary_pci):
    driver = str(driver or "")
    if dev_id in primary_pci or dev_id in secondary_pci:
        return "pci"
    if any(hint in driver for hint in PCI_DRIVER_HINTS):
        return "pci"
    if driver in BUS_CHILD_PARENT_PREFIXES or driver in BUS_CHILD_DRIVERS:
        return "bus_child"
    if driver.startswith(("scsi-", "ide-", "usb-", "isa-")):
        return "bus_child"
    return "non_pci"

def required_bus_parent(driver, dev_id, qtree):
    prefix = BUS_CHILD_PARENT_PREFIXES.get(driver)
    if not prefix:
        return ""
    if driver.startswith("scsi-"):
        match = re.match(r"^(scsi\d+)-", dev_id)
        if match:
            parent = match.group(1)
            if parent in qtree:
                return parent
        for candidate, item in qtree.items():
            item_driver = str(item.get("driver", ""))
            if candidate.startswith(prefix) or item_driver in {"virtio-scsi-pci", "virtio-scsi"}:
                return candidate
        return f"{prefix}*"
    for candidate in qtree:
        if candidate.startswith(prefix):
            return candidate
    return f"{prefix}*"

def bus_parent_missing(driver, dev_id, qtree):
    parent = required_bus_parent(driver, dev_id, qtree)
    if not parent:
        return False, ""
    if parent.endswith("*"):
        return True, parent
    return parent not in qtree, parent

primary_manifest_path, primary_manifest = load_manifest("primary")
secondary_manifest_path, secondary_manifest = load_manifest("secondary")
primary_generated, primary_generated_ordered = manifest_devices(primary_manifest)
secondary_generated, secondary_generated_ordered = manifest_devices(secondary_manifest)
primary_argv, primary_argv_ordered = parse_argv_devices(read_text(f"primary-live-qemu-argv-{phase}.txt"))
secondary_argv, secondary_argv_ordered = parse_argv_devices(read_text(f"secondary-live-qemu-argv-{phase}.txt"))
primary_qtree = qtree_devices(read_text(f"primary-info-qtree-{phase}.txt"))
secondary_qtree = qtree_devices(read_text(f"secondary-info-qtree-{phase}.txt"))
primary_pci = pci_devices(read_text(f"primary-info-pci-{phase}.txt"))
secondary_pci = pci_devices(read_text(f"secondary-info-pci-{phase}.txt"))
primary_zero_aliases = zero_pci_aliases(read_text(f"primary-info-mtree-{phase}.txt"))
secondary_zero_aliases = zero_pci_aliases(read_text(f"secondary-info-mtree-{phase}.txt"))

expected_ids = []
for item in primary_generated_ordered:
    dev_id = item.get("id", "")
    if dev_id and dev_id not in expected_ids:
        expected_ids.append(dev_id)
if not expected_ids:
    for item in primary_argv_ordered:
        dev_id = item.get("id", "")
        if dev_id and dev_id not in expected_ids:
            expected_ids.append(dev_id)

records = []
failure = None
for dev_id in expected_ids:
    base = primary_generated.get(dev_id) or primary_argv.get(dev_id) or {"id": dev_id, "driver": "unknown"}
    driver = base.get("driver", "unknown")
    dev_class = device_class(dev_id, driver, primary_pci, secondary_pci)
    primary_parent_missing, primary_parent = bus_parent_missing(driver, dev_id, primary_qtree)
    secondary_parent_missing, secondary_parent = bus_parent_missing(driver, dev_id, secondary_qtree)
    checks = [
        ("generated", dev_id in primary_generated and dev_id in secondary_generated),
        ("argv", dev_id in primary_argv and dev_id in secondary_argv),
        ("qtree", dev_id in primary_qtree and dev_id in secondary_qtree),
        ("pci", dev_class != "pci" or (dev_id in primary_pci and dev_id in secondary_pci)),
    ]
    layer = ""
    reason = ""
    if dev_id not in secondary_generated and primary_generated:
        layer = "generated_missing"
        reason = "secondary_generated_manifest_missing_device"
    elif dev_id not in primary_argv or dev_id not in secondary_argv:
        layer = "argv_missing"
        reason = "live_qemu_argv_missing_device"
    elif dev_id not in primary_qtree or dev_id not in secondary_qtree:
        layer = "qtree_missing"
        reason = "qtree_missing_device"
    elif primary_parent_missing or secondary_parent_missing:
        layer = "qtree_parent_missing"
        reason = f"bus_child_parent_missing primary={primary_parent} secondary={secondary_parent}"
    elif dev_class == "pci" and (dev_id not in primary_pci or dev_id not in secondary_pci):
        layer = "pci_missing"
        reason = "info_pci_missing_device"
    elif dev_class == "pci" and secondary_pci.get(dev_id, {}).get("resource_unassigned"):
        layer = "pci_unassigned"
        reason = "secondary_pci_resource_unassigned"
    record = {
        "id": dev_id,
        "driver": driver,
        "device_class": dev_class,
        "checks": dict(checks),
        "primary_bus_parent": primary_parent,
        "secondary_bus_parent": secondary_parent,
        "primary_pci": primary_pci.get(dev_id, {}),
        "secondary_pci": secondary_pci.get(dev_id, {}),
        "failure_layer": layer,
        "reason": reason,
    }
    records.append(record)
    if layer and failure is None:
        failure = record

if failure is None and len(secondary_zero_aliases) > len(primary_zero_aliases) + 2:
    failure = {
        "id": "",
        "driver": "",
        "failure_layer": "mtree_unmapped",
        "reason": "secondary_zero_range_pci_alias",
        "checks": {"generated": True, "argv": True, "qtree": True, "pci": True, "mtree": False},
        "secondary_mtree_first_zero_alias": secondary_zero_aliases[0] if secondary_zero_aliases else "",
    }

state = "failed" if failure else "ok"
layer = failure.get("failure_layer", "") if failure else ""
first_id = failure.get("id", "") if failure else ""
first_driver = failure.get("driver", "") if failure else ""
first_reason = failure.get("reason", "ok") if failure else "ok"
first_checks = failure.get("checks", {}) if failure else {"generated": True, "argv": True, "qtree": True, "pci": True, "mtree": True}
first_path = path_string(first_checks.items())

artifact = {
    "context": context,
    "phase": phase,
    "state": state,
    "failure_layer": layer,
    "first_missing_id": first_id,
    "first_missing_driver": first_driver,
    "first_missing_path": first_path,
    "first_reason": first_reason,
    "primary_manifest": primary_manifest_path,
    "secondary_manifest": secondary_manifest_path,
    "counts": {
        "primary_generated": len(primary_generated),
        "secondary_generated": len(secondary_generated),
        "primary_argv": len(primary_argv),
        "secondary_argv": len(secondary_argv),
        "primary_qtree": len(primary_qtree),
        "secondary_qtree": len(secondary_qtree),
        "primary_pci": len(primary_pci),
        "secondary_pci": len(secondary_pci),
        "primary_zero_aliases": len(primary_zero_aliases),
        "secondary_zero_aliases": len(secondary_zero_aliases),
    },
    "records": records,
}

json_path = os.path.join(debug_dir, f"materialization-pipeline-{phase}.json")
txt_path = os.path.join(debug_dir, f"materialization-pipeline-diff-{phase}.txt")
try:
    with open(json_path, "w", encoding="utf-8") as handle:
        json.dump(artifact, handle, sort_keys=True, indent=2)
        handle.write("\n")
    with open(txt_path, "w", encoding="utf-8") as handle:
        handle.write(f"state={state}\n")
        handle.write(f"failure_layer={layer}\n")
        handle.write(f"first_missing_id={first_id}\n")
        handle.write(f"first_missing_driver={first_driver}\n")
        handle.write(f"first_missing_path={first_path}\n")
        handle.write(f"first_reason={first_reason}\n")
        handle.write("counts=" + json.dumps(artifact["counts"], sort_keys=True, separators=(",", ":")) + "\n")
except Exception as exc:
    print(f"state=failed")
    print(f"failure_layer=artifact_write_failed")
    print(f"first_reason={compact(exc)}")
    raise SystemExit(0)

print(f"state={state}")
print(f"failure_layer={layer}")
print(f"first_missing_id={first_id}")
print(f"first_missing_driver={first_driver}")
print(f"first_missing_path={first_path}")
print(f"first_reason={compact(first_reason)}")
print(f"missing_count={sum(1 for record in records if record.get('failure_layer'))}")
print(f"primary_generated_count={len(primary_generated)}")
print(f"secondary_generated_count={len(secondary_generated)}")
print(f"primary_argv_count={len(primary_argv)}")
print(f"secondary_argv_count={len(secondary_argv)}")
print(f"primary_qtree_count={len(primary_qtree)}")
print(f"secondary_qtree_count={len(secondary_qtree)}")
print(f"primary_pci_count={len(primary_pci)}")
print(f"secondary_pci_count={len(secondary_pci)}")
PY
)" || rc=$?

  : "${rc}"
  ftctl_xcolo_write_debug_file "${vm}" "materialization-pipeline-summary-${phase}.txt" "${payload}" || true

  state="$(printf '%s\n' "${payload}" | sed -n 's/^state=//p' | head -n1)"
  layer="$(printf '%s\n' "${payload}" | sed -n 's/^failure_layer=//p' | head -n1)"
  first_id="$(printf '%s\n' "${payload}" | sed -n 's/^first_missing_id=//p' | head -n1)"
  first_driver="$(printf '%s\n' "${payload}" | sed -n 's/^first_missing_driver=//p' | head -n1)"
  first_path="$(printf '%s\n' "${payload}" | sed -n 's/^first_missing_path=//p' | head -n1)"
  missing_count="$(printf '%s\n' "${payload}" | sed -n 's/^missing_count=//p' | head -n1)"
  first_reason="$(printf '%s\n' "${payload}" | sed -n 's/^first_reason=//p' | head -n1)"
  [[ -n "${state}" ]] || state="unknown"

  ftctl_state_set "${vm}" \
    "xcolo_materialization_pipeline=${state}" \
    "xcolo_materialization_phase=${phase}" \
    "xcolo_materialization_context=${context}" \
    "xcolo_materialization_failure_layer=${layer}" \
    "xcolo_materialization_missing_count=${missing_count}" \
    "xcolo_materialization_first_missing_id=$(ftctl_xcolo_compact_log_value "${first_id}")" \
    "xcolo_materialization_first_missing_driver=$(ftctl_xcolo_compact_log_value "${first_driver}")" \
    "xcolo_materialization_first_missing_path=$(ftctl_xcolo_compact_log_value "${first_path}")" \
    "xcolo_materialization_first_reason=$(ftctl_xcolo_compact_log_value "${first_reason}")"
  ftctl_log_event "colo" "xcolo.materialization_pipeline" "${state}" "${vm}" "" \
    "phase=${phase} layer=${layer} id=$(ftctl_xcolo_compact_log_value "${first_id}") path=$(ftctl_xcolo_compact_log_value "${first_path}")"
  return 0
}

ftctl_xcolo_verify_live_runtime_topology_pair() {
  local vm="${1-}"
  local secondary_vm="${2-}"
  local phase="${3:-before_migrate}"
  local primary_argv="" secondary_argv=""
  local primary_pci="" secondary_pci="" out="" rc=0 payload="" reason="" error_name="" pci_warning=""
  local pci_first_diff_index="" pci_primary="" pci_secondary=""
  local primary_pci_file secondary_pci_file

  [[ -n "${vm}" && -n "${secondary_vm}" ]] || return 1
  if [[ "${FTCTL_DRY_RUN}" == "1" ]]; then
    ftctl_log_event "colo" "xcolo.live_runtime_topology" "skip" "${vm}" "" "reason=dry_run phase=${phase}"
    return 0
  fi

  ftctl_xcolo_capture_live_runtime_topology_one "${vm}" "${FTCTL_PROFILE_PRIMARY_URI}" "${vm}" "primary" "${phase}" || true
  ftctl_xcolo_capture_live_runtime_topology_one "${vm}" "${FTCTL_PROFILE_SECONDARY_URI}" "${secondary_vm}" "secondary" "${phase}" || true
  ftctl_xcolo_capture_qemu_proc_args_pair "${vm}" "${secondary_vm}" "${phase}" primary_argv secondary_argv || true

  primary_pci_file="$(ftctl_xcolo_debug_dir "${vm}")/primary-info-pci-${phase}.txt"
  secondary_pci_file="$(ftctl_xcolo_debug_dir "${vm}")/secondary-info-pci-${phase}.txt"
  primary_pci="$(cat "${primary_pci_file}" 2>/dev/null || true)"
  secondary_pci="$(cat "${secondary_pci_file}" 2>/dev/null || true)"

  payload="$(PHASE="${phase}" PRIMARY_ARGV="${primary_argv}" SECONDARY_ARGV="${secondary_argv}" PRIMARY_PCI="${primary_pci}" SECONDARY_PCI="${secondary_pci}" python3 - <<'PY'
import hashlib
import json
import os
import re

phase = os.environ.get("PHASE", "")
primary_argv = os.environ.get("PRIMARY_ARGV", "")
secondary_argv = os.environ.get("SECONDARY_ARGV", "")
primary_pci = os.environ.get("PRIMARY_PCI", "")
secondary_pci = os.environ.get("SECONDARY_PCI", "")

def argv_list(raw):
    return [line for line in raw.splitlines() if line]

def normalize_device_arg(value):
    value = value.strip()
    if not value:
        return ""
    if value.startswith("{"):
        try:
            data = json.loads(value)
            return json.dumps(data, sort_keys=True, separators=(",", ":"))
        except Exception:
            return value
    parts = value.split(",")
    driver = parts[0]
    opts = []
    for item in parts[1:]:
        if not item:
            continue
        if "=" not in item:
            opts.append([item, ""])
            continue
        key, val = item.split("=", 1)
        opts.append([key, val])
    return json.dumps([driver, sorted(opts)], sort_keys=True, separators=(",", ":"))

def guest_devices(raw):
    args = argv_list(raw)
    devices = []
    for idx, arg in enumerate(args):
        if arg != "-device" or idx + 1 >= len(args):
            continue
        value = args[idx + 1]
        # COLO uses -object for filters.  Every -device here is guest-visible
        # enough to matter for migration topology, including libvirt JSON args.
        devices.append(normalize_device_arg(value))
    return devices

def normalize_pci(raw):
    lines = []
    for line in raw.splitlines():
        line = line.strip()
        if not line:
            continue
        line = re.sub(r"\s+", " ", line)
        lines.append(line)
    return lines

PCI_HEADER_RE = re.compile(r"^Bus\s+([0-9a-fA-F]+),\s*device\s+([0-9a-fA-F]+),\s*function\s+([0-9a-fA-F]+):$")

def pci_identity(raw):
    records = []
    current = None
    for line in raw.splitlines():
        text = re.sub(r"\s+", " ", line.strip())
        if not text:
            continue
        match = PCI_HEADER_RE.match(text)
        if match:
            if current is not None:
                records.append(current)
            current = {
                "addr": f"bus={int(match.group(1), 10)} device={int(match.group(2), 10)} function={int(match.group(3), 10)}",
                "class": "",
                "subsystem": "",
                "id": "",
            }
            continue
        if current is None:
            continue
        if text.startswith("BAR") or text.startswith("IRQ"):
            continue
        if text.startswith("BUS ") or text.startswith("secondary bus ") or text.startswith("subordinate bus "):
            continue
        if text.startswith("IO range ") or text.startswith("memory range ") or text.startswith("prefetchable memory range "):
            continue
        if ": PCI device " in text and not current["class"]:
            current["class"] = text
            continue
        if text.startswith("PCI subsystem "):
            current["subsystem"] = text
            continue
        if text.startswith("id "):
            current["id"] = text
            continue
    if current is not None:
        records.append(current)
    return records

def pci_incoming_unassigned(raw):
    text = raw or ""
    if not text.strip():
        return False
    bridge_count = len(re.findall(r"PCI bridge: PCI device 1b36:000c", text))
    zero_secondary = len(re.findall(r"secondary bus 0\.", text))
    zero_subordinate = len(re.findall(r"subordinate bus 0\.", text))
    not_mapped = "(not mapped)" in text
    return bridge_count >= 2 and zero_secondary >= 2 and zero_subordinate >= 2 and not_mapped

def digest(obj):
    encoded = json.dumps(obj, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(encoded.encode("utf-8")).hexdigest()

def diff_summary(left, right):
    max_len = max(len(left), len(right))
    diff_count = 0
    first_index = ""
    first_left = ""
    first_right = ""
    for idx in range(max_len):
        lval = left[idx] if idx < len(left) else "<missing>"
        rval = right[idx] if idx < len(right) else "<missing>"
        if lval != rval:
            diff_count += 1
            if first_index == "":
                first_index = str(idx)
                first_left = lval
                first_right = rval
    return {
        "diff_count": diff_count,
        "missing_count": max(0, len(left) - len(right)),
        "extra_count": max(0, len(right) - len(left)),
        "first_index": first_index,
        "first_left": first_left,
        "first_right": first_right,
    }

p_args = argv_list(primary_argv)
s_args = argv_list(secondary_argv)
p_devices = guest_devices(primary_argv)
s_devices = guest_devices(secondary_argv)
p_pci = normalize_pci(primary_pci)
s_pci = normalize_pci(secondary_pci)
p_pci_identity = pci_identity(primary_pci)
s_pci_identity = pci_identity(secondary_pci)
pci_id_diff = diff_summary(p_pci_identity, s_pci_identity)
pci_raw_diff = diff_summary(p_pci, s_pci)

if not p_args and not s_args:
    print("error=xcolo_live_runtime_argv_empty")
    print("reason=both_qemu_argv_empty primary_args=0 secondary_args=0")
    raise SystemExit(1)

if not p_args:
    print("error=xcolo_live_primary_argv_empty")
    print(f"reason=primary_qemu_argv_empty secondary_args={len(s_args)} secondary_devices={len(s_devices)}")
    raise SystemExit(1)

if not s_args:
    print("error=xcolo_live_secondary_argv_empty")
    print(f"reason=secondary_qemu_argv_empty primary_args={len(p_args)} primary_devices={len(p_devices)}")
    raise SystemExit(1)

if not p_devices and not s_devices:
    print("error=xcolo_live_runtime_argv_no_devices")
    print(f"reason=both_qemu_argv_have_no_devices primary_args={len(p_args)} secondary_args={len(s_args)}")
    raise SystemExit(1)

if not p_devices:
    print("error=xcolo_live_primary_argv_no_devices")
    print(f"reason=primary_qemu_argv_has_no_devices primary_args={len(p_args)} secondary_devices={len(s_devices)}")
    raise SystemExit(1)

if not s_devices:
    print("error=xcolo_live_secondary_argv_no_devices")
    print(f"reason=secondary_qemu_argv_has_no_devices secondary_args={len(s_args)} primary_devices={len(p_devices)}")
    raise SystemExit(1)

if p_devices != s_devices:
    print("error=xcolo_live_qemu_argv_mismatch")
    print(f"reason=device_args_diff primary_hash={digest(p_devices)} secondary_hash={digest(s_devices)}")
    max_len = max(len(p_devices), len(s_devices))
    for idx in range(max_len):
        left = p_devices[idx] if idx < len(p_devices) else "<missing>"
        right = s_devices[idx] if idx < len(s_devices) else "<missing>"
        if left != right:
            print(f"first_diff_index={idx}")
            print(f"primary={left}")
            print(f"secondary={right}")
            break
    raise SystemExit(1)

if not p_pci or not s_pci:
    print("error=xcolo_live_pci_snapshot_missing")
    print(f"reason=missing_info_pci primary_lines={len(p_pci)} secondary_lines={len(s_pci)}")
    raise SystemExit(1)
elif not p_pci_identity or not s_pci_identity:
    print("error=xcolo_live_pci_identity_missing")
    print(f"reason=missing_info_pci_identity primary_identity={len(p_pci_identity)} secondary_identity={len(s_pci_identity)} primary_lines={len(p_pci)} secondary_lines={len(s_pci)}")
    raise SystemExit(1)
elif p_pci_identity != s_pci_identity:
    if pci_incoming_unassigned(secondary_pci):
        print(f"pci_first_diff_index={pci_id_diff['first_index']}")
        print("pci_primary=" + json.dumps(pci_id_diff["first_left"], sort_keys=True, separators=(",", ":")))
        print("pci_secondary=" + json.dumps(pci_id_diff["first_right"], sort_keys=True, separators=(",", ":")))
        if phase == "before_migrate":
            print("error=xcolo_secondary_pci_resource_unmaterialized_before_migrate")
            print(f"reason=secondary_incoming_pci_unassigned_before_migrate phase={phase} primary_hash={digest(p_pci_identity)} secondary_hash={digest(s_pci_identity)}")
            print(f"pci_identity_primary_count={len(p_pci_identity)}")
            print(f"pci_identity_secondary_count={len(s_pci_identity)}")
            print(f"pci_identity_diff_count={pci_id_diff['diff_count']}")
            print(f"pci_identity_missing_count={pci_id_diff['missing_count']}")
            print(f"pci_identity_extra_count={pci_id_diff['extra_count']}")
            print(f"pci_resource_diff_count={pci_raw_diff['diff_count']}")
            raise SystemExit(1)
        else:
            print("error=xcolo_live_pci_identity_unmaterialized")
            print(f"reason=secondary_incoming_pci_unassigned phase={phase} primary_hash={digest(p_pci_identity)} secondary_hash={digest(s_pci_identity)}")
            raise SystemExit(1)
    else:
        print("error=xcolo_live_pci_identity_mismatch")
        print(f"reason=info_pci_identity_diff primary_hash={digest(p_pci_identity)} secondary_hash={digest(s_pci_identity)}")
        print(f"pci_first_diff_index={pci_id_diff['first_index']}")
        print("pci_primary=" + json.dumps(pci_id_diff["first_left"], sort_keys=True, separators=(",", ":")))
        print("pci_secondary=" + json.dumps(pci_id_diff["first_right"], sort_keys=True, separators=(",", ":")))
        raise SystemExit(1)
elif p_pci != s_pci:
    print("error=")
    print("warning=xcolo_live_pci_resource_diff_ignored")
    print(f"pci_reason=info_pci_resource_diff primary_hash={digest(p_pci)} secondary_hash={digest(s_pci)}")
else:
    print("error=")
if p_pci != s_pci:
    print(f"pci_raw_hash=primary:{digest(p_pci)} secondary:{digest(s_pci)}")
print(f"pci_identity_primary_count={len(p_pci_identity)}")
print(f"pci_identity_secondary_count={len(s_pci_identity)}")
print(f"pci_identity_diff_count={pci_id_diff['diff_count']}")
print(f"pci_identity_missing_count={pci_id_diff['missing_count']}")
print(f"pci_identity_extra_count={pci_id_diff['extra_count']}")
print(f"pci_resource_diff_count={pci_raw_diff['diff_count']}")
print(f"reason=ok device_hash={digest(p_devices)} pci_identity_hash={digest(p_pci_identity)} devices={len(p_devices)} pci_devices={len(p_pci_identity)} pci_lines_primary={len(p_pci)} pci_lines_secondary={len(s_pci)}")
PY
)" || rc=$?

  ftctl_xcolo_write_debug_file "${vm}" "live-topology-diff-${phase}.txt" "${payload}" || true
  ftctl_xcolo_analyze_materialization_pipeline "${vm}" "${phase}" "live_runtime" || true
  local pci_identity_primary_count="" pci_identity_secondary_count="" pci_identity_diff_count=""
  local pci_identity_missing_count="" pci_identity_extra_count="" pci_resource_diff_count=""
  pci_identity_primary_count="$(printf '%s\n' "${payload}" | sed -n 's/^pci_identity_primary_count=//p' | head -n1)"
  pci_identity_secondary_count="$(printf '%s\n' "${payload}" | sed -n 's/^pci_identity_secondary_count=//p' | head -n1)"
  pci_identity_diff_count="$(printf '%s\n' "${payload}" | sed -n 's/^pci_identity_diff_count=//p' | head -n1)"
  pci_identity_missing_count="$(printf '%s\n' "${payload}" | sed -n 's/^pci_identity_missing_count=//p' | head -n1)"
  pci_identity_extra_count="$(printf '%s\n' "${payload}" | sed -n 's/^pci_identity_extra_count=//p' | head -n1)"
  pci_resource_diff_count="$(printf '%s\n' "${payload}" | sed -n 's/^pci_resource_diff_count=//p' | head -n1)"
  if [[ "${rc}" != "0" ]]; then
    error_name="$(printf '%s\n' "${payload}" | sed -n 's/^error=//p' | head -n1)"
    reason="$(printf '%s\n' "${payload}" | sed -n 's/^reason=//p' | head -n1)"
    pci_first_diff_index="$(printf '%s\n' "${payload}" | sed -n 's/^pci_first_diff_index=//p' | head -n1)"
    pci_primary="$(printf '%s\n' "${payload}" | sed -n 's/^pci_primary=//p' | head -n1)"
    pci_secondary="$(printf '%s\n' "${payload}" | sed -n 's/^pci_secondary=//p' | head -n1)"
    [[ -n "${error_name}" ]] || error_name="xcolo_live_runtime_snapshot_failed"
    [[ -n "${reason}" ]] || reason="unknown"
    local materialization_layer="" materialization_path="" materialization_reason=""
    materialization_layer="$(ftctl_state_get "${vm}" "xcolo_materialization_failure_layer" 2>/dev/null || true)"
    materialization_path="$(ftctl_state_get "${vm}" "xcolo_materialization_first_missing_path" 2>/dev/null || true)"
    materialization_reason="$(ftctl_state_get "${vm}" "xcolo_materialization_first_reason" 2>/dev/null || true)"
    if [[ "${phase}" == "before_migrate" \
      && "${error_name}" == "xcolo_secondary_pci_resource_unmaterialized_before_migrate" \
      && "${materialization_path}" == *"generated:True"* \
      && "${materialization_path}" == *"argv:True"* \
      && "${materialization_path}" == *"qtree:True"* \
      && ( "${materialization_layer}" == "qtree_parent_missing" \
        || "${materialization_layer}" == "pci_missing" \
        || "${materialization_layer}" == "pci_unassigned" \
        || "${materialization_layer}" == "mtree_unmapped" ) ]]; then
      error_name="xcolo_pre_migrate_secondary_pci_resource_unmaterialized"
      reason="incoming_secondary_not_migration_abi_materialized layer=${materialization_layer} path=${materialization_path} reason=${materialization_reason}"
    fi
    ftctl_state_set "${vm}" \
      "xcolo_live_runtime_topology=failed" \
      "xcolo_live_runtime_topology_phase=${phase}" \
      "xcolo_live_runtime_topology_reason=$(ftctl_xcolo_compact_log_value "${reason}")" \
      "xcolo_live_pci_identity=failed" \
      "xcolo_live_pci_identity_first_diff_index=${pci_first_diff_index}" \
      "xcolo_live_pci_identity_primary_count=${pci_identity_primary_count}" \
      "xcolo_live_pci_identity_secondary_count=${pci_identity_secondary_count}" \
      "xcolo_live_pci_identity_diff_count=${pci_identity_diff_count}" \
      "xcolo_live_pci_identity_missing_count=${pci_identity_missing_count}" \
      "xcolo_live_pci_identity_extra_count=${pci_identity_extra_count}" \
      "xcolo_live_pci_resource_diff_count=${pci_resource_diff_count}" \
      "xcolo_live_pci_identity_primary=$(ftctl_xcolo_compact_log_value "${pci_primary}")" \
      "xcolo_live_pci_identity_secondary=$(ftctl_xcolo_compact_log_value "${pci_secondary}")" \
      "xcolo_live_pci_evidence=${error_name}" \
      "xcolo_live_qtree_evidence=collected" \
      "xcolo_live_mtree_evidence=collected" \
      "xcolo_pre_migrate_pci_materialization_deferred=no" \
      "xcolo_pre_migrate_pci_materialization_failure_layer=${materialization_layer}" \
      "xcolo_pre_migrate_pci_materialization_failure_path=$(ftctl_xcolo_compact_log_value "${materialization_path}")" \
      "xcolo_pre_migrate_pci_materialization_failure_reason=$(ftctl_xcolo_compact_log_value "${materialization_reason}")" \
      "xcolo_protocol_failure_phase=pre_migrate_materialization" \
      "last_error=${error_name}"
    ftctl_log_event "colo" "xcolo.live_runtime_topology" "fail" "${vm}" "" \
      "phase=${phase} error=${error_name} reason=$(ftctl_xcolo_compact_log_value "${reason}")"
    return 1
  fi

  reason="$(printf '%s\n' "${payload}" | sed -n 's/^reason=//p' | head -n1)"
  pci_warning="$(printf '%s\n' "${payload}" | sed -n 's/^warning=//p' | head -n1)"
  pci_first_diff_index="$(printf '%s\n' "${payload}" | sed -n 's/^pci_first_diff_index=//p' | head -n1)"
  pci_primary="$(printf '%s\n' "${payload}" | sed -n 's/^pci_primary=//p' | head -n1)"
  pci_secondary="$(printf '%s\n' "${payload}" | sed -n 's/^pci_secondary=//p' | head -n1)"
  ftctl_state_set "${vm}" \
    "xcolo_live_runtime_topology=ok" \
    "xcolo_live_runtime_topology_phase=${phase}" \
    "xcolo_live_runtime_topology_reason=$(ftctl_xcolo_compact_log_value "${reason}")" \
    "xcolo_live_pci_identity=ok" \
    "xcolo_live_pci_identity_warning=${pci_warning}" \
    "xcolo_live_pci_identity_first_diff_index=${pci_first_diff_index}" \
    "xcolo_live_pci_identity_primary_count=${pci_identity_primary_count}" \
    "xcolo_live_pci_identity_secondary_count=${pci_identity_secondary_count}" \
    "xcolo_live_pci_identity_diff_count=${pci_identity_diff_count}" \
    "xcolo_live_pci_identity_missing_count=${pci_identity_missing_count}" \
    "xcolo_live_pci_identity_extra_count=${pci_identity_extra_count}" \
    "xcolo_live_pci_resource_diff_count=${pci_resource_diff_count}" \
    "xcolo_live_pci_identity_primary=$(ftctl_xcolo_compact_log_value "${pci_primary}")" \
    "xcolo_live_pci_identity_secondary=$(ftctl_xcolo_compact_log_value "${pci_secondary}")" \
    "xcolo_live_pci_evidence=${pci_warning:-none}" \
    "xcolo_live_qtree_evidence=collected" \
    "xcolo_live_mtree_evidence=collected"
  ftctl_log_event "colo" "xcolo.live_runtime_topology" "ok" "${vm}" "" \
    "phase=${phase} $(ftctl_xcolo_compact_log_value "${reason}")"
}

ftctl_xcolo_validate_pre_migrate_contract() {
  local vm="${1-}"
  local secondary_vm="${2-}"
  local disk_plan="${3-}"
  local phase="${4:-pre_migrate_contract}"
  local primary_argv="" secondary_argv="" payload="" rc=0
  local contract_state="" contract_reason="" contract_error=""
  local primary_block="" primary_block_reason="" secondary_block="" secondary_block_reason=""

  [[ -n "${vm}" && -n "${secondary_vm}" ]] || return 1
  if [[ "${FTCTL_DRY_RUN}" == "1" ]]; then
    ftctl_log_event "colo" "xcolo.pre_migrate_contract" "skip" "${vm}" "" "reason=dry_run"
    return 0
  fi

  ftctl_xcolo_capture_qemu_proc_args_pair "${vm}" "${secondary_vm}" "${phase}" primary_argv secondary_argv || true
  ftctl_xcolo_collect_primary_block_graph_state "${vm}" "${disk_plan}" || true
  ftctl_xcolo_collect_secondary_block_graph_state "${vm}" "${secondary_vm}" "${disk_plan}" || true

  primary_block="$(ftctl_state_get "${vm}" "xcolo_primary_block_graph_ready" 2>/dev/null || true)"
  primary_block_reason="$(ftctl_state_get "${vm}" "xcolo_primary_block_graph_reason" 2>/dev/null || true)"
  secondary_block="$(ftctl_state_get "${vm}" "xcolo_secondary_block_graph_ready" 2>/dev/null || true)"
  secondary_block_reason="$(ftctl_state_get "${vm}" "xcolo_secondary_block_graph_reason" 2>/dev/null || true)"

  payload="$(PRIMARY_ARGV="${primary_argv}" SECONDARY_ARGV="${secondary_argv}" PRIMARY_BLOCK="${primary_block}" SECONDARY_BLOCK="${secondary_block}" PRIMARY_BLOCK_REASON="${primary_block_reason}" SECONDARY_BLOCK_REASON="${secondary_block_reason}" python3 - <<'PY'
import hashlib
import json
import os
import re

primary_argv = os.environ.get("PRIMARY_ARGV", "")
secondary_argv = os.environ.get("SECONDARY_ARGV", "")
primary_block = os.environ.get("PRIMARY_BLOCK", "")
secondary_block = os.environ.get("SECONDARY_BLOCK", "")
primary_block_reason = os.environ.get("PRIMARY_BLOCK_REASON", "")
secondary_block_reason = os.environ.get("SECONDARY_BLOCK_REASON", "")

def argv_list(raw):
    return [line for line in raw.splitlines() if line]

def digest(obj):
    encoded = json.dumps(obj, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(encoded.encode("utf-8")).hexdigest()

def normalize_value(value):
    value = value.strip()
    if value.startswith("{"):
        try:
            return json.loads(value)
        except Exception:
            return value
    parts = value.split(",")
    if len(parts) == 1:
        return value
    opts = {}
    flags = []
    for item in parts[1:]:
        if not item:
            continue
        if "=" in item:
            key, val = item.split("=", 1)
            opts[key] = val
        else:
            flags.append(item)
    return {"driver": parts[0], "opts": opts, "flags": sorted(flags)}

def option_values(args, opt):
    values = []
    idx = 0
    while idx < len(args):
        if args[idx] == opt and idx + 1 < len(args):
            values.append(args[idx + 1])
            idx += 2
        else:
            idx += 1
    return values

def option_present(args, opt):
    return opt in args

def qemu_devices(args):
    return [normalize_value(v) for v in option_values(args, "-device")]

def object_ids(args):
    ids = {}
    for value in option_values(args, "-object"):
        data = normalize_value(value)
        if isinstance(data, dict) and "qom-type" in data:
            qtype = data.get("qom-type")
            oid = data.get("id", "")
        elif isinstance(data, dict):
            qtype = data.get("driver", "")
            oid = data.get("opts", {}).get("id", "")
        else:
            qtype = str(data).split(",", 1)[0]
            match = re.search(r"(?:^|,)id=([^,]+)", str(data))
            oid = match.group(1) if match else ""
        if oid:
            ids[oid] = qtype
    return ids

def chardev_ids(args):
    ids = {}
    for value in option_values(args, "-chardev"):
        data = normalize_value(value)
        if isinstance(data, dict):
            cid = data.get("id", "") or data.get("opts", {}).get("id", "")
            driver = data.get("backend", "") or data.get("driver", "")
        else:
            cid = ""
            driver = str(data).split(",", 1)[0]
            match = re.search(r"(?:^|,)id=([^,]+)", str(data))
            if match:
                cid = match.group(1)
        if cid:
            ids[cid] = driver
    return ids

p_args = argv_list(primary_argv)
s_args = argv_list(secondary_argv)
p_devices = qemu_devices(p_args)
s_devices = qemu_devices(s_args)
p_objects = object_ids(p_args)
s_objects = object_ids(s_args)
p_chardevs = chardev_ids(p_args)
s_chardevs = chardev_ids(s_args)

reasons = []
error = ""

if not p_args or not s_args:
    error = "xcolo_guest_abi_contract_mismatch"
    reasons.append(f"argv_missing primary={len(p_args)} secondary={len(s_args)}")
elif p_devices != s_devices:
    error = "xcolo_guest_abi_contract_mismatch"
    reasons.append(f"guest_devices_diff primary_hash={digest(p_devices)} secondary_hash={digest(s_devices)}")
    for idx in range(max(len(p_devices), len(s_devices))):
        left = p_devices[idx] if idx < len(p_devices) else "<missing>"
        right = s_devices[idx] if idx < len(s_devices) else "<missing>"
        if left != right:
            reasons.append(f"first_device_diff_index={idx}")
            reasons.append("primary_device=" + json.dumps(left, sort_keys=True, separators=(",", ":")))
            reasons.append("secondary_device=" + json.dumps(right, sort_keys=True, separators=(",", ":")))
            break

primary_required_chardevs = {"mirror0", "compare0", "compare0-0", "compare1", "compare_out", "compare_out0"}
primary_required_objects = {"m0": "filter-mirror", "redire0": "filter-redirector", "redire1": "filter-redirector", "comp0": "colo-compare"}
secondary_required_chardevs = {"red0", "red1"}
secondary_required_objects = {"f1": "filter-redirector", "f2": "filter-redirector", "rew0": "filter-rewriter"}
primary_forbidden_objects = {"f1", "f2", "rew0"}
secondary_forbidden_objects = {"m0", "redire0", "redire1", "comp0"}

role_reasons = []
for item in sorted(primary_required_chardevs - set(p_chardevs)):
    role_reasons.append(f"primary_chardev_{item}:missing")
for oid, qtype in primary_required_objects.items():
    if p_objects.get(oid) != qtype:
        role_reasons.append(f"primary_object_{oid}:{p_objects.get(oid, 'missing')}")
for item in sorted(primary_forbidden_objects & set(p_objects)):
    role_reasons.append(f"primary_forbidden_object_{item}:present")
for item in sorted(secondary_required_chardevs - set(s_chardevs)):
    role_reasons.append(f"secondary_chardev_{item}:missing")
for oid, qtype in secondary_required_objects.items():
    if s_objects.get(oid) != qtype:
        role_reasons.append(f"secondary_object_{oid}:{s_objects.get(oid, 'missing')}")
for item in sorted(secondary_forbidden_objects & set(s_objects)):
    role_reasons.append(f"secondary_forbidden_object_{item}:present")
if not option_present(s_args, "-incoming"):
    role_reasons.append("secondary_incoming:missing")

if not error and role_reasons:
    error = "xcolo_colo_role_contract_mismatch"
    reasons.extend(role_reasons)

if not error and primary_block != "yes":
    error = "xcolo_primary_block_replication_contract_incomplete"
    reasons.append(primary_block_reason or "primary_block_graph_not_ready")
if not error and secondary_block not in ("yes", "not_applicable"):
    error = "xcolo_secondary_block_replication_contract_incomplete"
    reasons.append(secondary_block_reason or "secondary_block_graph_not_ready")

print(f"state={'ok' if not error else 'failed'}")
print(f"error={error}")
print("reason=" + ",".join(reasons))
print(f"primary_argv_lines={len(p_args)}")
print(f"secondary_argv_lines={len(s_args)}")
print(f"guest_device_count={len(p_devices)}")
print(f"primary_guest_device_hash={digest(p_devices)}")
print(f"secondary_guest_device_hash={digest(s_devices)}")
print(f"primary_role_chardevs={','.join(sorted(p_chardevs))}")
print(f"secondary_role_chardevs={','.join(sorted(s_chardevs))}")
print(f"primary_role_objects={','.join(f'{k}:{v}' for k,v in sorted(p_objects.items()))}")
print(f"secondary_role_objects={','.join(f'{k}:{v}' for k,v in sorted(s_objects.items()))}")
print(f"primary_block_graph={primary_block}")
print(f"primary_block_graph_reason={primary_block_reason}")
print(f"secondary_block_graph={secondary_block}")
print(f"secondary_block_graph_reason={secondary_block_reason}")
PY
)" || rc=$?

  ftctl_xcolo_write_debug_file "${vm}" "migration-abi-contract-${phase}.txt" "${payload}" || true
  contract_state="$(printf '%s\n' "${payload}" | sed -n 's/^state=//p' | head -n1)"
  contract_error="$(printf '%s\n' "${payload}" | sed -n 's/^error=//p' | head -n1)"
  contract_reason="$(printf '%s\n' "${payload}" | sed -n 's/^reason=//p' | head -n1)"
  [[ -n "${contract_state}" ]] || contract_state="failed"

  if [[ "${contract_state}" == "ok" && "${rc}" == "0" ]]; then
    ftctl_state_set "${vm}" \
      "xcolo_pre_migrate_contract=ok" \
      "xcolo_pre_migrate_contract_phase=${phase}" \
      "xcolo_pre_migrate_contract_reason=$(ftctl_xcolo_compact_log_value "${contract_reason}")" \
      "xcolo_primary_block_graph_ready=${primary_block}" \
      "xcolo_secondary_block_graph_ready=${secondary_block}"
    ftctl_log_event "colo" "xcolo.pre_migrate_contract" "ok" "${vm}" "" \
      "phase=${phase} primary_block=${primary_block} secondary_block=${secondary_block}"
    return 0
  fi

  [[ -n "${contract_error}" ]] || contract_error="xcolo_pre_migrate_contract_failed"
  [[ -n "${contract_reason}" ]] || contract_reason="unknown"
  ftctl_state_set "${vm}" \
    "xcolo_pre_migrate_contract=failed" \
    "xcolo_pre_migrate_contract_phase=${phase}" \
    "xcolo_pre_migrate_contract_error=${contract_error}" \
    "xcolo_pre_migrate_contract_reason=$(ftctl_xcolo_compact_log_value "${contract_reason}")" \
    "xcolo_protocol_failure_phase=pre_migrate_contract" \
    "last_error=${contract_error}"
  ftctl_log_event "colo" "xcolo.pre_migrate_contract" "fail" "${vm}" "" \
    "phase=${phase} error=${contract_error} reason=$(ftctl_xcolo_compact_log_value "${contract_reason}") primary_block=${primary_block} secondary_block=${secondary_block}"
  return 1
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

ftctl_xcolo_secondary_qemu_assert_memory_region_container_observed() {
  local vm="${1-}"
  local secondary_vm="${2:-$vm}"
  local log_file

  [[ -n "${vm}" && -n "${secondary_vm}" ]] || return 1
  ftctl_xcolo_capture_qemu_log_tails "${vm}" "${secondary_vm}" || true
  log_file="$(ftctl_xcolo_debug_dir "${vm}")/secondary-qemu-log-tail.txt"
  if grep -Eq "memory_region_add_subregion_common|Assertion .*subregion->container|Assertion .*!subregion->container" "${log_file}" 2>/dev/null; then
    ftctl_state_set "${vm}" \
      "xcolo_secondary_qemu_assert=memory_region_add_subregion_common" \
      "xcolo_secondary_crash_detected=yes" \
      "xcolo_secondary_crash_assertion=memory_region_add_subregion_common"
    return 0
  fi
  return 1
}

ftctl_xcolo_post_migrate_secondary_failure_detected() {
  local vm="${1-}"
  local secondary_vm="${2-}"
  local phase="${3:-role_transition}"
  local primary_migrate="" secondary_migrate="" primary_status="" secondary_status=""
  local primary_colo="" query_state="" query_transient="" reason=""

  [[ -n "${vm}" && -n "${secondary_vm}" ]] || return 1

  primary_migrate="$(ftctl_state_get "${vm}" "xcolo_post_migrate_${phase}_primary_migrate_status" 2>/dev/null || true)"
  secondary_migrate="$(ftctl_state_get "${vm}" "xcolo_post_migrate_${phase}_secondary_migrate_status" 2>/dev/null || true)"
  primary_status="$(ftctl_state_get "${vm}" "xcolo_post_migrate_${phase}_primary_status" 2>/dev/null || true)"
  secondary_status="$(ftctl_state_get "${vm}" "xcolo_post_migrate_${phase}_secondary_status" 2>/dev/null || true)"
  primary_colo="$(ftctl_state_get "${vm}" "xcolo_post_migrate_${phase}_primary_colo_mode" 2>/dev/null || true)"
  query_state="$(ftctl_state_get "${vm}" "xcolo_post_migrate_${phase}_chardev_contract_query_state" 2>/dev/null || true)"
  query_transient="$(ftctl_state_get "${vm}" "xcolo_post_migrate_${phase}_chardev_contract_query_transient" 2>/dev/null || true)"

  case "${primary_migrate}:${primary_colo}:${primary_status}" in
    colo:*|*:primary:*) ;;
    *) return 1 ;;
  esac

  if [[ -n "${secondary_migrate}" && -n "${secondary_status}" &&
        "${query_state}" != *"secondary_query_failed"* &&
        "${query_transient}" != "yes" ]]; then
    return 1
  fi

  ftctl_xcolo_capture_post_migrate_secondary_failure_evidence "${vm}" "${secondary_vm}" "post_migrate_${phase}_secondary_failure" || true
  if ftctl_xcolo_secondary_qemu_assert_memory_region_container_observed "${vm}" "${secondary_vm}"; then
    reason="secondary_qemu_assert_memory_region_container"
    ftctl_state_set "${vm}" \
      "xcolo_secondary_qemu_assert=memory_region_add_subregion_common" \
      "xcolo_repeated_failure_signature=memory_region_add_subregion_common" \
      "last_error=xcolo_secondary_qemu_assert_memory_region_container"
  else
    reason="secondary_runtime_missing_after_migrate"
    ftctl_state_set "${vm}" \
      "last_error=xcolo_post_migrate_secondary_runtime_missing"
  fi

  ftctl_state_set "${vm}" \
    "xcolo_post_migrate_secondary_failure_detected=yes" \
    "xcolo_post_migrate_secondary_failure_phase=${phase}" \
    "xcolo_post_migrate_secondary_failure_reason=${reason}" \
    "xcolo_post_migrate_secondary_failure_primary_migrate=${primary_migrate}" \
    "xcolo_post_migrate_secondary_failure_primary_status=${primary_status}" \
    "xcolo_post_migrate_secondary_failure_primary_colo=${primary_colo}" \
    "xcolo_post_migrate_secondary_failure_secondary_migrate=${secondary_migrate}" \
    "xcolo_post_migrate_secondary_failure_secondary_status=${secondary_status}" \
    "xcolo_post_migrate_secondary_failure_query_state=${query_state}" \
    "xcolo_post_migrate_secondary_failure_query_transient=${query_transient}" \
    "xcolo_primary_safe_fail_recovery_required=yes"
  ftctl_log_event "colo" "xcolo.post_migrate_secondary_failure" "fail" "${vm}" "" \
    "phase=${phase} reason=${reason} primary_migrate=${primary_migrate} primary_status=${primary_status} secondary_migrate=${secondary_migrate} secondary_status=${secondary_status} query_state=${query_state}"
  return 0
}

ftctl_xcolo_analyze_runtime_topology_diff() {
  local vm="${1-}"
  local phase="${2:-post_migrate_secondary_crash}"
  local context="${3:-post_migrate}"
  local debug_dir="" summary="" rc=0
  local post_pci_diff_count="" post_qtree_diff_count="" post_mtree_diff_count=""
  local primary_zero_pci_alias_count="" secondary_zero_pci_alias_count=""
  local candidate_device="" candidate_region="" candidate_reason=""
  local gate_state="" gate_error="" gate_reason=""

  [[ -n "${vm}" ]] || return 0
  debug_dir="$(ftctl_xcolo_debug_dir "${vm}")"
  summary="$(DEBUG_DIR="${debug_dir}" PHASE="${phase}" CONTEXT="${context}" python3 - <<'PY'
import hashlib
import json
import os
import re

debug_dir = os.environ.get("DEBUG_DIR", "")
phase = os.environ.get("PHASE", "")
context = os.environ.get("CONTEXT", "")

def read_text(name):
    path = os.path.join(debug_dir, name)
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as handle:
            return handle.read()
    except FileNotFoundError:
        return ""

def digest(obj):
    encoded = json.dumps(obj, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(encoded.encode("utf-8")).hexdigest()

def norm_line(line):
    return re.sub(r"\s+", " ", line.strip())

PCI_HEADER_RE = re.compile(r"^Bus\s+([0-9a-fA-F]+),\s*device\s+([0-9a-fA-F]+),\s*function\s+([0-9a-fA-F]+):$")

def pci_identity(raw):
    records = []
    current = None
    for line in raw.splitlines():
        text = norm_line(line)
        if not text:
            continue
        match = PCI_HEADER_RE.match(text)
        if match:
            if current is not None:
                records.append(current)
            current = {
                "addr": f"bus={int(match.group(1), 10)} device={int(match.group(2), 10)} function={int(match.group(3), 10)}",
                "class": "",
                "subsystem": "",
                "id": "",
            }
            continue
        if current is None:
            continue
        if text.startswith(("BAR", "IRQ", "BUS ", "secondary bus ", "subordinate bus ")):
            continue
        if text.startswith(("IO range ", "memory range ", "prefetchable memory range ")):
            continue
        if ": PCI device " in text and not current["class"]:
            current["class"] = text
            continue
        if text.startswith("PCI subsystem "):
            current["subsystem"] = text
            continue
        if text.startswith("id "):
            current["id"] = text
            continue
    if current is not None:
        records.append(current)
    return records

def normalize_qtree(raw):
    lines = []
    for line in raw.splitlines():
        text = norm_line(line)
        if not text:
            continue
        if text.startswith(("dev:", "bus:", "child<", "gpio-", "link<")):
            lines.append(text)
            continue
        if any(key in text for key in (" addr =", " bus =", " class ", " device_id =", " serial =", " mac =")):
            lines.append(text)
    return lines

QTREE_DEV_RE = re.compile(r'^dev:\s*([^,]+)(?:,\s*id\s*"([^"]+)")?')

def qtree_devices(raw):
    devices = []
    for line in raw.splitlines():
        text = norm_line(line)
        match = QTREE_DEV_RE.match(text)
        if not match:
            continue
        driver = match.group(1).strip()
        dev_id = (match.group(2) or "").strip()
        if dev_id:
            devices.append(f"id:{dev_id}|driver:{driver}")
        else:
            devices.append(f"driver:{driver}")
    return devices

def qtree_missing(left, right):
    right_counts = {}
    for item in right:
        right_counts[item] = right_counts.get(item, 0) + 1
    missing = []
    for item in left:
        count = right_counts.get(item, 0)
        if count > 0:
            right_counts[item] = count - 1
        else:
            missing.append(item)
    return missing

MTREE_VOLATILE_RE = re.compile(r"\s+@[0-9a-fA-Fx]+")

def normalize_mtree(raw):
    lines = []
    for line in raw.splitlines():
        text = norm_line(line)
        if not text:
            continue
        if text.startswith(("FlatView", "Root memory region")):
            continue
        text = MTREE_VOLATILE_RE.sub("", text)
        lines.append(text)
    return lines

def diff_summary(left, right):
    max_len = max(len(left), len(right))
    diff_count = 0
    first_index = ""
    first_left = ""
    first_right = ""
    for idx in range(max_len):
        lval = left[idx] if idx < len(left) else "<missing>"
        rval = right[idx] if idx < len(right) else "<missing>"
        if lval != rval:
            diff_count += 1
            if first_index == "":
                first_index = str(idx)
                first_left = lval
                first_right = rval
    return diff_count, first_index, first_left, first_right

def repeated_items(items):
    seen = set()
    dup = []
    for item in items:
        if item in seen and item not in dup:
            dup.append(item)
        seen.add(item)
    return dup

ZERO_RANGE_RE = re.compile(r"^0+0-0+0 ")

def zero_range_pci_aliases(items):
    aliases = []
    for item in items:
        if not ZERO_RANGE_RE.match(item):
            continue
        if "alias pci_bridge_" in item or "alias pcie" in item:
            aliases.append(item)
    return aliases

def compact(value, limit=300):
    value = str(value).replace("\n", " ").replace("\t", " ")
    value = re.sub(r"\s+", " ", value).strip()
    return value[:limit]

primary_pci = pci_identity(read_text(f"primary-info-pci-{phase}.txt"))
secondary_pci = pci_identity(read_text(f"secondary-info-pci-{phase}.txt"))
primary_qtree = normalize_qtree(read_text(f"primary-info-qtree-{phase}.txt"))
secondary_qtree = normalize_qtree(read_text(f"secondary-info-qtree-{phase}.txt"))
primary_mtree = normalize_mtree(read_text(f"primary-info-mtree-{phase}.txt"))
secondary_mtree = normalize_mtree(read_text(f"secondary-info-mtree-{phase}.txt"))
primary_qtree_devices = qtree_devices(read_text(f"primary-info-qtree-{phase}.txt"))
secondary_qtree_devices = qtree_devices(read_text(f"secondary-info-qtree-{phase}.txt"))

pci_diff_count, pci_first_index, pci_first_primary, pci_first_secondary = diff_summary(primary_pci, secondary_pci)
qtree_diff_count, qtree_first_index, qtree_first_primary, qtree_first_secondary = diff_summary(primary_qtree, secondary_qtree)
mtree_diff_count, mtree_first_index, mtree_first_primary, mtree_first_secondary = diff_summary(primary_mtree, secondary_mtree)

primary_mtree_dups = repeated_items(primary_mtree)
secondary_mtree_dups = repeated_items(secondary_mtree)
primary_zero_pci_aliases = zero_range_pci_aliases(primary_mtree)
secondary_zero_pci_aliases = zero_range_pci_aliases(secondary_mtree)
qtree_missing_devices = qtree_missing(primary_qtree_devices, secondary_qtree_devices)
qtree_extra_devices = qtree_missing(secondary_qtree_devices, primary_qtree_devices)
candidate_device = ""
candidate_region = ""
candidate_reason = ""
gate_state = "ok"
gate_error = ""
gate_reason = ""

if mtree_diff_count:
    candidate_region = mtree_first_secondary if mtree_first_secondary != "<missing>" else mtree_first_primary
    candidate_reason = "mtree_first_diff"
if secondary_mtree_dups:
    candidate_region = secondary_mtree_dups[0]
    candidate_reason = "secondary_mtree_duplicate_region"
if qtree_diff_count:
    candidate_device = qtree_first_secondary if qtree_first_secondary != "<missing>" else qtree_first_primary
    if not candidate_reason:
        candidate_reason = "qtree_first_diff"
if pci_diff_count and not candidate_device:
    candidate_device = json.dumps(pci_first_secondary if pci_first_secondary != "<missing>" else pci_first_primary, sort_keys=True, separators=(",", ":"))
    if not candidate_reason:
        candidate_reason = "pci_first_diff"

if context == "pre_migrate":
    if len(primary_qtree_devices) > 0 and len(secondary_qtree_devices) == 0:
        gate_state = "failed"
        gate_error = "xcolo_pre_migrate_secondary_qtree_empty"
        gate_reason = "secondary_qtree_empty"
    elif len(primary_mtree) > 0 and len(secondary_mtree) <= 1:
        gate_state = "failed"
        gate_error = "xcolo_pre_migrate_secondary_mtree_empty"
        gate_reason = "secondary_mtree_empty"
    elif qtree_missing_devices:
        gate_state = "failed"
        gate_error = "xcolo_pre_migrate_guest_topology_missing"
        gate_reason = qtree_missing_devices[0]
        candidate_device = qtree_missing_devices[0]
        candidate_reason = "qtree_missing_device"
    elif len(secondary_zero_pci_aliases) > len(primary_zero_pci_aliases) + 2:
        gate_state = "failed"
        gate_error = "xcolo_pre_migrate_secondary_pci_resource_unmaterialized"
        gate_reason = secondary_zero_pci_aliases[0]
        candidate_region = secondary_zero_pci_aliases[0]
        candidate_reason = "secondary_zero_range_pci_alias"
elif context == "post_migrate_materialization":
    if len(primary_qtree_devices) > 0 and len(secondary_qtree_devices) == 0:
        gate_state = "failed"
        gate_error = "xcolo_post_migrate_secondary_qtree_empty"
        gate_reason = "secondary_qtree_empty"
    elif len(primary_mtree) > 0 and len(secondary_mtree) <= 1:
        gate_state = "failed"
        gate_error = "xcolo_post_migrate_secondary_mtree_empty"
        gate_reason = "secondary_mtree_empty"
    elif qtree_missing_devices:
        gate_state = "failed"
        gate_error = "xcolo_post_migrate_guest_topology_missing"
        gate_reason = qtree_missing_devices[0]
        candidate_device = qtree_missing_devices[0]
        candidate_reason = "qtree_missing_device"
    elif len(secondary_zero_pci_aliases) > len(primary_zero_pci_aliases) + 2:
        gate_state = "failed"
        gate_error = "xcolo_post_migrate_secondary_pci_resources_unmaterialized"
        gate_reason = secondary_zero_pci_aliases[0]
        candidate_region = secondary_zero_pci_aliases[0]
        candidate_reason = "secondary_zero_range_pci_alias"

print(f"context={context}")
print(f"phase={phase}")
print(f"pci_primary_count={len(primary_pci)}")
print(f"pci_secondary_count={len(secondary_pci)}")
print(f"pci_diff_count={pci_diff_count}")
print(f"pci_first_diff_index={pci_first_index}")
print("pci_first_primary=" + compact(json.dumps(pci_first_primary, sort_keys=True, separators=(",", ":"))))
print("pci_first_secondary=" + compact(json.dumps(pci_first_secondary, sort_keys=True, separators=(",", ":"))))
print(f"qtree_primary_lines={len(primary_qtree)}")
print(f"qtree_secondary_lines={len(secondary_qtree)}")
print(f"qtree_diff_count={qtree_diff_count}")
print(f"qtree_primary_device_count={len(primary_qtree_devices)}")
print(f"qtree_secondary_device_count={len(secondary_qtree_devices)}")
print(f"qtree_missing_device_count={len(qtree_missing_devices)}")
print(f"qtree_extra_device_count={len(qtree_extra_devices)}")
print("qtree_first_missing_device=" + compact(qtree_missing_devices[0] if qtree_missing_devices else ""))
print("qtree_first_extra_device=" + compact(qtree_extra_devices[0] if qtree_extra_devices else ""))
print(f"qtree_first_diff_index={qtree_first_index}")
print("qtree_first_primary=" + compact(qtree_first_primary))
print("qtree_first_secondary=" + compact(qtree_first_secondary))
print(f"mtree_primary_lines={len(primary_mtree)}")
print(f"mtree_secondary_lines={len(secondary_mtree)}")
print(f"mtree_diff_count={mtree_diff_count}")
print(f"mtree_secondary_empty={'yes' if len(secondary_mtree) <= 1 else 'no'}")
print(f"mtree_first_diff_index={mtree_first_index}")
print("mtree_first_primary=" + compact(mtree_first_primary))
print("mtree_first_secondary=" + compact(mtree_first_secondary))
print(f"mtree_primary_duplicate_count={len(primary_mtree_dups)}")
print(f"mtree_secondary_duplicate_count={len(secondary_mtree_dups)}")
print(f"mtree_primary_zero_pci_alias_count={len(primary_zero_pci_aliases)}")
print(f"mtree_secondary_zero_pci_alias_count={len(secondary_zero_pci_aliases)}")
print("mtree_first_secondary_zero_pci_alias=" + compact(secondary_zero_pci_aliases[0] if secondary_zero_pci_aliases else ""))
print("assert_candidate_device=" + compact(candidate_device or "unknown"))
print("assert_candidate_region=" + compact(candidate_region or "unknown"))
print("assert_candidate_reason=" + compact(candidate_reason or "insufficient_diff_evidence"))
print(f"topology_gate_state={gate_state}")
print(f"topology_gate_error={gate_error}")
print("topology_gate_reason=" + compact(gate_reason))
print(f"pci_identity_hash=primary:{digest(primary_pci)} secondary:{digest(secondary_pci)}")
print(f"qtree_hash=primary:{digest(primary_qtree)} secondary:{digest(secondary_qtree)}")
print(f"mtree_hash=primary:{digest(primary_mtree)} secondary:{digest(secondary_mtree)}")
PY
)" || rc=$?

  ftctl_xcolo_write_debug_file "${vm}" "runtime-topology-analysis-${phase}.txt" "${summary}" || true
  post_pci_diff_count="$(printf '%s\n' "${summary}" | sed -n 's/^pci_diff_count=//p' | head -n1)"
  post_qtree_diff_count="$(printf '%s\n' "${summary}" | sed -n 's/^qtree_diff_count=//p' | head -n1)"
  post_mtree_diff_count="$(printf '%s\n' "${summary}" | sed -n 's/^mtree_diff_count=//p' | head -n1)"
  primary_zero_pci_alias_count="$(printf '%s\n' "${summary}" | sed -n 's/^mtree_primary_zero_pci_alias_count=//p' | head -n1)"
  secondary_zero_pci_alias_count="$(printf '%s\n' "${summary}" | sed -n 's/^mtree_secondary_zero_pci_alias_count=//p' | head -n1)"
  candidate_device="$(printf '%s\n' "${summary}" | sed -n 's/^assert_candidate_device=//p' | head -n1)"
  candidate_region="$(printf '%s\n' "${summary}" | sed -n 's/^assert_candidate_region=//p' | head -n1)"
  candidate_reason="$(printf '%s\n' "${summary}" | sed -n 's/^assert_candidate_reason=//p' | head -n1)"
  gate_state="$(printf '%s\n' "${summary}" | sed -n 's/^topology_gate_state=//p' | head -n1)"
  gate_error="$(printf '%s\n' "${summary}" | sed -n 's/^topology_gate_error=//p' | head -n1)"
  gate_reason="$(printf '%s\n' "${summary}" | sed -n 's/^topology_gate_reason=//p' | head -n1)"

  ftctl_state_set "${vm}" \
    "xcolo_${context}_topology_analyzed=yes" \
    "xcolo_${context}_pci_diff_count=${post_pci_diff_count}" \
    "xcolo_${context}_qtree_diff_count=${post_qtree_diff_count}" \
    "xcolo_${context}_mtree_diff_count=${post_mtree_diff_count}" \
    "xcolo_${context}_mtree_primary_zero_pci_alias_count=${primary_zero_pci_alias_count}" \
    "xcolo_${context}_mtree_secondary_zero_pci_alias_count=${secondary_zero_pci_alias_count}" \
    "xcolo_assert_candidate_device=$(ftctl_xcolo_compact_log_value "${candidate_device}")" \
    "xcolo_assert_candidate_region=$(ftctl_xcolo_compact_log_value "${candidate_region}")" \
    "xcolo_assert_candidate_reason=$(ftctl_xcolo_compact_log_value "${candidate_reason}")" \
    "xcolo_${context}_topology_gate_state=${gate_state}" \
    "xcolo_${context}_topology_gate_error=${gate_error}" \
    "xcolo_${context}_topology_gate_reason=$(ftctl_xcolo_compact_log_value "${gate_reason}")"
  return "${rc}"
}

ftctl_xcolo_require_pre_migrate_runtime_topology_gate() {
  local vm="${1-}"
  local secondary_vm="${2:-$vm}"
  local phase="${3:-before_migrate}"
  local gate_state="" gate_error="" gate_reason=""

  [[ -n "${vm}" && -n "${secondary_vm}" ]] || return 1
  [[ "${FTCTL_DRY_RUN}" != "1" ]] || return 0

  ftctl_xcolo_capture_live_runtime_topology_one "${vm}" "${FTCTL_PROFILE_PRIMARY_URI}" "${vm}" "primary" "${phase}" || true
  ftctl_xcolo_capture_live_runtime_topology_one "${vm}" "${FTCTL_PROFILE_SECONDARY_URI}" "${secondary_vm}" "secondary" "${phase}" || true
  ftctl_xcolo_analyze_runtime_topology_diff "${vm}" "${phase}" "pre_migrate" || true

  gate_state="$(ftctl_state_get "${vm}" "xcolo_pre_migrate_topology_gate_state" 2>/dev/null || true)"
  gate_error="$(ftctl_state_get "${vm}" "xcolo_pre_migrate_topology_gate_error" 2>/dev/null || true)"
  gate_reason="$(ftctl_state_get "${vm}" "xcolo_pre_migrate_topology_gate_reason" 2>/dev/null || true)"
  if [[ "${gate_state}" == "failed" ]]; then
    [[ -n "${gate_error}" ]] || gate_error="xcolo_pre_migrate_topology_incomplete"
    ftctl_state_set "${vm}" \
      "conversion_stage=pre_migrate_topology_analysis_failed" \
      "conversion_state=error" \
      "protection_state=error" \
      "transport_state=failed" \
      "xcolo_protocol_failure_phase=pre_migrate_topology_analysis" \
      "xcolo_last_runtime_error=${gate_error}" \
      "last_error=${gate_error}"
    ftctl_log_event "colo" "xcolo.pre_migrate_topology_gate" "fail" "${vm}" "" \
      "secondary=${secondary_vm} reason=$(ftctl_xcolo_compact_log_value "${gate_reason}") error=${gate_error}"
    return 1
  fi

  if [[ "${gate_state}" == "deferred" ]]; then
    [[ -n "${gate_error}" ]] || gate_error="xcolo_pre_migrate_topology_deferred"
    ftctl_state_set "${vm}" \
      "conversion_stage=pre_migrate_topology_analysis_failed" \
      "conversion_state=error" \
      "protection_state=error" \
      "transport_state=failed" \
      "xcolo_protocol_failure_phase=pre_migrate_topology_analysis" \
      "xcolo_pre_migrate_topology_gate_state=failed" \
      "xcolo_pre_migrate_topology_deferred=no" \
      "xcolo_pre_migrate_topology_deferred_reason=$(ftctl_xcolo_compact_log_value "${gate_reason}")" \
      "xcolo_pre_migrate_topology_deferred_error=${gate_error}" \
      "xcolo_last_runtime_error=${gate_error}" \
      "last_error=${gate_error}"
    ftctl_log_event "colo" "xcolo.pre_migrate_topology_gate" "fail" "${vm}" "" \
      "secondary=${secondary_vm} reason=$(ftctl_xcolo_compact_log_value "${gate_reason}") error=${gate_error}"
    return 1
  fi

  ftctl_state_set "${vm}" \
    "xcolo_protocol_failure_phase=" \
    "xcolo_pre_migrate_topology_gate_state=ok"
  ftctl_log_event "colo" "xcolo.pre_migrate_topology_gate" "ok" "${vm}" "" \
    "secondary=${secondary_vm} pci_diff=$(ftctl_state_get "${vm}" "xcolo_pre_migrate_pci_diff_count" 2>/dev/null || true) qtree_diff=$(ftctl_state_get "${vm}" "xcolo_pre_migrate_qtree_diff_count" 2>/dev/null || true) mtree_diff=$(ftctl_state_get "${vm}" "xcolo_pre_migrate_mtree_diff_count" 2>/dev/null || true)"
}

ftctl_xcolo_require_secondary_startup_materialization_gate() {
  local vm="${1-}"
  local secondary_vm="${2-}"
  local phase="${3:-secondary_startup_materialization}"
  local materialization_layer materialization_path materialization_reason topology_error

  [[ -n "${vm}" && -n "${secondary_vm}" ]] || return 1
  if ftctl_xcolo_verify_live_runtime_topology_pair "${vm}" "${secondary_vm}" "${phase}"; then
    ftctl_state_set "${vm}" \
      "xcolo_secondary_startup_materialization=ok" \
      "xcolo_secondary_startup_materialization_phase=${phase}"
    ftctl_log_event "colo" "xcolo.secondary_startup_materialization" "ok" "${vm}" "" \
      "secondary=${secondary_vm}"
    return 0
  fi

  topology_error="$(ftctl_state_get "${vm}" "last_error" 2>/dev/null || true)"
  materialization_layer="$(ftctl_state_get "${vm}" "xcolo_materialization_failure_layer" 2>/dev/null || true)"
  materialization_path="$(ftctl_state_get "${vm}" "xcolo_materialization_first_missing_path" 2>/dev/null || true)"
  materialization_reason="$(ftctl_state_get "${vm}" "xcolo_materialization_first_reason" 2>/dev/null || true)"
  [[ -n "${topology_error}" ]] || topology_error="xcolo_secondary_startup_pci_unmaterialized"
  case "${topology_error}" in
    xcolo_live_runtime_topology_mismatch|xcolo_secondary_pci_resource_unmaterialized_before_migrate|xcolo_live_pci_identity_unmaterialized|xcolo_pre_migrate_secondary_pci_resource_unmaterialized)
      topology_error="xcolo_pre_migrate_secondary_pci_resource_unmaterialized"
      ;;
  esac
  ftctl_state_set "${vm}" \
    "xcolo_secondary_startup_materialization=failed" \
    "xcolo_secondary_startup_materialization_phase=${phase}" \
    "xcolo_secondary_startup_materialization_error=${topology_error}" \
    "xcolo_secondary_startup_materialization_layer=${materialization_layer}" \
    "xcolo_secondary_startup_materialization_path=$(ftctl_xcolo_compact_log_value "${materialization_path}")" \
    "xcolo_secondary_startup_materialization_reason=$(ftctl_xcolo_compact_log_value "${materialization_reason}")" \
    "xcolo_secondary_startup_deferred_pci=no" \
    "xcolo_protocol_failure_phase=secondary_startup_materialization" \
    "last_error=${topology_error}"
  ftctl_log_event "colo" "xcolo.secondary_startup_materialization" "fail" "${vm}" "" \
    "secondary=${secondary_vm} error=${topology_error} layer=${materialization_layer} path=$(ftctl_xcolo_compact_log_value "${materialization_path}") reason=$(ftctl_xcolo_compact_log_value "${materialization_reason}")"
  return 1
}

ftctl_xcolo_require_post_migrate_materialization_gate() {
  local vm="${1-}"
  local secondary_vm="${2:-$vm}"
  local phase="${3:-after_migrate_materialization}"
  local gate_state="" gate_error="" gate_reason=""
  local materialization_state="" materialization_layer="" materialization_path="" materialization_reason=""

  [[ -n "${vm}" && -n "${secondary_vm}" ]] || return 1
  [[ "${FTCTL_DRY_RUN}" != "1" ]] || return 0

  ftctl_xcolo_capture_live_runtime_topology_one "${vm}" "${FTCTL_PROFILE_PRIMARY_URI}" "${vm}" "primary" "${phase}" || true
  ftctl_xcolo_capture_live_runtime_topology_one "${vm}" "${FTCTL_PROFILE_SECONDARY_URI}" "${secondary_vm}" "secondary" "${phase}" || true
  ftctl_xcolo_capture_qemu_proc_args_pair "${vm}" "${secondary_vm}" "${phase}" _ftctl_xcolo_post_primary_argv _ftctl_xcolo_post_secondary_argv || true
  ftctl_xcolo_analyze_materialization_pipeline "${vm}" "${phase}" "post_migrate_materialization" || true
  materialization_state="$(ftctl_state_get "${vm}" "xcolo_materialization_pipeline" 2>/dev/null || true)"
  materialization_layer="$(ftctl_state_get "${vm}" "xcolo_materialization_failure_layer" 2>/dev/null || true)"
  materialization_path="$(ftctl_state_get "${vm}" "xcolo_materialization_first_missing_path" 2>/dev/null || true)"
  materialization_reason="$(ftctl_state_get "${vm}" "xcolo_materialization_first_reason" 2>/dev/null || true)"
  if [[ "${materialization_state}" == "failed" \
    && ( "${materialization_layer}" == "qtree_parent_missing" \
      || "${materialization_layer}" == "pci_missing" \
      || "${materialization_layer}" == "pci_unassigned" \
      || "${materialization_layer}" == "mtree_unmapped" ) ]]; then
    gate_error="xcolo_post_migrate_pci_materialization_failed"
    ftctl_state_set "${vm}" \
      "conversion_stage=post_migrate_materialization_failed" \
      "conversion_state=error" \
      "protection_state=error" \
      "transport_state=failed" \
      "xcolo_protocol_failure_phase=post_migrate_materialization" \
      "xcolo_last_runtime_error=${gate_error}" \
      "xcolo_post_migrate_materialization_gate_state=failed" \
      "xcolo_post_migrate_materialization_gate_error=${gate_error}" \
      "xcolo_post_migrate_materialization_gate_reason=$(ftctl_xcolo_compact_log_value "${materialization_reason}")" \
      "last_error=${gate_error}"
    ftctl_log_event "colo" "xcolo.post_migrate_materialization_gate" "fail" "${vm}" "" \
      "secondary=${secondary_vm} layer=${materialization_layer} path=$(ftctl_xcolo_compact_log_value "${materialization_path}") error=${gate_error}"
    return 1
  fi
  ftctl_xcolo_analyze_runtime_topology_diff "${vm}" "${phase}" "post_migrate_materialization" || true

  gate_state="$(ftctl_state_get "${vm}" "xcolo_post_migrate_materialization_topology_gate_state" 2>/dev/null || true)"
  gate_error="$(ftctl_state_get "${vm}" "xcolo_post_migrate_materialization_topology_gate_error" 2>/dev/null || true)"
  gate_reason="$(ftctl_state_get "${vm}" "xcolo_post_migrate_materialization_topology_gate_reason" 2>/dev/null || true)"
  if [[ "${gate_state}" == "failed" ]]; then
    [[ -n "${gate_error}" ]] || gate_error="xcolo_post_migrate_topology_incomplete"
    ftctl_state_set "${vm}" \
      "conversion_stage=post_migrate_materialization_failed" \
      "conversion_state=error" \
      "protection_state=error" \
      "transport_state=failed" \
      "xcolo_protocol_failure_phase=post_migrate_materialization" \
      "xcolo_last_runtime_error=${gate_error}" \
      "last_error=${gate_error}"
    ftctl_log_event "colo" "xcolo.post_migrate_materialization_gate" "fail" "${vm}" "" \
      "secondary=${secondary_vm} reason=$(ftctl_xcolo_compact_log_value "${gate_reason}") error=${gate_error}"
    return 1
  fi

  ftctl_state_set "${vm}" \
    "xcolo_post_migrate_materialization_gate_state=ok" \
    "xcolo_post_migrate_materialization_gate_reason=$(ftctl_xcolo_compact_log_value "${gate_reason}")"
  ftctl_log_event "colo" "xcolo.post_migrate_materialization_gate" "ok" "${vm}" "" \
    "secondary=${secondary_vm} pci_diff=$(ftctl_state_get "${vm}" "xcolo_post_migrate_materialization_pci_diff_count" 2>/dev/null || true) qtree_diff=$(ftctl_state_get "${vm}" "xcolo_post_migrate_materialization_qtree_diff_count" 2>/dev/null || true) mtree_diff=$(ftctl_state_get "${vm}" "xcolo_post_migrate_materialization_mtree_diff_count" 2>/dev/null || true)"
}

ftctl_xcolo_capture_post_migrate_secondary_failure_evidence() {
  local vm="${1-}"
  local secondary_vm="${2:-$vm}"
  local phase="${3:-post_migrate_secondary_crash}"
  local primary_argv="" secondary_argv="" summary="" debug_dir=""

  [[ -n "${vm}" && -n "${secondary_vm}" ]] || return 0
  [[ "${FTCTL_DRY_RUN}" != "1" ]] || return 0

  debug_dir="$(ftctl_xcolo_debug_dir "${vm}")"
  ftctl_state_set "${vm}" \
    "xcolo_post_migrate_failure_evidence_phase=${phase}" \
    "xcolo_debug_dir=${debug_dir}"

  ftctl_xcolo_collect_runtime_failure_diagnostics "${vm}" "${secondary_vm}" || true
  ftctl_xcolo_capture_socket_snapshot "${vm}" "${phase}" || true
  ftctl_xcolo_capture_failure_chardev_snapshot "${vm}" "${secondary_vm}" "${phase}" || true
  ftctl_xcolo_capture_policy_snapshot "${vm}" "${phase}" || true
  ftctl_xcolo_capture_live_runtime_topology_one "${vm}" "${FTCTL_PROFILE_PRIMARY_URI}" "${vm}" "primary" "${phase}" || true
  ftctl_xcolo_capture_live_runtime_topology_one "${vm}" "${FTCTL_PROFILE_SECONDARY_URI}" "${secondary_vm}" "secondary" "${phase}" || true
  ftctl_xcolo_capture_qemu_proc_args_pair "${vm}" "${secondary_vm}" "${phase}" primary_argv secondary_argv || true
  ftctl_xcolo_analyze_runtime_topology_diff "${vm}" "${phase}" "post_migrate_crash" || true

  summary="$(DEBUG_DIR="${debug_dir}" PHASE="${phase}" PRIMARY_ARGV="${primary_argv}" SECONDARY_ARGV="${secondary_argv}" python3 - <<'PY'
import hashlib
import os

debug_dir = os.environ.get("DEBUG_DIR", "")
phase = os.environ.get("PHASE", "")
primary_argv = os.environ.get("PRIMARY_ARGV", "")
secondary_argv = os.environ.get("SECONDARY_ARGV", "")

def file_digest(name):
    path = os.path.join(debug_dir, name)
    if not os.path.exists(path):
        return "missing"
    data = open(path, "rb").read()
    return f"size={len(data)} sha256={hashlib.sha256(data).hexdigest()}"

def first_matching_line(name, needles):
    path = os.path.join(debug_dir, name)
    if not os.path.exists(path):
        return ""
    with open(path, "r", encoding="utf-8", errors="replace") as handle:
        for line in handle:
            if any(needle in line for needle in needles):
                return line.strip()
    return ""

primary_devices = sum(1 for line in primary_argv.splitlines() if line == "-device")
secondary_devices = sum(1 for line in secondary_argv.splitlines() if line == "-device")
assertion = first_matching_line("secondary-qemu-log-tail.txt", [
    "memory_region_add_subregion_common",
    "subregion->container",
    "reason=crashed",
])

print(f"phase={phase}")
print(f"primary_argv_devices={primary_devices}")
print(f"secondary_argv_devices={secondary_devices}")
print(f"primary_argv={file_digest('primary-live-qemu-argv-' + phase + '.txt')}")
print(f"secondary_argv={file_digest('secondary-live-qemu-argv-' + phase + '.txt')}")
print(f"primary_pci={file_digest('primary-info-pci-' + phase + '.txt')}")
print(f"secondary_pci={file_digest('secondary-info-pci-' + phase + '.txt')}")
print(f"primary_qtree={file_digest('primary-info-qtree-' + phase + '.txt')}")
print(f"secondary_qtree={file_digest('secondary-info-qtree-' + phase + '.txt')}")
print(f"primary_mtree={file_digest('primary-info-mtree-' + phase + '.txt')}")
print(f"secondary_mtree={file_digest('secondary-info-mtree-' + phase + '.txt')}")
print(f"secondary_log_assertion={assertion or 'not_observed'}")
PY
)" || summary="phase=${phase}"$'\n'"summary=failed"
  ftctl_xcolo_write_debug_file "${vm}" "migration-abi-failure-summary-${phase}.txt" "${summary}" || true
  ftctl_state_set "${vm}" \
    "xcolo_post_migrate_failure_evidence_captured=yes" \
    "xcolo_post_migrate_crash_analyzed=$(ftctl_state_get "${vm}" "xcolo_post_migrate_crash_topology_analyzed" 2>/dev/null || printf no)" \
    "xcolo_post_migrate_pci_diff_count=$(ftctl_state_get "${vm}" "xcolo_post_migrate_crash_pci_diff_count" 2>/dev/null || true)" \
    "xcolo_post_migrate_qtree_diff_count=$(ftctl_state_get "${vm}" "xcolo_post_migrate_crash_qtree_diff_count" 2>/dev/null || true)" \
    "xcolo_post_migrate_mtree_diff_count=$(ftctl_state_get "${vm}" "xcolo_post_migrate_crash_mtree_diff_count" 2>/dev/null || true)"
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

ftctl_xcolo_primary_filter_mirror_send_errno_since_baseline() {
  local vm="${1-}"
  local baseline out="" err="" rc=0

  [[ -n "${vm}" ]] || return 1
  baseline="$(ftctl_state_get "${vm}" "xcolo_primary_qemu_log_baseline_lines" 2>/dev/null || true)"
  [[ "${baseline}" =~ ^[0-9]+$ ]] || baseline="0"
  # shellcheck disable=SC2016
  ftctl_cmd_run "${FTCTL_BLOCKCOPY_WAIT_TIMEOUT_SEC:-15}" out err rc -- \
    bash -c '
domain="$1"
baseline="$2"
line="$(awk -v b="${baseline}" "NR>b && /filter mirror send failed\\(/ { last=\\$0 } END { if (last != \"\") print last }" \
  "/var/log/libvirt/qemu/${domain}.log" 2>/dev/null || true)"
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
' _ "${vm}" "${baseline}" || true
  : "${err}"
  [[ "${rc}" == "0" && -n "${out}" ]] || return 1
  printf '%s\n' "${out%%$'\n'*}"
}

ftctl_xcolo_assert_no_premigrate_filter_mirror_send() {
  local vm="${1-}"
  local phase="${2:-pre_migrate}"
  local errno

  [[ -n "${vm}" ]] || return 1
  if errno="$(ftctl_xcolo_primary_filter_mirror_send_errno_since_baseline "${vm}")"; then
    ftctl_xcolo_capture_qemu_log_tails "${vm}" "$(ftctl_profile_secondary_vm_name_resolved "${vm}")" || true
    ftctl_state_set "${vm}" \
      "xcolo_premigrate_filter_mirror_send_failed=yes" \
      "xcolo_premigrate_filter_mirror_send_errno=${errno}" \
      "xcolo_premigrate_filter_mirror_send_phase=${phase}" \
      "xcolo_protocol_failure_phase=premigrate_filter_mirror_send" \
      "last_error=xcolo_filter_mirror_send_before_migrate"
    ftctl_log_event "colo" "xcolo.premigrate_filter_mirror_send" "fail" "${vm}" "" \
      "phase=${phase} errno=${errno} baseline=$(ftctl_state_get "${vm}" "xcolo_primary_qemu_log_baseline_lines" 2>/dev/null || true)"
    return 1
  fi

  ftctl_state_set "${vm}" \
    "xcolo_premigrate_filter_mirror_send_failed=no" \
    "xcolo_premigrate_filter_mirror_send_phase=${phase}"
  ftctl_log_event "colo" "xcolo.premigrate_filter_mirror_send" "ok" "${vm}" "" \
    "phase=${phase} baseline=$(ftctl_state_get "${vm}" "xcolo_primary_qemu_log_baseline_lines" 2>/dev/null || true)"
  return 0
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

ftctl_xcolo_capture_colo_chardev_contract() {
  local vm="${1-}"
  local secondary_vm="${2:-$vm}"
  local phase="${3:-runtime}"
  local primary_out="" primary_rc=0 secondary_out="" secondary_rc=0
  local payload="" phase_key="" state_args=()

  [[ -n "${vm}" && -n "${secondary_vm}" ]] || return 1
  phase_key="$(printf '%s' "${phase}" | tr -c 'A-Za-z0-9_' '_' | sed 's/_*$//')"
  [[ -n "${phase_key}" ]] || phase_key="runtime"

  ftctl_xcolo_qmp "${FTCTL_PROFILE_PRIMARY_URI}" "${vm}" '{"execute":"query-chardev"}' primary_out primary_rc
  ftctl_xcolo_qmp "${FTCTL_PROFILE_SECONDARY_URI}" "${secondary_vm}" '{"execute":"query-chardev"}' secondary_out secondary_rc
  ftctl_xcolo_write_debug_file "${vm}" "primary-query-chardev-contract-${phase}.json" "${primary_out}" || true
  ftctl_xcolo_write_debug_file "${vm}" "secondary-query-chardev-contract-${phase}.json" "${secondary_out}" || true

  payload="$(python3 - "${primary_out}" "${secondary_out}" "${primary_rc}" "${secondary_rc}" <<'PY'
import json
import sys

primary_raw = sys.argv[1] if len(sys.argv) > 1 else ""
secondary_raw = sys.argv[2] if len(sys.argv) > 2 else ""
primary_rc = sys.argv[3] if len(sys.argv) > 3 else "1"
secondary_rc = sys.argv[4] if len(sys.argv) > 4 else "1"

if primary_rc == "0" and secondary_rc == "0":
    query_state = "ok"
elif primary_rc != "0" and secondary_rc != "0":
    query_state = "both_query_failed"
elif primary_rc != "0":
    query_state = "primary_query_failed"
else:
    query_state = "secondary_query_failed"
query_transient = "yes" if query_state != "ok" else "no"

def entry(raw, label):
    try:
        data = json.loads(raw)
    except Exception:
        return {"state": "unknown", "backend": "unknown"}
    for item in data.get("return", []):
        if item.get("label") != label:
            continue
        opened = item.get("frontend-open")
        filename = item.get("filename") or ""
        if opened is True:
            state = "present_open"
        elif opened is False:
            state = "present_closed"
        else:
            state = "present_unknown"
        if "<->" in filename and not filename.startswith("disconnected:"):
            backend = "connected"
        elif filename.startswith("disconnected:"):
            backend = "disconnected"
        elif filename:
            backend = "present"
        else:
            backend = "unknown"
        return {"state": state, "backend": backend}
    return {"state": "missing", "backend": "missing"}

def state(raw, label):
    return entry(raw, label)["state"]

def backend(raw, label):
    return entry(raw, label)["backend"]

def input_frontend_ok(value):
    return value == "present_open"

def output_backend_ok(state_value, backend_value):
    return state_value in ("present_open", "present_closed") and backend_value == "connected"

def output_desc(state_value, backend_value):
    return f"{state_value}/{backend_value}"

primary_mirror0 = state(primary_raw, "mirror0") if primary_rc == "0" else "query_failed"
primary_mirror0_backend = backend(primary_raw, "mirror0") if primary_rc == "0" else "query_failed"
primary_compare1 = state(primary_raw, "compare1") if primary_rc == "0" else "query_failed"
primary_compare1_backend = backend(primary_raw, "compare1") if primary_rc == "0" else "query_failed"
secondary_red0 = state(secondary_raw, "red0") if secondary_rc == "0" else "query_failed"
secondary_red0_backend = backend(secondary_raw, "red0") if secondary_rc == "0" else "query_failed"
secondary_red1 = state(secondary_raw, "red1") if secondary_rc == "0" else "query_failed"
secondary_red1_backend = backend(secondary_raw, "red1") if secondary_rc == "0" else "query_failed"

checks = []
if not output_backend_ok(primary_mirror0, primary_mirror0_backend):
    checks.append(("mirror_path_primary_mirror0", output_desc(primary_mirror0, primary_mirror0_backend)))
if not input_frontend_ok(secondary_red0):
    checks.append(("mirror_path_secondary_red0", secondary_red0))
if not output_backend_ok(secondary_red1, secondary_red1_backend):
    checks.append(("compare_path_secondary_red1", output_desc(secondary_red1, secondary_red1_backend)))
if not input_frontend_ok(primary_compare1):
    checks.append(("compare_path_primary_compare1", primary_compare1))

reasons = [f"{name}={value}" for name, value in checks]
ready = "yes" if not reasons else "no"
if primary_rc != "0" or secondary_rc != "0":
    ready = "unknown" if not reasons else "no"

strict_checks = [
    ("mirror_path_primary_mirror0", primary_mirror0),
    ("mirror_path_secondary_red0", secondary_red0),
    ("compare_path_primary_compare1", primary_compare1),
    ("compare_path_secondary_red1", secondary_red1),
]
strict_reasons = [f"{name}={value}" for name, value in strict_checks if value != "present_open"]
strict_ready = "yes" if not strict_reasons else "no"
if primary_rc != "0" or secondary_rc != "0":
    strict_ready = "unknown" if not strict_reasons else "no"

print(f"ready={ready}")
print(f"directional_ready={ready}")
print(f"strict_frontend_ready={strict_ready}")
print(f"query_state={query_state}")
print(f"query_transient={query_transient}")
print("reason=" + ",".join(reasons))
print("strict_frontend_reason=" + ",".join(strict_reasons))
print("output_frontend_policy=backend_connected")
print(f"primary_mirror0={primary_mirror0}")
print(f"primary_mirror0_backend={primary_mirror0_backend}")
print(f"primary_compare1={primary_compare1}")
print(f"primary_compare1_backend={primary_compare1_backend}")
print(f"secondary_red0={secondary_red0}")
print(f"secondary_red0_backend={secondary_red0_backend}")
print(f"secondary_red1={secondary_red1}")
print(f"secondary_red1_backend={secondary_red1_backend}")
print(f"mirror_path=primary:m0->mirror0({primary_mirror0}/{primary_mirror0_backend})->secondary:red0({secondary_red0}/{secondary_red0_backend})->f1")
print(f"compare_path=secondary:f2->red1({secondary_red1}/{secondary_red1_backend})->primary:compare1({primary_compare1}/{primary_compare1_backend})->comp0")
PY
)" || payload="ready=unknown"$'\n'"reason=query_chardev_contract_parse_failed"

  state_args+=(
    "xcolo_chardev_contract_phase=${phase}"
    "xcolo_chardev_contract_primary_rc=${primary_rc}"
    "xcolo_chardev_contract_secondary_rc=${secondary_rc}"
  )
  while IFS= read -r line; do
    [[ -n "${line}" ]] || continue
    case "${line}" in
      ready=*)
        state_args+=("xcolo_chardev_contract_ready=${line#ready=}")
        state_args+=("xcolo_${phase_key}_chardev_contract_ready=${line#ready=}")
        ;;
      directional_ready=*)
        state_args+=("xcolo_chardev_contract_directional_ready=${line#directional_ready=}")
        state_args+=("xcolo_${phase_key}_chardev_contract_directional_ready=${line#directional_ready=}")
        ;;
      strict_frontend_ready=*)
        state_args+=("xcolo_chardev_contract_strict_frontend_ready=${line#strict_frontend_ready=}")
        state_args+=("xcolo_${phase_key}_chardev_contract_strict_frontend_ready=${line#strict_frontend_ready=}")
        ;;
      reason=*)
        state_args+=("xcolo_chardev_contract_reason=${line#reason=}")
        state_args+=("xcolo_${phase_key}_chardev_contract_reason=${line#reason=}")
        ;;
      strict_frontend_reason=*)
        state_args+=("xcolo_chardev_contract_strict_frontend_reason=${line#strict_frontend_reason=}")
        state_args+=("xcolo_${phase_key}_chardev_contract_strict_frontend_reason=${line#strict_frontend_reason=}")
        ;;
      mirror_path=*)
        state_args+=("xcolo_chardev_contract_mirror_path=${line#mirror_path=}")
        state_args+=("xcolo_${phase_key}_chardev_contract_mirror_path=${line#mirror_path=}")
        ;;
      compare_path=*)
        state_args+=("xcolo_chardev_contract_compare_path=${line#compare_path=}")
        state_args+=("xcolo_${phase_key}_chardev_contract_compare_path=${line#compare_path=}")
        ;;
      *=*)
        state_args+=("xcolo_chardev_contract_${line}")
        state_args+=("xcolo_${phase_key}_chardev_contract_${line}")
        ;;
    esac
  done <<< "${payload}"
  ftctl_state_set "${vm}" "${state_args[@]}"

  if [[ "$(ftctl_state_get "${vm}" "xcolo_chardev_contract_ready" 2>/dev/null || true)" == "yes" ]]; then
    ftctl_log_event "colo" "xcolo.chardev_contract" "ok" "${vm}" "" \
      "phase=${phase} policy=directional_backend_connected strict_frontend=$(ftctl_state_get "${vm}" "xcolo_chardev_contract_strict_frontend_ready" 2>/dev/null || true) mirror=$(ftctl_state_get "${vm}" "xcolo_chardev_contract_mirror_path" 2>/dev/null || true) compare=$(ftctl_state_get "${vm}" "xcolo_chardev_contract_compare_path" 2>/dev/null || true)"
    return 0
  fi

  ftctl_log_event "colo" "xcolo.chardev_contract" "fail" "${vm}" "" \
    "phase=${phase} policy=directional_backend_connected reason=$(ftctl_state_get "${vm}" "xcolo_chardev_contract_reason" 2>/dev/null || true) strict_frontend=$(ftctl_state_get "${vm}" "xcolo_chardev_contract_strict_frontend_ready" 2>/dev/null || true)"
  return 1
}

ftctl_xcolo_wait_colo_chardev_contract() {
  local vm="${1-}"
  local secondary_vm="${2:-$vm}"
  local phase="${3:-post_activation}"
  local timeout="${FTCTL_XCOLO_CHARDEV_CONTRACT_WAIT_SEC:-3}"
  local i

  [[ "${timeout}" =~ ^[0-9]+$ && "${timeout}" -gt 0 ]] || timeout="3"
  for ((i=0; i<timeout; i++)); do
    if ftctl_xcolo_capture_colo_chardev_contract "${vm}" "${secondary_vm}" "${phase}"; then
      ftctl_state_set "${vm}" \
        "xcolo_chardev_contract_gate=ready" \
        "xcolo_chardev_contract_gate_attempts=$((i + 1))"
      return 0
    fi
    sleep 1
  done

  ftctl_state_set "${vm}" \
    "xcolo_chardev_contract_gate=failed" \
    "xcolo_chardev_contract_gate_attempts=${timeout}" \
    "xcolo_chardev_contract_gate_reason=$(ftctl_state_get "${vm}" "xcolo_chardev_contract_reason" 2>/dev/null || true)"
  return 1
}

ftctl_xcolo_capture_guest_traffic_gate_state() {
  local vm="${1-}"
  local secondary_vm="${2:-$vm}"
  local phase="${3:-pre_guest_traffic_contract}"
  local phase_key primary_running="" primary_status="" secondary_running="" secondary_status=""

  [[ -n "${vm}" && -n "${secondary_vm}" ]] || return 0
  phase_key="$(printf '%s' "${phase}" | tr -c 'A-Za-z0-9_' '_' | sed 's/_*$//')"
  [[ -n "${phase_key}" ]] || phase_key="pre_guest_traffic_contract"

  ftctl_xcolo_query_running_flag "${FTCTL_PROFILE_PRIMARY_URI}" "${vm}" primary_running || true
  ftctl_xcolo_query_status_name "${FTCTL_PROFILE_PRIMARY_URI}" "${vm}" primary_status || true
  ftctl_xcolo_query_running_flag "${FTCTL_PROFILE_SECONDARY_URI}" "${secondary_vm}" secondary_running || true
  ftctl_xcolo_query_status_name "${FTCTL_PROFILE_SECONDARY_URI}" "${secondary_vm}" secondary_status || true
  ftctl_xcolo_capture_socket_snapshot "${vm}" "${phase}" || true
  ftctl_xcolo_capture_colo_chardev_contract "${vm}" "${secondary_vm}" "${phase}" || true

  ftctl_state_set "${vm}" \
    "xcolo_${phase_key}_primary_running=${primary_running}" \
    "xcolo_${phase_key}_primary_status=${primary_status}" \
    "xcolo_${phase_key}_secondary_running=${secondary_running}" \
    "xcolo_${phase_key}_secondary_status=${secondary_status}"
  ftctl_log_event "colo" "xcolo.guest_traffic_gate.snapshot" "ok" "${vm}" "" \
    "phase=${phase} primary_running=${primary_running} primary_status=${primary_status} secondary_running=${secondary_running} secondary_status=${secondary_status} chardev_contract=$(ftctl_state_get "${vm}" "xcolo_${phase_key}_chardev_contract_ready" 2>/dev/null || true)"
}

ftctl_xcolo_gate_before_guest_traffic() {
  local vm="${1-}"
  local secondary_vm="${2:-$vm}"
  local primary_running="" primary_status="" contract_ready="" contract_reason="" doc_topology=""
  local frontend_contract=""

  [[ -n "${vm}" && -n "${secondary_vm}" ]] || return 1
  ftctl_xcolo_capture_guest_traffic_gate_state "${vm}" "${secondary_vm}" "pre_guest_traffic_contract" || true

  primary_running="$(ftctl_state_get "${vm}" "xcolo_pre_guest_traffic_contract_primary_running" 2>/dev/null || true)"
  primary_status="$(ftctl_state_get "${vm}" "xcolo_pre_guest_traffic_contract_primary_status" 2>/dev/null || true)"
  if [[ "${primary_running}" == "true" ]]; then
    ftctl_state_set "${vm}" \
      "xcolo_pre_guest_traffic_gate=failed" \
      "xcolo_pre_guest_traffic_gate_reason=primary_running_before_contract" \
      "xcolo_protocol_failure_phase=pre_guest_traffic_contract" \
      "last_error=xcolo_pre_guest_primary_not_paused"
    ftctl_log_event "colo" "xcolo.guest_traffic_gate" "fail" "${vm}" "" \
      "reason=primary_running_before_contract primary_status=${primary_status}"
    return 1
  fi

  contract_ready="$(ftctl_state_get "${vm}" "xcolo_pre_guest_traffic_contract_chardev_contract_ready" 2>/dev/null || true)"
  contract_reason="$(ftctl_state_get "${vm}" "xcolo_pre_guest_traffic_contract_chardev_contract_reason" 2>/dev/null || true)"
  [[ -n "${contract_ready}" ]] || contract_ready="$(ftctl_state_get "${vm}" "xcolo_chardev_contract_ready" 2>/dev/null || true)"
  [[ -n "${contract_reason}" ]] || contract_reason="$(ftctl_state_get "${vm}" "xcolo_chardev_contract_reason" 2>/dev/null || true)"
  doc_topology="$(ftctl_state_get "${vm}" "xcolo_qemu_doc_topology" 2>/dev/null || true)"

  frontend_contract="${contract_ready:-unknown}"
  if [[ "${contract_ready}" != "yes" ]]; then
    if [[ "${contract_reason}" == *"present_closed"* ]]; then
      frontend_contract="closed"
    fi
    ftctl_state_set "${vm}" \
      "xcolo_qemu_doc_runtime_frontend=${frontend_contract}" \
      "xcolo_qemu_doc_runtime_frontend_reason=${contract_reason}" \
      "xcolo_pre_guest_traffic_frontend_contract=${frontend_contract}" \
      "xcolo_pre_guest_traffic_frontend_contract_reason=${contract_reason}" \
      "xcolo_pre_guest_traffic_gate=failed" \
      "xcolo_pre_guest_traffic_gate_reason=${contract_reason}" \
      "xcolo_pre_guest_traffic_gate_primary_status=${primary_status}" \
      "xcolo_pre_guest_traffic_gate_policy=qemu_9_2_directional_chardev_contract" \
      "xcolo_pre_guest_traffic_chardev_contract=${contract_ready:-unknown}" \
      "xcolo_protocol_failure_phase=pre_guest_traffic_contract" \
      "last_error=xcolo_pre_migrate_frontend_not_open"
    ftctl_log_event "colo" "xcolo.guest_traffic_gate" "fail" "${vm}" "" \
      "phase=pre_guest_traffic policy=qemu_9_2_directional_chardev_contract frontend_contract=${frontend_contract} contract=${contract_ready:-unknown} reason=${contract_reason} primary_status=${primary_status} doc_topology=${doc_topology:-unknown}"
    return 1
  fi

  ftctl_state_set "${vm}" \
    "xcolo_pre_guest_traffic_gate=ready" \
    "xcolo_pre_guest_traffic_gate_reason=${contract_reason}" \
    "xcolo_pre_guest_traffic_gate_primary_status=${primary_status}" \
    "xcolo_pre_guest_traffic_gate_policy=qemu_9_2_directional_chardev_contract" \
    "xcolo_pre_guest_traffic_chardev_contract=${contract_ready:-unknown}"
  ftctl_log_event "colo" "xcolo.guest_traffic_gate" "ok" "${vm}" "" \
    "phase=pre_guest_traffic policy=qemu_9_2_directional_chardev_contract contract=${contract_ready:-unknown} strict_frontend=$(ftctl_state_get "${vm}" "xcolo_chardev_contract_strict_frontend_ready" 2>/dev/null || true) primary_status=${primary_status}"
  return 0
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
  ftctl_xcolo_capture_colo_chardev_contract "${vm}" "${secondary_vm}" "${phase}" || true
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
  local errno="" reason="colo_control_message_invalid_zero_header"
  local last_error="xcolo_colo_control_message_invalid"
  local failure_scope="post_migrate_colo_control"
  local failure_phase="post_migrate_colo_control"
  local cap_return_path

  [[ -n "${vm}" && -n "${secondary_vm}" ]] || return 0
  ftctl_xcolo_collect_runtime_failure_diagnostics "${vm}" "${secondary_vm}" || true
  ftctl_xcolo_capture_socket_snapshot "${vm}" "post_migrate_failure" || true
  ftctl_xcolo_capture_failure_chardev_snapshot "${vm}" "${secondary_vm}" "post-migrate-failure" || true
  ftctl_xcolo_capture_policy_snapshot "${vm}" "post-migrate-failure" || true
  cap_return_path="$(ftctl_xcolo_query_primary_qmp_diag_value "${vm}" "query-migrate-capabilities" "cap:return-path")"

  if errno="$(ftctl_xcolo_primary_filter_mirror_send_errno "${vm}")"; then
    reason="filter_mirror_send_failed"
    last_error="xcolo_filter_mirror_send_failed"
    failure_scope="post_migrate_filter_mirror_send"
    failure_phase="post_migrate_filter_mirror_send"
    if [[ "${errno}" == "eperm" ]]; then
      reason="filter_mirror_send_eperm"
      last_error="xcolo_filter_mirror_send_eperm"
    fi
    ftctl_state_set "${vm}" \
      "xcolo_filter_mirror_send_failed=yes" \
      "xcolo_filter_mirror_send_errno=${errno}" \
      "xcolo_filter_mirror_send_path=primary:m0->mirror0->secondary:red0" \
      "xcolo_filter_mirror_send_contract_ready=$(ftctl_state_get "${vm}" "xcolo_chardev_contract_ready" 2>/dev/null || true)" \
      "xcolo_filter_mirror_send_contract_reason=$(ftctl_state_get "${vm}" "xcolo_chardev_contract_reason" 2>/dev/null || true)" \
      "xcolo_filter_mirror_send_contract_mirror_path=$(ftctl_state_get "${vm}" "xcolo_chardev_contract_mirror_path" 2>/dev/null || true)" \
      "xcolo_filter_mirror_send_contract_compare_path=$(ftctl_state_get "${vm}" "xcolo_chardev_contract_compare_path" 2>/dev/null || true)"
  elif [[ "${cap_return_path}" == "yes" ]]; then
    reason="migration_return_path_enabled_for_colo"
    last_error="xcolo_migration_return_path_conflict"
  fi

  ftctl_state_set "${vm}" \
    "xcolo_repeated_protocol_invalid_message=yes" \
    "xcolo_protocol_invalid_message_reason=${reason}" \
    "xcolo_protocol_invalid_message_scope=${failure_scope}" \
    "xcolo_protocol_failure_phase=${failure_phase}" \
    "xcolo_protocol_steady_state_required=true" \
    "xcolo_protocol_expected_primary_role=primary" \
    "xcolo_protocol_expected_secondary_role=secondary" \
    "xcolo_primary_capability_return_path_at_failure=${cap_return_path}" \
    "last_error=${last_error}"

  ftctl_log_event "colo" "xcolo.startup_active_stream_failure" "fail" "${vm}" "" \
    "reason=${reason} errno=${errno:-none} return_path=${cap_return_path} path=primary:m0->mirror0->secondary:red0 contract=$(ftctl_state_get "${vm}" "xcolo_chardev_contract_ready" 2>/dev/null || true) contract_reason=$(ftctl_state_get "${vm}" "xcolo_chardev_contract_reason" 2>/dev/null || true)"
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
  local mirror_port compare_port compare_local_port compare_out_port mirror_wait compare_wait
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
  mirror_port="${FTCTL_XCOLO_MIRROR_PORT:-9003}"
  compare_port="${FTCTL_XCOLO_COMPARE_PORT:-9004}"
  compare_local_port="${FTCTL_XCOLO_COMPARE_LOCAL_PORT:-9001}"
  compare_out_port="${FTCTL_XCOLO_COMPARE_OUT_PORT:-9005}"
  mirror_wait="off"
  compare_wait="off"
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
  _ftctl_xcolo_expect_cmdline_token "socket,id=mirror0,host=0.0.0.0,port=${mirror_port},server=on,wait=${mirror_wait}" "doc_mirror0_listener"
  _ftctl_xcolo_expect_cmdline_token "socket,id=compare1,host=0.0.0.0,port=${compare_port},server=on,wait=${compare_wait}" "doc_compare1_listener"
  _ftctl_xcolo_expect_cmdline_token "socket,id=compare0,host=127.0.0.1,port=${compare_local_port},server=on,wait=off" "doc_compare0_loopback_server"
  _ftctl_xcolo_expect_cmdline_token "socket,id=compare0-0,host=127.0.0.1,port=${compare_local_port}" "doc_compare0_loopback_client"
  _ftctl_xcolo_expect_cmdline_token "socket,id=compare_out,host=127.0.0.1,port=${compare_out_port},server=on,wait=off" "doc_compare_out_loopback_server"
  _ftctl_xcolo_expect_cmdline_token "socket,id=compare_out0,host=127.0.0.1,port=${compare_out_port}" "doc_compare_out_loopback_client"
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
    "xcolo_primary_filter_cmdline_mirror_wait=${mirror_wait}" \
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
  local mirror_port compare_port
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
  mirror_port="${FTCTL_XCOLO_MIRROR_PORT:-9003}"
  compare_port="${FTCTL_XCOLO_COMPARE_PORT:-9004}"

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
  _ftctl_xcolo_expect_secondary_cmdline_token "port=${mirror_port},reconnect-ms=1000" "doc_red0_reconnect"
  _ftctl_xcolo_expect_secondary_cmdline_token "port=${compare_port},reconnect-ms=1000" "doc_red1_reconnect"
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

  if [[ "${primary_qom}" != "yes" ]]; then
    reasons+=("primary_qom:${primary_qom_reason:-unknown}")
  fi
  if [[ "${primary_cmd}" != "yes" ]]; then
    reasons+=("primary_cmdline:${primary_cmd_reason:-unknown}")
  fi
  if [[ "${secondary_cmd}" != "yes" ]]; then
    reasons+=("secondary_cmdline:${secondary_cmd_reason:-unknown}")
  fi

  reason_text="$(IFS=,; printf '%s' "${reasons[*]}")"
  if [[ "${#reasons[@]}" -eq 0 ]]; then
    ftctl_state_set "${vm}" \
      "xcolo_topology_audit=ok" \
      "xcolo_topology_audit_phase=${phase}" \
      "xcolo_topology_audit_reason=" \
      "xcolo_topology_primary_ready=yes" \
      "xcolo_topology_secondary_ready=yes" \
      "xcolo_qemu_doc_topology=ok" \
      "xcolo_qemu_doc_topology_phase=${phase}" \
      "xcolo_qemu_doc_topology_reason=" \
      "xcolo_qemu_doc_primary_qom_ready=${primary_qom}" \
      "xcolo_qemu_doc_primary_cmdline_ready=${primary_cmd}" \
      "xcolo_qemu_doc_secondary_cmdline_ready=${secondary_cmd}"
    ftctl_log_event "colo" "xcolo.topology_audit" "ok" "${vm}" "" \
      "phase=${phase} primary_qom=${primary_qom} primary_cmdline=${primary_cmd} secondary_cmdline=${secondary_cmd}"
    return 0
  fi

  ftctl_state_set "${vm}" \
    "xcolo_topology_audit=failed" \
    "xcolo_topology_audit_phase=${phase}" \
    "xcolo_topology_audit_reason=${reason_text}" \
    "xcolo_topology_primary_ready=$([[ "${primary_qom}" == "yes" && "${primary_cmd}" == "yes" ]] && printf yes || printf no)" \
    "xcolo_topology_secondary_ready=$([[ "${secondary_cmd}" == "yes" ]] && printf yes || printf no)" \
    "xcolo_qemu_doc_topology=failed" \
    "xcolo_qemu_doc_topology_phase=${phase}" \
    "xcolo_qemu_doc_topology_reason=${reason_text}" \
    "xcolo_qemu_doc_primary_qom_ready=${primary_qom}" \
    "xcolo_qemu_doc_primary_cmdline_ready=${primary_cmd}" \
    "xcolo_qemu_doc_secondary_cmdline_ready=${secondary_cmd}" \
    "last_error=xcolo_qemu_doc_topology_mismatch"
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
  local pre_chardev pre_filter_qom pre_filter_cmdline cap_return_path

  firewall_ready="$(ftctl_state_get "${vm}" "xcolo_firewall_ready" 2>/dev/null || true)"
  storage_symmetry="$(ftctl_state_get "${vm}" "xcolo_storage_symmetry" 2>/dev/null || true)"
  runtime_socket_captured="$(ftctl_state_get "${vm}" "xcolo_socket_runtime_captured" 2>/dev/null || true)"
  topology_audit="$(ftctl_state_get "${vm}" "xcolo_topology_audit" 2>/dev/null || true)"
  startup_primary_9998="$(ftctl_state_get "${vm}" "xcolo_socket_post_migrate_startup_active_validation_primary_9998" 2>/dev/null || true)"
  failure_primary_9998="$(ftctl_state_get "${vm}" "xcolo_socket_failure_primary_9998" 2>/dev/null || true)"
  pre_chardev="$(ftctl_state_get "${vm}" "xcolo_premigrate_primary_filter_chardev_ready" 2>/dev/null || true)"
  pre_filter_qom="$(ftctl_state_get "${vm}" "xcolo_premigrate_primary_filter_qom_ready" 2>/dev/null || true)"
  pre_filter_cmdline="$(ftctl_state_get "${vm}" "xcolo_premigrate_primary_filter_cmdline_ready" 2>/dev/null || true)"
  cap_return_path="$(ftctl_state_get "${vm}" "xcolo_primary_capability_return_path" 2>/dev/null || true)"

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
  elif [[ "${cap_return_path}" == "yes" ]]; then
    printf '%s\n' "migration_return_path_enabled_for_colo"
  elif [[ "${primary_migrate}" == "failed" &&
          ( "${secondary_migrate}" == "colo" || "${secondary_colo}" == "secondary" ) &&
          "${startup_primary_9998}" == "established" &&
          "${failure_primary_9998}" == "closed" ]]; then
    printf '%s\n' "colo_control_channel_closed_after_startup_active"
  elif [[ "${primary_migrate}" == "failed" &&
          "${secondary_migrate}" == "colo" &&
          "${primary_colo}" == "none" &&
          "${secondary_colo}" == "secondary" ]]; then
    printf '%s\n' "primary_role_not_entered_after_migrate"
  else
    printf '%s\n' "colo_control_message_invalid_zero_header"
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
  local primary_migrate_ok="no"
  local primary_qga="" secondary_qga="" qga_policy health_reason="" health_rc=0
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
    primary_migrate_ok="no"
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
    if ftctl_xcolo_primary_migrate_state_ok "${primary_migrate}"; then
      primary_migrate_ok="yes"
    else
      primary_migrate_ok="no"
    fi
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

    if [[ ( "${primary_migrate}" == "colo" ||
            "${primary_colo}" == "primary" || "${primary_status}" == "finish-migrate" ) &&
          ( -z "${secondary_migrate}" || -z "${secondary_status}" ) ]]; then
      ftctl_xcolo_capture_post_migrate_secondary_failure_evidence "${vm}" "${secondary_vm}" "post_migrate_secondary_crash" || true
      if ftctl_xcolo_secondary_qemu_assert_memory_region_container_observed "${vm}" "${secondary_vm}"; then
        reason="secondary_qemu_assert_memory_region_container"
      else
        reason="secondary_runtime_missing_after_migrate"
      fi
      ftctl_state_set "${vm}" \
        "xcolo_protocol_failure_phase=post_migrate_secondary_crash" \
        "xcolo_secondary_runtime_missing_after_migrate=yes" \
        "xcolo_secondary_runtime_missing_after_migrate_primary_migrate=${primary_migrate}" \
        "xcolo_secondary_runtime_missing_after_migrate_primary_colo=${primary_colo}" \
        "xcolo_secondary_runtime_missing_after_migrate_primary_status=${primary_status}" \
        "xcolo_secondary_runtime_missing_after_migrate_secondary_status=${secondary_status}" \
        "xcolo_secondary_runtime_missing_after_migrate_secondary_migrate=${secondary_migrate}"
      break
    fi

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
            "${primary_running}" == "true" &&
            "${secondary_running}" == "true" &&
            "${primary_migrate_ok}" == "yes" &&
            "${secondary_migrate}" == "colo" &&
            "${primary_colo}" == "primary" &&
            "${secondary_colo}" == "secondary" ]] &&
          ftctl_xcolo_runtime_primary_topology_ready "${primary_xml}" "${primary_filter_qom}" "${primary_filter_cmdline}" \
            "${channel_mirror}" "${channel_compare}" "${channel_compare_local}" "${channel_compare_out}" \
            "${disk_plan}" "${secondary_block_graph}" &&
          ftctl_xcolo_colo_mode_active "${primary_colo}" &&
          ftctl_xcolo_colo_mode_active "${secondary_colo}"; then
      health_reason=""
      if ! ftctl_xcolo_validate_primary_storage_health "${vm}" health_reason; then
        reason="${health_reason}"
        break
      fi
      health_reason=""
      health_rc=0
      ftctl_xcolo_validate_primary_guest_health "${vm}" "${primary_qga}" health_reason || health_rc=$?
      case "${health_rc}" in
        0)
          ;;
        10)
          pending_reason="${health_reason}"
          [[ -n "${pending_reason}" ]] || pending_reason="$(ftctl_state_get "${vm}" "xcolo_pending_reason" 2>/dev/null || true)"
          [[ -n "${pending_reason}" ]] || pending_reason="primary_guest_health_pending"
          pending_since="$(ftctl_state_get "${vm}" "xcolo_runtime_pending_since" 2>/dev/null || true)"
          [[ -n "${pending_since}" ]] || pending_since="$(ftctl_now_iso8601)"
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
            "reason=${pending_reason} primary_running=${primary_running} secondary_running=${secondary_running} primary_status=${primary_status} secondary_status=${secondary_status} primary_colo=${primary_colo} secondary_colo=${secondary_colo} primary_migrate=${primary_migrate} secondary_migrate=${secondary_migrate} primary_qga=${primary_qga} secondary_qga=${secondary_qga} primary_storage_health=$(ftctl_state_get "${vm}" "xcolo_primary_storage_health_gate" 2>/dev/null || true) primary_guest_health=$(ftctl_state_get "${vm}" "xcolo_primary_guest_health_gate" 2>/dev/null || true) filter_qom=${primary_filter_qom} filter_cmdline=${primary_filter_cmdline} chardev=${primary_chardev} mirror=${channel_mirror} compare=${channel_compare} compare_local=${channel_compare_local} compare_out=${channel_compare_out} secondary_block_graph=${secondary_block_graph} attempts=$((i + 1))"
          return 10
          ;;
        *)
          reason="${health_reason}"
          break
          ;;
      esac
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
        "reason=colo_role_active primary_running=${primary_running} secondary_running=${secondary_running} primary_status=${primary_status} secondary_status=${secondary_status} primary_colo=${primary_colo} secondary_colo=${secondary_colo} primary_migrate=${primary_migrate} secondary_migrate=${secondary_migrate} primary_qga=${primary_qga} secondary_qga=${secondary_qga} primary_storage_health=$(ftctl_state_get "${vm}" "xcolo_primary_storage_health_gate" 2>/dev/null || true) primary_guest_health=$(ftctl_state_get "${vm}" "xcolo_primary_guest_health_gate" 2>/dev/null || true) filter_qom=${primary_filter_qom} filter_cmdline=${primary_filter_cmdline} chardev=${primary_chardev} mirror=${channel_mirror} compare=${channel_compare} compare_local=${channel_compare_local} compare_out=${channel_compare_out} secondary_block_graph=${secondary_block_graph} attempts=$((i + 1))"
      return 0
    fi

    sleep 1
  done

  if [[ -z "${reason}" ]]; then
    if [[ "${primary_xml}" == "ok" &&
          "${secondary_xml}" == "ok" &&
          "${primary_migrate_ok}" == "yes" &&
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
          "${primary_migrate_ok}" == "yes" &&
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
    elif [[ "${primary_migrate_ok}" != "yes" ]]; then
      reason="primary_not_in_colo_migration"
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
    if [[ "${reason}" == xcolo_primary_storage_unhealthy:* ]]; then
      last_error_value="${reason}"
      protocol_reason="primary_storage_health_gate_failed"
    elif [[ "${reason}" == xcolo_primary_guest_boot_unhealthy:* ]]; then
      last_error_value="${reason}"
      protocol_reason="primary_guest_health_gate_failed"
    elif [[ "${reason}" == "repeated_protocol_invalid_message" ]]; then
      last_error_value="xcolo_repeated_protocol_invalid_message"
      protocol_reason="$(ftctl_state_get "${vm}" "xcolo_protocol_invalid_message_reason" 2>/dev/null || true)"
      [[ -n "${protocol_reason}" ]] || protocol_reason="qemu_colo_protocol_invalid_message"
    elif [[ "${reason}" == "secondary_qemu_assert_memory_region_container" ]]; then
      last_error_value="xcolo_secondary_qemu_assert_memory_region_container"
      protocol_reason="secondary_qemu_crashed_while_applying_migration_state"
      ftctl_state_set "${vm}" \
        "xcolo_protocol_failure_phase=post_migrate_secondary_crash" \
        "xcolo_secondary_qemu_assert=memory_region_add_subregion_common" \
        "xcolo_secondary_crash_detected=yes"
    elif [[ "${reason}" == "secondary_runtime_missing_after_migrate" ]]; then
      last_error_value="xcolo_secondary_runtime_missing_after_migrate"
      protocol_reason="secondary_runtime_disappeared_after_primary_migrate"
      ftctl_state_set "${vm}" \
        "xcolo_protocol_failure_phase=post_migrate_secondary_crash" \
        "xcolo_secondary_crash_detected=unknown"
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
    "xcolo_primary_safe_fail_recovery=restored_from_backup" \
    "xcolo_primary_safe_fail_recovery_cause=${reason}" \
    "cloud_runtime_restore_needs_reconcile=yes" \
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
  ftctl_xcolo_require_secondary_startup_materialization_gate "${vm}" "${vm}" "secondary_startup_materialization" || return 1
  ftctl_xcolo_secondary_accept_deferred_incoming "${vm}" "${vm}" "pre_migrate" || return 1
  ftctl_xcolo_require_pre_migrate_receiver_ready "${vm}" "${vm}" "pre_migrate_receiver" || return 1
  ftctl_xcolo_require_pre_migrate_runtime_topology_gate "${vm}" "${vm}" "before_migrate" || return 1
  ftctl_xcolo_record_pre_migrate_materialization_result "${vm}"
  ftctl_xcolo_gate_before_guest_traffic "${vm}" "${vm}" || return 1
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
  local mirror_port compare_port compare_local_port compare_out_port
  local mirror_wait compare_wait
  local vnet_hdr_arg=""

  [[ "${netdev_id}" =~ ^[A-Za-z0-9_.-]+$ ]] || netdev_id="hostnet0"
  if [[ -n "${vm}" ]]; then
    ftctl_xcolo_update_vnet_hdr_state "${vm}" || true
    vnet_hdr_arg="$(ftctl_xcolo_vnet_hdr_arg "${vm}")"
  fi
  mirror_port="${FTCTL_XCOLO_MIRROR_PORT:-9003}"
  compare_port="${FTCTL_XCOLO_COMPARE_PORT:-9004}"
  compare_local_port="${FTCTL_XCOLO_COMPARE_LOCAL_PORT:-9001}"
  compare_out_port="${FTCTL_XCOLO_COMPARE_OUT_PORT:-9005}"
  mirror_wait="off"
  compare_wait="off"

  # Keep the primary COLO network topology in the generated QEMU startup
  # commandline. External listeners must not block QEMU command-line parsing;
  # FTCTL gates listener readiness and red0/red1 attachment explicitly before
  # migration.
  printf '%s\n' "-S;-chardev;socket,id=compare1,host=0.0.0.0,port=${compare_port},server=on,wait=${compare_wait};-chardev;socket,id=compare0,host=127.0.0.1,port=${compare_local_port},server=on,wait=off;-chardev;socket,id=compare0-0,host=127.0.0.1,port=${compare_local_port};-chardev;socket,id=compare_out,host=127.0.0.1,port=${compare_out_port},server=on,wait=off;-chardev;socket,id=compare_out0,host=127.0.0.1,port=${compare_out_port};-chardev;socket,id=mirror0,host=0.0.0.0,port=${mirror_port},server=on,wait=${mirror_wait};-object;filter-mirror,id=m0,netdev=${netdev_id},queue=tx,outdev=mirror0,insert=behind,position=tail${vnet_hdr_arg};-object;filter-redirector,id=redire0,netdev=${netdev_id},queue=rx,indev=compare_out,insert=behind,position=tail${vnet_hdr_arg};-object;filter-redirector,id=redire1,netdev=${netdev_id},queue=rx,outdev=compare0,insert=behind,position=tail${vnet_hdr_arg};-object;colo-compare,id=comp0,primary_in=compare0-0,secondary_in=compare1,outdev=compare_out0,iothread=iothread1${vnet_hdr_arg}"
}

ftctl_xcolo_build_secondary_qemu_args() {
  local netdev_id="${1:-hostnet0}"
  local vm="${2:-${FTCTL_CURRENT_VM:-}}"
  local connect_ctrl connect_data
  local mirror_port compare_port
  local vnet_hdr_arg=""
  local incoming_mode="${FTCTL_XCOLO_SECONDARY_INCOMING_MODE:-defer}"

  [[ "${netdev_id}" =~ ^[A-Za-z0-9_.-]+$ ]] || netdev_id="hostnet0"
  if [[ -n "${vm}" ]]; then
    ftctl_xcolo_update_vnet_hdr_state "${vm}" || true
    vnet_hdr_arg="$(ftctl_xcolo_vnet_hdr_arg "${vm}")"
  fi
  connect_ctrl="$(ftctl_xcolo_primary_listen_host control)"
  connect_data="$(ftctl_xcolo_primary_listen_host data)"
  mirror_port="${FTCTL_XCOLO_MIRROR_PORT:-9003}"
  compare_port="${FTCTL_XCOLO_COMPARE_PORT:-9004}"
  case "${incoming_mode}" in
    defer) ;;
    direct|uri) incoming_mode="${FTCTL_PROFILE_XCOLO_MIGRATE_URI}" ;;
    tcp:*) ;;
    *) incoming_mode="defer" ;;
  esac

  # Match the QEMU COLO startup procedure but keep incoming migration deferred.
  # All devices are created at startup; QMP migrate-incoming starts the listener
  # only after FTCTL verifies that secondary PCI/mtree materialization is safe.
  printf '%s\n' "-chardev;socket,id=red0,host=${connect_ctrl},port=${mirror_port},reconnect-ms=1000;-chardev;socket,id=red1,host=${connect_data},port=${compare_port},reconnect-ms=1000;-object;filter-redirector,id=f1,netdev=${netdev_id},queue=tx,indev=red0${vnet_hdr_arg};-object;filter-redirector,id=f2,netdev=${netdev_id},queue=rx,outdev=red1${vnet_hdr_arg};-object;filter-rewriter,id=rew0,netdev=${netdev_id},queue=all${vnet_hdr_arg};-incoming;${incoming_mode}"
}

ftctl_xcolo_qemu_args_append() {
  local base="${1-}"
  local extra="${2-}"

  if [[ -z "${extra}" ]]; then
    printf '%s\n' "${base}"
  elif [[ -z "${base}" ]]; then
    printf '%s\n' "${extra}"
  else
    printf '%s\n' "${base};${extra}"
  fi
}

ftctl_xcolo_secondary_args_with_disk_graph() {
  local base="${1-}"
  local disk_args="${2-}"
  local incoming="defer"
  local prefix="${base}"

  if [[ "${base}" == *";-incoming;"* ]]; then
    prefix="${base%;-incoming;*}"
    incoming="${base##*;-incoming;}"
  fi
  [[ -n "${incoming}" ]] || incoming="defer"
  printf '%s\n' "$(ftctl_xcolo_qemu_args_append "$(ftctl_xcolo_qemu_args_append "${prefix}" "${disk_args}")" "-incoming;${incoming}")"
}

ftctl_xcolo_xml_remove_disk_targets() {
  local xml_path="${1-}"
  local disk_plan="${2-}"

  command -v python3 >/dev/null 2>&1 || {
    echo "ERROR: python3 is required for x-colo disk XML rewrite" >&2
    return 2
  }

  XML_PATH="${xml_path}" DISK_PLAN="${disk_plan}" python3 - <<'PY'
import os
import xml.etree.ElementTree as ET

xml_path = os.environ["XML_PATH"]
plan = os.environ.get("DISK_PLAN", "")
targets = {entry.split("|", 1)[0] for entry in plan.split(";") if entry}
if not targets:
    raise SystemExit(0)

tree = ET.parse(xml_path)
root = tree.getroot()
devices = root.find("devices")
if devices is None:
    raise SystemExit("missing <devices> in xml")

protected_controllers = set()
removed = 0
for disk in list(devices.findall("disk")):
    if disk.get("device") != "disk":
        continue
    target = disk.find("target")
    if target is not None and target.get("dev") in targets:
        address = disk.find("address")
        if target.get("bus") == "scsi" and address is not None and address.get("type") == "drive":
            protected_controllers.add(address.get("controller") or "0")
        devices.remove(disk)
        removed += 1

if removed != len(targets):
    raise SystemExit(f"removed {removed} disk devices, expected {len(targets)}")

remaining_scsi_controllers = set()
for disk in devices.findall("disk"):
    if disk.get("device") != "disk":
        continue
    target = disk.find("target")
    address = disk.find("address")
    if target is None or target.get("bus") != "scsi":
        continue
    if address is None or address.get("type") != "drive":
        continue
    remaining_scsi_controllers.add(address.get("controller") or "0")

for controller in list(devices.findall("controller")):
    if controller.get("type") != "scsi":
        continue
    index = controller.get("index") or "0"
    if index in protected_controllers and index not in remaining_scsi_controllers:
        devices.remove(controller)

tree.write(xml_path, encoding="unicode")
PY
}

ftctl_xcolo_clone_primary_xml_for_secondary() {
  local primary_xml="${1-}"
  local secondary_xml="${2-}"
  local secondary_name="${3-}"

  command -v python3 >/dev/null 2>&1 || {
    echo "ERROR: python3 is required for x-colo secondary XML clone" >&2
    return 2
  }

  [[ -n "${primary_xml}" && -f "${primary_xml}" && -n "${secondary_xml}" && -n "${secondary_name}" ]] || return 1

  PRIMARY_XML="${primary_xml}" SECONDARY_XML="${secondary_xml}" SECONDARY_NAME="${secondary_name}" python3 - <<'PY'
import os
import xml.etree.ElementTree as ET

primary_xml = os.environ["PRIMARY_XML"]
secondary_xml = os.environ["SECONDARY_XML"]
secondary_name = os.environ["SECONDARY_NAME"]

tree = ET.parse(primary_xml)
root = tree.getroot()

name = root.find("name")
if name is None:
    name = ET.Element("name")
    root.insert(0, name)
name.text = secondary_name

# Keep the primary UUID and guest-visible device identity.  The secondary FT
# runtime is a migration target, not an independently shaped VM.  Because it is
# created on a different libvirt host, the duplicated UUID is intentional and
# matches the live-migration/COLO ABI contract.
for child in list(root):
    if child.tag == "id":
        root.remove(child)

tree.write(secondary_xml, encoding="unicode")
PY
}

ftctl_xcolo_disk_qdev_from_xml() {
  local xml_path="${1-}"
  local target="${2-}"
  local out_var="${3}"
  local payload

  [[ -f "${xml_path}" && -n "${target}" ]] || return 1
  command -v python3 >/dev/null 2>&1 || return 2

  payload="$(XML_PATH="${xml_path}" TARGET="${target}" python3 - <<'PY'
import os
import xml.etree.ElementTree as ET

xml_path = os.environ["XML_PATH"]
target_name = os.environ["TARGET"]

root = ET.parse(xml_path).getroot()
devices = root.find("devices")
if devices is None:
    raise SystemExit("missing_devices")

for disk in devices.findall("disk"):
    if disk.get("device") != "disk":
        continue
    target = disk.find("target")
    if target is None or target.get("dev") != target_name:
        continue
    alias = disk.find("alias")
    if alias is not None and alias.get("name"):
        print(alias.get("name"))
        raise SystemExit(0)
    if (target.get("bus") or "") != "scsi":
        raise SystemExit(f"unsupported_bus:{target.get('bus') or 'missing'}")
    address = disk.find("address")
    if address is None or address.get("type") != "drive":
        raise SystemExit("missing_drive_address")
    controller = address.get("controller") or "0"
    bus = address.get("bus") or "0"
    scsi_id = address.get("target") or "0"
    lun = address.get("unit") or "0"
    print(f"scsi{controller}-{bus}-{scsi_id}-{lun}")
    raise SystemExit(0)

raise SystemExit("disk_target_not_found")
PY
)" || return 1

  printf -v "${out_var}" '%s' "${payload}"
}

ftctl_xcolo_validate_startup_disk_topology_xml() {
  local vm="${1-}"
  local xml_path="${2-}"
  local disk_runtime="${3-}"
  local role="${4:-unknown}"
  local out="" rc=0

  [[ -n "${vm}" && -f "${xml_path}" && -n "${disk_runtime}" ]] || return 1

  out="$(XML_PATH="${xml_path}" DISK_RUNTIME="${disk_runtime}" python3 - <<'PY'
import os
import re
import xml.etree.ElementTree as ET

xml_path = os.environ["XML_PATH"]
runtime = os.environ.get("DISK_RUNTIME", "")
targets = [entry.split("|", 1)[0] for entry in runtime.split(";") if entry]

root = ET.parse(xml_path).getroot()
devices = root.find("devices")
if devices is None:
    print("missing_devices")
    raise SystemExit(1)

errors = []
for target_name in targets:
    disk = None
    for candidate in devices.findall("disk"):
        if candidate.get("device") != "disk":
            continue
        target = candidate.find("target")
        if target is not None and target.get("dev") == target_name:
            disk = candidate
            break
    if disk is None:
        errors.append(f"{target_name}:disk_missing")
        continue
    target = disk.find("target")
    if target is None or target.get("bus") != "scsi":
        errors.append(f"{target_name}:target_not_scsi")
    alias = disk.find("alias")
    qdev_id = alias.get("name") if alias is not None else ""
    address = disk.find("address")
    if address is None or address.get("type") != "drive":
        errors.append(f"{target_name}:drive_address_missing")
    else:
        controller = address.get("controller") or "0"
        bus = address.get("bus") or "0"
        scsi_id = address.get("target") or "0"
        lun = address.get("unit") or "0"
        expected = f"scsi{controller}-{bus}-{scsi_id}-{lun}"
        if qdev_id and qdev_id != expected and not re.fullmatch(r"scsi[0-9]+-[0-9]+-[0-9]+-[0-9]+", qdev_id):
            errors.append(f"{target_name}:alias_not_scsi_topology:{qdev_id}")
        elif not qdev_id:
            qdev_id = expected
    if qdev_id and not re.fullmatch(r"scsi[0-9]+-[0-9]+-[0-9]+-[0-9]+", qdev_id):
        errors.append(f"{target_name}:qdev_not_scsi_topology:{qdev_id}")

if errors:
    print(",".join(errors))
    raise SystemExit(1)

print("ok")
PY
)" || rc=$?

  if [[ "${rc}" != "0" ]]; then
    ftctl_state_set "${vm}" \
      "xcolo_protocol_failure_phase=startup_disk_graph" \
      "last_error=xcolo_startup_disk_topology_missing"
    ftctl_log_event "colo" "xcolo.startup_disk_topology" "fail" "${vm}" "" \
      "role=${role} path=${xml_path} reason=${out}"
    return 1
  fi

  ftctl_log_event "colo" "xcolo.startup_disk_topology" "ok" "${vm}" "" \
    "role=${role} path=${xml_path}"
}

ftctl_xcolo_build_startup_disk_args() {
  local xml_path="${1-}"
  local role="${2-}"
  local disk_runtime="${3-}"
  local out_var="${4}"
  local reference_qemu_log="${5-}"
  local primary_parent_nbd_map="${6-}"
  local payload

  command -v python3 >/dev/null 2>&1 || {
    echo "ERROR: python3 is required for x-colo disk commandline generation" >&2
    return 2
  }

  payload="$(XML_PATH="${xml_path}" ROLE="${role}" DISK_RUNTIME="${disk_runtime}" REFERENCE_QEMU_LOG="${reference_qemu_log}" XCOLO_RBD_COMMANDLINE_BACKEND="${FTCTL_XCOLO_RBD_COMMANDLINE_BACKEND:-librbd}" XCOLO_PRIMARY_PARENT_NBD_MAP="${primary_parent_nbd_map}" python3 - <<'PY'
import json
import os
import re
import shlex
import sys
import xml.etree.ElementTree as ET

xml_path = os.environ["XML_PATH"]
role = os.environ["ROLE"]
runtime_raw = os.environ.get("DISK_RUNTIME", "")
reference_qemu_log = os.environ.get("REFERENCE_QEMU_LOG", "")
rbd_commandline_backend = (os.environ.get("XCOLO_RBD_COMMANDLINE_BACKEND") or "librbd").strip().lower()
if rbd_commandline_backend not in {"librbd", "krbd"}:
    raise SystemExit(f"unsupported x-colo RBD commandline backend: {rbd_commandline_backend}")
primary_parent_nbd_map = {}
for raw_entry in (os.environ.get("XCOLO_PRIMARY_PARENT_NBD_MAP") or "").split(";"):
    if not raw_entry:
        continue
    parts = raw_entry.split("|", 2)
    if len(parts) != 3:
        raise SystemExit(f"invalid x-colo primary parent nbd map entry: {raw_entry}")
    primary_parent_nbd_map[parts[0]] = {"socket": parts[1], "export": parts[2]}

def suffix(value):
    return re.sub(r"[^A-Za-z0-9_.-]", "_", value or "root")

def qemu_driver(fmt):
    fmt = (fmt or "raw").strip()
    return fmt if fmt in {"raw", "qcow2"} else "raw"

def is_krbd_path(path):
    return path.startswith("/dev/rbd/")

def split_krbd_path(path):
    if path.startswith("/dev/rbd/"):
        spec = path[len("/dev/rbd/"):]
        if "/" not in spec:
            raise SystemExit(f"invalid krbd path: {path}")
        pool, image = spec.split("/", 1)
        if not pool or not image:
            raise SystemExit(f"invalid krbd path: {path}")
        if any(ch in pool + image for ch in ",;"):
            raise SystemExit(f"unsupported krbd pool/image characters: {path}")
        return pool, image
    raise SystemExit(f"not a krbd path: {path}")

def blockdev_source_nodes(path, fmt, node, file_node, host_node):
    driver = qemu_driver(fmt)
    if is_krbd_path(path):
        if rbd_commandline_backend == "krbd":
            adapter = primary_parent_nbd_map.get(path) if role == "primary" else None
            if adapter:
                nbd_node = host_node[:-5] + "-nbd" if host_node.endswith("-host") else host_node + "-nbd"
                socket_path = adapter["socket"]
                export_name = adapter["export"]
                if any(ch in socket_path + export_name for ch in ",;"):
                    raise SystemExit(f"unsupported nbd adapter characters for {path}")
                return [
                    "-blockdev",
                    f"driver=nbd,node-name={nbd_node},server.type=unix,server.path={socket_path},export={export_name}",
                    "-blockdev",
                    f"driver={driver},node-name={node},file={nbd_node}",
                ]
            return [
                "-blockdev",
                f"driver=host_device,node-name={host_node},filename={path}",
                "-blockdev",
                f"driver={driver},node-name={node},file={host_node}",
            ]
        pool, image = split_krbd_path(path)
        return [
            "-blockdev",
            f"driver={driver},node-name={node},file.driver=rbd,file.pool={pool},file.image={image}",
        ]
    return [
        "-blockdev",
        f"driver=file,node-name={file_node},filename={path}",
        "-blockdev",
        f"driver={driver},node-name={node},file={file_node}",
    ]

def parse_runtime(raw):
    entries = []
    for entry in raw.split(";"):
        if not entry:
            continue
        parts = entry.split("|")
        if len(parts) not in (7, 8):
            raise SystemExit(f"invalid xcolo disk runtime entry: {entry}")
        secondary_format = parts[7] if len(parts) == 8 else parts[2]
        entries.append({
            "target": parts[0],
            "source": parts[1],
            "format": parts[2] or "raw",
            "primary_active": parts[3],
            "secondary_dest": parts[4],
            "secondary_hidden": parts[5],
            "secondary_active": parts[6],
            "secondary_format": secondary_format or "raw",
        })
    return entries

def pci_int(value, default=0):
    if value is None or value == "":
        return default
    try:
        return int(str(value), 0)
    except ValueError:
        return default

def text_of(elem, default=""):
    if elem is None or elem.text is None:
        return default
    return elem.text.strip()

def parse_qemu_log_device_references(path):
    refs = {}
    controllers = {}
    if not path or not os.path.exists(path):
        return refs, controllers

    try:
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            lines = fh.readlines()
    except OSError:
        return refs, controllers

    blocks = []
    current = []
    in_block = False
    for line in lines:
        if line.startswith("LC_ALL=C"):
            if current:
                blocks.append(current)
            current = [line]
            in_block = True
            continue
        if in_block:
            current.append(line)
            if line.strip() == "-msg timestamp=on" or line.strip() == "-msg timestamp=on \\":
                blocks.append(current)
                current = []
                in_block = False
    if current:
        blocks.append(current)

    def qemu_arg_after_device(line):
        stripped = line.strip()
        if not stripped.startswith("-device "):
            return ""
        value = stripped[len("-device "):].strip()
        if value.endswith("\\"):
            value = value[:-1].strip()
        try:
            parts = shlex.split(value)
            if parts:
                return parts[0]
        except ValueError:
            pass
        return value.strip("'\"")

    for block in reversed(blocks):
        text = "".join(block)
        if "/usr/libexec/qemu-kvm" not in text:
            continue
        if "ftctl-colo-" in text or "colo-compare" in text or "filter-mirror" in text:
            continue
        block_refs = {}
        block_controllers = {}
        for line in block:
            arg = qemu_arg_after_device(line)
            if not arg:
                continue
            try:
                data = json.loads(arg)
            except json.JSONDecodeError:
                continue
            driver = data.get("driver")
            qdev_id = data.get("id")
            if not driver or not qdev_id:
                continue
            if driver == "scsi-hd":
                block_refs[qdev_id] = data
            elif driver == "virtio-scsi-pci":
                block_controllers[qdev_id] = data
        if block_refs:
            return block_refs, block_controllers
    return refs, controllers

reference_disks, reference_controllers = parse_qemu_log_device_references(reference_qemu_log)

def disk_topology(target, disk, disk_index):
    target_elem = disk.find("target")
    bus_type = target_elem.get("bus") if target_elem is not None else ""
    if bus_type != "scsi":
        raise SystemExit(f"unsupported protected disk bus for x-colo: {target}:{bus_type or 'missing'}")

    address = disk.find("address")
    if address is None or address.get("type") != "drive":
        raise SystemExit(f"missing drive address for protected disk: {target}")

    controller = address.get("controller") or "0"
    channel = address.get("bus") or "0"
    scsi_id = address.get("target") or "0"
    lun = address.get("unit") or str(disk_index)
    controller_id = f"scsi{controller}"
    qdev_id = f"{controller_id}-{channel}-{scsi_id}-{lun}"
    alias = disk.find("alias")
    if alias is not None and alias.get("name"):
        qdev_id = alias.get("name")

    serial = text_of(disk.find("serial"))
    boot = disk.find("boot")
    boot_order = boot.get("order") if boot is not None else ""
    driver = disk.find("driver")
    write_cache = ""
    if driver is not None and (driver.get("cache") or "").strip() == "writeback":
        write_cache = "on"

    return {
        "bus": f"{controller_id}.0",
        "controller_index": controller,
        "controller": controller_id,
        "channel": channel,
        "scsi_id": scsi_id,
        "lun": lun,
        "qdev_id": qdev_id,
        "serial": serial,
        "boot_order": boot_order,
        "write_cache": write_cache,
    }

def pci_bus_aliases(devices):
    aliases = {0: "pcie.0"}
    for controller in devices.findall("controller"):
        if controller.get("type") != "pci":
            continue
        index = pci_int(controller.get("index"), None)
        if index is None:
            continue
        alias = controller.find("alias")
        alias_name = alias.get("name") if alias is not None else ""
        if alias_name:
            aliases[index] = alias_name
        elif index == 0:
            aliases[index] = "pcie.0"
        else:
            aliases[index] = f"pci.{index}"
    return aliases

def scsi_controller_command(devices, controller_index):
    controller = None
    for candidate in devices.findall("controller"):
        if candidate.get("type") != "scsi":
            continue
        if (candidate.get("index") or "0") == str(controller_index):
            controller = candidate
            break
    if controller is None:
        raise SystemExit(f"missing scsi controller index {controller_index}")

    model = controller.get("model") or "virtio-scsi"
    if model != "virtio-scsi":
        raise SystemExit(f"unsupported scsi controller model for x-colo: {model}")

    alias = controller.find("alias")
    controller_id = alias.get("name") if alias is not None and alias.get("name") else f"scsi{controller_index}"
    if controller_id != f"scsi{controller_index}":
        raise SystemExit(f"unexpected scsi controller alias for x-colo: {controller_id}")

    address = controller.find("address")
    if address is None or address.get("type") != "pci":
        raise SystemExit(f"missing pci address for scsi controller {controller_id}")

    pci_aliases = pci_bus_aliases(devices)
    pci_bus_index = pci_int(address.get("bus"), 0)
    bus = pci_aliases.get(pci_bus_index)
    if not bus:
        raise SystemExit(f"missing pci bus alias for scsi controller {controller_id}: {address.get('bus')}")

    slot = pci_int(address.get("slot"), None)
    function = pci_int(address.get("function"), 0)
    if slot is None:
        raise SystemExit(f"missing pci slot for scsi controller {controller_id}")
    addr = f"0x{slot:x}" if function == 0 else f"0x{slot:x}.0x{function:x}"

    opts = f"virtio-scsi-pci,id={controller_id},bus={bus},addr={addr}"
    ref = reference_controllers.get(controller_id, {})
    if ref.get("num_queues") is not None:
        opts += f",num_queues={ref.get('num_queues')}"
    else:
        driver = controller.find("driver")
        if driver is not None and driver.get("queues"):
            opts += f",num_queues={driver.get('queues')}"
    return ["-device", opts]

tree = ET.parse(xml_path)
root = tree.getroot()
devices = root.find("devices")
if devices is None:
    raise SystemExit("missing <devices> in xml")

disk_by_target = {}
for index, disk in enumerate(devices.findall("disk")):
    if disk.get("device") != "disk":
        continue
    target = disk.find("target")
    if target is None or not target.get("dev"):
        continue
    disk_by_target[target.get("dev")] = (disk, index)

entries = parse_runtime(runtime_raw)
args = []
state = []
controller_args = []
controller_seen = set()
for order, item in enumerate(entries):
    target = item["target"]
    if target not in disk_by_target:
        raise SystemExit(f"disk target not found in xml: {target}")
    disk, disk_index = disk_by_target[target]
    topo = disk_topology(target, disk, disk_index)
    if topo["controller_index"] not in controller_seen:
        controller_args.extend(scsi_controller_command(devices, topo["controller_index"]))
        controller_seen.add(topo["controller_index"])
    s = suffix(target)
    parent = f"ftctl-parent-{s}" if role == "secondary" else f"ftctl-primary-parent-{s}"
    parent_file = f"{parent}-file"
    parent_host = f"{parent}-host"
    active = f"ftctl-active-{s}" if role == "secondary" else f"ftctl-primary-active-{s}"
    active_file = f"{active}-file"
    child = f"ftctl-childs-{s}"
    colo = f"ftctl-colo-{s}"
    hidden = f"ftctl-hidden-{s}"
    source = item["secondary_dest"] if role == "secondary" else item["source"]
    source_format = item["secondary_format"] if role == "secondary" else item["format"]
    guest_opts = (
        f"scsi-hd,bus={topo['bus']},channel={topo['channel']},"
        f"scsi-id={topo['scsi_id']},lun={topo['lun']},"
        f"drive={colo},id={topo['qdev_id']}"
    )
    ref = reference_disks.get(topo["qdev_id"], {})
    serial = str(ref.get("serial") or topo["serial"] or "")
    device_id = str(ref.get("device_id") or serial)
    if serial:
        guest_opts += f",serial={serial}"
    if device_id:
        guest_opts += f",device_id={device_id}"
    if ref.get("bootindex") is not None:
        guest_opts += f",bootindex={ref.get('bootindex')}"
    elif topo["boot_order"]:
        guest_opts += f",bootindex={topo['boot_order']}"
    elif order == 0:
        guest_opts += ",bootindex=1"
    write_cache = str(ref.get("write-cache") or topo["write_cache"] or "")
    if write_cache:
        guest_opts += f",write-cache={write_cache}"
    if ref.get("share-rw") is True:
        guest_opts += ",share-rw=on"
    guest = ["-device", guest_opts]
    args.extend(blockdev_source_nodes(source, source_format, parent, parent_file, parent_host))
    if role == "secondary":
        replication_opts = [
            "driver=replication",
            f"node-name={child}",
            "mode=secondary",
            "file.driver=qcow2",
            f"file.node-name={active}",
            "file.file.driver=file",
            f"file.file.filename={item['secondary_active']}",
            "file.backing.driver=qcow2",
            f"file.backing.node-name={hidden}",
            "file.backing.file.driver=file",
            f"file.backing.file.filename={item['secondary_hidden']}",
            f"file.backing.backing={parent}",
            f"top-id={colo}",
        ]
        args.extend([
            "-blockdev",
            ",".join(replication_opts),
            "-blockdev",
            f"driver=quorum,node-name={colo},read-pattern=fifo,vote-threshold=1,children.0={child}",
        ])
    else:
        args.extend([
            "-blockdev",
            f"driver=file,node-name={active_file},filename={item['primary_active']}",
            "-blockdev",
            f"driver=qcow2,node-name={active},file={active_file},backing={parent}",
            "-blockdev",
            f"driver=quorum,node-name={colo},read-pattern=fifo,vote-threshold=1,children.0={active}",
        ])
    args.extend(guest)
    state.extend([
        f"{target}.parent={parent}",
        f"{target}.parent_backend={parent}",
        f"{target}.colo={colo}",
        f"{target}.colo_backend={colo}",
        f"{target}.device={topo['qdev_id']}",
        f"{target}.controller={topo['controller']}",
        f"{target}.controller_bus={topo['bus']}",
        f"{target}.controller_mode=commandline-original",
    ])

print(";".join(controller_args + args))
PY
)" || return 1

  printf -v "${out_var}" '%s' "${payload}"
}

ftctl_xcolo_validate_startup_disk_args() {
  local vm="${1-}"
  local args="${2-}"
  local role="${3:-unknown}"
  local out="" rc=0

  out="$(XCOLO_QEMU_ARGS="${args}" python3 - <<'PY'
import os
import re
import sys

parts = os.environ.get("XCOLO_QEMU_ARGS", "").split(";")
errors = []
protected_disk_count = 0
controller_count = 0
host_device_count = 0
for idx, part in enumerate(parts):
    if part == "-device" and idx + 1 < len(parts):
        opts = parts[idx + 1]
        if "id=ftctl-xcolo-pci0" in opts or "id=ftctl-xcolo-scsi0" in opts:
            errors.append(f"ftctl_guest_visible_controller_forbidden:{opts}")
        if opts.startswith("virtio-scsi-pci,") and "id=scsi" in opts:
            controller_count += 1
    if part not in ("-drive", "-blockdev"):
        continue
    if idx + 1 >= len(parts):
        continue
    opts = parts[idx + 1]
    item = {}
    for raw in opts.split(","):
        if "=" in raw:
            k, v = raw.split("=", 1)
            item[k] = v
    if item.get("id") and item.get("node-name") and item["id"] == item["node-name"]:
        errors.append(f"backend_node_conflict:{item['id']}")
    if part == "-blockdev" and item.get("driver") == "host_device" and item.get("filename", "").startswith("/dev/rbd/"):
        host_device_count += 1

for idx, part in enumerate(parts):
    if part != "-device":
        continue
    if idx + 1 >= len(parts):
        continue
    opts = parts[idx + 1]
    if not opts.startswith("scsi-hd,") or "drive=ftctl-colo-" not in opts:
        continue
    protected_disk_count += 1
    m = re.search(r"(?:^|,)drive=([^,]+)", opts)
    if not m:
        errors.append(f"guest_drive_missing:{opts}")
        continue
    drive = m.group(1)
    if not drive.startswith("ftctl-colo-"):
        errors.append(f"guest_drive_backend_invalid:{drive}")
    bm = re.search(r"(?:^|,)bus=([^,]+)", opts)
    bus = bm.group(1) if bm else ""
    if not re.fullmatch(r"scsi[0-9]+\.0", bus or ""):
        errors.append(f"guest_bus_not_original_scsi:{bus or 'missing'}")
    im = re.search(r"(?:^|,)id=([^,]+)", opts)
    qdev_id = im.group(1) if im else ""
    if not re.fullmatch(r"scsi[0-9]+-[0-9]+-[0-9]+-[0-9]+", qdev_id or ""):
        errors.append(f"guest_qdev_not_original_scsi:{qdev_id or 'missing'}")
    if ",write-cache=on" not in opts:
        errors.append(f"guest_write_cache_missing:{qdev_id or opts}")

if protected_disk_count and any("/dev/rbd/" in p for p in parts) and host_device_count == 0:
    errors.append("krbd_host_device_blockdev_missing")

if errors:
    print(",".join(errors))
    sys.exit(1)

if protected_disk_count and controller_count == 0:
    print("original_scsi_controller_missing")
    sys.exit(1)
PY
)" || rc=$?
  if [[ "${rc}" != "0" ]]; then
    if [[ "${out}" == *"backend_node_conflict:"* ]]; then
      ftctl_state_set "${vm}" \
        "xcolo_startup_disk_backend=invalid" \
        "xcolo_protocol_failure_phase=startup_disk_graph" \
        "last_error=xcolo_startup_block_backend_node_conflict"
    elif [[ "${out}" == *"ftctl_guest_visible_controller_forbidden:"* || "${out}" == *"guest_bus_not_original_scsi:"* || "${out}" == *"guest_qdev_not_original_scsi:"* || "${out}" == *"original_scsi_controller_missing"* ]]; then
      ftctl_state_set "${vm}" \
        "xcolo_startup_disk_backend=invalid" \
        "xcolo_protocol_failure_phase=startup_disk_graph" \
        "last_error=xcolo_guest_topology_mismatch"
    elif [[ "${out}" == *"krbd_host_device_blockdev_missing"* ]]; then
      ftctl_state_set "${vm}" \
        "xcolo_startup_disk_backend=invalid" \
        "xcolo_protocol_failure_phase=startup_disk_graph" \
        "last_error=xcolo_startup_krbd_host_device_missing"
    elif [[ "${out}" == *"guest_drive_backend_invalid:"* || "${out}" == *"guest_drive_missing:"* ]]; then
      ftctl_state_set "${vm}" \
        "xcolo_startup_disk_backend=invalid" \
        "xcolo_protocol_failure_phase=startup_disk_graph" \
        "last_error=xcolo_startup_guest_drive_backend_invalid"
    else
      ftctl_state_set "${vm}" \
        "xcolo_startup_disk_backend=invalid" \
        "xcolo_protocol_failure_phase=startup_disk_graph" \
        "last_error=xcolo_startup_disk_graph_invalid"
    fi
    ftctl_log_event "colo" "xcolo.startup_disk_graph.validate" "fail" "${vm}" "" \
      "role=${role} reason=$(ftctl_xcolo_compact_log_value "${out}")"
    return 1
  fi
  ftctl_log_event "colo" "xcolo.startup_disk_graph.validate" "ok" "${vm}" "" \
    "role=${role}"
}

ftctl_xcolo_verify_generated_guest_abi_pair() {
  local vm="${1-}"
  local primary_xml="${2-}"
  local secondary_xml="${3-}"
  local phase="${4:-pre_create}"
  local out="" rc=0

  command -v python3 >/dev/null 2>&1 || {
    echo "ERROR: python3 is required for x-colo guest ABI validation" >&2
    return 2
  }

  [[ -n "${vm}" && -f "${primary_xml}" && -f "${secondary_xml}" ]] || return 1

  out="$(PRIMARY_XML="${primary_xml}" SECONDARY_XML="${secondary_xml}" python3 - <<'PY'
import hashlib
import json
import os
import xml.etree.ElementTree as ET

qemu_ns = "http://libvirt.org/schemas/domain/qemu/1.0"
primary_xml = os.environ["PRIMARY_XML"]
secondary_xml = os.environ["SECONDARY_XML"]

def lname(tag):
    return tag.rsplit("}", 1)[-1] if tag.startswith("{") else tag

def canon_elem(elem, path=""):
    name = lname(elem.tag)
    if name == "commandline":
        return None
    if name in {"name", "id", "resource", "seclabel"}:
        return None
    # Host-local presentation and management endpoints are not guest-visible
    # migration ABI.  They may legitimately differ by host even when the COLO
    # guest topology is identical.
    if name in {"graphics", "listen", "console", "channel"}:
        return None
    attrs = {
        k: v for k, v in sorted(elem.attrib.items())
        if k not in {"file", "dev", "dir", "socket", "pid", "port", "autoport", "listen"}
    }
    text = (elem.text or "").strip()
    children = []
    for child in list(elem):
        item = canon_elem(child, f"{path}/{name}")
        if item is not None:
            children.append(item)
    return [name, attrs, text, children]

def qemu_args(root):
    return [node.get("value", "") for node in root.findall(f".//{{{qemu_ns}}}arg")]

def split_pairs(args):
    pairs = []
    idx = 0
    while idx < len(args):
        key = args[idx]
        value = args[idx + 1] if idx + 1 < len(args) else ""
        pairs.append((key, value))
        idx += 2 if key.startswith("-") else 1
    return pairs

def guest_qemu_devices(root):
    devices = []
    for key, value in split_pairs(qemu_args(root)):
        if key != "-device":
            continue
        if value.startswith(("scsi-hd,", "virtio-scsi-pci,", "virtio-blk-pci,", "virtio-net-pci,")):
            devices.append(value)
    return devices

def manifest(path):
    root = ET.parse(path).getroot()
    payload = {
        "xml": canon_elem(root, "/domain"),
        "qemu_guest_devices": guest_qemu_devices(root),
    }
    encoded = json.dumps(payload, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(encoded.encode("utf-8")).hexdigest(), payload

phash, pmanifest = manifest(primary_xml)
shash, smanifest = manifest(secondary_xml)
if phash == shash:
    print(f"ok primary={phash} secondary={shash}")
    raise SystemExit(0)

def first_diff(a, b, prefix=""):
    if type(a) is not type(b):
        return f"{prefix}:type:{type(a).__name__}!={type(b).__name__}"
    if isinstance(a, dict):
        for key in sorted(set(a) | set(b)):
            if key not in a:
                return f"{prefix}/{key}:missing_primary"
            if key not in b:
                return f"{prefix}/{key}:missing_secondary"
            diff = first_diff(a[key], b[key], f"{prefix}/{key}")
            if diff:
                return diff
        return ""
    if isinstance(a, list):
        if len(a) != len(b):
            return f"{prefix}:len:{len(a)}!={len(b)}"
        for idx, (left, right) in enumerate(zip(a, b)):
            diff = first_diff(left, right, f"{prefix}[{idx}]")
            if diff:
                return diff
        return ""
    if a != b:
        return f"{prefix}:{a!r}!={b!r}"
    return ""

reason = first_diff(pmanifest, smanifest) or "unknown_manifest_difference"
print(f"mismatch primary={phash} secondary={shash} reason={reason}")
raise SystemExit(1)
PY
)" || rc=$?

  if [[ "${rc}" != "0" ]]; then
    ftctl_state_set "${vm}" \
      "xcolo_guest_abi_manifest=failed" \
      "xcolo_guest_abi_manifest_phase=${phase}" \
      "xcolo_guest_abi_manifest_reason=$(ftctl_xcolo_compact_log_value "${out}")" \
      "xcolo_protocol_failure_phase=guest_abi_manifest" \
      "last_error=xcolo_guest_abi_manifest_mismatch"
    ftctl_log_event "colo" "xcolo.guest_abi_manifest" "fail" "${vm}" "" \
      "phase=${phase} $(ftctl_xcolo_compact_log_value "${out}")"
    return 1
  fi

  ftctl_state_set "${vm}" \
    "xcolo_guest_abi_manifest=ok" \
    "xcolo_guest_abi_manifest_phase=${phase}" \
    "xcolo_guest_abi_manifest_result=$(ftctl_xcolo_compact_log_value "${out}")"
  ftctl_log_event "colo" "xcolo.guest_abi_manifest" "ok" "${vm}" "" \
    "phase=${phase} $(ftctl_xcolo_compact_log_value "${out}")"
}

ftctl_xcolo_verify_generated_pci_manifest_pair() {
  local vm="${1-}"
  local primary_xml="${2-}"
  local secondary_xml="${3-}"
  local phase="${4:-startup_disk_graph}"
  local out="" rc=0 debug_dir primary_manifest secondary_manifest diff_file

  command -v python3 >/dev/null 2>&1 || {
    echo "ERROR: python3 is required for x-colo PCI manifest validation" >&2
    return 2
  }

  [[ -n "${vm}" && -f "${primary_xml}" && -f "${secondary_xml}" ]] || return 1

  debug_dir="$(ftctl_xcolo_debug_dir "${vm}")"
  ftctl_ensure_dir "${debug_dir}" "0755"
  primary_manifest="${debug_dir}/primary-generated-pci-manifest-${phase}.json"
  secondary_manifest="${debug_dir}/secondary-generated-pci-manifest-${phase}.json"
  diff_file="${debug_dir}/generated-pci-manifest-diff-${phase}.txt"

  out="$(PRIMARY_XML="${primary_xml}" SECONDARY_XML="${secondary_xml}" PRIMARY_MANIFEST="${primary_manifest}" SECONDARY_MANIFEST="${secondary_manifest}" DIFF_FILE="${diff_file}" python3 - <<'PY'
import hashlib
import json
import os
import re
import sys
import xml.etree.ElementTree as ET

primary_xml = os.environ["PRIMARY_XML"]
secondary_xml = os.environ["SECONDARY_XML"]
primary_manifest = os.environ["PRIMARY_MANIFEST"]
secondary_manifest = os.environ["SECONDARY_MANIFEST"]
diff_file = os.environ["DIFF_FILE"]

GUEST_QEMU_DEVICE_DRIVERS = {
    "pcie-root-port",
    "pci-bridge",
    "pcie-pci-bridge",
    "virtio-scsi-pci",
    "scsi-hd",
    "ide-cd",
    "virtio-blk-pci",
    "virtio-net-pci",
    "virtio-serial-pci",
    "virtserialport",
    "virtio-balloon-pci",
    "virtio-rng-pci",
    "qemu-xhci",
    "usb-tablet",
    "i6300esb",
    "ich9-intel-hda",
    "hda-duplex",
    "isa-serial",
    "qxl",
    "virtio-vga",
    "VGA",
    "cirrus-vga",
}

HOST_LOCAL_XML_ATTRS = {
    "file",
    "dev",
    "dir",
    "socket",
    "pid",
    "port",
    "autoport",
    "listen",
    "address",
}

def lname(tag):
    return tag.rsplit("}", 1)[-1] if tag.startswith("{") else tag

def norm_attrs(elem, drop_host_local=False):
    attrs = {}
    for key, value in sorted(elem.attrib.items()):
        if drop_host_local and key in HOST_LOCAL_XML_ATTRS:
            continue
        attrs[key] = value
    return attrs

def elem_text(elem):
    return (elem.text or "").strip() if elem is not None else ""

def first(root, path):
    return root.find(path)

def child_attrs(elem, name, drop_host_local=False):
    child = elem.find(name) if elem is not None else None
    return norm_attrs(child, drop_host_local) if child is not None else {}

def scalar_manifest(root):
    os_type = first(root, "os/type")
    cpu = first(root, "cpu")
    memory = first(root, "memory")
    current_memory = first(root, "currentMemory")
    vcpu = first(root, "vcpu")
    features = first(root, "features")
    feature_names = []
    if features is not None:
        for child in list(features):
            feature_names.append([lname(child.tag), norm_attrs(child)])
    return {
        "domain_type": root.get("type", ""),
        "machine": os_type.get("machine", "") if os_type is not None else "",
        "arch": os_type.get("arch", "") if os_type is not None else "",
        "os_type": elem_text(os_type),
        "cpu": [norm_attrs(cpu), elem_text(cpu)] if cpu is not None else [],
        "memory": [norm_attrs(memory), elem_text(memory)] if memory is not None else [],
        "currentMemory": [norm_attrs(current_memory), elem_text(current_memory)] if current_memory is not None else [],
        "vcpu": [norm_attrs(vcpu), elem_text(vcpu)] if vcpu is not None else [],
        "features": sorted(feature_names),
    }

def device_alias(elem):
    alias = elem.find("alias") if elem is not None else None
    return alias.get("name", "") if alias is not None else ""

def device_address(elem):
    address = elem.find("address") if elem is not None else None
    return norm_attrs(address) if address is not None else {}

def pci_controllers(devices):
    rows = []
    if devices is None:
        return rows
    for controller in devices.findall("controller"):
        ctype = controller.get("type", "")
        if ctype not in {"pci", "scsi", "usb", "virtio-serial"}:
            continue
        row = {
            "type": ctype,
            "model": controller.get("model", ""),
            "index": controller.get("index", ""),
            "alias": device_alias(controller),
            "address": device_address(controller),
            "model_attrs": child_attrs(controller, "model"),
            "target_attrs": child_attrs(controller, "target"),
            "driver_attrs": child_attrs(controller, "driver"),
        }
        rows.append(row)
    return sorted(rows, key=lambda row: json.dumps(row, sort_keys=True, separators=(",", ":")))

def pci_devices(devices):
    rows = []
    if devices is None:
        return rows
    for tag in ("interface", "disk", "video", "memballoon", "rng", "serial"):
        for elem in devices.findall(tag):
            if tag == "disk" and elem.get("device", "") != "disk":
                continue
            address = elem.find("address")
            if address is None or address.get("type") not in {"pci", "drive"}:
                continue
            row = {
                "tag": tag,
                "type": elem.get("type", ""),
                "device": elem.get("device", ""),
                "alias": device_alias(elem),
                "address": norm_attrs(address),
                "target": child_attrs(elem, "target"),
                "model": child_attrs(elem, "model"),
                "mac": child_attrs(elem, "mac"),
                "driver": child_attrs(elem, "driver"),
            }
            rows.append(row)
    return sorted(rows, key=lambda row: json.dumps(row, sort_keys=True, separators=(",", ":")))

def qemu_args(root):
    values = []
    for elem in root.iter():
        if lname(elem.tag) != "arg":
            continue
        value = elem.get("value")
        if value is not None:
            values.append(value)
    return values

def split_qemu_pairs(args):
    pairs = []
    idx = 0
    while idx < len(args):
        key = args[idx]
        if key.startswith("-"):
            value = args[idx + 1] if idx + 1 < len(args) else ""
            pairs.append((key, value))
            idx += 2
        else:
            idx += 1
    return pairs

def parse_device_arg(value):
    value = value.strip()
    if not value:
        return None
    if value.startswith("{"):
        try:
            data = json.loads(value)
        except Exception:
            return {"driver": value, "opts": {}}
        driver = data.get("driver", "")
        if driver not in GUEST_QEMU_DEVICE_DRIVERS:
            return None
        opts = {str(k): str(v) for k, v in sorted(data.items()) if k != "driver"}
        return {"driver": driver, "opts": opts}
    parts = value.split(",")
    driver = parts[0]
    if driver not in GUEST_QEMU_DEVICE_DRIVERS:
        return None
    opts = {}
    flags = []
    for item in parts[1:]:
        if not item:
            continue
        if "=" in item:
            key, val = item.split("=", 1)
            opts[key] = val
        else:
            flags.append(item)
    return {"driver": driver, "opts": dict(sorted(opts.items())), "flags": sorted(flags)}

def qemu_guest_devices(root):
    rows = []
    for key, value in split_qemu_pairs(qemu_args(root)):
        if key != "-device":
            continue
        parsed = parse_device_arg(value)
        if parsed is not None:
            rows.append(parsed)
    return sorted(rows, key=lambda row: json.dumps(row, sort_keys=True, separators=(",", ":")))

def manifest(path):
    root = ET.parse(path).getroot()
    devices = root.find("devices")
    payload = {
        "scalar": scalar_manifest(root),
        "controllers": pci_controllers(devices),
        "devices": pci_devices(devices),
        "qemu_guest_devices": qemu_guest_devices(root),
    }
    encoded = json.dumps(payload, sort_keys=True, separators=(",", ":"))
    digest = hashlib.sha256(encoded.encode("utf-8")).hexdigest()
    return digest, payload

def first_diff(a, b, prefix=""):
    if type(a) is not type(b):
        return f"{prefix}:type:{type(a).__name__}!={type(b).__name__}"
    if isinstance(a, dict):
        for key in sorted(set(a) | set(b)):
            if key not in a:
                return f"{prefix}/{key}:missing_primary"
            if key not in b:
                return f"{prefix}/{key}:missing_secondary"
            diff = first_diff(a[key], b[key], f"{prefix}/{key}")
            if diff:
                return diff
        return ""
    if isinstance(a, list):
        if len(a) != len(b):
            return f"{prefix}:len:{len(a)}!={len(b)}"
        for idx, (left, right) in enumerate(zip(a, b)):
            diff = first_diff(left, right, f"{prefix}[{idx}]")
            if diff:
                return diff
        return ""
    if a != b:
        return f"{prefix}:{a!r}!={b!r}"
    return ""

try:
    phash, pmanifest = manifest(primary_xml)
    shash, smanifest = manifest(secondary_xml)
except Exception as exc:
    print(f"error=manifest_build_failed reason={exc}")
    sys.exit(1)

with open(primary_manifest, "w", encoding="utf-8") as fh:
    json.dump(pmanifest, fh, sort_keys=True, indent=2)
    fh.write("\n")
with open(secondary_manifest, "w", encoding="utf-8") as fh:
    json.dump(smanifest, fh, sort_keys=True, indent=2)
    fh.write("\n")

primary_count = sum(len(pmanifest[key]) if isinstance(pmanifest[key], list) else 1 for key in pmanifest)
secondary_count = sum(len(smanifest[key]) if isinstance(smanifest[key], list) else 1 for key in smanifest)

if phash == shash:
    with open(diff_file, "w", encoding="utf-8") as fh:
        fh.write(f"ok primary={phash} secondary={shash}\n")
    print(f"ok primary={phash} secondary={shash} primary_count={primary_count} secondary_count={secondary_count}")
    sys.exit(0)

reason = first_diff(pmanifest, smanifest) or "unknown_manifest_difference"
with open(diff_file, "w", encoding="utf-8") as fh:
    fh.write(f"mismatch primary={phash} secondary={shash} reason={reason}\n")
print(f"mismatch primary={phash} secondary={shash} primary_count={primary_count} secondary_count={secondary_count} reason={reason}")
sys.exit(1)
PY
)" || rc=$?

  if [[ "${rc}" != "0" ]]; then
    ftctl_state_set "${vm}" \
      "xcolo_generated_pci_manifest=failed" \
      "xcolo_generated_pci_manifest_phase=${phase}" \
      "xcolo_generated_pci_manifest_reason=$(ftctl_xcolo_compact_log_value "${out}")" \
      "xcolo_generated_pci_manifest_primary=${primary_manifest}" \
      "xcolo_generated_pci_manifest_secondary=${secondary_manifest}" \
      "xcolo_generated_pci_manifest_diff=${diff_file}" \
      "xcolo_protocol_failure_phase=generated_pci_manifest" \
      "last_error=xcolo_generated_pci_manifest_mismatch"
    ftctl_log_event "colo" "xcolo.generated_pci_manifest" "fail" "${vm}" "" \
      "phase=${phase} $(ftctl_xcolo_compact_log_value "${out}")"
    return 1
  fi

  ftctl_state_set "${vm}" \
    "xcolo_generated_pci_manifest=ok" \
    "xcolo_generated_pci_manifest_phase=${phase}" \
    "xcolo_generated_pci_manifest_result=$(ftctl_xcolo_compact_log_value "${out}")" \
    "xcolo_generated_pci_manifest_primary=${primary_manifest}" \
    "xcolo_generated_pci_manifest_secondary=${secondary_manifest}" \
    "xcolo_generated_pci_manifest_diff=${diff_file}"
  ftctl_log_event "colo" "xcolo.generated_pci_manifest" "ok" "${vm}" "" \
    "phase=${phase} $(ftctl_xcolo_compact_log_value "${out}")"
}

ftctl_xcolo_validate_generated_commandline_contract() {
  local vm="${1-}"
  local xml_path="${2-}"
  local role="${3-}"
  local out="" rc=0

  out="$(XML_PATH="${xml_path}" ROLE="${role}" python3 - <<'PY'
import os
import sys
import xml.etree.ElementTree as ET

xml_path = os.environ["XML_PATH"]
role = os.environ["ROLE"]

try:
    root = ET.parse(xml_path).getroot()
except Exception as exc:
    print(f"xml_parse_failed:{exc}")
    sys.exit(1)

args = []
for elem in root.iter():
    if elem.tag.endswith("arg"):
        value = elem.get("value")
        if value:
            args.append(value)
text = ";".join(args)

missing = []
errors = []

def require(token):
    if token not in text:
        missing.append(token)

if "ftctl-xcolo-pci0" in text or "ftctl-xcolo-scsi0" in text:
    errors.append("ftctl_guest_visible_controller_forbidden")

devices = root.find("devices")
if devices is not None:
    for controller in devices.findall("controller"):
        if controller.get("type") == "scsi":
            errors.append("libvirt_scsi_controller_not_removed")

has_original_scsi_disk = False
has_original_scsi_controller = False
for idx, arg in enumerate(args):
    if arg != "-device" or idx + 1 >= len(args):
        continue
    opts = args[idx + 1]
    if opts.startswith("virtio-scsi-pci,") and "id=scsi" in opts and "addr=" in opts:
        has_original_scsi_controller = True
    if not opts.startswith("scsi-hd,") or "drive=ftctl-colo-" not in opts:
        continue
    if "bus=scsi" in opts and ".0" in opts and "id=scsi" in opts:
        has_original_scsi_disk = True

if not has_original_scsi_disk:
    errors.append("original_scsi_guest_disk_missing")
if not has_original_scsi_controller:
    errors.append("original_scsi_controller_missing")

if role == "primary":
    for token in [
        "id=compare1",
        "id=mirror0",
        "filter-mirror",
        "filter-redirector",
        "colo-compare",
        "virtio-scsi-pci,id=scsi",
        "scsi-hd,bus=scsi",
        "drive=ftctl-colo-",
        "write-cache=on",
    ]:
        require(token)
elif role == "secondary":
    for token in [
        "id=red0",
        "id=red1",
        "filter-redirector",
        "filter-rewriter",
        "-incoming",
        "driver=replication",
        "file.file.driver=file",
        "file.backing.file.driver=file",
        "virtio-scsi-pci,id=scsi",
        "scsi-hd,bus=scsi",
        "drive=ftctl-colo-",
        "write-cache=on",
    ]:
        require(token)
else:
    print(f"unknown_role:{role}")
    sys.exit(1)

if errors or missing:
    parts = []
    if missing:
        parts.append("missing:" + ",".join(missing))
    if errors:
        parts.append("errors:" + ",".join(errors))
    print(";".join(parts))
    sys.exit(1)

print("ok")
PY
)" || rc=$?
  if [[ "${rc}" != "0" ]]; then
    if [[ "${out}" == *"ftctl_guest_visible_controller_forbidden"* || "${out}" == *"original_scsi_guest_disk_missing"* || "${out}" == *"original_scsi_controller_missing"* || "${out}" == *"libvirt_scsi_controller_not_removed"* ]]; then
      ftctl_state_set "${vm}" \
        "xcolo_protocol_failure_phase=startup_commandline_contract" \
        "last_error=xcolo_guest_topology_mismatch"
    elif [[ "${out}" == *"missing:"* ]]; then
      if [[ "${out}" == *"compare1"* || "${out}" == *"mirror0"* || "${out}" == *"filter-mirror"* || "${out}" == *"filter-redirector"* || "${out}" == *"colo-compare"* || "${out}" == *"red0"* || "${out}" == *"red1"* || "${out}" == *"-incoming"* || "${out}" == *"filter-rewriter"* ]]; then
        ftctl_state_set "${vm}" \
          "xcolo_protocol_failure_phase=startup_commandline_contract" \
          "last_error=xcolo_startup_network_args_missing"
      else
        ftctl_state_set "${vm}" \
          "xcolo_protocol_failure_phase=startup_commandline_contract" \
          "last_error=xcolo_startup_disk_args_missing"
      fi
    else
      ftctl_state_set "${vm}" \
        "xcolo_protocol_failure_phase=startup_commandline_contract" \
        "last_error=xcolo_startup_commandline_contract_invalid"
    fi
    ftctl_log_event "colo" "xcolo.startup_commandline_contract" "fail" "${vm}" "" \
      "role=${role} path=${xml_path} reason=$(ftctl_xcolo_compact_log_value "${out}")"
    return 1
  fi

  ftctl_log_event "colo" "xcolo.startup_commandline_contract" "ok" "${vm}" "" \
    "role=${role} path=${xml_path}"
}

ftctl_xcolo_apply_startup_disk_graphs() {
  local vm="${1-}"
  local primary_xml="${2-}"
  local secondary_xml="${3-}"
  local disk_runtime="${4-}"
  local primary_net_args="${5-}"
  local secondary_net_args="${6-}"
  local primary_disk_args secondary_disk_args reference_qemu_log
  local primary_args secondary_args rbd_backend primary_parent_nbd_map startup_parent_backend

  [[ -n "${vm}" && -f "${primary_xml}" && -f "${secondary_xml}" && -n "${disk_runtime}" ]] || return 1

  if [[ -z "${primary_net_args}" || -z "${secondary_net_args}" ]]; then
    ftctl_state_set "${vm}" \
      "xcolo_protocol_failure_phase=startup_commandline_contract" \
      "last_error=xcolo_startup_network_args_missing"
    ftctl_log_event "colo" "xcolo.startup_commandline_contract" "fail" "${vm}" "" \
      "role=both reason=network_args_not_passed"
    return 1
  fi

  reference_qemu_log="/var/log/libvirt/qemu/${vm}.log"
  rbd_backend="$(ftctl_xcolo_rbd_commandline_backend)"
  primary_parent_nbd_map=""
  startup_parent_backend="direct"
  if [[ "${rbd_backend}" == "krbd" ]]; then
    ftctl_xcolo_prepare_primary_parent_nbd_adapters "${vm}" "${disk_runtime}" primary_parent_nbd_map "startup_disk_graph" || return $?
    [[ -n "${primary_parent_nbd_map}" ]] && startup_parent_backend="krbd-nbd-adapter"
  elif [[ "${rbd_backend}" == "librbd" ]]; then
    startup_parent_backend="native-rbd"
    ftctl_state_set "${vm}"       "xcolo_primary_parent_nbd_adapter=disabled"       "xcolo_primary_parent_nbd_adapter_count=0"
    ftctl_log_event "colo" "xcolo.primary_parent_nbd.prepare" "skip" "${vm}" ""       "phase=startup_disk_graph reason=native_rbd_runtime_backend"
  fi
  ftctl_xcolo_build_startup_disk_args "${primary_xml}" "primary" "${disk_runtime}" primary_disk_args "${reference_qemu_log}" "${primary_parent_nbd_map}" || return 1
  ftctl_xcolo_build_startup_disk_args "${secondary_xml}" "secondary" "${disk_runtime}" secondary_disk_args "${reference_qemu_log}" || return 1
  primary_args="$(ftctl_xcolo_qemu_args_append "${primary_disk_args}" "${primary_net_args}")"
  secondary_args="$(ftctl_xcolo_secondary_args_with_disk_graph "${secondary_net_args}" "${secondary_disk_args}")"
  case "${rbd_backend}" in
    krbd)
      if [[ "${primary_args};${secondary_args}" == *"rbd:rbd/"* || "${primary_args};${secondary_args}" == *"file=rbd:"* ]]; then
        ftctl_state_set "${vm}" \
          "xcolo_startup_disk_backend=invalid" \
          "xcolo_protocol_failure_phase=startup_disk_graph" \
          "last_error=xcolo_startup_krbd_uri_leaked_preflight"
        ftctl_log_event "colo" "xcolo.startup_disk_graph" "fail" "${vm}" "" \
          "reason=krbd_uri_leaked_into_qemu_commandline backend=krbd"
        return 1
      fi
      if [[ "${primary_args};${secondary_args}" == *"/dev/rbd/"* && "${primary_args};${secondary_args}" != *"driver=host_device"* ]]; then
        ftctl_state_set "${vm}" \
          "xcolo_startup_disk_backend=invalid" \
          "xcolo_protocol_failure_phase=startup_disk_graph" \
          "last_error=xcolo_startup_krbd_host_device_missing"
        ftctl_log_event "colo" "xcolo.startup_disk_graph" "fail" "${vm}" "" \
          "reason=krbd_path_without_host_device backend=krbd"
        return 1
      fi
      ;;
    librbd)
      if [[ "${primary_args};${secondary_args}" == *"/dev/rbd/"* ]]; then
        ftctl_state_set "${vm}" \
          "xcolo_startup_disk_backend=invalid" \
          "xcolo_protocol_failure_phase=startup_disk_graph" \
          "last_error=xcolo_startup_krbd_path_leaked"
        ftctl_log_event "colo" "xcolo.startup_disk_graph" "fail" "${vm}" "" \
          "reason=krbd_path_leaked_into_qemu_commandline backend=librbd"
        return 1
      fi
      ;;
    *)
      ftctl_state_set "${vm}" \
        "xcolo_startup_disk_backend=invalid" \
        "xcolo_protocol_failure_phase=startup_disk_graph" \
        "last_error=xcolo_startup_rbd_backend_invalid"
      ftctl_log_event "colo" "xcolo.startup_disk_graph" "fail" "${vm}" "" \
        "reason=unsupported_rbd_commandline_backend backend=${FTCTL_XCOLO_RBD_COMMANDLINE_BACKEND}"
      return 1
      ;;
  esac
  ftctl_xcolo_validate_startup_disk_topology_xml "${vm}" "${primary_xml}" "${disk_runtime}" "primary" || return 1
  ftctl_xcolo_validate_startup_disk_topology_xml "${vm}" "${secondary_xml}" "${disk_runtime}" "secondary" || return 1
  ftctl_xcolo_validate_startup_disk_args "${vm}" "${primary_args}" "primary" || return 1
  ftctl_xcolo_validate_startup_disk_args "${vm}" "${secondary_args}" "secondary" || return 1

  ftctl_xcolo_record_krbd_materialization_contract "${vm}" "${disk_runtime}" "startup_disk_graph" || return 1
  ftctl_xcolo_xml_remove_disk_targets "${primary_xml}" "${disk_runtime}" || return 1
  ftctl_xcolo_xml_remove_disk_targets "${secondary_xml}" "${disk_runtime}" || return 1
  ftctl_xml_apply_qemu_commandline "${primary_xml}" "${primary_args}" || return 1
  ftctl_xml_apply_qemu_commandline "${secondary_xml}" "${secondary_args}" || return 1
  case "${rbd_backend}" in
    krbd)
      if grep -Eq 'rbd:rbd/|file=rbd:' "${primary_xml}" "${secondary_xml}"; then
        ftctl_state_set "${vm}"           "xcolo_startup_disk_backend=invalid"           "xcolo_protocol_failure_phase=startup_disk_graph"           "last_error=xcolo_startup_krbd_uri_leaked_preflight"
        ftctl_log_event "colo" "xcolo.startup_disk_graph" "fail" "${vm}" ""           "reason=krbd_uri_leaked_into_generated_xml backend=krbd primary_xml=${primary_xml} secondary_xml=${secondary_xml}"
        return 1
      fi
      if [[ -n "${primary_parent_nbd_map}" ]] && grep -q 'driver=host_device.*filename=/dev/rbd/' "${primary_xml}"; then
        ftctl_state_set "${vm}"           "xcolo_startup_disk_backend=invalid"           "xcolo_protocol_failure_phase=startup_disk_graph"           "last_error=xcolo_startup_primary_krbd_adapter_bypass"
        ftctl_log_event "colo" "xcolo.startup_disk_graph" "fail" "${vm}" ""           "reason=primary_krbd_host_device_leaked_in_generated_xml backend=krbd primary_xml=${primary_xml}"
        return 1
      fi
      if grep -q '/dev/rbd/' "${primary_xml}" "${secondary_xml}" && ! grep -q 'driver=host_device' "${primary_xml}" "${secondary_xml}"; then
        ftctl_state_set "${vm}"           "xcolo_startup_disk_backend=invalid"           "xcolo_protocol_failure_phase=startup_disk_graph"           "last_error=xcolo_startup_krbd_host_device_missing"
        ftctl_log_event "colo" "xcolo.startup_disk_graph" "fail" "${vm}" ""           "reason=krbd_path_without_host_device_in_generated_xml backend=krbd primary_xml=${primary_xml} secondary_xml=${secondary_xml}"
        return 1
      fi
      ;;
    librbd)
      if grep -Eq '/dev/rbd/' "${primary_xml}" "${secondary_xml}"; then
        ftctl_state_set "${vm}"           "xcolo_startup_disk_backend=invalid"           "xcolo_protocol_failure_phase=startup_disk_graph"           "last_error=xcolo_startup_krbd_path_leaked"
        ftctl_log_event "colo" "xcolo.startup_disk_graph" "fail" "${vm}" ""           "reason=krbd_path_leaked_into_generated_xml backend=librbd primary_xml=${primary_xml} secondary_xml=${secondary_xml}"
        return 1
      fi
      ;;
  esac
  ftctl_xcolo_validate_generated_commandline_contract "${vm}" "${primary_xml}" "primary" || return 1
  ftctl_xcolo_validate_generated_commandline_contract "${vm}" "${secondary_xml}" "secondary" || return 1
  ftctl_xcolo_verify_generated_guest_abi_pair "${vm}" "${primary_xml}" "${secondary_xml}" "startup_disk_graph" || return 1
  ftctl_xcolo_verify_generated_pci_manifest_pair "${vm}" "${primary_xml}" "${secondary_xml}" "startup_disk_graph" || return 1

  ftctl_state_set "${vm}" \
    "xcolo_startup_disk_graph=enabled" \
    "xcolo_startup_disk_backend=${rbd_backend}-rbd-or-file" \
    "xcolo_startup_disk_parent_backend=${startup_parent_backend}" \
    "xcolo_rbd_commandline_backend=${rbd_backend}" \
    "xcolo_startup_disk_graph_runtime=${disk_runtime}" \
    "primary_qemu_args=${primary_args}" \
    "secondary_qemu_args=${secondary_args}"
  ftctl_log_event "colo" "xcolo.startup_disk_graph" "ok" "${vm}" "" \
    "disk_count=$(printf '%s' "${disk_runtime}" | awk -F';' '{print NF}') primary_xml=${primary_xml} secondary_xml=${secondary_xml}"
}

ftctl_xcolo_doc_alignment_summary() {
  cat <<'EOF'
COLO startup alignment checklist
1. Primary startup:
   - mirror0 / compare1 external servers use wait=off in FTCTL's libvirt
     orchestration path, so QEMU command-line parsing cannot block before both
     listener objects are materialized
   - FTCTL waits for both primary listeners and then waits for secondary red0 /
     red1 attachment before migrate
   - compare0 / compare0-0 / compare_out / compare_out0 loopback sockets
   - filter-mirror, filter-redirector, and colo-compare objects are present
     in the startup qemu:commandline and start active
   - guest-visible disks start on COLO quorum nodes
   - no runtime device_del/device_add for protected disks
   - startup paused with -S
2. Secondary startup:
   - red0 / red1 reconnect sockets toward primary
   - filter-redirector / filter-rewriter objects present
   - parent / childs / hidden / active / colo disk graph present at startup
   - no runtime device_del/device_add for protected disks
   - -incoming defer present at startup; QMP migrate-incoming starts the URI
     after secondary startup materialization is verified
   - no -S on secondary startup
3. Protect QMP sequence:
   - secondary qmp_capabilities
   - secondary migrate-set-capabilities x-colo
   - secondary nbd-server-start
   - secondary nbd-server-add for the COLO base/parent node
   - primary qmp_capabilities
   - primary blockdev-add nbd child
   - primary x-blockdev-change parent=colo disk node=nbd child
   - primary migrate-set-capabilities x-colo
   - secondary migrate-incoming with the configured migration URI
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
  ftctl_xcolo_clone_primary_xml_for_secondary "${primary_xml_backup}" "${standby_generated_xml}" "${standby_vm_name}" ||
    ftctl_xcolo_prepare_block_generated_xmls_fail "xcolo_secondary_primary_shape_clone_failed" "primary=${primary_xml_backup} path=${standby_generated_xml}" || return 1

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
  ftctl_xml_normalize_ft_host_local_endpoints "${primary_generated_xml}" ||
    ftctl_xcolo_prepare_block_generated_xmls_fail "xcolo_primary_host_local_endpoint_xml_failed" "path=${primary_generated_xml}" || return 1
  ftctl_xml_normalize_ft_host_local_endpoints "${standby_generated_xml}" ||
    ftctl_xcolo_prepare_block_generated_xmls_fail "xcolo_standby_host_local_endpoint_xml_failed" "path=${standby_generated_xml}" || return 1
  ftctl_xml_apply_standby_host_runtime "${standby_generated_xml}" ||
    ftctl_xcolo_prepare_block_generated_xmls_fail "xcolo_standby_host_xml_failed" "path=${standby_generated_xml}" || return 1
  ftctl_xml_ensure_iothread_id "${primary_generated_xml}" "1" ||
    ftctl_xcolo_prepare_block_generated_xmls_fail "xcolo_primary_iothread_xml_failed" "path=${primary_generated_xml}" || return 1
  ftctl_xml_ensure_iothread_id "${standby_generated_xml}" "1" ||
    ftctl_xcolo_prepare_block_generated_xmls_fail "xcolo_standby_iothread_xml_failed" "path=${standby_generated_xml}" || return 1
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

ftctl_xcolo_seed_graph_format_from_info() {
  local detected_format="${1-}"
  local target_format="${2-raw}"
  local out_var="${3}"
  local graph_format=""

  [[ -n "${target_format}" ]] || target_format="raw"
  case "${target_format}" in
    qcow2)
      [[ "${detected_format}" == "qcow2" ]] || return 1
      graph_format="qcow2"
      ;;
    raw)
      case "${detected_format}" in
        raw|host_device|file|"") graph_format="raw" ;;
        *) return 1 ;;
      esac
      ;;
    *)
      [[ "${detected_format}" == "${target_format}" ]] || return 1
      graph_format="${target_format}"
      ;;
  esac

  printf -v "${out_var}" '%s' "${graph_format}"
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
  local seed_info seed_format seed_virtual seed_actual seed_graph_format

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

  seed_info="$(printf '%s\n' "${out}" | tail -n1 | tr -d '\r')"
  seed_format="$(printf '%s\n' "${seed_info}" | sed -n 's/.*format=\([^[:space:]]*\).*/\1/p')"
  seed_virtual="$(printf '%s\n' "${seed_info}" | sed -n 's/.*virtual=\([^[:space:]]*\).*/\1/p')"
  seed_actual="$(printf '%s\n' "${seed_info}" | sed -n 's/.*actual=\([^[:space:]]*\).*/\1/p')"
  if [[ -z "${seed_format}" || -z "${seed_virtual}" ]]; then
    ftctl_log_event "colo" "block_conversion.baseline_seed.info" "fail" "${vm}" "" \
      "target=${target} secondary_dest=${secondary_dest} info=$(ftctl_xcolo_compact_log_value "${seed_info}")"
    ftctl_state_set "${vm}" "last_error=xcolo_baseline_seed_info_missing:${target}"
    return 1
  fi
  if ! ftctl_xcolo_seed_graph_format_from_info "${seed_format}" "${target_format}" seed_graph_format; then
    ftctl_log_event "colo" "block_conversion.baseline_seed.format" "fail" "${vm}" "" \
      "target=${target} secondary_dest=${secondary_dest} expected=${target_format} detected=${seed_format} info=$(ftctl_xcolo_compact_log_value "${seed_info}")"
    ftctl_state_set "${vm}" "last_error=xcolo_secondary_baseline_format_mismatch:${target}"
    return 1
  fi
  if [[ -n "${expected_size}" && "${seed_virtual}" != "${expected_size}" ]]; then
    ftctl_log_event "colo" "block_conversion.baseline_seed.virtual_size" "fail" "${vm}" "" \
      "target=${target} secondary_dest=${secondary_dest} expected=${expected_size} detected=${seed_virtual} format=${seed_format}"
    ftctl_state_set "${vm}" "last_error=xcolo_secondary_baseline_virtual_size_mismatch:${target}"
    return 1
  fi

  ftctl_state_set "${vm}" \
    "xcolo_disk_${suffix}_baseline_seeded=true" \
    "xcolo_disk_${suffix}_secondary_baseline_format=${seed_format}" \
    "xcolo_disk_${suffix}_secondary_baseline_graph_format=${seed_graph_format}" \
    "xcolo_disk_${suffix}_secondary_baseline_virtual_size=${seed_virtual}" \
    "xcolo_disk_${suffix}_secondary_baseline_actual_size=${seed_actual}" \
    "xcolo_disk_${suffix}_secondary_baseline_target_format=${target_format}"
  ftctl_log_event "colo" "block_conversion.baseline_seed.copy" "ok" "${vm}" "" \
    "target=${target} secondary_dest=${secondary_dest} attempt=${attempt}/${attempts} format=${seed_format} graph_format=${seed_graph_format} virtual=${seed_virtual} actual=${seed_actual}"
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

  : "${uri}${device_id}"
  ftctl_state_set "${vm}" \
    "last_error=xcolo_runtime_guest_disk_hotplug_forbidden" \
    "xcolo_protocol_failure_phase=runtime_guest_disk_device_replace"
  ftctl_log_event "${stage}" "${prefix}.device_replace_forbidden" "fail" "${vm}" "" \
    "qdev=${qdev} drive=${drive} reason=guest_visible_disk_hotplug_forbidden"
  return 1
}

ftctl_xcolo_attach_primary_nbd_child() {
  local vm="${1-}"
  local target="${2-}"
  local nbd_node="${3-}"
  local suffix colo_node

  suffix="$(ftctl_xcolo_disk_suffix "${target}")"
  colo_node="ftctl-colo-${suffix}"
  [[ -n "${nbd_node}" ]] || return 1
  ftctl_xcolo_qmp_require_ok "${FTCTL_PROFILE_PRIMARY_URI}" "${vm}" \
    "{\"execute\":\"x-blockdev-change\",\"arguments\":{\"parent\":\"${colo_node}\",\"node\":\"${nbd_node}\"}}" \
    "colo" "primary.x_blockdev_change.${suffix}" || return 1
}

ftctl_xcolo_attach_secondary_block_graph() {
  local vm="${1-}"
  local base_node="${2-}"
  local hidden="${3-}"
  local active="${4-}"
  local qdev="${5-}"
  local target="${6-}"

  : "${base_node}${hidden}${active}${target}"
  ftctl_xcolo_replace_scsi_disk_device "${FTCTL_PROFILE_SECONDARY_URI}" "${vm}" "${qdev}" \
    "startup-only" "startup-only" "colo" "secondary" || return 1
}

ftctl_xcolo_attach_primary_block_graph() {
  local vm="${1-}"
  local base_node="${2-}"
  local active="${3-}"
  local qdev="${4-}"
  local target="${5-}"

  : "${base_node}${active}${target}"
  ftctl_xcolo_replace_scsi_disk_device "${FTCTL_PROFILE_PRIMARY_URI}" "${vm}" "${qdev}" \
    "startup-only" "startup-only" "colo" "primary" || return 1
}

ftctl_xcolo_attach_primary_block_graph_with_remote() {
  local vm="${1-}"
  local base_node="${2-}"
  local active="${3-}"
  local qdev="${4-}"
  local target="${5-}"
  local nbd_node="${6-}"

  : "${base_node}${active}${target}${nbd_node}"
  ftctl_xcolo_replace_scsi_disk_device "${FTCTL_PROFILE_PRIMARY_URI}" "${vm}" "${qdev}" \
    "startup-only" "startup-only" "colo" "primary" || return 1
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
  local primary_status="" secondary_status=""
  local primary_migrate_error_desc="" secondary_migrate_error_desc=""
  local invalid_message="no"

  ftctl_xcolo_query_migrate_status "${FTCTL_PROFILE_PRIMARY_URI}" "${vm}" primary_migrate || true
  ftctl_xcolo_query_migrate_status "${FTCTL_PROFILE_SECONDARY_URI}" "${secondary_vm}" secondary_migrate || true
  ftctl_xcolo_query_status_name "${FTCTL_PROFILE_PRIMARY_URI}" "${vm}" primary_status || true
  ftctl_xcolo_query_status_name "${FTCTL_PROFILE_SECONDARY_URI}" "${secondary_vm}" secondary_status || true
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
  if [[ "${expected_filter_status}" == "on" ]]; then
    ftctl_xcolo_capture_colo_chardev_contract "${vm}" "${secondary_vm}" "post_migrate_${phase}" || true
  fi
  ftctl_state_set "${vm}" \
    "xcolo_post_migrate_${phase}_primary_migrate_status=${primary_migrate}" \
    "xcolo_post_migrate_${phase}_secondary_migrate_status=${secondary_migrate}" \
    "xcolo_post_migrate_${phase}_primary_status=${primary_status}" \
    "xcolo_post_migrate_${phase}_secondary_status=${secondary_status}" \
    "xcolo_post_migrate_${phase}_primary_colo_mode=${primary_colo}" \
    "xcolo_post_migrate_${phase}_secondary_colo_mode=${secondary_colo}" \
    "xcolo_post_migrate_${phase}_primary_migrate_error_desc=${primary_migrate_error_desc}" \
    "xcolo_post_migrate_${phase}_secondary_migrate_error_desc=${secondary_migrate_error_desc}" \
    "xcolo_post_migrate_${phase}_invalid_message=${invalid_message}" \
    "xcolo_post_migrate_${phase}_filter_expected_status=${expected_filter_status}" \
    "xcolo_post_migrate_${phase}_filter_qom_ready=$(ftctl_state_get "${vm}" "xcolo_primary_filter_qom_ready" 2>/dev/null || true)" \
    "xcolo_post_migrate_${phase}_filter_qom_reason=$(ftctl_state_get "${vm}" "xcolo_primary_filter_qom_reason" 2>/dev/null || true)" \
    "xcolo_post_migrate_${phase}_chardev_contract_ready=$(ftctl_state_get "${vm}" "xcolo_post_migrate_${phase}_chardev_contract_ready" 2>/dev/null || true)" \
    "xcolo_post_migrate_${phase}_chardev_contract_reason=$(ftctl_state_get "${vm}" "xcolo_post_migrate_${phase}_chardev_contract_reason" 2>/dev/null || true)" \
    "xcolo_post_migrate_${phase}_chardev_contract_query_state=$(ftctl_state_get "${vm}" "xcolo_post_migrate_${phase}_chardev_contract_query_state" 2>/dev/null || true)" \
    "xcolo_post_migrate_${phase}_chardev_contract_query_transient=$(ftctl_state_get "${vm}" "xcolo_post_migrate_${phase}_chardev_contract_query_transient" 2>/dev/null || true)"
  ftctl_log_event "colo" "xcolo.post_migrate_transition" "ok" "${vm}" "" \
    "phase=${phase} filter_expected=${expected_filter_status} primary_migrate=${primary_migrate} secondary_migrate=${secondary_migrate} primary_status=${primary_status} secondary_status=${secondary_status} primary_colo=${primary_colo} secondary_colo=${secondary_colo} invalid_message=${invalid_message} chardev_contract=$(ftctl_state_get "${vm}" "xcolo_post_migrate_${phase}_chardev_contract_ready" 2>/dev/null || true) query_state=$(ftctl_state_get "${vm}" "xcolo_post_migrate_${phase}_chardev_contract_query_state" 2>/dev/null || true)"
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

ftctl_xcolo_post_migrate_status_transition_ok() {
  local status="${1-}"
  [[ "${status}" == "active" || "${status}" == "colo" ]]
}

ftctl_xcolo_wait_post_migrate_role_transition() {
  local vm="${1-}"
  local secondary_vm="${2-}"
  local timeout="${FTCTL_XCOLO_POST_MIGRATE_ROLE_TRANSITION_WAIT_SEC:-30}"
  local i primary_migrate secondary_migrate primary_status secondary_status
  local invalid_message chardev_ready chardev_reason query_transient query_state
  local failure_reason="timeout"

  [[ -n "${vm}" && -n "${secondary_vm}" ]] || return 1
  [[ "${timeout}" =~ ^[0-9]+$ && "${timeout}" -gt 0 ]] || timeout="30"

  ftctl_state_set "${vm}" \
    "xcolo_post_migrate_role_transition_gate=waiting" \
    "xcolo_post_migrate_role_transition_attempts=0" \
    "xcolo_post_migrate_role_transition_reason="

  for ((i=0; i<timeout; i++)); do
    ftctl_xcolo_capture_post_migrate_transition_state "${vm}" "${secondary_vm}" "role_transition" "on"
    primary_migrate="$(ftctl_state_get "${vm}" "xcolo_post_migrate_role_transition_primary_migrate_status" 2>/dev/null || true)"
    secondary_migrate="$(ftctl_state_get "${vm}" "xcolo_post_migrate_role_transition_secondary_migrate_status" 2>/dev/null || true)"
    primary_status="$(ftctl_state_get "${vm}" "xcolo_post_migrate_role_transition_primary_status" 2>/dev/null || true)"
    secondary_status="$(ftctl_state_get "${vm}" "xcolo_post_migrate_role_transition_secondary_status" 2>/dev/null || true)"
    invalid_message="$(ftctl_state_get "${vm}" "xcolo_post_migrate_role_transition_invalid_message" 2>/dev/null || true)"
    chardev_ready="$(ftctl_state_get "${vm}" "xcolo_post_migrate_role_transition_chardev_contract_ready" 2>/dev/null || true)"
    chardev_reason="$(ftctl_state_get "${vm}" "xcolo_post_migrate_role_transition_chardev_contract_reason" 2>/dev/null || true)"
    query_transient="$(ftctl_state_get "${vm}" "xcolo_post_migrate_role_transition_chardev_contract_query_transient" 2>/dev/null || true)"
    query_state="$(ftctl_state_get "${vm}" "xcolo_post_migrate_role_transition_chardev_contract_query_state" 2>/dev/null || true)"

    ftctl_state_set "${vm}" \
      "xcolo_post_migrate_role_transition_attempts=$((i + 1))" \
      "xcolo_post_migrate_role_transition_primary_migrate=${primary_migrate}" \
      "xcolo_post_migrate_role_transition_secondary_migrate=${secondary_migrate}" \
      "xcolo_post_migrate_role_transition_primary_status=${primary_status}" \
      "xcolo_post_migrate_role_transition_secondary_status=${secondary_status}" \
      "xcolo_post_migrate_role_transition_chardev_query_state=${query_state}" \
      "xcolo_post_migrate_role_transition_chardev_query_transient=${query_transient}"

    if ftctl_xcolo_post_migrate_secondary_failure_detected "${vm}" "${secondary_vm}" "role_transition"; then
      failure_reason="$(ftctl_state_get "${vm}" "xcolo_post_migrate_secondary_failure_reason" 2>/dev/null || true)"
      [[ -n "${failure_reason}" ]] || failure_reason="secondary_runtime_missing_after_migrate"
      ftctl_state_set "${vm}" \
        "xcolo_post_migrate_role_transition_gate=failed" \
        "xcolo_post_migrate_role_transition_reason=${failure_reason}" \
        "xcolo_protocol_failure_phase=post_migrate_secondary_crash" \
        "xcolo_primary_filter_activation_failed_reason=${failure_reason}"
      ftctl_log_event "colo" "xcolo.post_migrate_role_transition_gate" "fail" "${vm}" "" \
        "reason=${failure_reason} attempts=$((i + 1)) primary_migrate=${primary_migrate} secondary_migrate=${secondary_migrate} query_state=${query_state}"
      return 1
    fi

    if [[ "${invalid_message}" == "yes" ]]; then
      failure_reason="invalid_message_after_migrate"
      ftctl_state_set "${vm}" \
        "xcolo_post_migrate_role_transition_gate=failed" \
        "xcolo_post_migrate_role_transition_reason=${failure_reason}" \
        "xcolo_protocol_failure_phase=post_migrate_role_transition" \
        "last_error=xcolo_migrate_stream_failed_during_role_transition"
      ftctl_log_event "colo" "xcolo.post_migrate_role_transition_gate" "fail" "${vm}" "" \
        "reason=${failure_reason} primary_migrate=${primary_migrate} secondary_migrate=${secondary_migrate} query_state=${query_state}"
      return 1
    fi

    if [[ "${primary_migrate}" == "failed" || "${secondary_migrate}" == "failed" ]]; then
      failure_reason="migrate_failed"
      ftctl_state_set "${vm}" \
        "xcolo_post_migrate_role_transition_gate=failed" \
        "xcolo_post_migrate_role_transition_reason=${failure_reason}" \
        "xcolo_protocol_failure_phase=post_migrate_role_transition" \
        "last_error=xcolo_post_migrate_role_transition_failed"
      ftctl_log_event "colo" "xcolo.post_migrate_role_transition_gate" "fail" "${vm}" "" \
        "reason=${failure_reason} primary_migrate=${primary_migrate} secondary_migrate=${secondary_migrate} query_state=${query_state}"
      return 1
    fi

    if ftctl_xcolo_post_migrate_status_transition_ok "${primary_migrate}" &&
        ftctl_xcolo_post_migrate_status_transition_ok "${secondary_migrate}" &&
        [[ "${chardev_ready}" == "yes" ]]; then
      ftctl_state_set "${vm}" \
        "xcolo_post_migrate_role_transition_gate=ready" \
        "xcolo_post_migrate_role_transition_reason=ready"
      ftctl_log_event "colo" "xcolo.post_migrate_role_transition_gate" "ok" "${vm}" "" \
        "attempts=$((i + 1)) primary_migrate=${primary_migrate} secondary_migrate=${secondary_migrate} primary_status=${primary_status} secondary_status=${secondary_status} query_state=${query_state}"
      return 0
    fi

    if [[ "${query_transient}" == "yes" ]]; then
      failure_reason="chardev_query_transient"
    elif [[ -n "${chardev_reason}" ]]; then
      failure_reason="${chardev_reason}"
    else
      failure_reason="role_transition_not_ready"
    fi
    sleep 1
  done

  ftctl_xcolo_capture_post_migrate_secondary_failure_evidence "${vm}" "${secondary_vm}" "post_migrate_role_transition_timeout" || true
  if ftctl_xcolo_secondary_qemu_assert_memory_region_container_observed "${vm}" "${secondary_vm}"; then
    ftctl_state_set "${vm}" \
      "xcolo_post_migrate_role_transition_gate=failed" \
      "xcolo_post_migrate_role_transition_reason=secondary_qemu_assert_memory_region_container" \
      "xcolo_protocol_failure_phase=post_migrate_secondary_crash" \
      "xcolo_secondary_qemu_assert=memory_region_add_subregion_common" \
      "xcolo_secondary_crash_detected=yes" \
      "xcolo_primary_filter_activation_failed_reason=secondary_qemu_assert_memory_region_container" \
      "last_error=xcolo_secondary_qemu_assert_memory_region_container"
    ftctl_log_event "colo" "xcolo.post_migrate_role_transition_gate" "fail" "${vm}" "" \
      "reason=secondary_qemu_assert_memory_region_container attempts=${timeout} primary_migrate=$(ftctl_state_get "${vm}" "xcolo_post_migrate_role_transition_primary_migrate" 2>/dev/null || true) secondary_migrate=$(ftctl_state_get "${vm}" "xcolo_post_migrate_role_transition_secondary_migrate" 2>/dev/null || true)"
    return 1
  fi

  if [[ "${failure_reason}" == *"query"* ]]; then
    ftctl_state_set "${vm}" \
      "xcolo_post_migrate_role_transition_gate=failed" \
      "xcolo_post_migrate_role_transition_reason=${failure_reason}" \
      "xcolo_protocol_failure_phase=post_migrate_role_transition" \
      "xcolo_primary_filter_activation_failed_reason=${failure_reason}" \
      "last_error=xcolo_secondary_chardev_query_unstable_after_migrate"
  else
    ftctl_state_set "${vm}" \
      "xcolo_post_migrate_role_transition_gate=failed" \
      "xcolo_post_migrate_role_transition_reason=${failure_reason}" \
      "xcolo_protocol_failure_phase=post_migrate_chardev_contract" \
      "xcolo_primary_filter_activation_failed_reason=${failure_reason}" \
      "last_error=xcolo_colo_chardev_contract_not_ready"
  fi
  ftctl_log_event "colo" "xcolo.post_migrate_role_transition_gate" "fail" "${vm}" "" \
    "reason=${failure_reason} attempts=${timeout} primary_migrate=$(ftctl_state_get "${vm}" "xcolo_post_migrate_role_transition_primary_migrate" 2>/dev/null || true) secondary_migrate=$(ftctl_state_get "${vm}" "xcolo_post_migrate_role_transition_secondary_migrate" 2>/dev/null || true) query_state=$(ftctl_state_get "${vm}" "xcolo_post_migrate_role_transition_chardev_query_state" 2>/dev/null || true)"
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
  if ! ftctl_xcolo_wait_post_migrate_role_transition "${vm}" "${secondary_vm}"; then
    ftctl_log_event "colo" "xcolo.post_migrate_filter_activation" "fail" "${vm}" "" \
      "mode=startup-active reason=role_transition_not_ready gate_reason=$(ftctl_state_get "${vm}" "xcolo_post_migrate_role_transition_reason" 2>/dev/null || true)"
    return 1
  fi
  if ! ftctl_xcolo_require_post_migrate_materialization_gate "${vm}" "${secondary_vm}" "after_migrate_materialization"; then
    ftctl_log_event "colo" "xcolo.post_migrate_filter_activation" "fail" "${vm}" "" \
      "mode=startup-active reason=post_migrate_materialization_not_ready gate_reason=$(ftctl_state_get "${vm}" "xcolo_post_migrate_materialization_topology_gate_reason" 2>/dev/null || true)"
    return 1
  fi
  if ! ftctl_xcolo_wait_colo_chardev_contract "${vm}" "${secondary_vm}" "post_activation_contract"; then
    if ftctl_xcolo_primary_invalid_message_observed "${vm}" ||
        ftctl_xcolo_primary_log_has_filter_mirror_send_failure "${vm}"; then
      ftctl_xcolo_classify_startup_active_stream_failure "${vm}" "${secondary_vm}" || true
    else
      ftctl_state_set "${vm}" \
        "xcolo_primary_net_filters_activated=false" \
        "xcolo_protocol_failure_phase=post_migrate_chardev_contract" \
        "xcolo_primary_filter_activation_failed_reason=$(ftctl_state_get "${vm}" "xcolo_chardev_contract_gate_reason" 2>/dev/null || true)" \
        "last_error=xcolo_colo_chardev_contract_not_ready"
    fi
    ftctl_log_event "colo" "xcolo.post_migrate_filter_activation" "fail" "${vm}" "" \
      "mode=startup-active reason=chardev_contract_not_ready contract_reason=$(ftctl_state_get "${vm}" "xcolo_chardev_contract_gate_reason" 2>/dev/null || true)"
    return 1
  fi
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
  ftctl_xcolo_require_secondary_startup_materialization_gate "${vm}" "${secondary_vm}" "secondary_startup_materialization" || return 1
  ftctl_xcolo_secondary_accept_deferred_incoming "${vm}" "${secondary_vm}" "pre_migrate" || return 1
  ftctl_xcolo_require_pre_migrate_receiver_ready "${vm}" "${secondary_vm}" "pre_migrate_receiver" || return 1
  ftctl_xcolo_require_pre_migrate_runtime_topology_gate "${vm}" "${secondary_vm}" "before_migrate" || return 1
  ftctl_xcolo_require_primary_krbd_materialized_before_migrate "${vm}" || return 1
  ftctl_xcolo_record_pre_migrate_materialization_result "${vm}"
  ftctl_xcolo_assert_no_premigrate_filter_mirror_send "${vm}" "before_migrate" || return 1
  ftctl_xcolo_gate_before_guest_traffic "${vm}" "${secondary_vm}" || return 1
  ftctl_xcolo_resume_primary_before_migrate "${vm}" || return 1
  ftctl_xcolo_wait_primary_premigrate_boot_ready "${vm}" "${secondary_vm}" "" || return 1
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
    secondary_base_node="$(ftctl_state_get "${vm}" "xcolo_disk_${suffix}_secondary_base_node" 2>/dev/null || true)"
    nbd_node="${FTCTL_PROFILE_XCOLO_NBD_NODE}-${suffix}"
    export_node="${secondary_base_node}"
    [[ -n "${secondary_base_node}" ]] || return 1
    ftctl_xcolo_qmp_require_ok "${FTCTL_PROFILE_PRIMARY_URI}" "${vm}" \
      "{\"execute\":\"blockdev-add\",\"arguments\":{\"driver\":\"nbd\",\"node-name\":\"${nbd_node}\",\"server\":{\"type\":\"inet\",\"host\":\"${nbd_host}\",\"port\":\"${nbd_port}\"},\"export\":\"${export_node}\",\"detect-zeroes\":\"on\"}}" \
      "colo" "primary.blockdev_add.${suffix}" || return 1
    ftctl_xcolo_attach_primary_nbd_child "${vm}" "${target}" "${nbd_node}" || return 1
  done

  ftctl_xcolo_validate_pre_migrate_contract "${vm}" "${secondary_vm}" "${disk_plan}" "pre_migrate_contract" || return 1
  ftctl_xcolo_attach_primary_net_filters "${vm}" || return 1
  ftctl_xcolo_set_and_verify_migrate_capabilities "${FTCTL_PROFILE_PRIMARY_URI}" "${vm}" "${vm}" "primary" "primary" || return 1
  ftctl_xcolo_require_checkpoint_delay_before_migrate "${vm}" || return 1
  ftctl_xcolo_record_pre_migrate_evidence "${vm}" "on" || true
  ftctl_xcolo_preflight_firewall_contract "${vm}" || return 1
  ftctl_xcolo_require_primary_filter_cmdline_ready "${vm}" "pre_migrate" || return 1
  ftctl_xcolo_require_topology_audit_ready "${vm}" "${secondary_vm}" "pre_migrate" || return 1
  ftctl_xcolo_require_secondary_startup_materialization_gate "${vm}" "${secondary_vm}" "secondary_startup_materialization" || return 1
  ftctl_xcolo_secondary_accept_deferred_incoming "${vm}" "${secondary_vm}" "pre_migrate" || return 1
  ftctl_xcolo_require_pre_migrate_receiver_ready "${vm}" "${secondary_vm}" "pre_migrate_receiver" || return 1
  ftctl_xcolo_require_pre_migrate_runtime_topology_gate "${vm}" "${secondary_vm}" "before_migrate" || return 1
  ftctl_xcolo_require_primary_krbd_materialized_before_migrate "${vm}" || return 1
  ftctl_xcolo_record_pre_migrate_materialization_result "${vm}"
  ftctl_xcolo_assert_no_premigrate_filter_mirror_send "${vm}" "before_migrate" || return 1
  ftctl_xcolo_gate_before_guest_traffic "${vm}" "${secondary_vm}" || return 1
  ftctl_xcolo_resume_primary_before_migrate "${vm}" || return 1
  ftctl_xcolo_wait_primary_premigrate_boot_ready "${vm}" "${secondary_vm}" "${disk_plan}" || return 1
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
  ftctl_xcolo_prepare_primary_krbd_runtime_paths_from_xml "${vm}" "${generated_xml}" "primary_create" || {
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
  local timeout_sec="${FTCTL_XCOLO_DOMAIN_CREATE_TIMEOUT_SEC:-180}"
  if [[ -z "${timeout_sec}" || ! "${timeout_sec}" =~ ^[0-9]+$ || "${timeout_sec}" -lt 15 ]]; then
    timeout_sec=180
  fi
  printf '%s\n' "${timeout_sec}"
}

ftctl_xcolo_primary_krbd_hold_dir() {
  local vm="${1-}"
  printf '%s\n' "${FTCTL_RUN_DIR:-/run/ablestack-vm-ftctl}/krbd-hold/${vm}"
}

ftctl_xcolo_primary_krbd_guard_dir() {
  local vm="${1-}"
  printf '%s\n' "${FTCTL_RUN_DIR:-/run/ablestack-vm-ftctl}/krbd-guard/${vm}"
}

ftctl_xcolo_primary_krbd_pin_dir() {
  local vm="${1-}"
  printf '%s\n' "${FTCTL_RUN_DIR:-/run/ablestack-vm-ftctl}/krbd-pin/${vm}"
}

ftctl_xcolo_primary_parent_nbd_dir() {
  local vm="${1-}"
  printf '%s\n' "${FTCTL_RUN_DIR:-/run/ablestack-vm-ftctl}/xcolo-parent-nbd/${vm}"
}

ftctl_xcolo_path_safe_name() {
  local value="${1-}"
  printf '%s' "${value}" | sed 's#[^A-Za-z0-9_.-]#_#g'
}

ftctl_xcolo_libvirt_qemu_identity() {
  local out_user="${1-}"
  local out_group="${2-}"
  local conf="${FTCTL_LIBVIRT_QEMU_CONF:-/etc/libvirt/qemu.conf}"
  local resolved_user="${FTCTL_LIBVIRT_QEMU_USER:-qemu}"
  local resolved_group="${FTCTL_LIBVIRT_QEMU_GROUP:-qemu}"
  local parsed

  [[ -n "${out_user}" && -n "${out_group}" ]] || return 1

  if [[ -r "${conf}" ]]; then
    parsed="$(awk -F= '
      /^[[:space:]]*#/ { next }
      /^[[:space:]]*user[[:space:]]*=/ {
        value=$2
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
        gsub(/^"|"$/, "", value)
        print value
        exit
      }
    ' "${conf}" 2>/dev/null || true)"
    [[ -n "${parsed}" ]] && resolved_user="${parsed}"
    parsed="$(awk -F= '
      /^[[:space:]]*#/ { next }
      /^[[:space:]]*group[[:space:]]*=/ {
        value=$2
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
        gsub(/^"|"$/, "", value)
        print value
        exit
      }
    ' "${conf}" 2>/dev/null || true)"
    [[ -n "${parsed}" ]] && resolved_group="${parsed}"
  fi

  if ! getent passwd "${resolved_user}" >/dev/null 2>&1; then
    resolved_user="qemu"
  fi
  if ! getent group "${resolved_group}" >/dev/null 2>&1; then
    resolved_group="$(id -gn "${resolved_user}" 2>/dev/null || true)"
  fi
  if [[ -z "${resolved_group}" ]] || ! getent group "${resolved_group}" >/dev/null 2>&1; then
    resolved_group="${resolved_user}"
  fi
  if [[ -z "${resolved_user}" || -z "${resolved_group}" ]]; then
    return 1
  fi
  if ! getent passwd "${resolved_user}" >/dev/null 2>&1; then
    return 1
  fi
  if ! getent group "${resolved_group}" >/dev/null 2>&1; then
    return 1
  fi

  printf -v "${out_user}" '%s' "${resolved_user}"
  printf -v "${out_group}" '%s' "${resolved_group}"
}

ftctl_xcolo_fix_parent_nbd_socket_permissions() {
  local vm="${1-}"
  local target="${2-}"
  local socket_path="${3-}"
  local dir="${4-}"
  local qemu_user="" qemu_group="" base_dir

  [[ -n "${vm}" && -n "${target}" && -n "${socket_path}" && -n "${dir}" ]] || return 1
  [[ -S "${socket_path}" ]] || return 1

  if ! ftctl_xcolo_libvirt_qemu_identity qemu_user qemu_group; then
    ftctl_state_set "${vm}" "last_error=xcolo_primary_parent_nbd_identity_failed"
    ftctl_log_event "colo" "xcolo.primary_parent_nbd.permission" "fail" "${vm}" "" \
      "target=${target} socket=${socket_path} reason=qemu_identity_unresolved"
    return 1
  fi
  if [[ -z "${qemu_user}" || -z "${qemu_group}" ]]; then
    ftctl_state_set "${vm}" "last_error=xcolo_primary_parent_nbd_identity_failed"
    ftctl_log_event "colo" "xcolo.primary_parent_nbd.permission" "fail" "${vm}" "" \
      "target=${target} socket=${socket_path} reason=qemu_identity_empty user=${qemu_user} group=${qemu_group}"
    return 1
  fi

  base_dir="$(dirname "${dir}")"
  if getent group "${qemu_group}" >/dev/null 2>&1; then
    chgrp "${qemu_group}" "${base_dir}" "${dir}" "${socket_path}" >/dev/null 2>&1 || true
    chmod 0750 "${base_dir}" >/dev/null 2>&1 || true
    chmod 0770 "${dir}" >/dev/null 2>&1 || true
    chmod 0660 "${socket_path}" >/dev/null 2>&1 || true
  fi

  if command -v setfacl >/dev/null 2>&1; then
    setfacl -m "u:${qemu_user}:rx" "${base_dir}" >/dev/null 2>&1 || true
    setfacl -m "u:${qemu_user}:rwx" "${dir}" >/dev/null 2>&1 || true
    setfacl -m "u:${qemu_user}:rw" "${socket_path}" >/dev/null 2>&1 || true
  fi

  ftctl_log_event "colo" "xcolo.primary_parent_nbd.permission" "ok" "${vm}" "" \
    "target=${target} socket=${socket_path} user=${qemu_user} group=${qemu_group}"
}

ftctl_xcolo_probe_parent_nbd_as_qemu_user() {
  local vm="${1-}"
  local target="${2-}"
  local socket_path="${3-}"
  local export_name="${4-}"
  local qemu_user="" qemu_group="" out="" err="" rc=0 uri opts

  [[ -n "${vm}" && -n "${target}" && -n "${socket_path}" && -n "${export_name}" ]] || return 1
  command -v qemu-img >/dev/null 2>&1 || return 0
  command -v runuser >/dev/null 2>&1 || return 0
  if ! ftctl_xcolo_libvirt_qemu_identity qemu_user qemu_group; then
    ftctl_state_set "${vm}" "last_error=xcolo_primary_parent_nbd_identity_failed"
    ftctl_log_event "colo" "xcolo.primary_parent_nbd.qemu_user_probe" "fail" "${vm}" "" \
      "target=${target} socket=${socket_path} export=${export_name} reason=qemu_identity_unresolved"
    return 1
  fi
  if [[ -z "${qemu_user}" || -z "${qemu_group}" ]]; then
    ftctl_state_set "${vm}" "last_error=xcolo_primary_parent_nbd_identity_failed"
    ftctl_log_event "colo" "xcolo.primary_parent_nbd.qemu_user_probe" "fail" "${vm}" "" \
      "target=${target} socket=${socket_path} export=${export_name} reason=qemu_identity_empty user=${qemu_user} group=${qemu_group}"
    return 1
  fi

  uri="nbd+unix:///${export_name}?socket=${socket_path}"
  ftctl_cmd_run "${FTCTL_BLOCKCOPY_WAIT_TIMEOUT_SEC:-15}" out err rc -- \
    runuser -u "${qemu_user}" -- qemu-img info --force-share "${uri}" || true
  if [[ "${rc}" != "0" ]]; then
    out=""
    err=""
    rc=0
    opts="driver=nbd,server.type=unix,server.path=${socket_path},export=${export_name}"
    ftctl_cmd_run "${FTCTL_BLOCKCOPY_WAIT_TIMEOUT_SEC:-15}" out err rc -- \
      runuser -u "${qemu_user}" -- qemu-img info --force-share --image-opts "${opts}" || true
  fi
  if [[ "${rc}" != "0" ]]; then
    ftctl_state_set "${vm}" "last_error=xcolo_primary_parent_nbd_permission_failed"
    ftctl_log_event "colo" "xcolo.primary_parent_nbd.qemu_user_probe" "fail" "${vm}" "${rc}" \
      "target=${target} socket=${socket_path} export=${export_name} user=${qemu_user} error=$(ftctl_xcolo_compact_log_value "${err:-${out}}")"
    return 1
  fi

  ftctl_log_event "colo" "xcolo.primary_parent_nbd.qemu_user_probe" "ok" "${vm}" "" \
    "target=${target} socket=${socket_path} export=${export_name} user=${qemu_user} group=${qemu_group}"
}

ftctl_xcolo_stop_primary_parent_nbd_adapters() {
  local vm="${1-}"
  local reason="${2:-release}"
  local dir pid_file pid proc_cmd cmdline killed=0

  [[ -n "${vm}" ]] || return 1
  dir="$(ftctl_xcolo_primary_parent_nbd_dir "${vm}")"
  [[ -d "${dir}" ]] || return 0

  for pid_file in "${dir}"/*.pid; do
    [[ -f "${pid_file}" ]] || continue
    pid="$(cat "${pid_file}" 2>/dev/null || true)"
    if [[ -n "${pid}" && "${pid}" =~ ^[0-9]+$ && -d "/proc/${pid}" ]]; then
      kill "${pid}" >/dev/null 2>&1 || true
      killed=$((killed + 1))
    fi
    rm -f -- "${pid_file}" 2>/dev/null || true
  done

  for proc_cmd in /proc/[0-9]*/cmdline; do
    [[ -r "${proc_cmd}" ]] || continue
    pid="${proc_cmd#/proc/}"
    pid="${pid%%/*}"
    [[ -n "${pid}" && "${pid}" =~ ^[0-9]+$ ]] || continue
    [[ "${pid}" != "$$" ]] || continue
    cmdline="$(tr '\0' ' ' < "${proc_cmd}" 2>/dev/null || true)"
    [[ "${cmdline}" == *qemu-nbd* && "${cmdline}" == *"${dir}"* ]] || continue
    kill "${pid}" >/dev/null 2>&1 || true
    killed=$((killed + 1))
  done

  rm -rf -- "${dir}" 2>/dev/null || true
  ftctl_log_event "colo" "xcolo.primary_parent_nbd.release" "ok" "${vm}" ""     "reason=${reason} dir=${dir} killed=${killed}"
}

ftctl_xcolo_probe_primary_parent_nbd_adapter() {
  local vm="${1-}"
  local target="${2-}"
  local socket_path="${3-}"
  local export_name="${4-}"
  local out="" err="" rc=0 uri opts

  [[ -n "${vm}" && -n "${target}" && -n "${socket_path}" && -n "${export_name}" ]] || return 1
  [[ -S "${socket_path}" ]] || {
    ftctl_state_set "${vm}" "last_error=xcolo_parent_nbd_adapter_socket_missing"
    ftctl_log_event "colo" "xcolo.primary_parent_nbd.probe" "fail" "${vm}" ""       "target=${target} socket=${socket_path} export=${export_name} reason=socket_missing"
    return 1
  }
  command -v qemu-img >/dev/null 2>&1 || return 0

  uri="nbd+unix:///${export_name}?socket=${socket_path}"
  ftctl_cmd_run "${FTCTL_BLOCKCOPY_WAIT_TIMEOUT_SEC:-15}" out err rc --     qemu-img info --force-share "${uri}" >/dev/null 2>&1 || true
  if [[ "${rc}" != "0" ]]; then
    out=""
    err=""
    rc=0
    opts="driver=nbd,server.type=unix,server.path=${socket_path},export=${export_name}"
    ftctl_cmd_run "${FTCTL_BLOCKCOPY_WAIT_TIMEOUT_SEC:-15}" out err rc --       qemu-img info --force-share --image-opts "${opts}" >/dev/null 2>&1 || true
  fi
  if [[ "${rc}" != "0" ]]; then
    ftctl_state_set "${vm}" "last_error=xcolo_parent_nbd_adapter_probe_failed"
    ftctl_log_event "colo" "xcolo.primary_parent_nbd.probe" "fail" "${vm}" "${rc}"       "target=${target} socket=${socket_path} export=${export_name} error=$(ftctl_xcolo_compact_log_value "${err:-${out}}")"
    return 1
  fi

  ftctl_log_event "colo" "xcolo.primary_parent_nbd.probe" "ok" "${vm}" ""     "target=${target} socket=${socket_path} export=${export_name}"
}

ftctl_xcolo_start_primary_parent_nbd_adapter() {
  local vm="${1-}"
  local target="${2-}"
  local krbd_path="${3-}"
  local source_format="${4:-raw}"
  local phase="${5:-startup_disk_graph}"
  local out_var="${6}"
  local dir suffix socket_path export_name pid_file out="" err="" rc=0 wait_i

  [[ -n "${vm}" && -n "${target}" && -n "${krbd_path}" && -n "${out_var}" ]] || return 1
  ftctl_blockcopy_is_krbd_path "${krbd_path}" || return 1
  [[ -n "${source_format}" ]] || source_format="raw"

  ftctl_xcolo_prepare_primary_krbd_runtime_path "${vm}" "${krbd_path}" "${phase}_parent_nbd" || return $?

  dir="$(ftctl_xcolo_primary_parent_nbd_dir "${vm}")"
  mkdir -p "${dir}" 2>/dev/null || true
  suffix="$(ftctl_xcolo_disk_suffix "${target}")"
  socket_path="${dir}/${suffix}.sock"
  export_name="ftctl-primary-parent-${suffix}"
  pid_file="${dir}/${suffix}.pid"
  rm -f -- "${socket_path}" "${pid_file}" 2>/dev/null || true

  out=""
  err=""
  rc=0
  ftctl_cmd_run "${FTCTL_BLOCKCOPY_WAIT_TIMEOUT_SEC:-15}" out err rc --     qemu-nbd --fork --persistent --read-only --shared=8       --socket "${socket_path}"       --export-name "${export_name}"       --format "${source_format}"       --pid-file "${pid_file}"       "${krbd_path}" || true
  if [[ "${rc}" != "0" ]]; then
    ftctl_state_set "${vm}" "last_error=xcolo_parent_nbd_adapter_start_failed"
    ftctl_log_event "colo" "xcolo.primary_parent_nbd.start" "fail" "${vm}" "${rc}"       "phase=${phase} target=${target} krbd=${krbd_path} socket=${socket_path} export=${export_name} error=$(ftctl_xcolo_compact_log_value "${err:-${out}}")"
    return 1
  fi

  for wait_i in 1 2 3 4 5; do
    [[ -S "${socket_path}" ]] && break
    sleep 1
  done
  ftctl_xcolo_fix_parent_nbd_socket_permissions "${vm}" "${target}" "${socket_path}" "${dir}" || return $?
  ftctl_xcolo_probe_primary_parent_nbd_adapter "${vm}" "${target}" "${socket_path}" "${export_name}" || return $?
  ftctl_xcolo_probe_parent_nbd_as_qemu_user "${vm}" "${target}" "${socket_path}" "${export_name}" || return $?

  ftctl_log_event "colo" "xcolo.primary_parent_nbd.start" "ok" "${vm}" ""     "phase=${phase} target=${target} krbd=${krbd_path} socket=${socket_path} export=${export_name} pid=$(cat "${pid_file}" 2>/dev/null || true)"
  printf -v "${out_var}" '%s|%s|%s' "${krbd_path}" "${socket_path}" "${export_name}"
}

ftctl_xcolo_prepare_primary_parent_nbd_adapters() {
  local vm="${1-}"
  local disk_runtime="${2-}"
  local out_var="${3}"
  local phase="${4:-startup_disk_graph}"
  local entries=() entry target primary_source primary_format primary_active secondary_dest secondary_hidden secondary_active secondary_format
  local record map="" count=0

  [[ -n "${vm}" && -n "${out_var}" ]] || return 1
  printf -v "${out_var}" '%s' ""
  [[ -n "${disk_runtime}" ]] || return 0

  ftctl_xcolo_stop_primary_parent_nbd_adapters "${vm}" "prepare_refresh" || true
  IFS=';' read -r -a entries <<< "${disk_runtime}"
  for entry in "${entries[@]}"; do
    [[ -n "${entry}" ]] || continue
    IFS='|' read -r target primary_source primary_format primary_active secondary_dest secondary_hidden secondary_active secondary_format <<< "${entry}"
    : "${primary_active}${secondary_dest}${secondary_hidden}${secondary_active}${secondary_format}"
    ftctl_blockcopy_is_krbd_path "${primary_source}" || continue
    [[ -n "${primary_format}" ]] || primary_format="raw"
    ftctl_xcolo_start_primary_parent_nbd_adapter "${vm}" "${target}" "${primary_source}" "${primary_format}" "${phase}" record || return $?
    map="${map}${map:+;}${record}"
    count=$((count + 1))
  done

  if [[ "${count}" -gt 0 ]]; then
    ftctl_state_set "${vm}"       "xcolo_primary_parent_nbd_adapter=enabled"       "xcolo_primary_parent_nbd_adapter_count=${count}"       "xcolo_primary_parent_nbd_adapter_map=$(ftctl_xcolo_compact_log_value "${map}")"       "xcolo_startup_disk_parent_backend=krbd-nbd-adapter"
    ftctl_log_event "colo" "xcolo.primary_parent_nbd.prepare" "ok" "${vm}" ""       "phase=${phase} count=${count} map=$(ftctl_xcolo_compact_log_value "${map}")"
  else
    ftctl_state_set "${vm}"       "xcolo_primary_parent_nbd_adapter=disabled"       "xcolo_primary_parent_nbd_adapter_count=0"
    ftctl_log_event "colo" "xcolo.primary_parent_nbd.prepare" "skip" "${vm}" ""       "phase=${phase} reason=no_primary_krbd_parent"
  fi
  printf -v "${out_var}" '%s' "${map}"
}

ftctl_xcolo_extract_krbd_paths_from_generated_xml() {
  local xml_path="${1-}"
  local out_array_name="${2}"
  local payload line
  local -n _out_array="${out_array_name}"

  _out_array=()
  [[ -n "${xml_path}" && -f "${xml_path}" ]] || return 1
  command -v python3 >/dev/null 2>&1 || return 2

  payload="$(XML_PATH="${xml_path}" python3 - <<'PY'
import os
import re
import xml.etree.ElementTree as ET

xml_path = os.environ["XML_PATH"]
root = ET.parse(xml_path).getroot()
seen = set()

def emit(value):
    if not value:
        return
    if value.startswith("/dev/rbd/") and value not in seen:
        seen.add(value)
        print(value)

devices = root.find("devices")
if devices is not None:
    for disk in devices.findall("disk"):
        source = disk.find("source")
        if source is None:
            continue
        for attr in ("dev", "file", "name"):
            emit(source.get(attr, ""))

pattern = re.compile(r"(/dev/rbd/[^,;\s'\"]+)")
for elem in root.iter():
    if not elem.tag.endswith("arg"):
        continue
    value = elem.get("value", "")
    for match in pattern.findall(value):
        emit(match)
PY
)" || return $?

  while IFS= read -r line; do
    [[ -n "${line}" ]] || continue
    _out_array+=("${line}")
  done <<< "${payload}"
}

ftctl_xcolo_prepare_primary_krbd_runtime_path() {
  local vm="${1-}"
  local path="${2-}"
  local phase="${3:-primary_create}"
  local hold_dir hold_file safe real qemu_user="qemu" access_out="" access_err="" access_rc=0
  local open_out="" open_err="" open_rc=0

  [[ -n "${vm}" && -n "${path}" ]] || return 1
  ftctl_blockcopy_is_krbd_path "${path}" || return 0

  ftctl_blockcopy_krbd_map_local "${path}" || {
    ftctl_state_set "${vm}" "last_error=xcolo_primary_krbd_map_failed"
    ftctl_log_event "colo" "xcolo.primary_krbd_runtime_path" "fail" "${vm}" "" \
      "phase=${phase} path=${path} reason=map_failed"
    return 1
  }
  local settle_attempts="${FTCTL_XCOLO_KRBD_SETTLE_ATTEMPTS:-8}"
  local settle_sleep="${FTCTL_XCOLO_KRBD_SETTLE_SLEEP_SEC:-1}"
  local settle_i stable_count=0
  [[ "${settle_attempts}" =~ ^[0-9]+$ && "${settle_attempts}" -gt 0 ]] || settle_attempts=8
  [[ "${settle_sleep}" =~ ^[0-9]+$ ]] || settle_sleep=1

  for ((settle_i=0; settle_i<settle_attempts; settle_i++)); do
    udevadm settle >/dev/null 2>&1 || true
    if [[ -b "${path}" ]]; then
      stable_count=$((stable_count + 1))
      if [[ "${stable_count}" -ge 2 ]]; then
        break
      fi
    else
      stable_count=0
    fi
    sleep "${settle_sleep}"
  done
  [[ -b "${path}" && "${stable_count}" -ge 2 ]] || {
    ftctl_state_set "${vm}" \
      "xcolo_primary_krbd_settle_attempts=${settle_attempts}" \
      "xcolo_primary_krbd_settle_stable_count=${stable_count}" \
      "last_error=xcolo_primary_krbd_path_lost_before_create"
    ftctl_log_event "colo" "xcolo.primary_krbd_runtime_path" "fail" "${vm}" "" \
      "phase=${phase} path=${path} reason=stable_path_missing_after_map attempts=${settle_attempts} stable_count=${stable_count}"
    return 1
  }

  real="$(readlink -f "${path}" 2>/dev/null || true)"
  [[ -n "${real}" && -b "${real}" ]] || real="${path}"

  hold_dir="$(ftctl_xcolo_primary_krbd_hold_dir "${vm}")"
  mkdir -p "${hold_dir}" 2>/dev/null || true
  safe="$(ftctl_xcolo_path_safe_name "${path}")"
  hold_file="${hold_dir}/${safe}.hold"
  {
    printf 'vm=%s\n' "${vm}"
    printf 'phase=%s\n' "${phase}"
    printf 'path=%s\n' "${path}"
    printf 'resolved=%s\n' "${real}"
    printf 'created=%s\n' "$(date -Is 2>/dev/null || true)"
  } > "${hold_file}" 2>/dev/null || true

  if getent passwd "${qemu_user}" >/dev/null 2>&1; then
    if command -v setfacl >/dev/null 2>&1; then
      setfacl -m "u:${qemu_user}:rw" "${real}" >/dev/null 2>&1 || true
    elif getent group "${qemu_user}" >/dev/null 2>&1; then
      chgrp "${qemu_user}" "${real}" >/dev/null 2>&1 || true
      chmod g+rw "${real}" >/dev/null 2>&1 || true
    fi
    ftctl_cmd_run "${FTCTL_BLOCKCOPY_WAIT_TIMEOUT_SEC:-15}" access_out access_err access_rc -- \
      runuser -u "${qemu_user}" -- bash -c 'test -r "$1" && test -w "$1"' _ "${path}" || true
    : "${access_out}"
    if [[ "${access_rc}" != "0" ]]; then
      ftctl_state_set "${vm}" "last_error=xcolo_primary_krbd_access_denied_before_create"
      ftctl_log_event "colo" "xcolo.primary_krbd_runtime_path" "fail" "${vm}" "${access_rc}" \
        "phase=${phase} path=${path} resolved=${real} reason=qemu_user_access_failed error=$(ftctl_xcolo_compact_log_value "${access_err}")"
      return 1
    fi
  fi

  if command -v qemu-img >/dev/null 2>&1; then
    open_out=""
    open_err=""
    open_rc=0
    ftctl_cmd_run "${FTCTL_BLOCKCOPY_WAIT_TIMEOUT_SEC:-15}" open_out open_err open_rc -- \
      qemu-img info --force-share "${path}" >/dev/null 2>&1 || true
    if [[ "${open_rc}" != "0" ]]; then
      open_out=""
      open_err=""
      open_rc=0
      ftctl_cmd_run "${FTCTL_BLOCKCOPY_WAIT_TIMEOUT_SEC:-15}" open_out open_err open_rc -- \
        qemu-img info "${path}" >/dev/null 2>&1 || true
    fi
    if [[ "${open_rc}" != "0" ]]; then
      ftctl_state_set "${vm}" "last_error=xcolo_primary_krbd_open_failed_before_create"
      ftctl_log_event "colo" "xcolo.primary_krbd_runtime_path" "fail" "${vm}" "${open_rc}" \
        "phase=${phase} path=${path} resolved=${real} reason=qemu_img_open_failed output=$(ftctl_xcolo_compact_log_value "${open_out}") error=$(ftctl_xcolo_compact_log_value "${open_err}")"
      return 1
    fi
  fi

  ftctl_xcolo_pin_primary_krbd_runtime_path "${vm}" "${path}" "${phase}" || return $?

  ftctl_log_event "colo" "xcolo.primary_krbd_runtime_path" "ok" "${vm}" "" \
    "phase=${phase} path=${path} resolved=${real} hold=${hold_file}"
}

ftctl_xcolo_pin_primary_krbd_runtime_path() {
  local vm="${1-}"
  local path="${2-}"
  local phase="${3:-primary_create}"
  local pin_dir safe pid_file path_file real existing_pid pin_pid

  [[ -n "${vm}" && -n "${path}" ]] || return 1
  ftctl_blockcopy_is_krbd_path "${path}" || return 0
  [[ "${FTCTL_XCOLO_PRIMARY_KRBD_PIN:-1}" == "1" ]] || {
    ftctl_log_event "colo" "xcolo.primary_krbd_pin" "skip" "${vm}" "" \
      "phase=${phase} path=${path} reason=disabled"
    return 0
  }

  real="$(readlink -f "${path}" 2>/dev/null || true)"
  [[ -n "${real}" && -b "${real}" ]] || real="${path}"
  [[ -b "${real}" ]] || {
    ftctl_state_set "${vm}" "last_error=xcolo_primary_krbd_pin_path_missing"
    ftctl_log_event "colo" "xcolo.primary_krbd_pin" "fail" "${vm}" "" \
      "phase=${phase} path=${path} resolved=${real} reason=block_device_missing"
    return 1
  }

  pin_dir="$(ftctl_xcolo_primary_krbd_pin_dir "${vm}")"
  mkdir -p "${pin_dir}" 2>/dev/null || true
  safe="$(ftctl_xcolo_path_safe_name "${path}")"
  pid_file="${pin_dir}/${safe}.pid"
  path_file="${pin_dir}/${safe}.path"
  existing_pid="$(cat "${pid_file}" 2>/dev/null || true)"
  if [[ -n "${existing_pid}" && -d "/proc/${existing_pid}" ]]; then
    ftctl_log_event "colo" "xcolo.primary_krbd_pin" "ok" "${vm}" "" \
      "phase=${phase} path=${path} resolved=${real} pid=${existing_pid} reused=1"
    return 0
  fi

  rm -f "${pid_file}" 2>/dev/null || true
  printf '%s\n' "${path}" > "${path_file}" 2>/dev/null || true
  (
    exec 9<"${real}"
    printf '%s\n' "${BASHPID}" > "${pid_file}"
    trap 'exit 0' TERM INT
    while :; do sleep 3600; done
  ) >/dev/null 2>&1 &
  pin_pid="$!"

  for _ftctl_pin_wait in 1 2 3 4 5; do
    existing_pid="$(cat "${pid_file}" 2>/dev/null || true)"
    [[ -n "${existing_pid}" && -d "/proc/${existing_pid}" ]] && break
    sleep 1
  done
  existing_pid="$(cat "${pid_file}" 2>/dev/null || true)"
  if [[ -z "${existing_pid}" || ! -d "/proc/${existing_pid}" ]]; then
    kill "${pin_pid}" >/dev/null 2>&1 || true
    ftctl_state_set "${vm}" "last_error=xcolo_primary_krbd_pin_failed"
    ftctl_log_event "colo" "xcolo.primary_krbd_pin" "fail" "${vm}" "" \
      "phase=${phase} path=${path} resolved=${real} reason=pin_process_not_running"
    return 1
  fi

  ftctl_log_event "colo" "xcolo.primary_krbd_pin" "ok" "${vm}" "" \
    "phase=${phase} path=${path} resolved=${real} pid=${existing_pid}"
}

ftctl_xcolo_release_primary_krbd_pins() {
  local vm="${1-}"
  local reason="${2:-release}"
  local pin_dir pid_file path_file pid released=0

  [[ -n "${vm}" ]] || return 1
  ftctl_xcolo_stop_primary_parent_nbd_adapters "${vm}" "${reason}" || true
  pin_dir="$(ftctl_xcolo_primary_krbd_pin_dir "${vm}")"
  [[ -d "${pin_dir}" ]] || return 0

  for pid_file in "${pin_dir}"/*.pid; do
    [[ -f "${pid_file}" ]] || continue
    pid="$(cat "${pid_file}" 2>/dev/null || true)"
    path_file="${pid_file%.pid}.path"
    if [[ -n "${pid}" && -d "/proc/${pid}" ]]; then
      kill "${pid}" >/dev/null 2>&1 || true
      released=$((released + 1))
    fi
    rm -f "${pid_file}" "${path_file}" 2>/dev/null || true
  done
  rmdir "${pin_dir}" >/dev/null 2>&1 || true
  ftctl_log_event "colo" "xcolo.primary_krbd_pin.release" "ok" "${vm}" "" \
    "reason=${reason} released=${released}"
}

ftctl_xcolo_begin_primary_krbd_shutdown_guard() {
  local vm="${1-}"
  local xml_path="${2-}"
  local phase="${3:-primary_shutdown}"
  local guard_dir paths=() path ttl now expires token

  [[ -n "${vm}" && -n "${xml_path}" && -f "${xml_path}" ]] || return 1
  ftctl_xcolo_extract_krbd_paths_from_generated_xml "${xml_path}" paths || return $?
  ((${#paths[@]} > 0)) || {
    ftctl_log_event "colo" "xcolo.primary_krbd_guard" "skip" "${vm}" "" \
      "phase=${phase} reason=no_krbd_paths"
    return 0
  }

  guard_dir="$(ftctl_xcolo_primary_krbd_guard_dir "${vm}")"
  mkdir -p "${guard_dir}" 2>/dev/null || true
  ttl="${FTCTL_XCOLO_PRIMARY_KRBD_GUARD_TTL_SEC:-3600}"
  [[ "${ttl}" =~ ^[0-9]+$ && "${ttl}" -gt 0 ]] || ttl=3600
  now="$(date +%s 2>/dev/null || printf '0')"
  expires=$((now + ttl))
  token="$(date +%Y%m%d%H%M%S 2>/dev/null || printf 'token')-$$"
  {
    for path in "${paths[@]}"; do
      [[ -n "${path}" ]] && printf '%s\n' "${path}"
    done
  } > "${guard_dir}/paths"
  printf '1\n' > "${guard_dir}/enabled"
  printf '%s\n' "${token}" > "${guard_dir}/token"
  date -Is > "${guard_dir}/created" 2>/dev/null || true
  printf '%s\n' "${expires}" > "${guard_dir}/expires"

  for path in "${paths[@]}"; do
    if ! ftctl_xcolo_prepare_primary_krbd_runtime_path "${vm}" "${path}" "${phase}"; then
      ftctl_xcolo_end_primary_krbd_shutdown_guard "${vm}" "guard_prepare_failed" || true
      return 1
    fi
  done
  ftctl_state_set "${vm}" \
    "xcolo_primary_krbd_guard=enabled" \
    "xcolo_primary_krbd_guard_dir=${guard_dir}" \
    "xcolo_primary_krbd_guard_count=${#paths[@]}" \
    "xcolo_primary_krbd_guard_expires=${expires}"
  ftctl_log_event "colo" "xcolo.primary_krbd_guard" "ok" "${vm}" "" \
    "phase=${phase} count=${#paths[@]} dir=${guard_dir} expires=${expires}"
}

ftctl_xcolo_end_primary_krbd_shutdown_guard() {
  local vm="${1-}"
  local reason="${2:-release}"
  local guard_dir

  [[ -n "${vm}" ]] || return 1
  ftctl_xcolo_release_primary_krbd_pins "${vm}" "${reason}" || true
  guard_dir="$(ftctl_xcolo_primary_krbd_guard_dir "${vm}")"
  rm -rf "${guard_dir}" 2>/dev/null || true
  ftctl_state_set "${vm}" \
    "xcolo_primary_krbd_guard=disabled" \
    "xcolo_primary_krbd_guard_release_reason=${reason}"
  ftctl_log_event "colo" "xcolo.primary_krbd_guard.release" "ok" "${vm}" "" \
    "reason=${reason} dir=${guard_dir}"
}

ftctl_xcolo_wait_primary_shutdown_hook_settle() {
  local vm="${1-}"
  local delay="${FTCTL_XCOLO_SHUTDOWN_HOOK_SETTLE_SEC:-3}"

  [[ "${delay}" =~ ^[0-9]+$ ]] || delay=3
  if [[ "${delay}" -gt 0 ]]; then
    sleep "${delay}"
  fi
  udevadm settle >/dev/null 2>&1 || true
  ftctl_state_set "${vm}" "xcolo_primary_shutdown_hook_settle_sec=${delay}"
  ftctl_log_event "colo" "xcolo.primary_shutdown_hook_settle" "ok" "${vm}" "" \
    "delay=${delay}"
}

ftctl_xcolo_prepare_primary_krbd_runtime_paths_from_xml() {
  local vm="${1-}"
  local generated_xml="${2-}"
  local phase="${3:-primary_create}"
  local paths=()
  local path

  ftctl_xcolo_extract_krbd_paths_from_generated_xml "${generated_xml}" paths || return $?
  ((${#paths[@]} > 0)) || {
    ftctl_log_event "colo" "xcolo.primary_krbd_runtime_paths" "skip" "${vm}" "" \
      "phase=${phase} path=${generated_xml} reason=no_krbd_paths"
    return 0
  }

  for path in "${paths[@]}"; do
    ftctl_xcolo_prepare_primary_krbd_runtime_path "${vm}" "${path}" "${phase}" || return $?
  done
  ftctl_state_set "${vm}" "xcolo_primary_krbd_runtime_hold_count=${#paths[@]}"
  ftctl_log_event "colo" "xcolo.primary_krbd_runtime_paths" "ok" "${vm}" "" \
    "phase=${phase} count=${#paths[@]} path=${generated_xml}"
}

ftctl_xcolo_refresh_primary_krbd_runtime_paths_from_xml() {
  local vm="${1-}"
  local generated_xml="${2-}"
  local phase="${3:-primary_create_wait}"
  local paths=()
  local path safe real refresh_count=0 remap_count=0 ready="yes" missing=""

  [[ -n "${vm}" && -n "${generated_xml}" && -f "${generated_xml}" ]] || return 0
  ftctl_xcolo_extract_krbd_paths_from_generated_xml "${generated_xml}" paths || return $?
  ((${#paths[@]} > 0)) || return 0

  for path in "${paths[@]}"; do
    [[ -n "${path}" ]] || continue
    refresh_count=$((refresh_count + 1))
    if [[ ! -b "${path}" ]]; then
      remap_count=$((remap_count + 1))
      ftctl_log_event "colo" "xcolo.primary_krbd_runtime_refresh" "warn" "${vm}" ""         "phase=${phase} path=${path} reason=stable_path_missing remap=1"
      if ! ftctl_xcolo_prepare_primary_krbd_runtime_path "${vm}" "${path}" "${phase}_remap"; then
        ready="no"
        missing="${missing}${missing:+,}${path}"
        continue
      fi
    else
      ftctl_xcolo_pin_primary_krbd_runtime_path "${vm}" "${path}" "${phase}_pin" || {
        ready="no"
        missing="${missing}${missing:+,}${path}"
        continue
      }
    fi

    real="$(readlink -f "${path}" 2>/dev/null || true)"
    [[ -n "${real}" ]] || real="${path}"
    safe="$(ftctl_xcolo_path_safe_name "${phase}_${path}")"
    ftctl_state_set "${vm}"       "xcolo_primary_krbd_refresh_${safe}=ok:${path}->${real}"
  done

  ftctl_state_set "${vm}"     "xcolo_primary_krbd_refresh_phase=${phase}"     "xcolo_primary_krbd_refresh_count=${refresh_count}"     "xcolo_primary_krbd_refresh_remap_count=${remap_count}"     "xcolo_primary_krbd_refresh_missing=$(ftctl_xcolo_compact_log_value "${missing}")"

  if [[ "${ready}" != "yes" ]]; then
    ftctl_state_set "${vm}" "last_error=xcolo_primary_krbd_refresh_failed"
    ftctl_log_event "colo" "xcolo.primary_krbd_runtime_refresh" "fail" "${vm}" ""       "phase=${phase} count=${refresh_count} remap_count=${remap_count} missing=$(ftctl_xcolo_compact_log_value "${missing}")"
    return 1
  fi

  ftctl_log_event "colo" "xcolo.primary_krbd_runtime_refresh" "ok" "${vm}" ""     "phase=${phase} count=${refresh_count} remap_count=${remap_count}"
}

ftctl_xcolo_record_primary_krbd_create_visibility() {
  local vm="${1-}"
  local generated_xml="${2-}"
  local phase="${3:-primary_create}"
  local visible_var="${4-}"
  local missing_var="${5-}"
  local paths=()
  local path real visible="" missing="" count=0

  [[ -n "${vm}" && -n "${generated_xml}" && -f "${generated_xml}" ]] || return 1
  ftctl_xcolo_extract_krbd_paths_from_generated_xml "${generated_xml}" paths || return $?
  ((${#paths[@]} > 0)) || {
    [[ -n "${visible_var}" ]] && printf -v "${visible_var}" '%s' ""
    [[ -n "${missing_var}" ]] && printf -v "${missing_var}" '%s' ""
    return 0
  }

  for path in "${paths[@]}"; do
    [[ -n "${path}" ]] || continue
    count=$((count + 1))
    real="$(readlink -f "${path}" 2>/dev/null || true)"
    [[ -n "${real}" ]] || real="-"
    if [[ -b "${path}" ]]; then
      visible="${visible}${visible:+,}${path}->${real}"
    else
      missing="${missing}${missing:+,}${path}->${real}"
    fi
  done

  ftctl_state_set "${vm}" \
    "xcolo_primary_krbd_create_visibility_phase=${phase}" \
    "xcolo_primary_krbd_create_visibility_count=${count}" \
    "xcolo_primary_krbd_create_visible_paths=$(ftctl_xcolo_compact_log_value "${visible}")" \
    "xcolo_primary_krbd_create_missing_paths=$(ftctl_xcolo_compact_log_value "${missing}")"
  ftctl_log_event "colo" "xcolo.primary_krbd_create_visibility" "$( [[ -z "${missing}" ]] && printf ok || printf fail )" "${vm}" "" \
    "phase=${phase} visible=$(ftctl_xcolo_compact_log_value "${visible}") missing=$(ftctl_xcolo_compact_log_value "${missing}")"

  [[ -n "${visible_var}" ]] && printf -v "${visible_var}" '%s' "${visible}"
  [[ -n "${missing_var}" ]] && printf -v "${missing_var}" '%s' "${missing}"
}


ftctl_xcolo_krbd_contract_dir() {
  printf '%s\n' "/run/ablestack-vm-ftctl/krbd-contract"
}

ftctl_xcolo_record_krbd_materialization_contract() {
  local vm="${1-}"
  local disk_runtime="${2-}"
  local phase="${3:-startup_disk_graph}"
  local contract_dir contract_file tmp_file
  local entries=()
  local entry target primary_source primary_format primary_overlay secondary_dest secondary_hidden secondary_active secondary_format
  local source real major_minor role count=0 summary=""

  [[ -n "${vm}" && -n "${disk_runtime}" ]] || return 1

  contract_dir="$(ftctl_xcolo_krbd_contract_dir)"
  ftctl_ensure_dir "${contract_dir}" "0755"
  contract_file="${contract_dir}/${vm}.env"
  tmp_file="$(mktemp -t ftctl.krbd-contract.XXXXXX)"
  {
    printf 'vm=%q\n' "${vm}"
    printf 'phase=%q\n' "${phase}"
    printf 'created_at=%q\n' "$(ftctl_now_iso8601)"
  } > "${tmp_file}"

  IFS=';' read -r -a entries <<< "${disk_runtime}"
  for entry in "${entries[@]}"; do
    [[ -n "${entry}" ]] || continue
    IFS='|' read -r target primary_source primary_format primary_overlay secondary_dest secondary_hidden secondary_active secondary_format <<< "${entry}"
    for role in primary secondary; do
      source=""
      case "${role}" in
        primary) source="${primary_source}" ;;
        secondary) source="${secondary_dest}" ;;
      esac
      [[ "${source}" == /dev/rbd/* ]] || continue
      real="$(readlink -f "${source}" 2>/dev/null || true)"
      if [[ -b "${source}" ]]; then
        major_minor="$(stat -Lc '%t:%T' "${source}" 2>/dev/null || true)"
      else
        major_minor="missing"
      fi
      count=$((count + 1))
      {
        printf 'entry_%d_role=%q\n' "${count}" "${role}"
        printf 'entry_%d_target=%q\n' "${count}" "${target}"
        printf 'entry_%d_source=%q\n' "${count}" "${source}"
        printf 'entry_%d_real=%q\n' "${count}" "${real}"
        printf 'entry_%d_major_minor=%q\n' "${count}" "${major_minor}"
      } >> "${tmp_file}"
      summary="${summary}${summary:+,}${role}:${target}:${source}->${real}:${major_minor}"
    done
  done

  printf 'count=%q\n' "${count}" >> "${tmp_file}"
  mv -f "${tmp_file}" "${contract_file}"
  chmod 0644 "${contract_file}" 2>/dev/null || true

  ftctl_state_set "${vm}" \
    "xcolo_krbd_materialization_contract_phase=${phase}" \
    "xcolo_krbd_materialization_contract_file=${contract_file}" \
    "xcolo_krbd_materialization_contract_count=${count}" \
    "xcolo_krbd_materialization_contract_summary=$(ftctl_xcolo_compact_log_value "${summary}")"
  ftctl_log_event "colo" "xcolo.krbd_materialization_contract" "ok" "${vm}" "" \
    "phase=${phase} count=${count} file=${contract_file} summary=$(ftctl_xcolo_compact_log_value "${summary}")"
}

ftctl_xcolo_qemu_fd_matches_krbd_path() {
  local qemu_pid="${1-}"
  local path="${2-}"
  local out_var="${3}"
  local source_dev fd fd_dev link found=""

  [[ -n "${qemu_pid}" && -d "/proc/${qemu_pid}" && -n "${path}" ]] || return 1
  source_dev="$(stat -Lc '%t:%T' "${path}" 2>/dev/null || true)"
  [[ -n "${source_dev}" ]] || return 1
  for fd in /proc/${qemu_pid}/fd/*; do
    [[ -e "${fd}" ]] || continue
    fd_dev="$(stat -Lc '%t:%T' "${fd}" 2>/dev/null || true)"
    [[ "${fd_dev}" == "${source_dev}" ]] || continue
    link="$(readlink "${fd}" 2>/dev/null || true)"
    found="${fd##*/}->${link:-unknown}"
    break
  done
  printf -v "${out_var}" '%s' "${found}"
  [[ -n "${found}" ]]
}


ftctl_xcolo_qemu_child_pids() {
  local root_pid="${1-}"
  local depth="${2:-0}"
  local child_file child

  [[ -n "${root_pid}" && -d "/proc/${root_pid}" ]] || return 0
  [[ "${depth}" =~ ^[0-9]+$ ]] || depth=0
  (( depth <= 4 )) || return 0
  printf '%s\n' "${root_pid}"
  child_file="/proc/${root_pid}/task/${root_pid}/children"
  [[ -r "${child_file}" ]] || return 0
  for child in $(cat "${child_file}" 2>/dev/null || true); do
    [[ -n "${child}" && -d "/proc/${child}" ]] || continue
    ftctl_xcolo_qemu_child_pids "${child}" "$((depth + 1))"
  done
}

ftctl_xcolo_qemu_pid_matches_vm() {
  local pid="${1-}"
  local vm="${2-}"
  local comm cmd

  [[ -n "${pid}" && -d "/proc/${pid}" && -n "${vm}" ]] || return 1
  comm="$(cat "/proc/${pid}/comm" 2>/dev/null || true)"
  cmd="$(tr '\000' ' ' < "/proc/${pid}/cmdline" 2>/dev/null || true)"
  case "${comm}:${cmd}" in
    *qemu-kvm*|*qemu-system*) ;;
    *) return 1 ;;
  esac
  case " ${cmd} " in
    *"guest=${vm}"*|*"guest=${vm},"*|*" ${vm} "*) return 0 ;;
    *) return 1 ;;
  esac
}

ftctl_xcolo_qemu_pid_from_create_pid() {
  local create_pid="${1-}"
  local out_var="${2}"
  local vm="${3-}"
  local pid proc found_pid=""

  if [[ -n "${create_pid}" ]]; then
    while IFS= read -r pid; do
      [[ -n "${pid}" && -d "/proc/${pid}" ]] || continue
      if ftctl_xcolo_qemu_pid_matches_vm "${pid}" "${vm}"; then
        found_pid="${pid}"
        break
      fi
    done < <(ftctl_xcolo_qemu_child_pids "${create_pid}" | awk '!seen[$0]++')
  fi

  if [[ -z "${found_pid}" ]]; then
    for proc in /proc/[0-9]*; do
      pid="${proc##*/}"
      [[ -n "${pid}" && -d "/proc/${pid}" ]] || continue
      if ftctl_xcolo_qemu_pid_matches_vm "${pid}" "${vm}"; then
        found_pid="${pid}"
        break
      fi
    done
  fi

  printf -v "${out_var}" '%s' "${found_pid}"
  [[ -n "${found_pid}" ]]
}

ftctl_xcolo_verify_primary_krbd_qemu_namespace() {
  local vm="${1-}"
  local generated_xml="${2-}"
  local create_pid="${3-}"
  local phase="${4:-primary_listener}"
  local paths=()
  local path ns_path qemu_pid="" visible="" missing="" count=0
  local fd_match="" fd_open="" fd_missing=""
  local qmp_out="" qmp_rc=0 qmp_missing="" qmp_checked="no"

  [[ -n "${vm}" && -n "${generated_xml}" && -f "${generated_xml}" ]] || return 1
  ftctl_xcolo_extract_krbd_paths_from_generated_xml "${generated_xml}" paths || return $?
  ((${#paths[@]} > 0)) || {
    ftctl_log_event "colo" "xcolo.primary_krbd_qemu_namespace" "skip" "${vm}" "" \
      "phase=${phase} reason=no_krbd_paths"
    return 0
  }

  if ! ftctl_xcolo_qemu_pid_from_create_pid "${create_pid}" qemu_pid "${vm}" ||
      [[ -z "${qemu_pid}" || ! -d "/proc/${qemu_pid}" ]]; then
    ftctl_state_set "${vm}" \
      "xcolo_primary_krbd_qemu_namespace_phase=${phase}" \
      "xcolo_primary_krbd_qemu_namespace_visible=unknown" \
      "xcolo_primary_krbd_qemu_namespace_pid=" \
      "last_error=xcolo_primary_krbd_qemu_pid_not_found"
    ftctl_log_event "colo" "xcolo.primary_krbd_qemu_namespace" "fail" "${vm}" "" \
      "phase=${phase} create_pid=${create_pid} qemu_pid=${qemu_pid} reason=qemu_pid_not_found"
    return 1
  fi

  for path in "${paths[@]}"; do
    [[ -n "${path}" ]] || continue
    count=$((count + 1))
    ns_path="/proc/${qemu_pid}/root${path}"
    if [[ -b "${ns_path}" ]]; then
      visible="${visible}${visible:+,}${path}"
    elif ftctl_xcolo_qemu_fd_matches_krbd_path "${qemu_pid}" "${path}" fd_match; then
      fd_open="${fd_open}${fd_open:+,}${path}->${fd_match}"
    else
      missing="${missing}${missing:+,}${path}"
      fd_missing="${fd_missing}${fd_missing:+,}${path}"
    fi
  done

  if command -v timeout >/dev/null 2>&1; then
    qmp_out="$(timeout 8 virsh -c "${FTCTL_PROFILE_PRIMARY_URI}" qemu-monitor-command "${vm}" --pretty '{"execute":"query-named-block-nodes"}' 2>/dev/null)" || qmp_rc=$?
  else
    qmp_out="$(virsh -c "${FTCTL_PROFILE_PRIMARY_URI}" qemu-monitor-command "${vm}" --pretty '{"execute":"query-named-block-nodes"}' 2>/dev/null)" || qmp_rc=$?
  fi
  if [[ "${qmp_rc}" == "0" && -n "${qmp_out}" ]]; then
    qmp_checked="yes"
    for path in "${paths[@]}"; do
      [[ -n "${path}" ]] || continue
      if [[ "${qmp_out}" != *"${path}"* ]]; then
        qmp_missing="${qmp_missing}${qmp_missing:+,}${path}"
      fi
    done
  else
    qmp_checked="unavailable:${qmp_rc}"
  fi

  ftctl_state_set "${vm}" \
    "xcolo_primary_krbd_qemu_namespace_phase=${phase}" \
    "xcolo_primary_krbd_qemu_namespace_pid=${qemu_pid}" \
    "xcolo_primary_krbd_qemu_namespace_count=${count}" \
    "xcolo_primary_krbd_qemu_namespace_visible_paths=$(ftctl_xcolo_compact_log_value "${visible}")" \
    "xcolo_primary_krbd_qemu_namespace_missing_paths=$(ftctl_xcolo_compact_log_value "${missing}")" \
    "xcolo_primary_krbd_qemu_fd_open_paths=$(ftctl_xcolo_compact_log_value "${fd_open}")" \
    "xcolo_primary_krbd_qemu_fd_missing_paths=$(ftctl_xcolo_compact_log_value "${fd_missing}")" \
    "xcolo_primary_krbd_qmp_checked=${qmp_checked}" \
    "xcolo_primary_krbd_qmp_missing_paths=$(ftctl_xcolo_compact_log_value "${qmp_missing}")"

  if [[ "${phase}" == "primary_listener" && ( -n "${fd_missing}" || "${qmp_checked}" != "yes" || -n "${qmp_missing}" ) ]]; then
    ftctl_state_set "${vm}" \
      "xcolo_primary_krbd_qemu_namespace_visible=pending" \
      "xcolo_primary_krbd_qemu_fd_open=pending" \
      "xcolo_primary_krbd_materialization_pending=yes"
    ftctl_log_event "colo" "xcolo.primary_krbd_qemu_namespace" "pending" "${vm}" "" \
      "phase=${phase} qemu_pid=${qemu_pid} visible=$(ftctl_xcolo_compact_log_value "${visible}") fd_open=$(ftctl_xcolo_compact_log_value "${fd_open}") fd_missing=$(ftctl_xcolo_compact_log_value "${fd_missing}") namespace_missing=$(ftctl_xcolo_compact_log_value "${missing}") qmp=${qmp_checked} qmp_missing=$(ftctl_xcolo_compact_log_value "${qmp_missing}")"
    return 0
  fi

  if [[ "${phase}" == "pre_migrate_materialized" && "${qmp_checked}" != "yes" ]]; then
    ftctl_state_set "${vm}" \
      "xcolo_primary_krbd_qemu_namespace_visible=no" \
      "xcolo_primary_krbd_qemu_fd_open=no" \
      "last_error=xcolo_primary_krbd_qmp_unavailable_pre_migrate"
    ftctl_log_event "colo" "xcolo.primary_krbd_qemu_namespace" "fail" "${vm}" "" \
      "phase=${phase} qemu_pid=${qemu_pid} qmp=${qmp_checked} reason=qmp_unavailable"
    return 1
  fi

  if [[ -n "${fd_missing}" ]]; then
    ftctl_state_set "${vm}" \
      "xcolo_primary_krbd_qemu_namespace_visible=no" \
      "xcolo_primary_krbd_qemu_fd_open=no" \
      "last_error=xcolo_primary_krbd_open_fd_missing"
    ftctl_log_event "colo" "xcolo.primary_krbd_qemu_namespace" "fail" "${vm}" "" \
      "phase=${phase} qemu_pid=${qemu_pid} visible=$(ftctl_xcolo_compact_log_value "${visible}") fd_open=$(ftctl_xcolo_compact_log_value "${fd_open}") fd_missing=$(ftctl_xcolo_compact_log_value "${fd_missing}") namespace_missing=$(ftctl_xcolo_compact_log_value "${missing}")"
    return 1
  fi

  if [[ "${qmp_checked}" == "yes" && -n "${qmp_missing}" ]]; then
    ftctl_state_set "${vm}" \
      "xcolo_primary_krbd_qemu_namespace_visible=$( [[ -n "${missing}" ]] && printf fd || printf yes )" \
      "xcolo_primary_krbd_qemu_fd_open=yes" \
      "last_error=xcolo_primary_krbd_qmp_node_missing"
    ftctl_log_event "colo" "xcolo.primary_krbd_qemu_namespace" "fail" "${vm}" "" \
      "phase=${phase} qemu_pid=${qemu_pid} qmp_missing=$(ftctl_xcolo_compact_log_value "${qmp_missing}") fd_open=$(ftctl_xcolo_compact_log_value "${fd_open}") visible=$(ftctl_xcolo_compact_log_value "${visible}")"
    return 1
  fi

  ftctl_state_set "${vm}" \
    "xcolo_primary_krbd_qemu_namespace_visible=$( [[ -n "${missing}" ]] && printf fd || printf yes )" \
    "xcolo_primary_krbd_qemu_fd_open=yes" \
    "xcolo_primary_krbd_materialization_pending=no"
  ftctl_log_event "colo" "xcolo.primary_krbd_qemu_namespace" "ok" "${vm}" "" \
    "phase=${phase} qemu_pid=${qemu_pid} visible=$(ftctl_xcolo_compact_log_value "${visible}") fd_open=$(ftctl_xcolo_compact_log_value "${fd_open}") namespace_missing=$(ftctl_xcolo_compact_log_value "${missing}") qmp=${qmp_checked}"
}

ftctl_xcolo_require_primary_krbd_materialized_before_migrate() {
  local vm="${1-}"
  local generated_xml

  [[ -n "${vm}" ]] || return 1
  generated_xml="$(ftctl_state_get "${vm}" "primary_xml_generated" 2>/dev/null || true)"
  if [[ -z "${generated_xml}" || ! -f "${generated_xml}" ]]; then
    ftctl_state_set "${vm}" \
      "xcolo_primary_krbd_materialization_gate=skipped" \
      "xcolo_primary_krbd_materialization_skip_reason=generated_xml_missing"
    ftctl_log_event "colo" "xcolo.primary_krbd_materialized" "skip" "${vm}" "" \
      "reason=generated_xml_missing path=${generated_xml}"
    return 0
  fi

  ftctl_xcolo_verify_primary_krbd_qemu_namespace "${vm}" "${generated_xml}" "" "pre_migrate_materialized" || {
    ftctl_state_set "${vm}" "xcolo_protocol_failure_phase=pre_migrate_primary_krbd_materialization"
    return 1
  }
  ftctl_log_event "colo" "xcolo.primary_krbd_materialized" "ok" "${vm}" "" \
    "phase=pre_migrate_materialized path=${generated_xml}"
}
ftctl_xcolo_classify_primary_create_error() {
  local err_summary="${1-}"
  local out_var="${2}"
  local vm="${3-}"
  local generated_xml="${4-}"
  local phase="${5:-primary_create}"
  local create_error="xcolo_primary_create_failed_before_listener"
  local visible_paths="" missing_paths=""

  if [[ "${err_summary}" == *"/dev/rbd/"* && "${err_summary}" == *"No such file or directory"* ]]; then
    create_error="xcolo_primary_krbd_path_lost_at_create"
    if [[ -n "${vm}" && -n "${generated_xml}" && -f "${generated_xml}" ]]; then
      ftctl_xcolo_record_primary_krbd_create_visibility "${vm}" "${generated_xml}" "${phase}" visible_paths missing_paths || true
      if [[ -n "${visible_paths}" ]]; then
        create_error="xcolo_primary_krbd_libvirt_runtime_visibility_failed"
      fi
    fi
  elif [[ "${err_summary}" == *"/dev/rbd/"* && ( "${err_summary}" == *"Permission denied"* || "${err_summary}" == *"Operation not permitted"* ) ]]; then
    create_error="xcolo_primary_krbd_access_denied_at_create"
  elif [[ "${err_summary}" == *"Bus '"*" not found"* ||
          "${err_summary}" == *"PCI:"*" not available"* ||
          "${err_summary}" == *"slot "*" not available"* ]]; then
    create_error="xcolo_startup_pci_topology_failed"
  elif [[ "${err_summary}" == *"qemu-kvm:"* ]]; then
    create_error="xcolo_primary_create_qemu_parse_failed"
  fi
  printf -v "${out_var}" '%s' "${create_error}"
}

ftctl_xcolo_run_primary_generated_create_with_retry() {
  local vm="${1-}"
  local generated_xml="${2-}"
  local out_file="${3-}"
  local err_file="${4-}"
  local timeout_sec="${5-}"
  local create_rc=0 retry_rc=0 retry_out retry_err retry_reason=""

  [[ -n "${generated_xml}" && -f "${generated_xml}" && -n "${out_file}" && -n "${err_file}" ]] || return 1
  : > "${out_file}"
  : > "${err_file}"

  if command -v timeout >/dev/null 2>&1; then
    timeout --preserve-status "${timeout_sec}" env LC_ALL=C LANG=C \
      virsh -c "${FTCTL_PROFILE_PRIMARY_URI}" create "${generated_xml}" \
      >"${out_file}" 2>"${err_file}" || create_rc=$?
  else
    env LC_ALL=C LANG=C virsh -c "${FTCTL_PROFILE_PRIMARY_URI}" create "${generated_xml}" \
      >"${out_file}" 2>"${err_file}" || create_rc=$?
  fi

  if [[ "${FTCTL_XCOLO_PRIMARY_INTERNAL_CREATE_RETRY:-1}" == "1" &&
        "${create_rc}" != "0" ]] &&
     grep -q "/dev/rbd/" "${err_file}" 2>/dev/null &&
     grep -q "No such file or directory" "${err_file}" 2>/dev/null; then
    retry_reason="krbd_enoent_after_prepare"
    ftctl_log_event "colo" "primary.create_generated.retry" "warn" "${vm}" "${create_rc}" \
      "reason=${retry_reason} path=${generated_xml}"
    ftctl_xcolo_prepare_primary_krbd_runtime_paths_from_xml "${vm}" "${generated_xml}" "primary_create_retry" || {
      ftctl_log_event "colo" "primary.create_generated.retry" "fail" "${vm}" "" \
        "reason=krbd_reprepare_failed path=${generated_xml}"
      return "${create_rc}"
    }
    ftctl_xcolo_record_primary_krbd_create_visibility "${vm}" "${generated_xml}" "primary_create_retry_before_virsh" || true
    sleep 1
    retry_out="${out_file}.retry"
    retry_err="${err_file}.retry"
    : > "${retry_out}"
    : > "${retry_err}"
    if command -v timeout >/dev/null 2>&1; then
      timeout --preserve-status "${timeout_sec}" env LC_ALL=C LANG=C \
        virsh -c "${FTCTL_PROFILE_PRIMARY_URI}" create "${generated_xml}" \
        >"${retry_out}" 2>"${retry_err}" || retry_rc=$?
    else
      env LC_ALL=C LANG=C virsh -c "${FTCTL_PROFILE_PRIMARY_URI}" create "${generated_xml}" \
        >"${retry_out}" 2>"${retry_err}" || retry_rc=$?
    fi
    {
      printf '\n--- ftctl retry stdout ---\n'
      cat "${retry_out}" 2>/dev/null || true
    } >> "${out_file}"
    {
      printf '\n--- ftctl retry stderr ---\n'
      cat "${retry_err}" 2>/dev/null || true
    } >> "${err_file}"
    ftctl_state_set "${vm}" \
      "xcolo_primary_create_retry=1" \
      "xcolo_primary_create_retry_reason=${retry_reason}" \
      "xcolo_primary_create_retry_rc=${retry_rc}"
    ftctl_log_event "colo" "primary.create_generated.retry" "$(ftctl_result_from_rc "${retry_rc}")" "${vm}" "${retry_rc}" \
      "reason=${retry_reason} path=${generated_xml}"
    return "${retry_rc}"
  fi

  return "${create_rc}"
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
  local timeout_sec tmp_dir out_file err_file rc_file pid log_baseline

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
  ftctl_xcolo_prepare_primary_krbd_runtime_paths_from_xml "${vm}" "${generated_xml}" "primary_create" || {
    ftctl_log_event "colo" "primary.create_generated.rbd-map" "fail" "${vm}" "" "path=${generated_xml}"
    return 1
  }

  timeout_sec="$(ftctl_xcolo_domain_create_timeout_sec)"
  log_baseline="$(wc -l "/var/log/libvirt/qemu/${vm}.log" 2>/dev/null | awk '{print $1}' || printf '0')"
  [[ "${log_baseline}" =~ ^[0-9]+$ ]] || log_baseline="0"
  ftctl_state_set "${vm}" "xcolo_primary_qemu_log_baseline_lines=${log_baseline}"
  tmp_dir="$(mktemp -d "${FTCTL_RUN_DIR:-/run/ablestack-vm-ftctl}/xcolo-primary-create.${vm}.XXXXXX")" || return 1
  out_file="${tmp_dir}/stdout"
  err_file="${tmp_dir}/stderr"
  rc_file="${tmp_dir}/rc"
  (
    local create_rc=0
    ftctl_xcolo_run_primary_generated_create_with_retry "${vm}" "${generated_xml}" "${out_file}" "${err_file}" "${timeout_sec}" || create_rc=$?
    printf '%s\n' "${create_rc}" > "${rc_file}"
    exit "${create_rc}"
  ) &
  pid="$!"
  printf -v "${out_handle_var}" '%s|%s|%s|%s|%s' "${pid}" "${rc_file}" "${out_file}" "${err_file}" "${tmp_dir}"
  ftctl_log_event "colo" "primary.create_generated.async_start" "ok" "${vm}" "" \
    "path=${generated_xml} timeout=${timeout_sec} pid=${pid} qemu_log_baseline=${log_baseline}"
}

ftctl_xcolo_wait_primary_generated_listeners() {
  local vm="${1-}"
  local handle="${2-}"
  local timeout_sec mirror_port compare_port compare_local_port compare_out_port mirror_wait compare_wait i
  local pid="" rc_file="" out_file="" err_file="" tmp_dir=""
  local create_rc ready_reason err_summary create_error generated_xml

  IFS='|' read -r pid rc_file out_file err_file tmp_dir <<< "${handle}"
  : "${pid}${out_file}${err_file}${tmp_dir}"
  if [[ "${pid}" == "dry-run" ]]; then
    return 0
  fi

  generated_xml="$(ftctl_state_get "${vm}" "primary_xml_generated" 2>/dev/null || true)"
  timeout_sec="$(ftctl_xcolo_domain_create_timeout_sec)"
  mirror_port="${FTCTL_XCOLO_MIRROR_PORT:-9003}"
  compare_port="${FTCTL_XCOLO_COMPARE_PORT:-9004}"
  compare_local_port="${FTCTL_XCOLO_COMPARE_LOCAL_PORT:-9001}"
  compare_out_port="${FTCTL_XCOLO_COMPARE_OUT_PORT:-9005}"
  mirror_wait="off"
  compare_wait="off"
  for ((i=0; i<timeout_sec; i++)); do
    if [[ -n "${generated_xml}" && -f "${generated_xml}" ]]; then
      ftctl_xcolo_refresh_primary_krbd_runtime_paths_from_xml "${vm}" "${generated_xml}" "wait_listener" || return $?
    fi
    ready_reason=""
    if ftctl_xcolo_local_tcp_listen_port_ready "${mirror_port}" &&
       ftctl_xcolo_local_tcp_listen_port_ready "${compare_port}"; then
      ready_reason="listener_pair_wait_off"
    fi
    if [[ -n "${ready_reason}" ]]; then
      ftctl_state_set "${vm}" \
        "xcolo_bootstrap_phase=primary_listener" \
        "xcolo_primary_listener_wait_policy=wait_off_qmp_gated" \
        "xcolo_primary_listener_bootstrap=${ready_reason}" \
        "xcolo_primary_listener_bootstrap_mirror_wait=${mirror_wait}" \
        "xcolo_primary_listener_bootstrap_compare_wait=${compare_wait}"
      if [[ -n "${generated_xml}" && -f "${generated_xml}" ]]; then
        ftctl_xcolo_refresh_primary_krbd_runtime_paths_from_xml "${vm}" "${generated_xml}" "listener_ready" || return $?
      fi
      if ! ftctl_xcolo_verify_primary_krbd_qemu_namespace "${vm}" "${generated_xml}" "${pid}" "primary_listener"; then
        ftctl_xcolo_capture_socket_snapshot "${vm}" "primary_krbd_namespace_failed" || true
        return 1
      fi
      ftctl_log_event "colo" "primary.create_generated.listeners" "ok" "${vm}" "" \
        "reason=${ready_reason} mirror_port=${mirror_port} compare_port=${compare_port} compare_local_port=${compare_local_port} compare_out_port=${compare_out_port} mirror_wait=${mirror_wait} compare_wait=${compare_wait}"
      return 0
    fi
    if ftctl_xcolo_primary_create_async_done "${handle}"; then
      create_rc="$(cat "${rc_file}" 2>/dev/null || printf '1')"
      if [[ "${create_rc}" != "0" ]]; then
        create_error="xcolo_primary_create_failed_before_listener"
        err_summary="$(tr '\n' ' ' < "${err_file}" 2>/dev/null | cut -c1-220 || true)"
        ftctl_xcolo_classify_primary_create_error "${err_summary}" create_error "${vm}" "${generated_xml}" "primary_create_listener"
        ftctl_state_set "${vm}" \
          "xcolo_protocol_failure_phase=primary_create" \
          "xcolo_primary_create_error_summary=$(ftctl_xcolo_compact_log_value "${err_summary}")" \
          "last_error=${create_error}"
        ftctl_log_event "colo" "primary.create_generated.listeners" "fail" "${vm}" "${create_rc}" \
          "reason=create_exited_before_listen classified=${create_error} mirror_port=${mirror_port} compare_port=${compare_port} log_dir=${tmp_dir} error=$(ftctl_xcolo_compact_log_value "${err_summary}")"
        return 1
      fi
    fi
    sleep 1
  done
  if ftctl_xcolo_primary_create_async_done "${handle}"; then
    create_rc="$(cat "${rc_file}" 2>/dev/null || printf '1')"
    if [[ "${create_rc}" != "0" ]]; then
      create_error="xcolo_primary_create_failed_after_listener_timeout"
      err_summary="$(tr '\n' ' ' < "${err_file}" 2>/dev/null | cut -c1-220 || true)"
      ftctl_xcolo_classify_primary_create_error "${err_summary}" create_error "${vm}" "${generated_xml}" "primary_create_listener_final"
      ftctl_state_set "${vm}" \
        "xcolo_protocol_failure_phase=primary_create" \
        "xcolo_primary_create_error_summary=$(ftctl_xcolo_compact_log_value "${err_summary}")" \
        "last_error=${create_error}"
      ftctl_log_event "colo" "primary.create_generated.listeners" "fail" "${vm}" "${create_rc}" \
        "reason=create_exited_after_listener_timeout classified=${create_error} mirror_port=${mirror_port} compare_port=${compare_port} log_dir=${tmp_dir} error=$(ftctl_xcolo_compact_log_value "${err_summary}")"
      return 1
    fi
  fi
  ftctl_xcolo_capture_socket_snapshot "${vm}" "listener_timeout" || true
  local mirror_listen compare_listen
  mirror_listen="no"
  compare_listen="no"
  if ftctl_xcolo_local_tcp_listen_port_ready "${mirror_port}"; then
    mirror_listen="yes"
  fi
  if ftctl_xcolo_local_tcp_listen_port_ready "${compare_port}"; then
    compare_listen="yes"
  fi
  ftctl_log_event "colo" "primary.create_generated.listeners" "fail" "${vm}" "" \
    "reason=primary_listener_not_open mirror_port=${mirror_port} compare_port=${compare_port} compare_local_port=${compare_local_port} compare_out_port=${compare_out_port} mirror_wait=${mirror_wait} compare_wait=${compare_wait} mirror_listen=${mirror_listen} compare_listen=${compare_listen} log_dir=${tmp_dir}"
  ftctl_state_set "${vm}" \
    "xcolo_protocol_failure_phase=primary_listener" \
    "xcolo_primary_listener_wait_policy=wait_off_qmp_gated" \
    "xcolo_listener_timeout_evidence_captured=yes" \
    "xcolo_primary_listener_mirror_listen=${mirror_listen}" \
    "xcolo_primary_listener_compare_listen=${compare_listen}" \
    "last_error=xcolo_primary_listener_not_open"
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
  local create_rc generated_xml failure_reason secondary_vm contract_reason
  local mirror_established compare_established mirror_listen compare_listen

  IFS='|' read -r pid rc_file out_file err_file tmp_dir <<< "${handle}"
  : "${pid}${out_file}${err_file}${tmp_dir}"
  if [[ "${pid}" == "dry-run" ]]; then
    return 0
  fi

  generated_xml="$(ftctl_state_get "${vm}" "primary_xml_generated" 2>/dev/null || true)"
  secondary_vm="$(ftctl_state_get "${vm}" "secondary_vm_name" 2>/dev/null || ftctl_profile_secondary_vm_name_resolved "${vm}")"
  timeout_sec="$(ftctl_xcolo_channel_connect_timeout_sec)"
  mirror_port="${FTCTL_XCOLO_MIRROR_PORT:-9003}"
  compare_port="${FTCTL_XCOLO_COMPARE_PORT:-9004}"
  for ((i=0; i<timeout_sec; i++)); do
    if [[ -n "${generated_xml}" && -f "${generated_xml}" ]]; then
      ftctl_xcolo_refresh_primary_krbd_runtime_paths_from_xml "${vm}" "${generated_xml}" "wait_peer_attach" || return $?
    fi
    if ftctl_xcolo_local_tcp_established_port_ready "${mirror_port}" &&
       ftctl_xcolo_local_tcp_established_port_ready "${compare_port}"; then
      if [[ -n "${generated_xml}" && -f "${generated_xml}" ]]; then
        ftctl_xcolo_refresh_primary_krbd_runtime_paths_from_xml "${vm}" "${generated_xml}" "peer_attached" || return $?
      fi
      ftctl_xcolo_capture_primary_channel_state "${vm}" || true
      ftctl_log_event "colo" "primary.create_generated.channel_attach" "ok" "${vm}" "" \
        "mirror_port=${mirror_port} compare_port=${compare_port} attempts=$((i + 1))"
      return 0
    fi
    if ftctl_xcolo_primary_create_async_done "${handle}"; then
      create_rc="$(cat "${rc_file}" 2>/dev/null || printf '1')"
      if [[ "${create_rc}" != "0" ]]; then
        local err_summary create_error
        create_error="xcolo_primary_create_failed_before_channel_attach"
        err_summary="$(tr '\n' ' ' < "${err_file}" 2>/dev/null | cut -c1-220 || true)"
        ftctl_xcolo_classify_primary_create_error "${err_summary}" create_error "${vm}" "${generated_xml}" "primary_create_channel_attach"
        ftctl_state_set "${vm}" \
          "xcolo_protocol_failure_phase=primary_create" \
          "xcolo_channel_attach_failure_reason=primary_create_exited_before_channel_attach" \
          "xcolo_primary_create_error_summary=$(ftctl_xcolo_compact_log_value "${err_summary}")" \
          "last_error=${create_error}"
        ftctl_log_event "colo" "primary.create_generated.channel_attach" "fail" "${vm}" "${create_rc}" \
          "reason=create_exited_before_channel_attach classified=${create_error} mirror_port=${mirror_port} compare_port=${compare_port} log_dir=${tmp_dir} error=$(ftctl_xcolo_compact_log_value "${err_summary}")"
        return 1
      fi
    fi
    sleep 1
  done

  ftctl_xcolo_capture_primary_channel_state "${vm}" || true
  if [[ -n "${secondary_vm}" ]]; then
    ftctl_xcolo_capture_colo_chardev_contract "${vm}" "${secondary_vm}" "channel_attach_timeout" || true
  fi
  mirror_established="$(ftctl_state_get "${vm}" "xcolo_channel_mirror_established" 2>/dev/null || true)"
  compare_established="$(ftctl_state_get "${vm}" "xcolo_channel_compare_established" 2>/dev/null || true)"
  mirror_listen="$(ftctl_state_get "${vm}" "xcolo_channel_mirror_listen" 2>/dev/null || true)"
  compare_listen="$(ftctl_state_get "${vm}" "xcolo_channel_compare_listen" 2>/dev/null || true)"
  failure_reason="channel_attach_timeout"
  contract_reason="$(ftctl_state_get "${vm}" "xcolo_chardev_contract_reason" 2>/dev/null || true)"
  if [[ "${contract_reason}" == *"mirror_path_secondary_red0="* ]]; then
    failure_reason="secondary_red0_not_connected"
  elif [[ "${contract_reason}" == *"compare_path_secondary_red1="* ]]; then
    failure_reason="secondary_red1_not_connected"
  elif [[ "${mirror_established}" != "yes" && "${mirror_listen}" != "yes" ]]; then
    failure_reason="mirror_listener_absent"
  elif [[ "${mirror_established}" != "yes" ]]; then
    failure_reason="mirror_channel_not_established"
  elif [[ "${compare_established}" != "yes" && "${compare_listen}" != "yes" ]]; then
    failure_reason="compare_listener_absent"
  elif [[ "${compare_established}" != "yes" ]]; then
    failure_reason="compare_channel_not_established"
  fi
  ftctl_xcolo_capture_socket_snapshot "${vm}" "channel_attach_timeout" || true
  ftctl_xcolo_capture_qemu_log_tails "${vm}" "${secondary_vm}" || true
  ftctl_state_set "${vm}" \
    "xcolo_protocol_failure_phase=channel_attach" \
    "xcolo_channel_attach_failure_reason=${failure_reason}" \
    "xcolo_channel_attach_timeout_evidence_captured=yes" \
    "xcolo_channel_attach_timeout_mirror_port=${mirror_port}" \
    "xcolo_channel_attach_timeout_compare_port=${compare_port}" \
    "xcolo_channel_attach_timeout_mirror_established=${mirror_established}" \
    "xcolo_channel_attach_timeout_compare_established=${compare_established}" \
    "xcolo_channel_attach_timeout_mirror_listen=${mirror_listen}" \
    "xcolo_channel_attach_timeout_compare_listen=${compare_listen}" \
    "xcolo_channel_attach_contract_reason=$(ftctl_xcolo_compact_log_value "${contract_reason}")"
  if ftctl_xcolo_primary_create_async_done "${handle}"; then
    create_rc="$(cat "${rc_file}" 2>/dev/null || printf '1')"
    if [[ "${create_rc}" != "0" ]]; then
      local err_summary create_error
      create_error="xcolo_primary_create_failed_after_channel_attach_timeout"
      err_summary="$(tr '\n' ' ' < "${err_file}" 2>/dev/null | cut -c1-220 || true)"
      ftctl_xcolo_classify_primary_create_error "${err_summary}" create_error "${vm}" "${generated_xml}" "primary_create_channel_attach_final"
      ftctl_state_set "${vm}" \
        "xcolo_protocol_failure_phase=primary_create" \
        "xcolo_channel_attach_failure_reason=primary_create_exited_after_channel_attach_timeout" \
        "xcolo_primary_create_error_summary=$(ftctl_xcolo_compact_log_value "${err_summary}")" \
        "last_error=${create_error}"
      ftctl_log_event "colo" "primary.create_generated.channel_attach" "fail" "${vm}" "${create_rc}" \
        "reason=create_exited_after_channel_attach_timeout classified=${create_error} mirror_port=${mirror_port} compare_port=${compare_port} log_dir=${tmp_dir} error=$(ftctl_xcolo_compact_log_value "${err_summary}")"
      return 1
    fi
  fi
  ftctl_log_event "colo" "primary.create_generated.channel_attach" "fail" "${vm}" "" \
    "reason=timeout classified=${failure_reason} mirror_port=${mirror_port} compare_port=${compare_port} mirror_established=${mirror_established} compare_established=${compare_established} mirror_listen=${mirror_listen} compare_listen=${compare_listen} log_dir=${tmp_dir}"
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

ftctl_xcolo_bootstrap_generation_attempts() {
  local attempts="${FTCTL_XCOLO_BOOTSTRAP_GENERATION_ATTEMPTS:-2}"
  if [[ -z "${attempts}" || ! "${attempts}" =~ ^[0-9]+$ || "${attempts}" -lt 1 ]]; then
    attempts=2
  fi
  if [[ "${attempts}" -gt 3 ]]; then
    attempts=3
  fi
  printf '%s\n' "${attempts}"
}

ftctl_xcolo_teardown_bootstrap_generation() {
  local vm="${1-}"
  local handle="${2-}"
  local secondary_vm="${3-}"
  local reason="${4-xcolo_bootstrap_generation_retry}"
  local generation="${5-}"
  local out="" err="" rc=0 combined=""

  [[ -n "${vm}" ]] || return 1
  ftctl_log_event "colo" "bootstrap_generation.teardown" "start" "${vm}" "" \
    "generation=${generation} reason=${reason} secondary=${secondary_vm}"

  if [[ -n "${handle}" ]]; then
    ftctl_xcolo_abort_primary_generated_async "${vm}" "${handle}" || true
  fi

  if [[ -n "${secondary_vm}" ]]; then
    out=""
    err=""
    rc=0
    ftctl_virsh "${FTCTL_BLOCKCOPY_WAIT_TIMEOUT_SEC:-15}" out err rc -- \
      -c "${FTCTL_PROFILE_SECONDARY_URI}" destroy "${secondary_vm}" || true
    combined="$(printf '%s %s' "${out}" "${err}")"
    if [[ "${rc}" != "0" ]]; then
      case "${combined}" in
        *"failed to get domain"*|*"domain is not running"*|*"Domain not found"*|*"not found"*) rc=0 ;;
      esac
    fi
    ftctl_log_event "colo" "bootstrap_generation.secondary_destroy" "$(ftctl_result_from_rc "${rc}")" "${vm}" "${rc}" \
      "generation=${generation} reason=${reason} secondary=${secondary_vm} error=$(ftctl_xcolo_compact_log_value "${combined}")"
  fi

  if [[ "${FTCTL_PROFILE_PROVISIONING_BACKEND:-libvirt-managed}" == "cloud-managed" &&
        "${FTCTL_PROFILE_MODE:-}" == "ft" ]] &&
      declare -F ftctl_standby_cleanup_cloud_managed_runtime >/dev/null 2>&1; then
    ftctl_standby_cleanup_cloud_managed_runtime "${vm}" "${secondary_vm}" || {
      ftctl_log_event "colo" "bootstrap_generation.secondary_cleanup" "warn" "${vm}" "" \
        "generation=${generation} reason=${reason} secondary=${secondary_vm}"
    }
  fi

  ftctl_xcolo_unmap_secondary_runtime_rbd "${vm}" || {
    ftctl_log_event "colo" "bootstrap_generation.secondary_rbd_unmap" "warn" "${vm}" "" \
      "generation=${generation} reason=${reason}"
  }

  ftctl_state_set "${vm}" \
    "xcolo_bootstrap_generation_teardown_reason=${reason}" \
    "xcolo_bootstrap_generation_teardown_last=${generation}" \
    "standby_state=stopped" \
    "peer_domain_expected=false"
  ftctl_log_event "colo" "bootstrap_generation.teardown" "ok" "${vm}" "" \
    "generation=${generation} reason=${reason} secondary=${secondary_vm}"
}

ftctl_xcolo_finish_primary_generated_async() {
  local vm="${1-}"
  local generated_xml="${2-}"
  local handle="${3-}"
  local pid="" rc_file="" out_file="" err_file="" tmp_dir=""
  local rc err_summary create_error

  IFS='|' read -r pid rc_file out_file err_file tmp_dir <<< "${handle}"
  : "${out_file}"
  if [[ "${pid}" == "dry-run" ]]; then
    ftctl_log_event "colo" "primary.create_generated" "ok" "${vm}" "" "path=${generated_xml} dry_run=1"
    return 0
  fi

  wait "${pid}" >/dev/null 2>&1 || true
  rc="$(cat "${rc_file}" 2>/dev/null || printf '1')"
  if [[ "${rc}" != "0" ]]; then
    create_error="xcolo_primary_create_failed"
    err_summary="$(tr '\n' ' ' < "${err_file}" 2>/dev/null | cut -c1-220 || true)"
    ftctl_xcolo_classify_primary_create_error "${err_summary}" create_error "${vm}" "${generated_xml}" "primary_create_finish"
    ftctl_state_set "${vm}" \
      "xcolo_protocol_failure_phase=primary_create" \
      "xcolo_primary_create_error_summary=$(ftctl_xcolo_compact_log_value "${err_summary}")" \
      "last_error=${create_error}"
    ftctl_log_event "colo" "primary.create_generated" "fail" "${vm}" "${rc}" \
      "path=${generated_xml} log_dir=${tmp_dir} classified=${create_error} error=$(ftctl_xcolo_compact_log_value "${err_summary}")"
    return "${rc}"
  fi
  ftctl_log_event "colo" "primary.create_generated" "ok" "${vm}" "" \
    "path=${generated_xml} log_dir=${tmp_dir}"
}


ftctl_xcolo_primary_has_generated_block_graph() {
  local vm="${1-}"
  local out_var="${2-}"
  local out="" rc=0

  [[ -n "${vm}" ]] || return 2
  if [[ "${FTCTL_DRY_RUN}" == "1" ]]; then
    [[ -n "${out_var}" ]] && printf -v "${out_var}" '%s' "dry-run"
    return 1
  fi

  ftctl_xcolo_qmp "${FTCTL_PROFILE_PRIMARY_URI}" "${vm}" '{"execute":"query-named-block-nodes"}' out rc
  ftctl_xcolo_write_debug_file "${vm}" "primary-restore-query-named-block-nodes.json" "${out}" || true
  [[ -n "${out_var}" ]] && printf -v "${out_var}" '%s' "${out}"
  [[ "${rc}" == "0" ]] || return 2

  case "${out}" in
    *"ftctl-colo-"*|*"ftctl-primary-active-"*|*"ftctl-primary-parent-"*)
      return 0
      ;;
  esac
  return 1
}

ftctl_xcolo_force_primary_restore_from_backup() {
  local vm="${1-}"
  local reason="${2-xcolo_restore_primary}"
  local out="" err="" rc=0 graph="" graph_rc=0 combined="" destroy_state=""

  [[ -n "${vm}" ]] || return 1
  if [[ "${FTCTL_DRY_RUN}" == "1" ]]; then
    ftctl_log_event "colo" "block_conversion.rollback.primary_force_restore" "skip" "${vm}" "" \
      "reason=dry_run cause=${reason}"
    return 0
  fi

  out=""
  err=""
  rc=0
  ftctl_virsh "${FTCTL_BLOCKCOPY_WAIT_TIMEOUT_SEC}" out err rc -- -c "${FTCTL_PROFILE_PRIMARY_URI}" destroy "${vm}" || true
  combined="$(printf '%s %s' "${out}" "${err}")"
  case "${combined}" in
    *"failed to get domain"*|*"domain is not running"*|*"Domain not found"*) rc=0 ;;
  esac
  if [[ "${rc}" != "0" ]]; then
    destroy_state="$(ftctl_xcolo_primary_domain_state "${vm}" 2>/dev/null || echo "unknown")"
    case "${destroy_state}" in
      unknown|shutoff|shut\ off)
        ftctl_log_event "colo" "block_conversion.rollback.primary_destroy" "warn" "${vm}" "${rc}" \
          "cause=${reason} libvirt_state=${destroy_state} action=continue_restore error=$(ftctl_xcolo_compact_log_value "${combined}")"
        rc=0
        ;;
    esac
  fi
  if [[ "${rc}" != "0" ]]; then
    ftctl_state_set "${vm}" \
      "cloud_runtime_restore=primary_destroy_failed" \
      "last_error=${reason}:primary_destroy_failed"
    ftctl_log_event "colo" "block_conversion.rollback.primary_destroy" "fail" "${vm}" "${rc}" \
      "cause=${reason} error=$(ftctl_xcolo_compact_log_value "${combined}")"
    return "${rc}"
  fi

  ftctl_log_event "colo" "block_conversion.rollback.primary_destroy" "ok" "${vm}" "" \
    "cause=${reason}"
  ftctl_xcolo_prepare_primary_krbd_runtime_paths_from_xml "${vm}" \
    "$(ftctl_state_get "${vm}" "primary_xml_backup" 2>/dev/null || true)" \
    "primary_restore" || true

  ftctl_primary_activate_from_backup "${vm}" || {
    ftctl_state_set "${vm}" \
      "cloud_runtime_restore=primary_activate_failed" \
      "last_error=${reason}:primary_restore_failed"
    ftctl_log_event "colo" "block_conversion.rollback.primary_restore" "warn" "${vm}" "" \
      "cause=${reason}"
    return 1
  }

  ftctl_xcolo_primary_has_generated_block_graph "${vm}" graph
  graph_rc=$?
  : "${graph}"
  if [[ "${graph_rc}" == "0" ]]; then
    ftctl_state_set "${vm}" \
      "cloud_runtime_restore=generated_graph_present" \
      "xcolo_primary_restore_graph=generated_graph_present" \
      "xcolo_protocol_failure_phase=rollback_primary_restore" \
      "last_error=xcolo_primary_restore_generated_graph_present"
    ftctl_log_event "colo" "block_conversion.rollback.primary_restore_graph" "fail" "${vm}" "" \
      "cause=${reason} graph=generated_ftctl_nodes_present"
    return 1
  fi

  case "${graph_rc}" in
    2)
      ftctl_state_set "${vm}" \
        "cloud_runtime_restore=qmp_verify_failed" \
        "xcolo_primary_restore_graph=qmp_verify_failed" \
        "xcolo_protocol_failure_phase=rollback_primary_restore" \
        "last_error=xcolo_primary_restore_qmp_failed"
      ftctl_log_event "colo" "block_conversion.rollback.primary_restore_graph" "fail" "${vm}" "" \
        "cause=${reason} graph=qmp_verify_failed"
      return 1
      ;;
  esac

  local restored_state="unknown"
  restored_state="$(ftctl_xcolo_primary_domain_state "${vm}" 2>/dev/null || echo "unknown")"
  case "${restored_state}" in
    running|paused|pmsuspended)
      ftctl_state_set "${vm}" \
        "cloud_runtime_restore=primary_running" \
        "cloud_runtime_restore_verified=verified_cloud_runtime" \
        "cloud_runtime_restore_libvirt_state=${restored_state}" \
        "cloud_runtime_restore_needs_reconcile=yes" \
        "xcolo_primary_restore_graph=clean"
      ;;
    *)
      ftctl_state_set "${vm}" \
        "cloud_runtime_restore=primary_domain_missing" \
        "cloud_runtime_restore_verified=missing_cloud_runtime" \
        "cloud_runtime_state_mismatch=true" \
        "cloud_runtime_restore_libvirt_state=${restored_state}" \
        "xcolo_primary_restore_graph=clean" \
        "xcolo_protocol_failure_phase=rollback_primary_restore" \
        "last_error=${reason}:primary_domain_missing"
      ftctl_log_event "colo" "block_conversion.rollback.primary_restore_graph" "fail" "${vm}" "" \
        "cause=${reason} libvirt_state=${restored_state} reason=primary_domain_missing"
      return 1
      ;;
  esac
  ftctl_log_event "colo" "block_conversion.rollback.primary_restore_graph" "ok" "${vm}" "" \
    "cause=${reason} libvirt_state=${restored_state}"
  ftctl_xcolo_end_primary_krbd_shutdown_guard "${vm}" "primary_restore_done" || true
}

ftctl_xcolo_rollback_block_primary_create_failure() {
  local vm="${1-}"
  local reason="${2-xcolo_block_primary_create_failed}"
  local rollback_stage="rollback_after_primary_create_failed"
  local restore_cmd="ftctl_xcolo_force_primary_restore_from_backup"

  if [[ "${FTCTL_DRY_RUN}" == "1" ]]; then
    ftctl_log_event "colo" "block_conversion.rollback" "skip" "${vm}" "" "reason=dry_run cause=${reason}"
    return 0
  fi

  case "${reason}" in
    xcolo_baseline_seed_failed:*|xcolo_baseline_source_not_ready:*|xcolo_baseline_nbd_start_failed:*|xcolo_baseline_copy_failed:*)
      rollback_stage="rollback_after_baseline_seed_failed"
      restore_cmd="ftctl_primary_activate_from_backup"
      ;;
  esac

  if [[ "${FTCTL_PROFILE_PROVISIONING_BACKEND:-libvirt-managed}" == "cloud-managed" &&
        "${FTCTL_PROFILE_MODE:-}" == "ft" ]] &&
      declare -F ftctl_standby_cleanup_cloud_managed_runtime >/dev/null 2>&1; then
    ftctl_standby_cleanup_cloud_managed_runtime "${vm}" || {
      ftctl_log_event "colo" "block_conversion.rollback.secondary_cleanup" "warn" "${vm}" "" "cause=${reason}"
    }
  else
    ftctl_standby_deactivate "${vm}" || {
      ftctl_log_event "colo" "block_conversion.rollback.secondary_stop" "warn" "${vm}" "" "cause=${reason}"
    }
  fi
  ftctl_xcolo_unmap_secondary_runtime_rbd "${vm}" || {
    ftctl_log_event "colo" "block_conversion.rollback.secondary_rbd_unmap" "warn" "${vm}" "" "cause=${reason}"
  }
  "${restore_cmd}" "${vm}" "${reason}" || {
    ftctl_xcolo_end_primary_krbd_shutdown_guard "${vm}" "rollback_restore_failed" || true
    ftctl_state_set "${vm}" \
      "conversion_stage=${rollback_stage}:primary_restore_failed" \
      "conversion_state=error" \
      "protection_state=error" \
      "transport_state=failed" \
      "active_side=primary" \
      "standby_state=stopped" \
      "peer_domain_expected=false" \
      "xcolo_last_runtime_error=${reason}:primary_restore_failed" \
      "last_error=${reason}:primary_restore_failed"
    ftctl_log_event "colo" "block_conversion.rollback.primary_restore" "warn" "${vm}" "" "cause=${reason}"
    return 1
  }
  ftctl_xcolo_end_primary_krbd_shutdown_guard "${vm}" "rollback_restore_done" || true
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

ftctl_xcolo_rollback_startup_gate_failure() {
  local vm="${1-}"
  local reason="${2-xcolo_startup_gate_failed}"
  local secondary_vm_name out err rc

  if [[ "${FTCTL_DRY_RUN}" == "1" ]]; then
    ftctl_log_event "colo" "block_conversion.rollback_startup_gate" "skip" "${vm}" "" \
      "reason=dry_run cause=${reason}"
    return 0
  fi

  ftctl_xcolo_stop_primary_parent_nbd_adapters "${vm}" "rollback_startup_gate" || true

  secondary_vm_name="$(ftctl_state_get "${vm}" "secondary_vm_name" 2>/dev/null || ftctl_profile_secondary_vm_name_resolved "${vm}")"
  if [[ -n "${secondary_vm_name}" ]]; then
    out=""
    err=""
    rc=0
    ftctl_virsh "${FTCTL_BLOCKCOPY_WAIT_TIMEOUT_SEC}" out err rc -- -c "${FTCTL_PROFILE_SECONDARY_URI}" destroy "${secondary_vm_name}" || true
    : "${out}${err}"
    case "${err}" in
      *"failed to get domain"*|*"domain is not running"*|*"Domain not found"*) rc=0 ;;
    esac
    if [[ "${rc}" == "0" ]]; then
      ftctl_log_event "colo" "block_conversion.rollback_startup_gate.secondary_destroy" "ok" "${vm}" "" \
        "domain=${secondary_vm_name} cause=${reason}"
    else
      ftctl_log_event "colo" "block_conversion.rollback_startup_gate.secondary_destroy" "warn" "${vm}" "${rc}" \
        "domain=${secondary_vm_name} cause=${reason}"
    fi
  fi

  ftctl_xcolo_unmap_secondary_runtime_rbd "${vm}" || {
    ftctl_log_event "colo" "block_conversion.rollback_startup_gate.secondary_rbd_unmap" "warn" "${vm}" "" \
      "cause=${reason}"
  }
  ftctl_xcolo_force_primary_restore_from_backup "${vm}" "${reason}" || {
    ftctl_state_set "${vm}" \
      "conversion_stage=rollback_after_startup_gate_failed:primary_restore_failed" \
      "conversion_state=error" \
      "protection_state=error" \
      "transport_state=failed" \
      "active_side=primary" \
      "standby_state=stopped" \
      "peer_domain_expected=false" \
      "cloud_runtime_restore=failed_before_protection_ready" \
      "xcolo_last_runtime_error=${reason}:primary_restore_failed" \
      "last_error=${reason}:primary_restore_failed"
    ftctl_log_event "colo" "block_conversion.rollback_startup_gate.primary_restore" "warn" "${vm}" "" \
      "cause=${reason}"
    return 1
  }
  ftctl_state_set "${vm}" \
    "conversion_stage=rollback_after_startup_gate_failed" \
    "conversion_state=error" \
    "protection_state=error" \
    "transport_state=failed" \
    "active_side=primary" \
    "standby_state=stopped" \
    "peer_domain_expected=false" \
    "cloud_runtime_restore=skipped_before_protection_ready" \
    "xcolo_last_runtime_error=${reason}" \
    "last_error=${reason}"
  ftctl_log_event "colo" "block_conversion.rollback_startup_gate" "ok" "${vm}" "" "cause=${reason}"
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
if [[ ! -b "\${dest}" ]]; then
  echo "runtime_rbd_stable_path_missing:\${target}:\${dest}:device=\${runtime_device}" >&2
  exit 100
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
      runtime_rbd_stable_path_missing:*)
        ftctl_state_set "${vm}" "last_error=xcolo_secondary_runtime_rbd_stable_path_missing:${target}"
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

  suffix="$(ftctl_xcolo_disk_suffix "${target}")"
  state_key="xcolo_secondary_runtime_rbd_${suffix}"
  ftctl_state_set "${vm}" \
    "${state_key}=${secondary_dest}|${runtime_device}|${mapped_by_ftctl}" \
    "xcolo_secondary_runtime_rbd_stable_${suffix}=${secondary_dest}" \
    "xcolo_secondary_runtime_rbd_resolved_${suffix}=${runtime_device}" \
    "xcolo_secondary_runtime_rbd_prepared=true"
  ftctl_log_event "colo" "block_conversion.secondary_runtime_rbd_prepare" "ok" "${vm}" "" \
    "target=${target} stable_path=${secondary_dest} resolved_device=${runtime_device} mapped_by_ftctl=${mapped_by_ftctl}"
}

ftctl_xcolo_prepare_secondary_runtime_rbd() {
  local vm="${1-}"
  local xml_path="${2-}"
  local disk_plan="${3-}"
  local entry rest target primary_source primary_format primary_dtype secondary_dest
  local -a runtime_disk_entries=()

  [[ "${FTCTL_PROFILE_PROVISIONING_BACKEND:-libvirt-managed}" == "cloud-managed" ]] || return 0
  [[ -n "${xml_path}" && -f "${xml_path}" && -n "${disk_plan}" ]] || return 0
  if [[ "$(ftctl_xcolo_rbd_commandline_backend)" == "librbd" ]]; then
    ftctl_state_set "${vm}"       "xcolo_secondary_runtime_rbd_prepared=skipped_native_rbd"       "xcolo_secondary_runtime_rbd_backend=native-rbd"
    ftctl_log_event "colo" "block_conversion.secondary_runtime_rbd_prepare" "skip" "${vm}" ""       "backend=native-rbd reason=qemu_librbd_runtime"
    return 0
  fi

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

ftctl_xcolo_verify_qemu_rbd_backend_local() {
  local path="${1-}"
  local spec="" out="" err="" rc=0

  ftctl_blockcopy_krbd_spec_from_path "${path}" spec || return 1
  command -v rbd >/dev/null 2>&1 || {
    echo "ERROR: rbd CLI not found for stable KRBD startup backend ${path}" >&2
    return 2
  }
  command -v qemu-img >/dev/null 2>&1 || {
    echo "ERROR: qemu-img not found for stable KRBD startup backend ${path}" >&2
    return 2
  }
  [[ -e "${path}" ]] || {
    echo "ERROR: stable KRBD startup backend path does not exist: ${path}" >&2
    return 2
  }
  rbd info "${spec}" >/dev/null || {
    echo "ERROR: rbd info failed for stable KRBD startup backend ${spec}" >&2
    return 2
  }
  ftctl_cmd_run "${FTCTL_BLOCKCOPY_WAIT_TIMEOUT_SEC}" out err rc -- \
    qemu-img info --force-share --output=json "${path}" || true
  : "${out}"
  if [[ "${rc}" != "0" ]]; then
    echo "ERROR: qemu-img cannot open stable KRBD startup backend ${path}: ${err}" >&2
    return "${rc}"
  fi
}

ftctl_xcolo_verify_qemu_librbd_backend_local() {
  local path="${1-}"
  local spec="" uri="" out="" err="" rc=0

  ftctl_blockcopy_krbd_spec_from_path "${path}" spec || return 1
  command -v rbd >/dev/null 2>&1 || {
    echo "ERROR: rbd CLI not found for native RBD startup backend ${path}" >&2
    return 2
  }
  command -v qemu-img >/dev/null 2>&1 || {
    echo "ERROR: qemu-img not found for native RBD startup backend ${path}" >&2
    return 2
  }
  rbd info "${spec}" >/dev/null || {
    echo "ERROR: rbd info failed for native RBD startup backend ${spec}" >&2
    return 2
  }
  uri="rbd:${spec}"
  ftctl_cmd_run "${FTCTL_BLOCKCOPY_WAIT_TIMEOUT_SEC}" out err rc -- \
    qemu-img info --force-share --output=json "${uri}" || true
  : "${out}"
  if [[ "${rc}" != "0" ]]; then
    echo "ERROR: qemu-img cannot open native RBD startup backend ${uri}: ${err}" >&2
    return "${rc}"
  fi
}

ftctl_xcolo_verify_qemu_rbd_backend_remote() {
  local host="${1-}"
  local user="${2-}"
  local path="${3-}"
  local spec="" q_spec="" q_path="" remote_cmd="" out="" err="" rc=0

  ftctl_blockcopy_krbd_spec_from_path "${path}" spec || return 1
  printf -v q_spec '%q' "${spec}"
  printf -v q_path '%q' "${path}"
  remote_cmd="$(cat <<EOF
set -euo pipefail
command -v rbd >/dev/null 2>&1
command -v qemu-img >/dev/null 2>&1
test -e ${q_path}
rbd info ${q_spec} >/dev/null
qemu-img info --force-share --output=json ${q_path} >/dev/null
EOF
)"
  ftctl_blockcopy_remote_exec "${host}" "${user}" out err rc "${remote_cmd}" || true
  : "${out}"
  if [[ "${rc}" != "0" ]]; then
    echo "ERROR: remote qemu-img cannot open stable KRBD startup backend ${path}: ${err}" >&2
    return "${rc}"
  fi
}

ftctl_xcolo_verify_qemu_librbd_backend_remote() {
  local host="${1-}"
  local user="${2-}"
  local path="${3-}"
  local spec="" q_spec="" q_uri="" remote_cmd="" out="" err="" rc=0

  ftctl_blockcopy_krbd_spec_from_path "${path}" spec || return 1
  printf -v q_spec '%q' "${spec}"
  printf -v q_uri '%q' "rbd:${spec}"
  remote_cmd="$(cat <<EOF
set -euo pipefail
command -v rbd >/dev/null 2>&1
command -v qemu-img >/dev/null 2>&1
rbd info ${q_spec} >/dev/null
qemu-img info --force-share --output=json ${q_uri} >/dev/null
EOF
)"
  ftctl_blockcopy_remote_exec "${host}" "${user}" out err rc "${remote_cmd}" || true
  : "${out}"
  if [[ "${rc}" != "0" ]]; then
    echo "ERROR: remote qemu-img cannot open native RBD startup backend rbd:${spec}: ${err}" >&2
    return "${rc}"
  fi
}

ftctl_xcolo_rbd_commandline_backend() {
  local backend="${FTCTL_XCOLO_RBD_COMMANDLINE_BACKEND:-librbd}"
  backend="$(printf '%s' "${backend}" | tr '[:upper:]' '[:lower:]')"
  case "${backend}" in
    krbd|librbd) ;;
    *) backend="librbd" ;;
  esac
  printf '%s\n' "${backend}"
}

ftctl_xcolo_local_rbd_showmapped_devices() {
  local path="${1-}"
  local out_var="${2}"
  local spec="" pool="" image="" out=""

  ftctl_blockcopy_krbd_spec_from_path "${path}" spec || {
    printf -v "${out_var}" '%s' ""
    return 1
  }
  pool="${spec%%/*}"
  image="${spec#*/}"
  out="$(RBD_POOL="${pool}" RBD_IMAGE="${image}" python3 - <<'RBDJSON' 2>/dev/null || true
import json
import os
import subprocess

pool = os.environ.get("RBD_POOL", "")
image = os.environ.get("RBD_IMAGE", "")
if not pool or not image:
    raise SystemExit(0)

try:
    raw = subprocess.check_output(
        ["rbd", "showmapped", "--format", "json"],
        stderr=subprocess.DEVNULL,
        text=True,
        timeout=10,
    )
    data = json.loads(raw or "{}")
except Exception:
    data = None

rows = []
if isinstance(data, dict):
    if isinstance(data.get("devices"), list):
        rows = data.get("devices") or []
    else:
        rows = [value for value in data.values() if isinstance(value, dict)]
elif isinstance(data, list):
    rows = data

for row in rows:
    row_pool = str(row.get("pool", ""))
    row_image = str(row.get("image", row.get("name", "")))
    row_device = str(row.get("device", row.get("dev", "")))
    row_id = str(row.get("id", row.get("index", "")))
    if row_pool == pool and row_image == image and row_device:
        print(f"{row_id}|{row_device}")
RBDJSON
)"
  if [[ -z "${out}" ]]; then
    out="$(rbd showmapped 2>/dev/null | awk -v p="${pool}" -v i="${image}" '
      NR == 1 {
        for (idx = 1; idx <= NF; idx++) {
          h = tolower($idx)
          if (h == "id") id_idx = idx
          else if (h == "pool") pool_idx = idx
          else if (h == "image" || h == "name") image_idx = idx
          else if (h == "device" || h == "dev") device_idx = idx
        }
        next
      }
      NF > 0 {
        row_id = id_idx ? $id_idx : $1
        row_pool = pool_idx ? $pool_idx : $2
        row_device = device_idx ? $device_idx : $NF
        if (image_idx) {
          row_image = $image_idx
        } else if (NF >= 6) {
          row_image = $4
        } else {
          row_image = $3
        }
        if (row_pool == p && row_image == i && row_device != "") {
          print row_id "|" row_device
        }
      }
    ' || true)"
  fi
  printf -v "${out_var}" '%s' "${out}"
}

ftctl_xcolo_capture_primary_rbd_owner_evidence() {
  local vm="${1-}"
  local disk_plan="${2-}"
  local phase="${3:-runtime}"
  local phase_key entry rest target primary_source primary_format primary_dtype secondary_dest suffix
  local spec="" mapped="" status_out="" lock_out="" map_file status_file lock_file conflict="no" conflict_targets="" backend=""
  local -a entries=() state_args=()

  [[ -n "${vm}" && -n "${disk_plan}" ]] || return 0
  phase_key="$(printf '%s' "${phase}" | tr -c 'A-Za-z0-9_' '_' | sed 's/_*$//')"
  [[ -n "${phase_key}" ]] || phase_key="runtime"
  backend="$(ftctl_xcolo_rbd_commandline_backend)"

  IFS=';' read -r -a entries <<< "${disk_plan}"
  for entry in "${entries[@]}"; do
    [[ -n "${entry}" ]] || continue
    target="${entry%%|*}"
    rest="${entry#*|}"
    primary_source="${rest%%|*}"
    rest="${rest#*|}"
    primary_format="${rest%%|*}"
    rest="${rest#*|}"
    primary_dtype="${rest%%|*}"
    secondary_dest="${rest#*|}"
    : "${primary_format}${primary_dtype}${secondary_dest}"
    ftctl_blockcopy_is_krbd_path "${primary_source}" || continue
    suffix="$(ftctl_xcolo_disk_suffix "${target}")"

    mapped=""
    ftctl_xcolo_local_rbd_showmapped_devices "${primary_source}" mapped || mapped=""
    map_file="primary-${phase_key}-rbd-${suffix}-showmapped.txt"
    ftctl_xcolo_write_debug_file "${vm}" "${map_file}" "${mapped}" || true
    if [[ -n "${mapped}" ]]; then
      if [[ "${backend}" == "librbd" ]]; then
        conflict="yes"
        conflict_targets="${conflict_targets:+${conflict_targets},}${target}"
      fi
      state_args+=("xcolo_primary_${phase_key}_rbd_${suffix}_krbd_mapped=yes")
    else
      state_args+=("xcolo_primary_${phase_key}_rbd_${suffix}_krbd_mapped=no")
    fi

    ftctl_blockcopy_krbd_spec_from_path "${primary_source}" spec || spec=""
    if [[ -n "${spec}" ]]; then
      status_out="$(rbd status "${spec}" 2>&1 || true)"
      lock_out="$(rbd lock list "${spec}" 2>&1 || true)"
      status_file="primary-${phase_key}-rbd-${suffix}-status.txt"
      lock_file="primary-${phase_key}-rbd-${suffix}-lock-list.txt"
      ftctl_xcolo_write_debug_file "${vm}" "${status_file}" "${status_out}" || true
      ftctl_xcolo_write_debug_file "${vm}" "${lock_file}" "${lock_out}" || true
      state_args+=(
        "xcolo_primary_${phase_key}_rbd_${suffix}_status=$(ftctl_xcolo_compact_log_value "${status_out}")"
        "xcolo_primary_${phase_key}_rbd_${suffix}_locks=$(ftctl_xcolo_compact_log_value "${lock_out}")"
      )
    fi
  done

  state_args+=(
    "xcolo_primary_${phase_key}_rbd_runtime_owner_conflict=${conflict}"
    "xcolo_primary_${phase_key}_rbd_runtime_owner_conflict_targets=${conflict_targets}"
  )
  ftctl_state_set "${vm}" "${state_args[@]}"
  ftctl_log_event "colo" "xcolo.primary_rbd_owner_evidence" "$( [[ "${conflict}" == "yes" ]] && printf warn || printf ok )" "${vm}" "" \
    "phase=${phase} backend=${backend} librbd_conflict=${conflict} targets=${conflict_targets}"
}

ftctl_xcolo_release_primary_krbd_maps_for_librbd() {
  local vm="${1-}"
  local disk_plan="${2-}"
  local phase="${3:-before_primary_create}"
  local backend entry rest target primary_source primary_format primary_dtype secondary_dest suffix mapped line map_id map_dev
  local unmap_failed=0 conflict_targets="" spec="" out=""
  local -a entries=()

  [[ -n "${vm}" && -n "${disk_plan}" ]] || return 0
  backend="$(ftctl_xcolo_rbd_commandline_backend)"
  [[ "${backend}" == "librbd" ]] || return 0

  IFS=';' read -r -a entries <<< "${disk_plan}"
  for entry in "${entries[@]}"; do
    [[ -n "${entry}" ]] || continue
    target="${entry%%|*}"
    rest="${entry#*|}"
    primary_source="${rest%%|*}"
    rest="${rest#*|}"
    primary_format="${rest%%|*}"
    rest="${rest#*|}"
    primary_dtype="${rest%%|*}"
    secondary_dest="${rest#*|}"
    : "${primary_format}${primary_dtype}${secondary_dest}"
    ftctl_blockcopy_is_krbd_path "${primary_source}" || continue
    suffix="$(ftctl_xcolo_disk_suffix "${target}")"

    mapped=""
    ftctl_xcolo_local_rbd_showmapped_devices "${primary_source}" mapped || mapped=""
    if [[ -z "${mapped}" && ! -b "${primary_source}" ]]; then
      ftctl_state_set "${vm}" "xcolo_primary_librbd_release_${suffix}=not_mapped"
      continue
    fi

    ftctl_log_event "colo" "xcolo.primary_librbd_release_krbd" "start" "${vm}" "" \
      "phase=${phase} target=${target} stable_path=${primary_source} mapped=$(ftctl_xcolo_compact_log_value "${mapped}")"
    if [[ -b "${primary_source}" ]]; then
      rbd unmap "${primary_source}" >/dev/null 2>&1 || rbd unmap -o force "${primary_source}" >/dev/null 2>&1 || true
    fi
    while IFS='|' read -r map_id map_dev; do
      : "${map_id}"
      [[ -n "${map_dev}" && -b "${map_dev}" ]] || continue
      rbd unmap "${map_dev}" >/dev/null 2>&1 || rbd unmap -o force "${map_dev}" >/dev/null 2>&1 || true
    done <<< "${mapped}"
    udevadm settle >/dev/null 2>&1 || true

    mapped=""
    ftctl_xcolo_local_rbd_showmapped_devices "${primary_source}" mapped || mapped=""
    if [[ -n "${mapped}" || -b "${primary_source}" ]]; then
      unmap_failed=1
      conflict_targets="${conflict_targets:+${conflict_targets},}${target}"
      ftctl_state_set "${vm}" \
        "xcolo_primary_librbd_release_${suffix}=failed" \
        "xcolo_primary_librbd_release_${suffix}_mapped=$(ftctl_xcolo_compact_log_value "${mapped}")"
      ftctl_log_event "colo" "xcolo.primary_librbd_release_krbd" "fail" "${vm}" "" \
        "phase=${phase} target=${target} stable_path=${primary_source} remaining=$(ftctl_xcolo_compact_log_value "${mapped}")"
      continue
    fi

    ftctl_blockcopy_krbd_spec_from_path "${primary_source}" spec || spec=""
    if [[ -n "${spec}" ]]; then
      out="$(rbd status "${spec}" 2>&1 || true)"
      ftctl_xcolo_write_debug_file "${vm}" "primary-${phase}-librbd-${suffix}-status-after-unmap.txt" "${out}" || true
    fi
    ftctl_state_set "${vm}" "xcolo_primary_librbd_release_${suffix}=ok"
    ftctl_log_event "colo" "xcolo.primary_librbd_release_krbd" "ok" "${vm}" "" \
      "phase=${phase} target=${target} stable_path=${primary_source}"
  done

  if [[ "${unmap_failed}" != "0" ]]; then
    ftctl_state_set "${vm}" \
      "xcolo_primary_rbd_runtime_owner_conflict=yes" \
      "xcolo_primary_rbd_runtime_owner_conflict_targets=${conflict_targets}" \
      "xcolo_protocol_failure_phase=primary_rbd_runtime_ownership" \
      "last_error=xcolo_primary_rbd_runtime_owner_conflict:${conflict_targets}"
    return 1
  fi
  return 0
}

ftctl_xcolo_verify_stable_rbd_contract() {
  local vm="${1-}"
  local disk_plan="${2-}"
  local phase="${3:-runtime}"
  local phase_key entry rest target primary_source primary_format primary_dtype secondary_dest
  local host="" user="" map_msg="" backend_msg="" ready="yes" reason="" suffix="" backend=""
  local -a entries=() state_args=()

  [[ -n "${vm}" && -n "${disk_plan}" ]] || return 0
  phase_key="$(printf '%s' "${phase}" | tr -c 'A-Za-z0-9_' '_' | sed 's/_*$//')"
  [[ -n "${phase_key}" ]] || phase_key="runtime"
  backend="$(ftctl_xcolo_rbd_commandline_backend)"

  IFS=';' read -r -a entries <<< "${disk_plan}"
  for entry in "${entries[@]}"; do
    [[ -n "${entry}" ]] || continue
    target="${entry%%|*}"
    rest="${entry#*|}"
    primary_source="${rest%%|*}"
    rest="${rest#*|}"
    primary_format="${rest%%|*}"
    rest="${rest#*|}"
    primary_dtype="${rest%%|*}"
    secondary_dest="${rest#*|}"
    : "${primary_format}${primary_dtype}"
    suffix="$(ftctl_xcolo_disk_suffix "${target}")"

    if ftctl_blockcopy_is_krbd_path "${primary_source}"; then
      state_args+=("xcolo_${phase_key}_rbd_primary_${suffix}=ok:${primary_source}")
      if [[ "${backend}" == "krbd" ]]; then
        map_msg="$(ftctl_blockcopy_krbd_map_local "${primary_source}" 2>&1)" || {
          ready="no"
          reason="${reason:+${reason},}primary_${target}_stable_rbd_unmapped"
          state_args+=("xcolo_${phase_key}_rbd_primary_${suffix}=fail:${primary_source}")
          ftctl_log_event "colo" "xcolo.rbd_contract.primary" "fail" "${vm}" "" \
            "phase=${phase} target=${target} stable_path=${primary_source} backend=${backend} error=$(ftctl_xcolo_compact_log_value "${map_msg}")"
          continue
        }
        backend_msg="$(ftctl_xcolo_verify_qemu_rbd_backend_local "${primary_source}" 2>&1)" || {
          ready="no"
          reason="${reason:+${reason},}primary_${target}_stable_krbd_backend_unavailable"
          state_args+=("xcolo_${phase_key}_rbd_primary_backend_${suffix}=fail:${primary_source}")
          ftctl_log_event "colo" "xcolo.rbd_backend.primary" "fail" "${vm}" "" \
            "phase=${phase} target=${target} path=${primary_source} backend=${backend} error=$(ftctl_xcolo_compact_log_value "${backend_msg}")"
          continue
        }
        state_args+=("xcolo_${phase_key}_rbd_primary_backend_${suffix}=ok:${primary_source}")
      else
        backend_msg="$(ftctl_xcolo_verify_qemu_librbd_backend_local "${primary_source}" 2>&1)" || {
          ready="no"
          reason="${reason:+${reason},}primary_${target}_native_rbd_backend_unavailable"
          state_args+=("xcolo_${phase_key}_rbd_primary_backend_${suffix}=fail:rbd")
          ftctl_log_event "colo" "xcolo.rbd_backend.primary" "fail" "${vm}" "" \
            "phase=${phase} target=${target} path=${primary_source} backend=${backend} error=$(ftctl_xcolo_compact_log_value "${backend_msg}")"
          continue
        }
        state_args+=("xcolo_${phase_key}_rbd_primary_backend_${suffix}=ok:rbd")
      fi
    fi

    if ftctl_blockcopy_is_krbd_path "${secondary_dest}"; then
      if [[ -z "${host}" ]]; then
        ftctl_blockcopy_remote_target_host_user host user || {
          ready="no"
          reason="${reason:+${reason},}secondary_host_unresolved"
          state_args+=("xcolo_${phase_key}_rbd_secondary_${suffix}=fail:${secondary_dest}")
          continue
        }
      fi
      state_args+=("xcolo_${phase_key}_rbd_secondary_${suffix}=ok:${secondary_dest}")
      if [[ "${backend}" == "krbd" ]]; then
        map_msg="$(ftctl_blockcopy_map_remote_krbd_path "${host}" "${user}" "${secondary_dest}" 2>&1)" || {
          ready="no"
          reason="${reason:+${reason},}secondary_${target}_stable_rbd_unmapped"
          state_args+=("xcolo_${phase_key}_rbd_secondary_${suffix}=fail:${secondary_dest}")
          ftctl_log_event "colo" "xcolo.rbd_contract.secondary" "fail" "${vm}" ""             "phase=${phase} target=${target} stable_path=${secondary_dest} backend=${backend} error=$(ftctl_xcolo_compact_log_value "${map_msg}")"
          continue
        }
        backend_msg="$(ftctl_xcolo_verify_qemu_rbd_backend_remote "${host}" "${user}" "${secondary_dest}" 2>&1)" || {
          ready="no"
          reason="${reason:+${reason},}secondary_${target}_stable_krbd_backend_unavailable"
          state_args+=("xcolo_${phase_key}_rbd_secondary_backend_${suffix}=fail:${secondary_dest}")
          ftctl_log_event "colo" "xcolo.rbd_backend.secondary" "fail" "${vm}" ""             "phase=${phase} target=${target} path=${secondary_dest} backend=${backend} error=$(ftctl_xcolo_compact_log_value "${backend_msg}")"
          continue
        }
        state_args+=("xcolo_${phase_key}_rbd_secondary_backend_${suffix}=ok:${secondary_dest}")
      else
        backend_msg="$(ftctl_xcolo_verify_qemu_librbd_backend_remote "${host}" "${user}" "${secondary_dest}" 2>&1)" || {
          ready="no"
          reason="${reason:+${reason},}secondary_${target}_native_rbd_backend_unavailable"
          state_args+=("xcolo_${phase_key}_rbd_secondary_backend_${suffix}=fail:rbd")
          ftctl_log_event "colo" "xcolo.rbd_backend.secondary" "fail" "${vm}" ""             "phase=${phase} target=${target} path=${secondary_dest} backend=${backend} error=$(ftctl_xcolo_compact_log_value "${backend_msg}")"
          continue
        }
        state_args+=("xcolo_${phase_key}_rbd_secondary_backend_${suffix}=ok:rbd")
      fi
    fi
  done

  [[ -n "${reason}" ]] || reason=""
  state_args+=(
    "xcolo_${phase_key}_rbd_contract_ready=${ready}"
    "xcolo_${phase_key}_rbd_contract_reason=${reason}"
    "xcolo_rbd_contract_last_phase=${phase}"
    "xcolo_rbd_contract_ready=${ready}"
    "xcolo_rbd_contract_reason=${reason}"
  )
  if [[ "${ready}" != "yes" ]]; then
    state_args+=(
      "xcolo_protocol_failure_phase=rbd_startup_backend_contract"
      "last_error=xcolo_rbd_startup_backend_unavailable"
    )
  fi
  ftctl_state_set "${vm}" "${state_args[@]}"
  ftctl_log_event "colo" "xcolo.rbd_contract" "$( [[ "${ready}" == "yes" ]] && printf ok || printf fail )" "${vm}" "" \
    "phase=${phase} reason=${reason}"
  [[ "${ready}" == "yes" ]]
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
    : "${runtime_device}${mapped_by_ftctl}"
    if [[ -n "${runtime_dest}" ]]; then
      printf '%s\n' "${runtime_dest}"
      return 0
    fi
  fi
  printf '%s\n' "${fallback}"
}

ftctl_xcolo_unmap_secondary_runtime_rbd() {
  local vm="${1-}"
  local host="" user="" line key value dest runtime_device mapped_by_ftctl out="" err="" rc=0 q_device remote_cmd
  local disk_plan entry rest target primary_source primary_format primary_dtype secondary_dest q_dest
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
    printf -v q_device '%q' "${dest}"
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
        "key=${key} stable_path=${dest} resolved_device=${runtime_device}"
    else
      ftctl_log_event "colo" "block_conversion.secondary_runtime_rbd_unmap" "fail" "${vm}" "${rc}" \
        "key=${key} stable_path=${dest} resolved_device=${runtime_device} error=$(printf '%s %s' "${out}" "${err}" | tr '\n' ' ' | cut -c1-220)"
      unmap_failed=1
    fi
  done < "${state_path}"

  disk_plan="$(ftctl_state_get "${vm}" "xcolo_disk_plan" 2>/dev/null || true)"
  if [[ -n "${disk_plan}" ]]; then
    IFS=';' read -r -a _ftctl_xcolo_unmap_entries <<< "${disk_plan}"
    for entry in "${_ftctl_xcolo_unmap_entries[@]}"; do
      [[ -n "${entry}" ]] || continue
      target="${entry%%|*}"
      rest="${entry#*|}"
      primary_source="${rest%%|*}"
      rest="${rest#*|}"
      primary_format="${rest%%|*}"
      rest="${rest#*|}"
      primary_dtype="${rest%%|*}"
      secondary_dest="${rest#*|}"
      : "${target}${primary_source}${primary_format}${primary_dtype}"
      ftctl_blockcopy_is_krbd_path "${secondary_dest}" || continue
      if [[ -z "${host}" ]]; then
        ftctl_blockcopy_remote_target_host_user host user || {
          unmap_failed=1
          break
        }
      fi
      printf -v q_dest '%q' "${secondary_dest}"
      remote_cmd="$(cat <<EOF
set -euo pipefail
stable=${q_dest}
pool=""
image=""
if [[ "\${stable}" == /dev/rbd/*/* ]]; then
  spec="\${stable#/dev/rbd/}"
  pool="\${spec%%/*}"
  image="\${spec#*/}"
fi
if [[ -b "\${stable}" ]]; then
  rbd unmap "\${stable}" >/dev/null 2>&1 || true
fi
if [[ -n "\${pool}" && -n "\${image}" ]]; then
  rbd showmapped 2>/dev/null | awk -v p="\${pool}" -v i="\${image}" 'NR > 1 && \$2 == p && \$4 == i {print \$6}' |
  while IFS= read -r mapped; do
    [[ -n "\${mapped}" && -b "\${mapped}" ]] || continue
    rbd unmap "\${mapped}" >/dev/null 2>&1 || rbd unmap -o force "\${mapped}" >/dev/null 2>&1 || true
  done
fi
udevadm settle >/dev/null 2>&1 || true
EOF
)"
      out=""
      err=""
      rc=0
      ftctl_blockcopy_remote_exec "${host}" "${user}" out err rc "${remote_cmd}" || true
      if [[ "${rc}" == "0" ]]; then
        ftctl_log_event "colo" "block_conversion.secondary_runtime_rbd_unmap_fallback" "ok" "${vm}" "" \
          "target=${target} stable_path=${secondary_dest}"
      else
        ftctl_log_event "colo" "block_conversion.secondary_runtime_rbd_unmap_fallback" "fail" "${vm}" "${rc}" \
          "target=${target} stable_path=${secondary_dest} error=$(printf '%s %s' "${out}" "${err}" | tr '\n' ' ' | cut -c1-220)"
        unmap_failed=1
      fi
    done
  fi

  [[ "${unmap_failed}" == "0" ]]
}

ftctl_xcolo_execute_block_cold_conversion() {
  local vm="${1-}"
  local primary_generated_xml standby_generated_xml primary_source secondary_dest
  local primary_overlay secondary_pair secondary_hidden secondary_active
  local primary_base_node primary_qdev secondary_base_node secondary_qdev
  local secondary_vm primary_size secondary_size host user out err rc primary_create_handle
  local disk_plan entry rest target primary_format primary_dtype suffix seed_error runtime_prepare_error
  local secondary_runtime_source secondary_baseline_format disk_runtime startup_error
  local bootstrap_attempt bootstrap_max bootstrap_error bootstrap_success
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

  ftctl_xcolo_begin_primary_krbd_shutdown_guard "${vm}" "${primary_generated_xml}" "before_primary_shutdown" || {
    local guard_error
    guard_error="$(ftctl_state_get "${vm}" "last_error" 2>/dev/null || true)"
    [[ -n "${guard_error}" ]] || guard_error="xcolo_primary_krbd_guard_prepare_failed"
    ftctl_state_set "${vm}" "last_error=${guard_error}"
    return 1
  }

  ftctl_xcolo_shutdown_primary_for_conversion "${vm}" || {
    ftctl_log_event "colo" "block_conversion.primary_stop" "fail" "${vm}" "" \
      "reason=shutdown_failed"
    ftctl_state_set "${vm}" "last_error=xcolo_block_shutdown_failed"
    ftctl_xcolo_end_primary_krbd_shutdown_guard "${vm}" "primary_shutdown_failed" || true
    return 1
  }

  ftctl_state_set "${vm}" "conversion_stage=primary_stopped"
  ftctl_log_event "colo" "block_conversion.primary_stop" "ok" "${vm}" "" ""
  ftctl_xcolo_wait_primary_shutdown_hook_settle "${vm}" || true

  ftctl_xcolo_verify_stable_rbd_contract "${vm}" "${disk_plan}" "after_primary_stop" || {
    local rbd_error
    rbd_error="$(ftctl_state_get "${vm}" "last_error" 2>/dev/null || true)"
    [[ -n "${rbd_error}" ]] || rbd_error="xcolo_rbd_startup_backend_unavailable"
    ftctl_xcolo_rollback_block_primary_create_failure "${vm}" "${rbd_error}" || true
    ftctl_state_set "${vm}" \
      "conversion_state=error" \
      "protection_state=error" \
      "transport_state=failed" \
      "xcolo_last_runtime_error=${rbd_error}" \
      "last_error=${rbd_error}"
    return 1
  }

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

  ftctl_state_set "${vm}" "conversion_stage=startup_disk_graph_preparing"
  host=""
  user=""
  ftctl_blockcopy_remote_target_host_user host user || true
  disk_runtime=""
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
    secondary_runtime_source="${secondary_dest}"
    : "${primary_dtype}${secondary_runtime_source}"
    suffix="$(ftctl_xcolo_disk_suffix "${target}")"
    secondary_baseline_format="$(ftctl_state_get "${vm}" "xcolo_disk_${suffix}_secondary_baseline_graph_format" 2>/dev/null || true)"
    if [[ -z "${secondary_baseline_format}" ]]; then
      ftctl_log_event "colo" "block_conversion.baseline_seed.format" "fail" "${vm}" "" \
        "target=${target} secondary_dest=${secondary_dest} reason=missing_seed_graph_format"
      ftctl_state_set "${vm}" "last_error=xcolo_secondary_baseline_format_missing:${target}"
      ftctl_xcolo_rollback_block_primary_create_failure "${vm}" "xcolo_secondary_baseline_format_missing:${target}" || true
      return 1
    fi

    primary_size="$(ftctl_xcolo_disk_virtual_size_bytes "${primary_source}" 2>/dev/null || true)"
    secondary_size=""
    if [[ -n "${host}" ]]; then
      secondary_size="$(ftctl_xcolo_remote_disk_virtual_size_bytes "${host}" "${user}" "${secondary_dest}" 2>/dev/null || true)"
    fi
    if [[ -n "${secondary_size}" && -n "${primary_size}" && "${secondary_size}" != "${primary_size}" ]]; then
      ftctl_log_event "colo" "block_conversion.size_validation" "fail" "${vm}" "" \
        "target=${target} primary_size=${primary_size} secondary_size=${secondary_size}"
      ftctl_state_set "${vm}" "last_error=xcolo_block_preflight_size_mismatch"
      ftctl_xcolo_rollback_block_primary_create_failure "${vm}" "xcolo_block_preflight_size_mismatch" || true
      return 1
    fi
    if [[ -z "${secondary_size}" ]]; then
      secondary_size="${primary_size}"
    fi

    primary_overlay="$(ftctl_xcolo_prepare_primary_overlay "${vm}" "${target}" "${primary_size}")" || {
      ftctl_log_event "colo" "block_conversion.primary_overlay" "fail" "${vm}" "" "target=${target}"
      ftctl_state_set "${vm}" "last_error=xcolo_block_primary_overlay_prepare_failed"
      ftctl_xcolo_rollback_block_primary_create_failure "${vm}" "xcolo_block_primary_overlay_prepare_failed" || true
      return 1
    }
    secondary_pair="$(ftctl_xcolo_prepare_secondary_overlays "${vm}" "${target}" "${secondary_size}")" || {
      ftctl_log_event "colo" "block_conversion.secondary_overlay" "fail" "${vm}" "" "target=${target}"
      ftctl_state_set "${vm}" "last_error=xcolo_block_secondary_overlay_prepare_failed"
      ftctl_xcolo_rollback_block_primary_create_failure "${vm}" "xcolo_block_secondary_overlay_prepare_failed" || true
      return 1
    }
    secondary_hidden="${secondary_pair%%|*}"
    secondary_active="${secondary_pair##*|}"
    primary_base_node="ftctl-primary-parent-${suffix}"
    secondary_base_node="ftctl-parent-${suffix}"
    ftctl_xcolo_disk_qdev_from_xml "${primary_generated_xml}" "${target}" primary_qdev || {
      ftctl_log_event "colo" "xcolo.guest_topology" "fail" "${vm}" "" \
        "target=${target} role=primary reason=qdev_extract_failed"
      ftctl_state_set "${vm}" \
        "conversion_stage=startup_disk_graph_failed" \
        "conversion_state=error" \
        "protection_state=error" \
        "transport_state=failed" \
        "last_error=xcolo_startup_disk_topology_missing"
      ftctl_xcolo_rollback_block_primary_create_failure "${vm}" "xcolo_startup_disk_topology_missing" || true
      return 1
    }
    ftctl_xcolo_disk_qdev_from_xml "${standby_generated_xml}" "${target}" secondary_qdev || {
      ftctl_log_event "colo" "xcolo.guest_topology" "fail" "${vm}" "" \
        "target=${target} role=secondary reason=qdev_extract_failed"
      ftctl_state_set "${vm}" \
        "conversion_stage=startup_disk_graph_failed" \
        "conversion_state=error" \
        "protection_state=error" \
        "transport_state=failed" \
        "last_error=xcolo_startup_disk_topology_missing"
      ftctl_xcolo_rollback_block_primary_create_failure "${vm}" "xcolo_startup_disk_topology_missing" || true
      return 1
    }
    if [[ "${primary_qdev}" != "${secondary_qdev}" ]]; then
      ftctl_log_event "colo" "xcolo.guest_topology" "fail" "${vm}" "" \
        "target=${target} primary_qdev=${primary_qdev} secondary_qdev=${secondary_qdev}"
      ftctl_state_set "${vm}" \
        "conversion_stage=startup_disk_graph_failed" \
        "conversion_state=error" \
        "protection_state=error" \
        "transport_state=failed" \
        "last_error=xcolo_guest_topology_mismatch"
      ftctl_xcolo_rollback_block_primary_create_failure "${vm}" "xcolo_guest_topology_mismatch" || true
      return 1
    fi
    ftctl_state_set "${vm}" \
      "xcolo_disk_${suffix}_primary_base_node=${primary_base_node}" \
      "xcolo_disk_${suffix}_primary_base_backend=${primary_base_node}-bb" \
      "xcolo_disk_${suffix}_primary_base_qdev=${primary_qdev}" \
      "xcolo_disk_${suffix}_primary_colo_node=ftctl-colo-${suffix}" \
      "xcolo_disk_${suffix}_primary_colo_backend=ftctl-colo-${suffix}-bb" \
      "xcolo_disk_${suffix}_secondary_base_node=${secondary_base_node}" \
      "xcolo_disk_${suffix}_secondary_base_backend=${secondary_base_node}-bb" \
      "xcolo_disk_${suffix}_secondary_base_qdev=${secondary_qdev}" \
      "xcolo_disk_${suffix}_secondary_colo_node=ftctl-colo-${suffix}" \
      "xcolo_disk_${suffix}_secondary_colo_backend=ftctl-colo-${suffix}-bb" \
      "xcolo_disk_${suffix}_primary_overlay=${primary_overlay}" \
      "xcolo_disk_${suffix}_secondary_hidden=${secondary_hidden}" \
      "xcolo_disk_${suffix}_secondary_active=${secondary_active}"
    disk_runtime+="${disk_runtime:+;}${target}|${primary_source}|${primary_format}|${primary_overlay}|${secondary_dest}|${secondary_hidden}|${secondary_active}|${secondary_baseline_format}"
    ftctl_log_event "colo" "block_conversion.startup_overlay_prepare" "ok" "${vm}" "" \
      "target=${target} primary_overlay=${primary_overlay} secondary_hidden=${secondary_hidden} secondary_active=${secondary_active} secondary_baseline_format=${secondary_baseline_format}"
  done

  ftctl_xcolo_apply_startup_disk_graphs "${vm}" "${primary_generated_xml}" "${standby_generated_xml}" "${disk_runtime}" "${primary_qemu_args}" "${secondary_qemu_args}" || {
    startup_error="$(ftctl_state_get "${vm}" "last_error" 2>/dev/null || true)"
    [[ -n "${startup_error}" ]] || startup_error="xcolo_startup_disk_graph_prepare_failed"
    ftctl_state_set "${vm}" \
      "conversion_stage=startup_disk_graph_failed" \
      "conversion_state=error" \
      "protection_state=error" \
      "transport_state=failed" \
      "last_error=${startup_error}"
    ftctl_xcolo_rollback_startup_gate_failure "${vm}" "${startup_error}" || true
    return 1
  }
  ftctl_state_set "${vm}" "conversion_stage=startup_disk_graph_ready"

  ftctl_state_set "${vm}" "conversion_stage=primary_rbd_runtime_ownership_preparing"
  ftctl_xcolo_release_primary_krbd_maps_for_librbd "${vm}" "${disk_plan}" "before_primary_create" || {
    local rbd_owner_error
    rbd_owner_error="$(ftctl_state_get "${vm}" "last_error" 2>/dev/null || true)"
    [[ -n "${rbd_owner_error}" ]] || rbd_owner_error="xcolo_primary_rbd_runtime_owner_conflict"
    ftctl_xcolo_rollback_startup_gate_failure "${vm}" "${rbd_owner_error}" || true
    ftctl_state_set "${vm}" \
      "conversion_stage=primary_rbd_runtime_ownership_failed" \
      "conversion_state=error" \
      "protection_state=error" \
      "transport_state=failed" \
      "xcolo_last_runtime_error=${rbd_owner_error}" \
      "last_error=${rbd_owner_error}"
    return 1
  }
  ftctl_xcolo_capture_primary_rbd_owner_evidence "${vm}" "${disk_plan}" "before_primary_create" || true
  ftctl_state_set "${vm}" "conversion_stage=primary_rbd_runtime_ownership_ready"

  ftctl_xcolo_verify_stable_rbd_contract "${vm}" "${disk_plan}" "before_primary_create" || {
    local rbd_error
    rbd_error="$(ftctl_state_get "${vm}" "last_error" 2>/dev/null || true)"
    [[ -n "${rbd_error}" ]] || rbd_error="xcolo_rbd_startup_backend_unavailable"
    ftctl_xcolo_rollback_block_primary_create_failure "${vm}" "${rbd_error}" || true
    ftctl_state_set "${vm}" \
      "conversion_state=error" \
      "protection_state=error" \
      "transport_state=failed" \
      "xcolo_last_runtime_error=${rbd_error}" \
      "last_error=${rbd_error}"
    return 1
  }

  bootstrap_max="$(ftctl_xcolo_bootstrap_generation_attempts)"
  bootstrap_success="0"
  bootstrap_error=""
  for ((bootstrap_attempt=1; bootstrap_attempt<=bootstrap_max; bootstrap_attempt++)); do
    primary_create_handle=""
    ftctl_state_set "${vm}" \
      "xcolo_bootstrap_generation=${bootstrap_attempt}" \
      "xcolo_bootstrap_generation_max=${bootstrap_max}" \
      "conversion_stage=primary_create_generation_${bootstrap_attempt}"
    ftctl_log_event "colo" "bootstrap_generation.start" "ok" "${vm}" "" \
      "generation=${bootstrap_attempt}/${bootstrap_max} primary=${primary_generated_xml} secondary=${standby_generated_xml}"

    ftctl_log_event "colo" "block_conversion.primary_create" "ok" "${vm}" "" \
      "path=${primary_generated_xml} generation=${bootstrap_attempt}"
    if ! ftctl_xcolo_start_primary_generated_async "${vm}" "${primary_generated_xml}" primary_create_handle; then
      bootstrap_error="xcolo_block_primary_create_failed"
      ftctl_log_event "colo" "block_conversion.primary_create" "fail" "${vm}" "" \
        "path=${primary_generated_xml} generation=${bootstrap_attempt}"
      ftctl_state_set "${vm}" "last_error=${bootstrap_error}"
    else
      ftctl_state_set "${vm}" "conversion_stage=primary_create_started"
      if ! ftctl_xcolo_wait_primary_generated_listeners "${vm}" "${primary_create_handle}"; then
        bootstrap_error="$(ftctl_state_get "${vm}" "last_error" 2>/dev/null || true)"
        [[ -n "${bootstrap_error}" ]] || bootstrap_error="xcolo_block_primary_listener_wait_failed"
        ftctl_log_event "colo" "block_conversion.primary_create" "fail" "${vm}" "" \
          "path=${primary_generated_xml} reason=${bootstrap_error} generation=${bootstrap_attempt}"
        ftctl_state_set "${vm}" "last_error=${bootstrap_error}"
      else
        ftctl_state_set "${vm}" "conversion_stage=primary_listening"
        if ! ftctl_xcolo_verify_stable_rbd_contract "${vm}" "${disk_plan}" "before_secondary_create"; then
          bootstrap_error="$(ftctl_state_get "${vm}" "last_error" 2>/dev/null || true)"
          [[ -n "${bootstrap_error}" ]] || bootstrap_error="xcolo_rbd_startup_backend_unavailable"
          ftctl_state_set "${vm}" "last_error=${bootstrap_error}"
        else
          ftctl_log_event "colo" "block_conversion.secondary_create" "ok" "${vm}" "" \
            "path=${standby_generated_xml} generation=${bootstrap_attempt}"
          if ! ftctl_standby_activate "${vm}"; then
            bootstrap_error="xcolo_block_secondary_create_failed"
            ftctl_log_event "colo" "block_conversion.secondary_create" "fail" "${vm}" "" \
              "path=${standby_generated_xml} generation=${bootstrap_attempt}"
            ftctl_state_set "${vm}" "last_error=${bootstrap_error}"
          else
            ftctl_state_set "${vm}" "conversion_stage=secondary_created"
            ftctl_log_event "colo" "block_conversion.secondary_create" "ok" "${vm}" "" \
              "vm=${secondary_vm} generation=${bootstrap_attempt}"
            if ftctl_xcolo_wait_primary_peer_connections "${vm}" "${primary_create_handle}"; then
              bootstrap_success="1"
              bootstrap_error=""
              break
            fi
            bootstrap_error="$(ftctl_state_get "${vm}" "last_error" 2>/dev/null || true)"
            [[ -n "${bootstrap_error}" ]] || bootstrap_error="xcolo_channel_attach_timeout"
            ftctl_log_event "colo" "block_conversion.channel_attach" "fail" "${vm}" "" \
              "primary=${vm} secondary=${secondary_vm} reason=${bootstrap_error} generation=${bootstrap_attempt} classified=$(ftctl_state_get "${vm}" "xcolo_channel_attach_failure_reason" 2>/dev/null || true)"
          fi
        fi
      fi
    fi

    ftctl_state_set "${vm}" \
      "xcolo_bootstrap_generation_last_error=${bootstrap_error}" \
      "conversion_stage=bootstrap_generation_failed"
    if (( bootstrap_attempt < bootstrap_max )); then
      ftctl_xcolo_teardown_bootstrap_generation "${vm}" "${primary_create_handle}" "${secondary_vm}" "${bootstrap_error}" "${bootstrap_attempt}" || true
      ftctl_log_event "colo" "bootstrap_generation.retry" "warn" "${vm}" "" \
        "failed_generation=${bootstrap_attempt} next_generation=$((bootstrap_attempt + 1)) reason=${bootstrap_error}"
      continue
    fi

    ftctl_xcolo_abort_primary_generated_async "${vm}" "${primary_create_handle}" || true
    ftctl_state_set "${vm}" \
      "conversion_stage=channel_attach_failed" \
      "conversion_state=error" \
      "protection_state=error" \
      "transport_state=failed" \
      "last_error=${bootstrap_error}"
    ftctl_xcolo_rollback_block_primary_create_failure "${vm}" "${bootstrap_error}" || true
    return 1
  done

  [[ "${bootstrap_success}" == "1" ]] || {
    bootstrap_error="${bootstrap_error:-xcolo_bootstrap_generation_failed}"
    ftctl_state_set "${vm}" "last_error=${bootstrap_error}"
    ftctl_xcolo_rollback_block_primary_create_failure "${vm}" "${bootstrap_error}" || true
    return 1
  }
  ftctl_state_set "${vm}" "conversion_stage=channels_attached"
  ftctl_xcolo_assert_no_premigrate_filter_mirror_send "${vm}" "after_channel_attach" || {
    ftctl_xcolo_abort_primary_generated_async "${vm}" "${primary_create_handle}"
    ftctl_xcolo_rollback_block_primary_create_failure "${vm}" "xcolo_filter_mirror_send_before_migrate" || true
    return 1
  }

  ftctl_xcolo_finish_primary_generated_async "${vm}" "${primary_generated_xml}" "${primary_create_handle}" || {
    ftctl_log_event "colo" "block_conversion.primary_create" "fail" "${vm}" "" \
      "path=${primary_generated_xml}"
    ftctl_state_set "${vm}" "last_error=xcolo_block_primary_create_failed"
    ftctl_xcolo_rollback_block_primary_create_failure "${vm}" "xcolo_block_primary_create_failed" || true
    return 1
  }
  ftctl_state_set "${vm}" "conversion_stage=primary_created"
  ftctl_log_event "colo" "block_conversion.primary_create" "ok" "${vm}" "" ""
  ftctl_xcolo_end_primary_krbd_shutdown_guard "${vm}" "primary_generated_created" || true
  ftctl_xcolo_assert_no_premigrate_filter_mirror_send "${vm}" "after_primary_create" || {
    ftctl_xcolo_rollback_block_primary_create_failure "${vm}" "xcolo_filter_mirror_send_before_migrate" || true
    return 1
  }

  ftctl_xcolo_require_primary_netdev_vhost_off "${vm}" || {
    ftctl_xcolo_abort_primary_generated_async "${vm}" "${primary_create_handle}"
    ftctl_xcolo_rollback_block_primary_create_failure "${vm}" "$(ftctl_state_get "${vm}" "last_error" 2>/dev/null || printf '%s' primary_netdev_vhost_enabled)" || true
    return 1
  }
  ftctl_state_set "${vm}" "conversion_stage=primary_vhost_guard_passed"

  ftctl_xcolo_collect_secondary_block_graph_state "${vm}" "${secondary_vm}" "${disk_plan}" || {
    ftctl_state_set "${vm}" \
      "conversion_stage=startup_secondary_graph_validation_failed" \
      "conversion_state=error" \
      "protection_state=error" \
      "transport_state=failed" \
      "last_error=xcolo_secondary_startup_block_graph_not_ready"
    return 1
  }

  ftctl_xcolo_verify_stable_rbd_contract "${vm}" "${disk_plan}" "before_migrate" || {
    local rbd_error
    rbd_error="$(ftctl_state_get "${vm}" "last_error" 2>/dev/null || true)"
    [[ -n "${rbd_error}" ]] || rbd_error="xcolo_rbd_startup_backend_unavailable"
    ftctl_xcolo_rollback_block_primary_create_failure "${vm}" "${rbd_error}" || true
    ftctl_state_set "${vm}" \
      "conversion_state=error" \
      "protection_state=error" \
      "transport_state=failed" \
      "xcolo_last_runtime_error=${rbd_error}" \
      "last_error=${rbd_error}"
    return 1
  }

  ftctl_xcolo_verify_live_runtime_topology_pair "${vm}" "${secondary_vm}" "before_migrate" || {
    local topology_error
    topology_error="$(ftctl_state_get "${vm}" "last_error" 2>/dev/null || true)"
    [[ -n "${topology_error}" ]] || topology_error="xcolo_live_runtime_topology_mismatch"
    ftctl_state_set "${vm}" \
      "conversion_stage=pre_migrate_live_topology_failed" \
      "conversion_state=error" \
      "protection_state=error" \
      "transport_state=failed" \
      "xcolo_last_runtime_error=${topology_error}" \
      "last_error=${topology_error}"
    ftctl_xcolo_rollback_startup_gate_failure "${vm}" "${topology_error}" || true
    return 1
  }
  ftctl_state_set "${vm}" "conversion_stage=pre_migrate_live_topology_ready"

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

  ftctl_xcolo_capture_primary_qga_baseline "${vm}" || true
  ftctl_xcolo_capture_primary_qemu_log_baseline "${vm}" || true

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
    "xcolo_primary_qemu_args_network=${primary_qemu_args}" \
    "xcolo_secondary_qemu_args_network=${secondary_qemu_args}" \
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

  ftctl_xcolo_capture_primary_qga_baseline "${vm}" || true
  ftctl_xcolo_capture_primary_qemu_log_baseline "${vm}" || true

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

  ftctl_xcolo_require_supported_machine_contract "${vm}" || return 1

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
