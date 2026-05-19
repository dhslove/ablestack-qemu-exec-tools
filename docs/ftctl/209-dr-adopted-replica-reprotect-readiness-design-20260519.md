# 209. DR Adopted Replica Re-protection Readiness Design

Date: 2026-05-19

## 1. Purpose

When a remote-Mold DR replica is adopted as the operating VM, or its replica-side protection relationship is force released, the VM becomes a normal production VM on that Mold.

The qemu FTCTL side must support that transition by cleaning only the old DR session runtime state and then getting out of the way. Cloud remains responsible for VM and volume lifecycle and for deciding whether the VM can be protected again.

## 2. Related Designs

This document extends:

- [208. DR Replica-Site Disaster Failback And Adoption Design](208-dr-replica-site-disaster-failback-and-adoption-design-20260517.md)
- Cloud companion document `207-dr-adopted-replica-reprotect-readiness-design-20260519.md`

It supersedes any wording that could be read as keeping an adopted replica under the old DR protection relationship after adoption/release.

## 3. Principles

- Cloud owns Cloud-managed VM, volume, network, storage, host placement, and lifecycle APIs.
- qemu FTCTL owns only data-plane replication, reverse copy, NBD/export handling, finalize, reprotect, and qemu runtime cleanup.
- qemu FTCTL must not create, delete, start, stop, attach, detach, resize, or format Cloud-managed resources.
- Adoption/release is terminal for the old DR relationship and must not leave qemu runtime files that restart the old session.
- A later re-protection of the adopted VM is a new protection registration with new Cloud-selected host, storage, network, and policy inputs.

## 4. qemu Runtime Cleanup Contract

For `adoptFtctlDrReplica` and `releaseFtctlDrReplicaProtection`, Cloud may ask the replica execution host to run forced session cleanup.

The qemu cleanup must remove only session-specific artifacts for the old DR protection:

- NBD exports and related transport processes.
- temporary SSH keys generated for the DR session.
- locks under `/run/ablestack-vm-ftctl/locks`.
- transient state under `/run/ablestack-vm-ftctl/state`.
- profile/config files tied to the old DR session.

It must preserve:

- the adopted VM domain if it is running.
- guest disks and Cloud-managed volume contents.
- Cloud networking and VM identity.
- host-level FTCTL services and timers.

## 5. Cloud Boundary

Cloud closes the old replica recovery session by removing protection-blocking `ftctl.*` VM details from the adopted/released VM and by returning an unconfigured `getFtctlProtection` projection when no active protection row exists.

qemu FTCTL must not store Mold API keys or infer a new target site. If the adopted VM is protected again, Cloud sends a fresh registration profile with the new peer site, host, storage, network, and fencing choices.

## 6. Verification

After adoption/release:

- no old DR NBD export remains for the adopted VM.
- no old DR lock/profile/state file restarts the old protection session.
- Cloud DB has no active `ftctl_protection` row for the old relationship.
- Cloud VM details for the adopted VM do not contain stale `ftctl.*` protection markers.
- the adopted VM can be registered as a new primary candidate when it is Running.
