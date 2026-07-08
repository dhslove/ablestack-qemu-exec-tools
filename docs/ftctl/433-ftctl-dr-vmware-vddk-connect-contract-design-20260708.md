# FTCTL DR VMware VDDK Connect Contract Design

Date: 2026-07-08

## 1. Purpose

This document defines the FTCTL-side design for VMware source connection
validation and error separation after the raw-over-NBD source graph fix.

The failed DR sync for plan `71182935-11c6-4ed3-aeec-ebde1486bdfa` reached
`lib/ftctl/dr_vmware_mover.sh`, started the VDDK mover path, and then failed:

```text
VixDiskLib_ConnectEx: One of the parameters was invalid
qemu-img: server reported: VixDiskLib_ConnectEx: One of the parameters was invalid
```

The current implementation maps the final `qemu-img info --image-opts` failure
to exit 72, `DR_VMWARE_MOVER_SOURCE_GRAPH_INVALID`. That was correct for the
previous invalid QEMU graph. It is too broad for the current failure because the
QEMU raw-over-NBD graph is now valid and VDDK is rejecting connection parameters.

## 2. Required Runtime Contract

FTCTL must receive a complete non-secret VMware source contract plus a separate
credential file.

Profile fields:

```json
{
  "source": {
    "provider": "VMWARE",
    "driver": "VMWARE_CBT",
    "siteId": 2,
    "vmId": "vm-4486",
    "externalRef": "vm-4486",
    "vcenterRef": "<source-site-uuid-or-ref>",
    "endpointRef": "10.10.21.10"
  },
  "mapping": {
    "disks": [
      {
        "sourceVmdkPath": "[datastore] vm/vm.vmdk",
        "sourceVmRef": "vm-4486",
        "targetDiskRef": "Rokcy10-1-dr-disk-0",
        "targetStorageRef": "rbd",
        "targetFormat": "raw"
      }
    ]
  }
}
```

Credential fields:

```json
{
  "credentials": {
    "source": {
      "endpoint": "10.10.21.10",
      "principal": "administrator@ablecloud.local",
      "auth": {
        "password": "<redacted>"
      },
      "tlsVerify": false,
      "thumbprint": "<optional>"
    }
  }
}
```

Secrets must stay only in the runtime credential file and must not be copied
into manifests, disk maps, events, or logs.

## 3. Code-Level Changes

### 3.1 Canonicalization

File:

```text
lib/ftctl/dr_vmware.sh
```

Current canonicalization reads `source` and `target`, but `datastoreRef`
falls back to target storage fields and `vcenterRef` can remain empty:

```python
"vcenterRef": first_str(source.get("vcenterRef"), source.get("vCenterRef"), target.get("vcenterRef"), target.get("vCenterRef")),
"datastoreRef": first_str(target.get("datastoreRef"), target.get("datastore"), mapping.get("targetDatastoreRef"), mapping.get("targetStorageRef"), mapping.get("datastoreRef")),
```

Target canonicalization:

```python
direction = str(profile.get("direction") or mapping.get("direction") or "").upper()
source_vm_ref = first_str(
    source.get("vmId"),
    source.get("vmRef"),
    source.get("externalRef"),
    mapping.get("sourceExternalRef"),
)
vcenter_ref = first_str(
    source.get("vcenterRef"),
    source.get("vCenterRef"),
    source.get("endpointRef"),
    source.get("endpoint"),
)

if direction == "VMWARE_TO_KVM":
    datastore_ref = first_str(
        source.get("datastoreRef"),
        source.get("datastore"),
        mapping.get("sourceDatastoreRef"),
        mapping.get("sourceDatastore"),
    )
else:
    datastore_ref = first_str(
        target.get("datastoreRef"),
        target.get("datastore"),
        mapping.get("targetDatastoreRef"),
        mapping.get("datastoreRef"),
    )
```

Disk normalization must copy top-level VMware source identity into disk rows:

```python
"sourceVmRef": first_str(
    disk.get("sourceVmRef"),
    source_item.get("sourceVmRef"),
    source_vm_ref,
),
"vcenterRef": first_str(
    disk.get("vcenterRef"),
    source_item.get("vcenterRef"),
    vcenter_ref,
),
```

### 3.2 Preflight connect contract

Add a validation function in `lib/ftctl/dr_vmware.sh`:

```bash
ftctl_dr_vmware_validate_connect_contract() {
  local disk_map="${1-}" credentials_file="${2-}"
  python3 - "${disk_map}" "${credentials_file}" <<'PY'
import json
import os
import sys

disk_map_path, credentials_path = sys.argv[1:3]
with open(disk_map_path, "r", encoding="utf-8") as fh:
    disk_map = json.load(fh)
with open(credentials_path, "r", encoding="utf-8") as fh:
    credentials = json.load(fh)

source_cred = ((credentials.get("credentials") or {}).get("source") or {})
missing = []

if not str(source_cred.get("endpoint") or "").strip():
    missing.append("credentials.source.endpoint")
if not str(source_cred.get("principal") or source_cred.get("username") or "").strip():
    missing.append("credentials.source.principal")
auth = source_cred.get("auth") if isinstance(source_cred.get("auth"), dict) else {}
if not str(auth.get("password") or source_cred.get("password") or "").strip():
    missing.append("credentials.source.password")
if not str(disk_map.get("sourceVmRef") or "").strip():
    missing.append("source.vmId")

for index, disk in enumerate(disk_map.get("disks") or []):
    if not str(disk.get("sourceVmdkPath") or disk.get("sourceDiskRef") or disk.get("sourcePath") or "").strip():
        missing.append(f"disks[{index}].sourceVmdkPath")

print(json.dumps({
    "ready": not missing,
    "missingFields": missing,
    "diskCount": len(disk_map.get("disks") or []),
}, sort_keys=True, separators=(",", ":")))
sys.exit(0 if not missing else 73)
PY
}
```

The scheduler must call this validation after canonicalization and credential
save, but before target disk conversion. A failure maps to:

```text
exit 73 -> DR_VMWARE_VDDK_CONNECT_INVALID
```

