# 327. FT X-COLO Primary Filter Runtime Rebuild Design

Date: 2026-05-31

## Superseded Runtime Repair Note

The runtime-validation repair path described in this document is no longer the
normal FT protection path. The QMP rebuild primitive is still valid, but it must
be executed before `primary.migrate` whenever
the primary chardev/filter graph is incomplete.

See `328-ft-xcolo-pre-migrate-filter-strict-gate-design-20260531.md` for the
current gate. Runtime validation now diagnoses and classifies incomplete filter
state instead of trying to construct the graph after migration has started.

## Context

The retest after design 326 reached the deepest FT runtime point so far:

- baseline seeding completed for all primary disks
- secondary block graph was attached
- secondary entered `query-colo-status=secondary`
- primary migration stayed `active`
- primary command line contained the expected X-COLO filter topology

The final failure was:

```text
xcolo_runtime_validation_failed:primary_filter_chardev_frontend_incomplete
```

The decisive evidence was:

```text
primary_status=finish-migrate
secondary_status=inmigrate
primary_colo=none
secondary_colo=secondary
primary_migrate=active
secondary_migrate=colo
filter_cmdline=yes
chardev=no
chardev_reason=mirror0:frontend_closed,compare0:frontend_closed,compare_out0:frontend_closed
```

This means the command-line topology existed, but QEMU did not keep the primary
filter/chardev frontends alive as a working COLO primary filter chain.

## Principle

FT success must not be relaxed. `colo_running/mirroring` still requires:

- primary COLO role is `primary`
- secondary COLO role is `secondary`
- migration states are `active/colo`
- secondary block graph is ready
- primary filter topology and chardev frontend binding are actually alive

The fix is not to accept `primary_colo=none`; the fix is to rebuild the primary
filter/chardev runtime graph when XML command-line injection is insufficient.

## Required Behavior

When primary XML contains X-COLO command-line markers but
`query-chardev` reports missing or closed COLO chardev frontends, FTCTL must:

1. Keep the existing XML command-line generation path as the first attempt.
2. Run a QMP runtime rebuild before primary migration when pre-migrate
   chardev observation is incomplete.
3. Rebuild the runtime graph by:
   - best-effort removing stale objects: `m0`, `redire0`, `redire1`, `comp0`
   - best-effort removing stale chardevs:
     `mirror0`, `compare1`, `compare0`, `compare0-0`,
     `compare_out`, `compare_out0`
   - adding socket chardevs with QMP `chardev-add`
   - adding `filter-redirector`, `colo-compare`, and `filter-mirror`
     with QMP `object-add`
4. Repeat the same rebuild once during runtime validation if migration has
   reached `active/colo` but the primary chardev frontend is still incomplete.
5. Re-run chardev, QOM, command-line, channel, and COLO role validation after
   the rebuild.

## Runtime Rebuild Details

The runtime rebuild uses the same netdev ID resolved by design 326:

```text
xcolo_primary_netdev_id
```

For the common single-NIC case this remains `hostnet0`, but it is still derived
from libvirt XML rather than hardcoded.

The primary-side runtime socket layout is:

```text
mirror0       server 0.0.0.0:${FTCTL_XCOLO_MIRROR_PORT:-9003}
compare1      server 0.0.0.0:${FTCTL_XCOLO_COMPARE_PORT:-9004}
compare0      server 127.0.0.1:${FTCTL_XCOLO_COMPARE_LOCAL_PORT:-9001}
compare0-0    client 127.0.0.1:${FTCTL_XCOLO_COMPARE_LOCAL_PORT:-9001}
compare_out   server 127.0.0.1:${FTCTL_XCOLO_COMPARE_OUT_PORT:-9005}
compare_out0  client 127.0.0.1:${FTCTL_XCOLO_COMPARE_OUT_PORT:-9005}
```

The object chain is:

```text
redire0: filter-redirector queue=rx indev=compare_out
redire1: filter-redirector queue=rx outdev=compare0
comp0:   colo-compare primary_in=compare0-0 secondary_in=compare1 outdev=compare_out0
m0:      filter-mirror queue=tx outdev=mirror0
```

## State And Diagnostics

FTCTL records the rebuild attempt in state:

```text
xcolo_primary_filter_runtime_repair_attempted=yes
xcolo_primary_filter_runtime_repair_source=<pre_migrate_xml_chardev_incomplete|runtime_validation>
xcolo_primary_net_filters_attach_mode=qmp-rebuild
```

The expected event sequence includes:

```text
primary.net_filters.rebuild start
primary.chardev_add.*
primary.object_add_*
primary.net_filters.rebuild ok
```

## Expected Result

The next retest should either:

- reach a real `primary/secondary` COLO role pair and transition to
  `colo_running/mirroring`, or
- fail with a more precise QMP rebuild error before false success or ambiguous
  `primary_filter_chardev_frontend_incomplete` classification.

If the rebuild succeeds but primary still remains `query-colo-status=none`,
the next design focus should move from filter materialization to QEMU COLO
activation sequencing.
