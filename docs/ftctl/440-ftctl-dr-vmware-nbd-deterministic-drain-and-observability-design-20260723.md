# FTCTL DR VMware NBD Deterministic Drain And Observability Design

> 2026-07-27 후속 계약: 이 문서에서 생성한 NBD drain 증거를 실제 Failover
> operation status까지 손실 없이 전달하고 exact checkpoint로 복원하는 규칙은
> `442-ftctl-dr-failover-authority-cycle-evidence-and-abort-contract-design-20260727.md`
> 를 따른다.

- 문서 번호: 440
- 작성일: 2026-07-23
- 상태: 실환경 Preflight 검증 완료, 구현 전 상세 설계
- 적용 범위: VMware -> ABLESTACK 증분 동기화의 `nbdkit`, `nbd-client`,
  `qemu-nbd`, DR Scheduler, DR runtime
- Cloud 상위 설계:
  `ablestack-cloud/docs/ftctl/569-cross-hypervisor-dr-nbd-deterministic-drain-and-cycle-observability-design-20260723.md`
- 관련 설계:
  - [432-ftctl-dr-vmware-mover-nbd-source-graph-design-20260707.md](432-ftctl-dr-vmware-mover-nbd-source-graph-design-20260707.md)
  - [439-ftctl-dr-systemd-owned-scheduler-and-recovery-design-20260722.md](439-ftctl-dr-systemd-owned-scheduler-and-recovery-design-20260722.md)

## 1. 목적

VMware CBT 증분 데이터를 적용한 뒤 NBD 장치를 즉시 disconnect하면 커널의
partition 재조회 또는 udev 비동기 작업이 이미 해제된 NBD 장치의 0번 섹터를
읽을 수 있다. 이때 다음 오류가 반복된다.

```text
I/O error, dev nbd1, sector 0 op 0x0:(READ)
Buffer I/O error on dev nbd1, logical block 0, async page read
```

본 설계는 다음을 보장한다.

1. 모든 성공/실패 종료 경로가 하나의 deterministic drain 함수로 수렴한다.
2. NBD 장치는 `pid 없음`만으로 재사용하지 않고 완전한 stable-free 상태에서만
   다시 할당한다.
3. target flush와 NBD drain을 서로 다른 내구성 경계로 구분한다.
4. drain 실패 장치는 재사용하지 않고 Plan 단위로 격리한다.
5. drain 실패 시 새로운 CBT changeId와 baseline generation을 커밋하지 않는다.
6. 복구는 전체 데이터를 다시 복사하지 않고 cleanup-only로 재시도할 수 있다.
7. FTCTL status/event가 Cloud에 필요한 집계 상태를 제공한다.

## 2. 확인된 원인

현재 `lib/ftctl/dr_vmware_mover.sh`의 문제는 다음과 같다.

| 코드 경로 | 현재 동작 | 문제 |
|---|---|---|
| NBD 할당 | `/sys/class/block/nbdN/pid` 부재만 확인 | size, partition, holder, mount, 이전 격리를 확인하지 않음 |
| source attach 실패 | 개별 분기에서 즉시 종료 | 공통 자원 registry가 없음 |
| source size timeout | `nbd-client -d` 결과 무시 | detach 완료를 확인하지 않음 |
| target attach retry | `qemu-nbd --disconnect` 직후 재사용 | udev/partition drain을 기다리지 않음 |
| patch 실패 | target/source를 각각 즉시 disconnect | 순서, timeout, 결과가 비결정적 |
| patch 성공 | flush 결과와 disconnect 결과를 무시 | 데이터 내구성과 자원 정리 성공을 구분하지 않음 |
| nbdkit 종료 | NBD detach와 독립적으로 종료 가능 | source device가 죽은 export를 가리킬 수 있음 |

`pid` 파일이 사라진 것은 NBD client process가 연결을 놓았다는 뜻일 뿐이다.
커널 block size, partition child, holder, mount, udev work가 모두 정리되었다는
뜻은 아니다.

