#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cloud-handoff-contract.XXXXXX")"
trap 'rm -rf -- "${WORK_DIR}"' EXIT

run_v2k_contract() (
  # shellcheck source=/dev/null
  source "${ROOT_DIR}/lib/v2k/cloudstack_api.sh"
  # shellcheck source=/dev/null
  source "${ROOT_DIR}/lib/v2k/target_cloud.sh"

  local manifest="${WORK_DIR}/v2k.json" result
  cat >"${manifest}" <<'JSON'
{
  "source":{"vm":{"name":"v2k-test","nics":[]}},
  "target":{"provider":"ablestack-cloud","storage":{"type":"rbd"},"format":"raw","cloud":{}},
  "runtime":{"source_validation":{"status":"passed"},"cloud":{"readiness":{"status":"degraded","inspection_required":true,"components":{"boot":{"status":"degraded","reason":"test-bootstrap-failure"},"controller":{"status":"degraded","fallback":"sata"}}}}},
  "disks":[{"disk_id":"root","role":"root","size_bytes":1024,"transfer":{"target_path":"rbd:pool/root"},"controller":{"kind":"scsi"}}]
}
JSON

  # shellcheck disable=SC2317
  v2k_cloud_target_resolve_runtime_json() { printf '%s' '{"endpoint":"endpoint","api_key":"key","secret_key":"secret"}'; }
  # shellcheck disable=SC2317
  v2k_cloud_target_ensure_manifest_nic_mappings() { return 0; }
  # shellcheck disable=SC2317
  v2k_cloud_target_required_config_json() { printf '%s' '{"storage_id":"storage","disk_offering_id":"offering","network_ids":["network"],"nic_mappings":[],"name":"v2k-test","display_name":"v2k-test"}'; }
  # shellcheck disable=SC2317
  v2k_cloud_target_validate_config() { return 0; }
  # shellcheck disable=SC2317
  v2k_cloud_target_source_deploy_params_json() { printf '%s' '{"details[0].rootDiskController":"sata"}'; }
  # shellcheck disable=SC2317
  v2k_cloud_target_import_path() { printf '%s' 'root'; }
  # shellcheck disable=SC2317
  v2k_cloud_target_validate_import_visible() { return 0; }
  # shellcheck disable=SC2317
  v2k_cloud_target_import_volume() { printf '%s' '{"id":"root-v2k","job_id":"job-root-v2k"}'; }
  # shellcheck disable=SC2317
  v2k_cloud_target_deploy_vm_for_volume() { printf '%s' '{"id":"vm-v2k","job_id":"job-vm-v2k"}'; }
  # shellcheck disable=SC2317
  v2k_cloud_target_wait_for_vm_nic_match() { printf '%s' '{"matched":false,"checks":[]}'; return 1; }
  # shellcheck disable=SC2317
  v2k_cloud_target_ensure_root_volume() { printf '%s' '{"volume":{"id":"root-v2k","type":"ROOT"},"converted":false}'; }

  result="$(v2k_cloud_target_cutover "${manifest}" 0 1 0 endpoint key secret '')"
  jq -e '
    .status == "completed_with_warning"
    and .vm_id == "vm-v2k"
    and .inspection_required == true
    and .started == false
  ' <<<"${result}" >/dev/null
  jq -e '
    .runtime.cloud.vm_id == "vm-v2k"
    and .runtime.cloud.checkpoint.complete == true
    and .runtime.cloud.checkpoint.stage == "inspection-required"
  ' "${manifest}" >/dev/null
)

