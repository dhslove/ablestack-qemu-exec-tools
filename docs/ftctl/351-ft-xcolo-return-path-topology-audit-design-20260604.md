# FT XCOLO Return-Path Topology Audit Design - 2026-06-04

## Background

Run 74 validated the premigrate-active filter change from design 350:

- no normal-path `primary.filter_status_on.*` event was emitted
- primary filters were present and active before `primary.migrate`
- `xcolo_primary_net_filters_activation_mode=startup-active`
- `xcolo_primary_filter_activation_stage=premigrate_active`
- primary and secondary sockets reached an established state

The run still failed with the repeated QEMU protocol signature:

```text
Primary QEMU:   Received invalid message 0x0000 length 0x0000
Secondary QEMU: Can't receive COLO message: Input/output error
```

This means the active failure is no longer filter activation timing. TCP
connectivity also is not enough to explain or clear the failure. The socket can
be established while the QEMU COLO return-path protocol stream is still invalid
or closed by one side.

## Principle

Do not alter the premigrate-active topology from design 350 while diagnosing the
next failure. The next change must make the actual runtime topology observable
and must stop before `primary.migrate` only when a concrete documented topology
mismatch is found.

The investigation must distinguish:

- TCP reachability: listen/connect/firewall evidence
- QEMU commandline topology: the objects and chardevs QEMU actually started
- QOM topology: the properties QEMU exposes at runtime
- COLO return-path state: migration status, COLO role, and 9998 socket state
- QEMU-side failure text: primary and secondary libvirt/QEMU logs

## QEMU Topology Contract

The primary side must match the documented COLO packet path:

- `filter-mirror m0`
  - `netdev=<primary-netdev>`
  - `queue=tx`
  - `outdev=mirror0`
- `filter-redirector redire1`
  - `netdev=<primary-netdev>`
  - `queue=rx`
  - `outdev=compare0`
- `colo-compare comp0`
  - `primary_in=compare0-0`
  - `secondary_in=compare1`
  - `outdev=compare_out0`
- `filter-redirector redire0`
  - `netdev=<primary-netdev>`
  - `queue=rx`
  - `indev=compare_out`

The secondary side must expose the counterpart packet path:

- TX redirector sends packets from the secondary netdev to the primary compare
  peer channel
- RX redirector receives packets from the primary compare output channel
- `filter-rewriter` is present on the secondary netdev
- incoming migration endpoint is active before the primary starts migration

## Design

### Premigrate Audit

Add a `ftctl_xcolo_require_topology_audit_ready` gate immediately before
`primary.migrate`.

The gate does not replace existing firewall, channel, storage, QOM, or command
line checks. It consolidates the primary and secondary topology result into a
single decision:

- `xcolo_topology_audit=ok`: continue to `primary.migrate`
- `xcolo_topology_audit=failed`: stop before migrate
- `xcolo_topology_audit_reason=<comma-separated-mismatch-list>`

Primary checks reuse the existing QOM and commandline validation. Secondary
checks add a commandline topology parser because the previous code mostly
validated the primary side.

### Failure Evidence

On runtime validation failure, collect and persist:

- primary and secondary QMP snapshots
- primary and secondary QEMU process command lines
- primary and secondary libvirt/QEMU log tails
- primary and secondary topology audit state
- socket state before and after the failure

The debug directory remains:

```text
${FTCTL_RUN_DIR}/debug/xcolo/<vm-key>
```

New files:

- `primary-qemu-process-cmdline.txt`
- `secondary-qemu-process-cmdline.txt`
- `primary-qemu-log-tail.txt`
- `secondary-qemu-log-tail.txt`

### Protocol Subreason

When primary migration fails with the invalid-message signature and the previous
preconditions are ready, classify more narrowly:

- `return_path_protocol_closed_after_startup_active`
  - primary 9998 moved from established to closed
  - secondary reached `colo` or COLO `secondary`
- `topology_audit_failed`
  - the new topology audit found a concrete mismatch
- `qemu_return_path_invalid_zero_header`
  - topology audit was ok, sockets were observed, but primary still received
    the zero message header

The top-level error may remain `xcolo_repeated_protocol_invalid_message`, but
the subreason must be specific enough to prevent another generic timing loop.

## Implementation Steps

1. Add secondary QEMU commandline capture.
2. Add primary and secondary QEMU log tail capture.
3. Add secondary commandline topology validation.
4. Add combined premigrate topology audit gate before `primary.migrate`.
5. Enrich invalid-message reason classification with topology and return-path
   socket state.
6. Record this design and the next run expectation in the progress document.

## Next Test Expectation

The next run is progress only if it produces one of these results:

- FT reaches steady state.
- The new premigrate topology audit blocks with a concrete missing or miswired
  object.
- The same invalid-message signature repeats with topology audit `ok`, in which
  case the next change must target QEMU return-path protocol semantics or QEMU
  binary/runtime parity, not another filter activation timing change.

## Supersedes Nothing

This design does not supersede design 350. It extends it. The normal path stays
premigrate-active; this document only adds topology audit and better
return-path failure evidence.
