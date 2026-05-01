# Repository Rules

- Do not modify binary files under any circumstance unless the user explicitly requests it.
- Treat common binary artifacts as read-only during analysis, validation, and refactoring. This includes files such as `*.gz`, `*.zip`, `*.7z`, `*.xz`, `*.bz2`, `*.iso`, `*.img`, `*.qcow2`, `*.vmdk`, `*.exe`, `*.msi`, `*.dll`, `*.so`, `*.dylib`, `*.jar`, `*.war`, `*.ear`, `*.pdf`, `*.png`, `*.jpg`, `*.jpeg`, `*.gif`, `*.ico`, `*.woff`, `*.woff2`, and similar packaged or compiled artifacts.
- Do not re-encode, normalize line endings, rename, replace, or regenerate such binary files unless the user explicitly asks for that exact change.
- When a task touches paths that may be binary, prefer inspecting metadata only and stop before editing if there is any doubt.
- For ftctl-cloud integration work, use WSL as the default execution path for GitHub, GitHub Actions, artifact download, SSH, SCP, and remote host access. Do not use PowerShell for GitHub or remote host operations.
- The WSL environment is expected to provide `gh` and `GITHUB_TOKEN`/`GH_TOKEN` for GitHub access. Do not record token values in repository files or logs.
- Download GitHub Actions artifacts with `curl` from WSL and keep progress visible, for example with `--progress-bar`.