run_n2k_contract() (
  # shellcheck source=/dev/null
  source "${ROOT_DIR}/lib/n2k/cloudstack_api.sh"
  # shellcheck source=/dev/null
  source "${ROOT_DIR}/lib/n2k/target_cloud.sh"

  local manifest="${WORK_DIR}/n2k.json" result
  cat >"${manifest}" <<'JSON'
{
  "source":{"vm":{"name":"n2k-test","nics":[]}},
  "target":{"provider":"ablestack-cloud","storage":{"type":"rbd"},"format":"raw","cloud":{}},
  "runtime":{"source_validation":{"status":"passed"},"cloud":{"readiness":{"status":"degraded","inspection_required":true,"components":{"controller":{"status":"degraded","fallback":"sata","reason":"test-controller-failure"}}}}},
  "disks":[{"disk_id":"root","role":"root","size_bytes":1024,"transfer":{"target_path":"rbd:pool/root"},"controller":{"kind":"scsi"}}]
}
JSON

  # shellcheck disable=SC2317
  n2k_cloud_target_resolve_runtime_json() { printf '%s' '{"endpoint":"endpoint","api_key":"key","secret_key":"secret"}'; }
  # shellcheck disable=SC2317
  n2k_cloud_target_ensure_manifest_nic_mappings() { return 0; }
  # shellcheck disable=SC2317
  n2k_cloud_target_required_config_json() { printf '%s' '{"storage_id":"storage","disk_offering_id":"offering","network_ids":["network"],"nic_mappings":[],"name":"n2k-test","display_name":"n2k-test"}'; }
  # shellcheck disable=SC2317
  n2k_cloud_target_validate_config() { return 0; }
  # shellcheck disable=SC2317
  n2k_cloud_target_source_deploy_params_json() { printf '%s' '{"details[0].rootDiskController":"sata"}'; }
  # shellcheck disable=SC2317
  n2k_cloud_target_import_path() { printf '%s' 'root'; }
  # shellcheck disable=SC2317
  n2k_cloud_target_validate_import_visible() { return 0; }
  # shellcheck disable=SC2317
  n2k_cloud_target_import_volume() { printf '%s' '{"id":"root-n2k","job_id":"job-root-n2k"}'; }
  # shellcheck disable=SC2317
  n2k_cloud_target_deploy_vm_for_volume() { printf '%s' '{"id":"vm-n2k","job_id":"job-vm-n2k"}'; }
  # shellcheck disable=SC2317
  n2k_cloud_target_wait_for_vm_nic_match() { printf '%s' '{"matched":false,"checks":[]}'; return 1; }
  # shellcheck disable=SC2317
  n2k_cloud_target_ensure_root_volume() { printf '%s' '{"volume":{"id":"root-n2k","type":"ROOT"},"converted":false}'; }

  result="$(n2k_cloud_target_cutover "${manifest}" 0 1 0 endpoint key secret '')"
  jq -e '
    .status == "completed_with_warning"
    and .vm_id == "vm-n2k"
    and .inspection_required == true
    and .started == false
  ' <<<"${result}" >/dev/null
  jq -e '
    .runtime.cloud.vm_id == "vm-n2k"
    and .runtime.cloud.checkpoint.complete == true
    and .runtime.cloud.checkpoint.stage == "inspection-required"
  ' "${manifest}" >/dev/null
)

run_v2k_submission_checkpoint() (
  # shellcheck source=/dev/null
  source "${ROOT_DIR}/lib/v2k/cloudstack_api.sh"
  # shellcheck source=/dev/null
  source "${ROOT_DIR}/lib/v2k/target_cloud.sh"
  local manifest="${WORK_DIR}/v2k-submitted.json"
  printf '%s\n' '{"runtime":{"cloud":{}}}' >"${manifest}"
  # shellcheck disable=SC2317
  v2k_cloud_api_get() { printf '%s' '{"importvolumeresponse":{"jobid":"job-v2k-submitted"}}'; }
  # shellcheck disable=SC2317
  v2k_cloud_wait_job() { return 1; }
  if v2k_cloud_target_import_volume \
      endpoint key secret storage offering root name '{}' "${manifest}" 0; then
    echo "[ERR] v2k accepted a failed submitted import job" >&2
    exit 1
  fi
  jq -e '
    .runtime.cloud.checkpoint.stage == "root-import-submitted"
    and .runtime.cloud.checkpoint.root_import_job_id == "job-v2k-submitted"
  ' "${manifest}" >/dev/null
)

run_n2k_submission_checkpoint() (
  # shellcheck source=/dev/null
  source "${ROOT_DIR}/lib/n2k/cloudstack_api.sh"
  # shellcheck source=/dev/null
  source "${ROOT_DIR}/lib/n2k/target_cloud.sh"
  local manifest="${WORK_DIR}/n2k-submitted.json"
  printf '%s\n' '{"runtime":{"cloud":{}}}' >"${manifest}"
  # shellcheck disable=SC2317
  n2k_cloud_api_get() { printf '%s' '{"importvolumeresponse":{"jobid":"job-n2k-submitted"}}'; }
  # shellcheck disable=SC2317
  n2k_cloud_wait_job() { return 1; }
  if n2k_cloud_target_import_volume \
      endpoint key secret storage offering root name '{}' "${manifest}" 0; then
    echo "[ERR] n2k accepted a failed submitted import job" >&2
    exit 1
  fi
  jq -e '
    .runtime.cloud.checkpoint.stage == "root-import-submitted"
    and .runtime.cloud.checkpoint.root_import_job_id == "job-n2k-submitted"
  ' "${manifest}" >/dev/null
)

run_v2k_contract
run_n2k_contract
run_v2k_submission_checkpoint
run_n2k_submission_checkpoint
echo "[OK] v2k/n2k Cloud inspection handoff contract passed"
