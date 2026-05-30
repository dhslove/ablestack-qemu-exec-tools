# 323. FT X-COLO Established Candidate Promotion Design

Date: 2026-05-30

## Context

The retest after design 322 no longer failed on QOM property reads. The runtime
stayed alive with:

```text
primary_status=finish-migrate
secondary_status=inmigrate
primary_migrate=active
secondary_migrate=colo
filter_qom=unknown
filter_cmdline=yes
mirror=yes
compare=yes
compare_local=yes
compare_out=yes
xcolo_pending_reason=colo_established_candidate
```

The immediate problem at the time was controller state convergence. The runtime
was no longer a hard failure, but FTCTL kept the Cloud-visible state at:

```text
protection_state=pairing
transport_state=establishing
```

because every `rc=10` validation result is treated as generic
`runtime_converging` pending.

The next retest after this design showed that promoting the candidate directly
to `colo_running/mirroring` was too optimistic. Primary QMP still reported
`query-colo-status=none`, so design 324 supersedes this promotion behavior.

## Principle

`colo_established_candidate` is not the same as an arbitrary pending state, but
it is also not a completed FT state. It means the FT topology and transport are
alive enough to preserve runtime evidence and expose a candidate. It must not
be reported as successful protection unless QEMU reports a real primary and
secondary COLO role pair.

## Design

### Candidate Observation Gate

Add a bounded observation gate for `rc=10` validation results. A pending
runtime can be classified as an established candidate only when all of these
are true:

- `xcolo_pending_reason=colo_established_candidate`
- pending elapsed time is greater than or equal to
  `FTCTL_XCOLO_RUNTIME_CANDIDATE_PROMOTE_SEC`, defaulting to
  `FTCTL_XCOLO_RUNTIME_PENDING_MAX_SEC` or `180`
- primary status is `finish-migrate`
- secondary status is `inmigrate`
- primary migration is `active`
- secondary migration is `colo`
- all 9000-series channels are established
- primary filter topology is proven by live command line or QOM

### Candidate State

When the gate passes, FTCTL records a pending candidate, not a success:

```text
conversion_stage=handshake_candidate_established
conversion_state=pending
protection_state=pairing
transport_state=candidate_established
active_side=primary
xcolo_candidate_observed=true
```

and emits:

```text
xcolo.runtime_candidate result=pending
```

If the candidate remains beyond the configured observation window without
primary COLO role activation, design 324 records it as `activation_stalled`.

### Generic Pending

If the gate does not pass, existing pending behavior remains:

```text
protection_state=pairing
transport_state=establishing
```

## Expected Result

This design is retained as the first step that separated stable candidate
observation from generic `runtime_converging`. Its direct success promotion is
superseded by design 324.
