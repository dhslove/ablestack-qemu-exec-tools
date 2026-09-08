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
- FT/XCOLO transport endpoints are protection-relationship state, not VM
  identity or VM configuration. They must not be persisted as new VM details.
- Cloud stores automatic allocation metadata on the active `ftctl_protection`
  row. Cleanup is therefore tied to protection row removal, not VM detail
  deletion.
- The only DB schema change for this implementation is the minimal
  `ftctl_protection` allocation metadata needed to reserve a slot.
  A future long-term enhancement may add an explicit `ftctl_port_reservation`
  table if cross-management-server locking is required.

## AS-IS / TO-BE

| Area | AS-IS | TO-BE |
|---|---|---|
| UI default | FT endpoint fields are generated from fixed default ports. | FT defaults to automatic port allocation and does not submit endpoint fields unless manual mode is selected. |
| Remote NBD address | `remote.nbd.export.addr` can resolve independently from `xcolo.nbd.endpoint`. | `remote.nbd.export.addr` is derived from the selected XCOLO NBD endpoint in automatic mode. |
| Cloud validation | Only field presence is validated. | Backend rejects any mismatch between `remote.nbd.export.addr` and `xcolo.nbd.endpoint`. |
| Port ownership | No explicit port-set concept. | Backend allocates a deterministic per-protection port set from active `ftctl_protection.xcolo_port_slot` values. |
| qemu guard | Profile accepts inconsistent remote NBD and XCOLO NBD values. | Profile validation fails before runtime if those values disagree. |
| Release | Details are removed, but no port ownership is modeled. | Marking the protection row removed releases the slot reservation. |
| VM details | FT/XCOLO endpoints can be stored as `ftctl.xcolo.*` VM details. | No new FT/XCOLO transport VM detail keys are written. |

## DB Change

The Cloud DB must add allocation metadata to `ftctl_protection`:

```sql
ALTER TABLE cloud.ftctl_protection
  ADD COLUMN xcolo_port_allocation_mode varchar(16) DEFAULT NULL,
  ADD COLUMN xcolo_port_slot int DEFAULT NULL;
```

New installs and upgrade SQL create the same columns with the table. Existing
test clusters must receive the `ALTER TABLE` before deploying the Cloud code.
No `vm_instance_details` keys are added for automatic XCOLO port allocation.

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
   - automatic mode scans active protection rows and their allocated slots.
   - manual mode parses and validates supplied endpoints.
   - automatic mode stores only `xcolo_port_allocation_mode` and
     `xcolo_port_slot` on `ftctl_protection`.
   - endpoint strings shown in API responses are calculated from the
     protection row slot and peer host address; they are not read from VM
     details.
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
- Active FT registrations do not create `ftctl.xcolo.*` VM detail rows.
- After deployment, `r97-link-02` has no active stale FTCTL rows or host
  runtime files.
- A new FT registration request can be submitted without the operator manually
  typing `remote.nbd.export.addr`.
