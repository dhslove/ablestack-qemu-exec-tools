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
source "${LIB_BASE}/ftctl/dr_key.sh"
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

selftest_assert_not_contains() {
  local haystack="${1-}"
  local needle="${2-}"
  local msg="${3-assert_not_contains failed}"
  [[ "${haystack}" != *"${needle}"* ]] || selftest_fail "${msg}: unexpected '${needle}'"
}

selftest_mock_xcolo_primary_channels_ready() {
  # shellcheck disable=SC2317
  ftctl_xcolo_capture_primary_channel_state() {
    local vm="${1-}"
    ftctl_state_set "${vm}" \
      "xcolo_channel_mirror_established=yes" \
      "xcolo_channel_compare_established=yes" \
      "xcolo_channel_compare_local_established=yes" \
      "xcolo_channel_compare_out_established=yes" \
      "xcolo_channel_mirror_listen=yes" \
      "xcolo_channel_compare_listen=yes" \
      "xcolo_channel_compare_local_listen=yes" \
      "xcolo_channel_compare_out_listen=yes"
  }
  # shellcheck disable=SC2317
  ftctl_xcolo_validate_primary_channel_paths() {
    ftctl_xcolo_capture_primary_channel_state "$1"
  }
  # shellcheck disable=SC2317
  ftctl_xcolo_wait_primary_filter_chardev_binding() {
    local vm="${1-}"
    ftctl_state_set "${vm}" \
      "xcolo_primary_filter_chardev_ready=yes" \
      "xcolo_primary_filter_chardev_reason="
  }
}

selftest_mock_xcolo_primary_role_diagnostics_ok() {
  # shellcheck disable=SC2317
  ftctl_xcolo_collect_runtime_failure_diagnostics() {
    local vm="${1-}"
    ftctl_state_set "${vm}" \
      "xcolo_debug_dir=${FTCTL_RUN_DIR}/debug/xcolo/$(ftctl_state_vm_key "${vm}")" \
      "xcolo_primary_capability_x_colo=yes" \
      "xcolo_primary_capability_return_path=yes" \
      "xcolo_primary_checkpoint_delay_set=yes"
  }
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

selftest_case_dr_remote_key_connectivity_args() (
  selftest_reset_env
  selftest_info "DR remote key connectivity arguments"

  local vm="i-2-381-VM"
  local uri keyed_uri identity_args existing_key_uri encoded_key_path
  FTCTL_DR_KEY_ROOT="${SELFTEST_ROOT}/ssh/ftctl-dr"
  CLI_VM="${vm}"
  FTCTL_PROFILE_MODE="dr"
  ftctl_dr_key_ensure "${vm}" >/dev/null
  encoded_key_path="$(ftctl_dr_key_uri_query_escape "${FTCTL_DR_KEY_ROOT}/${vm}/id_ed25519")"

  uri="qemu+ssh://root@10.0.0.12:22/system"
  keyed_uri="$(ftctl_dr_key_uri_with_keyfile "${uri}" "${vm}")"
  selftest_assert_eq "${keyed_uri}" "${uri}?no_verify=1&keyfile=${encoded_key_path}" "DR qemu+ssh keyfile URI"

  keyed_uri="$(ftctl_dr_key_uri_with_keyfile "${uri}?no_verify=1" "${vm}")"
  selftest_assert_eq "${keyed_uri}" "${uri}?no_verify=1&keyfile=${encoded_key_path}" "DR qemu+ssh keyfile URI with existing no_verify"

  keyed_uri="$(ftctl_dr_key_uri_with_keyfile "${uri}?transport=ssh" "${vm}")"
  selftest_assert_eq "${keyed_uri}" "${uri}?transport=ssh&no_verify=1&keyfile=${encoded_key_path}" "DR qemu+ssh keyfile URI with existing query"

  existing_key_uri="${uri}?keyfile=/root/.ssh/custom"
  keyed_uri="$(ftctl_dr_key_uri_with_keyfile "${existing_key_uri}" "${vm}")"
  selftest_assert_eq "${keyed_uri}" "${existing_key_uri}&no_verify=1" "existing qemu+ssh keyfile is preserved"

  ftctl_blockcopy_dr_ssh_identity_args identity_args "${vm}"
  selftest_assert_contains "${identity_args}" "-i ${FTCTL_DR_KEY_ROOT}/${vm}/id_ed25519" "DR ssh identity key"
  selftest_assert_contains "${identity_args}" "-o IdentitiesOnly=yes" "DR ssh identities only"

  FTCTL_PROFILE_SECONDARY_URI="${uri}"
  FTCTL_PROFILE_SECONDARY_SSH_KEY_FILE=""
  ftctl_profile_materialize_dr_ssh_keyfile "${vm}"
  selftest_assert_eq "${FTCTL_PROFILE_SECONDARY_SSH_KEY_FILE}" "${FTCTL_DR_KEY_ROOT}/${vm}/id_ed25519" "DR profile keyfile materialized"
  selftest_assert_contains "${FTCTL_PROFILE_SECONDARY_URI}" "no_verify=1" "DR profile URI no_verify materialized"
  selftest_assert_contains "${FTCTL_PROFILE_SECONDARY_URI}" "keyfile=${encoded_key_path}" "DR profile URI keyfile materialized"
)

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

selftest_case_shared_xml_reuse_external() (
  selftest_reset_env
  selftest_info "shared XML blockcopy uses reuse-external for existing targets"

  local xml_path="${SELFTEST_ROOT}/shared.xml"
  local args_file="${SELFTEST_ROOT}/virsh.args"
  local out="" err="" rc=0

  cat > "${xml_path}" <<EOF
<disk type='block' device='disk'>
  <driver name='qemu' type='raw'/>
  <source dev='/dev/rbd/rbd/dst'/>
  <target dev='vda' bus='scsi'/>
</disk>
EOF

  # shellcheck disable=SC2317
  ftctl_virsh() {
    local out_var="${2}"
    local err_var="${3}"
    local rc_var="${4}"
    shift 5
    printf '%s\n' "$*" > "${args_file}"
    printf -v "${out_var}" '%s' ""
    printf -v "${err_var}" '%s' ""
    printf -v "${rc_var}" '%s' "0"
  }

  ftctl_blockcopy_start_shared_xml_job "qemu:///system" "vm1" "vda" "unknown" "${xml_path}" out err rc "1"
  selftest_assert_eq "${rc}" "0" "shared xml blockcopy rc"
  selftest_assert_file_contains "${args_file}" "--reuse-external"
)

selftest_case_blockcopy_target_empty_verify() (
  selftest_reset_env
  selftest_info "blockcopy target materialization detects empty RBD target"

  local vm="verify-empty"
  ftctl_state_init_vm "${vm}"

  # shellcheck disable=SC2317
  ftctl_blockcopy_rbd_du_used_bytes_primary() {
    case "${1-}" in
      rbd/source) printf -v "$2" '%s' "4096" ;;
      rbd/dest) printf -v "$2" '%s' "0" ;;
      *) printf -v "$2" '%s' "" ; return 1 ;;
    esac
  }
  # shellcheck disable=SC2317
  ftctl_blockcopy_path_head_sha256_primary() {
    return 1
  }

  if ftctl_blockcopy_verify_target_materialized "${vm}" "vda" "/dev/rbd/rbd/source" "/dev/rbd/rbd/dest"; then
    selftest_fail "empty RBD target should fail materialization verification"
  fi
  selftest_assert_file_contains "${FTCTL_EVENTS_LOG}" "target_empty"
)

selftest_case_blockcopy_verify_blocks_mirroring() (
  selftest_reset_env
  selftest_info "blockcopy verify failure blocks protected/mirroring"

  local vm="verify-blocks"
  FTCTL_PROFILE_BACKEND_MODE="shared-blockcopy"
  FTCTL_PROFILE_PRIMARY_URI="qemu:///system"
  ftctl_state_init_vm "${vm}"

  # shellcheck disable=SC2317
  ftctl_inventory_collect_vm_disks() {
    local out_array_name="${2}"
    eval "${out_array_name}=(\"vda|/dev/rbd/rbd/source|raw\")"
  }
  # shellcheck disable=SC2317
  ftctl_blockcopy_resolve_dest() {
    printf '%s\n' "/dev/rbd/rbd/dest"
  }
  # shellcheck disable=SC2317
  ftctl_blockcopy_job_query() {
    printf -v "$3" '%s' "copy"
    printf -v "$4" '%s' "yes"
  }
  # shellcheck disable=SC2317
  ftctl_blockcopy_progress_refresh_from_qmp() {
    return 0
  }
  # shellcheck disable=SC2317
  ftctl_blockcopy_verify_target_materialized() {
    return 21
  }

  if ftctl_blockcopy_refresh_vm_jobs "${vm}"; then
    selftest_fail "verify failure should make refresh fail"
  fi
  selftest_assert_eq "$(ftctl_state_get "${vm}" "protection_state")" "error" "verify failure protection state"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "transport_state")" "failed" "verify failure transport state"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "last_error")" "blockcopy_target_not_materialized:vda" "verify failure last_error"
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

  ftctl_state_set "${vm}" "transport_state=mirroring" "last_error="
  ftctl_failover_precheck_blockcopy_ready "${vm}" "ha" "7" "before_fencing" "0"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "failover_ready")" "1" "ready precheck records failover marker"
  ftctl_state_set "${vm}" "transport_state=transient_loss"
  ftctl_failover_precheck_blockcopy_ready "${vm}" "ha" "7" "cloud_prepare" "0"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "last_error")" "" "marker permits cloud prepare after primary stop"

  ftctl_state_set "${vm}" "failover_ready=" "transport_state=copying"
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
  FTCTL_PROFILE_SECONDARY_VM_NAME="${vm}-standby"
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

  local primary_args secondary_args
  primary_args="$(ftctl_xcolo_build_primary_qemu_args)"
  secondary_args="$(ftctl_xcolo_build_secondary_qemu_args)"
  ftctl_xcolo_prepare_block_generated_xmls "${vm}" \
    "${bundle}/primary.xml" "${bundle}/standby.xml" \
    "/var/lib/libvirt/images/${vm}.qcow2" "/mirror/${vm}-vda.qcow2" \
    "qcow2" "${primary_args}" "${secondary_args}"
  ftctl_state_set "${vm}" "protection_state=colo_running" "transport_state=mirroring"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "protection_state")" "colo_running" "xcolo protect"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "transport_state")" "mirroring" "xcolo transport"
  selftest_assert_file_contains "$(ftctl_state_get "${vm}" "primary_xml_generated")" "qemu:commandline"
  selftest_assert_file_contains "$(ftctl_state_get "${vm}" "primary_xml_generated")" "<iothreads>1</iothreads>"
  selftest_assert_file_contains "$(ftctl_state_get "${vm}" "primary_xml_generated")" '<iothread id="1"'
  selftest_assert_file_not_contains "$(ftctl_state_get "${vm}" "primary_xml_generated")" "iothread,id=iothread1"
  selftest_assert_file_not_contains "$(ftctl_state_get "${vm}" "primary_xml_generated")" "filter-mirror"
  selftest_assert_file_not_contains "$(ftctl_state_get "${vm}" "primary_xml_generated")" "filter-redirector"
  selftest_assert_file_not_contains "$(ftctl_state_get "${vm}" "primary_xml_generated")" "colo-compare"
  selftest_assert_file_contains "$(ftctl_state_get "${vm}" "primary_xml_generated")" "socket,id=mirror0,host=0.0.0.0,port=9003,server=on,wait=off"
  selftest_assert_file_contains "$(ftctl_state_get "${vm}" "primary_xml_generated")" "socket,id=compare1,host=0.0.0.0,port=9004,server=on,wait=on"
  selftest_assert_file_not_contains "$(ftctl_state_get "${vm}" "primary_xml_generated")" "socket,id=mirror0,host=0.0.0.0,port=9003,server=on,wait=on"
  selftest_assert_file_not_contains "$(ftctl_state_get "${vm}" "primary_xml_generated")" "socket,id=compare1,host=0.0.0.0,port=9004,server=on,wait=off"
  selftest_assert_file_contains "$(ftctl_state_get "${vm}" "standby_xml_generated")" "qemu:commandline"
  selftest_assert_file_contains "$(ftctl_state_get "${vm}" "standby_xml_generated")" "/mirror/${vm}-vda.qcow2"

  ftctl_xcolo_failover "${vm}"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "active_side")" "secondary" "xcolo failover side"
}

selftest_case_xcolo_iothread_contract_validation() {
  selftest_reset_env
  selftest_info "x-colo iothread contract validation"

  local vm="ft-iothread"
  local bundle="${SELFTEST_ROOT}/xml/${vm}"
  local bad_xml good_xml
  mkdir -p "${bundle}"
  bad_xml="${bundle}/bad.xml"
  good_xml="${bundle}/good.xml"
  cat > "${bad_xml}" <<'EOF'
<domain type='kvm' xmlns:qemu='http://libvirt.org/schemas/domain/qemu/1.0'>
  <name>ft-iothread</name>
  <devices/>
  <qemu:commandline>
    <qemu:arg value='-object'/>
    <qemu:arg value='iothread,id=iothread1'/>
    <qemu:arg value='-object'/>
    <qemu:arg value='colo-compare,id=comp0,iothread=iothread1'/>
  </qemu:commandline>
</domain>
EOF
  if ftctl_xml_validate_xcolo_iothread_contract "${bad_xml}" >/dev/null 2>&1; then
    selftest_fail "opaque qemu:commandline iothread should fail validation"
  fi

  cat > "${good_xml}" <<'EOF'
<domain type='kvm' xmlns:qemu='http://libvirt.org/schemas/domain/qemu/1.0'>
  <name>ft-iothread</name>
  <devices/>
  <qemu:commandline>
    <qemu:arg value='-object'/>
    <qemu:arg value='colo-compare,id=comp0,iothread=iothread1'/>
  </qemu:commandline>
</domain>
EOF
  ftctl_xml_ensure_iothread_id "${good_xml}" "1"
  ftctl_xml_validate_xcolo_iothread_contract "${good_xml}"
  selftest_assert_file_contains "${good_xml}" "<iothreads>1</iothreads>"
  selftest_assert_file_contains "${good_xml}" '<iothread id="1"'
}

