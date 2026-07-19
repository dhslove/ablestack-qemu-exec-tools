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

ftctl_guestprep_v2k_lib_dir() {
  local candidates=(
    "${FTCTL_LIB_BASE:-}/v2k"
    "${ROOT_DIR:-}/lib/v2k"
    "/usr/local/lib/ablestack-qemu-exec-tools/v2k"
  )
  local candidate
  for candidate in "${candidates[@]}"; do
    if [[ -n "${candidate}" && -f "${candidate}/engine.sh" && -f "${candidate}/target_libvirt.sh" ]]; then
      printf '%s\n' "${candidate}"
      return 0
    fi
  done
  return 1
}

ftctl_guestprep_write_manifest() {
  local session_path="${1-}" manifest_path="${2-}" test_domain_name="${3-}"
  python3 - "${session_path}" "${manifest_path}" "${test_domain_name}" <<'PY'
import json
import os
import sys

session_path, manifest_path, test_domain_name = sys.argv[1:4]
with open(session_path, "r", encoding="utf-8") as fh:
    session = json.load(fh)

profile = session.get("profile") if isinstance(session.get("profile"), dict) else {}
mapping = profile.get("mapping") if isinstance(profile.get("mapping"), dict) else {}
source_mapping = mapping.get("source") if isinstance(mapping.get("source"), dict) else {}
target_mapping = mapping.get("target") if isinstance(mapping.get("target"), dict) else {}
source_hw = source_mapping.get("hardware") if isinstance(source_mapping.get("hardware"), dict) else {}
target_hw = target_mapping.get("hardware") if isinstance(target_mapping.get("hardware"), dict) else {}
workload = source_mapping.get("workload") if isinstance(source_mapping.get("workload"), dict) else {}
artifacts = session.get("testArtifacts") if isinstance(session.get("testArtifacts"), dict) else {}
records = artifacts.get("records") if isinstance(artifacts.get("records"), list) else []
request = session.get("request") if isinstance(session.get("request"), dict) else {}

def first(*values):
    for value in values:
        if value is not None and str(value).strip() and str(value).lower() != "null":
            return value
    return None

firmware_value = str(first(source_hw.get("firmware"), source_hw.get("bootType"), target_hw.get("bootType"), "bios"))
secure_value = first(source_hw.get("secureBoot"), target_hw.get("bootMode") == "SECURE", False)
guest_family = str(first(
    workload.get("guestFamily"), workload.get("guestfamily"),
    source_hw.get("guestFamily"), source_mapping.get("guestFamily"), ""
))
guest_id = str(first(workload.get("guestId"), workload.get("guestid"), source_mapping.get("guestId"), ""))
guest_name = str(first(workload.get("name"), source_mapping.get("name"), profile.get("source", {}).get("externalRef"), test_domain_name))
cpu = first(target_mapping.get("cpuNumber"), target_mapping.get("cpu"), source_hw.get("cpu"), 2)
memory = first(target_mapping.get("memory"), target_mapping.get("memoryMb"), source_hw.get("memoryMb"), 2048)

disks = []
storage_type = "file"
for index, record in enumerate(records):
    if not isinstance(record, dict) or record.get("state") != "CREATED":
        continue
    artifact_type = str(record.get("type") or "")
    path = record.get("path") or record.get("clone")
    if artifact_type == "rbd-clone":
        storage_type = "rbd"
        path = record.get("clone") or path
    if not path:
        continue
    disks.append({
        "disk_id": str(record.get("device") or f"disk{index}"),
        "size_bytes": int(record.get("sizeBytes") or 0),
        "controller": {"type": "VirtualSCSIController"},
        "transfer": {"target_path": str(path)},
    })

manifest = {
    "version": 1,
    "source": {
        "vm": {
            "name": guest_name,
            "cpu": int(cpu or 2),
            "memory_mb": int(memory or 2048),
            "firmware": "efi" if "EFI" in firmware_value.upper() or "UEFI" in firmware_value.upper() else "bios",
            "secure_boot": bool(secure_value is True or str(secure_value).lower() in {"true", "1", "yes", "secure"}),
            "guestFamily": guest_family,
            "guestId": guest_id,
            "nics": [] if str(request.get("networkMode") or "ISOLATED").upper() == "ISOLATED" else workload.get("nics", []),
        }
    },
    "target": {
        "storage": {"type": storage_type},
        "format": "raw" if storage_type == "rbd" else "qcow2",
        "libvirt": {"name": test_domain_name},
    },
    "disks": disks,
}
os.makedirs(os.path.dirname(manifest_path), exist_ok=True)
with open(manifest_path, "w", encoding="utf-8") as fh:
    json.dump(manifest, fh, sort_keys=True, separators=(",", ":"))
    fh.write("\n")
PY
}

