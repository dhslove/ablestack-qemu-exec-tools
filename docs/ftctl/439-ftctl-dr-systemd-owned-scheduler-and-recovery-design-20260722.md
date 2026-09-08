# FTCTL DR Systemd-Owned Scheduler And Recovery Design

- 문서 번호: 439
- 작성일: 2026-07-22
- 상태: 실환경 Preflight 검증 완료, 구현 전 상세 설계
- 범위: FTCTL CLI, DR runtime, DR scheduler, systemd package, Mold Agent contract
- Cloud 상위 설계:
  - `ablestack-cloud/docs/ftctl/568-cross-hypervisor-dr-scheduler-service-and-automatic-recovery-design-20260722.md`
  - `ablestack-cloud/docs/ftctl/569-cross-hypervisor-dr-nbd-deterministic-drain-and-cycle-observability-design-20260723.md`
- 선행 설계:
  - [436-ftctl-dr-plan-scheduler-singleton-lease-and-generation-design-20260720.md](436-ftctl-dr-plan-scheduler-singleton-lease-and-generation-design-20260720.md)
  - [437-ftctl-dr-operation-and-protection-status-envelope-design-20260721.md](437-ftctl-dr-operation-and-protection-status-envelope-design-20260721.md)
  - [461-ftctl-dr-source-site-outage-incremental-recovery-design-20260821.md](461-ftctl-dr-source-site-outage-incremental-recovery-design-20260821.md)

> 2026-08-21 보강: 원본 사이트 단절은 systemd terminal 재시작 오류가 아니라
> `WAITING_SOURCE` retryable 상태로 유지한다. 상세 계약과 구현 검증은 문서 461을 따른다.

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

## 14. 구현 및 배포 결과 (2026-07-22)

### 14.1 구현 결과

- `ablestack-vm-ftctl-dr@.service`가 Plan별 Scheduler의 유일한 장기 프로세스 소유자가 되도록 구현했다.
- `dr-scheduler-run`, `dr-sync-recover`, `dr-reconcile` 명령과 regular reconcile 연동을 구현했다.
- SOURCE/RUNNING Plan만 복구하고 TARGET, FAILED_OVER, PAUSED 및 transition 중인 Plan은 억제한다.
- 복구 시 기존 committed baseline을 보존하며, 복구 상태와 systemd unit/cgroup 정보를 `dr-status`에 제공한다.
- 영향 selftest인 `selftest_case_dr_scheduler_systemd_launch_contract`와
  `selftest_case_dr_scheduler_resume_recovers_missing_worker`가 통과했다.

### 14.2 실제 환경 preflight에서 발견한 결함과 교정

최초 unit은 인스턴스 문자열에 `%I`를 사용했다. systemd가 UUID의 하이픈을 경로 구분자로
unescape하여 FTCTL에 `c952cae5/11db/...` 형태를 전달했고, Plan 조회가 `not_found`와 재시작
루프에 빠졌다. unit 인자를 raw 인스턴스인 `%i`로 교정하고, 설치 unit에 `%I`가 존재하지
않는 회귀 검사를 추가했다.

### 14.3 빌드 및 배포 증적

- 소스 커밋: `a8a2029ee0b7c23e78216174810bfe127f4d16ce`
- GitHub Actions: `29916365845` (`build-ftctl-rpm`, 성공)
- RPM: `ablestack_vm_ftctl-0.9.1-1.noarch.rpm`
- RPM SHA256: `328df7e4956488ec01ca831bfa0118724e0bad463eba7c284594ffa1f5468d22`
- 배포 호스트: `10.10.32.1`, `10.10.32.2`, `10.10.32.3`
- 세 호스트 모두 `ablestack-vm-ftctl.timer=active`, 설치 unit은 `%i`만 사용한다.

### 14.4 런타임 검증 결과

| Plan | 권한/상태 | systemd 상태 | 복구 결과 | 판정 |
|---|---|---|---|---|
| Rocky `c952cae5-...` | SOURCE / READY | active/running, 전용 cgroup | `SUCCEEDED/LOCAL_RECONCILE` | PASS |
| Windows `2514a846-...` | TARGET / FAILED_OVER | unit 없음 | `SUPPRESSED` | PASS |
| Ubuntu `daf0ab48-...` | SOURCE / READY | active/running, 전용 cgroup | `SUCCEEDED/LOCAL_RECONCILE` | PASS |

Rocky와 Ubuntu는 복구 후 fresh heartbeat와 새 incremental durable cycle을 만들었다. Ubuntu
Cycle 34는 `CBT_INCREMENTAL`, `BASELINE_VALID`, changed/transfer bytes `5,963,776`으로
기록되어 baseline 보존형 복구임을 확인했다. Scheduler cgroup은 `mold-agent.service`가
아닌 `ablestack-vm-ftctl-dr@<plan>.service`이다.

