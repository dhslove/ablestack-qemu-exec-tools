# 455. FTCTL DR Forward Cutover Commit Envelope And Idempotent ACK Design

- 작성일: 2026-08-06
- 상태: 상세 설계 완료, 격리 self-test preflight PASS, 구현 대기
- 적용 방향: VMware -> ABLESTACK 실제 Failover
- Cloud 상위 설계:
  `ablestack-cloud/docs/ftctl/599-cross-hypervisor-dr-forward-cutover-commit-contract-and-authority-convergence-design-20260806.md`
- 관련 설계: 438, 442, 453, 454

## 1. 목적

Cloud가 대상 VM을 시작하고 검증한 결과를 FTCTL authority에 확정하는
`dr-cutover-commit`을 versioned typed envelope와 durable journal로 강화한다.

현재 FTCTL 함수는 완전한 인자를 받으면 다음을 정상 수행한다.

- `CUTOVER_READY -> FAILED_OVER`
- `active_side=TARGET`
- 동일 요청 멱등 재호출
- 낮은 authority generation 거부

실패 원인은 Agent가 필수 CLI option을 전달하지 않은 것이다. 따라서 기존
authority 적용 규칙은 유지하되, Cloud-Agent 경계에서 누락을 검출하고 응답
유실을 status 조회로 복구할 수 있도록 계약을 확장한다.

## 2. 검증된 실패

| 항목 | 값 |
| --- | --- |
| Plan | `7889e625-371a-48f9-b553-54e311481170` |
| Failover Run | `e8e6d5fb-f036-40fc-9a66-badffd7c8177` |
| Engine session | `<plan>:<run>` |
| Checkpoint | `43` |
| Cloud authority generation | `43` |
| FTCTL state | `CUTOVER_READY/SOURCE` |
| Cloud target | `i-2-266-VM`, Running |
| VMware source | `vm-6429`, poweredOff |
| 오류 | `DR_CUTOVER_COMMIT_INVALID` |

실제 runtime과 checkpoint는 정상이다. 다음 필수가 CLI에서 비어 FTCTL이
authority 변경 전에 deterministic reject했다.

```text
checkpoint sequence
authority generation
target power state
boot validation state
```

## 3. Preflight 결과

실제 Plan runtime은 수정하지 않았다. WSL ext4 clone의 격리 self-test에서 다음
case를 실행했다.

```text
FTCTL_SELFTEST_CASES=selftest_case_dr_runtime_cloud_cutover_commit_is_idempotent
```

결과: PASS

1. 완전한 V1 인자는 TARGET authority를 적용했다.
2. 동일 인자는 멱등 성공했다.
3. 낮은 generation은 exit `79`와
   `DR_CUTOVER_GENERATION_STALE`을 반환했다.

이 결과는 기존 FTCTL transition을 새로 만들지 않고 typed transport와 durable
ACK를 보강해야 함을 증명한다.

## 4. 역할 경계

| 책임 | Cloud | Agent | FTCTL |
| --- | ---: | ---: | ---: |
| checkpoint 선택 | 조회/결속 | 전달 | 생성/검증 |
| target VM start/boot validation | O | Cloud 명령 중계 | X |
| commit envelope/hash | 생성 | 형식 검증/전달 | 재계산/검증 |
| engine authority 적용 | 요청 | 전달 | O |
| durable commit journal | 조회 | 전달 | O |
| Plan/Replica/Run terminal DB | O | X | X |

FTCTL은 Cloud VM을 시작하거나 정지하지 않는다. `POWERED_ON`과 boot validation은
Cloud 관측값이며 FTCTL은 envelope의 gate로만 검증한다.

## 5. 식별자와 CLI V2

### 5.1 식별자 분리

```text
engine_session_id           <plan UUID>:<run UUID>
cloud_cutover_session_uuid  dr_cutover_session.uuid
commit_attempt_id           Cloud-generated UUID
commit_envelope_sha256      canonical envelope SHA-256
```

`session-id` 하나에 engine session과 Cloud Session UUID를 번갈아 넣는 것을
금지한다.

### 5.2 CLI