ftctl_guestprep_detect_family() {
  local manifest_path="${1-}" explicit family root_path storage_type mapped=""
  explicit="$(jq -r '.source.vm.guestFamily // .source.vm.guestId // ""' "${manifest_path}" 2>/dev/null || true)"
  case "${explicit,,}" in
    *windows*) printf 'windows\n'; return 0 ;;
    *linux*|*rhel*|*centos*|*rocky*|*ubuntu*|*debian*|*sles*) printf 'linux\n'; return 0 ;;
  esac

  root_path="$(jq -r '.disks[0].transfer.target_path // ""' "${manifest_path}" 2>/dev/null || true)"
  storage_type="$(jq -r '.target.storage.type // "file"' "${manifest_path}" 2>/dev/null || true)"
  if [[ "${storage_type}" == "rbd" && "${root_path}" == rbd:* ]]; then
    mapped="$(rbd map "${root_path#rbd:}" 2>/dev/null || true)"
    [[ -n "${mapped}" ]] && root_path="${mapped}"
  fi
  family=""
  if command -v virt-inspector >/dev/null 2>&1 && [[ -n "${root_path}" ]]; then
    family="$(virt-inspector -a "${root_path}" 2>/dev/null | python3 -c '
import sys, xml.etree.ElementTree as ET
try:
    root = ET.parse(sys.stdin).getroot()
    values = " ".join((node.text or "") for node in root.iter() if node.tag in {"type", "distro", "product_name"}).lower()
    print("windows" if "windows" in values else ("linux" if values else ""))
except Exception:
    print("")
' || true)"
  fi
  [[ -n "${mapped}" ]] && rbd unmap "${mapped}" >/dev/null 2>&1 || true
  [[ -n "${family}" ]] || family="unknown"
  printf '%s\n' "${family}"
}

