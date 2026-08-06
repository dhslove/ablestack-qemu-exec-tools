# 215. DR Failback Commit Generation and Rollback Fence Design

작성일: 2026-07-27

## 0. Implementation Status (2026-07-27)

Status: implemented; local full validation and RPM build/deployment evidence are
recorded in the final sections of this document.

Implemented source:

- `lib/ftctl/dr_scheduler.sh`
  - writes the requested RUN generation before worker startup;
  - lets a new worker adopt that durable generation;
  - requires the same generation to reach `RUNNING` ACK.
- `lib/ftctl/dr_runtime.sh`
  - persists `<run>.commit.state`;
  - exposes `ACKNOWLEDGED`, `UNKNOWN`, `REJECTED`, and `ROLLED_BACK` outcomes;
  - implements scheduler-first rollback fencing.
- `bin/ablestack_vm_ftctl.sh`
  - exposes `dr-failback-commit-status`;
  - accepts two-phase `dr-failback-abort --phase prepare|commit`.
- `lib/ftctl/libvirt_wrap.sh`
  - allows the new status command through the Cloud Agent wrapper.
- `bin/ablestack_vm_ftctl_selftest.sh`
  - validates generation adoption, durable commit recovery, and rollback fence
    ordering.

The protocol version for this contract is `4`.

## 1. 목적

Cloud가 `FAILBACK_COMMIT`을 호출한 뒤 FTCTL scheduler는 실제로 시작했지만
Cloud에는 실패가 반환되는 경합을 제거한다. 또한 commit 결과가 불확실하거나
rollback이 필요한 경우 TARGET 서비스와 정방향 복제가 동시에 활성화되지 않도록
Plan 단위 fence를 강제한다.

이 문서는 다음 문서를 보강하며, scheduler generation과 failback rollback에
대해서는 이 문서가 우선한다.

- `214-dr-failback-data-ready-cloud-commit-contract-design-20260726.md`
- `439-ftctl-dr-systemd-owned-scheduler-and-recovery-design-20260722.md`
- Cloud 문서
  `575-cross-hypervisor-dr-failback-commit-convergence-and-rollback-fencing-design-20260727.md`

## 2. 실환경 및 격리 Preflight

대상 Plan:

```text
2514a846-64a2-4bc7-ba88-38a874410782
```

2026-07-27 읽기 전용 검증 결과:

| 항목 | 값 |
| --- | --- |
| FTCTL scheduler unit | `active` |
| `control.state` | generation `15`, command `run`, reason `scheduler-start` |
| `control.ack` | generation `15`, state `RUNNING` |
| 대상 VM | `i-2-256-VM / running` |
| Cloud Plan | `READY / TARGET` |
| Cloud Replica | `ERROR / TARGET / POWERED_ON` |
| 최신 FAILBACK Run | `FAILED / DR_STATUS_CYCLE_SNAPSHOT_INCOHERENT` |
| Failback session | `FAILED / engine ACK PENDING` |

현재 origin commit `e0baec272e`의 targeted failback selftest도 WSL ext4
worktree에서 PASS했다. 그러나 selftest는 아래처럼 실제 함수를 stub으로
대체한다.

```bash
ftctl_dr_scheduler_resume_after_transition() {
  ftctl_dr_runtime_path_set "$4" \
    "scheduler_state=RUNNING" "control_state=RUNNING"
  cp -f "$4" "$5"
  return 0
}
```

따라서 기존 PASS는 commit 상태 변환만 검증하며 worker bootstrap,
`control.state`, `control.ack`, generation 경쟁은 검증하지 않는다.

## 3. 오류 원인

현재 실행 순서는 다음과 같다.

```text
failback commit
  -> ftctl_dr_scheduler_resume_after_transition()
  -> ftctl_dr_scheduler_ensure_running()
  -> worker process starts and publishes PID/heartbeat
  -> caller considers worker running
  -> caller creates RUN generation N
  -> worker startup creates scheduler-start generation N+1
  -> worker ACKs N+1
  -> caller waits for N and times out
```

