# 214. DR Failback Data-Ready and Cloud Commit Contract

작성일: 2026-07-26

## 1. 목적

FTCTL의 failback 책임을 reverse data-plane 완료까지로 제한한다. Cloud가 실제
가상머신 lifecycle을 전환한 뒤 명시적 commit을 보낼 때만 SOURCE authority를
확정한다.

Cloud 전체 설계는 문서
`574-cross-hypervisor-dr-cloud-owned-failback-lifecycle-commit-design-20260726.md`
를 따른다.

## 2. 실제 오류

현재 `ftctl_dr_runtime_failback_worker()`는 reverse checkpoint 성공 직후
`READY/SOURCE`, `source_power_state=POWER_ON_DELEGATED`,
`failback_completed_at`을 기록한다.

실제 Plan `2514a846-64a2-4bc7-ba88-38a874410782`에서는 checkpoint 440이
생성되었지만 TARGET `i-2-256-VM`은 running이고 SOURCE `w22-01`은
poweredOff였다. 따라서 FTCTL의 현재 완료 상태는 실제 service authority를
증명하지 못한다.

## 3. 책임 경계

FTCTL:

- reverse profile과 checkpoint 생성/검증
- disk map과 transfer metric 기록
- `FAILBACK_DATA_READY` 보고
- commit의 session/checkpoint/generation 검증
- 최종 authority state 저장

Cloud:

- TARGET VM 정지
- SOURCE VM 기동
- SOURCE boot 검증
- production authority 결정
- commit/abort 명령

FTCTL은 Site VM lifecycle API를 직접 호출하지 않는다.

## 4. 상태 계약

### 4.1 Reverse checkpoint 완료

`ftctl_dr_runtime_failback_worker()`의 성공 결과:

```text
state=FAILBACK_DATA_READY
step=cloud-lifecycle-pending
progress=70
scheduler_state=STOPPED
failback_session_id=<plan>:<run>
failback_phase=DATA_READY
failback_checkpoint_sequence=<sequence>
failback_checkpoint_path=<path>
failback_manifest_path=<path>
reverse_target_ready_at=<time>
active_side=TARGET
source_power_state=UNKNOWN
source_promotion_state=STANDBY
target_power_state=POWERED_ON
target_promotion_state=PROMOTED
engine_ack_state=PENDING
failback_completed_at=
```

operation session도 `DATA_READY/TARGET`으로 기록한다.

### 4.2 Cloud commit

신규 action:

```text
dr-failback-commit
```

필수 option:

```text
--plan
--run
--session-id
--checkpoint-sequence
--authority-generation
--source-power-state POWERED_ON
--target-power-state POWERED_OFF
--boot-validation-state READY
```

검증:

1. active failback session과 ID 일치
2. 현재 phase가 `DATA_READY`
3. checkpoint sequence 일치
4. authority generation이 stale하지 않음
5. SOURCE `POWERED_ON`
6. TARGET `POWERED_OFF`
7. boot validation `READY`

성공 결과:

```text
state=SYNCING
step=protection-resuming
progress=90
failback_phase=SERVICE_RESTORED
active_side=SOURCE
source_power_state=POWERED_ON
source_promotion_state=PROMOTED
target_power_state=POWERED_OFF
target_promotion_state=DEMOTED
engine_ack_state=ACKNOWLEDGED
engine_ack_generation=<generation>
service_restored_at=<commit time>
scheduler_state=RUNNING
```

동일 session/checkpoint/generation 재호출은 idempotent success다.

original-direction scheduler의 첫 durable checkpoint가 완료되면:

```text
state=READY
step=completed
progress=100
failback_phase=COMPLETED
post_failback_checkpoint_sequence=<sequence>
protection_resumed_at=<checkpoint commit time>
failback_completed_at=<checkpoint commit time>
```

### 4.3 Abort와 reconcile

신규 action:

```text
dr-failback-abort
```

TARGET이 실제 active이면 다음으로 복구한다.

```text
state=FAILED_OVER
step=failback-aborted
active_side=TARGET
target_power_state=POWERED_ON
target_promotion_state=PROMOTED
source_promotion_state=STANDBY
failback_phase=ABORTED
```

양쪽이 모두 ON이거나 power가 UNKNOWN이면 authority를 자동 변경하지 않고
`COMMIT_UNCERTAIN`을 기록한다.

## 5. 코드 변경 지점

### 5.1 `lib/ftctl/dr_runtime.sh`

- `ftctl_dr_runtime_failback_worker`
  - `READY/SOURCE` 조기 기록 제거
  - `FAILBACK_DATA_READY/TARGET` 기록
- `ftctl_dr_runtime_start_failback`
  - 비동기 worker 계약 유지
- 신규 `ftctl_dr_runtime_failback_commit`
  - commit contract 검증과 idempotent authority write
- 신규 `ftctl_dr_runtime_failback_abort`
  - TARGET authority 복구
- status JSON
  - phase, lifecycle, ACK generation 노출
