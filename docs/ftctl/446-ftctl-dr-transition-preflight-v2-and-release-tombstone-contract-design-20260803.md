# 446. FTCTL DR Transition Preflight V2 And Release Tombstone Contract Design

> 2026-08-04 normative live-runtime correction:
> [449-ftctl-dr-live-runtime-observation-and-projection-boundary-design-20260804.md](449-ftctl-dr-live-runtime-observation-and-projection-boundary-design-20260804.md)
> clarifies that transition preflight validates FTCTL-owned projection and
> authority state only. Mold Agent and vCenter remain authoritative for live VM
> power, and reverse preflight requires the live KVM source domain.

- 작성일: 2026-08-03
- 상태: 상세 코드 설계 완료, 구현 대기
- Cloud 상위 설계:
  `ablestack-cloud/docs/ftctl/589-cross-hypervisor-dr-reprotect-preflight-and-release-terminal-convergence-design-20260803.md`
- 선행 설계: 441, 444, 445

## 1. 목적

Cloud의 Failback/Reprotect transition preflight가 일반 `dr-status` 응답과
혼동되지 않도록 버전이 명시된 strict JSON envelope를 정의한다. 또한
`dr-release` 완료 후 profile과 runtime이 제거돼도 Cloud가 terminal 상태를
검증할 수 있는 plan-scoped release tombstone을 정의한다.

FTCTL은 다음 책임만 가진다.

- authority journal과 generation 조회
- scheduler/worker/lock 조회
- target power/source isolation evidence 조회
- transition readiness의 data-plane 판정
- release 시 scheduler/runtime/profile 정리
- release terminal evidence 유지

FTCTL은 Cloud Plan 상태, UI action eligibility 또는 Cloud VM lifecycle을
변경하지 않는다.

## 2. 현재 계약 결함

현재 구현 `ftctl_dr_runtime_transition_preflight()`는 필요한 핵심 값을
반환하지만 다음 식별 정보가 없다.

```text
schema_version
contract_version
status_scope
retryable
checked_at_epoch_ms
```

구형 Agent가 `TRANSITION_PREFLIGHT`를 이해하지 못하면 일반 `PLAN_AUTHORITY`
JSON을 반환할 수 있다. Cloud가 JSON 문자열에서 `ready`만 찾는 방식으로는
실제 safety failure와 배포 버전 불일치를 구분하기 어렵다.

현재 `dr-release`는 `RELEASED/release-completed`를 만들지만 Cloud가 확인해야
하는 다음 불변조건을 하나의 terminal envelope로 제공하지 않는다.

```text
release 직전 authority
scheduler/worker 종료
profile/runtime 정리
VM 무변경
release identity
```

2026-08-03의 10.10.32.2 읽기 전용 확인에서는 help에 `dr-capabilities`가
표시되는데도 `ablestack_vm_ftctl dr-capabilities --json`이 capability JSON이
아닌 usage를 반환했다. 배포 검증은 단순 help marker가 아니라 실제 strict JSON
실행과 feature 목록을 기준으로 해야 한다.

## 3. Transition Preflight V2 명령

CLI는 기존 형식을 유지한다.

```bash
ablestack_vm_ftctl dr-transition-preflight \
  --plan <plan-uuid> \
  --operation failback|reprotect \
  --expected-authority TARGET \
  --authority-generation <generation> \
  --json
```

### 3.1 성공 envelope

```json
{
  "command": "dr-transition-preflight",
  "schema_version": "2",
  "contract_version": "dr-transition-preflight-v2",
  "status_scope": "TRANSITION_PREFLIGHT",
  "result": "ready",
  "ready": true,
  "plan_uuid": "2514a846-64a2-4bc7-ba88-38a874410782",
  "operation": "reprotect",
  "expected_authority": "TARGET",
  "active_side": "TARGET",
  "expected_generation": 2160,
  "authority_generation": 2160,
  "target_power_state": "POWERED_ON",
  "source_fence_state": "ACKNOWLEDGED",
  "source_power_state": "UNKNOWN",
  "scheduler_state": "STOPPED",
  "active_operation": "",
  "reverse_write_path_state": "READY",
  "split_brain_guard_state": "SAFE",
  "retryable": false,
  "error_code": "",
  "message": "transition preflight ready",
  "checked_at_epoch_ms": 1785730000000,
  "exit_code": 0
}
```

### 3.2 실패 envelope

```json
{
  "command": "dr-transition-preflight",
  "schema_version": "2",
  "contract_version": "dr-transition-preflight-v2",
  "status_scope": "TRANSITION_PREFLIGHT",
  "result": "rejected",
  "ready": false,
  "plan_uuid": "...",
  "operation": "reprotect",
  "expected_authority": "TARGET",
  "active_side": "SOURCE",
  "expected_generation": 2160,
  "authority_generation": 2159,
  "retryable": false,
  "error_code": "DR_TRANSITION_PREFLIGHT_AUTHORITY_MISMATCH",
  "message": "FTCTL authority does not match the Cloud transition authority",
  "checked_at_epoch_ms": 1785730000000,
  "exit_code": 79
}
```

