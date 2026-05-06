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

ftctl_failover_requires_blockcopy_ready() {
  local mode="${1-}"

  [[ "${mode}" == "ha" ]] || return 1
  case "${FTCTL_PROFILE_BACKEND_MODE:-}" in
    remote-nbd|shared-blockcopy) return 0 ;;
    *) return 1 ;;
  esac
}

ftctl_failover_transport_is_ready() {
  local vm="${1-}"
  local transport

  transport="$(ftctl_state_get "${vm}" "transport_state" 2>/dev/null || true)"
  case "${transport}" in
    mirroring|failed_over) return 0 ;;
    *) return 1 ;;
  esac
}

ftctl_failover_precheck_blockcopy_ready() {
  local vm="${1-}"
  local mode="${2-}"
  local count="${3-}"
  local stage="${4-}"
  local allow_wait="${5-0}"
  local timeout_sec="${FTCTL_FAILOVER_SYNC_READY_TIMEOUT_SEC:-120}"
  local transport

  ftctl_failover_requires_blockcopy_ready "${mode}" || return 0
  if ftctl_failover_transport_is_ready "${vm}"; then
    ftctl_log_event "failover" "failover.precheck" "ok" "${vm}" "" \
      "stage=${stage} failover_count=${count} transport=$(ftctl_state_get "${vm}" "transport_state" 2>/dev/null || true)"
    return 0
  fi

  if [[ "${allow_wait}" == "1" ]]; then
    if ftctl_blockcopy_wait_forward_sync_ready "${vm}" "${timeout_sec}" && ftctl_failover_transport_is_ready "${vm}"; then
      ftctl_log_event "failover" "failover.precheck" "ok" "${vm}" "" \
        "stage=${stage} failover_count=${count} transport=$(ftctl_state_get "${vm}" "transport_state" 2>/dev/null || true)"
      return 0
    fi
  fi

  transport="$(ftctl_state_get "${vm}" "transport_state" 2>/dev/null || echo "unknown")"
  if [[ "${allow_wait}" == "1" ]]; then
    ftctl_state_set "${vm}" \
      "protection_state=syncing" \
      "last_error=blockcopy_not_ready_for_failover"
  else
    ftctl_state_set "${vm}" \
      "protection_state=error" \
      "last_error=blockcopy_not_ready_for_failover"
  fi
  ftctl_log_event "failover" "failover.precheck" "fail" "${vm}" "" \
    "stage=${stage} failover_count=${count} transport=${transport} required=mirroring"
  return 1
}

ftctl_failover_release_remote_nbd_for_standby() {
  local vm="${1-}"

  [[ "${FTCTL_PROFILE_BACKEND_MODE:-}" == "remote-nbd" ]] || return 0
  ftctl_blockcopy_stop_remote_nbd_exports "${vm}" || true
  ftctl_blockcopy_wait_remote_nbd_release "${vm}" || {
    ftctl_state_set "${vm}" \
      "standby_state=release-timeout" \
      "last_error=remote_nbd_release_timeout"
    ftctl_log_event "failover" "failover.prepare" "fail" "${vm}" "" \
      "reason=remote_nbd_release_timeout"
    return 1
  }
}

ftctl_failover_prepare_cloud_managed() {
  local vm="${1-}"
  local reason="${2-manual}"
  local mode count

  mode="$(ftctl_state_get "${vm}" "mode" 2>/dev/null || echo "")"
  mode="${mode:-${FTCTL_PROFILE_MODE:-}}"
  count="$(ftctl_state_get "${vm}" "failover_count" 2>/dev/null || echo "0")"

  if [[ "${FTCTL_PROFILE_PROVISIONING_BACKEND:-libvirt-managed}" != "cloud-managed" ]]; then
    ftctl_log_event "failover" "failover.prepare" "skip" "${vm}" "" \
      "reason=not_cloud_managed provisioning=${FTCTL_PROFILE_PROVISIONING_BACKEND:-libvirt-managed}"
    return 0
  fi

  ftctl_failover_precheck_blockcopy_ready "${vm}" "${mode}" "${count}" "cloud_prepare" "1" || return 1
  ftctl_failover_release_remote_nbd_for_standby "${vm}" || return 1
  ftctl_state_set "${vm}" \
    "protection_state=failing_over" \
    "standby_state=start-ready" \
    "last_error="
  ftctl_log_event "failover" "failover.prepare" "ok" "${vm}" "" \
    "reason=${reason} provisioning=cloud-managed transport=$(ftctl_state_get "${vm}" "transport_state" 2>/dev/null || true)"
}

