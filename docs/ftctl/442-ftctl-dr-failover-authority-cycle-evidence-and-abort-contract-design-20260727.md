# 442. FTCTL DR Failover Authority Cycle Evidence and Abort Contract Design

- 작성일: 2026-07-27
- 상태: 상세 설계 완료, 구현 대기
- 적용 방향: VMware -> ABLESTACK 실제 Failover
- Cloud 상위 설계:
  `ablestack-cloud/docs/ftctl/577-cross-hypervisor-dr-failover-projection-evidence-and-compensation-design-20260727.md`
- 관련 설계:
  - `438-ftctl-dr-real-failover-cutover-manifest-contract-design-20260722.md`
  - `439-ftctl-dr-systemd-owned-scheduler-and-recovery-design-20260722.md`
  - `440-ftctl-dr-vmware-nbd-deterministic-drain-and-observability-design-20260723.md`

## 1. 목적

실제 Failover worker가 성공하여 `CUTOVER_READY`에 도달했는데도 Cloud Agent가
`DR_STATUS_CYCLE_SNAPSHOT_INCOHERENT`를 반환하는 문제를 해결한다.

이번 변경은 검증 조건을 느슨하게 만들지 않는다. 다음 두 가지를 동시에
보장하는 것이 목적이다.

1. Failover operation 상태를 새로 만들더라도 Plan 소유의 마지막 완료 복제
   cycle 증거를 잃지 않는다.
2. operation 상태에서 증거가 누락된 경우 동일 cycle의 immutable checkpoint를
   식별자로 검증한 뒤에만 누락 필드를 보완한다.

Cloud가 target VM을 시작하기 전 Failover 준비를 취소해야 하는 경우를 위해
`dr-failover-abort`의 멱등 복구 계약도 함께 정의한다.

## 2. 실환경 Read-only Preflight

대상 Plan:

```text
2514a846-64a2-4bc7-ba88-38a874410782
```

Failover Run:

```text
7900237f-a5b9-4c23-b536-89b66f67a7e4
```

완료 복제 producer Run:

```text
bb094cdb-7515-49fa-9a6b-49965ea0289d
```

검증 결과:

| 항목 | 값 |
| --- | --- |
| FTCTL operation state | `CUTOVER_READY` |
| guest preparation | `READY` |
| target promotion | `CUTOVER_READY` |
| target power | `POWERED_OFF` |
| scheduler | `STOPPED_PENDING_CUTOVER` |
| 완료 checkpoint sequence | `501` |
| effective mode | `CBT_INCREMENTAL` |
| incremental verified | `true` |
| changed/read/written bytes | `9,306,112` |
| changed extents | `94` |
| checkpoint commit state | `LOCAL_DURABLE` |
| checkpoint NBD teardown | `DRAINED` |
| quarantined NBD count | `0` |

현재 `status.state`에는 `latest_completed_*` 묶음이 없다. `dr-status`의
restore-point fallback은 sequence, mode, token, generation은 복구하지만 NBD
teardown 필드는 복구하지 않는다. 따라서 Agent에는 다음과 같은 부분
snapshot이 전달된다.

```text
sequence=501
cycleToken=<plan>:501
baselineGeneration=501
effectiveMode=CBT_INCREMENTAL
incrementalVerified=true
nbdTeardownState=
```

동일 Plan, producer Run, sequence, cycle token, baseline generation을 모두
대조한 뒤 checkpoint와 cycle metrics의 NBD 값을 보완하는 read-only simulation은
다음 결과를 냈다.

```text
sameCycleIdentity=true
hydratedNbdTeardownState=DRAINED
coherentAfterExactIdentityHydration=true
runtimeStateMutated=false
```

따라서 데이터 복제나 NBD drain 실패가 아니라 status projection에서 durable
cycle 증거가 손실된 것이 직접 원인이다.

## 3. 오류 원인

### 3.1 Failover가 권위 snapshot을 승계하지 않음

`lib/ftctl/dr_runtime.sh`의 background action 초기화는 새 Run state를 먼저
작성한다.

```bash
ftctl_dr_runtime_write_state "${run_path}" ...
```

