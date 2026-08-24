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

def join_path(base, name, suffix=""):
    base = str(base or "").rstrip("/")
    name = str(name or "").strip().lstrip("/")
    if not base or not name:
        return ""
    return f"{base}/{name}{suffix}"

def rbd_pool_from_ref(value):
    text = str(value or "").strip()
    if not text:
        return ""
    if text.startswith("rbd:"):
        text = text[4:]
    elif text.startswith("rbd/"):
        text = text[4:]
    elif text.startswith("/dev/rbd/"):
        text = text[len("/dev/rbd/"):]
    text = text.strip("/")
    if not text or text.startswith("/"):
        return ""
    return text.split("/", 1)[0]

def derive_target_path(target_name, storage_ref, storage_path, krbd_path, pool_type):
    name = str(target_name or "").strip()
    if not name:
        return ""
    pool_text = str(pool_type or "").upper()
    krbd_text = str(krbd_path or "").strip()
    path_text = str(storage_path or "").strip()
    storage_text = str(storage_ref or "").strip()
    if "RBD" in pool_text and krbd_text:
        pool_name = rbd_pool_from_ref(path_text) or rbd_pool_from_ref(storage_text)
        if krbd_text.rstrip("/") == "/dev/rbd" and pool_name:
            return join_path("/dev/rbd/" + pool_name, name)
        return join_path(krbd_text, name)
    if "RBD" in pool_text and (path_text.startswith("rbd:") or path_text.startswith("rbd/")):
        return join_path(path_text, name)
    if "RBD" in pool_text and path_text and not path_text.startswith("/"):
        return join_path("rbd/" + path_text.strip("/"), name)
    if "RBD" in pool_text and (storage_text.startswith("rbd:") or storage_text.startswith("rbd/")):
        return join_path(storage_text, name)
    if path_text.startswith("/"):
        suffix = "" if name.endswith((".qcow2", ".raw")) else ".qcow2"
        return join_path(path_text, name, suffix)
    if path_text.startswith("rbd:") or path_text.startswith("rbd/"):
        return join_path(path_text, name)
    if storage_text.startswith("/") or storage_text.startswith("rbd:") or storage_text.startswith("rbd/"):
        suffix = "" if storage_text.startswith(("rbd:", "rbd/")) or name.endswith((".qcow2", ".raw")) else ".qcow2"
        return join_path(storage_text, name, suffix)
    return ""

