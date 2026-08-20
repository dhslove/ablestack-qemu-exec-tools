# FTCTL DR Requested Cycle Terminal Journal Design

## 1. 목적

보호 그룹 Full Seed가 영구 완료된 직후 다음 CBT Cycle이 시작되는 경쟁 조건에서도 요청 Run의 완료 소유권을 잃지 않도록 한다. 검증된 VMware -> ABLESTACK(RBD) 전송, NBD, librbd 경로는 변경하지 않는다.

## 2. 원인

스케줄러는 durable checkpoint와 Plan status를 먼저 기록한 뒤 요청 Run 파일을 `full-resync-completed`로 투영했다. 이 경로는 일반 failback worker와 달리 terminal journal을 만들지 않았다. 다음 Cycle이 먼저 시작되면 Plan scheduler owner가 바뀌어 `dr-status --run`의 `control_request_run_uuid`까지 바뀔 수 있었다.

## 3. 구현 계약

1. requested Cycle이 `LOCAL_DURABLE`로 완료되면 다음 Cycle 계산 전에 terminal journal을 원자 기록한다.
2. journal 기록 뒤 Run state에 terminal 필드를 기록한다.
3. `dr-status --run`은 Plan의 최신 scheduler owner 대신 Run에 저장된 request owner를 우선한다.
4. journal 누락 복구는 다음 조건을 모두 만족할 때만 허용한다.
   - `state=READY`
   - `step=full-resync-completed`
   - `progress=100`
   - request owner가 조회 Run과 일치
   - requested Cycle state가 completed
   - latest completed mode가 Full Seed 또는 Full Reseed
   - commit state가 durable
   - target durable true
   - completed sequence와 cycle token 존재
5. 복구는 전송을 재시작하지 않고 terminal journal과 Run terminal projection만 보완한다.

## 4. 상태 파일 순서

```text
checkpoint/metrics/restore-point durable
  -> plan latest-completed snapshot
  -> requested-cycle state COMPLETED
  -> run terminal journal atomic write
  -> run state terminal projection
  -> next-cycle jitter/sleep
  -> next CBT cycle
```

## 5. AS-IS / TO-BE

| 항목 | AS-IS | TO-BE |
|---|---|---|
| Full Seed terminal | Run state만 갱신 | journal + Run state |
| 다음 증분 경쟁 | terminal 누락 가능 | terminal 선행 보장 |
| Run owner | Plan scheduler owner 영향 | operation owner 불변 |
| 조회 복구 | 없음 | durable 완전 증거 기반 제한 복구 |
| capability | 일반 terminal causality | `dr-requested-cycle-terminal-v1` |

## 6. 검증

- 1-disk Linux, 2-disk Linux, 2-disk Windows 요청 Run을 구성한다.
- durable Full Seed 상태에서 terminal journal 생성 여부를 확인한다.
- 다음 scheduler owner로 control을 변경한 뒤에도 run-scoped owner와 terminal authority가 유지되는지 확인한다.
- live transfer나 불완전 commit에서는 복구가 발생하지 않는지 확인한다.

## 7. 2026-08-20 scheduler sequence fallback과 terminal barrier 보강

### 7.1 확인된 배포 후 실패 경로

RPM의 FTCTL 스크립트는 갱신됐지만 Plan별 systemd scheduler는 패키지 교체 전에 시작된
장기 실행 프로세스였다. 이 프로세스는 구 shell 함수를 메모리에 유지해 Full Seed의
`sequence.state`를 `COMPLETED`로 만든 뒤 terminal journal 기록 실패를 `|| true`로
무시하고 다음 증분으로 진행했다. Run 파일에는 `requested_cycle_state=PENDING`이 남았기
때문에 새 `dr-status --run`도 이미 완료된 scheduler sequence를 복구 증거로 사용하지
못했다.

### 7.2 종결 발행 장벽

requested Full Seed Cycle은 다음 순서로만 종결한다.

```text
data/checkpoint/metrics LOCAL_DURABLE
  -> Run terminal journal atomic write
  -> Run terminal projection
  -> scheduler sequence COMPLETED
  -> next incremental cycle
```

terminal journal 또는 Run 투영이 실패하면 scheduler sequence는 `TERMINALIZING`으로
유지한다. 같은 Cycle의 종결 발행만 재시도하며 다음 증분 데이터 전송은 시작하지 않는다.
`COMPLETED`는 terminal journal과 Run terminal 필드가 모두 영구 기록된 뒤에만 쓸 수 있다.

### 7.3 제한적 상태 복구

`dr-status --run`은 Run 파일의 requested state가 완료되지 않았을 때 Plan의
`scheduler/sequence.state`를 추가로 읽을 수 있다. 다음 조건이 모두 참일 때만 과거
누락 journal을 복구한다.

1. scheduler `requested_cycle_owner_run`이 조회 Run UUID와 일치
2. scheduler `requested_cycle_sequence`가 Run의 latest completed sequence와 일치
3. scheduler `requested_cycle_state=COMPLETED`
4. latest completed token이 `<plan_uuid>:<sequence>`와 일치
5. Run이 `READY/full-resync-completed/100%`
6. requested/effective mode가 `FULL_RESEED` 또는 `FULL_SEED`
7. commit이 durable이고 `target_durable=true`

현재 증분 Cycle, 다른 Run owner 또는 불완전 commit은 복구 근거가 될 수 없다.

### 7.4 배포 rolling reload

패키지 설치만으로 장기 실행 scheduler 코드가 교체됐다고 판정하지 않는다. 배포 절차는
Plan별 unit을 조회하고 `cycle_state=IDLE`인 unit만 순차 재시작한다. 전송 중 unit은
완료될 때까지 대기하거나 deferred로 남긴다. 재시작 후 scheduler 상태에 기록된
`scheduler_code_sha256`과 `scheduler_started_at`이 설치 파일의 SHA256/mtime 이후인지
검증한다.

### 7.5 AS-IS / TO-BE

| 항목 | AS-IS | TO-BE |
|---|---|---|
| terminal 실패 | `|| true`로 무시하고 다음 증분 | `TERMINALIZING`에서 종결만 재시도 |
| sequence 완료 | journal보다 먼저 `COMPLETED` | journal/Run 투영 뒤 `COMPLETED` |
| 상태 복구 | Run 파일의 PENDING에서 중단 | 정확히 일치하는 scheduler sequence를 제한 사용 |
| 패키지 배포 | 실행 중 shell 프로세스는 구 코드 유지 | IDLE Plan별 rolling reload와 코드 hash 검증 |
| 데이터 경로 | VMware mover/NBD/librbd 성공 경로 | 변경 없음 |
