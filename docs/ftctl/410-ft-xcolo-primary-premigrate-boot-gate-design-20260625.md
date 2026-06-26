# FT XCOLO Primary Pre-Migrate Boot Gate 개선 설계

> Note: generated qemu commandline RBD backend rules in this document are
> superseded by
> [414. FT XCOLO RBD commandline backend contract](414-ft-xcolo-rbd-commandline-backend-contract-design-20260626.md).
> Cloud/profile disk identity remains the stable KRBD path, but the default
> generated XCOLO qemu commandline backend is the preserved `librbd` URI path.
> Pure generated-commandline KRBD is an explicit experimental mode.

## 배경

Run 134는 이전의 `invalid COLO message` 또는 storage log 오탐 지점을 넘어서 Primary/Secondary 모두 COLO role에 진입했다. 그러나 Primary guest QGA가 180초 동안 응답하지 않아 `xcolo_primary_guest_boot_unhealthy:qga_timeout`으로 실패했다.

실패 후 복구된 Primary는 Cloud/libvirt 원래 디스크 정의(`/dev/rbd/rbd/<volume-id>` 기반)로 재기동되자 QGA가 즉시 응답했다. 따라서 이번 문제는 COLO 네트워크 연결 자체보다, FTCTL이 만든 Primary COLO용 block graph가 guest boot 가능한 disk view를 제공하지 못하는 문제로 분리해야 한다.

## 설계 원칙

- QEMU COLO 문서의 순서를 유지한다. Secondary NBD export 준비 후 Primary에서 NBD child를 붙이고, 그 다음 migrate를 실행한다.
- migrate 전에 Primary COLO runtime block graph가 guest-visible disk로 성립했는지 확인한다.
- Primary guest가 COLO용 block graph에서 부팅 가능한 상태인지 migrate 전에 확인한다.
- ABLESTACK RBD 안정 경로 원칙을 지킨다. `/dev/rbd/rbd/<image>`를 장기 기준으로 사용하고, 이를 `rbd:rbd/<image>` userspace URI로 바꾸지 않는다.
- 실패는 원인 단계별로 분리한다. block graph 불성립, guest hard boot failure, QGA timeout, post-migrate COLO failure를 같은 오류로 섞지 않는다.

## AS-IS

| 항목 | 현재 동작 | 문제 |
| --- | --- | --- |
| Primary RBD parent source | `/dev/rbd/rbd/<id>` 입력을 `rbd:rbd/<id>` QEMU URI로 변환 | Cloud/libvirt 정상 부팅 backend와 FT runtime backend가 달라짐 |
| Primary block graph 검증 | `ftctl-colo-*`, `ftctl-primary-active-*`, `ftctl-nbd-*` node 존재 중심 | guest qdev가 `ftctl-colo-*`를 실제로 물고 있는지 확인이 약함 |
| Primary guest health 확인 | migrate 후 runtime steady-state gate에서 QGA 확인 | guest boot 불가와 COLO protocol 문제를 뒤늦게 섞어 관측 |
| 실패 분류 | post-migrate `qga_timeout` | COLO 전송 문제인지 Primary boot graph 문제인지 불명확 |

## TO-BE

| 항목 | 변경 동작 | 기대 효과 |
| --- | --- | --- |
| RBD source | `/dev/rbd/rbd/<id>`는 그대로 `file.filename=/dev/rbd/rbd/<id>`로 QEMU에 전달 | Cloud/libvirt 부팅 backend와 FT runtime backend 일관성 확보 |
| Primary block graph gate | `query-named-block-nodes`와 `query-block`을 함께 보고 node driver 및 qdev 연결 확인 | `x-blockdev-change` 이후 guest-visible disk view 확인 강화 |
| Pre-migrate boot gate | pre-migrate contract와 guest traffic gate 통과 후 `cont`, QGA/guest log/storage health 확인 | migrate 전 Primary COLO graph boot 가능성 검증 |
| 실패 상태 | `xcolo_primary_colo_boot_graph_invalid`, `xcolo_primary_colo_boot_unhealthy:*` | 다음 조치 지점을 명확히 분리 |
| 증거 | query-status/query-block/query-named-block-nodes/QEMU log tail debug 파일 저장 | 반복 테스트 때 같은 원인 순환 여부 판단 가능 |

## 실행 순서

1. Primary/Secondary generated XML을 만든다.
2. Primary를 COLO commandline으로 create하고, Secondary를 activate한다.
3. Secondary NBD server/export를 준비한다.
4. Primary에 NBD child를 `blockdev-add`하고 각 `ftctl-colo-*` quorum에 `x-blockdev-change`로 붙인다.
5. pre-migrate ABI/role/block graph contract를 검증한다.
6. filter/chardev/firewall/topology/materialization gate를 통과한다.
7. guest traffic gate 통과 후 Primary에 `cont`를 실행한다.
8. Primary pre-migrate boot gate를 수행한다.
   - block graph가 `ftctl-colo-*`, `ftctl-primary-active-*`, `ftctl-nbd-*` node와 guest qdev 연결을 갖는지 확인한다.
   - QMP block health와 QEMU log hard guest failure를 확인한다.
   - baseline QGA가 available이면 QGA 응답을 timeout까지 기다린다.
9. pre-migrate boot gate가 통과할 때만 `migrate`를 실행한다.

## 실패 분류

| 실패 | 의미 | 후속 분석 |
| --- | --- | --- |
| `xcolo_primary_colo_boot_graph_invalid` | Primary guest-visible COLO block graph가 성립하지 않음 | `primary-premigrate-query-block*.json`, `primary-premigrate-query-named-block-nodes*.json` 확인 |
| `xcolo_primary_colo_boot_unhealthy:sysroot_mount_failed` | guest가 root filesystem mount 실패 | Primary active overlay/backing/format/flush 확인 |
| `xcolo_primary_colo_boot_unhealthy:guest_filesystem_metadata_io_error` | guest filesystem metadata I/O 오류 | COLO overlay와 RBD parent write/read 일관성 확인 |
| `xcolo_primary_colo_boot_unhealthy:qga_timeout` | hard failure log는 없지만 baseline QGA가 돌아오지 않음 | guest console, qga service, root/data disk wait 상태 확인 |
| `xcolo_primary_storage_unhealthy:*` | QMP block 또는 명확한 block/rbd 오류 | storage path, RBD map, capacity/permission 확인 |

## 스모크 검증 기준

- `bash -n lib/ftctl/xcolo.sh`가 통과해야 한다.
- `/dev/rbd/rbd/<id>` 입력은 `file.filename=/dev/rbd/rbd/<id>`로 생성되어야 한다.
- primary block graph parser는 `ftctl-colo-*`, `ftctl-primary-active-*`, `ftctl-nbd-*`와 qdev 연결을 상태로 남겨야 한다.
- handshake path에는 `cont_before_migrate`와 `xcolo.primary_premigrate_boot` gate가 migrate보다 먼저 있어야 한다.
