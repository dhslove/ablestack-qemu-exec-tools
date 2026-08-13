# Ubuntu 26.04 release build design

## Objective

The release workflow must build and validate `ablestack-qemu-exec-tools` on
Ubuntu 26.04 LTS in addition to Ubuntu 22.04 and 24.04. The resulting offline
APT repository must be included in the Ubuntu installation ISO.

## Build path

The DEB matrix runs directly on GitHub's `ubuntu-26.04` hosted runner. This
ensures package metadata and the downloaded dependency closure come from the
target operating system instead of being copied from an older Ubuntu release.

The job produces the following workflow artifact and repository path:

```text
deb-package-26.04
release/deb/deb-ubuntu26.04
```

The repository contains the built DEB, its recursively downloaded runtime
dependencies, and `Packages.gz` metadata under `dists/stable/main/binary-amd64`.

## Release assembly

The release job downloads the 22.04, 24.04, and 26.04 DEB artifacts. Missing
any supported Ubuntu repository is fatal; an incomplete Ubuntu ISO must not be
published or reported as a successful validation build.

The Ubuntu ISO carries all three repositories:

```text
deb/deb-ubuntu22.04
deb/deb-ubuntu24.04
deb/deb-ubuntu26.04
```

The generated installer already derives `26.04` from the host `VERSION_ID`, so
Ubuntu 26.04 selects `deb/deb-ubuntu26.04` without a separate installer branch.

## Validation

Static smoke checks verify the three-version DEB matrix, collection loop,
fail-closed assembly guard, and ISO manifest. The origin-only release workflow
is dispatched with `publish_release=false`; the Ubuntu 26.04 DEB matrix job and
the final release-validation artifact must both succeed.
