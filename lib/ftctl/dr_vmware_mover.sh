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
FTCTL_DR_VMWARE_LAST_SNAPSHOT_REF=""
FTCTL_DR_VMWARE_LAST_SNAPSHOT_RESOLVE_METHOD=""
FTCTL_DR_VMWARE_SOURCE_OPEN_TLS_VERIFY=""
FTCTL_DR_VMWARE_SOURCE_OPEN_THUMBPRINT_PRESENT=""
FTCTL_DR_VMWARE_SOURCE_OPEN_THUMBPRINT_SOURCE=""

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

ftctl_vmware_mover_resolve_cbt_python() {
  local libdir="${1-}" compat_root candidate
  if [[ -n "${FTCTL_DR_VMWARE_CBT_PYTHON:-}" && -x "${FTCTL_DR_VMWARE_CBT_PYTHON}" ]]; then
    printf '%s\n' "${FTCTL_DR_VMWARE_CBT_PYTHON}"
    return 0
  fi
  if [[ -n "${libdir}" ]]; then
    compat_root="$(cd "${libdir}/.." 2>/dev/null && pwd || true)"
    for candidate in "${compat_root}/venv/bin/python" "${compat_root}/venv/bin/python3"; do
      [[ -x "${candidate}" ]] || continue
      "${candidate}" -c 'import pyVmomi' >/dev/null 2>&1 || continue
      printf '%s\n' "${candidate}"
      return 0
    done
  fi
  if python3 -c 'import pyVmomi' >/dev/null 2>&1; then
    command -v python3
    return 0
  fi
  return 1
}

ftctl_vmware_mover_query_cbt() {
  local endpoint="${1-}" username="${2-}" password_file="${3-}" tls_verify="${4-}" libdir="${5-}"
  local vm_ref="${6-}" snapshot_name="${7-}" disk_id="${8-}" previous_change_id="${9-}" output_path="${10-}"
  local python_bin helper
  python_bin="$(ftctl_vmware_mover_resolve_cbt_python "${libdir}" || true)"
  helper="${FTCTL_DR_VMWARE_CBT_QUERY_HELPER:-${FTCTL_DR_VMWARE_MOVER_LIB_DIR}/dr_vmware_changed_areas.py}"
  [[ -n "${python_bin}" ]] || ftctl_vmware_mover_die 82 "DR_CBT_QUERY_FAILED: pyVmomi runtime was not found"
  [[ -f "${helper}" ]] || ftctl_vmware_mover_die 82 "DR_CBT_QUERY_FAILED: CBT query helper was not found"
  [[ -n "${vm_ref}" && -n "${snapshot_name}" && -n "${disk_id}" ]] || \
    ftctl_vmware_mover_die 80 "DR_VMWARE_CBT_DISK_ID_UNRESOLVED: VM, snapshot, or disk identifier is empty"
  VCENTER_HOST="$(ftctl_vmware_mover_govc_url "${endpoint}")" \
  VCENTER_USER="${username}" \
  VCENTER_PASS="$(cat "${password_file}")" \
  VCENTER_INSECURE="$([[ "${tls_verify}" == "true" ]] && printf 0 || printf 1)" \
    "${python_bin}" "${helper}" --vm "${vm_ref}" --snapshot "${snapshot_name}" \
      --disk-id "${disk_id}" --change-id "${previous_change_id}" > "${output_path}" || \
    ftctl_vmware_mover_die 82 "DR_CBT_QUERY_FAILED: QueryChangedDiskAreas failed for ${disk_id}"
  jq -e '.new_change_id != null and .new_change_id != ""' "${output_path}" >/dev/null || \
    ftctl_vmware_mover_die 83 "DR_CBT_BASELINE_INVALID: VMware did not return a new changeId for ${disk_id}"
}

ftctl_vmware_mover_free_nbd() {
  local excluded="${1-}" dev name
  modprobe nbd max_part=16 >/dev/null 2>&1 || true
  for dev in /dev/nbd{0..31}; do
    [[ -b "${dev}" && "${dev}" != "${excluded}" ]] || continue
    name="${dev#/dev/}"
    if [[ ! -s "/sys/class/block/${name}/pid" ]]; then
      printf '%s\n' "${dev}"
      return 0
    fi
  done
  return 1
}