ftctl_failover_request() {
  local vm="${1-}"
  local reason="${2-manual}"
  local count
  local fence_rc
  local mode
  local explicit_fencing
  count="$(ftctl_state_increment "${vm}" "failover_count")"
  mode="$(ftctl_state_get "${vm}" "mode" 2>/dev/null || echo "")"
  mode="${mode:-${FTCTL_PROFILE_MODE:-}}"
  explicit_fencing="0"
  if ftctl_fencing_is_explicit "${vm}"; then
    explicit_fencing="1"
  fi
  if [[ "${explicit_fencing}" != "1" ]]; then
    ftctl_failover_precheck_blockcopy_ready "${vm}" "${mode}" "${count}" "before_fencing" "1" || return 1
  fi
  ftctl_state_set "${vm}" \
    "protection_state=failing_over" \
    "last_error=skeleton_failover_pending"
  fence_rc=0
  if [[ "${explicit_fencing}" == "1" ]]; then
    ftctl_state_set "${vm}" "last_error="
    ftctl_log_event "failover" "failover.fencing" "ok" "${vm}" "" \
      "reason=${reason} failover_count=${count} fencing=already_confirmed"
  else
    ftctl_fencing_execute "${vm}" "${reason}" || fence_rc=$?
  fi
  case "${fence_rc}" in
    0)
      if [[ "${mode}" == "ft" ]]; then
        if ! ftctl_xcolo_failover "${vm}"; then
          ftctl_state_set "${vm}" \
            "protection_state=error" \
            "last_error=xcolo_failover_failed"
          ftctl_log_event "failover" "failover.request" "fail" "${vm}" "" \
            "reason=${reason} failover_count=${count} xcolo=failover_failed"
          return 1
        fi
        ftctl_state_set "${vm}" "last_error="
        ftctl_log_event "failover" "failover.request" "ok" "${vm}" "" \
          "reason=${reason} failover_count=${count} fencing=complete xcolo=running"
        return 0
      fi

      ftctl_failover_precheck_blockcopy_ready "${vm}" "${mode}" "${count}" "before_standby" "0" || return 1

      if [[ "${FTCTL_PROFILE_PROVISIONING_BACKEND:-libvirt-managed}" == "cloud-managed" ]]; then
        if [[ "${reason}" != "manual" && "${reason}" != "manual-confirmed" ]]; then
          ftctl_state_set "${vm}" \
            "protection_state=failing_over" \
            "last_error=cloud_managed_standby_start_pending"
          ftctl_log_event "failover" "failover.request" "skip" "${vm}" "" \
            "reason=${reason} failover_count=${count} provisioning=cloud-managed standby=cloud_start_required"
          return 0
        fi
        ftctl_failover_release_remote_nbd_for_standby "${vm}" || return 1
        if ! ftctl_verify_standby_boot "${vm}"; then
          ftctl_state_set "${vm}" \
            "protection_state=error" \
            "last_error=standby_verify_failed"
          ftctl_log_event "failover" "failover.request" "fail" "${vm}" "" \
            "reason=${reason} failover_count=${count} standby=cloud_started_verify_failed"
          return 1
        fi
        ftctl_state_set "${vm}" \
          "standby_state=running" \
          "active_side=secondary" \
          "protection_state=failed_over" \
          "transport_state=failed_over" \
          "last_error="
        ftctl_log_event "failover" "failover.request" "ok" "${vm}" "" \
          "reason=${reason} failover_count=${count} fencing=complete standby=cloud-managed"
        return 0
      fi

      if [[ "${FTCTL_PROFILE_BACKEND_MODE}" == "remote-nbd" ]]; then
        ftctl_failover_release_remote_nbd_for_standby "${vm}" || return 1
      fi

      if ! ftctl_standby_activate "${vm}"; then
        ftctl_state_set "${vm}" \
          "protection_state=error" \
          "last_error=standby_activate_failed"
        ftctl_log_event "failover" "failover.request" "fail" "${vm}" "" \
          "reason=${reason} failover_count=${count} standby=activate_failed"
        return 1
      fi
      if ! ftctl_verify_standby_boot "${vm}"; then
        ftctl_state_set "${vm}" \
          "protection_state=error" \
          "last_error=standby_verify_failed"
        ftctl_log_event "failover" "failover.request" "fail" "${vm}" "" \
          "reason=${reason} failover_count=${count} standby=verify_failed"
        return 1
      fi
      ftctl_state_set "${vm}" \
        "protection_state=failed_over" \
        "transport_state=failed_over" \
        "last_error="
      ftctl_log_event "failover" "failover.request" "ok" "${vm}" "" \
        "reason=${reason} failover_count=${count} fencing=complete standby=running"
      ;;
    3)
      ftctl_state_set "${vm}" "last_error=manual_fencing_required"
      ftctl_log_event "failover" "failover.request" "warn" "${vm}" "" \
        "reason=${reason} failover_count=${count} fencing=manual_required"
      ;;
    4)
      ftctl_state_set "${vm}" "last_error=dry_run_fencing"
      ftctl_log_event "failover" "failover.request" "skip" "${vm}" "" \
        "reason=${reason} failover_count=${count} fencing=dry_run"
      ;;
    *)
      ftctl_state_set "${vm}" \
        "protection_state=error" \
        "last_error=fencing_failed"
      ftctl_log_event "failover" "failover.request" "fail" "${vm}" "" \
        "reason=${reason} failover_count=${count} fencing=failed"
      return 1
      ;;
  esac
}

