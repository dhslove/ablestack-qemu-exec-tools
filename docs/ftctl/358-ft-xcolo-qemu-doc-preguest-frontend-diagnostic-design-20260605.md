# FT XCOLO QEMU Doc Pre-Guest Frontend Diagnostic Design - 2026-06-05

## Problem

Run 81 proved that the previous stable RBD fix worked:

- all stable RBD contract phases passed
- primary generated listener bootstrap used `compare_bootstrap`
- primary and secondary TCP sockets for `9003` and `9004` reached established
  state before migrate
- topology, firewall, storage symmetry, and pre-migrate mirror-send guards
  passed

The run still failed before primary `migrate` because QMP `query-chardev`
reported:

```text
primary mirror0=present_closed
secondary red1=present_closed
```

This was classified as:

```text
last_error=xcolo_qemu_doc_runtime_frontend_closed
xcolo_protocol_failure_phase=pre_guest_traffic_doc_frontend_contract
```

That hard gate is stricter than the QEMU COLO procedure. The QEMU procedure
requires the documented topology and socket/channel setup before migration; it
does not require `query-chardev frontend-open=true` for every COLO chardev
before issuing `migrate`.

## Decision

For the pre-migrate/pre-guest boundary:

1. Keep collecting `query-chardev` for diagnostics.
2. Do not fail only because `frontend-open=false` or `present_closed`.
3. Treat closed frontend state as diagnostic evidence when:
   - QEMU document topology passed
   - socket snapshot shows expected listener/peer connectivity
   - pre-migrate mirror-send guard passed
   - primary is still paused/not running
4. Allow primary `migrate` to proceed.
5. Use post-migrate runtime validation to decide whether COLO actually entered
   a working FT state.

## State

When frontend-open is closed at the pre-guest boundary, FTCTL records:

```text
xcolo_pre_guest_traffic_gate=ready
xcolo_pre_guest_traffic_gate_policy=qemu_doc_topology_socket
xcolo_pre_guest_traffic_chardev_contract=no
xcolo_pre_guest_traffic_frontend_contract=diagnostic_closed
xcolo_pre_guest_traffic_frontend_contract_reason=<closed edge list>
xcolo_qemu_doc_runtime_frontend=diagnostic_closed
xcolo_qemu_doc_runtime_frontend_reason=<closed edge list>
```

It must not set:

```text
last_error=xcolo_qemu_doc_runtime_frontend_closed
xcolo_protocol_failure_phase=pre_guest_traffic_doc_frontend_contract
```

at this pre-migrate boundary.

## Retest Interpretation

The next run should move past the old pre-guest hard gate. Outcomes:

- If primary `migrate` is not issued, inspect topology/socket/mirror-send/RBD
  gates rather than `frontend-open`.
- If primary `migrate` is issued and fails, classify the QEMU migrate error from
  `query-migrate` and QEMU logs.
- If the repeated `invalid message 0x0000` / `Can't receive COLO message`
  appears after migrate, the issue is now a real COLO protocol/runtime problem,
  not a pre-migrate frontend-open gate problem.

## Supersedes

This document supersedes the pre-migrate hard frontend-open requirement in:

- `354-ft-xcolo-pre-guest-chardev-contract-gate-design-20260604.md`
- the `xcolo_qemu_doc_runtime_frontend_closed` retest interpretation in
  `356-ft-xcolo-premigrate-frontend-open-before-migrate-design-20260605.md`
