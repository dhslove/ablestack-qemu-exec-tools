# 318. FT X-COLO Primary Filter XML Binding And Standby Cleanup Design

Date: 2026-05-30

## Context

The `r97-link-01` retest after design 317 reached the intended later failure
boundary. The run no longer stopped before `cont`; it completed channel setup,
block graph setup, migration capability setup, `cont`, `migrate`, and runtime
validation. The final state was:

- primary: `finish-migrate`, migration `active`, COLO mode `none`
- secondary: `inmigrate`, migration `colo`, COLO mode `secondary`
- block graph: complete
- 9000-series TCP channels: established
- primary filter chardev frontends: still incomplete

The specific runtime error was:

```text
xcolo_runtime_validation_failed:primary_filter_chardev_frontend_incomplete
```

This proves that QMP `object-add` success is not enough. QEMU accepted the
`filter-mirror`, `filter-redirector`, and `colo-compare` objects, but the
filter-facing chardev frontends did not all bind into the live NIC path.

The same run also exposed a cleanup consistency gap. Runtime recovery reported
secondary deactivation as successful, but the actual secondary libvirt domain
remained running. The likely cause is that cleanup used the profile/display
secondary name while the Cloud-managed runtime domain name is the generated
libvirt instance name.

## Principles

1. FT must preserve the agreed service goal: the secondary is the service-level
   clone of the primary and must be able to take over with the same guest
   identity when the primary fails.
2. The primary COLO network filter path must be bound by QEMU, not merely
   accepted as QMP objects.
3. A failed FT runtime must not leave a running secondary while state says it
   was stopped.
4. Diagnostics should distinguish channel connectivity, QOM object presence,
   chardev frontend binding, block graph presence, and COLO role transition.

## Design

### Primary Filter Binding

The generated primary XML now includes the primary-side COLO network filter
objects at startup:

- `colo-compare,id=comp0`
- `filter-mirror,id=m0`
- `filter-redirector,id=redire0`
- `filter-redirector,id=redire1`

The primary generated XML still keeps the chardev sockets:

- `mirror0`
- `compare1`
- `compare0`
- `compare0-0`
- `compare_out`
- `compare_out0`

The QMP handshake no longer blindly adds duplicate primary filter objects when
the active runtime XML already contains them. In that case it:

1. issues `stop` to keep the runtime at a controlled boundary,
2. validates the channel paths,
3. observes chardev frontend state,
4. records `xcolo_primary_net_filters_attach_mode=xml`,
5. proceeds to `cont` and `migrate`.

If an older runtime has no primary filter objects in XML, the QMP object-add
fallback remains available and records
`xcolo_primary_net_filters_attach_mode=qmp`.

### Diagnostics

Runtime failure snapshots now include QOM object listings for:

- `/objects`
- `/objects/m0`
- `/objects/redire0`
- `/objects/redire1`
- `/objects/comp0`
- `/objects/f1`
- `/objects/f2`
- `/objects/rew0`

These files are written under:

```text
/run/ablestack-vm-ftctl/debug/xcolo/<vm>/
```

This gives the next failure enough evidence to separate:

- filter object absence,
- filter object presence but frontend binding failure,
- complete filter and block topology with QEMU still refusing COLO primary role.

### Standby Cleanup

`ftctl_standby_deactivate` now builds a domain-name candidate set from:

- `secondary_vm_name` in state,
- the resolved profile secondary VM name,
- `<name>` from `standby_xml_generated`,
- `<name>` from `standby_xml_seed`.

It attempts `destroy` and `undefine` for each unique candidate, then verifies
that none of those candidates remains active. It records `standby_state=stopped`
only after verification succeeds. If any candidate is still running, it records
`standby_state=stop_failed` and returns failure.

## Expected Result

The next retest should start the generated primary with primary-side COLO
filters already in its XML. If QEMU can bind the filters correctly only at
netdev creation time, the run should progress from runtime validation into
`colo_running`.

If it still fails, the evidence should identify whether:

- XML-started primary filters still leave frontends closed,
- QOM objects are missing or malformed,
- or QEMU has a deeper primary role transition problem even with complete
  topology.

Regardless of the runtime outcome, failure recovery must not report secondary
deactivation as successful while the Cloud-managed secondary domain remains
running.
