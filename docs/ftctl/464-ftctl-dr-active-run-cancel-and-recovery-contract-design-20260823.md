# FTCTL DR Active Run Cancel And Recovery Contract Design

## 1. 목적

DR UI의 `실행 취소`가 Cloud DB 상태만 바꾸거나, 진행 중인 전체 재동기화가 끝난 뒤에야
취소되는 문제를 방지한다. 검증된 VMware -> ABLESTACK(RBD)의 VDDK, `qemu-img`, librbd
전송 경로는 변경하지 않고 scheduler 제어 경계와 terminal 판정만 보강한다.

## 2. 확인된 원인

1. `dr-cancel`은 Run을 먼저 `CANCELED`로 기록했다.
2. scheduler는 동기식 전송 함수가 끝날 때까지 `control.state=stop`을 다시 읽지 못했다.
3. Cloud Agent 제한 시간보다 긴 전송에서는 Cloud가 `CANCEL_REQUESTED`, FTCTL은
   `CANCELED / COPYING`으로 서로 다른 상태를 표시했다.
4. 전송이 끝난 뒤 STOP ACK가 생성됐으므로 실제 데이터 복사는 취소되지 않았다.
5. 이후 `dr-sync-recover`는 `control_state=STOPPED`를 일반 운영 중지로 보아 거절했다.

## 3. 구현 계약

### 3.1 실행 중 취소

1. FTCTL은 먼저 Run을 `CANCEL_REQUESTED`로 기록한다.
2. plan scheduler의 control generation에 `stop`을 기록한다.
3. systemd 소유 scheduler는 `KillMode=control-group`으로 scheduler, mover, `qemu-img`,
   `nbdkit`을 같은 종료 경계에서 중단한다.
4. unit 종료와 worker lease 정리를 확인한 뒤에만 Run을 `CANCELED`로 종결한다.
5. 전송 중 취소라면 `runtime_endpoints_drained=true`와 scheduler unit inactive를 확인해야
   terminal 취소로 인정한다.
6. 제한 시간 내 종료되지 않으면 `CANCEL_REQUESTED`를 유지하고 재시도 가능한 오류를
   반환한다. 성공으로 위장하지 않는다.

### 3.2 데이터 기준선

전체 재동기화 도중 대상 RBD를 중단하면 기존 대상 내용도 부분 덮어쓰기 상태일 수 있다.
따라서 해당 Cycle은 durable checkpoint가 아니며 다음 값을 기록한다.

- `baseline_state=INVALID`
- `reseed_reason=OPERATOR_CANCELED_TRANSFER`
- `scheduler_recovery_state=REQUIRED`
- `current_checkpoint_state=CANCELED`
- 같은 plan sequence를 `pending_reseed_sequence`로 보존

이전 완료 checkpoint 메타데이터는 감사 이력으로 보존하지만 대상 데이터의 현재 기준선으로
재사용하지 않는다.

### 3.3 동기화 복구

`dr-sync-recover`는 일반 `STOPPED` 상태를 무조건 해제하지 않는다. 오직
`scheduler_recovery_state=REQUIRED`이고 `reseed_reason=OPERATOR_CANCELED_TRANSFER`인 경우에만
새 control generation을 `run`으로 전환하고 systemd scheduler를 다시 시작한다. 재개 Cycle은
중단된 시퀀스의 Full Reseed이며, 완료 후에만 `READY`와 새 durable baseline을 기록한다.

운영자가 명시적으로 취소한 상태는 장애 복구 컨트롤러의 자동 재시작 대상이 아니다. Cloud는
이 상태 조합을 자동 `RECOVER_SYNC` 제출에서 제외하고 UI의 `동기화 복구` 명령으로만
`dr-sync-recover`를 호출한다. 소스 사이트 장애나 전송 경로 장애의 자동 복구 계약은 유지한다.

FTCTL 로컬 reconcile도 동일한 계약을 따른다. 취소가 먼저 기록한
`scheduler/control.state command=stop`은 plan `status.state`보다 우선하는 내구성 보류 상태다.
systemd 종료와 status 투영 사이에 타이머가 실행되더라도 로컬 reconcile은 scheduler를 시작하지
않는다. 취소 종결 상태에는 `scheduler_desired_state=STOPPED`도 함께 기록한다. 운영자가 UI에서
`동기화 복구`를 실행해 control generation을 `command=run`으로 전환한 경우에만 같은 시퀀스의
Full Reseed를 다시 시작한다.

