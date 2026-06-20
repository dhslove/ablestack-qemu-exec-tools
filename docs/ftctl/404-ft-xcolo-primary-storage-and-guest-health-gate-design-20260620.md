# FT X-COLO Primary Storage And Guest Health Gate Design

## Background

The latest `r97-link-01` validation reached the QEMU COLO pair state: the
primary and secondary runtimes both reported COLO roles and migration state.
However, the guest console showed a root filesystem mount failure:

- `Failed to mount /sysroot`
- `Dependency failed for Initrd Root File System`
- `Entering emergency mode`

That is not a successful FT state. COLO transport convergence only proves that
the QEMU pair entered the replication protocol. FT success also requires the
primary guest to keep a usable storage path after the generated COLO runtime is
started.

This document extends the earlier guest boot and role failure contract in
[310. FT X-COLO Guest Boot And Role Failure Design](310-ft-xcolo-guest-boot-and-role-failure-design-20260528.md).

## Design Principles

1. A QEMU COLO role transition is necessary but not sufficient for FT success.
2. The primary guest must remain the service owner after COLO is enabled.
3. The secondary QEMU process may be running in COLO secondary mode, but it is
   not the active service side.
4. qemu FTCTL must not mark `colo_running/mirroring` while the primary block
   graph, RBD access, or guest boot health is unhealthy.
5. Guest health failures must be preserved separately from transport failures so
   the operator can distinguish "COLO did not form" from "COLO formed but
   primary storage/guest health failed".

## Runtime Success Gates

FT success is split into three ordered gates.

| Gate | Evidence | Failure class |
| --- | --- | --- |
| COLO runtime gate | QMP `query-migrate`, `query-colo-status`, channel/filter/topology state | `xcolo_runtime_validation_failed:*` |
| Primary storage safety gate | Primary QMP block graph/state, block stats, qemu log block/RBD errors | `xcolo_primary_storage_unhealthy:*` |
| Primary guest health gate | QGA and explicit boot failure evidence | `xcolo_primary_guest_boot_unhealthy:*` |

Only after all enabled gates pass may qemu FTCTL publish:

```text
conversion_state=colo_running
protection_state=colo_running
transport_state=mirroring
active_side=primary
```

## COLO Runtime State

QEMU 9.2.4 may report the primary migration status as `colo` after the pair is
established. Runtime validation must therefore accept both:

```text
primary query-migrate.status = active
primary query-migrate.status = colo
```

provided that:

```text
secondary query-migrate.status = colo
primary query-colo-status.mode = primary
secondary query-colo-status.mode = secondary
primary query-status.running = true
secondary query-status.running = true
```

The secondary `running=true` means the COLO secondary QEMU runtime is executing.
It does not mean the secondary is the active service side.

## Primary Storage Safety Gate

After the COLO runtime gate is a success candidate, qemu FTCTL collects:

- primary `query-block`
- primary `query-named-block-nodes`
- primary `query-blockstats`
- primary qemu log tail, when available

The gate fails if it observes clear storage failure evidence:

- QMP command failure
- `io-status` is `failed`
- qemu log contains storage/RBD failure patterns such as:
  - `Input/output error`
  - `I/O error`
  - `Operation not permitted`
  - `Permission denied`
  - `blk_update_request`
  - `rbd`

The gate records:

```text
xcolo_primary_storage_health_gate=ok|failed
xcolo_primary_storage_health_reason=<reason>
```

## Primary Guest Health Gate

The primary guest health policy is controlled by:

```text
FTCTL_XCOLO_PRIMARY_GUEST_HEALTH_POLICY=required|observe|off
```

Default: `required`.

Cloud-managed FT protects an already running service VM. In the supported
default path the generated primary must regain QGA after COLO startup. If an
image intentionally does not provide QGA, operators may lower this policy to
`observe` for diagnostics or `off` for controlled development tests.

Policy behavior:

| Policy | Behavior |
| --- | --- |
| `required` | Primary QGA must answer `guest-ping`; explicit boot/storage failure evidence also fails the gate |
| `observe` | QGA absence is recorded but does not fail; explicit boot/storage failure evidence still fails |
| `off` | Guest health does not affect success |

Explicit guest failure evidence includes:

- `Failed to mount /sysroot`
- `Entering emergency mode`
- `XFS ... metadata I/O error`
- `Uncorrected metadata errors`
- `dracut-initqueue timeout`

The gate records:

```text
xcolo_primary_guest_health_gate=ok|failed|observe
xcolo_primary_guest_health_reason=<reason>
```

## Recovery

If either health gate fails, qemu FTCTL must use the existing runtime convergence
failure recovery path. The generated primary/secondary runtime should be cleaned
up, the original primary XML/storage path should be restored when possible, and
the specific health failure must remain in both `last_error` and
`xcolo_last_runtime_error`.

## Test Expectations

The next `r97-link-01` FT run must report one of these clearly:

1. `colo_running/mirroring` only after COLO runtime and primary health gates pass.
2. `xcolo_primary_storage_unhealthy:*` if COLO forms but the primary block/RBD
   path shows an I/O or lock problem.
3. `xcolo_primary_guest_boot_unhealthy:*` if COLO forms but the primary guest
   enters emergency/root mount failure state.

This prevents a false success where QMP reports COLO but the guest cannot mount
its root filesystem.
