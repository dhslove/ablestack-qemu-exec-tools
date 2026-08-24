#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

ftctl_ensure_dir() { mkdir -p "$1"; }

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

FTCTL_REMOTE_NBD_PORT_BASE=11809
FTCTL_REMOTE_NBD_PORT_COUNT=4
ftctl_blockcopy_remote_nbd_candidate_port() { printf -v "$3" '%s' 11809; }
ftctl_dr_ablestack_local_port_in_use() { [[ "$1" == "11809" || "$1" == "11810" ]]; }
selected_port=""
ftctl_dr_ablestack_target_export_pick_port plan-a sda selected_port
[[ "${selected_port}" == "11811" ]]

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

echo "ftctl DR ABLESTACK remote RBD smoke: PASS"
