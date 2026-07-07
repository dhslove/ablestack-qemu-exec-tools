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

FTCTL_DR_VMWARE_MOVER_LOG_DIR="${FTCTL_DR_VMWARE_MOVER_LOG_DIR:-/run/ablestack-vm-ftctl/dr-runtime/mover}"
FTCTL_DR_VMWARE_NBDKIT_READY_TIMEOUT="${FTCTL_DR_VMWARE_NBDKIT_READY_TIMEOUT:-20}"

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
        "sourceVmdk": first(source.get("sourceVmdkPath"), source.get("sourceDiskRef"), source.get("sourcePath")),
        "sourceVmRef": first(source.get("sourceVmRef"), vmware.get("sourceVmRef")),
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

ftctl_vmware_mover_convert_disk() {
  local source_vmdk="${1-}" source_vm_ref="${2-}" target_uri="${3-}" target_format="${4-}" label="${5-}"
  local endpoint="${6-}" username="${7-}" password_file="${8-}" tls_verify="${9-}" thumbprint="${10-}" libdir="${11-}"
  local work_dir socket_path pid nbd_source

  [[ -n "${source_vmdk}" ]] || ftctl_vmware_mover_die 65 "source VMDK path is empty for ${label}"
  [[ -n "${target_uri}" ]] || ftctl_vmware_mover_die 65 "target disk path is empty for ${label}"
  [[ -n "${endpoint}" ]] || ftctl_vmware_mover_die 65 "vCenter endpoint is empty"
  [[ -n "${username}" ]] || ftctl_vmware_mover_die 65 "vCenter username is empty"
  [[ -s "${password_file}" ]] || ftctl_vmware_mover_die 65 "vCenter password file is empty"

  if [[ "${FTCTL_DR_VMWARE_MOVER_DRY_RUN:-0}" == "1" ]]; then
    printf 'DRY-RUN: %s -> %s\n' "${source_vmdk}" "${target_uri}" >&2
    return 0
  fi

  work_dir="$(mktemp -d -t ftctl.vmware.mover.XXXXXX)"
  socket_path="${work_dir}/vddk.sock"
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
  [[ -n "${thumbprint}" && "${tls_verify}" != "true" ]] && nbdkit_args+=("thumbprint=${thumbprint}")
  [[ -n "${libdir}" && -d "${libdir}" ]] && nbdkit_args+=("libdir=${libdir}")

  nbdkit "${nbdkit_args[@]}" &
  pid=$!
  if ! ftctl_vmware_mover_wait_for_socket "${socket_path}" "${pid}" "${FTCTL_DR_VMWARE_NBDKIT_READY_TIMEOUT}"; then
    kill "${pid}" 2>/dev/null || true
    wait "${pid}" 2>/dev/null || true
    rm -rf "${work_dir}"
    ftctl_vmware_mover_die 69 "nbdkit vddk socket did not become ready for ${label}"
  fi

  nbd_source="json:{\"driver\":\"nbd\",\"server\":{\"type\":\"unix\",\"path\":\"${socket_path}\"}}"
  if ! qemu-img convert -p -n -f raw -O "${target_format:-raw}" "${nbd_source}" "${target_uri}"; then
    kill "${pid}" 2>/dev/null || true
    wait "${pid}" 2>/dev/null || true
    rm -rf "${work_dir}"
    ftctl_vmware_mover_die 68 "qemu-img conversion failed for ${label}"
  fi

  kill "${pid}" 2>/dev/null || true
  wait "${pid}" 2>/dev/null || true
  rm -rf "${work_dir}"
}

main() {
  local disk_map="${FTCTL_DR_DISK_MAP:-}" target_disk_map="${FTCTL_DR_TARGET_DISK_MAP:-}" credentials_file="${FTCTL_DR_CREDENTIALS_FILE:-}"
  local endpoint username password tls_verify thumbprint libdir plan_json password_file rows row count i

  [[ -n "${disk_map}" && -f "${disk_map}" ]] || ftctl_vmware_mover_die 65 "FTCTL_DR_DISK_MAP is required"
  [[ -n "${credentials_file}" && -f "${credentials_file}" ]] || ftctl_vmware_mover_die 65 "FTCTL_DR_CREDENTIALS_FILE is required"
  ftctl_vmware_mover_require jq 65
  ftctl_vmware_mover_require python3 65
  ftctl_vmware_mover_require nbdkit 65
  ftctl_vmware_mover_require qemu-img 65

  endpoint="$(ftctl_vmware_mover_json_value "${credentials_file}" '.credentials.source.endpoint' '')"
  username="$(ftctl_vmware_mover_json_value "${credentials_file}" '.credentials.source.principal // .credentials.source.username' '')"
  password="$(ftctl_vmware_mover_json_value "${credentials_file}" '.credentials.source.auth.password // .credentials.source.password' '')"
  tls_verify="$(ftctl_vmware_mover_json_value "${credentials_file}" '.credentials.source.tlsVerify' 'false')"
  thumbprint="$(ftctl_vmware_mover_json_value "${credentials_file}" '.credentials.source.thumbprint // .credentials.source.tlsThumbprint' '')"
  libdir="$(ftctl_vmware_mover_json_value "${credentials_file}" '.credentials.source.vddkLibdir // .credentials.source.libdir' '')"

  [[ -n "${password}" ]] || ftctl_vmware_mover_die 65 "source credential password is empty"
  mkdir -p "${FTCTL_DR_VMWARE_MOVER_LOG_DIR}"
  password_file="$(mktemp -p "${FTCTL_DR_VMWARE_MOVER_LOG_DIR}" vmware-password.XXXXXX)"
  chmod 0600 "${password_file}"
  printf '%s' "${password}" > "${password_file}"
  trap 'rm -f "${password_file}"' EXIT

  rows="$(ftctl_vmware_mover_disk_plan "${disk_map}" "${target_disk_map}")"
  count="$(jq 'length' <<< "${rows}")"
  [[ "${count}" =~ ^[1-9][0-9]*$ ]] || ftctl_vmware_mover_die 65 "no VMware disk rows to move"

  i=0
  while [[ "${i}" -lt "${count}" ]]; do
    row="$(jq -c ".[$i]" <<< "${rows}")"
    local label source_vmdk source_vm_ref target_path target_name target_storage_path target_uri target_format
    label="$(jq -r '.label // ""' <<< "${row}")"
    source_vmdk="$(jq -r '.sourceVmdk // ""' <<< "${row}")"
    source_vm_ref="$(jq -r '.sourceVmRef // ""' <<< "${row}")"
    target_path="$(jq -r '.targetPath // ""' <<< "${row}")"
    target_name="$(jq -r '.targetName // ""' <<< "${row}")"
    target_storage_path="$(jq -r '.targetStoragePath // ""' <<< "${row}")"
    target_uri="$(ftctl_vmware_mover_target_uri "${target_path}" "${target_storage_path}" "${target_name}")"
    target_format="$(jq -r '.targetFormat // "raw"' <<< "${row}")"
    printf 'VMware DR mover: %s -> %s\n' "${source_vmdk}" "${target_uri}" >&2
    ftctl_vmware_mover_convert_disk "${source_vmdk}" "${source_vm_ref}" "${target_uri}" "${target_format:-raw}" "${label:-disk${i}}" \
      "${endpoint}" "${username}" "${password_file}" "${tls_verify}" "${thumbprint}" "${libdir}"
    i=$((i + 1))
  done
}

main "$@"
