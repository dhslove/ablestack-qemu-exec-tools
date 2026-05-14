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

ftctl_orchestrator_mark_transport_loss() {
  local vm="${1-}"
  local reason="${2-unknown}"
  local current
  current="$(ftctl_state_get "${vm}" "transport_loss_since" 2>/dev/null || true)"
  if [[ -z "${current}" ]]; then
    ftctl_state_set "${vm}" "transport_loss_since=$(ftctl_now_iso8601)"
  fi
  ftctl_state_set "${vm}" \
    "protection_state=degraded" \
    "last_error=${reason}"
}

ftctl_orchestrator_clear_transport_loss() {
  local vm="${1-}"
  ftctl_state_set "${vm}" \
    "transport_loss_since=" \
    "last_error=" \
    "last_reconcile_ts=$(ftctl_now_iso8601)"
}

ftctl_orchestrator_rearm_allowed() {
  local vm="${1-}"
  local elapsed_since_loss elapsed_since_rearm rearm_count
  elapsed_since_loss="$(ftctl_state_get_elapsed_key_sec "${vm}" "transport_loss_since" 2>/dev/null || echo "0")"
  rearm_count="$(ftctl_state_get "${vm}" "rearm_count" 2>/dev/null || echo "0")"
  [[ "${rearm_count}" =~ ^[0-9]+$ ]] || rearm_count="0"

  if (( elapsed_since_loss < FTCTL_TRANSIENT_NET_GRACE_SEC )); then
    return 1
  fi
  if (( rearm_count >= FTCTL_MAX_REARM_ATTEMPTS )); then
    return 2
  fi

  elapsed_since_rearm="$(ftctl_state_get_elapsed_key_sec "${vm}" "last_rearm_ts" 2>/dev/null || echo "${FTCTL_REARM_BACKOFF_SEC}")"
  if (( elapsed_since_rearm < FTCTL_REARM_BACKOFF_SEC )); then
    return 3
  fi
  return 0
}

ftctl_orchestrator_probe_peer() {
  local host_id_var="${1}"
  local mgmt_ip_var="${2}"
  local reach_var="${3}"
  local record="" host_id="" role="" mgmt_ip="" libvirt_uri="" blockcopy_ip="" xcolo_ctrl="" xcolo_data="" rc=0

  printf -v "${host_id_var}" '%s' ""
  printf -v "${mgmt_ip_var}" '%s' ""
  printf -v "${reach_var}" '%s' "unknown"

  if ! ftctl_cluster_find_peer_record_for_vm record; then
    return 1
  fi

  ftctl_cluster_parse_record "${record}" host_id role mgmt_ip libvirt_uri blockcopy_ip xcolo_ctrl xcolo_data
  : "${role}${libvirt_uri}${blockcopy_ip}${xcolo_ctrl}${xcolo_data}"
  printf -v "${host_id_var}" '%s' "${host_id}"
  printf -v "${mgmt_ip_var}" '%s' "${mgmt_ip}"

  ftctl_cluster_probe_management_reachability "${mgmt_ip}" "1" || rc=$?
  case "${rc}" in
    0) printf -v "${reach_var}" '%s' "reachable" ;;
    1|124) printf -v "${reach_var}" '%s' "unreachable" ;;
    *) printf -v "${reach_var}" '%s' "unknown" ;;
  esac
}