## 15. NBD Quarantine Recovery Addendum (2026-07-23)

The Scheduler recovery contract is extended by:

```text
440-ftctl-dr-vmware-nbd-deterministic-drain-and-observability-design-20260723.md
```

Local reconcile must not classify `NBD_TEARDOWN_FAILED` or
`nbdTeardownState=QUARANTINED` as an ordinary missing worker. It must first run
cleanup-only NBD drain. A new sync worker may start only after all quarantined
devices reach stable-free `DRAINED`.

Cleanup-only recovery preserves the previous committed CBT baseline and does
not create a VMware snapshot, query CBT, write target data, or increment the
cycle sequence. If cleanup still fails, the Plan remains recovery-required and
the Scheduler must not automatically start another copy cycle.

## 16. Failback Commit Generation Addendum (2026-07-27)

Failback commit 중 scheduler를 새로 시작할 때 systemd worker는 자체
`scheduler-start` generation으로 Cloud 요청 generation을 덮어쓰지 않는다.
transition control path가 생성한 pending generation을 launch state로 전달하고,
worker가 같은 generation을 채택해 `RUNNING` ACK를 기록한다.

Failback rollback은 일반 scheduler recovery보다 우선한다. rollback prepare가
`STOPPED/IDLE` ACK를 확보하기 전에는 TARGET VM lifecycle 복구나 자동 scheduler
recovery를 실행하지 않는다. 상세 control protocol, commit journal, 2단계 abort
계약은 문서 215를 따른다.

## 17. 패키지 교체 후 Failback 권한 수렴 보강 (2026-08-22)

### 17.1 오류 원인

RPM 교체 과정에서 Plan별 scheduler unit이 안전하게 정지되었지만, 일부 Plan의
`status.state`는 이전 Failover Run이 기록한 `TARGET/FAILED_OVER` 권한을 계속
보유했다. 이후 Failback session과 commit journal은 `SOURCE/COMPLETED`로 정상
종결되었음에도 `dr-sync-recover`가 단일 status 파일만 판정해
`DR_RECOVERY_SUPPRESSED_TARGET`으로 복구를 거부했다.

### 17.2 권한 판정 계약

Scheduler recovery 전에 다음 조건을 모두 만족하는 Failback만 현재 SOURCE 권한으로
수렴한다.

1. `failbacks/active.json`이 `COMPLETED`, `SOURCE`, `ACKNOWLEDGED`이다.
2. source/target 전원 상태가 각각 `POWERED_ON`/`POWERED_OFF`이다.
3. 같은 Run의 commit journal이 `COMPLETED/ACKNOWLEDGED`이고 Plan, Run, authority
   generation, checkpoint가 session과 일치한다.
4. post-Failback checkpoint가 commit checkpoint 이상이다.
5. 더 높은 generation 또는 더 늦은 완료 시각의 TARGET Failover 권한이 없다.

조건이 성립하면 stale status와 recovery Run을 `SOURCE/READY`, target
`POWERED_OFF/STANDBY`로 원자 수렴한 뒤 기존 systemd scheduler recovery를 수행한다.
조건이 하나라도 어긋나거나 최신 권한이 TARGET이면 기존
`DR_RECOVERY_SUPPRESSED_TARGET` 차단을 유지한다.

### 17.3 AS-IS / TO-BE

| 항목 | AS-IS | TO-BE |
|---|---|---|
| 복구 권한 원천 | 단일 `status.state` | 완료 Failback session + commit journal + 최신 Failover 비교 |
| RPM 교체 후 stale TARGET | 복구 영구 차단 | 검증된 SOURCE 권한으로 수렴 후 복구 |
| 실제 TARGET 운영 | 상태 파일 기준 차단 | 더 최신 TARGET 권한을 확인해 동일하게 차단 |
| 회귀 검증 | TARGET 차단만 검증 | stale TARGET 복구와 newer TARGET 차단을 함께 검증 |

### 17.4 운영 재테스트 규칙

상태 변경은 Cloud UI의 `복제 서비스 복구`로만 시작한다. API, DB, host CLI와
FTCTL 직접 명령은 상태 변경에 사용하지 않으며, 조회와 증거 수집에만 사용한다.
PASS는 UI Run 성공, systemd scheduler 활성, 다음 durable 증분/무변경 Cycle 완료,
Cloud Plan `READY/SOURCE`가 모두 일치할 때만 선언한다.