def first_networks(*values):
    out = []
    for value in values:
        for item in arr(value):
            item = obj(item)
            network_ref = first_str(value_at(item, "networkId", "networkRef", "id", "uuid", "value", "ref"))
            if network_ref:
                out.append({
                    "networkId": network_ref,
                    "role": first_str(value_at(item, "role"), "default"),
                })
    return out

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
    target_name = first_str(
        value_at(item, "targetName", "targetDiskName", "targetRef"),
        value_at(target, "name", "targetName", "ref"),
    )
    if not target_name and target_path:
        target_name = os.path.basename(target_path.rstrip("/"))
    target_storage_ref = first_str(
        value_at(item, "targetStorageRef", "targetStorage", "targetDatastoreRef"),
        value_at(target, "storageRef", "storagePoolId", "datastoreRef", "targetStorageRef"),
    )
    target_storage_path = first_str(
        value_at(item, "targetStoragePath", "storagePath"),
        value_at(target, "storagePath", "pathPrefix"),
    )
    target_storage_krbd_path = first_str(
        value_at(item, "targetStorageKrbdPath", "krbdPath"),
        value_at(target, "krbdPath"),
    )
    target_storage_type = first_str(
        value_at(item, "targetStorageType", "storagePoolType"),
        value_at(target, "storagePoolType", "poolType"),
    )
    if not target_path:
        target_path = derive_target_path(target_name, target_storage_ref, target_storage_path, target_storage_krbd_path, target_storage_type)
    elif "RBD" in str(target_storage_type or "").upper() and target_path.startswith("/dev/rbd/"):
        rbd_suffix = target_path[len("/dev/rbd/"):].strip("/")
        if rbd_suffix and "/" not in rbd_suffix:
            derived_target_path = derive_target_path(target_name or rbd_suffix, target_storage_ref, target_storage_path, target_storage_krbd_path, target_storage_type)
            if derived_target_path:
                target_path = derived_target_path
    elif "RBD" in str(target_storage_type or "").upper() and not (
        target_path.startswith("rbd:") or target_path.startswith("rbd/") or target_path.startswith("/dev/rbd/")
    ):
        derived_target_path = derive_target_path(target_name, target_storage_ref, target_storage_path, target_storage_krbd_path, target_storage_type)
        if derived_target_path:
            target_path = derived_target_path
    device = first_str(
        value_at(item, "device", "targetDevice", "diskTarget", "sourceDevice"),
        value_at(source, "device", "targetDevice"),
        value_at(target, "device", "targetDevice"),
        f"disk{index}",
    )
    source_type = infer_disk_type(source_path)
    target_type = first_str(
        value_at(item, "targetType", "type"),
        value_at(target, "targetType", "type"),
        infer_disk_type(target_path),
    ).lower()
    if "RBD" in str(target_storage_type or "").upper() and target_path:
        target_type = "rbd"
    source_format = first_str(
        value_at(item, "sourceFormat", "format"),
        value_at(source, "format", "sourceFormat"),
        infer_format(source_path, source_type),
    )
    target_format = first_str(
        value_at(item, "targetFormat"),
        value_at(target, "format", "targetFormat"),
        "raw" if target_type == "rbd" else "",
        infer_format(target_path, target_type),
        source_format if target_type == "file" else "",
    )
    target_disk_offering_id = first_str(
        value_at(item, "targetDiskOfferingId", "diskOfferingId"),
        value_at(target, "diskOfferingId", "diskOfferingRef", "offeringId"),
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
        "targetName": target_name,
        "targetStorageRef": target_storage_ref,
        "targetStoragePath": target_storage_path,
        "targetStorageKrbdPath": target_storage_krbd_path,
        "targetStorageType": target_storage_type,
        "targetDiskOfferingId": target_disk_offering_id,
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
mapping_target = obj(mapping.get("target"))
transport = obj(profile.get("transport"))

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
    "source": {
        "externalRef": first_str(source.get("externalRef"), source.get("vmUuid"), source.get("vmId")),
        "instanceName": first_str(source.get("instanceName"), obj(source.get("hardware")).get("instanceName")),
        "hostUuid": first_str(source.get("hostUuid"), obj(source.get("hardware")).get("sourceHostUuid")),
    },
    "target": {
        "siteId": first_str(target.get("siteId"), mapping_target.get("siteId")),
        "siteUuid": first_str(target.get("siteUuid"), mapping_target.get("siteUuid")),
        "zoneId": first_str(target.get("zoneId"), mapping_target.get("zoneId"), mapping.get("targetZoneId")),
        "workerHostId": first_str(target.get("workerHostId"), mapping_target.get("workerHostId"), mapping.get("targetWorkerHostId")),
        "vmName": first_str(target.get("vmName"), mapping_target.get("vmName"), mapping.get("targetVmName")),
        "storageRef": first_str(target.get("storageRef"), target.get("storagePoolId"), mapping_target.get("storageRef"), mapping_target.get("storagePoolId"), mapping.get("targetStorageRef"), mapping.get("targetDatastoreRef")),
        "serviceOfferingId": first_str(target.get("serviceOfferingId"), mapping_target.get("serviceOfferingId"), mapping.get("targetComputeRef")),
        "networks": first_networks(target.get("networks"), mapping_target.get("networks")),
    },
    "transport": {
        "mode": first_str(transport.get("mode"), "local"),
        "targetHostUuid": first_str(transport.get("targetHostUuid")),
        "targetHostAddress": first_str(transport.get("targetHostAddress")),
        "secondaryUri": first_str(transport.get("secondaryUri")),
        "sshUser": first_str(transport.get("sshUser"), "root"),
        "sshPort": first_str(transport.get("sshPort"), "22"),
        "sshKeyFile": first_str(transport.get("sshKeyFile")),
        "remoteNbdExportAddress": first_str(transport.get("remoteNbdExportAddress"), transport.get("targetHostAddress")),
        "targetStorageScope": first_str(transport.get("targetStorageScope"), "secondary-local"),
    },
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

ftctl_dr_ablestack_missing_config() {
  local disk_map="${1-}"
  [[ -n "${disk_map}" && -f "${disk_map}" ]] || return 1
  python3 - "${disk_map}" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as fh:
    data = json.load(fh)

def text(value):
    return str(value or "").strip()

missing = []
target_provider = text(data.get("targetProvider")).upper()
target = data.get("target") if isinstance(data.get("target"), dict) else {}
disks = data.get("disks") if isinstance(data.get("disks"), list) else []

if target_provider == "ABLESTACK":
    if not text(target.get("zoneId")):
        missing.append("TARGET_SITE_ZONE_REQUIRED")
    if not text(target.get("storageRef")):
        missing.append("TARGET_STORAGE_REQUIRED")
    if not text(target.get("serviceOfferingId")):
        missing.append("TARGET_SERVICE_OFFERING_REQUIRED")
    if not target.get("networks"):
        missing.append("TARGET_NETWORK_REQUIRED")
    if not disks:
        missing.append("DISK_MAPPING_REQUIRED")
    for index, disk in enumerate(disks):
        if not isinstance(disk, dict):
            missing.append(f"DISK_MAPPING_REQUIRED:{index}")
            continue
        if not text(disk.get("sourcePath")):
            missing.append(f"DISK_SOURCE_REQUIRED:{index}")
        if not text(disk.get("targetName")) and not text(disk.get("targetPath")):
            missing.append(f"DISK_TARGET_REQUIRED:{index}")
        if not text(disk.get("targetPath")):
            missing.append(f"DISK_TARGET_PATH_REQUIRED:{index}")
        if not text(disk.get("targetStorageRef")) and not text(target.get("storageRef")):
            missing.append(f"TARGET_STORAGE_REQUIRED:{index}")
        if not text(disk.get("targetDiskOfferingId")):
            missing.append(f"TARGET_DISK_OFFERING_REQUIRED:{index}")

print(",".join(missing))
PY
}

ftctl_dr_ablestack_disk_preflight_error() {
  local disk_map="${1-}"
  [[ -n "${disk_map}" && -f "${disk_map}" ]] || {
    printf 'DR_TARGET_DISK_MAPPING_INVALID:disk_map_missing\n'
    return 0
  }
  python3 - "${disk_map}" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as fh:
    data = json.load(fh)

def text(value):
    return str(value or "").strip()

source_provider = text(data.get("sourceProvider")).upper()
target_provider = text(data.get("targetProvider")).upper()
disks = data.get("disks") if isinstance(data.get("disks"), list) else []
errors = []
if target_provider == "ABLESTACK":
    if not disks:
        errors.append("DR_TARGET_DISK_MAPPING_INVALID:disks")
    for index, disk in enumerate(disks):
        if not isinstance(disk, dict):
            errors.append(f"DR_TARGET_DISK_MAPPING_INVALID:{index}")
            continue
        target_type = text(disk.get("targetType")).lower()
        target_storage_type = text(disk.get("targetStorageType")).upper()
        target_path = text(disk.get("targetPath"))
        target_name = text(disk.get("targetName"))
        source_path = text(disk.get("sourcePath"))
        try:
            size = int(disk.get("sizeBytes") or 0)
        except (TypeError, ValueError):
            size = 0
        if not source_path or (not target_path and not target_name):
            errors.append(f"DR_TARGET_DISK_MAPPING_INVALID:{index}")
        if target_storage_type == "RBD" and target_type != "rbd":
            errors.append(f"DR_TARGET_DISK_TYPE_INVALID:{index}")
        if not target_type:
            errors.append(f"DR_TARGET_DISK_TYPE_INVALID:{index}")
        if source_provider == "VMWARE" and size <= 0:
            errors.append(f"DR_TARGET_DISK_SIZE_UNRESOLVED:{index}")

print(",".join(errors))
PY
}

ftctl_dr_ablestack_disk_preflight_rc() {
  local error_text="${1-}"
  case "${error_text}" in
    *DR_TARGET_DISK_SIZE_UNRESOLVED*) printf '33\n' ;;
    *DR_TARGET_DISK_TYPE_INVALID*) printf '32\n' ;;
    *DR_TARGET_STORAGE_UNRESOLVED*) printf '35\n' ;;
    *DR_TARGET_DISK_MAPPING_INVALID*) printf '31\n' ;;
    *) printf '31\n' ;;
  esac
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
    print(json.dumps({
        key: str(disk.get(key, "") or "") for key in (
            "device", "sourcePath", "targetPath", "sourceFormat", "targetFormat",
            "sizeBytes", "sourceType", "targetType"
        )
    }, sort_keys=True, separators=(",", ":")))