ftctl_orchestrator_handle_transport_issue() {
  local vm="${1-}"
  local mode="${2-}"
  local reason="${3-transport_lost}"
  local peer_host_id="${4-}"
  local peer_reach="${5-unknown}"
  local rearm_rc=0
  local active_side standby_state

  if ftctl_fencing_is_explicit "${vm}"; then
    active_side="$(ftctl_state_get "${vm}" "active_side" 2>/dev/null || echo "primary")"
    standby_state="$(ftctl_state_get "${vm}" "standby_state" 2>/dev/null || echo "unknown")"
    if [[ "${active_side}" == "secondary" ]]; then
      case "${standby_state}" in
        running|start-dry-run|running-network-ok|running-network-unknown)
          ftctl_state_set "${vm}" \
            "protection_state=failed_over" \
            "transport_state=failed_over" \
            "last_error="
          ftctl_log_event "failover" "failover.steady" "ok" "${vm}" "" \
            "reason=source_fenced active_side=secondary standby=${standby_state}"
          return 0
          ;;
      esac
    fi
    ftctl_state_set "${vm}" \
      "protection_state=failing_over" \
      "transport_state=source_fenced" \
      "last_error=source_fenced"
    ftctl_log_event "failover" "failover.pending" "warn" "${vm}" "" \
      "reason=source_fenced peer_host=${peer_host_id}"
    return 0
  fi

  ftctl_orchestrator_mark_transport_loss "${vm}" "${reason}"

  if [[ "${peer_reach}" == "unreachable" ]]; then
    ftctl_state_set "${vm}" "transport_state=peer_unreachable"
    ftctl_log_event "health" "peer.reachability" "warn" "${vm}" "" \
      "peer_host=${peer_host_id} reachability=${peer_reach}"
    return 0
  fi

  if [[ "${FTCTL_PROFILE_AUTO_REARM:-1}" != "1" ]]; then
    ftctl_state_set "${vm}" "transport_state=transient_loss"
    ftctl_log_event "rearm" "rearm.skip" "warn" "${vm}" "" \
      "reason=auto_rearm_disabled peer_host=${peer_host_id}"
    return 0
  fi

  ftctl_orchestrator_rearm_allowed "${vm}" || rearm_rc=$?
  case "${rearm_rc}" in
    0)
      if [[ "${mode}" == "ft" ]]; then
        ftctl_xcolo_rearm "${vm}"
      else
        ftctl_blockcopy_rearm "${vm}"
      fi
      ;;
    1)
      ftctl_state_set "${vm}" "transport_state=transient_loss"
      ftctl_log_event "rearm" "rearm.defer" "warn" "${vm}" "" \
        "reason=grace_window peer_host=${peer_host_id}"
      ;;
    2)
      ftctl_state_set "${vm}" \
        "protection_state=error" \
        "transport_state=rearm_exhausted" \
        "last_error=rearm_attempts_exhausted"
      ftctl_log_event "rearm" "rearm.exhausted" "fail" "${vm}" "" \
        "peer_host=${peer_host_id} max_attempts=${FTCTL_MAX_REARM_ATTEMPTS}"
      ;;
    3)
      ftctl_state_set "${vm}" "transport_state=rearm_backoff"
      ftctl_log_event "rearm" "rearm.defer" "warn" "${vm}" "" \
        "reason=backoff peer_host=${peer_host_id}"
      ;;
    *)
      ftctl_state_set "${vm}" \
        "protection_state=error" \
        "transport_state=unknown" \
        "last_error=rearm_decision_failed"
      ;;
  esac
}

ftctl_orchestrator_protect() {
  local vm="${1-}"
  ftctl_state_init_vm "${vm}"
  if [[ "${FTCTL_PROFILE_MODE}" == "ft" ]]; then
    ftctl_xcolo_plan_protect "${vm}"
  else
    ftctl_blockcopy_plan_protect "${vm}"
  fi
  ftctl_verify_vm "${vm}"
  ftctl_state_print_one "${vm}" "0"
}

ftctl_orchestrator_check_vm() {
  local vm="${1-}"
  local json="${2-0}"
  local probe local_rc peer_rc result peer_domain_expected standby_domain_state snapshot
  probe="$(ftctl_inventory_check_vm "${vm}")"
  read -r local_rc peer_rc result peer_domain_expected standby_domain_state <<< "${probe}"
  peer_domain_expected="${peer_domain_expected:-true}"
  standby_domain_state="${standby_domain_state:-}"
  snapshot="$(printf '{"command":"check","vm":"%s","result":"ok","inventory_result":"%s","primary_rc":%s,"peer_rc":%s,"peer_domain_expected":%s,"standby_domain_state":"%s","provisioning_backend":"%s","updated":"%s"}' \
    "$(ftctl__json_escape "${vm}")" \
    "$(ftctl__json_escape "${result}")" \
    "${local_rc}" \
    "${peer_rc}" \
    "${peer_domain_expected}" \
    "$(ftctl__json_escape "${standby_domain_state}")" \
    "$(ftctl__json_escape "${FTCTL_PROFILE_PROVISIONING_BACKEND:-libvirt-managed}")" \
    "$(ftctl__json_escape "$(ftctl_now_iso8601)")")"
  ftctl_state_write_json_file "$(ftctl_state_check_path "${vm}")" "${snapshot}"

  if [[ "${json}" == "1" ]]; then
    printf '%s\n' "${snapshot}"
  else
    printf '%s inventory=%s primary_rc=%s peer_rc=%s peer_domain_expected=%s standby_domain_state=%s provisioning_backend=%s\n' \
      "${vm}" "${result}" "${local_rc}" "${peer_rc}" "${peer_domain_expected}" "${standby_domain_state}" \
      "${FTCTL_PROFILE_PROVISIONING_BACKEND:-libvirt-managed}"
  fi
}

