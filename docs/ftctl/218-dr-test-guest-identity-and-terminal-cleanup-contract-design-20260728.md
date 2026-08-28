# 218. DR Test Guest Identity And Terminal Cleanup Contract Design

- 작성일: 2026-07-28
- 상태: 상세 설계 완료, 구현 대기
- 범위: `guestprep_manifest.py`, `guestprep.sh`, `dr_runtime.sh`,
  `dr_scheduler.sh`, FTCTL status contract
- Cloud 상위 설계:
  `ablestack-cloud/docs/ftctl/579-cross-hypervisor-dr-action-intent-guest-identity-and-failed-test-terminal-convergence-design-20260728.md`
- 관련 문서: 435, 438, 442

## 1. 결정

테스트 페일오버와 실제 페일오버는 하나의 guest identity resolver와 하나의
manifest schema를 사용한다. Test artifact의 disk locator를 만드는 부분만
provider-specific adapter로 분리한다.

테스트 작업의 실패 종결은 다음 네 결과를 하나의 transaction처럼 다룬다.

```text
guest preparation result
test artifact cleanup result
checkpoint lease release result
worker terminal result
```

어느 하나라도 확인되지 않으면 `cleanupRequired=true`이고, 모두 확인되면 원래
작업이 실패했더라도 `cleanupRequired=false`다.

## 2. 실환경에서 확인한 결함

Plan `2514a846-64a2-4bc7-ba88-38a874410782`의 profile에는 다음 값이 있다.

```text
mapping.source.vm.guestId=windows2019srvNext_64Guest
mapping.source.hardware.guestId=windows2019srvNext_64Guest
mapping.source.hardware.firmware=EFI
mapping.source.hardware.secureBoot=true
```

현재 `ftctl_guestprep_write_manifest()`의 test 전용 추출식은 첫 두 guest ID
경로를 읽지 않아 빈 값을 만든다. 동일 profile을
`guestprep_manifest.py build/validate`로 처리하면 다음 결과가 나온다.

```text
guestFamily=windows
firmware=efi
secureBoot=true
storage=rbd/raw
diskCount=2
ioPolicy=io_uring
ioThreads=true
```

실패 Run `ffa398ba-bfbd-4996-83f8-a6c58339e760`은 artifact session을
`CLEANED`로 기록했으나 다음 stale state를 남겼다.

```text
worker_state=RUNNING
worker_pid=3479488            # 실제 프로세스 없음
checkpoint_lease_state=LEASED
checkpoint-713.lease          # owner는 실패 Run
```

코드상 원인은 guest preparation 실패 후 `rc`를 다시 검사하지 않고 같은
`if` 블록에서 lease를 획득하는 것과, cleanup 결과를
`>/dev/null 2>&1 || true`로 버리는 것이다.

## 3. Canonical manifest tool

대상: `lib/ftctl/guestprep_manifest.py`

### 3.1 공통 resolver

현재 `source_vm(profile)`을 다음 모든 경로의 유일한 resolver로 승격한다.

```text
build cutover manifest
inspect guest identity
build test artifact manifest
validate manifest
```

우선순위는 다음과 같다.

```python
guest_id = first(
    mapping.source.vm.guestId,
    mapping.source.hardware.guestId,
    mapping.source.workload.guestId,
    mapping.source.guestId,
    source.guestId,
)
```

firmware, Secure Boot, CPU, memory도 동일 함수에서 계산한다. guest family를
해석하지 못하면 `DR_GUEST_OS_UNRESOLVED`와 확인한 JSON path 목록을 반환한다.

### 3.2 신규 subcommand

```text
guestprep_manifest.py inspect --session <test-session.json>
guestprep_manifest.py build-test --session <test-session.json> \
  --domain <name> --output <manifest.json>
```

`inspect` 출력:

```json
{
  "result": "ok",
  "guestFamily": "windows",
  "guestId": "windows2019srvNext_64Guest",
  "firmware": "efi",
  "secureBoot": true,
  "requiredPreparation": "WINPE"
}
```

`build-test`는 `session.profile`을 `source_vm()`에 전달하고
`session.testArtifacts.records`를 disk adapter에 전달한다. 현재
`guestprep.sh`의 inline Python manifest builder는 제거한다.

