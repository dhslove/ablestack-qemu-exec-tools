# 216. DR Failback Late ACK and Authority Snapshot Convergence Design

작성일: 2026-07-27

상태: 설계 완료, 구현 대기

## 1. 목적

페일백에서 Cloud가 원본 VM을 기동하고 복제 VM을 정지한 뒤 FTCTL에
`dr-failback-commit`을 전달했지만, scheduler의 RUN ACK가 명령 대기 시간을
넘겨 도착하면 다음 상태가 동시에 존재할 수 있다.

- 실제 활성 VM: 원본 VMware VM
- 실제 대기 VM: ABLESTACK 복제 VM
- scheduler: `RUNNING`
- 후속 정방향 증분 복제: 정상
- failback commit journal: `UNKNOWN`
- Cloud failback session: `COMMIT_VERIFYING`

이 문서는 지연 ACK를 손실된 ACK로 안전하게 복구하고, operation 상태와 Plan
권위 스냅샷을 섞지 않도록 FTCTL의 영속 상태 계약을 정의한다.

Cloud 전체 수렴 계약은 다음 문서를 따른다.

- Cloud 문서
  `576-cross-hypervisor-dr-failback-late-ack-and-projection-convergence-design-20260727.md`
- 선행 FTCTL 문서
  `215-dr-failback-commit-generation-and-rollback-fence-design-20260727.md`

## 2. 라이브 Preflight 증거

대상 Plan:

```text
2514a846-64a2-4bc7-ba88-38a874410782
```

대상 failback Run:

```text
77ee629a-bc8a-44b2-b05b-cf24b4696d32
```

읽기 전용 검증 결과:

| 증거 | 값 |
| --- | --- |
| commit journal | `SCHEDULER_RESUMING / UNKNOWN` |
| commit 요청 generation | `21` |
| journal이 기억한 ACK generation | `19` |
| 현재 `control.state` | generation `21`, command `run` |
| 현재 `control.ack` | generation `21`, `RUNNING/IDLE` |
| ACK owner run | failback Run과 일치 |
| owner matched | `true` |
| scheduler | `RUNNING/HEALTHY` |
| source VM | `POWERED_ON` |
| target VM | `POWERED_OFF` |
| failback 기준 checkpoint | `440` |
| 최신 완료 checkpoint | `463` |
| 최신 cycle | CBT incremental |

즉, 커밋 명령 당시에는 ACK가 아직 `19`였지만 scheduler가 뒤늦게 요청
generation `21`을 정확히 ACK했다. 현재 구현은 이 새로운 증거를 기존
`commit.state`와 operation Run에 다시 병합하지 않는다.

## 3. 오류 원인

### 3.1 RUN ACK 처리 지연

worker는 RPO 대기 중 새 `control.state`를 즉시 확인하지 않을 수 있다.
따라서 `ftctl_dr_scheduler_resume_after_transition()`의 대기 시간보다 늦게
RUN ACK가 도착할 수 있다.

### 3.2 status 명령의 비수렴

`ftctl_dr_runtime_failback_commit_status()`는 현재 commit journal을 읽어
operation 상태를 반환할 뿐, 최신 `control.ack`를 이용해 지연 ACK를
복구하지 않는다.

### 3.3 서로 다른 상태 파일의 필드 혼합

현재 operation-scoped `dr-status`는 다음 데이터를 한 JSON에 평탄하게
혼합한다.

- operation Run 상태: `runs/<failback-run>.state`
- Plan 권위 상태: `status.state`
- 최신 복제 cycle: scheduler worker가 생성한 checkpoint
- scheduler 제어 상태: `scheduler/control.state`, `control.ack`

최신 checkpoint sequence와 producer Run은 Plan 권위에서 가져오면서 NBD
teardown 필드는 operation Run에서 가져오면, 한 cycle을 설명하는 필드들이
서로 다른 generation에서 생성된다.

### 3.4 operation 상태가 Plan 상태를 덮어쓸 위험

