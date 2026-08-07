# V2K/N2K Cloud inspection handoff design

## 1. Objective

V2K and N2K must create an inspectable ABLESTACK Cloud VM whenever migrated
disk data is complete and the root disk identity is unambiguous. Guest boot,
controller representation, network identity, or post-deploy assembly problems
must not discard an already viable migration result. Those problems produce a
stopped `inspection_required` VM that an engineer can accept or discard.

This contract does not hide data-integrity or Cloud infrastructure failures.
Final-sync failure, missing target images, ambiguous root disks, missing Cloud
configuration, root-volume import failure, and VM deployment failure remain
fatal because no trustworthy Cloud VM can be produced from them.

## 2. Readiness contract

Both engines store the operator handoff state below `.runtime.cloud`:

```json
{
  "readiness": {
    "status": "ready|degraded",
    "inspection_required": true,
    "components": {
      "boot": {"status": "degraded", "reason": "..."},
      "controller": {
        "status": "degraded",
        "fallback": "sata",
        "scope": "all-disks",
        "reason": "..."
      },
      "network": {
        "status": "degraded",
        "fallback": "cloud-assigned-mac",
        "reason": "..."
      }
    }
  },
  "checkpoint": {
    "stage": "vm-deployed|inspection-required|complete",
    "complete": false,
    "root_volume_id": "...",
    "vm_id": "...",
    "data_volumes": {}
  }
}
```

V2K also retains `.runtime.bootstrap_fallback` for compatibility. Its canonical
Cloud fallback is `bus=sata` and `scope=all-disks`.

## 3. V2K policy

V2K classifies a guest as Windows, Linux, or unknown. The following outcomes
force both `rootDiskController` and `dataDiskController` to SATA and continue
Cloud import/deploy:

- Linux root, boot, mount, chroot, or initramfs preparation failure;
- Windows WinPE definition, boot, driver injection, shutdown, or timeout;
- unavailable or invalid WinPE/VirtIO media;
- an explicitly skipped boot-preparation method;
- an unknown or unsupported guest OS classification.

The Cloud policy is mandatory. `--no-bootstrap-fallback` remains meaningful
only for direct libvirt targets. A degraded Cloud target is left stopped.

## 4. N2K policy

N2K separates disk identity from target controller compatibility. Missing or
ambiguous root identity remains fatal. If root identity is valid but the source
controller cannot be represented safely in Cloud, or data controllers are
mixed, N2K replaces the effective root and data controller plan with SATA and
continues.

Source controller metadata remains in the manifest for audit. Only the
effective Cloud plan is replaced.

## 5. Network fallback

When ordered source NIC/MAC mapping succeeds, Cloud receives the original MACs.
When source NIC count or MAC validity prevents that mapping but one or more
unique Cloud network IDs are present, both engines create one target NIC per
selected network and omit the MAC parameter. Cloud allocates the MAC and the
target is marked for inspection. Missing or duplicate target network IDs remain
fatal configuration errors.

Post-deploy NIC mismatch is non-fatal. Root-volume verification and data-disk
assembly continue and the VM remains stopped.

## 6. Mutation checkpoints and retry

The mutation sequence is:

```text
root-import-submitted -> root-imported
vm-deploy-submitted   -> vm-deployed
root-ready
data-imported         -> data-attached (per disk)
vm-started
complete | inspection-required
```

Root-volume and VM job IDs are persisted immediately after Cloud accepts the
asynchronous request. A retry waits for the recorded job or reuses the recorded
resource rather than importing or deploying a duplicate. Recorded root-volume,
VM, and data-volume IDs are reused to continue an incomplete checkpoint.

## 7. Post-deploy handoff

After `vm_id` exists, NIC verification, root verification, individual data-disk
import/attach, and VM start failures are accumulated as issues. Processing
continues where safe. The final result is one of:

```text
completed
completed_with_warning + inspection_required=true
```

`completed_with_warning` is a successful operator handoff, not proof that the
guest boots. The VM ID, root-volume ID, successfully imported data volumes, job
IDs, deployment properties, and issues are retained in the manifest.

## 8. Cleanup safety

Automatic source recovery-point or VMware migration-snapshot cleanup is blocked
while `.runtime.cloud.inspection_required` or its completed checkpoint is true.
The work directory is also retained. Cleanup requires a later explicit operator
decision after the Cloud VM has been accepted or discarded.

## 9. Validation

The contract is covered by focused controller, NIC, cutover-integrity, mutation
checkpoint, and cross-engine handoff smoke tests. Package builds for V2K and N2K
must succeed after those tests. Release publication and host deployment are not
part of this change.
