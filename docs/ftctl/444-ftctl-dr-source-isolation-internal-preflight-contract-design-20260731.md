# 444. FTCTL DR Source Isolation Internal Preflight Contract Design

> 2026-08-03 최신 후속 규약:
> [446-ftctl-dr-transition-preflight-v2-and-release-tombstone-contract-design-20260803.md](446-ftctl-dr-transition-preflight-v2-and-release-tombstone-contract-design-20260803.md)
> 는 실제 구현 필드에 맞춘 v2 strict envelope와 종료 코드 0/79, Release
> tombstone을 정의한다. 충돌 시 446을 우선한다.

## 1. 목적

Cross-Hypervisor `FTCTL_DR`에서 독립 `FENCE_CONFIRM` 사용자 작업을 제거하고,
Failback/Reprotect 내부에서 사용할 읽기 전용 transition preflight를 정의한다.

## 2. 역할

- Cloud: authority, VM lifecycle, site credential, 사용자 action
- Agent: Cloud command와 typed FTCTL JSON 전달
- FTCTL: authority journal, scheduler, lock, reverse locator/data path 검증

FTCTL은 preflight에서 VM power, production fence, profile, state를 변경하지
않는다.

## 3. 명령

```bash
ftctl dr-transition-preflight \
  --plan <uuid> \
  --operation failback|reprotect \
  --expected-authority target \
  --authority-generation <n> \
  --json
```

응답:

```json
{
  "command": "dr-transition-preflight",
  "schema_version": "2",
  "contract_version": "dr-transition-preflight-v2",
  "status_scope": "TRANSITION_PREFLIGHT",
  "result": "ready",
  "ready": true,
  "plan_uuid": "<uuid>",
  "operation": "failback",
  "expected_authority": "TARGET",
  "active_side": "TARGET",
  "expected_generation": 1494,
  "authority_generation": 1494,
  "target_power_state": "POWERED_ON",
  "source_fence_state": "ACKNOWLEDGED",
  "source_power_state": "POWERED_OFF",
  "scheduler_state": "STOPPED",
  "active_operation": "",
  "reverse_write_path_state": "READY",
  "split_brain_guard_state": "SAFE",
  "error_code": "",
  "message": "transition preflight ready",
  "checked_at_epoch_ms": 1785466800000,
  "retryable": false,
  "exit_code": 0
}
```

종료 코드:

| 코드 | 의미 |
| --- | --- |
| 0 | ready |
| 79 | typed preflight rejection; 세부 원인은 `error_code`/`retryable` 참조 |
| 2 | invalid request/profile/JSON 생성 실패 |
| 124/137 | timeout/forced termination |

세분화된 원인은 process exit code가 아니라 strict JSON의 `error_code`로
전달한다. 상세 v2 필드와 Release tombstone은 문서 446을 따른다.

## 4. 구현 계약

권장 함수:

```python
def preflight_dr_transition(
    plan_id: str,
    operation: str,
    expected_authority: str,
    expected_generation: int,
) -> TransitionPreflightResult:
    ...
```

검증 순서:

1. profile/schema validation
2. authority journal read
3. side/generation compare
4. active lock/operation read
5. scheduler compatibility
6. reverse locator parse
7. read-only reverse endpoint probe
8. split-brain guard evaluation

Failback은 TARGET authority, forward scheduler 정지, reverse path ready를
요구한다. Reprotect는 TARGET service authority와 SOURCE production isolation을
유지한 채 reverse scheduler를 구성할 수 있어야 한다.

FTCTL_DR profile에서 direct fence clear가 요청되면 다음을 반환한다.

```json
{
  "result": "unsupported",
  "reason_code": "DR_FENCE_CLEAR_INTERNAL_ONLY",
  "retryable": false
}
```

## 5. 무변경 검증

preflight 전후 다음 값은 같아야 한다.

- profile/state checksum
- authority generation
- scheduler desired state
- VM power state
- active lock owner

temporary handle은 `finally`에서 해제하고 persistent NBD/RBD mapping을 만들지
않는다.

## 6. 테스트

1. valid Failback/Reprotect
2. authority side/generation mismatch
3. active operation conflict
4. invalid/unreachable reverse locator
5. split-brain guard unsafe
6. preflight 전후 checksum 불변
7. direct FTCTL_DR fence clear rejection
8. typed JSON/exit-code round trip

## 7. AS-IS / TO-BE

| 구분 | AS-IS | TO-BE |
| --- | --- | --- |
| Fence clear | 독립 mutation으로 오해 가능 | FTCTL_DR direct action 거부 |
| 검증 | action 내부에 분산 | 공통 read-only preflight |
| Authority | 실행 중 간접 확인 | side/generation 명시 확인 |
| Reverse path | 실행 후 실패 가능 | 실행 전 read-only probe |
| 오류 | 일반 문자열 | typed reason + retryable |
