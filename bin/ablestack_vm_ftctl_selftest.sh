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
# shellcheck disable=SC2034

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
LIB_BASE="${ROOT_DIR}/lib"

# shellcheck source=/dev/null
source "${LIB_BASE}/ftctl/common.sh"
# shellcheck source=/dev/null
source "${LIB_BASE}/ftctl/config.sh"
# shellcheck source=/dev/null
source "${LIB_BASE}/ftctl/logging.sh"
# shellcheck source=/dev/null
source "${LIB_BASE}/ftctl/libvirt_wrap.sh"
# shellcheck source=/dev/null
source "${LIB_BASE}/ftctl/state.sh"
# shellcheck source=/dev/null
source "${LIB_BASE}/ftctl/profile.sh"
# shellcheck source=/dev/null
source "${LIB_BASE}/ftctl/inventory.sh"
# shellcheck source=/dev/null
source "${LIB_BASE}/ftctl/cluster.sh"
# shellcheck source=/dev/null
source "${LIB_BASE}/ftctl/blockcopy.sh"
# shellcheck source=/dev/null
source "${LIB_BASE}/ftctl/standby.sh"
# shellcheck source=/dev/null
source "${LIB_BASE}/ftctl/xcolo.sh"
# shellcheck source=/dev/null
source "${LIB_BASE}/ftctl/fencing.sh"
# shellcheck source=/dev/null
source "${LIB_BASE}/ftctl/failover.sh"
# shellcheck source=/dev/null
source "${LIB_BASE}/ftctl/events.sh"
# shellcheck source=/dev/null
source "${LIB_BASE}/ftctl/verify.sh"
# shellcheck source=/dev/null
source "${LIB_BASE}/ftctl/orchestrator.sh"

SELFTEST_ROOT_DEFAULT="${ROOT_DIR}/build/ftctl_selftest"
SELFTEST_ROOT="${FTCTL_SELFTEST_ROOT:-${SELFTEST_ROOT_DEFAULT}}"
SELFTEST_CONFIG="${SELFTEST_ROOT}/ftctl-test.conf"

selftest_info() {
  printf '[SELFTEST] %s\n' "$*"
}

selftest_fail() {
  printf '[SELFTEST][FAIL] %s\n' "$*" >&2
  exit 1
}

selftest_assert_eq() {
  local got="${1-}"
  local expect="${2-}"
  local msg="${3-assert_eq failed}"
  [[ "${got}" == "${expect}" ]] || selftest_fail "${msg}: got='${got}' expect='${expect}'"
}

selftest_assert_file_contains() {
  local path="${1-}"
  local needle="${2-}"
  grep -q -- "${needle}" "${path}" || selftest_fail "missing '${needle}' in ${path}"
}

selftest_assert_file_not_contains() {
  local path="${1-}"
  local needle="${2-}"
  ! grep -q -- "${needle}" "${path}" || selftest_fail "unexpected '${needle}' in ${path}"
}

selftest_assert_contains() {
  local haystack="${1-}"
  local needle="${2-}"
  local msg="${3-assert_contains failed}"
  [[ "${haystack}" == *"${needle}"* ]] || selftest_fail "${msg}: missing '${needle}'"
}

selftest_prepare_config_file() {
  mkdir -p "${SELFTEST_ROOT}"
  cat > "${SELFTEST_CONFIG}" <<EOF
FTCTL_RUN_DIR="${SELFTEST_ROOT}/run"
FTCTL_LOG_DIR="${SELFTEST_ROOT}/log"
FTCTL_EVENTS_LOG="${SELFTEST_ROOT}/log/events.log"
FTCTL_STATE_DIR="${SELFTEST_ROOT}/state"
FTCTL_PROFILE_DIR="${SELFTEST_ROOT}/profiles"
FTCTL_CLUSTER_CONFIG="${SELFTEST_ROOT}/cluster.conf"
FTCTL_CLUSTER_DIR="${SELFTEST_ROOT}/cluster.d"
FTCTL_CLUSTER_HOSTS_DIR="${SELFTEST_ROOT}/cluster.d/hosts"
FTCTL_BLOCKCOPY_TARGET_BASE_DIR="${SELFTEST_ROOT}/blockcopy"
FTCTL_XML_BACKUP_DIR="${SELFTEST_ROOT}/xml"
EOF
}

selftest_reset_env() {
  rm -rf "${SELFTEST_ROOT}"
  selftest_prepare_config_file
  ftctl_config_init_defaults
  ftctl_config_load_file "${SELFTEST_CONFIG}"
  ftctl_config_finalize_paths
  ftctl_ensure_runtime_dirs
  FTCTL_DRY_RUN="1"
}

selftest_run_lint() {
  local files=(
    "bin/ablestack_vm_ftctl.sh"
    "bin/ablestack_vm_ftctl_selftest.sh"
    "lib/ftctl/common.sh"
    "lib/ftctl/config.sh"
    "lib/ftctl/logging.sh"
    "lib/ftctl/libvirt_wrap.sh"
    "lib/ftctl/state.sh"
    "lib/ftctl/profile.sh"
    "lib/ftctl/inventory.sh"
    "lib/ftctl/cluster.sh"
    "lib/ftctl/blockcopy.sh"
    "lib/ftctl/standby.sh"
    "lib/ftctl/xcolo.sh"
    "lib/ftctl/fencing.sh"
    "lib/ftctl/failover.sh"
    "lib/ftctl/events.sh"
    "lib/ftctl/verify.sh"
    "lib/ftctl/orchestrator.sh"
    "completions/ablestack_vm_ftctl"
  )
  selftest_info "running bash -n"
  bash -n "${files[@]}"
  if command -v shellcheck >/dev/null 2>&1; then
    selftest_info "running shellcheck"
    shellcheck "${files[@]}"
  else
    selftest_info "shellcheck not found, skipping"
  fi
}