PY
}

ftctl_dr_ablestack_disk_json_field() {
  local disk_json="${1-}" field="${2-}"
  python3 - "${disk_json}" "${field}" <<'PY'
import json
import sys

try:
    disk = json.loads(sys.argv[1])
except Exception:
    disk = {}
value = disk.get(sys.argv[2], "")
print("" if value is None else str(value))
PY
}

ftctl_dr_ablestack_json_field() {
  local json_path="${1-}" field_path="${2-}"
  [[ -f "${json_path}" && -n "${field_path}" ]] || return 1
  python3 - "${json_path}" "${field_path}" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as fh:
    value = json.load(fh)
for key in sys.argv[2].split("."):
    value = value.get(key) if isinstance(value, dict) else None
    if value is None:
        break
print("" if value is None else str(value))
PY
}

ftctl_dr_ablestack_remote_transport_load() {
  local disk_map="${1-}" mode host port
  mode="$(ftctl_dr_ablestack_json_field "${disk_map}" transport.mode 2>/dev/null || true)"
  [[ "${mode}" == "remote-nbd" ]] || return 1
  host="$(ftctl_dr_ablestack_json_field "${disk_map}" transport.targetHostAddress 2>/dev/null || true)"
  port="$(ftctl_dr_ablestack_json_field "${disk_map}" transport.sshPort 2>/dev/null || true)"
  [[ -n "${host}" ]] || return 2
  FTCTL_PROFILE_BACKEND_MODE="remote-nbd"
  FTCTL_PROFILE_PROVISIONING_BACKEND="cloud-managed"
  FTCTL_PROFILE_TARGET_STORAGE_SCOPE="secondary-local"
  FTCTL_PROFILE_SECONDARY_URI="$(ftctl_dr_ablestack_json_field "${disk_map}" transport.secondaryUri)"
  FTCTL_PROFILE_SECONDARY_SSH_KEY_FILE="$(ftctl_dr_ablestack_json_field "${disk_map}" transport.sshKeyFile)"
  FTCTL_PROFILE_REMOTE_NBD_EXPORT_ADDR="$(ftctl_dr_ablestack_json_field "${disk_map}" transport.remoteNbdExportAddress)"
  FTCTL_PROFILE_FENCING_SSH_USER="$(ftctl_dr_ablestack_json_field "${disk_map}" transport.sshUser)"
  FTCTL_PROFILE_REMOTE_NBD_EXPORT_PORT="auto"
  FTCTL_PROFILE_REMOTE_NBD_EXPORT_NAME="dr-rbd"
  FTCTL_PROFILE_SECONDARY_TARGET_DIR="/dev/rbd"
  [[ "${port}" == "22" || -z "${port}" ]] || FTCTL_PROFILE_SECONDARY_URI="qemu+ssh://${FTCTL_PROFILE_FENCING_SSH_USER}@${host}:${port}/system"
  return 0
}

ftctl_dr_ablestack_remote_rbd_path() {
  local target_path="${1-}" out_var="${2}" spec=""
  ftctl_dr_ablestack_rbd_spec_from_path "${target_path}" spec || return 1
  printf -v "${out_var}" '/dev/rbd/%s' "${spec}"
}

