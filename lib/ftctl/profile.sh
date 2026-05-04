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

FTCTL_PROFILE_NAME=""
FTCTL_PROFILE_MODE=""
FTCTL_PROFILE_PRIMARY_URI=""
FTCTL_PROFILE_SECONDARY_URI=""
FTCTL_PROFILE_DISK_MAP=""
FTCTL_PROFILE_BACKEND_MODE=""
FTCTL_PROFILE_PROVISIONING_BACKEND=""
FTCTL_PROFILE_PROVISIONING_STATE=""
FTCTL_PROFILE_TARGET_STORAGE_SCOPE=""
FTCTL_PROFILE_SECONDARY_VM_NAME=""
FTCTL_PROFILE_SECONDARY_TARGET_DIR=""
FTCTL_PROFILE_REMOTE_NBD_EXPORT_ADDR=""
FTCTL_PROFILE_REMOTE_NBD_EXPORT_PORT=""
FTCTL_PROFILE_REMOTE_NBD_EXPORT_NAME=""
FTCTL_PROFILE_NETWORK_MAP=""
FTCTL_PROFILE_TRANSPORT_TOLERANCE_SEC=""
FTCTL_PROFILE_AUTO_REARM=""
FTCTL_PROFILE_FENCING_POLICY=""
FTCTL_PROFILE_FENCING_SSH_USER=""
FTCTL_PROFILE_FENCING_IPMI_PRIMARY_HOST=""
FTCTL_PROFILE_FENCING_IPMI_SECONDARY_HOST=""
FTCTL_PROFILE_FENCING_IPMI_PRIMARY_PORT=""
FTCTL_PROFILE_FENCING_IPMI_SECONDARY_PORT=""
FTCTL_PROFILE_FENCING_IPMI_PRIMARY_USER=""
FTCTL_PROFILE_FENCING_IPMI_SECONDARY_USER=""
FTCTL_PROFILE_FENCING_IPMI_PRIMARY_PASSWORD=""
FTCTL_PROFILE_FENCING_IPMI_SECONDARY_PASSWORD=""
FTCTL_PROFILE_FENCING_IPMI_PRIMARY_INTERFACE=""
FTCTL_PROFILE_FENCING_IPMI_SECONDARY_INTERFACE=""
FTCTL_PROFILE_FENCING_IPMI_USER=""
FTCTL_PROFILE_FENCING_IPMI_PASSWORD=""
FTCTL_PROFILE_FENCING_IPMI_INTERFACE=""
FTCTL_PROFILE_DOMAIN_PERSISTENCE=""
FTCTL_PROFILE_RECOVERY_PRIORITY=""
FTCTL_PROFILE_QGA_POLICY=""
FTCTL_PROFILE_FAILBACK_DISK_MAP=""
FTCTL_PROFILE_XCOLO_PROXY_ENDPOINT=""
FTCTL_PROFILE_XCOLO_NBD_ENDPOINT=""
FTCTL_PROFILE_XCOLO_MIGRATE_URI=""
FTCTL_PROFILE_XCOLO_PRIMARY_DISK_NODE=""
FTCTL_PROFILE_XCOLO_PARENT_BLOCK_NODE=""
FTCTL_PROFILE_XCOLO_NBD_NODE=""
FTCTL_PROFILE_XCOLO_CHECKPOINT_DELAY=""
FTCTL_PROFILE_XCOLO_QEMU_ARGS_PRIMARY=""
FTCTL_PROFILE_XCOLO_QEMU_ARGS_SECONDARY=""

ftctl_profile_reset() {
  FTCTL_PROFILE_NAME="default"
  FTCTL_PROFILE_MODE=""
  FTCTL_PROFILE_PRIMARY_URI="${FTCTL_DEFAULT_PRIMARY_URI}"
  FTCTL_PROFILE_SECONDARY_URI="${FTCTL_DEFAULT_PEER_URI}"
  FTCTL_PROFILE_DISK_MAP="auto"
  FTCTL_PROFILE_BACKEND_MODE="shared-blockcopy"
  FTCTL_PROFILE_PROVISIONING_BACKEND="libvirt-managed"
  FTCTL_PROFILE_PROVISIONING_STATE=""
  FTCTL_PROFILE_TARGET_STORAGE_SCOPE="shared"
  FTCTL_PROFILE_SECONDARY_VM_NAME=""
  FTCTL_PROFILE_SECONDARY_TARGET_DIR=""
  FTCTL_PROFILE_REMOTE_NBD_EXPORT_ADDR=""
  FTCTL_PROFILE_REMOTE_NBD_EXPORT_PORT="auto"
  FTCTL_PROFILE_REMOTE_NBD_EXPORT_NAME=""
  FTCTL_PROFILE_NETWORK_MAP="inherit"
  FTCTL_PROFILE_TRANSPORT_TOLERANCE_SEC="${FTCTL_TRANSIENT_NET_GRACE_SEC}"
  FTCTL_PROFILE_AUTO_REARM="1"
  FTCTL_PROFILE_FENCING_POLICY="manual-block"
  FTCTL_PROFILE_FENCING_SSH_USER="${FTCTL_FENCING_SSH_USER}"
  FTCTL_PROFILE_FENCING_IPMI_PRIMARY_HOST=""
  FTCTL_PROFILE_FENCING_IPMI_SECONDARY_HOST=""
  FTCTL_PROFILE_FENCING_IPMI_PRIMARY_PORT=""
  FTCTL_PROFILE_FENCING_IPMI_SECONDARY_PORT=""
  FTCTL_PROFILE_FENCING_IPMI_PRIMARY_USER=""
  FTCTL_PROFILE_FENCING_IPMI_SECONDARY_USER=""
  FTCTL_PROFILE_FENCING_IPMI_PRIMARY_PASSWORD=""
  FTCTL_PROFILE_FENCING_IPMI_SECONDARY_PASSWORD=""
  FTCTL_PROFILE_FENCING_IPMI_PRIMARY_INTERFACE=""
  FTCTL_PROFILE_FENCING_IPMI_SECONDARY_INTERFACE=""
  FTCTL_PROFILE_FENCING_IPMI_USER="${FTCTL_FENCING_IPMI_USER}"
  FTCTL_PROFILE_FENCING_IPMI_PASSWORD="${FTCTL_FENCING_IPMI_PASSWORD}"
  FTCTL_PROFILE_FENCING_IPMI_INTERFACE="${FTCTL_FENCING_IPMI_INTERFACE}"
  FTCTL_PROFILE_DOMAIN_PERSISTENCE="auto"
  FTCTL_PROFILE_RECOVERY_PRIORITY="100"
  FTCTL_PROFILE_QGA_POLICY="optional"
  FTCTL_PROFILE_FAILBACK_DISK_MAP="${FTCTL_FAILBACK_DISK_MAP}"
  FTCTL_PROFILE_XCOLO_PROXY_ENDPOINT=""
  FTCTL_PROFILE_XCOLO_NBD_ENDPOINT=""
  FTCTL_PROFILE_XCOLO_MIGRATE_URI=""
  FTCTL_PROFILE_XCOLO_PRIMARY_DISK_NODE="parent0"
  FTCTL_PROFILE_XCOLO_PARENT_BLOCK_NODE="colo-disk0"
  FTCTL_PROFILE_XCOLO_NBD_NODE="nbd0"
  FTCTL_PROFILE_XCOLO_CHECKPOINT_DELAY="2000"
  FTCTL_PROFILE_XCOLO_QEMU_ARGS_PRIMARY=""
  FTCTL_PROFILE_XCOLO_QEMU_ARGS_SECONDARY=""
}

