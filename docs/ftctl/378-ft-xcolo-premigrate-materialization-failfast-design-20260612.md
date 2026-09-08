# FT XCOLO Pre-Migrate Materialization Fail-Fast Design

Date: 2026-06-12

Update: this document defines the crash-prevention fail-fast gate. The root
topology fix is extended by
`379-ft-xcolo-canonical-pci-manifest-and-rollback-design-20260616.md`, which
adds generated Primary/Secondary PCI manifest equality and rollback graph
restoration checks.

## Background

Run 114 disproved the Run 113 assumption that an incoming secondary with
unassigned PCI/BAR resources can safely proceed to `primary.migrate`.

Run 114 reached the furthest stable point so far:

- baseline seed completed;
- generated primary and secondary XML startup completed;
- COLO channel attach completed;
- pre-migrate guest traffic gate passed;
- `primary.migrate` returned success;
- post-migrate startup active validation passed;
- 9003/9004 sockets were established.

Immediately after that, the secondary QEMU process crashed while applying
migration state:

```text
qemu-kvm: ../system/memory.c:2666: memory_region_add_subregion_common:
Assertion `!subregion->container' failed.
```

The captured runtime topology still showed the same unsafe condition before
migration:

- primary PCI identity count: `18`;
- secondary PCI identity count: `12`;
- PCI identity missing count: `6`;
- primary zero-range PCI alias count: `0`;
- secondary zero-range PCI alias count: `48`;
- assert candidate: `secondary_zero_range_pci_alias`.

Therefore the prior deferred-pre-migrate policy was not a valid path to a
stable COLO runtime. It allowed QEMU to enter a known crash path.

## Principle

FTCTL must not issue `primary.migrate` when the secondary incoming VM has not
materialized the PCI/mtree resources needed to accept the primary migration
state.

This is a safety gate, not a final topology fix. If the secondary is still in
an unmaterialized incoming state, FTCTL must fail before migration with clear
evidence instead of allowing QEMU to assert.

The no-hot-plug rule remains unchanged:

- FTCTL must not mutate the protected primary or secondary topology dynamically
  after startup to make migration pass;
- generated primary and secondary startup command lines remain the only place
  where COLO-specific disk, filter, chardev, and migration ABI wiring is built;
- `/dev/rbd/rbd/<image>` remains the stable RBD path policy. FTCTL must not use
  `/dev/rbdN` as the durable XML or QEMU command-line contract.

## Design

### Pre-Migrate Live PCI Gate

`ftctl_xcolo_verify_live_runtime_topology_pair()` must fail before
`primary.migrate` when the secondary `info pci` has the incoming-unassigned
shape:

- root ports report `secondary bus 0` / `subordinate bus 0`;
- BARs or other PCI resources are not mapped;
- primary and secondary PCI identity records differ because the secondary has
  not materialized bridge/device resources.

The failure must be:

```text
xcolo_secondary_pci_resource_unmaterialized_before_migrate
```

The evidence must include:

- primary/secondary PCI identity counts;
- PCI identity diff/missing/extra counts;
- raw PCI resource diff count;
- first PCI identity diff;
- primary/secondary QEMU argv and live topology debug files.

### Pre-Migrate mtree Gate

`ftctl_xcolo_analyze_runtime_topology_diff()` must also fail before migration
when the secondary mtree has substantially more zero-range PCI aliases than the
primary.

The same error is used:

```text
xcolo_secondary_pci_resource_unmaterialized_before_migrate
```

This prevents the Run 114 failure shape from reaching QEMU's migration state
application path.

### Post-Migrate Gate

The post-migrate materialization gate remains a hard failure, but it should now
be a last line of defense. The expected path is that the same condition is
caught before migration.

Post-migrate zero-range PCI aliases continue to report:

```text
xcolo_post_migrate_secondary_pci_resources_unmaterialized
```

### Progress Management

Each retest must record whether the same repeated blocker is present:

- if `xcolo_secondary_pci_resource_unmaterialized_before_migrate` appears, this
  is the same materialization blocker caught earlier and safer than Run 114;
- if QEMU still reaches `memory_region_add_subregion_common`, the pre-migrate
  gate is incomplete and the captured live topology evidence must be extended;
- if the gate passes and a later error appears, that is new progress and must be
  classified by phase.

## Expected Retest Result

The next run should not reach the QEMU assertion if the same Run 114 topology
condition appears again.

Acceptable next outcomes:

1. FTCTL fails before `primary.migrate` with
   `xcolo_secondary_pci_resource_unmaterialized_before_migrate`, preserving
   topology evidence. This confirms the crash-prevention gate works.
2. The secondary is fully materialized before migration and the flow moves past
   the previous assertion point. In that case, the next failure, if any, must be
   analyzed as a new phase.

Unacceptable outcome:

- the same unmaterialized secondary PCI/mtree condition reaches `primary.migrate`
  and QEMU asserts again.
