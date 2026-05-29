# 317. FT X-COLO Pre-Cont Filter Binding Defer Design

Date: 2026-05-30

## Context

The `r97-link-01` retest after design 316 showed that handshake failure
rollback is now effective:

- the generated primary runtime is destroyed,
- the original primary XML is restored,
- the primary VM returns to `running`,
- the secondary runtime is undefined,
- the exact error is preserved as
  `primary_filter_chardev_frontend_incomplete`.

The remaining failure boundary is earlier than the QEMU COLO role transition:

```text
primary.filter_chardev_binding fail
reason=mirror0:frontend_closed,compare0:frontend_closed,compare_out0:frontend_closed
```

At that point all TCP channel paths were already present. The chardev snapshot
also showed that some peer and loopback sides were already bound:

- `compare1=yes`
- `compare0-0=yes`
- `compare_out=yes`

while the packet-filter-facing endpoints were still closed:

- `mirror0=no`
- `compare0=no`
- `compare_out0=no`

This means the pre-`cont` check was too strict. It treated packet-filter
frontend binding as a prerequisite even though QEMU may not open every
filter-facing endpoint until after guest execution and the COLO migration path
advance.

## Principle

The pre-`cont` boundary must prove that the channel topology exists, not that
the entire runtime COLO data path has converged. Full COLO runtime convergence
must remain the job of `xcolo.runtime_validate`, which can observe QEMU after
`cont`, migration capabilities, checkpoint delay, and `migrate` have been
issued.

Failing too early hides the real transition behavior. It also prevents the
test from reaching the next meaningful evidence point.

## Design

1. Keep the existing primary channel path validation as a hard gate.
   - `9003` mirror peer path must be established.
   - `9004` compare peer path must be established.
   - `9001` local compare loopback must be established.
   - `9005` local compare output loopback must be established.
2. Change the pre-`cont` chardev frontend check from a hard gate to an
   observation.
   - If all chardev frontends are open, log
     `primary.filter_chardev_binding result=ok`.
   - If some frontends are still closed, log
     `primary.filter_chardev_binding result=defer` and preserve the reason in
     `xcolo_primary_filter_chardev_binding_deferred_reason`.
   - Do not set `last_error` at this point.
   - Do not block `primary.cont_before_migrate` or `primary.migrate` only
     because pre-`cont` filter-facing chardevs are closed.
3. Keep runtime validation strict.
   - If the pair later fails to enter the COLO role, runtime diagnostics still
     collect `query-chardev` and refine the failure to
     `primary_filter_chardev_frontend_incomplete` when that is still true.
4. Keep recovery strict.
   - If runtime validation or migration fails, qemu FTCTL must rollback the
     generated runtime and restore the original primary runtime shape.

## Expected Result

The next retest should no longer stop immediately after
`primary.object_add_filter_mirror`. It should proceed through:

```text
primary.filter_chardev_binding defer   # allowed if QEMU has not opened all frontends yet
primary.cont_before_migrate
primary.migrate_set_capabilities
primary.migrate_set_parameters
primary.migrate
xcolo.runtime_validate
```

If the same topology problem is still real after runtime convergence, the
failure should appear in `xcolo.runtime_validate` rather than at the pre-`cont`
boundary. That gives better evidence about whether the issue is:

- only a premature pre-`cont` assertion,
- a post-`cont` COLO role transition failure,
- or a genuine QEMU filter/redirector topology problem.
