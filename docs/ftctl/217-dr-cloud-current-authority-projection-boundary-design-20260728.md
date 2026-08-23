# 217. DR Cloud Current Authority Projection Boundary Design

> 2026-07-28 후속 규약:
> `218-dr-test-guest-identity-and-terminal-cleanup-contract-design-20260728.md`
> 는 FTCTL의 현재 data-plane authority를 변경하지 않으면서, 실패한 테스트
> 작업의 artifact/lease/worker terminal proof를 Cloud에 제공한다.

- 작성일: 2026-07-28
- 상태: 상세 설계 완료, FTCTL source 변경 없음
- Cloud 상위 설계:
  `ablestack-cloud/docs/ftctl/578-cross-hypervisor-dr-current-authority-and-ui-eligibility-projection-design-20260728.md`
- 관련 FTCTL 설계:
  - `216-dr-failback-late-ack-and-authority-snapshot-convergence-design-20260727.md`
  - `442-ftctl-dr-failover-authority-cycle-evidence-and-abort-contract-design-20260727.md`

## 1. 목적

Failover와 Failback 실행이 성공한 뒤 Cloud가 과거 cutover session을 현재
권한으로 표시하는 문제의 FTCTL 경계를 명확히 한다.

이번 문제는 FTCTL data-plane 실패가 아니다. 직전 실환경 검증에서 다음이
확인됐다.

```text
FTCTL active_side=SOURCE
scheduler=RUNNING
control_generation=27
control_ack_generation=27
post-failback checkpoint=585
checkpoint 585 mode=CBT_INCREMENTAL
NBD=DRAINED/0
```

Cloud Plan과 실제 VM도 SOURCE 권한으로 수렴했지만 Cloud가 과거
`dr_cutover_session`의 `PROMOTED` 값을 현재 화면에 투영했다.

## 2. FTCTL 소유 범위

FTCTL이 소유하는 현재 권한 증거:

```text
active_side
engine_ack_state
control_generation
control_ack_generation
scheduler_state
scheduler_health
latest_completed_checkpoint_sequence
latest_completed_checkpoint_cycle_type
nbd_teardown_state
nbd_quarantined_device_count
```

FTCTL이 소유하지 않는 데이터:

```text
Cloud dr_cutover_session history
Cloud dr_failback_session history
Cloud action eligibility
Cloud VM lifecycle state
UI current/history section selection
```

## 3. 금지되는 보정

이번 문제를 해결하기 위해 다음 변경을 해서는 안 된다.

1. 과거 Cloud session ID를 FTCTL profile에 저장
2. UI 표시를 위해 새 FTCTL action 추가
3. historical Run state를 Plan `status.state`에 덮어쓰기
4. Cloud DB 값을 FTCTL이 직접 수정
5. Cloud action eligibility를 FTCTL이 계산

FTCTL status는 현재 data-plane authority만 제공한다. Cloud는 이 증거와
Cloud Plan을 결합해 current projection을 만들고 과거 session은 history로
분리해야 한다.

## 4. Cloud가 적용할 검증 규칙

Cloud는 다음 조합을 canonical current authority로 사용한다.

```text
Plan.active_side=SOURCE
FTCTL.active_side=SOURCE
scheduler in {RUNNING, ACTIVE}
engine_ack_state=ACKNOWLEDGED
latest checkpoint > failback checkpoint
source VM=POWERED_ON
target VM=POWERED_OFF
```

위 조건이 성립하면 과거 Failover의 `PROMOTED` session은 current authority가
아니다.

`Plan.active_side=TARGET`일 때만 Cloud의 acknowledged cutover session과
FTCTL target authority를 함께 검증한다.

## 5. Agent 경계

Agent는 기존 typed status DTO를 유지한다.

- operation scope는 해당 action의 진행/결과만 반환한다.
- plan authority scope는 현재 scheduler/authority/checkpoint를 반환한다.
- Agent는 Cloud cutover history를 조회하지 않는다.
- DTO의 현재 필드가 유지되는 한 Agent JAR 또는 FTCTL RPM 재빌드는 필요 없다.

