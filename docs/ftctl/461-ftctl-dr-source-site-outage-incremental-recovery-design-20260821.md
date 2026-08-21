# FTCTL DR Source Site Outage Incremental Recovery Design

## 1. 목적

VMware 원본 사이트가 전원 또는 네트워크 장애로 일시 중단되어도 검증된 VMware -> ABLESTACK(RBD) VDDK, NBD, librbd 전송 경로와 마지막 durable CBT 기준선을 보존한다. 원본 복구 뒤 운영자 Full Reseed 없이 같은 보호 계획이 증분 동기화를 자동 재개하도록 한다.

## 2. 확인된 장애

- vCenter `10.10.21.10:443` 단절은 `no route to host`였지만 기존 mover가 `DR_VMWARE_VDDK_CONNECT_INVALID`로 분류했다.
- Scheduler는 종료 코드 73을 terminal 오류로 처리하고 systemd 재시작 제한에 도달해 `ERROR/DEAD/RECOVERY_FAILED`가 됐다.
- 마지막 durable Cycle은 유지됐고 실패 Cycle은 전송 또는 commit 전이므로 기준선 자체는 손상되지 않았다.
- vCenter 복구 후 사이트 헬스는 정상으로 돌아왔지만 Scheduler 자동 복구 설정과 ERROR 상태 eligibility가 복구를 막았다.

## 3. FTCTL 계약

| 구분 | AS-IS | TO-BE |
|---|---|---|
| 통신 단절 분류 | VDDK 인자 오류와 동일한 rc 73 | `DR_SOURCE_SITE_UNAVAILABLE`, rc 98 |
| Scheduler | terminal ERROR 후 프로세스 종료 | `WAITING_SOURCE`, retryable 대기 |
| Cycle | 재시도마다 새 sequence 가능 | 같은 sequence, cycle type, request Run 재사용 |
| 기준선 | 복구 방식 불명확 | 마지막 durable changeId와 snapshot 기준선 보존 |
| backoff | systemd 빠른 재시작 | 15~300초 지수 backoff와 제한된 jitter |
| 복구 완료 | 과거 오류 필드 잔존 가능 | 성공 commit과 함께 대기/오류 필드 원자적 정리 |

통신 오류 분류는 route, timeout, connection refused/reset, DNS 및 network unreachable에만 적용한다. VDDK parameter invalid, 인증 실패, 디스크 lock, CBT 오류는 기존 terminal 진단 경로를 유지한다.

## 4. 상태 및 재시도

```text
RUNNING -> source transport failure -> WAITING_SOURCE
WAITING_SOURCE -> same sequence retry -> WAITING_SOURCE
WAITING_SOURCE -> source restored -> CBT_INCREMENTAL/NO_CHANGE -> READY
```

- `pending_source_sequence`, `pending_source_cycle_type`, `pending_source_run`은 재시도 소유권을 고정한다.
- `source_outage_since`, `next_retry_at`, `retry_after_sec`는 관측용이며 durable 기준선은 변경하지 않는다.
- 원본 복구 후 baseline validation이 실패한 경우에만 기존 명시적 reseed 판정 규칙을 사용한다.
- 운영자가 장애 중 전체 재동기화를 누를 필요가 없다.

## 5. 검증

1. transport 문자열과 VDDK 인자 오류 분류 단위 테스트
2. snapshot.create 단절 rc 98 검증
3. backoff 증가 및 최대 300초 제한 검증
4. 같은 sequence 재사용과 성공 후 메타데이터 정리 검증
5. 실환경에서 vCenter 연속 정상 확인 뒤 자동 RECOVER_SYNC 제출
6. 복구 첫 durable Cycle이 `CBT_INCREMENTAL` 또는 `NO_CHANGE`이며 Full Reseed가 아님을 확인

