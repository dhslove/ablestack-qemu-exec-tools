# Rocky Linux 9.8 release build design

## Objective

The release workflow must produce V2K and N2K offline RPM repositories for
Rocky Linux 9.8 without removing the existing Rocky 9.6 and 9.7 outputs. Both
the validation artifact and the Rocky installation ISO must carry those repos.

## Repository policy

- Rocky 9.6 and 9.7 use their fixed minor trees in the Rocky vault.
- Rocky 9.8 uses the current `pub/rocky/9.8` BaseOS, AppStream, and CRB trees.
- An unknown minor fails closed instead of silently using a different release.
- The V2K dependency calculation uses the Rocky 9.7 ABLESTACK baseline for
  Rocky 9.8 until a separately measured ABLESTACK 9.8 baseline is committed.
  Required packages are still checked against the Rocky 9.8 repositories.

## Build and assembly contract

The V2K and N2K matrix jobs build the following additional artifacts:

```text
v2k-rpm-package-rocky9.8
n2k-rpm-package-rocky9.8
```

The release job must fail if either 9.8 repository is absent. Successful
repositories are copied into the Rocky ISO tree as:

```text
v2k/v2k-rpm-rocky9.8
n2k/n2k-rpm-rocky9.8
```

Validation builds upload the two Rocky 9.8 package RPMs with the generated
ISOs. Official publication assigns `rocky9.8` suffixes to avoid duplicate RPM
asset names, increasing the expected GitHub Release asset count from 12 to 14.

## Validation

Static smoke checks verify the two 9.8 matrix entries, official Rocky `pub`
routing, all collection loops, release paths, and the 14-asset publication
guard. The origin-only release workflow is then dispatched with
`publish_release=false`; all matrix and release assembly jobs must succeed.
