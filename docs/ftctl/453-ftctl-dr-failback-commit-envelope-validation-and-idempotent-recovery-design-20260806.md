# 453. FTCTL DR Failback Commit Envelope Validation And Idempotent Recovery Design

> 2026-08-06 normative follow-up: commit ACK proves authority transition but
> does not prove that forward protection resumed. Document 454 defines the
> shared initial-protection/reprotect target locator and the first durable
> `VMWARE_TO_KVM` checkpoint gate. Allocated or `PREPARING` scheduler sequence
> values cannot satisfy that gate.

## Implementation Result

- `dr-failback-commit` accepts only the complete `DR_FAILBACK_COMMIT_V1` typed envelope.
- FTCTL recomputes the canonical SHA-256 and rejects an identity or envelope mismatch before changing
  authority.
- Journal version 3 is written before authority mutation and records the evidence run, baseline,
  authority generation, attempt ID, envelope hash, and dispatch state.
- Replaying the same envelope is idempotent. Reusing an attempt with a different hash is a conflict.
- `dr-failback-commit-status` distinguishes `NOT_SUBMITTED` from acknowledged, rejected, and unknown
  outcomes and validates the same session/attempt/hash identity tuple.

## 1. 목적

이 문서는 Cloud가 VM lifecycle을 전환한 뒤 호출하는
`dr-failback-commit`을 versioned typed contract로 강화하고, 응답 손실이나
Cloud 재시작이 있어도 동일 commit이 내구성 journal로 수렴하도록 하는 FTCTL
상세 설계이다.

Cloud counterpart는
`597-cross-hypervisor-dr-failback-commit-envelope-and-pre-power-gate-design-20260806.md`이다.

## 2. 확인된 오류

Failback Run `202be3ef-3960-49b7-8634-919678f6a750`에서 reverse data는
generation 16으로 완료되었다. 그러나 Cloud command에 session/checkpoint/authority
필드가 없어서 현재 함수의 필수 검증에서 다음 오류가 발생했다.

```text
DR_FAILBACK_COMMIT_INVALID
session id, checkpoint sequence, and authority generation are required
```

commit journal이 생성되기 전 deterministic reject였으므로 이어진 status 조회는
`DR_FAILBACK_COMMIT_NOT_FOUND`를 반환했다. 이는 전송 완료 여부와 무관한 control
contract 오류이다.

## 3. 역할 경계

| 책임 | Cloud | Agent | FTCTL |
|---|---:|---:|---:|
| active cutover generation 결정 | O | 전달 | 검증 |
| reverse checkpoint/evidence 생성 | 조회 | 전달 | O |
| VM stop/start/guest heartbeat | O | 실행 중계 | X |
| commit envelope 생성/hash | O | 검증/전달 | 재계산/검증 |
| authority state 변경 | 요청 | 전달 | O |
| durable commit journal | 조회 | 전달 | O |
| Plan/Run/DB terminal transaction | O | X | X |

FTCTL은 Cloud VM을 직접 start/stop하지 않는다. FTCTL은 데이터 경로, scheduler,
authority state 및 commit journal만 소유한다.

## 4. CLI Contract V1

`bin/ablestack_vm_ftctl.sh`는 `dr-failback-commit`에 다음 option을 추가한다.

```text
--contract-version DR_FAILBACK_COMMIT_V1
--session-id <id>
--checkpoint-sequence <n>
--authority-generation <n>
--baseline-generation <n>
--evidence-run-uuid <uuid>
--commit-attempt-id <uuid>
--envelope-sha256 <64 hex>
--target-power-state POWERED_OFF
--source-power-state POWERED_ON
--boot-validation-state GUEST_HEARTBEAT_VALIDATED
```

`dr-failback-commit-status`에는 다음을 전달한다.

```text
--session-id <id>
--commit-attempt-id <uuid>
--envelope-sha256 <64 hex>
```

구버전 positional call은 self-test 전용 compatibility wrapper에서만 허용하고,
Cloud action contract V1에서는 option 누락을 허용하지 않는다.

## 5. Runtime 함수 변경

### 5.1 함수 signature

`lib/ftctl/dr_runtime.sh`

```bash
ftctl_dr_runtime_failback_commit \
  "${plan}" "${run}" "${session_id}" \
  "${checkpoint_sequence}" "${authority_generation}" \
  "${baseline_generation}" "${evidence_run_uuid}" \
  "${commit_attempt_id}" "${envelope_sha256}" \
  "${target_power_state}" "${source_power_state}" \
  "${boot_validation_state}" "${json}"
```

### 5.2 Envelope validation

신규 함수:

```bash
ftctl_dr_runtime_validate_failback_commit_envelope()
ftctl_dr_runtime_canonical_failback_commit_envelope_json()
ftctl_dr_runtime_failback_commit_envelope_sha256()
```