selftest_case_xcolo_block_xml_preserves_disk_targets() {
  selftest_reset_env
  selftest_info "block-backed FT generated XML preserves disk targets"

  local vm="block-ftvm"
  local bundle="${SELFTEST_ROOT}/xml/${vm}"
  local primary_generated standby_generated duplicate_xml
  mkdir -p "${bundle}"
  cat > "${bundle}/primary.xml" <<EOF
<domain type='kvm'>
  <name>${vm}</name>
  <devices>
    <disk type='block' device='disk'>
      <driver name='qemu' type='raw'/>
      <source dev='/dev/rbd/rbd/${vm}-root'/>
      <target dev='sda' bus='scsi'/>
    </disk>
    <disk type='block' device='disk'>
      <driver name='qemu' type='raw'/>
      <source dev='/dev/rbd/rbd/${vm}-data'/>
      <target dev='sdb' bus='scsi'/>
    </disk>
    <interface type='bridge'>
      <mac address='52:54:00:12:34:56'/>
      <source bridge='bridge0'/>
      <target dev='vnet0'/>
      <model type='virtio'/>
    </interface>
    <graphics type='vnc' port='5904' autoport='no' listen='172.16.20.11'>
      <listen type='address' address='172.16.20.11'/>
    </graphics>
  </devices>
</domain>
EOF
  cp "${bundle}/primary.xml" "${bundle}/standby.xml"

  ftctl_profile_reset
  FTCTL_PROFILE_SECONDARY_VM_NAME="${vm}-standby"
  FTCTL_PROFILE_DISK_MAP="sda=/var/lib/libvirt/images/${vm}-root;sdb=/var/lib/libvirt/images/${vm}-data"
  FTCTL_PROFILE_XCOLO_DISK_MAP_METADATA="sda=/var/lib/libvirt/images/${vm}-root|qcow2|file|file;sdb=/var/lib/libvirt/images/${vm}-data|qcow2|file|file"
  ftctl_xcolo_prepare_block_generated_xmls "${vm}" \
    "${bundle}/primary.xml" "${bundle}/standby.xml" \
    "/dev/rbd/rbd/${vm}-root" "/var/lib/libvirt/images/${vm}-root" \
    "raw" "" ""

  primary_generated="$(ftctl_state_get "${vm}" "primary_xml_generated")"
  standby_generated="$(ftctl_state_get "${vm}" "standby_xml_generated")"
  selftest_assert_file_contains "${primary_generated}" '<target dev="sda" bus="scsi"'
  selftest_assert_file_contains "${primary_generated}" '<target dev="sdb" bus="scsi"'
  selftest_assert_file_contains "${standby_generated}" '<target dev="sda" bus="scsi"'
  selftest_assert_file_contains "${standby_generated}" '<target dev="sdb" bus="scsi"'
  selftest_assert_file_contains "${standby_generated}" '<disk type="file" device="disk"'
  selftest_assert_file_contains "${standby_generated}" '<driver name="qemu" type="qcow2"'
  selftest_assert_file_contains "${standby_generated}" '<source file="/var/lib/libvirt/images/block-ftvm-root"'
  selftest_assert_file_contains "${standby_generated}" '<source file="/var/lib/libvirt/images/block-ftvm-data"'
  python3 - <<'PY' "${primary_generated}" "${standby_generated}"
import sys
import xml.etree.ElementTree as ET

for xml_path in sys.argv[1:]:
    root = ET.parse(xml_path).getroot()
    iface = root.find("./devices/interface")
    if iface is None:
        raise SystemExit(f"missing interface in {xml_path}")
    driver = iface.find("driver")
    if driver is None or driver.get("name") != "qemu":
        raise SystemExit(f"interface driver is not qemu in {xml_path}")

standby_root = ET.parse(sys.argv[2]).getroot()
graphics = standby_root.find("./devices/graphics")
if graphics is None:
    raise SystemExit("missing standby graphics")
if graphics.get("listen") != "0.0.0.0":
    raise SystemExit(f"standby graphics listen was not normalized: {graphics.get('listen')}")
listen = graphics.find("listen")
if listen is None or listen.get("address") != "0.0.0.0":
    raise SystemExit("standby graphics listen child was not normalized")
PY
  selftest_assert_file_contains "${standby_generated}" '/var/lib/libvirt/images/block-ftvm-root'
  selftest_assert_file_contains "${standby_generated}" '/var/lib/libvirt/images/block-ftvm-data'
  if grep -q '/dev/rbd/rbd/block-ftvm-data' "${standby_generated}"; then
    selftest_fail "standby generated XML kept original data disk source"
  fi
  ftctl_xml_validate_unique_disk_targets "${primary_generated}"
  ftctl_xml_validate_unique_disk_targets "${standby_generated}"

  duplicate_xml="${bundle}/duplicate.xml"
  cp "${standby_generated}" "${duplicate_xml}"
  python3 - <<'PY' "${duplicate_xml}"
import sys
import xml.etree.ElementTree as ET

xml_path = sys.argv[1]
tree = ET.parse(xml_path)
root = tree.getroot()
disks = [d for d in root.find("devices").findall("disk") if d.get("device") == "disk"]
disks[0].find("target").set("dev", "sdb")
tree.write(xml_path, encoding="unicode")
PY
  if ftctl_xml_validate_unique_disk_targets "${duplicate_xml}" >/dev/null 2>&1; then
    selftest_fail "duplicate disk target validator should fail"
  fi
}

selftest_case_xcolo_primary_create_maps_rbd_sources() (
  selftest_reset_env
  selftest_info "x-colo primary generated XML maps KRBD sources before create"

  local vm="primary-rbd-create"
  local bundle="${SELFTEST_ROOT}/xml/${vm}"
  local generated_xml="${bundle}/primary.generated.xml"
  local call_log="${SELFTEST_ROOT}/primary-rbd-create-calls.log"
  mkdir -p "${bundle}"
  cat > "${generated_xml}" <<EOF
<domain type='kvm'>
  <name>${vm}</name>
  <devices>
    <disk type='block' device='disk'>
      <source dev='/dev/rbd/rbd/${vm}-root'/>
      <target dev='sda' bus='scsi'/>
    </disk>
    <disk type='block' device='disk'>
      <source dev='/dev/rbd/rbd/${vm}-data'/>
      <target dev='sdb' bus='scsi'/>
    </disk>
  </devices>
</domain>
EOF

  ftctl_blockcopy_krbd_map_local() {
    printf 'MAP:%s\n' "$1" >> "${call_log}"
  }
  ftctl_virsh() {
    local _timeout="$1" out_var="$2" err_var="$3" rc_var="$4"
    shift 4
    : "${_timeout}"
    printf -v "${out_var}" '%s' ""
    printf -v "${err_var}" '%s' ""
    printf -v "${rc_var}" '%s' "0"
    printf 'VIRSH:%s\n' "$*" >> "${call_log}"
  }

  FTCTL_PROFILE_PRIMARY_URI="qemu:///system"
  FTCTL_XCOLO_QMP_TIMEOUT_SEC="3"
  ftctl_xcolo_create_primary_generated "${vm}" "${generated_xml}"

  selftest_assert_file_contains "${call_log}" "MAP:/dev/rbd/rbd/${vm}-root"
  selftest_assert_file_contains "${call_log}" "MAP:/dev/rbd/rbd/${vm}-data"
  selftest_assert_file_contains "${call_log}" "VIRSH:-- -c qemu:///system create ${generated_xml}"
  selftest_assert_file_contains "${FTCTL_EVENTS_LOG}" "primary.rbd-map"
  selftest_assert_file_contains "${FTCTL_EVENTS_LOG}" "primary.create_generated"
)

selftest_case_xcolo_scsi_root_replace_avoids_lun_collision() (
  selftest_reset_env
  selftest_info "x-colo SCSI root replacement removes existing qdev before reusing LUN"

  local call_log="${SELFTEST_ROOT}/xcolo-scsi-replace-calls.log"
  FTCTL_DRY_RUN="1"
  FTCTL_PROFILE_PRIMARY_URI="qemu:///system"
  FTCTL_PROFILE_SECONDARY_URI="qemu+ssh://peer/system"

  # shellcheck disable=SC2317
  ftctl_xcolo_qmp_require_ok() {
    local uri="$1" vm="$2" payload="$3" stage="$4" event="$5"
    printf '%s|%s|%s|%s|%s\n' "${stage}" "${event}" "${uri}" "${vm}" "${payload}" >> "${call_log}"
  }

  ftctl_xcolo_attach_secondary_block_graph \
    "standby-vm" "libvirt-3-format" "/tmp/hidden.qcow2" "/tmp/active.qcow2" "scsi0-0-0-0"
  ftctl_xcolo_attach_primary_block_graph \
    "primary-vm" "libvirt-3-storage" "/tmp/primary-active.qcow2" "scsi0-0-0-0"
  ftctl_xcolo_attach_primary_block_graph \
    "primary-vm" "libvirt-2-storage" "/tmp/primary-active-data.qcow2" "scsi0-0-0-1" "sdb"

  selftest_assert_file_contains "${call_log}" "secondary.device_del_existing_root"
  selftest_assert_file_contains "${call_log}" '"execute":"device_del","arguments":{"id":"scsi0-0-0-0"}'
  selftest_assert_file_contains "${call_log}" "secondary.device_add_colo_root"
  selftest_assert_file_contains "${call_log}" '"bus":"scsi0.0","channel":0,"scsi-id":0,"lun":0,"drive":"ftctl-colo-root","id":"ftctl-colo-root","bootindex":1'
  selftest_assert_file_contains "${call_log}" '"bus":"scsi0.0","channel":0,"scsi-id":0,"lun":1,"drive":"ftctl-colo-sdb","id":"ftctl-colo-sdb"'
  if grep -F '"lun":1' "${call_log}" | grep -q '"bootindex"'; then
    selftest_fail "non-root x-colo disk replacement must not set bootindex"
  fi
  selftest_assert_file_contains "${call_log}" "primary.device_del_existing_root"
  selftest_assert_file_contains "${call_log}" "primary.device_add_colo_root"
)

selftest_case_xcolo_block_handshake_sets_checkpoint_after_migrate() (
  selftest_reset_env
  selftest_info "x-colo block handshake sets checkpoint delay before primary migrate"

  local call_log="${SELFTEST_ROOT}/xcolo-block-handshake-order.log"
  local filter_line cont_line migrate_line params_line
  FTCTL_PROFILE_PRIMARY_URI="qemu:///system"
  FTCTL_PROFILE_SECONDARY_URI="qemu+ssh://peer/system"
  FTCTL_PROFILE_XCOLO_NBD_ENDPOINT="tcp:10.0.0.2:10809"
  FTCTL_PROFILE_XCOLO_MIGRATE_URI="tcp:10.0.0.2:9998"
  FTCTL_PROFILE_XCOLO_NBD_NODE="nbd0"
  FTCTL_PROFILE_XCOLO_CHECKPOINT_DELAY="2000"
  selftest_mock_xcolo_primary_channels_ready

  # shellcheck disable=SC2317
  ftctl_xcolo_qmp_require_ok() {
    local uri="$1" vm="$2" payload="$3" stage="$4" event="$5"
    printf '%s|%s|%s|%s|%s\n' "${stage}" "${event}" "${uri}" "${vm}" "${payload}" >> "${call_log}"
  }

  ftctl_xcolo_execute_handshake_with_nodes "primary-vm" "standby-vm" "parent0"

  selftest_assert_file_contains "${call_log}" "primary.object_add_redirector_in"
  selftest_assert_file_contains "${call_log}" "primary.object_add_redirector_out"
  selftest_assert_file_contains "${call_log}" "primary.object_add_colo_compare"
  selftest_assert_file_contains "${call_log}" "primary.object_add_filter_mirror"
  selftest_assert_file_contains "${call_log}" "primary.cont_before_migrate"
  selftest_assert_file_contains "${call_log}" "primary.migrate"
  selftest_assert_file_contains "${call_log}" "primary.migrate_set_parameters"
  selftest_assert_eq "$(ftctl_state_get "primary-vm" "xcolo_primary_net_filters_attached")" "true" \
    "primary net filters attached state"
  selftest_assert_eq "$(ftctl_state_get "primary-vm" "xcolo_primary_cont_before_migrate")" "true" \
    "primary continued before migrate state"
  filter_line="$(grep -n '|primary.object_add_filter_mirror|' "${call_log}" | head -n1 | cut -d: -f1)"
  cont_line="$(grep -n '|primary.cont_before_migrate|' "${call_log}" | head -n1 | cut -d: -f1)"
  migrate_line="$(grep -n '|primary.migrate|' "${call_log}" | head -n1 | cut -d: -f1)"
  params_line="$(grep -n '|primary.migrate_set_parameters|' "${call_log}" | head -n1 | cut -d: -f1)"
  [[ "${filter_line}" -lt "${migrate_line}" ]] || \
    selftest_fail "primary filter-mirror must be attached before primary.migrate"
  [[ "${params_line}" -lt "${migrate_line}" ]] || \
    selftest_fail "primary.migrate_set_parameters must be issued before primary.migrate"
  [[ "${cont_line}" -lt "${migrate_line}" ]] || \
    selftest_fail "primary.cont_before_migrate must be issued before primary.migrate"
)