### 3.3 Mover endpoint normalization

File:

```text
lib/ftctl/dr_vmware_mover.sh
```

Add:

```bash
ftctl_vmware_mover_normalize_vcenter_server() {
  local endpoint="${1-}"
  endpoint="${endpoint#https://}"
  endpoint="${endpoint#http://}"
  endpoint="${endpoint%%/sdk}"
  endpoint="${endpoint%%/api}"
  endpoint="${endpoint%%/client/api}"
  endpoint="${endpoint%%/}"
  printf '%s\n' "${endpoint}"
}
```

Use normalized endpoint for nbdkit:

```bash
endpoint="$(ftctl_vmware_mover_normalize_vcenter_server "${endpoint}")"
```

This makes site endpoints such as `https://10.10.21.10/sdk` safe for nbdkit
VDDK, while preserving a plain `10.10.21.10` value.

### 3.4 Mover error separation

Capture nbdkit and qemu probe stderr:

```bash
local nbdkit_log qemu_info_log
nbdkit_log="${FTCTL_DR_VMWARE_MOVER_LOG_DIR}/nbdkit-${label}.log"
qemu_info_log="${FTCTL_DR_VMWARE_MOVER_LOG_DIR}/qemu-img-info-${label}.log"

nbdkit "${nbdkit_args[@]}" >"${nbdkit_log}" 2>&1 &

if ! timeout "${FTCTL_DR_VMWARE_QEMU_INFO_TIMEOUT}" \
    qemu-img info --force-share --image-opts "${source_opts}" \
    > /dev/null 2>"${qemu_info_log}"; then
  ftctl_vmware_mover_classify_source_open_failure "${label}" "${nbdkit_log}" "${qemu_info_log}"
fi
```

Add classifier:

```bash
ftctl_vmware_mover_classify_source_open_failure() {
  local label="${1-}" nbdkit_log="${2-}" qemu_log="${3-}" combined
  combined="$(cat "${nbdkit_log}" "${qemu_log}" 2>/dev/null || true)"
  if grep -qi 'VixDiskLib_ConnectEx' <<< "${combined}"; then
    ftctl_vmware_mover_die 73 \
      "DR_VMWARE_VDDK_CONNECT_INVALID: VDDK rejected source connection parameters for ${label}"
  fi
  if grep -qi 'Requested export not available' <<< "${combined}"; then
    ftctl_vmware_mover_die 74 \
      "DR_VMWARE_VDDK_EXPORT_UNAVAILABLE: VDDK NBD export is unavailable for ${label}"
  fi
  ftctl_vmware_mover_die 72 \
    "DR_VMWARE_MOVER_SOURCE_GRAPH_INVALID: qemu-img cannot open VDDK NBD source for ${label}"
}
```

### 3.5 Scheduler/runtime error code map

Files:

```text
lib/ftctl/dr_scheduler.sh
lib/ftctl/dr_runtime.sh
```

Add exit mappings:

```bash
73) error_code="DR_VMWARE_VDDK_CONNECT_INVALID" ;;
74) error_code="DR_VMWARE_VDDK_EXPORT_UNAVAILABLE" ;;
```

Keep exit 72 for actual QEMU source graph failures.

## 4. Agent Contract

The Mold agent does not need a new command. It must:

- pass the generated FTCTL profile and credential file paths unchanged,
- preserve final FTCTL JSON,
- preserve the sanitized first mover error line,
- never log source credential secrets.

## 5. Test Plan

| Test | Expected result |
| --- | --- |
| Missing endpoint credential | exit 73, `DR_VMWARE_VDDK_CONNECT_INVALID` |
| Missing source VM ref | exit 73, `DR_VMWARE_VDDK_CONNECT_INVALID` |
| Missing disk source VMDK path | exit 73, `DR_VMWARE_VDDK_CONNECT_INVALID` |
| qemu graph regression | exit 72, `DR_VMWARE_MOVER_SOURCE_GRAPH_INVALID` |
| nbdkit/qemu logs contain `VixDiskLib_ConnectEx` | exit 73 |
| nbdkit/qemu logs contain `Requested export not available` | exit 74 |
| Successful source open | mover proceeds to `qemu-img convert` |

## 6. AS-IS / TO-BE

| Area | AS-IS | TO-BE |
| --- | --- | --- |
| Canonical source identity | `sourceVmRef` may exist, `vcenterRef` can be empty | Source VM, vCenter/source endpoint, and disk source paths are validated together |
| Datastore field | VMware-to-KVM can inherit target storage as `datastoreRef` | VMware source datastore is source-only; target storage remains target-only |
| VDDK failures | `ConnectEx` is collapsed into exit 72 | `ConnectEx` maps to exit 73 and a specific error code |
| Export failures | Export unavailable is collapsed into source graph failure | Export unavailable maps to exit 74 |
| Logs | nbdkit details may be lost behind qemu-img failure | nbdkit/qemu probe stderr is retained in sanitized runtime logs |
| Operator action | Generic retry without knowing which parameter is wrong | Update source site/plan credential/VM/disk mapping based on specific error |

## 7. Live Manual Preflight Refinement

The intended VDDK source-open contract was manually validated on the actual data
plane worker `10.10.32.1` for source VM `vm-4486`.

The safe validation boundary was:

- create a temporary memoryless VMware snapshot,
- expose the source disk through read-only nbdkit VDDK,
- run `qemu-img info --image-opts`,
- remove the temporary snapshot,
- do not run `qemu-img convert` and do not write target data.

Observed results:

| Probe | Result |
| --- | --- |
| no `vm` parameter | nbdkit fails immediately: `missing parameter: vm` |
| `vm=moref=vm-4486`, no snapshot | VDDK fails with `DiskLib error 16392: Failed to lock the file` |
| `vm=moref=vm-4486`, run snapshot MoRef, base VMDK path read from vCenter | `qemu-img info` succeeds, source is `raw`, virtual size is 100 GiB |
| run snapshot MoRef plus current delta VMDK path | VDDK fails with access-rights error |
| path passed through lossy local shell encoding | datastore name can be corrupted to `????` and open fails |