ftctl_guestprep_prepare_artifacts() {
  local session_path="${1-}" run_path="${2-}"
  local artifacts_dir plan run artifact_name manifest v2k_dir family rc=0 state_file execution_mode
  artifacts_dir="$(jq -r '.testArtifacts.path // ""' "${session_path}" 2>/dev/null || true)"
  plan="$(jq -r '.planUuid // ""' "${session_path}" 2>/dev/null || true)"
  run="$(jq -r '.runUuid // ""' "${session_path}" 2>/dev/null || true)"
  [[ -n "${artifacts_dir}" ]] || return 46
  execution_mode="$(jq -r '.profile.policy.testExecutionMode // .request.testExecutionMode // "BOOT"' "${session_path}" 2>/dev/null || echo BOOT)"
  if [[ "${execution_mode}" == "METADATA_ONLY" ]]; then
    python3 - "${session_path}" "$(ftctl_now_iso8601)" <<'PY'
import json, sys
session_path, now = sys.argv[1:3]
with open(session_path, "r", encoding="utf-8") as fh:
    session = json.load(fh)
session["guestPreparation"] = {"state":"SKIPPED", "reason":"METADATA_ONLY", "completedAt":now}
session["state"] = "TEST_ARTIFACTS_READY"
with open(session_path, "w", encoding="utf-8") as fh:
    json.dump(session, fh, sort_keys=True, separators=(",", ":")); fh.write("\n")
PY
    ftctl_dr_runtime_path_set "${run_path}" \
      "state=TEST_ARTIFACTS_READY" \
      "step=test-artifacts-ready" \
      "progress=100" \
      "guest_prep_state=SKIPPED" \
      "test_domain_name=" \
      "test_domain_state=" \
      "updated_at=$(ftctl_now_iso8601)"
    return 0
  fi
  artifact_name="ftctl-dr-artifact-$(ftctl_dr_runtime_key "${plan}")-$(ftctl_dr_runtime_key "${run}")"
  artifact_name="${artifact_name:0:62}"
  manifest="${artifacts_dir}/guestprep-manifest.json"
  ftctl_guestprep_write_manifest "${session_path}" "${manifest}" "${artifact_name}" || return 47
  [[ "$(jq -r '.disks | length' "${manifest}" 2>/dev/null || echo 0)" -gt 0 ]] || return 46

  v2k_dir="$(ftctl_guestprep_v2k_lib_dir || true)"
  [[ -n "${v2k_dir}" ]] || return 47
  family="$(ftctl_guestprep_detect_family "${manifest}")"
  case "${family}" in
    linux)
      env V2K_LIB_DIR="${v2k_dir}" V2K_WORKDIR="${artifacts_dir}" V2K_MANIFEST="${manifest}" V2K_JSON_OUT=1 \
        bash -c 'source "$1/engine.sh"; v2k_linux_bootstrap_initramfs "$2"' _ "${v2k_dir}" "${manifest}" || rc=$?
      ;;
    windows)
      env V2K_LIB_DIR="${v2k_dir}" V2K_WORKDIR="${artifacts_dir}" V2K_MANIFEST="${manifest}" V2K_JSON_OUT=1 \
        bash -c 'source "$1/engine.sh"; v2k_cloud_windows_winpe_bootstrap "${FTCTL_DR_WINPE_ISO:-/usr/share/ablestack/v2k/winpe/winpe-ablestack-v2k-amd64.iso}" "${FTCTL_DR_VIRTIO_ISO:-/usr/share/virtio-win/virtio-win.iso}" "${FTCTL_DR_WINPE_TIMEOUT:-900}"' _ "${v2k_dir}" || rc=$?
      ;;
    *) return 48 ;;
  esac
  [[ "${rc}" == "0" ]] || return 49

  state_file="$(mktemp -t ftctl.dr.guestprep-artifacts.XXXXXX)"
  python3 - "${session_path}" "${state_file}" "${manifest}" "${family}" "$(ftctl_now_iso8601)" <<'PY'
import json, sys
session_path, state_path, manifest, family, now = sys.argv[1:6]
with open(session_path, "r", encoding="utf-8") as fh:
    session = json.load(fh)
session["guestPreparation"] = {"state":"READY", "family":family, "manifest":manifest, "completedAt":now}
session["state"] = "TEST_ARTIFACTS_READY"
with open(session_path, "w", encoding="utf-8") as fh:
    json.dump(session, fh, sort_keys=True, separators=(",", ":")); fh.write("\n")
with open(state_path, "w", encoding="utf-8") as fh:
    fh.write("guest_prep_state=READY\n")
    fh.write(f"guest_family={family}\n")
    fh.write(f"guestprep_manifest_path={manifest}\n")
PY
  ftctl_dr_runtime_path_set "${run_path}" \
    "state=TEST_ARTIFACTS_READY" \
    "step=test-artifacts-ready" \
    "progress=100" \
    "guest_prep_state=$(ftctl_dr_runtime_state_get_from_path "${state_file}" guest_prep_state)" \
    "guest_family=$(ftctl_dr_runtime_state_get_from_path "${state_file}" guest_family)" \
    "guestprep_manifest_path=$(ftctl_dr_runtime_state_get_from_path "${state_file}" guestprep_manifest_path)" \
    "test_domain_name=" \
    "test_domain_state=" \
    "updated_at=$(ftctl_now_iso8601)"
  rm -f "${state_file}"
}

