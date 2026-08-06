# 454. FTCTL DR Forward Target Locator Reuse And Post-Failback Resume Design

## 1. 목적

이 문서는 최초 `VMware -> ABLESTACK` 보호에서 성공한 대상 디스크 해석 규칙을
페일백 후 정방향 재보호에도 그대로 재사용하기 위한 FTCTL 상세 설계이다.

핵심은 새 RBD 규칙을 추가하는 것이 아니다. 다음 기존 규칙을 모든 정방향 주기에
대해 하나의 공통 계약으로 강제한다.

```text
Cloud storage metadata: storageType=RBD, pool=rbd, image=<image>
FTCTL sync URI:          rbd:<pool>/<image>
Cloud VM runtime path:   /dev/rbd/<pool>/<image>
```

동기화는 librbd URI를 사용하고 Cloud가 VM을 실행할 때는 krbd 경로를 사용한다.
두 표현은 동일한 디스크를 가리키지만 용도와 소유자가 다르므로 하나의 문자열 필드로
덮어쓰지 않는다.

## 2. 실환경 Preflight 결과

검증 대상:

- Plan: `7889e625-371a-48f9-b553-54e311481170`
- Host: `10.10.32.2`
- Runtime root: `/run/ablestack-vm-ftctl/dr-runtime/plans/<plan>`

확인 결과:

| 항목 | 결과 |
|---|---|
| 원본 profile | `storagePath=rbd`, `storagePoolType=RBD`, volume UUID 모두 존재 |
| 정방향 대상 맵 | `ablestack/disk-map.json` 없음 |
| 역방향 맵 | `kvm-vmware/disk-map.json` 존재, `sourceUri=rbd:rbd/<image>` 정상 |
| 재개용 VMware 맵 | `targetDiskRef=<image>`만 존재 |
| 기존 canonicalizer dry-run | `/dev/rbd/rbd/<image>` 생성 성공 |
| 기존 qemu URI 변환 | `rbd:rbd/<image>` 생성 가능 |
| 현재 mover fallback | bare `<image>` 그대로 반환 |
| 실제 RBD open | `qemu-img info rbd:rbd/<image>` 성공 |

따라서 메타데이터나 RBD 이미지가 없어서 실패한 것이 아니다. 페일백 후 scheduler
재개가 최초 보호의 canonical target-map 생성을 호출하지 않은 것이 직접 원인이다.

## 3. 코드 수준 오류 원인

### 3.1 성공 경로

`lib/ftctl/dr_ablestack.sh`는 다음 순서로 대상 경로를 만든다.

1. `ftctl_dr_ablestack_canonicalize_profile()`이 profile의 target storage metadata를 읽는다.
2. RBD이면 `derive_target_path()`가 `/dev/rbd/<pool>/<image>`를 만든다.
3. `ftctl_dr_ablestack_target_uri_for_qemu()`가 이를 `rbd:<pool>/<image>`로 변환한다.

### 3.2 실패 경로

`lib/ftctl/dr_vmware.sh::ftctl_dr_vmware_replication_cycle()`은 VMware source map만
없을 때 재생성한다. ABLESTACK target map은 파일이 있을 때만
`FTCTL_DR_TARGET_DISK_MAP`으로 전달한다.

target map이 없으면 `lib/ftctl/dr_vmware_mover.sh::ftctl_vmware_mover_disk_plan()`이
source map의 `targetDiskRef`를 target path로 사용한다. 이어지는
`ftctl_vmware_mover_target_uri()`는 raw path가 비어 있을 때만 storage path와 name을
결합하므로 bare image name을 그대로 반환한다.

이 경로는 성공 로직을 재사용하지 않은 회귀 결함이다.

## 4. 불변 조건

1. 최초 보호와 페일백 후 정방향 재보호는 동일한 target locator resolver를 사용한다.
2. RBD sync target은 반드시 `rbd:<pool>/<image>`여야 한다.
3. `/dev/rbd/<pool>/<image>`는 VM runtime/krbd 표현이며 mover 입력으로 직접 사용하기
   전에 동일 공통 resolver를 통과한다.
