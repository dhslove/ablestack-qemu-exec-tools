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

## Active Dual-Cluster DR Test Environment (2026-08-13)

- The currently reachable SSH port for both the `10.10.22.*` and `10.10.32.*` test clusters is `22`. Live TCP and authenticated SSH checks on 2026-08-13 showed `10.10.22.1`, `.2`, `.3`, and `.10` accepting port `22` and refusing the former port `10022`.
- The 22 cluster management server is `10.10.22.10`; compute hosts are `10.10.22.1`, `10.10.22.2`, and `10.10.22.3`.
- The 32 cluster management server is `10.10.32.10`; compute hosts are `10.10.32.1`, `10.10.32.2`, and `10.10.32.3`.
- The VMware test vCenter endpoint is `10.10.21.10`.
- Never store test passwords, API keys, or VMware credentials in repository files. Use the GitHub `dr-test` environment secrets documented in the Cloud deployment record.
- Recheck the SSH port before a destructive or deployment action because the 22 cluster port changed from the historical `10022` setting to `22`.
- Existing VMware DR profiles may store a numeric `cbtDiskId` such as `2000`. The mover must pass the matching `sourceDiskKey` as `--device-key`; do not send the numeric ID as a bare controller-address selector. Validate this compatibility before restarting a persistent DR scheduler after package deployment.
- The dual-cluster test-release baseline and GitHub `dr-test` environment
  secret names are recorded in Cloud document
  `docs/ftctl/608-cross-hypervisor-dr-dual-cluster-test-release-deployment-20260813.md`.
  Keep package run IDs, checksums, active SSH ports, schema results, and runtime
  verification evidence current there after every paired Cloud/qemu deployment.
