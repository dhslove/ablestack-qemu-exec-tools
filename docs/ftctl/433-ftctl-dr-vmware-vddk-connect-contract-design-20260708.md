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
