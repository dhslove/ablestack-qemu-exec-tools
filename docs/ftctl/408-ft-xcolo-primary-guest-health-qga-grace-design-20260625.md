# FT XCOLO Primary Guest Health Gate 개선 설계

## 배경

FT Run 132에서 XCOLO 제어 채널, 마이그레이션 상태, 스토리지 헬스, secondary qcow2 baseline 형식 검증은 모두 정상 통과했다. 그러나 Primary VM의 QGA가 부팅 완료 직전까지 응답하지 않아 `xcolo_primary_guest_boot_unhealthy:qga_unavailable`로 즉시 실패 처리되었다.

이후 동일 VM의 QGA는 정상 응답했다. 따라서 해당 실패는 COLO 런타임 자체의 붕괴가 아니라, 게스트 부팅/QGA 초기화 지연을 즉시 오류로 판단한 검증 모델의 문제로 본다.

## 설계 원칙

- COLO 제어 채널, migrate 상태, filter/chardev, block graph, storage health 검증은 기존 기준을 유지한다.
- 게스트 하드 실패 증거는 즉시 실패로 판단한다.
- QGA 미응답만으로 즉시 실패하지 않는다. QGA는 게스트 부팅 이후 늦게 올라올 수 있으므로 grace window 동안 pending으로 둔다.
- pending 상태에서는 primary/secondary runtime을 보존하고 cleanup/recover를 실행하지 않는다.
- 최종 성공은 QGA가 안정적으로 응답하거나, 명시적으로 observe/off 정책을 선택한 경우에만 가능하다.
- 실패와 보류를 구분할 수 있도록 상태 키와 이벤트 로그에 기준값, 경과 시간, 안정화 횟수를 남긴다.

## AS-IS

| 항목 | 현재 동작 | 문제 |
| --- | --- | --- |
| QGA 검증 | `required` 정책에서 QGA가 한 번이라도 미응답이면 즉시 실패 | 게스트 부팅 중 일시 지연과 실제 부팅 실패를 구분하지 못함 |
| runtime validate | rc 10 pending 구조가 있으나 QGA health 함수는 pending을 반환하지 않음 | 이미 있는 pending 구조를 활용하지 못함 |
| 실패 복구 | QGA 미응답을 runtime failure로 보고 primary/secondary cleanup/recover 실행 | 실제로는 곧 정상화될 수 있는 런타임을 불필요하게 해체 |
| 증거 | 최종 QGA yes/no만 기록 | 보호 전 기준값, 대기 시작 시각, 경과 시간, 안정화 카운트가 없음 |

## TO-BE

| 항목 | 변경 동작 | 기대 효과 |
| --- | --- | --- |
| 보호 전 QGA 기준값 | Primary shutdown/conversion 전에 QGA baseline을 기록 | 원래 QGA 가능 VM인지, 처음부터 QGA 불가 VM인지 구분 |
| QGA grace window | QGA 미응답은 `FTCTL_XCOLO_PRIMARY_GUEST_HEALTH_TIMEOUT_SEC` 동안 pending | 부팅 중 QGA 지연을 실패로 오판하지 않음 |
| QGA 안정화 | QGA 성공은 `FTCTL_XCOLO_PRIMARY_GUEST_HEALTH_STABLE_COUNT`회 연속 성공 후 ok | 순간 응답만으로 정상 판단하지 않음 |
| hard boot failure | `/sysroot` mount 실패, emergency mode, XFS metadata I/O 오류, dracut timeout은 즉시 fail | 실제 부팅 실패는 지연 없이 차단 |
| pending 보존 | guest health pending은 validate rc 10으로 반환 | COLO runtime을 보존하고 후속 reconcile에서 재검증 |
| 상태 기록 | baseline, pending_since, elapsed, timeout, success_count, reason 기록 | 반복 테스트에서 같은 지점 반복 여부를 추적 가능 |
| 로그 reason 전달 | helper 내부 출력 변수와 호출자 출력 변수 이름이 충돌하지 않도록 분리 | hard guest/storage failure reason이 실제 호출자에게 전달됨 |

## 구현 상세

1. `ftctl_xcolo_capture_primary_qga_baseline` helper를 추가한다.
2. block cold conversion과 prebuilt 보호 경로에서 runtime 변경 전에 baseline을 기록한다.
3. `ftctl_xcolo_validate_primary_guest_health`가 세 가지 결과를 반환하도록 변경한다.
   - `0`: guest health ok 또는 observe/off 허용
   - `10`: hard failure는 없지만 QGA grace window가 남아 있음
   - `1`: hard failure 또는 grace timeout
4. `ftctl_xcolo_validate_pair_runtime`의 성공 후보 조건에서 QGA를 선행 조건으로 쓰지 않고, guest health 함수가 ok/pending/fail을 판정하게 한다.
5. guest health pending이면 `xcolo_pending_reason=primary_guest_health_pending:<reason>`으로 기록하고 runtime validate도 rc 10을 반환한다.
6. `*_failure_reason_from_text` helper 내부 변수명을 `detected_reason`으로 바꿔, 호출자가 `reason` 변수를 전달해도 Bash local scope 충돌로 reason이 사라지지 않게 한다.

## 기본 설정

| 설정 | 기본값 | 의미 |
| --- | --- | --- |
| `FTCTL_XCOLO_PRIMARY_GUEST_HEALTH_TIMEOUT_SEC` | `180` | QGA 미응답을 pending으로 유지할 최대 시간 |
| `FTCTL_XCOLO_PRIMARY_GUEST_HEALTH_STABLE_COUNT` | `2` | QGA ok 판정 전 필요한 연속 성공 횟수 |
| `FTCTL_XCOLO_PRIMARY_GUEST_HEALTH_POLICY` | `required` | FT steady state 성공 시 primary guest health 확인 필요 |

## Run 132 대비 개선 지점

Run 132와 동일하게 COLO/migrate/storage가 정상이고 QGA만 늦게 응답하면 즉시 실패하지 않는다. 상태는 `pairing/establishing` 또는 `pending`으로 유지되며, 다음 timer/reconcile에서 QGA가 회복되면 `colo_running/mirroring`으로 승격된다.

반대로 콘솔/로그에 `/sysroot` mount 실패나 XFS metadata I/O 오류가 보이면 이전과 같이 즉시 실패 처리한다. 이는 사용자가 우려한 “겉으로 정상처럼 보이지만 guest filesystem이 깨진 상태”를 통과시키지 않기 위한 조건이다.

## 스모크 검증 기준

- QGA 미응답: rc 10, `xcolo_primary_guest_health_gate=pending`, `xcolo_pending_reason=primary_guest_health_pending:qga_transient_wait`.
- QGA 1회 성공: rc 10, `qga_stabilizing`.
- QGA 2회 연속 성공: rc 0, `xcolo_primary_guest_health_gate=ok`.
- `/sysroot` mount 실패 로그: rc 1, `xcolo_primary_guest_boot_unhealthy:sysroot_mount_failed`.
- QEMU I/O error 로그: `qemu_log_io_error` reason이 호출자에게 전달.
