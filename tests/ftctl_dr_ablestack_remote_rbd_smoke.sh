#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

ftctl_ensure_dir() { mkdir -p "$1"; }
ftctl_dr_runtime_key() { printf '%s\n' "${1//[^A-Za-z0-9._-]/_}"; }
ftctl_dr_runtime_plan_dir() { printf '%s/runtime/%s\n' "${TMP}" "$(ftctl_dr_runtime_key "$1")"; }
ftctl_state_write_json_file() { printf '%s\n' "$2" > "$1"; }

# shellcheck source=../lib/ftctl/dr_ablestack.sh
source "${ROOT}/lib/ftctl/dr_ablestack.sh"

profile="${TMP}/profile.json"
canonical="${TMP}/canonical.json"
cat > "${profile}" <<'EOF'
{
  "source": {
    "provider": "ABLESTACK",
    "externalRef": "source-vm-uuid",
    "instanceName": "i-2-332-VM",
    "hostUuid": "source-host-uuid"
  },
  "target": {"provider": "ABLESTACK"},
  "mapping": {
    "disks": [{
      "device": "sda",
      "sourcePath": "rbd:rbd/source-image",
      "targetPath": "rbd:rbd/target-image",
      "sourceFormat": "raw",
      "targetFormat": "raw"
    }]
  },
  "transport": {
    "mode": "remote-nbd",
    "targetHostUuid": "target-host-uuid",
    "targetHostAddress": "10.10.32.2",
    "secondaryUri": "qemu+ssh://root@10.10.32.2/system",
    "sshUser": "root",
    "sshPort": "22",
    "sshKeyFile": "/root/.ssh/ftctl-dr/i-2-332-VM/id_ed25519",
    "remoteNbdExportAddress": "10.10.32.2",
    "targetStorageScope": "secondary-local"
  }
}
EOF

ftctl_dr_ablestack_canonicalize_profile "${profile}" "${canonical}"
[[ "$(jq -r '.source.instanceName' "${canonical}")" == "i-2-332-VM" ]]
[[ "$(jq -r '.transport.mode' "${canonical}")" == "remote-nbd" ]]
[[ "$(jq -r '.transport.targetStorageScope' "${canonical}")" == "secondary-local" ]]
[[ "$(jq -r '.disks[0].sourcePath' "${canonical}")" == "rbd:rbd/source-image" ]]
[[ "$(jq -r '.disks[0].targetPath' "${canonical}")" == "rbd:rbd/target-image" ]]

ftctl_dr_ablestack_remote_transport_load "${canonical}"
[[ "${FTCTL_PROFILE_BACKEND_MODE}" == "remote-nbd" ]]
[[ "${FTCTL_PROFILE_TARGET_STORAGE_SCOPE}" == "secondary-local" ]]
[[ "${FTCTL_PROFILE_SECONDARY_TARGET_DIR}" == "/dev/rbd" ]]

remote_path=""
ftctl_dr_ablestack_remote_rbd_path "rbd:rbd/target-image" remote_path
[[ "${remote_path}" == "/dev/rbd/rbd/target-image" ]]

grep -q 'rbd export-diff --from-snap' "${ROOT}/lib/ftctl/dr_ablestack.sh"
grep -q 'rbd import-diff' "${ROOT}/lib/ftctl/dr_ablestack.sh"
grep -q 'reason=baseline_unavailable' "${ROOT}/lib/ftctl/dr_ablestack.sh"
! grep -q 'rbd mirror' "${ROOT}/lib/ftctl/dr_ablestack.sh"

site_agent_profile="${TMP}/site-agent-profile.json"
site_agent_canonical="${TMP}/site-agent-canonical.json"
cat > "${site_agent_profile}" <<'EOF'
{
  "planUuid": "plan-a",
  "source": {
    "provider": "ABLESTACK",
    "externalRef": "source-vm-uuid",
    "instanceName": "i-2-332-VM",
    "hostUuid": "source-host-uuid"
  },
  "target": {"provider": "ABLESTACK"},
  "mapping": {
    "disks": [{
      "device": "sda",
      "sourcePath": "rbd:rbd/source-image",
      "targetPath": "rbd:rbd/target-image",
      "sourceFormat": "raw",
      "targetFormat": "raw",
      "sizeBytes": 1073741824,
      "sourceType": "rbd",
      "targetType": "rbd"
    }]
  },
  "transport": {
    "mode": "site-agent-nbd",
    "controlMode": "site-agent",
    "targetHostUuid": "target-host-uuid",
    "targetHostAddress": "10.10.32.2",
    "targetStorageScope": "secondary-local",
    "exports": [{
      "device": "sda",
      "host": "10.10.32.2",
      "port": 12032,
      "name": "dr-export-sda",
      "uri": "nbd://10.10.32.2:12032/dr-export-sda"
    }]
  }
}
EOF

