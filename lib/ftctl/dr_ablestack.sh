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

FTCTL_DR_ABLESTACK_FULL_SEED_ON_START="${FTCTL_DR_ABLESTACK_FULL_SEED_ON_START:-0}"

ftctl_dr_ablestack_disk_map_path() {
  local plan="${1-}"
  printf '%s/ablestack-disks.json\n' "$(ftctl_dr_runtime_plan_dir "${plan}")"
}

ftctl_dr_ablestack_manifest_dir() {
  local plan="${1-}"
  printf '%s/manifests\n' "$(ftctl_dr_runtime_plan_dir "${plan}")"
}

ftctl_dr_ablestack_checkpoint_dir() {
  local plan="${1-}"
  printf '%s/checkpoints\n' "$(ftctl_dr_runtime_plan_dir "${plan}")"
}

ftctl_dr_ablestack_manifest_path() {
  local plan="${1-}" run="${2-}"
  printf '%s/%s-manifest.json\n' \
    "$(ftctl_dr_ablestack_manifest_dir "${plan}")" \
    "$(ftctl_dr_runtime_key "${run:-current}")"
}

ftctl_dr_ablestack_checkpoint_path() {
  local plan="${1-}" run="${2-}"
  printf '%s/%s-checkpoint.json\n' \
    "$(ftctl_dr_ablestack_checkpoint_dir "${plan}")" \
    "$(ftctl_dr_runtime_key "${run:-current}")"
}

ftctl_dr_ablestack_profile_provider() {
  local profile_file="${1-}" endpoint="${2-}"
  ftctl_dr_runtime_profile_value "${profile_file}" "${endpoint}.provider" 2>/dev/null | tr '[:lower:]' '[:upper:]' || true
}

ftctl_dr_ablestack_profile_involves_ablestack() {
  local profile_file="${1-}"
  local source_provider target_provider
  source_provider="$(ftctl_dr_ablestack_profile_provider "${profile_file}" source)"
  target_provider="$(ftctl_dr_ablestack_profile_provider "${profile_file}" target)"
  [[ "${source_provider}" == "ABLESTACK" || "${target_provider}" == "ABLESTACK" ]]
}

