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

FTCTL_DR_KVM_VMWARE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Reuse the deterministic NBD allocation/drain and VDDK connection helpers.
# shellcheck source=/dev/null
source "${FTCTL_DR_KVM_VMWARE_LIB_DIR}/dr_vmware_mover.sh"

ftctl_kvm_vmware_die() {
  local rc="${1:-65}"
  shift || true
  printf 'ERROR: %s\n' "$*" >&2
  exit "${rc}"
}

ftctl_kvm_vmware_credential() {
  local expression="${1-}" default_value="${2-}"
  ftctl_vmware_mover_json_value "${FTCTL_DR_CREDENTIALS_FILE:-}" "${expression}" "${default_value}"
}

ftctl_kvm_vmware_write_password_file() {
  local output_path="${1-}" password
  password="$(ftctl_kvm_vmware_credential '([.credentials.source,.credentials.target,.source,.target] | map(select(type == "object" and (((.type // .provider // "") | ascii_upcase) | test("VCENTER|VMWARE")))) | .[0]) as $vc | $vc.auth.password // $vc.password' '')"
  [[ -n "${password}" ]] || ftctl_kvm_vmware_die 65 "DR_REVERSE_VMWARE_CREDENTIALS_MISSING: vCenter password is unavailable"
  umask 077
  printf '%s' "${password}" > "${output_path}"
}

ftctl_kvm_vmware_target_power_state() {
  local govc_bin="${1-}" endpoint="${2-}" username="${3-}" password_file="${4-}" tls_verify="${5-}" vm_ref="${6-}"
  local info
  info="$(GOVC_URL="$(ftctl_vmware_mover_govc_url "${endpoint}")" \
    GOVC_USERNAME="${username}" GOVC_PASSWORD="$(cat "${password_file}")" \
    GOVC_INSECURE="$([[ "${tls_verify}" == "true" ]] && printf 'false' || printf 'true')" \
    "${govc_bin}" vm.info -json "${vm_ref}")" || return 1
  jq -r '.. | .powerState? // empty' <<< "${info}" | head -n 1
}

ftctl_kvm_vmware_build_extent_file() {
  local cycle_type="${1-}" pool="${2-}" image="${3-}" previous_snapshot="${4-}" new_snapshot="${5-}" virtual_bytes="${6-}" output_path="${7-}"
  if [[ "${cycle_type}" == "FULL_REVERSE_SEED" ]]; then
    jq -cn --argjson size "${virtual_bytes}" '{areas:[{offset:0,length:$size,exists:true}]}' > "${output_path}"
    return 0
  fi
  [[ -n "${previous_snapshot}" ]] || return 83
  rbd diff --from-snap "${previous_snapshot}" "${pool}/${image}@${new_snapshot}" --format json \
    | jq '{areas:[.[] | {offset:(.offset|tonumber),length:(.length|tonumber),exists:(.exists != false)}]}' > "${output_path}"
}

ftctl_kvm_vmware_load_previous_snapshot() {
  local baseline_path="${1-}" disk_index="${2-}" cycle_type="${3-}"
  local snapshot=""

  if [[ ! -s "${baseline_path}" ]]; then
    [[ "${cycle_type}" == "FULL_REVERSE_SEED" ]] || return 83
    printf '\n'
    return 0
  fi

  jq -e '.schemaVersion == 1
    and .state == "LOCAL_DURABLE"
    and .direction == "KVM_TO_VMWARE"
    and (.disks | type == "array")' "${baseline_path}" >/dev/null 2>&1 || return 84
  snapshot="$(jq -r --argjson index "${disk_index}" \
    '[.disks[] | select(.diskIndex == $index) | .snapshot][0] // ""' \
    "${baseline_path}")" || return 84
  [[ -n "${snapshot}" || "${cycle_type}" == "FULL_REVERSE_SEED" ]] || return 83
  printf '%s\n' "${snapshot}"
}

