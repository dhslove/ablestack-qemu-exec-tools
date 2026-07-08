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

set -euo pipefail

FTCTL_DR_VMWARE_MOVER_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${FTCTL_DR_VMWARE_MOVER_LIB_DIR}/dr_vddk.sh" ]]; then
  # shellcheck source=/dev/null
  source "${FTCTL_DR_VMWARE_MOVER_LIB_DIR}/dr_vddk.sh"
fi

FTCTL_DR_VMWARE_MOVER_LOG_DIR="${FTCTL_DR_VMWARE_MOVER_LOG_DIR:-/run/ablestack-vm-ftctl/dr-runtime/mover}"
FTCTL_DR_VMWARE_NBDKIT_READY_TIMEOUT="${FTCTL_DR_VMWARE_NBDKIT_READY_TIMEOUT:-20}"
FTCTL_DR_VMWARE_QEMU_INFO_TIMEOUT="${FTCTL_DR_VMWARE_QEMU_INFO_TIMEOUT:-20}"
FTCTL_DR_VMWARE_SOURCE_OPEN_TIMEOUT="${FTCTL_DR_VMWARE_SOURCE_OPEN_TIMEOUT:-60}"

ftctl_vmware_mover_die() {
  local rc="${1:-65}"
  shift || true
  printf 'ERROR: %s\n' "$*" >&2
  exit "${rc}"
}

ftctl_vmware_mover_require() {
  command -v "$1" >/dev/null 2>&1 || ftctl_vmware_mover_die "${2:-65}" "required command not found: $1"
}

ftctl_vmware_mover_json_value() {
  local path="${1-}" expr="${2-}" default_value="${3-}"
  [[ -n "${path}" && -f "${path}" ]] || {
    printf '%s\n' "${default_value}"
    return 0
  }
  jq -er "${expr} // empty" "${path}" 2>/dev/null || printf '%s\n' "${default_value}"
}

ftctl_vmware_mover_target_uri() {
  local raw_path="${1-}" target_storage_path="${2-}" target_name="${3-}"
  local pool image
  if [[ -z "${raw_path}" && -n "${target_storage_path}" && -n "${target_name}" ]]; then
    raw_path="${target_storage_path%/}/${target_name}"
  fi
  case "${raw_path}" in
    rbd:*)
      printf '%s\n' "${raw_path}"
      ;;
    /dev/rbd/*/*)
      pool="${raw_path#/dev/rbd/}"
      pool="${pool%%/*}"
      image="${raw_path#/dev/rbd/${pool}/}"
      printf 'rbd:%s/%s\n' "${pool}" "${image}"
      ;;
    rbd/*/*)
      printf 'rbd:%s\n' "${raw_path#rbd/}"
      ;;
    *)
      printf '%s\n' "${raw_path}"
      ;;
  esac
}

ftctl_vmware_mover_qemu_opt_escape() {
  local value="${1-}"
  value="${value//\\/\\\\}"
  value="${value//,/\\,}"
  printf '%s\n' "${value}"
}

ftctl_vmware_mover_source_image_opts() {
  local socket_path="${1-}" escaped_socket
  [[ -n "${socket_path}" ]] || ftctl_vmware_mover_die 72 "DR_VMWARE_MOVER_SOURCE_GRAPH_INVALID: nbd socket path is empty"
  escaped_socket="$(ftctl_vmware_mover_qemu_opt_escape "${socket_path}")"
  printf 'driver=raw,file.driver=nbd,file.server.type=unix,file.server.path=%s\n' "${escaped_socket}"
}

ftctl_vmware_mover_safe_label() {
  local value="${1:-disk}"
  value="${value//[^A-Za-z0-9_.-]/_}"
  [[ -n "${value}" ]] || value="disk"
  printf '%s\n' "${value}"
}