ftctl_guestprep_prepare_and_start() {
  local session_path="${1-}" run_path="${2-}"
  local artifacts_dir plan run domain manifest v2k_dir family validation timeout rc=0 state_file execution_mode
  execution_mode="$(jq -r '.profile.policy.testExecutionMode // .request.testExecutionMode // "BOOT"' "${session_path}" 2>/dev/null || echo BOOT)"
  if [[ "${execution_mode}" == "METADATA_ONLY" ]]; then
    return 0
  fi
  artifacts_dir="$(jq -r '.testArtifacts.path // ""' "${session_path}" 2>/dev/null || true)"
  plan="$(jq -r '.planUuid // ""' "${session_path}" 2>/dev/null || true)"
  run="$(jq -r '.runUuid // ""' "${session_path}" 2>/dev/null || true)"
  [[ -n "${artifacts_dir}" ]] || return 46
  domain="ftctl-dr-test-$(ftctl_dr_runtime_key "${plan}")-$(ftctl_dr_runtime_key "${run}")"
  domain="${domain:0:62}"
  manifest="${artifacts_dir}/guestprep-manifest.json"
  ftctl_guestprep_write_manifest "${session_path}" "${manifest}" "${domain}" || return 47
  [[ "$(jq -r '.disks | length' "${manifest}" 2>/dev/null || echo 0)" -gt 0 ]] || return 46

  v2k_dir="$(ftctl_guestprep_v2k_lib_dir || true)"
  [[ -n "${v2k_dir}" ]] || return 47
  family="$(ftctl_guestprep_detect_family "${manifest}")"
  case "${family}" in
    linux)
      env V2K_LIB_DIR="${v2k_dir}" V2K_WORKDIR="${artifacts_dir}" V2K_MANIFEST="${manifest}" V2K_JSON_OUT=1 \
        bash -c 'source "$1/engine.sh"; v2k_linux_bootstrap_initramfs "$2"' _ "${v2k_dir}" "${manifest}" || rc=$?
      ;;
    windows)
      env V2K_LIB_DIR="${v2k_dir}" V2K_WORKDIR="${artifacts_dir}" V2K_MANIFEST="${manifest}" V2K_JSON_OUT=1 \
        bash -c 'source "$1/engine.sh"; v2k_cloud_windows_winpe_bootstrap "${FTCTL_DR_WINPE_ISO:-/usr/share/ablestack/v2k/winpe/winpe-ablestack-v2k-amd64.iso}" "${FTCTL_DR_VIRTIO_ISO:-/usr/share/virtio-win/virtio-win.iso}" "${FTCTL_DR_WINPE_TIMEOUT:-900}"' _ "${v2k_dir}" || rc=$?
      ;;
    *) return 48 ;;
  esac
  [[ "${rc}" == "0" ]] || return 49

  env V2K_LIB_DIR="${v2k_dir}" V2K_WORKDIR="${artifacts_dir}" V2K_MANIFEST="${manifest}" \
    bash -c 'source "$1/engine.sh"; v2k_cutover_prepare_rbd_mappings "$2"; xml="$(v2k_target_generate_libvirt_xml "$2")"; v2k_target_undefine_libvirt "$(jq -r .target.libvirt.name "$2")"; v2k_target_define_libvirt "$xml"; v2k_target_start_vm "$2"' \
    _ "${v2k_dir}" "${manifest}" || return 50

  validation="$(jq -r '.profile.policy.testBootValidationMode // .request.testBootValidationMode // "POWER_STATE_ONLY"' "${session_path}" 2>/dev/null || echo POWER_STATE_ONLY)"
  timeout="$(jq -r '.profile.policy.testBootTimeoutSeconds // .request.testBootTimeoutSeconds // 180' "${session_path}" 2>/dev/null || echo 180)"
  [[ "${timeout}" =~ ^[0-9]+$ ]] || timeout=180
  local deadline=$((SECONDS + timeout)) domain_state=""
  while (( SECONDS < deadline )); do
    domain_state="$(virsh domstate "${domain}" 2>/dev/null | tr -d '\r' | tr '[:upper:]' '[:lower:]' || true)"
    if [[ "${domain_state}" == "running" ]]; then
      if [[ "${validation}" != "QGA_REQUIRED" ]] || virsh qemu-agent-command "${domain}" '{"execute":"guest-ping"}' >/dev/null 2>&1; then
        break
      fi
    fi
    sleep 2
  done
  [[ "${domain_state}" == "running" ]] || return 51
  if [[ "${validation}" == "QGA_REQUIRED" ]]; then
    virsh qemu-agent-command "${domain}" '{"execute":"guest-ping"}' >/dev/null 2>&1 || return 52
  fi

  state_file="$(mktemp -t ftctl.dr.guestprep.XXXXXX)"
  python3 - "${session_path}" "${state_file}" "${manifest}" "${domain}" "${family}" "${validation}" "$(ftctl_now_iso8601)" <<'PY'