ftctl_dr_ablestack_canonicalize_profile() {
  local profile_file="${1-}" out_path="${2-}"
  [[ -n "${profile_file}" && -f "${profile_file}" && -n "${out_path}" ]] || return 2
  ftctl_ensure_dir "$(dirname "${out_path}")" "0755"
  python3 - "${profile_file}" "${out_path}" <<'PY'
import json
import os
import sys

profile_path, out_path = sys.argv[1], sys.argv[2]
with open(profile_path, "r", encoding="utf-8") as fh:
    profile = json.load(fh)

def obj(value):
    return value if isinstance(value, dict) else {}

def arr(value):
    return value if isinstance(value, list) else []

def first_str(*values):
    for value in values:
        if value is None:
            continue
        if isinstance(value, (dict, list)):
            continue
        text = str(value).strip()
        if text:
            return text
    return ""

def first_int(*values):
    for value in values:
        if value is None or value == "":
            continue
        try:
            number = int(value)
            if number > 0:
                return number
        except (TypeError, ValueError):
            continue
    return 0

def value_at(data, *keys):
    if not isinstance(data, dict):
        return None
    for key in keys:
        if key in data:
            return data.get(key)
    return None

def infer_disk_type(path):
    text = str(path or "")
    if text.startswith("rbd:") or text.startswith("/dev/rbd/") or text.startswith("rbd/"):
        return "rbd"
    if text.startswith("/dev/"):
        return "block"
    if text:
        return "file"
    return ""

def infer_format(path, disk_type):
    text = str(path or "")
    if disk_type in ("rbd", "block"):
        return "raw"
    if text.endswith(".qcow2") or ".qcow2" in text:
        return "qcow2"
    if text.endswith(".raw"):
        return "raw"
    return ""

def normalize_disk(item, index):
    item = obj(item)
    source = obj(item.get("source"))
    target = obj(item.get("target"))
    source_path = first_str(
        value_at(item, "sourcePath", "sourceDiskRef", "sourceDisk", "source", "sourceRef"),
        value_at(source, "path", "diskRef", "disk", "sourcePath", "ref"),
    )
    target_path = first_str(
        value_at(item, "targetPath", "targetDiskRef", "targetDisk", "destination", "dest", "target"),
        value_at(target, "path", "diskRef", "disk", "targetPath", "ref"),
    )
    device = first_str(
        value_at(item, "device", "targetDevice", "diskTarget", "sourceDevice"),
        value_at(source, "device", "targetDevice"),
        value_at(target, "device", "targetDevice"),
        f"disk{index}",
    )
    source_type = infer_disk_type(source_path)
    target_type = infer_disk_type(target_path)
    source_format = first_str(
        value_at(item, "sourceFormat", "format"),
        value_at(source, "format", "sourceFormat"),
        infer_format(source_path, source_type),
    )
    target_format = first_str(
        value_at(item, "targetFormat"),
        value_at(target, "format", "targetFormat"),
        infer_format(target_path, target_type),
        source_format if target_type == "file" else "",
    )
    size_bytes = first_int(
        value_at(item, "sizeBytes", "virtualSize", "bytesTotal", "capacityBytes"),
        value_at(source, "sizeBytes", "virtualSize", "bytesTotal", "capacityBytes"),
        value_at(target, "sizeBytes", "virtualSize", "bytesTotal", "capacityBytes"),
    )
    return {
        "device": device,
        "sourcePath": source_path,
        "targetPath": target_path,
        "sourceFormat": source_format,
        "targetFormat": target_format,
        "sizeBytes": size_bytes,
        "sourceType": source_type,
        "targetType": target_type,
    }

def normalize_pair(source_item, target_item, index):
    source_item = obj(source_item)
    target_item = obj(target_item)
    merged = {
        "device": first_str(value_at(source_item, "device", "targetDevice"), value_at(target_item, "device", "targetDevice"), f"disk{index}"),
        "source": source_item,
        "target": target_item,
        "sourcePath": first_str(value_at(source_item, "path", "diskRef", "sourcePath", "sourceDiskRef", "ref")),
        "targetPath": first_str(value_at(target_item, "path", "diskRef", "targetPath", "targetDiskRef", "ref")),
        "sourceFormat": first_str(value_at(source_item, "format", "sourceFormat")),
        "targetFormat": first_str(value_at(target_item, "format", "targetFormat")),
        "sizeBytes": first_int(value_at(source_item, "sizeBytes", "virtualSize"), value_at(target_item, "sizeBytes", "virtualSize")),
    }
    return normalize_disk(merged, index)

source = obj(profile.get("source"))
target = obj(profile.get("target"))
mapping = obj(profile.get("mapping"))

disk_items = []
for key in ("disks", "diskMappings", "volumes", "volumeMappings"):
    disk_items = arr(mapping.get(key))
    if disk_items:
        break
if not disk_items:
    for key in ("disks", "diskMappings", "volumes"):
        disk_items = arr(profile.get(key))
        if disk_items:
            break

disks = []
if disk_items:
    disks = [normalize_disk(item, idx) for idx, item in enumerate(disk_items)]
else:
    source_disks = arr(source.get("disks"))
    target_disks = arr(target.get("disks"))
    if source_disks or target_disks:
        for idx in range(max(len(source_disks), len(target_disks))):
            disks.append(normalize_pair(
                source_disks[idx] if idx < len(source_disks) else {},
                target_disks[idx] if idx < len(target_disks) else {},
                idx,
            ))

out = {
    "planUuid": profile.get("planUuid", ""),
    "runUuid": profile.get("runUuid", ""),
    "direction": profile.get("direction", ""),
    "sourceProvider": str(source.get("provider", "")).upper(),
    "targetProvider": str(target.get("provider", "")).upper(),
    "sourceDriver": source.get("driver", ""),
    "targetDriver": target.get("driver", ""),
    "requiresDiskMap": len(disks) == 0,
    "count": len(disks),
    "disks": disks,
}

tmp = out_path + ".tmp"
with open(tmp, "w", encoding="utf-8") as fh:
    json.dump(out, fh, sort_keys=True, separators=(",", ":"))
    fh.write("\n")
os.replace(tmp, out_path)
PY
}