ftctl_failback_reprotect_from_primary() {
  local vm="${1-}"
  local mode="${2-}"
  local host="" user="" out="" err="" rc=0 remote_cmd="" remote_blockcopy=""
  local timeout_sec="${FTCTL_FAILBACK_REPROTECT_TIMEOUT_SEC:-600}"
  local attempts

  if [[ "${FTCTL_PROFILE_PRIMARY_URI}" == "qemu:///system" ]]; then
    ftctl_blockcopy_plan_protect "${vm}" || return 1
    ftctl_blockcopy_wait_forward_sync_ready "${vm}" "${timeout_sec}" || return 1
    return 0
  fi

  ftctl_blockcopy_primary_target_host_user host user || return 1
  attempts=$(((timeout_sec + 1) / 2))
  ((attempts > 0)) || attempts=1
  remote_cmd="$(cat <<EOF
set -euo pipefail
ablestack_vm_ftctl protect --vm ${vm@Q} --mode ${mode@Q}
for _i in \$(seq 1 ${attempts}); do
  ablestack_vm_ftctl reconcile --vm ${vm@Q} >/dev/null 2>&1 || true
  status_json="\$(ablestack_vm_ftctl status --vm ${vm@Q} --json 2>/dev/null || true)"
  if [[ "\${status_json}" == *'"protection_state":"protected"'* && "\${status_json}" == *'"transport_state":"mirroring"'* && "\${status_json}" == *'"active_side":"primary"'* ]]; then
    exit 0
  fi
  sleep 2
done
echo "primary_reprotect_timeout:${vm}:${timeout_sec}" >&2
exit 99
EOF
)"
  out=""
  err=""
  rc=0
  ftctl_blockcopy_remote_exec "${host}" "${user}" out err rc "${remote_cmd}" || true
  : "${out}${err}"
  [[ "${rc}" == "0" ]] || {
    [[ -n "${err}" ]] && echo "ERROR: primary reprotect failed: ${err}" >&2
    return 1
  }

  out=""
  err=""
  rc=0
  ftctl_blockcopy_remote_exec "${host}" "${user}" out err rc "cat /run/ablestack-vm-ftctl/state/$(ftctl_state_vm_key "${vm}").state.blockcopy" || true
  : "${out}${err}"
  [[ "${rc}" == "0" && -n "${out}" ]] || {
    [[ -n "${err}" ]] && echo "ERROR: failed to fetch primary blockcopy state: ${err}" >&2
    return 1
  }
  remote_blockcopy="$(ftctl_blockcopy_state_path "${vm}")"
  printf '%s\n' "${out}" > "${remote_blockcopy}"
  chmod 0644 "${remote_blockcopy}" 2>/dev/null || true

  ftctl_state_set "${vm}" \
    "active_side=primary" \
    "protection_state=protected" \
    "transport_state=mirroring" \
    "fencing_state=clear" \
    "standby_state=prepared-transient" \
    "last_sync_ts=$(ftctl_now_iso8601)" \
    "last_error="
}

