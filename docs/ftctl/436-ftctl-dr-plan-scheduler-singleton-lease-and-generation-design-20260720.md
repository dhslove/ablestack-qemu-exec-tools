# FTCTL DR Plan Scheduler Singleton Lease And Generation Design

Date: 2026-07-20

Status: live-preflight-validated implementation design

Cloud companion:
`ablestack-cloud/docs/ftctl/564-cross-hypervisor-dr-plan-scheduler-singleton-authority-design-20260720.md`

## 1. 목적

FTCTL DR 지속 복제 Scheduler를 run별 background process가 아니라 Plan별 단일
보호 세션으로 관리한다. pause/resume/test cleanup 이후에도 worker 중복, stale
PID, 잘못된 ACK, 감소하는 runtime generation이 발생하지 않도록 Plan singleton
lease와 독립 generation을 도입한다.

기존 FT/HA의 global lock, RBD/QCOW2 blockcopy, xcolo, VMware mover 데이터 경로는
변경하지 않는다. 변경 범위는 DR Scheduler lifecycle과 status/control contract다.

## 2. 실환경 Preflight

Plan `cbdf5abe-2795-4e7c-9995-78a67129b0de`에서 다음을 확인했다.

- `scheduler/*.pid` 6개가 존재했다.
- 5개 PID는 DEAD, 한 PID만 ALIVE였다.
- Cloud 최신 resume run은 `d0fb2b49-...`, PID `957336`은 DEAD였다.
- 실제 live worker는 이전 run `f2c9d0dc-...`, PID `200700`이었다.
- `control.state`와 `control.ack`은 최신 run `d0fb2b49-...`를 owner로 기록했다.
- live worker는 계속 Plan checkpoint를 생성했지만 Cloud current authority는 최신
  run의 stale 상태를 유지했다.

따라서 cycle lock은 데이터 쓰기 충돌은 제한했지만 Scheduler singleton과 control
owner 증명에는 충분하지 않다.

## 3. 현재 코드의 구조적 문제

### 3.1 run별 PID

```bash
ftctl_dr_scheduler_pid_path() {
  printf '%s/%s.pid\n' "$(ftctl_dr_scheduler_dir "$plan")" "$run"
}
```

`ftctl_dr_scheduler_ensure_running()`은 요청 run PID만 검사한다. 다른 run의 live
worker가 있어도 새 worker를 시작할 수 있다.

### 3.2 ACK identity 미검증

`ftctl_dr_scheduler_wait_for_ack()`은 generation/state만 비교한다. owner run,
실제 worker PID와 process incarnation을 검증하지 않는다.

### 3.3 generation 단위 혼합

- Scheduler recovery: control generation을 `runtime_generation`에 기록
- Scheduler cycle: run-local cycle sequence를 `runtime_generation`에 기록

같은 run에서 generation이 감소할 수 있다.

### 3.4 Plan authority와 run state 혼합

지속 worker 상태와 pause/resume operation 상태가 같은 run/status 파일 조합을
사용한다. `dr-status --run`이 operation 상태, Plan latest checkpoint, scheduler
상태를 혼합할 수 있다.

## 4. 불변식

1. Plan마다 active scheduler session은 하나다.
2. active session마다 owner lock holder는 최대 하나다.
3. PID 검증에는 PID, command line, process start ticks를 함께 사용한다.
4. worker handoff/restart마다 lease epoch가 증가한다.
5. 같은 lease의 authority sequence는 감소하지 않는다.
6. Plan cycle sequence는 run이 바뀌어도 감소하지 않는다.
7. operation run은 scheduler session identity가 아니다.
8. control ACK는 실제 lease holder만 기록할 수 있다.

## 5. Plan runtime 파일 계약

```text
plans/<plan>/scheduler/
  owner.lock
  lease.state
  active.pid
  control.state
  control.ack
  sequence.state

plans/<plan>/authority.state
plans/<plan>/runs/<operation-run>.state
plans/<plan>/restore-points.jsonl
```