selftest_case_cluster_cli() {
  selftest_reset_env
  selftest_info "cluster config CLI"

  bash "${ROOT_DIR}/bin/ablestack_vm_ftctl.sh" config init-cluster \
    --config "${SELFTEST_CONFIG}" \
    --cluster-name demo-cluster \
    --local-host-id host-01 >/dev/null

  bash "${ROOT_DIR}/bin/ablestack_vm_ftctl.sh" config host-upsert \
    --config "${SELFTEST_CONFIG}" \
    --host-id host-01 \
    --role primary \
    --management-ip 10.0.0.11 \
    --libvirt-uri qemu+ssh://host-01/system \
    --blockcopy-ip 172.16.10.11 \
    --xcolo-control-ip 172.16.20.11 \
    --xcolo-data-ip 172.16.30.11 >/dev/null

  selftest_assert_file_contains "${SELFTEST_ROOT}/cluster.conf" "FTCTL_CLUSTER_NAME=\"demo-cluster\""
  selftest_assert_file_contains "${SELFTEST_ROOT}/cluster.d/hosts/host-01.conf" "FTCTL_HOST_MANAGEMENT_IP=\"10.0.0.11\""
}

selftest_case_blockcopy_and_standby() {
  selftest_reset_env
  selftest_info "blockcopy/standby dry-run"

  local vm="demo"
  local bundle="${SELFTEST_ROOT}/xml/${vm}"
  FTCTL_PROFILE_MODE="ha"
  FTCTL_PROFILE_PRIMARY_URI="qemu:///system"
  FTCTL_PROFILE_SECONDARY_URI="qemu+ssh://peer/system"
  FTCTL_PROFILE_SECONDARY_VM_NAME="${vm}-standby"
  ftctl_state_init_vm "${vm}"
  mkdir -p "${bundle}"

  cat > "${bundle}/standby.xml" <<EOF
<domain type='kvm'>
  <name>${vm}</name>
  <uuid>1234</uuid>
  <devices>
    <disk type='file' device='disk'>
      <source file='/var/lib/libvirt/images/${vm}.qcow2'/>
      <target dev='vda' bus='virtio'/>
    </disk>
  </devices>
</domain>
EOF

  ftctl_state_set "${vm}" \
    "standby_xml_seed=${bundle}/standby.xml" \
    "primary_persistence=no"
  cat > "$(ftctl_blockcopy_state_path "${vm}")" <<EOF
vda|/var/lib/libvirt/images/${vm}.qcow2|/mirror/${vm}-vda.qcow2|qcow2|running|yes
EOF

  ftctl_standby_prepare "${vm}"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "standby_state")" "prepared-transient" "standby prepare"
  selftest_assert_file_contains "$(ftctl_state_get "${vm}" "standby_xml_generated")" "/mirror/${vm}-vda.qcow2"
  selftest_assert_file_contains "$(ftctl_state_get "${vm}" "standby_xml_generated")" "<name>${vm}-standby</name>"

  ftctl_standby_activate "${vm}"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "standby_state")" "start-dry-run" "standby activate"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "active_side")" "secondary" "standby activate side"
}

selftest_case_libvirt_managed_peer_krbd_map() (
  selftest_reset_env
  selftest_info "libvirt-managed peer krbd map"

  local vm="krbd-standby"
  local bundle="${SELFTEST_ROOT}/xml/${vm}"
  local call_log="${SELFTEST_ROOT}/peer-map-calls.log"
  FTCTL_DRY_RUN="0"
  FTCTL_PROFILE_MODE="ha"
  FTCTL_PROFILE_PRIMARY_URI="qemu:///system"
  FTCTL_PROFILE_SECONDARY_URI="qemu+ssh://peer/system"
  FTCTL_PROFILE_PROVISIONING_BACKEND="libvirt-managed"
  FTCTL_PROFILE_SECONDARY_VM_NAME="${vm}-standby"
  FTCTL_PROFILE_FENCING_SSH_USER="root"
  ftctl_state_init_vm "${vm}"
  mkdir -p "${bundle}"

  cat > "${bundle}/standby.xml" <<EOF
<domain type='kvm'>
  <name>${vm}</name>
  <devices>
    <disk type='file' device='disk'>
      <source file='/var/lib/libvirt/images/${vm}.qcow2'/>
      <target dev='vda' bus='virtio'/>
    </disk>
  </devices>
</domain>
EOF

  ftctl_state_set "${vm}" \
    "standby_xml_seed=${bundle}/standby.xml" \
    "primary_persistence=no"
  cat > "$(ftctl_blockcopy_state_path "${vm}")" <<EOF
vda|/dev/rbd/rbd/${vm}-source|/dev/rbd/rbd/${vm}-mirror|raw|copy|yes
EOF

  ftctl_standby_prepare "${vm}"

  # shellcheck disable=SC2317
  ftctl_blockcopy_remote_target_host_user() {
    printf -v "$1" '%s' "peer"
    printf -v "$2" '%s' "root"
  }
  # shellcheck disable=SC2317
  ftctl_blockcopy_remote_exec() {
    printf 'REMOTE:%s:%s:%s\n' "$1" "$2" "$6" >> "${call_log}"
    printf -v "$3" '%s' ""
    printf -v "$4" '%s' ""
    printf -v "$5" '%s' "0"
  }
  # shellcheck disable=SC2317
  ftctl_virsh() {
    printf 'VIRSH:%s\n' "$*" >> "${call_log}"
    printf -v "$2" '%s' ""
    printf -v "$3" '%s' ""
    printf -v "$4" '%s' "0"
  }

  ftctl_standby_activate "${vm}"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "standby_state")" "running" "libvirt-managed standby activate"
  selftest_assert_file_contains "${call_log}" "rbd map"
  selftest_assert_file_contains "${call_log}" "/dev/rbd/rbd/${vm}-mirror"
  selftest_assert_file_contains "${call_log}" "VIRSH:"
)

