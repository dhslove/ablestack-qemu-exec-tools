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

Cloud backend는 Cloud 자원 관리와 FTCTL snapshot 캐시를 담당한다.

- Cloud가 소유한 VM, volume, NIC 작업만 직접 수행한다.
- Mold Agent로 FTCTL 명령을 전달한다.
- FTCTL 엔진이 반환한 상태와 이벤트를 조회/캐시하여 API 응답으로 제공한다.
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
  - 이벤트 동기화용 `event_seq` 또는 cursor 계약 추가
- `bin/ablestack_vm_ftctl.sh`
  - Cloud 비UI 동기화가 사용할 read-only snapshot export 명령 추가
  - snapshot export는 이미 기록된 파일만 읽고 libvirt/QMP를 호출하지 않음
- `bin/ablestack_vm_ftctl_selftest.sh`
  - QMP progress ready 기반 failback reverse sync 전이 selftest 추가
  - snapshot export가 live probe 없이 기록된 state/check/health/progress/event만 반환하는지 검증

`ablestack-cloud`

- `plugins/integrations/ftctl-service/src/main/java/com/cloud/ftctl/FtctlServiceImpl.java`
  - cloud-managed failback 중간 단계에서 Cloud가 FTCTL 상태를 직접 생산하던 경로 제거
  - Cloud-owned VM 작업은 이벤트로만 기록
  - 조회 API에서 Agent/host FTCTL을 동기 호출하는 경로 제거
  - `getFtctlProtection`의 `refreshruntime` 경로 제거 또는 무시
  - `getFtctlCheck`, `getFtctlHealth`, `getFtctlEvents`를 DB/cache 기반 응답으로 전환
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
- UI는 Cloud API가 DB/cache에서 읽어 제공하는 protection/check/health/event snapshot만 표시한다.
- progress 갱신은 FTCTL 엔진이 수행한 작업 및 이벤트 기록의 결과가 DB/cache로 동기화된 값을 표시한다.
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

3. Cloud API `getFtctlCheck`, `getFtctlHealth`, `getFtctlEvents`
   - 현재 구현은 각각 `FtctlCheckCommand`, `FtctlHealthCommand`, `FtctlEventsCommand`를 Agent로 보내 host FTCTL 명령을 실행한다.
   - UI background refresh가 이 API들을 호출하면 조회 화면이 host FTCTL 조회를 직접 유발한다.
   - 이 API들은 DB/cache 기반 응답으로 전환해야 한다.

보완 설계:

1. UI 조회는 DB/cache API만 사용한다.
   - `FtctlTab.vue`에서 `refreshRuntime` 옵션과 `refreshruntime=true` 파라미터 전달을 제거한다.
   - `fetchSyncProgress`는 별도 runtime refresh가 아니라 `fetchAll({ silent: true })` 또는 cache-only protection 조회로 통합한다.
   - UI polling은 host 최신화를 요청하지 않고, 이미 동기화된 snapshot의 변경분만 표시한다.

2. Cloud 조회 API는 Agent 호출을 하지 않는다.
   - `getFtctlProtection`은 `ftctl_protection`, VM detail, runtime snapshot cache만 읽는다.
   - `refreshruntime` 파라미터는 제거하거나 하위 호환 기간 동안 무시한다.
   - `getFtctlCheck`, `getFtctlHealth`, `getFtctlEvents`는 cached check/health/event 테이블 또는 VM detail snapshot에서 응답한다.
   - cache가 없거나 오래된 경우에도 조회 API가 host FTCTL을 즉시 호출하지 않고 `stale`, `unknown`, `not_available` 같은 snapshot 상태를 반환한다.

3. FTCTL runtime/progress/event 동기화는 UI와 분리한다.
   - FTCTL 엔진이 실제 작업, progress, event를 서버 측 원본으로 기록한다.
   - Cloud backend 또는 Mold Agent의 비UI 동기화 경로가 이 원본을 DB/cache로 반영한다.
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

UI가 DB/cache만 조회하려면 qemu host에서 실행되는 FTCTL 엔진이 화면에 필요한 값을 사전에 기록해야 한다. Cloud가 화면 조회 시점에 host libvirt 또는 FTCTL 엔진을 호출하지 않도록, 엔진 기록과 Cloud 동기화는 다음 계약을 따라야 한다.

현재 qemu FTCTL에서 이미 제공되는 기록:

- `ftctl_state_set`은 VM별 runtime state를 `${FTCTL_STATE_DIR}/<vm>.state`에 key/value 형태로 기록한다.
- `ftctl_state_emit_json_one`은 state 파일과 `<vm>.state.blockcopy.progress`를 조합해 status JSON을 만들 수 있다.
- `ftctl_blockcopy_progress_refresh_from_qmp`는 QMP blockjob 결과를 `<vm>.state.blockcopy.progress`에 JSON으로 기록한다.
- `ftctl_log_event`와 `ftctl_events_print`는 `${FTCTL_EVENTS_LOG}` JSONL 이벤트를 원본 이벤트 로그로 제공한다.
- `ablestack-vm-ftctl.timer`는 `ablestack_vm_ftctl reconcile`을 주기 실행해 FTCTL 엔진이 자체적으로 상태를 갱신할 수 있는 실행 경로를 제공한다.

현재 부족한 부분:

- `ablestack_vm_ftctl check --json`은 실행 시점에 inventory를 다시 계산해 출력하지만, 별도 check snapshot 파일로 영속 기록하지 않는다.
- `ablestack_vm_ftctl health --json`은 실행 시점에 libvirt health를 확인하고 이벤트만 남기며, UI가 읽을 수 있는 health snapshot을 별도로 남기지 않는다.
- `ablestack_vm_ftctl events --json`은 host 로그 파일을 직접 읽는 명령이다. UI 조회 경로에서 이 명령을 호출하면 원칙에 어긋난다.
- progress JSON은 기록되어 있지만, Cloud DB/cache와의 동기화 cursor 또는 event sequence 계약이 명확하지 않다.

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

4. event sync cursor
   - 기존 `${FTCTL_EVENTS_LOG}`는 원본 이벤트 로그로 유지한다.
   - 각 이벤트에 `event_seq` 또는 `event_id`를 추가하거나, Cloud sync가 파일 offset과 timestamp를 cursor로 관리할 수 있게 한다.
   - Cloud DB에는 이벤트를 중복 삽입하지 않도록 `(host, vm, event_seq)` 또는 이에 준하는 idempotency key를 둔다.

5. read-only snapshot export
   - Mold Agent가 비UI 동기화 작업에서 호출할 수 있는 read-only export 명령을 둔다.
   - 이 명령은 libvirt/QMP/FTCTL 작업을 수행하지 않고, 이미 기록된 state/check/health/progress/event 파일만 읽어 JSON으로 반환한다.
   - 예: `ablestack_vm_ftctl snapshot --vm <vm> --json`, `ablestack_vm_ftctl snapshot --all --json`
   - 기존 `status/check/health/events` 명령이 live probe 의미를 유지한다면 Cloud UI 조회 API에서는 사용하지 않는다.

Cloud 동기화 계약:

- Cloud backend 또는 Mold Agent scheduler는 UI 요청과 무관하게 read-only snapshot export를 주기적으로 수집한다.
- 수집 결과를 Cloud DB/cache에 저장한다.
- UI 조회 API는 이 DB/cache만 읽는다.
- action API가 FTCTL 명령을 실행한 직후에도 화면 응답은 live 재조회가 아니라 명령 결과와 이후 동기화된 snapshot을 기준으로 갱신한다.
- snapshot이 오래되었으면 UI에는 `stale` 또는 `updated` 시각을 표시하고, 조회 API가 host에 즉시 재조회하지 않는다.

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
- UI 조회 API는 host 호출 없이 Cloud DB/cache만 읽어야 한다.
- Cloud의 비UI 동기화 경로만 read-only snapshot export를 호출할 수 있다.

UI:

- 장애 보호 탭의 보호 주정보, 점검, 상태, 이벤트가 주기적으로 갱신된다.
- background refresh 중 기존 화면이 사라지거나 깜빡이지 않는다.
- 액션 버튼 loading은 버튼 단위로만 표시된다.
- UI는 `refreshruntime=true` 또는 이에 준하는 host runtime refresh를 호출하지 않는다.
- forward와 reverse progress는 같은 schema로 표시하되, 실제 refresh와 기록은 FTCTL 엔진 및 비UI 동기화 경로가 수행해야 한다.
- `getFtctlProtection`, `getFtctlCheck`, `getFtctlHealth`, `getFtctlEvents`는 UI 조회 경로에서 DB/cache 응답만 반환해야 한다.

HA-RKY:

- full-chain PASS는 clean start에서 `HA-RKY-01`부터 `HA-RKY-15`까지 모두 통과해야 한다.
- 중간 수동 보정이나 서비스 재시작 뒤 성공한 결과는 full-chain PASS로 기록하지 않는다.
- `manual-block` 정책에서는 failover의 `confirmFtctlFence`와 failback 이후의 `clearFtctlFence`를 모두 UI 작업으로 검증한다.
