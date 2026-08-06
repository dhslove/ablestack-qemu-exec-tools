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

FTCTL_DR_VMWARE_LOCAL_VMDK_CREATE="${FTCTL_DR_VMWARE_LOCAL_VMDK_CREATE:-0}"
FTCTL_DR_VMWARE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${FTCTL_DR_VMWARE_LIB_DIR}/dr_vddk.sh" ]]; then
  # shellcheck source=/dev/null
  source "${FTCTL_DR_VMWARE_LIB_DIR}/dr_vddk.sh"
fi

ftctl_dr_vmware_default_mover() {
  local candidate
  for candidate in \
    "${FTCTL_LIB_BASE:-}/ftctl/dr_vmware_mover.sh" \
    "/usr/local/lib/ablestack-qemu-exec-tools/ftctl/dr_vmware_mover.sh"; do
    [[ -n "${candidate}" && -x "${candidate}" ]] || continue
    printf '%s\n' "${candidate}"
    return 0
  done
  return 1
}

ftctl_dr_vmware_effective_mover() {
  if [[ -n "${FTCTL_DR_VMWARE_MOVER:-}" ]]; then
    [[ -x "${FTCTL_DR_VMWARE_MOVER}" ]] || return 1
    printf '%s\n' "${FTCTL_DR_VMWARE_MOVER}"
    return 0
  fi
  ftctl_dr_vmware_default_mover
}

ftctl_dr_vmware_disk_map_path() {
  local plan="${1-}"
  printf '%s/vmware-disks.json\n' "$(ftctl_dr_runtime_plan_dir "${plan}")"
}

ftctl_dr_vmware_capability_path() {
  local plan="${1-}"
  printf '%s/vmware-capability.json\n' "$(ftctl_dr_runtime_plan_dir "${plan}")"
}

ftctl_dr_vmware_cbt_status_path() {
  local plan="${1-}"
  printf '%s/vmware-cbt.json\n' "$(ftctl_dr_runtime_plan_dir "${plan}")"
}

ftctl_dr_vmware_source_open_status_path() {
  local plan="${1-}"
  printf '%s/vmware-source-open.json\n' "$(ftctl_dr_runtime_plan_dir "${plan}")"
}

ftctl_dr_vmware_source_snapshot_status_path() {
  local plan="${1-}"
  printf '%s/vmware-source-snapshot.json\n' "$(ftctl_dr_runtime_plan_dir "${plan}")"
}

ftctl_dr_vmware_manifest_dir() {
  local plan="${1-}"
  printf '%s/manifests\n' "$(ftctl_dr_runtime_plan_dir "${plan}")"
}

ftctl_dr_vmware_checkpoint_dir() {
  local plan="${1-}"
  printf '%s/checkpoints\n' "$(ftctl_dr_runtime_plan_dir "${plan}")"
}

ftctl_dr_vmware_cycle_metrics_dir() {
  local plan="${1-}"
  printf '%s/cycle-metrics\n' "$(ftctl_dr_runtime_plan_dir "${plan}")"
}

ftctl_dr_vmware_cycle_metrics_path() {
  local plan="${1-}" run="${2-}"
  printf '%s/%s.json\n' \
    "$(ftctl_dr_vmware_cycle_metrics_dir "${plan}")" \
    "$(ftctl_dr_runtime_key "${run:-current}")"
}

ftctl_dr_vmware_cycle_journal_dir() {
  local plan="${1-}"
  printf '%s/cycles\n' "$(ftctl_dr_runtime_plan_dir "${plan}")"
}

ftctl_dr_vmware_cycle_journal_path() {
  local plan="${1-}" run="${2-}"
  printf '%s/%s.json\n' \
    "$(ftctl_dr_vmware_cycle_journal_dir "${plan}")" \
    "$(ftctl_dr_runtime_key "${run:-current}")"
}

ftctl_dr_vmware_manifest_path() {
  local plan="${1-}" run="${2-}"
  printf '%s/%s-vmware-manifest.json\n' \
    "$(ftctl_dr_vmware_manifest_dir "${plan}")" \
    "$(ftctl_dr_runtime_key "${run:-current}")"
}

ftctl_dr_vmware_checkpoint_path() {
  local plan="${1-}" run="${2-}"
  printf '%s/%s-vmware-checkpoint.json\n' \
    "$(ftctl_dr_vmware_checkpoint_dir "${plan}")" \
    "$(ftctl_dr_runtime_key "${run:-current}")"
}

ftctl_dr_vmware_profile_value_upper() {
  local profile_file="${1-}" field="${2-}"
  ftctl_dr_runtime_profile_value "${profile_file}" "${field}" 2>/dev/null | tr '[:lower:]' '[:upper:]' || true
}

ftctl_dr_vmware_profile_involves_vmware() {
  local profile_file="${1-}"
  local source_provider target_provider source_driver target_driver
  source_provider="$(ftctl_dr_vmware_profile_value_upper "${profile_file}" "source.provider")"
  target_provider="$(ftctl_dr_vmware_profile_value_upper "${profile_file}" "target.provider")"
  source_driver="$(ftctl_dr_vmware_profile_value_upper "${profile_file}" "source.driver")"
  target_driver="$(ftctl_dr_vmware_profile_value_upper "${profile_file}" "target.driver")"
  [[ "${source_provider}" == "VMWARE" || "${target_provider}" == "VMWARE" ||
      "${source_driver}" == *"VMWARE"* || "${source_driver}" == *"VDDK"* || "${source_driver}" == *"CBT"* ||
      "${target_driver}" == *"VMWARE"* || "${target_driver}" == *"VDDK"* || "${target_driver}" == *"CBT"* ]]
}

ftctl_dr_vmware_bool_json() {
  local value="${1-}"
  if [[ "${value}" == "1" || "${value}" == "true" ]]; then
    printf 'true'
  else
    printf 'false'
  fi
}

ftctl_dr_vmware_nbdkit_vddk_available() {
  local libdir="${1-}"
  command -v nbdkit >/dev/null 2>&1 || return 1
  if [[ -z "${libdir}" ]] && command -v ftctl_dr_vddk_resolve_libdir >/dev/null 2>&1; then
    libdir="$(ftctl_dr_vddk_resolve_libdir "" 2>/dev/null || true)"
  fi
  if [[ -n "${libdir}" ]] && command -v ftctl_dr_vddk_nbdkit_loads >/dev/null 2>&1; then
    ftctl_dr_vddk_nbdkit_loads "${libdir}"
    return $?
  fi
  nbdkit --dump-plugin vddk >/dev/null 2>&1 || nbdkit vddk --help >/dev/null 2>&1
}

