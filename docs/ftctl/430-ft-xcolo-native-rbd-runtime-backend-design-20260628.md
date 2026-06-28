# FT XCOLO Native RBD Runtime Backend Design - 2026-06-28

## Background

The r97-link-02 FT retest reached primary generated-domain creation but failed
before listener materialization.  The last failing QEMU log showed the generated
primary command line trying to open the local parent NBD adapter socket:

```text
-blockdev driver=nbd,node-name=ftctl-primary-parent-sda-nbd,
server.type=unix,server.path=/run/ablestack-vm-ftctl/xcolo-parent-nbd/i-2-197-VM/sda.sock,
export=ftctl-primary-parent-sda:
Could not open image: Permission denied
```

The qemu-user shell probe passed, SELinux was permissive, and the socket was
created by FTCTL.  The failure is therefore not a simple Unix permission or
firewall issue.  The problem is that the protected disks are removed from
libvirt XML and reintroduced through `qemu:commandline`; libvirt cannot fully
model qemu-commandline-only KRBD/NBD socket resources in its security, cgroup,
namespace, and lifecycle handling.

## Decision

Keep ABLESTACK Cloud/libvirt disk management on stable KRBD paths for normal VM,
HA, DR, and inventory semantics.  For FT/XCOLO generated runtime only, use QEMU
native librbd block backends for RBD parent disks.

This is an FT runtime exception, not a general storage policy change.

## AS-IS / TO-BE

| Area | AS-IS | TO-BE |
|---|---|---|
| Default FT RBD commandline backend | `FTCTL_XCOLO_RBD_COMMANDLINE_BACKEND=krbd` | `FTCTL_XCOLO_RBD_COMMANDLINE_BACKEND=librbd` |
| Primary parent RBD source | KRBD path or local NBD adapter wrapping KRBD | Native QEMU RBD blockdev from `/dev/rbd/<pool>/<image>` metadata |
| Secondary RBD source | Remote KRBD materialization required | Remote native RBD open check; no KRBD runtime materialization required in native mode |
| Parent NBD adapter | Default for primary KRBD parent | Legacy diagnostic fallback only when backend is explicitly `krbd` |
| Startup state | `xcolo_startup_disk_parent_backend=krbd-nbd-adapter` or `direct` | `native-rbd` for default FT RBD runtime |
| Preflight | KRBD path/materialized device plus optional native probe | Native librbd open is the default preflight for RBD parents |
| Hook interaction | Shutdown hook can unmap KRBD paths used by runtime graph | Runtime graph does not depend on `/dev/rbd*`; hook risk is limited to Cloud/libvirt restore path |

## Code-Level Plan

| File | Function / Config | Change |
|---|---|---|
| `lib/ftctl/config.sh` | `FTCTL_XCOLO_RBD_COMMANDLINE_BACKEND_DEFAULT` | Change default from `krbd` to `librbd`. |
| `etc/ablestack-vm-ftctl.conf` | deployed config default | Document native RBD as FT runtime default and KRBD as legacy diagnostic fallback. |
| `lib/ftctl/xcolo.sh` | `ftctl_xcolo_rbd_commandline_backend` | Normalize empty/invalid backend to `librbd`. |
| `lib/ftctl/xcolo.sh` | `ftctl_xcolo_build_startup_disk_args` | Generate native RBD blockdevs by default for KRBD-discovered RBD paths. |
| `lib/ftctl/xcolo.sh` | `ftctl_xcolo_apply_startup_disk_graphs` | Do not start parent NBD adapters in `librbd` mode; record `xcolo_startup_disk_parent_backend=native-rbd`. |
| `lib/ftctl/xcolo.sh` | `ftctl_xcolo_verify_stable_rbd_contract` | Use native RBD local and remote qemu-img preflight in `librbd` mode. |
| `lib/ftctl/xcolo.sh` | `ftctl_xcolo_prepare_secondary_runtime_rbd` | Skip remote KRBD materialization when the runtime graph is native RBD. |
| `bin/ablestack_vm_ftctl_selftest.sh` | startup disk graph tests | Default test asserts native RBD; explicit KRBD test remains for fallback coverage. |

## Runtime Contract

- Cloud/libvirt/profile may still store and show `/dev/rbd/<pool>/<image>`.
- FTCTL parses that stable KRBD path only as metadata for `pool/image`.
- Generated XCOLO XML must not contain `/dev/rbd/` in `librbd` mode.
- Generated XCOLO XML must contain native RBD block backend options such as
  `file.driver=rbd,file.pool=<pool>,file.image=<image>`.
- Parent NBD adapter events must be `skip` in the default path, not `start`.

## Failure Classification

New failures after this change should no longer be reported as parent NBD socket
permission failures.  Expected failure classes are:

- native RBD auth/open failure: `xcolo_rbd_startup_backend_unavailable` with
  `xcolo.rbd_backend.*` evidence;
- generated graph validation failure: `xcolo_startup_disk_graph_invalid`;
- primary create/listener failure after native RBD graph generation.

## Validation

1. Run targeted selftests:
   - `selftest_case_xcolo_startup_disk_graph_uses_native_rbd_backend_by_default`
   - `selftest_case_xcolo_startup_disk_graph_allows_explicit_krbd_backend`
   - `selftest_case_xcolo_startup_disk_graph_allows_explicit_librbd_backend`
   - `selftest_case_xcolo_librbd_contract_does_not_map_primary_krbd`
2. Build through GitHub Actions.
3. Deploy only to the 32.x FT test cluster.
4. Verify installed scripts/config show `librbd` default and `native-rbd` parent backend logic.
5. Cleanup failed r97-link-02 artifacts while preserving the successful r97-link-01 state.