ftctl_dr_ablestack_remote_nbd_stop() {
  local vm="${1-}" device="${2-}" port="${3-}" host="" user="" out="" err="" rc=0 pid_file=""
  ftctl_blockcopy_remote_target_host_user host user || return 2
  pid_file="/run/ablestack-vm-ftctl/nbd-${vm}-${device}.pid"
  ftctl_blockcopy_remote_exec "${host}" "${user}" out err rc "$(cat <<EOF
set -euo pipefail
if [[ -f '${pid_file}' ]]; then
  pid=\$(cat '${pid_file}' 2>/dev/null || true)
  [[ -z \"\${pid}\" ]] || kill \"\${pid}\" >/dev/null 2>&1 || true
  rm -f '${pid_file}'
fi
for pid in \$(ss -lntp | awk '/:${port}[[:space:]]/ {while (match(\$0,/pid=[0-9]+/)){print substr(\$0,RSTART+4,RLENGTH-4);\$0=substr(\$0,RSTART+RLENGTH)}}' | sort -u); do
  kill \"\${pid}\" >/dev/null 2>&1 || true
done
EOF
)" || true
  [[ "${rc}" == "0" ]]
}

ftctl_dr_ablestack_append_disk_record() {
  local records_path="${1-}" disk_json="${2-}" source_format="${3-}" target_format="${4-}" resolved_size="${5-}" source_type="${6-}" target_type="${7-}"
  python3 - "${records_path}" "${disk_json}" "${source_format}" "${target_format}" "${resolved_size}" "${source_type}" "${target_type}" <<'PY'
import json
import sys

records_path, disk_json, source_format, target_format, resolved_size, source_type, target_type = sys.argv[1:8]
disk = json.loads(disk_json)
disk.update({
    "sourceFormat": source_format,
    "targetFormat": target_format,
    "sizeBytes": int(resolved_size or "0"),
    "sourceType": source_type,
    "targetType": target_type,
})
with open(records_path, "a", encoding="utf-8") as fh:
    json.dump(disk, fh, sort_keys=True, separators=(",", ":"))
    fh.write("\n")
PY
}

ftctl_dr_ablestack_rbd_spec_from_path() {
  local path="${1-}" out_var="${2}"
  local rbd_spec=""
  case "${path}" in
    rbd:*) rbd_spec="${path#rbd:}" ;;
    /dev/rbd/*/*) rbd_spec="${path#/dev/rbd/}" ;;
    rbd/*/*) rbd_spec="${path#rbd/}" ;;
    *) return 1 ;;
  esac
  [[ "${rbd_spec}" == */* && "${rbd_spec}" != */ ]] || return 1
  printf -v "${out_var}" '%s' "${rbd_spec}"
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

ftctl_dr_ablestack_error_code_for_rc() {
  local rc="${1-}"
  case "${rc}" in
    31) printf 'DR_TARGET_DISK_MAPPING_INVALID\n' ;;
    32) printf 'DR_TARGET_DISK_TYPE_INVALID\n' ;;
    33) printf 'DR_TARGET_DISK_SIZE_UNRESOLVED\n' ;;
    34) printf 'DR_TARGET_DISK_PREPARE_FAILED\n' ;;
    35) printf 'DR_TARGET_STORAGE_UNRESOLVED\n' ;;
    *) printf 'DR_ABLESTACK_DRIVER_FAILED\n' ;;
  esac
}

ftctl_dr_ablestack_mark_driver_error() {
  local state_path="${1-}" rc="${2-}" step="${3-}" message="${4-}"
  local error_code
  error_code="$(ftctl_dr_ablestack_error_code_for_rc "${rc}")"
  ftctl_dr_runtime_path_set "${state_path}" \
    "driver=ABLESTACK" \
    "driver_state=ERROR" \
    "state=ERROR" \
    "step=${step:-ablestack-driver-failed}" \
    "progress=100" \
    "accepted=false" \
    "error_code=${error_code}" \
    "error_message=${message:-ABLESTACK target driver failed}" \
    "driver_exit_code=${rc}" \
    "updated_at=$(ftctl_now_iso8601)" || true
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
            line = line.rstrip("\n")
            if not line:
                continue
            try:
                record = json.loads(line)
            except json.JSONDecodeError:
                parts = line.split("\t")
                if len(parts) < 8:
                    continue
                record = {
                    "device": parts[0],
                    "sourcePath": parts[1],
                    "targetPath": parts[2],
                    "sourceFormat": parts[3],
                    "targetFormat": parts[4],
                    "sizeBytes": int(parts[5] or "0"),
                    "sourceType": parts[6],
                    "targetType": parts[7],
                }
            device = str(record.get("device") or "")
            if device:
                records[device] = record

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
    "target": disk_map.get("target", {}),
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
  local records_path count disk_json device source_path target_path source_format target_format size_bytes source_type target_type resolved_size
  local source_at remote_transport="0"

  ftctl_dr_ablestack_canonicalize_profile "${profile_file}" "${disk_map}" || return $?
  if ftctl_dr_ablestack_remote_transport_load "${disk_map}"; then
    remote_transport="1"
  fi
  count="$(ftctl_dr_ablestack_disk_count "${disk_map}")" || return $?
  if [[ "${count}" == "0" ]]; then
    ftctl_log_event "dr-runtime" "dr.ablestack.disk_map" "warn" "" "" \
      "plan=${plan} run=${run} reason=missing_explicit_disk_map"
    return 30
  fi

  ftctl_ensure_dir "$(dirname "${manifest_path}")" "0755"
  records_path="${manifest_path}.records.jsonl"
  : > "${records_path}"
  while IFS= read -r disk_json; do
    device="$(ftctl_dr_ablestack_disk_json_field "${disk_json}" device)"
    source_path="$(ftctl_dr_ablestack_disk_json_field "${disk_json}" sourcePath)"
    target_path="$(ftctl_dr_ablestack_disk_json_field "${disk_json}" targetPath)"
    source_format="$(ftctl_dr_ablestack_disk_json_field "${disk_json}" sourceFormat)"
    target_format="$(ftctl_dr_ablestack_disk_json_field "${disk_json}" targetFormat)"
    size_bytes="$(ftctl_dr_ablestack_disk_json_field "${disk_json}" sizeBytes)"
    source_type="$(ftctl_dr_ablestack_disk_json_field "${disk_json}" sourceType)"
    target_type="$(ftctl_dr_ablestack_disk_json_field "${disk_json}" targetType)"
    [[ -n "${device}" ]] || continue
    if [[ -z "${source_path}" || -z "${target_path}" ]]; then
      ftctl_log_event "dr-runtime" "dr.ablestack.disk_map" "fail" "" "31" \
        "plan=${plan} run=${run} device=${device} reason=missing_source_or_target_path"
      return 31
    fi
    [[ -n "${target_format}" ]] || target_format="${source_format:-raw}"
    if [[ -z "${target_type}" ]]; then
      ftctl_log_event "dr-runtime" "dr.ablestack.disk_map" "fail" "" "32" \
        "plan=${plan} run=${run} device=${device} target=${target_path} reason=missing_target_type"
      return 32
    fi
    resolved_size=""
    if ! ftctl_dr_ablestack_source_size_bytes "${device}" "${source_path}" "${size_bytes}" resolved_size; then
      ftctl_log_event "dr-runtime" "dr.ablestack.source_size" "fail" "" "33" \
        "plan=${plan} run=${run} device=${device} source=${source_path} explicit_size=${size_bytes:-0}"
      return 33
    fi
    if [[ "${remote_transport}" != "1" ]] &&
       ! ftctl_dr_ablestack_prepare_target "${target_path}" "${target_format}" "${resolved_size}" "${target_type}"; then
      ftctl_log_event "dr-runtime" "dr.ablestack.target_prepare" "fail" "" "34" \
        "plan=${plan} run=${run} device=${device} target=${target_path} target_type=${target_type} size=${resolved_size}"
      return 34
    fi
    ftctl_dr_ablestack_append_disk_record "${records_path}" "${disk_json}" \
      "${source_format}" "${target_format}" "${resolved_size}" "${source_type}" "${target_type}"
  done < <(ftctl_dr_ablestack_disk_rows "${disk_map}")

  ftctl_dr_ablestack_write_manifest "${disk_map}" "${records_path}" "${manifest_path}" "target-prepared" || return $?
  source_at="$(ftctl_now_iso8601)"
  ftctl_dr_ablestack_write_checkpoint "${disk_map}" "${manifest_path}" "${checkpoint_path}" "TARGET_PREPARED" "${source_at}" "" "" || return $?
  ftctl_log_event "dr-runtime" "dr.ablestack.targets_prepared" "ok" "" "" \
    "plan=${plan} run=${run} disks=${count} manifest=${manifest_path} remote_transport=${remote_transport}"
}

