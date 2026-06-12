# FT XCOLO Pre-Migrate PCI Identity Hard ABI Gate Design

Date: 2026-06-10

## Background

Run 112 proved that the Run 111 deferred secondary mtree materialization
strategy is unsafe for QEMU 9.2.4 X-COLO startup.

The run made real progress:

- the old pre-migrate mtree zero-alias gate no longer blocked the flow;
- `primary.migrate` was issued and accepted;
- the primary/secondary guest device command hash matched;
- the primary/secondary block graphs were valid;
- the network chardev contract was ready before guest traffic.

The secondary then failed while QEMU applied migration state:

```text
qemu-kvm: ../system/memory.c:2666: memory_region_add_subregion_common:
Assertion `!subregion->container' failed.
```

The captured evidence showed live PCI identity mismatch immediately before
migration:

- primary PCI identity count: `18`
- secondary PCI identity count: `12`
- missing secondary PCI identities: `6`

This means that a secondary incoming VM with unmaterialized PCI bridge/device
identity is not a safe destination for QEMU migration state, even when qtree
guest devices and block graphs look compatible.

## Principle

2026-06-10 update after Run 113: this document's pre-migrate hard failure rule
for an incoming secondary with unassigned PCI/BAR resources was temporarily
superseded by
`377-ft-xcolo-incoming-secondary-premigrate-deferred-pci-design-20260610.md`.

2026-06-12 update after Run 114: the deferral rule was proven unsafe because it
allowed the same condition to reach QEMU's migration state application path and
trigger `memory_region_add_subregion_common` assertion. The active rule is now
`378-ft-xcolo-premigrate-materialization-failfast-design-20260612.md`, which
restores fail-fast behavior with the explicit error:

```text
xcolo_secondary_pci_resource_unmaterialized_before_migrate
```
The hard failure rule remains valid after migration state has been loaded. At
`before_migrate`, the known incoming-secondary unassigned shape is now treated
as an explicit deferred warning.

For FT/X-COLO, pre-migrate ABI compatibility is stricter than "same requested
devices". The secondary must be a migration-compatible live target before
`primary.migrate` is allowed.

Run 112 therefore required:

1. Do not treat `xcolo_live_pci_identity_deferred_for_incoming` as a successful
   pre-migrate condition.
2. Do not allow secondary zero-range PCI bridge aliases to be deferred past
   `primary.migrate`.
3. If the secondary live PCI identity or mtree bridge materialization is not
   compatible, stop before `primary.migrate` with a clear FTCTL error instead
   of allowing QEMU to crash.
4. Preserve all debug evidence needed for the next topology-cloning change:
   primary/secondary QEMU argv, `info pci`, `info qtree`, `info mtree`, block
   graph, and chardev snapshots.

Run 113 supersedes item 1 for the specific incoming-secondary unassigned shape
at `before_migrate`. That shape is now a deferred warning before migration and a
hard failure after migration.

## Immediate Code Change

### Live PCI Identity Gate

Current behavior:

- if secondary `info pci` looks like an incoming VM with unassigned bridge
  resources, emit:
  `warning=xcolo_live_pci_identity_deferred_for_incoming`;
- return success and allow the next stage.

Run 112 new behavior:

- emit `error=xcolo_live_pci_identity_unmaterialized`;
- record the first primary/secondary PCI identity difference and count fields;
- fail the pre-migrate gate before `primary.migrate`.

Run 113 superseding behavior:

- at `before_migrate`, emit
  `warning=xcolo_live_pci_identity_deferred_for_incoming` for the known incoming
  secondary unassigned shape and continue;
- after migration, keep `xcolo_live_pci_identity_unmaterialized` as a hard
  failure.

### Mtree Zero-Alias Gate

Current behavior:

- in pre-migrate context, materially more secondary zero-range PCI aliases
  produce:
  `xcolo_pre_migrate_secondary_pci_resources_deferred_for_incoming`;
- the caller treats `deferred` as success.

Run 112 new behavior:

- in pre-migrate context, materially more secondary zero-range PCI aliases
  produce:
  `xcolo_pre_migrate_secondary_pci_resources_unmaterialized`;
- the caller treats this as a hard failure.

Run 113 superseding behavior:

- in pre-migrate context, materially more secondary zero-range PCI aliases
  produce:
  `xcolo_pre_migrate_secondary_pci_resources_deferred_for_incoming`;
- after migration, zero-range PCI aliases remain a hard materialization failure.

## Next Topology-Cloning Direction

This change intentionally does not hide the remaining topology problem. It
prevents an unsafe QEMU assertion and leaves a precise blocker.

The next successful FT implementation step must make the secondary live PCI
identity match the primary before migration. The most likely correction area is
secondary command construction:

- primary devices are created by libvirt and appear in the QEMU argv in a stable
  order;
- secondary currently keeps some XML-created devices and appends FT scsi/disk
  devices via `qemu:commandline`;
- this can make the requested guest-device hash match while live PCI identity
  still differs.

The follow-up topology-cloning change should derive the secondary startup order
from the primary libvirt QEMU argv, preserving:

- bridge/root-port order;
- controller order;
- `virtio-scsi-pci` placement;
- disk device placement;
- network/filter placement required by the QEMU COLO command sample.

Until that is implemented and proven, FTCTL must fail before migration rather
than reaching QEMU's memory-region assertion.

## Expected Result

The next test is considered improved if:

- QEMU no longer crashes with
  `memory_region_add_subregion_common`;
- FTCTL stops before `primary.migrate` with
  `xcolo_live_pci_identity_unmaterialized` or
  `xcolo_pre_migrate_secondary_pci_resources_unmaterialized`;
- debug evidence shows the exact primary/secondary PCI identity counts and
  first differing bridge/device.

The next test is not considered successful FT activation yet unless secondary
PCI identity/materialized bridge topology matches primary and migration proceeds
without assertion.
