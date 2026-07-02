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

ftctl_dr_vmware_disk_map_path() {
  local plan="${1-}"
  printf '%s/vmware-disks.json\n' "$(ftctl_dr_runtime_plan_dir "${plan}")"
}

ftctl_dr_vmware_capability_path() {
  local plan="${1-}"
  printf '%s/vmware-capability.json\n' "$(ftctl_dr_runtime_plan_dir "${plan}")"
}

ftctl_dr_vmware_manifest_dir() {
  local plan="${1-}"
  printf '%s/manifests\n' "$(ftctl_dr_runtime_plan_dir "${plan}")"
}

ftctl_dr_vmware_checkpoint_dir() {
  local plan="${1-}"
  printf '%s/checkpoints\n' "$(ftctl_dr_runtime_plan_dir "${plan}")"
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
  command -v nbdkit >/dev/null 2>&1 || return 1
  nbdkit --dump-plugin vddk >/dev/null 2>&1 || nbdkit vddk --help >/dev/null 2>&1
}

ftctl_dr_vmware_write_capability() {
  local out_path="${1-}"
  local govc="0" nbdkit="0" nbdkit_vddk="0" vmware_vdiskmanager="0" vddk_ready="0" missing_code=""

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
    ftctl_dr_vmware_nbdkit_vddk_available && nbdkit_vddk="1"
    command -v vmware-vdiskmanager >/dev/null 2>&1 && vmware_vdiskmanager="1"
    if [[ "${nbdkit_vddk}" == "1" || "${vmware_vdiskmanager}" == "1" ]]; then
      vddk_ready="1"
    fi
  fi

  [[ "${vddk_ready}" == "1" ]] || missing_code="DR_MISSING_VDDK"
  printf '{"govc":%s,"nbdkit":%s,"nbdkitVddk":%s,"vmwareVdiskmanager":%s,"vddkReady":%s,"missingCode":"%s"}\n' \
    "$(ftctl_dr_vmware_bool_json "${govc}")" \
    "$(ftctl_dr_vmware_bool_json "${nbdkit}")" \
    "$(ftctl_dr_vmware_bool_json "${nbdkit_vddk}")" \
    "$(ftctl_dr_vmware_bool_json "${vmware_vdiskmanager}")" \
    "$(ftctl_dr_vmware_bool_json "${vddk_ready}")" \
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
    device = first_str(
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
    "datastoreRef": first_str(target.get("datastoreRef"), target.get("datastore"), mapping.get("targetDatastoreRef"), mapping.get("datastoreRef")),
    "folderPath": first_str(target.get("folderPath"), mapping.get("targetFolderPath"), mapping.get("folderPath")),
    "resourcePoolRef": first_str(target.get("resourcePoolRef"), mapping.get("targetResourcePoolRef"), mapping.get("resourcePoolRef")),
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
capable = bool(capability.get("vddkReady"))
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
    "vddk_ready": capable,
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
  local disk_map="${1-}" capability_path="${2-}" manifest_path="${3-}" phase="${4-}"
  ftctl_ensure_dir "$(dirname "${manifest_path}")" "0755"
  python3 - "${disk_map}" "${capability_path}" "${manifest_path}" "${phase}" "$(ftctl_now_iso8601)" <<'PY'
import json
import os
import sys

disk_map_path, capability_path, manifest_path, phase, now = sys.argv[1:6]
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
tmp = manifest_path + ".tmp"
with open(tmp, "w", encoding="utf-8") as fh:
    json.dump(manifest, fh, sort_keys=True, separators=(",", ":"))
    fh.write("\n")
os.replace(tmp, manifest_path)
PY
}

ftctl_dr_vmware_write_checkpoint() {
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

ftctl_dr_vmware_replication_cycle() {
  local plan="${1-}" run="${2-}" profile_file="${3-}" sequence="${4-}" cycle_type="${5-}"
  local disk_map capability_path manifest_path checkpoint_path cycle_run now mover_rc=0
  local credentials_file=""
  local source_epoch target_epoch rpo="0"

  [[ -n "${plan}" && -n "${run}" && -n "${profile_file}" ]] || return 2
  cycle_run="${run}-cycle-${sequence:-0}"
  disk_map="$(ftctl_dr_vmware_disk_map_path "${plan}")"
  capability_path="$(ftctl_dr_vmware_capability_path "${plan}")"
  manifest_path="$(ftctl_dr_vmware_manifest_path "${plan}" "${cycle_run}")"
  checkpoint_path="$(ftctl_dr_vmware_checkpoint_path "${plan}" "${cycle_run}")"
  [[ -f "${disk_map}" ]] || ftctl_dr_vmware_canonicalize_profile "${profile_file}" "${disk_map}" || return $?
  [[ -f "${capability_path}" ]] || ftctl_dr_vmware_write_capability "${capability_path}" || return $?

  if [[ -n "${FTCTL_DR_VMWARE_MOVER:-}" ]]; then
    credentials_file="$(ftctl_dr_runtime_credential_path "${plan}" 2>/dev/null || true)"
    FTCTL_DR_PLAN_UUID="${plan}" \
    FTCTL_DR_RUN_UUID="${run}" \
    FTCTL_DR_CHECKPOINT_SEQUENCE="${sequence:-0}" \
    FTCTL_DR_CYCLE_TYPE="${cycle_type:-incremental}" \
    FTCTL_DR_DISK_MAP="${disk_map}" \
    FTCTL_DR_CAPABILITY="${capability_path}" \
    FTCTL_DR_MANIFEST="${manifest_path}" \
    FTCTL_DR_CHECKPOINT="${checkpoint_path}" \
    FTCTL_DR_CREDENTIALS_FILE="$([[ -f "${credentials_file}" ]] && printf '%s' "${credentials_file}")" \
      "${FTCTL_DR_VMWARE_MOVER}" || mover_rc=$?
    [[ "${mover_rc}" == "0" ]] || return "${mover_rc}"
  elif [[ "${FTCTL_DR_VMWARE_MOCK_CYCLE:-0}" == "1" ]]; then
    :
  else
    ftctl_log_event "dr-runtime" "dr.vmware.mover" "fail" "" "65" \
      "plan=${plan} run=${run} reason=DR_VMWARE_MOVER_UNAVAILABLE"
    return 65
  fi

  now="$(ftctl_now_iso8601)"
  ftctl_dr_vmware_write_manifest "${disk_map}" "${capability_path}" "${manifest_path}" "vmware-${cycle_type:-incremental}-complete" || return $?
  source_epoch="$(ftctl_iso_to_epoch "${now}" 2>/dev/null || printf '0')"
  target_epoch="$(ftctl_iso_to_epoch "${now}" 2>/dev/null || printf '0')"
  if [[ "${source_epoch}" =~ ^[0-9]+$ && "${target_epoch}" =~ ^[0-9]+$ && "${target_epoch}" -ge "${source_epoch}" ]]; then
    rpo="$((target_epoch - source_epoch))"
  fi
  ftctl_dr_vmware_write_checkpoint "${disk_map}" "${manifest_path}" "${checkpoint_path}" "TARGET_READY" "${now}" "${now}" "${rpo}" || return $?
  ftctl_log_event "dr-runtime" "dr.vmware.cycle" "ok" "" "" \
    "plan=${plan} run=${run} sequence=${sequence:-0} type=${cycle_type:-incremental} checkpoint=${checkpoint_path} rpo=${rpo}"
  printf '%s\t%s\n' "${manifest_path}" "${checkpoint_path}"
}

ftctl_dr_vmware_sync_start() {
  local plan="${1-}" run="${2-}" profile_file="${3-}" state_path="${4-}" wait_value="${5-}"
  local disk_map capability_path manifest_path checkpoint_path count now vddk_ready missing_code
  : "${wait_value}"

  [[ -n "${profile_file}" && -f "${profile_file}" ]] || return 0
  ftctl_dr_vmware_profile_involves_vmware "${profile_file}" || return 0

  ftctl_dr_runtime_ensure_plan_dirs "${plan}"
  ftctl_ensure_dir "$(ftctl_dr_vmware_manifest_dir "${plan}")" "0755"
  ftctl_ensure_dir "$(ftctl_dr_vmware_checkpoint_dir "${plan}")" "0755"
  disk_map="$(ftctl_dr_vmware_disk_map_path "${plan}")"
  capability_path="$(ftctl_dr_vmware_capability_path "${plan}")"
  manifest_path="$(ftctl_dr_vmware_manifest_path "${plan}" "${run}")"
  checkpoint_path="$(ftctl_dr_vmware_checkpoint_path "${plan}" "${run}")"

  ftctl_dr_vmware_canonicalize_profile "${profile_file}" "${disk_map}" || return $?
  ftctl_dr_vmware_write_capability "${capability_path}" || return $?
  vddk_ready="$(ftctl_dr_vmware_capability_value "${capability_path}" "vddkReady" || true)"
  missing_code="$(ftctl_dr_vmware_capability_value "${capability_path}" "missingCode" || true)"
  count="$(ftctl_dr_vmware_disk_count "${disk_map}")" || count="0"

  if [[ "${vddk_ready}" != "true" ]]; then
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
    ftctl_dr_vmware_write_checkpoint "${disk_map}" "${manifest_path}" "${checkpoint_path}" "WAITING_FOR_VMWARE_DISK_MAP" "${now}" "" "" || return $?
    ftctl_dr_runtime_path_set "${state_path}" \
      "driver=VMWARE" \
      "driver_state=WAITING_FOR_VMWARE_DISK_MAP" \
      "step=vmware-disk-map-pending" \
      "progress=1" \
      "disk_map_path=${disk_map}" \
      "manifest_path=${manifest_path}" \
      "checkpoint_path=${checkpoint_path}" \
      "updated_at=${now}"
    ftctl_log_event "dr-runtime" "dr.vmware.disk_map" "warn" "" "" \
      "plan=${plan} run=${run} reason=missing_explicit_disk_map"
    return 0
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
    "manifest_path=${manifest_path}" \
    "checkpoint_path=${checkpoint_path}" \
    "last_source_checkpoint_at=${now}" \
    "updated_at=${now}"
  ftctl_log_event "dr-runtime" "dr.vmware.contract" "ok" "" "" \
    "plan=${plan} run=${run} disks=${count} manifest=${manifest_path}"
}