ftctl_failback_resume_primary_reprotect() {
  local vm="${1-}"
  local reason="${2-manual}"
  local mode="${FTCTL_PROFILE_MODE:-ha}"
  local protection transport

  protection="$(ftctl_state_get "${vm}" "protection_state" 2>/dev/null || true)"
  transport="$(ftctl_state_get "${vm}" "transport_state" 2>/dev/null || true)"
  case "${protection}:${transport}" in
    protected:mirroring)
      ftctl_log_event "failback" "failback.resume" "ok" "${vm}" "" \
        "reason=${reason} state=already_primary"
      return 0
      ;;
    syncing:copying|pairing:initializing|error:copying)
      ftctl_log_event "failback" "failback.resume" "ok" "${vm}" "" \
        "reason=${reason} state=reprotect_wait protection=${protection} transport=${transport}"
      if ftctl_blockcopy_wait_forward_sync_ready "${vm}" "${FTCTL_FAILBACK_REPROTECT_TIMEOUT_SEC:-600}"; then
        ftctl_state_set "${vm}" \
          "active_side=primary" \
          "protection_state=protected" \
          "transport_state=mirroring" \
          "fencing_state=clear" \
          "standby_state=prepared-transient" \
          "last_error="
        ftctl_log_event "failback" "failback.request" "ok" "${vm}" "" \
          "reason=${reason} cutback=already_done reprotect=completed"
        return 0
      fi
      ftctl_state_set "${vm}" \
        "protection_state=error" \
        "last_error=cutback_reprotect_failed"
      ftctl_log_event "failback" "failback.cutback" "fail" "${vm}" "" \
        "reason=${reason} reprotect=resume_failed"
      return 1
      ;;
  esac

  echo "ERROR: failback requires active_side=secondary" >&2
  return 1
}

ftctl_failback_sync_for_cloud_cutback() {
  local vm="${1-}"
  local reason="${2-manual}"
  local mode="${FTCTL_PROFILE_MODE:-ha}"
  local active_side primary_xml

  if [[ "${mode}" == "ft" ]]; then
    echo "ERROR: failback-sync is not supported for FT mode" >&2
    return 1
  fi

  active_side="$(ftctl_state_get "${vm}" "active_side" 2>/dev/null || echo "primary")"
  if [[ "${active_side}" == "primary" ]]; then
    ftctl_log_event "failback" "failback.sync" "ok" "${vm}" "" \
      "reason=${reason} state=already_primary"
    return 0
  fi

  if ! ftctl_verify_failback_ready "${vm}"; then
    ftctl_state_set "${vm}" \
      "protection_state=error" \
      "last_error=failback_precheck_failed"
    return 1
  fi

  primary_xml="$(ftctl_state_get "${vm}" "primary_xml_backup" 2>/dev/null || true)"
  if [[ -n "${primary_xml}" && -f "${primary_xml}" ]]; then
    if ! ftctl_primary_map_local_krbd_paths_from_xml "${vm}" "${primary_xml}"; then
      ftctl_state_set "${vm}" \
        "protection_state=error" \
        "transport_state=reverse_sync_failed" \
        "last_error=primary_rbd_map_failed"
      ftctl_log_event "failback" "failback.sync" "fail" "${vm}" "" \
        "reason=${reason} primary_rbd_map=failed"
      return 1
    fi
  fi

  ftctl_state_set "${vm}" \
    "protection_state=failing_back" \
    "last_error=reverse_sync_pending"
  if ! ftctl_blockcopy_start_reverse_sync "${vm}"; then
    ftctl_log_event "failback" "failback.sync" "fail" "${vm}" "" \
      "reason=${reason} reverse_sync=failed"
    return 1
  fi
  if ! ftctl_blockcopy_wait_reverse_sync_ready "${vm}" "${FTCTL_FAILBACK_REVERSE_SYNC_TIMEOUT_SEC:-600}"; then
    ftctl_state_set "${vm}" \
      "protection_state=error" \
      "transport_state=reverse_sync_failed" \
      "last_error=reverse_sync_timeout"
    ftctl_log_event "failback" "failback.sync" "fail" "${vm}" "" \
      "reason=${reason} reverse_sync=timeout"
    return 1
  fi

  ftctl_state_set "${vm}" \
    "protection_state=failing_back" \
    "transport_state=reverse_sync_ready" \
    "last_error="

  if [[ "${FTCTL_PROFILE_BACKEND_MODE}" == "remote-nbd" ]]; then
    ftctl_blockcopy_stop_primary_reverse_nbd_exports "${vm}" || true
    sleep 2
  fi

  ftctl_log_event "failback" "failback.sync" "ok" "${vm}" "" \
    "reason=${reason} reverse_sync=ready"
}