selftest_case_standby_activate_already_exists() (
  selftest_reset_env
  selftest_info "standby activate already exists"

  local vm="already-running-standby"
  local bundle="${SELFTEST_ROOT}/xml/${vm}"
  FTCTL_DRY_RUN="0"
  FTCTL_PROFILE_MODE="ha"
  FTCTL_PROFILE_PRIMARY_URI="qemu:///system"
  FTCTL_PROFILE_SECONDARY_URI="qemu+ssh://peer/system"
  FTCTL_PROFILE_PROVISIONING_BACKEND="cloud-managed"
  FTCTL_PROFILE_SECONDARY_VM_NAME="${vm}-standby"
  ftctl_state_init_vm "${vm}"
  mkdir -p "${bundle}"

  cat > "${bundle}/standby.generated.xml" <<EOF
<domain type='kvm'>
  <name>${vm}-standby</name>
</domain>
EOF

  ftctl_state_set "${vm}" \
    "standby_xml_generated=${bundle}/standby.generated.xml" \
    "primary_persistence=no"

  # shellcheck disable=SC2317
  ftctl_standby_map_peer_krbd_paths() {
    return 0
  }
  # shellcheck disable=SC2317
  ftctl_virsh() {
    printf -v "$2" '%s' ""
    printf -v "$3" '%s' "error: operation failed: domain '${vm}-standby' already exists with uuid 00000000-0000-0000-0000-000000000001"
    printf -v "$4" '%s' "1"
  }

  ftctl_standby_activate "${vm}"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "standby_state")" "running" "already existing standby activate"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "active_side")" "secondary" "already existing standby side"
)

selftest_case_backend_validation() {
  selftest_reset_env
  selftest_info "backend mode validation"

  local vm="backend-vm"
  ftctl_profile_reset
  FTCTL_PROFILE_MODE="ha"
  FTCTL_PROFILE_PRIMARY_URI="qemu:///system"
  FTCTL_PROFILE_SECONDARY_URI="qemu+ssh://peer/system"
  FTCTL_PROFILE_BACKEND_MODE="shared-blockcopy"
  FTCTL_PROFILE_TARGET_STORAGE_SCOPE="shared"
  FTCTL_PROFILE_SECONDARY_VM_NAME="${vm}-standby"
  FTCTL_PROFILE_DOMAIN_PERSISTENCE="yes"
  FTCTL_PROFILE_DISK_MAP="auto"

  if ftctl_profile_validate "${vm}" && ftctl_blockcopy_validate_backend_mode "${vm}"; then
    selftest_fail "shared-blockcopy should reject disk_map=auto"
  fi

  ftctl_profile_reset
  FTCTL_PROFILE_MODE="ha"
  FTCTL_PROFILE_PRIMARY_URI="qemu:///system"
  FTCTL_PROFILE_SECONDARY_URI="qemu+ssh://peer/system"
  FTCTL_PROFILE_BACKEND_MODE="shared-blockcopy"
  FTCTL_PROFILE_TARGET_STORAGE_SCOPE="secondary-local"
  FTCTL_PROFILE_SECONDARY_VM_NAME="${vm}-standby"
  FTCTL_PROFILE_DOMAIN_PERSISTENCE="yes"
  FTCTL_PROFILE_DISK_MAP="vda=/secondary/${vm}.qcow2"

  if ftctl_profile_validate "${vm}"; then
    selftest_fail "shared-blockcopy should reject secondary-local target storage scope"
  fi

  ftctl_profile_reset
  FTCTL_PROFILE_MODE="ha"
  FTCTL_PROFILE_PRIMARY_URI="qemu:///system"
  FTCTL_PROFILE_SECONDARY_URI="qemu+ssh://peer/system"
  FTCTL_PROFILE_BACKEND_MODE="remote-nbd"
  FTCTL_PROFILE_TARGET_STORAGE_SCOPE="secondary-local"
  FTCTL_PROFILE_SECONDARY_VM_NAME="${vm}-standby"
  FTCTL_PROFILE_SECONDARY_TARGET_DIR="/secondary"
  FTCTL_PROFILE_REMOTE_NBD_EXPORT_ADDR="10.0.0.12"
  FTCTL_PROFILE_REMOTE_NBD_EXPORT_PORT="10809"
  FTCTL_PROFILE_REMOTE_NBD_EXPORT_NAME="${vm}"
  FTCTL_PROFILE_DISK_MAP="auto"
  FTCTL_PROFILE_DOMAIN_PERSISTENCE="no"
  ftctl_profile_validate "${vm}"

  FTCTL_PROFILE_PROVISIONING_BACKEND="cloud-managed"
  if ftctl_profile_validate "${vm}" && ftctl_blockcopy_validate_backend_mode "${vm}"; then
    selftest_fail "cloud-managed remote-nbd should reject disk_map=auto"
  fi

  FTCTL_PROFILE_DISK_MAP="vda=relative-target.qcow2"
  ftctl_profile_validate "${vm}"
  ftctl_inventory_collect_vm_disks() {
    local out_array_name="${2}"
    local -n _out_array="${out_array_name}"
    _out_array=("vda|/var/lib/libvirt/images/${vm}.qcow2|qcow2")
  }
  if ftctl_blockcopy_validate_backend_mode "${vm}"; then
    selftest_fail "cloud-managed remote-nbd should reject relative disk map paths"
  fi

  FTCTL_PROFILE_DISK_MAP="vdb=/secondary/${vm}.qcow2"
  if ftctl_blockcopy_validate_backend_mode "${vm}"; then
    selftest_fail "cloud-managed remote-nbd should reject missing target mappings"
  fi

  FTCTL_PROFILE_DISK_MAP="vda=/secondary/${vm}.qcow2"
  ftctl_blockcopy_validate_backend_mode "${vm}"

  # Restore the real inventory function after the focused backend validation stub.
  # shellcheck source=/dev/null
  source "${LIB_BASE}/ftctl/inventory.sh"
  FTCTL_PROFILE_PROVISIONING_BACKEND="libvirt-managed"
  FTCTL_PROFILE_DISK_MAP="auto"

  mkdir -p "${SELFTEST_ROOT}/xml/${vm}"
  cat > "${SELFTEST_ROOT}/xml/${vm}/standby.xml" <<EOF
<domain type='kvm'>
  <name>${vm}</name>
  <devices>
    <disk type='file' device='disk'>
      <source file='/var/lib/libvirt/images/${vm}.qcow2'/>
      <target dev='vda' bus='virtio'/>
    </disk>
  </devices>
</domain>
EOF
  ftctl_state_init_vm "${vm}"
  ftctl_state_set "${vm}" \
    "standby_xml_seed=${SELFTEST_ROOT}/xml/${vm}/standby.xml" \
    "primary_persistence=no"
  cat > "$(ftctl_blockcopy_state_path "${vm}")" <<EOF
vda|/var/lib/libvirt/images/${vm}.qcow2|nbd://10.0.0.12:10809/${vm}-vda|qcow2|running|yes|/secondary/${vm}/vda-${vm}.qcow2
EOF
  ftctl_standby_prepare "${vm}"
  selftest_assert_file_contains "$(ftctl_state_get "${vm}" "standby_xml_generated")" "/secondary/${vm}/vda-${vm}.qcow2"

  FTCTL_REMOTE_NBD_PORT_BASE="10809"
  FTCTL_REMOTE_NBD_PORT_COUNT="32"
  FTCTL_REMOTE_NBD_MAX_CONCURRENT="32"
  local chosen_port=""
  ftctl_blockcopy_remote_target_host_user() { printf -v "$1" '%s' '10.0.0.12'; printf -v "$2" '%s' 'root'; }
  ftctl_blockcopy_remote_nbd_active_count() { printf -v "$3" '%s' '0'; }
  ftctl_blockcopy_remote_nbd_port_in_use() { return 1; }
  ftctl_blockcopy_remote_nbd_pick_port "${vm}" "vda" chosen_port
  [[ "${chosen_port}" =~ ^[0-9]+$ ]] || selftest_fail "remote-nbd port not assigned"
  (( chosen_port >= FTCTL_REMOTE_NBD_PORT_BASE && chosen_port < FTCTL_REMOTE_NBD_PORT_BASE + FTCTL_REMOTE_NBD_PORT_COUNT )) || \
    selftest_fail "remote-nbd port out of range"
}