ftctl_dr_ablestack_disk_count() {
  local disk_map="${1-}"
  [[ -n "${disk_map}" && -f "${disk_map}" ]] || return 1
  python3 - "${disk_map}" <<'PY'
import json
import sys
with open(sys.argv[1], "r", encoding="utf-8") as fh:
    data = json.load(fh)
print(int(data.get("count") or 0))
PY
}

ftctl_dr_ablestack_disk_rows() {
  local disk_map="${1-}"
  [[ -n "${disk_map}" && -f "${disk_map}" ]] || return 1
  python3 - "${disk_map}" <<'PY'
import json
import sys
with open(sys.argv[1], "r", encoding="utf-8") as fh:
    data = json.load(fh)
for disk in data.get("disks") or []:
    print("\t".join(str(disk.get(key, "") or "") for key in (
        "device", "sourcePath", "targetPath", "sourceFormat", "targetFormat",
        "sizeBytes", "sourceType", "targetType"
    )))
PY
}

ftctl_dr_ablestack_rbd_spec_from_path() {
  local path="${1-}" out_var="${2}"
  local spec=""
  case "${path}" in
    rbd:*) spec="${path#rbd:}" ;;
    /dev/rbd/*/*) spec="${path#/dev/rbd/}" ;;
    rbd/*/*) spec="${path#rbd/}" ;;
    *) return 1 ;;
  esac
  [[ "${spec}" == */* && "${spec}" != */ ]] || return 1
  printf -v "${out_var}" '%s' "${spec}"
}

ftctl_dr_ablestack_qemu_info_value() {
  local path="${1-}" field="${2-}" out_var="${3}"
  local out="" err="" rc=0 value=""
  ftctl_cmd_run "${FTCTL_BLOCKCOPY_WAIT_TIMEOUT_SEC:-30}" out err rc -- \
    qemu-img info --force-share --output=json "${path}" || true
  if [[ "${rc}" != "0" ]]; then
    return "${rc}"
  fi
  value="$(python3 -c 'import json,sys; obj=json.loads(sys.argv[1]); print(obj.get(sys.argv[2], ""))' "${out}" "${field}")" || return 1
  printf -v "${out_var}" '%s' "${value}"
}

ftctl_dr_ablestack_source_size_bytes() {
  local device="${1-}" source_path="${2-}" explicit_size="${3-}" out_var="${4}"
  local size=""
  if [[ "${explicit_size}" =~ ^[1-9][0-9]*$ ]]; then
    printf -v "${out_var}" '%s' "${explicit_size}"
    return 0
  fi
  ftctl_blockcopy_source_virtual_size_bytes "" "${device}" "${source_path}" size || return $?
  [[ "${size}" =~ ^[1-9][0-9]*$ ]] || return 1
  printf -v "${out_var}" '%s' "${size}"
}

ftctl_dr_ablestack_prepare_file_target() {
  local target_path="${1-}" target_format="${2-}" size_bytes="${3-}"
  local out="" err="" rc=0 current_format="" current_size=""
  [[ -n "${target_path}" && -n "${target_format}" && "${size_bytes}" =~ ^[1-9][0-9]*$ ]] || return 2
  ftctl_ensure_dir "$(dirname "${target_path}")" "0755"
  if [[ ! -e "${target_path}" ]]; then
    ftctl_cmd_run "${FTCTL_BLOCKCOPY_WAIT_TIMEOUT_SEC:-30}" out err rc -- \
      qemu-img create -f "${target_format}" "${target_path}" "${size_bytes}" || true
    : "${out}${err}"
    return "${rc}"
  fi
  ftctl_dr_ablestack_qemu_info_value "${target_path}" "format" current_format || return $?
  ftctl_dr_ablestack_qemu_info_value "${target_path}" "virtual-size" current_size || return $?
  [[ -z "${current_format}" || "${current_format}" == "${target_format}" ]] || return 96
  [[ "${current_size}" =~ ^[0-9]+$ && "${current_size}" -ge "${size_bytes}" ]] || return 97
}

