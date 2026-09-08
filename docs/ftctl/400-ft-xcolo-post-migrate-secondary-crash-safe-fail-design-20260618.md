# FT XCOLO Post-Migrate Secondary Crash Safe-Fail Design

Date: 2026-06-18

## Context

Run 121 proved that the current FT path can pass the pre-migrate receiver gates
and reach the real COLO migration phase:

- secondary `migrate-incoming` succeeds;
- pre-migrate receiver readiness is recorded;
- primary `query-migrate` reaches `colo`;
- primary remains paused while the secondary QEMU process crashes.

The secondary QEMU log again shows:

```text
memory_region_add_subregion_common: Assertion `!subregion->container' failed.
```

This is not a new generated manifest problem. The generated PCI manifest and
startup intent gates are already active. The remaining blocker is runtime
materialization equality after migration state is applied.

## Non-Goal

This change does not claim to make the secondary runtime topology fully equal to
the primary runtime topology. That is still the core FT correctness problem.

The immediate goal is safer failure handling and better evidence:

1. do not hide a secondary crash behind a transient post-migrate wait;
2. do not leave the primary stuck in `colo`/`paused`;
3. preserve the exact post-migrate evidence required for the next topology
   equality fix.

## QEMU COLO Contract Applied

QEMU COLO requires both sides to remain alive after the primary `migrate`
command transitions the pair. When the secondary dies, the primary side must be
treated as a primary-failover recovery case, not as a successful protected
state.

Therefore `primary query-migrate = colo` is not sufficient for success.
Success requires the secondary QMP path, migration state, chardev contract, and
post-migrate materialization gate to remain valid.

## Implementation Plan

### 1. Fail Fast During Role Transition

`ftctl_xcolo_wait_post_migrate_role_transition()` polls the post-migrate role
transition state. Each poll now checks for a secondary failure pattern:

- primary migration is `active` or `colo`, or primary COLO mode is `primary`;
- secondary QMP status/migration state cannot be queried;
- chardev contract reports `secondary_query_failed` or transient query failure;
- secondary QEMU log contains the memory-region assertion or crash marker.

When this pattern is found, the gate fails immediately with:

```text
xcolo_protocol_failure_phase=post_migrate_secondary_crash
xcolo_post_migrate_secondary_failure_detected=yes
xcolo_post_migrate_secondary_failure_reason=...
xcolo_primary_safe_fail_recovery_required=yes
```

The repeated assertion is also recorded:

```text
xcolo_repeated_failure_signature=memory_region_add_subregion_common
```

### 2. Preserve Recovery Intent

Runtime recovery already destroys the generated primary runtime and restores the
Cloud/libvirt managed backup. This path is now marked as a safe-fail recovery:

```text
xcolo_primary_safe_fail_recovery=restored_from_backup
xcolo_primary_safe_fail_recovery_cause=<original failure>
cloud_runtime_restore_needs_reconcile=yes
```

The qemu-side code does not update Cloud DB directly. It records the runtime
truth so the Cloud/Mold layer can reconcile lifecycle state.

### 3. Preserve ABI Evidence

On secondary failure, FTCTL captures:

- primary and secondary QEMU log tails;
- socket snapshots;
- chardev contract snapshots;
- live QEMU argv;
- qtree, `info pci`, mtree, and materialization pipeline summaries.

The next topology-equality fix must be based on this evidence. It must not
revert to static manifest edits unless the evidence shows generated manifest or
argv divergence.

## Retest Expectations

If the secondary runtime still crashes, the next run must fail faster and safer:

```text
xcolo_post_migrate_secondary_failure_detected=yes
xcolo_protocol_failure_phase=post_migrate_secondary_crash
xcolo_primary_safe_fail_recovery_required=yes
```

The primary must not remain indefinitely paused in COLO with a still-running
protect command.

If the assertion is observed again, it must be reported as the same repeated
post-migrate runtime materialization blocker, not as a new network or chardev
issue.
