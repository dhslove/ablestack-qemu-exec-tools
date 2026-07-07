# FTCTL DR VMware VDDK Libdir Resolution Design

Date: 2026-07-07

## 1. Purpose

This document is the qemu/ftctl-side companion design for the VMware to
ABLESTACK DR failure where `dr_vmware_mover.sh` reached nbdkit but nbdkit
looked for VDDK under `/usr/lib64/vmware-vix-disklib` instead of the
ABLESTACK-bundled compat VDDK path.

Cloud-side full-stack design:

- `ablestack-cloud/docs/ftctl/543-cross-hypervisor-dr-vddk-libdir-resolution-and-preflight-design-20260707.md`

Observed runtime failure:

```text
error_code=DR_VMWARE_NBDKIT_FAILED
worker_exit_code=69
nbdkit: error: /usr/lib64/vmware-vix-disklib/lib64/libvixDiskLib.so.9:
  cannot open shared object file
```

The target RBD path was already correct, so this fix is only about VMware
source VDDK data-plane readiness and mover startup.

## 2. Source-Level Current State

| File | Current behavior | Gap |
| --- | --- | --- |
| `lib/ftctl/dr_vmware_mover.sh` | reads `.credentials.source.vddkLibdir // .credentials.source.libdir` | no fallback when value is empty |
| `lib/ftctl/dr_vmware.sh` | reports VDDK ready when nbdkit plugin/help exists | does not prove `libvixDiskLib` is loadable |
| `lib/ftctl/dr_runtime.sh` | maps mover exit 69 to `DR_VMWARE_NBDKIT_FAILED` | no unresolved-libdir or load-failed error |
| `lib/ftctl/dr_scheduler.sh` | maps worker exit 69 to `DR_VMWARE_NBDKIT_FAILED` | same |
| `bin/ablestack_v2k.sh` | has a basic `v2k_resolve_vddk_libdir` helper | helper is not shared by FTCTL DR |

## 3. Non-goals

- Do not call v2k as the DR engine or mover.
- Do not require an operator to edit every DR Plan profile manually.
- Do not treat `nbdkit vddk --help` as sufficient preflight.
- Do not log VMware passwords or generated password files.

## 4. New Shared Resolver

Add `lib/ftctl/dr_vddk.sh`.

Candidate order:

1. `credentials.source.vddkLibdir`
2. `credentials.source.libdir`
3. `FTCTL_DR_VMWARE_VDDK_LIBDIR`
4. `VDDK_LIBDIR`
5. `/etc/profile.d/v2k-vddk.sh`
6. `/opt/vmware-vix-disklib-distrib`
7. `/usr/share/ablestack/v2k/compat/vsphere80/vddk`
8. `/usr/share/ablestack/v2k/compat/vsphere67/vddk`
9. `/usr/share/ablestack/v2k/compat/vsphere60/vddk`

Validation function:

```bash
ftctl_dr_vddk_validate_libdir() {
  local dir="${1:-}"
  [[ -n "${dir}" && -d "${dir}/lib64" ]] || return 1
  compgen -G "${dir}/lib64/libvixDiskLib.so*" >/dev/null || return 1
  nbdkit --dump-plugin vddk "libdir=${dir}" >/dev/null 2>&1 || return 1
}
```

Resolver function:

```bash
ftctl_dr_vddk_resolve_libdir() {
  local credentials_file="${1:-}" candidate
  while IFS= read -r candidate; do
    [[ -n "${candidate}" ]] || continue
    if ftctl_dr_vddk_validate_libdir "${candidate}"; then
      printf '%s\n' "${candidate}"
      return 0
    fi
  done < <(ftctl_dr_vddk_candidate_dirs "${credentials_file}")
  return 1
}
```

## 5. Mover Changes

File: `lib/ftctl/dr_vmware_mover.sh`

Before starting nbdkit:

```bash
libdir="$(ftctl_dr_vddk_resolve_libdir "${credentials_file}" || true)"
[[ -n "${libdir}" ]] || ftctl_vmware_mover_die 70 "DR_VDDK_LIBDIR_UNRESOLVED: no usable VDDK libdir"
nbdkit --dump-plugin vddk "libdir=${libdir}" >/dev/null 2>&1 \
  || ftctl_vmware_mover_die 71 "DR_VDDK_LIBRARY_LOAD_FAILED: ${libdir}"
nbdkit_args+=("libdir=${libdir}")
```

When the socket still does not become ready after that preflight, keep exit 69
and `DR_VMWARE_NBDKIT_FAILED`.

## 6. Capability Changes

File: `lib/ftctl/dr_vmware.sh`

