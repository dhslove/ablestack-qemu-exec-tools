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
- `bin/ablestack_vm_ftctl_selftest.sh`
  - QMP progress ready 기반 failback reverse sync 전이 selftest 추가

`ablestack-cloud`

- `plugins/integrations/ftctl-service/src/main/java/com/cloud/ftctl/FtctlServiceImpl.java`
  - cloud-managed failback 중간 단계에서 Cloud가 FTCTL 상태를 직접 생산하던 경로 제거
  - Cloud-owned VM 작업은 이벤트로만 기록
- `ui/src/views/compute/FtctlTab.vue`
  - 장애 보호 탭 전체 background refresh 추가
  - progress-only polling을 protection/runtime/event 포함 갱신으로 확장
  - polling interval을 상태별로 10초/30초로 분리

## 검증 기준

FTCTL 엔진:

- QMP progress JSON이 reverse 방향이고 모든 disk가 ready이면 `reverse_sync_ready`로 전이한다.
- 전이 시 `last_error`를 지우고 `reverse_sync.ready` 이벤트를 기록한다.

Cloud backend:

- Cloud는 FTCTL 고유 상태를 직접 만들지 않는다.
- Cloud-owned VM 작업은 그대로 수행하되 FTCTL 상태 전이는 엔진 snapshot을 따른다.

UI:

- 장애 보호 탭의 보호 주정보, 점검, 상태, 이벤트가 주기적으로 갱신된다.
- background refresh 중 기존 화면이 사라지거나 깜빡이지 않는다.
- 액션 버튼 loading은 버튼 단위로만 표시된다.

HA-RKY:

- full-chain PASS는 clean start에서 `HA-RKY-01`부터 `HA-RKY-15`까지 모두 통과해야 한다.
- 중간 수동 보정이나 서비스 재시작 뒤 성공한 결과는 full-chain PASS로 기록하지 않는다.