selftest_case_xcolo_multi_disk_handshake_exports_all_disks() (
  selftest_reset_env
  selftest_info "x-colo block handshake exports all mapped disks before primary migrate"

  local call_log="${SELFTEST_ROOT}/xcolo-multi-disk-handshake-order.log"
  local sda_export_line sdb_export_line cont_line migrate_line
  FTCTL_PROFILE_PRIMARY_URI="qemu:///system"
  FTCTL_PROFILE_SECONDARY_URI="qemu+ssh://peer/system"
  FTCTL_PROFILE_XCOLO_NBD_ENDPOINT="tcp:10.0.0.2:10809"
  FTCTL_PROFILE_XCOLO_MIGRATE_URI="tcp:10.0.0.2:9998"
  FTCTL_PROFILE_XCOLO_NBD_NODE="nbd0"
  FTCTL_PROFILE_XCOLO_CHECKPOINT_DELAY="2000"
  selftest_mock_xcolo_primary_channels_ready

  ftctl_state_set "primary-vm" \
    "xcolo_disk_sda_primary_base_node=libvirt-root-storage" \
    "xcolo_disk_sda_primary_base_qdev=scsi0-0-0-0" \
    "xcolo_disk_sda_primary_overlay=/tmp/primary-root-active.qcow2" \
    "xcolo_disk_sda_secondary_base_node=libvirt-root-format" \
    "xcolo_disk_sdb_primary_base_node=libvirt-data-storage" \
    "xcolo_disk_sdb_primary_base_qdev=scsi0-0-0-1" \
    "xcolo_disk_sdb_primary_overlay=/tmp/primary-data-active.qcow2" \
    "xcolo_disk_sdb_secondary_base_node=libvirt-data-format"

  # shellcheck disable=SC2317
  ftctl_xcolo_qmp_require_ok() {
    local uri="$1" vm="$2" payload="$3" stage="$4" event="$5"
    printf '%s|%s|%s|%s|%s\n' "${stage}" "${event}" "${uri}" "${vm}" "${payload}" >> "${call_log}"
  }

  ftctl_xcolo_execute_handshake_with_disk_plan \
    "primary-vm" "standby-vm" \
    "sda|/dev/rbd/rbd/root|raw|block|/var/lib/libvirt/images/root;sdb|/dev/rbd/rbd/data|raw|block|/var/lib/libvirt/images/data"

  selftest_assert_file_contains "${call_log}" "secondary.nbd_server_add.sda"
  selftest_assert_file_contains "${call_log}" "secondary.nbd_server_add.sdb"
  selftest_assert_file_contains "${call_log}" "primary.blockdev_add.sda"
  selftest_assert_file_contains "${call_log}" "primary.blockdev_add.sdb"
  selftest_assert_file_contains "${call_log}" "primary.blockdev_add_active.sda"
  selftest_assert_file_contains "${call_log}" "primary.blockdev_add_active.sdb"
  selftest_assert_file_contains "${call_log}" "primary.blockdev_add_quorum.sda"
  selftest_assert_file_contains "${call_log}" "primary.blockdev_add_quorum.sdb"
  selftest_assert_file_contains "${call_log}" "primary.x_blockdev_change.sda"
  selftest_assert_file_contains "${call_log}" "primary.x_blockdev_change.sdb"
  selftest_assert_file_contains "${call_log}" '"node-name":"nbd0-sda"'
  selftest_assert_file_contains "${call_log}" '"node-name":"nbd0-sdb"'
  selftest_assert_file_contains "${call_log}" '"children":\["ftctl-primary-active-sda"\]'
  selftest_assert_file_contains "${call_log}" '"children":\["ftctl-primary-active-sdb"\]'
  selftest_assert_file_contains "${call_log}" '"parent":"ftctl-colo-sda","node":"nbd0-sda"'
  selftest_assert_file_contains "${call_log}" '"parent":"ftctl-colo-sdb","node":"nbd0-sdb"'
  selftest_assert_file_contains "${call_log}" '"device":"ftctl-colo-sda"'
  selftest_assert_file_contains "${call_log}" '"device":"ftctl-colo-sdb"'
  selftest_assert_file_contains "${call_log}" '"export":"ftctl-colo-sda"'
  selftest_assert_file_contains "${call_log}" '"export":"ftctl-colo-sdb"'
  selftest_assert_file_not_contains "${call_log}" '"export":"libvirt-root-format"'
  selftest_assert_file_not_contains "${call_log}" '"export":"libvirt-data-format"'
  selftest_assert_file_contains "${call_log}" "primary.cont_before_migrate"
  sda_export_line="$(grep -n '|secondary.nbd_server_add.sda|' "${call_log}" | head -n1 | cut -d: -f1)"
  sdb_export_line="$(grep -n '|secondary.nbd_server_add.sdb|' "${call_log}" | head -n1 | cut -d: -f1)"
  cont_line="$(grep -n '|primary.cont_before_migrate|' "${call_log}" | head -n1 | cut -d: -f1)"
  migrate_line="$(grep -n '|primary.migrate|' "${call_log}" | head -n1 | cut -d: -f1)"
  [[ "${sda_export_line}" -lt "${migrate_line}" && "${sdb_export_line}" -lt "${migrate_line}" ]] || \
    selftest_fail "all disk exports must be added before primary.migrate"
  [[ "${cont_line}" -lt "${migrate_line}" ]] || \
    selftest_fail "primary.cont_before_migrate must be issued before primary.migrate"
)

selftest_case_xcolo_primary_filter_binding_blocks_migrate() (
  selftest_reset_env
  selftest_info "x-colo primary filter binding blocks migrate when QEMU frontend is incomplete"

  local call_log="${SELFTEST_ROOT}/xcolo-filter-binding-blocks-migrate.log"
  local rc=0
  FTCTL_PROFILE_PRIMARY_URI="qemu:///system"
  FTCTL_PROFILE_SECONDARY_URI="qemu+ssh://peer/system"
  FTCTL_PROFILE_XCOLO_NBD_ENDPOINT="tcp:10.0.0.2:10809"
  FTCTL_PROFILE_XCOLO_MIGRATE_URI="tcp:10.0.0.2:9998"
  FTCTL_PROFILE_XCOLO_NBD_NODE="nbd0"
  FTCTL_PROFILE_XCOLO_CHECKPOINT_DELAY="2000"
  FTCTL_XCOLO_FILTER_BIND_WAIT_SEC="1"
  FTCTL_XCOLO_FILTER_BIND_INTERVAL_SEC="1"
  selftest_mock_xcolo_primary_channels_ready

  # shellcheck disable=SC2317
  ftctl_xcolo_qmp_require_ok() {
    local uri="$1" vm="$2" payload="$3" stage="$4" event="$5"
    printf '%s|%s|%s|%s|%s\n' "${stage}" "${event}" "${uri}" "${vm}" "${payload}" >> "${call_log}"
  }
  # shellcheck disable=SC2317
  ftctl_xcolo_wait_primary_filter_chardev_binding() {
    local vm="${1-}"
    ftctl_state_set "${vm}" \
      "last_error=primary_filter_chardev_frontend_incomplete" \
      "xcolo_primary_filter_chardev_ready=no" \
      "xcolo_primary_filter_chardev_reason=mirror0:frontend_closed,compare0:frontend_closed"
    ftctl_log_event "colo" "primary.filter_chardev_binding" "fail" "${vm}" "" \
      "reason=mirror0:frontend_closed,compare0:frontend_closed attempts=1"
    return 1
  }

  ftctl_xcolo_execute_handshake_with_nodes "primary-vm" "standby-vm" "parent0" || rc=$?

  selftest_assert_eq "${rc}" "1" "incomplete primary filter binding should fail"
  selftest_assert_eq "$(ftctl_state_get "primary-vm" "last_error")" \
    "primary_filter_chardev_frontend_incomplete" \
    "specific filter binding error should be preserved"
  selftest_assert_file_contains "${call_log}" "primary.object_add_filter_mirror"
  selftest_assert_file_not_contains "${call_log}" "primary.cont_before_migrate"
  selftest_assert_file_not_contains "${call_log}" "primary.migrate"
)

selftest_case_xcolo_baseline_seed_uses_primary_nbd_before_runtime_graph() (
  selftest_reset_env
  selftest_info "x-colo block cold conversion seeds secondary baseline over primary read-only NBD"

  local call_log="${SELFTEST_ROOT}/xcolo-baseline-seed.log"
  FTCTL_PROFILE_SECONDARY_URI="qemu+ssh://peer/system"
  FTCTL_PROFILE_FENCING_SSH_USER="root"
  FTCTL_PROFILE_XCOLO_NBD_ENDPOINT="tcp:10.0.0.2:10809"
  FTCTL_REMOTE_NBD_PORT_BASE="10809"
  FTCTL_REMOTE_NBD_PORT_COUNT="64"
  FTCTL_XCOLO_QMP_TIMEOUT_SEC="3"

  # shellcheck disable=SC2317
  ftctl_xcolo_primary_connect_host() {
    printf '%s\n' "10.0.0.1"
  }
  # shellcheck disable=SC2317
  ftctl_blockcopy_remote_target_host_user() {
    printf -v "$1" '%s' "10.0.0.2"
    printf -v "$2" '%s' "root"
  }
  # shellcheck disable=SC2317
  ftctl_blockcopy_krbd_map_local() {
    printf 'MAP:%s\n' "$1" >> "${call_log}"
  }
  # shellcheck disable=SC2317
  ftctl_cmd_run() {
    local _timeout="$1" out_var="$2" err_var="$3" rc_var="$4" pid_file="" arg prev=""
    shift 4
    [[ "${1-}" == "--" ]] && shift
    printf 'LOCAL:%s\n' "$*" >> "${call_log}"
    for arg in "$@"; do
      if [[ "${prev}" == "--pid-file" ]]; then
        pid_file="${arg}"
        break
      fi
      prev="${arg}"
    done
    [[ -n "${pid_file}" ]] && printf '999999\n' > "${pid_file}"
    printf -v "${out_var}" '%s' ""
    printf -v "${err_var}" '%s' ""
    printf -v "${rc_var}" '%s' "0"
  }
  # shellcheck disable=SC2317
  ftctl_blockcopy_remote_exec() {
    local out_var="$3" err_var="$4" rc_var="$5" remote_cmd="$6"
    printf 'REMOTE:%s\n' "${remote_cmd}" >> "${call_log}"
    printf -v "${out_var}" '%s' "format=qcow2 virtual=12345 actual=4096"
    printf -v "${err_var}" '%s' ""
    printf -v "${rc_var}" '%s' "0"
  }

  ftctl_xcolo_seed_secondary_baseline_disk \
    "primary-vm" "sda" "/dev/rbd/rbd/root" "raw" "/var/lib/libvirt/images/root.qcow2" "12345"

  selftest_assert_file_contains "${call_log}" "qemu-nbd"
  selftest_assert_file_contains "${call_log}" "--read-only"
  selftest_assert_file_contains "${call_log}" "MAP:/dev/rbd/rbd/root"
  selftest_assert_file_contains "${call_log}" "qemu-img info --force-share --output=json /dev/rbd/rbd/root"
  selftest_assert_file_contains "${call_log}" "--export-name ftctl-xcolo-seed-primary-vm-sda"
  selftest_assert_file_contains "${call_log}" "qemu-img convert -p"
  selftest_assert_file_contains "${call_log}" "nbd://10.0.0.1:"
  selftest_assert_file_contains "${call_log}" "ftctl-xcolo-seed-primary-vm-sda"
  selftest_assert_file_contains "${call_log}" "mv -f --"
  selftest_assert_eq "$(ftctl_state_get "primary-vm" "xcolo_disk_sda_baseline_seeded")" "true" \
    "baseline seed state"
)

selftest_case_xcolo_runtime_validation_blocks_false_positive() (
  selftest_reset_env
  selftest_info "x-colo runtime validation blocks false-positive colo_running"

  local vm="xcolo-guard"
  ftctl_state_init_vm "${vm}"
  FTCTL_DRY_RUN="0"
  FTCTL_PROFILE_PRIMARY_URI="qemu:///system"
  FTCTL_PROFILE_SECONDARY_URI="qemu+ssh://peer/system"
  FTCTL_BLOCKCOPY_WAIT_TIMEOUT_SEC="1"
  FTCTL_XCOLO_RUNTIME_VALIDATE_TIMEOUT_SEC="1"
  FTCTL_PROFILE_QGA_POLICY="off"

  # shellcheck disable=SC2317
  ftctl_xcolo_query_running_flag() {
    local uri="${1-}" out_var="${3}"
    if [[ "${uri}" == "${FTCTL_PROFILE_PRIMARY_URI}" ]]; then
      printf -v "${out_var}" '%s' "false"
    else
      printf -v "${out_var}" '%s' "true"
    fi
    return 0
  }
  # shellcheck disable=SC2317
  ftctl_xcolo_query_status_name() {
    local out_var="${3}"
    printf -v "${out_var}" '%s' "running"
    return 0
  }
  # shellcheck disable=SC2317
  ftctl_xcolo_query_migrate_status() {
    local out_var="${3}"
    printf -v "${out_var}" '%s' "colo"
    return 0
  }
  # shellcheck disable=SC2317
  ftctl_xcolo_domain_xml_has_runtime_markers() {
    return 0
  }

  if ftctl_xcolo_validate_pair_runtime "${vm}" "${vm}-standby"; then
    selftest_fail "runtime validation should fail when primary is not running"
  fi
  selftest_assert_eq "$(ftctl_state_get "${vm}" "last_error")" \
    "xcolo_runtime_validation_failed:primary_not_running" \
    "runtime validation failure reason"
)

selftest_case_xcolo_runtime_validation_reports_primary_migrate_failure() (
  selftest_reset_env
  selftest_info "x-colo runtime validation reports terminal primary migration failure"

  local vm="xcolo-primary-failed"
  ftctl_state_init_vm "${vm}"
  FTCTL_DRY_RUN="0"
  FTCTL_PROFILE_PRIMARY_URI="qemu:///system"
  FTCTL_PROFILE_SECONDARY_URI="qemu+ssh://peer/system"
  FTCTL_BLOCKCOPY_WAIT_TIMEOUT_SEC="1"
  FTCTL_XCOLO_RUNTIME_VALIDATE_TIMEOUT_SEC="5"
  FTCTL_PROFILE_QGA_POLICY="off"

  # shellcheck disable=SC2317
  ftctl_xcolo_query_running_flag() {
    local out_var="${3}"
    printf -v "${out_var}" '%s' "true"
    return 0
  }
  # shellcheck disable=SC2317
  ftctl_xcolo_query_status_name() {
    local out_var="${3}"
    printf -v "${out_var}" '%s' "running"
    return 0
  }
  # shellcheck disable=SC2317
  ftctl_xcolo_query_migrate_status() {
    local uri="${1-}" out_var="${3}"
    if [[ "${uri}" == "${FTCTL_PROFILE_PRIMARY_URI}" ]]; then
      printf -v "${out_var}" '%s' "failed"
    else
      printf -v "${out_var}" '%s' "active"
    fi
    return 0
  }
  # shellcheck disable=SC2317
  ftctl_xcolo_domain_xml_has_runtime_markers() {
    return 0
  }

  if ftctl_xcolo_validate_pair_runtime "${vm}" "${vm}-standby"; then
    selftest_fail "runtime validation should fail on terminal primary migration failure"
  fi
  selftest_assert_eq "$(ftctl_state_get "${vm}" "last_error")" \
    "xcolo_runtime_validation_failed:primary_migrate_failed" \
    "runtime validation terminal failure reason"
)

