# FTCTL DR Post-Failover Scheduler Terminal Authority Contract

## 1. 목적

이 문서는 Cloud가 실제 Failover 성공을 커밋한 뒤 FTCTL이 유지해야 하는
TARGET authority 종단 상태를 정의한다.

Cloud 전체 설계는
[581-cross-hypervisor-dr-post-failover-runtime-ui-convergence-design-20260730.md](../../../ablestack-cloud/docs/ftctl/581-cross-hypervisor-dr-post-failover-runtime-ui-convergence-design-20260730.md)를 따른다.

## 2. Preflight에서 확인한 결함

대상 Plan:

```text
2514a846-64a2-4bc7-ba88-38a874410782
```

호스트 `10.10.32.2`의 설치 상태 파일:

```text
action=dr-cutover-commit
state=FAILED_OVER
active_side=TARGET
target_power_state=POWERED_ON
target_promotion_state=PROMOTED
scheduler_state=STOPPED
engine_ack_state=ACKNOWLEDGED
```

누락 필드:

```text
scheduler_desired_state
scheduler_health
replication_activity
scheduler_pid_alive
owner_matched
active_worker_run_uuid
active_worker_pid
active_worker_start_ticks
worker_heartbeat_at
```

Cloud DB에는 과거 값 `scheduler_desired_state=RUNNING`이 남았다.

## 3. 종단 상태 불변식

`state=FAILED_OVER`와 `active_side=TARGET`이면 다음 값은 강제된다.

```text
scheduler_state=STOPPED
scheduler_desired_state=STOPPED
scheduler_health=SUPPRESSED
scheduler_recovery_state=SUPPRESSED
replication_activity=STOPPED
scheduler_pid_alive=false
owner_matched=false
active_worker_run_uuid=
active_worker_pid=
active_worker_start_ticks=
worker_heartbeat_at=
control_state=STOPPED
```

TARGET authority에서 forward Scheduler가 실행되지 않는 것은 정상이다.
`DEAD`, `FAILED`, `DEGRADED`로 표현하지 않는다.

## 4. 코드 설계

파일:

```text
lib/ftctl/dr_runtime.sh
```

새 helper:

```bash
ftctl_dr_runtime_apply_target_authority_terminal_state() {
  local state_path="${1-}"
  local now="${2-$(ftctl_now_iso8601)}"
  ftctl_dr_runtime_path_set "${state_path}" \
    "state=FAILED_OVER" \
    "active_side=TARGET" \
    "scheduler_state=STOPPED" \
    "scheduler_desired_state=STOPPED" \
    "scheduler_health=SUPPRESSED" \
    "scheduler_recovery_state=SUPPRESSED" \
    "replication_activity=STOPPED" \
    "scheduler_pid_alive=false" \
    "owner_matched=false" \
    "active_worker_run_uuid=" \
    "active_worker_pid=" \
    "active_worker_start_ticks=" \
    "worker_heartbeat_at=" \
    "control_state=STOPPED" \
    "updated_at=${now}"
}
```

호출 지점:

1. `ftctl_dr_runtime_failover_worker()`의 CUTOVER_READY/FAILED_OVER 준비 직후
2. `ftctl_dr_runtime_cutover_commit()`의 Cloud evidence 검증 직후
3. Failback abort가 TARGET authority로 복귀할 때

## 5. 원자적 파일 갱신

`run_path`를 먼저 완성한 다음 같은 디렉터리의 임시 파일을 사용해
`status.state`로 rename한다.

```text
write complete run state
  -> fsync run state
  -> copy to status.state.tmp
  -> fsync temp
  -> atomic rename status.state.tmp -> status.state
```

부분 필드가 노출되는 `cp` 기반 갱신은 atomic helper로 교체한다.

## 6. CUTOVER_COMMIT idempotency

입력 키:

```text
plan UUID
run UUID
cutover session ID
checkpoint sequence
authority generation
```

동일 generation 재호출:

- 이미 `FAILED_OVER/TARGET/ACKNOWLEDGED`이면 성공 응답
- canonical terminal fields를 다시 적용
- completed timestamp는 최초 값을 유지

낮은 generation:

```text
DR_CUTOVER_GENERATION_STALE
```

높은 generation이지만 session/checkpoint 불일치:

```text
DR_CUTOVER_SESSION_MISMATCH
DR_CUTOVER_CHECKPOINT_MISMATCH
```

## 7. status 출력 계약

`dr-status --scope plan-authority --json`은 다음 필드를 반드시 출력한다.

```json
{
  "state": "FAILED_OVER",
  "active_side": "TARGET",
  "scheduler_state": "STOPPED",
  "scheduler_desired_state": "STOPPED",
  "scheduler_health": "SUPPRESSED",
  "scheduler_recovery_state": "SUPPRESSED",
  "replication_activity": "STOPPED",
  "scheduler_pid_alive": false,
  "owner_matched": false,
  "engine_ack_state": "ACKNOWLEDGED"
}
```

TARGET authority인데 desired state가 비어 있거나 RUNNING이면 status command는
성공 JSON을 만들지 않고 다음 integrity code를 반환한다.

```text
DR_TARGET_AUTHORITY_SCHEDULER_STATE_INCOHERENT
```

다만 rolling upgrade 호환 기간에는 한 릴리스 동안 다음 보정이 허용된다.

```text
TARGET + FAILED_OVER + missing desired
  -> desired STOPPED로 canonicalize
  -> warning event 기록
```

RUNNING 값은 자동 보정하지 않고 integrity failure로 처리한다.

## 8. Agent 경계

FTCTL은 다음 값만 제공한다.

- runtime authority
- scheduler terminal state
- checkpoint/manifest locator
- engine acknowledgement

FTCTL은 다음 값을 만들지 않는다.

- Cloud target VM ID
- Cloud target volume ID
- Cloud action eligibility
- UI severity

이 값은 Cloud가 소유한다.

## 9. 테스트 설계

추가 smoke:

```text
tests/ftctl/dr_cutover_terminal_state_smoke.sh
```

필수 케이스:

1. 기존 desired RUNNING 상태에서 commit 후 STOPPED 확인
2. worker PID/heartbeat 제거 확인
3. run/status 파일 동등성 확인
4. 동일 generation 재호출 확인
5. stale generation 거절 확인
6. session mismatch 거절 확인
7. status JSON 필수 필드 확인
8. Failback abort 후 TARGET terminal state 확인

## 10. AS-IS / TO-BE

| 항목 | AS-IS | TO-BE |
| --- | --- | --- |
| Scheduler state | STOPPED | STOPPED |
| Desired state | 누락 또는 RUNNING 잔존 | STOPPED |
| Health | 이전 값 또는 비어 있음 | SUPPRESSED |
| Worker identity | 이전 worker 정보 잔존 가능 | 모두 제거 |
| Status 갱신 | `cp` 기반 | 임시 파일 + atomic rename |
| Retry | 일부 state만 재사용 | 동일 generation idempotent |
| Cloud 소유 정보 | 혼합 가능성 | FTCTL에서 생성하지 않음 |

## 11. 구현 판정 기준

다음 명령 결과가 모두 충족되어야 한다.

```text
state=FAILED_OVER
active_side=TARGET
scheduler_state=STOPPED
scheduler_desired_state=STOPPED
scheduler_health=SUPPRESSED
replication_activity=STOPPED
engine_ack_state=ACKNOWLEDGED
```

이 계약이 충족된 뒤 Cloud의 Plan, Runtime, Session, Replica projection과
Protection View를 검증한다.