ftctl_kvm_vmware_start_writer() {
  local endpoint="${1-}" username="${2-}" password_file="${3-}" tls_verify="${4-}" thumbprint="${5-}" libdir="${6-}"
  local vm_ref="${7-}" vmdk="${8-}" socket_path="${9-}" log_path="${10-}" transports
  endpoint="$(ftctl_vmware_mover_normalize_vcenter_server "${endpoint}")"
  transports="${FTCTL_DR_VMWARE_VDDK_TRANSPORTS:-nbd:nbdssl}"
  if [[ "${tls_verify}" != "true" ]]; then
    thumbprint="$(ftctl_vmware_mover_resolve_thumbprint "${endpoint}" "${tls_verify}" "${thumbprint}" || true)"
    [[ -n "${thumbprint}" ]] || return 77
  fi
  local args=(--exit-with-parent --foreground --unix "${socket_path}" vddk
    "server=${endpoint}" "user=${username}" "password=+${password_file}"
    "file=${vmdk}" "single-link=true" "vm=moref=${vm_ref}")
  [[ -n "${transports}" ]] && args+=("transports=${transports}")
  [[ -n "${thumbprint}" && "${tls_verify}" != "true" ]] && args+=("thumbprint=${thumbprint}")
  [[ -n "${libdir}" && -d "${libdir}" ]] && args+=("libdir=${libdir}")
  nbdkit "${args[@]}" > "${log_path}" 2>&1 &
  printf '%s\n' "$!"
}