### 3.4 Cloud 종결

Cloud는 `FtctlDrCancelAnswer.accepted=true`만으로 Run을 즉시 `CANCELED` 처리하지 않는다.
FTCTL JSON 응답의 `state=CANCELED`, `terminal_authoritative=true`,
`runtime_endpoints_drained=true`, `transfer_activity_state=CANCELED`를 함께 검증한다.
다음 FTCTL terminal 증거가 모두 확인돼야 한다.

- 요청 plan/run UUID 일치
- `state=CANCELED`
- `terminal_authoritative=true`
- `runtime_endpoints_drained=true`
- `transfer_activity_state`가 `COPYING`이 아님

증거가 부족하면 Run은 `CANCEL_REQUESTED`를 유지하고 projection scheduler가 재확인한다.

## 4. 회귀 테스트

1. 대기 중 Run 취소
2. Full Seed 전송 중 취소와 scheduler cgroup 종료
3. 취소 timeout 시 거짓 terminal 금지
4. 취소 후 `dr-sync-recover`가 같은 시퀀스를 Full Reseed로 재수행
5. 복구 완료 후 다음 CBT incremental Cycle 성공
6. 기존 sync, pause/resume, release, test failover/cleanup, failover/failback 계약 유지
7. 운영자 취소 후 자동 복구 평가 주기를 지나도 scheduler가 `STOPPED`로 유지
8. UI `동기화 복구` 후에만 같은 시퀀스 Full Reseed 재시작
9. systemd 종료와 status 투영 사이에 로컬 reconcile이 실행돼도 `command=stop` 보류 유지
10. 전송이 이미 terminal이고 live scheduler/worker가 없으면 그 부재를 drain 경계로 사용해
    STOP generation을 로컬 ACK하고 즉시 `CANCELED`로 종결

## 4.1 무워커 취소 ACK 보강

ABLESTACK RBD 간 페일백은 역방향 복사가 끝난 뒤 Cloud 수명주기 커밋을 기다리는 동안
FTCTL one-shot worker가 먼저 종료될 수 있다. 이때 UI에서 `현재 작업 실행 취소`를 요청하면
기존 구현은 존재하지 않는 worker의 STOP ACK를 기다려 `DR_CANCEL_DRAIN_PENDING`에 고정됐다.

다음 조건을 모두 만족하면 별도 worker ACK 없이 로컬 STOP ACK를 기록한다.

- scheduler unit 또는 worker PID가 살아 있지 않음
- 현재 요청이 `dr-cancel`의 STOP generation임
- 실행 중인 scheduler cgroup 소유자가 없음

이 처리는 전송 중 worker 강제 종료 경로를 대체하지 않는다. live worker가 있으면 기존대로
systemd cgroup을 중단하고 unit inactive 및 lease 종료를 확인해야 한다. 따라서 검증된 RBD 전송과
VMware 전송 경로에는 영향이 없고, 이미 종료된 제어 주체에 대한 terminal 수렴만 보강한다.

## 5. AS-IS / TO-BE

| 구분 | AS-IS | TO-BE |
| --- | --- | --- |
| 취소 반응 | 전송 완료 뒤 STOP ACK | scheduler cgroup 선점 종료 |
| FTCTL 상태 | `CANCELED / COPYING` 충돌 | drain 확인 뒤 terminal `CANCELED` |
| Cloud 상태 | 요청 수락을 terminal로 오인 가능 | terminal 증거 확인 전 `CANCEL_REQUESTED` |
| 자동 복구 | 운영자 취소도 장애로 보고 재시작 | 취소 보류는 제외하고 UI 복구만 허용 |
| 로컬 reconcile | 지연된 status의 `RUNNING`을 보고 재시작 | 내구성 control의 `stop`을 우선해 재시작 금지 |
| 대상 기준선 | 부분 덮어쓰기 여부 미표시 | baseline 무효와 Full Reseed 필요 명시 |
| 복구 | STOPPED 상태에서 거절 | 취소 복구 계약일 때만 제한적으로 재시작 |
| terminal one-shot 취소 | 종료된 worker의 ACK를 기다려 pending | live owner 부재를 drain으로 인정하고 로컬 STOP ACK |
| 성공 경로 | 전송 코드와 제어 코드가 결합 | 검증된 전송은 유지하고 제어 경계만 보강 |
