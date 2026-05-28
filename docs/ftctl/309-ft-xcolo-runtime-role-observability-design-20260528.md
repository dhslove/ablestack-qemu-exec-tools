# FT X-COLO Runtime Role Observability Design

## Background

During FT validation for `r97-link-01`, protection progressed beyond the earlier baseline seed failure:

- primary VM: `i-2-54-VM`
- secondary VM: `i-2-85-VM`
- both `sda` and `sdb` baseline seed operations completed successfully
- generated primary and secondary domains were created
- QMP handshake completed
- runtime validation later failed with `runtime_convergence_timeout`

The host state showed the pair stuck in this shape:

- primary `query-status.status=finish-migrate`
- secondary `query-status.status=inmigrate`
- primary `query-migrate.status=active`
- secondary `query-migrate.status=colo`
- primary and secondary runtime XML markers were present
- `query-colo-status.mode=none` was captured around the handshake snapshot

This proves the baseline disk materialization problem was fixed. The remaining problem is narrower: qemu FTCTL needs to distinguish a real COLO role transition from a migration pair that reached `active/colo` transport states but never entered COLO checkpointing.

## Design Principles

1. Preserve the FT goal: the secondary is a clone of the primary at VM identity, disk, network, and memory checkpoint level.
2. Do not mark FT protection successful from standby creation or disk copy alone.
3. Treat `query-migrate` and `query-colo-status` as separate evidence.
4. Keep Cloud-managed ownership unchanged:
   - Cloud creates and owns VM/volume lifecycle.
   - qemu FTCTL owns generated runtime XML, QMP graph changes, COLO role validation, and recovery.
5. Preserve operator visibility. Runtime failure must leave a specific `last_error` and sticky `xcolo_last_runtime_error`.

## Runtime Classification

Runtime validation must collect the following values in every polling loop:

- primary and secondary `query-status.running`
- primary and secondary `query-status.status`
- primary and secondary `query-migrate.status`
- primary and secondary `query-colo-status.mode`
- primary and secondary runtime XML marker checks

The success model is:

1. Traditional running success:
   - primary running is `true`
   - secondary running is `true`
   - both runtime XML marker checks pass
   - secondary `query-migrate.status=colo`
2. Explicit COLO role success:
   - both runtime XML marker checks pass
   - primary `query-migrate.status=active`
   - secondary `query-migrate.status=colo`
   - primary and secondary `query-colo-status.mode` are both non-empty and not `none`

The second success path exists because QEMU may expose COLO steady-state through migration and COLO role status even when `query-status.running` is not the best signal. It must not be used when `query-colo-status.mode=none`.

## Pending And Failure Reasons

When the runtime XML markers are present and migration reports primary `active` and secondary `colo`, qemu FTCTL may keep the attempt pending for a bounded window.

Pending reason must be specific:

- `runtime_converging`: at least one side reports a non-`none` COLO mode, but the pair has not reached a complete success condition.
- `colo_role_not_entered`: both sides report empty or `none` COLO mode while migration remains `active/colo`.

If the pending state exceeds `FTCTL_XCOLO_RUNTIME_PENDING_MAX_SEC`, qemu FTCTL must fail with the specific pending reason instead of always reporting `runtime_convergence_timeout`.

Examples:

- `xcolo_runtime_validation_failed:colo_role_not_entered`
- `xcolo_runtime_validation_failed:runtime_convergence_timeout`
- `xcolo_runtime_validation_failed:primary_migrate_failed`
- `xcolo_runtime_validation_failed:secondary_migrate_failed`

## Recovery And Cloud Visibility

After a runtime validation failure, qemu FTCTL still performs bounded recovery:

1. deactivate the generated secondary runtime domain
2. destroy the generated primary runtime domain if present
3. restore the original primary from backup XML
4. set:
   - `conversion_stage=runtime_validation_failed`
   - `conversion_state=error`
   - `protection_state=error`
   - `transport_state=failed`
   - `active_side=primary`
   - `last_error=xcolo_runtime_validation_failed:<reason>`
   - `xcolo_last_runtime_error=xcolo_runtime_validation_failed:<reason>`

This keeps the primary service recoverable while still making the real FT failure visible to Cloud/UI.

## Test Coverage

Selftests must cover:

- migration `active/colo` with `query-colo-status.mode=none` remains pending first and then fails as `colo_role_not_entered`
- explicit non-`none` COLO roles are accepted as a valid runtime state
- existing false-positive guards remain: missing primary running state, terminal migration failure, and missing runtime XML markers still fail