`ftctl_dr_scheduler_ensure_running()`은 worker identity가 보이면 성공하지만,
worker의 startup control generation이 안정화됐는지는 확인하지 않는다.
동시에 `ftctl_dr_scheduler_run()`은 시작할 때 무조건 새
`scheduler-start` generation을 생성한다. 한 transition에 두 명령 생성자가
존재하는 것이 직접 원인이다.

또한 `ftctl_dr_runtime_failback_abort()`는 authority 필드만 TARGET으로
되돌리고 scheduler를 정지하거나 ACK를 확인하지 않는다. 이 때문에 Cloud가
TARGET VM을 재기동한 뒤에도 source-to-target scheduler가 실행될 수 있다.

## 4. 불변 조건

1. 한 transition에는 하나의 control generation만 존재한다.
2. control generation의 생성자는 Cloud 요청을 처리하는 FTCTL control path다.
3. 새 worker는 pending generation을 채택하고 같은 generation을 ACK한다.
4. worker는 유효한 pending generation이 없을 때만 bootstrap generation을 만든다.
5. PID 또는 heartbeat만으로 resume 성공을 판정하지 않는다.
6. commit success는 동일 generation의 `RUNNING` ACK 이후에만 반환한다.
7. TARGET authority에서는 source-to-target cycle을 실행하지 않는다.
8. rollback 시작 전에 scheduler를 먼저 fence하고 `STOPPED` ACK를 확인한다.
9. rollback 완료 전에는 TARGET authority를 최종 확정하지 않는다.
10. commit과 rollback은 session/checkpoint/authority/generation으로 멱등이다.

## 5. Scheduler Control Protocol v4

### 5.1 단일 generation 생성

`ftctl_dr_scheduler_resume_after_transition()`은 다음 순서를 사용한다.

```bash
ftctl_dr_scheduler_lock_acquire "$plan" control 204 "$timeout" "$reason:$run"
generation="$(ftctl_dr_scheduler_control_set \
  "$plan" run "$reason" "$run" false)"
ftctl_dr_scheduler_ensure_running \
  "$plan" "$scheduler_run" "$profile" "$run_path" "$status_path" \
  "$generation"
ftctl_dr_scheduler_wait_for_ack \
  "$plan" "$generation" RUNNING "$timeout" "$run" "$session"
ftctl_dr_scheduler_lock_release "$plan" control 204
```

`ensure_running`에 `expected_generation`을 전달한다. 이미 올바른 worker가
있으면 새 generation을 만들지 않고 그 worker가 해당 요청을 ACK하도록 한다.
worker가 없으면 launch state에 같은 generation을 넣고 systemd worker를
시작한다.

### 5.2 Launch state 확장

```text
control_protocol_version=4
bootstrap_generation=<N>
bootstrap_command=run
bootstrap_reason=failback-commit
bootstrap_owner_run=<run UUID>
authority_side=SOURCE
authority_sequence=<authority generation>
```

파일은 임시 파일 작성, `fsync`, rename 순서로 원자적으로 교체한다.

### 5.3 Worker의 pending generation 채택

`ftctl_dr_scheduler_run()`의 무조건적인 다음 호출을 제거한다.

```bash
ftctl_dr_scheduler_control_set "$plan" run scheduler-start "$run"
```

대신 다음 helper를 사용한다.

```bash
ftctl_dr_scheduler_bootstrap_generation \
  "$plan" "$run" "$launch_state"
```

알고리즘:

1. launch state의 generation과 현재 `control.state`를 읽는다.
2. command가 `run`이고 generation이 같으면 이를 채택한다.
3. owner/session/authority가 일치하는지 검증한다.
4. 같은 generation으로 `RUNNING` ACK를 기록한다.
5. pending request가 없을 때만 `scheduler-start` generation을 생성한다.
6. 더 새로운 generation이 있으면 오래된 launch를
   `DR_SCHEDULER_BOOTSTRAP_STALE`로 거부한다.

### 5.4 성공 판정

resume success:

```text
control.state.generation == requested generation
control.ack.generation == requested generation
control.ack.state == RUNNING
control.ack.owner_run == requested owner
active worker session == expected session
worker heartbeat is fresh
authority side == SOURCE
```

`ensure_running()`의 PID/heartbeat 확인은 process 준비 증거이며 최종
control ACK가 아니다.

## 6. Failback Commit Journal

Plan별 파일:

```text
/run/ablestack-vm-ftctl/dr-runtime/plans/<plan>/failbacks/
  <session>/commit.state
```

필드:

```text
version=1
plan=<plan UUID>
run=<run UUID>
session_id=<session ID>
checkpoint_sequence=<sequence>
authority_generation=<generation>
phase=PREPARED|AUTHORITY_COMMITTED|SCHEDULER_RESUMING|ACKNOWLEDGED
control_generation=<scheduler generation>
control_ack_generation=<scheduler ACK generation>
source_power_state=POWERED_ON
target_power_state=POWERED_OFF
updated_at=<time>
```

`ftctl_dr_runtime_failback_commit()`:

1. session/checkpoint/authority/power/boot evidence 검증
2. `PREPARED` journal 원자 저장
3. SOURCE authority와 session phase를 한 durable update로 저장
4. `AUTHORITY_COMMITTED` 저장
5. 단일 generation scheduler resume
6. matching ACK 후 `ACKNOWLEDGED` 저장
7. JSON result에 journal phase와 generation을 반환

동일 key 재호출은 journal을 읽어 다음처럼 처리한다.

- `ACKNOWLEDGED`: 동일 success 반환
- `SCHEDULER_RESUMING`: 동일 generation ACK 대기/조회
- `AUTHORITY_COMMITTED`: 새 authority를 만들지 않고 scheduler resume 재개
- `PREPARED`: evidence 재검증 후 계속

## 7. 2단계 Rollback Fence

기존 단일 `dr-failback-abort`를 논리적으로 두 단계로 분리한다.

```text
dr-failback-abort --phase prepare
dr-failback-abort --phase commit
```

### 7.1 Prepare

1. transition/control lock 획득
2. `stop` generation 생성
3. scheduler와 cycle 종료 대기
4. matching `STOPPED/IDLE` ACK 확인
5. pending RUN request 제거 또는 superseded 기록
6. `rollback_phase=FENCED` 기록

이 단계는 VM lifecycle을 수행하거나 TARGET authority를 확정하지 않는다.

### 7.2 Cloud lifecycle rollback

Cloud가 다음 순서로 수행한다.

```text
SOURCE power off 확인
TARGET power on 확인
TARGET boot/power validation
```

### 7.3 Commit

Cloud evidence를 전달한다.

```text
source_power_state=POWERED_OFF
target_power_state=POWERED_ON
rollback_generation=<prepare generation>
```

FTCTL은 같은 generation의 `STOPPED` ACK를 다시 확인한 뒤
`FAILED_OVER/TARGET`, `rollback_phase=COMPLETED`를 원자 저장한다.

## 8. Runtime Safety Fence

각 source-to-target cycle 직전에 다음을 검사한다.

```text
active_side == SOURCE
failback phase not in rollback
transition_state not uncertain
target production power evidence != POWERED_ON
control generation still owned
```

불충족이면 데이터 I/O 전에 cycle을 멈추고 다음 typed error를 기록한다.

| 오류 코드 | 의미 |
| --- | --- |
| `DR_SCHEDULER_BOOTSTRAP_STALE` | launch generation이 최신 request보다 오래됨 |
| `DR_SCHEDULER_ACK_GENERATION_MISMATCH` | 요청과 ACK generation 불일치 |
| `DR_FAILBACK_COMMIT_ACK_TIMEOUT` | commit scheduler ACK 시간 초과 |
| `DR_FAILBACK_ROLLBACK_FENCE_FAILED` | rollback 전 STOPPED ACK 실패 |
| `DR_FAILBACK_ROLLBACK_EVIDENCE_INVALID` | SOURCE/TARGET power 증거 불일치 |
| `DR_SCHEDULER_TARGET_AUTHORITY_FENCE` | TARGET authority에서 정방향 cycle 차단 |