Successful source-open command shape:

```bash
LD_LIBRARY_PATH="${libdir}" \
nbdkit --exit-with-parent --foreground --unix "${socket}" -r vddk \
  "libdir=${libdir}" \
  "server=${server}" \
  "user=${username}" \
  "password=+${password_file}" \
  "thumbprint=${thumbprint}" \
  "vm=moref=${source_vm_ref}" \
  "snapshot=${snapshot_ref}" \
  "transports=nbd:nbdssl" \
  "file=${base_vmdk_path}"

qemu-img info --force-share --image-opts \
  "driver=raw,file.driver=nbd,file.server.type=unix,file.server.path=${socket}"
```

Implementation consequence: `dr_vmware_mover.sh` must not start the base mover
with only `vm=moref=<vm>` and `file=<vmdk>`. A powered-on VM requires a snapshot
view for a stable read. The file path must be the base backing VMDK from source
inventory, not the current delta backing created after the snapshot.

## 8. Snapshot Lifecycle Design

Add a runtime source preparation step before target preparation:

```text
source-snapshot-create
source-open-preflight
target-prepare
base-transfer
source-snapshot-cleanup
```

Recommended helper functions:

```bash
ftctl_dr_vmware_create_run_snapshot() {
  local vm_ref="${1-}" run_uuid="${2-}" snapshot_name
  snapshot_name="ftctl-dr-${run_uuid}-base"
  # Use govc or an equivalent vSphere API wrapper.
  # Snapshot options: memory=false, quiesce policy from profile.
}

ftctl_dr_vmware_resolve_snapshot_moref() {
  local vm_ref="${1-}" snapshot_name="${2-}"
  # Return snapshot-<id> from vSphere snapshot tree.
}

ftctl_dr_vmware_cleanup_run_snapshot() {
  local vm_ref="${1-}" snapshot_name="${2-}"
  # Remove only snapshots created by this run.
}
```

Runtime state must record:

```json
{
  "source_snapshot": {
    "name": "ftctl-dr-<run>-base",
    "ref": "snapshot-7044",
    "createdByFtctl": true,
    "memory": false,
    "quiesce": false,
    "cleanupRequired": true
  }
}
```

Cleanup rules:

- If `source-open-preflight` fails after FTCTL created the snapshot, remove the
  snapshot before returning terminal failure when no transfer is active.
- If the worker is interrupted, `dr-cleanup` must remove snapshots tagged with
  the run UUID.
- Never remove an operator-created snapshot or a snapshot whose name/ref does
  not match the run state.

## 9. Mover Input Refinement

Extend disk-plan rows:

```json
{
  "sourceVmdk": "[datastore] vm/vm.vmdk",
  "sourceOpenVmdk": "[datastore] vm/vm.vmdk",
  "sourceVmRef": "vm-4486",
  "sourceSnapshotRef": "snapshot-7044",
  "targetPath": "rbd:rbd/Rokcy10-1-dr-disk-0",
  "targetFormat": "raw"
}
```

`ftctl_vmware_mover_convert_disk()` must require `sourceSnapshotRef` for a
powered-on base sync:

```bash
[[ -n "${source_snapshot_ref}" ]] || ftctl_vmware_mover_die 75 \
  "DR_VMWARE_VDDK_SOURCE_LOCKED: source snapshot is required for powered-on VMware disk open"

nbdkit_args+=("snapshot=${source_snapshot_ref}")
nbdkit_args+=("transports=nbd:nbdssl")
```

The mover must read VMDK paths from JSON using UTF-8-safe tooling (`jq`,
Python JSON, or direct profile files). Do not reconstruct datastore paths with
locale-dependent shell transformations.

## 10. Additional Error Codes

Extend scheduler/runtime mappings:

```bash
73) error_code="DR_VMWARE_VDDK_CONNECT_INVALID" ;;
74) error_code="DR_VMWARE_VDDK_EXPORT_UNAVAILABLE" ;;
75) error_code="DR_VMWARE_VDDK_SOURCE_LOCKED" ;;
76) error_code="DR_VMWARE_VDDK_OPEN_DENIED" ;;
```

Classifier additions:

```bash
if grep -qi 'DiskLib error 16392\\|Failed to lock the file' <<< "${combined}"; then
  ftctl_vmware_mover_die 75 \
    "DR_VMWARE_VDDK_SOURCE_LOCKED: source VMDK is locked; create/use a run snapshot"
fi
if grep -qi 'You do not have access rights to this file' <<< "${combined}"; then
  ftctl_vmware_mover_die 76 \
    "DR_VMWARE_VDDK_OPEN_DENIED: VDDK cannot open the requested VMDK path"
fi
```

## 11. Updated AS-IS / TO-BE

| Area | AS-IS | TO-BE |
| --- | --- | --- |
| Snapshot | Mover can run without snapshot and fail on locked powered-on disk | FTCTL creates a run snapshot before source open |
| VMDK path | Disk path may be copied through lossy shell/local encoding | Disk path is read from UTF-8 JSON/vCenter inventory and passed unchanged |
| File target | Current delta path may be selected after snapshot | Base VMDK path remains the open target with snapshot MoRef |
| Preflight | qemu-img info only validates graph | qemu-img info validates graph plus actual VDDK snapshot open |
| Cleanup | source snapshot lifecycle is undefined | run-created snapshots are recorded and cleaned on success/failure |

## 12. Live CBT And RPO Incremental Validation

The RPO incremental path was manually validated after source-open validation.

Actual VM state:

```text
config.changeTrackingEnabled=true
snapshot=null
base backing=[datastore] test1/test1.vmdk
```

Validation sequence:

```text
create S1
vmware_changed_areas.py --snapshot S1 --change-id ""
persist S1 new_change_id
remove S1
create S2
vmware_changed_areas.py --snapshot S2 --change-id <S1 new_change_id>
remove S2
verify snapshot=null
```

Observed output:

| Step | Result |
| --- | --- |
| baseline snapshot | returned new CBT changeId |
| S1 cleanup | succeeded |
| incremental snapshot | `QueryChangedDiskAreas` succeeded with previous changeId |
| changed areas | 2 |
| changed bytes | 131072 |
| S2 cleanup | succeeded |
| final snapshot tree | `null` |

This validates the intended low-snapshot-depth RPO model: after a checkpoint is
durable and its per-disk CBT changeId is persisted, the run-created snapshot can
be removed. The next RPO snapshot can still query changed areas from the stored
changeId.

## 13. CBT/RPO Engine Design

Add FTCTL runtime steps:

```text
ensure-cbt-enabled
source-snapshot-create
source-open-preflight
changed-areas-query
target-patch
checkpoint-durable
source-snapshot-cleanup
```

For base sync:

- `changed-areas-query` is not used for transfer selection.
- The base snapshot still records `new_change_id` for future RPO cycles.
- `ensure-cbt-enabled` must check and, when policy allows, enable CBT before
  the base snapshot is created.

For incremental sync:

- `lastChangeId` is mandatory.
- `QueryChangedDiskAreas(snapshot=currentSnapshot, changeId=lastChangeId)` is
  called before patch transfer.
- The returned areas become the only source extents copied to target.
- `new_change_id` is persisted only after target patch and restore point are
  durable.

Recommended status JSON:

```json
{
  "cbt": {
    "enabled": true,
    "diskId": "scsi0:0",
    "previousChangeId": "52.../636",
    "newChangeId": "52.../640",
    "changedAreas": 2,
    "changedBytes": 131072
  },
  "source_snapshot": {
    "name": "ftctl-dr-<run>-rpo",
    "ref": "snapshot-7044",
    "cleanupRequired": false
  }
}
```

Error mapping:

```bash
77) error_code="DR_VMWARE_CBT_DISABLED" ;;
78) error_code="DR_VMWARE_CBT_ENABLE_FAILED" ;;
79) error_code="DR_VMWARE_CBT_VERIFY_FAILED" ;;
80) error_code="DR_VMWARE_CBT_DISK_ID_UNRESOLVED" ;;
81) error_code="DR_VMWARE_CBT_CHANGE_ID_MISSING" ;;
82) error_code="DR_VMWARE_CBT_QUERY_FAILED" ;;
83) error_code="DR_VMWARE_SNAPSHOT_CLEANUP_REQUIRED" ;;
84) error_code="DR_VMWARE_CBT_SNAPSHOT_CONFLICT" ;;
```

Cleanup rules:

- Snapshot removal happens after checkpoint durability, not before.
- If the worker fails before any target patch starts, remove the run snapshot
  immediately.
- If the worker fails during target patch, keep `cleanupRequired=true` and let
  cleanup/retry logic decide whether the snapshot is still needed.
- Cleanup must match run-owned snapshot names/refs only.

## 14. Updated CBT AS-IS / TO-BE

| Area | AS-IS | TO-BE |
| --- | --- | --- |
| RPO sync | no proven changed-area cycle | actual VM validates S1/S2 CBT changed-area query |
| CBT state | not a runtime gate | `ensure-cbt-enabled` gates incremental sync |
| Snapshot depth | unclear whether old snapshots must stay | stored changeId allows previous snapshot removal after durability |
| Incremental patch | no required previous changeId contract | incremental requires durable `lastChangeId` |
| Cleanup evidence | not surfaced | status JSON reports snapshot cleanupRequired and checkpoint data |

## 15. CBT Check And Auto-Enable Design

The live validation VM already had `config.changeTrackingEnabled=true`, but the
engine must handle disabled CBT as part of the DR contract.

Implementation target:

```text
ensure-cbt-enabled:
  read VM-level config.changeTrackingEnabled
  read or resolve each selected disk's CBT id, such as scsi0:0
  read disk-level ctkEnabled state
  if all enabled: continue
  if disabled and profile.source.cbtPolicy.autoEnable=false: exit 77
  if non-FTCTL snapshots exist and failIfPreExistingSnapshots=true: exit 84
  enable VM-level CBT
  enable disk-level CBT for each selected disk
  re-read and verify VM/disk CBT state
  continue to source-snapshot-create
```

The v2k implementation already contains the basic govc pattern that this FTCTL
DR implementation should reuse conceptually without invoking the v2k migration
engine:

```bash
govc vm.change -vm "${vm}" -e "ctkEnabled=true"
govc vm.change -vm "${vm}" -e "${disk_id}.ctkEnabled=true"
```

For the current source disk, the vSphere hardware graph maps disk key `2000` to
`scsi0:0`. DR mapping should carry this as `source.cbtDiskId`; if Cloud mapping
does not include it, FTCTL must resolve it from controller bus/unit metadata.

Recommended helpers:

```bash
ftctl_dr_vmware_cbt_status_json() {
  # Return vmEnabled and selected disk enabled flags.
}

ftctl_dr_vmware_resolve_cbt_disk_id() {
  # Resolve diskRef/key/backing path to scsiX:Y using vSphere device graph.
}

ftctl_dr_vmware_enable_cbt() {
  local vm="${1-}"
  govc vm.change -vm "${vm}" -e "ctkEnabled=true"
  for disk_id in "${selected_disk_ids[@]}"; do
    govc vm.change -vm "${vm}" -e "${disk_id}.ctkEnabled=true"
  done
}

ftctl_dr_vmware_verify_cbt_enabled() {
  # Re-read VM and disk state; fail if any selected disk remains disabled.
}
```

Status JSON:

```json
{
  "cbt": {
    "required": true,
    "autoEnable": true,
    "vmEnabledBefore": false,
    "vmEnabledAfter": true,
    "enabledByFtctl": true,
    "disks": [
      {
        "diskRef": "2000",
        "cbtDiskId": "scsi0:0",
        "enabledBefore": false,
        "enabledAfter": true
      }
    ]
  }
}
```

Pre-existing snapshot rule:

- If `policy.cbtPolicy.failIfPreExistingSnapshots=true` and snapshots not owned
  by the current FTCTL run exist before enabling CBT, exit 84
  `DR_VMWARE_CBT_SNAPSHOT_CONFLICT`.