ftctl_dr_ablestack_full_seed_once() {
  local plan="${1-}" run="${2-}" profile_file="${3-}" disk_map="${4-}" manifest_path="${5-}" checkpoint_path="${6-}"
  local disk_json device source_path target_path source_format target_format size_bytes source_type target_type resolved_size target_uri
  local out="" err="" rc=0 source_at target_at source_epoch target_epoch rpo="0"
  local remote_transport="0" remote_path="" export_name="" export_port="" vm_name=""

  ftctl_dr_ablestack_prepare_targets "${plan}" "${run}" "${profile_file}" "${disk_map}" "${manifest_path}" "${checkpoint_path}" || return $?
  if ftctl_dr_ablestack_remote_transport_load "${disk_map}"; then
    remote_transport="1"
  fi
  vm_name="$(ftctl_dr_ablestack_json_field "${disk_map}" source.instanceName 2>/dev/null || true)"
  [[ -n "${vm_name}" ]] || vm_name="dr-${plan}"
  source_at="$(ftctl_now_iso8601)"
  while IFS= read -r disk_json; do
    device="$(ftctl_dr_ablestack_disk_json_field "${disk_json}" device)"
    source_path="$(ftctl_dr_ablestack_disk_json_field "${disk_json}" sourcePath)"
    target_path="$(ftctl_dr_ablestack_disk_json_field "${disk_json}" targetPath)"
    source_format="$(ftctl_dr_ablestack_disk_json_field "${disk_json}" sourceFormat)"
    target_format="$(ftctl_dr_ablestack_disk_json_field "${disk_json}" targetFormat)"
    size_bytes="$(ftctl_dr_ablestack_disk_json_field "${disk_json}" sizeBytes)"
    source_type="$(ftctl_dr_ablestack_disk_json_field "${disk_json}" sourceType)"
    target_type="$(ftctl_dr_ablestack_disk_json_field "${disk_json}" targetType)"
    [[ -n "${device}" ]] || continue
    : "${size_bytes}${source_type}${target_type}"
    [[ -n "${source_format}" ]] || source_format="raw"
    [[ -n "${target_format}" ]] || target_format="${source_format}"
    resolved_size=""
    ftctl_dr_ablestack_source_size_bytes "${device}" "${source_path}" "" resolved_size || return $?
    if [[ "${remote_transport}" == "1" ]]; then
      ftctl_dr_ablestack_remote_rbd_path "${target_path}" remote_path || return 35
      FTCTL_PROFILE_DISK_MAP="${device}=${remote_path}"
      export_name="dr-${plan//[^A-Za-z0-9]/}-${device}"
      ftctl_blockcopy_remote_nbd_pick_port "${vm_name}" "${device}" export_port || return $?
      ftctl_blockcopy_remote_nbd_prepare_target "${vm_name}" "${device}" "${source_path}" \
        "${source_format}" "${remote_path}" "${export_name}" "${export_port}" || return $?
      target_uri="$(ftctl_blockcopy_remote_nbd_uri "${FTCTL_PROFILE_REMOTE_NBD_EXPORT_ADDR}" "${export_port}" "${export_name}")"
    else
      ftctl_dr_ablestack_target_uri_for_qemu "${target_path}" target_uri
    fi
    out=""
    err=""
    rc=0
    ftctl_cmd_run "${FTCTL_DR_FULL_SEED_TIMEOUT_SEC:-3600}" out err rc -- \
      qemu-img convert --force-share -p -n -S "${FTCTL_THIN_SPARSE_SIZE:-4k}" \
      -f "${source_format}" -O "${target_format}" "${source_path}" "${target_uri}" || true
    : "${out}${err}${resolved_size}"
    if [[ "${remote_transport}" == "1" ]]; then
      ftctl_dr_ablestack_remote_nbd_stop "${vm_name}" "${device}" "${export_port}" || true
    fi
    [[ "${rc}" == "0" ]] || return "${rc}"
  done < <(ftctl_dr_ablestack_disk_rows "${disk_map}")

  target_at="$(ftctl_now_iso8601)"
  source_epoch="$(ftctl_iso_to_epoch "${source_at}" 2>/dev/null || printf '0')"
  target_epoch="$(ftctl_iso_to_epoch "${target_at}" 2>/dev/null || printf '0')"
  if [[ "${source_epoch}" =~ ^[0-9]+$ && "${target_epoch}" =~ ^[0-9]+$ && "${target_epoch}" -ge "${source_epoch}" ]]; then
    rpo="$((target_epoch - source_epoch))"
  fi
  ftctl_dr_ablestack_write_manifest "${disk_map}" "${manifest_path}.records.jsonl" "${manifest_path}" "full-seed-complete" || return $?
  ftctl_dr_ablestack_write_checkpoint "${disk_map}" "${manifest_path}" "${checkpoint_path}" "TARGET_READY" "${source_at}" "${target_at}" "${rpo}" || return $?
  if [[ "${remote_transport}" == "1" ]]; then
    ftctl_dr_ablestack_initialize_baselines "${plan}" "${run}" "${disk_map}" || return $?
  fi
  ftctl_log_event "dr-runtime" "dr.ablestack.full_seed" "ok" "" "" \
    "plan=${plan} run=${run} checkpoint=${checkpoint_path} rpo=${rpo}"
}