그 다음 `ftctl_dr_runtime_capture_authority_context()`를 호출하는 action은 현재
다음 두 가지뿐이다.

```text
dr-failback
dr-reprotect
```

`dr-failover`가 빠져 있어 마지막 완료 cycle의 checkpoint 및 NBD 필드가 새
operation state에 복사되지 않는다.

### 3.2 Restore-point fallback이 부분 projection을 만듦

`ftctl_dr_runtime_emit_state_json()`은
`latest_completed_checkpoint_sequence`가 비어 있을 때
`restore-points.jsonl`에서 28개 필드를 복원한다. NBD teardown 필드는 이
목록에 포함되지 않는다.

그 결과 하나의 completed-cycle DTO가 서로 다른 완전성 규칙을 가진 두
소스에서 조립된다.

### 3.3 Operation과 Plan authority의 소유권 혼합

`runs/<run>.state`는 operation 진행 상태이고 `status.state`는 Plan authority
projection이다. operation state를 `status.state`에 복사하면 다음 항목이
손실될 수 있다.

- 마지막 완료 checkpoint identity
- transfer metrics
- NBD drain 결과
- scheduler generation과 lease identity

operation과 authority는 덮어쓰기 관계가 아니라 별도 envelope로 결합되어야
한다.

## 4. 상태 파일 소유권

| 파일 | 소유자 | 역할 | 다른 파일로 덮어쓰기 |
| --- | --- | --- | --- |
| `runs/<run>.state` | operation worker | action 진행과 결과 | 금지 |
| `status.state` | Plan scheduler/authority | 현재 보호 권위와 마지막 완료 cycle | operation 전체 복사 금지 |
| `checkpoints/*.json` | data-plane cycle | immutable durable checkpoint | 수정 금지 |
| `cycle-metrics/*.json` | data-plane cycle | immutable 전송 측정값 | 수정 금지 |
| `restore-points.jsonl` | checkpoint index | 완료 checkpoint 검색 인덱스 | 기존 행 수정 금지 |
| `failovers/<run>.json` | failover protocol | 준비/승격/commit/abort journal | 다른 Run 재사용 금지 |

## 5. Completed Cycle Evidence 계약

### 5.1 증거 상태

```text
COMPLETE | INCOMPLETE | CONFLICT
```

| 상태 | 의미 | Agent 처리 |
| --- | --- | --- |
| `COMPLETE` | 필수 identity와 mode/NBD 증거가 모두 일치 | 성공 |
| `INCOMPLETE` | 식별자는 일치하지만 필수 필드가 누락 | 재시도 가능 |
| `CONFLICT` | 둘 이상의 durable source가 서로 다른 비어 있지 않은 값을 가짐 | hard failure |

`CBT_INCREMENTAL`이고 `incrementalVerified=true`인 cycle의 필수 필드:

```text
planUuid
producerRunUuid
sequence
cycleToken
baselineGeneration
checkpointState
cycleCommitState
effectiveMode
incrementalVerified
nbdTeardownState
nbdQuarantinedDeviceCount
```

정상 조건:

```text
cycleToken == planUuid + ":" + sequence
baselineGeneration == sequence
checkpointState in {TARGET_READY, READY, COMPLETED}
cycleCommitState == LOCAL_DURABLE
nbdTeardownState == DRAINED
nbdQuarantinedDeviceCount == 0
```

`NO_CHANGE` cycle은 NBD를 사용하지 않았다면
`nbdTeardownState=NOT_APPLICABLE`을 허용한다.

### 5.2 단일 snapshot 원칙

`dr-status`는 completed cycle을 필드별로 여러 파일에서 조립하지 않는다.
다음 순서로 하나의 canonical snapshot을 선택한다.

1. authority state가 가리키는 checkpoint path 확인
2. path가 없으면 restore point에서 최신 terminal checkpoint 선택
3. checkpoint JSON을 한 번 읽음
4. checkpoint가 참조하는 cycle metrics를 한 번 읽음
5. identity tuple을 대조
6. 누락값만 채움
7. 비어 있지 않은 값 충돌 시 `CONFLICT`

