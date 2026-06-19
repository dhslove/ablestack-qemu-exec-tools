# FT Cloud Machine Type Contract Design - 2026-06-19

## Background

FT/XCOLO validation on QEMU 9.2.4 narrowed the viable machine type to the
`pc-i440fx-*` family with `x-colo=true` and `return-path=false`.

`pc-q35-*` repeatedly failed in the migration/materialization path, including
QEMU-side `memory_region_add_subregion_common` assertions. Continuing to
attempt q35 conversion hides the real contract problem and repeats the same
failure loop.

Cloud-managed FT must therefore make the machine type an explicit contract
between Cloud and FTCTL. The contract starts when the source/primary VM is
created; FTCTL must not convert an existing running VM between q35 and i440fx.

## Current Cloud Behavior

Cloud KVM VM creation currently selects the machine type in
`LibvirtComputingResource.createGuestFromSpec()`:

- x86 BIOS VMs default to `machine='pc'`.
- UEFI VMs force `machine='q35'` when no explicit machine override is present.
- `kvm.guest.os.machine.type` is exposed as a VM detail option.
- The KVM agent consumes that explicit override before the UEFI branch can
  select q35.
- The UI still lacks a normal operator-facing selector for the machine type.

That means FT standby VM creation can be corrected by details, but an existing
source VM that was already created and started as `pc-q35-*` remains q35. The
source VM cannot be made FT-compatible by creating only the standby as
`pc-i440fx-*`.

## Design Decision

FT supports only `pc-i440fx-*` machine types for the current QEMU 9.2.4
integration path.

Cloud must be able to materialize an explicit machine type from VM details.
FTCTL must reject unsupported source runtimes before starting COLO conversion.

General Cloud VM behavior remains unchanged unless a valid machine type override
is present. In other words:

- non-FT BIOS VM without override: keep `pc`;
- non-FT UEFI VM without override: keep `q35`;
- FT VM or standby with override: use the explicit `pc-i440fx-*` value even for
  UEFI.

For user-operated FT, Cloud must expose this as a first-class creation-time UI
choice:

- General compatibility: keep the existing Cloud default behavior.
- FT compatibility: persist `kvm.guest.os.machine.type=pc-i440fx-9.2` on the
  primary VM at deploy time.

Existing q35 VMs are not converted in place. They must be recreated or cloned
through an FT-compatible creation path.

## Cloud Changes

| Item | As-Is | To-Be |
| --- | --- | --- |
| Machine override | `kvm.guest.os.machine.type` exists but is not consumed by the KVM XML generator. | `createGuestFromSpec()` applies a validated machine override from VM details. |
| UEFI machine selection | Any UEFI VM forces `q35`. | UEFI uses q35 only when no explicit machine override is present. |
| FT standby creation | Standby details copy the source VM detail set, but effective machine type is not guaranteed. | FT standby details include an explicit FT-compatible `pc-i440fx-*` machine type. |
| Current/remote Mold | Remote Mold standby creation can inherit the same q35 problem. | Current and remote Mold provisioning use the same explicit machine detail contract. |
| Validation | q35 may be attempted and fail later in QEMU. | FT registration/preflight rejects q35 before conversion. |
| User choice | No UI path for creating an FT-compatible source VM. | VM deploy advanced settings expose an FT compatibility selector that writes the machine type detail. |
| Existing q35 source | Standby may be allocated before FTCTL rejects the source runtime. | FT registration rejects the source before standby VM/volume/protection allocation when the source lacks an explicit `pc-i440fx-*` contract. |

### Cloud Implementation Plan

1. Update `LibvirtComputingResource.createGuestFromSpec()`.
   - Read `VmDetailConstants.KVM_GUEST_OS_MACHINE_TYPE` from
     `vmTO.getDetails()`.
   - Validate that the value is non-blank and does not contain XML-unsafe
     characters.
   - Apply the override after the architecture default is set and before the
     UEFI branch can force q35.
   - In the UEFI branch, only call `guest.setMachineType(Q35)` when no override
     was applied.

2. Add KVM unit coverage.
   - BIOS without override emits `machine='pc'`.
   - UEFI without override emits `machine='q35'`.
   - UEFI with `kvm.guest.os.machine.type=pc-i440fx-9.2` emits
     `machine='pc-i440fx-9.2'`.

3. Update FTCTL provisioning service.
   - Add a helper that resolves the FT machine type to place on standby VM
     details.
   - If the primary VM already has a valid `pc-i440fx-*` detail, copy it.
   - If the primary detail is missing but FT runtime preflight returns an
     effective `pc-i440fx-*`, store that effective value on the standby detail.
   - If neither is available, use the configured FT default machine type.
   - Never set q35 on an FT standby VM.

4. Apply the same detail generation to remote Mold provisioning.
   - `prepareDrReplicaResources()` and normal cloud-managed standby creation
     must converge on the same detail construction rule.
   - Remote Mold must run a Cloud build that understands the override; otherwise
     the API should report the remote site as not FT-machine-contract capable.

5. Improve API/UI validation messages.
   - q35 source: "FT supports only pc-i440fx machine types for this QEMU
     version. Current machine type: q35."
   - missing effective machine: "Unable to determine the source VM effective
     machine type before FT registration."

6. Add deploy UI support.
   - Add an advanced KVM field named FT compatibility.
   - Default value: General compatibility.
   - FT-compatible value: `pc-i440fx-9.2`.
   - Submit the value through `details[0].kvm.guest.os.machine.type` only when
     FT compatibility is selected.