import json, sys
session_path, state_path, manifest, domain, family, validation, now = sys.argv[1:8]
with open(session_path, "r", encoding="utf-8") as fh:
    session = json.load(fh)
session["guestPreparation"] = {"state":"READY", "family":family, "manifest":manifest, "completedAt":now}
session["testDomain"] = {"state":"RUNNING", "name":domain, "validationMode":validation, "validatedAt":now}
session["state"] = "TEST_RUNNING"
with open(session_path, "w", encoding="utf-8") as fh:
    json.dump(session, fh, sort_keys=True, separators=(",", ":")); fh.write("\n")
with open(state_path, "w", encoding="utf-8") as fh:
    fh.write("guest_prep_state=READY\n")
    fh.write(f"guest_family={family}\n")
    fh.write(f"guestprep_manifest_path={manifest}\n")
    fh.write(f"test_domain_name={domain}\n")
    fh.write("test_domain_state=RUNNING\n")
    fh.write(f"test_boot_validation_mode={validation}\n")
PY
  ftctl_dr_runtime_path_set "${run_path}" \
    "state=TEST_RUNNING" \
    "step=test-boot-validated" \
    "progress=100" \
    "guest_prep_state=$(ftctl_dr_runtime_state_get_from_path "${state_file}" guest_prep_state)" \
    "guest_family=$(ftctl_dr_runtime_state_get_from_path "${state_file}" guest_family)" \
    "guestprep_manifest_path=$(ftctl_dr_runtime_state_get_from_path "${state_file}" guestprep_manifest_path)" \
    "test_domain_name=$(ftctl_dr_runtime_state_get_from_path "${state_file}" test_domain_name)" \
    "test_domain_state=RUNNING" \
    "test_boot_validation_mode=$(ftctl_dr_runtime_state_get_from_path "${state_file}" test_boot_validation_mode)" \
    "updated_at=$(ftctl_now_iso8601)"
  rm -f "${state_file}"
}