### 3.3 Validation

`validate_manifest()`는 test/cutover 공통으로 다음을 검사한다.

- schema version
- guest family와 guest ID
- EFI/Secure Boot 조합
- disk count와 size
- provider locator
- root disk controller
- `ioPolicy`, 기본값 `io_uring`
- `ioThreads`, 기본값 `true`

## 4. Artifact 생성 전 Preflight

대상: `lib/ftctl/guestprep.sh`

신규 함수:

```bash
ftctl_guestprep_preflight_test_session() {
  local session_path="$1" run_path="$2"
  # 1. canonical inspect
  # 2. v2k library 확인
  # 3. Windows이면 WinPE/VirtIO ISO 확인
  # 4. 결과를 run_path에 기록
}
```

Windows ISO 검증:

```text
readable regular file 또는 유효 symlink
resolved file size > 0
ISO9660 descriptor 확인 가능
WinPE와 VirtIO ISO가 서로 다른 파일
```

호스트에서 확인한 현재 파일은 다음과 같다.

```text
/usr/share/ablestack/v2k/winpe/winpe-ablestack-v2k-amd64.iso
  399,939,584 bytes
/usr/share/virtio-win/virtio-win.iso
  -> virtio-win-1.9.49.iso
```

Preflight 실패 시 RBD snapshot/clone 또는 qcow2 overlay를 생성하지 않는다.

## 5. `guestprep.sh` 변경

### 5.1 제거 대상

```text
ftctl_guestprep_write_manifest() 내부의 독립 inline Python parser
test와 cutover에 중복된 guest family 판정 입력 생성
```

`ftctl_guestprep_detect_family()`은 canonical manifest의
`source.vm.guestFamily`만 우선 사용한다. 디스크 inspection fallback은 legacy
profile 호환 모드에서만 허용하고 경고 이벤트를 남긴다.

### 5.2 Test prepare 순서

```text
inspect profile
validate tool/ISO
materialize writable artifacts
build-test manifest
validate manifest/provider objects
run offline guest preparation
publish TEST_ARTIFACTS_READY
acquire checkpoint lease
publish TEST_ACTIVE transition
```

Cloud-managed test mode에서는 FTCTL이 직접 고객 VM을 define/start하지 않는다.
`ftctl_guestprep_prepare_and_start()`는 compatibility mode로만 유지하고 capability
negotiation 없이는 호출하지 않는다.

## 6. Failure finalizer

대상: `lib/ftctl/dr_runtime.sh`

신규 함수:

```bash
ftctl_dr_runtime_finalize_test_failure \
  "$plan" "$run" "$run_path" "$status_path" "$primary_rc" "$error_code"
```

처리 순서:

1. active test session과 owned artifact 목록 snapshot
2. guest preparation 임시 mapping 해제
3. test domain이 있으면 compatibility ownership 확인 후 제거
4. RBD clone/qcow2 overlay 제거
5. artifact directory 제거 확인
6. lease 파일의 `run=`이 현재 Run과 일치할 때만 lease 해제
7. scheduler transition rollback/resume
8. worker terminal field 기록
9. 하나의 atomic status publish

primary failure code는 보존한다. cleanup 실패가 있으면 다음 구조를 추가한다.

```text
error_code=DR_GUEST_OS_UNRESOLVED
cleanup_error_code=DR_TEST_CLEANUP_PARTIAL
cleanup_required=true
```

cleanup이 성공하면:

```text
state=ERROR
worker_state=FAILED
worker_exit_code=<primary rc>
test_session_state=FAILED
test_artifacts_state=CLEANED
checkpoint_lease_state=RELEASED
cleanup_state=COMPLETED
cleanup_required=false
```

### 6.1 현재 제어 흐름 수정

현재 구조:

```bash
if [[ "$rc" == 0 ]]; then
  guestprep || rc=$?
  acquire_lease
fi
```

목표 구조:

```bash
if [[ "$rc" == 0 ]]; then
  guestprep || rc=$?
fi
if [[ "$rc" == 0 ]]; then
  acquire_owned_lease || rc=$?
fi
if [[ "$rc" != 0 ]]; then
  finalize_test_failure ...
fi
```