selftest_case_blockcopy_missing_job_state() (
  selftest_reset_env
  selftest_info "blockcopy missing job state"

  local vm="missing-job-vm"
  FTCTL_PROFILE_MODE="ha"
  FTCTL_PROFILE_PRIMARY_URI="qemu:///system"
  FTCTL_PROFILE_SECONDARY_URI="qemu+ssh://peer/system"
  FTCTL_PROFILE_BACKEND_MODE="shared-blockcopy"
  FTCTL_PROFILE_TARGET_STORAGE_SCOPE="shared"
  FTCTL_PROFILE_DISK_MAP="vda=/dev/rbd/rbd/${vm}-mirror"
  ftctl_state_init_vm "${vm}"
  ftctl_state_set "${vm}" \
    "protection_state=protected" \
    "transport_state=mirroring" \
    "active_side=primary" \
    "last_error="
  cat > "$(ftctl_blockcopy_state_path "${vm}")" <<EOF
vda|/dev/rbd/rbd/${vm}-source|/dev/rbd/rbd/${vm}-mirror|raw|copy|no
EOF

  # shellcheck disable=SC2317
  ftctl_inventory_collect_vm_disks() {
    local -n _out_array="$2"
    _out_array=("vda|/dev/rbd/rbd/${vm}-source|raw")
  }
  # shellcheck disable=SC2317
  ftctl_blockcopy_job_query() {
    printf -v "$3" '%s' "unknown"
    printf -v "$4" '%s' "unknown"
    return 4
  }
  # shellcheck disable=SC2317
  ftctl_blockcopy_runtime_mirror_query() {
    printf -v "$3" '%s' "none"
    printf -v "$4" '%s' "unknown"
    return 1
  }

  if ftctl_blockcopy_refresh_vm_jobs "${vm}"; then
    selftest_fail "missing blockjob should fail refresh"
  fi
  selftest_assert_eq "$(ftctl_state_get "${vm}" "protection_state")" "error" "missing blockjob protection state"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "transport_state")" "failed" "missing blockjob transport state"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "last_error")" "blockcopy_job_missing:vda" "missing blockjob last_error"
)