## 3. 실환경 Preflight

### 3.1 관측 결과

`10.10.32.1`과 `10.10.32.3`의 오류 발생 시각은 각각 실행 중인 DR Plan의
RPO 주기와 일치했다. 각 cycle은 `CBT_INCREMENTAL`로 성공했지만 NBD
disconnect 직후 커널 오류가 발생했다. 확인 시점의 `/dev/nbd1`은
`pid 없음`, `size=0`, mount/holder 없음이었으므로 물리 디스크 불량이나
지속적으로 연결된 NBD 장치 문제는 아니다.

### 3.2 검증 절차

활성 DR Scheduler가 없는 `10.10.32.2`에서 임시 raw image와 미사용 NBD
장치만 사용해 다음 순서를 검증했다.

```text
target flush
  -> udevadm settle
  -> 비활성 NBD partition device-mapper holder 제거
  -> udevadm settle
  -> partx -d
  -> udevadm settle
  -> qemu-nbd 또는 nbd-client disconnect
  -> sysfs pid/size/holder/partition/mount drain 확인
  -> udevadm settle
  -> stable-free 재확인
```

검증 대상은 두 경로 모두이다.

| 경로 | 장치 | 결과 |
|---|---|---|
| target | `qemu-nbd --connect/--disconnect` | capacity/partition/disconnect 정상, I/O 오류 없음 |
| source | `nbdkit` + `nbd-client -u/-d` | capacity/partition/disconnect 정상, I/O 오류 없음 |

따라서 구현은 단순 sleep이 아니라 위 순서와 종료 조건을 그대로 사용한다.

추가 Preflight에서 `max_part=0`은 오류를 제거했지만 module 전역 설정이라
v2k의 partition 사용 경로와 충돌할 수 있음을 확인했다. 최종 구현은
`/dev/nbd16`~`/dev/nbd31`을 FTCTL 전용 pool로 예약하고, 이 범위에만 udev
blkid/LVM 자동 탐색 억제 rule을 적용한다. lower NBD pool은 v2k 등 기존
도구의 동작을 유지한다.

## 4. 상태 계약

### 4.1 NBD teardown 상태

```text
NOT_APPLICABLE
  -> ATTACHED
  -> DRAINING
  -> DRAINED

DRAINING
  -> QUARANTINED

QUARANTINED
  -> DRAINING
  -> DRAINED
```

| 상태 | 의미 |
|---|---|
| `NOT_APPLICABLE` | NBD 경로를 사용하지 않은 cycle |
| `ATTACHED` | source 또는 target NBD가 연결됨 |
| `DRAINING` | flush/partition 정리/disconnect/stable-free 확인 중 |
| `DRAINED` | 모든 cycle 소유 NBD가 stable-free |
| `QUARANTINED` | bounded drain 실패, 재사용과 다음 cycle 금지 |

### 4.2 Cycle 완료 조건

cycle `COMPLETED`는 다음 조건을 모두 만족해야 한다.

```text
target data flush 성공
AND source/target NBD teardownState == DRAINED
AND cycle metadata atomic commit 성공
AND mode decision state commit 성공
```

target flush가 성공했지만 drain이 실패하면:

```text
state       = NBD_TEARDOWN_FAILED
commitState = TARGET_DURABLE_CLEANUP_PENDING
```

이 상태에서는 대상 데이터가 일부 또는 전부 내구성 있게 기록되었더라도
새 `changeId`, `baselineGeneration`, `incrementalVerified=true`를 게시하지
않는다. 이전 committed baseline이 계속 권위 상태이다.

## 5. `dr_vmware_mover.sh` 변경 설계

### 5.1 설정값

```bash
: "${FTCTL_DR_NBD_DRAIN_TIMEOUT_MS:=10000}"
: "${FTCTL_DR_NBD_DRAIN_POLL_MS:=50}"
: "${FTCTL_DR_NBD_UDEV_SETTLE_TIMEOUT_SEC:=10}"
: "${FTCTL_DR_NBD_STABLE_POLLS:=2}"
: "${FTCTL_DR_NBD_QUARANTINE_ROOT:=/run/ablestack-vm-ftctl/dr-runtime/nbd-quarantine}"
```