selftest_case_xcolo_runtime_validation_reports_pending_convergence() (
  selftest_reset_env
  selftest_info "x-colo runtime validation reports missing colo role without hard failure"

  local vm="xcolo-runtime-pending"
  local rc=0
  ftctl_state_init_vm "${vm}"
  FTCTL_DRY_RUN="0"
  FTCTL_PROFILE_PRIMARY_URI="qemu:///system"
  FTCTL_PROFILE_SECONDARY_URI="qemu+ssh://peer/system"
  FTCTL_BLOCKCOPY_WAIT_TIMEOUT_SEC="1"
  FTCTL_XCOLO_RUNTIME_VALIDATE_TIMEOUT_SEC="1"
  FTCTL_PROFILE_QGA_POLICY="off"

  # shellcheck disable=SC2317
  ftctl_xcolo_query_running_flag() {
    local out_var="${3}"
    printf -v "${out_var}" '%s' "false"
    return 0
  }
  # shellcheck disable=SC2317
  ftctl_xcolo_query_status_name() {
    local uri="${1-}" out_var="${3}"
    if [[ "${uri}" == "${FTCTL_PROFILE_PRIMARY_URI}" ]]; then
      printf -v "${out_var}" '%s' "finish-migrate"
    else
      printf -v "${out_var}" '%s' "inmigrate"
    fi
    return 0
  }
  # shellcheck disable=SC2317
  ftctl_xcolo_query_migrate_status() {
    local uri="${1-}" out_var="${3}"
    if [[ "${uri}" == "${FTCTL_PROFILE_PRIMARY_URI}" ]]; then
      printf -v "${out_var}" '%s' "active"
    else
      printf -v "${out_var}" '%s' "colo"
    fi
    return 0
  }
  # shellcheck disable=SC2317
  ftctl_xcolo_query_colo_mode() {
    local out_var="${3}"
    printf -v "${out_var}" '%s' "none"
    return 0
  }
  # shellcheck disable=SC2317
  ftctl_xcolo_domain_xml_has_runtime_markers() {
    return 0
  }

  ftctl_xcolo_validate_pair_runtime "${vm}" "${vm}-standby" || rc=$?
  selftest_assert_eq "${rc}" "10" "runtime validation pending return code"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "xcolo_pending_reason")" \
    "colo_role_not_entered" \
    "runtime validation pending reason"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "xcolo_runtime_pending_since" >/dev/null 2>&1; echo $?)" \
    "0" \
    "runtime validation records pending start"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "last_error")" "" \
    "runtime validation pending keeps last_error clear"
)

selftest_case_xcolo_runtime_validation_times_out_stuck_convergence() (
  selftest_reset_env
  selftest_info "x-colo runtime validation reports missing colo role after bounded wait"

  local vm="xcolo-runtime-timeout"
  local rc=0
  ftctl_state_init_vm "${vm}"
  ftctl_state_set "${vm}" "xcolo_runtime_pending_since=$(date -d '10 seconds ago' '+%Y-%m-%dT%H:%M:%S%:z')"
  FTCTL_DRY_RUN="0"
  FTCTL_PROFILE_PRIMARY_URI="qemu:///system"
  FTCTL_PROFILE_SECONDARY_URI="qemu+ssh://peer/system"
  FTCTL_BLOCKCOPY_WAIT_TIMEOUT_SEC="1"
  FTCTL_XCOLO_RUNTIME_VALIDATE_TIMEOUT_SEC="1"
  FTCTL_XCOLO_RUNTIME_PENDING_MAX_SEC="1"
  FTCTL_PROFILE_QGA_POLICY="off"
  selftest_mock_xcolo_primary_channels_ready
  selftest_mock_xcolo_primary_role_diagnostics_ok
  ftctl_state_set "${vm}" "xcolo_primary_net_filters_attached=true"

  # shellcheck disable=SC2317
  ftctl_xcolo_query_running_flag() {
    local out_var="${3}"
    printf -v "${out_var}" '%s' "false"
    return 0
  }
  # shellcheck disable=SC2317
  ftctl_xcolo_query_status_name() {
    local uri="${1-}" out_var="${3}"
    if [[ "${uri}" == "${FTCTL_PROFILE_PRIMARY_URI}" ]]; then
      printf -v "${out_var}" '%s' "finish-migrate"
    else
      printf -v "${out_var}" '%s' "inmigrate"
    fi
    return 0
  }
  # shellcheck disable=SC2317
  ftctl_xcolo_query_migrate_status() {
    local uri="${1-}" out_var="${3}"
    if [[ "${uri}" == "${FTCTL_PROFILE_PRIMARY_URI}" ]]; then
      printf -v "${out_var}" '%s' "active"
    else
      printf -v "${out_var}" '%s' "colo"
    fi
    return 0
  }
  # shellcheck disable=SC2317
  ftctl_xcolo_query_colo_mode() {
    local out_var="${3}"
    printf -v "${out_var}" '%s' "none"
    return 0
  }
  # shellcheck disable=SC2317
  ftctl_xcolo_domain_xml_has_runtime_markers() {
    return 0
  }

  ftctl_xcolo_validate_pair_runtime "${vm}" "${vm}-standby" || rc=$?
  selftest_assert_eq "${rc}" "1" "stuck convergence should fail"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "last_error")" \
    "xcolo_runtime_validation_failed:colo_role_not_entered" \
    "missing colo role failure reason"
)

selftest_case_xcolo_runtime_validation_reports_one_sided_colo_role() (
  selftest_reset_env
  selftest_info "x-colo runtime validation reports one-sided secondary colo role"

  local vm="xcolo-runtime-one-sided-role"
  local rc=0
  ftctl_state_init_vm "${vm}"
  ftctl_state_set "${vm}" "xcolo_runtime_pending_since=$(date -d '10 seconds ago' '+%Y-%m-%dT%H:%M:%S%:z')"
  FTCTL_DRY_RUN="0"
  FTCTL_PROFILE_PRIMARY_URI="qemu:///system"
  FTCTL_PROFILE_SECONDARY_URI="qemu+ssh://peer/system"
  FTCTL_BLOCKCOPY_WAIT_TIMEOUT_SEC="1"
  FTCTL_XCOLO_RUNTIME_VALIDATE_TIMEOUT_SEC="1"
  FTCTL_XCOLO_RUNTIME_PENDING_MAX_SEC="1"
  FTCTL_PROFILE_QGA_POLICY="off"
  selftest_mock_xcolo_primary_channels_ready
  selftest_mock_xcolo_primary_role_diagnostics_ok
  ftctl_state_set "${vm}" "xcolo_primary_net_filters_attached=true"

  # shellcheck disable=SC2317
  ftctl_xcolo_query_running_flag() {
    local out_var="${3}"
    printf -v "${out_var}" '%s' "false"
    return 0
  }
  # shellcheck disable=SC2317
  ftctl_xcolo_query_status_name() {
    local uri="${1-}" out_var="${3}"
    if [[ "${uri}" == "${FTCTL_PROFILE_PRIMARY_URI}" ]]; then
      printf -v "${out_var}" '%s' "finish-migrate"
    else
      printf -v "${out_var}" '%s' "inmigrate"
    fi
    return 0
  }
  # shellcheck disable=SC2317
  ftctl_xcolo_query_migrate_status() {
    local uri="${1-}" out_var="${3}"
    if [[ "${uri}" == "${FTCTL_PROFILE_PRIMARY_URI}" ]]; then
      printf -v "${out_var}" '%s' "active"
    else
      printf -v "${out_var}" '%s' "colo"
    fi
    return 0
  }
  # shellcheck disable=SC2317
  ftctl_xcolo_query_colo_mode() {
    local uri="${1-}" out_var="${3}"
    if [[ "${uri}" == "${FTCTL_PROFILE_PRIMARY_URI}" ]]; then
      printf -v "${out_var}" '%s' "none"
    else
      printf -v "${out_var}" '%s' "secondary"
    fi
    return 0
  }
  # shellcheck disable=SC2317
  ftctl_xcolo_domain_xml_has_runtime_markers() {
    return 0
  }

  ftctl_xcolo_validate_pair_runtime "${vm}" "${vm}-standby" || rc=$?
  selftest_assert_eq "${rc}" "1" "one-sided role should fail after bounded wait"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "last_error")" \
    "xcolo_runtime_validation_failed:primary_qemu_colo_role_transition_failed" \
    "one-sided secondary role refined failure reason"
)

selftest_case_xcolo_runtime_validation_refines_missing_primary_colo_capability() (
  selftest_reset_env
  selftest_info "x-colo runtime validation refines missing primary x-colo capability"

  local vm="xcolo-runtime-missing-capability"
  local rc=0
  ftctl_state_init_vm "${vm}"
  ftctl_state_set "${vm}" \
    "xcolo_runtime_pending_since=$(date -d '10 seconds ago' '+%Y-%m-%dT%H:%M:%S%:z')" \
    "xcolo_primary_net_filters_attached=true"
  FTCTL_DRY_RUN="0"
  FTCTL_PROFILE_PRIMARY_URI="qemu:///system"
  FTCTL_PROFILE_SECONDARY_URI="qemu+ssh://peer/system"
  FTCTL_BLOCKCOPY_WAIT_TIMEOUT_SEC="1"
  FTCTL_XCOLO_RUNTIME_VALIDATE_TIMEOUT_SEC="1"
  FTCTL_XCOLO_RUNTIME_PENDING_MAX_SEC="1"
  FTCTL_PROFILE_QGA_POLICY="off"
  selftest_mock_xcolo_primary_channels_ready

  # shellcheck disable=SC2317
  ftctl_xcolo_collect_runtime_failure_diagnostics() {
    local vm="${1-}"
    ftctl_state_set "${vm}" \
      "xcolo_debug_dir=${FTCTL_RUN_DIR}/debug/xcolo/$(ftctl_state_vm_key "${vm}")" \
      "xcolo_primary_capability_x_colo=no" \
      "xcolo_primary_capability_return_path=yes" \
      "xcolo_primary_checkpoint_delay_set=yes"
  }
  # shellcheck disable=SC2317
  ftctl_xcolo_query_running_flag() {
    local out_var="${3}"
    printf -v "${out_var}" '%s' "false"
    return 0
  }
  # shellcheck disable=SC2317
  ftctl_xcolo_query_status_name() {
    local uri="${1-}" out_var="${3}"
    if [[ "${uri}" == "${FTCTL_PROFILE_PRIMARY_URI}" ]]; then
      printf -v "${out_var}" '%s' "finish-migrate"
    else
      printf -v "${out_var}" '%s' "inmigrate"
    fi
    return 0
  }
  # shellcheck disable=SC2317
  ftctl_xcolo_query_migrate_status() {
    local uri="${1-}" out_var="${3}"
    if [[ "${uri}" == "${FTCTL_PROFILE_PRIMARY_URI}" ]]; then
      printf -v "${out_var}" '%s' "active"
    else
      printf -v "${out_var}" '%s' "colo"
    fi
    return 0
  }
  # shellcheck disable=SC2317
  ftctl_xcolo_query_colo_mode() {
    local uri="${1-}" out_var="${3}"
    if [[ "${uri}" == "${FTCTL_PROFILE_PRIMARY_URI}" ]]; then
      printf -v "${out_var}" '%s' "none"
    else
      printf -v "${out_var}" '%s' "secondary"
    fi
    return 0
  }
  # shellcheck disable=SC2317
  ftctl_xcolo_domain_xml_has_runtime_markers() {
    return 0
  }

  ftctl_xcolo_validate_pair_runtime "${vm}" "${vm}-standby" || rc=$?
  selftest_assert_eq "${rc}" "1" "missing primary x-colo capability should fail"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "last_error")" \
    "xcolo_runtime_validation_failed:primary_colo_capability_missing" \
    "missing primary x-colo capability refined reason"
)

selftest_case_xcolo_runtime_validation_refines_primary_chardev_binding() (
  selftest_reset_env
  selftest_info "x-colo runtime validation refines incomplete primary chardev binding"

  local vm="xcolo-runtime-chardev-binding"
  local rc=0
  ftctl_state_init_vm "${vm}"
  ftctl_state_set "${vm}" \
    "xcolo_runtime_pending_since=$(date -d '10 seconds ago' '+%Y-%m-%dT%H:%M:%S%:z')" \
    "xcolo_primary_net_filters_attached=true"
  FTCTL_DRY_RUN="0"
  FTCTL_PROFILE_PRIMARY_URI="qemu:///system"
  FTCTL_PROFILE_SECONDARY_URI="qemu+ssh://peer/system"
  FTCTL_BLOCKCOPY_WAIT_TIMEOUT_SEC="1"
  FTCTL_XCOLO_RUNTIME_VALIDATE_TIMEOUT_SEC="1"
  FTCTL_XCOLO_RUNTIME_PENDING_MAX_SEC="1"
  FTCTL_PROFILE_QGA_POLICY="off"
  selftest_mock_xcolo_primary_channels_ready

  # shellcheck disable=SC2317
  ftctl_xcolo_collect_runtime_failure_diagnostics() {
    local vm="${1-}"
    ftctl_state_set "${vm}" \
      "xcolo_primary_capability_x_colo=yes" \
      "xcolo_primary_capability_return_path=yes" \
      "xcolo_primary_checkpoint_delay_set=yes" \
      "xcolo_primary_filter_chardev_ready=no" \
      "xcolo_primary_filter_chardev_reason=mirror0:frontend_closed" \
      "xcolo_primary_block_graph_ready=yes"
  }
  # shellcheck disable=SC2317
  ftctl_xcolo_query_running_flag() {
    local out_var="${3}"
    printf -v "${out_var}" '%s' "false"
    return 0
  }
  # shellcheck disable=SC2317
  ftctl_xcolo_query_status_name() {
    local uri="${1-}" out_var="${3}"
    if [[ "${uri}" == "${FTCTL_PROFILE_PRIMARY_URI}" ]]; then
      printf -v "${out_var}" '%s' "finish-migrate"
    else
      printf -v "${out_var}" '%s' "inmigrate"
    fi
    return 0
  }
  # shellcheck disable=SC2317
  ftctl_xcolo_query_migrate_status() {
    local uri="${1-}" out_var="${3}"
    if [[ "${uri}" == "${FTCTL_PROFILE_PRIMARY_URI}" ]]; then
      printf -v "${out_var}" '%s' "active"
    else
      printf -v "${out_var}" '%s' "colo"
    fi
    return 0
  }
  # shellcheck disable=SC2317
  ftctl_xcolo_query_colo_mode() {
    local uri="${1-}" out_var="${3}"
    if [[ "${uri}" == "${FTCTL_PROFILE_PRIMARY_URI}" ]]; then
      printf -v "${out_var}" '%s' "none"
    else
      printf -v "${out_var}" '%s' "secondary"
    fi
    return 0
  }
  # shellcheck disable=SC2317
  ftctl_xcolo_domain_xml_has_runtime_markers() {
    return 0
  }

  ftctl_xcolo_validate_pair_runtime "${vm}" "${vm}-standby" || rc=$?
  selftest_assert_eq "${rc}" "1" "incomplete chardev binding should fail"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "last_error")" \
    "xcolo_runtime_validation_failed:primary_filter_chardev_frontend_incomplete" \
    "incomplete chardev binding refined reason"
)