7. Add Cloud-side registration guard before provisioning.
   - For `mode=ft`, the source VM must already have
     `kvm.guest.os.machine.type=pc-i440fx-*`.
   - Missing, q35, pc-q35, or unknown values fail before standby resources are
     created.
   - HA/DR registrations are not blocked by this FT-only machine contract.

## FTCTL Changes

| Item | As-Is | To-Be |
| --- | --- | --- |
| Source machine detection | Runtime machine is observed during diagnostics but not enforced as a hard contract early enough. | Preflight resolves the effective source machine type before conversion. |
| q35 behavior | q35 can enter conversion and fail later in QEMU. | q35 fails fast with a specific unsupported-machine event. |
| Secondary runtime | Generated secondary shape can drift from the source runtime and fail near migrate. | Secondary generation uses the effective machine contract and then verifies runtime topology before migrate. |
| Failure evidence | QEMU assertion/protocol errors dominate the user-visible reason. | Unsupported machine and manifest mismatch are reported as first-class causes. |

### FTCTL Implementation Plan

1. Add an effective machine resolver.
   - Inspect `virsh dumpxml <domain>` for `<type machine='...'>`.
   - Inspect `/var/log/libvirt/qemu/<domain>.log` for the actual `-machine`
     argument.
   - Inspect the live QEMU process command line when available.
   - Normalize `pc` aliases to the observed concrete `pc-i440fx-*` value when
     the concrete value can be found.

2. Add a supported-machine gate.
   - Accept `pc-i440fx-*`.
   - Reject `q35`, `pc-q35-*`, and blank/unknown effective machine values.
   - Record:

```text
ft_machine_type_supported=no
ft_machine_type_effective=<value>
last_error=ft_unsupported_machine_type
```

3. Persist the machine contract in the runtime profile.
   - `ftctl.machine.type.effective=<pc-i440fx-*>`
   - `ftctl.colo.return-path=false`
   - `ftctl.machine.contract.source=libvirt-runtime|qemu-log|process-argv|cloud-detail`

4. Use the persisted contract when building generated primary and secondary
   runtime XML/argv.
   - Do not reintroduce q35 through Cloud defaults.
   - Do not hot plug base devices into an already-running protected VM.
   - COLO-specific disk graph and filter objects may be generated by FTCTL, but
     the base guest ABI must remain immutable.

5. Extend the pre-migrate topology gate.
   - Compare primary and secondary generated manifest machine values.
   - Compare live argv machine values.
   - Compare qtree/mtree/PCI evidence as already captured by the materialization
     gates.
   - Fail before `primary.migrate` if the machine type differs.

## Shared Contract

Cloud and FTCTL must share these fields:

```text
kvm.guest.os.machine.type=pc-i440fx-9.2
ftctl.machine.type.effective=pc-i440fx-9.2
ftctl.colo.return-path=false
ftctl.primary.runtime.manifest=<hash-or-json>
ftctl.secondary.runtime.manifest=<hash-or-json>
```

Cloud owns VM and volume lifecycle. FTCTL owns COLO runtime conversion,
handshake, migration, and runtime evidence. Neither side should silently
reinterpret q35 as an FT-compatible runtime.

## UI Contract

The VM deploy UI exposes:

| UI value | Stored detail | Behavior |
| --- | --- | --- |
| General compatibility | none | Existing Cloud behavior; UEFI can still become q35. |
| FT compatibility | `kvm.guest.os.machine.type=pc-i440fx-9.2` | Source VM is created with the FT-supported machine family. |

The FT protection dialog consumes the protection response machine fields and
blocks only `mode=ft` submission when the source VM is not FT-compatible. It
does not block HA/DR protection setup for q35 VMs.

## Implementation Order

1. Cloud KVM agent machine override support.
2. Cloud FTCTL provisioning detail generation for local and remote standby VMs.
3. FTCTL effective machine resolver and q35 fail-fast gate.
4. FTCTL runtime profile persistence and generated runtime use.
5. Cloud/API/UI error message cleanup.
6. Deploy UI FT compatibility selector.
7. Cloud registration guard before provisioning.
8. Tests and deployment validation.

## Test Plan

### Cloud Unit Tests

- `createGuestFromSpec()` BIOS without override keeps `pc`.
- `createGuestFromSpec()` UEFI without override keeps `q35`.
- `createGuestFromSpec()` UEFI with `pc-i440fx-9.2` override emits
  `pc-i440fx-9.2`.
- FTCTL standby deploy command details contain the resolved machine type.

### FTCTL Selftests

- q35 source profile fails before conversion with `ft_unsupported_machine_type`.
- pc-i440fx source profile passes the machine gate.
- generated primary/secondary manifests fail if machine values differ.
- return-path remains false for FT/XCOLO.

### Integration Tests

- BIOS + pc-i440fx FT registration and conversion path.
- UEFI + pc-i440fx FT registration and conversion path.
- UEFI + q35 FT registration rejection.
- Remote Mold standby provisioning keeps `kvm.guest.os.machine.type` and
  creates standby XML with the same machine value.

## Rollout Notes

Both Mold sites must run the Cloud build that consumes
`kvm.guest.os.machine.type`. Deploying only FTCTL is insufficient, because
Cloud can still create UEFI standby VMs as q35.

After deployment, verify:

```bash
virsh dumpxml <standby-domain> | grep "machine='pc-i440fx"
grep -R "ft_unsupported_machine_type" /usr/local/lib/ablestack-qemu-exec-tools/ftctl
grep -R "KVM_GUEST_OS_MACHINE_TYPE" /usr/share/cloudstack-management
```