ftctl_dr_ablestack_canonicalize_profile "${site_agent_profile}" "${site_agent_canonical}"
[[ "$(jq -r '.transport.mode' "${site_agent_canonical}")" == "site-agent-nbd" ]]
[[ "$(jq -r '.transport.exports[0].name' "${site_agent_canonical}")" == "dr-export-sda" ]]
ftctl_dr_ablestack_site_agent_transport_load "${site_agent_canonical}"
[[ "${FTCTL_PROFILE_BACKEND_MODE}" == "remote-nbd" ]]
[[ "${FTCTL_PROFILE_PROVISIONING_BACKEND}" == "cloud-managed" ]]
[[ "$(ftctl_dr_ablestack_export_value "${site_agent_canonical}" sda uri)" == "nbd://10.10.32.2:12032/dr-export-sda" ]]
grep -q 'ftctl_dr_ablestack_site_agent_incremental_once' "${ROOT}/lib/ftctl/dr_ablestack.sh"
grep -q 'rbd_extent_copy.py' "${ROOT}/lib/ftctl/dr_ablestack.sh"
[[ "$(ftctl_dr_ablestack_normalize_cycle_type incremental)" == "INCREMENTAL" ]]
[[ "$(ftctl_dr_ablestack_normalize_cycle_type cbt-incremental)" == "CBT_INCREMENTAL" ]]

checkpoint_manifest="${TMP}/checkpoint-manifest.json"
checkpoint_path="${TMP}/checkpoint.json"
printf '{"disks":[]}\n' > "${checkpoint_manifest}"
ftctl_dr_ablestack_write_checkpoint "${site_agent_canonical}" "${checkpoint_manifest}" "${checkpoint_path}" \
  TARGET_READY 2026-08-24T00:00:00Z 2026-08-24T00:00:02Z 2 \
  CBT_INCREMENTAL CBT_INCREMENTAL true 4096 "" 7 1 1
jq -e '.requestedMode == "CBT_INCREMENTAL"
  and .effectiveMode == "CBT_INCREMENTAL"
  and .incrementalVerified == true
  and .changedBytes == 4096
  and .targetWrittenBytes == 4096
  and .sequence == 7
  and .baselineGeneration == 7
  and .cycleToken == "plan-a:7"' "${checkpoint_path}" >/dev/null
jq -e '.cycleCommitState == "LOCAL_DURABLE"
  and .nbdTeardownState == "DRAINED"
  and .nbdSourceDeviceCount == 1
  and .nbdTargetDeviceCount == 1
  and .nbdQuarantinedDeviceCount == 0
  and .nbdTeardownCompletedAtEpochMs > 0' "${checkpoint_path}" >/dev/null

FTCTL_REMOTE_NBD_PORT_BASE=11809
FTCTL_REMOTE_NBD_PORT_COUNT=4
ftctl_blockcopy_remote_nbd_candidate_port() { printf -v "$3" '%s' 11809; }
ftctl_dr_ablestack_local_port_in_use() { [[ "$1" == "11809" || "$1" == "11810" ]]; }
selected_port=""
ftctl_dr_ablestack_target_export_pick_port plan-a sda selected_port
[[ "${selected_port}" == "11811" ]]

export_unit_a="$(ftctl_dr_ablestack_target_export_unit_name plan-a sda)"
export_unit_b="$(ftctl_dr_ablestack_target_export_unit_name plan-a sda)"
export_unit_c="$(ftctl_dr_ablestack_target_export_unit_name plan-a sdb)"
[[ "${export_unit_a}" == "${export_unit_b}" ]]
[[ "${export_unit_a}" != "${export_unit_c}" ]]
[[ "${export_unit_a}" =~ ^ablestack-vm-ftctl-dr-export-[0-9a-f]{20}\.service$ ]]
grep -q 'systemd-run --quiet --collect --unit' "${ROOT}/lib/ftctl/dr_ablestack.sh"
grep -q 'property=Restart=on-failure' "${ROOT}/lib/ftctl/dr_ablestack.sh"

