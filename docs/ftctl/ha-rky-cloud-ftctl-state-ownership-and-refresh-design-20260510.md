# HA-RKY Cloud/FTCTL 상태 소유권 및 장애 보호 탭 갱신 통합 설계

- 날짜: 2026-05-10
- 대상: HA-RKY full-chain `HA-RKY-01` ~ `HA-RKY-15`
- 대상 VM: `ha-r9-01` / `i-2-348-VM`
- 관련 저장소:
  - `dhslove/ablestack-qemu-exec-tools`
  - `dhslove/ablestack-cloud`

## 배경

최근 HA-RKY 실행에서 failback 단계 진입 후 standby VM의 reverse blockcopy QMP 진행률은 `ready=true`, `100%`에 도달했지만 Cloud DB/UI는 계속 `failing_back / reverse_syncing / secondary` 상태에 머물렀다.

또한 장애 보호 탭은 sync progress 일부만 주기적으로 갱신하고, 보호 주정보/점검/상태/이벤트는 수동 새로고침 전까지 오래된 값을 유지하는 문제가 있었다.

## 책임 경계

Cloud UI는 화면 표시와 사용자 명령 전달만 담당한다.

- `getFtctlProtection`, `getFtctlCheck`, `getFtctlHealth`, `getFtctlEvents` 결과를 표시한다.
- `pause`, `resume`, `failover`, `failback`, `fence confirm/clear`, `release` 같은 명령을 Cloud API로 전달한다.
- FTCTL 상태 머신을 직접 계산하거나 보정하지 않는다.

Cloud backend는 Cloud 자원 관리, FTCTL 상태 snapshot 캐시, qemu FTCTL 이벤트 조회 중계를 담당한다.

- Cloud가 소유한 VM, volume, NIC 작업만 직접 수행한다.
- Mold Agent로 FTCTL 명령을 전달한다.
- FTCTL 엔진이 반환한 상태 snapshot은 필요 시 캐시하고, 작업성 이벤트는 qemu `events.log`를 원본으로 조회해 API 응답으로 제공한다.
- `reverse_syncing`, `reverse_sync_ready`, `finalizing`, `protected` 같은 FTCTL 고유 상태를 임의로 생산하지 않는다.

Mold Agent는 명령 전달 계층이다.

- Cloud backend의 요청을 서버 측 `ablestack_vm_ftctl` 엔진 명령으로 전달한다.
- stdout JSON과 exit code를 반환한다.
- 상태 판단, Cloud resource orchestration, retry 정책을 소유하지 않는다.

서버 측 FTCTL 엔진은 실제 작업과 이벤트의 원본이다.

- protect/failover/failback/reprotect/unprotect 작업을 수행한다.
- libvirt/QMP/blockjob 상태를 판정한다.
- runtime state, progress, event log를 기록한다.
- Cloud가 수행해야 하는 작업이 필요한 경우 `required_cloud_action` 성격의 상태를 제공하고 Cloud ack 이후 다음 단계로 전이한다.

## 통합 상태 모델

`ftctl_protection`은 보호 관계와 설정의 기준 테이블로 유지한다.

- primary VM, secondary VM, peer host
- mode/backend/provisioning backend
- target storage/volume mapping
- fencing policy

FTCTL runtime 상태는 Cloud가 만든 값이 아니라 FTCTL 엔진 snapshot을 캐시한 값이어야 한다.

- `source=engine`
- `engine_updated_at`
- `workflow_id`
- `phase`
- `protection_state`
- `transport_state`
- `active_side`
- `admin_state`
- `fencing_state`
- `last_error`
- `sync_progress_json`
- `event_seq`

Cloud API는 보호 관계 정보와 FTCTL snapshot cache를 조합해 응답한다.

## Failback 설계

권장 흐름은 다음과 같다.

1. UI가 `failbackFtctlProtection`을 호출한다.
2. Cloud backend가 Mold Agent를 통해 FTCTL failback 명령을 전달한다.
3. FTCTL 엔진이 reverse sync를 시작하고 상태/이벤트를 기록한다.
4. Cloud backend는 FTCTL status polling으로 snapshot cache를 갱신한다.
5. FTCTL 엔진이 reverse blockcopy ready를 판정하면 Cloud가 수행해야 하는 작업을 상태로 노출한다.
6. Cloud backend는 standby VM stop, NIC identity handoff, primary VM start 같은 Cloud-owned 작업만 수행한다.
7. Cloud backend는 작업 결과를 FTCTL 엔진에 ack한다.
8. FTCTL 엔진은 ack를 검증하고 finalize/reprotect 단계로 전이한다.
9. UI는 snapshot/event 갱신 결과만 표시한다.

이번 구현에서는 장기 모델 전체를 한 번에 도입하지 않고, 현재 장애를 막는 최소 변경을 적용했다.