## 7. Owned lease 계약

대상: `lib/ftctl/dr_scheduler.sh`

신규 함수:

```bash
ftctl_dr_scheduler_checkpoint_lease_release_owned \
  "$plan" "$sequence" "$run"
```

lease 파일에서 plan/run/sequence를 확인한다. 다른 active Run 소유 lease는
삭제하지 않고 `DR_CHECKPOINT_LEASE_OWNER_MISMATCH`를 반환한다.

lease 획득도 기존 파일이 있으면 owner와 상태를 확인하고 같은 Run의 retry만
idempotent하게 허용한다.

## 8. Atomic state publish

Run state와 Plan status를 순서대로 복사하면서 중간 상태가 노출되지 않도록
temporary file + `mv`를 사용하는 공통 함수로 통합한다.

```bash
ftctl_dr_runtime_publish_terminal_snapshot "$run_path" "$status_path" \
  "state=ERROR" \
  "worker_state=FAILED" \
  "worker_exit_code=$rc" \
  "test_artifacts_state=$artifact_state" \
  "checkpoint_lease_state=$lease_state" \
  "cleanup_required=$cleanup_required"
```

terminal snapshot에서 금지되는 조합:

```text
state in {ERROR, FAILED} and worker_state=RUNNING
cleanup_required=false and checkpoint_lease_state=LEASED
test_artifacts_state=CLEANED and artifact path still exists
worker_state=FAILED and worker_exit_code empty
```

## 9. Status와 Agent 계약

`dr-status --json`에 다음 최상위 필드를 안정적으로 제공한다.

```text
test_session_state
test_artifacts_state
test_artifact_count
test_cleanup_state
cleanup_required
guest_family
worker_state
worker_exit_code
checkpoint_lease_state
```

내부 absolute artifact path와 credential은 Cloud/UI에 보내지 않는다.
필요한 경우 status JSON 내부 운영 진단 영역에만 저장하고 API compact projection에서
제거한다.

## 10. Self-test

대상:

- `tests/ftctl/test_guestprep_manifest.py`
- `tests/ftctl/test_dr_runtime_test_failure.sh`
- `tests/ftctl/test_dr_checkpoint_lease.sh`

필수 fixture:

1. `mapping.source.vm.guestId`만 있는 Windows
2. `mapping.source.hardware.guestId`만 있는 Windows
3. workload 경로만 있는 legacy Linux
4. guest identity가 모두 비어 있는 profile
5. EFI + Secure Boot + RBD/raw 2 disks
6. guestprep rc 48
7. artifact cleanup 일부 실패
8. lease owner mismatch
9. scheduler resume 실패

assertion:

```text
preflight failure -> artifact create call count 0
guestprep failure -> lease acquire call count 0
post-lease failure -> owned lease absent
terminal ERROR -> worker FAILED and exit code present
cleanup complete -> cleanup_required=false
cleanup partial -> cleanup_required=true
```

## 11. 배포 검증

로컬 source와 설치 파일 hash가 달랐으므로 다음을 배포 gate로 둔다.

```text
Git commit SHA
GitHub Actions run ID
downloaded RPM SHA256
installed package version
installed guestprep.sh SHA256
installed dr_runtime.sh SHA256
installed guestprep_manifest.py SHA256
```

설치 파일에는 다음 marker가 있어야 한다.

```text
build-test
inspect
ftctl_dr_runtime_finalize_test_failure
ftctl_dr_scheduler_checkpoint_lease_release_owned
DR_GUEST_OS_UNRESOLVED
```

## 12. Implementation Result (2026-07-28)

The implementation follows the contract above.

| Area | Implemented result |
|---|---|
| Canonical guest identity | `guestprep_manifest.py inspect`, `build-test`, and cutover use the same `source_vm()` resolver |
| Test manifest | `guestprep.sh` delegates manifest creation to `guestprep_manifest.py build-test` |
| Preflight ordering | Guest identity, v2k library, WinPE ISO, and VirtIO ISO checks run before test artifact materialization |
| Disk contract | Test disks retain target RBD/raw mapping, `ioPolicy=io_uring`, and configured IO threads |
| Lease ordering | Checkpoint lease acquisition runs only after guest preparation succeeds |
| Lease release | `ftctl_dr_scheduler_checkpoint_lease_release_owned()` releases only a matching plan/sequence/run owner |
| Failure convergence | The test failure finalizer cleans owned artifacts, releases an owned lease, resumes the scheduler, and writes terminal worker state |
| Typed status | Test session, artifacts, artifact count, cleanup state, cleanup-required flag, worker state, exit code, and lease state are published |