ftctl_dr_ablestack_prepare_block_target() {
  local target_path="${1-}" size_bytes="${2-}"
  local out="" err="" rc=0 current_size=""
  [[ -b "${target_path}" && "${size_bytes}" =~ ^[1-9][0-9]*$ ]] || return 2
  ftctl_cmd_run "${FTCTL_BLOCKCOPY_WAIT_TIMEOUT_SEC:-30}" out err rc -- \
    blockdev --getsize64 "${target_path}" || true
  : "${err}"
  [[ "${rc}" == "0" ]] || return "${rc}"
  current_size="$(awk 'NF {print $1; exit}' <<< "${out}")"
  [[ "${current_size}" =~ ^[0-9]+$ && "${current_size}" -ge "${size_bytes}" ]] || return 97
}

ftctl_dr_ablestack_prepare_rbd_target() {
  local target_path="${1-}" size_bytes="${2-}"
  local spec="" out="" err="" rc=0 size_mib
  ftctl_dr_ablestack_rbd_spec_from_path "${target_path}" spec || return 2
  size_mib=$(( (size_bytes + 1048575) / 1048576 ))
  (( size_mib > 0 )) || size_mib=1
  ftctl_cmd_run "${FTCTL_BLOCKCOPY_WAIT_TIMEOUT_SEC:-30}" out err rc -- \
    rbd info --format json "${spec}" || true
  if [[ "${rc}" == "0" ]]; then
    return 0
  fi
  out=""
  err=""
  rc=0
  ftctl_cmd_run "${FTCTL_BLOCKCOPY_WAIT_TIMEOUT_SEC:-30}" out err rc -- \
    rbd create --image-format 2 --size "${size_mib}" "${spec}" || true
  : "${out}${err}"
  return "${rc}"
}

ftctl_dr_ablestack_target_uri_for_qemu() {
  local target_path="${1-}" out_var="${2}"
  local spec=""
  if ftctl_dr_ablestack_rbd_spec_from_path "${target_path}" spec; then
    printf -v "${out_var}" 'rbd:%s' "${spec}"
  else
    printf -v "${out_var}" '%s' "${target_path}"
  fi
}

ftctl_dr_ablestack_prepare_target() {
  local target_path="${1-}" target_format="${2-}" size_bytes="${3-}" target_type="${4-}"
  case "${target_type}" in
    rbd) ftctl_dr_ablestack_prepare_rbd_target "${target_path}" "${size_bytes}" ;;
    block) ftctl_dr_ablestack_prepare_block_target "${target_path}" "${size_bytes}" ;;
    file) ftctl_dr_ablestack_prepare_file_target "${target_path}" "${target_format}" "${size_bytes}" ;;
    *) return 2 ;;
  esac
}

ftctl_dr_ablestack_write_manifest() {
  local disk_map="${1-}" records_path="${2-}" manifest_path="${3-}" phase="${4-}"
  ftctl_ensure_dir "$(dirname "${manifest_path}")" "0755"
  python3 - "${disk_map}" "${records_path}" "${manifest_path}" "${phase}" "$(ftctl_now_iso8601)" <<'PY'
import json
import os
import sys

disk_map_path, records_path, manifest_path, phase, now = sys.argv[1:6]
with open(disk_map_path, "r", encoding="utf-8") as fh:
    disk_map = json.load(fh)

records = {}
if os.path.exists(records_path):
    with open(records_path, "r", encoding="utf-8") as fh:
        for line in fh:
            parts = line.rstrip("\n").split("\t")
            if len(parts) >= 8:
                records[parts[0]] = {
                    "device": parts[0],
                    "sourcePath": parts[1],
                    "targetPath": parts[2],
                    "sourceFormat": parts[3],
                    "targetFormat": parts[4],
                    "sizeBytes": int(parts[5] or "0"),
                    "sourceType": parts[6],
                    "targetType": parts[7],
                }

disks = []
for disk in disk_map.get("disks") or []:
    device = str(disk.get("device") or "")
    item = dict(disk)
    item.update(records.get(device, {}))
    disks.append(item)

manifest = {
    "phase": phase,
    "generatedAt": now,
    "planUuid": disk_map.get("planUuid", ""),
    "runUuid": disk_map.get("runUuid", ""),
    "sourceProvider": disk_map.get("sourceProvider", ""),
    "targetProvider": disk_map.get("targetProvider", ""),
    "count": len(disks),
    "disks": disks,
}
tmp = manifest_path + ".tmp"
with open(tmp, "w", encoding="utf-8") as fh:
    json.dump(manifest, fh, sort_keys=True, separators=(",", ":"))
    fh.write("\n")
os.replace(tmp, manifest_path)
PY
}