identity tuple:

```text
(planUuid, producerRunUuid, sequence, cycleToken, baselineGeneration)
```

## 6. FTCTL 코드 설계

### 6.1 Failover authority 승계

파일:

```text
lib/ftctl/dr_runtime.sh
```

background action 초기화 분기를 다음과 같이 변경한다.

```bash
case "${action}" in
  dr-failover|dr-failback|dr-reprotect)
    ftctl_dr_runtime_capture_authority_context \
      "${plan}" "${run_path}" "${status_path}" "${persisted_authority_spec}"
    ;;
esac
```

`capture_authority_context()`는 기존 비어 있지 않은 operation 필드를 덮어쓰지
않으며, Plan authority에서 읽은 completed-cycle projection을 한 묶음으로
복사한다.

### 6.2 Canonical snapshot resolver

다음 helper를 추가한다.

```bash
ftctl_dr_runtime_resolve_completed_cycle_snapshot() {
  local plan="$1"
  local authority_state_path="$2"
  local output_json="$3"

  # authority -> restore point -> checkpoint -> metrics 순서
  # exact identity 검증
  # 같은 디렉터리 임시 파일에 JSON 작성
  # fsync + rename
}
```

resolver는 다음 구조를 출력한다.

```json
{
  "evidenceState": "COMPLETE",
  "evidenceSource": "checkpoint+cycle-metrics",
  "planUuid": "...",
  "producerRunUuid": "...",
  "sequence": 501,
  "cycleToken": "...:501",
  "baselineGeneration": 501,
  "effectiveMode": "CBT_INCREMENTAL",
  "incrementalVerified": true,
  "nbdTeardownState": "DRAINED",
  "nbdQuarantinedDeviceCount": 0
}
```

### 6.3 필드별 restore-point fallback 제거

현재 28개 positional line을 `mapfile`로 읽는 fallback을 제거한다.
`ftctl_dr_runtime_emit_state_json()`은 resolver가 만든 JSON snapshot에서 typed
field를 한 번에 출력한다.

기존 flat field는 rolling upgrade 호환을 위해 유지하지만 동일 snapshot에서
파생한다.

추가 field:

```text
latest_completed_evidence_state
latest_completed_evidence_source
latest_completed_evidence_error_code
latest_completed_evidence_error_message
```

### 6.4 충돌과 누락 오류

```text
DR_STATUS_CYCLE_EVIDENCE_INCOMPLETE
DR_STATUS_CYCLE_EVIDENCE_CONFLICT
```

- `INCOMPLETE`: exit code는 status query 실패 범주이나 `retryable=true`
- `CONFLICT`: `retryable=false`, target promotion 금지
- raw credential, VDDK cookie, `/dev/nbdN`은 오류 payload에 포함하지 않음

### 6.5 원자적 publication

`status.state`, Run state, failover journal은 destination directory에 임시
파일을 만든 뒤 다음 순서로 교체한다.

```text
write temp
fsync(temp)
rename(temp, final)
fsync(directory)
```

`cp -f`로 authority 상태를 publication하지 않는다.

## 7. Failover Abort 계약

### 7.1 새 명령

```text
dr-failover-abort
```

필수 입력:

```text
plan UUID
run UUID
failover session ID
expected checkpoint sequence
expected authority generation
```

### 7.2 자동 abort 허용 조건

다음을 모두 만족할 때만 Cloud가 자동 요청할 수 있다.

```text
active_side == SOURCE
target_promotion_state == CUTOVER_READY
target_power_state == POWERED_OFF
cloud_authority_generation is empty
engine_ack_state is empty or PENDING
failover session identity matches
checkpoint sequence matches
```

하나라도 다르면 `DR_FAILOVER_ABORT_UNSAFE`를 반환한다.

### 7.3 실행 순서

```text
transition lock 획득
-> failover journal identity 재검증
-> target가 OFF인지 재검증
-> checkpoint lease 해제
-> failover session ABORTED 기록
-> active failover pointer 제거
-> source authority 유지
-> scheduler desired state 복구
-> source가 online이면 RUN 요청
-> source가 offline이면 PAUSED_SOURCE_OFFLINE
-> ACK 기록
```