ftctl_kvm_vmware_patch_disk() {
  local row="${1-}" cycle_type="${2-}" previous_snapshot="${3-}" new_snapshot="${4-}"
  local endpoint="${5-}" username="${6-}" password_file="${7-}" tls_verify="${8-}" thumbprint="${9-}" libdir="${10-}"
  local metrics_path="${11-}" extent_path="${12-}" work_dir source_dev="" target_dev="" pid="" rc=0 cleanup_rc=0
  local pool image vmdk vm_ref virtual_bytes source_uri writer_log lock_file
  pool="$(jq -r '.sourcePool' <<< "${row}")"
  image="$(jq -r '.sourceImage' <<< "${row}")"
  vmdk="$(jq -r '.targetVmdkPath' <<< "${row}")"
  vm_ref="$(jq -r '.targetVmRef' <<< "${row}")"
  virtual_bytes="$(jq -r '.virtualBytes' <<< "${row}")"
  source_uri="rbd:${pool}/${image}@${new_snapshot}"
  work_dir="$(mktemp -d -t ftctl.kvm.vmware.XXXXXX)"
  writer_log="${work_dir}/vddk-writer.log"
  lock_file="${FTCTL_DR_VMWARE_NBD_LOCK:-/run/ablestack-vm-ftctl/dr-runtime/nbd.lock}"

  ftctl_kvm_vmware_build_extent_file "${cycle_type}" "${pool}" "${image}" "${previous_snapshot}" "${new_snapshot}" "${virtual_bytes}" "${extent_path}" || {
    rm -rf "${work_dir}"
    return 83
  }
  mkdir -p "$(dirname "${lock_file}")"
  exec 9>"${lock_file}"
  flock -x 9
  source_dev="$(ftctl_vmware_mover_free_nbd || true)"
  [[ -n "${source_dev}" ]] || { flock -u 9; rm -rf "${work_dir}"; return 86; }
  qemu-nbd --connect="${source_dev}" --format=raw "${source_uri}" >/dev/null || {
    flock -u 9; rm -rf "${work_dir}"; return 86;
  }
  FTCTL_DR_NBD_SOURCE_DEVICE_COUNT=1
  if ! ftctl_vmware_mover_wait_block_device_ready "${source_dev}" "${virtual_bytes}"; then
    ftctl_vmware_mover_nbd_drain "${source_dev}" "SOURCE" "QEMU_NBD" >/dev/null 2>&1 || true
    flock -u 9; rm -rf "${work_dir}"; return 89
  fi
  target_dev="$(ftctl_vmware_mover_free_nbd "${source_dev}" || true)"
  [[ -n "${target_dev}" ]] || {
    ftctl_vmware_mover_nbd_drain "${source_dev}" "SOURCE" "QEMU_NBD" >/dev/null 2>&1 || true
    flock -u 9; rm -rf "${work_dir}"; return 86;
  }
  pid="$(ftctl_kvm_vmware_start_writer "${endpoint}" "${username}" "${password_file}" "${tls_verify}" "${thumbprint}" "${libdir}" "${vm_ref}" "${vmdk}" "${work_dir}/writer.sock" "${writer_log}")" || rc=$?
  if [[ "${rc}" != "0" ]] || ! ftctl_vmware_mover_wait_for_socket "${work_dir}/writer.sock" "${pid}" "${FTCTL_DR_VMWARE_NBDKIT_READY_TIMEOUT}"; then
    ftctl_vmware_mover_nbd_drain "${source_dev}" "SOURCE" "QEMU_NBD" >/dev/null 2>&1 || true
    flock -u 9; ftctl_vmware_mover_cleanup_nbdkit "${pid}" "${work_dir}"; return 73
  fi
  if ! nbd-client -u -N default "${work_dir}/writer.sock" "${target_dev}" >/dev/null; then
    ftctl_vmware_mover_nbd_drain "${source_dev}" "SOURCE" "QEMU_NBD" >/dev/null 2>&1 || true
    flock -u 9; ftctl_vmware_mover_cleanup_nbdkit "${pid}" "${work_dir}"; return 86
  fi
  FTCTL_DR_NBD_TARGET_DEVICE_COUNT=1
  if ! ftctl_vmware_mover_wait_block_device_ready "${target_dev}" "${virtual_bytes}"; then
    ftctl_vmware_mover_nbd_drain "${target_dev}" "TARGET" "NBD_CLIENT" >/dev/null 2>&1 || true
    ftctl_vmware_mover_nbd_drain "${source_dev}" "SOURCE" "QEMU_NBD" >/dev/null 2>&1 || true
    flock -u 9; ftctl_vmware_mover_cleanup_nbdkit "${pid}" "${work_dir}"; return 89
  fi
  flock -u 9

  python3 "${FTCTL_DR_KVM_VMWARE_LIB_DIR}/dr_extent_patch.py" --source "${source_dev}" --target "${target_dev}" \
    --areas-json "${extent_path}" --expected-source-size "${virtual_bytes}" --expected-target-size "${virtual_bytes}" --verify > "${metrics_path}" || rc=$?
  cleanup_rc=0
  ftctl_vmware_mover_nbd_drain "${target_dev}" "TARGET" "NBD_CLIENT" || cleanup_rc=$?
  if [[ "${cleanup_rc}" == "0" ]]; then
    ftctl_vmware_mover_nbd_drain "${source_dev}" "SOURCE" "QEMU_NBD" || cleanup_rc=$?
  else
    ftctl_vmware_mover_nbd_drain "${source_dev}" "SOURCE" "QEMU_NBD" >/dev/null 2>&1 || true
  fi
  ftctl_vmware_mover_cleanup_nbdkit "${pid}" "${work_dir}"
  [[ "${rc}" == "0" ]] || return 86
  [[ "${cleanup_rc}" == "0" ]] || return "${cleanup_rc}"
  jq -e '.writeVerified == true and .verifiedBytes == .targetWrittenBytes' "${metrics_path}" >/dev/null || return 88
}