ftctl_profile_load_vm() {
  local vm="${1-}"
  local path
  ftctl_profile_reset
  path="${FTCTL_PROFILE_DIR}/${vm}.conf"
  if [[ -f "${path}" ]]; then
    set -a
    # shellcheck source=/dev/null
    source "${path}"
    set +a
    FTCTL_PROFILE_NAME="${FTCTL_PROFILE_NAME:-default}"
    FTCTL_PROFILE_PRIMARY_URI="${FTCTL_PROFILE_PRIMARY_URI:-${FTCTL_DEFAULT_PRIMARY_URI}}"
    FTCTL_PROFILE_SECONDARY_URI="${FTCTL_PROFILE_SECONDARY_URI:-${FTCTL_DEFAULT_PEER_URI}}"
    FTCTL_PROFILE_DISK_MAP="${FTCTL_PROFILE_DISK_MAP:-auto}"
    FTCTL_PROFILE_BACKEND_MODE="${FTCTL_PROFILE_BACKEND_MODE:-shared-blockcopy}"
    FTCTL_PROFILE_PROVISIONING_BACKEND="${FTCTL_PROFILE_PROVISIONING_BACKEND:-libvirt-managed}"
    FTCTL_PROFILE_PROVISIONING_STATE="${FTCTL_PROFILE_PROVISIONING_STATE:-}"
    FTCTL_PROFILE_TARGET_STORAGE_SCOPE="${FTCTL_PROFILE_TARGET_STORAGE_SCOPE:-shared}"
    FTCTL_PROFILE_SECONDARY_VM_NAME="${FTCTL_PROFILE_SECONDARY_VM_NAME:-${vm}-standby}"
    FTCTL_PROFILE_SECONDARY_TARGET_DIR="${FTCTL_PROFILE_SECONDARY_TARGET_DIR:-}"
    FTCTL_PROFILE_REMOTE_NBD_EXPORT_ADDR="${FTCTL_PROFILE_REMOTE_NBD_EXPORT_ADDR:-}"
    FTCTL_PROFILE_REMOTE_NBD_EXPORT_PORT="${FTCTL_PROFILE_REMOTE_NBD_EXPORT_PORT:-auto}"
    FTCTL_PROFILE_REMOTE_NBD_EXPORT_NAME="${FTCTL_PROFILE_REMOTE_NBD_EXPORT_NAME:-${vm}}"
    FTCTL_PROFILE_NETWORK_MAP="${FTCTL_PROFILE_NETWORK_MAP:-inherit}"
    FTCTL_PROFILE_TRANSPORT_TOLERANCE_SEC="${FTCTL_PROFILE_TRANSPORT_TOLERANCE_SEC:-${FTCTL_TRANSIENT_NET_GRACE_SEC}}"
    FTCTL_PROFILE_AUTO_REARM="${FTCTL_PROFILE_AUTO_REARM:-1}"
    FTCTL_PROFILE_FENCING_POLICY="${FTCTL_PROFILE_FENCING_POLICY:-manual-block}"
    FTCTL_PROFILE_FENCING_SSH_USER="${FTCTL_PROFILE_FENCING_SSH_USER:-${FTCTL_FENCING_SSH_USER}}"
    FTCTL_PROFILE_FENCING_IPMI_PRIMARY_HOST="${FTCTL_PROFILE_FENCING_IPMI_PRIMARY_HOST:-}"
    FTCTL_PROFILE_FENCING_IPMI_SECONDARY_HOST="${FTCTL_PROFILE_FENCING_IPMI_SECONDARY_HOST:-}"
    FTCTL_PROFILE_FENCING_IPMI_PRIMARY_PORT="${FTCTL_PROFILE_FENCING_IPMI_PRIMARY_PORT:-}"
    FTCTL_PROFILE_FENCING_IPMI_SECONDARY_PORT="${FTCTL_PROFILE_FENCING_IPMI_SECONDARY_PORT:-}"
    FTCTL_PROFILE_FENCING_IPMI_PRIMARY_USER="${FTCTL_PROFILE_FENCING_IPMI_PRIMARY_USER:-}"
    FTCTL_PROFILE_FENCING_IPMI_SECONDARY_USER="${FTCTL_PROFILE_FENCING_IPMI_SECONDARY_USER:-}"
    FTCTL_PROFILE_FENCING_IPMI_PRIMARY_PASSWORD="${FTCTL_PROFILE_FENCING_IPMI_PRIMARY_PASSWORD:-}"
    FTCTL_PROFILE_FENCING_IPMI_SECONDARY_PASSWORD="${FTCTL_PROFILE_FENCING_IPMI_SECONDARY_PASSWORD:-}"
    FTCTL_PROFILE_FENCING_IPMI_PRIMARY_INTERFACE="${FTCTL_PROFILE_FENCING_IPMI_PRIMARY_INTERFACE:-}"
    FTCTL_PROFILE_FENCING_IPMI_SECONDARY_INTERFACE="${FTCTL_PROFILE_FENCING_IPMI_SECONDARY_INTERFACE:-}"
    FTCTL_PROFILE_FENCING_IPMI_USER="${FTCTL_PROFILE_FENCING_IPMI_USER:-${FTCTL_FENCING_IPMI_USER}}"
    FTCTL_PROFILE_FENCING_IPMI_PASSWORD="${FTCTL_PROFILE_FENCING_IPMI_PASSWORD:-${FTCTL_FENCING_IPMI_PASSWORD}}"
    FTCTL_PROFILE_FENCING_IPMI_INTERFACE="${FTCTL_PROFILE_FENCING_IPMI_INTERFACE:-${FTCTL_FENCING_IPMI_INTERFACE}}"
    FTCTL_PROFILE_DOMAIN_PERSISTENCE="${FTCTL_PROFILE_DOMAIN_PERSISTENCE:-auto}"
    FTCTL_PROFILE_RECOVERY_PRIORITY="${FTCTL_PROFILE_RECOVERY_PRIORITY:-100}"
    FTCTL_PROFILE_QGA_POLICY="${FTCTL_PROFILE_QGA_POLICY:-optional}"
    FTCTL_PROFILE_FAILBACK_DISK_MAP="${FTCTL_PROFILE_FAILBACK_DISK_MAP:-${FTCTL_FAILBACK_DISK_MAP}}"
    FTCTL_PROFILE_XCOLO_PROXY_ENDPOINT="${FTCTL_PROFILE_XCOLO_PROXY_ENDPOINT:-}"
    FTCTL_PROFILE_XCOLO_NBD_ENDPOINT="${FTCTL_PROFILE_XCOLO_NBD_ENDPOINT:-}"
    FTCTL_PROFILE_XCOLO_MIGRATE_URI="${FTCTL_PROFILE_XCOLO_MIGRATE_URI:-}"
    FTCTL_PROFILE_XCOLO_PRIMARY_DISK_NODE="${FTCTL_PROFILE_XCOLO_PRIMARY_DISK_NODE:-parent0}"
    FTCTL_PROFILE_XCOLO_PARENT_BLOCK_NODE="${FTCTL_PROFILE_XCOLO_PARENT_BLOCK_NODE:-colo-disk0}"
    FTCTL_PROFILE_XCOLO_NBD_NODE="${FTCTL_PROFILE_XCOLO_NBD_NODE:-nbd0}"
    FTCTL_PROFILE_XCOLO_CHECKPOINT_DELAY="${FTCTL_PROFILE_XCOLO_CHECKPOINT_DELAY:-2000}"
    FTCTL_PROFILE_XCOLO_QEMU_ARGS_PRIMARY="${FTCTL_PROFILE_XCOLO_QEMU_ARGS_PRIMARY:-}"
    FTCTL_PROFILE_XCOLO_QEMU_ARGS_SECONDARY="${FTCTL_PROFILE_XCOLO_QEMU_ARGS_SECONDARY:-}"
  fi
  FTCTL_PROFILE_SECONDARY_VM_NAME="${FTCTL_PROFILE_SECONDARY_VM_NAME:-${vm}-standby}"
  FTCTL_PROFILE_REMOTE_NBD_EXPORT_NAME="${FTCTL_PROFILE_REMOTE_NBD_EXPORT_NAME:-${vm}}"
}