scheduler가 재개된 뒤 operation Run을 `status.state`로 다시 복사하면 최신
Plan checkpoint와 scheduler heartbeat가 과거 transition 상태로 되돌아갈 수
있다.

## 4. 권위 파일과 소유권

| 파일 | 소유자 | 용도 | 다른 파일로 덮어쓰기 |
| --- | --- | --- | --- |
| `runs/<run>.state` | operation worker | 해당 명령의 상태와 결과 | 금지 |
| `failbacks/<run>.commit.state` | failback commit protocol | commit 시도와 terminal outcome | 금지 |
| `scheduler/control.state` | transition caller | 요청 generation과 명령 | 금지 |
| `scheduler/control.ack` | scheduler worker | 요청에 대한 영속 ACK | 금지 |
| `status.state` | Plan authority scheduler | 현재 보호 권위와 최신 cycle | operation Run으로 덮어쓰기 금지 |
| `checkpoints/*.json` | data-plane cycle | 불변 cycle 증거 | 수정 금지 |

`status.state`와 operation Run은 복사 관계가 아니라 projection 관계다.
조회 시 두 스냅샷을 구조적으로 합치되 원본 파일은 서로 덮어쓰지 않는다.

## 5. 지연 ACK 복구 함수

`lib/ftctl/dr_runtime.sh`에 다음 함수를 추가한다.

```bash
ftctl_dr_runtime_reconcile_failback_commit() {
  local plan="$1"
  local run="$2"
  local session_id="$3"
  local commit_path control_path ack_path run_path

  # 1. transition lock 획득
  # 2. commit/control/ack/run을 같은 lock 안에서 다시 읽음
  # 3. terminal journal이면 그대로 반환
  # 4. late ACK 승격 조건 검증
  # 5. commit journal과 operation Run을 ACKNOWLEDGED로 원자 갱신
  # 6. Plan status는 덮어쓰지 않음
}
```

호출 위치:

- `ftctl_dr_runtime_failback_commit()`의 timeout 분기 직전 마지막 확인
- `ftctl_dr_runtime_failback_commit_status()`
- `dr-reconcile`에서 활성 failback session을 발견한 경우

## 6. Late ACK 승격 조건

다음 조건이 모두 참일 때만 `UNKNOWN -> ACKNOWLEDGED`를 허용한다.

```text
commit.plan == request.plan
commit.run == request.run
commit.session_id == request.session_id
commit.phase in {AUTHORITY_COMMITTED, SCHEDULER_RESUMING}
commit.outcome in {PENDING, UNKNOWN}
control.command == run
control.generation == commit.control_generation
control.owner_run == commit.run
ack.generation == control.generation
ack.state == RUNNING
ack.owner_run == commit.run
ack.request_run_uuid == commit.run
ack.scheduler_session_uuid == current scheduler session
ack.lease_epoch == current lease epoch
ack.owner_matched == true
source_power_state == POWERED_ON
target_power_state == POWERED_OFF
```

`ack.generation > commit.control_generation`은 자동 성공으로 처리하지 않는다.
다른 제어 명령이 이미 실행됐을 수 있으므로 Cloud가 현재 권위를 별도로
재검증해야 한다.

## 7. 원자 갱신

승격 성공 시 같은 transition lock 안에서 다음 순서로 갱신한다.

1. 임시 commit journal 작성
2. `fsync`
3. `rename`으로 terminal commit journal 교체
4. operation Run을 `ACKNOWLEDGED`로 갱신
5. failback session JSON이 있으면 동일 terminal 결과 반영
6. `dr.failback.commit.recovered` 이벤트 기록

terminal journal:

```text
version=2
phase=ACKNOWLEDGED
outcome=ACKNOWLEDGED
control_generation=21
control_ack_generation=21
ack_owner_run=<failback-run>
ack_scheduler_session_uuid=<plan-session>
ack_lease_epoch=<epoch>
recovered_from_late_ack=true
recovered_at=<timestamp>
```

operation Run:

```text
state=SYNCING
step=protection-resuming
engine_ack_state=ACKNOWLEDGED
failback_commit_outcome=ACKNOWLEDGED
failback_commit_phase=ACKNOWLEDGED
control_generation=21
control_ack_generation=21
error_code=
error_message=
retryable=false
```

후속 보호 checkpoint 완료 여부는 Cloud가 판정하므로 FTCTL operation Run을
이 시점에 바로 `READY`로 종결하지 않는다.

## 8. scheduler 즉시 ACK

`lib/ftctl/dr_scheduler.sh`의 RPO sleep은 한 번에 전체 interval을 잠들지
않는다.

```bash
ftctl_dr_scheduler_interruptible_wait() {
  local plan="$1"
  local expected_generation="$2"
  local remaining="$3"

  while (( remaining > 0 )); do
    sleep 1
    ftctl_dr_scheduler_write_heartbeat ...
    if [[ "$(ftctl_dr_scheduler_control_generation "$plan")" != "$expected_generation" ]]; then
      return 10
    fi
    remaining=$((remaining - 1))
  done
}
```

새 generation이 발견되면 cycle을 시작하기 전에 즉시 명령을 처리하고 ACK를
기록한다. RUN ACK는 실제 worker owner tuple을 포함해야 하며 단순 PID 존재
여부만으로 성공시키지 않는다.

## 9. 구조화된 status scope

status JSON 계약을 version 2로 확장한다.

```json
{
  "status_contract_version": 2,
  "status_scope": "OPERATION",
  "operation": {
    "run_uuid": "...",
    "state": "SYNCING",
    "step": "protection-resuming",
    "commit_outcome": "ACKNOWLEDGED"
  },
  "authority": {
    "plan_uuid": "...",
    "active_side": "SOURCE",
    "scheduler_state": "RUNNING",
    "control_generation": 21,
    "control_ack_generation": 21,
    "latest_completed_cycle": {}
  }
}
```

기존 flat field는 호환 기간 동안 유지하되 다음 원칙을 적용한다.

- operation 필드는 `runs/<run>.state`에서만 읽는다.
- authority 필드는 `status.state`에서만 읽는다.
- latest completed cycle은 checkpoint JSON 하나에서 전 필드를 읽는다.
- 누락 필드를 다른 generation의 파일에서 개별 보충하지 않는다.

## 10. Cycle identity 계약

역할을 다음과 같이 분리한다.

| 필드 | 형식 | 의미 |
| --- | --- | --- |
| `cycle_token` | `<plan_uuid>:<sequence>` | Plan 범위 cycle identity |
| `checkpoint_ref` | `ftctl:<plan_uuid>:<producer_run_uuid>:<sequence>` | 물리 checkpoint 참조 |
| `producer_run_uuid` | UUID | cycle을 생산한 장기 scheduler Run |
| `sequence` | 정수 | Plan 범위 단조 증가 sequence |
| `baseline_generation` | 정수 | 해당 cycle이 commit한 baseline generation |

Cloud가 failback operation Run을 조회해도 최신 cycle의 producer Run은 기존
장기 sync Run일 수 있다. producer Run이 operation Run과 다르다는 이유로
cycle을 거부하지 않는다.

## 11. Checkpoint 원자 로딩

다음 함수를 추가한다.

```bash
ftctl_dr_runtime_load_completed_cycle_snapshot \
  "$plan" "$status_path" "$restore_points_path"
```

반환 필드는 하나의 checkpoint JSON에서 읽는다.

- sequence, token, producer Run
- requested/effective mode
- baseline generation
- incremental verification
- changed/read/written bytes
- NBD teardown state와 장치 수
- source checkpoint/target durable 시각

checkpoint JSON이 없거나 JSON 전체를 파싱할 수 없으면 typed error
`DR_STATUS_CYCLE_SNAPSHOT_UNREADABLE`을 반환한다. 부분 필드를 조합해 정상
cycle처럼 만들지 않는다.

## 12. 오류 코드