검증 조건:

- contract version 정확히 `DR_FAILBACK_COMMIT_V1`
- plan/run/session/attempt가 비어 있지 않음
- checkpoint, baseline, authority가 unsigned integer
- `checkpoint_sequence == baseline_generation`
- evidence Run UUID가 command Run UUID와 같음
- 현재 reverse evidence tuple이 `COMPLETE`이고 generation/Run이 같음
- target/source/boot state가 예상 값과 같음
- Cloud hash와 FTCTL 재계산 hash가 같음

오류는 다음과 같이 구분한다.

| 오류 코드 | 의미 | retryable |
|---|---|---:|
| `DR_FAILBACK_COMMIT_CONTRACT_UNSUPPORTED` | version 불일치 | false |
| `DR_FAILBACK_COMMIT_INVALID` | 필수 필드 누락/형식 오류 | false |
| `DR_FAILBACK_COMMIT_EVIDENCE_MISMATCH` | Run/generation/evidence 불일치 | false |
| `DR_FAILBACK_COMMIT_POWER_STATE_INVALID` | lifecycle 관측값 불일치 | false |
| `DR_FAILBACK_COMMIT_HASH_MISMATCH` | canonical hash 불일치 | false |
| `DR_FAILBACK_COMMIT_CONFLICT` | 같은 attempt의 다른 envelope | false |
| `DR_FAILBACK_COMMIT_IO_ERROR` | journal 쓰기 실패 | true |

## 6. Durable Journal V3

기존 `ftctl_dr_runtime_failback_commit_state_path()` 경로를 유지하고 schema를 v3로
확장한다.

```text
schema_version=3
contract_version=DR_FAILBACK_COMMIT_V1
plan_uuid=<plan>
run_uuid=<run>
session_id=<session>
commit_attempt_id=<attempt>
envelope_sha256=<hash>
checkpoint_sequence=16
baseline_generation=16
authority_generation=10
evidence_run_uuid=<run>
target_power_state=POWERED_OFF
source_power_state=POWERED_ON
boot_validation_state=GUEST_HEARTBEAT_VALIDATED
commit_state=PREPARED|AUTHORITY_APPLIED|ACKNOWLEDGED|REJECTED
prepared_at=<epoch>
authority_applied_at=<epoch>
acknowledged_at=<epoch>
```

쓰기 순서:

```text
validate envelope
  -> write PREPARED temp file
  -> fsync(file)
  -> rename(temp, journal)
  -> fsync(parent dir)
  -> apply authority/scheduler handoff
  -> update journal AUTHORITY_APPLIED atomically
  -> verify active authority and control ACK
  -> update journal ACKNOWLEDGED atomically
  -> emit response
```

journal write 전에 authority state를 변경하지 않는다.

## 7. Idempotency와 Crash Recovery

### 7.1 동일 요청

`plan/run/session/attempt/hash`가 모두 같고 journal이 존재하면 현재 journal state를
반환한다. `ACKNOWLEDGED`이면 authority 작업을 다시 수행하지 않는다.

### 7.2 충돌 요청

같은 attempt ID에서 hash가 다르거나, 같은 Run에서 session/generation이 다르면
`DR_FAILBACK_COMMIT_CONFLICT`로 거부한다. 기존 journal을 덮지 않는다.

### 7.3 Crash point

| Crash 위치 | 다음 호출 동작 |
|---|---|
| PREPARED 전 | `NOT_SUBMITTED` |
| PREPARED 후 authority 전 | journal 검증 후 authority 적용 재개 |
| authority 적용 후 ACK 전 | 현재 authority 재검증 후 ACK 승격 |
| ACK 후 응답 전 | 동일 ACK 재반환 |

## 8. Commit Status 계약

`ftctl_dr_runtime_failback_commit_status()`는 journal 부재를 다음과 같이 반환한다.

```json
{
  "result": "not-submitted",
  "failback_commit_outcome": "NOT_SUBMITTED",
  "error_code": "DR_FAILBACK_COMMIT_NOT_SUBMITTED",
  "retryable": false
}
```

journal이 있으면 command의 attempt/hash와 비교한다. 다르면 NOT_FOUND가 아니라
`DR_FAILBACK_COMMIT_STATUS_CONFLICT`를 반환한다.

`PREPARED` 또는 `AUTHORITY_APPLIED` journal은
`ftctl_dr_runtime_reconcile_failback_commit()`로 재검증한다. 안전하게 ACK로 수렴할
수 없으면 `UNKNOWN`과 명확한 failed phase를 반환한다.

## 9. Status Projection

Plan-authority `dr-status`에 다음 typed field를 추가한다.

