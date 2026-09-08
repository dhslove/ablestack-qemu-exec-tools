# FTCTL DR Current And Completed Checkpoint Status Contract Design

Date: 2026-07-10

Status: implementation design

Cloud companion: `550-cross-hypervisor-dr-protection-view-cache-and-completed-checkpoint-design-20260710.md`

## 1. 목적

FTCTL scheduler의 현재 transfer sequence와 마지막으로 target durable 상태가
완료된 sequence를 분리한다. Cloud projection은 completed 필드만 사용하고,
Failover는 기존 JSONL latest-completed lock을 유지한다.

기존 RBD/RBD, RBD/qcow2, qcow2/RBD, qcow2/qcow2 FT 보호 성공 경로와 DR data
mover 동작은 변경하지 않는다. 변경 범위는 DR scheduler 상태 기록,
`dr-status --json`, self-test, Agent 전달 계약이다.

## 2. 실환경 문제

현재 `lib/ftctl/dr_scheduler.sh`은 cycle 시작 시 다음 값을 기록한다.

```text
checkpoint_sequence=N
checkpoint_ref=ftctl:<plan>:<run>:N
step=incremental-transfer
progress=40
```

이 시점의 `last_source_checkpoint_at`과 `last_target_durable_at`은 N-1의 완료
값이다. `dr-status --json`은 `checkpoint_sequence=N`만 내보내고 completed
sequence/ref를 내보내지 않는다.

실환경에서 FTCTL completed JSONL 4건과 Cloud READY row 5건이 동시에
관찰됐다. cycle 완료 뒤 같은 row가 보정되더라도 진행 중에는 존재하지 않는
완료 checkpoint가 노출된다.

## 3. 상태 모델

### 3.1 current transfer

```text
current_checkpoint_sequence
current_checkpoint_ref
current_checkpoint_cycle_type
current_checkpoint_state=TRANSFERRING|COMPLETED|FAILED
```

### 3.2 latest completed

```text
latest_completed_checkpoint_sequence
latest_completed_checkpoint_ref
latest_completed_checkpoint_cycle_type
latest_completed_checkpoint_state=TARGET_READY
latest_completed_source_checkpoint_at
latest_completed_target_durable_at
latest_completed_target_ready_rpo_seconds
latest_completed_manifest_path
latest_completed_checkpoint_path
latest_completed_recorded_at
```

`checkpoint_sequence`은 한 release 동안 current sequence alias로 유지한다.
완료 evidence로 사용하면 안 된다.

## 4. `dr_scheduler.sh` 변경 설계

### 4.1 cycle 시작

`ftctl_dr_scheduler_worker()`의 sequence 증가 직후에는 current 필드만
갱신한다.

```bash
ftctl_dr_scheduler_update_state "${state_path}" "${status_path}" \
  "state=SYNCING" \
  "step=${cycle_type}-transfer" \
  "progress=40" \
  "scheduler_state=RUNNING" \
  "current_checkpoint_sequence=${sequence}" \
  "current_checkpoint_cycle_type=${cycle_type}" \
  "current_checkpoint_ref=${checkpoint_ref}" \
  "current_checkpoint_state=TRANSFERRING" \
  "checkpoint_sequence=${sequence}" \
  "updated_at=${now}"
```

`latest_completed_*`, `last_source_checkpoint_at`, `last_target_durable_at`는
변경하지 않는다.

### 4.2 cycle 성공

target write/flush/verify와 JSONL append가 모두 성공한 뒤 completed 필드를
원자적인 state update 호출로 갱신한다.