ftctl_profile_secondary_vm_name_resolved() {
  local vm="${1-}"
  local value="${FTCTL_PROFILE_SECONDARY_VM_NAME:-}"
  if [[ -n "${value}" ]]; then
    printf '%s\n' "${value}"
  else
    printf '%s\n' "${vm}-standby"
  fi
}

ftctl_profile_path() {
  local vm="${1-}"
  echo "${FTCTL_PROFILE_DIR}/${vm}.conf"
}

ftctl_profile_write_assignment() {
  local name="${1-}"
  local value="${2-}"
  printf '%s=' "${name}"
  printf '%q' "${value}"
  printf '\n'
}

ftctl_profile_write_vm() {
  local vm="${1-}"
  local mode="${2-}"
  local peer_uri="${3-}"
  local profile_name="${4-}"
  local disk_map="${5-}"
  local backend_mode="${6-}"
  local provisioning_backend="${7-}"
  local provisioning_state="${8-}"
  local target_storage_scope="${9-}"
  local secondary_vm_name="${10-}"
  local fencing_policy="${11-}"
  local secondary_target_dir="${12-}"
  local remote_nbd_export_addr="${13-}"
  local xcolo_proxy_endpoint="${14-}"
  local xcolo_nbd_endpoint="${15-}"
  local xcolo_migrate_uri="${16-}"
  local fencing_ipmi_primary_host="${17-}"
  local fencing_ipmi_primary_port="${18-}"
  local fencing_ipmi_primary_user="${19-}"
  local fencing_ipmi_primary_password="${20-}"
  local fencing_ipmi_primary_interface="${21-}"
  local fencing_ipmi_secondary_host="${22-}"
  local fencing_ipmi_secondary_port="${23-}"
  local fencing_ipmi_secondary_user="${24-}"
  local fencing_ipmi_secondary_password="${25-}"
  local fencing_ipmi_secondary_interface="${26-}"
  local path tmp

  [[ -n "${vm}" ]] || {
    echo "ERROR: vm is required" >&2
    return 2
  }
  [[ -n "${mode}" ]] || {
    echo "ERROR: mode is required" >&2
    return 2
  }
  [[ -n "${peer_uri}" ]] || {
    echo "ERROR: peer uri is required" >&2
    return 2
  }

  ftctl_profile_reset
  FTCTL_PROFILE_MODE="${mode}"
  FTCTL_PROFILE_SECONDARY_URI="${peer_uri}"
  [[ -n "${profile_name}" ]] && FTCTL_PROFILE_NAME="${profile_name}"
  [[ -n "${disk_map}" ]] && FTCTL_PROFILE_DISK_MAP="${disk_map}"
  [[ -n "${backend_mode}" ]] && FTCTL_PROFILE_BACKEND_MODE="${backend_mode}"
  [[ -n "${provisioning_backend}" ]] && FTCTL_PROFILE_PROVISIONING_BACKEND="${provisioning_backend}"
  [[ -n "${provisioning_state}" ]] && FTCTL_PROFILE_PROVISIONING_STATE="${provisioning_state}"
  [[ -n "${target_storage_scope}" ]] && FTCTL_PROFILE_TARGET_STORAGE_SCOPE="${target_storage_scope}"
  [[ -n "${secondary_vm_name}" ]] && FTCTL_PROFILE_SECONDARY_VM_NAME="${secondary_vm_name}"
  [[ -n "${fencing_policy}" ]] && FTCTL_PROFILE_FENCING_POLICY="${fencing_policy}"
  [[ -n "${secondary_target_dir}" ]] && FTCTL_PROFILE_SECONDARY_TARGET_DIR="${secondary_target_dir}"
  [[ -n "${remote_nbd_export_addr}" ]] && FTCTL_PROFILE_REMOTE_NBD_EXPORT_ADDR="${remote_nbd_export_addr}"
  FTCTL_PROFILE_REMOTE_NBD_EXPORT_NAME="${FTCTL_PROFILE_REMOTE_NBD_EXPORT_NAME:-${vm}}"
  [[ -n "${xcolo_proxy_endpoint}" ]] && FTCTL_PROFILE_XCOLO_PROXY_ENDPOINT="${xcolo_proxy_endpoint}"
  [[ -n "${xcolo_nbd_endpoint}" ]] && FTCTL_PROFILE_XCOLO_NBD_ENDPOINT="${xcolo_nbd_endpoint}"
  [[ -n "${xcolo_migrate_uri}" ]] && FTCTL_PROFILE_XCOLO_MIGRATE_URI="${xcolo_migrate_uri}"
  [[ -n "${fencing_ipmi_primary_host}" ]] && FTCTL_PROFILE_FENCING_IPMI_PRIMARY_HOST="${fencing_ipmi_primary_host}"
  [[ -n "${fencing_ipmi_primary_port}" ]] && FTCTL_PROFILE_FENCING_IPMI_PRIMARY_PORT="${fencing_ipmi_primary_port}"
  [[ -n "${fencing_ipmi_primary_user}" ]] && FTCTL_PROFILE_FENCING_IPMI_PRIMARY_USER="${fencing_ipmi_primary_user}"
  [[ -n "${fencing_ipmi_primary_password}" ]] && FTCTL_PROFILE_FENCING_IPMI_PRIMARY_PASSWORD="${fencing_ipmi_primary_password}"
  [[ -n "${fencing_ipmi_primary_interface}" ]] && FTCTL_PROFILE_FENCING_IPMI_PRIMARY_INTERFACE="${fencing_ipmi_primary_interface}"
  [[ -n "${fencing_ipmi_secondary_host}" ]] && FTCTL_PROFILE_FENCING_IPMI_SECONDARY_HOST="${fencing_ipmi_secondary_host}"
  [[ -n "${fencing_ipmi_secondary_port}" ]] && FTCTL_PROFILE_FENCING_IPMI_SECONDARY_PORT="${fencing_ipmi_secondary_port}"
  [[ -n "${fencing_ipmi_secondary_user}" ]] && FTCTL_PROFILE_FENCING_IPMI_SECONDARY_USER="${fencing_ipmi_secondary_user}"
  [[ -n "${fencing_ipmi_secondary_password}" ]] && FTCTL_PROFILE_FENCING_IPMI_SECONDARY_PASSWORD="${fencing_ipmi_secondary_password}"
  [[ -n "${fencing_ipmi_secondary_interface}" ]] && FTCTL_PROFILE_FENCING_IPMI_SECONDARY_INTERFACE="${fencing_ipmi_secondary_interface}"
  ftctl_profile_validate "${vm}" || return $?

  path="$(ftctl_profile_path "${vm}")"
  ftctl_ensure_dir "$(dirname "${path}")" "0755"
  tmp="$(mktemp -t ftctl.profile.XXXXXX)"
  {
    printf 'FTCTL_PROFILE_NAME="%s"\n' "${FTCTL_PROFILE_NAME}"
    printf 'FTCTL_PROFILE_MODE="%s"\n' "${FTCTL_PROFILE_MODE}"
    printf 'FTCTL_PROFILE_SECONDARY_URI="%s"\n' "${FTCTL_PROFILE_SECONDARY_URI}"
    if [[ -n "${disk_map}" ]]; then
      printf 'FTCTL_PROFILE_DISK_MAP="%s"\n' "${FTCTL_PROFILE_DISK_MAP}"
    fi
    if [[ -n "${backend_mode}" ]]; then
      printf 'FTCTL_PROFILE_BACKEND_MODE="%s"\n' "${FTCTL_PROFILE_BACKEND_MODE}"
    fi
    if [[ -n "${provisioning_backend}" ]]; then
      printf 'FTCTL_PROFILE_PROVISIONING_BACKEND="%s"\n' "${FTCTL_PROFILE_PROVISIONING_BACKEND}"
    fi
    if [[ -n "${provisioning_state}" ]]; then
      printf 'FTCTL_PROFILE_PROVISIONING_STATE="%s"\n' "${FTCTL_PROFILE_PROVISIONING_STATE}"
    fi
    if [[ -n "${target_storage_scope}" ]]; then
      printf 'FTCTL_PROFILE_TARGET_STORAGE_SCOPE="%s"\n' "${FTCTL_PROFILE_TARGET_STORAGE_SCOPE}"
    fi
    if [[ -n "${secondary_vm_name}" ]]; then
      printf 'FTCTL_PROFILE_SECONDARY_VM_NAME="%s"\n' "${FTCTL_PROFILE_SECONDARY_VM_NAME}"
    fi
    if [[ -n "${fencing_policy}" ]]; then
      printf 'FTCTL_PROFILE_FENCING_POLICY="%s"\n' "${FTCTL_PROFILE_FENCING_POLICY}"
    fi
    if [[ -n "${fencing_ipmi_primary_host}" ]]; then
      ftctl_profile_write_assignment "FTCTL_PROFILE_FENCING_IPMI_PRIMARY_HOST" "${FTCTL_PROFILE_FENCING_IPMI_PRIMARY_HOST}"
    fi
    if [[ -n "${fencing_ipmi_primary_port}" ]]; then
      ftctl_profile_write_assignment "FTCTL_PROFILE_FENCING_IPMI_PRIMARY_PORT" "${FTCTL_PROFILE_FENCING_IPMI_PRIMARY_PORT}"
    fi
    if [[ -n "${fencing_ipmi_primary_user}" ]]; then
      ftctl_profile_write_assignment "FTCTL_PROFILE_FENCING_IPMI_PRIMARY_USER" "${FTCTL_PROFILE_FENCING_IPMI_PRIMARY_USER}"
    fi
    if [[ -n "${fencing_ipmi_primary_password}" ]]; then
      ftctl_profile_write_assignment "FTCTL_PROFILE_FENCING_IPMI_PRIMARY_PASSWORD" "${FTCTL_PROFILE_FENCING_IPMI_PRIMARY_PASSWORD}"
    fi
    if [[ -n "${fencing_ipmi_primary_interface}" ]]; then
      ftctl_profile_write_assignment "FTCTL_PROFILE_FENCING_IPMI_PRIMARY_INTERFACE" "${FTCTL_PROFILE_FENCING_IPMI_PRIMARY_INTERFACE}"
    fi
    if [[ -n "${fencing_ipmi_secondary_host}" ]]; then
      ftctl_profile_write_assignment "FTCTL_PROFILE_FENCING_IPMI_SECONDARY_HOST" "${FTCTL_PROFILE_FENCING_IPMI_SECONDARY_HOST}"
    fi
    if [[ -n "${fencing_ipmi_secondary_port}" ]]; then
      ftctl_profile_write_assignment "FTCTL_PROFILE_FENCING_IPMI_SECONDARY_PORT" "${FTCTL_PROFILE_FENCING_IPMI_SECONDARY_PORT}"
    fi
    if [[ -n "${fencing_ipmi_secondary_user}" ]]; then
      ftctl_profile_write_assignment "FTCTL_PROFILE_FENCING_IPMI_SECONDARY_USER" "${FTCTL_PROFILE_FENCING_IPMI_SECONDARY_USER}"
    fi
    if [[ -n "${fencing_ipmi_secondary_password}" ]]; then
      ftctl_profile_write_assignment "FTCTL_PROFILE_FENCING_IPMI_SECONDARY_PASSWORD" "${FTCTL_PROFILE_FENCING_IPMI_SECONDARY_PASSWORD}"
    fi
    if [[ -n "${fencing_ipmi_secondary_interface}" ]]; then
      ftctl_profile_write_assignment "FTCTL_PROFILE_FENCING_IPMI_SECONDARY_INTERFACE" "${FTCTL_PROFILE_FENCING_IPMI_SECONDARY_INTERFACE}"
    fi
    if [[ -n "${secondary_target_dir}" ]]; then
      printf 'FTCTL_PROFILE_SECONDARY_TARGET_DIR="%s"\n' "${FTCTL_PROFILE_SECONDARY_TARGET_DIR}"
    fi
    if [[ -n "${remote_nbd_export_addr}" ]]; then
      printf 'FTCTL_PROFILE_REMOTE_NBD_EXPORT_ADDR="%s"\n' "${FTCTL_PROFILE_REMOTE_NBD_EXPORT_ADDR}"
      printf 'FTCTL_PROFILE_REMOTE_NBD_EXPORT_NAME="%s"\n' "${FTCTL_PROFILE_REMOTE_NBD_EXPORT_NAME}"
    fi
    if [[ -n "${xcolo_proxy_endpoint}" ]]; then
      printf 'FTCTL_PROFILE_XCOLO_PROXY_ENDPOINT="%s"\n' "${FTCTL_PROFILE_XCOLO_PROXY_ENDPOINT}"
    fi
    if [[ -n "${xcolo_nbd_endpoint}" ]]; then
      printf 'FTCTL_PROFILE_XCOLO_NBD_ENDPOINT="%s"\n' "${FTCTL_PROFILE_XCOLO_NBD_ENDPOINT}"
    fi
    if [[ -n "${xcolo_migrate_uri}" ]]; then
      printf 'FTCTL_PROFILE_XCOLO_MIGRATE_URI="%s"\n' "${FTCTL_PROFILE_XCOLO_MIGRATE_URI}"
    fi
  } > "${tmp}"
  mv -f "${tmp}" "${path}"
  chmod 0600 "${path}" 2>/dev/null || true
  ftctl_log_event "profile" "profile.write" "ok" "${vm}" "" \
    "mode=${FTCTL_PROFILE_MODE} peer=${FTCTL_PROFILE_SECONDARY_URI}"
}