selftest_case_blockcopy_progress_status() (
  selftest_reset_env
  selftest_info "blockcopy progress status"

  local vm="progress-vm"
  FTCTL_PROFILE_MODE="ha"
  FTCTL_PROFILE_PRIMARY_URI="qemu:///system"
  ftctl_state_init_vm "${vm}"
  ftctl_state_set "${vm}" "transport_state=copying"
  ftctl_blockcopy_state_write "${vm}" \
    "vda|/dev/source-vda|nbd://10.0.0.12:10827/progress-vm-vda|qcow2|running|no|/secondary/progress-vm/vda.qcow2" \
    "vdb|/dev/source-vdb|/shared/progress-vm/vdb.raw|raw|ready|yes|"

  # shellcheck disable=SC2317
  ftctl_virsh() {
    local out_var="${2}"
    local err_var="${3}"
    local rc_var="${4}"
    printf -v "${out_var}" '%s' '{"return":[{"device":"copy-vda-libvirt-1-storage","offset":5368709120,"len":10737418240,"ready":false,"status":"running","paused":false,"io-status":"ok"},{"device":"copy-vdb-libvirt-2-storage","offset":10737418240,"len":10737418240,"ready":true,"status":"running","paused":false,"io-status":"ok"}]}'
    printf -v "${err_var}" '%s' ""
    printf -v "${rc_var}" '%s' "0"
  }

  ftctl_blockcopy_progress_refresh_from_qmp "${vm}" "${vm}" "${FTCTL_PROFILE_PRIMARY_URI}" "forward" "mirror" "blockcopy.progress"
  selftest_assert_file_contains "$(ftctl_blockcopy_progress_path "${vm}")" '"percent":75.0'
  selftest_assert_file_contains "$(ftctl_blockcopy_progress_path "${vm}")" '"target":"vda"'
  selftest_assert_file_contains "$(ftctl_blockcopy_progress_path "${vm}")" '"nbd_port":10827'
  selftest_assert_file_contains "$(ftctl_blockcopy_progress_path "${vm}")" '"nbd_endpoint":"10.0.0.12:10827/progress-vm-vda"'
  selftest_assert_file_contains "${FTCTL_EVENTS_LOG}" '"event":"blockcopy.progress"'

  local out=""
  out="$(ftctl_state_print_one "${vm}" "1")"
  selftest_assert_contains "${out}" '"sync_progress"' "status includes sync progress"
  selftest_assert_contains "${out}" '"copied_bytes":16106127360' "status includes copied bytes"
)

selftest_case_reconcile_and_fencing() {
  selftest_reset_env
  selftest_info "reconcile/fencing state machine"

  local vm="vm1"
  FTCTL_PROFILE_MODE="ha"
  FTCTL_PROFILE_PRIMARY_URI="qemu:///system"
  FTCTL_PROFILE_SECONDARY_URI="qemu+ssh://peer/system"
  FTCTL_PROFILE_FENCING_POLICY="manual-block"
  FTCTL_PROFILE_FENCING_SSH_USER="root"

  cat > "${SELFTEST_ROOT}/cluster.conf" <<EOF
FTCTL_CLUSTER_NAME="demo"
FTCTL_LOCAL_HOST_ID="host-01"
EOF
  cat > "${SELFTEST_ROOT}/cluster.d/hosts/host-02.conf" <<EOF
FTCTL_HOST_ID="host-02"
FTCTL_HOST_ROLE="secondary"
FTCTL_HOST_MANAGEMENT_IP="10.0.0.12"
FTCTL_HOST_LIBVIRT_URI="qemu+ssh://peer/system"
FTCTL_HOST_BLOCKCOPY_REPLICATION_IP="172.16.10.12"
FTCTL_HOST_XCOLO_CONTROL_IP="172.16.20.12"
FTCTL_HOST_XCOLO_DATA_IP="172.16.30.12"
EOF

  ftctl_state_init_vm "${vm}"
  ftctl_state_set "${vm}" "mode=ha" "transport_state=lost" "protection_state=degraded"

  ftctl_blockcopy_refresh_and_classify() { return 12; }
  ftctl_profile_load_vm() { :; }
  ftctl_profile_apply_cli() { :; }
  ftctl_profile_validate() { :; }
  ftctl_orchestrator_probe_peer() { printf -v "$1" '%s' 'host-02'; printf -v "$2" '%s' '10.0.0.12'; printf -v "$3" '%s' 'reachable'; }
  ftctl_blockcopy_rearm() { ftctl_state_set "$1" "protection_state=rearming" "transport_state=rearm_pending" "last_rearm_ts=$(ftctl_now_iso8601)"; }

  ftctl_orchestrator_reconcile_one "${vm}"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "transport_state")" "transient_loss" "reconcile grace window"

  ftctl_state_set "${vm}" \
    "transport_state=lost" \
    "transport_loss_since=$(date -d '10 seconds ago' '+%Y-%m-%dT%H:%M:%S%:z')"
  ftctl_orchestrator_reconcile_one "${vm}"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "transport_state")" "rearm_pending" "reconcile rearm"

  FTCTL_PROFILE_FENCING_POLICY="manual-block"
  ftctl_state_set "${vm}" "protection_state=protected" "transport_state=mirroring"
  ftctl_failover_request "${vm}" "manual" || true
  selftest_assert_eq "$(ftctl_state_get "${vm}" "fencing_state")" "required" "manual fencing required"
  ftctl_fencing_manual_confirm "${vm}"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "fencing_state")" "manual-fenced" "manual fencing confirm"

  ftctl_state_set "${vm}" \
    "standby_xml_generated=${SELFTEST_ROOT}/standby.generated.xml" \
    "primary_persistence=no"
  ftctl_failover_request "${vm}" "manual-confirmed"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "fencing_state")" "manual-fenced" "manual fencing retained"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "standby_state")" "start-dry-run" "manual fencing starts standby"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "active_side")" "secondary" "manual fencing active side"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "protection_state")" "failed_over" "manual fencing failover complete"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "transport_state")" "failed_over" "manual fencing transport complete"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "last_error")" "" "manual fencing clears last_error"
}

selftest_case_failover_blocks_copying_transport() (
  selftest_reset_env
  selftest_info "failover blocks non-ready blockcopy"

  local vm="copying-failover"
  ftctl_state_init_vm "${vm}"
  ftctl_state_set "${vm}" \
    "mode=ha" \
    "protection_state=syncing" \
    "transport_state=copying" \
    "fencing_state=clear"
  FTCTL_PROFILE_BACKEND_MODE="shared-blockcopy"
  FTCTL_PROFILE_FENCING_POLICY="manual-block"
  FTCTL_FAILOVER_SYNC_READY_TIMEOUT_SEC="1"
  # shellcheck disable=SC2317
  ftctl_blockcopy_wait_forward_sync_ready() { return 1; }

  if ftctl_failover_request "${vm}" "manual"; then
    selftest_fail "copying transport should block initial failover"
  fi
  selftest_assert_eq "$(ftctl_state_get "${vm}" "fencing_state")" "clear" "copying failover keeps fencing clear"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "protection_state")" "syncing" "copying failover keeps syncing"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "last_error")" "blockcopy_not_ready_for_failover" "copying failover last_error"

  ftctl_fencing_manual_confirm "${vm}"
  ftctl_state_set "${vm}" \
    "protection_state=failing_over" \
    "transport_state=copying" \
    "standby_xml_generated=${SELFTEST_ROOT}/standby.generated.xml" \
    "primary_persistence=no"

  if ftctl_failover_request "${vm}" "manual-confirmed"; then
    selftest_fail "copying transport should block fenced failover continuation"
  fi
  selftest_assert_eq "$(ftctl_state_get "${vm}" "protection_state")" "error" "fenced copying continuation errors"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "last_error")" "blockcopy_not_ready_for_failover" "fenced copying continuation last_error"
)