```bash
ftctl_dr_scheduler_append_restore_point ...

ftctl_dr_scheduler_update_state "${state_path}" "${status_path}" \
  "step=target-checkpoint-ready" \
  "progress=100" \
  "current_checkpoint_state=COMPLETED" \
  "latest_completed_checkpoint_sequence=${sequence}" \
  "latest_completed_checkpoint_cycle_type=${cycle_type}" \
  "latest_completed_checkpoint_ref=${checkpoint_ref}" \
  "latest_completed_checkpoint_state=TARGET_READY" \
  "latest_completed_source_checkpoint_at=${source_at}" \
  "latest_completed_target_durable_at=${target_at}" \
  "latest_completed_target_ready_rpo_seconds=${rpo}" \
  "latest_completed_manifest_path=${manifest_path}" \
  "latest_completed_checkpoint_path=${checkpoint_path}" \
  "latest_completed_recorded_at=${now}" \
  "last_source_checkpoint_at=${source_at}" \
  "last_target_durable_at=${target_at}" \
  "target_ready_rpo_seconds=${rpo}"
```

### 4.3 cycle 실패

실패 cycle은 다음만 변경한다.

```text
current_checkpoint_state=FAILED
state=ERROR
step=replication-cycle-failed
error_code=<mapped code>
```

`latest_completed_*`는 마지막 정상 cycle 값으로 유지한다.

## 5. JSONL 복구 설계

`ftctl_dr_runtime_latest_completed_checkpoint()` helper를 추가한다.

```bash
ftctl_dr_runtime_latest_completed_checkpoint RESTORE_POINTS_PATH
```

동작:

1. JSONL을 뒤에서 앞으로 읽는다.
2. parse 가능한 첫 record를 찾는다.
3. `state=TARGET_READY`, sequence/ref/source/target timestamp가 모두 있는지
   검증한다.
4. 한 줄의 compact JSON을 반환한다.
5. malformed tail은 건너뛴다.

상태 파일에 completed 필드가 없거나 JSONL latest ref와 다르면
`dr-status`는 JSONL 값을 응답에 사용한다. 조회 명령은 상태 파일을
파괴적으로 다시 쓰지 않는다. scheduler reconcile 경로가 별도로 복구 write를
수행할 수 있다.

## 6. `dr_runtime.sh` JSON 응답

`ftctl_dr_runtime_emit_state_json()`에 current/completed local variable과 JSON
field를 추가한다.

```json
{
  "state": "SYNCING",
  "step": "incremental-transfer",
  "current_checkpoint_sequence": 7,
  "current_checkpoint_ref": "ftctl:plan:run:7",
  "current_checkpoint_cycle_type": "incremental",
  "current_checkpoint_state": "TRANSFERRING",
  "latest_completed_checkpoint_sequence": 6,
  "latest_completed_checkpoint_ref": "ftctl:plan:run:6",
  "latest_completed_checkpoint_cycle_type": "incremental",
  "latest_completed_checkpoint_state": "TARGET_READY",
  "latest_completed_source_checkpoint_at": "2026-07-10T08:27:23Z",
  "latest_completed_target_durable_at": "2026-07-10T17:30:20+09:00",
  "latest_completed_target_ready_rpo_seconds": 177
}
```

기존 필드는 호환 alias로 유지한다.

```text
last_source_checkpoint_at = latest_completed_source_checkpoint_at
last_target_durable_at = latest_completed_target_durable_at
target_ready_rpo_seconds = dynamic age from latest completed target time
```

## 7. Agent 전달 계약

Cloud `FtctlDrStatusAnswer`와 KVM wrapper는 모든 current/completed 필드를
typed property로 전달한다. 신규 Agent가 구버전 FTCTL과 조합되어 completed
필드를 얻지 못하면 warning으로 응답하되 current sequence를 completed로
대체하지 않는다.

Agent status hard timeout과 비동기 action acceptance 계약은 변경하지 않는다.
UI/API thread에서 이 status command를 직접 호출하지 않는다.

## 8. Failover 계약

`dr-test-failover`와 `dr-failover`는 계속
`restore-points.jsonl`의 마지막 valid TARGET_READY record를 Plan lock 안에서
선택한다.

Cloud가 expected ref를 보내면 다음을 모두 만족해야 한다.

```text
expected ref == latest completed ref
manifest exists
checkpoint metadata exists
target disk map is valid
target durable timestamp exists
no partial transfer is selected
```

current checkpoint ref는 Failover selector로 사용할 수 없다.

## 9. Self-test

