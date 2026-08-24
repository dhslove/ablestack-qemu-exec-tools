# FTCTL DR ABLESTACK RBD Cross-Site Data Plane Design

Date: 2026-08-24

The FTCTL data plane is authority-neutral. It accepts an immutable command
from the Plan Owner Cloud through the Cloud that owns the local Agent. Source
or target execution does not grant FTCTL ownership of the DR plan, Cloud VM,
or volume lifecycle. Every remote command is correlated by Plan UUID, Run UUID,
site role, and operation reference; FTCTL never calls a remote Cloud lifecycle
API on its own.

## 1. Scope And Invariants

This document defines the FTCTL data plane for `KVM_TO_KVM`, RBD to RBD,
without Ceph `rbd-mirror`.

- Cloud owns VM, volume, RBD image, network, and power lifecycle.
- FTCTL receives explicit Cloud-created `rbd:<pool>/<image>` mappings.
- A running VM uses krbd; replication reads/writes through QEMU or librbd.
- FTCTL never creates a Cloud-managed RBD image or VM.
- Existing VMware CBT/VDDK functions are not modified by this provider driver.

## 2. Provider Pair

`KVM_TO_KVM` resolves to the `ABLESTACK_RBD_REMOTE_NBD` provider pair when all
protected source and target disks are RBD. The profile contains immutable disk
identity and never relies on local numeric Cloud IDs.

```json
{
  "providerPair": "ABLESTACK_RBD_REMOTE_NBD",
  "replicationMode": "SCHEDULED_INCREMENTAL",
  "disks": [{
    "diskId": "root",
    "source": "rbd:source-pool/source-image",
    "target": "rbd:target-pool/target-image",
    "targetExport": "nbd://target-host:port/export",
    "virtualBytes": 64424509440
  }]
}
```

## 3. Scheduled Replication

### Full seed

1. Verify target image exists and is at least the source virtual size.
2. Target broker starts an NBD export backed by target librbd.
3. Source worker streams the source RBD image to the export.
4. Target flushes, drains, and closes the export.
5. FTCTL records transfer metrics and commits a durable baseline token.

### Incremental cycle

1. Create source snapshot `ftctl-<plan>-<sequence>`.
2. When no baseline exists, request a full seed.
3. Run `rbd diff --whole-object --from-snap <baseline>` and stream changed
   extents to the target export at their original offsets.
4. Flush and close the target export.
5. Atomically promote the new source snapshot and target checkpoint token.
6. Delete only the superseded source baseline after the new baseline is
   durable. Keep one valid baseline at all times.

An interrupted cycle keeps the previous baseline and is retryable. A changed
disk topology invalidates only that Plan's baseline and requires an explicit
reseed; it never silently continues with a partial mapping.

## 4. Near-Real-Time Mode

`LIVE_MIRROR` uses the running QEMU source disk and remote NBD target. QEMU
mirrors guest writes while the VM remains on its krbd source disk. The mirror
target is not pivoted into the source VM.

FTCTL periodically establishes a durable boundary by querying the block job,
requesting a guest or block flush according to policy, recording mirror-ready
evidence, and committing a target checkpoint. On broker loss the job is
cancelled or recovered without starting the target VM. The UI exposes this as
near-real-time protection, not synchronous zero-RPO.

## 5. Failover And Failback

- Test failover clones or snapshots only the durable target artifact. The live
  writer is never attached to the test VM.
- Planned failover performs a final durable cycle, drains the target writer,
  confirms source isolation, then lets target Cloud start the replica.
- Disaster failover may use the latest durable target checkpoint without
  contacting the destroyed source site.
- Failback swaps the provider endpoints. The target site's active RBD is read
  through its broker and changed extents are applied to a Cloud-owned source RBD.
- Reprotect commits the reverse baseline before scheduled or live forward
  protection resumes.

## 6. Broker And Runtime State

Every site action is keyed by `plan_uuid`, `run_uuid`, `action`, and
`site_role`. Runtime files and terminal journals must be idempotent across Agent
or management-server retries. `dr-status --run` returns transfer bytes,
sequence, baseline generation, NBD teardown state, and terminal evidence.

No API credential, Cloud secret, or SSH private key is written into Plan state,
runtime status, events, or debug output.

## 7. Preflight Evidence (2026-08-24)

The 22 source host exposes QEMU `drive_mirror`, block-job control, and NBD server
commands. The sampled 22 and 32 hosts provide `qemu-nbd`, `rbd`, and
`/dev/nbd16` through `/dev/nbd31`. The 32 host has the FTCTL NBD firewall range
installed. Full cross-site port and signed-broker probes remain release gates.

## 8. Regression Tests

- one-disk RBD full seed and no-change incremental;
- changed-extents incremental and baseline rotation;
- interrupted incremental preserving the old baseline;
- live mirror start/checkpoint/stop and broker reconnect;
- test failover and cleanup while protection resumes;
- planned/disaster failover, failback, and reprotect;
- release with retain/delete resource dispositions;
- profile tombstone status after process restart;
- unchanged VMware-to-ABLESTACK contract suite.