ftctl_kvm_vmware_commit_baseline_and_metrics() {
  local map_path="${1-}" old_baseline="${2-}" new_rows="${3-}" disk_metrics="${4-}" output_baseline="${5-}" output_metrics="${6-}" cycle_type="${7-}"
  python3 - "${map_path}" "${old_baseline}" "${new_rows}" "${disk_metrics}" "${output_baseline}" "${output_metrics}" "${cycle_type}" \
    "${FTCTL_DR_PLAN_UUID:-}" "${FTCTL_DR_RUN_UUID:-}" "${FTCTL_DR_CHECKPOINT_SEQUENCE:-0}" <<'PY'
import json
import os
import sys
import time

map_path, old_path, rows_path, metrics_path, baseline_path, output_path, cycle_type, plan, run, sequence = sys.argv[1:11]
def load(path, default):
    try:
        with open(path, "r", encoding="utf-8") as handle:
            return json.load(handle)
    except (OSError, ValueError):
        return default
disk_map = load(map_path, {})
old = load(old_path, {})
rows = load(rows_path, [])
metrics = load(metrics_path, [])
sequence_number = int(sequence or 0)
generation = max(int(old.get("generation") or 0) + 1, sequence_number)
now = int(time.time() * 1000)
baseline_disks = []
for row in rows:
    baseline_disks.append({
        "diskIndex": int(row["diskIndex"]),
        "diskIdentityHash": row["diskIdentityHash"],
        "pool": row["sourcePool"],
        "image": row["sourceImage"],
        "snapshot": row["newSnapshot"],
        "previousSnapshot": row.get("previousSnapshot", ""),
        "generation": generation,
        "state": "LOCAL_DURABLE",
    })
baseline = {
    "schemaVersion": 1, "planUuid": plan, "direction": "KVM_TO_VMWARE",
    "providerPair": "ABLESTACK_TO_VMWARE", "generation": generation,
    "state": "LOCAL_DURABLE", "committedAtEpochMs": now, "disks": baseline_disks,
}
totals = {key: sum(int(item.get(key) or 0) for item in metrics) for key in (
    "changedExtentCount", "changedBytes", "sourceReadBytes", "targetWrittenBytes",
    "transferPayloadBytes", "durationMs", "verifiedBytes")}
virtual_bytes = sum(int(item.get("virtualBytes") or 0) for item in disk_map.get("disks", []))
duration_ms = totals["durationMs"]
payload = {
    "schemaVersion": 1, "planUuid": plan, "runUuid": run, "sequence": sequence_number,
    "direction": "KVM_TO_VMWARE", "providerPair": "ABLESTACK_TO_VMWARE",
    "requestedMode": cycle_type, "effectiveMode": cycle_type,
    "cycleToken": f"{plan}:{sequence_number}",
    "incrementalVerified": cycle_type != "FULL_REVERSE_SEED",
    "metricsEstimated": False, "virtualBytes": virtual_bytes,
    "throughputBps": int(totals["targetWrittenBytes"] * 1000 / duration_ms) if duration_ms > 0 else 0,
    "baselineGeneration": generation, "trackerState": "LOCAL_DURABLE",
    "writerState": "DURABLE", "targetWritten": True, "writeVerified": True,
    "cycleCommitState": "LOCAL_DURABLE", "disks": metrics,
}
payload.update(totals)
for path, value in ((baseline_path, baseline), (output_path, payload)):
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as handle:
        json.dump(value, handle, sort_keys=True, separators=(",", ":"))
        handle.write("\n")
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(tmp, path)
PY
}

