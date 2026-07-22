# FTCTL DR Systemd-Owned Scheduler And Recovery Design

- 문서 번호: 439
- 작성일: 2026-07-22
- 상태: 실환경 Preflight 검증 완료, 구현 전 상세 설계
- 범위: FTCTL CLI, DR runtime, DR scheduler, systemd package, Mold Agent contract
- Cloud 상위 설계:
  - `ablestack-cloud/docs/ftctl/568-cross-hypervisor-dr-scheduler-service-and-automatic-recovery-design-20260722.md`
- 선행 설계:
  - [436-ftctl-dr-plan-scheduler-singleton-lease-and-generation-design-20260720.md](436-ftctl-dr-plan-scheduler-singleton-lease-and-generation-design-20260720.md)
  - [437-ftctl-dr-operation-and-protection-status-envelope-design-20260721.md](437-ftctl-dr-operation-and-protection-status-envelope-design-20260721.md)

## 1. 목적

현재 `ftctl_dr_runtime_start_background_worker()`와
`ftctl_dr_scheduler_start()`는 Mold Agent 요청 처리 중 background subshell과
`nohup`으로 장기 DR Scheduler를 시작한다. 프로세스의 PPID가 1로 변경되어도
systemd cgroup은 `mold-agent.service`에 남으므로 Agent 재시작 시 Scheduler도
종료된다.

본 설계는 다음을 보장한다.

1. 장기 Scheduler의 프로세스 수명은 Mold Agent와 분리한다.
2. Plan별 Scheduler는 systemd template unit 하나가 소유한다.
3. Scheduler 복구는 기존 committed baseline을 보존한다.
4. Cloud authority가 없는 로컬 profile은 자동 실행하지 않는다.
5. failover된 TARGET, PAUSED, 전이 중 Plan은 forward Scheduler를 복구하지 않는다.

## 2. 실환경 Preflight 결과

2026-07-22 DR test cluster에서 확인한 사실은 다음과 같다.

| 항목 | 결과 |
|---|---|
| Agent unit | `mold-agent.service`, `KillMode=control-group` |
| 기존 Scheduler PPID | `1` |
| 기존 Scheduler cgroup | `/system.slice/mold-agent.service` |
| Agent 재시작 결과 | 같은 cgroup의 DR Scheduler 종료 |
| transient unit 검증 | `systemd-run --unit=ftctl-dr-preflight-* --collect /bin/sleep 8` 성공 |
| transient cgroup | `/system.slice/ftctl-dr-preflight-*.service` |
| 종료 후 정리 | unit stopped/collected, 기존 DR runtime 무변경 |

따라서 `nohup`, `setsid`, double fork만으로는 충분하지 않으며 systemd가 직접
main process를 소유해야 한다.

## 3. 파일별 변경 설계

### 3.1 systemd template 추가

신규 파일:

```text
lib/ftctl/systemd/ablestack-vm-ftctl-dr@.service
```

규약:

```ini
[Unit]
Description=ABLESTACK FTCTL DR scheduler for plan %i
After=network-online.target libvirtd.service
Wants=network-online.target
StartLimitIntervalSec=300
StartLimitBurst=3

[Service]
Type=exec
ExecStart=/usr/local/bin/ablestack_vm_ftctl dr-scheduler-run --plan %i --json
Restart=on-failure
RestartSec=5
KillMode=mixed
TimeoutStopSec=90
SuccessExitStatus=0 10

[Install]
WantedBy=multi-user.target
```

- template를 전역 enable하지 않는다.
- Cloud가 전달한
  `/run/ablestack-vm-ftctl/dr-runtime/plans/<plan>/profile.json`이 있을 때만
  `systemctl start ablestack-vm-ftctl-dr@<escaped-plan>.service`를 호출한다.
- Plan UUID는 `systemd-escape --path`가 아니라 instance escaping 규칙으로
  검증 후 전달한다.