ftctl_dr_vmware_write_capability() {
  local out_path="${1-}"
  local govc="0" nbdkit="0" nbdkit_vddk="0" vmware_vdiskmanager="0" qemu_img="0" mover_ready="0" vddk_ready="0" missing_code="" mover_path=""
  local vddk_libdir="" vddk_library_version=""

  [[ -n "${out_path}" ]] || return 2
  ftctl_ensure_dir "$(dirname "${out_path}")" "0755"

  if [[ "${FTCTL_DR_VMWARE_FORCE_MISSING_VDDK:-0}" == "1" ]]; then
    :
  elif [[ "${FTCTL_DR_VMWARE_FORCE_VDDK_READY:-0}" == "1" ]]; then
    nbdkit="1"
    nbdkit_vddk="1"
    vddk_ready="1"
  else
    command -v govc >/dev/null 2>&1 && govc="1"
    command -v nbdkit >/dev/null 2>&1 && nbdkit="1"
    if command -v ftctl_dr_vddk_resolve_libdir >/dev/null 2>&1; then
      vddk_libdir="$(ftctl_dr_vddk_resolve_libdir "" 2>/dev/null || true)"
      [[ -n "${vddk_libdir}" ]] && vddk_library_version="$(ftctl_dr_vddk_library_version "${vddk_libdir}" 2>/dev/null || true)"
    fi
    ftctl_dr_vmware_nbdkit_vddk_available "${vddk_libdir}" && nbdkit_vddk="1"
    command -v vmware-vdiskmanager >/dev/null 2>&1 && vmware_vdiskmanager="1"
    command -v qemu-img >/dev/null 2>&1 && qemu_img="1"
    if [[ "${nbdkit_vddk}" == "1" ]]; then
      vddk_ready="1"
    fi
  fi

  command -v qemu-img >/dev/null 2>&1 && qemu_img="1"
  mover_path="$(ftctl_dr_vmware_effective_mover 2>/dev/null || true)"
  [[ -n "${mover_path}" ]] && mover_ready="1"

  if [[ "${vddk_ready}" != "1" ]]; then
    if [[ -z "${vddk_libdir}" ]]; then
      missing_code="DR_VDDK_LIBDIR_UNRESOLVED"
    elif [[ "${nbdkit}" == "1" ]]; then
      missing_code="DR_VDDK_LIBRARY_LOAD_FAILED"
    else
      missing_code="DR_MISSING_VDDK"
    fi
  elif [[ "${qemu_img}" != "1" ]]; then
    missing_code="DR_MISSING_QEMU_IMG"
  elif [[ "${mover_ready}" != "1" ]]; then
    missing_code="DR_VMWARE_MOVER_UNAVAILABLE"
  fi
  printf '{"govc":%s,"nbdkit":%s,"nbdkitVddk":%s,"vmwareVdiskmanager":%s,"qemuImg":%s,"vddkReady":%s,"moverReady":%s,"vddkLibdir":"%s","vddkLibraryVersion":"%s","moverPath":"%s","missingCode":"%s"}\n' \
    "$(ftctl_dr_vmware_bool_json "${govc}")" \
    "$(ftctl_dr_vmware_bool_json "${nbdkit}")" \
    "$(ftctl_dr_vmware_bool_json "${nbdkit_vddk}")" \
    "$(ftctl_dr_vmware_bool_json "${vmware_vdiskmanager}")" \
    "$(ftctl_dr_vmware_bool_json "${qemu_img}")" \
    "$(ftctl_dr_vmware_bool_json "${vddk_ready}")" \
    "$(ftctl_dr_vmware_bool_json "${mover_ready}")" \
    "$(ftctl__json_escape "${vddk_libdir}")" \
    "$(ftctl__json_escape "${vddk_library_version}")" \
    "$(ftctl__json_escape "${mover_path}")" \
    "$(ftctl__json_escape "${missing_code}")" > "${out_path}.tmp"
  mv -f "${out_path}.tmp" "${out_path}"
  chmod 0644 "${out_path}" 2>/dev/null || true
}

ftctl_dr_vmware_capability_value() {
  local capability_path="${1-}" field="${2-}"
  [[ -n "${capability_path}" && -f "${capability_path}" ]] || return 1
  python3 - "${capability_path}" "${field}" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as fh:
    data = json.load(fh)
value = data.get(sys.argv[2])
if isinstance(value, bool):
    print("true" if value else "false")
elif value is None:
    print("")
else:
    print(str(value))
PY
}