- The current implementation default is `false` so the engine does not block an
  otherwise valid first sync solely because an operator-created snapshot exists.
- Do not delete operator-created snapshots.
- Operator can clear snapshots or explicitly choose a later policy that starts
  a new full baseline with acknowledgement.

## 16. Implementation Update - 2026-07-08

Implemented in `lib/ftctl/dr_vmware.sh`:

- `ftctl_dr_vmware_canonicalize_profile` now preserves `device`,
  `cbtDiskId`, `sourceDiskKey`, `controllerBusNumber`, and `unitNumber` from
  the Cloud disk mapping. If bus/unit are present it infers `scsiX:Y`.
- `ftctl_dr_vmware_ensure_cbt_enabled` runs before the VMware sync contract is
  marked ready. It reads VM/disk CBT state through `govc vm.info -json`, enables
  `ctkEnabled=true` and `${disk_id}.ctkEnabled=true` when allowed, and verifies
  the state again.
- Runtime status writes `vmware-cbt.json` and sync failure state points to that
  file through `cbt_status_path`.
- Failure states map to explicit codes:
  `DR_VMWARE_CBT_DISABLED`, `DR_VMWARE_CBT_ENABLE_FAILED`,
  `DR_VMWARE_CBT_VERIFY_FAILED`, `DR_VMWARE_CBT_DISK_ID_UNRESOLVED`,
  `DR_VMWARE_CBT_QUERY_FAILED`, and `DR_VMWARE_CBT_SNAPSHOT_CONFLICT`.
- A fake `govc` smoke verified that disabled CBT triggers the expected
  `vm.change -e ctkEnabled=true` and `vm.change -e scsi0:0.ctkEnabled=true`
  calls before the contract-ready step.

## 17. Live Preflight Regression - 2026-07-08

Runtime validation against the current test plan showed that the vCenter side is
reachable and the selected VM is CBT-ready, but FTCTL fails before it can use
that state.

Observed plan:

| Item | Value |
| --- | --- |
| Plan UUID | `bb4a6719-13c7-49de-a8ce-f5e04ff640a7` |
| Direction | `VMWARE_TO_KVM` |
| Source VM ref | `vm-4486` |
| Coordinator/worker host | `10.10.32.1` |
| Plan state | `ERROR` |
| Run step | `runtime-projection` |
| Error code | `DR_VMWARE_CBT_QUERY_FAILED` |
| FTCTL step | `vmware-cbt-preflight` |
| FTCTL worker exit code | `82` |

Runtime files showed this split:

- `profile.json` contains the non-secret DR topology, source VM reference, and
  disk mapping.
- `credentials.json` contains the vCenter endpoint, principal, password,
  TLS policy, VDDK library path, and VDDK version.
- `vmware-cbt.json` reported
  `vCenter endpoint, username, password, or source VM reference is missing`.

The message is a false negative. A direct preflight on `10.10.32.1` using the
runtime credential contract succeeded:

| Check | Result |
| --- | --- |
| `govc about` | vCenter `8.0.1`, build `21560480` |
| `govc vm.info -json vm-4486` | succeeded |
| VM name | `Rokcy10-1` |
| VM CBT | `changeTrackingEnabled=true` |
| Disk key | `2000` |
| Disk backing | `[3...-localdisk] test1/test1.vmdk` |
| Resolved CBT disk id | `scsi0:0` |
| Disk CBT | `ctkEnabled=TRUE`, `scsi0:0.ctkEnabled=TRUE` |

The executable check also showed that `govc` is not on the default PATH of the
worker hosts. The usable binary is delivered through the compatibility bundle:

```text
/usr/share/ablestack/v2k/compat/vsphere80/bin/govc
```

Conclusion:

- The current failure is not a vCenter reachability failure.
- The current failure is not a CBT-disabled failure.
- The qemu-side CBT preflight currently reads only `profile.credentials.source`
  and does not load the separate runtime `credentials.json` contract.
- The qemu-side CBT preflight also assumes `govc` is on PATH, which is not true
  on the current worker hosts.
- The disk mapping can arrive with only the vCenter disk key and backing path;
  FTCTL must be able to normalize that into the CBT disk id `scsiX:Y`.

## 18. Remediation Design - Credentials, govc, And Disk Identity

This remediation is qemu/FTCTL-scoped. It does not require a new Cloud DB
schema, and it must preserve the rule that secrets are not copied into
`profile.json`, logs, status JSON, or UI payloads.

### 18.1 Credential loading contract

Add a single FTCTL helper used by all VMware CBT/VDDK paths:

```bash
ftctl_dr_vmware_load_source_credentials() {
  local profile_file="${1:?profile file required}"
  local credentials_file="${2:-${FTCTL_DR_CREDENTIALS_FILE:-}}"
  python3 - "$profile_file" "$credentials_file" <<'PY'
import json
import os
import sys

profile_path, credentials_path = sys.argv[1], sys.argv[2]
with open(profile_path, encoding="utf-8") as fh:
    profile = json.load(fh)

merged = {}

def deep_merge(dst, src):
    for key, value in (src or {}).items():
        if isinstance(value, dict) and isinstance(dst.get(key), dict):
            deep_merge(dst[key], value)
        else:
            dst[key] = value

deep_merge(merged, profile.get("credentials", {}).get("source", {}))

if credentials_path and os.path.exists(credentials_path):
    with open(credentials_path, encoding="utf-8") as fh:
        credentials = json.load(fh)
    deep_merge(merged, credentials.get("credentials", {}).get("source", {}))

source = profile.get("source", {})
merged.setdefault("endpoint", source.get("endpoint") or source.get("apiEndpoint"))
merged.setdefault("externalRef", source.get("externalRef"))

print(json.dumps(merged, separators=(",", ":")))
PY
}
```

Rules:

- `FTCTL_DR_CREDENTIALS_FILE` is the preferred runtime source for secrets.
- `profile.credentials.source` remains supported only for backward
  compatibility and test fixtures.