### 3.3 종료 코드

초기 v2 구현은 프로세스 종료 코드를 단순하게 유지한다.

| 코드 | 의미 |
| --- | --- |
| 0 | `ready=true` |
| 79 | typed preflight rejection |
| 2 | CLI/profile/JSON 생성 자체 실패 |
| 124/137 | timeout/forced termination |

세부 원인과 retry 가능 여부는 반드시 JSON의 `error_code`와 `retryable`로
전달한다. Agent는 stderr 문자열로 원인을 추론하지 않는다.

## 4. V2 검증 순서

`ftctl_dr_runtime_transition_preflight()`를 다음 순서로 확장한다.

1. plan UUID와 operation 검증
2. status/profile identity 검증
3. active side 확인
4. Cloud expected generation 비교
5. target serving power evidence 확인
6. source fence 또는 source power-off evidence 확인
7. plan-scoped active operation/lock 확인
8. scheduler가 transition과 충돌하지 않는지 확인
9. reverse provider/locator parse
10. persistent mapping을 만들지 않는 read-only endpoint probe
11. split-brain guard 판정
12. 한 개의 strict JSON object 출력

Reprotect readiness:

```text
active_side == TARGET
authority_generation == expected_generation
target_power_state == POWERED_ON
source_fence_state in {ACKNOWLEDGED, CONFIRMED, FENCED, ISOLATED, BLOCKED}
  OR source_power_state == POWERED_OFF
active operation 없음
reverse write path READY
split-brain guard SAFE
```

Failback은 위 조건에 더해 reverse baseline/final-delta readiness를 확인한다.

## 5. Read-only 불변조건

preflight 전후 다음 checksum/값은 같아야 한다.

```text
plan status file checksum
profile checksum
authority generation
scheduler desired state
worker identity
VM power state
source fence state
active lock owner
baseline/checkpoint sequence
```

probe용 handle은 `trap/finally`에서 해제한다. 다음 자원을 만들지 않는다.

- persistent NBD device
- RBD map
- VMware snapshot
- libvirt domain mutation
- scheduler unit
- profile/state rewrite

## 6. Capability 계약

`ftctl_dr_runtime_capabilities()`에 다음 feature를 추가한다.

```text
dr-transition-preflight-v2
dr-release-tombstone-v1
```

기존 `dr-transition-preflight-v1`은 mixed-version 식별을 위해 유지할 수 있지만
Cloud의 새 Reprotect/Failback 경로는 v2를 필수로 요구한다.

Capabilities JSON에는 다음을 유지한다.

```text
ftctl_version
runtime_schema_version
action_contract_version
supported_commands
supported_features
```

## 7. Release Tombstone 계약

### 7.1 목적

Release는 scheduler/profile/runtime을 정리하므로 일반 status 파일만 삭제하면
Cloud가 성공을 재검증할 근거가 사라진다. 따라서 최소 terminal evidence를
plan-scoped tombstone으로 남긴다.

경로:

```text
/run/ablestack-vm-ftctl/dr-runtime/plans/<plan-uuid>/release.json
```

또는 기존 plan status 경로가 terminal status를 보존하도록 구현할 수 있다.
어느 방식을 사용하든 `dr-status --scope plan-authority`에서 같은 envelope가
조회돼야 한다.

### 7.2 Release 성공 envelope

```json
{
  "command": "dr-release",
  "schema_version": "1",
  "contract_version": "dr-release-tombstone-v1",
  "status_scope": "PLAN_AUTHORITY",
  "result": "ok",
  "state": "RELEASED",
  "step": "release-completed",
  "progress": 100,
  "plan_uuid": "...",
  "run_uuid": "...",
  "release_id": "...",
  "released_authority_side": "TARGET",
  "authority_generation": 2160,
  "scheduler_state": "STOPPED",
  "scheduler_desired_state": "STOPPED",
  "worker_state": "IDLE",
  "active_worker_run_uuid": "",
  "profile_removed": true,
  "runtime_removed": true,
  "checkpoint_lease_state": "RELEASED",
  "target_vm_present": true,
  "vm_mutated": false,
  "storage_mutated": false,
  "network_mutated": false,
  "force": false,
  "completed_at_epoch_ms": 1785730000000,
  "error_code": "",
  "exit_code": 0
}
```

### 7.3 VM 무변경

`dr-release`는 다음 명령을 호출하지 않는다.

```text
virsh start/shutdown/destroy/undefine
Cloud VM API
volume delete/detach
network attach/detach
guest preparation
```

VM lifecycle은 Cloud가 별도 작업으로만 수행한다.

### 7.4 Tombstone 수명