ftctl_dr_ablestack_baseline_path() {
  local plan="${1-}" device="${2-}"
  printf '%s/baseline-%s.snap\n' "$(ftctl_dr_ablestack_checkpoint_dir "${plan}")" "$(ftctl_dr_runtime_key "${device}")"
}

ftctl_dr_ablestack_snapshot_name() {
  local plan="${1-}" sequence="${2-}"
  printf 'ftctl-dr-%s-%s\n' "$(printf '%s' "${plan}" | cksum | awk '{print $1}')" "${sequence:-0}"
}

ftctl_dr_ablestack_remote_rbd_command() {
  local command_text="${1-}" out_var="${2}" err_var="${3}" rc_var="${4}" host="" user=""
  ftctl_blockcopy_remote_target_host_user host user || return 2
  ftctl_blockcopy_remote_exec "${host}" "${user}" "${out_var}" "${err_var}" "${rc_var}" "${command_text}" || true
}

ftctl_dr_ablestack_reset_baseline_snapshot() {
  local source_spec="${1-}" target_spec="${2-}" snap="${3-}" out="" err="" rc=0
  [[ -n "${source_spec}" && -n "${target_spec}" && -n "${snap}" ]] || return 2
  rbd snap rm "${source_spec}@${snap}" >/dev/null 2>&1 || true
  ftctl_dr_ablestack_remote_rbd_command \
    "rbd snap rm '${target_spec}@${snap}' >/dev/null 2>&1 || true" out err rc
  [[ "${rc}" == "0" ]]
}

ftctl_dr_ablestack_initialize_baselines() {
  local plan="${1-}" sequence="${2-}" disk_map="${3-}" snap="" disk_json device source_path target_path source_spec target_spec baseline previous
  local out="" err="" rc=0
  snap="$(ftctl_dr_ablestack_snapshot_name "${plan}" "${sequence}")"
  while IFS= read -r disk_json; do
    device="$(ftctl_dr_ablestack_disk_json_field "${disk_json}" device)"
    source_path="$(ftctl_dr_ablestack_disk_json_field "${disk_json}" sourcePath)"
    target_path="$(ftctl_dr_ablestack_disk_json_field "${disk_json}" targetPath)"
    ftctl_dr_ablestack_rbd_spec_from_path "${source_path}" source_spec || return 32
    ftctl_dr_ablestack_rbd_spec_from_path "${target_path}" target_spec || return 32
    baseline="$(ftctl_dr_ablestack_baseline_path "${plan}" "${device}")"
    if [[ -s "${baseline}" ]]; then
      previous="$(head -n 1 "${baseline}")"
      ftctl_dr_ablestack_reset_baseline_snapshot "${source_spec}" "${target_spec}" "${previous}" || return $?
    fi
    ftctl_dr_ablestack_reset_baseline_snapshot "${source_spec}" "${target_spec}" "${snap}" || return $?
    rbd snap create "${source_spec}@${snap}" || return $?
    ftctl_dr_ablestack_remote_rbd_command "rbd snap create '${target_spec}@${snap}'" out err rc
    if [[ "${rc}" != "0" ]]; then
      rbd snap rm "${source_spec}@${snap}" >/dev/null 2>&1 || true
      return "${rc}"
    fi
    printf '%s\n' "${snap}" > "${baseline}"
  done < <(ftctl_dr_ablestack_disk_rows "${disk_map}")
}