ftctl_orchestrator_is_failover_steady_state() {
  local vm="${1-}"
  local mode="${2-}"
  local active_side="${3-}"
  local peer_rc="${4-}"
  local inventory_result="${5-}"
  local standby_domain_state="${6-}"
  local standby_state

  [[ "${mode}" == "ha" ]] || return 1
  [[ "${active_side}" == "secondary" ]] || return 1
  [[ "${FTCTL_PROFILE_PROVISIONING_BACKEND:-libvirt-managed}" == "cloud-managed" ]] || return 1
  [[ "${inventory_result}" == "ok" ]] || return 1
  [[ "${peer_rc}" == "0" ]] || return 1
  ftctl_fencing_is_explicit "${vm}" || return 1

  standby_state="${standby_domain_state:-$(ftctl_state_get "${vm}" "standby_state" 2>/dev/null || echo "unknown")}"
  case "${standby_state}" in
    running|start-dry-run|running-network-ok|running-network-unknown)
      return 0
      ;;
  esac
  return 1
}

ftctl_orchestrator_is_cloud_failback_transition() {
  local vm="${1-}"
  local protection_state="${2-}"
  local transport_state="${3-}"

  [[ "${FTCTL_PROFILE_PROVISIONING_BACKEND:-libvirt-managed}" == "cloud-managed" ]] || return 1
  case "${protection_state}" in
    failing_back)
      return 0
      ;;
  esac
  case "${transport_state}" in
    reverse_syncing|reverse_sync_ready|reverse_sync_cutback_required|reverse_sync_failed|secondary_stopping|finalizing|primary_restoring|cutback_ready|cutback_switching|failback_failed)
      return 0
      ;;
    failed_over|unknown|"")
      if declare -F ftctl_blockcopy_reverse_sync_artifacts_present >/dev/null 2>&1 &&
          ftctl_blockcopy_reverse_sync_artifacts_present "${vm}"; then
        return 0
      fi
      ;;
  esac
  return 1
}

ftctl_orchestrator_is_cloud_failback_awaiting_command() {
  local mode="${1-}"
  local active_side="${2-}"
  local protection_state="${3-}"
  local transport_state="${4-}"
  local fencing_state="${5-}"

  [[ "${FTCTL_PROFILE_PROVISIONING_BACKEND:-libvirt-managed}" == "cloud-managed" ]] || return 1
  [[ "${mode}" == "ha" ]] || return 1
  [[ "${active_side}" == "secondary" ]] || return 1
  [[ "${protection_state}" == "failed_over" ]] || return 1
  [[ "${transport_state}" == "failed_over" ]] || return 1
  case "${fencing_state}" in
    clear|cleared)
      return 0
      ;;
  esac
  return 1
}

