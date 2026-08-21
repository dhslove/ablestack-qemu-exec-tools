# FTCTL DR RPO Deadline Scheduler Design

## 1. 목적

지속 보호의 RPO를 단순한 scheduler sleep 간격이 아니라 마지막 대상 durable checkpoint부터 다음 durable checkpoint까지의 최대 허용 시간으로 보장한다. 검증된 VMware -> ABLESTACK(RBD)의 VDDK, NBD, librbd 전송 경로는 변경하지 않는다.

## 2. 확인된 문제

- 정책 RPO와 `schedule.intervalSeconds`는 300초였다.
- 기존 scheduler는 Cycle 시작 시각에 interval과 jitter를 더해 다음 시작을 계산했다.
- 스냅샷, CBT 조회, admission 대기, 전송 및 durable commit 시간이 RPO 예산에 포함되지 않았다.
- 세 VM 동시 보호에서 durable 완료 간격은 340~345초였다.
- 현재 상태는 다시 낮은 RPO로 갱신되지만 완료 직전에는 목표 RPO를 반복적으로 초과할 수 있었다.
- 1차 deadline 구현 후에도 `sleep_or_stop()`이 실제 경과시간이 아니라 1초 반복 횟수를 사용했다. 각 반복의 제어 파일 확인과 heartbeat I/O가 누적되어 283초 대기가 실제로는 약 323초가 되었고, 계산된 `scheduler_next_run_at`보다 약 40초 늦게 Cycle이 시작되었다.

## 3. Deadline 계약

```text
durable_deadline = last_target_durable_epoch + target_rpo_seconds
execution_budget = P95(last 10 scheduler wall durations)
start_advance = execution_budget + bounded_jitter
next_cycle_start = durable_deadline - start_advance
sleep = max(0, next_cycle_start - now)
```

대기 루프는 `sleep` 호출 횟수를 세지 않고, 시작 시 계산한 절대 epoch와 현재 epoch를 매 반복 비교한다. 제어 명령 확인과 heartbeat 기록 시간은 대기 예산을 추가로 소비하지 않으며, `scheduler_next_run_at`은 실제 wake-up barrier와 같은 deadline을 나타낸다.

표본이 없으면 `clamp(targetRpo / 5, 30, targetRpo / 2)`를 초기 예산으로 사용한다. P95는 mover 전송시간이 아니라 Cycle lock/admission, snapshot, CBT, copy, commit, terminal publication을 포함한 scheduler 벽시계 시간이다. 실행 예산은 최소 15초, 최대 RPO의 1/2로 제한한다.

jitter는 deadline에 가산하지 않는다. 여러 계획의 동시 시작을 분산하되 `next_cycle_start`를 더 앞당기는 값으로만 사용한다.

## 4. 상태 계약

FTCTL 상태에 다음 값을 항상 제공한다.

| 필드 | 의미 |
|---|---|
| `target_rpo_seconds` | 정책의 목표 RPO |
| `latest_completed_cycle_sequence` | 최신 durable Cycle sequence |
| `scheduler_next_run_at` | deadline 예산을 반영한 다음 시작 예정 시각 |
| `scheduler_execution_budget_seconds` | 현재 적용한 P95 또는 초기 실행 예산 |
| `scheduler_cycle_wall_duration_seconds` | 최신 완료 Cycle의 전체 벽시계 실행시간 |

기존 `latest_completed_checkpoint_sequence`는 호환을 위해 유지하고 `latest_completed_cycle_sequence`를 같은 값의 명시적 alias로 제공한다.

## 5. 실패 및 복구 규칙

- 자원 부족 재시도는 동일 Cycle sequence/token을 유지한다.
- 실행시간이 예산을 초과하면 다음 sleep을 0으로 만들되 중복 Cycle을 시작하지 않는다.
- deadline 계산 실패 시 기존 interval 시작 규칙으로 조용히 후퇴하지 않고 상태에 `DR_RPO_DEADLINE_INVALID`를 기록한다.
- 다음 실행 예정 시각은 Cycle 시작 때 지우고, durable terminal 완료 후 다시 계산해 기록한다.

## 6. 검증

1. 계산 단위 테스트: 표본 없음, P95, clamp, jitter, 이미 지난 deadline.
2. 대기 회귀 테스트: 제어/heartbeat 처리시간이 있어도 반복 횟수가 아니라 절대 epoch에 도달하면 종료.
3. 상태 테스트: 목표 RPO, sequence alias, 다음 실행 시각이 JSON에 항상 존재.
4. 1/2 disk Linux와 Windows 동시 3계획, 연속 10 Cycle.
5. 각 durable 간격이 `target RPO + 명시적 판정 grace` 이내인지 확인.
6. 변경 VM은 CBT incremental bytes > 0, 미변경 VM은 NO_CHANGE 허용.
7. 기존 Full Seed, NBD 범위, RBD locator와 terminal journal 회귀 확인.

## 7. AS-IS / TO-BE

| 구분 | AS-IS | TO-BE |
|---|---|---|
| RPO 의미 | Cycle 시작 간격 | durable-to-durable deadline |
| 실행시간 | RPO 외부 비용 | P95 실행 예산으로 선반영 |
| jitter | interval에 가산 | deadline 안에서 시작을 앞당김 |
| 다음 실행 | 상태에서 누락 | `scheduler_next_run_at` 제공 |
| scheduler 대기 | 반복 횟수에 I/O 시간이 누적 | 절대 epoch deadline까지 대기 |
| 최신 sequence | checkpoint 명칭만 제공 | cycle alias도 제공 |
| 데이터 경로 | 검증된 VDDK/NBD/librbd | 변경 없음 |