- The credential file values override profile values because they are the
  runtime authority.
- The helper must return a redaction-safe object to shell callers only when the
  caller immediately uses it; it must not write the password to status files.
- Any status or event record must redact `password`, `secret`, `token`,
  `apiKey`, and compatible aliases.

### 18.2 govc resolver

All qemu-side VMware helpers must call a resolver instead of hard-coding
`govc`.

```bash
ftctl_dr_vmware_resolve_govc_bin() {
  local credentials_json="${1:?credentials json required}"
  python3 - "$credentials_json" <<'PY'
import json
import os
import shutil
import sys

creds = json.loads(sys.argv[1] or "{}")
candidates = []

env_bin = os.environ.get("FTCTL_DR_VMWARE_GOVC_BIN")
if env_bin:
    candidates.append(env_bin)

for key in ("govcPath", "govcBin"):
    if creds.get(key):
        candidates.append(creds[key])

vddk_libdir = creds.get("vddkLibdir")
if vddk_libdir:
    compat_root = os.path.dirname(os.path.abspath(vddk_libdir))
    candidates.append(os.path.join(compat_root, "bin", "govc"))
    candidates.append(os.path.join(os.path.dirname(compat_root), "bin", "govc"))

version = str(creds.get("vddkVersion") or "").strip()
if version:
    normalized = version.replace(".", "")
    if normalized == "8":
        normalized = "80"
    candidates.append(f"/usr/share/ablestack/v2k/compat/vsphere{normalized}/bin/govc")

path_bin = shutil.which("govc")
if path_bin:
    candidates.append(path_bin)

candidates.extend([
    "/usr/local/bin/govc",
    "/usr/bin/govc",
])

seen = set()
for candidate in candidates:
    if not candidate or candidate in seen:
        continue
    seen.add(candidate)
    if os.path.isfile(candidate) and os.access(candidate, os.X_OK):
        print(candidate)
        sys.exit(0)

sys.exit(1)
PY
}
```

Resolver order:

1. `FTCTL_DR_VMWARE_GOVC_BIN`
2. `credentials.source.govcPath` or `credentials.source.govcBin`
3. `credentials.source.vddkLibdir` adjacent compatibility bundle
4. `credentials.source.vddkVersion` compatibility bundle
5. PATH
6. common system locations

The CBT preflight must run a cheap `govc about` with the selected binary before
querying VM hardware. If no binary is found or `govc about` fails, return
`DR_VMWARE_CBT_QUERY_FAILED` with a redacted message that names the missing
binary or connection category, not the password.

### 18.3 VMware credential environment

Build a `govc` environment from the merged credential object:

```bash
ftctl_dr_vmware_govc_env_file() {
  local credentials_json="${1:?credentials json required}"
  local env_file="${2:?env file required}"
  python3 - "$credentials_json" "$env_file" <<'PY'
import json
import os
import shlex
import sys

creds = json.loads(sys.argv[1] or "{}")
env_file = sys.argv[2]

endpoint = creds.get("endpoint") or creds.get("url")
principal = creds.get("principal") or creds.get("username")
password = ((creds.get("auth") or {}).get("password")
            or creds.get("password"))
tls_verify = bool(creds.get("tlsVerify"))

if not endpoint or not principal or not password:
    raise SystemExit(82)

url = endpoint
if not url.startswith(("http://", "https://")):
    url = "https://" + url
if not url.endswith("/sdk"):
    url = url.rstrip("/") + "/sdk"

lines = [
    "export GOVC_URL=" + shlex.quote(url),
    "export GOVC_USERNAME=" + shlex.quote(principal),
    "export GOVC_PASSWORD=" + shlex.quote(password),
    "export GOVC_INSECURE=" + shlex.quote("false" if tls_verify else "true"),
]
with open(env_file, "w", encoding="utf-8") as fh:
    fh.write("\n".join(lines) + "\n")
os.chmod(env_file, 0o600)
PY
}
```

The environment file must be created under the plan runtime directory with
`0600` permissions and removed during cleanup when possible.

### 18.4 CBT disk id normalization

The disk map may contain any subset of these fields:

```json
{
  "sourceDiskKey": "2000",
  "sourceDiskRef": "[datastore] vm/vm.vmdk",
  "controllerKey": "1000",
  "controllerBusNumber": 0,
  "unitNumber": 0,
  "cbtDiskId": ""
}
```

FTCTL must normalize it before CBT checks:

```python
def normalize_cbt_disk_id(vm_devices, disk_mapping):
    existing = str(disk_mapping.get("cbtDiskId") or "")
    if re.match(r"^scsi\d+:\d+$", existing):
        return existing

    controllers = {
        str(d.key): d.busNumber
        for d in vm_devices
        if d.type in ("VirtualLsiLogicController",
                      "VirtualLsiLogicSASController",
                      "ParaVirtualSCSIController")
    }

    for disk in vm_devices:
        if disk.type != "VirtualDisk":
            continue
        key_match = str(disk.key) == str(disk_mapping.get("sourceDiskKey") or disk_mapping.get("diskRef") or "")
        path_match = disk.backing.fileName == disk_mapping.get("sourceDiskRef")
        label_match = disk.deviceInfo.label == disk_mapping.get("sourceDiskLabel")
        if not (key_match or path_match or label_match):
            continue
        bus = controllers.get(str(disk.controllerKey))
        if bus is None or disk.unitNumber is None:
            break
        return f"scsi{bus}:{disk.unitNumber}"

    raise DrError("DR_VMWARE_CBT_DISK_ID_UNRESOLVED")
```

When normalization succeeds, write both the original and normalized identity to
`vmware-cbt.json`:

```json
{
  "diskRef": "2000",
  "sourceDiskKey": "2000",
  "sourceDiskRef": "[3...-localdisk] test1/test1.vmdk",
  "cbtDiskId": "scsi0:0",
  "resolution": "vm-device-graph"
}
```

### 18.5 Updated CBT preflight sequence