selftest_case_xcolo_runtime_validation_reports_compare_channel_failure() (
  selftest_reset_env
  selftest_info "x-colo runtime validation reports missing 9000-series compare channel"

  local vm="xcolo-runtime-channel-missing"
  local rc=0
  ftctl_state_init_vm "${vm}"
  ftctl_state_set "${vm}" "xcolo_runtime_pending_since=$(date -d '10 seconds ago' '+%Y-%m-%dT%H:%M:%S%:z')"
  FTCTL_DRY_RUN="0"
  FTCTL_PROFILE_PRIMARY_URI="qemu:///system"
  FTCTL_PROFILE_SECONDARY_URI="qemu+ssh://peer/system"
  FTCTL_BLOCKCOPY_WAIT_TIMEOUT_SEC="1"
  FTCTL_XCOLO_RUNTIME_VALIDATE_TIMEOUT_SEC="1"
  FTCTL_XCOLO_RUNTIME_PENDING_MAX_SEC="1"
  FTCTL_PROFILE_QGA_POLICY="off"

  # shellcheck disable=SC2317
  ftctl_xcolo_capture_primary_channel_state() {
    local target_vm="${1-}"
    ftctl_state_set "${target_vm}" \
      "xcolo_channel_mirror_established=yes" \
      "xcolo_channel_compare_established=no" \
      "xcolo_channel_compare_local_established=yes" \
      "xcolo_channel_compare_out_established=yes"
  }
  # shellcheck disable=SC2317
  ftctl_xcolo_query_running_flag() {
    local out_var="${3}"
    printf -v "${out_var}" '%s' "false"
    return 0
  }
  # shellcheck disable=SC2317
  ftctl_xcolo_query_status_name() {
    local uri="${1-}" out_var="${3}"
    if [[ "${uri}" == "${FTCTL_PROFILE_PRIMARY_URI}" ]]; then
      printf -v "${out_var}" '%s' "finish-migrate"
    else
      printf -v "${out_var}" '%s' "inmigrate"
    fi
    return 0
  }
  # shellcheck disable=SC2317
  ftctl_xcolo_query_migrate_status() {
    local uri="${1-}" out_var="${3}"
    if [[ "${uri}" == "${FTCTL_PROFILE_PRIMARY_URI}" ]]; then
      printf -v "${out_var}" '%s' "active"
    else
      printf -v "${out_var}" '%s' "colo"
    fi
    return 0
  }
  # shellcheck disable=SC2317
  ftctl_xcolo_query_colo_mode() {
    local uri="${1-}" out_var="${3}"
    if [[ "${uri}" == "${FTCTL_PROFILE_PRIMARY_URI}" ]]; then
      printf -v "${out_var}" '%s' "none"
    else
      printf -v "${out_var}" '%s' "secondary"
    fi
    return 0
  }
  # shellcheck disable=SC2317
  ftctl_xcolo_domain_xml_has_runtime_markers() {
    return 0
  }

  ftctl_xcolo_validate_pair_runtime "${vm}" "${vm}-standby" || rc=$?
  selftest_assert_eq "${rc}" "1" "missing compare channel should fail after bounded wait"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "last_error")" \
    "xcolo_runtime_validation_failed:colo_compare_peer_channel_not_established" \
    "missing compare channel failure reason"
)

selftest_case_xcolo_runtime_validation_accepts_reported_colo_role() (
  selftest_reset_env
  selftest_info "x-colo runtime validation accepts explicit colo role state"

  local vm="xcolo-runtime-role-active"
  local rc=0
  ftctl_state_init_vm "${vm}"
  FTCTL_DRY_RUN="0"
  FTCTL_PROFILE_PRIMARY_URI="qemu:///system"
  FTCTL_PROFILE_SECONDARY_URI="qemu+ssh://peer/system"
  FTCTL_BLOCKCOPY_WAIT_TIMEOUT_SEC="1"
  FTCTL_XCOLO_RUNTIME_VALIDATE_TIMEOUT_SEC="1"
  FTCTL_PROFILE_QGA_POLICY="off"

  # shellcheck disable=SC2317
  ftctl_xcolo_query_running_flag() {
    local out_var="${3}"
    printf -v "${out_var}" '%s' "false"
    return 0
  }
  # shellcheck disable=SC2317
  ftctl_xcolo_query_status_name() {
    local uri="${1-}" out_var="${3}"
    if [[ "${uri}" == "${FTCTL_PROFILE_PRIMARY_URI}" ]]; then
      printf -v "${out_var}" '%s' "finish-migrate"
    else
      printf -v "${out_var}" '%s' "inmigrate"
    fi
    return 0
  }
  # shellcheck disable=SC2317
  ftctl_xcolo_query_migrate_status() {
    local uri="${1-}" out_var="${3}"
    if [[ "${uri}" == "${FTCTL_PROFILE_PRIMARY_URI}" ]]; then
      printf -v "${out_var}" '%s' "active"
    else
      printf -v "${out_var}" '%s' "colo"
    fi
    return 0
  }
  # shellcheck disable=SC2317
  ftctl_xcolo_query_colo_mode() {
    local uri="${1-}" out_var="${3}"
    if [[ "${uri}" == "${FTCTL_PROFILE_PRIMARY_URI}" ]]; then
      printf -v "${out_var}" '%s' "primary"
    else
      printf -v "${out_var}" '%s' "secondary"
    fi
    return 0
  }
  # shellcheck disable=SC2317
  ftctl_xcolo_domain_xml_has_runtime_markers() {
    return 0
  }

  ftctl_xcolo_validate_pair_runtime "${vm}" "${vm}-standby" || rc=$?
  selftest_assert_eq "${rc}" "0" "explicit colo role should validate"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "xcolo_primary_colo_mode")" \
    "primary" \
    "primary colo role recorded"
)

selftest_case_xcolo_runtime_validation_records_optional_qga() (
  selftest_reset_env
  selftest_info "x-colo runtime validation records optional qga without failing"

  local vm="xcolo-runtime-optional-qga"
  local rc=0
  ftctl_state_init_vm "${vm}"
  FTCTL_DRY_RUN="0"
  FTCTL_PROFILE_PRIMARY_URI="qemu:///system"
  FTCTL_PROFILE_SECONDARY_URI="qemu+ssh://peer/system"
  FTCTL_BLOCKCOPY_WAIT_TIMEOUT_SEC="1"
  FTCTL_XCOLO_RUNTIME_VALIDATE_TIMEOUT_SEC="1"
  FTCTL_PROFILE_QGA_POLICY="optional"

  # shellcheck disable=SC2317
  ftctl_xcolo_query_running_flag() {
    local out_var="${3}"
    printf -v "${out_var}" '%s' "false"
    return 0
  }
  # shellcheck disable=SC2317
  ftctl_xcolo_query_status_name() {
    local uri="${1-}" out_var="${3}"
    if [[ "${uri}" == "${FTCTL_PROFILE_PRIMARY_URI}" ]]; then
      printf -v "${out_var}" '%s' "finish-migrate"
    else
      printf -v "${out_var}" '%s' "inmigrate"
    fi
    return 0
  }
  # shellcheck disable=SC2317
  ftctl_xcolo_query_migrate_status() {
    local uri="${1-}" out_var="${3}"
    if [[ "${uri}" == "${FTCTL_PROFILE_PRIMARY_URI}" ]]; then
      printf -v "${out_var}" '%s' "active"
    else
      printf -v "${out_var}" '%s' "colo"
    fi
    return 0
  }
  # shellcheck disable=SC2317
  ftctl_xcolo_query_colo_mode() {
    local uri="${1-}" out_var="${3}"
    if [[ "${uri}" == "${FTCTL_PROFILE_PRIMARY_URI}" ]]; then
      printf -v "${out_var}" '%s' "primary"
    else
      printf -v "${out_var}" '%s' "secondary"
    fi
    return 0
  }
  # shellcheck disable=SC2317
  ftctl_xcolo_query_guest_ping() {
    local out_var="${3}"
    printf -v "${out_var}" '%s' "no"
    return 1
  }
  # shellcheck disable=SC2317
  ftctl_xcolo_domain_xml_has_runtime_markers() {
    return 0
  }

  ftctl_xcolo_validate_pair_runtime "${vm}" "${vm}-standby" || rc=$?
  selftest_assert_eq "${rc}" "0" "optional qga should not block runtime role success"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "xcolo_primary_qga")" \
    "no" \
    "optional qga state recorded"
)

selftest_case_xcolo_runtime_validation_requires_primary_qga() (
  selftest_reset_env
  selftest_info "x-colo runtime validation can require primary qga health"

  local vm="xcolo-runtime-required-qga"
  local rc=0
  ftctl_state_init_vm "${vm}"
  ftctl_state_set "${vm}" "xcolo_runtime_pending_since=$(date -d '10 seconds ago' '+%Y-%m-%dT%H:%M:%S%:z')"
  FTCTL_DRY_RUN="0"
  FTCTL_PROFILE_PRIMARY_URI="qemu:///system"
  FTCTL_PROFILE_SECONDARY_URI="qemu+ssh://peer/system"
  FTCTL_BLOCKCOPY_WAIT_TIMEOUT_SEC="1"
  FTCTL_XCOLO_RUNTIME_VALIDATE_TIMEOUT_SEC="1"
  FTCTL_XCOLO_RUNTIME_PENDING_MAX_SEC="1"
  FTCTL_PROFILE_QGA_POLICY="required"

  # shellcheck disable=SC2317
  ftctl_xcolo_query_running_flag() {
    local out_var="${3}"
    printf -v "${out_var}" '%s' "false"
    return 0
  }
  # shellcheck disable=SC2317
  ftctl_xcolo_query_status_name() {
    local uri="${1-}" out_var="${3}"
    if [[ "${uri}" == "${FTCTL_PROFILE_PRIMARY_URI}" ]]; then
      printf -v "${out_var}" '%s' "finish-migrate"
    else
      printf -v "${out_var}" '%s' "inmigrate"
    fi
    return 0
  }
  # shellcheck disable=SC2317
  ftctl_xcolo_query_migrate_status() {
    local uri="${1-}" out_var="${3}"
    if [[ "${uri}" == "${FTCTL_PROFILE_PRIMARY_URI}" ]]; then
      printf -v "${out_var}" '%s' "active"
    else
      printf -v "${out_var}" '%s' "colo"
    fi
    return 0
  }
  # shellcheck disable=SC2317
  ftctl_xcolo_query_colo_mode() {
    local uri="${1-}" out_var="${3}"
    if [[ "${uri}" == "${FTCTL_PROFILE_PRIMARY_URI}" ]]; then
      printf -v "${out_var}" '%s' "primary"
    else
      printf -v "${out_var}" '%s' "secondary"
    fi
    return 0
  }
  # shellcheck disable=SC2317
  ftctl_xcolo_query_guest_ping() {
    local out_var="${3}"
    printf -v "${out_var}" '%s' "no"
    return 1
  }
  # shellcheck disable=SC2317
  ftctl_xcolo_domain_xml_has_runtime_markers() {
    return 0
  }

  ftctl_xcolo_validate_pair_runtime "${vm}" "${vm}-standby" || rc=$?
  selftest_assert_eq "${rc}" "1" "required qga should block runtime success"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "last_error")" \
    "xcolo_runtime_validation_failed:primary_guest_boot_unhealthy" \
    "required qga failure reason"
)

selftest_case_xcolo_runtime_recovery_preserves_error_reason() (
  selftest_reset_env
  selftest_info "x-colo runtime recovery preserves validation error reason"

  local vm="xcolo-runtime-recover"
  local reason="xcolo_runtime_validation_failed:runtime_convergence_timeout"
  ftctl_state_init_vm "${vm}"
  FTCTL_DRY_RUN="0"
  FTCTL_PROFILE_PRIMARY_URI="qemu:///system"

  # shellcheck disable=SC2317
  ftctl_standby_deactivate() {
    return 0
  }
  # shellcheck disable=SC2317
  ftctl_virsh() {
    local out_var="${2}" err_var="${3}" rc_var="${4}"
    printf -v "${out_var}" '%s' ""
    printf -v "${err_var}" '%s' ""
    printf -v "${rc_var}" '%s' "0"
    return 0
  }
  # shellcheck disable=SC2317
  ftctl_primary_activate_from_backup() {
    return 0
  }

  ftctl_xcolo_recover_runtime_convergence_failure "${vm}" "${reason}"

  selftest_assert_eq "$(ftctl_state_get "${vm}" "conversion_stage")" \
    "runtime_validation_failed" \
    "runtime recovery marks validation failure stage"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "last_error")" \
    "${reason}" \
    "runtime recovery preserves last_error"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "xcolo_last_runtime_error")" \
    "${reason}" \
    "runtime recovery preserves sticky runtime error"
)

selftest_case_xcolo_block_handshake_failure_recovers_runtime() (
  selftest_reset_env
  selftest_info "x-colo block handshake failure restores primary and stops secondary"

  local vm="xcolo-handshake-recover"
  local reason="primary_filter_chardev_frontend_incomplete"
  ftctl_state_init_vm "${vm}"
  FTCTL_DRY_RUN="0"
  FTCTL_PROFILE_PRIMARY_URI="qemu:///system"

  # shellcheck disable=SC2317
  ftctl_standby_deactivate() {
    local target_vm="${1-}"
    ftctl_state_set "${target_vm}" "standby_state=stopped"
    return 0
  }
  # shellcheck disable=SC2317
  ftctl_virsh() {
    local out_var="${2}" err_var="${3}" rc_var="${4}"
    printf -v "${out_var}" '%s' ""
    printf -v "${err_var}" '%s' ""
    printf -v "${rc_var}" '%s' "0"
    return 0
  }
  # shellcheck disable=SC2317
  ftctl_primary_activate_from_backup() {
    return 0
  }

  ftctl_xcolo_recover_block_handshake_failure "${vm}" "${reason}"

  selftest_assert_eq "$(ftctl_state_get "${vm}" "conversion_stage")" \
    "handshake_failed" \
    "handshake recovery keeps handshake failure stage"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "active_side")" \
    "primary" \
    "handshake recovery returns active side to primary"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "standby_state")" \
    "stopped" \
    "handshake recovery stops standby runtime"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "last_error")" \
    "${reason}" \
    "handshake recovery preserves original reason"
)

selftest_case_xcolo_error_status_uses_sticky_runtime_error() (
  selftest_reset_env
  selftest_info "x-colo error status emits sticky runtime error when last_error is blank"

  local vm="xcolo-sticky-status"
  local out
  ftctl_state_init_vm "${vm}"
  ftctl_state_set "${vm}" \
    "mode=ft" \
    "protection_state=error" \
    "transport_state=failed" \
    "conversion_state=error" \
    "last_error=" \
    "xcolo_last_runtime_error=xcolo_runtime_validation_failed:primary_colo_role_not_entered"

  out="$(ftctl_state_emit_json_one "${vm}" "ok")"
  selftest_assert_contains "${out}" \
    '"last_error":"xcolo_runtime_validation_failed:primary_colo_role_not_entered"' \
    "status json falls back to sticky runtime error"
)

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