ftctl_profile_remove_vm() {
  local vm="${1-}"
  local path
  path="$(ftctl_profile_path "${vm}")"
  rm -f "${path}"
  ftctl_log_event "profile" "profile.remove" "ok" "${vm}" "" "path=${path}"
}

ftctl_profile_show_vm() {
  local vm="${1-}"
  local json="${2-0}"
  local path
  path="$(ftctl_profile_path "${vm}")"
  [[ -f "${path}" ]] || {
    if [[ "${json}" == "1" ]]; then
      printf '{"command":"config.profile-show","result":"not_found","vm":"%s"}\n' "${vm}"
    else
      printf '%s: profile not found\n' "${vm}"
    fi
    return 1
  }

  ftctl_profile_load_vm "${vm}"
  if [[ "${json}" == "1" ]]; then
    printf '{"command":"config.profile-show","result":"ok","vm":"%s","path":"%s","profile":"%s","mode":"%s","peer_uri":"%s","disk_map":"%s","backend_mode":"%s","provisioning_backend":"%s","provisioning_state":"%s","target_storage_scope":"%s","secondary_vm_name":"%s","fencing_policy":"%s","secondary_target_dir":"%s","remote_nbd_export_addr":"%s","xcolo_proxy_endpoint":"%s","xcolo_nbd_endpoint":"%s","xcolo_migrate_uri":"%s"}\n' \
      "${vm}" \
      "$(ftctl__json_escape "${path}")" \
      "$(ftctl__json_escape "${FTCTL_PROFILE_NAME}")" \
      "$(ftctl__json_escape "${FTCTL_PROFILE_MODE}")" \
      "$(ftctl__json_escape "${FTCTL_PROFILE_SECONDARY_URI}")" \
      "$(ftctl__json_escape "${FTCTL_PROFILE_DISK_MAP}")" \
      "$(ftctl__json_escape "${FTCTL_PROFILE_BACKEND_MODE}")" \
      "$(ftctl__json_escape "${FTCTL_PROFILE_PROVISIONING_BACKEND}")" \
      "$(ftctl__json_escape "${FTCTL_PROFILE_PROVISIONING_STATE}")" \
      "$(ftctl__json_escape "${FTCTL_PROFILE_TARGET_STORAGE_SCOPE}")" \
      "$(ftctl__json_escape "${FTCTL_PROFILE_SECONDARY_VM_NAME}")" \
      "$(ftctl__json_escape "${FTCTL_PROFILE_FENCING_POLICY}")" \
      "$(ftctl__json_escape "${FTCTL_PROFILE_SECONDARY_TARGET_DIR}")" \
      "$(ftctl__json_escape "${FTCTL_PROFILE_REMOTE_NBD_EXPORT_ADDR}")" \
      "$(ftctl__json_escape "${FTCTL_PROFILE_XCOLO_PROXY_ENDPOINT}")" \
      "$(ftctl__json_escape "${FTCTL_PROFILE_XCOLO_NBD_ENDPOINT}")" \
      "$(ftctl__json_escape "${FTCTL_PROFILE_XCOLO_MIGRATE_URI}")"
  else
    printf '%s profile=%s mode=%s peer_uri=%s disk_map=%s backend_mode=%s provisioning_backend=%s provisioning_state=%s target_storage_scope=%s secondary_vm_name=%s fencing_policy=%s secondary_target_dir=%s remote_nbd_export_addr=%s xcolo_proxy_endpoint=%s xcolo_nbd_endpoint=%s xcolo_migrate_uri=%s\n' \
      "${vm}" \
      "${FTCTL_PROFILE_NAME}" \
      "${FTCTL_PROFILE_MODE}" \
      "${FTCTL_PROFILE_SECONDARY_URI}" \
      "${FTCTL_PROFILE_DISK_MAP}" \
      "${FTCTL_PROFILE_BACKEND_MODE}" \
      "${FTCTL_PROFILE_PROVISIONING_BACKEND}" \
      "${FTCTL_PROFILE_PROVISIONING_STATE}" \
      "${FTCTL_PROFILE_TARGET_STORAGE_SCOPE}" \
      "${FTCTL_PROFILE_SECONDARY_VM_NAME}" \
      "${FTCTL_PROFILE_FENCING_POLICY}" \
      "${FTCTL_PROFILE_SECONDARY_TARGET_DIR}" \
      "${FTCTL_PROFILE_REMOTE_NBD_EXPORT_ADDR}" \
      "${FTCTL_PROFILE_XCOLO_PROXY_ENDPOINT}" \
      "${FTCTL_PROFILE_XCOLO_NBD_ENDPOINT}" \
      "${FTCTL_PROFILE_XCOLO_MIGRATE_URI}"
  fi
}