```text
dr-cutover-commit
  --contract-version DR_CUTOVER_COMMIT_V2
  --plan <uuid>
  --run <uuid>
  --engine-session-id <plan:run>
  --cloud-session-id <uuid>
  --checkpoint-sequence <n>
  --manifest-sha256 <64 hex>
  --authority-generation <n>
  --commit-attempt-id <uuid>
  --commit-envelope-sha256 <64 hex>
  --target-vm-id <id>
  --target-external-ref <uuid>
  --target-power-state POWERED_ON
  --boot-validation-state POWER_STATE_VALIDATED|GUEST_HEARTBEAT_VALIDATED
  --source-fence-state ACKNOWLEDGED|VERIFIED
  --source-power-state POWERED_OFF|UNREACHABLE
  --json
```

신규 명령:

```text
dr-cutover-commit-status
  --contract-version DR_CUTOVER_COMMIT_V2
  --plan <uuid>
  --run <uuid>
  --engine-session-id <plan:run>
  --commit-attempt-id <uuid>
  --commit-envelope-sha256 <64 hex>
  --json
```

## 6. Canonical Envelope

canonical hash 입력:

```json
{
  "authorityGeneration": 43,
  "bootValidationState": "POWER_STATE_VALIDATED",
  "checkpointSequence": 43,
  "cloudCutoverSessionUuid": "69bbcaf8-d073-43cf-acdb-8216396fbb7d",
  "commitAttemptId": "<uuid>",
  "contractVersion": "DR_CUTOVER_COMMIT_V2",
  "engineSessionId": "<plan>:<run>",
  "manifestSha256": "<64 hex>",
  "planUuid": "7889e625-371a-48f9-b553-54e311481170",
  "runUuid": "e8e6d5fb-f036-40fc-9a66-badffd7c8177",
  "sourceFenceState": "ACKNOWLEDGED",
  "sourcePowerState": "POWERED_OFF",
  "targetExternalRef": "ce028129-98a7-4dba-b05c-7c74ca5df398",
  "targetPowerState": "POWERED_ON",
  "targetVmId": 266
}
```

UTF-8, key 정렬, 공백 없는 JSON을 SHA-256한다. Cloud와 FTCTL은 동일 fixture로
hash를 검증한다.

## 7. Validation

적용 전 다음을 모두 확인한다.

1. contract version이 정확히 `DR_CUTOVER_COMMIT_V2`
2. plan/run/engine session/Cloud Session/attempt가 비어 있지 않음
3. engine session이 현재 failover runtime과 일치
4. checkpoint가 선택된 durable checkpoint 및 guestprep checkpoint와 일치
5. manifest SHA-256이 runtime과 일치
6. generation이 현재 generation보다 작지 않음
7. target VM identity가 materialization identity와 일치
8. target power가 `POWERED_ON`
9. boot validation이 허용 상태
10. source fence가 `ACKNOWLEDGED|VERIFIED`이고 power가 `POWERED_OFF|UNREACHABLE|UNKNOWN`
11. Cloud hash와 FTCTL 재계산 hash가 일치

재해 모드에서는 원본 사이트 전원 관측 자체가 불가능할 수 있으므로 `UNKNOWN`을
독립적인 안전 증거로 취급하지 않는다. 반드시 운영자가 승인한 fence 증거와 함께
제출된 경우에만 허용하며, fence가 확인되지 않은 `UNKNOWN`은 계속 차단한다.

typed error:

| 오류 | 의미 | retryable |
| --- | --- | ---: |
| `DR_CUTOVER_COMMIT_CONTRACT_UNSUPPORTED` | version 불일치 | false |
| `DR_CUTOVER_COMMIT_INVALID` | 필수값 누락/형식 오류 | false |
| `DR_CUTOVER_SESSION_MISMATCH` | engine session 불일치 | false |
| `DR_CUTOVER_CLOUD_SESSION_MISMATCH` | Cloud Session 충돌 | false |
| `DR_CUTOVER_CHECKPOINT_MISMATCH` | checkpoint 불일치 | false |
| `DR_CUTOVER_MANIFEST_MISMATCH` | manifest 불일치 | false |
| `DR_CUTOVER_GENERATION_STALE` | generation 역행 | false |
| `DR_CUTOVER_TARGET_IDENTITY_MISMATCH` | VM identity 불일치 | false |
| `DR_CUTOVER_POWER_STATE_INVALID` | lifecycle 관측값 불일치 | false |
| `DR_CUTOVER_COMMIT_HASH_MISMATCH` | canonical hash 불일치 | false |
| `DR_CUTOVER_COMMIT_CONFLICT` | 같은 attempt의 다른 envelope | false |
| `DR_CUTOVER_COMMIT_IO_ERROR` | journal 쓰기 실패 | true |

