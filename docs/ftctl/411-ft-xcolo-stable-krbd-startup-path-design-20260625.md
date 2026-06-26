# FT XCOLO Stable KRBD Startup Path Design

> Note: generated qemu commandline RBD backend rules in this document are
> superseded by
> [414. FT XCOLO RBD commandline backend contract](414-ft-xcolo-rbd-commandline-backend-contract-design-20260626.md).
> Stable KRBD verification applies to Cloud/profile/disk-plan paths and to the
> default generated XCOLO qemu commandline.  `rbd:rbd/...` and `file=rbd:` are
> forbidden in default FT startup args/XML; native `librbd` is explicit
> experimental mode only.

## Background

`r97-link-02` run 135 completed baseline seeding but failed at the startup gate.

- `xcolo_disk_sda_baseline_seeded=true`
- `xcolo_disk_sdb_baseline_seeded=true`
- final error: `xcolo_startup_krbd_path_leaked:primary_restore_failed`

The state file still recorded forbidden userspace RBD URI values next to the stable ABLESTACK KRBD paths.

```text
xcolo_after_primary_stop_rbd_primary_backend_sda=ok:rbd:rbd/...
xcolo_after_primary_stop_rbd_primary_backend_sdb=ok:rbd:rbd/...
```

ABLESTACK must keep `/dev/rbd/rbd/<id>` as the stable disk path for RBD-backed VM disks. FT runtime must not reinterpret those paths as `rbd:rbd/<id>` userspace URIs.

## Principles

- The long-lived FT startup disk path is `/dev/rbd/rbd/<id>`.
- `rbd:rbd/<id>` and `file=rbd:` must not appear in FT startup args, generated XML, or state backend records.
- `/dev/rbd/rbd/<id>` in the QEMU command line is valid and must not be treated as a leak.
- Startup preflight blocks only forbidden RBD URI forms before VM creation.
- Rollback restores the primary from the Cloud/libvirt backup XML using stable paths.

## AS-IS / TO-BE

| Area | AS-IS | TO-BE |
| --- | --- | --- |
| RBD backend contract | Converts `/dev/rbd/rbd/<id>` to userspace RBD URI for `qemu-img info` | Checks `rbd info <pool/image>` and directly verifies `qemu-img info /dev/rbd/rbd/<id>` |
| Backend state | Can record userspace RBD URI backend values | Records only `ok:/dev/rbd/rbd/...` |
| Startup disk gate | Treats `/dev/rbd/` in args as a leak | Allows `/dev/rbd/`; blocks only forbidden RBD URI forms |
| Generated XML preflight | No explicit forbidden URI check | Checks generated args and XML for forbidden URI forms |
| Failure name | `xcolo_startup_krbd_path_leaked` | `xcolo_startup_krbd_uri_leaked_preflight` |

## Implementation Plan

1. Remove use of the helper that converts KRBD paths into userspace RBD URIs.
2. Make local and remote backend validation operate on stable KRBD paths directly.
3. Make `ftctl_xcolo_verify_stable_rbd_contract` record `/dev/rbd/rbd/...` backend values.
4. Make `ftctl_xcolo_apply_startup_disk_graphs` fail only when generated args/XML contain forbidden RBD URI forms.
5. Smoke test `bash -n`, absence of forbidden URI generators, `/dev/rbd/` acceptance, and forbidden URI preflight rejection.