timeout은 무한 대기를 막기 위한 상한이다. production 경로에 drain bypass
옵션은 두지 않는다.

### 5.2 장치 snapshot

다음 함수는 명령 성공 여부가 아니라 커널 관측 상태를 JSON으로 반환한다.

```bash
ftctl_vmware_mover_nbd_snapshot DEVICE ROLE ATTACH_METHOD
```

반환 필드:

```json
{
  "device": "/dev/nbd10",
  "role": "TARGET",
  "attachMethod": "QEMU_NBD",
  "pidPresent": false,
  "sizeSectors": 0,
  "holderCount": 0,
  "partitionCount": 0,
  "mountedChildCount": 0
}
```

raw device 이름은 host-local 상세 로그에만 기록하며 Cloud API에는 노출하지
않는다.

### 5.3 stable-free 판정

```bash
ftctl_vmware_mover_nbd_is_stable_free DEVICE
ftctl_vmware_mover_nbd_wait_stable_free DEVICE TIMEOUT_MS
```

다음 조건이 `FTCTL_DR_NBD_STABLE_POLLS`회 연속 참이어야 한다.

```text
sysfs pid 없음
AND sysfs size == 0
AND holderCount == 0
AND partitionCount == 0
AND mountedChildCount == 0
AND quarantine record 없음
```

`ftctl_vmware_mover_free_nbd()`는 기존 전역 NBD lock을 잡은 상태에서 이
함수를 사용한다. `pid 없음/size > 0`과 같은 전이 중 장치는 건너뛴다.

### 5.4 cycle 자원 registry

`ftctl_vmware_mover_patch_disk()`의 로컬 변수만으로 cleanup하지 않고,
attach 직후 cycle-owned registry에 등록한다.

```bash
ftctl_vmware_mover_nbd_register DEVICE ROLE ATTACH_METHOD
ftctl_vmware_mover_nbd_mark_flushed DEVICE
ftctl_vmware_mover_nbd_unregister DEVICE
ftctl_vmware_mover_nbd_cleanup_all
```

함수 시작 시 `trap ftctl_vmware_mover_nbd_cleanup_all RETURN`을 설치한다.
성공, attach timeout, patch 실패, signal 종료가 같은 cleanup 순서를 사용한다.
registry는 LIFO로 정리해 target을 source보다 먼저 drain한다.

### 5.5 deterministic drain

```bash
ftctl_vmware_mover_nbd_drain DEVICE ROLE ATTACH_METHOD
```

구현 순서:

1. 전역 NBD lock을 획득한다.
2. TARGET이면 `blockdev --flushbufs` 성공을 필수로 확인한다.
3. `udevadm settle --timeout=<sec>`를 bounded 실행한다.
4. NBD partition holder가 device-mapper이고 mount/swap 사용 흔적이 없을
   때만 `dmsetup remove --retry`로 제거한다.
5. 다시 `udevadm settle`을 실행한다.
6. `partx -d <device>`를 실행한다. partition이 없는 결과는 성공으로 취급한다.
7. 다시 `udevadm settle`을 실행한다.
8. `QEMU_NBD`는 `qemu-nbd --disconnect`, `NBD_CLIENT`는
   `nbd-client -d`를 bounded 실행한다.
9. `wait_stable_free`로 pid/size/holder/partition/mount가 모두 비워지는지
   확인한다.
10. post-disconnect `udevadm settle` 후 stable-free를 다시 확인한다.
11. 성공 이벤트를 기록하고 registry에서 제거한다.
12. 실패 시 quarantine record를 atomic write하고 lock을 해제한다.

holder 제거는 NBD partition의 sysfs holder로 직접 확인된 장치에만 적용한다.
mount, 활성 swap 또는 비 device-mapper holder는 임의로 해제하지 않고
`DR_NBD_DEVICE_BUSY`로 격리한다. 따라서 호스트 루트 VG나 다른 VM 장치를
이름만으로 비활성화하지 않는다.