selftest_case_xcolo_and_xml() {
  selftest_reset_env
  selftest_info "x-colo dry-run and XML commandline"

  local vm="ftvm"
  local bundle="${SELFTEST_ROOT}/xml/${vm}"
  mkdir -p "${bundle}"
  cat > "${bundle}/primary.xml" <<EOF
<domain type='kvm'>
  <name>${vm}</name>
  <devices>
    <disk type='file' device='disk'>
      <source file='/var/lib/libvirt/images/${vm}.qcow2'/>
      <target dev='vda' bus='virtio'/>
    </disk>
  </devices>
</domain>
EOF
  cp "${bundle}/primary.xml" "${bundle}/standby.xml"
  cat > "$(ftctl_state_path "${vm}")" <<EOF
vm=${vm}
primary_xml_backup=${bundle}/primary.xml
standby_xml_seed=${bundle}/standby.xml
primary_persistence=yes
EOF
  cat > "$(ftctl_blockcopy_state_path "${vm}")" <<EOF
vda|/var/lib/libvirt/images/${vm}.qcow2|/mirror/${vm}-vda.qcow2|qcow2|running|yes
EOF

  ftctl_profile_reset
  FTCTL_PROFILE_MODE="ft"
  FTCTL_PROFILE_PRIMARY_URI="qemu:///system"
  FTCTL_PROFILE_SECONDARY_URI="qemu+ssh://peer/system"
  FTCTL_PROFILE_XCOLO_PROXY_ENDPOINT="tcp:10.10.10.21:9000"
  FTCTL_PROFILE_XCOLO_NBD_ENDPOINT="tcp:10.10.20.21:9999"
  FTCTL_PROFILE_XCOLO_MIGRATE_URI="tcp:10.10.20.21:9998"
  FTCTL_PROFILE_XCOLO_PRIMARY_DISK_NODE="parent0"
  FTCTL_PROFILE_XCOLO_PARENT_BLOCK_NODE="colo-disk0"
  FTCTL_PROFILE_XCOLO_NBD_NODE="nbd0"
  FTCTL_PROFILE_XCOLO_CHECKPOINT_DELAY="2000"
  FTCTL_PROFILE_XCOLO_QEMU_ARGS_PRIMARY="-incoming;defer"
  FTCTL_PROFILE_XCOLO_QEMU_ARGS_SECONDARY="-S;-msg;timestamp=on"
  FTCTL_PROFILE_FENCING_SSH_USER="root"
  ftctl_profile_validate "${vm}"
  ftctl_state_set "${vm}" "mode=ft" "active_side=primary"

  ftctl_xcolo_plan_protect "${vm}"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "protection_state")" "colo_running" "xcolo protect"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "transport_state")" "mirroring" "xcolo transport"
  selftest_assert_file_contains "$(ftctl_state_get "${vm}" "primary_xml_generated")" "qemu:commandline"
  selftest_assert_file_contains "$(ftctl_state_get "${vm}" "standby_xml_generated")" "qemu:commandline"
  selftest_assert_file_contains "$(ftctl_state_get "${vm}" "standby_xml_generated")" "/mirror/${vm}-vda.qcow2"

  ftctl_xcolo_failover "${vm}"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "active_side")" "secondary" "xcolo failover side"
}

selftest_case_json_and_locking() {
  selftest_reset_env
  selftest_info "json output and lock behavior"

  local vm="json-vm"
  local fakebin="${SELFTEST_ROOT}/bin"
  local out="" rc=0

  mkdir -p "${fakebin}" "${SELFTEST_ROOT}/profiles"
  cat > "${fakebin}/virsh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$*" == *" list --name"* ]]; then
  exit 0
fi
if [[ "$*" == *" dominfo json-vm"* ]]; then
  if [[ "$*" == *"qemu:///system"* ]]; then
    printf 'Id: 1\nName: json-vm\n'
    exit 0
  fi
  printf 'Domain not found\n' >&2
  exit 1
fi
if [[ "$*" == *"qemu+ssh://peer/system"* && "$*" == *" domstate json-vm-standby"* ]]; then
  printf 'Domain not found\n' >&2
  exit 1
fi
if [[ "$*" == *"qemu+ssh://peer/system"* && "$*" == *" dominfo json-vm-standby"* ]]; then
  printf 'Domain not found\n' >&2
  exit 1
fi
printf 'unsupported test virsh invocation: %s\n' "$*" >&2
exit 2
EOF
  chmod 0755 "${fakebin}/virsh"

  cat > "${SELFTEST_ROOT}/profiles/${vm}.conf" <<EOF
