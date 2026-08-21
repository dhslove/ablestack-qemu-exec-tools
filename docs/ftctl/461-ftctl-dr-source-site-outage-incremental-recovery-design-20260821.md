# FTCTL DR Source Site Outage Incremental Recovery Design

## 1. 목적

VMware 원본 사이트가 전원 또는 네트워크 장애로 일시 중단되어도 검증된 VMware -> ABLESTACK(RBD) VDDK, NBD, librbd 전송 경로와 마지막 durable CBT 기준선을 보존한다. 원본 복구 뒤 운영자 Full Reseed 없이 같은 보호 계획이 증분 동기화를 자동 재개하도록 한다.

## 2. 확인된 장애

- vCenter `10.10.21.10:443` 단절은 `no route to host`였지만 기존 mover가 `DR_VMWARE_VDDK_CONNECT_INVALID`로 분류했다.
- 전원 복구 중 vCenter reverse proxy는 `/ui`와 VAPI를 제공하면서도 SOAP SDK `/sdk`에 `503 Service Unavailable`과 `no healthy upstream`을 반환했다. 이 문자열도 기존 transport 분류에서 빠져 snapshot.create 실패가 VDDK 인자 오류로 잘못 종결됐다.
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

통신 오류 분류는 route, timeout, connection refused/reset, DNS, network unreachable 및 vCenter SDK의 HTTP 503/upstream unavailable에만 적용한다. VDDK parameter invalid, 인증 실패, 디스크 lock, CBT 오류는 기존 terminal 진단 경로를 유지한다.

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

1. transport 문자열, SDK 503와 VDDK 인자 오류 분류 단위 테스트
2. snapshot.create 단절 및 SDK 503의 rc 98 검증
3. backoff 증가 및 최대 300초 제한 검증
4. 같은 sequence 재사용과 성공 후 메타데이터 정리 검증
5. 실환경에서 vCenter 연속 정상 확인 뒤 자동 RECOVER_SYNC 제출
6. 복구 첫 durable Cycle이 `CBT_INCREMENTAL` 또는 `NO_CHANGE`이며 Full Reseed가 아님을 확인

## 6. 전원 장애로 CBT epoch가 변경된 경우

원본 사이트 연결 복구와 CBT 기준선 유효성은 별개의 조건이다. vCenter와 VM이
정상이어도 강제 전원 장애 뒤 과거 changeId가 현재 CBT epoch에서 더 이상 조회되지
않을 수 있다. 이때 과거 changeId의 `QueryChangedDiskAreas`는 `FileFault`를 반환하지만,
같은 임시 스냅샷의 현재 changeId 조회는 성공한다.

```text
WAITING_SOURCE
  -> old changeId query fails
  -> current changeId preflight succeeds
  -> DR_CBT_RESEED_REQUIRED / SOURCE_CBT_EPOCH_RESET
  -> same sequence, same owner Run, one controlled FULL_RESEED
  -> LOCAL_DURABLE
  -> next scheduled cycle CBT_INCREMENTAL or NO_CHANGE
```

- 현재 changeId preflight까지 실패하면 기준선 문제가 아니라 VMware 파일 또는
  datastore 장애일 수 있으므로 자동 재시드를 수행하지 않는다.
- 자동 재시드는 동일 sequence에서 한 번만 허용한다. 재시드 자체가 실패하면
  terminal 오류로 종결해 무한 전체 복사를 방지한다.
- 시퀀스 상태에는 자동 재시드를 시도한 `baselineGeneration`을 가드로 보존한다.
  프로세스 또는 systemd가 재시작돼도 같은 generation으로는 자동 재시드를 다시
  수행하지 않으며 `DR_CBT_RESEED_LOOP_DETECTED`로 종결한다. 새 기준선이 durable
  commit된 경우에만 가드를 해제한다.
- 재시드 commit 전까지 마지막 정상 증분 기준선과 대상 디스크를 유효한 복구
  기준으로 유지한다.
