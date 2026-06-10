# FT XCOLO Secondary Mtree Deferred Materialization Design

Date: 2026-06-10

## Superseded Scope

Run 112 proved that this deferred-materialization strategy is unsafe as a
pre-migrate success condition for QEMU 9.2.4. It allowed `primary.migrate` to
start while the secondary live PCI identity was still not materialized like the
primary, and QEMU then asserted in
`memory_region_add_subregion_common`.

This document remains as historical evidence for the hypothesis tested in Run
112, but its "defer and continue to migrate" rule is superseded by
`376-ft-xcolo-premigrate-pci-identity-hard-abi-gate-design-20260610.md`.
From that design forward, secondary live PCI identity or mtree PCI resource
unmaterialization must fail before `primary.migrate`.

## Background

Run 111 stopped before `primary.migrate` with:

```text
last_error=xcolo_pre_migrate_secondary_pci_resources_unmaterialized
qtree_diff_count=0
mtree_diff_count=497
mtree_primary_zero_pci_alias_count=0
mtree_secondary_zero_pci_alias_count=48
```

This was progress over Run 110 because the secondary QEMU assertion was avoided.
However, it also showed that the current pre-migrate mtree gate is too strict
for a secondary QEMU running in `-incoming` mode.

QEMU can create the secondary guest with the same guest-visible qtree and command
contract while leaving some PCI bridge aliases and BAR-backed mtree regions as
zero-range placeholders until migration state is applied. FTCTL must distinguish
that deferred incoming shape from a real guest topology mismatch.

## Design Principle

Do not manually assign PCI BAR ranges in FTCTL.

FTCTL owns the generated command-line contract and topology validation. QEMU owns
runtime BAR/mtree materialization through migration state. Therefore the correct
contract is:

1. before migrate, primary and secondary guest-visible topology must match;
2. if the only mismatch is secondary zero-range PCI aliases in incoming state,
   record it as deferred and allow one migrate attempt;
3. after migrate, secondary mtree must converge. If zero-range aliases remain,
   fail with a post-migrate materialization error.

## Implementation

### Pre-Migrate

`ftctl_xcolo_analyze_runtime_topology_diff()` keeps hard failures for:

- empty secondary qtree;
- empty secondary mtree;
- missing guest qtree devices.

For secondary zero-range PCI alias differences:

- if qtree devices match and no guest device is missing, mark:

```text
topology_gate_state=deferred
topology_gate_error=xcolo_pre_migrate_secondary_pci_resources_deferred_for_incoming
```

- do not fail registration at this point;
- record the zero alias counts and the first zero alias as evidence.

`ftctl_xcolo_require_pre_migrate_runtime_topology_gate()` accepts both `ok` and
`deferred`, but emits the deferred state in `events.log` and state files.

### Post-Migrate

After `primary.migrate`, but before filter activation is treated as stable,
FTCTL captures primary/secondary `info pci`, `info qtree`, and `info mtree`
again and analyzes them as `post_migrate_materialization`.

Hard failures after migrate:

- secondary qtree empty;
- secondary mtree empty;
- guest qtree devices missing;
- secondary zero-range PCI alias count still materially exceeds primary.

The post-migrate failure is explicit:

```text
xcolo_protocol_failure_phase=post_migrate_materialization
last_error=xcolo_post_migrate_secondary_pci_resources_unmaterialized
```

## Non-Goals

- Do not hotplug disks, NICs, controllers, or bridges.
- Do not change the already aligned QEMU COLO command sample order.
- Do not use `/dev/rbdN` as a persistent disk identity.
- Do not treat `red0` connection refusal as the root cause until the mtree
  materialization contract is settled.

## Repetition Guard

If the next run reaches `primary.migrate` and then fails with
`xcolo_post_migrate_secondary_pci_resources_unmaterialized`, that is progress:
the pre-migrate gate is no longer blocking incoming deferred state, but QEMU
still did not materialize secondary PCI resources after migration.

If the next run still fails before `primary.migrate` with
`xcolo_pre_migrate_secondary_pci_resources_unmaterialized`, this change did not
take effect or guest topology was no longer equal. Inspect qtree missing/extra
device counts before changing network or chardev logic.
