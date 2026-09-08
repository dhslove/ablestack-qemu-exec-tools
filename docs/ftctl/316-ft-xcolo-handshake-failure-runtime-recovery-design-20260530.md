# 316. FT X-COLO Handshake Failure Runtime Recovery Design

Date: 2026-05-30

## Context

The `r97-link-01` retest after design 315 proved that the new primary
filter/chardev binding gate works. qemu FTCTL stopped before `cont` and
`migrate` and reported:

- `last_error=primary_filter_chardev_frontend_incomplete`
- `xcolo_primary_filter_chardev_reason=mirror0:frontend_closed,compare0:frontend_closed,compare_out0:frontend_closed`

This is an improvement over the previous long runtime convergence timeout.
However, the failure happened after qemu FTCTL had already created generated
primary and secondary runtimes and attached QMP block/network state. Because
the failure occurred in the block cold-conversion handshake path, not in the
later runtime validation path, the existing runtime recovery function was not
called.

The observed residue was:

- primary runtime `i-2-54-VM` left paused on the primary host,
- secondary runtime `i-2-92-VM` left paused on the peer host,
- Cloud DB still showing the standby VM and volumes as active until explicit
  cleanup.

## Principle

Any FT path that mutates primary or secondary QEMU runtime must either complete
the FT pairing or restore the pre-protect runtime shape before returning an
error. The operator should not need a separate manual recovery just because the
failure was detected earlier than runtime validation.

Cloud still owns VM and volume lifecycle rows. qemu FTCTL owns only runtime
rollback: stopping/removing generated secondary runtime, destroying the
generated primary runtime, restoring the primary from the original backup XML,
and preserving the exact error reason for Cloud/UI display.

## Design

Add a block-handshake recovery wrapper:

1. On `ftctl_xcolo_execute_handshake_with_disk_plan` failure, preserve the
   specific `last_error` if one exists.
2. Call the existing runtime recovery routine because it already performs the
   required qemu-side rollback:
   - deactivate secondary runtime,
   - destroy generated primary runtime,
   - restore primary from `primary_xml_backup`,
   - set `active_side=primary`,
   - set `standby_state=stopped`.
3. After successful rollback, keep the stage as `handshake_failed` rather than
   `runtime_validation_failed`, so the failure boundary remains accurate.
4. Preserve the original error in both `last_error` and
   `xcolo_last_runtime_error`.
5. If rollback itself fails, mark `conversion_stage=handshake_recover_failed`
   and preserve the rollback error.

## Desired Result

The next run may still fail at the same chardev binding boundary until the QEMU
filter topology is fixed, but it must not leave both generated domains paused.
After the failure:

- primary should be restored and running from the backup XML,
- secondary runtime should be stopped/undefined,
- qemu state should clearly report `primary_filter_chardev_frontend_incomplete`,
- Cloud cleanup can safely remove the standby VM/volume rows for the next
  retest.

## Next Boundary

After this recovery behavior is stable, the remaining technical problem is the
primary COLO filter topology itself: QEMU accepts the objects, TCP sockets are
established, but the primary filter frontends stay closed for `mirror0`,
`compare0`, and `compare_out0`.

Design 317 narrows this further: those closed frontends are no longer treated as
a pre-`cont` failure by themselves. qemu FTCTL now records them as a deferred
observation and lets the pair advance to `cont`, migration setup, and runtime
validation. If the same frontend state remains fatal, the runtime validation
path will fail and this recovery model still applies.
