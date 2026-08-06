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

# KVM/RBD -> VMware/VDDK reverse replication.  The RBD snapshot named in the
# baseline is the durable tracker.  It is advanced only after the VDDK writer
# reports that every selected extent was flushed to the target VMDK.

ftctl_dr_kvm_vmware_root() {
  printf '%s/kvm-vmware\n' "$(ftctl_dr_runtime_plan_dir "$1")"
}

ftctl_dr_kvm_vmware_disk_map_path() {
  printf '%s/disk-map.json\n' "$(ftctl_dr_kvm_vmware_root "$1")"
}

ftctl_dr_kvm_vmware_baseline_path() {
  printf '%s/baseline.json\n' "$(ftctl_dr_kvm_vmware_root "$1")"
}

ftctl_dr_kvm_vmware_cycle_dir() {
  printf '%s/cycles/%s\n' "$(ftctl_dr_kvm_vmware_root "$1")" "$2"
}

ftctl_dr_kvm_vmware_effective_mover() {
  local candidate="${FTCTL_DR_KVM_VMWARE_MOVER:-}"
  if [[ -n "${candidate}" && -x "${candidate}" ]]; then
    printf '%s\n' "${candidate}"
    return 0
  fi
  candidate="${FTCTL_LIB_BASE:-/usr/local/lib/ablestack-qemu-exec-tools}/ftctl/dr_kvm_vmware_mover.sh"
  [[ -x "${candidate}" ]] || return 1
  printf '%s\n' "${candidate}"
}

ftctl_dr_kvm_vmware_canonicalize_profile() {
  local profile_file="${1-}" output_path="${2-}"
  python3 - "${profile_file}" "${output_path}" <<'PY'
import hashlib
import json
import os
import re
import sys

profile_path, output_path = sys.argv[1:3]
with open(profile_path, "r", encoding="utf-8") as handle:
    profile = json.load(handle)

def obj(value):
    return value if isinstance(value, dict) else {}

def items(value):
    return value if isinstance(value, list) else []

def first(*values):
    for value in values:
        if value is None or isinstance(value, (dict, list)):
            continue
        value = str(value).strip()
        if value:
            return value
    return ""

forward_source = obj(profile.get("source"))
forward_target = obj(profile.get("target"))
mapping = obj(profile.get("mapping"))
direction = first(profile.get("direction")).upper()
reverse_from_target = direction == "VMWARE_TO_KVM"
source = forward_target if reverse_from_target else forward_source
target = forward_source if reverse_from_target else forward_target
disks = items(mapping.get("disks") or mapping.get("diskMappings") or profile.get("disks"))
rows = []
for index, disk in enumerate(disks):
    disk = obj(disk)
    forward_disk_source = obj(disk.get("source"))
    forward_disk_target = obj(disk.get("target"))
    source_obj = forward_disk_target if reverse_from_target else forward_disk_source
    target_obj = forward_disk_source if reverse_from_target else forward_disk_target
    source_path = first(
        source_obj.get("path"), source_obj.get("diskRef"),
        disk.get("targetPath") if reverse_from_target else disk.get("sourcePath"),
        disk.get("targetDiskRef") if reverse_from_target else disk.get("sourceDiskRef"),
    )
    pool = first(
        disk.get("sourcePool"), source_obj.get("pool"), source_obj.get("storagePath"),
        source_obj.get("storagePool"), source.get("storagePool"),
    )
    image = first(
        disk.get("sourceImage"), source_obj.get("image"), source_obj.get("rbdImage"),
        source_obj.get("name"), source_obj.get("volumeUuid"), source_obj.get("uuid"),
    )
    match = re.match(r"^(?:rbd:|/dev/rbd/|rbd/)?([^/]+)/(.+)$", source_path)
    if match:
        pool = pool or match.group(1)
        image = image or match.group(2)
    image = image.split("@", 1)[0]
    target_vmdk = first(
        target_obj.get("vmdkPath"), target_obj.get("path"), target_obj.get("diskRef"),
        disk.get("sourcePath") if reverse_from_target else disk.get("targetVmdkPath"),
        disk.get("sourceDiskRef") if reverse_from_target else disk.get("targetPath"),
    )
    size = disk.get("sizeBytes") or source_obj.get("sizeBytes") or target_obj.get("sizeBytes") or 0
    identity = "|".join((pool, image, target_vmdk, str(size)))
    rows.append({
        "diskIndex": index,
        "device": first(disk.get("device"), source_obj.get("device"), target_obj.get("device"), f"disk{index}"),
        "sourcePool": pool,
        "sourceImage": image,
        "sourceVolumeUuid": first(source_obj.get("volumeUuid"), source_obj.get("uuid")),
        "sourceUri": f"rbd:{pool}/{image}" if pool and image else source_path,
        "targetVmdkPath": target_vmdk,
        "targetVmRef": first(target.get("externalRef"), target.get("vmId"), target.get("id"), disk.get("targetVmRef")),
        "virtualBytes": int(size or 0),
        "diskIdentityHash": "sha256:" + hashlib.sha256(identity.encode("utf-8")).hexdigest(),
    })

payload = {
    "schemaVersion": 1,
    "direction": "KVM_TO_VMWARE",
    "providerPair": "ABLESTACK_TO_VMWARE",
    "planUuid": profile.get("planUuid", ""),
    "runUuid": profile.get("runUuid", ""),
    "source": source,
    "target": target,
    "sourceDomain": first(source.get("instanceName"), source.get("domainName"), source.get("vmName")),
    "disks": rows,
}
if not payload["sourceDomain"] or not rows or any(not row["sourcePool"] or not row["sourceImage"] or not row["targetVmdkPath"] or not row["targetVmRef"] for row in rows):
    raise SystemExit("KVM_TO_VMWARE disk map is incomplete")
os.makedirs(os.path.dirname(output_path) or ".", exist_ok=True)
tmp = output_path + ".tmp"
with open(tmp, "w", encoding="utf-8") as handle:
    json.dump(payload, handle, sort_keys=True, separators=(",", ":"))
    handle.write("\n")
    handle.flush()
    os.fsync(handle.fileno())
os.replace(tmp, output_path)
PY
}