- 성공 체크포인트에는 `automaticReseed=true`,
  `modeDecisionCode=SOURCE_CBT_EPOCH_RESET`을 기록한다.
- 다음 durable 주기가 `CBT_INCREMENTAL` 또는 `NO_CHANGE`로 완료돼야 자동 증분
  복구 완료로 판정한다.

## 7. 2026-08-21 실환경 preflight

- 과거 changeId 조회: `vim.fault.FileFault`
- 같은 VM, 같은 디스크, 새 임시 스냅샷의 현재 changeId 조회: 성공
- 전체 50 GiB coverage: 1 page, 0 changed area, activation verified
- 판정: vCenter 연결 및 CBT 기능 정상, 과거 CBT epoch만 무효

전원 복구 이후 추가 점검에서는 `/ui` HTTP 200, VAPI 인증 응답과 달리 SOAP
SDK `/sdk`가 HTTP 503을 반환했다. 이 상태에서는 CBT epoch 검증보다 앞선
snapshot.create 자체가 불가능하다. 따라서 rc 73 terminal 오류가 아니라 rc 98
`WAITING_SOURCE`로 같은 sequence와 마지막 durable 기준선을 보존해야 한다.

| 항목 | AS-IS | TO-BE |
|---|---|---|
| 과거 changeId 무효 | `DR_CBT_QUERY_FAILED`, systemd 반복 재시작 | 현재 epoch preflight 후 `DR_CBT_RESEED_REQUIRED` |
| 복구 Cycle | 매 재시작마다 새 실패 sequence | 동일 sequence에서 1회 제한 자동 재시드 |
| 재시드 실패 후 재시작 | 동일 기준선 전체 복사 반복 가능 | generation 가드로 반복 차단, 운영자 복구 요구 |
| 기준선 | 과거 durable 기준선만 계속 재시도 | 재시드 commit 전까지 보존, 성공 시 원자 교체 |
| 이후 보호 | `ERROR/DEAD` | 다음 RPO 주기부터 증분 또는 무변경 |

## 8. 2026-08-21 테스트 배포 및 대기 경로 검증

- 소스 커밋: `926a98da9b3e06973c564a49b1f5a9fbfba1c7dc`
- GitHub Actions Run: `32458925978`
- RPM: `ablestack_vm_ftctl-0.9.5-1.noarch`
- RPM SHA256: `8605b85169ed17c6bbf257c593689aa85f703c2995437c92398fc1e2ac4cb446`
- 설치 mover SHA256: `0cffb6987835adaa6796c309898181ece8bd90bb3b3faf5ff3a34f570ed25d13`

32번 클러스터의 3개 호스트에는 `aspkg`, 22번 클러스터의 3개 호스트에는
네이티브 `rpm`으로 동일 아티팩트를 설치했다. 모든 호스트에서 timer active,
SDK 503와 `no healthy upstream` transport 분류 PASS, VDDK parameter invalid의
비-transport 분류 PASS를 확인했다.

32번의 기존 장기 scheduler는 패키지 교체 전에 시작돼 구버전 mover를 메모리에
유지하고 있었다. 중단된 VDDK/NBD worker가 실제 전송 없이 남아 있음을 확인한 뒤
계획별 systemd unit만 rolling restart했다. 세 계획은 각각 기존 sequence
`1916`, `1790`, `2811`을 유지하면서 `WAITING_SOURCE`, `retryable=true`로
네 차례 이상 재시도했고, 백오프는 약 40초에서 130초대로 증가했다. 새 Cycle 또는
새 Run은 생성되지 않았으며 잔류 nbdkit 프로세스도 정리됐다.

22번 호스트에는 실행 중 DR scheduler와 VDDK/NBD 전송 프로세스가 없어 패키지
설치 후 별도 rolling restart를 수행하지 않았다. 이후 생성 또는 재개되는 scheduler는
설치된 새 코드를 처음부터 사용한다.
