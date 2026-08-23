# 465. FTCTL DR Release Resource Disposition Contract

- 작성일: 2026-08-23
- 상태: 설계 및 구현 완료, 이중 클러스터 배포 검증 대기
- 관련 Cloud 설계: `616-dr-release-resource-disposition-and-target-retention-design-20260823.md`

## 1. 목표

보호 관계 종료와 Cloud 자원 삭제를 분리한다. FTCTL은 scheduler와 복제 runtime을
종료하고 release tombstone에 운영자가 선택한 처분 의도를 기록한다. Cloud VM과
볼륨의 생명주기는 Cloud만 소유하며 FTCTL은 어떤 처분 모드에서도 이를 삭제하지
않는다.

## 2. 계약

| 값 | 의미 | FTCTL 동작 |
| --- | --- | --- |
| `RETAIN_OPERATIONAL_VM` | 대상 VM과 디스크 보존 | 복제 종료 및 의도 기록 |
| `DELETE_STANDBY_REPLICA` | Cloud 소유 대기 복제 자원 삭제 요청 | 복제 종료 및 의도 기록 |

값이 없으면 `RETAIN_OPERATIONAL_VM`을 사용한다. release status와 tombstone에는
`resource_disposition`을 남기지만 `vm_mutated`, `storage_mutated`,
`network_mutated`는 항상 `false`다. profile 삭제 후 tombstone에서 상태를 복원해도
같은 처분 값이 유지되어야 한다.

## 3. 역할 경계

1. FTCTL은 mover, scheduler, NBD와 복제 profile만 종료한다.
2. FTCTL은 Cloud VM, volume, NIC, network를 삭제하지 않는다.
3. Cloud는 release 완료 후 plan authority와 target ownership을 다시 검증한다.
4. Cloud만 선택적으로 대기 복제 VM과 소유 volume을 삭제한다.
5. target이 운영 authority인 경우 Cloud는 삭제를 거부한다.

## 4. 회귀 테스트

- 기본값과 보존 모드 tombstone 직렬화
- status 파일 유실 후 처분 값 복원
- 두 모드 모두 `*_mutated=false`
- release profile tombstone 회귀 게이트
- 기존 sync, pause/resume, test failover/cleanup, failover/failback 계약

## 5. AS-IS / TO-BE

| 구분 | AS-IS | TO-BE |
| --- | --- | --- |
| 자원 처분 의도 | 상태 증거에 없음 | tombstone/status에 명시 |
| 기본 동작 | 암묵적 보존 | 명시적 보존 기본값 |
| VM/볼륨 삭제 주체 | 경계 불명확 | Cloud 전용 |
| target authority | 처분 구분 없음 | 삭제 요청을 Cloud가 차단 |