```text
load profile.json
load credentials.json from FTCTL_DR_CREDENTIALS_FILE
merge source credentials without persisting secrets
resolve govc binary
create temporary govc env file with 0600 permissions
run govc about
run govc vm.info -json <source.externalRef>
normalize selected disk identities to scsiX:Y
read VM and disk CBT state
if CBT disabled and autoEnable=true:
  run govc vm.change -vm <ref> -e ctkEnabled=true
  run govc vm.change -vm <ref> -e <scsiX:Y>.ctkEnabled=true per selected disk
verify CBT state again
write redacted vmware-cbt.json
continue to snapshot/changeId baseline
```

### 18.6 Layer impact

| Layer | Change |
| --- | --- |
| UI | No blocking UI flow change. Display the more specific CBT preflight message from run details when available. |
| API/Backend | No schema change. Continue writing secrets only to `credentials.json`; ensure the agent command exports `FTCTL_DR_CREDENTIALS_FILE`. |
| Agent | No business logic change. Preserve runtime credential path, `0600` file permissions, and redacted logs. |
| FTCTL | Required: credential-file loader, govc resolver, govc env builder, disk id normalizer, and redacted CBT status. |
| DB | No schema change. Existing run/step details can carry redacted CBT status and error code. |

### 18.7 Acceptance criteria

- A plan whose runtime credentials are stored only in `credentials.json` passes
  the CBT preflight.
- Worker hosts without PATH-level `govc` can use
  `/usr/share/ablestack/v2k/compat/vsphere80/bin/govc`.
- Disk key `2000` for VM `vm-4486` normalizes to `scsi0:0`.
- `vmware-cbt.json` never contains plaintext credentials.
- A real CBT-disabled VM is enabled only when `autoEnable=true`.
- A real unresolved disk fails with `DR_VMWARE_CBT_DISK_ID_UNRESOLVED`, not the
  generic missing-credential message.

## 19. Implementation Update - 2026-07-08

The validated preflight design is now reflected in the ftctl runtime path.

| Area | Implemented behavior |
| --- | --- |
| Runtime credential loading | `ftctl_dr_vmware_ensure_cbt_enabled` reads the runtime credential file resolved by `ftctl_dr_runtime_credential_path` and merges it over profile-level source credentials. |
| govc resolution | The CBT preflight resolves `govc` from explicit config, VDDK compat bundle paths such as `/usr/share/ablestack/v2k/compat/vsphere80/bin/govc`, PATH, and common system locations. |
| CBT disk identity | VMware disk key/path/label is normalized to `scsiX:Y` using the VM hardware device graph before CBT status is evaluated. |
| Redacted status projection | `dr-status --json` includes the redacted `cbt_status` object from `vmware-cbt.json`, including `enabled`, `cbtDiskId`, `message`, `govcBin`, and `checkedAtEpochMs` when available. |
| Selftest coverage | A selftest validates that a profile without embedded credentials succeeds when runtime `credentials.json` contains the vCenter credential and compat `govc` path. |

No ftctl DB or profile schema change is required. The runtime contract remains:
Cloud writes secrets to the runtime credential file, Agent preserves the path,
and ftctl emits only redacted operational evidence.

## 20. Live Source-Open Regression - 2026-07-08

The next live plan confirmed that the CBT and credential loading fixes are not
enough to declare the VMware-to-KVM sync path ready.

Observed plan:

| Item | Value |
| --- | --- |
| Plan UUID | `9e0aaaae-5d0f-4f12-9edf-49ad94f96056` |
| Run UUID | `ed5519bb-0d77-4580-92af-f833346cd456` |
| Worker host | `10.10.32.1` |
| Direction | `VMWARE_TO_KVM` |
| Source VM ref | `vm-4486` |
| Source disk | `[3...-local-disk] test1/test1.vmdk` |
| CBT status | enabled, disk resolved as `scsi0:0` |
| Runtime state | `ERROR` |
| Runtime step | `scheduler-failed` |
| Worker exit | `72` |
| Current error | `DR_VMWARE_MOVER_SOURCE_GRAPH_INVALID` |

The runtime preflight was repeated manually on `10.10.32.1` with read-only
`nbdkit vddk` and `qemu-img info --image-opts`. No conversion or target write
was executed.

| Probe | Result | Conclusion |
| --- | --- | --- |
| Current endpoint | endpoint is already host-shaped, `10.10.21.10` | endpoint URL normalization is not the current root cause |
| Normalized endpoint | same `VixDiskLib_ConnectEx` failure | normalization is still useful but insufficient |
| `vm` omitted | nbdkit fails: `missing parameter: vm` | source VM MoRef is mandatory |
| `vm=moref=vm-4486`, `single-link=true` | `VixDiskLib_ConnectEx: One of the parameters was invalid` | VDDK rejects the current source-open contract |
| `vm=moref=vm-4486`, no `single-link` | same failure | `single-link` is not the deciding factor |
| `vm=vm-4486` | same failure | plain VM value does not fix the contract |

This proves the next change must move from syntactic source graph validation to
an explicit VDDK source-open contract. The engine must not wait until
`qemu-img convert` to discover this; it must create or resolve the required
snapshot view, verify source open with `qemu-img info`, and only then start any
target write.

## 21. Source-Open Preflight Code Design

### 21.1 Mover parameter model

Extend `ftctl_vmware_mover_convert_disk()` in
`lib/ftctl/dr_vmware_mover.sh` so the caller can pass a snapshot reference and
the base VMDK path resolved from VMware inventory.

Target signature:

```bash
ftctl_vmware_mover_convert_disk() {
  local source_vmdk="${1-}" source_vm_ref="${2-}" source_snapshot_ref="${3-}"
  local target_uri="${4-}" target_format="${5-}" label="${6-}"
  local endpoint="${7-}" username="${8-}" password_file="${9-}"
  local tls_verify="${10-}" thumbprint="${11-}" libdir="${12-}"
}
```

Rules:

- `source_vmdk` must be the base backing VMDK path from vCenter inventory, not a
  delta path created after the run snapshot.
