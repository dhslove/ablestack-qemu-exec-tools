# FTCTL DR Test Artifact Canonical Locator And Failure Contract Design

- Date: 2026-07-19
- Status: implemented and real-environment verified; Cloud terminal convergence correction pending
- Scope: `dr-test-prepare` and `dr-test-artifact-cleanup`
- Cloud normative design: `ablestack-cloud/docs/ftctl/562-cross-hypervisor-dr-test-artifact-contract-and-projection-isolation-design-20260719.md`
- Cloud terminal design: `ablestack-cloud/docs/ftctl/563-cross-hypervisor-dr-test-failover-terminal-convergence-design-20260720.md`

> Normative guest identity and terminal cleanup correction (2026-07-28):
> `218-dr-test-guest-identity-and-terminal-cleanup-contract-design-20260728.md`
> replaces the test-only inline guest parser and defines owner-checked lease
> release plus atomic failed-operation cleanup proof.

## 1. Engine boundary

Cloud owns the Test Session, temporary volumes, temporary VM, network,
placement, and customer workload lifecycle. FTCTL owns only:

- committed checkpoint selection and lease;
- provider-specific writable test artifacts;
- offline guest preparation on those artifacts;
- artifact manifest and cleanup;
- scheduler quiesce/resume around the storage transaction.

FTCTL must never create or control the Cloud customer test VM. It must never
infer a storage provider from a display name or a bare disk reference.

## 2. Current defect

`ftctl_dr_runtime_materialize_test_artifacts()` currently selects:

```python
target_path = disk.get("targetPath") or disk.get("targetDiskRef")
```

Only `rbd:` and `/dev/rbd/` prefixes are recognized as RBD. The real Cloud RBD
volume `Rokcy10-1-dr-disk-0` was therefore passed to `qemu-img -b` as a local
relative file and Test Failover failed before Cloud VM creation.

The failure also returned generic rc `1`, was mislabeled
`DR_RESTORE_POINT_NOT_FOUND`, and skipped cleanup because cleanup was gated on
`rc >= 46`.

## 3. Required CLI contract

`dr-test-prepare` adds:

```text
--artifact-spec-json <root-only-json-file>
```

For `test-artifact-v3`, this argument is mandatory. The file is validated by
the Agent and contains no credentials.

Example:

```json
{
  "schemaVersion": 3,
  "planUuid": "plan-uuid",
  "runUuid": "run-uuid",
  "checkpointRef": "ftctl:plan:sync-run:53",
  "checkpointSequence": 53,
  "disks": [
    {
      "diskIndex": 0,
      "device": "2000",
      "provider": "RBD",
      "pool": "rbd",
      "image": "Rokcy10-1-dr-disk-0",
      "canonicalLocator": "rbd:rbd/Rokcy10-1-dr-disk-0",
      "format": "raw",
      "virtualSizeBytes": 107374182400
    }
  ]
}
```

## 4. Function split

Replace the inference-heavy body with:

```text
ftctl_dr_test_spec_validate
ftctl_dr_test_source_preflight
ftctl_dr_test_rbd_create
ftctl_dr_test_file_create
ftctl_dr_test_manifest_publish
ftctl_dr_test_artifacts_cleanup
```

### 4.1 Validation

`ftctl_dr_test_spec_validate` verifies:

- schema, Plan, Run, checkpoint identity;
- unique contiguous disk indices;
- provider is `RBD` or `FILE_QCOW2`;
- RBD pool/image and locator agree exactly;
- file locator is absolute and already normalized by Agent;
- format and positive virtual size are present;
- no credentials, shell fragments, snapshots, or clone names are supplied.

### 4.2 RBD preflight and create

Use librbd-backed `rbd` operations only.

```text
rbd info <pool>/<image>
rbd snap create <pool>/<image>@<generated-snapshot>
rbd snap protect <pool>/<image>@<generated-snapshot>
rbd clone <pool>/<image>@<generated-snapshot> <pool>/<generated-clone>
rbd info <pool>/<generated-clone>
```

Generated names are Plan/Run/disk scoped and never accepted from API input.
Rollback order is clone remove, snapshot unprotect, snapshot remove.

### 4.3 File preflight and create

The source must be an absolute regular file and its canonical path must remain
under the Agent-validated storage root. A qcow2 overlay is allowed only when
the backing checkpoint is immutable for the test lifetime. Otherwise use a
reflink/copy or return `DR_TEST_STORAGE_ISOLATION_UNSUPPORTED`.

## 5. Artifact journal

Write a durable journal entry immediately after each side effect.

```json
{
  "diskIndex": 0,
  "provider": "RBD",
  "state": "CREATED",
  "source": "rbd:rbd/Rokcy10-1-dr-disk-0",
  "snapshot": "ftctl-drtest-...",
  "artifact": "rbd:rbd/Rokcy10-1-dr-disk-0-ftctl-test-...",
  "cleanupToken": "opaque-plan-run-disk-token"
}
```

The journal is the cleanup source of truth. Cleanup does not reconstruct names
from display labels.

## 6. Error and cleanup contract

| Exit | Error code | Retry |
|---:|---|---|
| 46 | `DR_TEST_MATERIALIZATION_FAILED` | no, after cleanup |
| 53 | `DR_TEST_SOURCE_LOCATOR_INVALID` | no |
| 54 | `DR_TEST_SOURCE_UNREACHABLE` | policy-dependent |
| 55 | `DR_TEST_ARTIFACT_ROLLBACK_FAILED` | cleanup retry required |
| other | `DR_ENGINE_ACTION_FAILED` | no implicit restore-point mapping |