selftest_case_reconcile_cloud_managed_reports_failover_candidate() (
  selftest_reset_env
  selftest_info "reconcile reports cloud-managed failover candidate without executing qemu failover"

  local vm="cloud-managed-auto-candidate"

  FTCTL_PROFILE_MODE="dr"
  FTCTL_PROFILE_PROVISIONING_BACKEND="cloud-managed"
  ftctl_state_init_vm "${vm}"
  ftctl_state_set "${vm}" \
    "mode=dr" \
    "active_side=primary" \
    "protection_state=protected" \
    "transport_state=mirroring" \
    "fencing_state=clear"

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
  ftctl_inventory_check_vm() { printf '1 0 ok true not-defined-expected\n'; }
  # shellcheck disable=SC2317
  ftctl_failover_request() { selftest_fail "cloud-managed automatic candidate must be handled by Cloud, not qemu ftctl"; }

  ftctl_orchestrator_reconcile_one "${vm}"

  selftest_assert_eq "$(ftctl_state_get "${vm}" "protection_state")" "protected" "cloud candidate protection state preserved"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "transport_state")" "mirroring" "cloud candidate transport state preserved"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "last_error")" "cloud_managed_failover_candidate" "cloud candidate last_error"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "failover_candidate_reason")" "primary_domain_missing" "cloud candidate reason"
  selftest_assert_file_contains "${FTCTL_EVENTS_LOG}" '"event":"cloud_managed.failover_candidate"'
)

selftest_case_reconcile_defers_manual_fence_pending() (
  selftest_reset_env
  selftest_info "reconcile defers manual fence pending state"

  local vm="manual-fence-pending-vm"
  local call_log="${SELFTEST_ROOT}/manual-fence-pending-calls.log"

  ftctl_state_init_vm "${vm}"
  ftctl_state_set "${vm}" \
    "mode=ha" \
    "active_side=primary" \
    "protection_state=failing_over" \
    "transport_state=mirroring" \
    "fencing_state=required" \
    "failover_ready=1" \
    "last_error=manual_fencing_required"

  # shellcheck disable=SC2317
  ftctl_profile_load_vm() {
    printf 'profile-load-called\n' >> "${call_log}"
  }
  # shellcheck disable=SC2317
  ftctl_inventory_check_vm() {
    printf 'inventory-called\n' >> "${call_log}"
    printf '1 0 ok true running\n'
  }
  # shellcheck disable=SC2317
  ftctl_blockcopy_refresh_and_classify() {
    printf 'blockcopy-refresh-called\n' >> "${call_log}"
    return 12
  }

  ftctl_orchestrator_reconcile_one "${vm}"

  [[ ! -f "${call_log}" ]] || selftest_fail "manual fence pending reconcile should not probe inventory or blockcopy"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "protection_state")" "failing_over" "manual fence pending protection state"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "transport_state")" "mirroring" "manual fence pending transport state"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "fencing_state")" "required" "manual fence pending fencing state"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "last_error")" "manual_fencing_required" "manual fence pending last_error retained"
  selftest_assert_file_contains "${FTCTL_EVENTS_LOG}" '"event":"reconcile.defer"'
  selftest_assert_file_contains "${FTCTL_EVENTS_LOG}" 'manual_fence_in_progress'
)

selftest_case_global_reconcile_skips_missing_profile_state() (
  selftest_reset_env
  selftest_info "global reconcile skips stale state without profile"

  local stale_vm="stale-profile-vm"
  local live_vm="live-profile-vm"
  local call_log="${SELFTEST_ROOT}/global-reconcile-calls.log"

  ftctl_state_init_vm "${stale_vm}"
  ftctl_state_set "${stale_vm}" \
    "mode=dr" \
    "protection_state=syncing" \
    "transport_state=copying" \
    "active_side=primary"

  ftctl_state_init_vm "${live_vm}"
  ftctl_state_set "${live_vm}" \
    "mode=dr" \
    "protection_state=syncing" \
    "transport_state=copying" \
    "active_side=primary"

  cat > "$(ftctl_profile_path "${live_vm}")" <<EOF
FTCTL_PROFILE_MODE="dr"
FTCTL_PROFILE_SECONDARY_URI="qemu+ssh://10.0.0.2/system"
FTCTL_PROFILE_BACKEND_MODE="remote-nbd"
FTCTL_PROFILE_TARGET_STORAGE_SCOPE="secondary-local"
FTCTL_PROFILE_SECONDARY_TARGET_DIR="/dev/rbd/rbd/${live_vm}"
FTCTL_PROFILE_REMOTE_NBD_EXPORT_ADDR="10.0.0.2:10809"
EOF

  # shellcheck disable=SC2317
  ftctl_orchestrator_reconcile_one() {
    printf '%s\n' "${1-}" >> "${call_log}"
    return 0
  }
  # shellcheck disable=SC2317
  ftctl_orchestrator_check_vm() { return 0; }
  # shellcheck disable=SC2317
  ftctl_local_health() { return 0; }

  ftctl_orchestrator_reconcile "" "0" >/dev/null

  [[ -f "${call_log}" ]] || selftest_fail "global reconcile should process live VM"
  selftest_assert_file_not_contains "${call_log}" "${stale_vm}"
  selftest_assert_file_contains "${call_log}" "${live_vm}"
  selftest_assert_file_contains "${FTCTL_EVENTS_LOG}" 'missing_profile'
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
  printf '%s\n' '{"inventory_result":"ok"}' > "$(ftctl_state_path "${vm}").check.json"
  printf '%s\n' 'mode=cold-conversion' > "$(ftctl_state_path "${vm}").xcolo"
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
  selftest_assert_contains "${out}" '"remote_nbd_required":false' "shared unprotect does not require remote nbd"
  [[ ! -f "$(ftctl_blockcopy_state_path "${vm}")" ]] || selftest_fail "blockcopy state should be removed after release"
  [[ ! -f "$(ftctl_state_path "${vm}").check.json" ]] || selftest_fail "check state should be removed after release"
  [[ ! -f "$(ftctl_state_path "${vm}").xcolo" ]] || selftest_fail "xcolo state should be removed after release"
  selftest_assert_file_contains "${call_log}" "block-job-cancel"
  selftest_assert_file_contains "${call_log}" "query-named-block-nodes"
  selftest_assert_file_contains "${FTCTL_EVENTS_LOG}" "protection.unprotect.block-jobs-released"
  selftest_assert_file_contains "${FTCTL_EVENTS_LOG}" "protection.unprotect.qmp-destinations-released"
)

selftest_case_unprotect_releases_remote_nbd_exports() (
  selftest_reset_env
  selftest_info "unprotect releases remote-nbd exports"

  local vm="unprotect-remote-nbd"
  local call_log="${SELFTEST_ROOT}/unprotect-remote-nbd-calls.log"
  FTCTL_PROFILE_BACKEND_MODE="remote-nbd"
  FTCTL_PROFILE_REMOTE_NBD_EXPORT_NAME="${vm}"
  FTCTL_UNPROTECT_RELEASE_TIMEOUT_SEC="5"
  FTCTL_BLOCKCOPY_WAIT_TIMEOUT_SEC="1"
  ftctl_state_init_vm "${vm}"
  cat > "$(ftctl_blockcopy_state_path "${vm}")" <<EOF
vdb|/dev/rbd/rbd/${vm}-source|nbd://10.0.0.12:10823/${vm}-vdb|raw|copy|yes|/var/lib/libvirt/images/${vm}-vdb
EOF

  # shellcheck disable=SC2317
  ftctl_virsh() {
    local out_var="${2}"
    local err_var="${3}"
    local rc_var="${4}"
    local cmd="$*"
    printf '%s\n' "${cmd}" >> "${call_log}"
    printf -v "${out_var}" '%s' '{"return":[]}'
    printf -v "${err_var}" '%s' ""
    printf -v "${rc_var}" '%s' "0"
    return 0
  }
  # shellcheck disable=SC2317
  ftctl_blockcopy_stop_remote_nbd_exports() {
    printf 'stop-remote-nbd:%s\n' "$1" >> "${call_log}"
  }
  # shellcheck disable=SC2317
  ftctl_blockcopy_wait_remote_nbd_release() {
    printf 'wait-remote-nbd:%s\n' "$1" >> "${call_log}"
  }

  local out=""
  out="$(ftctl_state_unprotect_vm "${vm}" 1)"
  selftest_assert_contains "${out}" '"result":"ok"' "remote-nbd unprotect result"
  selftest_assert_contains "${out}" '"remote_nbd_required":true' "remote-nbd unprotect requires release"
  selftest_assert_contains "${out}" '"remote_nbd_released":true' "remote-nbd unprotect release result"
  selftest_assert_file_contains "${call_log}" "stop-remote-nbd:${vm}"
  selftest_assert_file_contains "${call_log}" "wait-remote-nbd:${vm}"
  selftest_assert_file_contains "${FTCTL_EVENTS_LOG}" "protection.unprotect.remote-nbd-release"
)

selftest_case_unprotect_fails_when_remote_nbd_release_fails() (
  selftest_reset_env
  selftest_info "unprotect fails when remote-nbd release fails"

  local vm="unprotect-remote-nbd-fail"
  FTCTL_PROFILE_BACKEND_MODE="remote-nbd"
  FTCTL_PROFILE_REMOTE_NBD_EXPORT_NAME="${vm}"
  FTCTL_UNPROTECT_RELEASE_TIMEOUT_SEC="1"
  FTCTL_BLOCKCOPY_WAIT_TIMEOUT_SEC="1"
  ftctl_state_init_vm "${vm}"
  cat > "$(ftctl_blockcopy_state_path "${vm}")" <<EOF
vdb|/dev/rbd/rbd/${vm}-source|nbd://10.0.0.12:10824/${vm}-vdb|raw|copy|yes|/var/lib/libvirt/images/${vm}-vdb
EOF

  # shellcheck disable=SC2317
  ftctl_virsh() {
    local out_var="${2}"
    local err_var="${3}"
    local rc_var="${4}"
    printf -v "${out_var}" '%s' '{"return":[]}'
    printf -v "${err_var}" '%s' ""
    printf -v "${rc_var}" '%s' "0"
    return 0
  }
  # shellcheck disable=SC2317
  ftctl_blockcopy_stop_remote_nbd_exports() { :; }
  # shellcheck disable=SC2317
  ftctl_blockcopy_wait_remote_nbd_release() { return 99; }

  local rc=0
  ftctl_state_unprotect_vm "${vm}" 1 >/dev/null 2>&1 || rc=$?
  [[ "${rc}" != "0" ]] || selftest_fail "unprotect should fail when remote-nbd release fails"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "last_error")" "remote_nbd_release_timeout" "remote-nbd release failure last_error"
  [[ -f "$(ftctl_blockcopy_state_path "${vm}")" ]] || selftest_fail "blockcopy state should remain after failed remote-nbd release"
)

selftest_case_unprotect_force_cleanup_warns_when_remote_nbd_release_fails() (
  selftest_reset_env
  selftest_info "unprotect force cleanup warns when remote-nbd release fails"

  local vm="unprotect-remote-nbd-force"
  FTCTL_PROFILE_BACKEND_MODE="remote-nbd"
  FTCTL_PROFILE_REMOTE_NBD_EXPORT_NAME="${vm}"
  FTCTL_UNPROTECT_RELEASE_TIMEOUT_SEC="1"
  FTCTL_BLOCKCOPY_WAIT_TIMEOUT_SEC="1"
  ftctl_state_init_vm "${vm}"
  cat > "$(ftctl_blockcopy_state_path "${vm}")" <<EOF
vdb|/dev/rbd/rbd/${vm}-source|nbd://10.0.0.12:10824/${vm}-vdb|raw|copy|yes|/var/lib/libvirt/images/${vm}-vdb
EOF

  # shellcheck disable=SC2317
  ftctl_virsh() {
    local out_var="${2}"
    local err_var="${3}"
    local rc_var="${4}"
    printf -v "${out_var}" '%s' '{"return":[]}'
    printf -v "${err_var}" '%s' ""
    printf -v "${rc_var}" '%s' "0"
    return 0
  }
  # shellcheck disable=SC2317
  ftctl_blockcopy_stop_remote_nbd_exports() { :; }
  # shellcheck disable=SC2317
  ftctl_blockcopy_wait_remote_nbd_release() { return 99; }

  local out=""
  out="$(ftctl_state_unprotect_vm "${vm}" 1 1)"
  selftest_assert_contains "${out}" '"result":"warn"' "force cleanup warning result"
  selftest_assert_contains "${out}" '"forced":true' "force cleanup forced flag"
  selftest_assert_contains "${out}" '"remote_nbd_released":false' "force cleanup records remote-nbd release failure"
  selftest_assert_contains "${out}" '"remote_nbd_release_failed"' "force cleanup warning details"
  [[ ! -f "$(ftctl_blockcopy_state_path "${vm}")" ]] || selftest_fail "blockcopy state should be removed after forced cleanup"
  selftest_assert_file_contains "${FTCTL_EVENTS_LOG}" "protection.unprotect.force-cleanup-warning"
)