ftctl_dr_ablestack_incremental_once() {
  local plan="${1-}" run="${2-}" profile_file="${3-}" disk_map="${4-}" manifest_path="${5-}" checkpoint_path="${6-}" sequence="${7-}"
  local disk_json device source_path target_path source_spec target_spec baseline previous current host user ssh_host ssh_port ssh_port_args identity_args
  local out="" err="" rc=0 changed_bytes="0" started_at completed_at
  ftctl_dr_ablestack_canonicalize_profile "${profile_file}" "${disk_map}" || return $?
  ftctl_dr_ablestack_remote_transport_load "${disk_map}" || return 90
  ftctl_blockcopy_remote_target_host_user host user || return 2
  ftctl_blockcopy_split_ssh_host_port "${host}" ssh_host ssh_port
  ssh_port_args=""
  [[ -z "${ssh_port}" ]] || printf -v ssh_port_args -- '-p %q ' "${ssh_port}"
  ftctl_blockcopy_dr_ssh_identity_args identity_args "$(ftctl_dr_ablestack_json_field "${disk_map}" source.instanceName)" || true
  current="$(ftctl_dr_ablestack_snapshot_name "${plan}" "${sequence}")"
  started_at="$(ftctl_now_iso8601)"
  while IFS= read -r disk_json; do
    device="$(ftctl_dr_ablestack_disk_json_field "${disk_json}" device)"
    source_path="$(ftctl_dr_ablestack_disk_json_field "${disk_json}" sourcePath)"
    target_path="$(ftctl_dr_ablestack_disk_json_field "${disk_json}" targetPath)"
    ftctl_dr_ablestack_rbd_spec_from_path "${source_path}" source_spec || return 32
    ftctl_dr_ablestack_rbd_spec_from_path "${target_path}" target_spec || return 32
    baseline="$(ftctl_dr_ablestack_baseline_path "${plan}" "${device}")"
    [[ -s "${baseline}" ]] || return 91
    previous="$(head -n 1 "${baseline}")"
    rbd snap create "${source_spec}@${current}" || return $?
    changed_bytes="$(rbd diff --from-snap "${previous}" --format json "${source_spec}@${current}" 2>/dev/null | python3 -c 'import json,sys; print(sum(int(x.get("length",0)) for x in json.load(sys.stdin)))' 2>/dev/null || printf '0')"
    ftctl_cmd_run "${FTCTL_DR_FULL_SEED_TIMEOUT_SEC:-3600}" out err rc -- bash -lc \
      "rbd export-diff --from-snap $(printf '%q' "${previous}") $(printf '%q' "${source_spec}@${current}") - | ssh ${ssh_port_args}${identity_args}-o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=${FTCTL_BLOCKCOPY_WAIT_TIMEOUT_SEC:-30} $(printf '%q' "${user}@${ssh_host}") rbd import-diff - $(printf '%q' "${target_spec}")" || true
    if [[ "${rc}" != "0" ]]; then
      rbd snap rm "${source_spec}@${current}" >/dev/null 2>&1 || true
      ftctl_dr_ablestack_remote_rbd_command "rbd snap rollback '${target_spec}@${previous}' >/dev/null 2>&1 || true; rbd snap rm '${target_spec}@${current}' >/dev/null 2>&1 || true" out err rc
      return 92
    fi
    rbd snap rm "${source_spec}@${previous}" >/dev/null 2>&1 || true
    ftctl_dr_ablestack_remote_rbd_command "rbd snap rm '${target_spec}@${previous}' >/dev/null 2>&1 || true" out err rc
    printf '%s\n' "${current}" > "${baseline}"
    ftctl_log_event "dr-runtime" "dr.ablestack.incremental_disk" "ok" "" "" \
      "plan=${plan} run=${run} device=${device} from=${previous} to=${current} bytes=${changed_bytes}"
  done < <(ftctl_dr_ablestack_disk_rows "${disk_map}")
  completed_at="$(ftctl_now_iso8601)"
  ftctl_dr_ablestack_write_manifest "${disk_map}" "${manifest_path}.records.jsonl" "${manifest_path}" "incremental-complete" || return $?
  ftctl_dr_ablestack_write_checkpoint "${disk_map}" "${manifest_path}" "${checkpoint_path}" "TARGET_READY" "${started_at}" "${completed_at}" "0" || return $?
}

