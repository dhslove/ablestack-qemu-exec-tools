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

The remaining problem is controller state convergence. The runtime is no
longer a hard failure, but FTCTL keeps the Cloud-visible state at:

```text
protection_state=pairing
transport_state=establishing
```

because every `rc=10` validation result is treated as generic
`runtime_converging` pending.

## Principle

`colo_established_candidate` is not the same as an arbitrary pending state.
It means the FT topology and transport are alive enough to preserve the
runtime and expose it as an FT candidate. FTCTL should not leave Cloud in an
endless `pairing/establishing` loop when the candidate has remained stable past
the configured observation window.

At the same time, this promotion is intentionally explicit. If later testing
shows that `finish-migrate/inmigrate` does not provide guest service continuity,
that is a separate QEMU COLO runtime progression issue, not a controller-state
timeout issue.

## Design

### Candidate Promotion Gate

Add a promotion gate for `rc=10` validation results. A pending runtime can be
promoted only when all of these are true:

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

### Promotion State

When the gate passes, FTCTL records:

```text
conversion_stage=handshake_candidate_established
conversion_state=colo_running
protection_state=colo_running
transport_state=mirroring
active_side=primary
xcolo_candidate_promoted=true
```

and emits:

```text
xcolo.runtime_candidate_promote result=ok
```

### Generic Pending

If the gate does not pass, existing pending behavior remains:

```text
protection_state=pairing
transport_state=establishing
```

## Expected Result

The next retest should no longer remain indefinitely at `pairing/establishing`
after the candidate is stable. If the runtime reaches the established
candidate gate, Cloud-visible state should move to `colo_running/mirroring`
while preserving diagnostic fields that show the exact QMP status and COLO
role state.
