# FT XCOLO Pre-Guest Chardev Contract Gate Design - 2026-06-04

## Background

The latest r97-link-01 FT run no longer failed as an unknown COLO protocol
stream issue. The previous chardev contract diagnostics identified the precise
closed frontend edges:

- primary mirror path: `primary:m0 -> mirror0(present_closed) -> secondary:red0(present_open) -> f1`
- compare return path: `secondary:f2 -> red1(present_closed) -> primary:compare1(present_open) -> comp0`

The primary QEMU log then reported:

- `filter mirror send failed(Operation not permitted)`
- `Received invalid message 0x0000 length 0x0000`

The secondary QEMU log reported:

- `Can't receive COLO message: Input/output error`

This means TCP reachability and topology presence are not enough. The COLO
network path must not be considered ready until the QEMU chardev frontends that
back the mirror and compare paths are open.

## Problem

The primary domain is currently started with startup-active COLO network
filters. The post-migrate contract check runs after the primary filter can
already attempt to send guest TX traffic through `m0 -> mirror0`.

That ordering is too late. If `mirror0` or `red1` is still
`present_closed`, QEMU can fail the filter send path before ftctl reaches the
diagnostic gate. The result is a protocol-level invalid message, which is a
downstream symptom rather than the first failure.

## Design Principles

- Keep the existing COLO topology and startup-active filter work intact unless
  evidence proves that topology itself is wrong.
- Do not regress storage, firewall, checkpoint-delay, or topology validations
  that already moved the boundary forward.
- Treat TCP established state as a prerequisite, not as proof of COLO readiness.
- Treat the QEMU chardev frontend contract as the activation boundary for guest
  traffic.
- When the contract is broken, fail before migrate/guest traffic can produce
  `filter mirror send failed(Operation not permitted)`.
- Preserve phase-specific evidence so repeated failures can be compared without
  falling back to generic `invalid message` diagnosis.

## Superseded Contract

This hard pre-migrate frontend-open contract is superseded by:

- `358-ft-xcolo-qemu-doc-preguest-frontend-diagnostic-design-20260605.md`

Run 81 proved that `query-chardev frontend-open=false` can coexist with:

- QEMU document topology passing
- TCP sockets for `9003` and `9004` established
- stable RBD contract passing at all conversion boundaries
- no pre-migrate `filter mirror send failed(...)`

Therefore, before primary `migrate`, the chardev frontend-open state is
diagnostic evidence, not a hard failure condition. The older design below is
retained only as historical context for why the diagnostic fields exist.

## Historical Required Contract

Before primary guest traffic is allowed to proceed into the COLO network
filters, the following query-chardev states must all be `present_open`:

- primary `mirror0`
- primary `compare1`
- secondary `red0`
- secondary `red1`

The gate records both paths:

- mirror path: `primary:m0 -> mirror0 -> secondary:red0 -> f1`
- compare path: `secondary:f2 -> red1 -> primary:compare1 -> comp0`

## Runtime Flow

1. Start the generated primary domain with COLO XML and filters, but keep the
   guest stopped by `-S`.
2. Start the secondary domain.
3. Confirm TCP listeners and peer connections for `9003`, `9004`, and `9998`.
4. Attach block graphs and export NBD disks.
5. Set and verify migration capabilities and checkpoint-delay.
6. Run firewall and topology audits.
7. Run the diagnostic `pre_guest_traffic_contract` capture:
   - capture primary/secondary `query-status`
   - capture socket state
   - capture primary/secondary `query-chardev`
   - record closed frontends as diagnostic evidence
   - do not fail solely because a QEMU chardev reports `frontend-open=false`
8. If topology, sockets, RBD contract, and premature mirror-send guards pass,
   issue primary `migrate`.
9. Keep the post-migrate contract check as a second validation point.

## Failure Behavior

If the primary is already running before the contract is validated:

- `last_error=xcolo_pre_guest_primary_not_paused`
- `xcolo_protocol_failure_phase=pre_guest_traffic_contract`

Historical failure behavior, now superseded for the pre-migrate boundary:

- `last_error=xcolo_colo_chardev_contract_not_ready_before_guest_traffic`
- `xcolo_protocol_failure_phase=pre_guest_traffic_contract`
- `xcolo_pre_guest_traffic_gate=failed`
- `xcolo_pre_guest_traffic_gate_reason=<closed edge list>`

If the QEMU COLO document startup topology audit has already passed, but the
contract still shows closed chardev frontends, the failure is classified more
specifically:

- `last_error=xcolo_qemu_doc_runtime_frontend_closed`
- `xcolo_protocol_failure_phase=pre_guest_traffic_doc_frontend_contract`
- `xcolo_qemu_doc_runtime_frontend=closed`
- `xcolo_qemu_doc_runtime_frontend_reason=<closed edge list>`

This distinction is important: it means the command line shape follows the
documented COLO sample, and the remaining issue is the runtime frontend state
of the QEMU chardev graph.

Current behavior records the same evidence as:

- `xcolo_pre_guest_traffic_gate=ready`
- `xcolo_pre_guest_traffic_gate_policy=qemu_doc_topology_socket`
- `xcolo_pre_guest_traffic_frontend_contract=diagnostic_closed`
- `xcolo_qemu_doc_runtime_frontend=diagnostic_closed`

Expected evidence includes:

- `xcolo_pre_guest_traffic_contract_primary_running`
- `xcolo_pre_guest_traffic_contract_primary_status`
- `xcolo_pre_guest_traffic_contract_secondary_running`
- `xcolo_pre_guest_traffic_contract_secondary_status`
- `xcolo_pre_guest_traffic_contract_chardev_contract_ready`
- `xcolo_pre_guest_traffic_contract_chardev_contract_reason`
- `primary-query-chardev-contract-pre_guest_traffic_contract.json`
- `secondary-query-chardev-contract-pre_guest_traffic_contract.json`

## Retest Interpretation

The next retest is successful only if one of these happens:

- The gate passes, primary migrate starts, and the pair reaches steady FT/COLO
  state without `invalid message`.
- The gate fails before primary migrate and before QEMU logs
  `filter mirror send failed(Operation not permitted)`, with the closed chardev
  edges clearly recorded.

If `filter mirror send failed(Operation not permitted)` still appears before
the pre-guest gate result, then the gate is still too late and the next change
must move traffic suppression earlier in the primary create path.
