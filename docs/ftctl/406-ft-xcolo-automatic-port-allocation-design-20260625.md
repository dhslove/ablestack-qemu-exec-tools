# FT XCOLO automatic port allocation design - 2026-06-25

## Problem

FT/XCOLO currently exposes multiple endpoint values to the registration flow, but
the most important remote NBD export address can remain hidden or read-only in
the UI. In multi-VM tests this lets one protected VM keep `10809` while a second
registration also resolves to `10809`, even when the operator intended to use a
different XCOLO NBD endpoint.

Manual port entry is not acceptable as the default operational model because
XCOLO needs a coordinated port set, not a single field.

## Principles

- Cloud owns protection orchestration and the Cloud-managed VM/volume lifecycle.
- qemu FTCTL owns runtime action and must reject inconsistent runtime profiles.
- The UI should not ask operators to allocate ordinary XCOLO ports manually.
- Existing HA/DR behavior must not regress.
- DB schema changes are avoided for this implementation. Active
  `ftctl_protection` rows plus VM details are used as the reservation source.
  A future long-term enhancement may add an explicit `ftctl_port_reservation`
  table if cross-management-server locking is required.

## AS-IS / TO-BE

| Area | AS-IS | TO-BE |
|---|---|---|
| UI default | FT endpoint fields are generated from fixed default ports. | FT defaults to automatic port allocation and does not submit endpoint fields unless manual mode is selected. |
| Remote NBD address | `remote.nbd.export.addr` can resolve independently from `xcolo.nbd.endpoint`. | `remote.nbd.export.addr` is derived from the selected XCOLO NBD endpoint in automatic mode. |
| Cloud validation | Only field presence is validated. | Backend rejects any mismatch between `remote.nbd.export.addr` and `xcolo.nbd.endpoint`. |
| Port ownership | No explicit port-set concept. | Backend allocates a deterministic per-VM port set from active Cloud details. |
| qemu guard | Profile accepts inconsistent remote NBD and XCOLO NBD values. | Profile validation fails before runtime if those values disagree. |
| Release | Details are removed, but no port ownership is modeled. | Removing `ftctl.*` details releases the implicit reservation. |

## Automatic Port Set

The backend allocates one slot per FT registration. Slot `n` uses:

- `compare local`: `9101 + n * 10`
- `mirror`: `9103 + n * 10`
- `compare`: `9104 + n * 10`
- `compare out`: `9105 + n * 10`
- `migrate`: `9198 + n`
- `remote NBD`: `11809 + n`
- `proxy endpoint`: `tcp:<peer-address>:(9100 + n * 10)`

The initial range is intentionally separate from the legacy single-VM defaults
`9001/9003/9004/9005/9998/10809`, so an existing protected VM does not block the
new automatic range.

## Host Firewall Contract

The qemu FTCTL package must keep the legacy ports open for already protected
VMs and additionally open the automatic ranges:

- XCOLO filter/proxy range: `9100-9259/tcp`
- XCOLO migrate/control range: `9198-9213/tcp`
- automatic remote NBD range: `11809-11824/tcp`

This keeps existing `900x/10809` deployments working while allowing new
registrations to use collision-free automatic slots.

## Implementation Notes

1. `RegisterFtctlProtectionCmd` gains `xcoloportallocationmode`.
   - `auto` is the default for FT.
   - `manual` preserves explicit test/debug endpoint entry.
2. `FtctlServiceImpl` creates an `XcoloPortAllocation` before provisioning.
   - automatic mode scans active protection rows and FTCTL details.
   - manual mode parses and validates supplied endpoints.
3. `FtctlSyncProfileCommand` carries the resolved per-profile XCOLO ports.
4. The KVM wrapper sends the new port options to `ablestack_vm_ftctl`.
5. `ablestack_vm_ftctl profile-upsert` persists profile-scoped
   `FTCTL_XCOLO_*` values.
6. `profile.sh` validates that remote NBD export host/port equals XCOLO NBD
   host/port for FT remote-nbd profiles.
7. `ablestack_vm_ftctl_firewalld.sh` opens both legacy and automatic FT/XCOLO
   ranges.

## Smoke Criteria

- Cloud unit/module build succeeds.
- UI build succeeds.
- qemu selftest/build succeeds.
- After deployment, `r97-link-02` has no active stale FTCTL rows or host
  runtime files.
- A new FT registration request can be submitted without the operator manually
  typing `remote.nbd.export.addr`.