- secret은 unit environment 또는 persistent drop-in에 기록하지 않는다.

### 3.2 `lib/ftctl/dr_runtime.sh`

기존 `ftctl_dr_runtime_start_background_worker()`는 호환 wrapper로 남기되 신규
Plan profile에서는 다음 함수를 호출한다.

```bash
ftctl_dr_runtime_unit_name PLAN_UUID
ftctl_dr_runtime_write_launch_state PLAN_UUID PROFILE_JSON
ftctl_dr_runtime_start_systemd PLAN_UUID
ftctl_dr_runtime_stop_systemd PLAN_UUID REASON
ftctl_dr_runtime_query_systemd PLAN_UUID
ftctl_dr_runtime_validate_cloud_fence PLAN_UUID
```

`ftctl_dr_runtime_start_systemd()`의 순서:

1. Plan UUID와 profile schema를 검증한다.
2. Cloud authority fence와 desired state를 검증한다.
3. `scheduler/launch.state.tmp`을 쓰고 `fsync + rename`으로 교체한다.
4. 기존 unit이 active이면 identity를 확인하고 idempotent success를 반환한다.
5. inactive이면 `systemctl start --no-block`을 호출한다.
6. short-lived command는 `START_ACCEPTED`와 unit name을 반환한다.

### 3.3 `lib/ftctl/dr_scheduler.sh`

다음 entry point를 추가한다.

```bash
ftctl_dr_scheduler_run PLAN_UUID
ftctl_dr_scheduler_recover PLAN_UUID FORCE_FULL_RESEED
ftctl_dr_scheduler_reconcile_local
ftctl_dr_scheduler_publish_identity_ack
```

`ftctl_dr_scheduler_run()`은 systemd의 foreground main process다. 내부에서 다시
background fork하지 않는다. 종료 코드는 다음과 같이 제한한다.

| 코드 | 의미 | systemd 처리 |
|---:|---|---|
| 0 | 정상 정지 | 재시작 안 함 |
| 10 | Cloud desired stop | 재시작 안 함 |
| 20 | 일시 lock/lease 충돌 | on-failure 재시작 |
| 30 | profile/fence invalid | 재시작 제한 후 failed |
| 40 | runtime fatal | on-failure 재시작 |

### 3.4 `bin/ablestack_vm_ftctl`

신규 명령:

```text
dr-sync-recover
dr-scheduler-run
dr-reconcile
```

`dr-sync-recover`는 복구 요청을 검증하고 unit start를 접수하는 짧은 명령이다.
실제 복제 완료를 기다리지 않는다. `dr-scheduler-run`은 systemd 전용 내부 명령이며
interactive/operator 호출 시 경고를 남긴다.

## 4. Launch State 계약

경로:

```text
/run/ablestack-vm-ftctl/dr-runtime/plans/<plan-uuid>/scheduler/launch.state
```

필드:

```json
{
  "schemaVersion": 1,
  "planUuid": "...",
  "sessionUuid": "...",
  "producerRunUuid": "...",
  "profilePath": "/run/ablestack-vm-ftctl/dr-runtime/plans/.../profile.json",
  "desiredState": "RUNNING",
  "activeSide": "SOURCE",
  "cloudAuthoritySequence": 42,
  "leaseEpoch": 8,
  "recoveryTrigger": "AGENT_RESTART",
  "forceFullReseed": false,
  "updatedAtEpochMs": 1784716587000
}
```

`launch.state`는 실행 편의를 위한 비영속 상태다. 재부팅 후 profile이 없으면 FTCTL은
Scheduler를 추측 실행하지 않고 Cloud profile 재전달을 기다린다.

## 5. 복구 알고리즘

`ftctl_dr_scheduler_recover()`는 다음 조건을 모두 만족해야 실행한다.

```text
activeSide == SOURCE
protectionEnabled == true
desiredState == RUNNING
transitionLease == absent
checkpointLease == absent
liveOwner == absent or stale
cloudAuthoritySequence == profile.authoritySequence
```

