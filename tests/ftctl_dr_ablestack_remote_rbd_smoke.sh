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

echo "ftctl DR ABLESTACK remote RBD smoke: PASS"