- Cloud backend의 cloud-managed failback 중간 단계에서 직접 `ftctl_protection`/VM detail 상태를 쓰던 `markCloudManagedFailbackStage` 경로를 제거했다.
- Cloud backend는 secondary stop과 primary start 시점에 Cloud 감사 이벤트만 남긴다.
- FTCTL 엔진은 reverse sync 상태 판정 시 per-target `virsh blockjob --info`가 불명확하더라도 QMP progress JSON이 모든 disk에 대해 reverse ready를 보이면 `reverse_sync_ready`로 전이한다.

## 장애 보호 탭 갱신 설계

장애 보호 탭은 progress-only polling에서 tab-wide background refresh로 변경한다.

주기적으로 갱신할 대상:

- protection summary
- protection/transport/active/admin/fencing state
- sync progress
- last error
- check result
- health/runtime status
- FTCTL events

갱신 방식:

- 최초 진입 시에만 전체 loading 상태를 사용한다.
- 이후 polling은 background refresh로 동작한다.
- 기존 섹션 데이터를 비우지 않고 성공한 응답만 병합한다.
- action 실행 중에는 해당 버튼 단위 loading만 표시한다.
- polling 중 `blockingLoadingState`를 사용하지 않는다.

현재 구현된 주기:

- 진행 중 상태: 10초
  - `syncing`
  - `failing_over`
  - `failed_over`
  - `failing_back`
  - `copying`
  - `reverse_syncing`
  - `reverse_sync_ready`
  - `reverse_sync_pending`
  - `finalizing`
  - `primary_restoring`
- 안정 상태: 30초

## 구현 범위

`ablestack-qemu-exec-tools`

- `lib/ftctl/blockcopy.sh`
  - reverse progress JSON을 검사하는 `ftctl_blockcopy_reverse_progress_ready` 추가
  - QMP progress가 reverse ready이면 `reverse_sync_ready`로 전이
- `lib/ftctl/state.sh`, `lib/ftctl/orchestrator.sh`, `lib/ftctl/libvirt_wrap.sh`, `lib/ftctl/events.sh`
  - UI/Cloud 조회용 live probe가 아니라 engine-recorded snapshot을 생성하도록 보완
  - VM별 runtime/check/progress snapshot과 host health snapshot을 원자적으로 기록
  - `${FTCTL_EVENTS_LOG}` JSONL을 작업 이벤트의 단일 원본으로 유지
- `bin/ablestack_vm_ftctl.sh`
  - Cloud가 사용할 read-only snapshot/event export 명령 유지
  - snapshot export는 이미 기록된 파일만 읽고 libvirt/QMP를 호출하지 않음
- `bin/ablestack_vm_ftctl_selftest.sh`
  - QMP progress ready 기반 failback reverse sync 전이 selftest 추가
  - snapshot/event export가 live probe 없이 기록된 state/check/health/progress/event만 반환하는지 검증

`ablestack-cloud`

- `plugins/integrations/ftctl-service/src/main/java/com/cloud/ftctl/FtctlServiceImpl.java`
  - cloud-managed failback 중간 단계에서 Cloud가 FTCTL 상태를 직접 생산하던 경로 제거
  - Cloud-owned VM 작업은 이벤트로만 기록
  - 조회 API에서 host libvirt/QMP/FTCTL engine 작업을 동기 호출하는 경로 제거
  - `getFtctlProtection`의 `refreshruntime` 경로 제거 또는 무시
  - `getFtctlCheck`, `getFtctlHealth`는 DB/cache 기반 응답으로 유지하고, `getFtctlEvents`는 Agent를 통해 qemu `events.log`를 read-only로 조회하도록 전환
- `ui/src/views/compute/FtctlTab.vue`
  - 장애 보호 탭 전체 background refresh 추가
  - progress-only polling을 cache-only protection/check/health/event 갱신으로 확장
  - `refreshruntime=true` 전달 제거
  - polling interval을 상태별로 10초/30초로 분리

## 추가 분석 및 보완 설계

2026-05-10 HA-RKY 재시험에서 reverse sync 자체는 성공했지만 failback cutback 이후 단계가 실패했다.

확인된 런타임 상태:

- `ftctl_protection` active row는 `error / reverse_sync_failed / secondary / manual-fenced` 상태로 남았다.
- primary VM `i-2-348-VM`과 standby VM `i-2-367-VM`은 모두 `Stopped` 상태가 되었다.
- FTCTL progress JSON은 `direction=reverse`, `percent=100.0`, `ready=true`였다.
- 최종 `last_error`는 `reverse_sync_refresh_failed`였지만, 이는 standby domain stop 이후 timer/reconcile이 reverse job을 다시 조회하지 못하면서 덮어쓴 결과로 판단한다.

실패 원인:

- Cloud-managed failback은 reverse sync ready 확인 후 standby VM을 stop하고 `FAILBACK_FINALIZE`를 호출한다.
- 현재 `ftctl_blockcopy_finalize_reverse_sync`는 `remote-nbd` backend만 허용한다.
- HA-RKY는 `shared-blockcopy` backend이므로 finalize 단계에서 `reverse_finalize_unsupported_backend:shared-blockcopy` 성격의 실패가 발생한다.
- 이후 standby domain이 이미 사라진 상태에서 FTCTL refresh가 reverse blockjob을 조회하려 하면서 최종 상태가 `reverse_sync_refresh_failed`로 정리된다.

보완 설계:

1. `shared-blockcopy`용 reverse finalize 경로를 FTCTL 엔진에 추가한다.
   - reverse progress JSON이 `ready=true`이고 모든 disk가 완료된 상태인지 확인한다.
   - primary 쪽 RBD target size/materialization 상태를 검증한다.
   - standby domain stopped 상태를 확인한다.
   - reverse state artifact를 정리하고 `cutback_ready` 또는 다음 reprotect 가능 상태로 전이한다.
   - `remote-nbd` 전용 `qemu-img convert` 경로와 분리해 backend별 finalize 책임을 명확히 한다.

2. Cloud-managed failback 중간 상태의 소유권을 FTCTL로 되돌린다.
   - Cloud backend는 standby stop, NIC handoff, primary start 같은 Cloud-owned 작업만 수행한다.
   - `secondary_stopping`, `finalizing`, `primary_restoring` 같은 workflow 상태는 Cloud가 임의로 DB에 쓰지 않고 FTCTL snapshot 또는 FTCTL ack 결과를 기준으로 반영한다.
   - Cloud 작업이 필요한 시점은 FTCTL이 요구 상태를 기록하고, Cloud는 작업 결과를 FTCTL에 ack하는 방식으로 정리한다.

3. standby stop 이후 reverse job refresh가 상태를 오염시키지 않도록 한다.
   - `finalizing` 이후에는 running standby domain의 QMP blockjob 존재를 전제로 한 refresh를 수행하지 않는다.
   - 이미 `ready=true`로 확정된 reverse progress는 cutback/finalize 검증 입력으로 사용하고, job refresh 실패로 되돌리지 않는다.

## UI 진행률 갱신 보완 설계

현재 UI 표시 레이어는 forward와 reverse를 같은 방식으로 표시한다.

- `syncprogressjson`, `syncprogresspercent`, `syncdirection`, `syncready`를 공통 computed 값으로 풀어 화면에 표시한다.
- forward/reverse의 차이는 UI가 아니라 FTCTL 엔진의 수집 대상에 있다.
  - forward는 primary domain의 QMP blockjob을 조회한다.
  - reverse는 secondary domain의 QMP blockjob을 조회한다.

조회 경로의 원칙은 다음과 같다.

- UI는 host libvirt, QMP, FTCTL 엔진을 직접 또는 조회 API를 통해 동기 호출하지 않는다.
- UI는 Cloud API가 제공하는 protection/check/health snapshot과 qemu `events.log` 기반 event/progress 응답만 표시한다.
- progress 갱신은 FTCTL 엔진이 `events.log`에 기록한 `blockcopy.progress` / `reverse_sync.progress` 이벤트를 Cloud가 read-only로 읽어 전달한 값을 표시한다.
- `refreshruntime=true` 같은 UI-triggered runtime refresh 파라미터는 사용하지 않는다.

소스 검토에서 확인된 원칙 위반 후보:

1. UI `FtctlTab.vue`
   - `fetchProtection({ refreshRuntime: true })`가 `getFtctlProtection`에 `refreshruntime=true`를 전달한다.
   - `refreshProtectionRuntime`과 `fetchSyncProgress`가 이 경로를 주기적으로 호출한다.
   - 이 경로는 조회 화면에서 Agent/host status 호출을 유발하므로 제거 대상이다.

2. Cloud API `getFtctlProtection`
   - `GetFtctlProtectionCmd`가 `refreshruntime` 파라미터를 노출한다.
   - `FtctlServiceImpl.getFtctlProtection`이 `cmd.isRefreshRuntime()`이면 `populateRuntimeStateFromAgent`를 호출한다.
   - `populateRuntimeStateFromAgent`는 `FtctlStatusCommand`를 Agent로 보내 host의 `ablestack_vm_ftctl status --json`을 실행한다.
   - 조회 API에서 이 동기 host 호출 경로는 제거하거나 무시해야 한다.

3. Cloud API `getFtctlCheck`, `getFtctlHealth`
   - 현재 구현은 각각 `FtctlCheckCommand`, `FtctlHealthCommand`를 Agent로 보내 host FTCTL 명령을 실행한다.
   - UI background refresh가 이 API들을 호출하면 조회 화면이 host FTCTL 조회를 직접 유발한다.
   - check/health API는 DB/cache 기반 응답으로 전환해야 한다.