FTCTL_PROFILE_MODE="ha"
FTCTL_PROFILE_SECONDARY_URI="qemu+ssh://peer/system"
EOF

  FTCTL_PROFILE_MODE="ha"
  FTCTL_PROFILE_PRIMARY_URI="qemu:///system"
  FTCTL_PROFILE_SECONDARY_URI="qemu+ssh://peer/system"
  ftctl_state_init_vm "${vm}"

  out="$(PATH="${fakebin}:$PATH" bash "${ROOT_DIR}/bin/ablestack_vm_ftctl.sh" status --config "${SELFTEST_CONFIG}" --vm "${vm}" --json)"
  selftest_assert_contains "${out}" '"command":"status"' "status json command"
  selftest_assert_contains "${out}" '"result":"ok"' "status json result"
  selftest_assert_contains "${out}" "\"vm\":\"${vm}\"" "status json vm"

  out="$(PATH="${fakebin}:$PATH" bash "${ROOT_DIR}/bin/ablestack_vm_ftctl.sh" check --config "${SELFTEST_CONFIG}" --vm "${vm}" --json)"
  selftest_assert_contains "${out}" '"command":"check"' "check json command"
  selftest_assert_contains "${out}" '"result":"ok"' "check json result"
  selftest_assert_contains "${out}" '"inventory_result":"warn"' "check json inventory result"
  selftest_assert_contains "${out}" '"primary_rc":0' "check primary rc"
  selftest_assert_contains "${out}" '"peer_rc":1' "check peer rc"

  out="$(PATH="${fakebin}:$PATH" bash "${ROOT_DIR}/bin/ablestack_vm_ftctl.sh" health --config "${SELFTEST_CONFIG}" --json)"
  selftest_assert_contains "${out}" '"command":"health"' "health json command"
  selftest_assert_contains "${out}" '"result":"ok"' "health json result"
  selftest_assert_contains "${out}" '"rc":0' "health rc"

  exec 209>"${FTCTL_LOCK_FILE}"
  flock -n 209 || selftest_fail "unable to hold test lock"

  set +e
  out="$(bash "${ROOT_DIR}/bin/ablestack_vm_ftctl.sh" config init-cluster --config "${SELFTEST_CONFIG}" --cluster-name demo --local-host-id host-01 --json)"
  rc=$?
  set -e
  selftest_assert_eq "${rc}" "20" "lock conflict exit code"
  selftest_assert_contains "${out}" '"result":"locked"' "lock conflict json result"

  out="$(PATH="${fakebin}:$PATH" bash "${ROOT_DIR}/bin/ablestack_vm_ftctl.sh" status --config "${SELFTEST_CONFIG}" --vm "${vm}" --json)"
  selftest_assert_contains "${out}" '"result":"ok"' "read-only status should ignore lock"

  exec 209>&-
}

selftest_case_check_secondary_active_side() {
  selftest_reset_env
  selftest_info "check accepts cloud-managed secondary runtime domain"

  local vm="failover-vm"
  local secondary_vm="i-2-309-VM"
  local fakebin="${SELFTEST_ROOT}/bin"
  local out=""

  mkdir -p "${fakebin}" "${SELFTEST_ROOT}/profiles"
  cat > "${fakebin}/virsh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$*" == *" list --name"* ]]; then
  exit 0
fi
if [[ "$*" == *"qemu:///system"* && "$*" == *" dominfo failover-vm"* ]]; then
  printf 'Domain not found\n' >&2
  exit 1
fi
if [[ "$*" == *"qemu+ssh://peer/system"* && "$*" == *" domstate i-2-309-VM"* ]]; then
  printf 'running\n'
  exit 0
fi
printf 'unsupported test virsh invocation: %s\n' "$*" >&2
exit 2
EOF
  chmod 0755 "${fakebin}/virsh"

  cat > "${SELFTEST_ROOT}/profiles/${vm}.conf" <<EOF
FTCTL_PROFILE_MODE="ha"
FTCTL_PROFILE_PRIMARY_URI="qemu:///system"
FTCTL_PROFILE_SECONDARY_URI="qemu+ssh://peer/system"
FTCTL_PROFILE_SECONDARY_VM_NAME="${secondary_vm}"
FTCTL_PROFILE_PROVISIONING_BACKEND="cloud-managed"
EOF

  out="$(PATH="${fakebin}:$PATH" bash "${ROOT_DIR}/bin/ablestack_vm_ftctl.sh" check --config "${SELFTEST_CONFIG}" --vm "${vm}" --secondary-vm-name "${secondary_vm}" --active-side secondary --provisioning-backend cloud-managed --json)"
  selftest_assert_contains "${out}" '"command":"check"' "secondary check json command"
  selftest_assert_contains "${out}" '"inventory_result":"ok"' "secondary check inventory result"
  selftest_assert_contains "${out}" '"primary_rc":1' "secondary check primary rc"
  selftest_assert_contains "${out}" '"peer_rc":0' "secondary check peer rc"
  selftest_assert_contains "${out}" '"peer_domain_expected":true' "secondary check peer expected"
  selftest_assert_contains "${out}" '"standby_domain_state":"running"' "secondary check standby running"
  selftest_assert_contains "${out}" '"provisioning_backend":"cloud-managed"' "secondary check provisioning backend"
}