ftctl_dr_vmware_canonicalize_profile() {
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
existing = {}
if os.path.exists(out_path):
    try:
        with open(out_path, "r", encoding="utf-8") as fh:
            existing = json.load(fh)
    except (OSError, TypeError, ValueError):
        existing = {}

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

def first_any_int(*values):
    for value in values:
        if value is None or value == "":
            continue
        try:
            return int(value)
        except (TypeError, ValueError):
            continue
    return None

def value_at(data, *keys):
    if not isinstance(data, dict):
        return None
    for key in keys:
        if key in data:
            return data.get(key)
    return None

def infer_vmdk_ref(item):
    return first_str(
        value_at(item, "vmdkPath", "vmdk", "backingFile", "path", "diskRef", "ref", "externalRef", "uuid", "id")
    )

def normalize_disk(item, index):
    item = obj(item)
    source = obj(item.get("source"))
    target = obj(item.get("target"))
    bus = first_any_int(
        value_at(item, "controllerBusNumber", "controllerBus", "bus"),
        value_at(source, "controllerBusNumber", "controllerBus", "bus"),
    )
    unit = first_any_int(
        value_at(item, "unitNumber", "unit"),
        value_at(source, "unitNumber", "unit"),
    )
    inferred_cbt_disk_id = f"scsi{bus}:{unit}" if bus is not None and unit is not None else ""
    cbt_disk_id = first_str(
        value_at(item, "cbtDiskId", "sourceCbtDiskId"),
        value_at(source, "cbtDiskId", "device"),
        inferred_cbt_disk_id,
    )
    source_disk_key = first_str(
        value_at(item, "sourceDiskKey", "deviceKey", "key"),
        value_at(source, "sourceDiskKey", "deviceKey", "key"),
    )
    device = first_str(
        cbt_disk_id,
        value_at(item, "device", "targetDevice", "diskTarget", "unitNumber", "key"),
        value_at(source, "device", "targetDevice", "unitNumber", "key"),
        value_at(target, "device", "targetDevice", "unitNumber", "key"),
        f"disk{index}",
    )
    source_disk_ref = first_str(
        value_at(item, "sourceDiskRef", "sourceVmdkPath", "sourcePath", "sourceDisk", "source"),
        infer_vmdk_ref(source),
    )
    target_disk_ref = first_str(
        value_at(item, "targetDiskRef", "targetVmdkPath", "targetPath", "targetDisk", "destination", "dest", "target"),
        infer_vmdk_ref(target),
    )
    return {
        "device": device,
        "cbtDiskId": cbt_disk_id,
        "sourceDiskKey": source_disk_key,
        "controllerBusNumber": bus if bus is not None else "",
        "unitNumber": unit if unit is not None else "",
        "sourceDiskRef": source_disk_ref,
        "sourceVmdkPath": first_str(value_at(item, "sourceVmdkPath", "sourcePath"), value_at(source, "vmdkPath", "path"), source_disk_ref),
        "targetDiskRef": target_disk_ref,
        "targetVmdkPath": first_str(value_at(item, "targetVmdkPath", "targetPath"), value_at(target, "vmdkPath", "path"), target_disk_ref),
        "sourceFormat": first_str(value_at(item, "sourceFormat"), value_at(source, "format"), "vmdk"),
        "targetFormat": first_str(value_at(item, "targetFormat"), value_at(target, "format"), "vmdk"),
        "sizeBytes": first_int(
            value_at(item, "sizeBytes", "virtualSize", "capacityBytes", "bytesTotal"),
            value_at(source, "sizeBytes", "virtualSize", "capacityBytes", "bytesTotal"),
            value_at(target, "sizeBytes", "virtualSize", "capacityBytes", "bytesTotal"),
        ),
        "changeId": first_str(value_at(item, "changeId", "change_id", "cbtChangeId"), value_at(source, "changeId", "change_id", "cbtChangeId")),
        "cbtChangeId": first_str(value_at(item, "cbtChangeId", "changeId", "change_id"), value_at(source, "cbtChangeId", "changeId", "change_id")),
        "baselineGeneration": first_any_int(value_at(item, "baselineGeneration"), value_at(source, "baselineGeneration")) or 0,
        "lastSyncSequence": first_any_int(value_at(item, "lastSyncSequence"), value_at(source, "lastSyncSequence")) or 0,
        "baselineState": first_str(value_at(item, "baselineState"), value_at(source, "baselineState")),
        "snapshotRef": first_str(value_at(item, "snapshotRef", "snapshot", "snapshotId"), value_at(source, "snapshotRef", "snapshot", "snapshotId")),
    }

def normalize_pair(source_item, target_item, index):
    source_item = obj(source_item)
    target_item = obj(target_item)
    return normalize_disk({
        "device": first_str(value_at(source_item, "device", "targetDevice", "unitNumber"), value_at(target_item, "device", "targetDevice", "unitNumber"), f"disk{index}"),
        "source": source_item,
        "target": target_item,
        "sourceDiskRef": infer_vmdk_ref(source_item),
        "targetDiskRef": infer_vmdk_ref(target_item),
        "sourceFormat": first_str(value_at(source_item, "format"), "vmdk"),
        "targetFormat": first_str(value_at(target_item, "format"), "vmdk"),
        "sizeBytes": first_int(value_at(source_item, "sizeBytes", "virtualSize", "capacityBytes"), value_at(target_item, "sizeBytes", "virtualSize", "capacityBytes")),
        "changeId": value_at(source_item, "changeId", "change_id", "cbtChangeId"),
        "snapshotRef": value_at(source_item, "snapshotRef", "snapshot", "snapshotId"),
    }, index)

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
    for idx in range(max(len(source_disks), len(target_disks))):
        disks.append(normalize_pair(
            source_disks[idx] if idx < len(source_disks) else {},
            target_disks[idx] if idx < len(target_disks) else {},
            idx,
        ))

def disk_identity(item):
    item = obj(item)
    for key in ("sourceDiskKey", "cbtDiskId", "sourceDiskRef", "sourceVmdkPath", "device"):
        value = first_str(item.get(key))
        if value:
            return f"{key}:{value}"
    return ""

existing_disks = {
    disk_identity(item): item
    for item in arr(obj(existing).get("disks"))
    if disk_identity(item)
}
runtime_fields = (
    "changeId", "cbtChangeId", "baselineGeneration", "lastSyncSequence", "baselineState",
)
for disk in disks:
    previous = existing_disks.get(disk_identity(disk))
    if not isinstance(previous, dict):
        continue
    previous_generation = first_any_int(previous.get("baselineGeneration")) or 0
    current_generation = first_any_int(disk.get("baselineGeneration")) or 0
    if previous_generation < current_generation:
        continue
    for key in runtime_fields:
        value = previous.get(key)
        if value not in (None, ""):
            disk[key] = value

out = {
    "planUuid": profile.get("planUuid", ""),
    "runUuid": profile.get("runUuid", ""),
    "direction": profile.get("direction", ""),
    "sourceProvider": str(source.get("provider", "")).upper(),
    "targetProvider": str(target.get("provider", "")).upper(),
    "sourceDriver": source.get("driver", ""),
    "targetDriver": target.get("driver", ""),
    "sourceVmRef": first_str(source.get("vmId"), source.get("uuid"), source.get("externalRef"), source.get("name")),
    "targetVmRef": first_str(target.get("vmId"), target.get("uuid"), target.get("externalRef"), target.get("name")),
    "vcenterRef": first_str(source.get("vcenterRef"), source.get("vCenterRef"), target.get("vcenterRef"), target.get("vCenterRef")),
    "datastoreRef": first_str(target.get("datastoreRef"), target.get("datastore"), mapping.get("targetDatastoreRef"), mapping.get("targetStorageRef"), mapping.get("datastoreRef")),
    "folderPath": first_str(target.get("folderPath"), mapping.get("targetFolderPath"), mapping.get("targetFolder"), mapping.get("folderPath")),
    "resourcePoolRef": first_str(target.get("resourcePoolRef"), mapping.get("targetResourcePoolRef"), mapping.get("targetComputeRef"), mapping.get("resourcePoolRef")),
    "networkRef": first_str(target.get("networkRef"), mapping.get("targetNetworkRef"), mapping.get("networkRef")),
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

ftctl_dr_vmware_disk_count() {
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

ftctl_dr_vmware_preflight_summary_json() {
  local disk_map="${1-}" capability_path="${2-}" role="${3-}" disk_map_path_for_output="${4-}" capability_path_for_output="${5-}"
  python3 - "${disk_map}" "${capability_path}" "${role}" "${disk_map_path_for_output}" "${capability_path_for_output}" <<'PY'
import json
import sys

disk_map_path, capability_path, role, disk_map_out, capability_out = sys.argv[1:6]
with open(disk_map_path, "r", encoding="utf-8") as fh:
    disk_map = json.load(fh)
with open(capability_path, "r", encoding="utf-8") as fh:
    capability = json.load(fh)
capable = bool(capability.get("vddkReady")) and bool(capability.get("qemuImg")) and bool(capability.get("moverReady"))
error_code = "" if capable else (capability.get("missingCode") or "DR_MISSING_VDDK")
summary = {
    "driver": "VMWARE",
    "involved": True,
    "capable": capable,
    "error_code": error_code,
    "role": role,
    "source_provider": disk_map.get("sourceProvider", ""),
    "target_provider": disk_map.get("targetProvider", ""),
    "source_driver": disk_map.get("sourceDriver", ""),
    "target_driver": disk_map.get("targetDriver", ""),
    "disk_count": int(disk_map.get("count") or 0),
    "requires_disk_map": bool(disk_map.get("requiresDiskMap")),
    "vddk_ready": bool(capability.get("vddkReady")),
    "mover_ready": bool(capability.get("moverReady")),
    "missing_code": error_code,
    "disk_map_path": disk_map_out,
    "capability_path": capability_out,
    "capability": capability,
}
print(json.dumps(summary, sort_keys=True, separators=(",", ":")))
PY
}

ftctl_dr_vmware_preflight_json() {
  local plan="${1-}" profile_file="${2-}" role="${3-}" dry_run="${4-0}"
  local work_dir disk_map capability out_disk_map out_capability summary rc=0

  if ! ftctl_dr_vmware_profile_involves_vmware "${profile_file}"; then
    printf '{"driver":"VMWARE","involved":false,"capable":true,"error_code":"","role":"%s"}\n' \
      "$(ftctl__json_escape "${role}")"
    return 0
  fi

  if [[ "${dry_run}" == "1" ]]; then
    work_dir="$(mktemp -d -t ftctl.dr.vmware.preflight.XXXXXX)"
    disk_map="${work_dir}/vmware-disks.json"
    capability="${work_dir}/vmware-capability.json"
    out_disk_map=""
    out_capability=""
  else
    ftctl_dr_runtime_ensure_plan_dirs "${plan}"
    disk_map="$(ftctl_dr_vmware_disk_map_path "${plan}")"
    capability="$(ftctl_dr_vmware_capability_path "${plan}")"
    out_disk_map="${disk_map}"
    out_capability="${capability}"
  fi

  ftctl_dr_vmware_canonicalize_profile "${profile_file}" "${disk_map}" || rc=$?
  if [[ "${rc}" == "0" ]]; then
    ftctl_dr_vmware_write_capability "${capability}" || rc=$?
  fi
  if [[ "${rc}" == "0" ]]; then
    summary="$(ftctl_dr_vmware_preflight_summary_json "${disk_map}" "${capability}" "${role}" "${out_disk_map}" "${out_capability}")" || rc=$?
  fi
  [[ -n "${work_dir:-}" ]] && rm -rf "${work_dir}"
  if [[ "${rc}" != "0" ]]; then
    printf '{"driver":"VMWARE","involved":true,"capable":false,"error_code":"DR_VMWARE_PREFLIGHT_FAILED","role":"%s","rc":%s}\n' \
      "$(ftctl__json_escape "${role}")" "${rc}"
    return 0
  fi
  printf '%s\n' "${summary}"
}

ftctl_dr_vmware_write_manifest() {
  local disk_map="${1-}" capability_path="${2-}" manifest_path="${3-}" phase="${4-}" metrics_path="${5-}"
  ftctl_ensure_dir "$(dirname "${manifest_path}")" "0755"
  python3 - "${disk_map}" "${capability_path}" "${manifest_path}" "${phase}" "$(ftctl_now_iso8601)" "${metrics_path}" <<'PY'
import json
import os
import sys

disk_map_path, capability_path, manifest_path, phase, now, metrics_path = sys.argv[1:7]
with open(disk_map_path, "r", encoding="utf-8") as fh:
    disk_map = json.load(fh)
with open(capability_path, "r", encoding="utf-8") as fh:
    capability = json.load(fh)

manifest = {
    "phase": phase,
    "generatedAt": now,
    "driver": "VMWARE",
    "planUuid": disk_map.get("planUuid", ""),
    "runUuid": disk_map.get("runUuid", ""),
    "direction": disk_map.get("direction", ""),
    "sourceProvider": disk_map.get("sourceProvider", ""),
    "targetProvider": disk_map.get("targetProvider", ""),
    "sourceDriver": disk_map.get("sourceDriver", ""),
    "targetDriver": disk_map.get("targetDriver", ""),
    "sourceVmRef": disk_map.get("sourceVmRef", ""),
    "targetVmRef": disk_map.get("targetVmRef", ""),
    "vcenterRef": disk_map.get("vcenterRef", ""),
    "datastoreRef": disk_map.get("datastoreRef", ""),
    "folderPath": disk_map.get("folderPath", ""),
    "resourcePoolRef": disk_map.get("resourcePoolRef", ""),
    "networkRef": disk_map.get("networkRef", ""),
    "capability": capability,
    "count": int(disk_map.get("count") or 0),
    "disks": disk_map.get("disks") or [],
}
if metrics_path and os.path.exists(metrics_path):
    with open(metrics_path, "r", encoding="utf-8") as fh:
        manifest["cycleMetrics"] = json.load(fh)
tmp = manifest_path + ".tmp"
with open(tmp, "w", encoding="utf-8") as fh:
    json.dump(manifest, fh, sort_keys=True, separators=(",", ":"))
    fh.write("\n")
os.replace(tmp, manifest_path)
PY
}

ftctl_dr_vmware_write_checkpoint() {
  local disk_map="${1-}" manifest_path="${2-}" checkpoint_path="${3-}" state="${4-}" source_at="${5-}" target_at="${6-}" rpo="${7-}" metrics_path="${8-}"
  ftctl_ensure_dir "$(dirname "${checkpoint_path}")" "0755"
  python3 - "${disk_map}" "${manifest_path}" "${checkpoint_path}" "${state}" "${source_at}" "${target_at}" "${rpo}" "${metrics_path}" <<'PY'
import json
import os
import sys

disk_map_path, manifest_path, checkpoint_path, state, source_at, target_at, rpo, metrics_path = sys.argv[1:9]
with open(disk_map_path, "r", encoding="utf-8") as fh:
    disk_map = json.load(fh)
manifest = {}
if os.path.exists(manifest_path):
    with open(manifest_path, "r", encoding="utf-8") as fh:
        manifest = json.load(fh)

checkpoint = {
    "checkpointUuid": os.path.splitext(os.path.basename(checkpoint_path))[0],
    "driver": "VMWARE",
    "state": state,
    "sourceCheckpointAt": source_at,
    "targetDurableAt": target_at,
    "targetReadyRpoSeconds": int(rpo) if str(rpo).isdigit() else None,
    "manifest": manifest_path,
    "planUuid": disk_map.get("planUuid", ""),
    "runUuid": disk_map.get("runUuid", ""),
    "sourceProvider": disk_map.get("sourceProvider", ""),
    "targetProvider": disk_map.get("targetProvider", ""),
    "disks": manifest.get("disks", disk_map.get("disks", [])),
}
cycle_metrics = manifest.get("cycleMetrics") or {}
if not cycle_metrics and metrics_path and os.path.exists(metrics_path):
    with open(metrics_path, "r", encoding="utf-8") as fh:
        cycle_metrics = json.load(fh)
if cycle_metrics:
    checkpoint["cycleMetrics"] = cycle_metrics
    checkpoint["cycleMetricsPath"] = metrics_path
    for key in (
        "cycleUuid", "cycleToken", "sequence", "requestedMode", "effectiveMode",
        "automaticReseed", "modeDecisionCode", "reseedReason", "invalidBaselineDiskCount",
        "incrementalVerified", "metricsEstimated", "baselineGeneration", "cycleCommitState",
        "virtualBytes", "changedBytes", "sourceReadBytes", "targetWrittenBytes",
        "transferPayloadBytes", "changedExtentCount", "durationMs", "throughputBps",
        "nbdTeardownState", "nbdTeardownStartedAtEpochMs", "nbdTeardownCompletedAtEpochMs",
        "nbdTeardownDurationMs", "nbdSourceDeviceCount", "nbdTargetDeviceCount",
        "nbdQuarantinedDeviceCount", "nbdTeardownErrorCode", "nbdTeardownErrorMessage",
    ):
        if key in cycle_metrics:
            checkpoint[key] = cycle_metrics[key]
tmp = checkpoint_path + ".tmp"
with open(tmp, "w", encoding="utf-8") as fh:
    json.dump(checkpoint, fh, sort_keys=True, separators=(",", ":"))
    fh.write("\n")
os.replace(tmp, checkpoint_path)
PY
}

ftctl_dr_vmware_prepare_local_vmdk_targets() {
  local disk_map="${1-}"
  [[ "${FTCTL_DR_VMWARE_LOCAL_VMDK_CREATE}" == "1" ]] || return 0
  command -v qemu-img >/dev/null 2>&1 || return 60
  python3 - "${disk_map}" <<'PY' | while IFS=$'\t' read -r target_path size_bytes; do
import json
import sys
with open(sys.argv[1], "r", encoding="utf-8") as fh:
    data = json.load(fh)
for disk in data.get("disks") or []:
    target = str(disk.get("targetVmdkPath") or "")
    size = int(disk.get("sizeBytes") or 0)
    if target.startswith("/") and size > 0:
        print(f"{target}\t{size}")
PY
    [[ -n "${target_path}" && "${size_bytes}" =~ ^[1-9][0-9]*$ ]] || continue
    ftctl_ensure_dir "$(dirname "${target_path}")" "0755"
    [[ -e "${target_path}" ]] && continue
    qemu-img create -f vmdk "${target_path}" "${size_bytes}" >/dev/null || return $?
  done
}

ftctl_dr_vmware_cbt_error_code() {
  case "${1-}" in
    77) printf '%s\n' "DR_VMWARE_CBT_DISABLED" ;;
    78) printf '%s\n' "DR_VMWARE_CBT_ENABLE_FAILED" ;;
    79) printf '%s\n' "DR_VMWARE_CBT_VERIFY_FAILED" ;;
    80) printf '%s\n' "DR_VMWARE_CBT_DISK_ID_UNRESOLVED" ;;
    82) printf '%s\n' "DR_VMWARE_CBT_QUERY_FAILED" ;;
    84) printf '%s\n' "DR_VMWARE_CBT_SNAPSHOT_CONFLICT" ;;
    *) printf '%s\n' "DR_VMWARE_CBT_PREFLIGHT_FAILED" ;;
  esac
}