ftctl_guestprep_prepare_cutover_target() {
  local profile_file="${1-}" run_path="${2-}" workdir="${3-}"
  local manifest v2k_dir family rc=0
  mkdir -p "${workdir}"
  manifest="${workdir}/cutover-manifest.json"
  python3 - "${profile_file}" "${manifest}" <<'PY'
import json, os, sys
profile_path, manifest_path = sys.argv[1:3]
with open(profile_path, "r", encoding="utf-8") as fh:
    profile = json.load(fh)
mapping = profile.get("mapping") if isinstance(profile.get("mapping"), dict) else {}
source = mapping.get("source") if isinstance(mapping.get("source"), dict) else {}
target = mapping.get("target") if isinstance(mapping.get("target"), dict) else {}
hardware = source.get("hardware") if isinstance(source.get("hardware"), dict) else {}
target_hw = target.get("hardware") if isinstance(target.get("hardware"), dict) else {}
workload = source.get("workload") if isinstance(source.get("workload"), dict) else {}
disks = mapping.get("disks") if isinstance(mapping.get("disks"), list) else []
converted = []
storage = "file"
for index, disk in enumerate(disks):
    if not isinstance(disk, dict): continue
    path = disk.get("targetPath") or disk.get("targetDiskRef")
    if not path: continue
    if str(path).startswith("rbd:") or str(path).startswith("/dev/rbd/"): storage = "rbd"
    converted.append({"disk_id":str(disk.get("device") or f"disk{index}"), "size_bytes":int(disk.get("sizeBytes") or 0), "controller":{"type":"VirtualSCSIController"}, "transfer":{"target_path":str(path)}})
firmware = str(hardware.get("firmware") or target_hw.get("bootType") or "bios")
secure = hardware.get("secureBoot", target_hw.get("bootMode") == "SECURE")
secure = secure is True or str(secure).strip().lower() in {"true", "1", "yes", "secure"}
manifest = {"version":1,"source":{"vm":{"name":workload.get("name") or "ftctl-dr-cutover","cpu":int(target.get("cpuNumber") or 2),"memory_mb":int(target.get("memory") or 2048),"firmware":"efi" if "EFI" in firmware.upper() or "UEFI" in firmware.upper() else "bios","secure_boot":secure,"guestFamily":workload.get("guestFamily") or source.get("guestFamily") or "","guestId":workload.get("guestId") or "","nics":[]}},"target":{"storage":{"type":storage},"format":"raw" if storage == "rbd" else "qcow2","libvirt":{"name":"ftctl-dr-cutover-prep"}},"disks":converted}
os.makedirs(os.path.dirname(manifest_path), exist_ok=True)
with open(manifest_path,"w",encoding="utf-8") as fh: json.dump(manifest,fh,sort_keys=True,separators=(",",":")); fh.write("\n")
PY
  v2k_dir="$(ftctl_guestprep_v2k_lib_dir || true)"
  [[ -n "${v2k_dir}" ]] || return 47
  family="$(ftctl_guestprep_detect_family "${manifest}")"
  case "${family}" in
    linux)
      env V2K_LIB_DIR="${v2k_dir}" V2K_WORKDIR="${workdir}" V2K_MANIFEST="${manifest}" V2K_JSON_OUT=1 \
        bash -c 'source "$1/engine.sh"; v2k_linux_bootstrap_initramfs "$2"' _ "${v2k_dir}" "${manifest}" || rc=$?
      ;;
    windows)
      env V2K_LIB_DIR="${v2k_dir}" V2K_WORKDIR="${workdir}" V2K_MANIFEST="${manifest}" V2K_JSON_OUT=1 \
        bash -c 'source "$1/engine.sh"; v2k_cloud_windows_winpe_bootstrap "${FTCTL_DR_WINPE_ISO:-/usr/share/ablestack/v2k/winpe/winpe-ablestack-v2k-amd64.iso}" "${FTCTL_DR_VIRTIO_ISO:-/usr/share/virtio-win/virtio-win.iso}" "${FTCTL_DR_WINPE_TIMEOUT:-900}"' _ "${v2k_dir}" || rc=$?
      ;;
    *) return 48 ;;
  esac
  [[ "${rc}" == "0" ]] || return 49
  ftctl_dr_runtime_path_set "${run_path}" \
    "state=CUTOVER_READY" \
    "step=guest-preparation-completed" \
    "progress=90" \
    "guest_prep_state=READY" \
    "guest_family=${family}" \
    "guestprep_manifest_path=${manifest}" \
    "target_promotion_state=CUTOVER_READY" \
    "target_power_state=POWERED_OFF" \
    "updated_at=$(ftctl_now_iso8601)"
}