- dispatcher
  - commit/abort action 추가

### 5.2 `bin/ablestack_vm_ftctl.sh`

- help/action allow-list 추가
- 필수 option parsing
- `dr-cutover-commit`과 같은 짧은 synchronous control action으로 분류

### 5.3 `lib/ftctl/libvirt_wrap.sh`

- commit/abort를 VM lifecycle 호출이 없는 control action으로 허용
- durable state와 log에 secret을 기록하지 않는 기존 계약 유지

### 5.4 Status JSON

```json
{
  "failback_phase": "DATA_READY",
  "failback_session_id": "...",
  "failback_checkpoint_sequence": 440,
  "cloud_lifecycle_state": "PENDING",
  "authority_generation": 440,
  "engine_ack_state": "PENDING",
  "engine_ack_generation": null,
  "source_power_state": "UNKNOWN",
  "target_power_state": "POWERED_ON",
  "service_restored_at": null,
  "protection_resumed_at": null,
  "post_failback_checkpoint_sequence": null
}
```

## 6. 오류 코드

| 코드 | 의미 |
| --- | --- |
| `DR_FAILBACK_COMMIT_INVALID` | 필수 evidence 누락 |
| `DR_FAILBACK_SESSION_MISMATCH` | active session 불일치 |
| `DR_FAILBACK_CHECKPOINT_MISMATCH` | checkpoint 불일치 |
| `DR_FAILBACK_AUTHORITY_STALE` | 오래된 generation |
| `DR_FAILBACK_SOURCE_NOT_RUNNING` | SOURCE power 불충족 |
| `DR_FAILBACK_TARGET_STILL_RUNNING` | TARGET power 불충족 |
| `DR_FAILBACK_BOOT_NOT_READY` | boot validation 불충족 |
| `DR_FAILBACK_COMMIT_UNCERTAIN` | 실제 실행 위치 확정 불가 |

오류 시 `failback_completed_at`을 기록하지 않는다.

## 7. Selftest

`bin/ablestack_vm_ftctl_selftest.sh`:

1. reverse 완료 후 `DATA_READY/TARGET`
2. `failback_completed_at` 미기록
3. 필수 option 누락 commit 거부
4. TARGET ON commit 거부
5. SOURCE OFF commit 거부
6. boot 미완료 commit 거부
7. 정상 commit 후 `READY/SOURCE`
8. 동일 commit idempotent success
9. stale generation 거부
10. abort 후 `FAILED_OVER/TARGET`
11. commit 후 original-direction scheduler RUNNING
12. 첫 durable checkpoint 전 `SYNCING/SOURCE`
13. 첫 durable checkpoint 후 `READY/COMPLETED`
14. 과거 조기 완료 상태 reconcile

## 8. AS-IS / TO-BE

| 항목 | AS-IS | TO-BE |
| --- | --- | --- |
| reverse 완료 | `READY/SOURCE` | `FAILBACK_DATA_READY/TARGET` |
| SOURCE power | 실행 없이 delegated 표시 | Cloud evidence를 commit에서 수신 |
| TARGET power | ON인데 SOURCE authority | commit 전에 반드시 OFF |
| 서비스 복구 시각 | reverse checkpoint 시각 | Cloud commit ACK 시각 |
| 보호 완료 시각 | 별도 증거 없음 | 첫 정방향 durable checkpoint 시각 |
| 복구 | 명시적 abort 없음 | `dr-failback-abort` |
| idempotency | worker 결과만 존재 | session/checkpoint/generation 기반 |

## 9. 완료 기준

FTCTL은 다음 조건에서만 failback 완료를 보고한다.

```text
active session matches
checkpoint matches
generation is current
source power evidence == POWERED_ON
target power evidence == POWERED_OFF
boot validation == READY
engine state write succeeded
original-direction scheduler == RUNNING
post-failback durable checkpoint exists
```

그 전 상태는 데이터 전송이 완료됐더라도 `DATA_READY`다.

## 10. 2026-07-27 Commit Generation과 Rollback Fence 보강

실환경 재검증에서 `FAILBACK_COMMIT`이 실패로 반환됐지만 scheduler가
`RUNNING`이 되는 generation 경합이 확인됐다. 또한 기존 abort는 scheduler를
정지하지 않아 TARGET 서비스가 복구된 뒤에도 정방향 복제가 남을 수 있다.

다음 항목은 문서 215의 계약으로 대체한다.

- commit당 control generation은 하나만 생성한다.
- 새 worker는 pending generation을 채택하고 같은 generation을 ACK한다.
- commit은 durable journal에서 멱등 재개한다.
- rollback은 scheduler `STOPPED` ACK, VM lifecycle 복구, TARGET authority
  commit의 2단계 fence를 사용한다.
- 기존 stub 기반 failback selftest 외에 실제 worker generation 통합 테스트를
  필수로 수행한다.

상세 설계:
`215-dr-failback-commit-generation-and-rollback-fence-design-20260727.md`.