4. RBD target에 bare image name만 있으면 추정 실행하지 않고 typed error로 중단한다.
5. forward target map과 reverse source map은 파일, role, generation을 분리한다.
6. reverse map은 forward target map의 대체물이 될 수 없다.
7. map은 profile SHA-256과 materialization generation에 결속된다.
8. scheduler sequence 할당은 checkpoint 완료 증거가 아니다.
9. 페일백 후 최초 정방향 checkpoint가 durable하게 완료되어야 보호 재개가 완료된다.
10. 실패한 재개 주기는 SOURCE authority를 되돌리지 않고 보호 상태만 degraded로 만든다.

## 5. 공통 Storage Locator V1

### 5.1 JSON 계약

```json
{
  "schemaVersion": 1,
  "storageType": "RBD",
  "volumeUuid": "93338e0f-2095-4b8f-8010-a10e32366ce7",
  "pool": "rbd",
  "image": "w22-01-dr-disk-0",
  "syncUri": "rbd:rbd/w22-01-dr-disk-0",
  "runtimePath": "/dev/rbd/rbd/w22-01-dr-disk-0",
  "format": "raw",
  "virtualBytes": 107374182400,
  "locatorHash": "<sha256>"
}
```

`locatorHash`는 `schemaVersion`, `storageType`, `volumeUuid`, `pool`, `image`,
`format`, `virtualBytes`의 canonical JSON SHA-256이다. `syncUri`와 `runtimePath`는
그 구성요소에서 결정적으로 생성하며 hash 입력에 중복 포함하지 않는다.

QCOW2/file target은 `storageType=FILE`, absolute `syncUri`와 `runtimePath`를 사용한다.
상대 경로는 허용하지 않는다.

### 5.2 공통 함수

신규 `lib/ftctl/dr_storage_locator.sh`에 성공 경로의 로직을 추출한다.

```bash
ftctl_dr_storage_locator_from_disk_json <disk-json> <out-json>
ftctl_dr_storage_locator_sync_uri <locator-json> <out-var>
ftctl_dr_storage_locator_runtime_path <locator-json> <out-var>
ftctl_dr_storage_locator_validate <locator-json> <access-mode>
ftctl_dr_forward_target_map_ensure <plan> <profile> <generation> <out-path>
```

구현 원칙:

- `ftctl_dr_ablestack_rbd_spec_from_path()`의 인정 형식을 그대로 유지한다.
- `ftctl_dr_ablestack_target_uri_for_qemu()`의 `rbd:` 변환 결과를 그대로 유지한다.
- 기존 함수는 호환 wrapper로 남기고 내부에서 공통 함수를 호출한다.
- 문자열 조합을 mover마다 다시 구현하지 않는다.
- RBD pool은 `target.storagePath`, image는 `target.name` 또는 Cloud volume path에서
  결정한다. `storageRef` UUID를 pool 이름으로 사용하지 않는다.

## 6. Direction-scoped Map 설계

런타임 파일을 다음과 같이 분리한다.

```text
<plan>/maps/forward/source-vmware.json
<plan>/maps/forward/target-ablestack.json
<plan>/maps/reverse/source-ablestack.json
<plan>/maps/reverse/target-vmware.json
```

각 map은 다음 header를 가진다.

```json
{
  "schemaVersion": 2,
  "mapRole": "FORWARD_TARGET",
  "direction": "VMWARE_TO_KVM",
  "generation": 11,
  "profileSha256": "<sha256>",
  "materializationGeneration": 4,
  "disks": []
}
```

`ftctl_dr_forward_target_map_ensure()`는 파일 존재만 확인하지 않는다. role, direction,
profile hash, materialization generation, disk count, locator hash를 검증한다. 불일치하면
immutable profile에서 임시 파일로 재생성하고 `fsync + rename`으로 교체한다.

## 7. 파일별 변경 설계

### 7.1 `lib/ftctl/dr_ablestack.sh`