### 5.1 `lease.state`

```text
version=1
plan_uuid=<plan>
scheduler_session_uuid=<session>
lease_epoch=4
worker_pid=12345
worker_start_ticks=987654321
worker_run_uuid=<initial-or-recovery-operation>
acquired_at=<timestamp>
heartbeat_at=<timestamp>
state=ACTIVE
```

### 5.2 `active.pid`

```text
pid=12345
start_ticks=987654321
lease_epoch=4
scheduler_session_uuid=<session>
```

### 5.3 `sequence.state`

```text
plan_cycle_sequence=28
authority_sequence=91
```

모든 state write는 임시 파일 작성, fsync 가능한 범위의 flush, atomic rename을
사용한다.

## 6. lifetime owner lock

worker는 다음 절차로 owner를 획득한다.

```bash
exec 205>"${scheduler_dir}/owner.lock"
flock -n 205 || return DR_SCHEDULER_ALREADY_OWNED
```

FD 205는 worker 종료까지 유지한다. `active.pid`가 stale이어도 lock을 획득할 수
있다면 기존 owner는 없는 것으로 판정한다. lock 획득 후 기존 metadata를 검사하고
lease epoch를 증가시킨다.

`kill -0`만으로는 PID reuse를 구분하지 못하므로 `/proc/<pid>/stat`의 starttime과
command line의 Plan/session을 확인한다.

## 7. 코드 수준 변경

### 7.1 `lib/ftctl/dr_scheduler.sh`

기존 run PID helper를 다음 Plan helper로 대체한다.

```bash
ftctl_dr_scheduler_owner_lock_path PLAN
ftctl_dr_scheduler_lease_path PLAN
ftctl_dr_scheduler_active_pid_path PLAN
ftctl_dr_scheduler_sequence_path PLAN
ftctl_dr_scheduler_process_start_ticks PID
ftctl_dr_scheduler_validate_process PLAN SESSION PID START_TICKS
ftctl_dr_scheduler_read_lease PLAN
ftctl_dr_scheduler_acquire_lease PLAN SESSION REQUEST_RUN
ftctl_dr_scheduler_release_lease PLAN SESSION EPOCH
ftctl_dr_scheduler_find_active_worker PLAN
ftctl_dr_scheduler_adopt_or_start PLAN SESSION REQUEST_RUN PROFILE STATE STATUS
ftctl_dr_scheduler_next_authority_sequence PLAN EPOCH
ftctl_dr_scheduler_next_plan_cycle_sequence PLAN
```

`ftctl_dr_scheduler_has_live_worker(plan)`은 PID 파일 loop가 아니라 lease validation
결과를 반환한다.

```text
NONE
HEALTHY(session, epoch, pid, startTicks)
STALE(metadata)
DUPLICATE(workers[])
MISMATCH(expectedSession, actualSession)
```

### 7.2 `ftctl_dr_scheduler_ensure_running()`

입력은 `plan, schedulerSession, requestRun, profile`이다.

```text
HEALTHY same session
  -> existing worker adopt
  -> 새 process 생성 금지

NONE or STALE same session
  -> owner.lock 획득
  -> epoch + 1
  -> worker 시작

MISMATCH
  -> DR_SCHEDULER_SESSION_MISMATCH

DUPLICATE
  -> DR_SCHEDULER_DUPLICATE_WORKER
  -> 자동 kill 금지
```

### 7.3 Scheduler worker

worker 시작 시 run-local last sequence를 읽지 않는다.

```bash
plan_cycle_sequence="$(ftctl_dr_scheduler_current_plan_sequence "$plan")"
```

각 loop는 다음 순서다.

```text
lease/heartbeat 검증
control request 확인 및 identity ACK
plan cycle lock 획득
planCycleSequence + 1
cycle 실행과 durable commit
authoritySequence + 1
authority.state 갱신
cycle lock 해제
heartbeat 갱신
RPO interval sleep
```