ftctl_dr_kvm_vmware_baseline_state() {
  local plan="${1-}" baseline
  baseline="$(ftctl_dr_kvm_vmware_baseline_path "${plan}")"
  if [[ ! -e "${baseline}" ]]; then
    printf 'MISSING_EXPECTED\n'
  elif [[ -s "${baseline}" ]] && jq -e '.state == "LOCAL_DURABLE" and ((.disks | type) == "array") and ((.disks | length) > 0)' \
      "${baseline}" >/dev/null 2>&1; then
    printf 'LOCAL_DURABLE\n'
  else
    printf 'INVALID\n'
  fi
}

ftctl_dr_kvm_vmware_mode_decision() {
  local plan="${1-}" operation_intent="${2-}" requested_mode="${3-AUTO}" baseline_state effective_mode decision_code initial_seed=false
  operation_intent="${operation_intent^^}"
  operation_intent="${operation_intent//-/_}"
  requested_mode="${requested_mode^^}"
  requested_mode="${requested_mode//-/_}"
  baseline_state="$(ftctl_dr_kvm_vmware_baseline_state "${plan}")"

  [[ -n "${operation_intent}" ]] || operation_intent="FAILBACK_FINAL"
  [[ -n "${requested_mode}" ]] || requested_mode="AUTO"
  if [[ "${baseline_state}" == "INVALID" ]]; then
    printf '%s\t%s\t%s\t%s\n' "${baseline_state}" "" "DR_REVERSE_BASELINE_INVALID" "false"
    return 84
  fi

  case "${requested_mode}" in
    AUTO)
      if [[ "${baseline_state}" == "MISSING_EXPECTED" ]]; then
        effective_mode="FULL_REVERSE_SEED"
        decision_code="INITIAL_REVERSE_BASELINE_MISSING"
        initial_seed=true
      elif [[ "${operation_intent}" == "FAILBACK_FINAL" ]]; then
        effective_mode="REVERSE_FINAL"
        decision_code="DURABLE_BASELINE_FINAL_DELTA"
      else
        effective_mode="REVERSE_INCREMENTAL"
        decision_code="DURABLE_BASELINE_INCREMENTAL"
      fi
      ;;
    FULL_REVERSE_SEED)
      effective_mode="FULL_REVERSE_SEED"
      decision_code="EXPLICIT_FULL_REVERSE_SEED"
      initial_seed=true
      ;;
    REVERSE_FINAL|REVERSE_INCREMENTAL)
      if [[ "${baseline_state}" != "LOCAL_DURABLE" ]]; then
        printf '%s\t%s\t%s\t%s\n' "${baseline_state}" "" "DR_REVERSE_BASELINE_REQUIRED" "false"
        return 83
      fi
      effective_mode="${requested_mode}"
      decision_code="EXPLICIT_${requested_mode}"
      ;;
    *)
      printf '%s\t%s\t%s\t%s\n' "${baseline_state}" "" "DR_REVERSE_MODE_INVALID" "false"
      return 2
      ;;
  esac
  printf '%s\t%s\t%s\t%s\n' "${baseline_state}" "${effective_mode}" "${decision_code}" "${initial_seed}"
}