ftctl_failback_reprotect_after_cloud_cutback() {
  local vm="${1-}"
  local reason="${2-manual}"
  local mode="${FTCTL_PROFILE_MODE:-ha}"
  local protection transport

  if [[ "${mode}" == "ft" ]]; then
    echo "ERROR: failback-reprotect is not supported for FT mode" >&2
    return 1
  fi

  protection="$(ftctl_state_get "${vm}" "protection_state" 2>/dev/null || true)"
  transport="$(ftctl_state_get "${vm}" "transport_state" 2>/dev/null || true)"
  if [[ "${protection}:${transport}" == "protected:mirroring" ]]; then
    ftctl_log_event "failback" "failback.reprotect" "ok" "${vm}" "" \
      "reason=${reason} state=already_protected"
    return 0
  fi

  ftctl_state_set "${vm}" \
    "active_side=primary" \
    "fencing_state=clear" \
    "protection_state=pairing" \
    "transport_state=initializing" \
    "standby_state=prepared-transient" \
    "last_error="

  if ! ftctl_failback_reprotect_from_primary "${vm}" "${mode}"; then
    ftctl_state_set "${vm}" \
      "protection_state=error" \
      "last_error=cutback_reprotect_failed"
    ftctl_log_event "failback" "failback.reprotect" "fail" "${vm}" "" \
      "reason=${reason} reprotect=failed"
    return 1
  fi

  ftctl_log_event "failback" "failback.reprotect" "ok" "${vm}" "" \
    "reason=${reason} cloud_cutback=done"
}

ftctl_failback_request() {
  local vm="${1-}"
  local reason="${2-manual}"
  local mode="${FTCTL_PROFILE_MODE:-ha}"
  local active_side
  if [[ "${mode}" == "ft" ]]; then
    if ! ftctl_xcolo_failback "${vm}"; then
      ftctl_log_event "failback" "failback.request" "fail" "${vm}" "" \
        "reason=${reason} xcolo=failback_failed"
      return 1
    fi
    return 0
  fi
  active_side="$(ftctl_state_get "${vm}" "active_side" 2>/dev/null || echo "primary")"
  if [[ "${active_side}" == "primary" ]]; then
    ftctl_failback_resume_primary_reprotect "${vm}" "${reason}"
    return $?
  fi
  if ! ftctl_verify_failback_ready "${vm}"; then
    ftctl_state_set "${vm}" \
      "protection_state=error" \
      "last_error=failback_precheck_failed"
    return 1
  fi
  ftctl_state_set "${vm}" \
    "protection_state=failing_back" \
    "last_error=reverse_sync_pending"
  if ! ftctl_blockcopy_start_reverse_sync "${vm}"; then
    ftctl_log_event "failback" "failback.request" "fail" "${vm}" "" \
      "reason=${reason} reverse_sync=failed"
    return 1
  fi
  if ! ftctl_blockcopy_wait_reverse_sync_ready "${vm}" "${FTCTL_FAILBACK_REVERSE_SYNC_TIMEOUT_SEC:-600}"; then
    ftctl_state_set "${vm}" \
      "protection_state=error" \
      "transport_state=reverse_sync_failed" \
      "last_error=reverse_sync_timeout"
    ftctl_log_event "failback" "failback.request" "fail" "${vm}" "" \
      "reason=${reason} reverse_sync=timeout"
    return 1
  fi

  ftctl_state_set "${vm}" \
    "protection_state=failing_back" \
    "transport_state=cutback_switching" \
    "last_error="

  if [[ "${FTCTL_PROFILE_BACKEND_MODE}" == "remote-nbd" ]]; then
    ftctl_blockcopy_stop_primary_reverse_nbd_exports "${vm}" || true
    sleep 2
  fi

  if ! ftctl_standby_deactivate "${vm}"; then
    ftctl_state_set "${vm}" \
      "protection_state=error" \
      "last_error=cutback_secondary_stop_failed"
    ftctl_log_event "failback" "failback.cutback" "fail" "${vm}" "" \
      "reason=${reason} secondary=stop_failed"
    return 1
  fi
  if ! ftctl_primary_activate_from_backup "${vm}"; then
    local primary_activate_error
    primary_activate_error="$(ftctl_state_get "${vm}" "last_error" 2>/dev/null || true)"
    ftctl_state_set "${vm}" \
      "protection_state=error" \
      "last_error=${primary_activate_error:-cutback_primary_activate_failed}"
    ftctl_log_event "failback" "failback.cutback" "fail" "${vm}" "" \
      "reason=${reason} primary=activate_failed"
    return 1
  fi

  ftctl_state_set "${vm}" \
    "active_side=primary" \
    "fencing_state=clear" \
    "protection_state=pairing" \
    "transport_state=initializing" \
    "standby_state="

  if ! ftctl_failback_reprotect_from_primary "${vm}" "${mode}"; then
    ftctl_state_set "${vm}" \
      "protection_state=error" \
      "last_error=cutback_reprotect_failed"
    ftctl_log_event "failback" "failback.cutback" "fail" "${vm}" "" \
      "reason=${reason} reprotect=failed"
    return 1
  fi

  ftctl_log_event "failback" "failback.request" "ok" "${vm}" "" \
    "reason=${reason} reverse_sync=completed cutback=done"
}