source NBD를 drain하기 전에 nbdkit process를 종료하지 않는다. source가
`DRAINED`된 후에만 `ftctl_vmware_mover_cleanup_nbdkit()`을 실행한다.

### 5.6 오류 코드

기존 exit 90과 91은 reseed guard에 사용 중이므로 다음 번호를 사용한다.

| Exit | 오류 코드 | 의미 |
|---|---|---|
| 92 | `DR_NBD_TEARDOWN_TIMEOUT` | stable-free 도달 timeout |
| 93 | `DR_NBD_DISCONNECT_FAILED` | disconnect command 실패 |
| 94 | `DR_NBD_DEVICE_BUSY` | holder/mount/partition 제거 실패 |
| 95 | `DR_NBD_DEVICE_QUARANTINED` | 격리 장치가 남아 다음 cycle 차단 |
| 96 | `DR_NBD_TARGET_FLUSH_FAILED` | target flush 실패 |

`dr_runtime.sh`와 `dr_scheduler.sh`는 이 exit code를 typed error code로
매핑한다. stderr 전체 문자열을 상태 코드로 사용하지 않는다.

## 6. 격리와 복구

### 6.1 격리 record

경로:

```text
/run/ablestack-vm-ftctl/dr-runtime/nbd-quarantine/<plan-uuid>/<nbd-name>.json
```

필드:

```json
{
  "schemaVersion": 1,
  "planUuid": "...",
  "cycleSequence": 747,
  "role": "TARGET",
  "attachMethod": "QEMU_NBD",
  "state": "QUARANTINED",
  "errorCode": "DR_NBD_TEARDOWN_TIMEOUT",
  "quarantinedAtEpochMs": 1784800000000
}
```

credential, vCenter URL, VMDK path, RBD secret은 기록하지 않는다.

### 6.2 cleanup-only reconcile

`dr-reconcile`과 `dr-sync-recover`는 새 worker를 시작하기 전에 해당 Plan의
quarantine record를 조회한다.

```text
record 없음
  -> 기존 reconcile

record 있음
  -> cycle 복사 금지
  -> nbd_drain 재실행
  -> 전부 DRAINED이면 record 제거
  -> 이전 committed baseline으로 scheduler 재개
```

cleanup-only 복구 중에는:

- VMware snapshot을 새로 만들지 않는다.
- CBT query를 실행하지 않는다.
- target에 데이터를 다시 쓰지 않는다.
- cycle sequence를 증가시키지 않는다.
- 이전 실패 cycle을 성공으로 바꾸지 않는다.
- 별도의 recovery event를 남긴다.

## 7. FTCTL status/event 계약

cycle 및 current runtime JSON에 다음 집계 필드를 추가한다.

```json
{
  "nbdTeardownState": "DRAINED",
  "nbdTeardownStartedAtEpochMs": 1784800000000,
  "nbdTeardownCompletedAtEpochMs": 1784800000042,
  "nbdTeardownDurationMs": 42,
  "nbdSourceDeviceCount": 1,
  "nbdTargetDeviceCount": 1,
  "nbdQuarantinedDeviceCount": 0,
  "nbdTeardownErrorCode": "",
  "nbdTeardownErrorMessage": ""
}
```

이벤트:

```text
dr.nbd.teardown.started
dr.nbd.teardown.completed
dr.nbd.teardown.quarantined
dr.nbd.teardown.recovered
```

정상 `DRAINED`는 info, `QUARANTINED`는 error이다. 예상 가능한 `partx`의
no-partition 결과는 warning으로 남기지 않는다.

## 8. Scheduler 제어