## 9. Status JSON

```json
{
  "failback_commit_phase": "SCHEDULER_RESUMING",
  "failback_commit_outcome": "PENDING",
  "control_generation": 16,
  "control_ack_generation": 16,
  "scheduler_state": "RUNNING",
  "rollback_phase": "NONE",
  "authority_side": "SOURCE",
  "authority_generation": 441
}
```

`failback_commit_outcome`:

```text
PENDING
ACKNOWLEDGED
REJECTED
UNKNOWN
ROLLED_BACK
```

## 10. Selftest와 통합 테스트

기존 stub 기반 테스트는 상태 변환 unit test로 유지한다. 다음 실제 worker
테스트를 필수로 추가한다.

```text
selftest_case_dr_failback_commit_reuses_bootstrap_generation
selftest_case_dr_scheduler_start_adopts_pending_run_generation
selftest_case_dr_failback_commit_duplicate_is_idempotent
selftest_case_dr_failback_abort_fences_scheduler_before_target_authority
selftest_case_dr_scheduler_blocks_forward_cycle_on_target_authority
selftest_case_dr_failback_commit_recovers_from_ack_timeout
```

테스트는 실제 background/systemd test worker와 실제
`control.state/control.ack` 파일을 사용한다. PASS 조건:

```text
one transition -> one generation
requested generation == ACK generation
no scheduler-start overwrite
abort prepare -> STOPPED ACK
TARGET authority -> no source-to-target I/O
```

## 11. 구현 순서

1. control protocol v4와 launch state reader/writer
2. worker pending generation 채택
3. `resume_after_transition()` 단일 generation 전환
4. commit journal과 멱등 resume
5. 2단계 abort fence
6. cycle authority fence
7. status/error 확장
8. 실제 worker 통합 selftest
9. Cloud Agent/Backend 계약과 동시 배포

## 12. AS-IS / TO-BE

| 항목 | AS-IS | TO-BE |
| --- | --- | --- |
| generation 생성 | caller와 worker가 각각 생성 | transition caller가 한 번만 생성 |
| worker 시작 | `scheduler-start`로 pending 요청 덮어씀 | pending generation 채택 |
| resume 성공 | PID/heartbeat 이후 별도 ACK 대기 | 동일 generation ACK까지 한 계약 |
| commit 재시도 | 실행 위치 불명확 | durable journal에서 멱등 재개 |
| abort | authority 필드만 TARGET으로 변경 | scheduler fence, VM 복구, TARGET commit |
| TARGET 안전성 | scheduler가 남을 수 있음 | 정방향 cycle hard fence |
| selftest | resume 함수 stub | 실제 worker와 generation 검증 |

## 13. 완료 기준

```text
commit request generation == scheduler ACK generation
commit journal == ACKNOWLEDGED
SOURCE authority에서만 forward scheduler RUNNING
rollback prepare == STOPPED/IDLE ACK
rollback commit == SOURCE OFF + TARGET ON + TARGET authority
TARGET authority에서 source-to-target I/O 0건
duplicate commit/abort returns the same terminal result
```
## 17. Implementation Verification

The implementation is accepted only when all of the following pass:

1. Shell syntax validation for the command, scheduler, runtime, and self-test.
2. Full FTCTL self-test, including the real scheduler resume path.
3. Repeated `dr-failback-commit-status` returns the same durable outcome.
4. A nonzero or interrupted commit response can be classified without changing
   authority.
5. Rollback `prepare` reaches a STOP generation ACK before VM power recovery.
6. Rollback `commit` records `ROLLED_BACK` only after source OFF and target ON
   evidence.
7. Installed host scripts contain protocol v4 and the new status command.

### AS-IS / TO-BE

