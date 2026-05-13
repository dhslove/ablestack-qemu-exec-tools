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

ftctl_blockcopy_state_path() {
  local vm="${1-}"
  echo "$(ftctl_state_path "${vm}").blockcopy"
}

ftctl_blockcopy_reverse_state_path() {
  local vm="${1-}"
  echo "$(ftctl_state_path "${vm}").blockcopy.reverse"
}

ftctl_blockcopy_progress_path() {
  local vm="${1-}"
  echo "$(ftctl_state_path "${vm}").blockcopy.progress"
}

ftctl_blockcopy_progress_event_state_path() {
  local vm="${1-}"
  echo "$(ftctl_state_path "${vm}").blockcopy.progress.event"
}

ftctl_blockcopy_progress_direction_is() {
  local vm="${1-}"
  local expected="${2-}"
  local progress_path

  progress_path="$(ftctl_blockcopy_progress_path "${vm}")"
  [[ -f "${progress_path}" ]] || return 1
  python3 - "${progress_path}" "${expected}" <<'PY'
import json
import sys

try:
    with open(sys.argv[1], "r", encoding="utf-8") as fh:
        data = json.load(fh)
except Exception:
    raise SystemExit(1)

raise SystemExit(0 if data.get("direction") == sys.argv[2] else 1)
PY
}

ftctl_blockcopy_reverse_sync_artifacts_present() {
  local vm="${1-}"
  local reverse_path

  reverse_path="$(ftctl_blockcopy_reverse_state_path "${vm}")"
  [[ -s "${reverse_path}" ]] || return 1
  if ftctl_blockcopy_progress_direction_is "${vm}" "reverse"; then
    return 0
  fi
  [[ ! -f "$(ftctl_blockcopy_progress_path "${vm}")" ]]
}

ftctl_blockcopy_promote_stale_reverse_sync() {
  local vm="${1-}"
  local transport

  ftctl_blockcopy_reverse_sync_artifacts_present "${vm}" || return 1
  transport="$(ftctl_state_get "${vm}" "transport_state" 2>/dev/null || true)"
  case "${transport}" in
    failed_over|unknown|"")
      ftctl_state_set "${vm}" \
        "protection_state=failing_back" \
        "transport_state=reverse_syncing" \
        "last_error=reverse_sync_pending"
      ftctl_log_event "failback" "reverse_sync.recover" "warn" "${vm}" "" \
        "reason=reverse_sync_artifacts_present previous_transport=${transport:-unknown}"
      return 0
      ;;
  esac
  return 1
}

ftctl_blockcopy_state_write() {
  local vm="${1-}"
  shift
  local path tmp line
  path="$(ftctl_blockcopy_state_path "${vm}")"
  tmp="$(mktemp -t ftctl.blockcopy.XXXXXX)"
  for line in "$@"; do
    printf "%s\n" "${line}" >> "${tmp}"
  done
  mv -f "${tmp}" "${path}"
  chmod 0644 "${path}" 2>/dev/null || true
}

ftctl_blockcopy_state_record_for_target() {
  local vm="${1-}"
  local target="${2-}"
  local out_var="${3}"
  local path line

  path="$(ftctl_blockcopy_state_path "${vm}")"
  [[ -f "${path}" ]] || return 1
  while IFS= read -r line; do
    [[ -n "${line}" ]] || continue
    if [[ "${line%%|*}" == "${target}" ]]; then
      printf -v "${out_var}" '%s' "${line}"
      return 0
    fi
  done < "${path}"
  return 1
}

ftctl_blockcopy_debug_dir() {
  local vm="${1-}"
  local target="${2-}"
  printf '%s\n' "${FTCTL_RUN_DIR}/debug/blockcopy/$(ftctl_state_vm_key "${vm}")/${target}"
}

ftctl_blockcopy_write_debug_file() {
  local vm="${1-}"
  local target="${2-}"
  local name="${3-}"
  local content="${4-}"
  local dir path

  dir="$(ftctl_blockcopy_debug_dir "${vm}" "${target}")"
  ftctl_ensure_dir "${dir}" "0755"
  path="${dir}/${name}"
  printf '%s\n' "${content}" > "${path}"
  chmod 0644 "${path}" 2>/dev/null || true
}

ftctl_blockcopy_progress_refresh_from_qmp() {
  local vm="${1-}"
  local active_vm="${2-}"
  local uri="${3-}"
  local direction="${4-forward}"
  local stage="${5-mirror}"
  local event="${6-blockcopy.progress}"
  local out err rc progress tmp updated path state_path

  out=""
  err=""
  rc=0
  ftctl_virsh "${FTCTL_BLOCKCOPY_WAIT_TIMEOUT_SEC}" out err rc -- -c "${uri}" qemu-monitor-command "${active_vm}" --pretty '{"execute":"query-block-jobs"}' || true
  [[ "${rc}" == "0" ]] || return "${rc}"

  updated="$(ftctl_now_iso8601)"
  if [[ "${direction}" == "reverse" ]]; then
    state_path="$(ftctl_blockcopy_reverse_state_path "${vm}")"
  else
    state_path="$(ftctl_blockcopy_state_path "${vm}")"
  fi

  progress="$(python3 -c '
import json
import re
import sys

direction = sys.argv[1]
updated = sys.argv[2]
state_path = sys.argv[3]

try:
    payload = json.load(sys.stdin)
except Exception:
    sys.exit(1)

records = {}
runtime = {}
try:
    with open(state_path, "r", encoding="utf-8") as fh:
        for raw in fh:
            parts = raw.rstrip("\n").split("|")
            if len(parts) < 3 or not parts[0]:
                continue
            target = parts[0]
            dest = parts[2]
            if direction == "reverse":
                secondary_path = parts[4] if len(parts) > 4 else ""
                guest_virtual_size = parts[5] if len(parts) > 5 else ""
                target_size = parts[6] if len(parts) > 6 else ""
            else:
                secondary_path = parts[6] if len(parts) > 6 else ""
                guest_virtual_size = ""
                target_size = ""
            item = {
                "dest": dest,
                "secondary_path": secondary_path,
            }
            if guest_virtual_size.isdigit():
                item["guest_virtual_size"] = int(guest_virtual_size)
            if target_size.isdigit():
                item["target_size"] = int(target_size)
            match = re.match(r"^nbd://([^:/]+):([0-9]+)/(.+)$", dest or "")
            if match:
                item.update({
                    "nbd_uri": dest,
                    "nbd_host": match.group(1),
                    "nbd_port": int(match.group(2)),
                    "nbd_export_name": match.group(3),
                    "nbd_endpoint": "%s:%s/%s" % (match.group(1), match.group(2), match.group(3)),
                })
            records[target] = item
except Exception:
    records = {}

jobs = payload.get("return", []) or []
disks = []
copied = 0
total = 0
all_ready = bool(jobs)

for job in jobs:
    device = str(job.get("device") or "")
    match = re.match(r"^copy-(.+?)-libvirt-", device)
    target = match.group(1) if match else device
    length = int(job.get("len") or 0)
    offset = int(job.get("offset") or 0)
    if length < 0:
        length = 0
    if offset < 0:
        offset = 0
    ready = bool(job.get("ready"))
    all_ready = all_ready and ready
    copied += offset
    total += length
    percent = round((offset * 100.0 / length), 1) if length > 0 else 0.0
    disk = {
        "target": target,
        "device": device,
        "percent": percent,
        "offset": offset,
        "len": length,
        "ready": ready,
        "status": job.get("status") or "",
        "paused": bool(job.get("paused")),
        "io_status": job.get("io-status") or "",
    }
    record = records.get(target)
    if record:
        if record.get("dest"):
            disk["mirror_uri"] = record.get("dest")
        if record.get("secondary_path"):
            disk["secondary_path"] = record.get("secondary_path")
        if record.get("guest_virtual_size"):
            guest_virtual_size = int(record.get("guest_virtual_size") or 0)
            disk["guest_virtual_size"] = guest_virtual_size
            if length > guest_virtual_size > 0:
                disk["virtual_size_exceeded"] = True
                disk["excess_bytes"] = length - guest_virtual_size
            else:
                disk["virtual_size_exceeded"] = False
                disk["excess_bytes"] = 0
        if record.get("target_size"):
            disk["target_size"] = int(record.get("target_size") or 0)
        for key in ("nbd_uri", "nbd_host", "nbd_port", "nbd_export_name", "nbd_endpoint"):
            if record.get(key) not in (None, ""):
                disk[key] = record.get(key)
    disks.append(disk)

if not disks:
    sys.exit(2)

runtime_path = ""
if state_path.endswith(".blockcopy.reverse"):
    runtime_path = state_path[:-len(".blockcopy.reverse")]
elif state_path.endswith(".blockcopy"):
    runtime_path = state_path[:-len(".blockcopy")]
if runtime_path:
    try:
        with open(runtime_path, "r", encoding="utf-8") as fh:
            for raw in fh:
                raw = raw.rstrip("\n")
                if "=" not in raw:
                    continue
                key, value = raw.split("=", 1)
                if key in ("thin_preserve", "rbd_parent_flattened", "last_thin_preserve_reason"):
                    runtime[key] = value
    except Exception:
        runtime = {}

percent = round((copied * 100.0 / total), 1) if total > 0 else 0.0
payload = {
    "direction": direction,
    "percent": percent,
    "copied_bytes": copied,
    "total_bytes": total,
    "ready": all_ready,
    "updated": updated,
    "disks": disks,
}
payload.update({k: v for k, v in runtime.items() if v not in (None, "")})
print(json.dumps(payload, separators=(",", ":")))
' "${direction}" "${updated}" "${state_path}" <<< "${out}" 2>/dev/null || true)"
  [[ -n "${progress}" ]] || return 2

  path="$(ftctl_blockcopy_progress_path "${vm}")"
  tmp="$(mktemp -t ftctl.blockcopy.progress.XXXXXX)"
  printf '%s\n' "${progress}" > "${tmp}"
  mv -f "${tmp}" "${path}"
  chmod 0644 "${path}" 2>/dev/null || true
  ftctl_blockcopy_progress_log_event "${vm}" "${stage}" "${event}" "${progress}"
}

ftctl_blockcopy_progress_log_event() {
  local vm="${1-}"
  local stage="${2-mirror}"
  local event="${3-blockcopy.progress}"
  local progress_json="${4-}"
  local state_path bucket bucket_key previous details

  [[ -n "${progress_json}" ]] || return 0
  bucket="$(python3 -c '
import json
import math
import sys
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(1)
percent = float(data.get("percent") or 0)
ready = bool(data.get("ready"))
bucket = 100 if ready or percent >= 100 else int(math.floor(percent))
print(bucket)
' <<< "${progress_json}" 2>/dev/null || true)"
  [[ "${bucket}" =~ ^[0-9]+$ ]] || return 0
  bucket_key="${event}:${bucket}"

  state_path="$(ftctl_blockcopy_progress_event_state_path "${vm}")"
  previous=""
  [[ -f "${state_path}" ]] && previous="$(cat "${state_path}" 2>/dev/null || true)"
  [[ "${previous}" != "${bucket_key}" ]] || return 0

  details="$(python3 -c '
import json
import sys
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(1)
print(
    "direction={direction} stage={stage} percent={percent} copied_bytes={copied} total_bytes={total} ready={ready} disks={disks} updated={updated}".format(
        direction=data.get("direction") or "",
        stage=sys.argv[1],
        percent=data.get("percent") or 0,
        copied=data.get("copied_bytes") or 0,
        total=data.get("total_bytes") or 0,
        ready=str(bool(data.get("ready"))).lower(),
        disks=len(data.get("disks") or []),
        updated=data.get("updated") or "",
    )
)
' "${stage}" <<< "${progress_json}" 2>/dev/null || true)"
  [[ -n "${details}" ]] || return 0
  printf '%s\n' "${bucket_key}" > "${state_path}" 2>/dev/null || true
  chmod 0644 "${state_path}" 2>/dev/null || true
  ftctl_log_event "${stage}" "${event}" "ok" "${vm}" "" "${details}"
}

ftctl_blockcopy_refresh_status_progress() {
  local vm="${1-}"
  local transport active_vm

  transport="$(ftctl_state_get "${vm}" "transport_state" 2>/dev/null || true)"
  case "${transport}" in
    copying|mirroring|syncing)
      ftctl_blockcopy_progress_refresh_from_qmp "${vm}" "${vm}" "${FTCTL_PROFILE_PRIMARY_URI}" "forward" "mirror" "blockcopy.progress" >/dev/null 2>&1 || true
      ;;
    reverse_syncing|reverse_sync_ready|reverse_sync_cutback_required)
      ftctl_blockcopy_refresh_reverse_jobs "${vm}" >/dev/null 2>&1 || true
      ;;
    failed_over|unknown|"")
      if ftctl_blockcopy_promote_stale_reverse_sync "${vm}"; then
        ftctl_blockcopy_refresh_reverse_jobs "${vm}" >/dev/null 2>&1 || true
      fi
      ;;
  esac
}

ftctl_blockcopy_resolve_dest() {
  local vm="${1-}"
  local target="${2-}"
  local source="${3-}"
  local format="${4-}"
  local explicit dest source_base

  explicit="$(ftctl_profile_lookup_map_value "${FTCTL_PROFILE_DISK_MAP}" "${target}" 2>/dev/null || true)"
  if [[ -n "${explicit}" ]]; then
    ftctl_blockcopy_validate_cloud_managed_dest "${target}" "${explicit}" || return $?
    printf '%s\n' "${explicit}"
    return 0
  fi

  if ftctl_blockcopy_is_cloud_managed; then
    echo "ERROR: cloud-managed missing destination mapping for disk target ${target}" >&2
    return 2
  fi

  if [[ "${FTCTL_PROFILE_DISK_MAP}" == "auto" ]]; then
    source_base="$(basename "${source}")"
    dest="${FTCTL_BLOCKCOPY_TARGET_BASE_DIR}/${vm}/${target}-${source_base}"
    if [[ -n "${format}" ]]; then
      case "${dest}" in
        *.qcow2|*.raw) ;;
        *)
          dest="${dest}.${format}"
          ;;
      esac
    fi
    printf '%s\n' "${dest}"
    return 0
  fi

  echo "ERROR: no destination mapping for disk target ${target}" >&2
  return 2
}

ftctl_blockcopy_remote_nbd_uri() {
  local host="${1-}"
  local port="${2-}"
  local export_name="${3-}"
  local normalized_host
  ftctl_blockcopy_remote_nbd_host_only "${host}" normalized_host
  printf 'nbd://%s:%s/%s\n' "${normalized_host}" "${port}" "${export_name}"
}

ftctl_blockcopy_remote_nbd_host_only() {
  local value="${1-}"
  local out_var="${2}"
  local host="${value}"

  if [[ "${value}" =~ ^([^:]+):([0-9]+)$ ]]; then
    host="${BASH_REMATCH[1]}"
  fi
  [[ -n "${host}" ]] || return 1
  printf -v "${out_var}" '%s' "${host}"
}

ftctl_blockcopy_is_cloud_managed() {
  [[ "${FTCTL_PROFILE_PROVISIONING_BACKEND:-}" == "cloud-managed" ]]
}

ftctl_blockcopy_is_absolute_dest() {
  local path="${1-}"
  [[ "${path}" == /* ]]
}

ftctl_blockcopy_validate_cloud_managed_dest() {
  local target="${1-}"
  local dest="${2-}"

  ftctl_blockcopy_is_cloud_managed || return 0
  [[ -n "${dest}" ]] || {
    echo "ERROR: cloud-managed missing destination mapping for disk target ${target}" >&2
    return 2
  }
  ftctl_blockcopy_is_absolute_dest "${dest}" || {
    echo "ERROR: cloud-managed disk target ${target} must use an absolute Cloud-managed path: ${dest}" >&2
    return 2
  }
}

ftctl_blockcopy_is_krbd_path() {
  local path="${1-}"
  [[ "${path}" == /dev/rbd/* ]]
}

ftctl_blockcopy_krbd_spec_from_path() {
  local path="${1-}"
  local out_var="${2}"
  [[ "${path}" == /dev/rbd/* ]] || return 1
  printf -v "${out_var}" '%s' "${path#/dev/rbd/}"
}

ftctl_blockcopy_krbd_map_local() {
  local path="${1-}"
  local spec mapped

  ftctl_blockcopy_is_krbd_path "${path}" || return 1
  command -v rbd >/dev/null 2>&1 || {
    echo "ERROR: rbd CLI not found for krbd path ${path}" >&2
    return 2
  }
  if [[ -b "${path}" ]]; then
    return 0
  fi

  ftctl_blockcopy_krbd_spec_from_path "${path}" spec || return 1
  mapped="$(rbd map "${spec}" 2>&1)" || {
    echo "ERROR: rbd map failed for ${spec}: ${mapped}" >&2
    return 2
  }
  udevadm settle >/dev/null 2>&1 || true
  [[ -b "${path}" ]] || {
    echo "ERROR: krbd stable path missing after map: ${path}" >&2
    return 2
  }
}

ftctl_blockcopy_map_remote_krbd_path() {
  local host="${1-}"
  local user="${2-}"
  local path="${3-}"
  local spec q_path q_spec remote_cmd out err rc

  ftctl_blockcopy_krbd_spec_from_path "${path}" spec || return 1
  printf -v q_path '%q' "${path}"
  printf -v q_spec '%q' "${spec}"
  remote_cmd=$(cat <<EOF
set -euo pipefail
path=${q_path}
spec=${q_spec}
if [[ -b "\${path}" ]]; then
  exit 0
fi
command -v rbd >/dev/null 2>&1
rbd map "\${spec}" >/dev/null
udevadm settle >/dev/null 2>&1 || true
[[ -b "\${path}" ]]
EOF
)
  out=""
  err=""
  rc=0
  ftctl_blockcopy_remote_exec "${host}" "${user}" out err rc "${remote_cmd}" || true
  : "${out}"
  if [[ "${rc}" != "0" ]]; then
    echo "ERROR: remote rbd map failed for ${path}: ${err}" >&2
    return "${rc}"
  fi
}

ftctl_blockcopy_payload_indicates_start_failure() {
  local payload="${1-}"
  grep -Eiq \
    "missing destination file|No such file or directory|Cannot access storage file|failed to stat|could not open|failed to get shared" \
    <<< "${payload}"
}

ftctl_blockcopy_remote_nbd_port_extract_from_uri() {
  local uri="${1-}"
  local out_var="${2}"
  local tail port
  tail="${uri#nbd://}"
  tail="${tail#*/}"
  port="${uri#nbd://}"
  port="${port#*:}"
  port="${port%%/*}"
  [[ "${port}" =~ ^[0-9]+$ ]] || return 1
  printf -v "${out_var}" '%s' "${port}"
}

ftctl_blockcopy_remote_nbd_host_extract_from_uri() {
  local uri="${1-}"
  local out_var="${2}"
  local rest host
  rest="${uri#nbd://}"
  host="${rest%%:*}"
  [[ -n "${host}" ]] || return 1
  printf -v "${out_var}" '%s' "${host}"
}

ftctl_blockcopy_remote_nbd_candidate_port() {
  local vm="${1-}"
  local target="${2-}"
  local out_var="${3}"
  local seed offset
  seed="$(printf '%s:%s' "${vm}" "${target}" | cksum | awk '{print $1}')"
  offset=$((seed % FTCTL_REMOTE_NBD_PORT_COUNT))
  printf -v "${out_var}" '%s' "$((FTCTL_REMOTE_NBD_PORT_BASE + offset))"
}

ftctl_blockcopy_remote_nbd_secondary_path() {
  local vm="${1-}"
  local target="${2-}"
  local source="${3-}"
  local format="${4-}"
  local source_base path explicit

  explicit="$(ftctl_profile_lookup_map_value "${FTCTL_PROFILE_DISK_MAP}" "${target}" 2>/dev/null || true)"
  if [[ -n "${explicit}" && "${FTCTL_PROFILE_DISK_MAP}" != "auto" ]]; then
    ftctl_blockcopy_validate_cloud_managed_dest "${target}" "${explicit}" || return $?
    printf '%s\n' "${explicit}"
    return 0
  fi

  if ftctl_blockcopy_is_cloud_managed; then
    if [[ "${FTCTL_PROFILE_DISK_MAP}" == "auto" ]]; then
      echo "ERROR: cloud-managed requires an explicit FTCTL_PROFILE_DISK_MAP" >&2
    else
      echo "ERROR: cloud-managed missing destination mapping for disk target ${target}" >&2
    fi
    return 2
  fi

  source_base="$(basename "${source}")"
  path="${FTCTL_PROFILE_SECONDARY_TARGET_DIR}/${vm}/${target}-${source_base}"
  if [[ -n "${format}" ]]; then
    case "${path}" in
      *.qcow2|*.raw) ;;
      *) path="${path}.${format}" ;;
    esac
  fi
  printf '%s\n' "${path}"
}

