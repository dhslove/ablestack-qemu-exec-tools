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

`현재 작업 실행 취소`는 Run 범위 명령이며 지속 보호를 중지하는 명령이 아니다. FTCTL은
취소 Run의 terminal journal을 먼저 `CANCELED`로 확정한 뒤, 별도의 내부 recovery Run UUID를
만들어 control generation을 `run`으로 전환한다. 취소 Run UUID를 recovery producer로
재사용해서는 안 된다. 그래야 자동 Full Reseed가 이미 종결된 Cloud Run을 성공 상태로 다시
덮어쓰지 않는다.

전송 중 취소는 중단된 시퀀스를 `pending_reseed_sequence`로 유지하고
`pending_reseed_request_bound=false`로 기록한다. 로컬 reconcile은 내부 recovery Run을
사용해 systemd scheduler를 다시 시작하고 같은 시퀀스를 Full Reseed한다. 이 Cycle은 취소한
Cloud Run의 결과가 아니라 지속 보호의 새 producer Cycle이며, 완료 후에만 새 durable baseline과
다음 증분 Cycle을 허용한다.

`동기화 일시 중지`와 `보호 해제`는 계속 `scheduler_desired_state=STOPPED`를 유지한다.
`dr-sync-recover`는 자동 recovery queue가 시작되지 못했거나 scheduler 재기동이 반복 실패한
경우의 운영자 복구 수단으로 남는다. 자동 복구 변경은 remote `KVM_TO_KVM`의
`site-agent-nbd` 경로에만 적용하고 VMware/VDDK 및 로컬 RBD 성공 경로의 기존 취소 계약은
변경하지 않는다.

FTCTL 로컬 reconcile은 `scheduler_recovery_run_uuid`가 있으면 과거 완료 producer보다 해당
내부 Run을 우선해 재기동한다. 취소 drain 중에는 내구성 `command=stop`을 계속 우선하고,
terminal journal 기록과 recovery queue 생성이 모두 끝난 뒤에만 `command=run`으로 바꾼다.
따라서 종료 중인 mover를 조기에 다시 시작하지 않으면서도 다음 timer 주기에는 보호가 자동으로
복구된다.

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
4. 취소 terminal 이후 별도 내부 recovery Run이 같은 시퀀스를 Full Reseed로 재수행
5. 복구 완료 후 다음 CBT incremental Cycle 성공
6. 기존 sync, pause/resume, release, test failover/cleanup, failover/failback 계약 유지
7. remote `KVM_TO_KVM` 취소 후 scheduler가 자동 `RUNNING`으로 복귀
8. 취소 Run은 `CANCELED`를 유지하고 내부 recovery Run만 Full Reseed producer가 됨
9. systemd 종료와 terminal 기록 사이에 로컬 reconcile이 실행돼도 `command=stop` 보류 유지
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

## 4.2 내부 recovery Run 생성 계약

자동복구 Run은 취소한 Cloud Run과 다른 새 UUID를 사용하므로 상태 파일이 존재하지 않는다.
따라서 recovery queue는 다음 순서를 지켜야 한다.

1. `ftctl_dr_runtime_write_state()`로 표준 Run 상태 파일을 원자적으로 생성한다.
2. 생성이 성공한 뒤 `ftctl_dr_runtime_path_set()`으로 scheduler 전용 필드를 추가한다.
3. Run 파일 생성 후에만 sequence의 `pending_reseed_run`과 control generation을 갱신한다.
4. 어느 단계든 실패하면 `scheduler_recovery_rc`와 실패 단계를 남기며, 존재하지 않는 Run을
   control owner로 게시하지 않는다.

`ftctl_dr_runtime_path_set()`은 기존 파일 갱신 전용이며 파일이 없으면 실패하는 것이 계약이다.
테스트에서 이를 생성 함수처럼 mock하면 실환경 실패를 숨기므로, 스모크 테스트도 미존재 파일
갱신은 실패하도록 유지하고 표준 writer 호출을 검증한다.

## 5. AS-IS / TO-BE

| 구분 | AS-IS | TO-BE |
| --- | --- | --- |
| 취소 반응 | 전송 완료 뒤 STOP ACK | scheduler cgroup 선점 종료 |
| FTCTL 상태 | `CANCELED / COPYING` 충돌 | drain 확인 뒤 terminal `CANCELED` |
| Cloud 상태 | 요청 수락을 terminal로 오인 가능 | terminal 증거 확인 전 `CANCEL_REQUESTED` |
| 자동 복구 | 취소가 지속 보호까지 영구 정지 | 취소 Run 종결 후 별도 내부 Run으로 보호 자동 복구 |
| recovery Run 파일 | 갱신 함수가 미존재 파일에서 실패 | 표준 writer로 생성 후 scheduler 필드 갱신 |
| 로컬 reconcile | 취소한 Cloud Run을 재사용하거나 영구 정지 | drain 중 `stop` 우선, terminal 후 recovery Run 우선 |
| 대상 기준선 | 부분 덮어쓰기 여부 미표시 | baseline 무효와 Full Reseed 필요 명시 |
| 복구 | 운영자가 별도 복구 메뉴를 실행해야 함 | remote KVM은 자동 복구, 실패 시 수동 복구 제공 |
| terminal one-shot 취소 | 종료된 worker의 ACK를 기다려 pending | live owner 부재를 drain으로 인정하고 로컬 STOP ACK |
| 성공 경로 | 전송 코드와 제어 코드가 결합 | 검증된 전송은 유지하고 제어 경계만 보강 |