| Area | AS-IS | TO-BE |
| --- | --- | --- |
| Resume generation | Worker could replace the caller generation | Worker adopts the durable caller generation |
| Commit evidence | Process exit was the only result | Durable commit journal is authoritative |
| Lost ACK | Reported as failure | Classified as `UNKNOWN` and probed |
| Rollback order | VM power recovery preceded engine fencing | STOP fence precedes all VM lifecycle recovery |
| Retry | Could repeat authority changes | Idempotent by Plan, run, session, and generation |
| Operator evidence | Generic command error | Typed outcome, generation, ACK, and rollback state |

## 18. Live STOP ACK Race Verification

The 2026-07-27 live rollback preflight exposed a terminal ACK race that the
initial self-test did not model:

```text
control generation 16 -> STOPPED/IDLE ACK written
worker exits immediately after ACK
caller rechecks active.pid -> worker is gone
valid rollback fence is reported as timeout
```

The scheduler request path now captures the immutable owner tuple before
writing the request:

```text
scheduler session + lease epoch + PID + process start ticks
```

`STOPPED` success is decided by the requested generation, expected owner run,
and that captured owner tuple in the durable ACK. It does not require the
worker to remain alive after its terminal ACK. Non-terminal ACKs such as
`RUNNING` and `PAUSED` still require a live matching worker.

The plan-scoped control self-test now writes a STOPPED ACK only after removing
the active worker identity. The test passes only when the caller accepts that
durable terminal ACK without a false timeout.

## 19. Rollback Error Ownership

A successful rollback commit is the terminal authority for the failed
failback attempt. It must therefore clear the transient failback error fields
from the run projection before copying that projection to the plan status:

```text
error_code=""
error_message=""
failed_component=""
```

The failed Cloud run remains immutable audit history. The cleared FTCTL fields
mean only that the current serving state is no longer failed: target authority
is restored, the source is powered off, and the scheduler is stopped.

| Area | AS-IS | TO-BE |
| --- | --- | --- |
| Rollback result | `ROLLED_BACK`, but stale failback error remains current | `ROLLED_BACK` and current error fields are empty |
| Cloud refresh | Reprojects the stale engine error onto the plan | Projects `FAILED_OVER_UNPROTECTED` without a current error |
| Audit | Failed run and current state can be confused | Failed run is retained; current authority is healthy and explicit |

## 20. Commit Envelope Generation Source Amendment - 2026-08-06

Failback authority generation is supplied by Cloud from the active committed
cutover session. It is not derived from reverse checkpoint sequence, baseline
generation, FTCTL operation Run, or Cloud DB Run ID. FTCTL validates and
persists the supplied generation but does not synthesize it.

The complete envelope and write-ahead journal ordering are defined in document
453. Fixtures in which checkpoint and authority generation happen to be equal
must not be treated as a contract requirement.

## 2026-07-27 Late ACK and Authority Snapshot Convergence Addendum

이 문서의 generation 및 rollback fence 계약은 유지한다. 다만 commit 호출이
timeout된 뒤 동일 generation의 정상 ACK가 도착하는 경우와, failback operation
Run과 재개된 scheduler의 producer Run이 다른 경우의 최종 판정은 문서 216을
따른다.

- `dr-failback-commit-status`는 과거 operation state만 반환하지 않고 현재
  `control.state`와 `control.ack`를 다시 검증한다.
- 요청 generation, owner Run, session/lease/PID lineage, SOURCE ON 및 TARGET OFF
  증거가 모두 일치하면 late ACK를 `ACKNOWLEDGED`로 원자 수렴한다.
- operation Run은 audit/transition 소유자이고, `status.state`는 Plan authority,
  checkpoint의 `producer_run_id`는 복제 cycle 생산자다. 세 식별자를 서로
  대체하지 않는다.
- latest cycle은 한 개의 immutable checkpoint에서 원자적으로 읽으며 다른
  Run의 NBD/CBT 필드를 섞지 않는다.

상세 상태 파일 소유권, reconciliation 함수, status schema v2, selftest 및
PASS 조건:
[216-dr-failback-late-ack-and-authority-snapshot-convergence-design-20260727.md](216-dr-failback-late-ack-and-authority-snapshot-convergence-design-20260727.md).
