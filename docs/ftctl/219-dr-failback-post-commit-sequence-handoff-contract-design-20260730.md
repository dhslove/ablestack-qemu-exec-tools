# 219. DR Failback Post-Commit Sequence Handoff Contract Design

> 2026-07-31 addendum: SOURCE fence release is not a standalone FTCTL_DR user
> action. Document 444 validates isolation and reverse-path readiness before
> this post-commit sequence.

## 1. 목적

Failback reverse-final checkpoint와 원본 방향으로 재개된 scheduler cycle이 같은
Plan sequence를 사용하는 문제를 제거한다. Cloud 통합 계약은
`583-cross-hypervisor-dr-failback-action-response-and-terminal-convergence-design-20260730.md`
를 따른다.

## 2. 확인된 결함

실환경 Plan `2514a846-64a2-4bc7-ba88-38a874410782`에서:

```text
failback checkpoint sequence=1193
first resumed original-direction cycle sequence=1193
next cycle sequence=1194
RPO interval=300 seconds
```

Cloud의 올바른 완료 조건 `post > failback`을 만족하려면 다음 정규 주기까지
기다려야 했다. 이는 데이터 전송 실패가 아니라 sequence handoff 부재다.

## 3. 불변식

```text
baseline=max(
  failback checkpoint,
  persisted plan_cycle_sequence,
  latest completed checkpoint
)
required=baseline+1
next allocated cycle >= required
```

동일 Plan의 cycle sequence는 방향이 바뀌어도 단조 증가한다.

## 4. 코드 설계

### 4.1 `lib/ftctl/dr_scheduler.sh`

추가 함수:

```bash
ftctl_dr_scheduler_seed_resume_baseline() {
  local plan="$1" baseline="$2" minimum="$3" owner_run="$4"
  # transition lock 보유를 확인한다.
  # sequence 파일과 authority state의 최대값을 계산한다.
  # temp + rename으로 원자 publish한다.
}

ftctl_dr_scheduler_request_immediate_cycle() {
  local plan="$1" owner_run="$2" reason="$3" minimum="$4"
  # control generation에 immediate cycle intent를 기록한다.
  # live worker를 깨우고 같은 generation 재요청은 중복 실행하지 않는다.
}
```

sequence state:

```text
plan_cycle_sequence=N
minimum_next_cycle_sequence=N+1
resume_owner_run=<failback-run>
resume_generation=<control-generation>
immediate_cycle_pending=true
```

worker 할당:

```bash
sequence=$(( max(local_sequence, persisted_sequence, minimum - 1) + 1 ))
```

cycle commit 후 `sequence >= minimum`이면
`immediate_cycle_pending=false`를 원자 반영한다.

### 4.2 `lib/ftctl/dr_runtime.sh`

`ftctl_dr_runtime_failback_commit()`의 scheduler resume 전에 다음 순서를 적용한다.

```text
validate Cloud VM power/boot evidence
validate failback session/checkpoint/generation
seed resume baseline
publish SOURCE authority
resume scheduler
request immediate cycle
publish ACK
```

인자:

```text
--resume-baseline-checkpoint-sequence
--minimum-completed-checkpoint-sequence
--force-immediate-cycle
```

오류:

| 코드 | 의미 | retryable |
| --- | --- | --- |
| `DR_FAILBACK_SEQUENCE_HANDOFF_INVALID` | 숫자 또는 순서 위반 | false |
| `DR_FAILBACK_SEQUENCE_HANDOFF_CONFLICT` | 동일 generation에 다른 session/owner | false |
| `DR_FAILBACK_SEQUENCE_HANDOFF_PERSIST_FAILED` | 원자 저장 실패 | true |
| `DR_POST_FAILBACK_IMMEDIATE_CYCLE_NOT_ACCEPTED` | worker가 즉시 cycle 요청을 수락하지 못함 | true |

### 4.3 status