4. Cloud API `getFtctlEvents`
   - 이벤트는 qemu FTCTL의 `/var/log/ablestack-vm-ftctl/events.log` JSONL이 원본이다.
   - 이 일시 작업 이벤트를 Cloud DB에 다시 저장하지 않는다.
   - `getFtctlEvents`는 Agent를 통해 `ablestack_vm_ftctl events --vm <vm> --limit <n> --json`을 실행하되, 이 명령은 libvirt/QMP 상태를 계산하지 않고 이미 기록된 로그 파일만 읽어야 한다.
   - 응답에는 qemu FTCTL 이벤트 목록과 최신 `blockcopy.progress` 또는 `reverse_sync.progress`를 함께 포함한다.

보완 설계:

1. UI 조회는 Cloud API만 사용한다.
   - `FtctlTab.vue`에서 `refreshRuntime` 옵션과 `refreshruntime=true` 파라미터 전달을 제거한다.
   - `fetchSyncProgress`는 별도 runtime refresh가 아니라 `fetchAll({ silent: true })` 또는 cache-only protection 조회로 통합한다.
   - UI polling은 host libvirt/QMP 최신화를 요청하지 않고, Cloud API가 제공한 snapshot 및 qemu event log 응답의 변경분만 표시한다.

2. Cloud 상태 조회 API는 Agent 호출을 하지 않는다.
   - `getFtctlProtection`은 `ftctl_protection`, VM detail, runtime snapshot cache만 읽는다.
   - `refreshruntime` 파라미터는 제거하거나 하위 호환 기간 동안 무시한다.
   - `getFtctlCheck`, `getFtctlHealth`는 cached check/health 테이블 또는 VM detail snapshot에서 응답한다.
   - cache가 없거나 오래된 경우에도 조회 API가 host FTCTL을 즉시 호출하지 않고 `stale`, `unknown`, `not_available` 같은 snapshot 상태를 반환한다.

3. FTCTL runtime/progress/event 소유권은 qemu FTCTL에 둔다.
   - FTCTL 엔진이 실제 작업, progress, event를 서버 측 원본으로 기록한다.
   - runtime/check/health snapshot은 Cloud backend 또는 Mold Agent의 비UI 동기화 경로가 DB/cache로 반영할 수 있다.
   - 작업성 event/progress는 Cloud DB에 중복 저장하지 않고 qemu `events.log`를 read-only 원본으로 사용한다.
   - 동기화 주기는 FTCTL timer, 작업 완료 callback, 별도 backend scheduler 중 하나로 운영하되 UI 요청에 의해 즉시 host 조회가 발생하지 않게 한다.
   - action API는 명령 전달이 목적이므로 Agent 호출이 허용되지만, 응답에 포함되는 상태도 FTCTL이 기록한 결과 또는 동기화된 snapshot을 기준으로 한다.

4. UI의 전체 background refresh와 progress refresh를 단일 갱신 흐름으로 정리한다.
   - 같은 `this.protection` 객체를 여러 비동기 요청이 동시에 덮어쓰지 않도록 request sequence를 둔다.
   - 오래된 응답은 폐기한다.
   - progress-only timer가 필요하면 전체 refresh와 상호 배타적으로 동작하게 한다.

5. section별 화면 깜빡임을 막는다.
   - 최초 로딩 후에는 기존 섹션 데이터를 유지한다.
   - 성공한 응답만 해당 섹션에 병합한다.
   - 실패한 섹션은 기존 값을 유지하고 해당 섹션에만 오류 상태를 표시한다.

## FTCTL 엔진 기록 및 동기화 보완 설계

UI가 Cloud API만 조회하고 host libvirt/QMP 상태를 직접 계산하지 않으려면 qemu host에서 실행되는 FTCTL 엔진이 화면에 필요한 값을 사전에 기록해야 한다. Cloud가 화면 조회 시점에 host libvirt 또는 FTCTL 엔진 작업을 호출하지 않도록, 엔진 기록과 Cloud 조회/동기화는 다음 계약을 따라야 한다.

현재 qemu FTCTL에서 이미 제공되는 기록:

- `ftctl_state_set`은 VM별 runtime state를 `${FTCTL_STATE_DIR}/<vm>.state`에 key/value 형태로 기록한다.
- `ftctl_state_emit_json_one`은 state 파일과 `<vm>.state.blockcopy.progress`를 조합해 status JSON을 만들 수 있다.
- `ftctl_blockcopy_progress_refresh_from_qmp`는 QMP blockjob 결과를 `<vm>.state.blockcopy.progress`에 JSON으로 기록한다.
- `ftctl_log_event`와 `ftctl_events_print`는 `${FTCTL_EVENTS_LOG}` JSONL 이벤트를 원본 이벤트 로그로 제공한다.
- `ablestack-vm-ftctl.timer`는 `ablestack_vm_ftctl reconcile`을 주기 실행해 FTCTL 엔진이 자체적으로 상태를 갱신할 수 있는 실행 경로를 제공한다.

현재 부족한 부분:

- `ablestack_vm_ftctl check --json`은 실행 시점에 inventory를 다시 계산해 출력하지만, 별도 check snapshot 파일로 영속 기록하지 않는다.
- `ablestack_vm_ftctl health --json`은 실행 시점에 libvirt health를 확인하고 이벤트만 남기며, UI가 읽을 수 있는 health snapshot을 별도로 남기지 않는다.
- `ablestack_vm_ftctl events --json`은 host 로그 파일을 직접 읽는 read-only 명령이다. 이 명령은 UI가 직접 호출하지 않고 Cloud가 Agent를 통해 중계한다.
- progress JSON은 기록되어 있지만, UI가 `events.log` 기반 최신 진행율을 우선 적용하는 응답 계약이 필요하다.

보완해야 할 FTCTL 엔진 기록:

1. VM별 runtime snapshot
   - 기존 `<vm>.state`와 `<vm>.state.blockcopy.progress`를 FTCTL runtime 원본으로 유지한다.
   - state에는 `engine_updated_at`, `workflow_id`, `phase`, `state_generation`을 추가해 Cloud가 변경 여부를 판단할 수 있게 한다.
   - progress JSON에는 `updated`, `direction`, `ready`, `percent`, disk별 상태를 유지하고, 변경 시 `state_generation` 또는 `progress_generation`을 증가시킨다.

2. VM별 check snapshot
   - reconcile 주기 또는 상태 변경 시 `ftctl_orchestrator_check_vm` 결과를 `<vm>.state.check.json` 같은 원자적 JSON 파일로 기록한다.
   - 포함 필드:
     - `vm`
     - `result`
     - `inventory_result`
     - `primary_rc`
     - `peer_rc`
     - `peer_domain_expected`
     - `standby_domain_state`
     - `provisioning_backend`
     - `updated`
   - `check --json`은 live 계산용 명령으로 남기더라도 UI/cache 동기화에는 snapshot 파일을 사용한다.

3. host health snapshot
   - FTCTL timer 주기 또는 별도 engine health 주기에서 local libvirt health를 확인하고 `${FTCTL_STATE_DIR}/health.json`에 기록한다.
   - 포함 필드:
     - `result`
     - `uri`
     - `rc`
     - `updated`
     - `host_id` 또는 `host_name`을 식별할 수 있는 값
   - `health --json`은 live probe 명령으로 남기더라도 UI 조회 경로에서는 DB/cache에 동기화된 health snapshot만 사용한다.

4. event/progress 원본 로그
   - 기존 `${FTCTL_EVENTS_LOG}`는 원본 이벤트 로그로 유지한다.
   - Cloud DB에는 동일 이벤트를 중복 저장하지 않는다.
   - Cloud `getFtctlEvents`는 Agent를 통해 이 파일을 read-only로 조회하고, 응답 시 최신 `blockcopy.progress` 또는 `reverse_sync.progress`를 `latestprogress`로 함께 반환한다.
   - forward와 reverse progress는 같은 JSON schema를 사용하고 `direction` 및 event name으로 구분한다.

5. read-only snapshot/event export
   - Mold Agent가 비UI 동기화 작업에서 호출할 수 있는 read-only export 명령을 둔다.
   - 이 명령은 libvirt/QMP/FTCTL 작업을 수행하지 않고, 이미 기록된 state/check/health/progress/event 파일만 읽어 JSON으로 반환한다.
   - 예: `ablestack_vm_ftctl snapshot --vm <vm> --json`, `ablestack_vm_ftctl snapshot --all --json`
   - `events --json`은 `events.log` 파일만 읽는 read-only 명령이므로 Cloud event API에서 사용할 수 있다.
   - 기존 `status/check/health` 명령이 live probe 의미를 유지한다면 Cloud UI 조회 API에서는 사용하지 않는다.

Cloud 동기화/조회 계약:

- Cloud backend 또는 Mold Agent scheduler는 UI 요청과 무관하게 read-only snapshot export를 주기적으로 수집할 수 있다.
- runtime/check/health 수집 결과는 Cloud DB/cache에 저장한다.
- event/progress는 qemu `events.log`가 단일 원본이므로 Cloud DB에 복제하지 않는다.
- UI 조회 API는 protection/check/health는 DB/cache에서 읽고, event/progress는 Cloud가 Agent를 통해 `events.log`를 read-only로 읽어 반환한다.
- action API가 FTCTL 명령을 실행한 직후에도 화면 응답은 live 재조회가 아니라 명령 결과와 이후 동기화된 snapshot을 기준으로 갱신한다.
- snapshot이 오래되었으면 UI에는 `stale` 또는 `updated` 시각을 표시하고, 상태 조회 API가 host에 즉시 재조회하지 않는다.

## HA-RKY 테스트 자동화 보완

HA-RKY는 `manual-block` fencing policy를 사용한다. 따라서 자동화는 manual fence의 두 작업을 모두 UI 중심으로 검증해야 한다.

현재 반영된 단계:

- failover 중 `confirmFtctlFence` UI 작업은 반영되어 있다.
- 해당 증거는 `08-confirm-fence-*` artifact와 `ui-confirmFtctlFence-*` artifact로 남는다.

추가 반영이 필요한 단계:

- failback으로 active side가 primary로 돌아온 뒤 UI에서 `clearFtctlFence`를 명시적으로 실행한다.
- `clearFtctlFence` 실행 결과로 `fencing_state=clear`를 확인한다.
- 그 이후 blockjob 잔존 여부, guest QGA/NIC 유지, release cleanup을 검증한다.

권장 step 재정의:

- `HA-RKY-11-FAILBACK-ACTION`
  - UI `failbackFtctlProtection` 실행
  - primary VM `Running`, `active_side=primary` 도달 확인
- `HA-RKY-12-FAILBACK-GUEST`
  - primary guest QGA 응답 확인
  - failover 전 IP/MAC 유지 확인
- `HA-RKY-13-FENCE-CLEAR-UI`
  - UI `clearFtctlFence` 실행
  - `fencing_state=clear` 확인
- `HA-RKY-14-FAILBACK-CONSISTENCY`
  - protection/transport/active/admin/fencing state 정합성 확인
  - `query-block-jobs` 결과가 비어 있는지 확인
- `HA-RKY-15-RELEASE-AND-RESIDUAL`
  - UI `releaseFtctlProtection` 실행
  - DB/runtime/RBD 잔여 자원 없음 확인

이번 실패는 `HA-RKY-11-FAILBACK-ACTION` 단계에서 primary 복귀 전에 발생했으므로, `clearFtctlFence` 단계까지 도달하지 못했다. 따라서 fence clear 누락이 이번 실패의 직접 원인은 아니지만, full-chain 자동화에는 반드시 포함해야 한다.

## 검증 기준

FTCTL 엔진:

- QMP progress JSON이 reverse 방향이고 모든 disk가 ready이면 `reverse_sync_ready`로 전이한다.
- 전이 시 `last_error`를 지우고 `reverse_sync.ready` 이벤트를 기록한다.
- `shared-blockcopy` failback finalize가 reverse progress ready 상태를 기준으로 성공해야 한다.
- standby stop 이후에는 reverse job refresh 실패가 이미 확정된 ready 상태를 `reverse_sync_failed`로 되돌리지 않아야 한다.
- reconcile 또는 engine 주기 실행이 runtime/check/health/progress/event snapshot을 기록해야 한다.
- read-only snapshot export는 libvirt/QMP 호출 없이 기록된 파일만 반환해야 한다.
- snapshot에는 Cloud가 변경분을 판단할 수 있는 `updated`와 generation 또는 sequence 정보가 있어야 한다.

Cloud backend:

- Cloud는 FTCTL 고유 상태를 직접 만들지 않는다.
- Cloud-owned VM 작업은 그대로 수행하되 FTCTL 상태 전이는 엔진 snapshot을 따른다.
- Cloud-managed failback 중 standby stop, NIC handoff, primary start 결과는 FTCTL ack/snapshot으로 동기화한다.
- 상태 조회 API는 host 호출 없이 Cloud DB/cache만 읽어야 한다.
- 이벤트 조회 API는 qemu `events.log`를 Agent로 read-only 조회해 UI에 전달하되, Cloud DB에 중복 기록하지 않는다.
- Cloud의 비UI 동기화 경로만 read-only snapshot export를 호출할 수 있다.

UI:

- 장애 보호 탭의 보호 주정보, 점검, 상태, 이벤트가 주기적으로 갱신된다.
- background refresh 중 기존 화면이 사라지거나 깜빡이지 않는다.
- 액션 버튼 loading은 버튼 단위로만 표시된다.
- UI는 `refreshruntime=true` 또는 이에 준하는 host runtime refresh를 호출하지 않는다.
- forward와 reverse progress는 같은 schema로 표시하되, 실제 기록은 FTCTL 엔진의 `events.log`에 남긴 값을 사용해야 한다.
- `getFtctlProtection`, `getFtctlCheck`, `getFtctlHealth`는 UI 조회 경로에서 DB/cache 응답만 반환해야 한다.
- `getFtctlEvents`는 qemu FTCTL event log와 latest progress를 반환해야 하며 Cloud 이벤트 테이블을 사용하지 않아야 한다.

HA-RKY:

- full-chain PASS는 clean start에서 `HA-RKY-01`부터 `HA-RKY-15`까지 모두 통과해야 한다.
- 중간 수동 보정이나 서비스 재시작 뒤 성공한 결과는 full-chain PASS로 기록하지 않는다.
- `manual-block` 정책에서는 failover의 `confirmFtctlFence`와 failback 이후의 `clearFtctlFence`를 모두 UI 작업으로 검증한다.

## 2026-05-11 HA-RKY failback 실패 확정 분석 및 개선 확정안

이 섹션은 2026-05-11 HA-RKY 수동 UI 재시험에서 확인한 결과를 기준으로 하며, 위의 이전 failback/fence 순서 설명보다 우선 적용한다.

