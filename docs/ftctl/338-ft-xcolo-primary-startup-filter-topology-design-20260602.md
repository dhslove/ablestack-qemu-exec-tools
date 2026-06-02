# FT XC0LO Primary Startup Filter Topology Design - 2026-06-02

## Problem

Run `2026-06-02-08` proved that the generated primary runtime no longer uses a
vhost-backed netdev:

```text
xcolo_primary_netdev_vhost=off
conversion_stage=primary_vhost_guard_passed
```

The same terminal failure still occurred after primary `migrate`:

```text
Received invalid message 0x0000 length 0x0000
Can't receive COLO message: Input/output error
```

This closes the vhost hypothesis. The next structural mismatch is that the
secondary COLO net filters are present from QEMU startup, while the primary
filter objects are currently attached later through QMP.

## Design Principle

The generated FT/COLO runtime should match QEMU's documented COLO startup
topology as closely as possible. Runtime QMP diagnostics remain useful, but the
normal datapath should not depend on adding the primary packet filter topology
after the VM is already running.

## Required Behavior

1. Primary generated XML must include the full primary network filter topology
   in `qemu:commandline`.
2. The primary commandline object order must remain:
   `m0 -> redire0 -> redire1 -> comp0`.
3. If the commandline topology is present, ftctl must not add duplicate primary
   filter objects through QMP.
4. The normal attach marker must become:
   `xcolo_primary_net_filters_attach_mode=cmdline`.
5. Pre-migrate must require the actual process commandline topology:
   `xcolo_primary_filter_cmdline_ready=yes`.
6. If commandline topology is missing, ftctl must fail before `migrate` with:
   `last_error=primary_filter_cmdline_topology_missing`.

## Channel Evidence

Before primary `migrate`, ftctl must continue to capture:

- `mirror0` / `red0`
- `compare1` / `red1`
- `compare0` / `compare0-0`
- `compare_out` / `compare_out0`

The existing `ss` based established/listen markers remain the immediate gate.
The next failure classification must distinguish a channel/path mismatch from a
generic primary migration failure.

## Repetition Control

If a future run records all of the following and still fails with the same COLO
protocol message, the blocker is no longer startup topology:

- `xcolo_primary_netdev_vhost=off`
- `xcolo_primary_net_filters_attach_mode=cmdline`
- `xcolo_primary_filter_cmdline_ready=yes`
- `xcolo_primary_filter_qom_ready=yes`
- all pre-migrate channel markers established

That case must be classified as a lower-level COLO protocol/runtime behavior
issue, not another filter attachment iteration.