구현 시 Cloud가 새 Agent field를 요구하지 않는지 changed-file audit로
확인한다. DTO 변경이 생기는 경우에만 Agent와 FTCTL 호환성 검증을 다시
수행한다.

## 6. Preflight와 회귀 테스트

Cloud 변경 전후 FTCTL read-only 확인:

```text
dr-status --scope plan-authority
active_side == SOURCE
scheduler_state == RUNNING
control_ack_generation >= control_generation
latest_completed_checkpoint_sequence >= 585
nbd_teardown_state == DRAINED
nbd_quarantined_device_count == 0
```

Cloud projection 변경 후에도 위 값과 FTCTL state file은 변경되지 않아야 한다.

회귀 항목:

1. Sync가 새 incremental checkpoint를 계속 생성
2. Test Failover와 Failover eligibility가 Cloud에서 정상 계산
3. 새 Failover 때만 target authority가 생성
4. Failback 완료 뒤 FTCTL SOURCE authority 유지
5. Cloud cache rebuild가 FTCTL operation state를 변조하지 않음

## 7. AS-IS / TO-BE

| 구분 | AS-IS | TO-BE |
| --- | --- | --- |
| FTCTL | SOURCE 권한과 checkpoint를 정상 제공 | 계약 유지 |
| Agent | typed status를 정상 중계 | 계약 유지 |
| Cloud | 과거 PROMOTED session을 current로 해석 | Plan/FTCTL current authority 우선 |
| UI | 과거 cutover를 현재 권한처럼 표시 | history와 current 분리 |
| 배포 | 문제를 FTCTL RPM으로 오인할 위험 | Cloud changed-module/UI 중심 배포 |

## 8. 완료 기준

1. FTCTL source와 installed package의 authority 증거가 변경되지 않는다.
2. Cloud만 변경해 current/historical projection 불일치가 해소된다.
3. Agent/FTCTL 신규 command 없이 UI action이 최신 eligibility를 반영한다.
4. 후속 incremental checkpoint 생성에 회귀가 없다.

## 9. 구현 및 배포 확인

이번 변경은 Cloud current-authority projection과 UI eligibility 교정이므로 Agent와 FTCTL source/RPM은 변경하지 않았다.

| 항목 | 확인 결과 |
| --- | --- |
| Agent typed status contract | 변경 없음 |
| FTCTL command/status contract | 변경 없음 |
| FTCTL RPM 재빌드/재배포 | 불필요 |
| 10.10.32.1/2/3 FTCTL timer | active |
| 10.10.32.1/2/3 설치 script | 존재 및 `dr-sync-start` 경로 확인 |
| Plan scheduler | RUNNING/HEALTHY |
| 최신 cycle | incremental, COMPLETED |
| Cloud authority projection | SOURCE/READY/CONSISTENT |

Cloud API, Protection View version 4, DB current cutover 조회가 같은 결과를 반환하므로 역할 경계 검증은 PASS다. 후속 E2E에서는 FTCTL이 제공하는 권한 증거를 변경하지 않고 Cloud의 current session 생성/종결만 확인한다.

## 2026-07-30 TARGET Terminal Authority Addendum

실제 Failover 후 FTCTL은 Cloud 권한을 추론하지 않지만, 자신의 scheduler
terminal state를 완전하게 제공해야 한다. `FAILED_OVER/TARGET`에서는 desired
state가 반드시 `STOPPED`이고 health/recovery는 `SUPPRESSED`다. 상세 계약은
[218-dr-post-failover-scheduler-terminal-authority-contract-design-20260730.md](218-dr-post-failover-scheduler-terminal-authority-contract-design-20260730.md)를
따른다.
## 10. 2026-07-30 Failback Sequence Handoff Boundary

Cloud current-authority correction 자체는 FTCTL action을 요구하지 않았지만,
Failback post-commit 수렴에는 별도 sequence handoff 계약이 필요하다. FTCTL은
Cloud UI/history를 소유하지 않으며, Failback checkpoint baseline, 최소 다음
sequence, immediate cycle intent만 소유한다. Agent/Cloud가 전달하는 typed
baseline 계약과 엔진 구현은 문서 219를 따른다.