| 코드 | 조건 | retryable |
| --- | --- | --- |
| `DR_FAILBACK_COMMIT_ACK_PENDING` | 요청 generation ACK 미도착 | true |
| `DR_FAILBACK_COMMIT_ACK_OWNER_MISMATCH` | ACK owner 불일치 | false |
| `DR_FAILBACK_COMMIT_ACK_SUPERSEDED` | 더 새로운 제어 generation 존재 | false |
| `DR_FAILBACK_COMMIT_POWER_EVIDENCE_INVALID` | journal의 전원 증거 불충분 | false |
| `DR_STATUS_CYCLE_SNAPSHOT_UNREADABLE` | checkpoint 전체 파싱 실패 | true |
| `DR_STATUS_CYCLE_SNAPSHOT_INCOHERENT` | 단일 checkpoint 내부 계약 위반 | false |

timeout 자체는 `ACK_PENDING`이며 실패나 rollback을 의미하지 않는다.

## 13. Self-test

`bin/ablestack_vm_ftctl_selftest.sh`에 다음을 추가한다.

1. commit 대기 시간 이후 동일 generation ACK 도착
2. `commit-status` 첫 호출에서 journal 승격
3. 반복 호출이 동일 terminal 결과 반환
4. owner Run 불일치 ACK 거부
5. 더 새로운 generation ACK를 과거 commit 성공으로 오인하지 않음
6. worker 재시작 후 동일 session/lease lineage 복구
7. operation Run과 producer Run이 다른 최신 cycle 허용
8. NBD 필드가 operation Run에 없어도 checkpoint 원자 스냅샷으로 반환
9. checkpoint 일부 필드가 다른 generation이면 typed error
10. scheduler RPO wait 중 새 control generation을 2초 이내 ACK

## 14. AS-IS / TO-BE

| 영역 | AS-IS | TO-BE |
| --- | --- | --- |
| RUN ACK | RPO sleep 뒤 ACK 가능 | control 변경을 즉시 감지하고 ACK |
| commit timeout | journal이 영구 `UNKNOWN` | 최신 동일-generation ACK로 멱등 승격 |
| commit status | 과거 operation 상태만 반환 | control/ACK를 재검증하고 terminal 수렴 |
| Plan status | operation Run 복사로 덮어쓸 수 있음 | Plan authority 전용 스냅샷 |
| cycle 조회 | 서로 다른 파일의 필드를 혼합 | checkpoint 한 개를 원자 로딩 |
| cycle identity | operation Run과 producer Run 혼동 | token, checkpoint ref, producer Run 분리 |
| NBD 증거 | operation Run에 없으면 누락 | checkpoint cycle 증거에서 조회 |
| retry | 동일 명령이 상태를 다시 변경할 수 있음 | Plan/Run/session/generation 기반 멱등 처리 |

## 15. 완료 조건

```text
late ACK generation == requested generation
late ACK owner == failback Run
commit journal == ACKNOWLEDGED
operation engine ACK == ACKNOWLEDGED
Plan authority active side == SOURCE
scheduler == RUNNING/HEALTHY
latest completed sequence > failback checkpoint sequence
latest cycle snapshot is loaded from one immutable checkpoint
repeated status calls return the same terminal commit result
```

## 16. 구현 결과 (2026-07-27)

본 설계의 FTCTL 범위 구현을 완료했다.

- scheduler RPO 대기 중 control generation 변경을 1초 단위로 감지하고 즉시 ACK한다.
- failback commit journal을 version 2로 확장하고, timeout 뒤 도착한 동일 generation/owner ACK를
  `ACKNOWLEDGED`로 멱등 수렴시킨다.
- late ACK 판정은 Plan, Run, Session, generation, worker owner, lease epoch, pid/start time을 모두
  일치시킨 경우에만 허용한다.
- operation 상태와 Plan authority 상태를 분리하고, 최신 완료 cycle은 하나의 immutable checkpoint에서
  원자적으로 읽는다.
- failback commit 과정에서 최신 checkpoint 및 NBD 종료 증거가 유실되지 않도록 field-level 상태 갱신으로
  변경했다.