ftctl_blockcopy_remote_nbd_target_format() {
  local secondary_path="${1-}"
  local source_format="${2-raw}"
  local out_var="${3}"
  local resolved_format=""

  case "${secondary_path}" in
    /dev/rbd/*)
      resolved_format="raw"
      ;;
    /dev/*)
      resolved_format="${source_format:-raw}"
      ;;
    *.raw)
      resolved_format="raw"
      ;;
    *.qcow2|*.qcow2.*)
      resolved_format="qcow2"
      ;;
    *)
      resolved_format="qcow2"
      ;;
  esac

  printf -v "${out_var}" '%s' "${resolved_format}"
}

ftctl_blockcopy_parse_ssh_target_from_uri() {
  local uri="${1-}"
  local host_var="${2}"
  local user_var="${3}"
  local rest host_value user_value

  [[ "${uri}" == qemu+ssh://* ]] || {
    echo "ERROR: remote-nbd requires qemu+ssh secondary URI" >&2
    return 2
  }
  rest="${uri#qemu+ssh://}"
  rest="${rest%%/*}"
  if [[ "${rest}" == *"@"* ]]; then
    user_value="${rest%@*}"
    host_value="${rest#*@}"
  else
    user_value="${FTCTL_PROFILE_FENCING_SSH_USER}"
    host_value="${rest}"
  fi
  [[ -n "${host_value}" ]] || {
    echo "ERROR: could not parse remote host from URI: ${uri}" >&2
    return 2
  }
  [[ -n "${user_value}" ]] || user_value="root"
  printf -v "${host_var}" '%s' "${host_value}"
  printf -v "${user_var}" '%s' "${user_value}"
}

ftctl_blockcopy_ssh_host_has_explicit_port() {
  local host="${1-}"
  [[ "${host}" =~ ^\[[^]]+\]:[0-9]+$ || "${host}" =~ ^[^:]+:[0-9]+$ ]]
}

ftctl_blockcopy_remote_target_host_user() {
  local host_var="${1}"
  local user_var="${2}"
  local record="" host_id="" role="" mgmt_ip="" libvirt_uri="" blockcopy_ip="" xcolo_ctrl="" xcolo_data=""
  local resolved_host="" resolved_user="" uri_host="" uri_user=""

  ftctl_cluster_load || true
  resolved_user="${FTCTL_PROFILE_FENCING_SSH_USER:-root}"
  if [[ "${FTCTL_PROFILE_SECONDARY_URI}" == "qemu:///system" ]]; then
    resolved_host="${FTCTL_PROFILE_REMOTE_NBD_EXPORT_ADDR:-}"
    [[ -n "${resolved_host}" ]] || resolved_host="127.0.0.1"
    ftctl_blockcopy_remote_nbd_host_only "${resolved_host}" resolved_host || return 2
    printf -v "${host_var}" '%s' "${resolved_host}"
    printf -v "${user_var}" '%s' "${resolved_user}"
    return 0
  fi
  if [[ "${FTCTL_PROFILE_SECONDARY_URI}" == "qemu:///system" && -n "${FTCTL_LOCAL_HOST_ID:-}" ]]; then
    if ftctl_cluster_find_record_by_host_id "${FTCTL_LOCAL_HOST_ID}" record 2>/dev/null; then
      ftctl_cluster_parse_record "${record}" host_id role mgmt_ip libvirt_uri blockcopy_ip xcolo_ctrl xcolo_data
      : "${host_id}${role}${libvirt_uri}${blockcopy_ip}${xcolo_ctrl}${xcolo_data}"
      resolved_host="${mgmt_ip}"
    fi
  fi
  if [[ -z "${resolved_host}" ]] && ftctl_cluster_find_peer_record_for_vm record 2>/dev/null; then
    ftctl_cluster_parse_record "${record}" host_id role mgmt_ip libvirt_uri blockcopy_ip xcolo_ctrl xcolo_data
    : "${host_id}${role}${libvirt_uri}${blockcopy_ip}${xcolo_ctrl}${xcolo_data}"
    resolved_host="${mgmt_ip}"
    if [[ -n "${libvirt_uri}" ]] &&
        ftctl_blockcopy_parse_ssh_target_from_uri "${libvirt_uri}" uri_host uri_user 2>/dev/null; then
      if ftctl_blockcopy_ssh_host_has_explicit_port "${uri_host}"; then
        resolved_host="${uri_host}"
      fi
      if [[ -n "${uri_user}" && "${uri_user}" != "${FTCTL_PROFILE_FENCING_SSH_USER:-root}" ]]; then
        resolved_user="${uri_user}"
      fi
    fi
  fi
  if [[ -z "${resolved_host}" ]]; then
    ftctl_blockcopy_parse_ssh_target_from_uri "${FTCTL_PROFILE_SECONDARY_URI}" resolved_host resolved_user || return 2
  fi
  printf -v "${host_var}" '%s' "${resolved_host}"
  printf -v "${user_var}" '%s' "${resolved_user}"
}

ftctl_blockcopy_split_ssh_host_port() {
  local host_spec="${1-}"
  local host_var="${2}"
  local port_var="${3}"
  local host="${host_spec}"
  local port=""

  if [[ "${host_spec}" =~ ^\[([^]]+)\]:([0-9]+)$ ]]; then
    host="${BASH_REMATCH[1]}"
    port="${BASH_REMATCH[2]}"
  elif [[ "${host_spec}" =~ ^([^:]+):([0-9]+)$ ]]; then
    host="${BASH_REMATCH[1]}"
    port="${BASH_REMATCH[2]}"
  fi
  printf -v "${host_var}" '%s' "${host}"
  printf -v "${port_var}" '%s' "${port}"
}

ftctl_blockcopy_remote_nbd_port_in_use() {
  local host="${1-}"
  local user="${2-}"
  local port="${3-}"
  local out err rc

  out=""
  err=""
  rc=0
  ftctl_blockcopy_remote_exec "${host}" "${user}" out err rc "ss -lntp | grep -q ':${port}[[:space:]]'" || true
  [[ "${rc}" == "0" ]]
}

ftctl_blockcopy_remote_path_exists() {
  local host="${1-}"
  local user="${2-}"
  local path="${3-}"
  local out err rc

  out=""
  err=""
  rc=0
  ftctl_blockcopy_remote_exec "${host}" "${user}" out err rc "test -e $(printf '%q' "${path}")" || true
  [[ "${rc}" == "0" ]]
}

ftctl_blockcopy_remote_nbd_process_exists() {
  local host="${1-}"
  local user="${2-}"
  local needle="${3-}"
  local out err rc

  out=""
  err=""
  rc=0
  ftctl_blockcopy_remote_exec "${host}" "${user}" out err rc "ps -ef | grep qemu-nbd | grep -F -- $(printf '%q' "${needle}") | grep -v grep >/dev/null" || true
  [[ "${rc}" == "0" ]]
}

ftctl_blockcopy_remote_nbd_progress_looks_alive() {
  local dest_uri="${1-}"
  local secondary_path="${2-}"
  local host="" user="" port="" export_name=""

  ftctl_blockcopy_remote_target_host_user host user || return 1
  export_name="${dest_uri##*/}"
  [[ -n "${export_name}" ]] || return 1
  ftctl_blockcopy_remote_nbd_process_exists "${host}" "${user}" "${export_name}" || return 1
  ftctl_blockcopy_remote_nbd_port_extract_from_uri "${dest_uri}" port || return 1
  ftctl_blockcopy_remote_nbd_port_in_use "${host}" "${user}" "${port}" || return 1
  [[ -n "${secondary_path}" ]] || return 0
  ftctl_blockcopy_remote_path_exists "${host}" "${user}" "${secondary_path}"
}

ftctl_blockcopy_remote_preflight_emit() {
  local vm="${1-}"
  local json="${2-0}"
  local result="${3-}"
  local reason="${4-}"
  local peer_uri="${5-}"
  local remote_host="${6-}"
  local remote_user="${7-}"
  local rc="${8-0}"
  if [[ "${json}" == "1" ]]; then
    printf '{"command":"preflight-remote","result":"%s","vm":"%s","reason":"%s","peer_uri":"%s","remote_host":"%s","remote_user":"%s","exit_code":%s}\n' \
      "$(ftctl__json_escape "${result}")" \
      "$(ftctl__json_escape "${vm}")" \
      "$(ftctl__json_escape "${reason}")" \
      "$(ftctl__json_escape "${peer_uri}")" \
      "$(ftctl__json_escape "${remote_host}")" \
      "$(ftctl__json_escape "${remote_user}")" \
      "${rc}"
  else
    printf 'preflight-remote result=%s vm=%s reason=%s peer_uri=%s remote_host=%s remote_user=%s exit_code=%s\n' \
      "${result}" "${vm}" "${reason}" "${peer_uri}" "${remote_host}" "${remote_user}" "${rc}"
  fi
}

ftctl_blockcopy_remote_preflight() {
  local vm="${1-}"
  local json="${2-0}"
  local remote_host="" remote_user="" out="" err="" rc=0 reason="" remote_port=""

  if [[ "${FTCTL_PROFILE_BACKEND_MODE:-}" != "remote-nbd" ]]; then
    reason="unsupported_backend"
    ftctl_blockcopy_remote_preflight_emit "${vm}" "${json}" "fail" "${reason}" "${FTCTL_PROFILE_SECONDARY_URI}" "" "" 2
    return 2
  fi
  if [[ -z "${FTCTL_PROFILE_SECONDARY_URI:-}" ]]; then
    reason="missing_peer_uri"
    ftctl_blockcopy_remote_preflight_emit "${vm}" "${json}" "fail" "${reason}" "" "" "" 2
    return 2
  fi
  ftctl_blockcopy_parse_ssh_target_from_uri "${FTCTL_PROFILE_SECONDARY_URI}" remote_host remote_user || {
    rc=$?
    reason="remote_ssh_uri_invalid"
    ftctl_blockcopy_remote_preflight_emit "${vm}" "${json}" "fail" "${reason}" "${FTCTL_PROFILE_SECONDARY_URI}" "" "" "${rc}"
    return "${rc}"
  }

  out=""
  err=""
  rc=0
  ftctl_blockcopy_remote_exec "${remote_host}" "${remote_user}" out err rc "true" || true
  if [[ "${rc}" != "0" ]]; then
    reason="remote_ssh_auth_failed"
    if grep -Eiq "connection refused" <<< "${out}${err}"; then
      reason="remote_ssh_port_refused"
    elif grep -Eiq "host key verification failed|REMOTE HOST IDENTIFICATION HAS CHANGED" <<< "${out}${err}"; then
      reason="remote_ssh_host_key_mismatch"
    fi
    ftctl_blockcopy_remote_preflight_emit "${vm}" "${json}" "fail" "${reason}" "${FTCTL_PROFILE_SECONDARY_URI}" "${remote_host}" "${remote_user}" "${rc}"
    return "${rc}"
  fi

  out=""
  err=""
  rc=0
  ftctl_virsh "${FTCTL_BLOCKCOPY_WAIT_TIMEOUT_SEC}" out err rc -- -c "${FTCTL_PROFILE_SECONDARY_URI}" list --all || true
  if [[ "${rc}" != "0" ]]; then
    reason="remote_libvirt_unreachable"
    if grep -Eiq "connection refused" <<< "${out}${err}"; then
      reason="remote_ssh_port_refused"
    elif grep -Eiq "permission denied|publickey" <<< "${out}${err}"; then
      reason="remote_ssh_auth_failed"
    elif grep -Eiq "host key verification failed|REMOTE HOST IDENTIFICATION HAS CHANGED" <<< "${out}${err}"; then
      reason="remote_ssh_host_key_mismatch"
    fi
    ftctl_blockcopy_remote_preflight_emit "${vm}" "${json}" "fail" "${reason}" "${FTCTL_PROFILE_SECONDARY_URI}" "${remote_host}" "${remote_user}" "${rc}"
    return "${rc}"
  fi

  if ftctl_blockcopy_remote_nbd_port_extract_from_uri "nbd://${FTCTL_PROFILE_REMOTE_NBD_EXPORT_ADDR:-}/x" remote_port 2>/dev/null && [[ -n "${remote_port}" ]]; then
    out=""
    err=""
    rc=0
    ftctl_blockcopy_remote_exec "${remote_host}" "${remote_user}" out err rc \
      "if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then firewall-cmd --query-service=ablestack-vm-ftctl-remote-nbd >/dev/null 2>&1 || firewall-cmd --query-port=${remote_port}/tcp >/dev/null 2>&1; fi" || true
    if [[ "${rc}" != "0" ]]; then
      reason="remote_nbd_firewall_closed"
      ftctl_blockcopy_remote_preflight_emit "${vm}" "${json}" "fail" "${reason}" "${FTCTL_PROFILE_SECONDARY_URI}" "${remote_host}" "${remote_user}" "${rc}"
      return "${rc}"
    fi
  fi

  ftctl_blockcopy_remote_preflight_emit "${vm}" "${json}" "ok" "ok" "${FTCTL_PROFILE_SECONDARY_URI}" "${remote_host}" "${remote_user}" 0
}

ftctl_blockcopy_remote_nbd_active_count() {
  local host="${1-}"
  local user="${2-}"
  local out_var="${3}"
  local out err rc count remote_cmd

  out=""
  err=""
  rc=0
  remote_cmd=$(cat <<EOF
ss -lntp | python3 -c 'import sys,re; base=${FTCTL_REMOTE_NBD_PORT_BASE}; end=${FTCTL_REMOTE_NBD_PORT_BASE}+${FTCTL_REMOTE_NBD_PORT_COUNT}-1; n=0
for line in sys.stdin:
    if "qemu-nbd" not in line:
        continue
    m = re.search(r":([0-9]+)\\s", line)
    if not m:
        continue
    p = int(m.group(1))
    if base <= p <= end:
        n += 1
print(n)'
EOF
)
  ftctl_blockcopy_remote_exec "${host}" "${user}" out err rc "${remote_cmd}" || true
  if [[ "${rc}" != "0" ]]; then
    return "${rc}"
  fi
  count="$(tr -dc '0-9' <<< "${out}")"
  [[ "${count}" =~ ^[0-9]+$ ]] || count="0"
  printf -v "${out_var}" '%s' "${count}"
}

ftctl_blockcopy_remote_nbd_pick_port() {
  local vm="${1-}"
  local target="${2-}"
  local out_var="${3}"
  local record="" host="" user="" active_count=0 preferred=0 candidate=0 i=0 existing_uri="" existing_port=""

  if [[ "${FTCTL_PROFILE_REMOTE_NBD_EXPORT_PORT}" != "auto" ]]; then
    printf -v "${out_var}" '%s' "${FTCTL_PROFILE_REMOTE_NBD_EXPORT_PORT}"
    return 0
  fi

  if ftctl_blockcopy_state_record_for_target "${vm}" "${target}" record; then
    existing_uri="$(cut -d'|' -f3 <<< "${record}")"
    if ftctl_blockcopy_remote_nbd_port_extract_from_uri "${existing_uri}" existing_port; then
      printf -v "${out_var}" '%s' "${existing_port}"
      return 0
    fi
  fi

  ftctl_blockcopy_remote_target_host_user host user || return 2
  ftctl_blockcopy_remote_nbd_active_count "${host}" "${user}" active_count || true
  if (( active_count >= FTCTL_REMOTE_NBD_MAX_CONCURRENT )); then
    echo "ERROR: remote-nbd active count ${active_count} reached FTCTL_REMOTE_NBD_MAX_CONCURRENT=${FTCTL_REMOTE_NBD_MAX_CONCURRENT}" >&2
    return 3
  fi

  ftctl_blockcopy_remote_nbd_candidate_port "${vm}" "${target}" preferred
  for ((i=0; i<FTCTL_REMOTE_NBD_PORT_COUNT; i++)); do
    candidate=$((FTCTL_REMOTE_NBD_PORT_BASE + ((preferred - FTCTL_REMOTE_NBD_PORT_BASE + i) % FTCTL_REMOTE_NBD_PORT_COUNT)))
    if ! ftctl_blockcopy_remote_nbd_port_in_use "${host}" "${user}" "${candidate}"; then
      printf -v "${out_var}" '%s' "${candidate}"
      return 0
    fi
  done

  echo "ERROR: no free remote-nbd port available in range ${FTCTL_REMOTE_NBD_PORT_BASE}..$((FTCTL_REMOTE_NBD_PORT_BASE + FTCTL_REMOTE_NBD_PORT_COUNT - 1))" >&2
  return 4
}

ftctl_blockcopy_source_virtual_size_bytes() {
  local vm="${1-}"
  local target="${2-}"
  local source_path="${3-}"
  local out_var="${4}"
  local out err rc size_value

  out=""
  err=""
  rc=0
  if [[ -n "${vm}" && -n "${target}" ]]; then
    ftctl_virsh "${FTCTL_BLOCKCOPY_WAIT_TIMEOUT_SEC}" out err rc -- -c "${FTCTL_PROFILE_PRIMARY_URI}" domblkinfo "${vm}" "${target}" || true
    if [[ "${rc}" == "0" ]]; then
      size_value="$(awk -F: 'tolower($1) ~ /capacity/ { line=$0; gsub(/[^0-9]/, "", line); print line; exit }' <<< "${out}")"
      if [[ "${size_value}" =~ ^[0-9]+$ ]]; then
        printf -v "${out_var}" '%s' "${size_value}"
        return 0
      fi
    fi
  fi

  out=""
  err=""
  rc=0
  ftctl_cmd_run "${FTCTL_BLOCKCOPY_WAIT_TIMEOUT_SEC}" out err rc -- qemu-img info --force-share --output=json "${source_path}" || true
  if [[ "${rc}" != "0" ]]; then
    return "${rc}"
  fi
  size_value="$(python3 -c 'import json, sys; obj=json.loads(sys.argv[1]); print(obj.get("virtual-size", ""))' "${out}")" || return 1
  [[ "${size_value}" =~ ^[0-9]+$ ]] || return 1
  printf -v "${out_var}" '%s' "${size_value}"
}

ftctl_blockcopy_source_allocated_size_bytes() {
  local source_path="${1-}"
  local out_var="${2}"
  local out err rc size_value

  out=""
  err=""
  rc=0
  ftctl_cmd_run "${FTCTL_BLOCKCOPY_WAIT_TIMEOUT_SEC}" out err rc -- qemu-img info --force-share --output=json "${source_path}" || true
  if [[ "${rc}" != "0" ]]; then
    return "${rc}"
  fi
  size_value="$(python3 -c 'import json, sys; obj=json.loads(sys.argv[1]); print(obj.get("actual-size", obj.get("virtual-size", "")))' "${out}")" || return 1
  [[ "${size_value}" =~ ^[0-9]+$ ]] || return 1
  printf -v "${out_var}" '%s' "${size_value}"
}

ftctl_blockcopy_local_path_virtual_size_bytes() {
  local path="${1-}"
  local out_var="${2}"
  local out err rc size_value

  [[ -n "${path}" ]] || return 1
  if [[ -b "${path}" ]]; then
    out=""
    err=""
    rc=0
    ftctl_cmd_run "${FTCTL_BLOCKCOPY_WAIT_TIMEOUT_SEC}" out err rc -- blockdev --getsize64 "${path}" || true
    if [[ "${rc}" == "0" && "${out}" =~ ^[0-9]+$ ]]; then
      printf -v "${out_var}" '%s' "${out}"
      return 0
    fi
  fi

  out=""
  err=""
  rc=0
  ftctl_cmd_run "${FTCTL_BLOCKCOPY_WAIT_TIMEOUT_SEC}" out err rc -- qemu-img info --force-share --output=json "${path}" || true
  [[ "${rc}" == "0" ]] || return "${rc}"
  size_value="$(python3 -c 'import json, sys; obj=json.loads(sys.argv[1]); print(obj.get("virtual-size", ""))' "${out}")" || return 1
  [[ "${size_value}" =~ ^[0-9]+$ ]] || return 1
  printf -v "${out_var}" '%s' "${size_value}"
}

ftctl_blockcopy_remote_path_virtual_size_bytes() {
  local host="${1-}"
  local user="${2-}"
  local path="${3-}"
  local out_var="${4}"
  local q_path remote_cmd out err rc size_value

  [[ -n "${path}" ]] || return 1
  printf -v q_path '%q' "${path}"
  remote_cmd=$(cat <<EOF
set -euo pipefail
path=${q_path}
if [[ -b "\${path}" ]]; then
  blockdev --getsize64 "\${path}"
  exit 0
fi
qemu-img info --force-share --output=json "\${path}" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("virtual-size",""))'
EOF
)
  out=""
  err=""
  rc=0
  ftctl_blockcopy_remote_exec "${host}" "${user}" out err rc "${remote_cmd}" || true
  : "${err}"
  [[ "${rc}" == "0" ]] || return "${rc}"
  size_value="$(awk 'NF {print $1; exit}' <<< "${out}")"
  [[ "${size_value}" =~ ^[0-9]+$ ]] || return 1
  printf -v "${out_var}" '%s' "${size_value}"
}

ftctl_blockcopy_disk_bus_from_xml() {
  local xml_path="${1-}"
  local target="${2-}"
  local out_var="${3}"
  local bus_value

  bus_value="$(python3 -c 'import sys, xml.etree.ElementTree as ET; xml_path, target = sys.argv[1], sys.argv[2]; tree = ET.parse(xml_path); root = tree.getroot();
for disk in root.findall("./devices/disk"):
    t = disk.find("target")
    if t is not None and t.get("dev") == target:
        print(t.get("bus", "virtio"))
        break
else:
    print("virtio")' "${xml_path}" "${target}")" || return 1
  printf -v "${out_var}" '%s' "${bus_value}"
}

ftctl_blockcopy_rbd_parse_spec() {
  local spec="${1-}"
  local pool_var="${2}"
  local image_var="${3}"
  local -n _pool_ref="${pool_var}"
  local -n _image_ref="${image_var}"
  local body="" parsed_pool="" parsed_image=""

  [[ "${spec}" == rbd:* ]] || return 1
  body="${spec#rbd:}"
  parsed_pool="${body%%/*}"
  parsed_image="${body#*/}"
  [[ -n "${parsed_pool}" && -n "${parsed_image}" && "${parsed_image}" != "${parsed_pool}" ]] || return 1
  _pool_ref="${parsed_pool}"
  _image_ref="${parsed_image}"
}

ftctl_blockcopy_rbd_spec_from_path() {
  local path="${1-}"
  local out_var="${2}"
  local spec=""

  case "${path}" in
    rbd:*)
      spec="${path#rbd:}"
      ;;
    /dev/rbd/*/*)
      spec="${path#/dev/rbd/}"
      ;;
    /dev/rbd/*)
      spec="${path#/dev/rbd/}"
      ;;
    *)
      return 1
      ;;
  esac
  [[ "${spec}" == */* && "${spec}" != */ ]] || return 1
  printf -v "${out_var}" '%s' "${spec}"
}