ftctl_dr_kvm_vmware_cycle_type() {
  local plan="${1-}" legacy_requested="${2-}" operation_intent requested_mode decision rc=0
  case "${legacy_requested}" in
    failback-final) operation_intent="FAILBACK_FINAL"; requested_mode="AUTO" ;;
    reprotect-seed) operation_intent="REPROTECT"; requested_mode="AUTO" ;;
    full-reverse-seed|FULL_REVERSE_SEED) operation_intent="REPROTECT"; requested_mode="FULL_REVERSE_SEED" ;;
    reverse-final|REVERSE_FINAL) operation_intent="FAILBACK_FINAL"; requested_mode="REVERSE_FINAL" ;;
    reverse-incremental|REVERSE_INCREMENTAL) operation_intent="REPROTECT"; requested_mode="REVERSE_INCREMENTAL" ;;
    *) operation_intent="REPROTECT"; requested_mode="AUTO" ;;
  esac
  decision="$(ftctl_dr_kvm_vmware_mode_decision "${plan}" "${operation_intent}" "${requested_mode}")" || rc=$?
  [[ "${rc}" == "0" ]] || return "${rc}"
  awk -F '\t' '{print $2}' <<< "${decision}"
}

ftctl_dr_kvm_vmware_reverse_preflight() {
  local plan="${1-}" profile_file="${2-}" operation_intent="${3-FAILBACK_FINAL}" requested_mode="${4-AUTO}" json="${5-0}"
  local map_path decision rc=0 baseline_state effective_mode decision_code initial_seed source_disk_count estimated_virtual_bytes
  local source_domain source_domain_probe_state="READY" source_disk_probe_state="READY" target_writer_probe_state="READY" error_code="" ready=true
  [[ -n "${plan}" && -f "${profile_file}" ]] || return 2
  map_path="$(mktemp "${TMPDIR:-/tmp}/ftctl-reverse-map.XXXXXX.json")"
  # RETURN traps survive into the caller unless they clear themselves.
  trap 'rm -f -- "${map_path:-}"; trap - RETURN' RETURN
  ftctl_dr_kvm_vmware_canonicalize_profile "${profile_file}" "${map_path}" || {
    rc=67; error_code="DR_REVERSE_DISK_MAP_INVALID"; ready=false
  }
  if [[ "${rc}" == "0" ]]; then
    decision="$(ftctl_dr_kvm_vmware_mode_decision "${plan}" "${operation_intent}" "${requested_mode}")" || rc=$?
    IFS=$'\t' read -r baseline_state effective_mode decision_code initial_seed <<< "${decision}"
    [[ "${rc}" == "0" ]] || { ready=false; error_code="${decision_code}"; }
  else
    baseline_state="$(ftctl_dr_kvm_vmware_baseline_state "${plan}")"
  fi
  source_disk_count="$(jq -r '.disks | length' "${map_path}" 2>/dev/null || printf 0)"
  estimated_virtual_bytes="$(jq -r '[.disks[].virtualBytes // 0] | add // 0' "${map_path}" 2>/dev/null || printf 0)"
  source_domain="$(jq -r '.sourceDomain // empty' "${map_path}" 2>/dev/null || true)"
  if [[ "${rc}" == "0" ]]; then
    if [[ -z "${source_domain}" ]] || ! virsh dominfo "${source_domain}" >/dev/null 2>&1; then
      source_domain_probe_state="NOT_FOUND"
      source_disk_probe_state="NOT_CHECKED"
      ready=false
      rc=86
      error_code="DR_REVERSE_SOURCE_DOMAIN_NOT_FOUND"
    elif [[ "$(virsh domstate "${source_domain}" 2>/dev/null | tr '[:lower:]' '[:upper:]' | tr -d '[:space:]')" != "RUNNING" ]]; then
      source_domain_probe_state="NOT_RUNNING"
      source_disk_probe_state="NOT_CHECKED"
      ready=false
      rc=87
      error_code="DR_REVERSE_SOURCE_DOMAIN_NOT_RUNNING"
    fi
  else
    source_domain_probe_state="NOT_CHECKED"
  fi
  if [[ "${rc}" == "0" ]]; then
    while IFS=$'\t' read -r pool image; do
      if [[ -z "${pool}" || -z "${image}" ]] || ! rbd info "${pool}/${image}" >/dev/null 2>&1; then
        source_disk_probe_state="NOT_READY"
        ready=false
        rc=82
        error_code="DR_REVERSE_SOURCE_STORAGE_MISSING"
        break
      fi
    done < <(jq -r '.disks[] | [.sourcePool,.sourceImage] | @tsv' "${map_path}")
  else
    source_disk_probe_state="NOT_CHECKED"
  fi
  for cmd in jq rbd qemu-nbd nbd-client nbdkit blockdev flock python3; do
    if ! command -v "${cmd}" >/dev/null 2>&1; then
      target_writer_probe_state="NOT_READY"
      ready=false
      [[ "${rc}" != "0" ]] || rc=65
      [[ -n "${error_code}" ]] || error_code="DR_VMWARE_MOVER_UNAVAILABLE"
    fi
  done
  if [[ "${json}" == "1" ]]; then
    printf '{"command":"dr-reverse-preflight","schema_version":2,"contract_version":"dr-reverse-preflight-v2","result":"%s","ready":%s,"status_evidence_contract_version":1,"status_evidence_publication_ready":true,"status_evidence_error_code":"","plan_uuid":"%s","operation_intent":"%s","requested_mode":"%s","effective_mode":"%s","mode_decision_code":"%s","initial_seed_required":%s,"baseline_file_state":"%s","source_domain_probe_state":"%s","source_disk_probe_state":"%s","source_disk_count":%s,"target_writer_probe_state":"%s","estimated_virtual_bytes":%s,"error_code":"%s","exit_code":%s}\n' \
      "$( [[ "${ready}" == "true" ]] && printf ok || printf error )" "${ready}" "$(ftctl__json_escape "${plan}")" \
      "$(ftctl__json_escape "${operation_intent}")" "$(ftctl__json_escape "${requested_mode}")" "$(ftctl__json_escape "${effective_mode}")" \
      "$(ftctl__json_escape "${decision_code}")" "${initial_seed:-false}" "$(ftctl__json_escape "${baseline_state}")" \
      "$(ftctl__json_escape "${source_domain_probe_state}")" "$(ftctl__json_escape "${source_disk_probe_state}")" "${source_disk_count:-0}" "$(ftctl__json_escape "${target_writer_probe_state}")" \
      "${estimated_virtual_bytes:-0}" "$(ftctl__json_escape "${error_code}")" "${rc}"
  else
    printf 'ready=%s baseline=%s requested=%s effective=%s decision=%s source_disks=%s writer=%s\n' \
      "${ready}" "${baseline_state}" "${requested_mode}" "${effective_mode}" "${decision_code}" "${source_disk_count}" "${target_writer_probe_state}"
  fi
  return "${rc}"
}