ftctl_vmware_mover_patch_disk() {
  local source_vmdk="${1-}" source_vm_ref="${2-}" source_snapshot_ref="${3-}" target_uri="${4-}" target_format="${5-}" label="${6-}"
  local endpoint="${7-}" username="${8-}" password_file="${9-}" tls_verify="${10-}" thumbprint="${11-}" libdir="${12-}"
  local areas_path="${13-}" metrics_path="${14-}" work_dir socket_path pid="" source_opts safe_label nbdkit_log qemu_info_log transports
  local source_dev="" target_dev="" patch_helper lock_file="${FTCTL_DR_VMWARE_NBD_LOCK:-/run/ablestack-vm-ftctl/dr-runtime/nbd.lock}"

  [[ -s "${areas_path}" ]] || ftctl_vmware_mover_die 84 "DR_CBT_EXTENT_INVALID: changed-area payload is missing for ${label}"
  work_dir="$(mktemp -d -t ftctl.vmware.patch.XXXXXX)"
  socket_path="${work_dir}/vddk.sock"
  safe_label="$(ftctl_vmware_mover_safe_label "${label}")"
  nbdkit_log="${FTCTL_DR_VMWARE_MOVER_LOG_DIR}/nbdkit-patch-${safe_label}.log"
  qemu_info_log="${FTCTL_DR_VMWARE_MOVER_LOG_DIR}/qemu-img-patch-info-${safe_label}.log"
  transports="${FTCTL_DR_VMWARE_VDDK_TRANSPORTS:-nbd:nbdssl}"
  endpoint="$(ftctl_vmware_mover_normalize_vcenter_server "${endpoint}")"
  if [[ "${tls_verify}" != "true" ]]; then
    thumbprint="$(ftctl_vmware_mover_resolve_thumbprint "${endpoint}" "${tls_verify}" "${thumbprint}" || true)"
    [[ -n "${thumbprint}" ]] || ftctl_vmware_mover_die 77 "DR_VMWARE_VDDK_THUMBPRINT_UNRESOLVED: thumbprint is missing for ${label}"
  fi
  local nbdkit_args=(--exit-with-parent --foreground --unix "${socket_path}" -r vddk
    "server=${endpoint}" "user=${username}" "password=+${password_file}" "file=${source_vmdk}" "single-link=true")
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
  qemu-img info --force-share --image-opts "${source_opts}" >/dev/null 2>"${qemu_info_log}" || {
    ftctl_vmware_mover_cleanup_nbdkit "${pid}" "${work_dir}"
    ftctl_vmware_mover_classify_source_open_failure "${label}" "${nbdkit_log}" "${qemu_info_log}" "${source_vm_ref}" "${source_snapshot_ref}" "${source_vmdk}"
  }

  mkdir -p "$(dirname "${lock_file}")"
  exec 9>"${lock_file}"
  flock -x 9
  source_dev="$(ftctl_vmware_mover_free_nbd || true)"
  if [[ -z "${source_dev}" ]]; then
    flock -u 9
    ftctl_vmware_mover_cleanup_nbdkit "${pid}" "${work_dir}"
    ftctl_vmware_mover_die 86 "DR_CBT_PATCH_FAILED: no free source NBD device"
  fi
  if ! nbd-client -u -N default "${socket_path}" "${source_dev}" >/dev/null; then
    flock -u 9
    ftctl_vmware_mover_cleanup_nbdkit "${pid}" "${work_dir}"
    ftctl_vmware_mover_die 86 "DR_CBT_PATCH_FAILED: source NBD attach failed"
  fi
  target_dev="$(ftctl_vmware_mover_free_nbd "${source_dev}" || true)"
  if [[ -z "${target_dev}" ]]; then
    nbd-client -d "${source_dev}" >/dev/null 2>&1 || true
    flock -u 9
    ftctl_vmware_mover_cleanup_nbdkit "${pid}" "${work_dir}"
    ftctl_vmware_mover_die 86 "DR_CBT_PATCH_FAILED: no free target NBD device"
  fi
  if ! qemu-nbd --connect="${target_dev}" --format="${target_format:-raw}" "${target_uri}" >/dev/null; then
    nbd-client -d "${source_dev}" >/dev/null 2>&1 || true
    flock -u 9
    ftctl_vmware_mover_cleanup_nbdkit "${pid}" "${work_dir}"
    ftctl_vmware_mover_die 86 "DR_CBT_PATCH_FAILED: target NBD attach failed"
  fi
  flock -u 9

  patch_helper="${FTCTL_DR_VMWARE_EXTENT_PATCH_HELPER:-${FTCTL_DR_VMWARE_MOVER_LIB_DIR}/dr_extent_patch.py}"
  if ! python3 "${patch_helper}" --source "${source_dev}" --target "${target_dev}" --areas-json "${areas_path}" > "${metrics_path}"; then
    qemu-nbd --disconnect "${target_dev}" >/dev/null 2>&1 || true
    nbd-client -d "${source_dev}" >/dev/null 2>&1 || true
    ftctl_vmware_mover_cleanup_nbdkit "${pid}" "${work_dir}"
    ftctl_vmware_mover_die 86 "DR_CBT_PATCH_FAILED: extent apply failed for ${label}"
  fi
  blockdev --flushbufs "${target_dev}" >/dev/null 2>&1 || true
  qemu-nbd --disconnect "${target_dev}" >/dev/null 2>&1 || true
  nbd-client -d "${source_dev}" >/dev/null 2>&1 || true
  ftctl_vmware_mover_cleanup_nbdkit "${pid}" "${work_dir}"
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

ftctl_vmware_mover_endpoint_connect_target() {
  local endpoint="${1-}"
  endpoint="$(ftctl_vmware_mover_normalize_vcenter_server "${endpoint}")"
  endpoint="${endpoint%%/*}"
  if [[ "${endpoint}" == *:* ]]; then
    printf '%s\n' "${endpoint}"
  else
    printf '%s:443\n' "${endpoint}"
  fi
}

ftctl_vmware_mover_fetch_vcenter_thumbprint() {
  local endpoint="${1-}" connect_target fingerprint
  connect_target="$(ftctl_vmware_mover_endpoint_connect_target "${endpoint}")"
  [[ -n "${connect_target}" ]] || return 1
  if command -v timeout >/dev/null 2>&1; then
    fingerprint="$(timeout 15 openssl s_client -connect "${connect_target}" </dev/null 2>/dev/null \
      | openssl x509 -fingerprint -sha1 -noout 2>/dev/null \
      | sed -n 's/^.*Fingerprint=//Ip' \
      | head -n 1 \
      | tr '[:lower:]' '[:upper:]')" || true
  else
    fingerprint="$(openssl s_client -connect "${connect_target}" </dev/null 2>/dev/null \
      | openssl x509 -fingerprint -sha1 -noout 2>/dev/null \
      | sed -n 's/^.*Fingerprint=//Ip' \
      | head -n 1 \
      | tr '[:lower:]' '[:upper:]')" || true
  fi
  [[ -n "${fingerprint}" ]] || return 1
  printf '%s\n' "${fingerprint}"
}

ftctl_vmware_mover_resolve_thumbprint() {
  local endpoint="${1-}" tls_verify="${2-}" configured="${3-}" fetched
  FTCTL_DR_VMWARE_SOURCE_OPEN_TLS_VERIFY="${tls_verify}"
  FTCTL_DR_VMWARE_SOURCE_OPEN_THUMBPRINT_PRESENT="false"
  FTCTL_DR_VMWARE_SOURCE_OPEN_THUMBPRINT_SOURCE="missing"
  [[ "${tls_verify}" == "true" ]] && {
    FTCTL_DR_VMWARE_SOURCE_OPEN_THUMBPRINT_SOURCE="tls-verify"
    return 0
  }
  if [[ -n "${configured}" ]]; then
    FTCTL_DR_VMWARE_SOURCE_OPEN_THUMBPRINT_PRESENT="true"
    FTCTL_DR_VMWARE_SOURCE_OPEN_THUMBPRINT_SOURCE="runtime"
    printf '%s\n' "${configured}"
    return 0
  fi
  fetched="$(ftctl_vmware_mover_fetch_vcenter_thumbprint "${endpoint}" || true)"
  [[ -n "${fetched}" ]] || return 1
  FTCTL_DR_VMWARE_SOURCE_OPEN_THUMBPRINT_PRESENT="true"
  FTCTL_DR_VMWARE_SOURCE_OPEN_THUMBPRINT_SOURCE="host-auto"
  printf '%s\n' "${fetched}"
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
        "sourceSnapshotName": first(source.get("sourceSnapshotName"), source.get("snapshotName"), vmware.get("sourceSnapshotName")),
        "cbtDiskId": first(source.get("cbtDiskId"), source.get("sourceDiskKey"), source.get("device")),
        "previousChangeId": first(source.get("changeId"), source.get("cbtChangeId")),
        "virtualBytes": first(source.get("sizeBytes"), dest.get("sizeBytes")),
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
  local tls_verify="${FTCTL_DR_VMWARE_SOURCE_OPEN_TLS_VERIFY:-}" thumbprint_present="${FTCTL_DR_VMWARE_SOURCE_OPEN_THUMBPRINT_PRESENT:-}" thumbprint_source="${FTCTL_DR_VMWARE_SOURCE_OPEN_THUMBPRINT_SOURCE:-}"
  [[ -n "${path}" ]] || return 0
  mkdir -p "$(dirname "${path}")"
  python3 - "${path}" "${ready}" "${error_code}" "${message}" "${vm_ref}" "${snapshot_ref}" "${source_vmdk}" "${tls_verify}" "${thumbprint_present}" "${thumbprint_source}" <<'PY'
import json
import os
import sys

path, ready, error_code, message, vm_ref, snapshot_ref, source_vmdk, tls_verify, thumbprint_present, thumbprint_source = sys.argv[1:11]
data = {
    "checked": True,
    "ready": str(ready).lower() == "true",
    "error_code": error_code,
    "message": message,
    "vmRef": vm_ref,
    "snapshotRefPresent": bool(snapshot_ref),
    "sourceVmdkPathPresent": bool(source_vmdk),
}
if tls_verify:
    data["tlsVerify"] = str(tls_verify).lower() == "true"
if thumbprint_present:
    data["thumbprintPresent"] = str(thumbprint_present).lower() == "true"
if thumbprint_source:
    data["thumbprintSource"] = thumbprint_source
tmp = path + ".tmp"
with open(tmp, "w", encoding="utf-8") as fh:
    json.dump(data, fh, sort_keys=True, separators=(",", ":"))
    fh.write("\n")
os.replace(tmp, path)
PY
}

ftctl_vmware_mover_write_source_snapshot_status() {
  local path="${FTCTL_DR_SOURCE_SNAPSHOT_STATUS_PATH:-}" ready="${1-}" error_code="${2-}" message="${3-}" vm_ref="${4-}" snapshot_name="${5-}" snapshot_ref="${6-}" created="${7-}" cleanup_required="${8-}" resolve_method="${9-}"
  [[ -n "${path}" ]] || return 0
  mkdir -p "$(dirname "${path}")"
  python3 - "${path}" "${ready}" "${error_code}" "${message}" "${vm_ref}" "${snapshot_name}" "${snapshot_ref}" "${created}" "${cleanup_required}" "${resolve_method}" <<'PY'
import json
import os
import sys
import time

path, ready, error_code, message, vm_ref, snapshot_name, snapshot_ref, created, cleanup_required, resolve_method = sys.argv[1:11]
data = {
    "checked": True,
    "ready": str(ready).lower() == "true",
    "created": str(created).lower() == "true",
    "cleanupRequired": str(cleanup_required).lower() == "true",
    "error_code": error_code,
    "message": message,
    "vmRef": vm_ref,
    "snapshotName": snapshot_name,
    "snapshotRefPresent": bool(snapshot_ref),
    "snapshotRef": snapshot_ref,
    "resolveMethod": resolve_method,
    "checkedAtEpochMs": int(time.time() * 1000),
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
  FTCTL_DR_VMWARE_SOURCE_OPEN_TLS_VERIFY="${tls_verify}"
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
  if [[ "${tls_verify}" != "true" ]]; then
    thumbprint="$(ftctl_vmware_mover_resolve_thumbprint "${endpoint}" "${tls_verify}" "${thumbprint}" || true)"
    if [[ -z "${thumbprint}" ]]; then
      ftctl_vmware_mover_source_open_die 77 "DR_VMWARE_VDDK_THUMBPRINT_UNRESOLVED" \
        "VDDK requires the vCenter thumbprint when TLS verification is disabled for ${label}" \
        "${source_vm_ref}" "${source_snapshot_ref}" "${source_vmdk}"
    fi
  else
    FTCTL_DR_VMWARE_SOURCE_OPEN_THUMBPRINT_PRESENT="$([[ -n "${thumbprint}" ]] && printf 'true' || printf 'false')"
    FTCTL_DR_VMWARE_SOURCE_OPEN_THUMBPRINT_SOURCE="tls-verify"
  fi
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

ftctl_vmware_mover_snapshot_ref_from_object_collect() {
  ftctl_vmware_mover_snapshot_ref_from_tree "$@"
}

ftctl_vmware_mover_resolve_run_snapshot_ref() {
  local govc_bin="${1-}" endpoint="${2-}" username="${3-}" password_file="${4-}" tls_verify="${5-}" source_vm_ref="${6-}" snapshot_name="${7-}"
  local object_collect_json snapshot_tree snapshot_ref

  FTCTL_DR_VMWARE_LAST_SNAPSHOT_REF=""
  FTCTL_DR_VMWARE_LAST_SNAPSHOT_RESOLVE_METHOD=""
  [[ -x "${govc_bin}" && -n "${source_vm_ref}" && -n "${snapshot_name}" && -s "${password_file}" ]] || return 1

  object_collect_json="$(mktemp -p "${FTCTL_DR_VMWARE_MOVER_LOG_DIR}" vmware-snapshot-object-collect.XXXXXX.json)"
  if GOVC_URL="$(ftctl_vmware_mover_govc_url "${endpoint}")" \
    GOVC_USERNAME="${username}" \
    GOVC_PASSWORD="$(cat "${password_file}")" \
    GOVC_INSECURE="$([[ "${tls_verify}" == "true" ]] && printf 'false' || printf 'true')" \
      "${govc_bin}" object.collect -json "${source_vm_ref}" snapshot.rootSnapshotList > "${object_collect_json}" 2>/dev/null; then
    snapshot_ref="$(ftctl_vmware_mover_snapshot_ref_from_object_collect "${object_collect_json}" "${snapshot_name}" || true)"
    if [[ -n "${snapshot_ref}" ]]; then
      FTCTL_DR_VMWARE_LAST_SNAPSHOT_REF="${snapshot_ref}"
      FTCTL_DR_VMWARE_LAST_SNAPSHOT_RESOLVE_METHOD="object.collect:snapshot.rootSnapshotList"
      rm -f "${object_collect_json}"
      return 0
    fi
  fi
  rm -f "${object_collect_json}"

  snapshot_tree="$(mktemp -p "${FTCTL_DR_VMWARE_MOVER_LOG_DIR}" vmware-snapshot-tree.XXXXXX.json)"
  if GOVC_URL="$(ftctl_vmware_mover_govc_url "${endpoint}")" \
    GOVC_USERNAME="${username}" \
    GOVC_PASSWORD="$(cat "${password_file}")" \
    GOVC_INSECURE="$([[ "${tls_verify}" == "true" ]] && printf 'false' || printf 'true')" \
      "${govc_bin}" snapshot.tree -vm "${source_vm_ref}" -json > "${snapshot_tree}" 2>/dev/null; then
    snapshot_ref="$(ftctl_vmware_mover_snapshot_ref_from_tree "${snapshot_tree}" "${snapshot_name}" || true)"
    if [[ -n "${snapshot_ref}" ]]; then
      FTCTL_DR_VMWARE_LAST_SNAPSHOT_REF="${snapshot_ref}"
      FTCTL_DR_VMWARE_LAST_SNAPSHOT_RESOLVE_METHOD="snapshot.tree"
      rm -f "${snapshot_tree}"
      return 0
    fi
  fi
  rm -f "${snapshot_tree}"
  return 1
}

ftctl_vmware_mover_create_run_snapshot() {
  local govc_bin="${1-}" endpoint="${2-}" username="${3-}" password_file="${4-}" tls_verify="${5-}" source_vm_ref="${6-}" snapshot_name="${7-}"
  [[ -x "${govc_bin}" ]] || return 73
  [[ -n "${source_vm_ref}" && -n "${snapshot_name}" ]] || return 73
  if ! GOVC_URL="$(ftctl_vmware_mover_govc_url "${endpoint}")" \
    GOVC_USERNAME="${username}" \
    GOVC_PASSWORD="$(cat "${password_file}")" \
    GOVC_INSECURE="$([[ "${tls_verify}" == "true" ]] && printf 'false' || printf 'true')" \
      "${govc_bin}" snapshot.create -vm "${source_vm_ref}" -m=false -q=false "${snapshot_name}" >/dev/null; then
    ftctl_vmware_mover_write_source_snapshot_status false "DR_VMWARE_VDDK_CONNECT_INVALID" \
      "Failed to create VMware source snapshot" "${source_vm_ref}" "${snapshot_name}" "" false false ""
    return 73
  fi

  FTCTL_DR_VMWARE_GOVC_BIN_EFFECTIVE="${govc_bin}"
  FTCTL_DR_VMWARE_SOURCE_VM_REF_EFFECTIVE="${source_vm_ref}"
  FTCTL_DR_VMWARE_RUN_SNAPSHOT_NAME="${snapshot_name}"
  FTCTL_DR_VMWARE_RUN_SNAPSHOT_CREATED="true"

  if ! ftctl_vmware_mover_resolve_run_snapshot_ref "${govc_bin}" "${endpoint}" "${username}" "${password_file}" "${tls_verify}" "${source_vm_ref}" "${snapshot_name}"; then
    ftctl_vmware_mover_write_source_snapshot_status false "DR_VMWARE_SNAPSHOT_REF_UNRESOLVED" \
      "VMware source snapshot was created, but its MoRef could not be resolved" \
      "${source_vm_ref}" "${snapshot_name}" "" true true ""
    return 81
  fi

  FTCTL_DR_VMWARE_RUN_SNAPSHOT_REF="${FTCTL_DR_VMWARE_LAST_SNAPSHOT_REF}"
  ftctl_vmware_mover_write_source_snapshot_status true "" \
    "VMware source snapshot was created and resolved" \
    "${source_vm_ref}" "${snapshot_name}" "${FTCTL_DR_VMWARE_LAST_SNAPSHOT_REF}" true false \
    "${FTCTL_DR_VMWARE_LAST_SNAPSHOT_RESOLVE_METHOD}"
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

ftctl_vmware_mover_commit_cycle_metrics() {
  local disk_map="${1-}" results_path="${2-}" metrics_path="${3-}" plan="${4-}" run="${5-}" sequence="${6-}" requested_mode="${7-}"
  python3 - "${disk_map}" "${results_path}" "${metrics_path}" "${plan}" "${run}" "${sequence}" "${requested_mode}" <<'PY'
import json
import os
import sys
import time
import uuid

disk_map_path, results_path, metrics_path, plan, run, sequence, requested_mode = sys.argv[1:8]
with open(disk_map_path, "r", encoding="utf-8") as handle:
    disk_map = json.load(handle)
with open(results_path, "r", encoding="utf-8") as handle:
    disks = json.load(handle)

generation = int(sequence or 0)
for result in disks:
    index = int(result["diskIndex"])
    if index >= len(disk_map.get("disks") or []):
        raise SystemExit(f"disk result index is out of range: {index}")
    disk = disk_map["disks"][index]
    disk["changeId"] = result["newChangeId"]
    disk["cbtChangeId"] = result["newChangeId"]
    disk["baselineGeneration"] = generation
    disk["lastSyncSequence"] = generation
    disk["baselineState"] = "LOCAL_DURABLE"

disk_tmp = disk_map_path + ".tmp"
with open(disk_tmp, "w", encoding="utf-8") as handle:
    json.dump(disk_map, handle, sort_keys=True, separators=(",", ":"))
    handle.write("\n")
os.replace(disk_tmp, disk_map_path)

effective_modes = {str(item.get("effectiveMode") or "") for item in disks}
if effective_modes == {"NO_CHANGE"}:
    effective_mode = "NO_CHANGE"
elif requested_mode in ("FULL_SEED", "FULL_RESEED"):
    effective_mode = requested_mode
else:
    effective_mode = "CBT_INCREMENTAL"
incremental_verified = bool(disks) and all(bool(item.get("incrementalVerified")) for item in disks)
if effective_mode in ("FULL_SEED", "FULL_RESEED"):
    incremental_verified = False

sum_fields = (
    "virtualBytes", "changedBytes", "sourceReadBytes", "targetWrittenBytes",
    "transferPayloadBytes", "changedExtentCount", "durationMs"
)
metrics = {field: sum(int(item.get(field) or 0) for item in disks) for field in sum_fields}
duration_ms = max((int(item.get("durationMs") or 0) for item in disks), default=0)
metrics["durationMs"] = duration_ms
metrics["throughputBps"] = (metrics["sourceReadBytes"] * 1000 // duration_ms) if duration_ms else 0
metrics.update({
    "schemaVersion": 1,
    "cycleUuid": str(uuid.uuid5(uuid.NAMESPACE_URL, f"ablestack-dr:{plan}:{sequence}")),
    "cycleToken": f"{plan}:{sequence}",
    "planUuid": plan,
    "runUuid": run,
    "sequence": generation,
    "requestedMode": requested_mode,
    "effectiveMode": effective_mode,
    "incrementalVerified": incremental_verified,
    "metricsEstimated": any(bool(item.get("metricsEstimated")) for item in disks),
    "baselineGeneration": generation,
    "cycleCommitState": "LOCAL_DURABLE",
    "targetDurableAtEpochMs": int(time.time() * 1000),
    "disks": disks,
})
os.makedirs(os.path.dirname(metrics_path), exist_ok=True)
metrics_tmp = metrics_path + ".tmp"
with open(metrics_tmp, "w", encoding="utf-8") as handle:
    json.dump(metrics, handle, sort_keys=True, separators=(",", ":"))
    handle.write("\n")
os.replace(metrics_tmp, metrics_path)
PY
}

main() {
  local disk_map="${FTCTL_DR_DISK_MAP:-}" target_disk_map="${FTCTL_DR_TARGET_DISK_MAP:-}" credentials_file="${FTCTL_DR_CREDENTIALS_FILE:-}"
  local endpoint username password tls_verify thumbprint libdir password_file rows row count i
  local govc_bin source_vm_ref_for_snapshot snapshot_name snapshot_ref snapshot_created="false" mover_rc=0
  local cycle_type requested_mode metrics_path results_path result_tmp query_path patch_metrics_path

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
  cycle_type="${FTCTL_DR_CYCLE_TYPE:-full-seed}"
  case "${cycle_type}" in
    full-seed) requested_mode="FULL_SEED" ;;
    full-reseed) requested_mode="FULL_RESEED" ;;
    *) requested_mode="CBT_INCREMENTAL" ;;
  esac
  metrics_path="${FTCTL_DR_CYCLE_METRICS_PATH:-${FTCTL_DR_VMWARE_MOVER_LOG_DIR}/cycle-${FTCTL_DR_CHECKPOINT_SEQUENCE:-0}.json}"
  results_path="$(mktemp -p "${FTCTL_DR_VMWARE_MOVER_LOG_DIR}" vmware-cycle-results.XXXXXX.json)"
  printf '[]\n' > "${results_path}"
  snapshot_ref="$(jq -r '[.[].sourceSnapshotRef // ""] | map(select(. != "")) | .[0] // ""' <<< "${rows}")"
  snapshot_name="$(jq -r '[.[].sourceSnapshotName // ""] | map(select(. != "")) | .[0] // ""' <<< "${rows}")"
  source_vm_ref_for_snapshot="$(jq -r '[.[].sourceVmRef // ""] | map(select(. != "")) | .[0] // ""' <<< "${rows}")"
  if [[ -z "${snapshot_ref}" && -n "${source_vm_ref_for_snapshot}" && "${FTCTL_DR_VMWARE_CREATE_RUN_SNAPSHOT:-1}" == "1" ]]; then
    govc_bin="$(ftctl_vmware_mover_resolve_govc_bin "${credentials_file}" "${libdir}")"
    [[ -n "${govc_bin}" ]] || ftctl_vmware_mover_die 73 "DR_VMWARE_VDDK_CONNECT_INVALID: govc binary is required to create VMware source snapshot"
    snapshot_name="ftctl-dr-${FTCTL_DR_RUN_UUID:-$(date +%s)}-cycle-${FTCTL_DR_CHECKPOINT_SEQUENCE:-0}"
    mover_rc=0
    ftctl_vmware_mover_create_run_snapshot "${govc_bin}" "${endpoint}" "${username}" "${password_file}" "${tls_verify}" "${source_vm_ref_for_snapshot}" "${snapshot_name}" || mover_rc=$?
    if [[ "${mover_rc}" != "0" ]]; then
      if [[ "${mover_rc}" == "81" ]]; then
        ftctl_vmware_mover_die 81 "DR_VMWARE_SNAPSHOT_REF_UNRESOLVED: VMware source snapshot was created but its MoRef could not be resolved"
      fi
      ftctl_vmware_mover_die "${mover_rc:-73}" "DR_VMWARE_VDDK_CONNECT_INVALID: failed to create VMware source snapshot"
    fi
    snapshot_ref="${FTCTL_DR_VMWARE_LAST_SNAPSHOT_REF}"
    snapshot_created="true"
  fi

  i=0
  while [[ "${i}" -lt "${count}" ]]; do
    row="$(jq -c ".[$i]" <<< "${rows}")"
    local label source_vmdk source_vm_ref source_snapshot_ref target_path target_name target_storage_path target_uri target_format
    local cbt_disk_id previous_change_id new_change_id virtual_bytes areas_count changed_bytes effective_mode incremental_verified
    label="$(jq -r '.label // ""' <<< "${row}")"
    source_vmdk="$(jq -r '.sourceVmdk // ""' <<< "${row}")"
    source_vm_ref="$(jq -r '.sourceVmRef // ""' <<< "${row}")"
    source_snapshot_ref="$(jq -r '.sourceSnapshotRef // ""' <<< "${row}")"
    [[ -n "${source_snapshot_ref}" ]] || source_snapshot_ref="${snapshot_ref}"
    cbt_disk_id="$(jq -r '.cbtDiskId // ""' <<< "${row}")"
    previous_change_id="$(jq -r '.previousChangeId // ""' <<< "${row}")"
    virtual_bytes="$(jq -r '.virtualBytes // 0' <<< "${row}")"
    target_path="$(jq -r '.targetPath // ""' <<< "${row}")"
    target_name="$(jq -r '.targetName // ""' <<< "${row}")"
    target_storage_path="$(jq -r '.targetStoragePath // ""' <<< "${row}")"
    target_uri="$(ftctl_vmware_mover_target_uri "${target_path}" "${target_storage_path}" "${target_name}")"
    target_format="$(jq -r '.targetFormat // "raw"' <<< "${row}")"
    [[ -n "${snapshot_name}" ]] || ftctl_vmware_mover_die 82 "DR_CBT_QUERY_FAILED: VMware snapshot name is unavailable"
    if [[ "${requested_mode}" == "CBT_INCREMENTAL" && -z "${previous_change_id}" ]]; then
      ftctl_vmware_mover_die 85 "DR_CBT_RESEED_REQUIRED: committed changeId is missing for ${label:-disk${i}}"
    fi
    query_path="$(mktemp -p "${FTCTL_DR_VMWARE_MOVER_LOG_DIR}" vmware-cbt-query-${i}.XXXXXX.json)"
    ftctl_vmware_mover_query_cbt "${endpoint}" "${username}" "${password_file}" "${tls_verify}" "${libdir}" \
      "${source_vm_ref}" "${snapshot_name}" "${cbt_disk_id}" \
      "$([[ "${requested_mode}" == "CBT_INCREMENTAL" ]] && printf '%s' "${previous_change_id}")" "${query_path}"
    new_change_id="$(jq -r '.new_change_id // ""' "${query_path}")"
    source_vmdk="$(jq -r '.vmdk_path // ""' "${query_path}")"
    areas_count="$(jq -r '(.areas // []) | length' "${query_path}")"
    changed_bytes="$(jq -r '[.areas[]?.length] | add // 0' "${query_path}")"
    patch_metrics_path="$(mktemp -p "${FTCTL_DR_VMWARE_MOVER_LOG_DIR}" vmware-patch-metrics-${i}.XXXXXX.json)"
    if [[ "${requested_mode}" == "FULL_SEED" || "${requested_mode}" == "FULL_RESEED" ]]; then
      printf 'VMware DR mover full copy: %s snapshot=%s -> %s\n' "${source_vmdk}" "${source_snapshot_ref:-none}" "${target_uri}" >&2
      ftctl_vmware_mover_convert_disk "${source_vmdk}" "${source_vm_ref}" "${source_snapshot_ref}" "${target_uri}" "${target_format:-raw}" "${label:-disk${i}}" \
        "${endpoint}" "${username}" "${password_file}" "${tls_verify}" "${thumbprint}" "${libdir}"
      effective_mode="${requested_mode}"
      incremental_verified="false"
      jq -cn --argjson size "${virtual_bytes:-0}" '{changedExtentCount:1,changedBytes:$size,sourceReadBytes:$size,targetWrittenBytes:$size,transferPayloadBytes:$size,durationMs:0,throughputBps:0,metricsEstimated:true}' > "${patch_metrics_path}"
    elif [[ "${areas_count}" == "0" ]]; then
      effective_mode="NO_CHANGE"
      incremental_verified="true"
      printf '{"changedExtentCount":0,"changedBytes":0,"sourceReadBytes":0,"targetWrittenBytes":0,"transferPayloadBytes":0,"durationMs":0,"throughputBps":0,"metricsEstimated":false}\n' > "${patch_metrics_path}"
    else
      effective_mode="CBT_INCREMENTAL"
      incremental_verified="true"
      printf 'VMware DR mover CBT patch: disk=%s extents=%s bytes=%s -> %s\n' "${label:-disk${i}}" "${areas_count}" "${changed_bytes}" "${target_uri}" >&2
      ftctl_vmware_mover_patch_disk "${source_vmdk}" "${source_vm_ref}" "${source_snapshot_ref}" "${target_uri}" "${target_format:-raw}" "${label:-disk${i}}" \
        "${endpoint}" "${username}" "${password_file}" "${tls_verify}" "${thumbprint}" "${libdir}" "${query_path}" "${patch_metrics_path}"
    fi
    result_tmp="$(mktemp -p "${FTCTL_DR_VMWARE_MOVER_LOG_DIR}" vmware-cycle-result.XXXXXX.json)"
    jq -cn --argjson index "${i}" --arg label "${label:-disk${i}}" --arg requested "${requested_mode}" \
      --arg effective "${effective_mode}" --arg previous "${previous_change_id}" --arg next "${new_change_id}" \
      --argjson virtual "${virtual_bytes:-0}" --argjson verified "${incremental_verified}" --slurpfile metric "${patch_metrics_path}" \
      '{diskIndex:$index,diskLabel:$label,requestedMode:$requested,effectiveMode:$effective,previousChangeId:$previous,newChangeId:$next,virtualBytes:$virtual,incrementalVerified:$verified} + $metric[0]' > "${result_tmp}"
    jq --slurpfile item "${result_tmp}" '. + $item' "${results_path}" > "${results_path}.tmp"
    mv -f "${results_path}.tmp" "${results_path}"
    rm -f "${query_path}" "${patch_metrics_path}" "${result_tmp}"
    i=$((i + 1))
  done
  ftctl_vmware_mover_commit_cycle_metrics "${disk_map}" "${results_path}" "${metrics_path}" \
    "${FTCTL_DR_PLAN_UUID:-}" "${FTCTL_DR_RUN_UUID:-}" "${FTCTL_DR_CHECKPOINT_SEQUENCE:-0}" "${requested_mode}"
  rm -f "${results_path}"
}

main "$@"
