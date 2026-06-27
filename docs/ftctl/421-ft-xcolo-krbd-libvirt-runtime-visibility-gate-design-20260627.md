# FT XCOLO KRBD Libvirt Runtime Visibility Gate Design - 2026-06-27

## Purpose

The FT XCOLO KRBD path must keep ABLESTACK stable KRBD paths such as
`/dev/rbd/<pool>/<image>` as the long-term disk identity. It must not switch to
`/dev/rbdN` and must not fall back to librbd URI strings such as
`rbd:<pool>/<image>`.

The latest failure showed that the cloud hook guard correctly skipped KRBD
unmap, but the generated primary QEMU still failed before channel attach with:

```text
Could not open /dev/rbd/rbd/<image>: No such file or directory
```

This means the next gate must distinguish three cases before secondary startup
and migration:

1. Host KRBD mapping is missing.
2. Host KRBD mapping exists, but the generated QEMU process cannot see the
   stable KRBD path in its runtime namespace/cgroup.
3. The KRBD path is visible and the failure is later in the COLO protocol.

## Principles

- Keep the ABLESTACK stable KRBD path as the QEMU disk path.
- Do not use `/dev/rbdN` in generated XML or qemu command line as a durable
  reference.
- Do not convert KRBD to librbd URI syntax for FT XCOLO.
- Do not continue into secondary create or migration if the primary generated
  QEMU process cannot see every KRBD disk path.
- Preserve existing successful RBD-to-RBD behavior; this change is a gate and
  evidence improvement, not a rewrite of the working COLO command topology.

## AS-IS / TO-BE

| Area | AS-IS | TO-BE |
|---|---|---|
| `rbd showmapped` parsing | Text parser assumed fixed columns and failed when namespace column was absent. | Prefer `rbd showmapped --format json`; keep a header-aware text fallback. |
| Primary KRBD visibility | Checked the host path and generated XML path before create. | Also check the generated QEMU process namespace after listener readiness and before secondary create/migration. |
| QEMU PID discovery | No explicit generated QEMU PID gate. | Locate QEMU by create child scan first, then by global `/proc/*/cmdline` match for `guest=<vm>`; use a non-conflicting internal `found_pid` variable so Bash dynamic scoping cannot shadow the caller output variable. |
| Failure classification | `No such file or directory` could look like another channel/bootstrap failure. | Record `xcolo_primary_krbd_qemu_namespace_*` and fail with `xcolo_primary_krbd_qemu_namespace_invisible` or `xcolo_primary_krbd_qemu_pid_not_found`. |
| Hook interaction | Hook guard skip was visible, but empty generated XML disk source still produced confusing `rbd unmap ""` logs. | Cloud hook skips empty source dev and logs `ftctl_krbd_skip_empty_unmap_source`. |

## Runtime Flow

1. FTCTL pins KRBD mappings and writes the guard contract.
2. FTCTL generates primary XCOLO XML with stable `/dev/rbd/<pool>/<image>` paths.
3. FTCTL starts the generated primary asynchronously.
4. When frontend/listener ports become ready, FTCTL finds the generated QEMU PID.
5. FTCTL checks `/proc/<qemu-pid>/root/dev/rbd/<pool>/<image>` for every KRBD
   path from the generated XML.
6. If any path is missing, FTCTL captures socket evidence, records the namespace
   failure state, and stops before secondary create/migration.
7. If all paths are visible, FTCTL proceeds to the existing peer connection and
   migration sequence.

## Evidence Keys

The implementation records these state/event keys:

```text
xcolo_primary_krbd_qemu_namespace_phase
xcolo_primary_krbd_qemu_namespace_pid
xcolo_primary_krbd_qemu_namespace_count
xcolo_primary_krbd_qemu_namespace_visible_paths
xcolo_primary_krbd_qemu_namespace_missing_paths
xcolo_primary_krbd_qemu_namespace_visible
last_error=xcolo_primary_krbd_qemu_namespace_invisible
last_error=xcolo_primary_krbd_qemu_pid_not_found
```

Events use:

```text
xcolo.primary_krbd_qemu_namespace
primary_krbd_namespace_failed
```

## Implementation Guardrail

The PID helper must never declare a local variable with the same name as the
caller output variable. In Bash, local variables use dynamic scope, so
`printf -v "${out_var}"` can write back into the callee local variable instead
of the caller variable when the names collide. The implementation therefore uses
`found_pid` internally and revalidates the caller-visible `qemu_pid` before
checking `/proc/<qemu-pid>/root/...`.

## Success Criteria

- `bash -n lib/ftctl/xcolo.sh` passes.
- `rbd showmapped` parsing handles JSON output and namespace-column text output.
- A generated primary that cannot see stable KRBD paths fails before secondary
  create/migration with explicit namespace evidence.
- A generated primary that can see the stable KRBD paths proceeds through the
  existing COLO readiness flow.
- Cloud hook empty generated disk source does not trigger `rbd unmap ""` noise.