Every failure includes a sanitized non-empty `error_message`. The string `OK`
is invalid when state is `ERROR` or `FAILED`.

After the test session file exists, all nonzero exits execute:

1. artifact rollback from journal;
2. checkpoint lease release if acquired;
3. scheduler resume;
4. terminal failure evidence publication;
5. transient active-session pointer removal.

The terminal session record remains until Cloud confirms or requests cleanup.

Scheduler resume is a recovery operation, not only a control-message write. If
the former continuous-sync worker is no longer alive, FTCTL first starts and
verifies an owned worker from the persisted Plan profile and the latest durable
checkpoint producer Run, then sends the generation-scoped `run` command and
waits for the matching `RUNNING` ACK. The finite cleanup Run never becomes the
producer of later checkpoints. A missing worker can therefore never be
represented as a successful cleanup with `PAUSED` or `QUIESCED` control state.

## 7. Status isolation

Finite Test Failover state must not overwrite Plan-wide protection authority.

```text
status.state                 protection authority only
runs/<run>.state             finite operation only
test-sessions/<run>.json     artifact session only
```

`dr-status --run <test-run>` returns both `operation` and `protection` objects.
The protection object retains the sync scheduler Run UUID and latest completed
checkpoint even when the test operation fails.

Checkpoint events and manifests retain their producer sync Run UUID. A test
operation never becomes the producer of later scheduler checkpoints.

## 8. Read-only preflight evidence

The actual failed target was checked without mutation.

```text
rbd info rbd/Rokcy10-1-dr-disk-0
  PASS, RBD format 2, 100 GiB, layering enabled

qemu-img info rbd:rbd/Rokcy10-1-dr-disk-0
  PASS, raw, 100 GiB

rbd snap ls rbd/Rokcy10-1-dr-disk-0
  []
```

This proves the canonical locator is readable by the installed librbd/qemu
stack. Positive clone creation must be tested later on a disposable image, not
the permanent replica image.

## 9. Source change map

| File | Change |
|---|---|
| `bin/ablestack_vm_ftctl` | parse and require `--artifact-spec-json` for v3 |
| `lib/ftctl/dr_runtime.sh` | strict provider dispatch, journal, error mapping, cleanup |
| `lib/ftctl/guestprep.sh` | consume prepared artifact refs only |
| FTCTL self-tests | locator validation, rollback injection, status isolation |

## 10. Acceptance

PASS requires:

- a bare display name is rejected before scheduler quiesce;
- canonical RBD creates a protected snapshot and clone;
- injected failures leave no snapshot, clone, lease, or active pointer;
- scheduler resumes after all failure classes;
- cleanup restarts a missing scheduler worker before publishing `READY`;
- status reports the failed operation without changing protection authority;
- Cloud can consume the published manifest and create its own test VM;
- cleanup is idempotent when called repeatedly.

## 11. AS-IS / TO-BE

| Area | AS-IS | TO-BE |
|---|---|---|
| Input | checkpoint disk label/ref | Agent-validated typed v3 artifact spec |
| RBD detection | prefix inference | explicit provider plus pool/image contract |
| RBD access | bare name can fall into file path | librbd-backed RBD transaction only |
| File access | relative path possible | validated absolute immutable source only |
| Failure | rc 1 becomes restore point not found | explicit materialization/locator error |
| Cleanup | only selected exit codes | all post-session failures rollback |
| Scheduler recovery | cleanup can wait on a dead worker | ensure owned worker, then require `RUNNING` ACK |
| Status | operation can overwrite Plan state | operation and protection stored separately |
| VM authority | compatibility path may start a domain | Cloud exclusively owns customer test VM |

## 12. Real-environment verification and authority boundary - 2026-07-20

The v3 RBD contract passed a real Test Failover preparation for Plan
`cbdf5abe-2795-4e7c-9995-78a67129b0de`, Run
`5d44ebc4-3bde-46d1-a706-353cfd878f60`.

| Check | Result |
|---|---|
| FTCTL state | `TEST_ARTIFACTS_READY`, progress 100 |
| Worker | `SUCCEEDED`, exit 0 |
| Checkpoint | sequence 19 leased |
| RBD | protected snapshot and Plan/Run-scoped clone present |
| Guest preparation | Linux `READY` |
| Cloud import | test volume created from the clone |
| Cloud VM | created and Running with secure OVMF and `io_uring` |

The remaining nonterminal Cloud Run is not an FTCTL failure. FTCTL must retain
`TEST_ARTIFACTS_READY`, `TEST_ACTIVE`, and the checkpoint lease until explicit
artifact cleanup. It must not add a Cloud-VM-running state or complete the
Cloud Run because Cloud owns volume import, VM start, and boot validation.

Cloud document 563 is normative for monotonic `DrTestSession` transitions and
finite Run completion. No FTCTL behavior change is required for that correction.

## 13. Cleanup Resume Projection Boundary - 2026-07-21

Artifact cleanup success and scheduler resume are confirmed separately. The
cleanup action releases the checkpoint lease and obtains an identity-bearing
RUNNING ACK, while the next normal producer checkpoint proves resumed data
protection. A cleanup Run never owns that checkpoint.

FTCTL status must therefore expose the cleanup operation and Plan protection as
separate envelopes. The normative engine contract is document 437; the Cloud
projection contract is document 565.