## 8. Durable Journal

경로:

```text
<plan>/cutover-commits/<run>.json
```

schema:

```json
{
  "schemaVersion": 2,
  "contractVersion": "DR_CUTOVER_COMMIT_V2",
  "planUuid": "...",
  "runUuid": "...",
  "engineSessionId": "...",
  "cloudCutoverSessionUuid": "...",
  "commitAttemptId": "...",
  "commitEnvelopeSha256": "...",
  "checkpointSequence": 43,
  "authorityGeneration": 43,
  "commitState": "PREPARED",
  "preparedAt": "...",
  "authorityAppliedAt": null,
  "acknowledgedAt": null
}
```

쓰기 순서:

```text
validate
-> journal PREPARED atomic write
-> authority state TARGET atomic apply
-> journal AUTHORITY_APPLIED atomic write
-> authority/session/status verify
-> journal ACKNOWLEDGED atomic write
-> response
```

각 write는 같은 filesystem의 temp file, fsync, rename, parent directory fsync를
사용한다.

## 9. Idempotency와 Status

| journal 상태 | 동일 envelope 재호출/조회 |
| --- | --- |
| 없음 | `NOT_SUBMITTED` |
| `PREPARED` | authority 적용 재개 |
| `AUTHORITY_APPLIED` | 현재 authority 검증 후 ACK 승격 |
| `ACKNOWLEDGED` | 같은 ACK 재반환 |
| `REJECTED` | 원래 typed 오류 재반환 |

같은 `commitAttemptId`에서 hash가 다르면 기존 journal을 덮지 않고 conflict를
반환한다. ACK 이후에는 event, failover session, authority history를 중복 생성하지
않는다.

status response 예:

```json
{
  "command": "dr-cutover-commit-status",
  "result": "ok",
  "commit_outcome": "ACKNOWLEDGED",
  "commit_state": "ACKNOWLEDGED",
  "active_side": "TARGET",
  "authority_generation": 43,
  "checkpoint_sequence": 43,
  "retryable": false
}
```

## 10. Runtime 변경

`lib/ftctl/dr_runtime.sh`:

- 기존 `ftctl_dr_runtime_cutover_commit()`을 V2 envelope validator 뒤에서
  호출하도록 분리한다.
- `ftctl_dr_runtime_cutover_commit_status()`를 추가한다.
- `cloud_cutover_session_id`에는 Cloud Session UUID만 기록한다.
- `failover_session_id`에는 engine session만 유지한다.
- status에 다음을 추가한다.

```text
cutover_commit_contract_version
cutover_commit_attempt_id
cutover_commit_envelope_sha256
cutover_commit_dispatch_state
cutover_commit_checkpoint_sequence
cutover_commit_authority_generation
```

authority 적용 후 terminal tuple:

```text
state=FAILED_OVER
active_side=TARGET
target_power_state=POWERED_ON
target_promotion_state=PROMOTED
engine_ack_state=ACKNOWLEDGED
scheduler_state=STOPPED
scheduler_desired_state=STOPPED
scheduler_health=SUPPRESSED
scheduler_recovery_state=SUPPRESSED
replication_activity=STOPPED
protection_state=FAILED_OVER_UNPROTECTED
```

checkpoint, manifest, baseline, restore point, source isolation evidence는 보존한다.

## 11. CLI와 Capability

`bin/ablestack_vm_ftctl.sh`:

- V2 option parser 추가
- `dr-cutover-commit-status` dispatch 추가
- V1 positional 변수와 V2 변수를 섞지 않음

`dr-capabilities`:

```text
cloud-cutover-commit-v2
cloud-cutover-commit-journal-v2
cloud-cutover-commit-status-v1
```

신규 Cloud는 세 capability가 모두 있는 coordinator에서만 target power-on을
허용한다.

## 12. Self-test

