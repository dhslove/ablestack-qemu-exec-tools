# FT XCOLO Health Log Classifier 개선 설계

## 배경

Run 133은 COLO role transition까지 도달했지만 `xcolo_primary_storage_unhealthy:qemu_log_io_error`로 실패했다. 실제 원인은 디스크 I/O 장애가 아니라 QEMU 로그에 있던 COLO 채널 메시지였다.

```text
qemu-kvm: Can't receive COLO message: Input/output error
```

기존 storage health는 QEMU 로그 tail 전체에서 `Input/output error` 또는 `I/O error` 문자열을 찾으면 storage failure로 분류했다. 이 방식은 두 문제가 있다.

- COLO channel/protocol 오류와 block storage 오류를 구분하지 못한다.
- 현재 run 이전의 오래된 QEMU 로그가 tail에 포함되어 현재 health 판정을 오염시킬 수 있다.

## 설계 원칙

- Storage health는 storage evidence만 사용한다.
- COLO channel/protocol 로그는 storage failure로 분류하지 않는다.
- QEMU 로그 기반 health 판정은 현재 protection run 범위만 분석한다.
- QMP block API 결과는 로그보다 우선한다.
- hard guest boot failure 판정도 현재 run 로그 범위만 사용한다.

## AS-IS

| 항목 | 현재 동작 | 문제 |
| --- | --- | --- |
| QEMU 로그 범위 | `/var/log/libvirt/qemu/<vm>.log` tail 전체 | 이전 run 또는 cleanup 이후 로그가 섞임 |
| Storage log classifier | `Input/output error`, `I/O error`, `Operation not permitted`를 generic storage failure로 처리 | COLO channel teardown, filter send 오류를 storage 장애로 오분류 |
| COLO channel 로그 | 별도 classifier 없이 storage classifier에 걸릴 수 있음 | 원인 분류가 불명확함 |
| Guest hard failure | 같은 tail 전체 사용 | 이전 부팅 실패 로그가 현재 run에 영향을 줄 수 있음 |

## TO-BE

| 항목 | 변경 동작 | 기대 효과 |
| --- | --- | --- |
| QEMU log baseline | 보호 시작 시점에 log byte offset과 timestamp 기록 | 현재 run 이후 로그만 health 판정에 사용 |
| Storage classifier | QMP block failure 또는 block/rbd 문맥의 오류만 storage failure | COLO channel I/O 메시지 오탐 제거 |
| Protocol classifier | `Can't receive COLO message`, `Received invalid message`, `filter mirror send failed`는 protocol/channel notice로 기록 | storage와 protocol 원인 분리 |
| Guest classifier | 현재 run log window만 분석 | 과거 guest boot failure 로그 오염 방지 |

## Storage Failure 판정 기준

Storage health는 다음 경우에만 fail 처리한다.

- `query-block`, `query-named-block-nodes`, `query-blockstats` QMP 호출 실패
- `query-block` 결과의 `io-status=failed`
- 현재 run QEMU log window 내 명확한 block/rbd 오류
  - `blk_update_request`
  - `Buffer I/O error`
  - `end_request ... I/O error`
  - `rbd ... error/failed/denied/not permitted`
  - `No space left on device`

다음은 storage failure가 아니다.

- `Can't receive COLO message: Input/output error`
- `Received invalid message ...`
- `filter mirror send failed(...)`
- `Operation not permitted` 단독 메시지

## 구현 항목

1. `ftctl_xcolo_capture_primary_qemu_log_baseline` 추가
   - QEMU log path, byte offset, timestamp를 state에 저장한다.
2. `ftctl_xcolo_primary_qemu_log_tail` 변경
   - baseline offset 이후의 로그만 tail로 반환한다.
   - baseline이 없거나 로그가 rotate되어 offset보다 작으면 기존 tail로 fallback한다.
3. `ftctl_xcolo_primary_storage_failure_reason_from_text` 변경
   - generic `Input/output error`와 generic `Operation not permitted` 판정을 제거한다.
   - block/rbd 문맥이 있는 오류만 storage reason으로 반환한다.
4. `ftctl_xcolo_primary_protocol_notice_from_text` 추가
   - COLO channel/protocol 관련 로그를 state notice로 남긴다.
5. block cold conversion 및 prebuilt 보호 시작 지점에서 QGA baseline과 함께 QEMU log baseline을 기록한다.

## 스모크 검증 기준

- `Can't receive COLO message: Input/output error`만 있는 로그는 storage failure가 아니다.
- `blk_update_request ... I/O error`는 storage failure다.
- `rbd ... failed`는 storage failure다.
- `filter mirror send failed(Operation not permitted)`는 storage failure가 아니다.
- baseline 이후 로그만 health 판정에 사용된다.