ftctl_orchestrator_reconcile_one() {
  local vm="${1-}"
  local admin mode transport refresh_rc peer_host_id peer_mgmt_ip peer_reach active_side
  local protection_state fencing_state failover_ready
  local inventory_probe local_rc peer_rc inventory_result _peer_domain_expected _standby_domain_state
  admin="$(ftctl_state_get "${vm}" "admin_state" 2>/dev/null || echo "active")"
  [[ "${admin}" == "paused" ]] && {
    ftctl_log_event "rearm" "reconcile.skip" "skip" "${vm}" "" "reason=admin_paused"
    return 0
  }

  mode="$(ftctl_state_get "${vm}" "mode" 2>/dev/null || echo "")"
  transport="$(ftctl_state_get "${vm}" "transport_state" 2>/dev/null || echo "unknown")"
  active_side="$(ftctl_state_get "${vm}" "active_side" 2>/dev/null || echo "primary")"
  protection_state="$(ftctl_state_get "${vm}" "protection_state" 2>/dev/null || echo "")"
  fencing_state="$(ftctl_state_get "${vm}" "fencing_state" 2>/dev/null || echo "clear")"
  failover_ready="$(ftctl_state_get "${vm}" "failover_ready" 2>/dev/null || echo "")"

  if [[ ( "${mode}" == "ha" || "${mode}" == "dr" ) && "${active_side}" == "primary" && "${protection_state}" == "failing_over" ]]; then
    case "${fencing_state}" in
      required|manual-required|manual-fenced)
        case "${failover_ready}" in
          1|true|yes)
            ftctl_state_set "${vm}" "last_reconcile_ts=$(ftctl_now_iso8601)"
            ftctl_log_event "failover" "reconcile.defer" "skip" "${vm}" "" \
              "reason=manual_fence_in_progress protection=${protection_state} transport=${transport} fencing=${fencing_state} readiness=marker"
            return 0
            ;;
        esac
        ;;
    esac
  fi

  ftctl_profile_load_vm "${vm}"
  ftctl_profile_apply_cli "${vm}" "${mode}" "" ""
  ftctl_profile_validate "${vm}"
  ftctl_cluster_load || true
  ftctl_orchestrator_probe_peer peer_host_id peer_mgmt_ip peer_reach || true
  : "${peer_mgmt_ip}"
  ftctl_state_set "${vm}" "last_reconcile_ts=$(ftctl_now_iso8601)"

  protection_state="$(ftctl_state_get "${vm}" "protection_state" 2>/dev/null || echo "${protection_state}")"
  transport="$(ftctl_state_get "${vm}" "transport_state" 2>/dev/null || echo "${transport}")"
  active_side="$(ftctl_state_get "${vm}" "active_side" 2>/dev/null || echo "${active_side}")"
  fencing_state="$(ftctl_state_get "${vm}" "fencing_state" 2>/dev/null || echo "${fencing_state}")"
  if ftctl_orchestrator_is_cloud_failback_awaiting_command "${mode}" "${active_side}" "${protection_state}" "${transport}" "${fencing_state}"; then
    ftctl_state_set "${vm}" "last_healthy_ts=$(ftctl_now_iso8601)"
    ftctl_log_event "failback" "failback.await-command" "ok" "${vm}" "" \
      "reason=cloud_managed_manual_fence_released active_side=${active_side} protection=${protection_state} transport=${transport} fencing=${fencing_state}"
    return 0
  fi
  if [[ "${mode}" != "ft" ]] && ftctl_orchestrator_is_cloud_failback_transition "${vm}" "${protection_state}" "${transport}"; then
    case "${transport}" in
      reverse_syncing|reverse_sync_ready|reverse_sync_cutback_required|failed_over|unknown|"")
        refresh_rc=0
        ftctl_blockcopy_refresh_and_classify "${vm}" || refresh_rc=$?
        transport="$(ftctl_state_get "${vm}" "transport_state" 2>/dev/null || echo "${transport}")"
        case "${refresh_rc}" in
          0|11|23)
            ftctl_state_set "${vm}" "last_healthy_ts=$(ftctl_now_iso8601)"
            ftctl_log_event "failback" "reconcile.reverse-sync" "ok" "${vm}" "" \
              "transport=${transport} refresh_rc=${refresh_rc}"
            return 0
            ;;
          *)
            ftctl_state_set "${vm}" \
              "protection_state=error" \
              "transport_state=reverse_sync_failed" \
              "last_error=reverse_sync_refresh_failed"
            ftctl_log_event "failback" "reconcile.reverse-sync" "fail" "${vm}" "" \
              "transport=${transport} refresh_rc=${refresh_rc} peer_host=${peer_host_id} peer_reach=${peer_reach}"
            return 0
            ;;
        esac
        ;;
      reverse_sync_failed)
        ftctl_state_set "${vm}" "last_healthy_ts=$(ftctl_now_iso8601)"
        ftctl_log_event "failback" "reconcile.defer" "warn" "${vm}" "" \
          "reason=cloud_failback_failure_preserved transport=${transport}"
        return 0
        ;;
      *)
        ftctl_state_set "${vm}" "last_healthy_ts=$(ftctl_now_iso8601)"
        ftctl_log_event "failback" "reconcile.defer" "ok" "${vm}" "" \
          "reason=cloud_failback_transition transport=${transport}"
        return 0
        ;;
    esac
  fi

  inventory_probe="$(ftctl_inventory_check_vm "${vm}")"
  read -r local_rc peer_rc inventory_result _peer_domain_expected _standby_domain_state <<< "${inventory_probe}"
  : "${peer_rc}${inventory_result}"

  if ftctl_orchestrator_is_failover_steady_state "${vm}" "${mode}" "${active_side}" "${peer_rc}" "${inventory_result}" "${_standby_domain_state}"; then
    ftctl_state_set "${vm}" \
      "protection_state=failed_over" \
      "transport_state=failed_over" \
      "last_error=" \
      "last_healthy_ts=$(ftctl_now_iso8601)"
    ftctl_log_event "failover" "failover.steady" "ok" "${vm}" "" \
      "reason=source_fenced active_side=secondary standby=${_standby_domain_state:-unknown}"
    return 0
  fi

  if [[ "${mode}" == "ha" && "${active_side}" == "primary" && "${local_rc}" != "0" ]]; then
    ftctl_log_event "failover" "failover.auto" "warn" "${vm}" "" \
      "reason=primary_domain_missing peer_host=${peer_host_id}"
    ftctl_failover_request "${vm}" "primary_domain_missing"
    return 0
  fi

  refresh_rc=0
  if [[ "${mode}" != "ft" ]]; then
    ftctl_blockcopy_refresh_and_classify "${vm}" || refresh_rc=$?
    transport="$(ftctl_state_get "${vm}" "transport_state" 2>/dev/null || echo "${transport}")"
  fi

  if [[ "${mode}" != "ft" ]]; then
    case "${refresh_rc}" in
      0|11)
        ftctl_orchestrator_clear_transport_loss "${vm}"
        ftctl_state_set "${vm}" "last_healthy_ts=$(ftctl_now_iso8601)"
        ftctl_log_event "health" "reconcile.tick" "ok" "${vm}" "" \
          "mode=${mode} transport=${transport} peer_host=${peer_host_id} peer_reach=${peer_reach}"
        ;;
      *)
        ftctl_orchestrator_handle_transport_issue "${vm}" "${mode}" "blockcopy_transport_lost" "${peer_host_id}" "${peer_reach}"
        ;;
    esac
    return 0
  fi

  case "${transport}" in
    broken|lost|disconnected|rearm-requested|colo_rearming|transient_loss|rearm_backoff)
      ftctl_orchestrator_handle_transport_issue "${vm}" "${mode}" "xcolo_transport_lost" "${peer_host_id}" "${peer_reach}"
      ;;
    *)
      ftctl_orchestrator_clear_transport_loss "${vm}"
      ftctl_state_set "${vm}" "last_healthy_ts=$(ftctl_now_iso8601)"
      ftctl_log_event "health" "reconcile.tick" "ok" "${vm}" "" \
        "mode=${mode} transport=${transport} peer_host=${peer_host_id} peer_reach=${peer_reach}"
      ;;
  esac
}