ftctl_dr_ablestack_replication_cycle() {
  local plan="${1-}" run="${2-}" profile_file="${3-}" sequence="${4-}" cycle_type="${5-}"
  local disk_map manifest_path checkpoint_path cycle_run

  [[ -n "${plan}" && -n "${run}" && -n "${profile_file}" ]] || return 2
  cycle_run="${run}-cycle-${sequence:-0}"
  disk_map="$(ftctl_dr_ablestack_disk_map_path "${plan}")"
  manifest_path="$(ftctl_dr_ablestack_manifest_path "${plan}" "${cycle_run}")"
  checkpoint_path="$(ftctl_dr_ablestack_checkpoint_path "${plan}" "${cycle_run}")"
  if [[ "${cycle_type}" == *INCREMENTAL* ]] &&
     ftctl_dr_ablestack_remote_transport_load "${disk_map}" 2>/dev/null; then
    local incremental_rc=0
    ftctl_dr_ablestack_incremental_once "${plan}" "${cycle_run}" "${profile_file}" "${disk_map}" "${manifest_path}" "${checkpoint_path}" "${sequence}" || incremental_rc=$?
    if [[ "${incremental_rc}" == "91" ]]; then
      ftctl_log_event "dr-runtime" "dr.ablestack.incremental_fallback" "warn" "" "" \
        "plan=${plan} run=${cycle_run} reason=baseline_unavailable"
      ftctl_dr_ablestack_full_seed_once "${plan}" "${cycle_run}" "${profile_file}" "${disk_map}" "${manifest_path}" "${checkpoint_path}" || return $?
    elif [[ "${incremental_rc}" != "0" ]]; then
      ftctl_log_event "dr-runtime" "dr.ablestack.incremental" "fail" "" "${incremental_rc}" \
        "plan=${plan} run=${cycle_run} reason=incremental_transfer_failed"
      return "${incremental_rc}"
    fi
  else
    ftctl_dr_ablestack_full_seed_once "${plan}" "${cycle_run}" "${profile_file}" "${disk_map}" "${manifest_path}" "${checkpoint_path}" || return $?
  fi
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
  local disk_map manifest_path checkpoint_path count now source_provider target_provider missing_config preflight_error rc

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
  ftctl_dr_runtime_path_set "${state_path}" \
    "driver=ABLESTACK" \
    "driver_state=TARGET_MAP_READY" \
    "step=ablestack-target-map-ready" \
    "progress=2" \
    "disk_map_path=${disk_map}" \
    "target_disk_map_path=${disk_map}" \
    "disk_map_role=target" \
    "target_disk_count=${count}" \
    "target_disk_invalid_count=0" \
    "updated_at=$(ftctl_now_iso8601)" || true
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
      "disk_map_path=${disk_map}" \
      "target_disk_map_path=${disk_map}" \
      "disk_map_role=target" \
      "target_disk_count=0" \
      "target_disk_invalid_count=1" \
      "accepted=false" \
      "error_code=DR_TARGET_DISK_MAPPING_INVALID" \
      "error_message=missing explicit target disk map"
    ftctl_log_event "dr-runtime" "dr.ablestack.disk_map" "warn" "" "" \
      "plan=${plan} run=${run} reason=missing_explicit_disk_map"
    return 31
  fi

  missing_config="$(ftctl_dr_ablestack_missing_config "${disk_map}" || true)"
  if [[ -n "${missing_config}" ]]; then
    rc=31
    ftctl_dr_runtime_path_set "${state_path}" \
      "driver=ABLESTACK" \
      "driver_state=CONFIG_INCOMPLETE" \
      "state=CONFIG_INCOMPLETE" \
      "step=ablestack-target-config-incomplete" \
      "progress=1" \
      "disk_map_path=${disk_map}" \
      "target_disk_map_path=${disk_map}" \
      "disk_map_role=target" \
      "target_disk_count=${count}" \
      "target_disk_invalid_count=${count:-1}" \
      "accepted=false" \
      "error_code=DR_TARGET_MAPPING_INVALID" \
      "error_message=${missing_config}" \
      "last_error=DR_TARGET_MAPPING_INVALID:${missing_config}"
    ftctl_log_event "dr-runtime" "dr.ablestack.config_incomplete" "warn" "" "" \
      "plan=${plan} run=${run} reason=${missing_config}"
    return "${rc}"
  fi

  preflight_error="$(ftctl_dr_ablestack_disk_preflight_error "${disk_map}" || true)"
  if [[ -n "${preflight_error}" ]]; then
    rc="$(ftctl_dr_ablestack_disk_preflight_rc "${preflight_error}")"
    ftctl_dr_runtime_path_set "${state_path}" \
      "driver=ABLESTACK" \
      "driver_state=TARGET_MAP_INVALID" \
      "state=ERROR" \
      "step=ablestack-target-map-invalid" \
      "progress=100" \
      "disk_map_path=${disk_map}" \
      "target_disk_map_path=${disk_map}" \
      "disk_map_role=target" \
      "target_disk_count=${count}" \
      "target_disk_invalid_count=1" \
      "accepted=false" \
      "error_code=$(ftctl_dr_ablestack_error_code_for_rc "${rc}")" \
      "error_message=${preflight_error}" \
      "driver_exit_code=${rc}" \
      "updated_at=$(ftctl_now_iso8601)" || true
    ftctl_log_event "dr-runtime" "dr.ablestack.target_map_preflight" "fail" "" "${rc}" \
      "plan=${plan} run=${run} reason=${preflight_error}"
    return "${rc}"
  fi

  if [[ "${FTCTL_DR_ABLESTACK_FULL_SEED_ON_START}" == "1" ]] ||
      { [[ "${wait_value}" != "false" ]] && ftctl_dr_ablestack_profile_bool "${profile_file}" "request.performFullSeed"; }; then
    rc=0
    ftctl_dr_ablestack_full_seed_once "${plan}" "${run}" "${profile_file}" "${disk_map}" "${manifest_path}" "${checkpoint_path}" || rc=$?
    if [[ "${rc}" != "0" ]]; then
      ftctl_dr_ablestack_mark_driver_error "${state_path}" "${rc}" "ablestack-full-seed-failed" \
        "ABLESTACK full seed failed before target durable checkpoint"
      return "${rc}"
    fi
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

  rc=0
  ftctl_dr_ablestack_prepare_targets "${plan}" "${run}" "${profile_file}" "${disk_map}" "${manifest_path}" "${checkpoint_path}" || rc=$?
  if [[ "${rc}" != "0" ]]; then
    ftctl_dr_ablestack_mark_driver_error "${state_path}" "${rc}" "ablestack-target-prepare-failed" \
      "ABLESTACK target preparation failed before target VM materialization"
    return "${rc}"
  fi
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
