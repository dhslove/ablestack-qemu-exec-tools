#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

ftctl_now_iso8601() { printf '2026-08-28T00:00:00Z\n'; }
ftctl_dr_runtime_key() { printf '%s\n' "${1-}"; }
ftctl_dr_runtime_path_set() {
  local path="${1-}" item key tmp
  shift
  for item in "$@"; do
    key="${item%%=*}"
    tmp="${path}.tmp"
    awk -F= -v key="${key}" '$1 != key' "${path}" > "${tmp}" 2>/dev/null || true
    printf '%s\n' "${item}" >> "${tmp}"
    mv "${tmp}" "${path}"
  done
}

# shellcheck source=../lib/ftctl/guestprep.sh
source "${ROOT}/lib/ftctl/guestprep.sh"

RUN_PATH="${TMP}/run.state"
SESSION_PATH="${TMP}/session.json"
: > "${RUN_PATH}"
cat > "${SESSION_PATH}" <<'EOF'
{
  "profile": {
    "planUuid": "plan-rocky",
    "direction": "VMWARE_TO_KVM",
    "mapping": {
      "source": {"vm": {"guestId": "Rocky Linux 9", "firmware": "BIOS"}},
      "target": {"hardware": {"bootType": "BIOS", "bootMode": "LEGACY"}}
    }
  }
}
EOF

FTCTL_LIB_BASE="${ROOT}/lib"
FTCTL_DR_WINPE_ISO="${TMP}/missing-winpe.iso"
FTCTL_DR_VIRTIO_ISO="${TMP}/missing-virtio.iso"
ftctl_guestprep_preflight_test_session "${SESSION_PATH}" "${RUN_PATH}"
grep -Fxq 'guest_preflight_state=READY' "${RUN_PATH}"
grep -Fxq 'guest_family=linux' "${RUN_PATH}"
grep -Fxq 'guest_preflight_error_code=' "${RUN_PATH}"

FTCTL_LIB_BASE="${TMP}/missing-runtime"
ROOT_DIR="${TMP}/missing-root"
if ftctl_guestprep_preflight_test_session "${SESSION_PATH}" "${RUN_PATH}"; then
  echo 'missing v2k runtime was accepted' >&2
  exit 1
fi
grep -Fxq 'guest_preflight_state=ERROR' "${RUN_PATH}"
grep -Fxq 'guest_preflight_error_code=DR_GUEST_PREP_V2K_RUNTIME_MISSING' "${RUN_PATH}"

cat > "${SESSION_PATH}" <<'EOF'
{
  "profile": {
    "planUuid": "plan-native-rocky",
    "direction": "KVM_TO_KVM",
    "source": {"provider": "ABLESTACK"},
    "target": {"provider": "ABLESTACK"},
    "mapping": {
      "source": {"vm": {"guestId": "Rocky Linux 9", "firmware": "BIOS"}},
      "target": {"hardware": {"bootType": "BIOS", "bootMode": "LEGACY"}}
    }
  }
}
EOF
FTCTL_LIB_BASE="${TMP}/missing-runtime"
ROOT_DIR="${TMP}/missing-root"
ftctl_guestprep_preflight_test_session "${SESSION_PATH}" "${RUN_PATH}"
grep -Fxq 'guest_preflight_state=READY' "${RUN_PATH}"
grep -Fxq 'guest_family=linux' "${RUN_PATH}"
grep -Fxq 'guest_preflight_error_code=' "${RUN_PATH}"

mkdir -p "${TMP}/artifacts"
jq -c --arg path "${TMP}/artifacts" '
  .runUuid = "run-native-rocky"
  | .testArtifacts = {path:$path}
' "${SESSION_PATH}" > "${SESSION_PATH}.tmp"
mv "${SESSION_PATH}.tmp" "${SESSION_PATH}"
ftctl_dr_runtime_state_get_from_path() {
  local path="${1-}" key="${2-}"
  awk -F= -v key="${key}" '$1 == key {sub(/^[^=]*=/, ""); value=$0} END {print value}' "${path}" 2>/dev/null
}
ftctl_guestprep_write_manifest() {
  local _session="${1-}" manifest="${2-}"
  cat > "${manifest}" <<'EOF'
{
  "source":{"vm":{"guestFamily":"linux","guestId":"Rocky Linux 9"}},
  "target":{"storage":{"type":"file"},"format":"qcow2"},
  "disks":[{"storage":{"type":"file","format":"qcow2","locator":"/mnt/glue-gfs/native.qcow2"},"transfer":{"target_path":"/mnt/glue-gfs/native.qcow2"}}]
}
EOF
}
: > "${RUN_PATH}"
ftctl_guestprep_prepare_artifacts "${SESSION_PATH}" "${RUN_PATH}"
grep -Fxq 'state=TEST_ARTIFACTS_READY' "${RUN_PATH}"
grep -Fxq 'guest_prep_state=SKIPPED' "${RUN_PATH}"
grep -Fxq 'guest_prep_reason=NATIVE_COMPATIBILITY_PRESERVED' "${RUN_PATH}"
jq -e '.guestPreparation.state == "SKIPPED" and .guestPreparation.reason == "NATIVE_COMPATIBILITY_PRESERVED"' "${SESSION_PATH}" >/dev/null

FTCTL_LIB_BASE="${ROOT}/lib"
printf '{invalid\n' > "${SESSION_PATH}"
if ftctl_guestprep_preflight_test_session "${SESSION_PATH}" "${RUN_PATH}"; then
  echo 'malformed guest preparation session was accepted' >&2
  exit 1
fi
grep -Fxq 'guest_preflight_error_code=DR_GUEST_PREP_PROFILE_INVALID' "${RUN_PATH}"

printf 'ftctl DR guest preparation preflight smoke: PASS\n'