main() {
  local map_path="${FTCTL_DR_KVM_VMWARE_DISK_MAP:-}" baseline_path="${FTCTL_DR_KVM_VMWARE_BASELINE:-}" metrics_path="${FTCTL_DR_CYCLE_METRICS_PATH:-}"
  local credentials_file="${FTCTL_DR_CREDENTIALS_FILE:-}" cycle_type="${FTCTL_DR_CYCLE_TYPE:-FULL_REVERSE_SEED}"
  local endpoint username tls_verify thumbprint libdir govc_bin vm_ref power_state work_dir password_file rows_path disk_metrics_path
  local index row pool image previous_snapshot new_snapshot metric_path extent_path rc=0 baseline_file_state
  [[ -f "${map_path}" && -n "${baseline_path}" && -n "${metrics_path}" ]] || ftctl_kvm_vmware_die 65 "DR_REVERSE_MAP_MISSING"
  for command in jq rbd qemu-nbd nbd-client nbdkit blockdev flock python3; do
    ftctl_vmware_mover_require "${command}" 65
  done
  work_dir="$(mktemp -d -t ftctl.kvm.vmware.cycle.XXXXXX)"
  password_file="${work_dir}/vcenter.password"
  rows_path="${work_dir}/new-baseline-rows.json"
  disk_metrics_path="${work_dir}/disk-metrics.json"
  printf '[]\n' > "${rows_path}"
  printf '[]\n' > "${disk_metrics_path}"
  ftctl_kvm_vmware_write_password_file "${password_file}"
  endpoint="$(ftctl_kvm_vmware_credential '([.credentials.source,.credentials.target,.source,.target] | map(select(type == "object" and (((.type // .provider // "") | ascii_upcase) | test("VCENTER|VMWARE")))) | .[0]) as $vc | $vc.endpoint' '')"
  username="$(ftctl_kvm_vmware_credential '([.credentials.source,.credentials.target,.source,.target] | map(select(type == "object" and (((.type // .provider // "") | ascii_upcase) | test("VCENTER|VMWARE")))) | .[0]) as $vc | $vc.principal // $vc.username' '')"
  tls_verify="$(ftctl_kvm_vmware_credential '([.credentials.source,.credentials.target,.source,.target] | map(select(type == "object" and (((.type // .provider // "") | ascii_upcase) | test("VCENTER|VMWARE")))) | .[0]) as $vc | $vc.tlsVerify' 'false')"
  thumbprint="$(ftctl_kvm_vmware_credential '([.credentials.source,.credentials.target,.source,.target] | map(select(type == "object" and (((.type // .provider // "") | ascii_upcase) | test("VCENTER|VMWARE")))) | .[0]) as $vc | $vc.thumbprint // $vc.tlsThumbprint' '')"
  libdir="$(ftctl_kvm_vmware_credential '([.credentials.source,.credentials.target,.source,.target] | map(select(type == "object" and (((.type // .provider // "") | ascii_upcase) | test("VCENTER|VMWARE")))) | .[0]) as $vc | $vc.vddkLibdir // $vc.libdir' '')"
  govc_bin="${libdir%/vddk}/bin/govc"
  [[ -x "${govc_bin}" ]] || govc_bin="$(ftctl_vmware_mover_resolve_govc_bin "${credentials_file}" "${libdir}" || true)"
  vm_ref="$(jq -r '.disks[0].targetVmRef' "${map_path}")"
  [[ -n "${endpoint}" && -n "${username}" && -x "${govc_bin}" ]] || ftctl_kvm_vmware_die 65 "DR_REVERSE_VMWARE_CREDENTIALS_MISSING"
  power_state="$(ftctl_kvm_vmware_target_power_state "${govc_bin}" "${endpoint}" "${username}" "${password_file}" "${tls_verify}" "${vm_ref}" || true)"
  [[ "${power_state}" == "poweredOff" || "${power_state}" == "POWERED_OFF" ]] || ftctl_kvm_vmware_die 76 "DR_REVERSE_TARGET_VM_NOT_STOPPED: ${vm_ref} state=${power_state:-unknown}"

  if [[ -s "${baseline_path}" ]]; then
    jq -e '.schemaVersion == 1
      and .state == "LOCAL_DURABLE"
      and .direction == "KVM_TO_VMWARE"
      and (.disks | type == "array")' "${baseline_path}" >/dev/null 2>&1 \
      || ftctl_kvm_vmware_die 84 "DR_REVERSE_BASELINE_INVALID"
    baseline_file_state="LOCAL_DURABLE"
  else
    [[ "${cycle_type}" == "FULL_REVERSE_SEED" ]] \
      || ftctl_kvm_vmware_die 83 "DR_REVERSE_BASELINE_REQUIRED"
    baseline_file_state="MISSING_EXPECTED"
  fi

  while IFS= read -r row; do
    index="$(jq -r '.diskIndex' <<< "${row}")"
    pool="$(jq -r '.sourcePool' <<< "${row}")"
    image="$(jq -r '.sourceImage' <<< "${row}")"
    rc=0
    previous_snapshot="$(ftctl_kvm_vmware_load_previous_snapshot \
      "${baseline_path}" "${index}" "${cycle_type}")" || rc=$?
    if [[ "${rc}" != "0" ]]; then
      [[ "${rc}" == "83" ]] \
        && ftctl_kvm_vmware_die "${rc}" "DR_REVERSE_BASELINE_REQUIRED: disk=${index} state=${baseline_file_state}"
      ftctl_kvm_vmware_die "${rc}" "DR_REVERSE_BASELINE_INVALID: disk=${index} state=${baseline_file_state}"
    fi
    new_snapshot="ftctl-dr-${FTCTL_DR_PLAN_UUID:0:8}-${FTCTL_DR_CHECKPOINT_SEQUENCE}-${index}"
    rbd snap create "${pool}/${image}@${new_snapshot}" || ftctl_kvm_vmware_die 86 "DR_REVERSE_SNAPSHOT_CREATE_FAILED: ${pool}/${image}"
    row="$(jq -c --arg old "${previous_snapshot}" --arg new "${new_snapshot}" '. + {previousSnapshot:$old,newSnapshot:$new}' <<< "${row}")"
    jq --argjson row "${row}" '. + [$row]' "${rows_path}" > "${rows_path}.tmp" && mv -f "${rows_path}.tmp" "${rows_path}"
  done < <(jq -c '.disks[]' "${map_path}")

  while IFS= read -r row; do
    index="$(jq -r '.diskIndex' <<< "${row}")"
    previous_snapshot="$(jq -r '.previousSnapshot' <<< "${row}")"
    new_snapshot="$(jq -r '.newSnapshot' <<< "${row}")"
    metric_path="${work_dir}/disk-${index}-metrics.json"
    extent_path="${work_dir}/disk-${index}-extents.json"
    if [[ "${cycle_type}" != "FULL_REVERSE_SEED" && -z "${previous_snapshot}" ]]; then
      rc=83
      break
    fi
    rc=0
    ftctl_kvm_vmware_patch_disk "${row}" "${cycle_type}" "${previous_snapshot}" "${new_snapshot}" \
      "${endpoint}" "${username}" "${password_file}" "${tls_verify}" "${thumbprint}" "${libdir}" "${metric_path}" "${extent_path}" || rc=$?
    if [[ "${rc}" != "0" ]]; then
      break
    fi
    jq --argjson index "${index}" --arg old "${previous_snapshot}" --arg new "${new_snapshot}" --arg mode "${cycle_type}" \
      '. + {diskIndex:$index,previousSnapshot:$old,newSnapshot:$new,effectiveMode:$mode,writerState:"DURABLE",trackerState:"PENDING_COMMIT"}' \
      "${metric_path}" > "${metric_path}.tmp" && mv -f "${metric_path}.tmp" "${metric_path}"
    jq --slurpfile item "${metric_path}" '. + $item' "${disk_metrics_path}" > "${disk_metrics_path}.tmp" && mv -f "${disk_metrics_path}.tmp" "${disk_metrics_path}"
  done < <(jq -c '.[]' "${rows_path}")
  if [[ "${rc}" != "0" ]]; then
    while IFS= read -r row; do
      rbd snap rm "$(jq -r '.sourcePool' <<< "${row}")/$(jq -r '.sourceImage' <<< "${row}")@$(jq -r '.newSnapshot' <<< "${row}")" >/dev/null 2>&1 || true
    done < <(jq -c '.[]' "${rows_path}")
    rm -rf "${work_dir}"
    exit "${rc}"
  fi
  ftctl_kvm_vmware_commit_baseline_and_metrics "${map_path}" "${baseline_path}" "${rows_path}" "${disk_metrics_path}" \
    "${baseline_path}" "${metrics_path}" "${cycle_type}" || ftctl_kvm_vmware_die 88 "DR_REVERSE_BASELINE_COMMIT_FAILED"
  while IFS= read -r row; do
    previous_snapshot="$(jq -r '.previousSnapshot' <<< "${row}")"
    [[ -z "${previous_snapshot}" ]] || rbd snap rm "$(jq -r '.sourcePool' <<< "${row}")/$(jq -r '.sourceImage' <<< "${row}")@${previous_snapshot}" >/dev/null 2>&1 || true
  done < <(jq -c '.[]' "${rows_path}")
  rm -rf "${work_dir}"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