rollback_records="${TMP}/rollback.records"
rollback_manifest="${TMP}/rollback.json"
rollback_pid="${TMP}/rollback.pid"
sleep 60 &
rollback_process=$!
printf '%s\n' "${rollback_process}" > "${rollback_pid}"
python3 - "${rollback_records}" "${rollback_pid}" <<'PY'
import json,sys
with open(sys.argv[1], "w", encoding="utf-8") as fh:
    fh.write(json.dumps({"pidFile": sys.argv[2]}, separators=(",", ":")) + "\n")
PY
printf '{}\n' > "${rollback_manifest}"
ftctl_dr_ablestack_target_export_abort "${rollback_records}" "${rollback_manifest}"
! kill -0 "${rollback_process}" 2>/dev/null
[[ ! -e "${rollback_records}" && ! -e "${rollback_manifest}" && ! -e "${rollback_pid}" ]]

FTCTL_DR_TARGET_EXPORT_PERSIST_ROOT="${TMP}/persist"
persistent_manifest="${TMP}/persistent-exports.json"
cat > "${persistent_manifest}" <<'EOF'
{"schemaVersion":1,"exports":[{"device":"sda","host":"127.0.0.1","port":12032,"name":"dr-export-sda"}]}
EOF
ftctl_dr_ablestack_export_persist_intent plan-persist run-persist RUNNING "${site_agent_profile}" "${persistent_manifest}"
persist_dir="$(ftctl_dr_ablestack_export_persist_dir plan-persist)"
[[ "$(jq -r '.desiredState' "${persist_dir}/intent.json")" == "RUNNING" ]]
[[ "$(jq -r '.runUuid' "${persist_dir}/intent.json")" == "run-persist" ]]
[[ "$(jq -r '.exports[0].port' "${persist_dir}/exports.json")" == "12032" ]]

ftctl_dr_ablestack_local_port_in_use() { return 1; }
selected_port=""
ftctl_dr_ablestack_target_export_pick_port plan-persist sda selected_port
[[ "${selected_port}" == "12032" ]]

listener_port_file="${TMP}/listener.port"
python3 - "${listener_port_file}" <<'PY' &
import socket, sys, time
s = socket.socket()
s.bind(("127.0.0.1", 0))
s.listen(4)
with open(sys.argv[1], "w", encoding="utf-8") as fh:
    fh.write(str(s.getsockname()[1]))
while True:
    conn, _ = s.accept()
    conn.close()
PY
listener_pid=$!
for _ in $(seq 1 50); do [[ -s "${listener_port_file}" ]] && break; sleep 0.1; done
listener_port="$(cat "${listener_port_file}")"
ftctl_dr_ablestack_target_export_reachable 127.0.0.1 "${listener_port}" 1
kill "${listener_pid}"
wait "${listener_pid}" 2>/dev/null || true
! ftctl_dr_ablestack_target_export_reachable 127.0.0.1 "${listener_port}" 1

# A Plan Owner may dispatch target-side test actions while the canonical
# restore-point journal remains on a remote KVM source worker.
ftctl_state_vm_key() { printf '%s\n' "${1//[^A-Za-z0-9._-]/_}"; }
ftctl_now_iso8601() { printf '%s\n' 2026-08-24T00:05:00Z; }
export FTCTL_RUN_DIR="${TMP}/runtime-root"
# shellcheck source=../lib/ftctl/dr_runtime.sh
source "${ROOT}/lib/ftctl/dr_runtime.sh"

