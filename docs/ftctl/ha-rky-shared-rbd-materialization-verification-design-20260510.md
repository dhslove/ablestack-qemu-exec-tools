# HA-RKY Shared RBD Materialization Verification Design

## 1. Background

HA-RKY full-path retest on 2026-05-10 failed at `HA-RKY-09-FAILOVER-GUEST`.

Observed evidence:

- failover action completed and the standby VM started
- the standby console reported `No bootable device`
- source root RBD had boot-sector data
- target root/data RBD images were still `USED 0 B`
- FTCTL recorded blockcopy progress as `100%` and `ready=true`

The failure means the control plane accepted libvirt/QEMU blockcopy readiness before proving that the Cloud-created standby RBD targets actually contained usable data.

## 2. Non-Goal

Do not replace the shared RBD target model.

The KRBD target path model, `/dev/rbd/rbd/<image>`, remains the shared-blockcopy target for this path. It has already been validated in earlier shared-visible RBD tests, so this change must not switch shared RBD targets to network RBD XML.

## 3. Root-Cause Hypotheses

The highest-risk paths are:

1. Existing Cloud-managed target volumes were passed through the XML blockcopy path without `--reuse-external`.
2. Thin-preserve attributes, `discard='unmap' detect_zeroes='unmap'`, can make a target appear logically ready while the RBD image remains physically empty unless materialization is verified.
3. Parent-backed source RBD handling became less strict after the default changed to defer flattening.
4. QMP blockjob progress and runtime mirror readiness were treated as final replication success.

## 4. Final Design

### 4.1 Keep KRBD Shared Target

Continue using block XML targets backed by `/dev/rbd/rbd/<image>` for shared RBD HA/DR. The implementation only hardens option selection and completion verification.

### 4.2 Reuse Existing Cloud Targets

When the provisioning backend is `cloud-managed`, shared XML blockcopy starts with `--reuse-external`.

This matches the Cloud-managed lifecycle: Cloud creates the standby volume and FTCTL mirrors into that existing target. FTCTL must not rely on libvirt/QEMU to create a new target implicitly.

### 4.3 Verify Target Materialization

After all blockcopy jobs report ready, FTCTL enters a `verifying` transport state and checks each RBD/KRBD target before switching to `protected/mirroring`.

Verification rules:

- if source RBD has allocated data and target RBD reports `USED 0 B`, fail
- if the source head sample is non-zero and differs from the target head sample, fail

Failure state:

- `protection_state=error`
- `transport_state=failed`
- `last_error=blockcopy_target_not_materialized:<targets>`
- event `blockcopy.verify` with `result=fail`

### 4.4 Parent-Backed Source Policy

Default RBD parent policy returns to `flatten-on-protect`.

If a source RBD has a parent, FTCTL flattens it before protect and then runs `rbd sparsify` to recover thin allocation. Defer mode remains possible only as an explicit override, and target verification still applies.

### 4.5 Progress Is Not Completion

FTCTL keeps progress as a host-side event/progress-file source. VM details are not used as a progress source.

`progress=100%` means QEMU blockjob readiness only. Final success requires materialization verification.

Expected state flow:

`syncing/copying` -> `syncing/verifying` -> `protected/mirroring`

## 5. Implementation Notes

- `ftctl_blockcopy_start_shared_xml_job` accepts a reuse flag and appends `--reuse-external`.
- `ftctl_blockcopy_refresh_vm_jobs` performs materialization verification before setting `protected/mirroring`.
- `FTCTL_BLOCKCOPY_VERIFY_TARGET=1` enables verification by default.
- `FTCTL_BLOCKCOPY_VERIFY_BYTES=4096` controls the head sample size.
- Existing KRBD mapping and XML target construction remain unchanged.
