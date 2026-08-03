# 447. FTCTL DR Target Materialization Ownership Manifest Contract Design

- 작성일: 2026-08-03
- 상태: 상세 코드 설계 완료, 구현 대기
- Cloud 상위 설계:
  `ablestack-cloud/docs/ftctl/590-cross-hypervisor-dr-plan-async-mutation-and-target-resource-ownership-design-20260803.md`
- 관련 문서: 201, 210, 436, 445, 446

## 1. 목적과 역할 경계

Cloud가 다른 DR 계획의 VM/볼륨을 잘못 materialize한 경우 FTCTL까지 `READY`로
수렴하지 않도록 `dr-target-materialized` 계약을 강화한다.

역할은 다음과 같이 고정한다.

| 구성요소 | 책임 |
| --- | --- |
| Cloud | VM/volume/artifact 소유권 claim, lifecycle, 삭제/보존 결정 |
| Mold Agent | libvirt domain, 전원 상태, disk locator 실측 |
| FTCTL | manifest schema, generation, digest, runtime monotonicity 검증 |

FTCTL은 Cloud DB 소유권을 독자적으로 재판정하지 않는다. 반대로 Cloud가 전달한
target reference를 검증 없이 신뢰해 READY를 쓰지도 않는다.

## 2. 현재 문제

현재 `ftctl_dr_runtime_target_materialized()`는 target VM id 또는 external ref가
존재하면 다음 값을 바로 기록한다.

```text
state=READY
target_vm_present=true
target_storage_present=true
target_network_present=true
target_materialized=true
```

plan UUID, replica UUID, ownership generation, disk binding digest, Agent가 관측한 실제
전원 상태를 검증하지 않는다. 따라서 Cloud의 잘못된 VM 재사용이 FTCTL READY로
확대된다.

## 3. CLI contract v2

```text
ablestack_vm_ftctl dr-target-materialized \
  --plan <plan-uuid> \
  --run <run-uuid> \
  --materialization-spec-json <path> \
  --materialization-spec-sha256 sha256:<digest> \
  --json
```

contract v2가 활성화된 환경에서는 다음 loose 인자만으로 실행하는 경로를 거부한다.

```text
--target-vm-id
--target-external-ref
--target-volume-map-json
```

이 인자는 v2 manifest에서 파생되는 read-only compatibility output으로만 남긴다.

## 4. Manifest schema

```json
{
  "contractVersion": 2,
  "planUuid": "...",
  "runUuid": "...",
  "replicaUuid": "...",
  "ownershipGeneration": 1,
  "activeSide": "SOURCE",
  "target": {
    "claimUuid": "...",
    "cloudVmId": 300,
    "vmUuid": "...",
    "instanceName": "i-2-300-VM",
    "displayName": "w22-01-dr",
    "expectedPowerState": "POWERED_OFF",
    "observedPowerState": "POWERED_OFF",
    "observedAt": "2026-08-03T15:00:00+09:00"
  },
  "disks": [
    {
      "diskKey": "2000",
      "claimUuid": "...",
      "cloudVolumeId": 600,
      "volumeUuid": "...",
      "artifactUuid": "...",
      "provider": "RBD",
      "replicationLocator": "rbd/w22-plan-uuid-disk-0",
      "runtimeLocator": "/dev/rbd/rbd/w22-plan-uuid-disk-0",
      "capacityBytes": 107374182400
    }
  ],
  "observedDiskDigest": "sha256:..."
}
```

JSON canonicalization은 UTF-8, key sort, compact separator를 사용한다.

```python
json.dumps(payload, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
```

## 5. Shell 구현 설계

### 5.1 신규 함수

`lib/ftctl/dr_runtime.sh`:

```text
ftctl_dr_runtime_load_materialization_manifest
ftctl_dr_runtime_validate_materialization_manifest_v2
ftctl_dr_runtime_materialization_manifest_digest
ftctl_dr_runtime_validate_materialization_generation
ftctl_dr_runtime_commit_materialization_manifest
```

`bin/ablestack_vm_ftctl.sh`:

```text
CLI_MATERIALIZATION_SPEC_JSON
CLI_MATERIALIZATION_SPEC_SHA256
--materialization-spec-json
--materialization-spec-sha256
```

### 5.2 검증 순서

```text
1. manifest file regular-file/permission/size 검사
2. canonical SHA-256 재계산
3. contractVersion == 2
4. CLI plan/run == manifest plan/run
5. replicaUuid, ownershipGeneration, target claim 필수값 검사
6. expectedPowerState == observedPowerState
7. disks non-empty, claimUuid/locator/capacity 필수값 검사
8. observedDiskDigest 재계산 결과 검사
9. 기존 runtime generation/digest와 monotonic 비교
10. 임시 파일에 상태 기록 후 atomic rename
```

### 5.3 generation 규칙

| 조건 | 결과 |
| --- | --- |
| incoming generation < current | `DR_TARGET_MATERIALIZATION_STALE` |
| generation == current, digest == current | idempotent success |
| generation == current, digest != current | `DR_TARGET_OWNERSHIP_CONFLICT` |
| generation > current | 검증 후 commit |

## 6. Runtime 상태

성공 시 다음을 기록한다.

