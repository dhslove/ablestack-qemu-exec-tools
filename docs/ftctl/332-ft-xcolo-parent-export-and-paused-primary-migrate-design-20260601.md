# 332. FT X-COLO Parent Export And Paused Primary Migrate Design

Date: 2026-06-01

## Context

The retest after design 331 reached the narrowest failure point so far:

```text
primary query-status: finish-migrate
primary query-migrate: active, remaining=0
primary query-colo-status: none
secondary query-status: inmigrate
secondary query-migrate: colo
secondary query-colo-status: secondary
```

The 9000-series transport paths were established and the secondary block graph
was present. The new failure classification also worked: FTCTL reported
`primary_finish_migrate_colo_role_not_entered` instead of hiding the issue
behind primary chardev frontend state.

That means the remaining issue is the primary COLO role transition itself.
The implementation must now remove local deviations from the documented QEMU
COLO startup sequence.

## Confirmed Runtime Boundary

The failure is not:

- remote host reachability,
- primary-to-secondary migration socket reachability,
- secondary incoming migration readiness,
- secondary COLO mode entry,
- secondary block graph creation,
- primary XML deployment staleness.

The primary remains in `finish-migrate` while the secondary has entered COLO.
This points at the disk replication export/attach contract or the primary
migrate start sequence.

## Design

### Export The Secondary Parent/Base Node

For block-backed, cloud-managed FT, the secondary graph is created dynamically:

```text
secondary base node -> hidden overlay -> active overlay -> replication child -> quorum top
```

The previous implementation exported the secondary quorum top node
`ftctl-colo-<target>` through NBD and then attached that export under the
primary quorum. That is not aligned with the QEMU COLO procedure, which exports
the secondary parent/base node (`parent0`) and attaches that NBD export as the
remote child under the primary quorum.

The disk-plan handshake must therefore:

1. read `xcolo_disk_<target>_secondary_base_node`,
2. run `nbd-server-add device=<secondary_base_node> writable=true`,
3. use the same `<secondary_base_node>` as the primary NBD `export`,
4. keep the primary remote NBD child under `ftctl-colo-<target>`.

This keeps the primary/secondary disk roles consistent with QEMU COLO: the
secondary replication driver owns the active/hidden overlay chain, while the
primary writes to its local active overlay and the remote parent export through
the quorum.

### Do Not Explicitly Continue Primary Before Migrate

The generated primary starts paused with `-S` while FTCTL builds the runtime
disk and network graph. Earlier designs introduced `primary.cont_before_migrate`
to force the VM into a running state before `migrate`. Retesting proved that
this could move the run forward but did not make primary enter COLO.

The QEMU COLO startup sequence is:

```text
primary qmp_capabilities
primary blockdev-add nbd child
primary x-blockdev-change
primary migrate-set-capabilities return-path,x-colo
primary migrate
```

There is no explicit `cont` between capability setup and `migrate`. FTCTL must
therefore leave the generated primary paused and let the COLO migration command
drive the role transition.

### Preserve Activation-Stalled Runtime Evidence

When the runtime reaches:

```text
primary_status=finish-migrate
secondary_status=inmigrate
primary_migrate=active
secondary_migrate=colo
primary_colo!=primary
secondary_colo=secondary
channels established
secondary block graph ready
```

and it remains there past the observation threshold, FTCTL must mark:

```text
conversion_stage=activation_stalled
conversion_state=pending
protection_state=pairing
transport_state=activation_stalled
last_error=xcolo_activation_stalled
```

It must not immediately destroy the runtime pair. The purpose is to preserve
QMP state, channel state, and block graph evidence for diagnosis. Explicit
cleanup or unprotect may still tear the pair down before the next retest.

## Expected Result

The next retest should either:

- reach a real COLO role pair:

```text
primary query-colo-status: primary
secondary query-colo-status: secondary
FTCTL: colo_running / mirroring
```

or, if QEMU still refuses the primary role transition:

- remain observable as `activation_stalled` without destroying the secondary
  runtime immediately.

Either outcome is useful. A success proves the export/start-sequence mismatch
was the blocker. An activation-stalled result preserves enough live evidence to
inspect the remaining QEMU/libvirt interaction without another blind retry.

## Consistency Updates

This design supersedes the following earlier assumptions:

- Design 300's explicit `primary.cont_before_migrate` requirement.
- Design 306's secondary NBD export of `ftctl-colo-<target>`.
- Designs 328, 329, and 330 examples that listed `primary.cont_before_migrate`
  as part of the successful pre-migrate sequence.