ftctl_dr_kvm_vmware_write_checkpoint() {
  local map_path="${1-}" baseline_path="${2-}" metrics_path="${3-}" manifest_path="${4-}" checkpoint_path="${5-}" cycle_type="${6-}"
  python3 - "${map_path}" "${baseline_path}" "${metrics_path}" "${manifest_path}" "${checkpoint_path}" "${cycle_type}" <<'PY'
import datetime
import json
import os
import sys

map_path, baseline_path, metrics_path, manifest_path, checkpoint_path, cycle_type = sys.argv[1:7]
def load(path):
    with open(path, "r", encoding="utf-8") as handle:
        return json.load(handle)
disk_map, baseline, metrics = load(map_path), load(baseline_path), load(metrics_path)
now = datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")
common = {
    "schemaVersion": 1,
    "planUuid": metrics.get("planUuid", disk_map.get("planUuid", "")),
    "runUuid": metrics.get("runUuid", ""),
    "direction": "KVM_TO_VMWARE",
    "providerPair": "ABLESTACK_TO_VMWARE",
    "cycleType": cycle_type,
    "cycleMetrics": metrics,
    "baselineGeneration": baseline.get("generation", 0),
    "baselineState": baseline.get("state", ""),
    "trackerState": metrics.get("trackerState", ""),
    "writerState": metrics.get("writerState", ""),
    "targetWritten": bool(metrics.get("targetWritten")),
    "writeVerified": bool(metrics.get("writeVerified")),
}
manifest = dict(common, state="reverse-data-durable", disks=disk_map.get("disks", []), completedAt=now)
checkpoint = dict(common, state="TARGET_READY", sourceCheckpointAt=now, targetDurableAt=now,
                  targetReadyRpoSeconds=0, completedAt=now)
for path, payload in ((manifest_path, manifest), (checkpoint_path, checkpoint)):
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as handle:
        json.dump(payload, handle, sort_keys=True, separators=(",", ":"))
        handle.write("\n")
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(tmp, path)
PY
}