```text
materialization_contract_version=2
materialization_generation=<n>
materialization_manifest_sha256=sha256:<digest>
target_ownership_state=VALID
target_claim_uuid=<uuid>
target_replica_uuid=<uuid>
target_vm_id=<id>
target_external_ref=<uuid>
target_instance_name=<instance>
target_power_state=<observed>
target_power_observed_at=<time>
target_disk_digest=sha256:<digest>
target_materialized=true
target_vm_present=true
target_storage_present=true
state=READY
step=target-ready
```

실패 시 기존 성공 runtime을 덮어쓰지 않고 run status에 typed error만 기록한다.

## 7. Error/exit contract

| exit | error code | 의미 |
| --- | --- | --- |
| 2 | `DR_TARGET_MATERIALIZATION_SPEC_INVALID` | schema/필수값 오류 |
| 78 | `DR_TARGET_OWNERSHIP_CONFLICT` | claim 또는 같은 generation digest 충돌 |
| 79 | `DR_TARGET_MATERIALIZATION_STALE` | 오래된 generation/run |
| 80 | `DR_TARGET_VM_POWER_STATE_MISMATCH` | expected/observed power 불일치 |
| 81 | `DR_TARGET_DISK_MANIFEST_MISMATCH` | disk locator/digest 불일치 |

모든 JSON error에는 `retryable=false`를 기본으로 한다. stale status refresh만
idempotent 재조회 대상이며 자동 재물질화하지 않는다.

## 8. Capability contract

`dr-capabilities --json`에 다음을 추가한다.

```json
{
  "actions": {
    "TARGET_MATERIALIZED": "dr-target-materialized"
  },
  "contracts": {
    "targetMaterialization": {
      "version": 2,
      "manifestSha256": true,
      "ownershipGeneration": true,
      "observedPowerState": true,
      "diskDigest": true
    }
  }
}
```

Cloud는 version 2가 아니면 materialization을 차단한다. 자동 v1 downgrade는 없다.

## 9. librbd/krbd 정규화

복제 중 FTCTL은 librbd locator를 사용하고, Cloud VM 실행 XML은 krbd block device를
사용할 수 있다. 두 문자열이 다르다는 이유만으로 mismatch로 판정하지 않는다.

다음 canonical tuple을 비교한다.

```text
provider=RBD
pool=<ceph pool>
image=<image name>
snapshot=<optional snapshot>
```

예:

```text
rbd:w22-plan-disk-0
/dev/rbd/rbd/w22-plan-disk-0
```

둘 다 `(RBD, rbd, w22-plan-disk-0, null)`로 정규화해야 한다.

## 10. Selftest 설계

`bin/ablestack_vm_ftctl_selftest.sh`에 다음 case를 추가한다.

```text
target_materialization_v2_accepts_valid_manifest
target_materialization_v2_is_idempotent
target_materialization_v2_rejects_stale_generation
target_materialization_v2_rejects_digest_conflict
target_materialization_v2_rejects_power_mismatch
target_materialization_v2_rejects_disk_digest_mismatch
target_materialization_v2_normalizes_librbd_and_krbd
target_materialization_v2_preserves_previous_ready_on_rejection
```

## 11. AS-IS / TO-BE

| 항목 | AS-IS | TO-BE |
| --- | --- | --- |
| 입력 | loose VM/volume 인자 | versioned canonical manifest |
| 소유권 | target ref 존재만 확인 | claim UUID, replica UUID, generation 검증 |
| 전원 | 검증하지 않음 | Agent observed power 필수 |
| 디스크 | JSON을 그대로 저장 | normalized locator digest 검증 |
| 재시도 | 이전 상태를 덮어쓸 수 있음 | generation monotonic + digest idempotency |
| 실패 | READY 오염 가능 | 기존 READY 보존, typed run error 기록 |
| 호환 | 느슨한 v1 허용 | capability v2 없으면 Cloud 단계에서 차단 |

## 12. 결론

FTCTL의 `READY`는 단순히 Cloud가 target id를 전달했다는 뜻이 아니라, Cloud claim,
Agent 실측, FTCTL runtime 세대가 같은 materialization manifest에 동의했다는 뜻이어야
한다. 이 계약은 Cloud의 소유권 결함을 대신하지 않지만, 결함이 실행 가능한 DR
상태로 확대되는 마지막 경계를 차단한다.

## 13. Implementation verification (2026-08-03)

Implemented in `ablestack_vm_ftctl.sh` and `dr_runtime.sh`:

- `--materialization-spec-json` and `--materialization-spec-sha256` CLI inputs
- contract version, plan/run, replica/generation, VM identity, power-state, and disk-map validation
- SHA-256 verification before any READY state mutation
- monotonic ownership generation and same-generation digest conflict checks
- runtime persistence of contract version, replica id, generation, manifest digest, disk digest, and observed power state
- capability features `target-materialization-manifest-v2` and `target-resource-ownership-generation-v1`

The focused self-test `selftest_case_dr_target_materialization_manifest_v2` verifies:

1. a valid v2 manifest reaches READY;
2. a stale generation exits with code 79 and `DR_MATERIALIZATION_STALE_GENERATION`;
3. a mismatched disk map exits with code 81 and `DR_MATERIALIZATION_DISK_MAP_MISMATCH`.