### 확인된 실패 흐름

수동 UI 절차에서 다음 순서까지는 정상 진행되었다.

1. UI `clearFtctlFence` 실행.
2. `fencing_state=clear` 확인.
3. UI `failbackFtctlProtection` 실행.
4. reverse block copy 진행.
5. reverse progress가 `direction=reverse`, `percent=100.0`, `ready=true`로 도달.
6. Cloud-managed failback monitor가 secondary VM `i-2-373-VM`을 정지.
7. primary VM `i-2-348-VM`이 기동되지 않고 최종 상태가 `rearm_exhausted`로 전이.

현재 DB와 runtime 상태는 다음과 일치했다.

- `ftctl_protection` active row `72`
  - `protection_state=error`
  - `transport_state=rearm_exhausted`
  - `active_side=secondary`
  - `fencing_state=clear`
  - `last_error=rearm_attempts_exhausted`
- primary VM `i-2-348-VM`: `Stopped`
- secondary VM `i-2-373-VM`: `Stopped`
- standby volumes `465`, `466`: active `Ready`
- qemu FTCTL progress file: reverse 100%, ready true

### 직접 원인

직접 원인은 primary VM start 코드 부재가 아니라, Cloud failback workflow가 primary start 단계까지 도달하지 못한 것이다.

Cloud failback cutback 구현 순서는 다음과 같다.

1. reverse sync ready 확인.
2. `stopSecondaryVmForCloudManagedFailback`.
3. `FAILBACK_FINALIZE` agent action 호출.
4. NIC identity handoff.
5. `startPrimaryVmForCloudManagedFailback`.
6. `FAILBACK_REPROTECT`.

이번 실패에서는 3단계에서 중단되었다. host 설치본 `/usr/local/lib/ablestack-qemu-exec-tools/ftctl/blockcopy.sh`의 `ftctl_blockcopy_finalize_reverse_sync()`는 현재 다음 조건으로 `shared-blockcopy` backend를 거부한다.

```bash
[[ "${FTCTL_PROFILE_BACKEND_MODE:-}" == "remote-nbd" ]] || {
  ftctl_state_set "${vm}" "last_error=reverse_finalize_unsupported_backend:${FTCTL_PROFILE_BACKEND_MODE:-}"
  return 2
}
```

따라서 Cloud log와 qemu events.log는 다음 실패를 기록했다.

- `FAILBACK_FINALIZE` result: fail
- `last_error=reverse_finalize_unsupported_backend:shared-blockcopy`
- qemu event: `failback.finalize fail`

이 예외 때문에 Cloud는 `handoffNicIdentityToPrimary()`와 `startPrimaryVmForCloudManagedFailback()`를 실행하지 못했다.

### rearm_exhausted의 성격

`rearm_exhausted`는 1차 원인이 아니라 후속 상태 오염이다.

`FAILBACK_FINALIZE` 실패 후 secondary VM은 이미 Cloud에 의해 정지되었고, primary VM은 아직 시작되지 않았다. 이 중간 상태에서 qemu FTCTL timer/reconcile이 계속 실행되면서 다음처럼 판단했다.

- `primary_domain_state=not-found`
- `standby_domain_state=not-found`
- `active_side=secondary`
- `peer_domain_expected=true`

그 결과 auto-rearm을 반복했고, `FTCTL_MAX_REARM_ATTEMPTS=5`에 도달하여 다음 상태로 덮었다.

- `protection_state=error`
- `transport_state=rearm_exhausted`
- `last_error=rearm_attempts_exhausted`

따라서 최종 UI의 `rearm_exhausted`만 보면 원인을 오해할 수 있다. 실제 최초 실패 지점은 `reverse_finalize_unsupported_backend:shared-blockcopy`이다.

### 확정 개선 방향

#### 1. qemu FTCTL: shared-blockcopy reverse finalize 지원

`ftctl_blockcopy_finalize_reverse_sync()`는 backend별 finalize 전략을 분리해야 한다.

- `remote-nbd`
  - 기존 `qemu-img convert` 기반 finalize 경로 유지.
- `shared-blockcopy`
  - reverse progress JSON이 `ready=true`이고 모든 disk가 ready인지 확인.
  - reverse state file의 source/dest가 primary RBD target과 standby RBD source를 정확히 가리키는지 확인.
  - primary RBD target size와 reverse progress total/target size 정합성 확인.
  - standby domain이 stopped 또는 not-defined 상태인지 확인.
  - shared RBD reverse blockcopy가 이미 target에 materialize된 것으로 확정되면 remote-nbd 전용 convert를 수행하지 않는다.
  - reverse state artifact를 정리하고 `transport_state=cutback_ready` 또는 다음 Cloud cutback 가능 상태로 전이한다.
  - `last_error`를 비운다.
  - `failback.reverse_finalize.shared` 또는 `reverse_sync.finalize` ok 이벤트를 남긴다.