ftctl_dr_ablestack_write_checkpoint() {
  local disk_map="${1-}" manifest_path="${2-}" checkpoint_path="${3-}" state="${4-}" source_at="${5-}" target_at="${6-}" rpo="${7-}"
  ftctl_ensure_dir "$(dirname "${checkpoint_path}")" "0755"
  python3 - "${disk_map}" "${manifest_path}" "${checkpoint_path}" "${state}" "${source_at}" "${target_at}" "${rpo}" <<'PY'
import json
import os
import sys

disk_map_path, manifest_path, checkpoint_path, state, source_at, target_at, rpo = sys.argv[1:8]
with open(disk_map_path, "r", encoding="utf-8") as fh:
    disk_map = json.load(fh)
manifest = {}
if os.path.exists(manifest_path):
    with open(manifest_path, "r", encoding="utf-8") as fh:
        manifest = json.load(fh)

checkpoint = {
    "checkpointUuid": os.path.splitext(os.path.basename(checkpoint_path))[0],
    "state": state,
    "sourceCheckpointAt": source_at,
    "targetDurableAt": target_at,
    "targetReadyRpoSeconds": int(rpo) if str(rpo).isdigit() else None,
    "manifest": manifest_path,
    "planUuid": disk_map.get("planUuid", ""),
    "runUuid": disk_map.get("runUuid", ""),
    "disks": manifest.get("disks", disk_map.get("disks", [])),
}
tmp = checkpoint_path + ".tmp"
with open(tmp, "w", encoding="utf-8") as fh:
    json.dump(checkpoint, fh, sort_keys=True, separators=(",", ":"))
    fh.write("\n")
os.replace(tmp, checkpoint_path)
PY
}

ftctl_dr_ablestack_prepare_targets() {
  local plan="${1-}" run="${2-}" profile_file="${3-}" disk_map="${4-}" manifest_path="${5-}" checkpoint_path="${6-}"
  local records_path count device source_path target_path source_format target_format size_bytes source_type target_type resolved_size
  local source_at

  ftctl_dr_ablestack_canonicalize_profile "${profile_file}" "${disk_map}" || return $?
  count="$(ftctl_dr_ablestack_disk_count "${disk_map}")" || return $?
  if [[ "${count}" == "0" ]]; then
    ftctl_log_event "dr-runtime" "dr.ablestack.disk_map" "warn" "" "" \
      "plan=${plan} run=${run} reason=missing_explicit_disk_map"
    return 30
  fi

  ftctl_ensure_dir "$(dirname "${manifest_path}")" "0755"
  records_path="${manifest_path}.records"
  : > "${records_path}"
  while IFS=$'\t' read -r device source_path target_path source_format target_format size_bytes source_type target_type; do
    [[ -n "${device}" ]] || continue
    [[ -n "${source_path}" && -n "${target_path}" ]] || return 31
    [[ -n "${target_format}" ]] || target_format="${source_format:-raw}"
    [[ -n "${target_type}" ]] || return 32
    resolved_size=""
    ftctl_dr_ablestack_source_size_bytes "${device}" "${source_path}" "${size_bytes}" resolved_size || return $?
    ftctl_dr_ablestack_prepare_target "${target_path}" "${target_format}" "${resolved_size}" "${target_type}" || return $?
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "${device}" "${source_path}" "${target_path}" "${source_format}" "${target_format}" "${resolved_size}" "${source_type}" "${target_type}" >> "${records_path}"
  done < <(ftctl_dr_ablestack_disk_rows "${disk_map}")

  ftctl_dr_ablestack_write_manifest "${disk_map}" "${records_path}" "${manifest_path}" "target-prepared" || return $?
  source_at="$(ftctl_now_iso8601)"
  ftctl_dr_ablestack_write_checkpoint "${disk_map}" "${manifest_path}" "${checkpoint_path}" "TARGET_PREPARED" "${source_at}" "" "" || return $?
  ftctl_log_event "dr-runtime" "dr.ablestack.targets_prepared" "ok" "" "" \
    "plan=${plan} run=${run} disks=${count} manifest=${manifest_path}"
}