`bin/ablestack_vm_ftctl_selftest.sh`에 다음 test를 추가한다.

```text
test_dr_scheduler_current_does_not_advance_completed
test_dr_scheduler_success_advances_completed_once
test_dr_scheduler_failure_preserves_completed
test_dr_status_current_n_completed_n_minus_one
test_dr_status_recovers_completed_from_jsonl
test_dr_status_skips_malformed_jsonl_tail
test_dr_failover_rejects_current_checkpoint_ref
```

필수 assertion:

```text
transfer 중 current=N, completed=N-1
성공 후 current=N, completed=N
실패 후 current=N failed, completed=N-1
JSONL row 수 == completed sequence 수
```

## 10. 실환경 Preflight

1. 300초 RPO Plan을 생성한다.
2. cycle transfer 중 `dr-status --json`을 조회한다.
3. current sequence가 completed sequence보다 1 큰지 확인한다.
4. Cloud DB READY max sequence는 completed sequence와 같아야 한다.
5. cycle 완료 뒤 FTCTL JSONL, Cloud DB sequence/ref/timestamps가 같아야 한다.
6. 세 cycle 동안 VMware snapshot tree와 RBD snapshot이 누적되지 않아야 한다.
7. 실패 injection 시 completed ref가 마지막 성공 ref로 유지되어야 한다.
8. Test Failover는 latest completed ref를 선택해야 한다.

## 11. AS-IS / TO-BE

| 영역 | AS-IS | TO-BE |
| --- | --- | --- |
| sequence | current sequence 하나만 노출 | current와 latest completed 분리 |
| cycle start | checkpoint sequence를 즉시 교체 | current 필드만 갱신 |
| completion | timestamp만 나중에 보정 | JSONL append 후 completed bundle 갱신 |
| status | current N + durable N-1 혼합 | current N, completed N-1 명시 |
| Cloud fallback | current sequence를 READY로 추론 가능 | completed field 없으면 projection 보류 |
| failed cycle | 현재 오류와 마지막 성공 경계 불명확 | current failed, completed 유지 |
| Failover | ambiguous status ref 가능 | JSONL latest completed lock만 허용 |

## 12. 완료 조건

- current/completed 상태 bundle이 FTCTL status와 JSON에 모두 존재한다.
- Cloud Agent typed answer가 동일 필드를 전달한다.
- 실패/진행 cycle가 Cloud READY checkpoint로 표시되지 않는다.
- 기존 FT/DR 데이터 전송 경로와 lock 경계가 회귀하지 않는다.
- self-test와 세 RPO cycle 실환경 검증을 통과한다.

## 13. 2026-07-20 Plan-Wide Sequence And Scheduler Session Addendum

Current/completed checkpoint 분리는 유지하되 sequence와 Scheduler ownership은
run 경계에 종속되면 안 된다. 실환경에서 pause/resume 및 test cleanup 이후
여러 run PID 파일과 이전 run의 live worker가 동시에 관찰됐다. run-local
sequence는 Cloud authority generation과 충돌했다.

신규 cycle은 Plan 단위 `plan_cycle_sequence`를 사용하고, 지속 Scheduler는
별도 `scheduler_session_uuid`와 Plan singleton lease를 가진다. current와 latest
completed bundle은 해당 session, lease epoch, Plan sequence를 함께 제공한다.
세부 파일 구조, generation, control ACK, reconcile 및 selftest 계약은
`436-ftctl-dr-plan-scheduler-singleton-lease-and-generation-design-20260720.md`를
따른다.

## 14. 2026-07-21 Operation/Protection Envelope Addendum

`current`와 `latest completed` bundle은 상태 조회에 전달된 operation Run에
귀속되지 않는다. Test Cleanup 상태 조회처럼 요청 Run과 producer Run이 다를 수
있으므로 completed cycle은 durable record의 producer UUID를 제공해야 한다.

요청 Run의 상태, Plan 보호 authority, completed cycle을 분리하는 JSON 계약과
호환 alias 규칙은
`437-ftctl-dr-operation-and-protection-status-envelope-design-20260721.md`를 따른다.
