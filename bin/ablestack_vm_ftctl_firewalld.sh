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

CONFIG_PATH="/etc/ablestack/ablestack-vm-ftctl.conf"
SERVICE_NAME="ablestack-vm-ftctl-remote-nbd"
SERVICE_DIR="/etc/firewalld/services"
SERVICE_PATH="${SERVICE_DIR}/${SERVICE_NAME}.xml"
ACTION="${1-apply}"

FTCTL_REMOTE_NBD_PORT_BASE="10809"
FTCTL_REMOTE_NBD_PORT_COUNT="32"
FTCTL_XCOLO_PROXY_PORT="9000"
FTCTL_XCOLO_MIGRATE_PORT="9998"
FTCTL_XCOLO_MIRROR_PORT="9003"
FTCTL_XCOLO_COMPARE_PORT="9004"
FTCTL_XCOLO_AUTO_PORT_BASE="9100"
FTCTL_XCOLO_AUTO_PORT_COUNT="160"
FTCTL_XCOLO_AUTO_MIGRATE_PORT_BASE="9198"
FTCTL_XCOLO_AUTO_MIGRATE_PORT_COUNT="16"
FTCTL_REMOTE_NBD_AUTO_PORT_BASE="11809"
FTCTL_REMOTE_NBD_AUTO_PORT_COUNT="16"

if [[ -f "${CONFIG_PATH}" ]]; then
  set -a
  # shellcheck source=/dev/null
  source "${CONFIG_PATH}"
  set +a
fi

range_end=$((FTCTL_REMOTE_NBD_PORT_BASE + FTCTL_REMOTE_NBD_PORT_COUNT - 1))
xcolo_auto_range_end=$((FTCTL_XCOLO_AUTO_PORT_BASE + FTCTL_XCOLO_AUTO_PORT_COUNT - 1))
xcolo_auto_migrate_range_end=$((FTCTL_XCOLO_AUTO_MIGRATE_PORT_BASE + FTCTL_XCOLO_AUTO_MIGRATE_PORT_COUNT - 1))
remote_nbd_auto_range_end=$((FTCTL_REMOTE_NBD_AUTO_PORT_BASE + FTCTL_REMOTE_NBD_AUTO_PORT_COUNT - 1))

write_service_file() {
  mkdir -p "${SERVICE_DIR}"
  cat > "${SERVICE_PATH}" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<service>
  <short>ABLESTACK VM FTCTL</short>
  <description>Remote NBD export range and x-colo control/migrate ports for ABLESTACK VM FTCTL.</description>
  <port protocol="tcp" port="${FTCTL_XCOLO_PROXY_PORT}"/>
  <port protocol="tcp" port="${FTCTL_XCOLO_MIGRATE_PORT}"/>
  <port protocol="tcp" port="${FTCTL_XCOLO_MIRROR_PORT}"/>
  <port protocol="tcp" port="${FTCTL_XCOLO_COMPARE_PORT}"/>
  <port protocol="tcp" port="${FTCTL_REMOTE_NBD_PORT_BASE}-${range_end}"/>
  <port protocol="tcp" port="${FTCTL_XCOLO_AUTO_PORT_BASE}-${xcolo_auto_range_end}"/>
  <port protocol="tcp" port="${FTCTL_XCOLO_AUTO_MIGRATE_PORT_BASE}-${xcolo_auto_migrate_range_end}"/>
  <port protocol="tcp" port="${FTCTL_REMOTE_NBD_AUTO_PORT_BASE}-${remote_nbd_auto_range_end}"/>
</service>
EOF
  chmod 0644 "${SERVICE_PATH}"
}

firewalld_running() {
  systemctl is-active --quiet firewalld
}