lease가 바뀌거나 owner lock이 유실되면 즉시 worker가 종료한다.

### 7.4 control request/ACK

`control.state`:

```text
version=3
control_generation=24
command=run
request_run_uuid=<resume-operation>
scheduler_session_uuid=<session>
expected_lease_epoch=4
requested_at=<timestamp>
```

`control.ack`:

```text
version=3
control_generation=24
state=RUNNING
request_run_uuid=<resume-operation>
scheduler_session_uuid=<session>
lease_epoch=4
worker_pid=12345
worker_start_ticks=987654321
cycle_state=IDLE
acknowledged_at=<timestamp>
```

`ftctl_dr_scheduler_wait_for_ack()`은 모든 identity field를 비교한다. ACK writer는
현재 owner lock을 보유하고 lease 검증을 통과한 worker로 제한한다.

### 7.5 `lib/ftctl/dr_runtime.sh`

- operation state는 `runs/<run>.state`에만 기록한다.
- current protection authority는 `authority.state`에만 기록한다.
- delegated resume worker는 ACK 검증이 성공한 뒤 operation을 terminal 처리한다.
- Scheduler가 이미 healthy이면 adopt 성공으로 처리하되 active worker의 session과
  epoch를 응답한다.
- `dr-status --plan`은 Plan authority를 반환한다.
- `dr-status --run`은 명시적으로 operation detail만 반환한다.

### 7.6 Timer reconcile

Timer는 Plan마다 다음을 수행한다.

```text
lease validation
  -> healthy: heartbeat/RPO만 확인
  -> stale/dead: protection DEGRADED 기록 후 adopt-or-start
  -> duplicate: DUPLICATE_WORKER 기록, 자동 kill 금지
  -> transition active: restart 보류
```

timer reconcile과 `dr-sync-resume`은 같은 `adopt-or-start` primitive를 사용한다.

## 8. 상태와 generation JSON

`dr-status --plan --json`은 다음을 반환한다.

```json
{
  "scheduler_session_uuid": "...",
  "scheduler_lease_epoch": 4,
  "authority_sequence": 91,
  "plan_cycle_sequence": 28,
  "scheduler_health": "HEALTHY",
  "replication_activity": "IDLE",
  "protection_state": "READY",
  "active_worker_run_uuid": "...",
  "active_worker_pid": 12345,
  "active_worker_start_ticks": 987654321,
  "worker_heartbeat_at": "...",
  "control_generation": 24,
  "control_ack_generation": 24,
  "control_request_run_uuid": "...",
  "owner_matched": true
}
```

기존 `runtime_generation`, `scheduler_pid_alive`, `state=SYNCING`은 한 릴리스 동안
호환 field로 유지한다. Cloud 신규 authority는 이를 ordering key로 사용하지 않는다.

## 9. 보호 상태 계산

Scheduler는 cycle 시작 시 Plan의 `protection_state`를 SYNCING으로 되돌리지 않는다.

```text
첫 durable 전: protection_state=SYNCING
durable 존재 + healthy: protection_state=READY
cycle 실행 중: replication_activity=TRANSFERRING
worker dead/mismatch: protection_state=DEGRADED
operator pause: protection_state=PAUSED
```

current cycle failure는 `replication_activity`와 error를 갱신하고 last completed
checkpoint를 유지한다.

## 10. 오류 코드

```text
DR_SCHEDULER_ALREADY_OWNED
DR_SCHEDULER_DUPLICATE_WORKER
DR_SCHEDULER_SESSION_MISMATCH
DR_SCHEDULER_LEASE_STALE
DR_SCHEDULER_ACK_IDENTITY_MISMATCH
DR_SCHEDULER_OWNER_MISMATCH
DR_STATUS_AUTHORITY_STALE
```

