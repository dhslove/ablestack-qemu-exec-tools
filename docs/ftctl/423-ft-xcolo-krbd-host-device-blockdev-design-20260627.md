# FT XCOLO KRBD host_device blockdev graph design

Date: 2026-06-27
Scope: `ablestack_vm_ftctl` FT/XCOLO cloud-managed KRBD primary with file/qcow2 secondary experimental path.

## Background

The previous KRBD materialization contract recorded the stable KRBD path, runtime `/dev/rbdN` path, and major/minor numbers before FT primary startup. The latest test proved that the contract is recorded correctly, but the FT primary listener failed with `xcolo_primary_krbd_open_fd_missing`.

The failure means the generated FT primary QEMU command line contained `/dev/rbd/rbd/<image>`, but the created QEMU process did not expose matching KRBD fds. The normal Cloud/libvirt VM uses libvirt native blockdev JSON like:

```text
-blockdev {"driver":"host_device","filename":"/dev/rbd/rbd/<image>","node-name":"libvirt-*-storage",...}
-device scsi-hd,drive=libvirt-*-storage,...
```

The FT generated command line instead used legacy `-drive` syntax:

```text
-drive if=none,id=ftctl-primary-parent-sda-bb,node-name=ftctl-primary-parent-sda,file.filename=/dev/rbd/rbd/<image>,driver=raw
```

This is not explicit enough for the KRBD runtime contract. It also made the KRBD fd check run while primary QEMU was still blocked at `wait=on` COLO socket listeners, before QMP/block graph materialization could be verified reliably.

## Design principles

1. Do not switch KRBD to librbd. `file=rbd:<pool>/<image>` remains invalid for the KRBD success path.
2. Do not keep native libvirt `<disk>` entries for protected disks. FT startup still removes those disks and reintroduces the guest-visible disks through `qemu:commandline`; otherwise duplicated guest disks can appear.
3. Build the FT disk graph as explicit QEMU block nodes. KRBD sources must be opened by a `host_device` node, then wrapped by the actual guest format node.
4. Treat primary listener startup and pre-migrate readiness as separate phases. Listener startup may block on COLO sockets by design, so KRBD fd absence at that exact point is recorded as pending rather than fatal.
5. The fatal KRBD materialization gate runs only before migration, after secondary red0/red1 connection and primary QMP readiness.

## Code-level changes

| Area | AS-IS | TO-BE |
|---|---|---|
| Primary KRBD parent | `-drive ...,driver=raw,file.filename=/dev/rbd/...` | `-blockdev driver=host_device,node-name=...-host,filename=/dev/rbd/...` plus `-blockdev driver=raw,node-name=parent,file=...-host` |
| Primary overlay | `-drive driver=qcow2,file.filename=primary-active,backing=parent` | `-blockdev driver=file,node-name=...-file,filename=primary-active` plus `-blockdev driver=qcow2,node-name=active,file=...-file,backing=parent` |
| Primary quorum | `-drive driver=quorum,children.0=active` | `-blockdev driver=quorum,node-name=colo,children.0=active` |
| Secondary qcow2 base | `-drive driver=qcow2,file.filename=secondary_dest` | explicit `file` node plus `qcow2` node |
| Secondary replication | nested `file.driver=qcow2` string remains, but the parent/base node references the explicit parent node | keep replication node, backed by explicit parent node |
| KRBD path policy | KRBD path allowed only for backend `krbd`; librbd URI forbidden | same, plus KRBD source is only accepted through `host_device` blockdev |
| Listener-phase KRBD gate | fd missing is fatal | fd missing/QMP unavailable records pending for `primary_listener` |
| Pre-migrate KRBD gate | no strict separate phase | `pre_migrate_materialized` requires QMP and fd/QMP path visibility |

## Expected commandline shape

Primary protected disk:

```text
-blockdev driver=host_device,node-name=ftctl-primary-host-sda,filename=/dev/rbd/rbd/<image>,aio=io_uring
-blockdev driver=raw,node-name=ftctl-primary-parent-sda,file=ftctl-primary-host-sda
-blockdev driver=file,node-name=ftctl-primary-active-file-sda,filename=/var/lib/.../primary-active-sda.qcow2
-blockdev driver=qcow2,node-name=ftctl-primary-active-sda,file=ftctl-primary-active-file-sda,backing=ftctl-primary-parent-sda
-blockdev driver=quorum,node-name=ftctl-colo-sda,read-pattern=fifo,vote-threshold=1,children.0=ftctl-primary-active-sda
-device scsi-hd,drive=ftctl-colo-sda,...
```

Secondary protected disk with qcow2 destination:

```text
-blockdev driver=file,node-name=ftctl-parent-file-sda,filename=/var/lib/libvirt/images/<base>
-blockdev driver=qcow2,node-name=ftctl-parent-sda,file=ftctl-parent-file-sda
-blockdev driver=replication,node-name=ftctl-childs-sda,mode=secondary,file.driver=qcow2,...file.backing.backing=ftctl-parent-sda
-blockdev driver=quorum,node-name=ftctl-colo-sda,read-pattern=fifo,vote-threshold=1,children.0=ftctl-childs-sda
-device scsi-hd,drive=ftctl-colo-sda,...
```

## Validation contract

1. Generated XML must still pass guest ABI and PCI manifest parity checks.
2. Generated commandline must not contain `file=rbd:` or `rbd:rbd/` when backend is `krbd`.
3. Generated commandline must contain `driver=host_device` for KRBD sources.
4. `primary_listener` KRBD namespace verification records pending evidence when QMP is unavailable or fd is not open yet.
5. `pre_migrate_materialized` verification fails if:
   - QMP cannot answer `query-named-block-nodes`,
   - expected KRBD paths are missing from the QMP block graph,
   - QEMU fd major/minor does not match the KRBD materialization contract.

## Non-goals

- Do not enable librbd as a fallback for this test path.
- Do not persist new VM details for port or disk graph state.
- Do not change Cloud-managed lifecycle ownership. Cloud still creates and owns VM/volume lifecycle; FTCTL only rewrites runtime XML and performs FT actions.