ftctl_profile_apply_cli() {
  local vm="${1-}"
  local mode="${2-}"
  local peer="${3-}"
  local profile="${4-}"
  [[ -n "${profile}" ]] && FTCTL_PROFILE_NAME="${profile}"
  [[ -n "${mode}" ]] && FTCTL_PROFILE_MODE="${mode}"
  [[ -n "${peer}" ]] && FTCTL_PROFILE_SECONDARY_URI="${peer}"
  [[ -n "${FTCTL_PROFILE_MODE}" ]] || FTCTL_PROFILE_MODE="ha"
  case "${FTCTL_PROFILE_MODE}" in
    ha|dr|ft) ;;
    *)
      echo "ERROR: invalid mode: ${FTCTL_PROFILE_MODE}" >&2
      return 2
      ;;
  esac
  ftctl_log_event "profile" "profile.load" "ok" "${vm}" "" \
    "mode=${FTCTL_PROFILE_MODE} profile=${FTCTL_PROFILE_NAME} peer=${FTCTL_PROFILE_SECONDARY_URI}"
}

ftctl_profile__is_uint() {
  local value="${1-}"
  [[ "${value}" =~ ^[0-9]+$ ]]
}

ftctl_profile__validate_bool() {
  local name="${1-}"
  local value="${2-}"
  case "${value}" in
    0|1) return 0 ;;
    *)
      echo "ERROR: ${name} must be 0 or 1: ${value}" >&2
      return 2
      ;;
  esac
}