duplicate worker는 데이터 보존 우선으로 자동 kill하지 않는다. Cloud/운영자에게
각 PID/session/epoch 증거를 반환하고 전환 작업을 차단한다.

## 11. 호환 정리

업그레이드 후 reconcile은 run별 `scheduler/*.pid`를 다음처럼 처리한다.

1. 모든 PID의 실제 process identity를 조회한다.
2. live worker가 0개면 신규 Plan lease로 worker를 복구한다.
3. live worker가 1개이고 profile/session이 일치하면 Plan lease로 adopt한다.
4. live worker가 2개 이상이면 duplicate 상태를 기록하고 자동 선택하지 않는다.
5. dead PID 파일은 증거 이벤트를 기록한 뒤 제거한다.

release는 active worker stop ACK, owner lock 해제, lease terminal 기록 후 runtime을
정리한다.

## 12. Selftest

```text
test_dr_scheduler_singleton_rejects_second_worker
test_dr_scheduler_adopts_existing_healthy_worker
test_dr_scheduler_rejects_pid_reuse
test_dr_scheduler_increments_epoch_on_recovery
test_dr_scheduler_ack_requires_worker_identity
test_dr_scheduler_rejects_other_session_ack
test_dr_scheduler_plan_cycle_sequence_survives_resume
test_dr_scheduler_authority_sequence_is_monotonic
test_dr_scheduler_control_generation_is_independent
test_dr_scheduler_duplicate_worker_is_degraded
test_dr_status_separates_plan_authority_and_operation
test_dr_reconcile_recovers_dead_owner_once
```

동시성 테스트는 두 `dr-sync-start`를 동시에 실행하고 owner lock holder와 active
PID가 정확히 하나인지 검증한다.

## 13. 실환경 수용 테스트

1. clean Plan에서 initial sync 시작
2. `owner.lock`, `lease.state`, `active.pid` 생성 확인
3. host 전체에서 해당 Plan worker 수가 1인지 확인
4. incremental cycle 2회와 Plan sequence 증가 확인
5. pause/resume 3회 반복 후 worker/PID 파일 수 확인
6. resume operation run terminal과 scheduler session 지속성 확인
7. worker 강제 종료 후 DEGRADED 및 timer recovery 확인
8. epoch 1회 증가와 worker 1개 복구 확인
9. 다음 durable checkpoint 후 READY 복귀 확인
10. Test Failover quiesce/cleanup 후 같은 singleton 불변식 확인

## 14. 구현 순서

1. singleton/identity/generation selftest
2. Plan file layout와 owner lock
3. lease acquire/validate/release
4. Plan sequence와 authority sequence
5. adopt-or-start와 timer reconcile 통합
6. control protocol v3 ACK identity
7. plan authority/run operation status 분리
8. capability `dr-scheduler-singleton-v1`
9. Cloud/Agent companion contract 적용
10. GitHub Actions RPM build와 32.x 반복 수용 테스트

## 15. AS-IS / TO-BE

| 항목 | AS-IS | TO-BE |
|---|---|---|
| PID | run별 PID 파일 | Plan 단위 active PID/lease |
| worker 수 | 여러 run worker 가능 | owner lock으로 최대 하나 |
| resume | 요청 run worker를 새로 시작 | 기존 session adopt 또는 원자 복구 |
| owner | operation run UUID | scheduler session + lease epoch |
| PID 확인 | `kill -0` 중심 | PID + cmdline + start ticks + lock |
| ACK | generation/state 확인 | request/session/epoch/PID identity 확인 |
| runtime generation | control과 cycle이 혼용 | lease epoch/authority/cycle/control 분리 |
| cycle sequence | run 변경 시 초기화 | Plan 단위 단조 증가 |
| 상태 파일 | run과 Plan authority 혼합 | operation state와 authority 분리 |
| cycle 중 상태 | Plan SYNCING | READY + TRANSFERRING |
| 장애 | stale RUNNING/SYNCING | DEGRADED + reconcile |