ftctl_dr_kvm_vmware_replication_cycle() {
  local plan="${1-}" run="${2-}" profile_file="${3-}" sequence="${4-0}" requested="${5-}"
  local root map_path baseline_path cycle_dir metrics_path manifest_path checkpoint_path mover credentials_file effective rc=0
  [[ -n "${plan}" && -n "${run}" && -f "${profile_file}" ]] || return 2
  root="$(ftctl_dr_kvm_vmware_root "${plan}")"
  map_path="$(ftctl_dr_kvm_vmware_disk_map_path "${plan}")"
  baseline_path="$(ftctl_dr_kvm_vmware_baseline_path "${plan}")"
  cycle_dir="$(ftctl_dr_kvm_vmware_cycle_dir "${plan}" "${run}-cycle-${sequence}")"
  metrics_path="${cycle_dir}/metrics.json"
  manifest_path="${cycle_dir}/manifest.json"
  checkpoint_path="${cycle_dir}/checkpoint.json"
  ftctl_ensure_dir "${root}" "0755"
  ftctl_ensure_dir "${cycle_dir}" "0755"
  ftctl_dr_kvm_vmware_canonicalize_profile "${profile_file}" "${map_path}" || return 67
  effective="$(ftctl_dr_kvm_vmware_cycle_type "${plan}" "${requested}")" || return $?
  mover="$(ftctl_dr_kvm_vmware_effective_mover 2>/dev/null || true)"
  [[ -n "${mover}" ]] || return 65
  credentials_file="$(ftctl_dr_runtime_credential_path "${plan}" 2>/dev/null || true)"
  FTCTL_DR_PLAN_UUID="${plan}" \
  FTCTL_DR_RUN_UUID="${run}" \
  FTCTL_DR_CHECKPOINT_SEQUENCE="${sequence}" \
  FTCTL_DR_CYCLE_TYPE="${effective}" \
  FTCTL_DR_KVM_VMWARE_DISK_MAP="${map_path}" \
  FTCTL_DR_KVM_VMWARE_BASELINE="${baseline_path}" \
  FTCTL_DR_CYCLE_METRICS_PATH="${metrics_path}" \
  FTCTL_DR_CREDENTIALS_FILE="$([[ -f "${credentials_file}" ]] && printf '%s' "${credentials_file}")" \
    "${mover}" || rc=$?
  [[ "${rc}" == "0" ]] || return "${rc}"
  jq -e '.targetWritten == true and .writeVerified == true and .writerState == "DURABLE" and .trackerState == "LOCAL_DURABLE"' \
    "${metrics_path}" >/dev/null || return 88
  ftctl_dr_kvm_vmware_write_checkpoint "${map_path}" "${baseline_path}" "${metrics_path}" "${manifest_path}" "${checkpoint_path}" "${effective}" || return $?
  ftctl_log_event "dr-runtime" "dr.kvm-vmware.cycle" "ok" "" "" \
    "plan=${plan} run=${run} sequence=${sequence} type=${effective} checkpoint=${checkpoint_path}"
  printf '%s\t%s\n' "${manifest_path}" "${checkpoint_path}"
}