ftctl_profile__validate_choice() {
  local name="${1-}"
  local value="${2-}"
  shift 2
  local allowed
  for allowed in "$@"; do
    [[ "${value}" == "${allowed}" ]] && return 0
  done
  echo "ERROR: ${name} has invalid value: ${value}" >&2
  return 2
}

ftctl_profile__validate_nonempty() {
  local name="${1-}"
  local value="${2-}"
  [[ -n "${value}" ]] && return 0
  echo "ERROR: ${name} is required" >&2
  return 2
}

ftctl_profile__validate_disk_map() {
  local value="${1-}"
  local re='^[^=;]+=[^=;]+(;[^=;]+=[^=;]+)*$'
  [[ -n "${value}" ]] || {
    echo "ERROR: FTCTL_PROFILE_DISK_MAP is required" >&2
    return 2
  }
  if [[ "${value}" == "auto" ]]; then
    return 0
  fi
  [[ "${value}" =~ ${re} ]] && return 0
  echo "ERROR: FTCTL_PROFILE_DISK_MAP must be 'auto' or target=path[;target=path...]" >&2
  return 2
}

ftctl_profile__validate_network_map() {
  local value="${1-}"
  local re='^[^=;]+=[^=;]+(;[^=;]+=[^=;]+)*$'
  [[ -n "${value}" ]] || {
    echo "ERROR: FTCTL_PROFILE_NETWORK_MAP is required" >&2
    return 2
  }
  if [[ "${value}" == "inherit" ]]; then
    return 0
  fi
  [[ "${value}" =~ ${re} ]] && return 0
  echo "ERROR: FTCTL_PROFILE_NETWORK_MAP must be 'inherit' or guestnet=hostnet[;guestnet=hostnet...]" >&2
  return 2
}

