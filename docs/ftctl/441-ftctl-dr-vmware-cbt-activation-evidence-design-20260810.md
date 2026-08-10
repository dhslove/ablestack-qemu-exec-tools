# FTCTL DR VMware CBT Activation Evidence Design

## 1. Purpose

This document closes the CBT auto-enable gap found while creating DR plan
`d9ba2979-1f2f-4819-8784-ce26fc0aad00` for VMware VM `w25-01`
(`vm-18049`). The initial sync failed before data transfer with
`DR_VMWARE_CBT_VERIFY_FAILED`.

The design applies to the VMware to KVM forward replication path. It does not
change the already successful path for a VM whose selected disks already
produce valid CBT change IDs.

Live transfer observability after CBT activation is defined separately in
`442-ftctl-dr-live-transfer-progress-contract-design-20260810.md`. That
document is normative for in-flight bytes, percentage, throughput, ETA, and
stalled-transfer detection; this document remains normative for CBT readiness.

## 2. Failure Evidence

The failed run was `df40cd82-ac55-473e-a4e0-4a1dc94592d7`.

| Evidence | Value |
| --- | --- |
| FTCTL step | `vmware-cbt-preflight` |
| worker exit | `79` |
| transferred bytes | `0` |
| target VM | not created |
| restore point | not created |
| VM power state | `poweredOn` |
| `config.changeTrackingEnabled` | `false` |
| VM ExtraConfig `ctkEnabled` | `true` after FTCTL command |
| disk ExtraConfig `scsi0:0.ctkEnabled` | `true` |
| pre-existing snapshot | none |

The deployed implementation writes CBT ExtraConfig and immediately requires
`config.changeTrackingEnabled=true`. The VM-level property remained false, so
the worker terminated even though the disk configuration had been accepted.

## 3. Live Preflight Result

The following non-memory, non-quiesced temporary snapshot tests were performed
on the same powered-on VM on 2026-08-10. Every temporary snapshot was removed.

1. Create `ftctl-cbt-activation-preflight-20260810`.
2. Verify `w25-01-ctk.vmdk` and snapshot CTK files were created.
3. Remove the snapshot and verify no snapshot remained.
4. Create `ftctl-cbt-query-preflight-20260810`.
5. Resolve a non-empty disk change ID for `scsi0:0`.
6. Call `QueryChangedDiskAreas` with that change ID.
7. Verify the query succeeded and remove the snapshot.

Observed change ID:

```text
52 88 fe 27 93 f2 f1 ce-d3 3e 51 b0 ff 84 3e 59/5
```

Important conclusion:

- `config.changeTrackingEnabled` remained `false` before and after activation.
- CTK files, a valid per-disk change ID, and a successful
  `QueryChangedDiskAreas` call proved that disk CBT was operational.
- Therefore the VM-level Boolean is an informational signal in this
  environment, not sufficient authority for the replication gate.

## 4. Authoritative CBT Readiness Contract

CBT readiness is evaluated per selected disk.

```text
CBT_ACTIVE =
  every selected disk has a resolved VMware device identity
  AND every selected disk has ctkEnabled=true
  AND the run snapshot exposes a non-empty changeId for every selected disk
  AND QueryChangedDiskAreas succeeds for every selected disk
```

`config.changeTrackingEnabled` remains captured for diagnostics but cannot
alone fail the run when all disk-level proofs are valid.

The first full seed still transfers the complete selected disks. Its change ID
is committed only after target durability, and later cycles use that committed
change ID for incremental queries.

## 5. State Machine

```text
UNKNOWN
  -> CONFIG_REQUIRED
  -> CONFIGURED_PENDING_ACTIVATION
  -> ACTIVATING_WITH_RUN_SNAPSHOT
  -> VERIFYING_DISK_EVIDENCE
  -> ACTIVE

Any non-recoverable configuration error -> FAILED
Any snapshot/query transient error       -> RETRYABLE_FAILED
```

State meanings:

| State | Meaning |
| --- | --- |
| `CONFIG_REQUIRED` | One or more required ExtraConfig values are absent or false. |
| `CONFIGURED_PENDING_ACTIVATION` | Required values were saved, but no run snapshot has established disk evidence yet. |
| `ACTIVATING_WITH_RUN_SNAPSHOT` | The normal source snapshot for this replication cycle is being created. |
| `VERIFYING_DISK_EVIDENCE` | Snapshot disks are checked for change ID and CBT query capability. |
| `ACTIVE` | All selected disks passed authoritative evidence checks. |
| `RETRYABLE_FAILED` | A transient vCenter, snapshot, or query failure may be retried safely. |
| `FAILED` | Policy, device identity, or unsupported VMware configuration blocks CBT. |

## 6. FTCTL Code Design

### 6.1 `lib/ftctl/dr_vmware.sh`

Split the current `ftctl_dr_vmware_preflight_cbt` behavior into explicit
functions:

```bash
ftctl_dr_vmware_read_cbt_config
ftctl_dr_vmware_configure_cbt
ftctl_dr_vmware_mark_cbt_activation_pending
ftctl_dr_vmware_verify_snapshot_cbt_evidence
ftctl_dr_vmware_publish_cbt_status
```

`ftctl_dr_vmware_configure_cbt`:

- Resolves every selected disk to `scsiX:Y`.
- Writes missing `ctkEnabled=true` and disk-level values through vCenter.
- Re-reads ExtraConfig and fails only if those values were not persisted.
- Does not require `config.changeTrackingEnabled=true` immediately.
- Does not power off or reboot the source VM.
- Returns `CONFIGURED_PENDING_ACTIVATION` when snapshot proof is still absent.

`ftctl_dr_vmware_replication_cycle`:

- Creates the normal run snapshot using the existing plan/run-scoped name.
- Uses that snapshot for activation and VDDK source-open; it must not create an
  extra permanent activation snapshot.
- Calls `ftctl_dr_vmware_verify_snapshot_cbt_evidence` before data movement.
- Continues with full seed only after every selected disk is verified.

`ftctl_dr_vmware_verify_snapshot_cbt_evidence`:

```text
for each selected disk:
  resolve snapshot disk by sourceDiskKey and cbtDiskId
  read snapshot backing changeId
  require non-empty and non-placeholder changeId
  call QueryChangedDiskAreas(snapshot, disk, changeId)
  record query success and returned changeId
ACTIVE only when every selected disk passes
```

The query with the current snapshot change ID is a capability check. It may
legitimately return zero changed extents.

### 6.2 `dr_vmware_changed_areas.py`

Add a dedicated verification mode instead of inferring success from a normal
incremental response:

```text
--verify-current-change-id
```

The JSON response must include:

```json
{
  "disk_id": "scsi0:0",
  "current_change_id": "...",
  "change_id_present": true,
  "query_succeeded": true,
  "changed_extent_count": 0
}
```

No plaintext vCenter credential may be written to output, status, or logs.

### 6.3 Status schema

`vmware-cbt.json` and `dr-status --json` expose versioned evidence:

```json
{
  "schemaVersion": 2,
  "lifecycleState": "ACTIVE",
  "enabled": true,
  "vmConfigSignal": false,
  "activationMethod": "RUN_SNAPSHOT_STUN",
  "activationSnapshotRef": "snapshot-...",
  "disks": [
    {
      "sourceDiskKey": "2000",
      "cbtDiskId": "scsi0:0",
      "configEnabled": true,
      "changeIdPresent": true,
      "querySucceeded": true
    }
  ],
  "message": "CBT is active for all selected disks"
}
```

The top-level runtime `error_message` must copy the actionable CBT message on
failure. Cloud must not need to parse a nested object to explain a terminal
failure.

### 6.4 Error codes

| Code | Retryable | Meaning |
| --- | --- | --- |
| `DR_VMWARE_CBT_CONFIG_FAILED` | depends on vCenter fault | ExtraConfig could not be persisted. |
| `DR_VMWARE_CBT_ACTIVATION_FAILED` | yes for transient task failure | Run snapshot did not establish CBT disk evidence. |
| `DR_VMWARE_CBT_CHANGE_ID_MISSING` | yes once after cleanup/retry | A selected snapshot disk has no valid change ID. |
| `DR_VMWARE_CBT_QUERY_FAILED` | yes for transport/session faults | CBT query failed for a selected disk. |
| `DR_VMWARE_CBT_UNSUPPORTED` | no | Disk/controller/snapshot configuration does not support CBT. |
| `DR_VMWARE_CBT_VERIFY_FAILED` | compatibility only | Legacy aggregate error; new code must emit a specific code. |