ftctl_vmware_mover_normalize_vcenter_server() {
  local endpoint="${1-}"
  endpoint="${endpoint#https://}"
  endpoint="${endpoint#http://}"
  endpoint="${endpoint%%/sdk}"
  endpoint="${endpoint%%/api}"
  endpoint="${endpoint%%/client/api}"
  endpoint="${endpoint%%/}"
  printf '%s\n' "${endpoint}"
}

ftctl_vmware_mover_govc_url() {
  local endpoint="${1-}"
  if [[ "${endpoint}" != http://* && "${endpoint}" != https://* ]]; then
    endpoint="https://${endpoint}"
  fi
  endpoint="${endpoint%/}"
  [[ "${endpoint}" == */sdk ]] || endpoint="${endpoint}/sdk"
  printf '%s\n' "${endpoint}"
}

ftctl_vmware_mover_resolve_govc_bin() {
  local credentials_file="${1-}" libdir="${2-}" candidate version normalized
  candidate="$(ftctl_vmware_mover_json_value "${credentials_file}" '.credentials.source.govcBin // .credentials.source.govcPath' '')"
  [[ -n "${candidate}" && -x "${candidate}" ]] && {
    printf '%s\n' "${candidate}"
    return 0
  }
  [[ -n "${FTCTL_DR_VMWARE_GOVC_BIN:-}" && -x "${FTCTL_DR_VMWARE_GOVC_BIN}" ]] && {
    printf '%s\n' "${FTCTL_DR_VMWARE_GOVC_BIN}"
    return 0
  }
  if [[ -n "${libdir}" ]]; then
    candidate="$(cd "${libdir}/.." 2>/dev/null && pwd)/bin/govc"
    [[ -x "${candidate}" ]] && {
      printf '%s\n' "${candidate}"
      return 0
    }
  fi
  version="$(ftctl_vmware_mover_json_value "${credentials_file}" '.credentials.source.vddkVersion // .credentials.source.version' '')"
  if [[ -n "${version}" ]]; then
    normalized="${version//./}"
    [[ "${normalized}" == "8" ]] && normalized="80"
    candidate="/usr/share/ablestack/v2k/compat/vsphere${normalized}/bin/govc"
    [[ -x "${candidate}" ]] && {
      printf '%s\n' "${candidate}"
      return 0
    }
  fi
  command -v govc 2>/dev/null || true
}

ftctl_vmware_mover_cleanup_nbdkit() {
  local pid="${1-}" work_dir="${2-}"
  [[ -n "${pid}" ]] && kill "${pid}" 2>/dev/null || true
  [[ -n "${pid}" ]] && wait "${pid}" 2>/dev/null || true
  [[ -n "${work_dir}" ]] && rm -rf "${work_dir}"
}

ftctl_vmware_mover_source_open_die() {
  local rc="${1-}" error_code="${2-}" message="${3-}" vm_ref="${4-}" snapshot_ref="${5-}" source_vmdk="${6-}"
  ftctl_vmware_mover_write_source_open_status false "${error_code}" "${message}" "${vm_ref}" "${snapshot_ref}" "${source_vmdk}"
  ftctl_vmware_mover_die "${rc}" "${error_code}: ${message}"
}

ftctl_vmware_mover_classify_source_open_failure() {
  local label="${1-}" nbdkit_log="${2-}" qemu_log="${3-}" vm_ref="${4-}" snapshot_ref="${5-}" source_vmdk="${6-}" combined
  combined="$(cat "${nbdkit_log}" "${qemu_log}" 2>/dev/null || true)"
  if grep -qi 'DiskLib error 16392\|Failed to lock the file' <<< "${combined}"; then
    ftctl_vmware_mover_source_open_die 75 "DR_VMWARE_VDDK_SOURCE_LOCKED" "source VMDK is locked; create/use a run snapshot for ${label}" "${vm_ref}" "${snapshot_ref}" "${source_vmdk}"
  fi
  if grep -qi 'access rights to this file\|Permission denied' <<< "${combined}"; then
    ftctl_vmware_mover_source_open_die 76 "DR_VMWARE_VDDK_OPEN_DENIED" "VDDK cannot open the requested VMDK path for ${label}" "${vm_ref}" "${snapshot_ref}" "${source_vmdk}"
  fi
  if grep -qi 'VixDiskLib_ConnectEx' <<< "${combined}"; then
    ftctl_vmware_mover_source_open_die 73 "DR_VMWARE_VDDK_CONNECT_INVALID" "VDDK rejected source connection parameters for ${label}" "${vm_ref}" "${snapshot_ref}" "${source_vmdk}"
  fi
  if grep -qi 'Requested export not available' <<< "${combined}"; then
    ftctl_vmware_mover_source_open_die 74 "DR_VMWARE_VDDK_EXPORT_UNAVAILABLE" "VDDK NBD export is unavailable for ${label}" "${vm_ref}" "${snapshot_ref}" "${source_vmdk}"
  fi
  ftctl_vmware_mover_source_open_die 72 "DR_VMWARE_MOVER_SOURCE_GRAPH_INVALID" "qemu-img cannot open VDDK NBD source for ${label}" "${vm_ref}" "${snapshot_ref}" "${source_vmdk}"
}

ftctl_vmware_mover_disk_plan() {
  local vmware_map="${1-}" target_map="${2-}"
  python3 - "${vmware_map}" "${target_map}" <<'PY'
import json
import os
import sys

vmware_path, target_path = sys.argv[1:3]

def load(path):
    if not path or not os.path.exists(path):
        return {}
    with open(path, "r", encoding="utf-8") as fh:
        return json.load(fh)

def text(value):
    if value is None or isinstance(value, (dict, list)):
        return ""
    return str(value).strip()

def first(*values):
    for value in values:
        value = text(value)
        if value:
            return value
    return ""

def item_at(items, index):
    if isinstance(items, list) and index < len(items) and isinstance(items[index], dict):
        return items[index]
    return {}

vmware = load(vmware_path)
target = load(target_path)
source_disks = vmware.get("disks") if isinstance(vmware.get("disks"), list) else []
target_disks = target.get("disks") if isinstance(target.get("disks"), list) else []
count = max(len(source_disks), len(target_disks))
rows = []
for index in range(count):
    source = item_at(source_disks, index)
    dest = item_at(target_disks, index)
    rows.append({
        "index": index,
        "label": first(source.get("device"), source.get("label"), dest.get("device"), dest.get("label"), f"disk{index}"),
        "sourceVmdk": first(source.get("sourceOpenVmdk"), source.get("sourceOpenVmdkPath"), source.get("sourceVmdkPath"), source.get("sourceDiskRef"), source.get("sourcePath")),
        "sourceVmRef": first(source.get("sourceVmRef"), vmware.get("sourceVmRef")),
        "sourceSnapshotRef": first(source.get("sourceSnapshotRef"), source.get("snapshotRef"), source.get("snapshot"), vmware.get("sourceSnapshotRef")),
        "targetPath": first(dest.get("targetPath"), source.get("targetPath"), source.get("targetDiskRef"), source.get("targetVmdkPath")),
        "targetName": first(dest.get("targetName"), source.get("targetName"), source.get("targetDiskRef")),
        "targetStoragePath": first(dest.get("targetStoragePath"), target.get("target", {}).get("storagePath") if isinstance(target.get("target"), dict) else ""),
        "targetFormat": first(dest.get("targetFormat"), source.get("targetFormat"), "raw").lower(),
    })
print(json.dumps(rows, sort_keys=True, separators=(",", ":")))
PY
}

ftctl_vmware_mover_wait_for_socket() {
  local socket_path="${1-}" pid="${2-}" deadline="${3-}"
  local waited=0
  while [[ "${waited}" -lt "${deadline}" ]]; do
    [[ -S "${socket_path}" ]] && return 0
    if ! kill -0 "${pid}" 2>/dev/null; then
      return 1
    fi
    sleep 1
    waited=$((waited + 1))
  done
  return 1
}

ftctl_vmware_mover_write_source_open_status() {
  local path="${FTCTL_DR_SOURCE_OPEN_STATUS_PATH:-}" ready="${1-}" error_code="${2-}" message="${3-}" vm_ref="${4-}" snapshot_ref="${5-}" source_vmdk="${6-}"
  [[ -n "${path}" ]] || return 0
  mkdir -p "$(dirname "${path}")"
  python3 - "${path}" "${ready}" "${error_code}" "${message}" "${vm_ref}" "${snapshot_ref}" "${source_vmdk}" <<'PY'
import json
import os
import sys

path, ready, error_code, message, vm_ref, snapshot_ref, source_vmdk = sys.argv[1:8]
data = {
    "checked": True,
    "ready": str(ready).lower() == "true",
    "error_code": error_code,
    "message": message,
    "vmRef": vm_ref,
    "snapshotRefPresent": bool(snapshot_ref),
    "sourceVmdkPathPresent": bool(source_vmdk),
}
tmp = path + ".tmp"
with open(tmp, "w", encoding="utf-8") as fh:
    json.dump(data, fh, sort_keys=True, separators=(",", ":"))
    fh.write("\n")
os.replace(tmp, path)
PY
}

ftctl_vmware_mover_convert_disk() {
  local source_vmdk="${1-}" source_vm_ref="${2-}" source_snapshot_ref="${3-}" target_uri="${4-}" target_format="${5-}" label="${6-}"
  local endpoint="${7-}" username="${8-}" password_file="${9-}" tls_verify="${10-}" thumbprint="${11-}" libdir="${12-}"
  local work_dir socket_path pid="" source_opts safe_label nbdkit_log qemu_info_log transports

  [[ -n "${source_vmdk}" ]] || ftctl_vmware_mover_die 65 "source VMDK path is empty for ${label}"
  [[ -n "${target_uri}" ]] || ftctl_vmware_mover_die 65 "target disk path is empty for ${label}"
  [[ -n "${endpoint}" ]] || ftctl_vmware_mover_die 65 "vCenter endpoint is empty"
  [[ -n "${username}" ]] || ftctl_vmware_mover_die 65 "vCenter username is empty"
  [[ -s "${password_file}" ]] || ftctl_vmware_mover_die 65 "vCenter password file is empty"
  [[ -n "${source_vm_ref}" ]] || ftctl_vmware_mover_source_open_die 73 "DR_VMWARE_VDDK_CONNECT_INVALID" "source VM reference is empty for ${label}" "${source_vm_ref}" "${source_snapshot_ref}" "${source_vmdk}"

  if [[ "${FTCTL_DR_VMWARE_MOVER_DRY_RUN:-0}" == "1" ]]; then
    printf 'DRY-RUN: %s snapshot=%s -> %s\n' "${source_vmdk}" "${source_snapshot_ref:-none}" "${target_uri}" >&2
    return 0
  fi

  endpoint="$(ftctl_vmware_mover_normalize_vcenter_server "${endpoint}")"
  work_dir="$(mktemp -d -t ftctl.vmware.mover.XXXXXX)"
  socket_path="${work_dir}/vddk.sock"
  safe_label="$(ftctl_vmware_mover_safe_label "${label}")"
  nbdkit_log="${FTCTL_DR_VMWARE_MOVER_LOG_DIR}/nbdkit-${safe_label}.log"
  qemu_info_log="${FTCTL_DR_VMWARE_MOVER_LOG_DIR}/qemu-img-info-${safe_label}.log"
  transports="${FTCTL_DR_VMWARE_VDDK_TRANSPORTS:-nbd:nbdssl}"
  local nbdkit_args=(
    --exit-with-parent
    --foreground
    --unix "${socket_path}"
    -r
    vddk
    "server=${endpoint}"
    "user=${username}"
    "password=+${password_file}"
    "file=${source_vmdk}"
    "single-link=true"
  )
  [[ -n "${source_vm_ref}" ]] && nbdkit_args+=("vm=moref=${source_vm_ref}")
  [[ -n "${source_snapshot_ref}" ]] && nbdkit_args+=("snapshot=${source_snapshot_ref}")
  [[ -n "${transports}" ]] && nbdkit_args+=("transports=${transports}")
  [[ -n "${thumbprint}" && "${tls_verify}" != "true" ]] && nbdkit_args+=("thumbprint=${thumbprint}")
  [[ -n "${libdir}" && -d "${libdir}" ]] && nbdkit_args+=("libdir=${libdir}")

  nbdkit "${nbdkit_args[@]}" >"${nbdkit_log}" 2>&1 &
  pid=$!
  if ! ftctl_vmware_mover_wait_for_socket "${socket_path}" "${pid}" "${FTCTL_DR_VMWARE_NBDKIT_READY_TIMEOUT}"; then
    ftctl_vmware_mover_cleanup_nbdkit "${pid}" "${work_dir}"
    ftctl_vmware_mover_classify_source_open_failure "${label}" "${nbdkit_log}" "${qemu_info_log}" "${source_vm_ref}" "${source_snapshot_ref}" "${source_vmdk}"
  fi

  source_opts="$(ftctl_vmware_mover_source_image_opts "${socket_path}")"
  if command -v timeout >/dev/null 2>&1; then
    if ! timeout "${FTCTL_DR_VMWARE_QEMU_INFO_TIMEOUT}" qemu-img info --force-share --image-opts "${source_opts}" >/dev/null 2>"${qemu_info_log}"; then
      ftctl_vmware_mover_cleanup_nbdkit "${pid}" "${work_dir}"
      ftctl_vmware_mover_classify_source_open_failure "${label}" "${nbdkit_log}" "${qemu_info_log}" "${source_vm_ref}" "${source_snapshot_ref}" "${source_vmdk}"
    fi
  elif ! qemu-img info --force-share --image-opts "${source_opts}" >/dev/null 2>"${qemu_info_log}"; then
    ftctl_vmware_mover_cleanup_nbdkit "${pid}" "${work_dir}"
    ftctl_vmware_mover_classify_source_open_failure "${label}" "${nbdkit_log}" "${qemu_info_log}" "${source_vm_ref}" "${source_snapshot_ref}" "${source_vmdk}"
  fi
  ftctl_vmware_mover_write_source_open_status true "" "VDDK source open preflight succeeded" "${source_vm_ref}" "${source_snapshot_ref}" "${source_vmdk}"

  if ! qemu-img convert --force-share -p -n --image-opts -O "${target_format:-raw}" "${source_opts}" "${target_uri}"; then
    ftctl_vmware_mover_cleanup_nbdkit "${pid}" "${work_dir}"
    ftctl_vmware_mover_die 68 "qemu-img conversion failed for ${label}"
  fi

  ftctl_vmware_mover_cleanup_nbdkit "${pid}" "${work_dir}"
}

ftctl_vmware_mover_snapshot_ref_from_tree() {
  local json_path="${1-}" snapshot_name="${2-}"
  python3 - "${json_path}" "${snapshot_name}" <<'PY'
import json
import sys

path, name = sys.argv[1:3]
with open(path, "r", encoding="utf-8") as fh:
    data = json.load(fh)

def text(value):
    if value is None:
        return ""
    if isinstance(value, (dict, list)):
        return ""
    return str(value)

def ref_value(value):
    if isinstance(value, str):
        return value
    if isinstance(value, dict):
        for key in ("Value", "value", "MoRef", "moRef", "moid", "id"):
            result = text(value.get(key))
            if result:
                return result
    return ""

def walk(value):
    if isinstance(value, dict):
        node_name = text(value.get("Name") or value.get("name"))
        if node_name == name:
            result = ref_value(value.get("Snapshot") or value.get("snapshot"))
            if result:
                return result
        for child in value.values():
            result = walk(child)
            if result:
                return result
    elif isinstance(value, list):
        for child in value:
            result = walk(child)
            if result:
                return result
    return ""

result = walk(data)
if result:
    print(result)
    sys.exit(0)
sys.exit(1)
PY
}

ftctl_vmware_mover_create_run_snapshot() {
  local govc_bin="${1-}" endpoint="${2-}" username="${3-}" password_file="${4-}" tls_verify="${5-}" source_vm_ref="${6-}" snapshot_name="${7-}"
  local snapshot_tree snapshot_ref
  [[ -x "${govc_bin}" ]] || return 1
  [[ -n "${source_vm_ref}" && -n "${snapshot_name}" ]] || return 1
  snapshot_tree="$(mktemp -p "${FTCTL_DR_VMWARE_MOVER_LOG_DIR}" vmware-snapshot-tree.XXXXXX.json)"
  GOVC_URL="$(ftctl_vmware_mover_govc_url "${endpoint}")" \
  GOVC_USERNAME="${username}" \
  GOVC_PASSWORD="$(cat "${password_file}")" \
  GOVC_INSECURE="$([[ "${tls_verify}" == "true" ]] && printf 'false' || printf 'true')" \
    "${govc_bin}" snapshot.create -vm "${source_vm_ref}" -m=false -q=false "${snapshot_name}" >/dev/null
  GOVC_URL="$(ftctl_vmware_mover_govc_url "${endpoint}")" \
  GOVC_USERNAME="${username}" \
  GOVC_PASSWORD="$(cat "${password_file}")" \
  GOVC_INSECURE="$([[ "${tls_verify}" == "true" ]] && printf 'false' || printf 'true')" \
    "${govc_bin}" snapshot.tree -vm "${source_vm_ref}" -json > "${snapshot_tree}"
  snapshot_ref="$(ftctl_vmware_mover_snapshot_ref_from_tree "${snapshot_tree}" "${snapshot_name}" || true)"
  rm -f "${snapshot_tree}"
  [[ -n "${snapshot_ref}" ]] || return 1
  printf '%s\n' "${snapshot_ref}"
}

ftctl_vmware_mover_remove_run_snapshot() {
  local govc_bin="${1-}" endpoint="${2-}" username="${3-}" password_file="${4-}" tls_verify="${5-}" source_vm_ref="${6-}" snapshot_name="${7-}"
  [[ -x "${govc_bin}" && -n "${source_vm_ref}" && -n "${snapshot_name}" ]] || return 0
  [[ -s "${password_file}" ]] || return 0
  GOVC_URL="$(ftctl_vmware_mover_govc_url "${endpoint}")" \
  GOVC_USERNAME="${username}" \
  GOVC_PASSWORD="$(cat "${password_file}")" \
  GOVC_INSECURE="$([[ "${tls_verify}" == "true" ]] && printf 'false' || printf 'true')" \
    "${govc_bin}" snapshot.remove -vm "${source_vm_ref}" "${snapshot_name}" >/dev/null 2>&1 || true
}

ftctl_vmware_mover_cleanup() {
  if [[ "${FTCTL_DR_VMWARE_RUN_SNAPSHOT_CREATED:-false}" == "true" ]]; then
    ftctl_vmware_mover_remove_run_snapshot \
      "${FTCTL_DR_VMWARE_GOVC_BIN_EFFECTIVE:-}" \
      "${FTCTL_DR_VMWARE_ENDPOINT_EFFECTIVE:-}" \
      "${FTCTL_DR_VMWARE_USERNAME_EFFECTIVE:-}" \
      "${FTCTL_DR_VMWARE_PASSWORD_FILE:-}" \
      "${FTCTL_DR_VMWARE_TLS_VERIFY_EFFECTIVE:-false}" \
      "${FTCTL_DR_VMWARE_SOURCE_VM_REF_EFFECTIVE:-}" \
      "${FTCTL_DR_VMWARE_RUN_SNAPSHOT_NAME:-}"
  fi
  rm -f "${FTCTL_DR_VMWARE_PASSWORD_FILE:-}"
}

main() {
  local disk_map="${FTCTL_DR_DISK_MAP:-}" target_disk_map="${FTCTL_DR_TARGET_DISK_MAP:-}" credentials_file="${FTCTL_DR_CREDENTIALS_FILE:-}"
  local endpoint username password tls_verify thumbprint libdir plan_json password_file rows row count i
  local govc_bin source_vm_ref_for_snapshot snapshot_name snapshot_ref snapshot_created="false"

  [[ -n "${disk_map}" && -f "${disk_map}" ]] || ftctl_vmware_mover_die 65 "FTCTL_DR_DISK_MAP is required"
  [[ -n "${credentials_file}" && -f "${credentials_file}" ]] || ftctl_vmware_mover_die 65 "FTCTL_DR_CREDENTIALS_FILE is required"
  ftctl_vmware_mover_require jq 65
  ftctl_vmware_mover_require python3 65
  ftctl_vmware_mover_require nbdkit 65
  ftctl_vmware_mover_require qemu-img 65

  endpoint="$(ftctl_vmware_mover_json_value "${credentials_file}" '.credentials.source.endpoint' '')"
  endpoint="$(ftctl_vmware_mover_normalize_vcenter_server "${endpoint}")"
  username="$(ftctl_vmware_mover_json_value "${credentials_file}" '.credentials.source.principal // .credentials.source.username' '')"
  password="$(ftctl_vmware_mover_json_value "${credentials_file}" '.credentials.source.auth.password // .credentials.source.password' '')"
  tls_verify="$(ftctl_vmware_mover_json_value "${credentials_file}" '.credentials.source.tlsVerify' 'false')"
  thumbprint="$(ftctl_vmware_mover_json_value "${credentials_file}" '.credentials.source.thumbprint // .credentials.source.tlsThumbprint' '')"
  if command -v ftctl_dr_vddk_resolve_libdir >/dev/null 2>&1; then
    libdir="$(ftctl_dr_vddk_resolve_libdir "${credentials_file}" 2>/dev/null || true)"
  else
    libdir="$(ftctl_vmware_mover_json_value "${credentials_file}" '.credentials.source.vddkLibdir // .credentials.source.libdir' '')"
  fi

  [[ -n "${password}" ]] || ftctl_vmware_mover_die 65 "source credential password is empty"
  [[ -n "${libdir}" ]] || ftctl_vmware_mover_die 70 "DR_VDDK_LIBDIR_UNRESOLVED: usable VDDK library directory was not found"
  if command -v ftctl_dr_vddk_nbdkit_loads >/dev/null 2>&1 && ! ftctl_dr_vddk_nbdkit_loads "${libdir}"; then
    ftctl_vmware_mover_die 71 "DR_VDDK_LIBRARY_LOAD_FAILED: nbdkit cannot load VDDK library directory ${libdir}"
  fi
  mkdir -p "${FTCTL_DR_VMWARE_MOVER_LOG_DIR}"
  password_file="$(mktemp -p "${FTCTL_DR_VMWARE_MOVER_LOG_DIR}" vmware-password.XXXXXX)"
  chmod 0600 "${password_file}"
  printf '%s' "${password}" > "${password_file}"
  FTCTL_DR_VMWARE_PASSWORD_FILE="${password_file}"
  FTCTL_DR_VMWARE_ENDPOINT_EFFECTIVE="${endpoint}"
  FTCTL_DR_VMWARE_USERNAME_EFFECTIVE="${username}"
  FTCTL_DR_VMWARE_TLS_VERIFY_EFFECTIVE="${tls_verify}"
  FTCTL_DR_VMWARE_RUN_SNAPSHOT_CREATED="false"
  trap 'ftctl_vmware_mover_cleanup' EXIT

  rows="$(ftctl_vmware_mover_disk_plan "${disk_map}" "${target_disk_map}")"
  count="$(jq 'length' <<< "${rows}")"
  [[ "${count}" =~ ^[1-9][0-9]*$ ]] || ftctl_vmware_mover_die 65 "no VMware disk rows to move"
  snapshot_ref="$(jq -r '[.[].sourceSnapshotRef // ""] | map(select(. != "")) | .[0] // ""' <<< "${rows}")"
  source_vm_ref_for_snapshot="$(jq -r '[.[].sourceVmRef // ""] | map(select(. != "")) | .[0] // ""' <<< "${rows}")"
  if [[ -z "${snapshot_ref}" && -n "${source_vm_ref_for_snapshot}" && "${FTCTL_DR_VMWARE_CREATE_RUN_SNAPSHOT:-1}" == "1" ]]; then
    govc_bin="$(ftctl_vmware_mover_resolve_govc_bin "${credentials_file}" "${libdir}")"
    [[ -n "${govc_bin}" ]] || ftctl_vmware_mover_die 73 "DR_VMWARE_VDDK_CONNECT_INVALID: govc binary is required to create VMware source snapshot"
    snapshot_name="ftctl-dr-${FTCTL_DR_RUN_UUID:-$(date +%s)}-source"
    snapshot_ref="$(ftctl_vmware_mover_create_run_snapshot "${govc_bin}" "${endpoint}" "${username}" "${password_file}" "${tls_verify}" "${source_vm_ref_for_snapshot}" "${snapshot_name}")" \
      || ftctl_vmware_mover_die 73 "DR_VMWARE_VDDK_CONNECT_INVALID: failed to create or resolve VMware source snapshot"
    snapshot_created="true"
    FTCTL_DR_VMWARE_GOVC_BIN_EFFECTIVE="${govc_bin}"
    FTCTL_DR_VMWARE_SOURCE_VM_REF_EFFECTIVE="${source_vm_ref_for_snapshot}"
    FTCTL_DR_VMWARE_RUN_SNAPSHOT_NAME="${snapshot_name}"
    FTCTL_DR_VMWARE_RUN_SNAPSHOT_REF="${snapshot_ref}"
    FTCTL_DR_VMWARE_RUN_SNAPSHOT_CREATED="true"
  fi

  i=0
  while [[ "${i}" -lt "${count}" ]]; do
    row="$(jq -c ".[$i]" <<< "${rows}")"
    local label source_vmdk source_vm_ref source_snapshot_ref target_path target_name target_storage_path target_uri target_format
    label="$(jq -r '.label // ""' <<< "${row}")"
    source_vmdk="$(jq -r '.sourceVmdk // ""' <<< "${row}")"
    source_vm_ref="$(jq -r '.sourceVmRef // ""' <<< "${row}")"
    source_snapshot_ref="$(jq -r '.sourceSnapshotRef // ""' <<< "${row}")"
    [[ -n "${source_snapshot_ref}" ]] || source_snapshot_ref="${snapshot_ref}"
    target_path="$(jq -r '.targetPath // ""' <<< "${row}")"
    target_name="$(jq -r '.targetName // ""' <<< "${row}")"
    target_storage_path="$(jq -r '.targetStoragePath // ""' <<< "${row}")"
    target_uri="$(ftctl_vmware_mover_target_uri "${target_path}" "${target_storage_path}" "${target_name}")"
    target_format="$(jq -r '.targetFormat // "raw"' <<< "${row}")"
    printf 'VMware DR mover: %s snapshot=%s -> %s\n' "${source_vmdk}" "${source_snapshot_ref:-none}" "${target_uri}" >&2
    ftctl_vmware_mover_convert_disk "${source_vmdk}" "${source_vm_ref}" "${source_snapshot_ref}" "${target_uri}" "${target_format:-raw}" "${label:-disk${i}}" \
      "${endpoint}" "${username}" "${password_file}" "${tls_verify}" "${thumbprint}" "${libdir}"
    i=$((i + 1))
  done
}

main "$@"