- `dr-plan-authority-snapshot-v1`, `dr-failback-commit-journal-v2`,
  `dr-failback-late-ack-reconcile-v1` capability를 제공한다.

구현 검증은 다음 self-test를 기준으로 한다.

```text
selftest_case_dr_runtime_failback_restores_source_after_reverse_checkpoint
selftest_case_dr_scheduler_wait_is_interrupted_by_new_generation
selftest_case_dr_runtime_state_snapshot_consistency
```

배포 후에는 설치된 호스트 스크립트에서 위 capability와 late-ACK reconcile 함수를 확인하고,
Cloud의 `PLAN_AUTHORITY` 조회가 최신 post-failback checkpoint를 반환하는지 검증한다.

## 17. 배포 및 실환경 검증 결과 (2026-07-27)

- 소스 커밋: `99f7b0c` (`fix: reconcile failback late acknowledgements`)
- GitHub Actions run: `30237953593`
- 배포 RPM: `ablestack_vm_ftctl-0.9.1-1.noarch`
- RPM SHA256:
  `e4f3ce07ad540034753d3fb46228b27abc1e45ed8458cd43b5072b1a9e98c68d`
- `10.10.32.1`, `10.10.32.2`, `10.10.32.3`에 동일 RPM을 배포했고,
  FTCTL timer와 Mold Agent가 모두 active임을 확인했다.
- 설치된 스크립트에서 `ftctl_dr_runtime_reconcile_failback_commit`과
  `ftctl_dr_scheduler_sleep_or_stop` 함수가 확인되었다.
- 대상 Plan `2514a846-64a2-4bc7-ba88-38a874410782`의 지연 ACK를
  `dr-failback-commit-status`로 재검증한 결과, commit journal version 2가
  `ACKNOWLEDGED`로 수렴했다.
- 요청 generation과 ACK generation은 모두 `21`, ACK owner는 failback Run
  `77ee629a-bc8a-44b2-b05b-cf24b4696d32`로 일치했다.
- failback 기준 checkpoint `440` 이후 checkpoint `478` 이상이 확인됐고,
  스케줄러 재기동 후에도 `RUNNING/HEALTHY`로 복구됐다.
- 재기동 후 첫 증분 주기에서 checkpoint `481`,
  `effective_mode=CBT_INCREMENTAL`, `changed_bytes=1048576`이 확인됐다.

## 18. Cloud Current Authority Projection Boundary - 2026-07-28

후속 검증에서 FTCTL은 Failback 뒤 `SOURCE`, scheduler `RUNNING`,
generation/ACK `27/27`, post-failback incremental checkpoint `585`를 정상
제공했다. 남은 문제는 Cloud가 과거 `PROMOTED` cutover session을 현재
권한으로 표시한 control-plane projection 결함이다.

FTCTL은 Cloud session history나 UI action eligibility를 관리하지 않는다.
이번 보정은 신규 FTCTL command나 state field 없이 Cloud의 current/history
조회 경계를 수정한다. 세부 경계는
`217-dr-cloud-current-authority-projection-boundary-design-20260728.md`와
Cloud 문서 578을 따른다.
## 20. Commit Submission Precondition Amendment - 2026-08-06

Late ACK recovery requires a durable journal identified by session, attempt
ID, and envelope hash. Journal absence before a recorded dispatch is
`NOT_SUBMITTED`, not an ambiguous late ACK. Deterministic validation errors
return directly to Cloud without status probing.

Document 453 defines the status-v2 outcome model and crash recovery points.

## 19. 2026-07-30 Post-Commit Sequence Handoff Amendment

late ACK 수렴만으로는 첫 원본 방향 checkpoint의 단조 증가를 보장하지 않는다.
Failback reverse-final checkpoint `N`을 scheduler의 Plan sequence baseline으로
원자 인계하고, 첫 resumed cycle을 `N+1` 이상으로 즉시 실행한다. operation ACK와
`PLAN_AUTHORITY` checkpoint의 소유권은 계속 분리한다. 상세 FTCTL 함수, 상태 파일,
idempotency 및 self-test 계약은 문서 219를 따른다.