selftest_case_failback_reverse_finalize() (
  selftest_reset_env
  selftest_info "failback reverse finalize"

  local vm="reverse-finalize"
  local call_log="${SELFTEST_ROOT}/reverse-finalize-calls.log"
  FTCTL_PROFILE_BACKEND_MODE="remote-nbd"
  FTCTL_PROFILE_FAILBACK_DISK_MAP="source"
  FTCTL_PROFILE_REMOTE_NBD_EXPORT_NAME="${vm}"
  ftctl_state_init_vm "${vm}"
  ftctl_state_set "${vm}" "active_side=secondary"
  ftctl_blockcopy_state_write_reverse "${vm}" \
    "vda|nbd://10.0.0.12:10820/${vm}-vda|/dev/rbd/rbd/${vm}-root|qcow2|/secondary/${vm}/root.qcow2|1024|1024"

  cat > "$(ftctl_blockcopy_progress_path "${vm}")" <<EOF
{"vm":"${vm}","direction":"reverse","disks":[{"target":"vda","offset":2048,"len":4096,"guest_virtual_size":1024,"target_size":1024}]}
EOF
  ftctl_blockcopy_reverse_cutback_ready "${vm}" || selftest_fail "reverse cutback readiness should accept guest virtual size boundary"

  # shellcheck disable=SC2317
  ftctl_blockcopy_secondary_domain_state() { return 1; }
  # shellcheck disable=SC2317
  ftctl_blockcopy_remote_target_host_user() { printf -v "$1" '%s' '10.0.0.12'; printf -v "$2" '%s' 'root'; }
  # shellcheck disable=SC2317
  ftctl_blockcopy_primary_export_addr() { printf -v "$1" '%s' '10.0.0.11'; }
  # shellcheck disable=SC2317
  ftctl_blockcopy_primary_nbd_pick_port() { printf -v "$3" '%s' '10821'; }
  # shellcheck disable=SC2317
  ftctl_blockcopy_prepare_rbd_target_for_sparse_finalize() {
    printf '%s\n' "PREPARE_SPARSE:$2:$3" >> "${call_log}"
  }
  # shellcheck disable=SC2317
  ftctl_blockcopy_primary_nbd_prepare_target() {
    printf 'PREPARE:%s:%s:%s:%s:%s\n' "$2" "$3" "$4" "$6" "$7" >> "${call_log}"
  }
  # shellcheck disable=SC2317
  ftctl_blockcopy_remote_exec() {
    local out_var="$3" err_var="$4" rc_var="$5" cmd="$6"
    printf '%s\n' "${cmd}" >> "${call_log}"
    printf -v "${out_var}" '%s' ""
    printf -v "${err_var}" '%s' ""
    printf -v "${rc_var}" '%s' "0"
  }
  # shellcheck disable=SC2317
  ftctl_blockcopy_stop_primary_reverse_nbd_exports() {
    printf '%s\n' "STOP_REVERSE_NBD" >> "${call_log}"
  }
  # shellcheck disable=SC2317
  ftctl_blockcopy_sparsify_rbd_target_after_finalize() {
    printf '%s\n' "SPARSIFY:$2:$3" >> "${call_log}"
  }

  ftctl_blockcopy_finalize_reverse_sync "${vm}"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "transport_state")" "cutback_ready" "reverse finalize transport"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "last_error")" "" "reverse finalize clears error"
  selftest_assert_file_contains "${call_log}" "qemu-img convert -p -n"
  selftest_assert_file_contains "${call_log}" '-S "4k"'
  selftest_assert_file_contains "${call_log}" "SPARSIFY:vda:/dev/rbd/rbd/${vm}-root"
  selftest_assert_file_contains "${call_log}" "nbd://10.0.0.11:10821/${vm}-vda-reverse"
  selftest_assert_file_contains "${FTCTL_EVENTS_LOG}" "reverse_sync.finalize"
)

selftest_case_failback_reverse_finalize_uses_rbd_uri_source() (
  selftest_reset_env
  selftest_info "failback reverse finalize uses stable RBD URI source"

  local vm="reverse-finalize-rbd-uri"
  local call_log="${SELFTEST_ROOT}/reverse-finalize-rbd-uri-calls.log"
  FTCTL_PROFILE_BACKEND_MODE="remote-nbd"
  FTCTL_PROFILE_FAILBACK_DISK_MAP="source"
  FTCTL_PROFILE_REMOTE_NBD_EXPORT_NAME="${vm}"
  ftctl_state_init_vm "${vm}"
  ftctl_state_set "${vm}" "active_side=secondary"
  ftctl_blockcopy_state_write_reverse "${vm}" \
    "vda|nbd://10.0.0.12:10820/${vm}-vda|/dev/rbd/rbd/${vm}-root|raw|/dev/rbd/rbd/${vm}-standby-root|1024|1024"

  # shellcheck disable=SC2317
  ftctl_blockcopy_secondary_domain_state() { return 1; }
  # shellcheck disable=SC2317
  ftctl_blockcopy_remote_target_host_user() { printf -v "$1" '%s' '10.0.0.12'; printf -v "$2" '%s' 'root'; }
  # shellcheck disable=SC2317
  ftctl_blockcopy_primary_export_addr() { printf -v "$1" '%s' '10.0.0.11'; }
  # shellcheck disable=SC2317
  ftctl_blockcopy_primary_nbd_pick_port() { printf -v "$3" '%s' '10821'; }
  # shellcheck disable=SC2317
  ftctl_blockcopy_prepare_rbd_target_for_sparse_finalize() { :; }
  # shellcheck disable=SC2317
  ftctl_blockcopy_primary_nbd_prepare_target() {
    printf 'PREPARE:%s:%s:%s:%s:%s\n' "$2" "$3" "$4" "$6" "$7" >> "${call_log}"
  }
  # shellcheck disable=SC2317
  ftctl_blockcopy_remote_exec() {
    local out_var="$3" err_var="$4" rc_var="$5" cmd="$6"
    printf '%s\n' "${cmd}" >> "${call_log}"
    printf -v "${out_var}" '%s' ""
    printf -v "${err_var}" '%s' ""
    printf -v "${rc_var}" '%s' "0"
  }
  # shellcheck disable=SC2317
  ftctl_blockcopy_stop_primary_reverse_nbd_exports() { :; }
  # shellcheck disable=SC2317
  ftctl_blockcopy_sparsify_rbd_target_after_finalize() { :; }

  ftctl_blockcopy_finalize_reverse_sync "${vm}"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "transport_state")" "cutback_ready" "reverse RBD finalize transport"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "last_error")" "" "reverse RBD finalize clears error"
  selftest_assert_file_contains "${call_log}" "secondary_path=rbd:rbd/${vm}-standby-root"
  selftest_assert_file_contains "${call_log}" "qemu-img convert -p -n"
  selftest_assert_file_contains "${FTCTL_EVENTS_LOG}" "source\":\"rbd:rbd/${vm}-standby-root"
)

selftest_case_failback_shared_reverse_finalize() (
  selftest_reset_env
  selftest_info "failback shared reverse finalize"

  local vm="shared-reverse-finalize"
  FTCTL_PROFILE_BACKEND_MODE="shared-blockcopy"
  ftctl_state_init_vm "${vm}"
  ftctl_state_set "${vm}" \
    "active_side=secondary" \
    "protection_state=failing_back" \
    "transport_state=reverse_sync_ready" \
    "last_error=reverse_sync_pending"
  ftctl_blockcopy_state_write_reverse "${vm}" \
    "vda|/dev/rbd/rbd/${vm}-standby-root|/dev/rbd/rbd/${vm}-root|raw||1024|1024"

  cat > "$(ftctl_blockcopy_progress_path "${vm}")" <<EOF
{"direction":"reverse","ready":true,"disks":[{"target":"vda","ready":true,"status":"ready","offset":1024,"len":1024,"guest_virtual_size":1024,"target_size":1024}]}
EOF

  # shellcheck disable=SC2317
  ftctl_blockcopy_secondary_domain_state() { return 1; }
  # shellcheck disable=SC2317
  ftctl_blockcopy_local_path_virtual_size_bytes() {
    printf -v "$2" '%s' "1024"
  }

  ftctl_blockcopy_finalize_reverse_sync "${vm}"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "transport_state")" "cutback_ready" "shared reverse finalize transport"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "last_error")" "" "shared reverse finalize clears error"
  [[ ! -f "$(ftctl_blockcopy_reverse_state_path "${vm}")" ]] || selftest_fail "shared reverse state should be removed after finalize"
  selftest_assert_file_contains "${FTCTL_EVENTS_LOG}" '"backend":"shared-blockcopy"'
  selftest_assert_file_contains "${FTCTL_EVENTS_LOG}" "reverse_sync.finalize"
)

selftest_case_dr_remote_failback_maps_reverse_rbd_on_primary() (
  selftest_reset_env
  selftest_info "DR remote-nbd failback maps reverse RBD destinations on primary"

  local vm="dr-remote-reverse-map"
  local call_log="${SELFTEST_ROOT}/dr-remote-reverse-map-calls.log"
  FTCTL_PROFILE_MODE="dr"
  FTCTL_PROFILE_BACKEND_MODE="remote-nbd"
  FTCTL_PROFILE_PROVISIONING_BACKEND="cloud-managed"
  FTCTL_PROFILE_PRIMARY_URI="qemu:///system"
  FTCTL_PROFILE_SECONDARY_URI="qemu+ssh://root@10.10.32.1:22/system"
  ftctl_state_init_vm "${vm}"
  ftctl_blockcopy_state_write_reverse "${vm}" \
    "sda|nbd://10.10.32.1:10816/${vm}-sda|/dev/rbd/rbd/${vm}-source-root|raw|/dev/rbd/rbd/${vm}-standby-root|1024|1024"

  # shellcheck disable=SC2317
  ftctl_blockcopy_krbd_map_local() {
    printf 'PRIMARY_LOCAL_MAP:%s\n' "$1" >> "${call_log}"
  }
  # shellcheck disable=SC2317
  ftctl_blockcopy_map_remote_krbd_path() {
    printf 'UNEXPECTED_SECONDARY_MAP:%s:%s:%s\n' "$1" "$2" "$3" >> "${call_log}"
    return 9
  }

  ftctl_blockcopy_map_reverse_krbd_destinations "${vm}"
  selftest_assert_file_contains "${call_log}" "PRIMARY_LOCAL_MAP:/dev/rbd/rbd/${vm}-source-root"
  selftest_assert_file_not_contains "${call_log}" "UNEXPECTED_SECONDARY_MAP"
  selftest_assert_file_contains "${FTCTL_EVENTS_LOG}" "reverse_sync.primary-rbd-map"
  selftest_assert_file_contains "${FTCTL_EVENTS_LOG}" "site\":\"primary"
)

selftest_case_dr_remote_reverse_plan_stores_rbd_uri_source() (
  selftest_reset_env
  selftest_info "DR remote-nbd reverse plan stores stable RBD URI source"

  local vm="dr-remote-reverse-rbd-source"
  FTCTL_PROFILE_BACKEND_MODE="remote-nbd"
  FTCTL_PROFILE_FAILBACK_DISK_MAP="source"
  ftctl_state_init_vm "${vm}"
  ftctl_blockcopy_state_write "${vm}" \
    "sda|/dev/rbd/rbd/${vm}-primary-root|nbd://10.10.32.1:10816/${vm}-sda|raw|copy|yes|/dev/rbd/rbd/${vm}-standby-root"

  # shellcheck disable=SC2317
  ftctl_blockcopy_remote_target_host_user() { printf -v "$1" '%s' '10.10.32.1'; printf -v "$2" '%s' 'root'; }
  # shellcheck disable=SC2317
  ftctl_blockcopy_remote_path_virtual_size_bytes() {
    [[ "$3" == "rbd:rbd/${vm}-standby-root" ]] || selftest_fail "reverse plan should size stable RBD URI, got $3"
    printf -v "$4" '%s' "1024"
  }
  # shellcheck disable=SC2317
  ftctl_blockcopy_local_path_virtual_size_bytes() { printf -v "$2" '%s' "1024"; }

  ftctl_blockcopy_prepare_reverse_sync_plan "${vm}"
  selftest_assert_file_contains "$(ftctl_blockcopy_reverse_state_path "${vm}")" "rbd:rbd/${vm}-standby-root|1024|1024"
)

selftest_case_dr_remote_primary_nbd_prepare_maps_unmapped_rbd() (
  selftest_reset_env
  selftest_info "DR remote-nbd primary export maps unmapped source RBD"

  local vm="dr-primary-rbd-export"
  local call_log="${SELFTEST_ROOT}/dr-primary-rbd-export-calls.log"
  FTCTL_PROFILE_MODE="dr"
  FTCTL_PROFILE_BACKEND_MODE="remote-nbd"
  FTCTL_PROFILE_PRIMARY_URI="qemu+ssh://root@10.10.22.3:22/system"
  FTCTL_PROFILE_SECONDARY_URI="qemu+ssh://root@10.10.32.1:22/system"

  # shellcheck disable=SC2317
  ftctl_blockcopy_primary_target_host_user() {
    printf -v "$1" '%s' "10.10.22.3"
    printf -v "$2" '%s' "root"
  }
  # shellcheck disable=SC2317
  ftctl_blockcopy_primary_export_addr() {
    printf -v "$1" '%s' "10.10.22.3"
  }
  # shellcheck disable=SC2317
  ftctl_blockcopy_remote_exec() {
    local out_var="$3" err_var="$4" rc_var="$5" cmd="$6"
    printf '%s\n' "${cmd}" > "${call_log}"
    printf -v "${out_var}" '%s' ""
    printf -v "${err_var}" '%s' ""
    printf -v "${rc_var}" '%s' "0"
  }

  ftctl_blockcopy_primary_nbd_prepare_target \
    "${vm}" \
    "sda" \
    "nbd://10.10.32.1:10816/${vm}-sda" \
    "raw" \
    "/dev/rbd/rbd/${vm}-source-root" \
    "${vm}-sda-reverse" \
    "10816"

  selftest_assert_file_contains "${call_log}" 'krbd_spec="rbd/dr-primary-rbd-export-source-root"'
  selftest_assert_file_contains "${call_log}" "rbd map \"\${krbd_spec}\""
  selftest_assert_file_contains "${call_log}" "reverse_primary_rbd_map_failed:/dev/rbd/rbd/dr-primary-rbd-export-source-root"
)

selftest_case_failback_reverse_progress_ready() (
  selftest_reset_env
  selftest_info "failback reverse progress ready"

  local vm="reverse-progress-ready"
  FTCTL_PROFILE_BACKEND_MODE="shared-blockcopy"
  FTCTL_PROFILE_SECONDARY_URI="qemu+ssh://10.0.0.12/system"
  ftctl_state_init_vm "${vm}"
  ftctl_state_set "${vm}" \
    "active_side=secondary" \
    "protection_state=failing_back" \
    "transport_state=reverse_syncing" \
    "secondary_vm_name=${vm}-standby" \
    "last_error=reverse_sync_pending"
  ftctl_blockcopy_state_write_reverse "${vm}" \
    "vda|/dev/rbd/rbd/${vm}-standby-root|/dev/rbd/rbd/${vm}-root|raw|||"

  # shellcheck disable=SC2317
  ftctl_blockcopy_active_domain_on_secondary() { echo "${vm}-standby"; }
  # shellcheck disable=SC2317
  ftctl_blockcopy_secondary_domain_state() { printf -v "$2" '%s' "running"; return 0; }
  # shellcheck disable=SC2317
  ftctl_blockcopy_reverse_job_query() {
    printf -v "$3" '%s' "unknown"
    printf -v "$4" '%s' "unknown"
    return 0
  }
  # shellcheck disable=SC2317
  ftctl_blockcopy_progress_refresh_from_qmp() {
    cat > "$(ftctl_blockcopy_progress_path "${vm}")" <<EOF
{"direction":"reverse","ready":true,"disks":[{"target":"vda","ready":true,"status":"ready","offset":1073741824,"len":1073741824}]}
EOF
  }

  ftctl_blockcopy_refresh_reverse_jobs "${vm}"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "transport_state")" "reverse_sync_ready" "reverse QMP progress ready transport"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "last_error")" "" "reverse QMP progress ready clears error"
  selftest_assert_file_contains "${FTCTL_EVENTS_LOG}" "reverse_sync.ready"
)

