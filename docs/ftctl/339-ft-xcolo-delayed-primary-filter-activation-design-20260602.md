# FT XCOLO Delayed Primary Filter Activation Design - 2026-06-02

## Problem

Run `2026-06-02-09` proved that the primary COLO filter topology is now created
from QEMU startup commandline:

```text
xcolo_primary_netdev_vhost=off
xcolo_primary_net_filters_attach_mode=cmdline
xcolo_primary_filter_cmdline_ready=yes
xcolo_primary_filter_qom_ready=yes
```

The same runtime failure still occurred after primary `migrate`:

```text
filter mirror send failed(Operation not permitted)
Received invalid message 0x0000 length 0x0000
Can't receive COLO message: Input/output error
```

The new first error is important. It appears immediately after generated
runtime startup and before the final COLO protocol failure. This means the next
blocker is no longer filter creation or QMP attachment. The likely race is that
the primary `filter-mirror` is active before the full COLO channel and block
handshake path has converged.

## Design Principle

Primary filter objects should be present from startup, but packet forwarding
should not be enabled until the peer runtime, socket channels, block graph, QOM
topology, and chardev binding gates have all passed.

## Required Behavior

1. Primary generated XML must continue to include the complete filter topology
   in `qemu:commandline`.
2. Primary `filter-mirror` and `filter-redirector` objects must start with
   `status=off`.
3. The startup state must be recorded as:
   `xcolo_primary_filter_startup_status=off`.
4. After secondary runtime startup, channel validation, block graph attachment,
   and startup QOM topology validation, ftctl must enable primary filters with
   QMP `qom-set`.
5. Activation order must be:
   `redire0 -> redire1 -> m0`.
6. After activation, ftctl must verify QOM status is `on` for all three filter
   objects and then run the strict chardev binding gate.
7. Normal markers must include:
   - `xcolo_primary_net_filters_attach_mode=cmdline`
   - `xcolo_primary_net_filters_activation_mode=qom-set-status`
   - `xcolo_primary_net_filters_activated=true`
   - `xcolo_primary_filter_runtime_status=on`
8. If activation fails, ftctl must stop before primary `migrate` with:
   `last_error=primary_filter_activation_failed`.

## Failure Classification

If the next run still reaches primary `migrate` and fails with:

```text
filter mirror send failed(Operation not permitted)
```

while the new activation markers are all present, the issue must be classified
as a lower-level QEMU COLO runtime/protocol blocker, not as another startup
filter topology problem.

## Evidence To Preserve

Before and after activation, ftctl must record:

- QOM filter status for `m0`, `redire0`, and `redire1`
- `query-chardev` binding status
- socket channel state for ports `9003`, `9004`, `9001`, and `9005`
- QEMU log context if runtime validation fails

## Repetition Control

Do not return to QMP object-add based primary filter creation unless a future
run proves startup commandline creation is missing. The active hypothesis for
the next run is delayed filter activation, not filter topology placement.