FTCTL은 source VM의 전원을 자동으로 켜지 않는다. 계획된 테스트에서 운영자가
source를 격리했을 수 있으므로 power control은 Cloud/provider 또는 운영자의
명시적 작업이다.

### 7.4 멱등성

같은 identity로 재호출할 때 이미 `ABORTED`이면 성공을 반환한다. 다른 Run이나
다른 generation이 같은 Plan을 소유하고 있으면 실패한다.

## 8. Capability

`dr-capabilities`에 다음 feature를 추가한다.

```text
cloud-failover-evidence-v1
cloud-failover-abort-v1
```

Cloud는 두 feature가 확인되기 전에는 새 자동 보상 경로를 사용하지 않는다.
구버전 FTCTL에서는 기존 Failover를 시작하지 않고 preflight에서 업그레이드
필요를 반환한다.

## 9. Self-test 설계

`bin/ablestack_vm_ftctl_selftest.sh`에 다음을 추가한다.

1. `dr-failover` 초기화가 prior authority cycle 전체를 승계
2. operation state에 cycle 필드가 없어도 exact checkpoint로 COMPLETE 복원
3. NBD field만 누락된 incremental cycle이 DRAINED로 복원
4. sequence가 같은 다른 producer Run은 CONFLICT
5. cycle token mismatch는 CONFLICT
6. baseline generation mismatch는 CONFLICT
7. checkpoint DRAINED와 metrics QUARANTINED 충돌은 CONFLICT
8. abort가 target OFF/SOURCE authority에서 scheduler를 복구
9. abort 재호출이 멱등 성공
10. target POWERED_ON 상태에서 자동 abort 거부
11. source offline에서 `PAUSED_SOURCE_OFFLINE` 유지
12. 출력에 credential과 raw NBD 장치가 없음

## 10. 구현 순서

1. canonical cycle snapshot resolver
2. `dr-failover` authority 승계
3. status emitter 단일 snapshot 전환
4. evidence 상태와 오류 코드
5. `dr-failover-abort`
6. capability
7. self-test와 shell syntax test
8. GitHub Actions RPM build
9. FTCTL 선배포
10. 설치 script marker와 capability 검증

## 11. AS-IS / TO-BE

| 구분 | AS-IS | TO-BE |
| --- | --- | --- |
| Failover 시작 | 새 Run state가 완료 cycle 증거를 잃음 | prior Plan authority snapshot 전체 승계 |
| status fallback | restore point 28개 필드만 부분 복원 | exact checkpoint 기반 단일 typed snapshot |
| NBD 증거 | incremental인데 teardown 값이 비어 있음 | `DRAINED` 또는 명확한 INCOMPLETE/CONFLICT |
| 충돌 처리 | 누락과 충돌을 동일 incoherent로 처리 | 누락은 bounded retry, 충돌은 hard gate |
| publication | operation이 authority를 덮을 수 있음 | 파일 소유권 분리와 원자 publication |
| 준비 취소 | generic `dr-cancel`은 scheduler stop 의미 | 전용 멱등 `dr-failover-abort` |
| source 전원 | 복구 동작이 불명확 | 자동 power-on 금지, offline은 pause |
| rolling upgrade | 기능 버전 구분 없음 | capability 두 개로 명시적 gate |

## 12. Scheduler acknowledgement convergence

`dr-failover-abort` can resume an existing scheduler while that worker is
finishing an in-flight RPO cycle. In that case the control acknowledgement may
arrive after the normal command timeout even though the source replication
worker is already active and healthy.

The abort path accepts `RUNNING_PENDING_ACK` only when all of these facts hold:

1. The wait result is the acknowledgement timeout code (`21`).
2. The control generation still equals the generation written by the abort.
3. The current control command is still `run`.
4. The active worker matches the plan scheduler session and has a valid lease.

The runtime keeps the last observed acknowledgement generation rather than
fabricating an acknowledgement. Any generation change, non-`run` command, dead
worker, or session mismatch remains a hard resume failure.