selftest_case_reconcile_secondary_steady_skips_primary_disks() (
  selftest_reset_env
  selftest_info "reconcile skips primary disk inventory after cloud-managed failover"

  local vm="steady-failover-vm"
  local call_log="${SELFTEST_ROOT}/steady-failover-calls.log"

  FTCTL_PROFILE_MODE="ha"
  FTCTL_PROFILE_PROVISIONING_BACKEND="cloud-managed"
  ftctl_state_init_vm "${vm}"
  ftctl_state_set "${vm}" \
    "mode=ha" \
    "active_side=secondary" \
    "fencing_state=manual-fenced" \
    "protection_state=failed_over" \
    "transport_state=failed_over" \
    "standby_state=running"

  # shellcheck disable=SC2317
  ftctl_profile_load_vm() { :; }
  # shellcheck disable=SC2317
  ftctl_profile_apply_cli() { :; }
  # shellcheck disable=SC2317
  ftctl_profile_validate() { :; }
  # shellcheck disable=SC2317
  ftctl_cluster_load() { :; }
  # shellcheck disable=SC2317
  ftctl_orchestrator_probe_peer() { printf -v "$1" '%s' 'host-02'; printf -v "$2" '%s' '10.0.0.12'; printf -v "$3" '%s' 'reachable'; }
  # shellcheck disable=SC2317
  ftctl_inventory_check_vm() { printf '1 0 ok true running\n'; }
  # shellcheck disable=SC2317
  ftctl_blockcopy_refresh_and_classify() {
    printf 'blockcopy-refresh-called\n' >> "${call_log}"
    return 12
  }

  ftctl_orchestrator_reconcile_one "${vm}"

  [[ ! -f "${call_log}" ]] || selftest_fail "blockcopy refresh should not run after steady failover"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "protection_state")" "failed_over" "steady failover protection state"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "transport_state")" "failed_over" "steady failover transport state"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "last_error")" "" "steady failover clears last_error"
  selftest_assert_file_contains "${FTCTL_EVENTS_LOG}" '"event":"failover.steady"'
  selftest_assert_file_not_contains "${FTCTL_EVENTS_LOG}" 'inventory.disks'
)

selftest_case_unprotect_releases_blockcopy_targets() (
  selftest_reset_env
  selftest_info "unprotect releases blockcopy targets"

  local vm="unprotect-release"
  local call_log="${SELFTEST_ROOT}/unprotect-release-calls.log"
  local job_queries=0
  local node_queries=0
  FTCTL_UNPROTECT_RELEASE_TIMEOUT_SEC="5"
  FTCTL_BLOCKCOPY_WAIT_TIMEOUT_SEC="1"
  ftctl_state_init_vm "${vm}"
  cat > "$(ftctl_blockcopy_state_path "${vm}")" <<EOF
vdb|/dev/rbd/rbd/${vm}-source|/dev/rbd/rbd/${vm}-mirror|raw|copy|yes
EOF

  # shellcheck disable=SC2317
  ftctl_virsh() {
    local out_var="${2}"
    local err_var="${3}"
    local rc_var="${4}"
    local cmd="$*"
    printf '%s\n' "${cmd}" >> "${call_log}"
    printf -v "${err_var}" '%s' ""
    printf -v "${rc_var}" '%s' "0"
    if [[ "${cmd}" == *"query-block-jobs"* ]]; then
      job_queries=$((job_queries + 1))
      if (( job_queries == 1 )); then
        printf -v "${out_var}" '%s' '{"return":[{"device":"vdb"}]}'
      else
        printf -v "${out_var}" '%s' '{"return":[]}'
      fi
      return 0
    fi
    if [[ "${cmd}" == *"query-named-block-nodes"* ]]; then
      node_queries=$((node_queries + 1))
      if (( node_queries == 1 )); then
        printf -v "${out_var}" '%s' '{"return":[{"file":"/dev/rbd/rbd/unprotect-release-mirror"}]}'
      else
        printf -v "${out_var}" '%s' '{"return":[]}'
      fi
      return 0
    fi
    printf -v "${out_var}" '%s' '{"return":{}}'
  }

  local out=""
  out="$(ftctl_state_unprotect_vm "${vm}" 1)"
  selftest_assert_contains "${out}" '"result":"ok"' "unprotect result"
  selftest_assert_contains "${out}" '"block_jobs_cancelled":1' "unprotect cancels job"
  [[ ! -f "$(ftctl_blockcopy_state_path "${vm}")" ]] || selftest_fail "blockcopy state should be removed after release"
  selftest_assert_file_contains "${call_log}" "block-job-cancel"
  selftest_assert_file_contains "${call_log}" "query-named-block-nodes"
  selftest_assert_file_contains "${FTCTL_EVENTS_LOG}" "protection.unprotect.block-jobs-released"
  selftest_assert_file_contains "${FTCTL_EVENTS_LOG}" "protection.unprotect.qmp-destinations-released"
)

selftest_case_events_json() {
  selftest_reset_env
  selftest_info "events json output"

  cat > "${SELFTEST_ROOT}/log/events.log" <<EOF
{"ts":"2026-04-18T10:00:00+09:00","scan_id":"s1","vm":"vm-a","stage":"health","event":"reconcile.tick","result":"ok"}
{"ts":"2026-04-18T10:01:00+09:00","scan_id":"s2","vm":"vm-b","stage":"failover","event":"failover.request","result":"warn"}
{"ts":"2026-04-18T10:02:00+09:00","scan_id":"s3","vm":"vm-a","stage":"rearm","event":"rearm.defer","result":"warn","details":{"reason":"backoff"}}
EOF

  local out=""
  out="$(bash "${ROOT_DIR}/bin/ablestack_vm_ftctl.sh" events --config "${SELFTEST_CONFIG}" --vm vm-a --limit 2 --json)"
  selftest_assert_contains "${out}" '"command":"events"' "events json command"
  selftest_assert_contains "${out}" '"result":"ok"' "events json result"
  selftest_assert_contains "${out}" '"count":2' "events count"
  selftest_assert_contains "${out}" '"event":"rearm.defer"' "events latest item"
}

selftest_main() {
  selftest_run_lint
  selftest_case_cluster_cli
  selftest_case_blockcopy_and_standby
  selftest_case_libvirt_managed_peer_krbd_map
  selftest_case_standby_activate_already_exists
  selftest_case_backend_validation
  selftest_case_blockcopy_missing_job_state
  selftest_case_blockcopy_progress_status
  selftest_case_reconcile_and_fencing
  selftest_case_failover_blocks_copying_transport
  selftest_case_xcolo_and_xml
  selftest_case_json_and_locking
  selftest_case_check_secondary_active_side
  selftest_case_reconcile_secondary_steady_skips_primary_disks
  selftest_case_unprotect_releases_blockcopy_targets
  selftest_case_events_json
  selftest_info "all checks passed"
}

selftest_main "$@"
