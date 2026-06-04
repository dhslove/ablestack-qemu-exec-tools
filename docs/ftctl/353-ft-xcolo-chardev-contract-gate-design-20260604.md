# FT XCOLO Chardev Contract Gate Design - 2026-06-04

## Background

Run 76 repeated the same QEMU-level failure signature captured in design 352:

```text
Primary QEMU:   filter mirror send failed(Operation not permitted)
Primary QEMU:   Received invalid message 0x0000 length 0x0000
Secondary QEMU: Can't receive COLO message: Input/output error
```

The diagnostic change from design 352 worked: the failure was classified as
`xcolo_filter_mirror_send_eperm` instead of the older generic startup-active
stream failure. The new evidence showed that TCP sockets can be established
while QEMU chardev frontends are not all open:

```text
primary mirror0  = present_closed
primary compare1 = present_open
secondary red0   = present_open
secondary red1   = present_closed
```

This means the next boundary is not storage type, checkpoint delay, or raw TCP
reachability. The boundary is whether the runtime COLO network filter graph has
usable QEMU chardev frontends at the point where the filter path is expected to
carry packets.

## Principle

Do not revisit already validated FT preparation steps unless new evidence
invalidates them:

- disk baseline seeding
- storage symmetry checks
- primary/secondary QEMU command generation
- 9003/9004/9998 TCP path capture
- primary migrate start
- existing invalid-message and EPERM classification

The new code must make the QEMU network filter contract explicit and must report
which edge is closed. It must not infer success from `ss ESTABLISHED` alone.

## COLO Chardev Contract

The runtime contract is:

```text
mirror path:
  primary m0 -> mirror0 -> secondary red0 -> f1

compare return path:
  secondary f2 -> red1 -> primary compare1 -> comp0
```

At startup-active/post-activation validation time, the required QMP
`query-chardev` state is:

```text
primary mirror0  = present_open
primary compare1 = present_open
secondary red0   = present_open
secondary red1   = present_open
```

`present_closed`, `missing`, `present_unknown`, and `query_failed` are contract
failures for this phase.

## Implementation Direction

Add a QMP-based contract capture function that queries both domains and persists:

- `xcolo_chardev_contract_ready`
- `xcolo_chardev_contract_reason`
- `xcolo_chardev_contract_mirror_path`
- `xcolo_chardev_contract_compare_path`
- `xcolo_chardev_contract_primary_mirror0`
- `xcolo_chardev_contract_primary_compare1`
- `xcolo_chardev_contract_secondary_red0`
- `xcolo_chardev_contract_secondary_red1`

Also persist phase-specific copies such as:

- `xcolo_post_migrate_startup_active_validation_chardev_contract_ready`
- `xcolo_post_migrate_post_activation_validation_chardev_contract_ready`
- `xcolo_post_activation_contract_chardev_contract_ready`

The startup-active validation path must wait briefly for the contract. If it
does not become ready:

1. If QEMU already logged `filter mirror send failed(...)` or primary migration
   already reports the invalid-message failure, keep the existing
   `xcolo_filter_mirror_send_eperm` classification and attach the contract
   fields to that failure.
2. Otherwise fail early with `last_error=xcolo_colo_chardev_contract_not_ready`
   and `xcolo_protocol_failure_phase=post_migrate_chardev_contract`.

## Retest Reporting Contract

For the next FT retest, the report must explicitly include:

- whether the contract gate ran
- whether the contract was `ready`, `no`, or `unknown`
- the mirror path state
- the compare path state
- whether the result is a repeated failure or a narrower/newer failure

If the same EPERM and invalid-message signature appears again but the contract
fields identify the closed edge, that is diagnostic progress. If the contract
fields are missing, the change failed to instrument the actual boundary and must
be corrected before another hypothesis is pursued.
