# FT XC0LO Primary Vhost Guard Design - 2026-06-02

## Problem

The `r97-link-01` FT validation now reaches the primary `migrate` stage with
the following gates already passing:

- primary QMP filter object order is the QEMU documented primary order
- primary QOM topology confirms `m0`, `redire0`, `redire1`, and `comp0`
- pre-migrate channel evidence is complete
- secondary block graph is ready

The remaining terminal failure is still:

```text
xcolo_runtime_validation_failed:primary_migrate_failed
Received invalid message 0x0000 length 0x0000
```

The generated primary runtime command line can still expose a vhost-backed tap
netdev (`vhost=true` or `vhostfd=...`). COLO network filters must operate in
QEMU userspace. A vhost-backed virtio-net datapath can bypass that userspace
filter path and invalidate the COLO packet mirror/compare assumptions.

## Design Principle

FT mode must preserve the service identity of the primary VM, but the generated
COLO runtime may apply transport-only constraints that are required by QEMU
COLO. The guest MAC/IP identity must remain unchanged, while the generated
primary and secondary NIC datapaths must be compatible with QEMU netfilter.

## Required Behavior

1. Generated FT/COLO XML must normalize virtio interfaces to the QEMU userspace
   network driver.
2. After the generated primary runtime starts, ftctl must inspect the actual
   QEMU process command line, not only the XML.
3. If the COLO-filtered primary netdev is vhost-backed, ftctl must stop before
   issuing primary `migrate`.
4. The result must be explicit in state and events:
   - `xcolo_primary_netdev_vhost=off`
   - `xcolo_primary_netdev_vhost=on`
   - `xcolo_primary_netdev_vhost=unknown`
5. `on` is a hard failure with:
   - `last_error=primary_netdev_vhost_enabled`
   - `conversion_stage=primary_vhost_guard_failed`
   - `protection_state=error`
   - `transport_state=failed`

## Runtime Guard

The guard runs after the generated primary domain has started and before
secondary graph setup and primary migration proceed far enough to produce an
opaque COLO protocol error.

The command line scan must:

- read `/proc/*/cmdline` to avoid truncated `ps` output
- match the target VM name
- prefer the expected `hostnetN` netdev token when present
- mark vhost as `on` if the relevant command line contains `vhostfd`,
  `"vhost":true`, `vhost=on`, or `vhost=true`
- mark vhost as `off` if the QEMU process is found and no vhost marker is
  present

## Repetition Control

If the next run still fails with `Received invalid message 0x0000 length 0x0000`
while `xcolo_primary_netdev_vhost=off` is recorded, the vhost hypothesis is
closed and the next investigation must move to COLO channel payload direction
or QEMU version behavior. If it fails earlier with
`primary_netdev_vhost_enabled`, the test is intentionally stopped before the
known-invalid migrate path.

## Cleanup Requirement

Run 57 left stale Cloud state:

- `ftctl_protection.id=57`
- standby VM `i-2-113-VM`
- standby volumes `211`, `212`

These must be cleaned before the next valid test run, otherwise the UI can
display the previous failed state and no new FT engine execution occurs.
