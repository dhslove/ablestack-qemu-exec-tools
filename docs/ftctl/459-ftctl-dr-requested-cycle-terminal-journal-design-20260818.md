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
