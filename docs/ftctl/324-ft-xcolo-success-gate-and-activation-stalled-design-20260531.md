# 324. FT X-COLO Success Gate And Activation Stalled Design

Date: 2026-05-31

## Context

The retest after design 323 proved that the controller can now leave the
endless `pairing/establishing` loop. However, the runtime evidence showed that
the new promotion was too optimistic:

```text
Cloud/FTCTL:
  protection_state=colo_running
  transport_state=mirroring

Primary QMP:
  query-status=finish-migrate
  running=false
  query-colo-status=none

Secondary QMP:
  query-status=inmigrate
  running=false
  query-colo-status=secondary
```

This is not a valid FT success state. QEMU COLO success must be judged by the
actual QEMU runtime role and service continuity, not only by transport/channel
establishment.

One detail from the same retest is important: `virsh domblklist` on the
secondary showed only the CD-ROM after QMP device replacement, but QMP
`query-block` and HMP `info qtree` showed `ftctl-colo-sda` and
`ftctl-colo-sdb` attached as SCSI disks. Therefore secondary disk validation
must use QMP block graph/qdev evidence, not libvirt `domblklist` alone.

## Principle

`colo_established_candidate` is a diagnostic/pending state. It must not be
reported as `colo_running/mirroring`.

FTCTL can report success only when QEMU reports a real COLO role combination
and the secondary disk graph is present. If transport and disk graph are alive
but the primary never enters `query-colo-status=primary`, FTCTL must preserve
runtime evidence and report an activation-stalled pending state.

## Success Gate

`colo_running/mirroring` is valid only when all of these are true:

- primary runtime XML contains the COLO markers
- secondary runtime XML contains the COLO markers
- primary migration status is `active`
- secondary migration status is `colo`
- primary COLO mode is `primary`
- secondary COLO mode is `secondary`
- all 9000-series COLO channel paths are established
- primary filter topology is proven by command line or QOM
- for block-backed FT, secondary QMP block graph contains all expected
  `ftctl-colo-<target>` devices

## Candidate State

When these are true:

```text
primary_status=finish-migrate
secondary_status=inmigrate
primary_migrate=active
secondary_migrate=colo
secondary_colo=secondary
channel paths established
primary topology proven
secondary block graph ready
```

but `primary_colo` is still `none`, FTCTL records:

```text
conversion_stage=handshake_candidate_established
conversion_state=pending
protection_state=pairing
transport_state=candidate_established
```

## Activation Stalled State

If the same candidate state remains past
`FTCTL_XCOLO_RUNTIME_PENDING_MAX_SEC`, FTCTL records:

```text
conversion_stage=activation_stalled
conversion_state=pending
protection_state=pairing
transport_state=activation_stalled
last_error=xcolo_activation_stalled
```

This is intentionally not a hard cleanup failure. The QEMU runtime should be
preserved for evidence collection unless a later explicit cleanup/unprotect is
requested.

## Expected Result

The next retest should no longer show a false `colo_running/mirroring` success
when the primary stays at `query-colo-status=none`. It should either:

- reach a real COLO role pair and become `colo_running/mirroring`, or
- remain observable as `candidate_established` and then
  `activation_stalled`, with secondary block graph evidence recorded.