## 7. Snapshot And Retry Contract

- Snapshot names include plan UUID, run UUID, and cycle sequence.
- The journal records `snapshot_created`, `cbt_verified`, `source_opened`, and
  `snapshot_removed` independently.
- A retry reuses a snapshot only when its plan/run identity and source hardware
  fingerprint match; otherwise it cleans the stale snapshot first.
- Failed activation sets `cleanupRequired=true` when the run snapshot remains.
- A snapshot is deleted only after VDDK handles are closed.
- The first successful full seed persists the change ID only after target data
  and checkpoint metadata are durable.
- A failed preflight must never publish a restore point or target VM readiness.

## 8. Test Design

Unit tests:

1. VM Boolean false, disk config true, change ID/query valid -> `ACTIVE`.
2. VM Boolean true, one disk config false -> `CONFIG_REQUIRED`.
3. All config true, one disk change ID missing -> specific retryable failure.
4. All change IDs present, one query fails -> `DR_VMWARE_CBT_QUERY_FAILED`.
5. Zero changed extents with successful query -> `ACTIVE`.
6. Multi-disk VM requires evidence for every selected disk.
7. Credentials are absent from all emitted JSON and logs.
8. Crash after snapshot creation sets cleanup evidence and supports safe retry.

Integration tests:

1. CBT-disabled powered-on VM completes configure, run snapshot activation,
   full seed, and first durable checkpoint without a power cycle.
2. The second cycle uses the committed change ID and reports an incremental
   transfer.
3. A VM with pre-enabled CBT keeps the existing successful fast path.
4. Snapshot-incompatible VM fails before data transfer with an actionable code.

## 9. Implementation Priority

1. Correct FTCTL readiness authority and status schema.
2. Add snapshot-backed disk evidence verification.
3. Add deterministic snapshot cleanup and retry behavior.
4. Update Cloud projection and API fields.
5. Update UI state/message mapping.
6. Run unit, shell, module, and live full-seed/incremental smoke tests.

## 10. AS-IS / TO-BE

| Area | AS-IS | TO-BE |
| --- | --- | --- |
| CBT authority | VM Boolean plus disk ExtraConfig | Per-disk config, change ID, and successful CBT query |
| Running VM activation | Set ExtraConfig and immediately verify | Set config, activate with the normal run snapshot, then verify |
| VM power handling | Immediate false result becomes terminal failure | No automatic power cycle; snapshot activation is attempted first |
| Initial snapshot | Reached only after CBT hard gate | Serves as both CBT activation boundary and full-seed source |
| Multi-disk safety | Aggregate Boolean | Evidence required for every selected disk |
| Failure message | Nested message; top-level may be empty | Specific top-level code and actionable message |
| Retry | Exit 79 is non-retryable | Transient activation/query failures are safely retryable |
| Compatibility | Pre-enabled VM path succeeds | Existing fast path remains unchanged |

## 11. Implementation Result (2026-08-10)

- `dr_vmware.sh` now treats the VM-level Boolean as `vmConfigSignal` and
  accepts persisted per-disk CBT configuration as
  `CONFIGURED_PENDING_ACTIVATION`.
- `dr_vmware_changed_areas.py --verify-current` requires a non-empty current
  snapshot change ID and executes `QueryChangedDiskAreas` with that ID.
- `dr_vmware_mover.sh` records per-disk query evidence and promotes the shared
  status to `ACTIVE` only after every selected disk has passed.
- Query and change-ID failures update the shared CBT status with the failed
  disk and typed error before the mover exits.
- FTCTL self-tests cover the false VM Boolean compatibility case, ACTIVE
  promotion, and the full-seed `--verify-current` invocation.