ftctl_blockcopy_rbd_run_on_primary() {
  local timeout_sec="${1-30}"
  local out_var="${2}"
  local err_var="${3}"
  local rc_var="${4}"
  local command_text="${5-}"
  local host="" user="" out="" err="" rc=0

  if ftctl_blockcopy_primary_uri_is_local_system; then
    ftctl_cmd_run "${timeout_sec}" out err rc -- bash -lc "${command_text}" || true
  else
    ftctl_blockcopy_primary_target_host_user host user || {
      printf -v "${out_var}" '%s' ""
      printf -v "${err_var}" '%s' "primary_target_unresolved"
      printf -v "${rc_var}" '%s' "2"
      return 2
    }
    ftctl_blockcopy_remote_exec "${host}" "${user}" out err rc "${command_text}" || true
  fi
  printf -v "${out_var}" '%s' "${out}"
  printf -v "${err_var}" '%s' "${err}"
  printf -v "${rc_var}" '%s' "${rc}"
  [[ "${rc}" == "0" ]]
}

ftctl_blockcopy_rbd_parent_from_info_json() {
  local json_payload="${1-}"
  python3 -c '
import json, sys
try:
    data = json.loads(sys.argv[1])
except Exception:
    sys.exit(1)
parent = data.get("parent")
if isinstance(parent, dict):
    pool = str(parent.get("pool") or "")
    image = str(parent.get("image") or "")
    snap = str(parent.get("snapshot") or parent.get("snap") or "")
    value = "/".join(x for x in (pool, image) if x)
    if snap:
        value = value + "@" + snap if value else snap
    print(value)
elif isinstance(parent, str):
    print(parent)
' "${json_payload}" 2>/dev/null
}

ftctl_blockcopy_rbd_du_used_bytes_from_json() {
  local json_payload="${1-}"
  python3 -c '
import json, sys
try:
    data = json.loads(sys.argv[1])
except Exception:
    sys.exit(1)
def walk(value):
    if isinstance(value, dict):
        for key in ("used_size", "used_size_bytes", "used", "provisioned_size"):
            raw = value.get(key)
            if isinstance(raw, int):
                print(raw)
                return True
            if isinstance(raw, str) and raw.isdigit():
                print(raw)
                return True
        for item in value.values():
            if walk(item):
                return True
    if isinstance(value, list):
        for item in value:
            if walk(item):
                return True
    return False
if not walk(data):
    sys.exit(1)
' "${json_payload}" 2>/dev/null
}

ftctl_blockcopy_rbd_du_used_bytes_primary() {
  local spec="${1-}"
  local out_var="${2}"
  local q_spec="" out="" err="" rc=0 used=""

  [[ -n "${spec}" ]] || return 1
  printf -v q_spec '%q' "${spec}"
  ftctl_blockcopy_rbd_run_on_primary "${FTCTL_BLOCKCOPY_WAIT_TIMEOUT_SEC}" out err rc \
    "rbd du --format json ${q_spec}" || true
  : "${err}"
  if [[ "${rc}" == "0" ]]; then
    used="$(ftctl_blockcopy_rbd_du_used_bytes_from_json "${out}" || true)"
  fi
  [[ "${used}" =~ ^[0-9]+$ ]] || used=""
  printf -v "${out_var}" '%s' "${used}"
  [[ -n "${used}" ]]
}

ftctl_blockcopy_path_head_sha256_primary() {
  local path="${1-}"
  local bytes="${2-4096}"
  local out_var="${3}"
  local q_path="" out="" err="" rc=0 hash=""

  [[ -n "${path}" && "${bytes}" =~ ^[1-9][0-9]*$ ]] || return 1
  printf -v q_path '%q' "${path}"
  ftctl_blockcopy_rbd_run_on_primary "${FTCTL_BLOCKCOPY_WAIT_TIMEOUT_SEC}" out err rc \
    "test -b ${q_path} && dd if=${q_path} bs=${bytes} count=1 status=none | sha256sum | awk '{print \$1}'" || true
  : "${err}"
  [[ "${rc}" == "0" ]] || return "${rc}"
  hash="$(awk 'NF {print $1; exit}' <<< "${out}")"
  [[ "${hash}" =~ ^[0-9a-fA-F]{64}$ ]] || return 1
  printf -v "${out_var}" '%s' "${hash}"
}

ftctl_blockcopy_zero_sha256() {
  local bytes="${1-4096}"
  local out_var="${2}"
  local hash=""

  [[ "${bytes}" =~ ^[1-9][0-9]*$ ]] || return 1
  hash="$(python3 -c 'import hashlib,sys; print(hashlib.sha256(bytes(int(sys.argv[1]))).hexdigest())' "${bytes}" 2>/dev/null || true)"
  [[ "${hash}" =~ ^[0-9a-fA-F]{64}$ ]] || return 1
  printf -v "${out_var}" '%s' "${hash}"
}

ftctl_blockcopy_verify_target_materialized() {
  local vm="${1-}"
  local target="${2-}"
  local source_path="${3-}"
  local dest_path="${4-}"
  local source_spec="" dest_spec="" source_used="" dest_used=""
  local verify_bytes="${FTCTL_BLOCKCOPY_VERIFY_BYTES:-4096}"
  local source_hash="" dest_hash="" zero_hash=""

  [[ "${FTCTL_BLOCKCOPY_VERIFY_TARGET:-1}" == "1" ]] || return 0
  ftctl_blockcopy_rbd_spec_from_path "${dest_path}" dest_spec || return 0
  ftctl_blockcopy_rbd_spec_from_path "${source_path}" source_spec || source_spec=""

  if [[ -n "${source_spec}" ]]; then
    ftctl_blockcopy_rbd_du_used_bytes_primary "${source_spec}" source_used || source_used=""
  fi
  ftctl_blockcopy_rbd_du_used_bytes_primary "${dest_spec}" dest_used || dest_used=""

  if [[ "${source_used}" =~ ^[1-9][0-9]*$ && "${dest_used}" == "0" ]]; then
    ftctl_log_event "mirror" "blockcopy.verify" "fail" "${vm}" "" \
      "target=${target} reason=target_empty source=${source_spec} source_used=${source_used} dest=${dest_spec} dest_used=${dest_used}"
    return 21
  fi

  ftctl_blockcopy_path_head_sha256_primary "${dest_path}" "${verify_bytes}" dest_hash || dest_hash=""

  if [[ -n "${source_spec}" ]]; then
    ftctl_blockcopy_zero_sha256 "${verify_bytes}" zero_hash || zero_hash=""
    ftctl_blockcopy_path_head_sha256_primary "${source_path}" "${verify_bytes}" source_hash || source_hash=""
    if [[ -n "${source_hash}" && -n "${dest_hash}" && -n "${zero_hash}" && "${source_hash}" != "${zero_hash}" && "${source_hash}" != "${dest_hash}" ]]; then
      ftctl_log_event "mirror" "blockcopy.verify" "fail" "${vm}" "" \
        "target=${target} reason=head_hash_mismatch source=${source_spec} dest=${dest_spec} source_hash=${source_hash} dest_hash=${dest_hash} bytes=${verify_bytes}"
      return 23
    fi
  fi

  ftctl_log_event "mirror" "blockcopy.verify" "ok" "${vm}" "" \
    "target=${target} source=${source_spec} source_used=${source_used} dest=${dest_spec} dest_used=${dest_used} bytes=${verify_bytes}"
}

ftctl_blockcopy_prepare_primary_rbd_thin_for_protect() {
  local vm="${1-}"
  local target="${2-}"
  local source_path="${3-}"
  local spec="" q_spec="" out="" err="" rc=0 parent="" before_used="" after_flatten_used="" after_sparsify_used=""
  local policy="${FTCTL_RBD_PARENT_POLICY:-flatten-on-protect}"

  [[ "${FTCTL_THIN_PRESERVE:-1}" == "1" ]] || return 0
  ftctl_blockcopy_rbd_spec_from_path "${source_path}" spec || return 0

  printf -v q_spec '%q' "${spec}"
  ftctl_blockcopy_rbd_du_used_bytes_primary "${spec}" before_used || before_used=""
  ftctl_blockcopy_rbd_run_on_primary "${FTCTL_BLOCKCOPY_WAIT_TIMEOUT_SEC}" out err rc \
    "rbd info --format json ${q_spec}" || true
  if [[ "${rc}" != "0" ]]; then
    ftctl_log_event "mirror" "rbd.thin.precheck" "warn" "${vm}" "${rc}" \
      "target=${target} image=${spec} error=${err}"
    ftctl_state_set "${vm}" "thin_preserve=warn" "last_thin_preserve_reason=rbd_info_failed:${target}"
    return 0
  fi

  parent="$(ftctl_blockcopy_rbd_parent_from_info_json "${out}" || true)"
  if [[ -z "${parent}" ]]; then
    ftctl_state_set "${vm}" "thin_preserve=enabled" "rbd_parent_flattened=no"
    ftctl_log_event "mirror" "rbd.parent.check" "ok" "${vm}" "" \
      "target=${target} image=${spec} parent=none used_bytes=${before_used}"
    return 0
  fi

  if [[ "${policy}" != "flatten-on-protect" ]]; then
    ftctl_state_set "${vm}" "thin_preserve=enabled" "rbd_parent_flattened=deferred" "last_thin_preserve_reason=parent_present:${target}:${policy}"
    ftctl_log_event "mirror" "rbd.parent.check" "warn" "${vm}" "" \
      "target=${target} image=${spec} parent=${parent} policy=${policy} action=defer_flatten"
    return 0
  fi

  ftctl_state_set "${vm}" "thin_preserve=preparing" "last_thin_preserve_reason=flattening:${target}"
  ftctl_log_event "mirror" "rbd.flatten.start" "ok" "${vm}" "" \
    "target=${target} image=${spec} parent=${parent} used_before=${before_used}"

  out=""; err=""; rc=0
  ftctl_blockcopy_rbd_run_on_primary "${FTCTL_RBD_FLATTEN_TIMEOUT_SEC:-3600}" out err rc \
    "rbd flatten ${q_spec}" || true
  if [[ "${rc}" != "0" ]]; then
    ftctl_state_set "${vm}" "protection_state=error" "transport_state=failed" "thin_preserve=failed" "last_error=rbd_flatten_failed:${target}"
    ftctl_log_event "mirror" "rbd.flatten" "fail" "${vm}" "${rc}" \
      "target=${target} image=${spec} parent=${parent} error=${err}"
    return "${rc}"
  fi

  ftctl_blockcopy_rbd_du_used_bytes_primary "${spec}" after_flatten_used || after_flatten_used=""
  out=""; err=""; rc=0
  ftctl_blockcopy_rbd_run_on_primary "${FTCTL_BLOCKCOPY_WAIT_TIMEOUT_SEC}" out err rc \
    "rbd info --format json ${q_spec}" || true
  parent="$(ftctl_blockcopy_rbd_parent_from_info_json "${out}" || true)"
  if [[ -n "${parent}" ]]; then
    ftctl_state_set "${vm}" "protection_state=error" "transport_state=failed" "thin_preserve=failed" "last_error=rbd_parent_still_present:${target}"
    ftctl_log_event "mirror" "rbd.flatten.verify" "fail" "${vm}" "" \
      "target=${target} image=${spec} parent=${parent}"
    return 2
  fi

  out=""; err=""; rc=0
  ftctl_blockcopy_rbd_run_on_primary "${FTCTL_RBD_SPARSIFY_TIMEOUT_SEC:-1800}" out err rc \
    "rbd sparsify ${q_spec}" || true
  if [[ "${rc}" != "0" ]]; then
    ftctl_state_set "${vm}" "thin_preserve=warn" "rbd_parent_flattened=yes" "last_thin_preserve_reason=rbd_sparsify_failed:${target}"
    ftctl_log_event "mirror" "rbd.sparsify" "warn" "${vm}" "${rc}" \
      "target=${target} image=${spec} used_before=${before_used} used_after_flatten=${after_flatten_used} error=${err}"
    return 0
  fi

  ftctl_blockcopy_rbd_du_used_bytes_primary "${spec}" after_sparsify_used || after_sparsify_used=""
  ftctl_state_set "${vm}" "thin_preserve=enabled" "rbd_parent_flattened=yes" "last_thin_preserve_reason="
  ftctl_log_event "mirror" "rbd.sparsify" "ok" "${vm}" "" \
    "target=${target} image=${spec} used_before=${before_used} used_after_flatten=${after_flatten_used} used_after_sparsify=${after_sparsify_used}"
}

ftctl_blockcopy_rbd_connection_from_xml() {
  local xml_path="${1-}"
  local target="${2-}"
  local host_var="${3}"
  local port_var="${4}"
  local user_var="${5}"
  local secret_var="${6}"
  local values

  values="$(python3 -c 'import sys, xml.etree.ElementTree as ET
xml_path, target = sys.argv[1], sys.argv[2]
tree = ET.parse(xml_path)
root = tree.getroot()
for disk in root.findall("./devices/disk"):
    t = disk.find("target")
    if t is None or t.get("dev") != target:
        continue
    source = disk.find("source")
    auth = disk.find("auth")
    host = ""
    port = ""
    user = ""
    secret = ""
    if source is not None:
        h = source.find("host")
        if h is not None:
            host = h.get("name", "")
            port = h.get("port", "")
    if auth is not None:
        user = auth.get("username", "")
        s = auth.find("secret")
        if s is not None:
            secret = s.get("uuid", "")
    print(host)
    print(port)
    print(user)
    print(secret)
    raise SystemExit(0)
raise SystemExit(1)' "${xml_path}" "${target}")" || return 1
  printf -v "${host_var}" '%s' "$(sed -n '1p' <<< "${values}")"
  printf -v "${port_var}" '%s' "$(sed -n '2p' <<< "${values}")"
  printf -v "${user_var}" '%s' "$(sed -n '3p' <<< "${values}")"
  printf -v "${secret_var}" '%s' "$(sed -n '4p' <<< "${values}")"
}

ftctl_blockcopy_remote_nbd_dest_xml_path() {
  local vm="${1-}"
  local target="${2-}"
  printf '%s\n' "${FTCTL_RUN_DIR}/xml/$(ftctl_state_vm_key "${vm}")-${target}-remote-nbd.xml"
}

ftctl_blockcopy_shared_dest_xml_path() {
  local vm="${1-}"
  local target="${2-}"
  printf '%s\n' "${FTCTL_RUN_DIR}/xml/$(ftctl_state_vm_key "${vm}")-${target}-shared-blockcopy.xml"
}

ftctl_blockcopy_driver_thin_attrs() {
  if [[ "${FTCTL_THIN_PRESERVE:-1}" == "1" ]]; then
    printf " discard='unmap' detect_zeroes='unmap'"
  fi
}

ftctl_blockcopy_build_remote_nbd_dest_xml() {
  local vm="${1-}"
  local target="${2-}"
  local format="${3-}"
  local export_addr="${4-}"
  local export_port="${5-}"
  local export_name="${6-}"
  local source_xml="${7-}"
  local out_path_var="${8}"
  local out_path bus export_host

  out_path="$(ftctl_blockcopy_remote_nbd_dest_xml_path "${vm}" "${target}")"
  ftctl_blockcopy_remote_nbd_host_only "${export_addr}" export_host || return 2
  ftctl_ensure_dir "$(dirname "${out_path}")" "0755"
  bus="virtio"
  if [[ -n "${source_xml}" && -f "${source_xml}" ]]; then
    ftctl_blockcopy_disk_bus_from_xml "${source_xml}" "${target}" bus || true
  fi
  cat > "${out_path}" <<EOF
<disk type='network' device='disk'>
  <driver name='qemu' type='raw' discard='unmap' detect_zeroes='unmap'/>
  <source protocol='nbd' name='${export_name}'>
    <host name='${export_host}' port='${export_port}' transport='tcp'/>
  </source>
  <target dev='${target}' bus='${bus}'/>
</disk>
EOF
  printf -v "${out_path_var}" '%s' "${out_path}"
}