| teardown 상태 | Scheduler 동작 |
|---|---|
| `DRAINING` | 현재 worker의 bounded cleanup 대기 |
| `DRAINED` | 다음 RPO cycle 허용 |
| `QUARANTINED` | desired state를 `PAUSED_RECOVERY_REQUIRED`로 투영 |
| cleanup recovery 성공 | 이전 desired state가 RUNNING이면 재개 |
| cleanup recovery 실패 | 계속 격리, backoff 후 재시도 또는 운영자 복구 |

일반 local reconcile은 `QUARANTINED`를 단순 dead worker로 간주해 새 sync를
시작하면 안 된다. 먼저 cleanup-only drain이 성공해야 한다.

## 9. 테스트 설계

`tests/ftctl-selftest.sh`에 다음 case를 추가한다.

| Selftest | 검증 |
|---|---|
| `dr-nbd-free-requires-zero-size` | pid가 없어도 size가 남으면 할당하지 않음 |
| `dr-nbd-free-rejects-partitions` | child partition이 남으면 할당하지 않음 |
| `dr-nbd-target-drain-order` | flush -> settle -> partx -> disconnect -> wait 순서 |
| `dr-nbd-partition-holder-release` | 비활성 NBD 전용 device-mapper holder 제거 |
| `dr-nbd-mounted-holder-safety` | mount/swap holder 제거 거부 및 격리 |
| `dr-nbd-source-drain-before-nbdkit-stop` | source detach 후 nbdkit 종료 |
| `dr-nbd-drain-delayed-sysfs` | 지연된 pid/size 제거를 bounded poll로 대기 |
| `dr-nbd-drain-timeout-quarantine` | timeout 시 atomic quarantine 기록 |
| `dr-nbd-allocator-skips-quarantine` | 격리 장치 재사용 금지 |
| `dr-nbd-failure-path-shared-cleanup` | patch/attach/size 실패가 공통 cleanup 사용 |
| `dr-nbd-baseline-not-advanced` | teardown 실패 시 changeId/generation 불변 |
| `dr-nbd-cleanup-only-recovery` | 재복사 없이 drain 및 scheduler 재개 |
| `dr-nbd-status-aggregate` | cycle/runtime JSON 집계 필드 |

실환경 검증은 최소 다음을 포함한다.

1. Linux와 Windows Plan에서 연속 3회 CBT incremental cycle 수행
2. 각 cycle 후 관련 NBD의 pid/size/partition/holder가 모두 비어 있는지 확인
3. `journalctl -k`에 새 NBD sector-0 I/O 오류가 없는지 확인
4. disconnect 지연을 주입해 quarantine과 sync 차단 확인
5. `dr-sync-recover`가 cleanup-only로 복구하고 기존 baseline을 유지하는지 확인

## 10. 구현 순서

1. NBD snapshot/stable-free/drain helper와 설정값을 구현한다.
2. allocator를 stable-free + quarantine 기준으로 변경한다.
3. patch 함수의 모든 종료 분기를 registry/trap 기반 cleanup으로 통합한다.
4. target flush 실패를 terminal error로 승격한다.
5. cycle commit을 `DRAINED` 이후로 이동한다.
6. quarantine와 cleanup-only reconcile을 구현한다.
7. runtime/status/event 집계 필드를 추가한다.
8. selftest와 fault injection을 통과시킨다.
9. GitHub Actions로 FTCTL RPM을 빌드한다.
10. 10.10.32.1/2/3에 동일 RPM을 배포하고 kernel log/RPO cycle을 재검증한다.

## 11. AS-IS / TO-BE