실행 순서:

1. Plan owner lock을 획득한다.
2. 현재 generation과 lease epoch를 다시 읽는다.
3. live owner가 생겼으면 idempotent success로 종료한다.
4. lease epoch를 한 번만 증가시킨다.
5. committed baseline과 CBT cursor를 변경하지 않는다.
6. systemd unit을 시작한다.
7. worker가 새로운 identity ACK를 기록한다.
8. heartbeat를 기록하고 첫 durable Cycle을 수행한다.
9. durable Cycle commit 후에만 Cloud가 READY로 승격할 수 있다.

복제 방식 결정:

| 조건 | 방식 | reason |
|---|---|---|
| committed baseline과 CBT chain 유효 | `CBT_INCREMENTAL` | `RECOVERY_BASELINE_VALID` |
| baseline 없음 | `FULL_RESEED` | `RECOVERY_BASELINE_MISSING` |
| CBT chain 불일치 | `FULL_RESEED` | `RECOVERY_CBT_CHAIN_INVALID` |
| 운영자 강제 | `FULL_RESEED` | `OPERATOR_FORCED_RESEED` |

단순 프로세스 재시작은 Full Reseed 사유가 아니다.

## 6. 로컬 Reconcile 경계

`dr-reconcile`은 다음 경로만 스캔한다.

```text
/run/ablestack-vm-ftctl/dr-runtime/plans/*/profile.json
```

각 profile에 대해 다음 순서로 판정한다.

1. schema와 Plan UUID 일치 여부
2. Cloud authority fence 유효 여부
3. SOURCE/TARGET active side
4. RUNNING/PAUSED/STOPPED desired state
5. 전이 lease와 operation lock
6. systemd unit 상태와 identity ACK

허용 규칙:

- `SOURCE + RUNNING + fence valid + no owner`: start/recover
- `SOURCE + PAUSED`: unit stop 유지
- `TARGET` 또는 `FAILED_OVER`: forward unit stop 유지
- transition 진행 중: 변경 금지
- fence stale/unknown: 변경 금지, 진단 이벤트만 기록

## 7. Status Envelope 확장

`dr-status --json`과 Agent 응답에 다음 필드를 추가한다.

```json
{
  "scheduler": {
    "desiredState": "RUNNING",
    "health": "RECOVERING",
    "serviceUnit": "ablestack-vm-ftctl-dr@....service",
    "unitActiveState": "active",
    "unitSubState": "running",
    "cgroup": "/system.slice/ablestack-vm-ftctl-dr@....service",
    "identityAck": true,
    "leaseEpoch": 8,
    "recoveryTrigger": "AGENT_RESTART"
  }
}
```

`health=READY` 조건은 unit active만으로 충족되지 않는다. 새 identity ACK, heartbeat,
그리고 durable Cycle commit이 모두 필요하다.

## 8. 오류 코드

| 코드 | 의미 | retryable |
|---|---|---|
| `DR_RECOVERY_NOT_REQUIRED` | live owner가 이미 정상 | false |
| `DR_RECOVERY_AUTHORITY_STALE` | Cloud fence 불일치 | true |
| `DR_RECOVERY_SUPPRESSED_TARGET` | TARGET/failed-over | false |
| `DR_RECOVERY_SUPPRESSED_PAUSED` | 의도적 PAUSED | false |
| `DR_RECOVERY_TRANSITION_ACTIVE` | 전이 lease 존재 | true |
| `DR_RECOVERY_UNIT_START_FAILED` | systemd start 실패 | true |
| `DR_RECOVERY_IDENTITY_TIMEOUT` | identity ACK 미수신 | true |
| `DR_RECOVERY_DURABLE_CYCLE_FAILED` | 첫 Cycle commit 실패 | true |

오류 메시지에는 secret, vCenter password, API secret을 포함하지 않는다.

## 9. Capability와 호환성

신규 capability:

```text
dr-scheduler-systemd-unit-v1
dr-sync-recover-v1
dr-local-reconcile-fence-v1
```

Cloud는 세 capability를 모두 확인한 뒤 recovery API와 자동 controller를 활성화한다.
구버전 호스트에서는 기존 status 조회만 허용하고 자동 복구를 시도하지 않는다.

## 10. Selftest와 실환경 수용 테스트

### 10.1 Selftest

1. unit name escaping과 UUID validation
2. atomic `launch.state` write
3. duplicate recover idempotency
4. SOURCE/RUNNING allow
5. TARGET/PAUSED/transition deny
6. valid baseline incremental 유지
7. invalid CBT chain reason-bearing reseed
8. unit active지만 identity mismatch인 경우 READY 금지
9. secret redaction

### 10.2 실환경 테스트

1. Plan READY와 incremental baseline을 확인한다.
2. Scheduler cgroup이 전용 unit인지 확인한다.
3. `systemctl restart mold-agent`를 수행한다.
4. Scheduler가 유지되거나 recovery Run 하나로 복구되는지 확인한다.
5. 복구 Cycle이 `CBT_INCREMENTAL/RECOVERY_BASELINE_VALID`인지 확인한다.
6. transferred bytes가 전체 virtual size보다 작은지 확인한다.
7. TARGET/FAILED_OVER Plan에는 unit이 시작되지 않는지 확인한다.
8. 호스트 재부팅 후 Cloud profile 전달 전에는 시작하지 않는지 확인한다.

## 11. 구현 및 배포 순서

1. systemd template와 FTCTL CLI를 구현한다.
2. qemu GitHub Actions로 RPM을 빌드한다.
3. capability를 비활성 상태로 호스트에 선배포한다.
4. Agent DTO/wrapper를 배포한다.
5. Cloud DB/API/backend controller를 배포한다.
6. Cloud UI를 배포한다.
7. 수동 `recoverDrSync` 수용 테스트를 수행한다.
8. 자동 recovery controller를 활성화한다.
9. Agent rolling restart와 host reboot 시험을 수행한다.

배포 전 active transition과 checkpoint lease를 drain한다. 패키지 설치 또는 Agent
재시작 중 Scheduler가 종료될 수 있는 기존 버전에서는 일괄 재시작하지 않는다.

## 12. AS-IS / TO-BE

| 항목 | AS-IS | TO-BE |
|---|---|---|
| 프로세스 소유 | Mold Agent cgroup | Plan별 systemd unit |
| 장기 실행 | background subshell + `nohup` | foreground `dr-scheduler-run` |
| Agent 재시작 | Scheduler 동반 종료 | Scheduler 수명 독립 |
| 자동 복구 | 문서 규약만 있고 실행 경로 없음 | fenced local reconcile + Cloud controller |
| 복구 API | start/resume 재사용 | 전용 `dr-sync-recover` |
| baseline | 복구 시 reseed 가능 | committed baseline 불변 보존 |
| READY 조건 | process/start 응답 중심 | identity + heartbeat + durable Cycle |
| failover Plan | 일반 dead와 혼동 | TARGET forward recovery 금지 |
| 보안 | persistent 실행 정보 위험 | `/run` profile과 secret 비기록 unit |

## 13. 완료 기준

- Agent 재시작이 Scheduler를 종료하지 않는다.
- Scheduler cgroup에 `mold-agent.service`가 나타나지 않는다.
- 실제 Scheduler 사망 시 recovery 요청은 하나만 생성된다.
- valid baseline 복구가 incremental로 완료된다.
- Full Reseed에는 명시적 reason과 전송량이 기록된다.
- READY는 identity ACK, heartbeat, durable Cycle 이후에만 표시된다.
- TARGET/FAILED_OVER/PAUSED/transition Plan은 자동 복구되지 않는다.
- 기존 RBD/QCOW2 FT/HA와 xcolo 경로에 회귀가 없다.