## 16. 완료 기준

- Plan별 worker가 0개 또는 1개다.
- pause/resume/test cleanup 반복으로 worker가 늘지 않는다.
- stale PID와 PID reuse를 정상 worker로 오인하지 않는다.
- 다른 worker/session의 ACK로 operation이 성공하지 않는다.
- generation과 Plan cycle sequence가 감소하지 않는다.
- Scheduler 장애는 무한 SYNCING이 아니라 DEGRADED로 관측된다.
- FTCTL/Agent/Cloud DB/UI가 같은 session, epoch, sequence를 보고한다.

## 17. 구현 결과 (2026-07-20)

- `lib/ftctl/dr_scheduler.sh`
  - Plan 단위 `owner.lock`, `active.pid`, `lease.state`, `sequence.state`를 구현했다.
  - PID, `/proc/<pid>/stat` start ticks, command line, scheduler session을 함께
    검증해 PID reuse와 다른 Plan worker를 거부한다.
  - control protocol v3 ACK에 request run, active worker run, session, lease epoch,
    PID/start ticks, owner match를 기록하고 모두 일치할 때만 성공 처리한다.
  - resume/start는 유효한 active worker를 adopt하고, 중복 worker는
    `DR_SCHEDULER_DUPLICATE_WORKER`로 차단한다.
- `lib/ftctl/dr_runtime.sh`
  - status JSON에 scheduler session, lease epoch, authority/Plan cycle sequence,
    scheduler health, replication activity, active worker identity, heartbeat,
    control request run, owner match를 추가했다.
  - capability `control-protocol-v3`, `dr-scheduler-singleton-v1`을 추가했다.
- `bin/ablestack_vm_ftctl_selftest.sh`
  - control v3 active owner identity와 ABLESTACK/VMware checkpoint loop를 검증한다.

검증 결과: shell syntax와 targeted selftest
`selftest_case_dr_plan_scoped_control_protocol`,
`selftest_case_dr_scheduler_ablestack_checkpoint_loop`,
`selftest_case_dr_scheduler_vmware_mock_checkpoint_loop`가 통과했다.

## 18. Status Consumer Identity Correction - 2026-07-21

Plan singleton ownership is insufficient if a consumer interprets the latest
terminal operation Run as the producer. The status request Run now identifies
only the operation envelope. Scheduler lease/active PID identifies the producer,
and each completed cycle carries that producer UUID from its durable record.

Automatic Test Cleanup resume remains unchanged. Status envelope v2 and its
self-test/compatibility rules are normative in document 437.

## 19. Self-owner validation and automatic recovery correction - 2026-07-21

Read-only preflight on Plan `c952cae5-11db-4e2a-807d-5ae1d3f9634d` found that
the resumed worker completed cycles 153 and 154, then stopped with:

```text
state=ERROR
step=scheduler-recovery-failed
error_code=DR_SCHEDULER_OWNER_MISMATCH
scheduler_pid_alive=false
scheduler_health=OWNER_MISMATCH
owner_matched=false
replication_activity=STOPPED
```

The durable checkpoint remained valid. The failure was scheduler ownership,
not data loss. Current worker code converts any failure of
`ftctl_dr_scheduler_active_worker_valid()` into a terminal owner mismatch. That
binary decision is too strong for transient, partially replaced, or repairable
self-record state.

### 19.1 Immutable worker identity

After background `exec`, the worker captures and retains:

```text
local_pid=$BASHPID
local_start_ticks=/proc/$BASHPID/stat[22]
local_session_uuid
local_lease_epoch
local_producer_run_uuid
owner_lock_fd=205
```

The identity is not re-derived from mutable `active.pid` during each loop.
`active.pid` and `lease.state` are durable observations of this identity, not
the source of the worker's self identity.

### 19.2 Diagnostic validation result