- canonical profile parsing은 유지한다.
- RBD spec/URI 생성 부분은 `dr_storage_locator.sh`를 호출한다.
- 최초 보호가 생성하는 target map을 Map V2 형식으로 기록한다.
- 기존 map reader는 schema v1을 읽되 즉시 v2 in-memory locator로 승격한다.

### 7.2 `lib/ftctl/dr_vmware.sh`

`ftctl_dr_vmware_replication_cycle()` 시작 전에 다음을 강제한다.

```bash
ftctl_dr_forward_target_map_ensure \
  "${plan}" "${profile_file}" "${materialization_generation}" target_disk_map
```

- `FTCTL_DR_TARGET_DISK_MAP`은 선택 값이 아니라 필수 값이다.
- map ensure 실패 시 mover를 시작하지 않는다.
- status에 map role/generation/hash/preflight state를 기록한다.

### 7.3 `lib/ftctl/dr_vmware_mover.sh`

- `ftctl_vmware_mover_disk_plan()`은 destination row를 target map에서만 읽는다.
- `source.targetDiskRef`와 `source.targetVmdkPath` fallback을 제거한다.
- `ftctl_vmware_mover_target_uri()`는 공통 locator wrapper로 교체한다.
- RBD인데 결과가 `rbd:`로 시작하지 않으면 `DR_FORWARD_TARGET_LOCATOR_INVALID`로
  fail-fast한다.
- qemu-img 실행 전 `qemu-img info --force-share --output=json <syncUri>`를 수행하고
  volume UUID/virtual size와 일치하는지 검증한다.

### 7.4 `lib/ftctl/dr_runtime.sh`

다음 상태 필드를 추가한다.

```text
forward_target_map_path
forward_target_map_generation
forward_target_map_sha256
forward_target_map_state
forward_target_map_error_code
post_failback_required_checkpoint_sequence
post_failback_completed_checkpoint_sequence
post_failback_protection_state
```

`disk_map_role` 단일 문자열은 호환 projection으로만 남긴다.

### 7.5 `lib/ftctl/dr_scheduler.sh`

- failback commit handoff 후 첫 정방향 주기를 `POST_FAILBACK_FORWARD_VERIFY`로 표시한다.
- sequence를 예약한 시점은 `ALLOCATED`, checkpoint commit 후만 `COMPLETED`이다.
- 첫 주기는 map preflight를 통과하기 전 VMware snapshot을 만들지 않는다.
- 완료 조건은 target durable, per-disk success, map generation/hash 일치이다.
- 실패 시 scheduler는 bounded retry 후 `PROTECTION_DEGRADED`를 기록한다.

### 7.6 `lib/ftctl/dr_failback.sh` 및 commit handoff

authority commit은 다음 값을 journal에 남긴다.

```text
resume_profile_sha256
resume_materialization_generation
resume_forward_target_map_sha256
required_post_failback_checkpoint_sequence
```

commit ACK는 authority 전환 성공을 의미한다. 보호 복구 완료는 별도 checkpoint gate로
판정한다.

## 8. Typed Error

| 코드 | 의미 | 재시도 |
|---|---|---|
| `DR_FORWARD_TARGET_MAP_MISSING` | profile로도 map을 만들 수 없음 | false |
| `DR_FORWARD_TARGET_MAP_ROLE_MISMATCH` | reverse/다른 role map 사용 | false |
| `DR_FORWARD_TARGET_MAP_STALE` | profile/materialization generation 불일치 | regenerate |
| `DR_FORWARD_TARGET_LOCATOR_INVALID` | RBD bare name 또는 불완전 locator | false |
| `DR_FORWARD_TARGET_VOLUME_NOT_FOUND` | canonical URI open 실패 | bounded |
| `DR_FORWARD_TARGET_IDENTITY_MISMATCH` | UUID/size/hash 불일치 | false |
| `DR_POST_FAILBACK_FORWARD_CYCLE_FAILED` | 재개 첫 주기 실패 | operator retry |