Implemented files:

```text
lib/ftctl/guestprep_manifest.py
lib/ftctl/guestprep.sh
lib/ftctl/dr_scheduler.sh
lib/ftctl/dr_runtime.sh
tests/ftctl/guestprep_manifest_test.py
```

Local verification:

```text
guestprep_manifest_test.py: 3 passed
python py_compile: PASS
bash -n guestprep.sh: PASS
bash -n dr_scheduler.sh: PASS
bash -n dr_runtime.sh: PASS
git diff --check: PASS
```

Deployment remains gated by the qemu-exec-tools GitHub Actions RPM build and
installed-file marker/hash verification.

## 13. AS-IS / TO-BE

| 항목 | AS-IS | TO-BE |
|---|---|---|
| guest identity | test inline parser와 cutover parser 분리 | `source_vm()` 단일 resolver |
| Windows 판정 | 정상 guestId가 있어도 empty | canonical path 우선순위 |
| preflight 시점 | artifact 생성 뒤 | artifact 생성 전 |
| test manifest | shell 내부 Python | `guestprep_manifest.py build-test` |
| lease 획득 | guestprep 실패 후에도 실행 가능 | 성공 재검증 후 실행 |
| lease 해제 | 파일 경로만으로 삭제 | owner 검증 후 idempotent 해제 |
| cleanup 결과 | stdout/rc 폐기 | 구조화 proof로 publish |
| terminal worker | 사망 PID + RUNNING 가능 | FAILED + exit code |
| 오류 표현 | unsupported로 오분류 | unresolved와 runtime unavailable 분리 |
| 배포 일치 | source/install drift 탐지 없음 | SHA256 provenance gate |

## 14. Guest preparation preflight evidence contract

Test Failover must not collapse every guest preparation prerequisite failure
into `DR_GUEST_PREP_RUNTIME_UNAVAILABLE`. Before any test disk is copied or a
Cloud test VM is created, FTCTL records a structured preflight result in the
owning Run and exposes it through `dr-status`.

Required fields are `guest_preflight_state`,
`guest_preflight_error_code`, and `guest_preflight_error_message`. The
specific error code is also promoted to the Run-level `error_code` so Cloud
and the UI display the same cause.

| Code | Meaning |
| --- | --- |
| `DR_GUEST_PREP_SESSION_MISSING` | selected test session is absent or unreadable |
| `DR_GUEST_PREP_MANIFEST_TOOL_MISSING` | `guestprep_manifest.py` is not installed |
| `DR_GUEST_PREP_V2K_RUNTIME_MISSING` | required v2k runtime scripts are not installed |
| `DR_GUEST_PREP_PROFILE_INVALID` | session profile is malformed |
| `DR_GUEST_OS_UNRESOLVED` | source guest identity cannot be resolved |
| `DR_GUEST_PREP_WINPE_ISO_MISSING` | required Windows WinPE ISO is absent |
| `DR_GUEST_PREP_VIRTIO_ISO_MISSING` | required Windows virtio ISO is absent |

Linux plans never require either Windows ISO. A Rocky Linux SharedMountPoint
plan with a valid profile, manifest tool, and v2k runtime must pass preflight
without ISO files. Test artifact materialization remains after this barrier.

| Area | AS-IS | TO-BE |
| --- | --- | --- |
| FTCTL failure | generic exit 47 | exact prerequisite code and message |
| Cloud projection | generic runtime/ISO message | preserves FTCTL error code and message |
| UI | accepted request later becomes an opaque failure | shows the exact failed prerequisite in execution history |
| Regression | Linux can be confused with Windows ISO readiness | Linux no-ISO, missing-v2k, and malformed-profile smoke cases |