selftest_case_failback_sync_idempotent_when_reverse_ready() (
  selftest_reset_env
  selftest_info "failback-sync is idempotent when reverse sync is ready"

  local vm="reverse-sync-ready-idempotent"
  FTCTL_PROFILE_MODE="dr"
  FTCTL_PROFILE_BACKEND_MODE="remote-nbd"
  ftctl_state_init_vm "${vm}"
  ftctl_state_set "${vm}" \
    "active_side=secondary" \
    "protection_state=failing_back" \
    "transport_state=reverse_sync_ready" \
    "secondary_vm_name=${vm}-standby" \
    "last_error="
  ftctl_blockcopy_state_write_reverse "${vm}" \
    "vda|/dev/rbd/rbd/${vm}-standby-root|/dev/rbd/rbd/${vm}-root|raw|/dev/rbd/rbd/${vm}-standby-root||"

  # shellcheck disable=SC2317
  ftctl_blockcopy_start_reverse_sync() {
    selftest_fail "FAILBACK_SYNC must not restart reverse block jobs once ready"
  }

  ftctl_failback_sync_for_cloud_cutback "${vm}" "manual"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "transport_state")" "reverse_sync_ready" "ready failback-sync keeps ready transport"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "last_error")" "" "ready failback-sync keeps last_error clear"
  selftest_assert_file_contains "${FTCTL_EVENTS_LOG}" '"reverse_sync":"already_ready"'
)

selftest_case_failback_sync_recovers_failed_ready_progress() (
  selftest_reset_env
  selftest_info "failback-sync recovers reverse ready progress after failed retry"

  local vm="reverse-sync-failed-ready-progress"
  FTCTL_PROFILE_MODE="dr"
  FTCTL_PROFILE_BACKEND_MODE="remote-nbd"
  ftctl_state_init_vm "${vm}"
  ftctl_state_set "${vm}" \
    "active_side=secondary" \
    "protection_state=error" \
    "transport_state=reverse_sync_failed" \
    "secondary_vm_name=${vm}-standby" \
    "last_error=reverse_sync_start_failed"
  ftctl_blockcopy_state_write_reverse "${vm}" \
    "vda|/dev/rbd/rbd/${vm}-standby-root|/dev/rbd/rbd/${vm}-root|raw|/dev/rbd/rbd/${vm}-standby-root||"
  cat > "$(ftctl_blockcopy_progress_path "${vm}")" <<EOF
{"direction":"reverse","ready":true,"disks":[{"target":"vda","ready":true,"status":"ready","offset":1073741824,"len":1073741824}]}
EOF

  # shellcheck disable=SC2317
  ftctl_blockcopy_start_reverse_sync() {
    selftest_fail "FAILBACK_SYNC must recover ready progress instead of restarting block jobs"
  }

  ftctl_failback_sync_for_cloud_cutback "${vm}" "manual"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "protection_state")" "failing_back" "failed ready progress returns to failing_back"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "transport_state")" "reverse_sync_ready" "failed ready progress recovers ready transport"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "last_error")" "" "failed ready progress clears last_error"
  selftest_assert_file_contains "${FTCTL_EVENTS_LOG}" '"reverse_sync":"recovered_ready_from_progress"'
)

selftest_case_reconcile_preserves_cloud_failback_failure() (
  selftest_reset_env
  selftest_info "reconcile preserves cloud failback failure"

  local vm="cloud-failback-failed"
  FTCTL_PROFILE_PROVISIONING_BACKEND="cloud-managed"
  ftctl_state_init_vm "${vm}"
  ftctl_state_set "${vm}" \
    "mode=ha" \
    "active_side=secondary" \
    "protection_state=error" \
    "transport_state=reverse_sync_failed" \
    "last_error=reverse_finalize_unsupported_backend:shared-blockcopy" \
    "rearm_count=0"
  ftctl_blockcopy_state_write_reverse "${vm}" \
    "vda|/dev/rbd/rbd/${vm}-standby-root|/dev/rbd/rbd/${vm}-root|raw|||"

  # shellcheck disable=SC2317
  ftctl_profile_load_vm() { :; }
  # shellcheck disable=SC2317
  ftctl_profile_apply_cli() { :; }
  # shellcheck disable=SC2317
  ftctl_profile_validate() { :; }
  # shellcheck disable=SC2317
  ftctl_cluster_load() { :; }
  # shellcheck disable=SC2317
  ftctl_orchestrator_probe_peer() {
    printf -v "$1" '%s' "peer-1"
    printf -v "$2" '%s' "10.0.0.12"
    printf -v "$3" '%s' "reachable"
  }
  # shellcheck disable=SC2317
  ftctl_blockcopy_rearm() {
    selftest_fail "cloud-managed failed failback must not auto-rearm"
  }

  ftctl_orchestrator_reconcile_one "${vm}"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "transport_state")" "reverse_sync_failed" "failed failback transport preserved"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "rearm_count")" "0" "failed failback must not increment rearm"
  selftest_assert_file_contains "${FTCTL_EVENTS_LOG}" "cloud_failback_failure_preserved"
)

selftest_case_reconcile_waits_for_cloud_failback_after_fence_clear() (
  selftest_reset_env
  selftest_info "reconcile waits for cloud failback command after manual fence release"

  local vm="cloud-failback-await"
  FTCTL_PROFILE_PROVISIONING_BACKEND="cloud-managed"
  ftctl_state_init_vm "${vm}"
  ftctl_state_set "${vm}" \
    "mode=ha" \
    "active_side=secondary" \
    "protection_state=failed_over" \
    "transport_state=failed_over" \
    "fencing_state=clear" \
    "rearm_count=0"

  # shellcheck disable=SC2317
  ftctl_profile_load_vm() { :; }
  # shellcheck disable=SC2317
  ftctl_profile_apply_cli() { :; }
  # shellcheck disable=SC2317
  ftctl_profile_validate() { :; }
  # shellcheck disable=SC2317
  ftctl_cluster_load() { :; }
  # shellcheck disable=SC2317
  ftctl_orchestrator_probe_peer() {
    printf -v "$1" '%s' "peer-1"
    printf -v "$2" '%s' "10.0.0.12"
    printf -v "$3" '%s' "reachable"
  }
  # shellcheck disable=SC2317
  ftctl_inventory_check_vm() {
    selftest_fail "cloud-managed failback-ready state must not run inventory before FAILBACK_SYNC"
  }
  # shellcheck disable=SC2317
  ftctl_blockcopy_rearm() {
    selftest_fail "cloud-managed failback-ready state must not auto-rearm"
  }

  ftctl_orchestrator_reconcile_one "${vm}"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "protection_state")" "failed_over" "await command protection preserved"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "transport_state")" "failed_over" "await command transport preserved"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "rearm_count")" "0" "await command must not increment rearm"
  selftest_assert_file_contains "${FTCTL_EVENTS_LOG}" "failback.await-command"
)

selftest_case_reconcile_waits_for_cloud_dr_failback_after_fence_clear() (
  selftest_reset_env
  selftest_info "DR reconcile waits for cloud failback command after manual fence release"

  local vm="cloud-dr-failback-await"
  FTCTL_PROFILE_PROVISIONING_BACKEND="cloud-managed"
  ftctl_state_init_vm "${vm}"
  ftctl_state_set "${vm}" \
    "mode=dr" \
    "active_side=secondary" \
    "protection_state=failed_over" \
    "transport_state=failed_over" \
    "fencing_state=clear" \
    "rearm_count=0"

  # shellcheck disable=SC2317
  ftctl_profile_load_vm() { :; }
  # shellcheck disable=SC2317
  ftctl_profile_apply_cli() { :; }
  # shellcheck disable=SC2317
  ftctl_profile_validate() { :; }
  # shellcheck disable=SC2317
  ftctl_cluster_load() { :; }
  # shellcheck disable=SC2317
  ftctl_orchestrator_probe_peer() {
    printf -v "$1" '%s' "peer-1"
    printf -v "$2" '%s' "10.0.0.12"
    printf -v "$3" '%s' "reachable"
  }
  # shellcheck disable=SC2317
  ftctl_inventory_check_vm() {
    selftest_fail "cloud-managed DR failback-ready state must not run inventory before Cloud recovery"
  }
  # shellcheck disable=SC2317
  ftctl_blockcopy_rearm() {
    selftest_fail "cloud-managed DR failback-ready state must not auto-rearm"
  }

  ftctl_orchestrator_reconcile_one "${vm}"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "protection_state")" "failed_over" "DR await command protection preserved"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "transport_state")" "failed_over" "DR await command transport preserved"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "rearm_count")" "0" "DR await command must not increment rearm"
  selftest_assert_file_contains "${FTCTL_EVENTS_LOG}" "failback.await-command"
)

selftest_case_failback_reprotect_clears_standby_verify_state() (
  selftest_reset_env
  selftest_info "failback reprotect clears stale standby verification state"

  local vm="failback-standby-state"
  FTCTL_PROFILE_MODE="ha"
  ftctl_state_init_vm "${vm}"
  ftctl_state_set "${vm}" \
    "active_side=secondary" \
    "protection_state=failing_back" \
    "transport_state=cutback_ready" \
    "standby_state=running" \
    "standby_verify_state=running-network-unknown" \
    "standby_domain_state=running" \
    "peer_domain_expected=true"

  # shellcheck disable=SC2317
  ftctl_failback_reprotect_from_primary() {
    ftctl_state_set "$1" \
      "protection_state=protected" \
      "transport_state=mirroring"
  }

  ftctl_failback_reprotect_after_cloud_cutback "${vm}" "selftest"

  selftest_assert_eq "$(ftctl_state_get "${vm}" "active_side")" "primary" "reprotect active side"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "protection_state")" "protected" "reprotect protection state"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "transport_state")" "mirroring" "reprotect transport state"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "standby_state")" "prepared-transient" "reprotect standby state"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "standby_verify_state")" "not-defined-expected" "reprotect standby verify state"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "standby_domain_state")" "not-defined-expected" "reprotect standby domain state"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "peer_domain_expected")" "false" "reprotect peer domain expected"

  ftctl_state_set "${vm}" "standby_verify_state=running-network-unknown"
  ftctl_failback_reprotect_after_cloud_cutback "${vm}" "selftest-idempotent"
  selftest_assert_eq "$(ftctl_state_get "${vm}" "standby_verify_state")" "not-defined-expected" "idempotent reprotect standby verify state"

  local out=""
  out="$(ftctl_state_print_one "${vm}" 1)"
  selftest_assert_contains "${out}" '"standby_verify_state":"not-defined-expected"' "status emits post-failback standby verify state"
  selftest_assert_not_contains "${out}" '"standby_verify_state":"running-network-unknown"' "status omits stale standby verify state"
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
  selftest_case_dr_remote_key_connectivity_args
  selftest_case_blockcopy_missing_job_state
  selftest_case_blockcopy_progress_status
  selftest_case_shared_xml_reuse_external
  selftest_case_blockcopy_target_empty_verify
  selftest_case_blockcopy_verify_blocks_mirroring
  selftest_case_reconcile_and_fencing
  selftest_case_failover_blocks_copying_transport
  selftest_case_xcolo_and_xml
  selftest_case_xcolo_iothread_contract_validation
  selftest_case_xcolo_block_xml_preserves_disk_targets
  selftest_case_xcolo_primary_create_maps_rbd_sources
  selftest_case_xcolo_scsi_root_replace_avoids_lun_collision
  selftest_case_xcolo_block_handshake_sets_checkpoint_after_migrate
  selftest_case_xcolo_multi_disk_handshake_exports_all_disks
  selftest_case_xcolo_primary_filter_binding_blocks_migrate
  selftest_case_xcolo_baseline_seed_uses_primary_nbd_before_runtime_graph
  selftest_case_xcolo_runtime_validation_blocks_false_positive
  selftest_case_xcolo_runtime_validation_reports_primary_migrate_failure
  selftest_case_xcolo_runtime_validation_reports_pending_convergence
  selftest_case_xcolo_runtime_validation_times_out_stuck_convergence
  selftest_case_xcolo_runtime_validation_reports_one_sided_colo_role
  selftest_case_xcolo_runtime_validation_refines_missing_primary_colo_capability
  selftest_case_xcolo_runtime_validation_refines_primary_chardev_binding
  selftest_case_xcolo_runtime_validation_reports_compare_channel_failure
  selftest_case_xcolo_runtime_validation_accepts_reported_colo_role
  selftest_case_xcolo_runtime_validation_records_optional_qga
  selftest_case_xcolo_runtime_validation_requires_primary_qga
  selftest_case_xcolo_runtime_recovery_preserves_error_reason
  selftest_case_xcolo_block_handshake_failure_recovers_runtime
  selftest_case_xcolo_error_status_uses_sticky_runtime_error
  selftest_case_json_and_locking
  selftest_case_check_secondary_active_side
  selftest_case_reconcile_secondary_steady_skips_primary_disks
  selftest_case_reconcile_cloud_managed_reports_failover_candidate
  selftest_case_reconcile_defers_manual_fence_pending
  selftest_case_global_reconcile_skips_missing_profile_state
  selftest_case_unprotect_releases_blockcopy_targets
  selftest_case_unprotect_releases_remote_nbd_exports
  selftest_case_unprotect_fails_when_remote_nbd_release_fails
  selftest_case_unprotect_force_cleanup_warns_when_remote_nbd_release_fails
  selftest_case_failback_reverse_finalize
  selftest_case_failback_reverse_finalize_uses_rbd_uri_source
  selftest_case_failback_shared_reverse_finalize
  selftest_case_dr_remote_failback_maps_reverse_rbd_on_primary
  selftest_case_dr_remote_reverse_plan_stores_rbd_uri_source
  selftest_case_dr_remote_primary_nbd_prepare_maps_unmapped_rbd
  selftest_case_failback_reverse_progress_ready
  selftest_case_failback_sync_idempotent_when_reverse_ready
  selftest_case_failback_sync_recovers_failed_ready_progress
  selftest_case_reconcile_preserves_cloud_failback_failure
  selftest_case_reconcile_waits_for_cloud_failback_after_fence_clear
  selftest_case_reconcile_waits_for_cloud_dr_failback_after_fence_clear
  selftest_case_failback_reprotect_clears_standby_verify_state
  selftest_case_events_json
  selftest_info "all checks passed"
}

selftest_main "$@"
