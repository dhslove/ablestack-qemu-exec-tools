# 210. DR Re-protection Replica Name Guard Design

Date: 2026-05-20

## 1. Purpose

This companion document records the qemu-side boundary for the Cloud design:

`ablestack-cloud/docs/ftctl/208-dr-reprotect-replica-name-guard-design-20260520.md`

The issue occurs before qemu FTCTL receives a profile: after a DR replica is adopted as the operating VM, Cloud may need to protect that VM back toward a Mold that still contains the old primary VM name. Cloud must generate and validate a safe target replica VM name before qemu FTCTL starts synchronization.

## 2. Boundary

qemu FTCTL must not create, rename, delete, attach, detach, or otherwise manage Cloud VM and volume lifecycle resources.

Cloud is responsible for:

- choosing the target replica VM name;
- avoiding old primary or expunging VM name collisions;
- creating the Cloud-managed replica VM and volumes;
- returning the actual target disk map and replica VM identity;
- creating the qemu FTCTL profile only after resource preparation succeeds.

qemu FTCTL is responsible for:

- accepting the final Cloud-provided profile;
- using the supplied secondary VM/runtime name and disk map;
- running forward/reverse copy and runtime DR actions;
- reporting status/events without inferring Cloud resource names.

## 3. Expected qemu Observation

When Cloud-managed target provisioning fails due to name/resource conflict, qemu FTCTL should show no profile/state for that VM. That is expected because Cloud has not completed the resource ownership step.

When Cloud-managed target provisioning succeeds, qemu FTCTL receives one complete profile using the actual replica identity returned by Cloud. Synchronization starts only from that point.

## 4. Verification

For DR re-protection after replica adoption:

- before successful Cloud resource preparation: no qemu profile and no block job;
- after successful Cloud resource preparation: profile contains the returned replica VM name and disk map;
- qemu does not attempt to rename or create Cloud VM resources;
- block copy starts only after Cloud has returned `STATE_READY`.