`PLAN_AUTHORITY`에 다음을 추가한다.

```text
resume_baseline_checkpoint_sequence
minimum_next_cycle_sequence
immediate_cycle_pending
immediate_cycle_owner_run
```

operation status의 ACK 필드와 섞지 않는다.

## 5. idempotency

key:

```text
plan + failback_session + authority_generation
```

- 같은 key와 같은 baseline/minimum은 기존 결과 반환
- 낮은 baseline/minimum은 상태를 후퇴시키지 않음
- 같은 generation의 다른 session/owner는 conflict
- worker 재시작 후에도 persisted minimum을 읽고 다음 cycle을 할당

## 6. Self-test

1. persisted sequence 10, failback 12 -> first cycle 13
2. persisted sequence 15, failback 12 -> first cycle 16
3. 동일 commit 두 번 -> cycle 13 한 번만 생성
4. worker restart -> minimum 유지
5. immediate cycle 완료 -> regular RPO sleep 복귀
6. sequence state write failure -> scheduler 시작 금지
7. `PLAN_AUTHORITY`는 baseline/minimum을 반환
8. operation status와 authority status의 필드 소유권 분리

## 7. Capability

```text
dr-failback-sequence-handoff-v1
dr-post-failback-immediate-cycle-v1
```

두 capability는 함께 제공한다.

## 8. AS-IS / TO-BE

| 항목 | AS-IS | TO-BE |
| --- | --- | --- |
| sequence 인계 | Failback checkpoint를 scheduler counter에 반영하지 않음 | commit 전에 baseline을 원자 seed |
| 첫 재개 cycle | Failback과 같은 sequence 가능 | 항상 baseline보다 큼 |
| 완료 시각 | 다음 RPO timer까지 대기 | immediate validation cycle로 수렴 |
| 재시도 | commit 재호출과 cycle 중복 가능성 | session/generation idempotency |
| status | handoff 진행 상태 없음 | baseline/minimum/pending typed 출력 |

## 9. 완료 기준

```text
failback checkpoint=N
first resumed checkpoint>=N+1
duplicate sequence=0
immediate cycle completes without waiting regular RPO interval
following cycles remain monotonic and CBT_INCREMENTAL
```

## 10. Implementation and verification result

Implemented on `feature/ftctl-cloud-integration`:

- atomically persist the failback baseline and minimum resumed sequence
- reconcile the worker-local counter with the persisted plan sequence
- force one immediate original-direction cycle after failback commit
- expose baseline, minimum sequence, immediate-cycle pending state, and owner run in typed status output
- preserve normal RPO scheduling after the immediate validation cycle

Verification:

| Check | Result |
| --- | --- |
| Bash syntax for changed FTCTL scripts | PASS |
| Failback source-restore self-test | PASS |
| Duplicate or regressed sequence prevention | PASS |
| Status contract fields | PASS |

Deployment acceptance requires the installed host scripts to contain
`resume_baseline_checkpoint_sequence`,
`minimum_completed_checkpoint_sequence`, and
`immediate_cycle_pending`.

## 11. 2026-08-01 Directional Sequence Correction

The Failback checkpoint `N` must represent a committed `KVM_TO_VMWARE`
transaction owned by the Failback Run. A VMware CBT change ID advanced by a
forward-source probe, an old Protection Run cycle, or a zero-byte forward
cycle is not valid Failback evidence.

Only after Cloud commits authority back to SOURCE may sequence `N+1` start in
the original `VMWARE_TO_KVM` direction. Sequence handoff therefore validates
`run_id`, `direction`, `source_generation`, `target_generation`, transferred
bytes, and target durability together. The normative bidirectional contract is
[445-ftctl-dr-bidirectional-incremental-replication-and-reverse-guest-compatibility-design-20260801.md](445-ftctl-dr-bidirectional-incremental-replication-and-reverse-guest-compatibility-design-20260801.md).