```text
selftest_case_dr_cutover_commit_v2_rejects_missing_fields
selftest_case_dr_cutover_commit_v2_rejects_hash_mismatch
selftest_case_dr_cutover_commit_v2_separates_engine_and_cloud_session
selftest_case_dr_cutover_commit_v2_writes_journal_before_authority
selftest_case_dr_cutover_commit_v2_replays_same_envelope
selftest_case_dr_cutover_commit_v2_rejects_attempt_conflict
selftest_case_dr_cutover_commit_v2_recovers_prepared_journal
selftest_case_dr_cutover_commit_status_reports_not_submitted
selftest_case_dr_cutover_commit_status_recovers_authority_applied
selftest_case_dr_cutover_commit_preserves_durable_checkpoint
```

fixture는 checkpoint와 authority generation이 다른 정상값을 포함한다. 기존 V1
idempotency self-test는 compatibility regression으로 유지한다.

## 13. 현재 Run 복구

구현·배포 후 Cloud가 다음 tuple을 다시 검증해 V2 envelope를 만든다.

```text
plan=7889e625-371a-48f9-b553-54e311481170
run=e8e6d5fb-f036-40fc-9a66-badffd7c8177
engine_session=<plan>:<run>
cloud_session=69bbcaf8-d073-43cf-acdb-8216396fbb7d
checkpoint=43
authority_generation=43
target_vm_id=266
target_power_state=POWERED_ON
boot_validation_state=POWER_STATE_VALIDATED
```

FTCTL status가 여전히 `CUTOVER_READY/SOURCE`이고 모든 identity가 일치할 때만
commit을 실행한다. 전체 Failover worker, data transfer, VM lifecycle은 다시
실행하지 않는다.

## 14. AS-IS / TO-BE

| 영역 | AS-IS | TO-BE |
| --- | --- | --- |
| 입력 | 일부 session/checkpoint/generation option | versioned complete envelope |
| session 의미 | Cloud와 engine ID 혼용 가능 | 두 ID 명시 분리 |
| 무결성 | 개별 필드 비교 | canonical envelope SHA-256 |
| durability | authority state 중심 | write-ahead commit journal |
| 응답 유실 | Cloud Run 고착 | status 조회와 exact replay |
| 재시도 | 전체 Failover 재실행 위험 | commit-only 멱등 재개 |
| capability | command 존재 여부 중심 | V2/journal/status 묶음 gate |
| VM lifecycle | FTCTL이 관측값만 받음 | 동일, Cloud 소유권 유지 |

## 15. 완료 기준

- 완전한 V2 envelope만 authority를 변경한다.
- 같은 attempt/hash는 항상 같은 결과를 반환한다.
- journal이 authority 변경보다 먼저 durable하다.
- FTCTL과 Cloud Session identity가 혼용되지 않는다.
- ACK 유실 후 status만으로 수렴한다.
- 기존 V1 성공 동작을 회귀시키지 않는다.
- 현재 실패 Run을 data transfer 없이 TARGET authority로 복구할 수 있다.

## 16. Cloud-verified planned source-isolation promotion (2026-08-21)

Planned VMware Failover begins with provisional FTCTL evidence because FTCTL
does not own vCenter VM lifecycle:

```text
source_fence_state=REQUESTED
source_power_state=UNKNOWN
```

Cloud owns the source power action. After vCenter confirms that the source VM
is off, the V2 commit envelope supplies:

```text
source_fence_state=VERIFIED
source_power_state=POWERED_OFF
```

FTCTL accepts only this monotonic evidence promotion. `REQUESTED|UNKNOWN` may
become `ACKNOWLEDGED|VERIFIED`, and power `UNKNOWN` may become
`POWERED_OFF|UNREACHABLE`. An authoritative value changing to a conflicting or
weaker value is still rejected with `DR_CUTOVER_POWER_STATE_INVALID`.

The barrier order is source isolation, Cloud target promotion, durable FTCTL
commit acknowledgement, then authority projection. A failed commit never
changes active authority to TARGET. Existing VMware transfer, CBT, RBD write,
guest preparation, and target materialization logic is unchanged.

| Area | AS-IS | TO-BE |
|---|---|---|
| Provisional evidence | Exact equality rejects Cloud's stronger verified evidence | Safe monotonic promotion is accepted |
| Conflicting evidence | Rejected | Still rejected |
| Authority | Could be projected before ACK by Cloud | Changes only after durable commit ACK |
| Regression | ACKNOWLEDGED/UNKNOWN fixture only | REQUESTED/UNKNOWN to VERIFIED/POWERED_OFF fixture and replay |