ftctl_dr_vmware_ensure_cbt_enabled() {
  local plan="${1-}" run="${2-}" profile_file="${3-}" disk_map="${4-}" cbt_status_path="${5-}"
  local source_provider required auto_enable fail_snapshots credentials_file

  [[ -n "${profile_file}" && -f "${profile_file}" && -n "${disk_map}" && -f "${disk_map}" ]] || return 2
  source_provider="$(ftctl_dr_vmware_profile_value_upper "${profile_file}" "source.provider")"
  [[ "${source_provider}" == "VMWARE" ]] || return 0

  if ftctl_dr_runtime_profile_bool_default "${profile_file}" "policy.cbtPolicy.required" "true"; then
    required="true"
  else
    required="false"
  fi
  [[ "${required}" == "true" ]] || return 0
  if ftctl_dr_runtime_profile_bool_default "${profile_file}" "policy.cbtPolicy.autoEnable" "true"; then
    auto_enable="true"
  else
    auto_enable="false"
  fi
  if ftctl_dr_runtime_profile_bool_default "${profile_file}" "policy.cbtPolicy.failIfPreExistingSnapshots" "false"; then
    fail_snapshots="true"
  else
    fail_snapshots="false"
  fi

  ftctl_ensure_dir "$(dirname "${cbt_status_path}")" "0755"
  credentials_file="$(ftctl_dr_runtime_credential_path "${plan}" 2>/dev/null || true)"
  python3 - "${profile_file}" "${disk_map}" "${cbt_status_path}" "$([[ -f "${credentials_file}" ]] && printf '%s' "${credentials_file}")" "${auto_enable}" "${fail_snapshots}" "$(ftctl_now_iso8601)" <<'PY'
import json
import os
import re
import shutil
import subprocess
import sys
from urllib.parse import urlparse, urlunparse

profile_path, disk_map_path, out_path, credentials_path, auto_enable, fail_snapshots, now = sys.argv[1:8]
auto_enable = str(auto_enable).lower() == "true"
fail_snapshots = str(fail_snapshots).lower() == "true"

with open(profile_path, "r", encoding="utf-8") as fh:
    profile = json.load(fh)
with open(disk_map_path, "r", encoding="utf-8") as fh:
    disk_map = json.load(fh)
credential_payload = {}
if credentials_path and os.path.exists(credentials_path):
    with open(credentials_path, "r", encoding="utf-8") as fh:
        credential_payload = json.load(fh)

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

def boolish(value):
    if isinstance(value, bool):
        return value
    return str(value).strip().lower() in ("1", "true", "yes", "on")

def deep_merge(base, override):
    result = dict(base or {})
    if not isinstance(override, dict):
        return result
    for key, value in override.items():
        if isinstance(value, dict) and isinstance(result.get(key), dict):
            result[key] = deep_merge(result[key], value)
        else:
            result[key] = value
    return result

def normalize_vcenter_url(value):
    text = first_str(value)
    if not text:
        return ""
    if "://" not in text:
        text = "https://" + text
    parsed = urlparse(text)
    path = parsed.path or ""
    if not path or path == "/":
        path = "/sdk"
    elif path.rstrip("/") in ("/rest", "/ui"):
        path = "/sdk"
    elif path.rstrip("/") not in ("/sdk",):
        path = path.rstrip("/") + "/sdk" if not path.endswith("/sdk") else path
    return urlunparse((parsed.scheme, parsed.netloc, path, "", "", ""))

def get_ci(data, key):
    if not isinstance(data, dict):
        return None
    if key in data:
        return data.get(key)
    lower = key.lower()
    for k, v in data.items():
        if str(k).lower() == lower:
            return v
    return None

def path_ci(data, *keys):
    cur = data
    for key in keys:
        cur = get_ci(cur, key)
        if cur is None:
            return None
    return cur

def nested_bool(data, *keys):
    cur = data
    for key in keys:
        cur = get_ci(cur, key)
        if cur is None:
            return None
    return boolish(cur)

def collect_extra_config(data):
    result = {}
    def walk(value):
        if isinstance(value, dict):
            key = value.get("key") or value.get("Key")
            val = value.get("value") if "value" in value else value.get("Value")
            if key is not None:
                result[str(key)] = val
            for child in value.values():
                walk(child)
        elif isinstance(value, list):
            for child in value:
                walk(child)
    walk(data)
    return result

def find_vm_object(vm_info):
    if not isinstance(vm_info, dict):
        return {}
    for key in ("virtualMachines", "VirtualMachines"):
        items = vm_info.get(key)
        if isinstance(items, list) and items:
            return items[0] if isinstance(items[0], dict) else {}
    return vm_info

def collect_vm_devices(vm_obj):
    devices = path_ci(vm_obj, "config", "hardware", "device")
    if isinstance(devices, list):
        return [item for item in devices if isinstance(item, dict)]
    found = []
    def walk(value):
        if isinstance(value, dict):
            maybe = get_ci(value, "device")
            if isinstance(maybe, list) and any(isinstance(item, dict) and get_ci(item, "key") is not None for item in maybe):
                found.extend(item for item in maybe if isinstance(item, dict))
            for child in value.values():
                walk(child)
        elif isinstance(value, list):
            for child in value:
                walk(child)
    walk(vm_obj)
    return found

def device_type(device):
    return first_str(get_ci(device, "type"), get_ci(device, "Type"), get_ci(device, "_typeName"), get_ci(device, "dynamicType"), get_ci(device, "class"))

def device_label(device):
    return first_str(path_ci(device, "deviceInfo", "label"), path_ci(device, "DeviceInfo", "Label"), get_ci(device, "label"), get_ci(device, "name"))

def backing_path(device):
    return first_str(path_ci(device, "backing", "fileName"), path_ci(device, "Backing", "FileName"), path_ci(device, "backing", "FileName"))

def int_or_none(value):
    if value is None or value == "":
        return None
    try:
        return int(value)
    except (TypeError, ValueError):
        return None

def is_scsi_controller(device):
    dtype = device_type(device).lower()
    label = device_label(device).lower()
    has_bus = int_or_none(get_ci(device, "busNumber")) is not None
    return has_bus and (
        ("scsi" in dtype and "controller" in dtype)
        or "scsi" in label
        or get_ci(device, "sharedBus") is not None
    )

def is_virtual_disk(device):
    dtype = device_type(device).lower()
    if "virtualdisk" in dtype or dtype.endswith(".disk"):
        return True
    return get_ci(device, "controllerKey") is not None and int_or_none(get_ci(device, "unitNumber")) is not None and bool(backing_path(device))

def normalize_cbt_disk_id_from_vm(vm_obj, disk, item):
    devices = collect_vm_devices(vm_obj)
    controllers = {}
    for device in devices:
        if not is_scsi_controller(device):
            continue
        key = first_str(get_ci(device, "key"), get_ci(device, "Key"))
        bus = int_or_none(first_str(get_ci(device, "busNumber"), get_ci(device, "BusNumber")))
        if key and bus is not None:
            controllers[key] = bus

    disk = obj(disk)
    source = obj(disk.get("source"))
    wanted_key = first_str(
        disk.get("sourceDiskKey"), source.get("sourceDiskKey"), disk.get("deviceKey"), source.get("deviceKey"),
        disk.get("diskKey"), source.get("diskKey"), disk.get("key"), source.get("key"),
        disk.get("sourcePath") if str(disk.get("sourcePath") or "").isdigit() else "",
        item.get("sourceDiskKey"),
    )
    wanted_path = first_str(
        disk.get("sourceDiskRef"), source.get("sourceDiskRef"), disk.get("sourceVmdkPath"), source.get("sourceVmdkPath"),
        disk.get("sourcePath") if not str(disk.get("sourcePath") or "").isdigit() else "",
        item.get("sourceDiskRef"),
    )
    wanted_label = first_str(disk.get("label"), source.get("label"), item.get("label"))

    for device in devices:
        if not is_virtual_disk(device):
            continue
        key = first_str(get_ci(device, "key"), get_ci(device, "Key"))
        label = device_label(device)
        path = backing_path(device)
        key_match = bool(wanted_key and key == wanted_key)
        path_match = bool(wanted_path and path == wanted_path)
        label_match = bool(wanted_label and label == wanted_label)
        if not (key_match or path_match or label_match):
            continue
        controller_key = first_str(get_ci(device, "controllerKey"), get_ci(device, "ControllerKey"))
        unit = int_or_none(first_str(get_ci(device, "unitNumber"), get_ci(device, "UnitNumber")))
        bus = controllers.get(controller_key)
        if bus is None or unit is None:
            continue
        item["sourceDiskKey"] = first_str(item.get("sourceDiskKey"), key)
        item["sourceDiskRef"] = first_str(item.get("sourceDiskRef"), path)
        item["resolution"] = "vm-device-graph"
        return f"scsi{bus}:{unit}"
    return ""

def has_snapshot(value):
    if value in (None, "", [], {}):
        return False
    if isinstance(value, list):
        return any(has_snapshot(item) for item in value)
    if isinstance(value, dict):
        if any(str(k).lower() in ("snapshot", "rootSnapshotList".lower(), "childSnapshotList".lower(), "children", "tree", "trees") and has_snapshot(v) for k, v in value.items()):
            return True
        if any(str(k).lower() in ("name", "snapshotname") for k in value):
            return True
        return any(has_snapshot(v) for v in value.values())
    return False

def disk_id_for(disk, index):
    disk = obj(disk)
    source = obj(disk.get("source"))
    cbt = first_str(disk.get("cbtDiskId"), source.get("cbtDiskId"))
    if re.match(r"^scsi[0-9]+:[0-9]+$", cbt):
        return cbt
    device = first_str(disk.get("device"), source.get("device"))
    if re.match(r"^scsi[0-9]+:[0-9]+$", device):
        return device
    bus = first_str(disk.get("controllerBusNumber"), source.get("controllerBusNumber"), disk.get("controllerBus"), source.get("controllerBus"))
    unit = first_str(disk.get("unitNumber"), source.get("unitNumber"), disk.get("unit"), source.get("unit"))
    if bus.isdigit() and unit.isdigit():
        return f"scsi{bus}:{unit}"
    return ""

def resolve_govc_bin(source_credential):
    candidates = []
    env_bin = os.environ.get("FTCTL_DR_VMWARE_GOVC_BIN")
    if env_bin:
        candidates.append(env_bin)
    for key in ("govcPath", "govcBin"):
        value = first_str(source_credential.get(key))
        if value:
            candidates.append(value)
    vddk_libdir = first_str(source_credential.get("vddkLibdir"), source_credential.get("libdir"))
    if vddk_libdir:
        compat_root = os.path.dirname(os.path.abspath(vddk_libdir))
        candidates.append(os.path.join(compat_root, "bin", "govc"))
        candidates.append(os.path.join(os.path.dirname(compat_root), "bin", "govc"))
    version = first_str(source_credential.get("vddkVersion"), source_credential.get("version"))
    if version:
        normalized = version.replace(".", "")
        if normalized == "8":
            normalized = "80"
        candidates.append(f"/usr/share/ablestack/v2k/compat/vsphere{normalized}/bin/govc")
    path_bin = shutil.which("govc")
    if path_bin:
        candidates.append(path_bin)
    candidates.extend(("/usr/local/bin/govc", "/usr/bin/govc"))
    seen = set()
    for candidate in candidates:
        if not candidate or candidate in seen:
            continue
        seen.add(candidate)
        if os.path.isfile(candidate) and os.access(candidate, os.X_OK):
            return candidate
    return ""

profile_credentials = obj(profile.get("credentials"))
profile_source_credential = obj(profile_credentials.get("source"))
runtime_credentials = obj(credential_payload.get("credentials"))
runtime_source_credential = obj(runtime_credentials.get("source"))
source_credential = deep_merge(profile_source_credential, runtime_source_credential)
auth = obj(source_credential.get("auth"))
source = obj(profile.get("source"))
endpoint = normalize_vcenter_url(first_str(source_credential.get("endpoint"), source.get("endpoint")))
principal = first_str(source_credential.get("principal"), source_credential.get("username"), auth.get("username"), auth.get("user"), auth.get("principal"))
password = first_str(auth.get("password"), source_credential.get("password"))
tls_verify = source_credential.get("tlsVerify")
vm_ref = first_str(disk_map.get("sourceVmRef"), source.get("externalRef"), source.get("vmRef"), source.get("name"), source.get("vmId"))

disks = arr(disk_map.get("disks"))
resolved = []
unresolved = []
for index, disk in enumerate(disks):
    disk_id = disk_id_for(disk, index)
    item = {
        "index": index,
        "label": first_str(obj(disk).get("label"), f"Disk {index + 1}"),
        "sourceDiskKey": first_str(obj(disk).get("sourceDiskKey"), obj(obj(disk).get("source")).get("sourceDiskKey"), obj(disk).get("deviceKey"), obj(obj(disk).get("source")).get("deviceKey")),
        "sourceDiskRef": first_str(obj(disk).get("sourceDiskRef"), obj(disk).get("sourceVmdkPath"), obj(disk).get("sourcePath"), obj(obj(disk).get("source")).get("diskRef")),
        "cbtDiskId": disk_id,
    }
    if disk_id:
        resolved.append(item)
    else:
        unresolved.append(item)

status = {
    "driver": "VMWARE",
    "phase": "cbt-preflight",
    "checkedAt": now,
    "vmRef": vm_ref,
    "endpoint": endpoint,
    "required": True,
    "autoEnable": auto_enable,
    "failIfPreExistingSnapshots": fail_snapshots,
    "vmEnabled": False,
    "enabled": False,
    "enabledByFtctl": False,
    "enableAttempted": False,
    "disks": resolved,
    "unresolvedDisks": unresolved,
    "error_code": "",
}

def write_status(code=0, error_code=""):
    status["error_code"] = error_code
    tmp = out_path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(status, fh, sort_keys=True, separators=(",", ":"))
        fh.write("\n")
    os.replace(tmp, out_path)
    sys.exit(code)

if not endpoint or not principal or not password or not vm_ref:
    status["message"] = "vCenter endpoint, username, password, or source VM reference is missing"
    write_status(82, "DR_VMWARE_CBT_QUERY_FAILED")

govc_bin = resolve_govc_bin(source_credential)
if not govc_bin:
    status["message"] = "govc binary was not found in compatibility bundle or PATH"
    write_status(82, "DR_VMWARE_CBT_QUERY_FAILED")
status["govcBin"] = govc_bin

env = os.environ.copy()
env.update({
    "GOVC_URL": endpoint,
    "GOVC_USERNAME": principal,
    "GOVC_PASSWORD": password,
    "GOVC_INSECURE": "false" if boolish(tls_verify) else "true",
})

def govc(args, check=True):
    proc = subprocess.run([govc_bin] + list(args), env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    if check and proc.returncode != 0:
        raise RuntimeError(proc.stderr.strip() or proc.stdout.strip() or f"govc {' '.join(args)} failed")
    return proc

def read_vm_info():
    vm_proc = govc(["vm.info", "-json", vm_ref])
    try:
        vm_info = json.loads(vm_proc.stdout or "{}")
    except json.JSONDecodeError as exc:
        raise RuntimeError(f"govc vm.info returned invalid JSON: {exc}")
    return vm_info

def read_state(vm_info=None):
    if vm_info is None:
        vm_info = read_vm_info()
    vm_obj = find_vm_object(vm_info)
    extra = collect_extra_config(vm_obj)
    vm_enabled = nested_bool(vm_obj, "config", "changeTrackingEnabled")
    if vm_enabled is None:
        vm_enabled = boolish(extra.get("ctkEnabled"))
    disk_rows = []
    all_disks_enabled = True
    for disk in resolved:
        key = disk["cbtDiskId"] + ".ctkEnabled"
        disk_enabled = boolish(extra.get(key))
        row = dict(disk)
        row["ctkEnabled"] = disk_enabled
        disk_rows.append(row)
        all_disks_enabled = all_disks_enabled and disk_enabled
    return vm_enabled, disk_rows, extra

try:
    govc(["about"])
    initial_vm_info = read_vm_info()
    if unresolved:
        vm_obj = find_vm_object(initial_vm_info)
        still_unresolved = []
        for item in list(unresolved):
            disk = disks[item["index"]]
            disk_id = normalize_cbt_disk_id_from_vm(vm_obj, disk, item)
            if disk_id:
                item["cbtDiskId"] = disk_id
                resolved.append(item)
            else:
                still_unresolved.append(item)
        unresolved = still_unresolved
        status["disks"] = resolved
        status["unresolvedDisks"] = unresolved
    if unresolved:
        status["message"] = "VMware CBT disk id was not resolved for one or more selected disks"
        write_status(80, "DR_VMWARE_CBT_DISK_ID_UNRESOLVED")
    vm_enabled, disk_rows, extra = read_state(initial_vm_info)
    status["vmEnabled"] = bool(vm_enabled)
    status["disks"] = disk_rows
    status["enabled"] = bool(vm_enabled) and all(d.get("ctkEnabled") for d in disk_rows)
    if status["enabled"]:
        write_status(0, "")
    if not auto_enable:
        status["message"] = "VMware CBT is disabled and autoEnable is false"
        write_status(77, "DR_VMWARE_CBT_DISABLED")
    if fail_snapshots:
        snap_proc = govc(["snapshot.tree", "-vm", vm_ref, "-json"], check=False)
        if snap_proc.returncode == 0 and snap_proc.stdout.strip():
            try:
                status["hasPreExistingSnapshots"] = has_snapshot(json.loads(snap_proc.stdout))
            except json.JSONDecodeError:
                status["hasPreExistingSnapshots"] = False
            if status["hasPreExistingSnapshots"]:
                status["message"] = "VMware CBT enable requires snapshot cleanup before sync"
                write_status(84, "DR_VMWARE_CBT_SNAPSHOT_CONFLICT")
    status["enableAttempted"] = True
    govc(["vm.change", "-vm", vm_ref, "-e", "ctkEnabled=true"])
    for disk in resolved:
        govc(["vm.change", "-vm", vm_ref, "-e", f"{disk['cbtDiskId']}.ctkEnabled=true"])
    status["enabledByFtctl"] = True
    vm_enabled, disk_rows, extra = read_state()
    status["vmEnabled"] = bool(vm_enabled)
    status["disks"] = disk_rows
    status["enabled"] = bool(vm_enabled) and all(d.get("ctkEnabled") for d in disk_rows)
    if status["enabled"]:
        write_status(0, "")
    status["message"] = "VMware CBT enable command completed but verification still failed"
    write_status(79, "DR_VMWARE_CBT_VERIFY_FAILED")
except RuntimeError as exc:
    status["message"] = str(exc)
    if status.get("enabledByFtctl"):
        write_status(79, "DR_VMWARE_CBT_VERIFY_FAILED")
    if status.get("enableAttempted"):
        write_status(78, "DR_VMWARE_CBT_ENABLE_FAILED")
    write_status(82, "DR_VMWARE_CBT_QUERY_FAILED")
PY
}

ftctl_dr_vmware_replication_cycle() {
  local plan="${1-}" run="${2-}" profile_file="${3-}" sequence="${4-}" cycle_type="${5-}"
  local disk_map target_disk_map capability_path manifest_path checkpoint_path metrics_path journal_path source_open_status_path source_snapshot_status_path cycle_run now mover_path mover_rc=0
  local credentials_file=""
  local source_at target_at snapshot_epoch_ms snapshot_source_at source_epoch target_epoch rpo="0"

  [[ -n "${plan}" && -n "${run}" && -n "${profile_file}" ]] || return 2
  cycle_run="${run}-cycle-${sequence:-0}"
  disk_map="$(ftctl_dr_vmware_disk_map_path "${plan}")"
  capability_path="$(ftctl_dr_vmware_capability_path "${plan}")"
  manifest_path="$(ftctl_dr_vmware_manifest_path "${plan}" "${cycle_run}")"
  checkpoint_path="$(ftctl_dr_vmware_checkpoint_path "${plan}" "${cycle_run}")"
  metrics_path="$(ftctl_dr_vmware_cycle_metrics_path "${plan}" "${cycle_run}")"
  journal_path="$(ftctl_dr_vmware_cycle_journal_path "${plan}" "${cycle_run}")"
  source_open_status_path="$(ftctl_dr_vmware_source_open_status_path "${plan}")"
  source_snapshot_status_path="$(ftctl_dr_vmware_source_snapshot_status_path "${plan}")"
  [[ -f "${disk_map}" ]] || ftctl_dr_vmware_canonicalize_profile "${profile_file}" "${disk_map}" || return $?
  target_disk_map="$(ftctl_dr_ablestack_disk_map_path "${plan}" 2>/dev/null || true)"
  if [[ -z "${target_disk_map}" ]] || ! command -v ftctl_dr_ablestack_canonicalize_profile >/dev/null 2>&1; then
    ftctl_log_event "dr-runtime" "dr.vmware.target_map" "fail" "" "65" \
      "plan=${plan} run=${run} error_code=DR_FORWARD_TARGET_MAP_GENERATOR_UNAVAILABLE"
    return 65
  fi
  # The ABLESTACK canonicalizer is the single source of truth for forward
  # target locators. Rebuild the role-scoped map before every VMware cycle so
  # post-failback resume cannot fall back to a bare Cloud volume name.
  ftctl_dr_ablestack_canonicalize_profile "${profile_file}" "${target_disk_map}" || {
    ftctl_log_event "dr-runtime" "dr.vmware.target_map" "fail" "" "65" \
      "plan=${plan} run=${run} error_code=DR_FORWARD_TARGET_MAP_INVALID"
    return 65
  }
  [[ -f "${capability_path}" ]] || ftctl_dr_vmware_write_capability "${capability_path}" || return $?
  source_at="$(ftctl_now_iso8601)"

  mover_path="$(ftctl_dr_vmware_effective_mover 2>/dev/null || true)"
  if [[ "${FTCTL_DR_VMWARE_MOCK_CYCLE:-0}" == "1" ]]; then
    :
  elif [[ -n "${mover_path}" ]]; then
    credentials_file="$(ftctl_dr_runtime_credential_path "${plan}" 2>/dev/null || true)"
    FTCTL_DR_PLAN_UUID="${plan}" \
    FTCTL_DR_RUN_UUID="${run}" \
    FTCTL_DR_CHECKPOINT_SEQUENCE="${sequence:-0}" \
    FTCTL_DR_CYCLE_TYPE="${cycle_type:-incremental}" \
    FTCTL_DR_DISK_MAP="${disk_map}" \
    FTCTL_DR_TARGET_DISK_MAP="${target_disk_map}" \
    FTCTL_DR_CAPABILITY="${capability_path}" \
    FTCTL_DR_MANIFEST="${manifest_path}" \
    FTCTL_DR_CHECKPOINT="${checkpoint_path}" \
    FTCTL_DR_CYCLE_METRICS_PATH="${metrics_path}" \
    FTCTL_DR_CYCLE_JOURNAL_PATH="${journal_path}" \
    FTCTL_DR_SOURCE_OPEN_STATUS_PATH="${source_open_status_path}" \
    FTCTL_DR_SOURCE_SNAPSHOT_STATUS_PATH="${source_snapshot_status_path}" \
    FTCTL_DR_CREDENTIALS_FILE="$([[ -f "${credentials_file}" ]] && printf '%s' "${credentials_file}")" \
      "${mover_path}" || mover_rc=$?
    [[ "${mover_rc}" == "0" ]] || return "${mover_rc}"
  else
    ftctl_log_event "dr-runtime" "dr.vmware.mover" "fail" "" "65" \
      "plan=${plan} run=${run} reason=DR_VMWARE_MOVER_UNAVAILABLE"
    return 65
  fi

  target_at="$(ftctl_now_iso8601)"
  ftctl_dr_vmware_write_manifest "${disk_map}" "${capability_path}" "${manifest_path}" "vmware-${cycle_type:-incremental}-complete" "${metrics_path}" || return $?
  if [[ -f "${source_snapshot_status_path}" ]]; then
    snapshot_epoch_ms="$(jq -r '.checkedAtEpochMs // empty' "${source_snapshot_status_path}" 2>/dev/null || true)"
    if [[ "${snapshot_epoch_ms}" =~ ^[0-9]+$ ]]; then
      snapshot_source_at="$(date -u -d "@$((snapshot_epoch_ms / 1000))" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || true)"
      [[ -n "${snapshot_source_at}" ]] && source_at="${snapshot_source_at}"
    fi
  fi
  source_epoch="$(ftctl_iso_to_epoch "${source_at}" 2>/dev/null || printf '0')"
  target_epoch="$(ftctl_iso_to_epoch "${target_at}" 2>/dev/null || printf '0')"
  if [[ "${source_epoch}" =~ ^[0-9]+$ && "${target_epoch}" =~ ^[0-9]+$ && "${target_epoch}" -ge "${source_epoch}" ]]; then
    rpo="$((target_epoch - source_epoch))"
  fi
  ftctl_dr_vmware_write_checkpoint "${disk_map}" "${manifest_path}" "${checkpoint_path}" "TARGET_READY" "${source_at}" "${target_at}" "${rpo}" "${metrics_path}" || return $?
  ftctl_log_event "dr-runtime" "dr.vmware.cycle" "ok" "" "" \
    "plan=${plan} run=${run} sequence=${sequence:-0} type=${cycle_type:-incremental} checkpoint=${checkpoint_path} rpo=${rpo}"
  printf '%s\t%s\n' "${manifest_path}" "${checkpoint_path}"
}

ftctl_dr_vmware_sync_start() {
  local plan="${1-}" run="${2-}" profile_file="${3-}" state_path="${4-}" wait_value="${5-}"
  local disk_map capability_path cbt_status_path source_open_status_path source_snapshot_status_path manifest_path checkpoint_path count now vddk_ready mover_ready qemu_img_ready missing_code target_provider disk_map_role
  local cbt_rc cbt_error
  : "${wait_value}"

  [[ -n "${profile_file}" && -f "${profile_file}" ]] || return 0
  ftctl_dr_vmware_profile_involves_vmware "${profile_file}" || return 0

  ftctl_dr_runtime_ensure_plan_dirs "${plan}"
  ftctl_ensure_dir "$(ftctl_dr_vmware_manifest_dir "${plan}")" "0755"
  ftctl_ensure_dir "$(ftctl_dr_vmware_checkpoint_dir "${plan}")" "0755"
  disk_map="$(ftctl_dr_vmware_disk_map_path "${plan}")"
  target_provider="$(ftctl_dr_vmware_profile_value_upper "${profile_file}" "target.provider")"
  if [[ "${target_provider}" == "ABLESTACK" ]]; then
    disk_map_role="source"
  else
    disk_map_role="target"
  fi
  capability_path="$(ftctl_dr_vmware_capability_path "${plan}")"
  cbt_status_path="$(ftctl_dr_vmware_cbt_status_path "${plan}")"
  source_open_status_path="$(ftctl_dr_vmware_source_open_status_path "${plan}")"
  source_snapshot_status_path="$(ftctl_dr_vmware_source_snapshot_status_path "${plan}")"
  manifest_path="$(ftctl_dr_vmware_manifest_path "${plan}" "${run}")"
  checkpoint_path="$(ftctl_dr_vmware_checkpoint_path "${plan}" "${run}")"

  ftctl_dr_vmware_canonicalize_profile "${profile_file}" "${disk_map}" || return $?
  ftctl_dr_vmware_write_capability "${capability_path}" || return $?
  vddk_ready="$(ftctl_dr_vmware_capability_value "${capability_path}" "vddkReady" || true)"
  mover_ready="$(ftctl_dr_vmware_capability_value "${capability_path}" "moverReady" || true)"
  qemu_img_ready="$(ftctl_dr_vmware_capability_value "${capability_path}" "qemuImg" || true)"
  missing_code="$(ftctl_dr_vmware_capability_value "${capability_path}" "missingCode" || true)"
  count="$(ftctl_dr_vmware_disk_count "${disk_map}")" || count="0"

  if [[ "${vddk_ready}" != "true" || "${mover_ready}" != "true" || "${qemu_img_ready}" != "true" ]]; then
    now="$(ftctl_now_iso8601)"
    ftctl_dr_vmware_write_manifest "${disk_map}" "${capability_path}" "${manifest_path}" "vmware-capability-missing" || true
    ftctl_dr_vmware_write_checkpoint "${disk_map}" "${manifest_path}" "${checkpoint_path}" "MISSING_VDDK" "${now}" "" "" || true
    ftctl_dr_runtime_path_set "${state_path}" \
      "driver=VMWARE" \
      "driver_state=MISSING_VDDK" \
      "state=ERROR" \
      "step=vmware-capability-missing" \
      "progress=100" \
      "accepted=false" \
      "error_code=${missing_code:-DR_MISSING_VDDK}" \
      "disk_map_path=${disk_map}" \
      "source_disk_map_path=${disk_map}" \
      "disk_map_role=${disk_map_role}" \
      "source_open_status_path=${source_open_status_path}" \
      "source_snapshot_status_path=${source_snapshot_status_path}" \
      "manifest_path=${manifest_path}" \
      "checkpoint_path=${checkpoint_path}" \
      "updated_at=${now}"
    ftctl_log_event "dr-runtime" "dr.vmware.capability" "fail" "" "44" \
      "plan=${plan} run=${run} reason=${missing_code:-DR_MISSING_VDDK}"
    return 44
  fi

  if [[ "${count}" == "0" ]]; then
    now="$(ftctl_now_iso8601)"
    ftctl_dr_vmware_write_manifest "${disk_map}" "${capability_path}" "${manifest_path}" "vmware-disk-map-pending" || return $?
    ftctl_dr_vmware_write_checkpoint "${disk_map}" "${manifest_path}" "${checkpoint_path}" "CONFIG_INCOMPLETE" "${now}" "" "" || return $?
    ftctl_dr_runtime_path_set "${state_path}" \
      "driver=VMWARE" \
      "driver_state=CONFIG_INCOMPLETE" \
      "state=CONFIG_INCOMPLETE" \
      "step=vmware-disk-map-pending" \
      "progress=0" \
      "accepted=false" \
      "error_code=DR_TARGET_MAPPING_INVALID" \
      "disk_map_path=${disk_map}" \
      "source_disk_map_path=${disk_map}" \
      "disk_map_role=${disk_map_role}" \
      "source_open_status_path=${source_open_status_path}" \
      "source_snapshot_status_path=${source_snapshot_status_path}" \
      "manifest_path=${manifest_path}" \
      "checkpoint_path=${checkpoint_path}" \
      "updated_at=${now}"
    ftctl_log_event "dr-runtime" "dr.vmware.disk_map" "warn" "" "" \
      "plan=${plan} run=${run} reason=config_incomplete_missing_explicit_disk_map"
    return 0
  fi

  cbt_rc=0
  ftctl_dr_vmware_ensure_cbt_enabled "${plan}" "${run}" "${profile_file}" "${disk_map}" "${cbt_status_path}" || cbt_rc=$?
  if [[ "${cbt_rc}" != "0" ]]; then
    now="$(ftctl_now_iso8601)"
    cbt_error="$(ftctl_dr_vmware_cbt_error_code "${cbt_rc}")"
    ftctl_dr_vmware_write_manifest "${disk_map}" "${capability_path}" "${manifest_path}" "vmware-cbt-preflight-failed" || true
    ftctl_dr_vmware_write_checkpoint "${disk_map}" "${manifest_path}" "${checkpoint_path}" "CBT_PREFLIGHT_FAILED" "${now}" "" "" || true
    ftctl_dr_runtime_path_set "${state_path}" \
      "driver=VMWARE" \
      "driver_state=CBT_PREFLIGHT_FAILED" \
      "state=ERROR" \
      "step=vmware-cbt-preflight" \
      "progress=100" \
      "accepted=false" \
      "error_code=${cbt_error}" \
      "disk_map_path=${disk_map}" \
      "source_disk_map_path=${disk_map}" \
      "disk_map_role=${disk_map_role}" \
      "cbt_status_path=${cbt_status_path}" \
      "source_open_status_path=${source_open_status_path}" \
      "source_snapshot_status_path=${source_snapshot_status_path}" \
      "manifest_path=${manifest_path}" \
      "checkpoint_path=${checkpoint_path}" \
      "updated_at=${now}"
    ftctl_log_event "dr-runtime" "dr.vmware.cbt" "fail" "" "${cbt_rc}" \
      "plan=${plan} run=${run} reason=${cbt_error} status=${cbt_status_path}"
    return "${cbt_rc}"
  fi

  ftctl_dr_vmware_prepare_local_vmdk_targets "${disk_map}" || return $?
  now="$(ftctl_now_iso8601)"
  ftctl_dr_vmware_write_manifest "${disk_map}" "${capability_path}" "${manifest_path}" "vmware-contract-ready" || return $?
  ftctl_dr_vmware_write_checkpoint "${disk_map}" "${manifest_path}" "${checkpoint_path}" "VMWARE_CONTRACT_READY" "${now}" "" "" || return $?
  ftctl_dr_runtime_path_set "${state_path}" \
    "driver=VMWARE" \
    "driver_state=VMWARE_CONTRACT_READY" \
    "step=vmware-driver-contract-ready" \
    "progress=5" \
    "disk_map_path=${disk_map}" \
    "source_disk_map_path=${disk_map}" \
    "disk_map_role=${disk_map_role}" \
    "cbt_status_path=${cbt_status_path}" \
    "source_open_status_path=${source_open_status_path}" \
    "source_snapshot_status_path=${source_snapshot_status_path}" \
    "manifest_path=${manifest_path}" \
    "checkpoint_path=${checkpoint_path}" \
    "last_source_checkpoint_at=${now}" \
    "updated_at=${now}"
  ftctl_log_event "dr-runtime" "dr.vmware.contract" "ok" "" "" \
    "plan=${plan} run=${run} disks=${count} manifest=${manifest_path}"
}