검증 실패 시에는 구체적인 원인을 남긴다.

- `reverse_finalize_missing_state`
- `reverse_finalize_progress_not_ready`
- `reverse_finalize_disk_not_ready:<target>`
- `reverse_finalize_size_mismatch:<target>:<expected>:<actual>`
- `reverse_finalize_secondary_running`
- `reverse_finalize_shared_target_invalid:<target>`

#### 2. qemu FTCTL: Cloud-managed failback cutback 중 auto-rearm 억제

Cloud-managed failback의 cutback 구간은 일반 장애 복구 rearm 대상이 아니다.

FTCTL reconcile은 다음 상태에서는 auto-rearm을 수행하지 않아야 한다.

- `transport_state=reverse_sync_ready`
- `transport_state=reverse_sync_cutback_required`
- `transport_state=secondary_stopping`
- `transport_state=finalizing`
- `transport_state=cutback_ready`
- `transport_state=primary_restoring`
- `last_error=reverse_sync_pending`

특히 standby domain이 Cloud에 의해 정지된 직후에는 `standby_domain_state=not-found`가 정상 중간 상태일 수 있다. 이 경우 `rearm_count`를 증가시키거나 `rearm_exhausted`로 전이하면 안 된다.

권장 상태 전이는 다음과 같다.

- reverse ready 이후: `failing_back / reverse_sync_ready / secondary`
- secondary stop 이후: `failing_back / secondary_stopping` 또는 `failing_back / finalizing`
- shared finalize 성공 이후: `failing_back / cutback_ready`
- Cloud primary start 중: `failing_back / primary_restoring`
- reprotect 성공 이후: `protected / mirroring / primary`

#### 3. Cloud: FAILBACK_FINALIZE 실패 시 primary start로 진행하지 않는다

Cloud는 지금처럼 `FAILBACK_FINALIZE` 실패 시 primary start로 진행하지 않는 것이 맞다. reverse finalize 실패 상태에서 primary를 시작하면 데이터 정합성을 보장할 수 없다.

다만 실패를 명확히 보존해야 한다.

- Cloud는 `FAILBACK_FINALIZE` 실패 원문을 `cloud_managed_failback_failed:<reason>` 형태로 보존한다.
- 이후 runtime sync가 `rearm_exhausted`로 원인을 덮어쓰지 않도록 FTCTL engine이 cutback 상태에서 rearm을 억제해야 한다.
- UI는 최종 `rearm_exhausted`만 표시하지 말고 qemu events.log의 최초 failback failure 이벤트도 함께 보여야 한다.

#### 4. Cloud: primary start 코드 보강은 보조 개선

primary start 코드 자체는 존재하지만, 다음 보강은 필요하다.

- `startPrimaryVmForCloudManagedFailback()` 호출 전후에 명확한 FTCTL/Cloud 이벤트를 남긴다.
- start 실패 시 `Unable to start FTCTL primary VM ...` 원문, host id, CloudStack async job id, VM state를 보존한다.
- primary start 실패와 qemu finalize 실패를 구분해서 UI에 표시한다.

이번 실패에는 primary start 실패 로그가 없었다. 따라서 primary start code path 자체까지 도달하지 못한 것으로 판단한다.

### manual fence 순서 확정

HA-RKY `manual-block` 정책의 failback 순서는 다음으로 확정한다.

1. failover 완료.
2. operator가 primary host/storage 복구를 확인.
3. UI `clearFtctlFence` 실행.
4. `fencing_state=clear` 확인.
5. UI `failbackFtctlProtection` 실행.
6. reverse block copy 진행 및 완료.
7. Cloud-managed cutback:
   - secondary stop
   - FTCTL finalize
   - NIC handoff
   - primary start
   - reprotect
8. primary guest/QGA/NIC 확인.
9. release 및 residual cleanup.

즉 `clearFtctlFence`는 reverse block copy/failback 이전에 수행한다. failback 이후 fence clear를 수행한다는 이전 자동화 설명은 폐기한다.

### 테스트 기준

수정 후 HA-RKY full-chain PASS 기준은 다음이다.

- clean start에서 보호 설정부터 release까지 단일 체인으로 진행한다.
- `clearFtctlFence`가 `failbackFtctlProtection`보다 먼저 호출된 증거가 UI/API artifact에 남아야 한다.
- reverse progress가 UI에 계속 표시되어야 하며, 값은 qemu events.log 기반이어야 한다.
- `FAILBACK_FINALIZE`가 `shared-blockcopy`에서 성공해야 한다.
- secondary stop 이후에도 `rearm_count`가 증가하지 않아야 한다.
- primary VM이 Cloud에 의해 원래 primary host에서 Running 상태로 복구되어야 한다.
- 최종 상태는 `protected / mirroring / primary / clear`이어야 한다.
- release 후 active protection, ftctl details, standby VM, standby volumes, blockjobs, stale RBD maps가 남지 않아야 한다.