Replace boolean validation with a typed result:

```text
VALID
SELF_RECORD_MISSING
SELF_RECORD_STALE
PROCESS_DEAD
START_TICKS_MISMATCH
SESSION_MISMATCH
LEASE_EPOCH_MISMATCH
FOREIGN_LIVE_OWNER
OWNER_LOCK_LOST
```

The worker retries state-file reads three times. If it still owns the lifetime
lock and no higher live lease is proven, `SELF_RECORD_MISSING` and
`SELF_RECORD_STALE` are repaired atomically from immutable local identity and
the loop continues. `FOREIGN_LIVE_OWNER`, a higher lease, or lost owner lock is
a genuine mismatch and stops the worker.

### 19.3 Atomic state files

Write `active.pid`, `lease.state`, `control.ack`, and `sequence.state` through a
temporary file in the same directory, `fsync`, and atomic rename. Readers parse
one complete snapshot and reject duplicate keys or missing required identity
fields. A status query never rewrites these files.

### 19.4 Recovery algorithm

The DR reconcile path scans enabled Plan profiles. For a dead worker:

1. acquire the Plan owner lock non-blocking;
2. recheck that no live owner exists;
3. ensure no transition/checkpoint lease is active;
4. increment `lease_epoch` exactly once;
5. write RECOVERING authority and start one worker;
6. require RUNNING ACK with matching session/epoch/PID/start ticks;
7. require a fresh heartbeat before reporting HEALTHY;
8. require a subsequent durable cycle before restoring normal cutover
   eligibility.

Recovery is rate-limited by Plan and idempotent. Repeated timer invocations may
observe or adopt the same worker but cannot create another worker. A failed
recovery remains DEGRADED with a stable reason; it never leaves a green READY
status.

### 19.5 Self-tests

```text
test_dr_scheduler_repairs_missing_self_record_under_owned_lock
test_dr_scheduler_repairs_stale_self_record_under_owned_lock
test_dr_scheduler_rejects_higher_foreign_lease
test_dr_scheduler_rejects_lost_owner_lock
test_dr_scheduler_recover_dead_owner_once
test_dr_scheduler_reconcile_is_idempotent_under_concurrency
test_dr_scheduler_recovery_requires_identity_ack
test_dr_scheduler_recovery_requires_new_heartbeat
test_dr_scheduler_status_does_not_recover_worker
```

### 19.6 Corrected AS-IS / TO-BE

| Area | AS-IS | TO-BE |
|---|---|---|
| self identity | re-read from mutable active file | immutable local identity plus durable observation |
| validation | boolean pass/fail | typed reason and bounded repair |
| transient file state | terminal OWNER_MISMATCH | atomic reread and self-repair under owner lock |
| genuine conflict | same generic mismatch | proven foreign identity/higher lease only |
| dead worker | may remain stopped | singleton reconcile with lease +1 |
| READY restoration | stale DB/cache may remain green | fresh identity ACK, heartbeat, and cycle required |

## 20. Systemd Cgroup Ownership Correction - 2026-07-22

본 문서의 lease, generation, immutable identity 규약은 그대로 유지한다. 그러나
background subshell과 `nohup`은 Scheduler를 Mold Agent의 systemd cgroup에서
분리하지 못한다. PPID가 1이어도 `/system.slice/mold-agent.service`에 남은 worker는
Agent 재시작 시 종료된다.

Plan별 systemd template가 Scheduler foreground process를 직접 소유하고,
`dr-sync-recover`와 Cloud-fenced local reconcile이 이 unit을 제어하도록 보정한다.
valid committed baseline은 process recovery 중 보존하며 READY는 새 identity ACK,
heartbeat, durable Cycle commit 후에만 성립한다. 파일, CLI, unit, capability, 테스트
계약은
`439-ftctl-dr-systemd-owned-scheduler-and-recovery-design-20260722.md`를 규범으로 한다.