`ftctl_dr_vmware_write_capability()` should call the resolver and write:

```json
{
  "nbdkit": true,
  "nbdkitVddk": true,
  "vddkReady": true,
  "vddkLibdir": "/usr/share/ablestack/v2k/compat/vsphere80/vddk",
  "vddkLibraryVersion": "8",
  "moverReady": true,
  "missingCode": ""
}
```

If no candidate is valid:

```json
{
  "nbdkit": true,
  "nbdkitVddk": false,
  "vddkReady": false,
  "vddkLibdir": "",
  "missingCode": "DR_VDDK_LIBDIR_UNRESOLVED"
}
```

## 7. Runtime And Scheduler Error Mapping

Update `lib/ftctl/dr_runtime.sh` and `lib/ftctl/dr_scheduler.sh`:

| Exit | Error code |
| --- | --- |
| 70 | `DR_VDDK_LIBDIR_UNRESOLVED` |
| 71 | `DR_VDDK_LIBRARY_LOAD_FAILED` |
| 69 | `DR_VMWARE_NBDKIT_FAILED` |

Preflight and projected status details should carry the capability JSON so Cloud
can render data-plane evidence. The current implementation exposes this through
the existing `capability` object, for example:

```json
{
  "capability": {
    "vddkReady": true,
    "vddkLibdir": "/usr/share/ablestack/v2k/compat/vsphere80/vddk",
    "vddkLibraryVersion": "8",
    "missingCode": ""
  },
  "vddk_ready": true,
  "missing_code": ""
}
```

## 8. Ordering

The VMware source preflight must happen before ABLESTACK target storage
preparation:

```text
profile validation
VMware mover and VDDK libdir preflight
ABLESTACK target storage preparation
VMware mover cycle
checkpoint/write status
```

This prevents a missing VDDK library from leaving a new partial target disk.

## 9. Selftests

Add selftests:

| Test | Expected |
| --- | --- |
| `dr-vmware-vddk-libdir-compat-detect` | resolver selects `/usr/share/ablestack/v2k/compat/vsphere80/vddk` |
| `dr-vmware-vddk-libdir-missing` | preflight fails with `DR_VDDK_LIBDIR_UNRESOLVED` |
| `dr-vmware-vddk-libdir-load-failed` | preflight fails with `DR_VDDK_LIBRARY_LOAD_FAILED` |
| `dr-vmware-mover-libdir-arg` | nbdkit command includes explicit `libdir=<resolved>` |
| `dr-vmware-preflight-before-target` | no target disk is created when VDDK preflight fails |

## 10. AS-IS / TO-BE

| Area | AS-IS | TO-BE |
| --- | --- | --- |
| VDDK discovery | only explicit credential libdir or nbdkit default | deterministic resolver with ABLESTACK compat paths |
| Capability | plugin/help can imply ready | actual `libvixDiskLib` loadability is required |
| Mover | nbdkit may fall back to `/usr/lib64/vmware-vix-disklib` | nbdkit always receives explicit resolved `libdir` |
| Error mapping | missing library becomes generic `DR_VMWARE_NBDKIT_FAILED` | unresolved, load failure, and nbdkit runtime failure are separate |
| Ordering | target disk can be prepared before VDDK failure | data-plane preflight runs before target preparation |

## 11. Implementation Update

Implemented on 2026-07-07:

| Area | Implemented file | Result |
| --- | --- | --- |
| Shared resolver | `lib/ftctl/dr_vddk.sh` | resolves `credentials.source.vddkLibdir`, `FTCTL_DR_VMWARE_VDDK_LIBDIR`, `VDDK_LIBDIR`, `/etc/profile.d/v2k-vddk.sh`, `/opt/vmware-vix-disklib-distrib`, and ABLESTACK v2k compat paths |
| Library validation | `lib/ftctl/dr_vddk.sh` | requires `lib64/libvixDiskLib.so*` and `nbdkit --dump-plugin vddk libdir=<path>` success |
| Capability JSON | `lib/ftctl/dr_vmware.sh` | emits `vddkLibdir`, `vddkLibraryVersion`, and specific `missingCode` |
| Mover startup | `lib/ftctl/dr_vmware_mover.sh` | always resolves and validates libdir before starting nbdkit; exits 70/71 for libdir/load failures |
| Error propagation | `lib/ftctl/dr_runtime.sh`, `lib/ftctl/dr_scheduler.sh` | maps exit 70/71 to `DR_VDDK_LIBDIR_UNRESOLVED` and `DR_VDDK_LIBRARY_LOAD_FAILED` |

No ftctl DB or state-file schema migration is required. The new data is carried
through existing runtime status, capability JSON, and Cloud run projection paths.
