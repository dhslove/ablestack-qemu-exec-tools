# FT XCOLO Secondary Incoming PCI Deferred Gate Design - 2026-06-10

## Context

Run 106 validated that the previous hard gate correctly prevented the repeated
post-migrate secondary QEMU assertion.  It also exposed a stronger fact:
`primary.generated.xml` and `standby.generated.xml` already preserved the same
guest-visible PCI controller shape, including the `pcie-to-pci-bridge` alias
`pci.6` at bus `0x01`, slot `0x00`.

The failing evidence was from live HMP `info pci` before migration:

```text
primary:   bus=1 device=0 function=0 class=PCI bridge 1b36:000e id="pci.6"
secondary: bus=0 device=2 function=1 class=PCI bridge 1b36:000c id="pci.2"
```

The generated XML did not lose `pci.6`; rather, the secondary was still in
`-incoming` state.  In that state QEMU can report root ports with
`secondary bus 0`, `subordinate bus 0`, and unmapped BARs before incoming
migration realizes the final PCI bus assignment.

## Problem

Treating secondary pre-migrate `info pci` as an absolute ABI equality check is
too strict for `-incoming` runtimes.  It can stop a valid generated XML/QEMU
argv pair before `primary.migrate`, even though the secondary has not yet
realized all PCI bus numbers.

At the same time, the previous repeated `memory_region_add_subregion_common`
QEMU assertion must not be allowed to become invisible again.

## Design

1. Keep the hard checks for generated QEMU argv guest devices.
   - Empty argv snapshots remain failures.
   - Missing guest `-device` entries remain failures.
   - Primary/secondary guest `-device` mismatches remain failures.

2. Keep hard failure for real PCI identity mismatch.
   - If both primary and secondary `info pci` snapshots are fully assigned and
     the identity records differ, fail with
     `xcolo_live_pci_identity_mismatch`.

3. Add an explicit deferred state for secondary incoming PCI snapshots.
   - If generated argv devices match, but secondary `info pci` has multiple PCI
     bridges with `secondary bus 0`, `subordinate bus 0`, and unmapped BARs,
     record:

```text
warning=xcolo_live_pci_identity_deferred_for_incoming
xcolo_live_pci_identity=deferred
```

   - Do not fail before `primary.migrate` solely for this deferred PCI shape.

4. Preserve evidence for follow-up.
   - Continue saving first PCI identity diff index and primary/secondary
     records.
   - Continue collecting qtree, mtree, argv, QMP block/chardev/status snapshots.
   - If migration later fails, the failure can be correlated with the deferred
     PCI state instead of losing the evidence.

## Non-Goals

- Do not remove the generated XML/argv ABI checks.
- Do not reintroduce hotplug or runtime device mutation for protected disks.
- Do not use `/dev/rbdN` as a persistent XML identity.  ABLESTACK must continue
  using stable `/dev/rbd/rbd/<image>` paths in libvirt XML and native RBD specs
  in generated QEMU command-line disk graph.

## Expected Retest Result

The next run should pass the pre-migrate live topology gate when the only
difference is the secondary incoming PCI-unassigned shape.  If QEMU still fails
after `primary.migrate`, the failure is no longer hidden behind a false
pre-migrate gate and must be analyzed as an actual migration/runtime issue.