plan_owner_profile="${TMP}/plan-owner-profile.json"
plan_owner_artifact="${TMP}/plan-owner-artifact.json"
checkpoint_ref="ftctl:plan-owner:source-run:12"
cat > "${plan_owner_profile}" <<EOF
{
  "direction":"KVM_TO_KVM",
  "workers":{"source":"source-host","coordinator":"target-host","target":"target-host"},
  "request":{
    "schedulerTransitionScope":"REMOTE_SOURCE",
    "checkpointContractVersion":1,
    "checkpointPlanUuid":"plan-owner",
    "checkpointRef":"${checkpoint_ref}",
    "restorePointRef":"${checkpoint_ref}",
    "checkpointSequence":12,
    "checkpointState":"READY",
    "checkpointCycleType":"CBT_INCREMENTAL",
    "checkpointCycleToken":"plan-owner:12",
    "checkpointEffectiveMode":"CBT_INCREMENTAL",
    "checkpointSourceCreatedAt":"2026-08-24T00:04:57Z",
    "checkpointTargetReadyAt":"2026-08-24T00:05:00Z",
    "checkpointTargetReadyRpoSeconds":3
  }
}
EOF
cat > "${plan_owner_artifact}" <<EOF
{"contractVersion":3,"planUuid":"plan-owner","runUuid":"test-run","checkpointRef":"${checkpoint_ref}","checkpointSequence":12,"disks":[]}
EOF
ftctl_dr_runtime_remote_source_transition "${plan_owner_profile}"
ftctl_dr_runtime_ensure_plan_dirs plan-owner
plan_owner_run_path="$(ftctl_dr_runtime_run_path plan-owner test-run)"
plan_owner_status_path="$(ftctl_dr_runtime_status_path plan-owner)"
printf 'state=READY\n' > "${plan_owner_run_path}"
printf 'state=READY\nrestore_points_path=%s\n' "${TMP}/missing-restore-points.jsonl" > "${plan_owner_status_path}"
ftctl_dr_runtime_prepare_test_session plan-owner test-run "${plan_owner_profile}" "${checkpoint_ref}" \
  "${plan_owner_run_path}" "${plan_owner_status_path}" "${plan_owner_artifact}"
plan_owner_session="$(ftctl_dr_runtime_test_session_path plan-owner test-run)"
jq -e --arg ref "${checkpoint_ref}" '.restorePoint.ref == $ref
  and .restorePoint.checkpointSequence == 12
  and .request.schedulerTransitionScope == "REMOTE_SOURCE"' "${plan_owner_session}" >/dev/null

invalid_profile="${TMP}/invalid-plan-owner-profile.json"
jq '.request.checkpointPlanUuid="wrong-plan"' "${plan_owner_profile}" > "${invalid_profile}"
ftctl_dr_runtime_ensure_plan_dirs invalid-plan
invalid_run_path="$(ftctl_dr_runtime_run_path invalid-plan invalid-run)"
invalid_status_path="$(ftctl_dr_runtime_status_path invalid-plan)"
printf 'state=READY\n' > "${invalid_run_path}"
printf 'state=READY\nrestore_points_path=%s\n' "${TMP}/missing-invalid-restore-points.jsonl" > "${invalid_status_path}"
if ftctl_dr_runtime_prepare_test_session invalid-plan invalid-run "${invalid_profile}" "${checkpoint_ref}" \
  "${invalid_run_path}" "${invalid_status_path}" "${plan_owner_artifact}"; then
  echo "controller checkpoint with mismatched Plan was accepted" >&2
  exit 1
else
  [[ "$?" == "44" ]]
fi

reconcile_marker="${TMP}/reconciled"
ftctl_log_event() { :; }
ftctl_dr_ablestack_target_export_start() {
  printf '%s\t%s\t%s\n' "$1" "$2" "$3" > "${reconcile_marker}"
}
rm -f "$(ftctl_dr_ablestack_export_manifest_path plan-persist)"
ftctl_dr_ablestack_target_export_reconcile_all 0
[[ "$(cut -f1 "${reconcile_marker}")" == "plan-persist" ]]
[[ "$(cut -f2 "${reconcile_marker}")" == "run-persist" ]]

grep -q 'DR_TARGET_EXPORT_UNAVAILABLE' "${ROOT}/lib/ftctl/dr_scheduler.sh"
grep -q 'pending_resource_sequence=${sequence}' "${ROOT}/lib/ftctl/dr_scheduler.sh"
grep -q 'rc.*100' "${ROOT}/lib/ftctl/dr_scheduler.sh"

echo "ftctl DR ABLESTACK remote RBD smoke: PASS"
