# Repository Rules

- Do not modify binary files under any circumstance unless the user explicitly requests it.
- Treat common binary artifacts as read-only during analysis, validation, and refactoring. This includes files such as `*.gz`, `*.zip`, `*.7z`, `*.xz`, `*.bz2`, `*.iso`, `*.img`, `*.qcow2`, `*.vmdk`, `*.exe`, `*.msi`, `*.dll`, `*.so`, `*.dylib`, `*.jar`, `*.war`, `*.ear`, `*.pdf`, `*.png`, `*.jpg`, `*.jpeg`, `*.gif`, `*.ico`, `*.woff`, `*.woff2`, and similar packaged or compiled artifacts.
- Do not re-encode, normalize line endings, rename, replace, or regenerate such binary files unless the user explicitly asks for that exact change.
- When a task touches paths that may be binary, prefer inspecting metadata only and stop before editing if there is any doubt.
- For ftctl-cloud integration work, use WSL as the default execution path for `gh`, GitHub Actions control, artifact download, SSH, SCP, and remote host access.
- Use local Windows commands instead of WSL for file-heavy operations against repositories on `C:\` when WSL's `/mnt/c` 9P filesystem access would be a bottleneck. This includes Git operations that refresh or scan the working tree, such as `git status`, `git add`, `git commit`, and other commands that heavily stat repository files.
- Keep GitHub-facing work in WSL by default unless the operation is specifically blocked by `/mnt/c` 9P file access. For example, prefer WSL for `gh workflow run`, but use local Windows Git when committing or pushing a large Windows-hosted working tree is required.
- The WSL environment is expected to provide `gh` and `GITHUB_TOKEN`/`GH_TOKEN` for GitHub access. Do not record token values in repository files or logs.
- Download GitHub Actions artifacts with `curl` from WSL and keep progress visible, for example with `--progress-bar`.
- The active Cloud management UI path is `/usr/share/cloudstack-management/webapp`. Never delete or replace this directory wholesale, and never run `rsync --delete` from `ui/dist` into the webapp root. The active webapp contains server-side directories such as `WEB-INF` that are not produced by the UI build; deleting them can break the management/login UI.
- Cloud UI deployment must preserve server-side webapp directories (`WEB-INF`, and `META-INF` if present) and update only static UI assets from the built dist output, such as `index.html`, `assets/`, `css/`, `js/`, `locales/`, and related static configuration files.
- Before and after Cloud UI deployment, verify `/usr/share/cloudstack-management/webapp/WEB-INF` still exists, `/client/` returns HTTP 200 from the management server, and the active bundle contains the expected FTCTL UI markers.

## Validated DR Path Regression Gate

- Previously validated DR paths are immutable behavioral contracts. A change to shared runtime status, profile parsing, scheduler, Agent answer, or Cloud projection code must not be treated as isolated to the feature that motivated the change.
- DR plans must never pin transient virtualization placement as execution authority. VM host, coordinator, and transfer worker identities are runtime observations or leases. Do not persist or reuse `hostid`, `sourceHostUuid`, or `sourceWorkerHostUuid` to gate a future action.
- User-facing DR plan creation must not require coordinator/source/target worker selection. Cloud schedules eligible workers from live site inventory, Agent health, storage reachability, and resource admission. Manual host constraints are administrator-only preferences, never required bindings.
- A stopped or migrated VM must not make SharedMountPoint file synchronization unavailable. Resolve the current VM host only for an actual VM-local QMP/lifecycle command; schedule file transfer independently on a storage-capable worker.
- Disaster Failover, checkpoint-based Test Failover, cleanup, and release must not require source VM, source Agent, or source Mold reachability when target capability and durable recovery evidence satisfy the action contract.
- VMware source VMs may be powered on or off for protection and Full Seed. A powered-off source with a valid CBT baseline remains eligible for incremental or `NO_CHANGE`; never power it on merely to satisfy DR readiness.
- Never pin a VMware VM to an observed ESXi host. Re-resolve vCenter placement and disk locators for each capture attempt so vMotion/DRS remains transparent. Select the VDDK KVM worker automatically from the live capable pool.
- Any change to placement, capability, or Agent routing must test running, stopped, live-migrated, and source-unreachable states across VMware-to-RBD, RBD-to-RBD, and SharedMountPoint qcow2-to-qcow2.
- Any change to `dr_runtime.sh`, `dr_scheduler.sh`, the FTCTL DR JSON schema, or profile lifecycle must run the release tombstone regression: profile-present status, successful release, profile deletion, profile-missing `dr-status`, runtime status reconstruction from the tombstone, and process-restart status.
- `set -u` must never make an optional status field fatal. Every field emitted by `dr-status` requires an explicit default before conditional profile or runtime reads.
- A successful release must preserve VM, storage, network, and authority while converging to `RELEASED / UNPROTECTED / STOPPED`; Cloud must converge to `UNPROTECTED / DISABLED` without direct DB repair.
- The FTCTL branch release workflow must fail before RPM creation when the release tombstone regression fails. Do not bypass this gate for test deployment.
- Shared DR changes must run the baseline action contract suite for sync, pause/resume, release, test failover/cleanup, failover, and failback before deployment. Record any intentional contract change in the paired Cloud and qemu design documents first.

## Active Dual-Cluster DR Test Environment (2026-08-13)

- The currently reachable SSH port for both the `10.10.22.*` and `10.10.32.*` test clusters is `22`. Live TCP and authenticated SSH checks on 2026-08-13 showed `10.10.22.1`, `.2`, `.3`, and `.10` accepting port `22` and refusing the former port `10022`.
- The 22 cluster management server is `10.10.22.10`; compute hosts are `10.10.22.1`, `10.10.22.2`, and `10.10.22.3`.
- The 32 cluster management server is `10.10.32.10`; compute hosts are `10.10.32.1`, `10.10.32.2`, and `10.10.32.3`.
- The VMware test vCenter endpoint is `10.10.21.10`.
- Never store test passwords, API keys, or VMware credentials in repository files. Use the GitHub `dr-test` environment secrets documented in the Cloud deployment record.
- Recheck the SSH port before a destructive or deployment action because the 22 cluster port changed from the historical `10022` setting to `22`.
- Use native `rpm` for the 22 cluster and the administrator wrapper `aspkg` for
  the 32 cluster. Direct RPM commands are intentionally blocked on the 32
  cluster and that policy is not a host failure.
- After a 32-cluster Cloud management package replacement, verify
  `aspkg -V cloudstack-management` and `management-server.err` before declaring
  startup healthy. The 2026-08-13 test release exposed a package cleanup case
  that moved package-owned Cloud JARs into `legacy-lib` and caused
  `ClassNotFoundException: org.apache.cloudstack.ServerDaemon`; the exact
  recovery evidence is recorded in the linked Cloud deployment document.
- Existing VMware DR profiles may store a numeric `cbtDiskId` such as `2000`. The mover must pass the matching `sourceDiskKey` as `--device-key`; do not send the numeric ID as a bare controller-address selector. Validate this compatibility before restarting a persistent DR scheduler after package deployment.
- The dual-cluster test-release baseline and GitHub `dr-test` environment
  secret names are recorded in Cloud document
  `docs/ftctl/608-cross-hypervisor-dr-dual-cluster-test-release-deployment-20260813.md`.
  Keep package run IDs, checksums, active SSH ports, schema results, and runtime
  verification evidence current there after every paired Cloud/qemu deployment.