```json
{
  "failback_commit_contract_version": "DR_FAILBACK_COMMIT_V1",
  "failback_commit_attempt_id": "<uuid>",
  "failback_commit_envelope_sha256": "<hash>",
  "failback_commit_dispatch_state": "ACKNOWLEDGED",
  "failback_commit_checkpoint_sequence": 16,
  "failback_commit_authority_generation": 10
}
```

Cloud는 이 값을 authority 상태의 보조 증거로 사용하되 DB lifecycle state를 FTCTL
status가 직접 덮도록 허용하지 않는다.

## 10. 현재 실패 Run 복구 명령

일반 operator CLI에 임의 field를 입력하는 복구 option을 노출하지 않는다. Cloud가
DB와 live evidence를 검증해 완전한 V1 envelope를 만든 뒤 정상
`dr-failback-commit`을 한 번 호출한다.

현재 Run에서 기대되는 tuple은 다음과 같다.

```text
checkpoint_sequence=16
baseline_generation=16
authority_generation=10
target_power_state=POWERED_OFF
source_power_state=POWERED_ON
boot_validation_state=GUEST_HEARTBEAT_VALIDATED
```

복구 전에 FTCTL은 reverse evidence Run UUID와 durability tuple을 다시 확인한다.
data transfer, target writer, source VM lifecycle을 재실행하지 않는다.

## 11. Self-Test 설계

`bin/ablestack_vm_ftctl_selftest.sh`에 다음 case를 추가한다.

```text
selftest_case_dr_failback_commit_v1_rejects_missing_fields
selftest_case_dr_failback_commit_v1_rejects_hash_mismatch
selftest_case_dr_failback_commit_v1_distinguishes_checkpoint_and_authority
selftest_case_dr_failback_commit_v1_writes_journal_before_authority
selftest_case_dr_failback_commit_v1_replays_same_envelope
selftest_case_dr_failback_commit_v1_rejects_attempt_conflict
selftest_case_dr_failback_commit_v1_recovers_prepared_journal
selftest_case_dr_failback_commit_status_reports_not_submitted
selftest_case_dr_failback_commit_status_rejects_hash_conflict
```

fixture는 checkpoint 16, authority 10처럼 두 값이 다른 정상 사례를 반드시 포함한다.
두 값을 우연히 같게 만드는 fixture만 사용하면 현재 결함을 재현하지 못한다.

## 12. Capability와 Rolling Upgrade

`dr-capabilities`에 다음을 추가한다.

```text
dr-failback-commit-envelope-v1
dr-failback-commit-journal-v3
dr-failback-commit-status-v2
```

Cloud preflight는 세 capability가 모두 있을 때만 Failback lifecycle transition을
허용한다. 일부 호스트만 신버전이면 coordinator 배치를 차단한다.

## 13. AS-IS / TO-BE

| 영역 | AS-IS | TO-BE |
|---|---|---|
| CLI | session/checkpoint/authority positional 값 | versioned typed option 전체 |
| Validation | 세 필드 존재 여부 중심 | identity/evidence/power/hash 전체 검증 |
| Journal | Run 기준, commit 후 결과 중심 | attempt/hash 기반 write-ahead journal |
| Missing journal | `NOT_FOUND` | `NOT_SUBMITTED`로 원인 구분 |
| Replay | session/checkpoint 일부 비교 | complete envelope idempotency |
| Conflict | 일부 generation 비교 | attempt/hash conflict 명시 |
| Recovery | status 재조회 또는 전체 재실행 | PREPARED journal 단계별 재개 |
| Cloud boundary | FTCTL이 VM lifecycle 결과를 추정 | Cloud 관측값을 검증만 하고 authority만 담당 |

## 14. 구현 순서와 완료 기준

1. CLI parser 및 canonical hash fixture
2. journal v3와 status v2
3. idempotency/crash self-test
4. Cloud typed command와 함께 GitHub Actions build
5. 세 호스트 동시 배포 및 capability 검증
6. 현재 Run의 forward commit dry-run
7. 실제 commit과 scheduler/checkpoint handoff 검증

완료 조건:

- incomplete command가 authority state를 변경하지 않는다.
- checkpoint 16과 authority 10을 독립적으로 보존한다.
- 동일 envelope 재호출이 같은 ACK를 반환한다.
- status가 미제출과 불명확 결과를 구분한다.
- Cloud/FTCTL hash가 동일하다.
- 현재 Run이 reverse copy 재실행 없이 SOURCE authority로 수렴한다.

## 15. Windows 정상 부팅 권한 전환 게이트 (2026-08-22)

### 15.1 문제

VMware에서 ABLESTACK으로 보호된 Windows 계획은 테스트 부팅 정책이
`POWER_STATE_ONLY`인 경우가 있다. 이 값을 페일백에도 재사용하면 vCenter에서
원본 VM이 `poweredOn`인 사실만으로 source authority를 확정할 수 있다. 또한
역방향 프로필의 `ORIGINAL_VMWARE_COMPATIBILITY_PRESERVED`는 실제 부팅 검증 결과가
아니라 원본 provider lineage에서 합성한 값이므로 성공 증거로 사용할 수 없다.