ftctl_dr_ablestack_full_seed_once() {
  local plan="${1-}" run="${2-}" profile_file="${3-}" disk_map="${4-}" manifest_path="${5-}" checkpoint_path="${6-}"
  local device source_path target_path source_format target_format size_bytes source_type target_type resolved_size target_uri
  local out="" err="" rc=0 source_at target_at source_epoch target_epoch rpo="0"

  ftctl_dr_ablestack_prepare_targets "${plan}" "${run}" "${profile_file}" "${disk_map}" "${manifest_path}" "${checkpoint_path}" || return $?
  while IFS=$'\t' read -r device source_path target_path source_format target_format size_bytes source_type target_type; do
    [[ -n "${device}" ]] || continue
    : "${size_bytes}${source_type}${target_type}"
    [[ -n "${source_format}" ]] || source_format="raw"
    [[ -n "${target_format}" ]] || target_format="${source_format}"
    resolved_size=""
    ftctl_dr_ablestack_source_size_bytes "${device}" "${source_path}" "" resolved_size || return $?
    ftctl_dr_ablestack_target_uri_for_qemu "${target_path}" target_uri
    out=""
    err=""
    rc=0
    ftctl_cmd_run "${FTCTL_DR_FULL_SEED_TIMEOUT_SEC:-3600}" out err rc -- \
      qemu-img convert --force-share -p -n -S "${FTCTL_THIN_SPARSE_SIZE:-4k}" \
      -f "${source_format}" -O "${target_format}" "${source_path}" "${target_uri}" || true
    : "${out}${err}${resolved_size}"
    [[ "${rc}" == "0" ]] || return "${rc}"
  done < <(ftctl_dr_ablestack_disk_rows "${disk_map}")

  source_at="$(ftctl_now_iso8601)"
  target_at="$(ftctl_now_iso8601)"
  source_epoch="$(ftctl_iso_to_epoch "${source_at}" 2>/dev/null || printf '0')"
  target_epoch="$(ftctl_iso_to_epoch "${target_at}" 2>/dev/null || printf '0')"
  if [[ "${source_epoch}" =~ ^[0-9]+$ && "${target_epoch}" =~ ^[0-9]+$ && "${target_epoch}" -ge "${source_epoch}" ]]; then
    rpo="$((target_epoch - source_epoch))"
  fi
  ftctl_dr_ablestack_write_manifest "${disk_map}" "${manifest_path}.records" "${manifest_path}" "full-seed-complete" || return $?
  ftctl_dr_ablestack_write_checkpoint "${disk_map}" "${manifest_path}" "${checkpoint_path}" "TARGET_READY" "${source_at}" "${target_at}" "${rpo}" || return $?
  ftctl_log_event "dr-runtime" "dr.ablestack.full_seed" "ok" "" "" \
    "plan=${plan} run=${run} checkpoint=${checkpoint_path} rpo=${rpo}"
}

ftctl_dr_ablestack_replication_cycle() {
  local plan="${1-}" run="${2-}" profile_file="${3-}" sequence="${4-}" cycle_type="${5-}"
  local disk_map manifest_path checkpoint_path cycle_run

  [[ -n "${plan}" && -n "${run}" && -n "${profile_file}" ]] || return 2
  cycle_run="${run}-cycle-${sequence:-0}"
  disk_map="$(ftctl_dr_ablestack_disk_map_path "${plan}")"
  manifest_path="$(ftctl_dr_ablestack_manifest_path "${plan}" "${cycle_run}")"
  checkpoint_path="$(ftctl_dr_ablestack_checkpoint_path "${plan}" "${cycle_run}")"
  : "${cycle_type}"

  ftctl_dr_ablestack_full_seed_once "${plan}" "${cycle_run}" "${profile_file}" "${disk_map}" "${manifest_path}" "${checkpoint_path}" || return $?
  printf '%s\t%s\n' "${manifest_path}" "${checkpoint_path}"
}