firewalld_target_zones() {
  local zones=() zone default_zone active_line
  default_zone="$(firewall-cmd --get-default-zone 2>/dev/null || true)"
  [[ -n "${default_zone}" ]] && zones+=("${default_zone}")
  while IFS= read -r active_line; do
    [[ "${active_line}" == *":" ]] || continue
    zone="${active_line%:}"
    [[ -n "${zone}" ]] && zones+=("${zone}")
  done < <(firewall-cmd --get-active-zones 2>/dev/null || true)
  printf '%s\n' "${zones[@]}" | awk 'NF && !seen[$0]++'
}

add_service_to_zone() {
  local zone="${1-}"
  [[ -n "${zone}" ]] || return 0
  firewall-cmd --permanent --zone="${zone}" --add-service="${SERVICE_NAME}" >/dev/null 2>&1 || true
  if firewalld_running; then
    firewall-cmd --zone="${zone}" --add-service="${SERVICE_NAME}" >/dev/null 2>&1 || true
  fi
}

apply_service() {
  write_service_file
  if command -v firewall-cmd >/dev/null 2>&1; then
    firewall-cmd --reload >/dev/null 2>&1 || true
    while IFS= read -r zone; do
      add_service_to_zone "${zone}"
    done < <(firewalld_target_zones)
    firewall-cmd --reload >/dev/null 2>&1 || true
  fi
  echo "[INFO] Firewalld service ensured: ${SERVICE_NAME} (legacy x-colo ${FTCTL_XCOLO_PROXY_PORT},${FTCTL_XCOLO_MIGRATE_PORT},${FTCTL_XCOLO_MIRROR_PORT},${FTCTL_XCOLO_COMPARE_PORT}/tcp; auto x-colo ${FTCTL_XCOLO_AUTO_PORT_BASE}-${xcolo_auto_range_end}/tcp; auto migrate ${FTCTL_XCOLO_AUTO_MIGRATE_PORT_BASE}-${xcolo_auto_migrate_range_end}/tcp; remote-nbd ${FTCTL_REMOTE_NBD_PORT_BASE}-${range_end},${FTCTL_REMOTE_NBD_AUTO_PORT_BASE}-${remote_nbd_auto_range_end}/tcp)"
}

remove_service() {
  if command -v firewall-cmd >/dev/null 2>&1; then
    firewall-cmd --permanent --remove-service="${SERVICE_NAME}" >/dev/null 2>&1 || true
    if firewalld_running; then
      firewall-cmd --remove-service="${SERVICE_NAME}" >/dev/null 2>&1 || true
      firewall-cmd --reload >/dev/null 2>&1 || true
    fi
  fi
  rm -f "${SERVICE_PATH}" >/dev/null 2>&1 || true
  echo "[INFO] Firewalld service removed: ${SERVICE_NAME}"
}

status_service() {
  local zone query_rc=1
  echo "service_file=${SERVICE_PATH}"
  [[ -f "${SERVICE_PATH}" ]] && echo "service_file_present=true" || echo "service_file_present=false"
  if ! command -v firewall-cmd >/dev/null 2>&1; then
    echo "firewall_cmd=false"
    return 0
  fi
  echo "firewall_cmd=true"
  firewalld_running && echo "firewalld=active" || echo "firewalld=inactive"
  while IFS= read -r zone; do
    [[ -n "${zone}" ]] || continue
    if firewall-cmd --zone="${zone}" --query-service="${SERVICE_NAME}" >/dev/null 2>&1; then
      query_rc=0
      echo "runtime_zone_${zone}=enabled"
    else
      echo "runtime_zone_${zone}=disabled"
    fi
    if firewall-cmd --permanent --zone="${zone}" --query-service="${SERVICE_NAME}" >/dev/null 2>&1; then
      echo "permanent_zone_${zone}=enabled"
    else
      echo "permanent_zone_${zone}=disabled"
    fi
  done < <(firewalld_target_zones)
  return "${query_rc}"
}

case "${ACTION}" in
  apply)
    apply_service
    ;;
  remove)
    remove_service
    ;;
  status)
    status_service
    ;;
  *)
    echo "Usage: $0 [apply|remove|status]" >&2
    exit 2
    ;;
esac