### 15.2 계약

- 성공한 KVM-to-VMware 전송, CBT 기준선, VDDK writer 경로는 변경하지 않는다.
- 역방향 프로필의 원본 VMware `guestId`가 Windows이면
  `GUEST_HEARTBEAT_VALIDATED`만 authority commit 증거로 허용한다.
- Windows 프로필에 `POWER_STATE_VALIDATED`가 전달되면
  `DR_FAILBACK_WINDOWS_GUEST_HEARTBEAT_REQUIRED`로 거부한다.
- 비 Windows 및 기존 프로필은 현재 power-state 호환 경로를 유지한다.
- VMware 원본 VM을 그대로 복구 대상으로 사용하는 검증된
  `VMWARE -> ABLESTACK -> VMWARE` 경로는 디스크/컨트롤러 계보가 보존되므로
  `guestCompatibility.state=ORIGINAL_VMWARE_COMPATIBILITY_PRESERVED`를 유지한다.
- 그 외 경로만 `VALIDATION_REQUIRED`로 시작한다. 이 호환성 상태는 전송 경로의
  사전 조건이며, 실제 Windows 정상 부팅 증거인 vCenter guest heartbeat와는
  별개의 계약이다.

### 15.3 회귀 게이트

Self-test는 VMware 원본 계보의 호환성 보존, Windows 역방향 프로필 + power-only
commit 거부와 Windows 역방향 프로필 + guest-heartbeat commit 성공을 모두 포함한다. 기존
Failback commit envelope, scheduler resume, post-failback incremental 테스트는
그대로 통과해야 한다.

### 15.4 AS-IS / TO-BE

| 영역 | AS-IS | TO-BE |
| --- | --- | --- |
| Windows commit | 전원 ON만으로 허용 가능 | vCenter guest heartbeat 필수 |
| Compatibility | VMware 원본 계보 보존 | 성공 경로는 보존, 기타 경로만 `VALIDATION_REQUIRED` |
| FTCTL 방어 | guest family와 무관하게 power-only 허용 | Windows 프로필 power-only 거부 |
| 데이터 경로 | 검증된 증분 writer | 변경 없음 |

## 16. Provider-pair별 Windows 부팅 증거 분리 (2026-08-25)

### 16.1 문제

`ABLESTACK -> ABLESTACK` RBD Failback에서 원본 KVM VM이 UEFI로 정상 기동하고
QGA가 응답해도, 공통 Windows 게이트가 경로를 구분하지 않고 vCenter guest heartbeat를
요구했다. 그 결과 데이터 역전송과 Cloud 전원 전환은 완료됐지만
`DR_FAILBACK_WINDOWS_GUEST_HEARTBEAT_REQUIRED`로 commit journal이 생성되지 않았다.

### 16.2 계약

- Windows guest 판정과 부팅 증거 판정은 `providerPair`와 함께 수행한다.
- 역방향 대상이 VMware인 `*_TO_VMWARE` 경로는 기존 성공 계약대로
  `GUEST_HEARTBEAT_VALIDATED`만 허용한다.
- `ABLESTACK_TO_ABLESTACK` 경로는 Cloud/KVM Agent가 확인한
  `POWER_STATE_VALIDATED` 또는 `GUEST_HEARTBEAT_VALIDATED`를 허용한다.
- 알 수 없거나 누락된 provider pair는 보수적으로 기존 Windows vCenter heartbeat
  게이트를 유지한다.
- 전송, RBD URI, checkpoint, scheduler와 VMware writer 로직은 변경하지 않는다.

### 16.3 회귀 게이트

- Windows + `ABLESTACK_TO_ABLESTACK` + power validation은 commit 가능해야 한다.
- Windows + `ABLESTACK_TO_VMWARE` + power validation은 기존 오류 코드로 거부해야 한다.
- Windows + `ABLESTACK_TO_VMWARE` + guest heartbeat는 commit 가능해야 한다.
- 기존 Failback envelope/hash/idempotency 및 scheduler resume 테스트를 모두 통과해야 한다.

### 16.4 AS-IS / TO-BE

| 영역 | AS-IS | TO-BE |
| --- | --- | --- |
| Windows 부팅 게이트 | provider와 무관하게 vCenter heartbeat 요구 | 역방향 대상 provider별 검증 |
| ABLESTACK 대상 | 정상 KVM 부팅도 commit 거부 | power/QGA 계열 검증으로 commit 허용 |
| VMware 대상 | vCenter heartbeat 필수 | 기존 계약 유지 |
| 데이터 경로 | 정상 RBD/VDDK 전송 | 변경 없음 |
