# FT XCOLO Network, Firewall, and Storage Preflight Design - 2026-06-02

## Background

Run 62 for `r97-link-01` progressed past both baseline seed disks and reached
COLO runtime validation. The repeated failure is now:

- primary QEMU: `Received invalid message 0x0000 length 0x0000`
- secondary QEMU: `Can't receive COLO message: Input/output error`

The run also proved that many previous blockers are no longer the immediate
failure:

- `sda` and `sdb` baseline seed completed.
- primary and secondary generated runtime domains started.
- primary QOM filter topology was ready.
- `vnet_hdr_support` was recorded as enabled on the primary filter objects.
- pre-migrate chardev and 9000-series channels were recorded as ready.
- secondary block graph was recorded as ready.

Because FT continuously synchronizes memory, disk, and network state over host
network paths, network/firewall/socket readiness must be treated as a first
class FT contract rather than incidental evidence.

## Goals

- Define the FT XCOLO network port contract in code and documentation.
- Verify firewall readiness before starting the primary migrate step.
- Capture actual socket state immediately before and after migrate starts.
- Classify repeated `Received invalid message 0x0000 length 0x0000` failures as
  a repeated COLO protocol-path blocker when all pre-migrate evidence is ready.
- Record storage symmetry diagnostics so RBD/raw to filesystem/qcow2 mismatches
  are visible and can be separated from network/protocol failures.

## Non-Goals

- Do not change Cloud ownership. Cloud still creates and manages the
  cloud-managed primary and standby VM/volume lifecycle.
- Do not change DR/HA runtime behavior.
- Do not permanently change host firewall policy without an explicit operator
  action.
- Do not keep making generic filter-order guesses after the repeated
  invalid-message signature is detected.

## FT XCOLO Port Contract

External host-to-host ports:

- `9000/tcp`: XCOLO proxy/control endpoint.
- `9003/tcp`: primary mirror channel. Primary listens; secondary connects.
- `9004/tcp`: primary compare peer channel. Primary listens; secondary
  connects.
- `9998/tcp`: migration endpoint. Secondary listens; primary connects.
- `10809-10872/tcp`: remote NBD/baseline seed/export range.

Loopback-only primary ports:

- `9001/tcp`: primary local compare loop.
- `9005/tcp`: primary local compare output loop.

The loopback ports must bind/connect on `127.0.0.1`. If they are observed on
non-loopback addresses, FTCTL must record a topology warning or blocker because
they are not intended to be externally reachable.

## Firewall Preflight

Before the primary `migrate` command, FTCTL records firewall readiness on both
hosts:

- firewalld state
- runtime service/port coverage for the external port set
- whether nft/iptables contains reject/drop rules for the relevant ports

Expected state:

- firewalld inactive: record `xcolo_firewall_ready=yes` and continue because
  there is no active firewalld gate.
- firewalld active and all external ports covered: record
  `xcolo_firewall_ready=yes`.
- firewalld active and any external port missing: record
  `xcolo_firewall_ready=no`, `xcolo_firewall_missing_ports=...`, and stop before
  primary migrate with `last_error=xcolo_firewall_ports_missing` unless the
  profile explicitly allows auto-opening runtime ports.

Runtime auto-opening is intentionally not the default for this change. The next
test should first prove whether the firewall contract is satisfied.

## Socket Snapshot

FTCTL captures `ss -tanp` snapshots on both hosts:

- `pre_migrate`
- immediately after primary migrate starts
- on migration failure before rollback

The snapshot is summarized into state fields:

- `xcolo_socket_<phase>_primary_9003`
- `xcolo_socket_<phase>_primary_9004`
- `xcolo_socket_<phase>_primary_9998`
- `xcolo_socket_<phase>_secondary_9003`
- `xcolo_socket_<phase>_secondary_9004`
- `xcolo_socket_<phase>_secondary_9998`
- `xcolo_socket_<phase>_loopback_9001`
- `xcolo_socket_<phase>_loopback_9005`

Each value is a compact summary: `listen`, `established`, `closed`, or
`unknown`. The full raw snapshot is stored under the existing FTCTL debug/state
area where possible.

## Storage Symmetry Compatibility Gate

Run 62 used asymmetric storage:

- primary: RBD/raw block devices
- secondary: filesystem/qcow2 file volumes

Run 63 proved that firewall and socket paths are healthy while the same invalid
COLO message remains. The storage mismatch is therefore no longer treated as
only passive evidence. FT aims to run a secondary clone with equivalent device
semantics, so backend/format mismatch is a compatibility blocker for the normal
protection path.

FTCTL records:

- `xcolo_storage_symmetry=ok|warning|unknown`
- `xcolo_storage_primary_layout=block/raw`
- `xcolo_storage_secondary_layout=file/qcow2`
- `xcolo_storage_symmetry_reason=...`

Strict default behavior:

- if `xcolo_storage_symmetry=ok`, continue
- if `xcolo_storage_symmetry=warning`, stop before primary shutdown and record
  `last_error=xcolo_storage_backend_mismatch`
- only an explicit experimental override can allow a mismatched storage pair to
  continue; such a run must be treated as non-default evidence

## Repeated Invalid-Message Guard

When all of these are true:

- `xcolo_premigrate_primary_filter_qom_ready=yes`
- `xcolo_premigrate_primary_filter_chardev_ready=yes`
- all 9000-series channel evidence is ready
- `xcolo_secondary_block_graph_ready=yes`
- primary migration fails with `Received invalid message 0x0000 length 0x0000`

FTCTL records:

- `xcolo_repeated_protocol_invalid_message=yes`
- `last_error=xcolo_repeated_protocol_invalid_message`

This prevents the investigation from cycling through already-cleared baseline
seed, generic filter ordering, or generic channel readiness hypotheses.

## Implementation Steps

1. Change commandline `vnet_hdr_support` short-form to `vnet_hdr_support=on`.
2. Add FT XCOLO port contract helper functions.
3. Add firewall preflight state capture before primary migrate.
4. Add socket snapshot capture before migrate, after migrate start, and on
   failure.
5. Add storage symmetry diagnostics after disk plan creation.
6. Block storage mismatch before primary shutdown by default.
7. Add repeated invalid-message classification in runtime validation using
   pre-migrate readiness evidence.
8. Record Run progress and the next test expectation in the progress log.

## Next Test Expectations

The next run is progress if one of these happens:

- firewall preflight blocks before migrate and records the missing port set;
- storage mismatch blocks before primary shutdown with
  `xcolo_storage_backend_mismatch`;
- socket snapshots identify the first channel that closes or is misbound;
- primary migration no longer fails with the invalid message and enters COLO.

If the invalid message repeats and the firewall/socket/storage diagnostics do
not add new evidence, report it immediately as a repeated protocol-path blocker.