`qemu-img: No such file or directory` 원문만 노출하지 않고 locator error와 disk key를
status에 기록한다. 인증정보와 Ceph secret은 기록하지 않는다.

## 9. Self-test와 Preflight

### 9.1 FTCTL self-test

1. 최초 보호와 post-failback resume가 동일 profile에서 동일 locator hash를 만든다.
2. bare RBD image + pool metadata가 `rbd:<pool>/<image>`로 해석된다.
3. bare RBD image만 있고 pool이 없으면 fail-fast한다.
4. forward target map 부재 시 profile에서 재생성한다.
5. reverse map을 forward map으로 주입하면 role mismatch가 발생한다.
6. stale generation은 atomic regenerate 후 진행한다.
7. QCOW2 absolute path는 기존 동작을 유지한다.
8. map preflight 실패 시 VMware snapshot/mover가 시작되지 않는다.
9. sequence allocation만으로 completed checkpoint가 생성되지 않는다.
10. 첫 post-failback checkpoint가 durable할 때만 protection resume가 완료된다.

### 9.2 실환경 acceptance

1. 기존 profile로 forward target map을 dry-run 생성한다.
2. 모든 RBD target이 `rbd:` URI인지 확인한다.
3. `qemu-img info --force-share`로 각 URI를 연다.
4. target KVM VM이 stopped이고 source VMware VM이 powered on인지 확인한다.
5. failback 후 첫 정방향 주기를 실행한다.
6. `dr_sync_cycle`이 `COMPLETED`, `target_durable_at` non-null인지 확인한다.
7. 다음 주기가 CBT incremental이며 full reseed가 아닌지 확인한다.

## 10. 배포 호환성

FTCTL을 먼저 배포한다. 새 FTCTL은 map v1과 v2를 읽고, Cloud가 아직 locator contract를
보내지 않으면 기존 profile에서 v2를 생성한다. 이후 Agent/Cloud를 배포해 typed map
generation/hash를 전달한다. 구 FTCTL에 새 Cloud contract를 보내는 조합은 capability
gate로 차단한다.

## 11. AS-IS / TO-BE

| 영역 | AS-IS | TO-BE |
|---|---|---|
| RBD 규칙 | 최초 보호에서만 정규화 | 최초 보호와 재보호가 공통 resolver 사용 |
| target map | 있으면 사용, 없으면 생략 | profile에서 검증·재생성 후 필수 전달 |
| mover fallback | source의 bare `targetDiskRef` 사용 | destination locator만 사용, bare path 거부 |
| map 역할 | forward/reverse 파일 의미가 암묵적 | role/direction/generation/hash 명시 |
| sync/runtime 경로 | 한 필드에 혼재 | `syncUri`와 `runtimePath` 분리 |
| 재보호 완료 | scheduler/sequence 존재로 추정 | 첫 durable 정방향 checkpoint로 증명 |
| 실패 영향 | failback 성공처럼 보인 뒤 plan ERROR | authority 성공과 보호 degraded를 분리 표시 |
| 검증 | 역방향 commit 중심 | 왕복 후 첫 정방향 주기까지 PASS gate |

## 12. 권장 구현 순서와 완료 기준

1. 성공한 RBD helper를 공통 storage locator로 추출한다.
2. Map V2와 forward target-map ensure/self-test를 구현한다.
3. VMware mover의 source fallback을 제거하고 fail-fast를 추가한다.
4. failback handoff와 scheduler checkpoint gate를 연결한다.
5. Agent/Cloud typed contract와 capability를 반영한다.
6. Cloud DB/API/UI projection을 반영한다.
7. FTCTL, Agent/Cloud 순으로 빌드·배포한다.
8. 기존 실패 Plan을 cleanup하고 왕복 acceptance를 수행한다.

완료 기준은 페일백 commit 성공만이 아니다. 동일 Plan에서 post-failback 첫 정방향
checkpoint와 그 다음 CBT incremental checkpoint가 모두 durable하게 완료되어야 한다.