ftctl_orchestrator_reconcile() {
  local vm="${1-}"
  local json="${2-0}"
  local f name lock_file
  if [[ -n "${vm}" ]]; then
    ftctl_orchestrator_reconcile_one "${vm}"
    if ftctl_profile_load_vm "${vm}" 2>/dev/null; then
      ftctl_orchestrator_check_vm "${vm}" "1" >/dev/null || true
    fi
    ftctl_local_health "1" "${vm}" >/dev/null || true
    ftctl_state_print_one "${vm}" "${json}"
    return 0
  fi

  ftctl_local_health "1" "${vm}" >/dev/null || true
  shopt -s nullglob
  for f in "${FTCTL_STATE_DIR}"/*.state; do
    name="$(basename "${f}" .state)"
    lock_file="$(ftctl_lock_path_for_command "reconcile" "${name}")"
    CLI_COMMAND="reconcile" CLI_VM="${name}" ftctl_lock_acquire "${lock_file}" || {
      ftctl_log_event "lock" "reconcile.skip" "skip" "${name}" "${EXIT_LOCKED:-20}" \
        "reason=vm_locked lock_file=${lock_file}"
      continue
    }
    ftctl_orchestrator_reconcile_one "${name}"
    if ftctl_profile_load_vm "${name}" 2>/dev/null; then
      ftctl_orchestrator_check_vm "${name}" "1" >/dev/null || true
    fi
    ftctl_lock_release
    if [[ "${json}" == "1" ]]; then
      ftctl_state_emit_json "${name}"
    else
      ftctl_state_print_one "${name}" "0"
    fi
  done
  shopt -u nullglob
}