| 항목 | AS-IS | TO-BE |
|---|---|---|
| NBD 할당 | sysfs pid 부재만 확인 | pid/size/holder/partition/mount/quarantine stable-free |
| NBD pool | v2k와 동일한 전체 범위 | FTCTL은 nbd16~31 예약, lower pool과 분리 |
| host 자동 탐색 | udev blkid/LVM이 게스트 파티션 탐색 | FTCTL 예약 pool만 blkid/LVM 자동 탐색 억제 |
| 종료 코드 | 분기마다 직접 disconnect | registry와 공통 deterministic drain |
| target 내구성 | flush 실패 무시 | flush 성공이 필수 commit gate |
| disconnect | command 반환 후 즉시 진행 | udev/partition drain과 sysfs 안정화 확인 |
| 게스트 LVM holder | host device-mapper에 남아 partx 실패 | 미사용 NBD holder만 제한 제거, 사용 중 holder는 격리 |
| 실패 장치 | 다음 cycle에서 재사용 가능 | Plan 단위 quarantine |
| cycle 완료 | patch/flush 직후 완료 가능 | 모든 NBD `DRAINED` 후 완료 |
| CBT baseline | teardown 실패와 무관하게 전진 가능 | 이전 committed baseline 유지 |
| 복구 | worker 재시작 또는 재동기화 | cleanup-only drain 후 scheduler 재개 |
| 관측성 | kernel log로만 발견 | typed status/event와 Cloud 집계 |
| 오류 분류 | 일반 patch/mover 실패 | timeout/disconnect/busy/quarantine/flush 구분 |

## 12. 완료 기준

- source와 target의 모든 성공/실패 경로가 공통 drain을 사용한다.
- NBD sector-0 I/O 오류가 연속 RPO cycle에서 재발하지 않는다.
- teardown 실패 시 다음 cycle과 NBD 재사용이 차단된다.
- teardown 실패 cycle은 `incrementalVerified=true`가 될 수 없다.
- cleanup-only 복구가 데이터 재전송 없이 격리를 해제한다.
- Cloud가 raw host device 정보 없이 Plan/cycle 정리 상태를 판단할 수 있다.
- 기존 RBD/QCOW2 FT/HA와 xcolo 경로에는 동작 변경이 없다.

## 13. 실환경 보강: Cloud 관리 RBD 대상 librbd 직접 쓰기

예약 NBD pool과 deterministic drain을 배포한 뒤 실제 RPO cycle을 다시
관찰한 결과, source `/dev/nbd16`에는 오류가 없었지만 target
`/dev/nbd17`에서만 sector-0 read 오류가 재현되었다. Cloud가 전달한
`targetPath`는 대상 RBD의 예상 KRBD 경로였지만 worker에 실제 map된 장치는
아니었다. mover는 이를 `rbd:<pool>/<image>`로 정규화한 뒤 qemu-nbd로 다시
감싸고 있었다. 이 두 번째 NBD 계층은 필요하지 않으며 오류 표면만 늘린다.

보강된 mover 계약은 다음과 같다.

1. VMware source는 VDDK를 연 nbdkit과 FTCTL 예약 source NBD로 읽는다.
2. `rbd:<pool>/<image>` target은 `python-rados`와 `python-rbd`로 열어
   extent를 직접 쓰고 `Image.flush()`한다.
3. 실제 블록 target은 `pwrite`, `fsync`, `blockdev --flushbufs`를 사용한다.
4. 이 경로의 `nbdTargetDeviceCount`는 `0`이고 source NBD만 deterministic
   drain한다.
5. 비블록 URI는 기존 target qemu-nbd 호환 경로를 유지한다.

| 항목 | AS-IS | TO-BE |
|---|---|---|
| VMware source | VDDK -> nbdkit -> source NBD | 동일, FTCTL 예약 NBD 사용 |
| ABLESTACK RBD target | librbd URI를 target qemu-nbd로 다시 래핑 | native python-librbd로 image에 직접 증분 쓰기 |
| target NBD 수 | RBD cycle마다 1 | Cloud 관리 블록 대상은 0 |
| 내구성 gate | target NBD flush 후 drain | librbd image flush 또는 block fsync/flush, source NBD drain |
| 소유권 | FTCTL이 Cloud 대상 위에 임시 target NBD 생성 | Cloud가 대상 image를 소유하고 FTCTL은 전달받은 RBD locator만 사용 |

완료 판정에는 연속 changed-data RPO cycle에서 `nbdTargetDeviceCount=0`,
`nbdTeardownState=DRAINED`, 신규 kernel NBD I/O 오류 0건을 함께 요구한다.