ftctl_profile_validate() {
  local vm="${1-}"

  ftctl_profile__validate_choice "FTCTL_PROFILE_MODE" "${FTCTL_PROFILE_MODE}" ha dr ft || return 2
  ftctl_profile__validate_nonempty "FTCTL_PROFILE_PRIMARY_URI" "${FTCTL_PROFILE_PRIMARY_URI}" || return 2
  ftctl_profile__validate_nonempty "FTCTL_PROFILE_SECONDARY_URI" "${FTCTL_PROFILE_SECONDARY_URI}" || return 2
  ftctl_profile__validate_disk_map "${FTCTL_PROFILE_DISK_MAP}" || return 2
  ftctl_profile__validate_choice "FTCTL_PROFILE_BACKEND_MODE" "${FTCTL_PROFILE_BACKEND_MODE}" \
    shared-blockcopy remote-nbd || return 2
  ftctl_profile__validate_choice "FTCTL_PROFILE_PROVISIONING_BACKEND" "${FTCTL_PROFILE_PROVISIONING_BACKEND}" \
    libvirt-managed cloud-managed || return 2
  ftctl_profile__validate_choice "FTCTL_PROFILE_TARGET_STORAGE_SCOPE" "${FTCTL_PROFILE_TARGET_STORAGE_SCOPE}" \
    shared secondary-local || return 2
  ftctl_profile__validate_nonempty "FTCTL_PROFILE_SECONDARY_VM_NAME" "${FTCTL_PROFILE_SECONDARY_VM_NAME}" || return 2
  ftctl_profile__validate_network_map "${FTCTL_PROFILE_NETWORK_MAP}" || return 2
  ftctl_profile__validate_choice "FTCTL_PROFILE_FENCING_POLICY" "${FTCTL_PROFILE_FENCING_POLICY}" \
    manual-block ssh peer-virsh-destroy ipmi redfish || return 2
  ftctl_profile__validate_nonempty "FTCTL_PROFILE_FENCING_SSH_USER" "${FTCTL_PROFILE_FENCING_SSH_USER}" || return 2
  ftctl_profile__validate_choice "FTCTL_PROFILE_DOMAIN_PERSISTENCE" "${FTCTL_PROFILE_DOMAIN_PERSISTENCE}" \
    auto yes no || return 2
  ftctl_profile__validate_choice "FTCTL_PROFILE_QGA_POLICY" "${FTCTL_PROFILE_QGA_POLICY}" \
    optional required off || return 2
  ftctl_profile__validate_bool "FTCTL_PROFILE_AUTO_REARM" "${FTCTL_PROFILE_AUTO_REARM}" || return 2

  ftctl_profile__is_uint "${FTCTL_PROFILE_TRANSPORT_TOLERANCE_SEC}" || {
    echo "ERROR: FTCTL_PROFILE_TRANSPORT_TOLERANCE_SEC must be an unsigned integer" >&2
    return 2
  }
  ftctl_profile__is_uint "${FTCTL_PROFILE_RECOVERY_PRIORITY}" || {
    echo "ERROR: FTCTL_PROFILE_RECOVERY_PRIORITY must be an unsigned integer" >&2
    return 2
  }
  if [[ "${FTCTL_PROFILE_REMOTE_NBD_EXPORT_PORT}" != "auto" ]]; then
    ftctl_profile__is_uint "${FTCTL_PROFILE_REMOTE_NBD_EXPORT_PORT}" || {
      echo "ERROR: FTCTL_PROFILE_REMOTE_NBD_EXPORT_PORT must be 'auto' or an unsigned integer" >&2
      return 2
    }
  fi

  case "${FTCTL_PROFILE_BACKEND_MODE}" in
    shared-blockcopy)
      [[ "${FTCTL_PROFILE_TARGET_STORAGE_SCOPE}" == "shared" ]] || {
        echo "ERROR: shared-blockcopy requires FTCTL_PROFILE_TARGET_STORAGE_SCOPE=shared" >&2
        return 2
      }
      ;;
    remote-nbd)
      [[ "${FTCTL_PROFILE_TARGET_STORAGE_SCOPE}" == "secondary-local" ]] || {
        echo "ERROR: remote-nbd requires FTCTL_PROFILE_TARGET_STORAGE_SCOPE=secondary-local" >&2
        return 2
      }
      ftctl_profile__validate_nonempty "FTCTL_PROFILE_SECONDARY_TARGET_DIR" "${FTCTL_PROFILE_SECONDARY_TARGET_DIR}" || return 2
      ftctl_profile__validate_nonempty "FTCTL_PROFILE_REMOTE_NBD_EXPORT_ADDR" "${FTCTL_PROFILE_REMOTE_NBD_EXPORT_ADDR}" || return 2
      ftctl_profile__validate_nonempty "FTCTL_PROFILE_REMOTE_NBD_EXPORT_NAME" "${FTCTL_PROFILE_REMOTE_NBD_EXPORT_NAME}" || return 2
      ;;
  esac

  case "${FTCTL_PROFILE_FENCING_POLICY}" in
    ipmi)
      ftctl_profile__validate_nonempty "FTCTL_PROFILE_FENCING_IPMI_PRIMARY_HOST" "${FTCTL_PROFILE_FENCING_IPMI_PRIMARY_HOST}" || return 2
      ftctl_profile__validate_nonempty "FTCTL_PROFILE_FENCING_IPMI_SECONDARY_HOST" "${FTCTL_PROFILE_FENCING_IPMI_SECONDARY_HOST}" || return 2
      ftctl_profile__validate_nonempty "FTCTL_PROFILE_FENCING_IPMI_PRIMARY_USER" "${FTCTL_PROFILE_FENCING_IPMI_PRIMARY_USER:-${FTCTL_PROFILE_FENCING_IPMI_USER}}" || return 2
      ftctl_profile__validate_nonempty "FTCTL_PROFILE_FENCING_IPMI_PRIMARY_PASSWORD" "${FTCTL_PROFILE_FENCING_IPMI_PRIMARY_PASSWORD:-${FTCTL_PROFILE_FENCING_IPMI_PASSWORD}}" || return 2
      ftctl_profile__validate_nonempty "FTCTL_PROFILE_FENCING_IPMI_PRIMARY_INTERFACE" "${FTCTL_PROFILE_FENCING_IPMI_PRIMARY_INTERFACE:-${FTCTL_PROFILE_FENCING_IPMI_INTERFACE}}" || return 2
      ftctl_profile__validate_nonempty "FTCTL_PROFILE_FENCING_IPMI_SECONDARY_USER" "${FTCTL_PROFILE_FENCING_IPMI_SECONDARY_USER:-${FTCTL_PROFILE_FENCING_IPMI_USER}}" || return 2
      ftctl_profile__validate_nonempty "FTCTL_PROFILE_FENCING_IPMI_SECONDARY_PASSWORD" "${FTCTL_PROFILE_FENCING_IPMI_SECONDARY_PASSWORD:-${FTCTL_PROFILE_FENCING_IPMI_PASSWORD}}" || return 2
      ftctl_profile__validate_nonempty "FTCTL_PROFILE_FENCING_IPMI_SECONDARY_INTERFACE" "${FTCTL_PROFILE_FENCING_IPMI_SECONDARY_INTERFACE:-${FTCTL_PROFILE_FENCING_IPMI_INTERFACE}}" || return 2
      if [[ -n "${FTCTL_PROFILE_FENCING_IPMI_PRIMARY_PORT}" ]]; then
        ftctl_profile__is_uint "${FTCTL_PROFILE_FENCING_IPMI_PRIMARY_PORT}" || {
          echo "ERROR: FTCTL_PROFILE_FENCING_IPMI_PRIMARY_PORT must be an unsigned integer" >&2
          return 2
        }
      fi
      if [[ -n "${FTCTL_PROFILE_FENCING_IPMI_SECONDARY_PORT}" ]]; then
        ftctl_profile__is_uint "${FTCTL_PROFILE_FENCING_IPMI_SECONDARY_PORT}" || {
          echo "ERROR: FTCTL_PROFILE_FENCING_IPMI_SECONDARY_PORT must be an unsigned integer" >&2
          return 2
        }
      fi
      ;;
  esac

  case "${FTCTL_PROFILE_MODE}" in
    ha|dr)
      if [[ -n "${FTCTL_PROFILE_XCOLO_PROXY_ENDPOINT}" || -n "${FTCTL_PROFILE_XCOLO_NBD_ENDPOINT}" ]]; then
        echo "ERROR: FTCTL_PROFILE_XCOLO_* fields are only valid for ft mode" >&2
        return 2
      fi
      ;;
    ft)
      ftctl_profile__validate_nonempty "FTCTL_PROFILE_XCOLO_PROXY_ENDPOINT" "${FTCTL_PROFILE_XCOLO_PROXY_ENDPOINT}" || return 2
      ftctl_profile__validate_nonempty "FTCTL_PROFILE_XCOLO_NBD_ENDPOINT" "${FTCTL_PROFILE_XCOLO_NBD_ENDPOINT}" || return 2
      ftctl_profile__validate_nonempty "FTCTL_PROFILE_XCOLO_MIGRATE_URI" "${FTCTL_PROFILE_XCOLO_MIGRATE_URI}" || return 2
      ftctl_profile__validate_nonempty "FTCTL_PROFILE_XCOLO_PRIMARY_DISK_NODE" "${FTCTL_PROFILE_XCOLO_PRIMARY_DISK_NODE}" || return 2
      ftctl_profile__validate_nonempty "FTCTL_PROFILE_XCOLO_PARENT_BLOCK_NODE" "${FTCTL_PROFILE_XCOLO_PARENT_BLOCK_NODE}" || return 2
      ftctl_profile__validate_nonempty "FTCTL_PROFILE_XCOLO_NBD_NODE" "${FTCTL_PROFILE_XCOLO_NBD_NODE}" || return 2
      ftctl_profile__is_uint "${FTCTL_PROFILE_XCOLO_CHECKPOINT_DELAY}" || {
        echo "ERROR: FTCTL_PROFILE_XCOLO_CHECKPOINT_DELAY must be an unsigned integer" >&2
        return 2
      }
      ;;
  esac

  if [[ "${FTCTL_PROFILE_MODE}" == "ha" || "${FTCTL_PROFILE_MODE}" == "dr" ]]; then
    if [[ "${FTCTL_PROFILE_SECONDARY_VM_NAME}" == "${vm}" ]]; then
      echo "ERROR: FTCTL_PROFILE_SECONDARY_VM_NAME must differ from the primary VM name for HA/DR" >&2
      return 2
    fi
  fi

  ftctl_log_event "profile" "profile.validate" "ok" "${vm}" "" \
    "mode=${FTCTL_PROFILE_MODE} backend=${FTCTL_PROFILE_BACKEND_MODE} target_scope=${FTCTL_PROFILE_TARGET_STORAGE_SCOPE} fencing=${FTCTL_PROFILE_FENCING_POLICY} qga=${FTCTL_PROFILE_QGA_POLICY} auto_rearm=${FTCTL_PROFILE_AUTO_REARM}"
}

ftctl_profile_lookup_map_value() {
  local map_value="${1-}"
  local key="${2-}"
  local entry lhs rhs
  [[ -n "${map_value}" && -n "${key}" ]] || return 1
  for entry in ${map_value//;/ }; do
    lhs="${entry%%=*}"
    rhs="${entry#*=}"
    if [[ "${lhs}" == "${key}" && "${rhs}" != "${lhs}" ]]; then
      printf '%s\n' "${rhs}"
      return 0
    fi
  done
  return 1
}
