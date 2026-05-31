# FT X-COLO Runtime Netdev Aware Filter Design

## Background

The FT X-COLO protection path reached a later runtime stage: the primary and secondary channels were established, the secondary entered `colo`, and the primary migration stayed `active`. The final failure was classified as:

```text
xcolo_runtime_validation_failed:primary_filter_chardev_frontend_incomplete
```

The runtime evidence showed the primary filter objects existed, but their chardev frontends were not fully bound. The previous generated command line assumed that the guest NIC netdev was always `hostnet0`:

```text
filter-mirror,id=m0,netdev=hostnet0
filter-redirector,id=redire0,netdev=hostnet0
filter-redirector,id=redire1,netdev=hostnet0
```

That assumption is too narrow for cloud-managed VMs. Libvirt normally maps the first interface alias `net0` to QEMU netdev `hostnet0`, but this must be resolved from the generated domain XML instead of treated as a constant.

## Design Principle

FT must preserve the shared goal of a true primary clone:

- The secondary is a runtime clone of the primary, including network identity.
- Primary failure must allow the secondary to continue the same service identity.
- X-COLO packet filters must bind to the actual QEMU netdev backing the guest NIC.
- A false success is worse than a delayed success. Runtime success remains gated on active X-COLO roles, block graph readiness, and filter/chardev binding.

## Required Behavior

During block-backed cold conversion:

1. Resolve the primary NIC netdev ID from the primary XML before generating `qemu:commandline`.
2. Resolve the secondary NIC netdev ID from the standby XML before generating `qemu:commandline`.
3. Prefer a libvirt interface alias such as `net0` to infer `hostnet0`; otherwise use the interface index.
4. Store the resolved values in FTCTL state:
   - `xcolo_primary_netdev_id`
   - `xcolo_secondary_netdev_id`
   - alias, target, and model diagnostic fields
5. Generate primary and secondary X-COLO filter objects with the resolved netdev ID.
6. Use the same resolved netdev ID for:
   - XML command-line generation
   - QMP fallback `object-add`
   - command-line validation
   - QOM validation

## Failure Classification

The runtime validation must distinguish these cases:

- `primary_filter_netdev_id_unresolved`
  - The primary XML did not contain a usable interface.
- `secondary_filter_netdev_id_unresolved`
  - The standby XML did not contain a usable interface.
- `primary_filter_netdev_not_found`
  - The generated/attached filter chain does not refer to the resolved netdev.
- `primary_filter_chardev_frontend_incomplete`
  - The filter objects are present, but their chardev frontends are still closed or incomplete.
- `primary_qemu_colo_role_transition_failed`
  - Capabilities, filters, channels, and block graph look valid, but QEMU still did not enter the primary COLO role.

## Compatibility

For single-NIC VMs with alias `net0`, the resolved value remains `hostnet0`, so existing 32.x FT tests should keep the same visible command-line shape. The important change is that this is now a derived runtime contract rather than a hardcoded assumption.

This document supersedes earlier examples in documents 319 through 322 where `hostnet0` was shown as a fixed value. Those examples should be read as the common single-NIC result, not as a required constant.

Follow-up design 327 keeps this netdev resolution contract and adds a QMP runtime rebuild path for the primary filter/chardev graph when XML command-line injection is present but the primary chardev frontends do not stay bound.
