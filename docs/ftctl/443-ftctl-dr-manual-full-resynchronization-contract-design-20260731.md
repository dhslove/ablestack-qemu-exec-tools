# FTCTL DR Manual Full Resynchronization Contract

## 범위

Cloud의 `전체 재동기화` 요청을 FTCTL 스케줄러가 1회성 전체 복제 주기로 실행하고,
완료 후 기존 RPO 기반 CBT 증분 루프로 복귀시키는 런타임 계약을 정의한다.

## 구현 계약

- 입력: `dr-sync-start --mode FULL_RESEED --force-immediate-cycle`
- 예약 상태: `requested_cycle_state=PENDING`
- 실행 상태: `requested_cycle_state=RUNNING`
- 종료 상태: `COMPLETED` 또는 `FAILED`
- 주기 유형: `full-reseed`
- 결과 귀속: `latest_completed_producer_run_uuid=<request run UUID>`
- 완료 결과: `latest_completed_requested_mode=FULL_RESEED`
- 작업별 조회: 공용 Plan 상태의 완료 체크포인트를 요청 Run 상태 파일에 투영하고 `run=<request run UUID>`를 유지
- 후속 주기: 디스크 맵의 새 `LOCAL_DURABLE` 기준선을 이용한 `incremental`

Cloud 프로필에서 `vmware-disks.json`을 다시 생성할 때 디스크 식별자가 동일하면 다음 런타임 필드를
보존한다.

- `changeId`
- `cbtChangeId`
- `baselineGeneration`
- `lastSyncSequence`
- `baselineState`

## AS-IS / TO-BE

| 항목 | AS-IS | TO-BE |
|---|---|---|
| 수동 명령 | 일반 sync 시작 | 1회성 FULL_RESEED 예약 |
| 즉시 실행 | 기존 스케줄러 대기 주기에 종속 | control generation 변경으로 즉시 기상 |
| Run 상관관계 | 영구 스케줄러 Run으로 기록 | 요청 Run UUID로 체크포인트 생성 |
| Run 상태 조회 | 수동 Run이 예약 상태에 머물 수 있음 | 실행 중/성공/실패를 요청 Run 파일에 동일하게 투영 |
| 증분 기준선 | 정규화 과정에서 덮어쓰기 가능 | 동일 디스크의 durable 기준선 보존 |
| 반복 여부 | 후속 주기도 full-reseed 가능 | 요청 완료 후 자동 incremental 복귀 |