- `source_vm_ref` is required for remote VDDK opens.
- `source_snapshot_ref` is required for powered-on source VM base transfer.
- Endpoint normalization still runs before nbdkit, but a host-shaped endpoint
  does not make the source-open contract complete.
- All path values must be read from UTF-8 JSON or vCenter output; do not rebuild
  datastore paths through locale-dependent shell transformations.

### 21.2 Snapshot gate

Add a pre-mover gate in `lib/ftctl/dr_vmware.sh`:

```bash
ftctl_dr_vmware_require_source_snapshot_for_open() {
  local vm_power_state="${1-}" snapshot_ref="${2-}"
  if [[ "${vm_power_state}" == "poweredOn" && -z "${snapshot_ref}" ]]; then
    ftctl_dr_runtime_error 75 \
      "DR_VMWARE_VDDK_SOURCE_LOCKED: source snapshot is required for powered-on VMware disk open"
    return 75
  fi
}
```

The power-state reader must tolerate govc JSON schema differences by checking
both upper-case and lower-case property paths, for example:

```python
power = first_str(
    nested(vm, "Runtime", "PowerState"),
    nested(vm, "runtime", "powerState"),
    nested(vm, "summary", "runtime", "powerState"),
)
```

### 21.3 Bounded source-open preflight

Add a reusable mover helper:

```bash
ftctl_vmware_mover_probe_source_open() {
  local socket_path="${1-}" label="${2-}" nbdkit_log="${3-}" qemu_log="${4-}"
  local source_opts
  source_opts="$(ftctl_vmware_mover_source_image_opts "${socket_path}")"
  if ! timeout "${FTCTL_DR_VMWARE_QEMU_INFO_TIMEOUT:-20}" \
      qemu-img info --force-share --image-opts "${source_opts}" \
      >/dev/null 2>"${qemu_log}"; then
    ftctl_vmware_mover_classify_source_open_failure \
      "${label}" "${nbdkit_log}" "${qemu_log}"
  fi
}
```

Wrap the whole source-open probe with a wall-time guard in the caller:

```bash
timeout "${FTCTL_DR_VMWARE_SOURCE_OPEN_TIMEOUT:-60}" \
  ftctl_vmware_mover_convert_disk ...
```

The live manual test showed that a shell/SSH-side hang is possible if the probe
is not bounded end-to-end. Both `nbdkit` and `qemu-img` must be cleaned up
through a trap.

### 21.4 Error classifier

The classifier must preserve specific operator meaning:

```bash
if grep -qi 'VixDiskLib_ConnectEx' <<< "${combined}"; then
  ftctl_vmware_mover_die 73 \
    "DR_VMWARE_VDDK_CONNECT_INVALID: VDDK rejected source connection parameters for ${label}"
fi
if grep -qi 'Requested export not available' <<< "${combined}"; then
  ftctl_vmware_mover_die 74 \
    "DR_VMWARE_VDDK_EXPORT_UNAVAILABLE: VDDK NBD export is unavailable for ${label}"
fi
if grep -qi 'DiskLib error 16392\|Failed to lock the file' <<< "${combined}"; then
  ftctl_vmware_mover_die 75 \
    "DR_VMWARE_VDDK_SOURCE_LOCKED: source VMDK is locked; create/use a run snapshot"
fi
if grep -qi 'access rights to this file\|Permission denied' <<< "${combined}"; then
  ftctl_vmware_mover_die 76 \
    "DR_VMWARE_VDDK_OPEN_DENIED: VDDK cannot open the requested VMDK path"
fi
```

Order matters: if VDDK reports both `ConnectEx` and export unavailable, the
primary code is `DR_VMWARE_VDDK_CONNECT_INVALID`; export unavailable is retained
as secondary evidence in the sanitized log.

## 22. Updated Layer Scope

| Layer | Required change |
| --- | --- |
| FTCTL | Add snapshot-aware source-open preflight, wall-time timeout, cleanup trap, endpoint normalization, and VDDK-specific error classification. |
| Agent | No new command. Preserve stdout/stderr and final JSON, but do not interpret VDDK error text. |
| Cloud/API | No qemu-side schema change. Cloud must pass run snapshot policy and source identity; detailed API response hardening is covered in the Cloud companion design. |
| DB | No qemu DB. Runtime JSON gains redacted `source_open` and `source_snapshot` fields. |

Recommended runtime status extension:

```json
{
  "source_open": {
    "checked": true,
    "ready": false,
    "error_code": "DR_VMWARE_VDDK_CONNECT_INVALID",
    "vmRef": "vm-4486",
    "snapshotRefPresent": false,
    "sourceVmdkPathPresent": true
  }
}
```

## 23. Current Error Cause And AS-IS / TO-BE

Current root cause:

```text
The plan reached ftctl and CBT was ready, but the VMware mover tried to open
the selected VMDK through VDDK without a complete snapshot-aware source-open
contract. VDDK rejected the ConnectEx parameters. The engine mapped that to the
older generic source graph error, hiding the real recovery direction.
```

| Area | AS-IS | TO-BE |
| --- | --- | --- |
| Source-open validation | `qemu-img info` runs after nbdkit starts, but all failures collapse to source graph invalid | Source-open preflight classifies VDDK connect/export/lock/open-denied failures before conversion |
| Snapshot | Snapshot reference is not enforced for powered-on source open | FTCTL creates/resolves a run snapshot and passes `snapshot=<MoRef>` to nbdkit |
| Endpoint | Endpoint is passed as-is | Endpoint is normalized, but source-open readiness does not rely on endpoint normalization alone |
| Timeout | qemu probe has a timeout, but the whole preflight path can still hang around SSH/shell/process cleanup | Entire source-open probe is wall-time bounded and cleans nbdkit/qemu/temp files through trap |
| Error code | `VixDiskLib_ConnectEx` appears as `DR_VMWARE_MOVER_SOURCE_GRAPH_INVALID` | `VixDiskLib_ConnectEx` maps to `DR_VMWARE_VDDK_CONNECT_INVALID` with sanitized evidence |
| Runtime status | No structured source-open object | `source_open` and `source_snapshot` are exposed in redacted status JSON |