ftctl_dr_ablestack_profile_bool() {
  local profile_file="${1-}" field="${2-}"
  local value
  value="$(ftctl_dr_runtime_profile_value "${profile_file}" "${field}" 2>/dev/null | tr '[:upper:]' '[:lower:]' || true)"
  [[ "${value}" == "true" || "${value}" == "1" || "${value}" == "yes" ]]
}

ftctl_dr_ablestack_sync_start() {
  local plan="${1-}" run="${2-}" profile_file="${3-}" state_path="${4-}" wait_value="${5-}"
  local disk_map manifest_path checkpoint_path count now source_provider target_provider

  [[ -n "${profile_file}" && -f "${profile_file}" ]] || return 0
  ftctl_dr_ablestack_profile_involves_ablestack "${profile_file}" || return 0
  source_provider="$(ftctl_dr_ablestack_profile_provider "${profile_file}" source)"
  target_provider="$(ftctl_dr_ablestack_profile_provider "${profile_file}" target)"

  ftctl_dr_runtime_ensure_plan_dirs "${plan}"
  ftctl_ensure_dir "$(ftctl_dr_ablestack_manifest_dir "${plan}")" "0755"
  ftctl_ensure_dir "$(ftctl_dr_ablestack_checkpoint_dir "${plan}")" "0755"
  disk_map="$(ftctl_dr_ablestack_disk_map_path "${plan}")"
  manifest_path="$(ftctl_dr_ablestack_manifest_path "${plan}" "${run}")"
  checkpoint_path="$(ftctl_dr_ablestack_checkpoint_path "${plan}" "${run}")"

  ftctl_dr_ablestack_canonicalize_profile "${profile_file}" "${disk_map}" || return $?
  count="$(ftctl_dr_ablestack_disk_count "${disk_map}")" || count="0"
  if [[ "${target_provider}" != "ABLESTACK" ]]; then
    ftctl_log_event "dr-runtime" "dr.ablestack.source_metadata" "ok" "" "" \
      "plan=${plan} run=${run} source=${source_provider:-unknown} target=${target_provider:-unknown} disks=${count}"
    return 0
  fi

  if [[ "${count}" == "0" ]]; then
    ftctl_dr_runtime_path_set "${state_path}" \
      "driver=ABLESTACK" \
      "driver_state=WAITING_FOR_DISK_MAP" \
      "step=ablestack-disk-map-pending" \
      "progress=1" \
      "disk_map_path=${disk_map}"
    ftctl_log_event "dr-runtime" "dr.ablestack.disk_map" "warn" "" "" \
      "plan=${plan} run=${run} reason=missing_explicit_disk_map"
    return 0
  fi

  if [[ "${FTCTL_DR_ABLESTACK_FULL_SEED_ON_START}" == "1" ]] ||
      { [[ "${wait_value}" != "false" ]] && ftctl_dr_ablestack_profile_bool "${profile_file}" "request.performFullSeed"; }; then
    ftctl_dr_ablestack_full_seed_once "${plan}" "${run}" "${profile_file}" "${disk_map}" "${manifest_path}" "${checkpoint_path}" || return $?
    now="$(ftctl_now_iso8601)"
    ftctl_dr_runtime_path_set "${state_path}" \
      "driver=ABLESTACK" \
      "driver_state=TARGET_READY" \
      "state=READY" \
      "step=ablestack-full-seed-complete" \
      "progress=100" \
      "disk_map_path=${disk_map}" \
      "manifest_path=${manifest_path}" \
      "checkpoint_path=${checkpoint_path}" \
      "last_target_durable_at=${now}" \
      "target_ready_rpo_seconds=0"
    return 0
  fi

  ftctl_dr_ablestack_prepare_targets "${plan}" "${run}" "${profile_file}" "${disk_map}" "${manifest_path}" "${checkpoint_path}" || return $?
  now="$(ftctl_now_iso8601)"
  ftctl_dr_runtime_path_set "${state_path}" \
    "driver=ABLESTACK" \
    "driver_state=TARGET_PREPARED" \
    "step=ablestack-targets-prepared" \
    "progress=5" \
    "disk_map_path=${disk_map}" \
    "manifest_path=${manifest_path}" \
    "checkpoint_path=${checkpoint_path}" \
    "last_source_checkpoint_at=${now}"
}