- 같은 Plan의 보호 재구성이 성공할 때까지 유지
- Plan delete가 확인된 후 정리 가능
- 같은 Plan에서 새 full seed가 시작되면 이전 tombstone을 history로 이동
- timer/reconcile은 tombstone을 active protection profile로 해석하지 않음

## 8. Force Release 계약

FTCTL은 다음 필드를 Run context에서 받는다.

```text
force
acknowledgement
reason
```

검증:

```text
force=false -> normal release preflight 필수
force=true  -> acknowledgement=true AND reason non-empty
```

force가 true여도 VM mutation 금지 불변조건은 바뀌지 않는다. 강제 경로는 stale
lock/profile/runtime을 정리하는 것이지 운영 VM을 정리하는 기능이 아니다.

## 9. 구현 대상

- `lib/ftctl/dr_runtime.sh`
  - `ftctl_dr_runtime_transition_preflight()` v2 envelope
  - release tombstone write/read helper
  - capability feature 추가
- `bin/ablestack_vm_ftctl.sh`
  - 기존 CLI 인자 유지
  - strict single-JSON 출력 보장
- `lib/ftctl/libvirt_wrap.sh`
  - read-only 명령 분류 유지
- `bin/ablestack_vm_ftctl_selftest.sh`
  - v2/tombstone/무변경 selftest 추가

권장 helper:

```bash
ftctl_dr_runtime_emit_transition_preflight_v2()
ftctl_dr_runtime_release_tombstone_path()
ftctl_dr_runtime_write_release_tombstone()
ftctl_dr_runtime_read_release_tombstone()
ftctl_dr_runtime_emit_release_tombstone_json()
```

## 10. Selftest 설계

1. valid Reprotect v2 envelope
2. valid Failback v2 envelope
3. schema/contract/status scope 존재
4. authority mismatch typed rejection
5. generation mismatch typed rejection
6. target not serving
7. source isolation unsafe
8. active operation conflict with `retryable=true`
9. reverse path unavailable
10. preflight 전후 checksum 불변
11. Release tombstone identity/authority 보존
12. Release 후 scheduler/worker STOPPED/IDLE
13. Release 전후 VM/libvirt 상태 불변
14. profile 제거 후 `dr-status`로 tombstone 조회
15. timer가 tombstone을 active profile로 재생성하지 않음
16. force acknowledgement/reason 검증

## 11. 실환경 Preflight 절차

배포 전:

```bash
ablestack_vm_ftctl dr-capabilities --json
ablestack_vm_ftctl dr-transition-preflight ... --json
sha256sum <plan-status> <plan-profile>
```

배포 후 10.10.32.1/2/3에서 모두 확인한다.

```text
dr-transition-preflight-v2 present
dr-release-tombstone-v1 present
same FTCTL package checksum
same installed script checksum
```

Release E2E에서는 실행 전후 다음을 비교한다.

```text
target VM id
virsh domain existence/state
volume ids
network ids
scheduler unit
profile/runtime files
release tombstone
```

## 12. 배포 순서

1. FTCTL GitHub Actions package build
2. 10.10.32.1/2/3 동일 package 배포
3. capabilities와 installed script marker 확인
4. Mold Agent v2 wrapper 배포
5. Agent 재시작 후 typed round trip 확인
6. Cloud backend 배포
7. Reprotect/Release E2E

Cloud가 v2를 요구하기 전에 FTCTL과 Agent가 먼저 준비돼야 한다.

## 13. AS-IS / TO-BE

| 구분 | AS-IS | TO-BE |
| --- | --- | --- |
| Preflight 식별 | command와 일부 필드만 존재 | schema/contract/scope가 있는 v2 envelope |
| Agent 혼동 | 일반 status가 전달될 수 있음 | strict identity 불일치로 거부 |
| 오류 | exit 79와 문자열 중심 | typed error/retryable + 고정 exit 정책 |
| 무변경 증거 | selftest 일부만 확인 | profile/status/VM/lock 전체 checksum 검증 |
| Release terminal | status/profile 정리 후 증거가 약함 | plan-scoped tombstone 유지 |
| Release authority | Cloud가 별도로 추론 | `released_authority_side` 명시 |
| Release VM | 암묵적으로 무변경 | `vm_mutated=false`와 E2E 검증 |
| Mixed version | action 실행 후 실패 | capabilities 단계에서 사전 차단 |

## 14. 완료 기준

1. preflight JSON이 v2 contract로만 Cloud에 수용된다.
2. preflight가 persistent state와 VM을 변경하지 않는다.
3. 구형 Agent/FTCTL은 action 시작 전에 typed mismatch로 차단된다.
4. 정상 TARGET authority에서 Reprotect preflight가 READY다.
5. Release 후 scheduler/profile/runtime이 정리된다.
6. Release 후 target VM과 storage/network가 변하지 않는다.
7. Cloud가 profile 제거 후에도 tombstone으로 terminal 상태를 검증한다.
8. timer/reconcile이 released Plan을 다시 보호 상태로 만들지 않는다.