ftctl_blockcopy_build_shared_dest_xml() {
  local vm="${1-}"
  local target="${2-}"
  local format="${3-}"
  local dest="${4-}"
  local source_xml="${5-}"
  local out_path_var="${6}"
  local out_path bus disk_type source_attr_name driver_thin_attrs
  local rbd_pool="" rbd_image="" rbd_host="" rbd_port="" rbd_user="" rbd_secret=""

  out_path="$(ftctl_blockcopy_shared_dest_xml_path "${vm}" "${target}")"
  ftctl_ensure_dir "$(dirname "${out_path}")" "0755"
  bus="virtio"
  if [[ -n "${source_xml}" && -f "${source_xml}" ]]; then
    ftctl_blockcopy_disk_bus_from_xml "${source_xml}" "${target}" bus || true
  fi

  if [[ "${dest}" == rbd:* ]]; then
    disk_type="network"
    source_attr_name=""
    ftctl_blockcopy_rbd_parse_spec "${dest}" rbd_pool rbd_image || return 1
    if [[ -n "${source_xml}" && -f "${source_xml}" ]]; then
      ftctl_blockcopy_rbd_connection_from_xml "${source_xml}" "${target}" rbd_host rbd_port rbd_user rbd_secret || true
    fi
    [[ -n "${rbd_host}" ]] || rbd_host="scvm"
    [[ -n "${rbd_port}" ]] || rbd_port="6789"
    [[ -n "${rbd_user}" ]] || rbd_user="admin"
    [[ -n "${rbd_secret}" ]] || rbd_secret="11111111-1111-1111-1111-111111111111"
  elif [[ "${dest}" == /dev/* ]]; then
    disk_type="block"
    source_attr_name="dev"
  else
    disk_type="file"
    source_attr_name="file"
  fi
  driver_thin_attrs="$(ftctl_blockcopy_driver_thin_attrs)"

  if [[ "${disk_type}" == "network" ]]; then
    cat > "${out_path}" <<EOF
<disk type='network' device='disk'>
  <driver name='qemu' type='${format}'${driver_thin_attrs}/>
  <auth username='${rbd_user}'>
    <secret type='ceph' uuid='${rbd_secret}'/>
  </auth>
  <source protocol='rbd' name='${rbd_pool}/${rbd_image}'>
    <host name='${rbd_host}' port='${rbd_port}'/>
  </source>
  <target dev='${target}' bus='${bus}'/>
</disk>
EOF
  else
    cat > "${out_path}" <<EOF
<disk type='${disk_type}' device='disk'>
  <driver name='qemu' type='${format}'${driver_thin_attrs}/>
  <source ${source_attr_name}='${dest}'/>
  <target dev='${target}' bus='${bus}'/>
</disk>
EOF
  fi
  printf -v "${out_path_var}" '%s' "${out_path}"
}

ftctl_blockcopy_remote_exec() {
  local host="${1-}"
  local user="${2-}"
  local out_var="${3}"
  local err_var="${4}"
  local rc_var="${5}"
  local remote_cmd="${6-}"
  local tmp_cmd=""
  local local_wrapper=""
  local ssh_host="" ssh_port="" ssh_port_args=""
  [[ -n "${host}" ]] || {
    printf -v "${out_var}" '%s' ""
    printf -v "${err_var}" '%s' "missing_remote_host"
    printf -v "${rc_var}" '%s' "2"
    return 2
  }
  [[ -n "${user}" ]] || user="root"
  ftctl_blockcopy_split_ssh_host_port "${host}" ssh_host ssh_port
  [[ -n "${ssh_host}" ]] || ssh_host="${host}"
  if [[ -n "${ssh_port}" ]]; then
    printf -v ssh_port_args -- '-p %q ' "${ssh_port}"
  fi
  [[ -n "${remote_cmd}" ]] || {
    printf -v "${out_var}" '%s' ""
    printf -v "${err_var}" '%s' "missing_remote_command"
    printf -v "${rc_var}" '%s' "2"
    return 2
  }
  tmp_cmd="$(mktemp -t ftctl.remote.XXXXXX)"
  printf '%s\n' "${remote_cmd}" > "${tmp_cmd}"
  chmod 0600 "${tmp_cmd}" 2>/dev/null || true
  if [[ -n "${FTCTL_SSH_PASSWORD:-}" ]] && command -v sshpass >/dev/null 2>&1; then
    printf -v local_wrapper 'sshpass -p %q ssh %s-o StrictHostKeyChecking=no -o ConnectTimeout=%q %q %q < %q' \
      "${FTCTL_SSH_PASSWORD}" \
      "${ssh_port_args}" \
      "${FTCTL_BLOCKCOPY_WAIT_TIMEOUT_SEC}" \
      "${user}@${ssh_host}" \
      "bash -s" \
      "${tmp_cmd}"
  else
    printf -v local_wrapper 'ssh %s-o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=%q %q %q < %q' \
      "${ssh_port_args}" \
      "${FTCTL_BLOCKCOPY_WAIT_TIMEOUT_SEC}" \
      "${user}@${ssh_host}" \
      "bash -s" \
      "${tmp_cmd}"
  fi
  ftctl_cmd_run "${FTCTL_BLOCKCOPY_WAIT_TIMEOUT_SEC}" "${out_var}" "${err_var}" "${rc_var}" -- \
    bash -lc "${local_wrapper}"
  rm -f -- "${tmp_cmd}" 2>/dev/null || true
}

ftctl_blockcopy_secondary_uri_is_local_system() {
  [[ "${FTCTL_PROFILE_SECONDARY_URI}" == "qemu:///system" ]]
}

ftctl_blockcopy_primary_uri_is_local_system() {
  [[ "${FTCTL_PROFILE_PRIMARY_URI}" == "qemu:///system" ]]
}

ftctl_blockcopy_primary_target_host_user() {
  local host_var="${1}"
  local user_var="${2}"
  local record="" host_id="" role="" mgmt_ip="" libvirt_uri="" blockcopy_ip="" xcolo_ctrl="" xcolo_data=""
  local resolved_host="" resolved_user=""

  ftctl_cluster_load || true
  resolved_user="${FTCTL_PROFILE_FENCING_SSH_USER:-root}"
  if [[ "${FTCTL_PROFILE_PRIMARY_URI}" == "qemu:///system" && -n "${FTCTL_LOCAL_HOST_ID:-}" ]]; then
    if ftctl_cluster_find_record_by_host_id "${FTCTL_LOCAL_HOST_ID}" record 2>/dev/null; then
      ftctl_cluster_parse_record "${record}" host_id role mgmt_ip libvirt_uri blockcopy_ip xcolo_ctrl xcolo_data
      : "${host_id}${role}${libvirt_uri}${blockcopy_ip}${xcolo_ctrl}${xcolo_data}"
      resolved_host="${mgmt_ip}"
    fi
  fi
  if ftctl_cluster_find_record_by_libvirt_uri "${FTCTL_PROFILE_PRIMARY_URI}" record 2>/dev/null; then
    ftctl_cluster_parse_record "${record}" host_id role mgmt_ip libvirt_uri blockcopy_ip xcolo_ctrl xcolo_data
    : "${host_id}${role}${libvirt_uri}${xcolo_ctrl}${xcolo_data}"
    resolved_host="${mgmt_ip}"
  fi
  if [[ -z "${resolved_host}" ]]; then
    ftctl_blockcopy_parse_ssh_target_from_uri "${FTCTL_PROFILE_PRIMARY_URI}" resolved_host resolved_user || return 2
  fi
  printf -v "${host_var}" '%s' "${resolved_host}"
  printf -v "${user_var}" '%s' "${resolved_user}"
}

ftctl_blockcopy_primary_export_addr() {
  local -n out_ref="${1}"
  local record="" host_id="" role="" mgmt_ip="" libvirt_uri="" blockcopy_ip="" xcolo_ctrl="" xcolo_data=""
  local result=""

  ftctl_cluster_load || true
  if [[ "${FTCTL_PROFILE_PRIMARY_URI}" == "qemu:///system" && -n "${FTCTL_LOCAL_HOST_ID:-}" ]]; then
    if ftctl_cluster_find_record_by_host_id "${FTCTL_LOCAL_HOST_ID}" record 2>/dev/null; then
      ftctl_cluster_parse_record "${record}" host_id role mgmt_ip libvirt_uri blockcopy_ip xcolo_ctrl xcolo_data
      : "${host_id}${role}${libvirt_uri}${xcolo_ctrl}${xcolo_data}"
      result="${blockcopy_ip:-${mgmt_ip}}"
    fi
  fi
  if ftctl_cluster_find_record_by_libvirt_uri "${FTCTL_PROFILE_PRIMARY_URI}" record 2>/dev/null; then
    ftctl_cluster_parse_record "${record}" host_id role mgmt_ip libvirt_uri blockcopy_ip xcolo_ctrl xcolo_data
    : "${host_id}${role}${libvirt_uri}${xcolo_ctrl}${xcolo_data}"
    result="${blockcopy_ip:-${mgmt_ip}}"
  fi
  if [[ -z "${result}" && "${FTCTL_PROFILE_PRIMARY_URI}" == qemu+ssh://* ]]; then
    local parsed_host="" parsed_user=""
    ftctl_blockcopy_parse_ssh_target_from_uri "${FTCTL_PROFILE_PRIMARY_URI}" parsed_host parsed_user || return 2
    : "${parsed_user}"
    result="${parsed_host}"
  fi
  out_ref="${result}"
}

ftctl_blockcopy_primary_nbd_pick_port() {
  local vm="${1-}"
  local target="${2-}"
  local out_var="${3}"
  local record="" host="" user="" active_count=0 preferred=0 candidate=0 i=0

  if ftctl_blockcopy_primary_uri_is_local_system; then
    ftctl_blockcopy_remote_nbd_candidate_port "${vm}" "${target}-reverse" preferred
    for ((i=0; i<FTCTL_REMOTE_NBD_PORT_COUNT; i++)); do
      candidate=$((FTCTL_REMOTE_NBD_PORT_BASE + ((preferred - FTCTL_REMOTE_NBD_PORT_BASE + i) % FTCTL_REMOTE_NBD_PORT_COUNT)))
      if ! ss -lntp | grep -q ":${candidate}[[:space:]]"; then
        printf -v "${out_var}" '%s' "${candidate}"
        return 0
      fi
    done
    echo "ERROR: no free primary reverse remote-nbd port available in range ${FTCTL_REMOTE_NBD_PORT_BASE}..$((FTCTL_REMOTE_NBD_PORT_BASE + FTCTL_REMOTE_NBD_PORT_COUNT - 1))" >&2
    return 4
  fi

  ftctl_blockcopy_primary_target_host_user host user || return 2
  ftctl_blockcopy_remote_nbd_active_count "${host}" "${user}" active_count || true
  if (( active_count >= FTCTL_REMOTE_NBD_MAX_CONCURRENT )); then
    echo "ERROR: primary reverse remote-nbd active count ${active_count} reached FTCTL_REMOTE_NBD_MAX_CONCURRENT=${FTCTL_REMOTE_NBD_MAX_CONCURRENT}" >&2
    return 3
  fi

  ftctl_blockcopy_remote_nbd_candidate_port "${vm}" "${target}-reverse" preferred
  for ((i=0; i<FTCTL_REMOTE_NBD_PORT_COUNT; i++)); do
    candidate=$((FTCTL_REMOTE_NBD_PORT_BASE + ((preferred - FTCTL_REMOTE_NBD_PORT_BASE + i) % FTCTL_REMOTE_NBD_PORT_COUNT)))
    if ! ftctl_blockcopy_remote_nbd_port_in_use "${host}" "${user}" "${candidate}"; then
      printf -v "${out_var}" '%s' "${candidate}"
      return 0
    fi
  done

  echo "ERROR: no free primary reverse remote-nbd port available in range ${FTCTL_REMOTE_NBD_PORT_BASE}..$((FTCTL_REMOTE_NBD_PORT_BASE + FTCTL_REMOTE_NBD_PORT_COUNT - 1))" >&2
  return 4
}

ftctl_blockcopy_primary_nbd_prepare_target() {
  local vm="${1-}"
  local target="${2-}"
  local source="${3-}"
  local format="${4-}"
  local primary_path="${5-}"
  local export_name="${6-}"
  local export_port="${7-}"
  local host="" user="" bind_addr="" out="" err="" rc=0 pid_file="" remote_cmd="" debug_cmd=""

  ftctl_blockcopy_primary_target_host_user host user || return 2
  ftctl_blockcopy_primary_export_addr bind_addr || return 2
  pid_file="/run/ablestack-vm-ftctl/nbd-reverse-${vm}-${target}.pid"
  remote_cmd=$(cat <<EOF
set -euo pipefail
mkdir -p /run/ablestack-vm-ftctl
if [[ -b "${primary_path}" && "${primary_path}" != /dev/rbd/* ]]; then
  primary_real="\$(readlink -f "${primary_path}" 2>/dev/null || true)"
  stale_map=""
  if [[ -n "\${primary_real}" ]]; then
    stale_map="\$(dmsetup info -C --noheadings -o name "\${primary_real}" 2>/dev/null | awk 'NR==1{print \$1}' || true)"
  fi
  vg_name="\$(lvs --noheadings -o vg_name "${primary_path}" 2>/dev/null | awk 'NR==1{gsub(/^[ \t]+|[ \t]+$/, "", \$0); print \$0}' || true)"
  lvchange -an "${primary_path}" >/dev/null 2>&1 || true
  if [[ -n "\${stale_map}" && -n "\${primary_real}" ]]; then
    stale_open="\$(dmsetup info -C --noheadings -o open "\${primary_real}" 2>/dev/null | awk 'NR==1{print \$1}' || true)"
    if [[ "\${stale_open}" == "0" ]]; then
      dmsetup remove "\${stale_map}" >/dev/null 2>&1 || true
      udevadm settle >/dev/null 2>&1 || true
    fi
  fi
  if [[ -n "\${vg_name}" ]]; then
    vgchange --refresh "\${vg_name}" >/dev/null 2>&1 || true
  fi
  vgscan --mknodes >/dev/null 2>&1 || true
  lvchange -ay "${primary_path}"
  udevadm settle >/dev/null 2>&1 || true
elif [[ -b "${primary_path}" && "${primary_path}" == /dev/rbd/* ]]; then
  if [[ ! -b "${primary_path}" ]]; then
    rbd map "${primary_path#/dev/rbd/}" >/dev/null
    udevadm settle >/dev/null 2>&1 || true
  fi
else
  mkdir -p "$(dirname "${primary_path}")"
  if [[ ! -f "${primary_path}" ]]; then
    echo "missing_reverse_target:${primary_path}" >&2
    exit 96
  fi
fi
if [[ -f "${pid_file}" ]]; then
  oldpid="\$(cat "${pid_file}" 2>/dev/null || true)"
  if [[ -n "\${oldpid}" ]] && kill -0 "\${oldpid}" >/dev/null 2>&1; then
    kill "\${oldpid}" >/dev/null 2>&1 || true
    sleep 1
  fi
  rm -f "${pid_file}"
fi
listener_pids="\$(ss -lntp | awk '/:${export_port}[[:space:]]/ { while (match(\$0, /pid=[0-9]+/)) { print substr(\$0, RSTART+4, RLENGTH-4); \$0=substr(\$0, RSTART+RLENGTH) } }' | sort -u)"
for listener_pid in \${listener_pids}; do
  [[ -n "\${listener_pid}" ]] || continue
  cmdline="\$(tr '\0' ' ' < /proc/\${listener_pid}/cmdline 2>/dev/null || true)"
  if [[ "\${cmdline}" == *qemu-nbd* ]]; then
    kill "\${listener_pid}" >/dev/null 2>&1 || true
    sleep 1
  fi
done
if ss -lntp | grep -q ":${export_port}[[:space:]]"; then
  echo "port_in_use:${export_port}" >&2
  exit 98
fi
nbd_thin_opts=()
if [[ "${FTCTL_THIN_PRESERVE:-1}" == "1" ]]; then
  qemu-nbd --help 2>&1 | grep -q -- '--discard' && nbd_thin_opts+=(--discard=unmap)
  qemu-nbd --help 2>&1 | grep -q -- '--detect-zeroes' && nbd_thin_opts+=(--detect-zeroes=unmap)
fi
qemu-nbd --fork --persistent --shared=8 "\${nbd_thin_opts[@]}" \
  --bind "${bind_addr}" \
  --port "${export_port}" \
  --export-name "${export_name}" \
  --format "${format}" \
  --pid-file "${pid_file}" \
  "${primary_path}"
EOF
)
  debug_cmd="$(tr '\n' ' ' <<< "${remote_cmd}" | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//')"

  out=""
  err=""
  rc=0
  if ftctl_blockcopy_primary_uri_is_local_system; then
    ftctl_cmd_run "${FTCTL_BLOCKCOPY_WAIT_TIMEOUT_SEC}" out err rc -- bash -lc "${remote_cmd}" || true
  else
    ftctl_blockcopy_remote_exec "${host}" "${user}" out err rc "${remote_cmd}" || true
  fi
  : "${out}${err}"
  [[ "${rc}" == "0" ]] || {
    echo "ERROR: reverse remote-nbd prepare context: host=${host} user=${user} bind_addr=${bind_addr} format=${format} primary_path=${primary_path} export=${export_name}" >&2
    echo "ERROR: reverse remote-nbd prepare command: ${debug_cmd}" >&2
    [[ -n "${err}" ]] && echo "ERROR: reverse remote-nbd prepare failed: ${err}" >&2
    return "${rc}"
  }
}

ftctl_blockcopy_remote_nbd_prepare_target() {
  local vm="${1-}"
  local target="${2-}"
  local source="${3-}"
  local format="${4-}"
  local secondary_path="${5-}"
  local export_name="${6-}"
  local export_port="${7-}"
  local host="" user="" size="" alloc_size="" out="" err="" rc=0 pid_file="" remote_cmd="" debug_cmd="" bind_addr="" target_format="" cloud_managed="0"

  ftctl_blockcopy_remote_target_host_user host user || return 2
  ftctl_blockcopy_remote_nbd_host_only "${FTCTL_PROFILE_REMOTE_NBD_EXPORT_ADDR}" bind_addr || return 2
  ftctl_blockcopy_is_cloud_managed && cloud_managed="1"
  ftctl_blockcopy_validate_cloud_managed_dest "${target}" "${secondary_path}" || return $?
  ftctl_blockcopy_remote_nbd_target_format "${secondary_path}" "${format}" target_format
  ftctl_blockcopy_source_virtual_size_bytes "${vm}" "${target}" "${source}" size || {
    echo "ERROR: could not determine source virtual size for ${source}" >&2
    return 2
  }
  ftctl_blockcopy_source_allocated_size_bytes "${source}" alloc_size || alloc_size="${size}"

  pid_file="/run/ablestack-vm-ftctl/nbd-${vm}-${target}.pid"
  if [[ -b "${secondary_path}" ]]; then
    lvchange -an "${secondary_path}" >/dev/null 2>&1 || true
  fi
remote_cmd=$(cat <<EOF
set -euo pipefail
mkdir -p /run/ablestack-vm-ftctl
cloud_managed="${cloud_managed}"
if [[ "${secondary_path}" == /dev/rbd/* ]]; then
  krbd_spec="${secondary_path#/dev/rbd/}"
  if [[ -b "${secondary_path}" ]]; then
    krbd_real="\$(readlink -f "${secondary_path}" 2>/dev/null || true)"
    krbd_open="0"
    if [[ -n "\${krbd_real}" ]]; then
      krbd_open="\$(dmsetup info -C --noheadings -o open "\${krbd_real}" 2>/dev/null | awk 'NR==1{print \$1}' || true)"
    fi
    if [[ "\${krbd_open}" == "0" ]]; then
      rbd unmap "${secondary_path}" >/dev/null 2>&1 || true
      udevadm settle >/dev/null 2>&1 || true
    fi
  fi
  if [[ ! -b "${secondary_path}" ]]; then
    rbd map "\${krbd_spec}" >/dev/null
    udevadm settle >/dev/null 2>&1 || true
  fi
fi
target_format="${target_format}"
if [[ -b "${secondary_path}" && "${secondary_path}" != /dev/rbd/* ]]; then
  secondary_real="\$(readlink -f "${secondary_path}" 2>/dev/null || true)"
  stale_map=""
  if [[ -n "\${secondary_real}" ]]; then
    stale_map="\$(dmsetup info -C --noheadings -o name "\${secondary_real}" 2>/dev/null | awk 'NR==1{print \$1}' || true)"
  fi
  vg_name="\$(lvs --noheadings -o vg_name "${secondary_path}" 2>/dev/null | awk 'NR==1{gsub(/^[ \t]+|[ \t]+$/, \"\", \$0); print \$0}' || true)"
  echo "=== PRE-LVCHANGE ==="
  lvs -a -o lv_name,lv_attr,lv_active "${secondary_path}" 2>/dev/null || true
  if [[ -n "\${secondary_real}" ]]; then
    dmsetup info -c "\${secondary_real}" 2>/dev/null || true
  fi
  if [[ -b "${source}" ]]; then
    lvchange -an "${source}" >/dev/null 2>&1 || true
  fi
  lvchange -an "${secondary_path}" >/dev/null 2>&1 || true
  if [[ -n "\${stale_map}" && -n "\${secondary_real}" ]]; then
    stale_open="\$(dmsetup info -C --noheadings -o open "\${secondary_real}" 2>/dev/null | awk 'NR==1{print \$1}' || true)"
    if [[ "\${stale_open}" == "0" ]]; then
      dmsetup remove "\${stale_map}" >/dev/null 2>&1 || true
      udevadm settle >/dev/null 2>&1 || true
    fi
  fi
  if [[ -n "\${vg_name}" ]]; then
    vgchange --refresh "\${vg_name}" >/dev/null 2>&1 || true
  fi
  vgscan --mknodes >/dev/null 2>&1 || true
  lvchange -ay "${secondary_path}"
  udevadm settle >/dev/null 2>&1 || true
  echo "=== POST-LVCHANGE ==="
  lvs -a -o lv_name,lv_attr,lv_active "${secondary_path}" 2>/dev/null || true
  if [[ -n "\${secondary_real}" ]]; then
    dmsetup info -c "\${secondary_real}" 2>/dev/null || true
  fi
  if [[ "\${target_format}" != "raw" ]]; then
    current_format="\$(qemu-img info --force-share --output=json "${secondary_path}" 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin).get(\"format\",\"\"))' 2>/dev/null || true)"
    if [[ "\${current_format}" != "\${target_format}" ]]; then
      qemu-img create -f "\${target_format}" "${secondary_path}" "${size}"
    fi
  fi
elif [[ -b "${secondary_path}" && "${secondary_path}" == /dev/rbd/* ]]; then
  if [[ "\${target_format}" != "raw" ]]; then
    current_format="\$(qemu-img info --force-share --output=json "${secondary_path}" 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin).get(\"format\",\"\"))' 2>/dev/null || true)"
    if [[ "\${current_format}" != "\${target_format}" ]]; then
      qemu-img create -f "\${target_format}" "${secondary_path}" "${size}"
    fi
  fi
else
  if [[ "\${cloud_managed}" == "1" && ! -f "${secondary_path}" ]]; then
    echo "cloud_managed_target_missing:${secondary_path}" >&2
    exit 95
  fi
  mkdir -p "$(dirname "${secondary_path}")"
  avail_bytes="\$(df -B1 --output=avail "$(dirname "${secondary_path}")" | tail -n 1 | tr -dc '0-9' || true)"
  if [[ -n "\${avail_bytes}" && "\${avail_bytes}" =~ ^[0-9]+$ ]] && (( avail_bytes < ${alloc_size} )); then
    echo "insufficient_space:${secondary_path}:\${avail_bytes}:${alloc_size}" >&2
    exit 97
  fi
  if [[ ! -f "${secondary_path}" ]]; then
    qemu-img create -f "\${target_format}" "${secondary_path}" "${size}"
  else
    current_format="\$(qemu-img info --force-share --output=json "${secondary_path}" 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin).get(\"format\",\"\"))' 2>/dev/null || true)"
    if [[ -n "\${current_format}" && "\${current_format}" != "\${target_format}" ]]; then
      echo "secondary_format_mismatch:${secondary_path}:\${current_format}:\${target_format}" >&2
      exit 96
    fi
  fi
fi
if [[ -f "${pid_file}" ]]; then
  oldpid="\$(cat "${pid_file}" 2>/dev/null || true)"
  if [[ -n "\${oldpid}" ]] && kill -0 "\${oldpid}" >/dev/null 2>&1; then
    kill "\${oldpid}" >/dev/null 2>&1 || true
    sleep 1
  fi
  rm -f "${pid_file}"
fi
listener_pids="\$(ss -lntp | awk '/:${export_port}[[:space:]]/ { while (match(\$0, /pid=[0-9]+/)) { print substr(\$0, RSTART+4, RLENGTH-4); \$0=substr(\$0, RSTART+RLENGTH) } }' | sort -u)"
for listener_pid in \${listener_pids}; do
  [[ -n "\${listener_pid}" ]] || continue
  cmdline="\$(tr '\0' ' ' < /proc/\${listener_pid}/cmdline 2>/dev/null || true)"
  if [[ "\${cmdline}" == *qemu-nbd* ]]; then
    kill "\${listener_pid}" >/dev/null 2>&1 || true
    sleep 1
  fi
done
if ss -lntp | grep -q ":${export_port}[[:space:]]"; then
  echo "port_in_use:${export_port}" >&2
  exit 98
fi
nbd_thin_opts=()
if [[ "${FTCTL_THIN_PRESERVE:-1}" == "1" ]]; then
  qemu-nbd --help 2>&1 | grep -q -- '--discard' && nbd_thin_opts+=(--discard=unmap)
  qemu-nbd --help 2>&1 | grep -q -- '--detect-zeroes' && nbd_thin_opts+=(--detect-zeroes=unmap)
fi
qemu-nbd --fork --persistent --shared=8 "\${nbd_thin_opts[@]}" \
  --bind "${bind_addr}" \
  --port "${export_port}" \
  --export-name "${export_name}" \
  --format "\${target_format}" \
  --pid-file "${pid_file}" \
  "${secondary_path}"
EOF
)
  debug_cmd="$(tr '\n' ' ' <<< "${remote_cmd}" | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//')"

  out=""
  err=""
  rc=0
  ftctl_blockcopy_remote_exec "${host}" "${user}" out err rc "${remote_cmd}" || true
  ftctl_blockcopy_write_debug_file "${vm}" "${target}" "secondary-prepare-stdout.txt" "${out}"
  ftctl_blockcopy_write_debug_file "${vm}" "${target}" "secondary-prepare-stderr.txt" "${err}"
  ftctl_blockcopy_write_debug_file "${vm}" "${target}" "secondary-prepare-rc.txt" "${rc}"
  : "${out}${err}"
  [[ "${rc}" == "0" ]] || {
    echo "ERROR: remote-nbd prepare context: host=${host} user=${user} size=${size} source_format=${format} target_format=${target_format} secondary_path=${secondary_path} export=${export_name}" >&2
    echo "ERROR: remote-nbd prepare command: ${debug_cmd}" >&2
    [[ -n "${err}" ]] && echo "ERROR: remote-nbd prepare failed: ${err}" >&2
    return "${rc}"
  }
}

ftctl_blockcopy_start_remote_nbd_job() {
  local uri="${1-}"
  local vm="${2-}"
  local target="${3-}"
  local format="${4-}"
  local persistence="${5-unknown}"
  local xml_path="${6-}"
  local out_var="${7-}"
  local err_var="${8-}"
  local rc_var="${9-}"
  local out err rc
  local args=()

  args=(-c "${uri}" blockcopy "${vm}" "${target}" --xml "${xml_path}")
  if [[ "${persistence}" == "yes" ]]; then
    args+=(--transient-job)
  fi
  if [[ "${FTCTL_BLOCKCOPY_SYNC_WRITES}" == "1" ]]; then
    args+=(--synchronous-writes)
  fi

  out=""
  err=""
  rc=0
  ftctl_virsh "${FTCTL_BLOCKCOPY_WAIT_TIMEOUT_SEC}" out err rc -- "${args[@]}" || true
  : "${out}${err}"
  if [[ -n "${out_var}" ]]; then
    printf -v "${out_var}" '%s' "${out}"
  fi
  if [[ -n "${err_var}" ]]; then
    printf -v "${err_var}" '%s' "${err}"
  fi
  if [[ -n "${rc_var}" ]]; then
    printf -v "${rc_var}" '%s' "${rc}"
  fi
  return "${rc}"
}

ftctl_blockcopy_start_shared_xml_job() {
  local uri="${1-}"
  local vm="${2-}"
  local target="${3-}"
  local persistence="${4-unknown}"
  local xml_path="${5-}"
  local out_var="${6-}"
  local err_var="${7-}"
  local rc_var="${8-}"
  local force_reuse="${9-0}"
  local out err rc
  local args=()

  args=(-c "${uri}" blockcopy "${vm}" "${target}" --xml "${xml_path}")
  if [[ "${persistence}" == "yes" ]]; then
    args+=(--transient-job)
  fi
  if [[ "${FTCTL_BLOCKCOPY_SYNC_WRITES}" == "1" ]]; then
    args+=(--synchronous-writes)
  fi
  if [[ "${force_reuse}" == "1" ]]; then
    args+=(--reuse-external)
  fi

  out=""
  err=""
  rc=0
  ftctl_virsh "${FTCTL_BLOCKCOPY_WAIT_TIMEOUT_SEC}" out err rc -- "${args[@]}" || true
  : "${out}${err}"
  if [[ -n "${out_var}" ]]; then
    printf -v "${out_var}" '%s' "${out}"
  fi
  if [[ -n "${err_var}" ]]; then
    printf -v "${err_var}" '%s' "${err}"
  fi
  if [[ -n "${rc_var}" ]]; then
    printf -v "${rc_var}" '%s' "${rc}"
  fi
  return "${rc}"
}

ftctl_blockcopy_write_remote_nbd_repro() {
  local vm="${1-}"
  local target="${2-}"
  local xml_path="${3-}"
  local remote_host="${4-}"
  local remote_user="${5-}"
  local remote_cmd="${6-}"
  local persistence="${7-}"
  local cmd script

  cmd="env LC_ALL=C LANG=C virsh -c ${FTCTL_PROFILE_PRIMARY_URI@Q} blockcopy ${vm@Q} ${target@Q} --xml ${xml_path@Q}"
  if [[ "${persistence}" == "yes" ]]; then
    cmd+=" --transient-job"
  fi
  if [[ "${FTCTL_BLOCKCOPY_SYNC_WRITES}" == "1" ]]; then
    cmd+=" --synchronous-writes"
  fi

  script=$(cat <<EOF
#!/usr/bin/env bash
set -euo pipefail

echo "[REPRO] remote prepare on secondary host"
ssh -o BatchMode=yes -o StrictHostKeyChecking=no "${remote_user}@${remote_host}" bash -lc $(printf '%q' "${remote_cmd}")

echo "[REPRO] blockcopy command on primary host"
${cmd}
EOF
)
  ftctl_blockcopy_write_debug_file "${vm}" "${target}" "remote-nbd-repro.sh" "${script}"
  ftctl_blockcopy_write_debug_file "${vm}" "${target}" "primary-blockcopy-command.txt" "${cmd}"
  ftctl_blockcopy_write_debug_file "${vm}" "${target}" "secondary-prepare-command.txt" "${remote_cmd}"
  if [[ -f "${xml_path}" ]]; then
    ftctl_blockcopy_write_debug_file "${vm}" "${target}" "remote-nbd-dest.xml" "$(cat "${xml_path}")"
  fi
}

ftctl_blockcopy_capture_primary_debug() {
  local vm="${1-}"
  local target="${2-}"
  local out err rc

  out=""
  err=""
  rc=0
  ftctl_virsh "${FTCTL_BLOCKCOPY_WAIT_TIMEOUT_SEC}" out err rc -- -c "${FTCTL_PROFILE_PRIMARY_URI}" dumpxml "${vm}" || true
  ftctl_blockcopy_write_debug_file "${vm}" "${target}" "primary-dumpxml.stdout.xml" "${out}"
  ftctl_blockcopy_write_debug_file "${vm}" "${target}" "primary-dumpxml.stderr.txt" "${err}"
  ftctl_blockcopy_write_debug_file "${vm}" "${target}" "primary-dumpxml.rc.txt" "${rc}"

  out=""
  err=""
  rc=0
  ftctl_virsh "${FTCTL_BLOCKCOPY_WAIT_TIMEOUT_SEC}" out err rc -- -c "${FTCTL_PROFILE_PRIMARY_URI}" blockjob "${vm}" "${target}" --info || true
  ftctl_blockcopy_write_debug_file "${vm}" "${target}" "primary-blockjob.stdout.txt" "${out}"
  ftctl_blockcopy_write_debug_file "${vm}" "${target}" "primary-blockjob.stderr.txt" "${err}"
  ftctl_blockcopy_write_debug_file "${vm}" "${target}" "primary-blockjob.rc.txt" "${rc}"

  out=""
  err=""
  rc=0
  ftctl_virsh "${FTCTL_BLOCKCOPY_WAIT_TIMEOUT_SEC}" out err rc -- -c "${FTCTL_PROFILE_PRIMARY_URI}" qemu-monitor-command "${vm}" --pretty '{"execute":"query-block-jobs"}' || true
  ftctl_blockcopy_write_debug_file "${vm}" "${target}" "primary-qmp-query-block-jobs.stdout.json" "${out}"
  ftctl_blockcopy_write_debug_file "${vm}" "${target}" "primary-qmp-query-block-jobs.stderr.txt" "${err}"
  ftctl_blockcopy_write_debug_file "${vm}" "${target}" "primary-qmp-query-block-jobs.rc.txt" "${rc}"

  out=""
  err=""
  rc=0
  ftctl_virsh "${FTCTL_BLOCKCOPY_WAIT_TIMEOUT_SEC}" out err rc -- -c "${FTCTL_PROFILE_PRIMARY_URI}" qemu-monitor-command "${vm}" --pretty '{"execute":"query-named-block-nodes"}' || true
  ftctl_blockcopy_write_debug_file "${vm}" "${target}" "primary-qmp-query-named-block-nodes.stdout.json" "${out}"
  ftctl_blockcopy_write_debug_file "${vm}" "${target}" "primary-qmp-query-named-block-nodes.stderr.txt" "${err}"
  ftctl_blockcopy_write_debug_file "${vm}" "${target}" "primary-qmp-query-named-block-nodes.rc.txt" "${rc}"
}

ftctl_blockcopy_resolve_reverse_dest() {
  local target="${1-}"
  local source="${2-}"
  local explicit

  if [[ "${FTCTL_PROFILE_FAILBACK_DISK_MAP}" == "source" ]]; then
    printf '%s\n' "${source}"
    return 0
  fi

  explicit="$(ftctl_profile_lookup_map_value "${FTCTL_PROFILE_FAILBACK_DISK_MAP}" "${target}" 2>/dev/null || true)"
  if [[ -n "${explicit}" ]]; then
    printf '%s\n' "${explicit}"
    return 0
  fi

  echo "ERROR: no reverse destination mapping for disk target ${target}" >&2
  return 2
}

ftctl_blockcopy_validate_backend_mode() {
  local vm="${1-}"
  local disks=()
  local line target source format dest secondary_target

  case "${FTCTL_PROFILE_BACKEND_MODE}" in
    shared-blockcopy)
      if [[ "${FTCTL_PROFILE_DISK_MAP}" == "auto" ]]; then
        echo "ERROR: shared-blockcopy requires an explicit FTCTL_PROFILE_DISK_MAP with shared-visible target paths" >&2
        return 2
      fi
      ftctl_inventory_collect_vm_disks "${vm}" disks || return $?
      for line in "${disks[@]}"; do
        target="${line%%|*}"
        source="${line#*|}"
        source="${source%%|*}"
        format="${line##*|}"
        dest="$(ftctl_blockcopy_resolve_dest "${vm}" "${target}" "${source}" "${format}")" || return $?
        if [[ "${dest}" == "${FTCTL_BLOCKCOPY_TARGET_BASE_DIR}/"* ]]; then
          echo "ERROR: shared-blockcopy destination must not use the default local blockcopy target base dir: ${dest}" >&2
          return 2
        fi
      done
      ;;
    remote-nbd)
      if ftctl_blockcopy_is_cloud_managed && [[ "${FTCTL_PROFILE_DISK_MAP}" == "auto" ]]; then
        echo "ERROR: cloud-managed requires an explicit FTCTL_PROFILE_DISK_MAP" >&2
        return 2
      fi
      ftctl_inventory_collect_vm_disks "${vm}" disks || return $?
      for line in "${disks[@]}"; do
        target="${line%%|*}"
        source="${line#*|}"
        source="${source%%|*}"
        format="${line##*|}"
        secondary_target="$(ftctl_blockcopy_remote_nbd_secondary_path "${vm}" "${target}" "${source}" "${format}")" || return $?
        [[ -n "${secondary_target}" ]] || {
          echo "ERROR: remote-nbd requires a resolvable secondary target path" >&2
          return 2
        }
      done
      ;;
    *)
      echo "ERROR: unsupported backend mode: ${FTCTL_PROFILE_BACKEND_MODE}" >&2
      return 2
      ;;
  esac
}

ftctl_blockcopy_start_job() {
  local uri="${1-}"
  local vm="${2-}"
  local target="${3-}"
  local dest="${4-}"
  local format="${5-}"
  local force_reuse="${6-0}"
  local persistence="${7-unknown}"
  local out_var="${8-}"
  local err_var="${9-}"
  local rc_var="${10-}"
  local out err rc
  local args=()

  args=(-c "${uri}" blockcopy "${vm}" "${target}" "${dest}")
  if [[ -n "${format}" ]]; then
    args+=(--format "${format}")
  fi
  if [[ "${persistence}" == "yes" ]]; then
    args+=(--transient-job)
  fi
  if [[ "${FTCTL_BLOCKCOPY_SYNC_WRITES}" == "1" ]]; then
    args+=(--synchronous-writes)
  fi
  if [[ "${force_reuse}" == "1" ]]; then
    args+=(--reuse-external)
  fi
  if [[ "${FTCTL_BLOCKCOPY_BANDWIDTH_MIB}" =~ ^[1-9][0-9]*$ ]]; then
    args+=("${FTCTL_BLOCKCOPY_BANDWIDTH_MIB}")
  fi

  out=""
  err=""
  rc=0
  ftctl_virsh "${FTCTL_BLOCKCOPY_WAIT_TIMEOUT_SEC}" out err rc -- "${args[@]}" || true
  : "${out}${err}"
  if [[ -n "${out_var}" ]]; then
    printf -v "${out_var}" '%s' "${out}"
  fi
  if [[ -n "${err_var}" ]]; then
    printf -v "${err_var}" '%s' "${err}"
  fi
  if [[ -n "${rc_var}" ]]; then
    printf -v "${rc_var}" '%s' "${rc}"
  fi
  return "${rc}"
}

ftctl_blockcopy_abort_job() {
  local uri="${1-}"
  local vm="${2-}"
  local target="${3-}"
  local out err rc

  out=""
  err=""
  rc=0
  ftctl_virsh "${FTCTL_BLOCKCOPY_WAIT_TIMEOUT_SEC}" out err rc -- -c "${uri}" blockjob "${vm}" "${target}" --abort || true
  : "${out}${err}"
  return 0
}

ftctl_blockcopy_state_write_reverse() {
  local vm="${1-}"
  shift
  local path tmp line
  path="$(ftctl_blockcopy_reverse_state_path "${vm}")"
  tmp="$(mktemp -t ftctl.blockcopy.reverse.XXXXXX)"
  for line in "$@"; do
    printf "%s\n" "${line}" >> "${tmp}"
  done
  mv -f "${tmp}" "${path}"
  chmod 0644 "${path}" 2>/dev/null || true
}

ftctl_blockcopy_reverse_krbd_paths() {
  local vm="${1-}"
  local out_array_name="${2}"
  local -n _out_array="${out_array_name}"
  local path line target source dest format existing item

  _out_array=()
  path="$(ftctl_blockcopy_reverse_state_path "${vm}")"
  [[ -f "${path}" ]] || return 0

  while IFS= read -r line; do
    [[ -n "${line}" ]] || continue
    target="${line%%|*}"
    line="${line#*|}"
    source="${line%%|*}"
    line="${line#*|}"
    dest="${line%%|*}"
    format="${line##*|}"
    : "${target}${source}${format}"
    ftctl_blockcopy_is_krbd_path "${dest}" || continue
    existing="0"
    for item in "${_out_array[@]}"; do
      if [[ "${item}" == "${dest}" ]]; then
        existing="1"
        break
      fi
    done
    [[ "${existing}" == "1" ]] || _out_array+=("${dest}")
  done < "${path}"
}

ftctl_blockcopy_map_reverse_krbd_destinations() {
  local vm="${1-}"
  local paths=()
  local path host user

  ftctl_blockcopy_reverse_krbd_paths "${vm}" paths
  ((${#paths[@]} > 0)) || return 0

  if ftctl_blockcopy_secondary_uri_is_local_system; then
    for path in "${paths[@]}"; do
      if ! ftctl_blockcopy_krbd_map_local "${path}"; then
        ftctl_log_event "failback" "reverse_sync.rbd-map" "fail" "${vm}" "" \
          "path=${path} secondary_uri=${FTCTL_PROFILE_SECONDARY_URI}"
        return 1
      fi
    done
  else
    host=""
    user=""
    ftctl_blockcopy_remote_target_host_user host user || return $?
    for path in "${paths[@]}"; do
      if ! ftctl_blockcopy_map_remote_krbd_path "${host}" "${user}" "${path}"; then
        ftctl_log_event "failback" "reverse_sync.rbd-map" "fail" "${vm}" "" \
          "path=${path} secondary_uri=${FTCTL_PROFILE_SECONDARY_URI}"
        return 1
      fi
    done
  fi

  ftctl_log_event "failback" "reverse_sync.rbd-map" "ok" "${vm}" "" \
    "count=${#paths[@]} secondary_uri=${FTCTL_PROFILE_SECONDARY_URI}"
}

ftctl_blockcopy_job_query() {
  local vm="${1-}"
  local target="${2-}"
  local state_var="${3}"
  local ready_var="${4}"
  local out err rc payload state_value ready_value

  out=""
  err=""
  rc=0
  ftctl_virsh "${FTCTL_BLOCKCOPY_WAIT_TIMEOUT_SEC}" out err rc -- -c "${FTCTL_PROFILE_PRIMARY_URI}" blockjob "${vm}" "${target}" --info || true
  payload="${out}"$'\n'"${err}"
  if [[ "${rc}" != "0" ]] || grep -qi "no current block job" <<< "${payload}"; then
    printf -v "${state_var}" '%s' "unknown"
    printf -v "${ready_var}" '%s' "unknown"
    [[ "${rc}" == "0" ]] && rc=4
    return "${rc}"
  fi

  state_value="$(awk -F: 'tolower($1) ~ /state/ {gsub(/^[ \t]+/, "", $2); print tolower($2); exit}' <<< "${payload}")"
  ready_value="$(awk -F: 'tolower($1) ~ /ready/ {gsub(/^[ \t]+/, "", $2); print tolower($2); exit}' <<< "${payload}")"
  if [[ -z "${state_value}" && "${payload}" =~ Block[[:space:]]+Copy:[[:space:]]+\[([0-9.]+)[[:space:]]*%\] ]]; then
    state_value="copy"
    ready_value="no"
    if [[ "${BASH_REMATCH[1]}" == "100.00" || "${BASH_REMATCH[1]}" == "100" ]]; then
      ready_value="yes"
    fi
  fi
  if [[ -z "${state_value}" && -z "${ready_value}" ]]; then
    printf -v "${state_var}" '%s' "unknown"
    printf -v "${ready_var}" '%s' "unknown"
    return 5
  fi
  [[ -n "${state_value}" ]] || state_value="unknown"
  [[ -n "${ready_value}" ]] || ready_value="unknown"
  printf -v "${state_var}" '%s' "${state_value}"
  printf -v "${ready_var}" '%s' "${ready_value}"
}

ftctl_blockcopy_active_domain_on_secondary() {
  local vm="${1-}"
  local secondary_vm_name
  secondary_vm_name="$(ftctl_state_get "${vm}" "secondary_vm_name" 2>/dev/null || ftctl_profile_secondary_vm_name_resolved "${vm}")"
  printf '%s\n' "${secondary_vm_name}"
}

ftctl_blockcopy_secondary_domain_state() {
  local vm="${1-}"
  local state_var="${2}"
  local active_vm out err rc state

  active_vm="$(ftctl_blockcopy_active_domain_on_secondary "${vm}")"
  out=""
  err=""
  rc=0
  ftctl_virsh "${FTCTL_BLOCKCOPY_WAIT_TIMEOUT_SEC}" out err rc -- -c "${FTCTL_PROFILE_SECONDARY_URI}" domstate "${active_vm}" || true
  if [[ "${rc}" != "0" ]]; then
    printf -v "${state_var}" '%s' "not-found"
    return "${rc}"
  fi
  state="$(awk 'NF {print tolower($0); exit}' <<< "${out}")"
  [[ -n "${state}" ]] || state="unknown"
  printf -v "${state_var}" '%s' "${state}"
}

ftctl_blockcopy_reverse_job_query() {
  local vm="${1-}"
  local target="${2-}"
  local state_var="${3}"
  local ready_var="${4}"
  local active_vm out err rc payload state_value ready_value

  active_vm="$(ftctl_blockcopy_active_domain_on_secondary "${vm}")"
  out=""
  err=""
  rc=0
  ftctl_virsh "${FTCTL_BLOCKCOPY_WAIT_TIMEOUT_SEC}" out err rc -- -c "${FTCTL_PROFILE_SECONDARY_URI}" blockjob "${active_vm}" "${target}" --info || true
  payload="${out}"$'\n'"${err}"
  if [[ "${rc}" != "0" ]] || grep -qi "no current block job" <<< "${payload}"; then
    printf -v "${state_var}" '%s' "unknown"
    printf -v "${ready_var}" '%s' "unknown"
    [[ "${rc}" == "0" ]] && rc=4
    return "${rc}"
  fi

  state_value="$(awk -F: 'tolower($1) ~ /state/ {gsub(/^[ \t]+/, "", $2); print tolower($2); exit}' <<< "${payload}")"
  ready_value="$(awk -F: 'tolower($1) ~ /ready/ {gsub(/^[ \t]+/, "", $2); print tolower($2); exit}' <<< "${payload}")"
  if [[ -z "${state_value}" && "${payload}" =~ Block[[:space:]]+Copy:[[:space:]]+\[([0-9.]+)[[:space:]]*%\] ]]; then
    state_value="copy"
    ready_value="no"
    if [[ "${BASH_REMATCH[1]}" == "100.00" || "${BASH_REMATCH[1]}" == "100" ]]; then
      ready_value="yes"
    fi
  fi
  [[ -n "${state_value}" ]] || state_value="unknown"
  [[ -n "${ready_value}" ]] || ready_value="unknown"
  printf -v "${state_var}" '%s' "${state_value}"
  printf -v "${ready_var}" '%s' "${ready_value}"
}

ftctl_blockcopy_runtime_mirror_query() {
  local vm="${1-}"
  local target="${2-}"
  local type_var="${3}"
  local ready_var="${4}"
  local out err rc payload

  out=""
  err=""
  rc=0
  ftctl_virsh "${FTCTL_BLOCKCOPY_WAIT_TIMEOUT_SEC}" out err rc -- -c "${FTCTL_PROFILE_PRIMARY_URI}" dumpxml "${vm}" || true
  if [[ "${rc}" != "0" ]]; then
    printf -v "${type_var}" '%s' "unknown"
    printf -v "${ready_var}" '%s' "unknown"
    return "${rc}"
  fi

  payload="$(python3 -c 'import sys, xml.etree.ElementTree as ET; target=sys.argv[1]; xml_text=sys.argv[2]; root=ET.fromstring(xml_text);
for disk in root.findall("./devices/disk"):
    tgt = disk.find("target")
    if tgt is None or tgt.get("dev") != target:
        continue
    mirror = disk.find("mirror")
    if mirror is None:
        print("none|unknown")
        break
    print(mirror.get("type", "unknown") + "|" + mirror.get("ready", "no"))
    break
else:
    print("none|unknown")' "${target}" "${out}")" || payload="none|unknown"

  printf -v "${type_var}" '%s' "${payload%%|*}"
  printf -v "${ready_var}" '%s' "${payload##*|}"
  [[ "${payload%%|*}" != "none" ]]
}

ftctl_blockcopy_wait_for_job_visibility() {
  local vm="${1-}"
  local target="${2-}"
  local state_var="${3}"
  local ready_var="${4}"
  local tries="${5-5}"
  local state ready rc=0

  state="unknown"
  ready="unknown"
  while ((tries > 0)); do
    if ftctl_blockcopy_job_query "${vm}" "${target}" state ready; then
      printf -v "${state_var}" '%s' "${state}"
      printf -v "${ready_var}" '%s' "${ready}"
      return 0
    fi
    if [[ "${FTCTL_PROFILE_BACKEND_MODE}" == "remote-nbd" ]]; then
      if ftctl_blockcopy_runtime_mirror_query "${vm}" "${target}" state ready; then
        if [[ "${state}" == "network" ]]; then
          state="copy"
        fi
        printf -v "${state_var}" '%s' "${state}"
        printf -v "${ready_var}" '%s' "${ready}"
        return 0
      fi
    fi
    rc=$?
    sleep 1
    tries=$((tries - 1))
  done

  printf -v "${state_var}" '%s' "${state}"
  printf -v "${ready_var}" '%s' "${ready}"
  return "${rc}"
}

ftctl_blockcopy_refresh_vm_jobs() {
  local vm="${1-}"
  local disks=()
  local line target source format dest job_state ready secondary_dest runtime_mirror_type existing_record existing_dest
  local records=()
  local all_ready="1"
  local rc_any=0
  local missing_targets=""
  local verify_failed_targets="" verify_record verify_target verify_source verify_dest verify_format verify_job_state verify_ready verify_secondary_dest

  ftctl_inventory_collect_vm_disks "${vm}" disks || return $?

  for line in "${disks[@]}"; do
    target="${line%%|*}"
    source="${line#*|}"
    source="${source%%|*}"
    format="${line##*|}"
    secondary_dest=""
    if [[ "${FTCTL_PROFILE_BACKEND_MODE}" == "remote-nbd" ]]; then
      existing_record=""
      existing_dest=""
      if ftctl_blockcopy_state_record_for_target "${vm}" "${target}" existing_record; then
        existing_dest="$(cut -d'|' -f3 <<< "${existing_record}")"
        secondary_dest="$(cut -d'|' -f7 <<< "${existing_record}")"
      fi
      if [[ -n "${existing_dest}" && "${existing_dest}" == nbd://* ]]; then
        dest="${existing_dest}"
      else
        dest="$(ftctl_blockcopy_remote_nbd_uri "${FTCTL_PROFILE_REMOTE_NBD_EXPORT_ADDR}" "${FTCTL_PROFILE_REMOTE_NBD_EXPORT_PORT}" "${FTCTL_PROFILE_REMOTE_NBD_EXPORT_NAME}-${target}")"
      fi
      if [[ -z "${secondary_dest}" ]]; then
        secondary_dest="$(ftctl_blockcopy_remote_nbd_secondary_path "${vm}" "${target}" "${source}" "${format}")" || {
          rc_any=1
          secondary_dest=""
        }
      fi
    else
      dest="$(ftctl_blockcopy_resolve_dest "${vm}" "${target}" "${source}" "${format}")"
    fi
    job_state="unknown"
    ready="unknown"
    if ! ftctl_blockcopy_job_query "${vm}" "${target}" job_state ready; then
      if [[ "${FTCTL_PROFILE_BACKEND_MODE}" == "remote-nbd" || "${FTCTL_PROFILE_BACKEND_MODE}" == "shared-blockcopy" ]]; then
        runtime_mirror_type="unknown"
        if ftctl_blockcopy_runtime_mirror_query "${vm}" "${target}" runtime_mirror_type ready; then
          if [[ "${runtime_mirror_type}" == "network" || "${runtime_mirror_type}" == "file" ]]; then
            job_state="copy"
          else
            job_state="${runtime_mirror_type}"
          fi
        elif [[ "${FTCTL_PROFILE_BACKEND_MODE}" == "remote-nbd" && -n "${dest}" && "${dest}" == nbd://* ]]; then
          if ftctl_blockcopy_remote_nbd_progress_looks_alive "${dest}" "${secondary_dest}"; then
            job_state="copy"
            ready="no"
          else
            rc_any=1
            job_state="missing"
            ready="no"
            missing_targets="${missing_targets}${missing_targets:+,}${target}"
          fi
        else
          rc_any=1
          job_state="missing"
          ready="no"
          missing_targets="${missing_targets}${missing_targets:+,}${target}"
        fi
      else
        rc_any=1
        job_state="missing"
        ready="no"
        missing_targets="${missing_targets}${missing_targets:+,}${target}"
      fi
    fi
    [[ "${ready}" == "yes" ]] || all_ready="0"
    records+=("${target}|${source}|${dest}|${format}|${job_state}|${ready}|${secondary_dest}")
  done

  ftctl_blockcopy_state_write "${vm}" "${records[@]}"
  ftctl_blockcopy_progress_refresh_from_qmp "${vm}" "${vm}" "${FTCTL_PROFILE_PRIMARY_URI}" "forward" "mirror" "blockcopy.progress" >/dev/null 2>&1 || true

  if [[ "${all_ready}" == "1" && "${rc_any}" == "0" ]]; then
    ftctl_state_set "${vm}" \
      "protection_state=syncing" \
      "transport_state=verifying" \
      "last_sync_ts=$(ftctl_now_iso8601)"
    for verify_record in "${records[@]}"; do
      verify_target=""; verify_source=""; verify_dest=""; verify_format=""; verify_job_state=""; verify_ready=""; verify_secondary_dest=""
      IFS='|' read -r verify_target verify_source verify_dest verify_format verify_job_state verify_ready verify_secondary_dest <<< "${verify_record}"
      : "${verify_format}${verify_job_state}${verify_ready}${verify_secondary_dest}"
      if ! ftctl_blockcopy_verify_target_materialized "${vm}" "${verify_target}" "${verify_source}" "${verify_dest}"; then
        verify_failed_targets="${verify_failed_targets}${verify_failed_targets:+,}${verify_target}"
      fi
    done
    if [[ -n "${verify_failed_targets}" ]]; then
      ftctl_state_set "${vm}" \
        "protection_state=error" \
        "transport_state=failed" \
        "last_sync_ts=$(ftctl_now_iso8601)" \
        "last_error=blockcopy_target_not_materialized:${verify_failed_targets}"
      ftctl_log_event "mirror" "blockcopy.verify" "fail" "${vm}" "" \
        "targets=${verify_failed_targets}"
      return 1
    fi
    ftctl_state_set "${vm}" \
      "protection_state=protected" \
      "transport_state=mirroring" \
      "last_sync_ts=$(ftctl_now_iso8601)" \
      "last_error="
  elif [[ -n "${missing_targets}" ]]; then
    ftctl_state_set "${vm}" \
      "protection_state=error" \
      "transport_state=failed" \
      "last_sync_ts=$(ftctl_now_iso8601)" \
      "last_error=blockcopy_job_missing:${missing_targets}"
    ftctl_log_event "mirror" "blockcopy.refresh" "fail" "${vm}" "" \
      "missing_targets=${missing_targets}"
  else
    ftctl_state_set "${vm}" \
      "protection_state=syncing" \
      "transport_state=copying" \
      "last_sync_ts=$(ftctl_now_iso8601)"
  fi

  return "${rc_any}"
}

ftctl_blockcopy_plan_protect() {
  local vm="${1-}"
  local disks=()
  local line target source format dest secondary_dest remote_xml shared_xml export_name export_port shared_reuse shared_cmd
  local xml_bundle_dir primary_xml_backup standby_xml_seed persistence
  local out err rc job_state ready
  local records=()
  local sync_flag="0"

  xml_bundle_dir=""
  primary_xml_backup=""
  standby_xml_seed=""
  persistence="unknown"
  if ! ftctl_blockcopy_validate_backend_mode "${vm}"; then
    rc=$?
    ftctl_state_set "${vm}" \
      "protection_state=error" \
      "transport_state=failed" \
      "last_error=backend_mode_validation_failed"
    return "${rc}"
  fi
  ftctl_inventory_backup_domain_xml "${vm}" xml_bundle_dir primary_xml_backup standby_xml_seed persistence
  if [[ "${FTCTL_PROFILE_DOMAIN_PERSISTENCE:-auto}" == "yes" || "${FTCTL_PROFILE_DOMAIN_PERSISTENCE:-auto}" == "no" ]]; then
    persistence="${FTCTL_PROFILE_DOMAIN_PERSISTENCE}"
  fi
  ftctl_state_set "${vm}" \
    "xml_bundle_dir=${xml_bundle_dir}" \
    "primary_xml_backup=${primary_xml_backup}" \
    "standby_xml_seed=${standby_xml_seed}" \
    "primary_persistence=${persistence}" \
    "secondary_vm_name=$(ftctl_profile_secondary_vm_name_resolved "${vm}")" \
    "backend_mode=${FTCTL_PROFILE_BACKEND_MODE}" \
    "target_storage_scope=${FTCTL_PROFILE_TARGET_STORAGE_SCOPE}"

  ftctl_inventory_collect_vm_disks "${vm}" disks

  for line in "${disks[@]}"; do
    target="${line%%|*}"
    source="${line#*|}"
    source="${source%%|*}"
    format="${line##*|}"
    ftctl_blockcopy_prepare_primary_rbd_thin_for_protect "${vm}" "${target}" "${source}" || return $?
    if [[ "${FTCTL_PROFILE_BACKEND_MODE}" == "remote-nbd" ]]; then
      secondary_dest="$(ftctl_blockcopy_remote_nbd_secondary_path "${vm}" "${target}" "${source}" "${format}")" || return $?
      export_port=""
      ftctl_blockcopy_remote_nbd_pick_port "${vm}" "${target}" export_port || return $?
      export_name="${FTCTL_PROFILE_REMOTE_NBD_EXPORT_NAME}-${target}"
      dest="$(ftctl_blockcopy_remote_nbd_uri "${FTCTL_PROFILE_REMOTE_NBD_EXPORT_ADDR}" "${export_port}" "${export_name}")"
    else
      secondary_dest=""
      export_port=""
      export_name=""
      dest="$(ftctl_blockcopy_resolve_dest "${vm}" "${target}" "${source}" "${format}")"
    fi
    if [[ "${FTCTL_PROFILE_BACKEND_MODE}" != "remote-nbd" ]]; then
      ftctl_ensure_dir "$(dirname "${dest}")" "0755"
    fi
    if [[ "${FTCTL_BLOCKCOPY_SYNC_WRITES}" == "1" ]]; then
      sync_flag="1"
    fi

    out=""
    err=""
    rc=0
    if [[ "${FTCTL_PROFILE_BACKEND_MODE}" == "remote-nbd" ]]; then
      ftctl_blockcopy_remote_nbd_prepare_target "${vm}" "${target}" "${source}" "${format}" "${secondary_dest}" "${export_name}" "${export_port}" || return $?
      remote_xml=""
      ftctl_blockcopy_build_remote_nbd_dest_xml \
        "${vm}" "${target}" "${format}" \
        "${FTCTL_PROFILE_REMOTE_NBD_EXPORT_ADDR}" "${export_port}" "${export_name}" \
        "${primary_xml_backup}" remote_xml
      {
        local remote_host="" remote_user="" debug_remote_cmd="" debug_size="" debug_bind_addr="" debug_target_format=""
        ftctl_blockcopy_remote_target_host_user remote_host remote_user || true
        ftctl_blockcopy_remote_nbd_host_only "${FTCTL_PROFILE_REMOTE_NBD_EXPORT_ADDR}" debug_bind_addr || debug_bind_addr="${FTCTL_PROFILE_REMOTE_NBD_EXPORT_ADDR}"
        ftctl_blockcopy_remote_nbd_target_format "${secondary_dest}" "${format}" debug_target_format
        ftctl_blockcopy_source_virtual_size_bytes "${vm}" "${target}" "${source}" debug_size || true
        debug_remote_cmd="$(cat <<EOF
set -euo pipefail
mkdir -p "$(dirname "${secondary_dest}")" /run/ablestack-vm-ftctl
if [[ ! -f "${secondary_dest}" ]]; then
  qemu-img create -f "${debug_target_format}" "${secondary_dest}" "${debug_size}"
fi
nbd_thin_opts=()
if [[ "${FTCTL_THIN_PRESERVE:-1}" == "1" ]]; then
  qemu-nbd --help 2>&1 | grep -q -- '--discard' && nbd_thin_opts+=(--discard=unmap)
  qemu-nbd --help 2>&1 | grep -q -- '--detect-zeroes' && nbd_thin_opts+=(--detect-zeroes=unmap)
fi
qemu-nbd --fork --persistent --shared=8 "\${nbd_thin_opts[@]}" --bind "${debug_bind_addr}" --port "${export_port}" --export-name "${export_name}" --format "${debug_target_format}" --pid-file "/run/ablestack-vm-ftctl/nbd-${vm}-${target}.pid" "${secondary_dest}"
EOF
)"
        ftctl_blockcopy_write_remote_nbd_repro "${vm}" "${target}" "${remote_xml}" "${remote_host}" "${remote_user}" "${debug_remote_cmd}" "${persistence}"
        ftctl_blockcopy_write_debug_file "${vm}" "${target}" "secondary-prepare-context.txt" \
          "host=${remote_host}
user=${remote_user}
size=${debug_size}
source_format=${format}
target_format=${debug_target_format}
secondary_path=${secondary_dest}
export_name=${export_name}
xml_port=${export_port}
xml=${remote_xml}"
      }
      ftctl_blockcopy_start_remote_nbd_job \
        "${FTCTL_PROFILE_PRIMARY_URI}" \
        "${vm}" \
        "${target}" \
        "${format}" \
        "${persistence}" \
        "${remote_xml}" \
        out \
        err \
        rc || true
      ftctl_blockcopy_write_debug_file "${vm}" "${target}" "primary-blockcopy-stdout.txt" "${out}"
      ftctl_blockcopy_write_debug_file "${vm}" "${target}" "primary-blockcopy-stderr.txt" "${err}"
      ftctl_blockcopy_write_debug_file "${vm}" "${target}" "primary-blockcopy-rc.txt" "${rc}"
      ftctl_blockcopy_capture_primary_debug "${vm}" "${target}"
    else
      if ftctl_blockcopy_is_krbd_path "${dest}"; then
        ftctl_blockcopy_krbd_map_local "${dest}" || return $?
      fi
      shared_xml=""
      ftctl_blockcopy_build_shared_dest_xml \
        "${vm}" "${target}" "${format}" "${dest}" "${primary_xml_backup}" shared_xml
      ftctl_blockcopy_write_debug_file "${vm}" "${target}" "shared-blockcopy-dest.xml" "$(cat "${shared_xml}")"
      shared_reuse="0"
      ftctl_blockcopy_is_cloud_managed && shared_reuse="1"
      shared_cmd="env LC_ALL=C LANG=C virsh -c ${FTCTL_PROFILE_PRIMARY_URI@Q} blockcopy ${vm@Q} ${target@Q} --xml ${shared_xml@Q}"
      [[ "${persistence}" == "yes" ]] && shared_cmd+=" --transient-job"
      [[ "${FTCTL_BLOCKCOPY_SYNC_WRITES}" == "1" ]] && shared_cmd+=" --synchronous-writes"
      [[ "${shared_reuse}" == "1" ]] && shared_cmd+=" --reuse-external"
      ftctl_blockcopy_write_debug_file "${vm}" "${target}" "primary-blockcopy-command.txt" "${shared_cmd}"
      ftctl_blockcopy_start_shared_xml_job \
        "${FTCTL_PROFILE_PRIMARY_URI}" \
        "${vm}" \
        "${target}" \
        "${persistence}" \
        "${shared_xml}" \
        out \
        err \
        rc \
        "${shared_reuse}" || true
    fi
    if [[ "${rc}" != "0" ]]; then
      ftctl_state_set "${vm}" \
        "protection_state=error" \
        "transport_state=failed" \
        "last_error=blockcopy_start_failed_${target}"
      ftctl_log_event "mirror" "blockcopy.protect" "fail" "${vm}" "${rc}" \
        "target=${target} dest=${dest}"
      if [[ -n "${err}" ]]; then
        echo "ERROR: blockcopy start failed for ${vm}:${target}: ${err}" >&2
      else
        echo "ERROR: blockcopy start failed for ${vm}:${target} rc=${rc}" >&2
      fi
      if [[ "${FTCTL_PROFILE_BACKEND_MODE}" == "remote-nbd" ]]; then
        ftctl_blockcopy_write_debug_file "${vm}" "${target}" "primary-blockcopy-stdout.txt" "${out}"
        ftctl_blockcopy_write_debug_file "${vm}" "${target}" "primary-blockcopy-stderr.txt" "${err}"
        ftctl_blockcopy_write_debug_file "${vm}" "${target}" "primary-blockcopy-rc.txt" "${rc}"
      fi
      return "${rc}"
    fi

    job_state="unknown"
    ready="unknown"
    if ! ftctl_blockcopy_wait_for_job_visibility "${vm}" "${target}" job_state ready 5; then
      ftctl_state_set "${vm}" \
        "protection_state=error" \
        "transport_state=failed" \
        "last_error=blockcopy_job_query_failed"
      ftctl_log_event "mirror" "blockcopy.query" "fail" "${vm}" "" \
        "target=${target} dest=${dest}"
      if [[ "${FTCTL_PROFILE_BACKEND_MODE}" == "remote-nbd" ]]; then
        ftctl_blockcopy_write_debug_file "${vm}" "${target}" "primary-blockcopy-stdout.txt" "${out}"
        ftctl_blockcopy_write_debug_file "${vm}" "${target}" "primary-blockcopy-stderr.txt" "${err}"
        ftctl_blockcopy_write_debug_file "${vm}" "${target}" "primary-blockcopy-rc.txt" "${rc}"
      fi
      return 1
    fi

    records+=("${target}|${source}|${dest}|${format}|${job_state}|${ready}|${secondary_dest}")
    ftctl_log_event "mirror" "blockcopy.start" "ok" "${vm}" "" \
      "target=${target} dest=${dest} format=${format} sync_writes=${sync_flag}"
  done

  ftctl_blockcopy_state_write "${vm}" "${records[@]}"
  ftctl_blockcopy_refresh_vm_jobs "${vm}" || return $?
  if [[ "${FTCTL_PROFILE_MODE}" == "dr" && "${FTCTL_EXPERIMENT_DR_DEFER_STANDBY_PREPARE:-0}" == "1" ]]; then
    ftctl_log_event "standby" "standby.prepare" "skip" "${vm}" "" "reason=dr_experiment_defer"
  else
    ftctl_standby_prepare "${vm}"
  fi
}

ftctl_blockcopy_rearm() {
  local vm="${1-}"
  local count
  local records=()
  local record target source dest format rc_any=0
  local persistence out err rc
  count="$(ftctl_state_increment "${vm}" "rearm_count")"
  persistence="$(ftctl_state_get "${vm}" "primary_persistence" 2>/dev/null || echo "unknown")"
  ftctl_state_set "${vm}" \
    "protection_state=rearming" \
    "transport_state=rearm_pending" \
    "last_rearm_ts=$(ftctl_now_iso8601)" \
    "last_error="

  ftctl_standby_blockcopy_records "${vm}" records || {
    ftctl_state_set "${vm}" \
      "protection_state=error" \
      "transport_state=rearm_failed" \
      "last_error=blockcopy_rearm_missing_state"
    return 1
  }

  for record in "${records[@]}"; do
    target="${record%%|*}"
    record="${record#*|}"
    source="${record%%|*}"
    record="${record#*|}"
    dest="${record%%|*}"
    record="${record#*|}"
    format="${record%%|*}"
    : "${source}"
    ftctl_blockcopy_abort_job "${FTCTL_PROFILE_PRIMARY_URI}" "${vm}" "${target}"
    out=""
    err=""
    rc=0
    ftctl_blockcopy_start_job \
      "${FTCTL_PROFILE_PRIMARY_URI}" \
      "${vm}" \
      "${target}" \
      "${dest}" \
      "${format}" \
      "1" \
      "${persistence}" \
      out \
      err \
      rc || true
    if [[ "${rc}" != "0" ]]; then
      rc_any=1
      ftctl_log_event "rearm" "blockcopy.rearm.start" "fail" "${vm}" "" \
        "target=${target} dest=${dest}"
      [[ -n "${err}" ]] && echo "ERROR: blockcopy rearm failed for ${vm}:${target}: ${err}" >&2
    else
      ftctl_log_event "rearm" "blockcopy.rearm.start" "ok" "${vm}" "" \
        "target=${target} dest=${dest} rearm_count=${count}"
    fi
  done

  if [[ "${rc_any}" != "0" ]]; then
    ftctl_state_set "${vm}" \
      "protection_state=error" \
      "transport_state=rearm_failed" \
      "last_error=blockcopy_rearm_start_failed"
    return 1
  fi

  ftctl_blockcopy_refresh_vm_jobs "${vm}"
  if [[ "${FTCTL_PROFILE_MODE}" == "dr" && "${FTCTL_EXPERIMENT_DR_DEFER_STANDBY_PREPARE:-0}" == "1" ]]; then
    ftctl_log_event "standby" "standby.prepare" "skip" "${vm}" "" "reason=dr_experiment_defer"
  else
    ftctl_standby_prepare "${vm}"
  fi
}

ftctl_blockcopy_prepare_reverse_sync_plan() {
  local vm="${1-}"
  local records=()
  local reverse_records=()
  local record target source dest format job_state ready secondary_path reverse_dest
  local remote_host="" remote_user="" guest_size="" target_size=""

  ftctl_standby_blockcopy_records "${vm}" records || return 1
  if [[ "${FTCTL_PROFILE_BACKEND_MODE:-}" == "remote-nbd" ]]; then
    ftctl_blockcopy_remote_target_host_user remote_host remote_user || return 2
  fi

  for record in "${records[@]}"; do
    target=""; source=""; dest=""; format=""; job_state=""; ready=""; secondary_path=""
    IFS='|' read -r target source dest format job_state ready secondary_path <<< "${record}"
    : "${job_state}${ready}"

    reverse_dest="$(ftctl_blockcopy_resolve_reverse_dest "${target}" "${source}")"
    guest_size=""
    target_size=""
    if [[ "${FTCTL_PROFILE_BACKEND_MODE:-}" == "remote-nbd" && -n "${secondary_path}" ]]; then
      ftctl_blockcopy_remote_path_virtual_size_bytes "${remote_host}" "${remote_user}" "${secondary_path}" guest_size || guest_size=""
      ftctl_blockcopy_local_path_virtual_size_bytes "${reverse_dest}" target_size || target_size=""
    fi
    if [[ -n "${guest_size}" && -n "${target_size}" && "${guest_size}" != "${target_size}" ]]; then
      ftctl_state_set "${vm}" "last_error=reverse_size_mismatch:${target}:${guest_size}:${target_size}"
      ftctl_log_event "failback" "reverse_sync.size" "fail" "${vm}" "" \
        "target=${target} secondary_path=${secondary_path} guest_virtual_size=${guest_size} target_size=${target_size}"
      return 2
    fi
    reverse_records+=("${target}|${dest}|${reverse_dest}|${format}|${secondary_path}|${guest_size}|${target_size}")
  done

  ftctl_blockcopy_state_write_reverse "${vm}" "${reverse_records[@]}"
}

ftctl_blockcopy_start_reverse_sync() {
  local vm="${1-}"
  local path line target source dest format secondary_path guest_size target_size rc_any=0 payload state ready query_rc i
  local persistence out err rc
  local active_vm export_name export_port export_addr reverse_xml source_xml shared_reuse

  ftctl_blockcopy_prepare_reverse_sync_plan "${vm}" || {
    ftctl_state_set "${vm}" "last_error=reverse_sync_plan_failed"
    return 1
  }

  path="$(ftctl_blockcopy_reverse_state_path "${vm}")"
  [[ -f "${path}" ]] || return 1
  persistence="$(ftctl_state_get "${vm}" "primary_persistence" 2>/dev/null || echo "unknown")"

  if ! ftctl_blockcopy_map_reverse_krbd_destinations "${vm}"; then
    ftctl_state_set "${vm}" \
      "protection_state=error" \
      "transport_state=reverse_sync_failed" \
      "last_error=reverse_rbd_map_failed"
    return 1
  fi

  active_vm="$(ftctl_blockcopy_active_domain_on_secondary "${vm}")"
  while IFS= read -r line; do
    [[ -n "${line}" ]] || continue
    target=""; source=""; dest=""; format=""; secondary_path=""; guest_size=""; target_size=""
    IFS='|' read -r target source dest format secondary_path guest_size target_size <<< "${line}"
    : "${source}${secondary_path}${guest_size}${target_size}"
    out=""
    err=""
    rc=0
    if [[ "${FTCTL_PROFILE_BACKEND_MODE}" == "remote-nbd" ]]; then
      export_port=""
      ftctl_blockcopy_primary_nbd_pick_port "${vm}" "${target}" export_port || return $?
      export_name="${FTCTL_PROFILE_REMOTE_NBD_EXPORT_NAME}-${target}-reverse"
      ftctl_blockcopy_primary_export_addr export_addr || return $?
      ftctl_blockcopy_primary_nbd_prepare_target "${vm}" "${target}" "${source}" "${format}" "${dest}" "${export_name}" "${export_port}" || return $?
      reverse_xml=""
      source_xml="$(ftctl_state_get "${vm}" "standby_xml_seed" 2>/dev/null || true)"
      ftctl_blockcopy_build_remote_nbd_dest_xml \
        "${vm}" "${target}" "${format}" \
        "${export_addr}" "${export_port}" "${export_name}" \
        "${source_xml}" reverse_xml
      ftctl_blockcopy_start_remote_nbd_job \
        "${FTCTL_PROFILE_SECONDARY_URI}" \
        "${active_vm}" \
        "${target}" \
        "${format}" \
        "${persistence}" \
        "${reverse_xml}" \
        out \
        err \
        rc || true
    else
      reverse_xml=""
      source_xml="$(ftctl_state_get "${vm}" "standby_xml_seed" 2>/dev/null || true)"
      ftctl_blockcopy_build_shared_dest_xml \
        "${vm}" "${target}" "${format}" "${dest}" "${source_xml}" reverse_xml
      shared_reuse="0"
      ftctl_blockcopy_is_cloud_managed && shared_reuse="1"
      ftctl_blockcopy_start_shared_xml_job \
        "${FTCTL_PROFILE_SECONDARY_URI}" \
        "${active_vm}" \
        "${target}" \
        "${persistence}" \
        "${reverse_xml}" \
        out \
        err \
        rc \
        "${shared_reuse}" || true
    fi
    payload="${out}"$'\n'"${err}"
    if [[ "${rc}" == "0" ]] && ftctl_blockcopy_payload_indicates_start_failure "${payload}"; then
      rc=2
    fi
    if [[ "${rc}" == "0" ]]; then
      state="unknown"
      ready="unknown"
      query_rc=1
      for i in 1 2 3 4 5; do
        if ftctl_blockcopy_reverse_job_query "${vm}" "${target}" state ready; then
          query_rc=0
          break
        fi
        sleep 1
      done
      if [[ "${query_rc}" != "0" ]]; then
        rc=3
        err="${err}"$'\n'"reverse block job not found after start for ${target}"
      fi
    fi
    if [[ "${rc}" != "0" ]]; then
      rc_any=1
      ftctl_log_event "failback" "reverse_sync.start" "fail" "${vm}" "" \
        "target=${target} dest=${dest}"
      [[ -n "${err}" ]] && echo "ERROR: reverse sync start failed for ${vm}:${target}: ${err}" >&2
    else
      ftctl_log_event "failback" "reverse_sync.start" "ok" "${vm}" "" \
        "target=${target} dest=${dest}"
    fi
  done < "${path}"

  if [[ "${rc_any}" != "0" ]]; then
    ftctl_state_set "${vm}" \
      "protection_state=error" \
      "transport_state=reverse_sync_failed" \
      "last_error=reverse_sync_start_failed"
    return 1
  fi

  ftctl_state_set "${vm}" \
    "transport_state=reverse_syncing" \
    "last_sync_ts=$(ftctl_now_iso8601)"
}

ftctl_blockcopy_refresh_reverse_jobs() {
  local vm="${1-}"
  local path line target source dest format secondary_path guest_size target_size state ready active_vm domain_state
  local all_ready="1"
  local rc_any=0

  path="$(ftctl_blockcopy_reverse_state_path "${vm}")"
  [[ -f "${path}" ]] || return 1

  active_vm="$(ftctl_blockcopy_active_domain_on_secondary "${vm}")"
  domain_state=""
  if ! ftctl_blockcopy_secondary_domain_state "${vm}" domain_state; then
    if ftctl_blockcopy_reverse_progress_ready "${vm}"; then
      ftctl_state_set "${vm}" "transport_state=reverse_sync_ready" "last_sync_ts=$(ftctl_now_iso8601)" "last_error="
      ftctl_log_event "failback" "reverse_sync.ready" "ok" "${vm}" "" \
        "reason=qmp_progress_ready_after_secondary_stop active_vm=${active_vm} state=${domain_state:-not-found}"
      return 0
    fi
    ftctl_state_set "${vm}" \
      "protection_state=error" \
      "transport_state=reverse_sync_failed" \
      "last_error=reverse_sync_domain_lost" \
      "last_sync_ts=$(ftctl_now_iso8601)"
    ftctl_log_event "failback" "reverse_sync.domain" "fail" "${vm}" "" \
      "active_vm=${active_vm} state=${domain_state} peer_uri=${FTCTL_PROFILE_SECONDARY_URI}"
    return 21
  fi
  case "${domain_state}" in
    running|running\ \(*)
      ;;
    *)
      if ftctl_blockcopy_reverse_progress_ready "${vm}"; then
        ftctl_state_set "${vm}" "transport_state=reverse_sync_ready" "last_sync_ts=$(ftctl_now_iso8601)" "last_error="
        ftctl_log_event "failback" "reverse_sync.ready" "ok" "${vm}" "" \
          "reason=qmp_progress_ready_after_secondary_stop active_vm=${active_vm} state=${domain_state}"
        return 0
      fi
      ftctl_state_set "${vm}" \
        "protection_state=error" \
        "transport_state=reverse_sync_failed" \
        "last_error=reverse_sync_domain_not_running" \
        "last_sync_ts=$(ftctl_now_iso8601)"
      ftctl_log_event "failback" "reverse_sync.domain" "fail" "${vm}" "" \
        "active_vm=${active_vm} state=${domain_state} peer_uri=${FTCTL_PROFILE_SECONDARY_URI}"
      return 22
      ;;
  esac

  while IFS= read -r line; do
    [[ -n "${line}" ]] || continue
    target=""; source=""; dest=""; format=""; secondary_path=""; guest_size=""; target_size=""
    IFS='|' read -r target source dest format secondary_path guest_size target_size <<< "${line}"
    : "${source}${dest}${format}${secondary_path}${guest_size}${target_size}"
    state="unknown"
    ready="unknown"
    if ! ftctl_blockcopy_reverse_job_query "${vm}" "${target}" state ready; then
      rc_any=1
    fi
    [[ "${ready}" == "yes" ]] || all_ready="0"
  done < "${path}"
  ftctl_blockcopy_progress_refresh_from_qmp "${vm}" "${active_vm}" "${FTCTL_PROFILE_SECONDARY_URI}" "reverse" "failback" "reverse_sync.progress" >/dev/null 2>&1 || true

  if [[ "${all_ready}" == "1" && "${rc_any}" == "0" ]]; then
    ftctl_state_set "${vm}" "transport_state=reverse_sync_ready" "last_sync_ts=$(ftctl_now_iso8601)" "last_error="
    return 0
  fi

  if ftctl_blockcopy_reverse_progress_ready "${vm}"; then
    ftctl_state_set "${vm}" "transport_state=reverse_sync_ready" "last_sync_ts=$(ftctl_now_iso8601)" "last_error="
    ftctl_log_event "failback" "reverse_sync.ready" "ok" "${vm}" "" \
      "reason=qmp_progress_ready"
    return 0
  fi

  if [[ "${rc_any}" == "0" ]] && ftctl_blockcopy_reverse_cutback_ready "${vm}"; then
    ftctl_state_set "${vm}" "transport_state=reverse_sync_cutback_required" "last_sync_ts=$(ftctl_now_iso8601)" "last_error="
    ftctl_log_event "failback" "reverse_sync.cutback-ready" "ok" "${vm}" "" \
      "reason=guest_virtual_size_reached"
    return 23
  fi

  ftctl_state_set "${vm}" "transport_state=reverse_syncing" "last_sync_ts=$(ftctl_now_iso8601)"
  return 11
}

ftctl_blockcopy_reverse_progress_ready() {
  local vm="${1-}"
  local progress_path

  progress_path="$(ftctl_blockcopy_progress_path "${vm}")"
  [[ -f "${progress_path}" ]] || return 1
  python3 - "${progress_path}" <<'PY'
import json
import sys

path = sys.argv[1]
try:
    with open(path, "r", encoding="utf-8") as fh:
        data = json.load(fh)
except Exception:
    raise SystemExit(1)

if data.get("direction") != "reverse":
    raise SystemExit(1)
if data.get("ready") is not True:
    raise SystemExit(1)
disks = data.get("disks") or []
if not disks:
    raise SystemExit(1)
for disk in disks:
    if disk.get("ready") is not True:
        raise SystemExit(1)
    if str(disk.get("status") or "").lower() not in ("ready", "concluded"):
        raise SystemExit(1)
raise SystemExit(0)
PY
}

ftctl_blockcopy_reverse_cutback_ready() {
  local vm="${1-}"
  local progress_path

  progress_path="$(ftctl_blockcopy_progress_path "${vm}")"
  [[ -f "${progress_path}" ]] || return 1
  python3 - "${progress_path}" <<'PY'
import json
import sys

path = sys.argv[1]
try:
    with open(path, "r", encoding="utf-8") as fh:
        data = json.load(fh)
except Exception:
    raise SystemExit(1)

if data.get("direction") != "reverse":
    raise SystemExit(1)
disks = data.get("disks") or []
if not disks:
    raise SystemExit(1)

for disk in disks:
    guest = int(disk.get("guest_virtual_size") or 0)
    target = int(disk.get("target_size") or 0)
    offset = int(disk.get("offset") or 0)
    if guest <= 0 or target <= 0:
        raise SystemExit(1)
    if guest != target:
        raise SystemExit(1)
    if offset < guest:
        raise SystemExit(1)
raise SystemExit(0)
PY
}

ftctl_blockcopy_shared_reverse_finalize_validate_progress() {
  local vm="${1-}"
  local reverse_path progress_path

  reverse_path="$(ftctl_blockcopy_reverse_state_path "${vm}")"
  progress_path="$(ftctl_blockcopy_progress_path "${vm}")"
  [[ -s "${reverse_path}" ]] || {
    ftctl_state_set "${vm}" "last_error=reverse_finalize_missing_state"
    return 1
  }
  [[ -s "${progress_path}" ]] || {
    ftctl_state_set "${vm}" "last_error=reverse_finalize_progress_not_ready"
    return 2
  }

  python3 - "${reverse_path}" "${progress_path}" <<'PY'
import json
import sys

reverse_path, progress_path = sys.argv[1:3]

records = {}
try:
    with open(reverse_path, "r", encoding="utf-8") as fh:
        for raw in fh:
            raw = raw.rstrip("\n")
            if not raw:
                continue
            parts = raw.split("|")
            while len(parts) < 7:
                parts.append("")
            target, source, dest, _fmt, _secondary, guest_size, target_size = parts[:7]
            if not target or not source or not dest:
                print("reverse_finalize_shared_target_invalid:%s" % (target or "unknown"))
                raise SystemExit(10)
            if source == dest:
                print("reverse_finalize_shared_target_invalid:%s" % target)
                raise SystemExit(10)
            records[target] = {
                "source": source,
                "dest": dest,
                "guest_size": int(guest_size) if guest_size.isdigit() else 0,
                "target_size": int(target_size) if target_size.isdigit() else 0,
            }
except SystemExit:
    raise
except Exception:
    print("reverse_finalize_missing_state")
    raise SystemExit(1)

if not records:
    print("reverse_finalize_missing_state")
    raise SystemExit(1)

try:
    with open(progress_path, "r", encoding="utf-8") as fh:
        progress = json.load(fh)
except Exception:
    print("reverse_finalize_progress_not_ready")
    raise SystemExit(2)

if progress.get("direction") != "reverse" or progress.get("ready") is not True:
    print("reverse_finalize_progress_not_ready")
    raise SystemExit(2)

disks = progress.get("disks") or []
if not disks:
    print("reverse_finalize_progress_not_ready")
    raise SystemExit(2)

by_target = {str(d.get("target") or ""): d for d in disks if d.get("target")}
for target, record in records.items():
    disk = by_target.get(target)
    if not disk:
        print("reverse_finalize_disk_not_ready:%s" % target)
        raise SystemExit(11)
    if disk.get("ready") is not True:
        print("reverse_finalize_disk_not_ready:%s" % target)
        raise SystemExit(11)
    if str(disk.get("status") or "").lower() not in ("ready", "concluded"):
        print("reverse_finalize_disk_not_ready:%s" % target)
        raise SystemExit(11)

    offset = int(disk.get("offset") or 0)
    length = int(disk.get("len") or 0)
    progress_target_size = int(disk.get("target_size") or 0)
    progress_guest_size = int(disk.get("guest_virtual_size") or 0)
    expected_sizes = [x for x in (
        record["target_size"],
        record["guest_size"],
        progress_target_size,
        progress_guest_size,
    ) if x > 0]

    if length <= 0 or offset <= 0:
        print("reverse_finalize_disk_not_ready:%s" % target)
        raise SystemExit(11)
    if offset < length:
        print("reverse_finalize_disk_not_ready:%s" % target)
        raise SystemExit(11)
    if expected_sizes and any(size != expected_sizes[0] for size in expected_sizes):
        print("reverse_finalize_size_mismatch:%s:%s" % (target, ":".join(str(x) for x in expected_sizes)))
        raise SystemExit(12)
    if expected_sizes and offset < expected_sizes[0]:
        print("reverse_finalize_size_mismatch:%s:%s:%s" % (target, expected_sizes[0], offset))
        raise SystemExit(12)

raise SystemExit(0)
PY
}

ftctl_blockcopy_finalize_reverse_sync_shared() {
  local vm="${1-}"
  local path="${2-}"
  local line target source dest format secondary_path guest_size target_size
  local target_size_actual="" validate_error=""

  validate_error="$(ftctl_blockcopy_shared_reverse_finalize_validate_progress "${vm}" 2>/dev/null)" || {
    [[ -n "${validate_error}" ]] || validate_error="$(ftctl_state_get "${vm}" "last_error" 2>/dev/null || echo "reverse_finalize_progress_not_ready")"
    ftctl_state_set "${vm}" "last_error=${validate_error}"
    ftctl_log_event "failback" "reverse_sync.finalize" "fail" "${vm}" "" \
      "backend=shared-blockcopy reason=${validate_error}"
    return 2
  }

  while IFS= read -r line; do
    [[ -n "${line}" ]] || continue
    target=""; source=""; dest=""; format=""; secondary_path=""; guest_size=""; target_size=""
    IFS='|' read -r target source dest format secondary_path guest_size target_size <<< "${line}"
    : "${format}${secondary_path}${guest_size}"
    if ! ftctl_blockcopy_local_path_virtual_size_bytes "${dest}" target_size_actual; then
      ftctl_state_set "${vm}" "last_error=reverse_finalize_shared_target_invalid:${target}"
      ftctl_log_event "failback" "reverse_sync.finalize" "fail" "${vm}" "" \
        "backend=shared-blockcopy target=${target} dest=${dest} reason=target_size_unavailable"
      return 2
    fi
    if [[ "${target_size}" =~ ^[1-9][0-9]*$ && "${target_size_actual}" != "${target_size}" ]]; then
      ftctl_state_set "${vm}" "last_error=reverse_finalize_size_mismatch:${target}:${target_size}:${target_size_actual}"
      ftctl_log_event "failback" "reverse_sync.finalize" "fail" "${vm}" "" \
        "backend=shared-blockcopy target=${target} dest=${dest} expected_size=${target_size} actual_size=${target_size_actual}"
      return 2
    fi
    ftctl_log_event "failback" "reverse_sync.finalize" "ok" "${vm}" "" \
      "backend=shared-blockcopy target=${target} source=${source} dest=${dest} target_size=${target_size_actual}"
  done < "${path}"

  rm -f -- "${path}" 2>/dev/null || true
  ftctl_state_set "${vm}" \
    "transport_state=cutback_ready" \
    "last_sync_ts=$(ftctl_now_iso8601)" \
    "last_error="
}

ftctl_blockcopy_wait_forward_sync_ready() {
  local vm="${1-}"
  local timeout_sec="${2-120}"
  local deadline rc

  deadline=$((SECONDS + timeout_sec))
  while (( SECONDS <= deadline )); do
    rc=0
    ftctl_blockcopy_refresh_vm_jobs "${vm}" || rc=$?
    if [[ "${rc}" == "0" ]] && [[ "$(ftctl_state_get "${vm}" "transport_state" 2>/dev/null || true)" == "mirroring" ]]; then
      return 0
    fi
    sleep 2
  done
  return 1
}

ftctl_blockcopy_stop_primary_reverse_nbd_exports() {
  local vm="${1-}"
  local path line target source dest format secondary_path guest_size target_size host="" user="" out="" err="" rc=0

  path="$(ftctl_blockcopy_reverse_state_path "${vm}")"
  [[ -f "${path}" ]] || return 0
  if ! ftctl_blockcopy_primary_uri_is_local_system; then
    ftctl_blockcopy_primary_target_host_user host user || return 0
  fi

  while IFS= read -r line; do
    [[ -n "${line}" ]] || continue
    target=""; source=""; dest=""; format=""; secondary_path=""; guest_size=""; target_size=""
    IFS='|' read -r target source dest format secondary_path guest_size target_size <<< "${line}"
    : "${source}${dest}${format}${secondary_path}${guest_size}${target_size}"
    out="" err="" rc=0
    local stop_cmd
    stop_cmd="$(cat <<EOF
set -euo pipefail
pid_file="/run/ablestack-vm-ftctl/nbd-reverse-${vm}-${target}.pid"
export_name="${FTCTL_PROFILE_REMOTE_NBD_EXPORT_NAME}-${target}-reverse"
collect_pids() {
  if [[ -f "\${pid_file}" ]]; then
    oldpid="\$(cat "\${pid_file}" 2>/dev/null || true)"
    if [[ -n "\${oldpid}" ]] && kill -0 "\${oldpid}" >/dev/null 2>&1; then
      printf '%s\n' "\${oldpid}"
    fi
  fi
  ps -C qemu-nbd -o pid=,args= 2>/dev/null | while read -r qpid qargs; do
    [[ -n "\${qpid}" ]] || continue
    case "\${qargs}" in
      *"--export-name \${export_name}"*|*"--export-name=\${export_name}"*|*"\${pid_file}"*)
        printf '%s\n' "\${qpid}"
        ;;
    esac
  done | sort -u
}
if [[ -f "\${pid_file}" ]]; then
  oldpid="\$(cat "\${pid_file}" 2>/dev/null || true)"
  if [[ -n "\${oldpid}" ]] && kill -0 "\${oldpid}" >/dev/null 2>&1; then
    kill "\${oldpid}" >/dev/null 2>&1 || true
  fi
fi
for qpid in \$(collect_pids); do
  kill "\${qpid}" >/dev/null 2>&1 || true
done
for _i in \$(seq 1 10); do
  if [[ -z "\$(collect_pids)" ]]; then
    rm -f "\${pid_file}"
    exit 0
  fi
  sleep 1
done
for qpid in \$(collect_pids); do
  kill -9 "\${qpid}" >/dev/null 2>&1 || true
done
for _i in \$(seq 1 5); do
  if [[ -z "\$(collect_pids)" ]]; then
    rm -f "\${pid_file}"
    exit 0
  fi
  sleep 1
done
echo "reverse_nbd_stop_failed:\${export_name}:\${pid_file}" >&2
exit 99
EOF
)"
    if ftctl_blockcopy_primary_uri_is_local_system; then
      ftctl_cmd_run "${FTCTL_BLOCKCOPY_WAIT_TIMEOUT_SEC}" out err rc -- bash -lc "${stop_cmd}" || true
    else
      ftctl_blockcopy_remote_exec "${host}" "${user}" out err rc "${stop_cmd}" || true
    fi
    : "${out}${err}"
    if [[ "${rc}" != "0" ]]; then
      ftctl_state_set "${vm}" "last_error=reverse_nbd_stop_failed:${target}"
      ftctl_log_event "failback" "reverse_nbd.stop" "fail" "${vm}" "${rc}" \
        "target=${target} error=${err}"
      return "${rc}"
    fi
    ftctl_log_event "failback" "reverse_nbd.stop" "ok" "${vm}" "" \
      "target=${target}"
  done < "${path}"
}

ftctl_blockcopy_reverse_secondary_path_for_target() {
  local vm="${1-}"
  local target="${2-}"
  local out_var="${3}"
  local records=()
  local record rec_target source dest format job_state ready secondary_path

  ftctl_standby_blockcopy_records "${vm}" records || return 1
  for record in "${records[@]}"; do
    rec_target=""; source=""; dest=""; format=""; job_state=""; ready=""; secondary_path=""
    IFS='|' read -r rec_target source dest format job_state ready secondary_path <<< "${record}"
    : "${source}${dest}${format}${job_state}${ready}"
    if [[ "${rec_target}" == "${target}" && -n "${secondary_path}" ]]; then
      printf -v "${out_var}" '%s' "${secondary_path}"
      return 0
    fi
  done
  return 1
}

ftctl_blockcopy_prepare_rbd_target_for_sparse_finalize() {
  local vm="${1-}"
  local target="${2-}"
  local primary_path="${3-}"
  local spec="" q_spec="" q_path="" out="" err="" rc=0 parent="" before_used=""

  [[ "${FTCTL_THIN_PRESERVE:-1}" == "1" ]] || return 0
  ftctl_blockcopy_rbd_spec_from_path "${primary_path}" spec || return 0
  printf -v q_spec '%q' "${spec}"
  printf -v q_path '%q' "${primary_path}"

  ftctl_blockcopy_rbd_du_used_bytes_primary "${spec}" before_used || before_used=""
  ftctl_blockcopy_rbd_run_on_primary "${FTCTL_BLOCKCOPY_WAIT_TIMEOUT_SEC}" out err rc \
    "rbd info --format json ${q_spec}" || true
  if [[ "${rc}" != "0" ]]; then
    ftctl_state_set "${vm}" "last_error=reverse_finalize_rbd_info_failed:${target}" "thin_preserve=failed"
    ftctl_log_event "failback" "rbd.thin.precheck" "fail" "${vm}" "${rc}" \
      "target=${target} image=${spec} error=${err}"
    return "${rc}"
  fi
  parent="$(ftctl_blockcopy_rbd_parent_from_info_json "${out}" || true)"
  if [[ -n "${parent}" ]]; then
    ftctl_state_set "${vm}" "last_error=reverse_finalize_parent_present:${target}" "thin_preserve=failed"
    ftctl_log_event "failback" "rbd.thin.precheck" "fail" "${vm}" "" \
      "target=${target} image=${spec} parent=${parent}"
    return 2
  fi

  out=""; err=""; rc=0
  ftctl_blockcopy_rbd_run_on_primary "${FTCTL_BLOCKCOPY_WAIT_TIMEOUT_SEC}" out err rc \
    "if [[ -b ${q_path} ]]; then blkdiscard ${q_path}; else exit 11; fi" || true
  if [[ "${rc}" != "0" ]]; then
    ftctl_state_set "${vm}" "thin_preserve=warn" "last_thin_preserve_reason=blkdiscard_failed:${target}"
    ftctl_log_event "failback" "rbd.discard" "warn" "${vm}" "${rc}" \
      "target=${target} image=${spec} path=${primary_path} used_before=${before_used} error=${err}"
    return 30
  fi

  ftctl_state_set "${vm}" "thin_preserve=enabled" "last_thin_preserve_reason="
  ftctl_log_event "failback" "rbd.discard" "ok" "${vm}" "" \
    "target=${target} image=${spec} path=${primary_path} used_before=${before_used}"
}

ftctl_blockcopy_sparsify_rbd_target_after_finalize() {
  local vm="${1-}"
  local target="${2-}"
  local primary_path="${3-}"
  local spec="" q_spec="" out="" err="" rc=0 after_used=""

  [[ "${FTCTL_THIN_PRESERVE:-1}" == "1" ]] || return 0
  ftctl_blockcopy_rbd_spec_from_path "${primary_path}" spec || return 0
  printf -v q_spec '%q' "${spec}"
  out=""; err=""; rc=0
  ftctl_blockcopy_rbd_run_on_primary "${FTCTL_RBD_SPARSIFY_TIMEOUT_SEC:-1800}" out err rc \
    "rbd sparsify ${q_spec}" || true
  if [[ "${rc}" != "0" ]]; then
    ftctl_state_set "${vm}" "thin_preserve=warn" "last_thin_preserve_reason=post_finalize_sparsify_failed:${target}"
    ftctl_log_event "failback" "rbd.sparsify" "warn" "${vm}" "${rc}" \
      "target=${target} image=${spec} error=${err}"
    return 0
  fi
  ftctl_blockcopy_rbd_du_used_bytes_primary "${spec}" after_used || after_used=""
  ftctl_state_set "${vm}" "thin_preserve=enabled" "last_thin_preserve_reason="
  ftctl_log_event "failback" "rbd.sparsify" "ok" "${vm}" "" \
    "target=${target} image=${spec} used_after_sparsify=${after_used}"
}

ftctl_blockcopy_finalize_reverse_sync() {
  local vm="${1-}"
  local path line target source dest format secondary_path guest_size target_size
  local domain_state active_vm remote_host="" remote_user="" export_addr="" export_port="" export_name=""
  local out="" err="" rc=0 q_secondary="" q_nbd="" remote_cmd=""
  local convert_sparse_size="0" dest_rbd_spec=""
  local saved_wait_timeout="${FTCTL_BLOCKCOPY_WAIT_TIMEOUT_SEC}"

  path="$(ftctl_blockcopy_reverse_state_path "${vm}")"
  [[ -f "${path}" ]] || {
    ftctl_state_set "${vm}" "last_error=reverse_finalize_missing_state"
    return 1
  }

  active_vm="$(ftctl_blockcopy_active_domain_on_secondary "${vm}")"
  domain_state=""
  if ftctl_blockcopy_secondary_domain_state "${vm}" domain_state; then
    case "${domain_state}" in
      running|running\ \(*)
        ftctl_state_set "${vm}" "last_error=reverse_finalize_secondary_running"
        ftctl_log_event "failback" "reverse_sync.finalize" "fail" "${vm}" "" \
          "active_vm=${active_vm} state=${domain_state}"
        return 22
        ;;
    esac
  fi

  if [[ "${FTCTL_PROFILE_BACKEND_MODE:-}" == "shared-blockcopy" ]]; then
    ftctl_blockcopy_finalize_reverse_sync_shared "${vm}" "${path}"
    return $?
  fi

  [[ "${FTCTL_PROFILE_BACKEND_MODE:-}" == "remote-nbd" ]] || {
    ftctl_state_set "${vm}" "last_error=reverse_finalize_unsupported_backend:${FTCTL_PROFILE_BACKEND_MODE:-}"
    return 2
  }

  ftctl_blockcopy_remote_target_host_user remote_host remote_user || return 2
  ftctl_blockcopy_primary_export_addr export_addr || return 2
  FTCTL_BLOCKCOPY_WAIT_TIMEOUT_SEC="${FTCTL_FAILBACK_FINALIZE_TIMEOUT_SEC:-1800}"

  while IFS= read -r line; do
    [[ -n "${line}" ]] || continue
    target=""; source=""; dest=""; format=""; secondary_path=""; guest_size=""; target_size=""
    IFS='|' read -r target source dest format secondary_path guest_size target_size <<< "${line}"
    : "${source}${format}"
    if [[ -z "${secondary_path}" ]]; then
      ftctl_blockcopy_reverse_secondary_path_for_target "${vm}" "${target}" secondary_path || secondary_path=""
    fi
    if [[ -z "${secondary_path}" ]]; then
      FTCTL_BLOCKCOPY_WAIT_TIMEOUT_SEC="${saved_wait_timeout}"
      ftctl_state_set "${vm}" "last_error=reverse_finalize_missing_secondary_path:${target}"
      return 1
    fi

    if [[ -z "${guest_size}" ]]; then
      ftctl_blockcopy_remote_path_virtual_size_bytes "${remote_host}" "${remote_user}" "${secondary_path}" guest_size || guest_size=""
    fi
    if [[ -z "${target_size}" ]]; then
      ftctl_blockcopy_local_path_virtual_size_bytes "${dest}" target_size || target_size=""
    fi
    if [[ -z "${guest_size}" || -z "${target_size}" || "${guest_size}" != "${target_size}" ]]; then
      FTCTL_BLOCKCOPY_WAIT_TIMEOUT_SEC="${saved_wait_timeout}"
      ftctl_state_set "${vm}" "last_error=reverse_finalize_size_mismatch:${target}:${guest_size}:${target_size}"
      ftctl_log_event "failback" "reverse_sync.finalize" "fail" "${vm}" "" \
        "target=${target} secondary_path=${secondary_path} guest_virtual_size=${guest_size} target_size=${target_size}"
      ftctl_blockcopy_stop_primary_reverse_nbd_exports "${vm}" || true
      return 2
    fi

    export_port=""
    ftctl_blockcopy_primary_nbd_pick_port "${vm}" "${target}" export_port || {
      FTCTL_BLOCKCOPY_WAIT_TIMEOUT_SEC="${saved_wait_timeout}"
      return $?
    }
    export_name="${FTCTL_PROFILE_REMOTE_NBD_EXPORT_NAME}-${target}-reverse"
    convert_sparse_size="0"
    dest_rbd_spec=""
    if [[ "${FTCTL_THIN_PRESERVE:-1}" == "1" ]] && ftctl_blockcopy_rbd_spec_from_path "${dest}" dest_rbd_spec; then
      rc=0
      ftctl_blockcopy_prepare_rbd_target_for_sparse_finalize "${vm}" "${target}" "${dest}" || rc=$?
      if [[ "${rc}" == "0" ]]; then
        convert_sparse_size="${FTCTL_THIN_SPARSE_SIZE:-4k}"
      elif [[ "${rc}" == "30" ]]; then
        convert_sparse_size="0"
        ftctl_log_event "failback" "rbd.thin.fallback" "warn" "${vm}" "" \
          "target=${target} image=${dest_rbd_spec} reason=discard_unavailable action=full_overwrite"
      else
        FTCTL_BLOCKCOPY_WAIT_TIMEOUT_SEC="${saved_wait_timeout}"
        return "${rc}"
      fi
    fi
    ftctl_blockcopy_primary_nbd_prepare_target "${vm}" "${target}" "${dest}" "raw" "${dest}" "${export_name}" "${export_port}" || {
      FTCTL_BLOCKCOPY_WAIT_TIMEOUT_SEC="${saved_wait_timeout}"
      return $?
    }

    printf -v q_secondary '%q' "${secondary_path}"
    printf -v q_nbd '%q' "$(ftctl_blockcopy_remote_nbd_uri "${export_addr}" "${export_port}" "${export_name}")"
    remote_cmd=$(cat <<EOF
set -euo pipefail
secondary_path=${q_secondary}
target_uri=${q_nbd}
expected_size=${guest_size}
source_format="\$(qemu-img info --force-share --output=json "\${secondary_path}" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("format",""))')"
if [[ -z "\${source_format}" ]]; then
  echo "reverse_finalize_source_format_unknown:\${secondary_path}" >&2
  exit 90
fi
actual_guest_size="\$(qemu-img info --force-share --output=json "\${secondary_path}" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("virtual-size",""))')"
if [[ "\${actual_guest_size}" != "\${expected_size}" ]]; then
  echo "reverse_finalize_source_size_mismatch:\${secondary_path}:\${actual_guest_size}:\${expected_size}" >&2
  exit 91
fi
qemu-img convert -p -n -S "${convert_sparse_size}" -f "\${source_format}" -O raw "\${secondary_path}" "\${target_uri}"
EOF
)
    out=""
    err=""
    rc=0
    ftctl_blockcopy_remote_exec "${remote_host}" "${remote_user}" out err rc "${remote_cmd}" || true
    : "${out}"
    if [[ "${rc}" != "0" ]]; then
      FTCTL_BLOCKCOPY_WAIT_TIMEOUT_SEC="${saved_wait_timeout}"
      ftctl_state_set "${vm}" "last_error=reverse_finalize_convert_failed:${target}"
      ftctl_log_event "failback" "reverse_sync.finalize" "fail" "${vm}" "${rc}" \
        "target=${target} secondary_path=${secondary_path} dest=${dest} error=${err}"
      ftctl_blockcopy_stop_primary_reverse_nbd_exports "${vm}" || true
      return "${rc}"
    fi
    if ! ftctl_blockcopy_stop_primary_reverse_nbd_exports "${vm}"; then
      FTCTL_BLOCKCOPY_WAIT_TIMEOUT_SEC="${saved_wait_timeout}"
      ftctl_state_set "${vm}" "last_error=reverse_finalize_nbd_cleanup_failed:${target}"
      return 99
    fi
    if [[ "${convert_sparse_size}" != "0" ]]; then
      ftctl_blockcopy_sparsify_rbd_target_after_finalize "${vm}" "${target}" "${dest}" || true
    fi
    ftctl_log_event "failback" "reverse_sync.finalize" "ok" "${vm}" "" \
      "target=${target} secondary_path=${secondary_path} dest=${dest} guest_virtual_size=${guest_size} sparse_size=${convert_sparse_size}"
  done < "${path}"

  if ! ftctl_blockcopy_stop_primary_reverse_nbd_exports "${vm}"; then
    FTCTL_BLOCKCOPY_WAIT_TIMEOUT_SEC="${saved_wait_timeout}"
    ftctl_state_set "${vm}" "last_error=reverse_finalize_nbd_cleanup_failed"
    return 99
  fi
  rm -f -- "${path}" 2>/dev/null || true
  FTCTL_BLOCKCOPY_WAIT_TIMEOUT_SEC="${saved_wait_timeout}"
  ftctl_state_set "${vm}" \
    "transport_state=cutback_ready" \
    "last_sync_ts=$(ftctl_now_iso8601)" \
    "last_error="
}

ftctl_blockcopy_stop_remote_nbd_exports() {
  local vm="${1-}"
  local records=()
  local record target source dest format job_state ready secondary_dest
  local host user out err rc pid_file export_name export_port

  ftctl_standby_blockcopy_records "${vm}" records || return 0
  if ! ftctl_blockcopy_secondary_uri_is_local_system; then
    ftctl_blockcopy_remote_target_host_user host user || return 0
  fi

  for record in "${records[@]}"; do
    target=""; source=""; dest=""; format=""; job_state=""; ready=""; secondary_dest=""
    IFS='|' read -r target source dest format job_state ready secondary_dest <<< "${record}"
    pid_file="/run/ablestack-vm-ftctl/nbd-${vm}-${target}.pid"
    export_name="${FTCTL_PROFILE_REMOTE_NBD_EXPORT_NAME}-${target}"
    export_port=""
    if [[ "${dest}" == nbd://* ]]; then
      ftctl_blockcopy_remote_nbd_port_extract_from_uri "${dest}" export_port || true
    fi

    out="" err="" rc=0
    local stop_cmd
    stop_cmd="$(cat <<EOF
set -euo pipefail
if [[ -f "${pid_file}" ]]; then
  oldpid="\$(cat "${pid_file}" 2>/dev/null || true)"
  if [[ -n "\${oldpid}" ]] && kill -0 "\${oldpid}" >/dev/null 2>&1; then
    kill "\${oldpid}" >/dev/null 2>&1 || true
    sleep 1
  fi
  rm -f "${pid_file}"
fi
if [[ -n "${export_port}" ]]; then
  listener_pids="\$(ss -lntp | awk '/:${export_port}[[:space:]]/ { while (match(\$0, /pid=[0-9]+/)) { print substr(\$0, RSTART+4, RLENGTH-4); \$0=substr(\$0, RSTART+RLENGTH) } }' | sort -u)"
  for listener_pid in \${listener_pids}; do
    [[ -n "\${listener_pid}" ]] || continue
    kill "\${listener_pid}" >/dev/null 2>&1 || true
    sleep 1
  done
fi
if [[ -n "${secondary_dest}" && -e "${secondary_dest}" ]]; then
  for lock_pid in \$(fuser "${secondary_dest}" 2>/dev/null || true); do
    [[ -n "\${lock_pid}" ]] || continue
    comm="\$(ps -p "\${lock_pid}" -o comm= 2>/dev/null || true)"
    if [[ "\${comm}" == qemu-nbd* ]]; then
      kill "\${lock_pid}" >/dev/null 2>&1 || true
      sleep 1
    fi
  done
fi
pkill -f "qemu-nbd.*${vm}.*${target}" >/dev/null 2>&1 || true
EOF
)"
    if ftctl_blockcopy_secondary_uri_is_local_system; then
      ftctl_cmd_run "${FTCTL_BLOCKCOPY_WAIT_TIMEOUT_SEC}" out err rc -- bash -lc "${stop_cmd}" || true
    else
      ftctl_blockcopy_remote_exec "${host}" "${user}" out err rc "${stop_cmd}" || true
    fi
    : "${out}${err}"
    [[ "${rc}" == "0" ]] || {
      [[ -n "${err}" ]] && echo "ERROR: remote-nbd export stop failed: ${err}" >&2
      return "${rc}"
    }
  done
}

ftctl_blockcopy_wait_remote_nbd_release() {
  local vm="${1-}"
  local records=()
  local record target source dest format job_state ready secondary_dest
  local host user out err rc pid_file export_name export_uri export_port

  ftctl_standby_blockcopy_records "${vm}" records || return 0
  if ! ftctl_blockcopy_secondary_uri_is_local_system; then
    ftctl_blockcopy_remote_target_host_user host user || return 0
  fi

  for record in "${records[@]}"; do
    target=""; source=""; dest=""; format=""; job_state=""; ready=""; secondary_dest=""
    IFS='|' read -r target source dest format job_state ready secondary_dest <<< "${record}"
    pid_file="/run/ablestack-vm-ftctl/nbd-${vm}-${target}.pid"
    export_name="${FTCTL_PROFILE_REMOTE_NBD_EXPORT_NAME}-${target}"
    export_port=""
    if [[ "${dest}" == nbd://* ]]; then
      export_uri="${dest}"
      ftctl_blockcopy_remote_nbd_port_extract_from_uri "${export_uri}" export_port || true
    fi

    out="" err="" rc=0
    local wait_cmd
    wait_cmd="$(cat <<EOF
set -euo pipefail
for _i in \$(seq 1 20); do
  busy=0
  if [[ -f "${pid_file}" ]]; then
    busy=1
  fi
  if [[ -n "${export_port}" ]] && ss -lntp | grep -q ":${export_port}[[:space:]]"; then
    busy=1
  fi
  if [[ -n "${secondary_dest}" && -e "${secondary_dest}" ]]; then
    for lock_pid in \$(fuser "${secondary_dest}" 2>/dev/null || true); do
      [[ -n "\${lock_pid}" ]] || continue
      comm="\$(ps -p "\${lock_pid}" -o comm= 2>/dev/null || true)"
      if [[ "\${comm}" == qemu-nbd* ]]; then
        busy=1
      fi
    done
  fi
  if [[ "\${busy}" == "0" ]]; then
    exit 0
  fi
  sleep 1
done
echo "remote_nbd_release_timeout:${secondary_dest}:${export_port}" >&2
exit 99
EOF
)"
    if ftctl_blockcopy_secondary_uri_is_local_system; then
      ftctl_cmd_run "${FTCTL_BLOCKCOPY_WAIT_TIMEOUT_SEC}" out err rc -- bash -lc "${wait_cmd}" || true
    else
      ftctl_blockcopy_remote_exec "${host}" "${user}" out err rc "${wait_cmd}" || true
    fi
    : "${out}${err}"
    [[ "${rc}" == "0" ]] || {
      [[ -n "${err}" ]] && echo "ERROR: remote-nbd release wait failed: ${err}" >&2
      return "${rc}"
    }
  done
}

ftctl_blockcopy_refresh_and_classify() {
  local vm="${1-}"
  local rc=0
  local last_error=""
  local transport_state=""

  transport_state="$(ftctl_state_get "${vm}" "transport_state" 2>/dev/null || true)"
  if ftctl_blockcopy_promote_stale_reverse_sync "${vm}"; then
    transport_state="reverse_syncing"
  fi
  case "${transport_state}" in
    reverse_syncing|reverse_sync_ready|reverse_sync_cutback_required)
      ftctl_blockcopy_refresh_reverse_jobs "${vm}" || rc=$?
      case "${rc}" in
        0|23)
          return 0
          ;;
        11)
          return 11
          ;;
        21|22)
          return "${rc}"
          ;;
        *)
          last_error="$(ftctl_state_get "${vm}" "last_error" 2>/dev/null || true)"
          if [[ -z "${last_error}" || "${last_error}" == "reverse_sync_pending" ]]; then
            ftctl_state_set "${vm}" \
              "protection_state=error" \
              "transport_state=reverse_sync_failed" \
              "last_error=reverse_sync_refresh_failed"
          fi
          return 12
          ;;
      esac
      ;;
  esac

  ftctl_blockcopy_refresh_vm_jobs "${vm}" || rc=$?
  case "${rc}" in
    0)
      if [[ "$(ftctl_state_get "${vm}" "transport_state" 2>/dev/null || true)" == "mirroring" ]]; then
        return 0
      fi
      return 11
      ;;
    *)
      last_error="$(ftctl_state_get "${vm}" "last_error" 2>/dev/null || true)"
      if [[ "${last_error}" == blockcopy_job_missing:* ]]; then
        return 12
      fi
      ftctl_state_set "${vm}" \
        "protection_state=degraded" \
        "transport_state=lost" \
        "last_error=blockcopy_refresh_failed"
      return 12
      ;;
  esac
}
