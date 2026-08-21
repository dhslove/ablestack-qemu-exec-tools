# 463. FTCTL DR Release Tombstone Profile-Independent Status Contract

- 작성일: 2026-08-21
- 상태: 설계 및 구현 완료, 테스트 배포 검증 대기
- 관련 Cloud 설계: `614-cross-hypervisor-dr-release-terminal-regression-gate-design-20260821.md`
- 회귀 발생 변경: RPO deadline 상태 필드 추가

## 1. 문제

보호 해제는 scheduler를 중지하고 release tombstone을 기록한 뒤 `profile.json`을
삭제한다. 이는 정상 동작이다. 그러나 RPO deadline 상태 필드가 추가되면서
`dr-status`가 profile 안에서만 초기화되는 `policy_target_rpo_seconds`를 profile
삭제 후에도 참조했다. `set -u`에 의해 상태 JSON 생성이 중단되어 Cloud가
`RELEASED`를 읽지 못하고 과거 `READY` 상태를 유지했다.

## 2. 불변 계약

1. release 완료 후 profile 부재는 오류가 아니라 terminal 상태다.
2. `release.json`만 남아도 `dr-status`는 `RELEASED / UNPROTECTED / STOPPED`를
   반환해야 한다.
3. release 상태 조회는 VM, 스토리지, 네트워크를 변경하지 않는다.
4. release 직전 authority는 tombstone과 재구성 상태에서 동일하게 보존한다.
5. optional 상태 필드는 조건부 읽기 전에 기본값을 가져야 하며 `set -u` 예외를
   만들 수 없다.
6. status 파일이 재부팅 또는 정리로 없어져도 유효한 tombstone에서 안전하게
   복원한다.

## 3. 구현

- `dr_runtime.sh`
  - `policy_target_rpo_seconds`를 빈 값으로 명시 초기화한다.
  - profile이 없으면 기본 RPO 값으로 정규화한다.
  - `ftctl_dr_runtime_restore_release_status()`가 contract, plan UUID, state, step,
    protection state를 모두 검증한 후 status를 재구성한다.
  - 임의 JSON이나 다른 Plan의 tombstone은 사용하지 않는다.
- `ftctl_dr_release_tombstone_smoke.sh`
  - profile 없는 release status 직렬화
  - status 삭제 후 tombstone 기반 재구성
  - authority 보존과 profile 미생성
  - 기본 RPO 필드의 strict JSON 출력을 검증한다.

## 4. 영구 회귀 방지 규칙

`dr_runtime.sh`, `dr_scheduler.sh`, DR status JSON, profile lifecycle 중 하나라도
바뀌면 release regression gate를 필수 실행한다. branch 개발 RPM workflow는 이
테스트가 실패하면 RPM 생성 전에 중단한다. 공통 상태 코드 변경은 동기화 기능만의
변경으로 간주하지 않고 release, pause/resume, test failover/cleanup,
failover/failback의 기존 성공 계약을 함께 검증한다.

## 5. AS-IS / TO-BE

| 구분 | AS-IS | TO-BE |
| --- | --- | --- |
| profile 삭제 후 status | unbound variable로 JSON 실패 | 정상 RELEASED JSON |
| status 파일 유실 | not found | tombstone에서 복원 |
| RPO 필드 | profile 존재 시에만 초기화 | 항상 기본값 보장 |
| 배포 게이트 | 정상 보호 상태만 검사 | release terminal 회귀 필수 검사 |

