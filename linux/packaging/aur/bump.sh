#!/bin/sh
# Point the usagebar-cli-bin PKGBUILD at a published release and regenerate
# .SRCINFO:
#
#   linux/packaging/aur/bump.sh <version> [--from DIR]
#
# Sets pkgver, resets pkgrel to 1, and pins the checksums of the LICENSE at
# the release tag and of both tarballs (read from the release's .sha256 files).
# When the release workflow's Swift version changes, update _swiftver and the
# second sha256sums entry (Swift's LICENSE.txt) by hand.
# --from DIR reads usagebar-cli-<version>-linux-<arch>.tar.gz.sha256 and
# LICENSE from DIR instead of GitHub (for tests). .SRCINFO comes from
# `makepkg --printsrcinfo`, run in an archlinux container (podman or docker)
# when makepkg isn't installed.
set -eu

[ $# -ge 1 ] || { sed -n '2,15p' "$0"; exit 1; }
version=$1
from=
if [ "${2:-}" = --from ]; then from=$3; fi
repo=${USAGEBAR_REPO:-felipearosr/UsageBar}
here=$(cd "$(dirname "$0")" && pwd)
echo "$version" | grep -Eq '^[0-9]+(\.[0-9]+)*$' || { echo "bad version: $version" >&2; exit 1; }

tarball_sha() {
    name="usagebar-cli-$version-linux-$1.tar.gz.sha256"
    if [ -n "$from" ]; then
        value=$(cut -d ' ' -f 1 "$from/$name")
    else
        value=$(curl -fsSL "https://github.com/$repo/releases/download/usagebar-v$version/$name" | cut -d ' ' -f 1)
    fi
    echo "$value" | grep -Eq '^[0-9a-f]{64}$' || { echo "no checksum for $name" >&2; exit 1; }
    echo "$value"
}
sha_x86_64=$(tarball_sha x86_64)
sha_aarch64=$(tarball_sha aarch64)
if [ -n "$from" ]; then
    sha_license=$(sha256sum "$from/LICENSE" | cut -d ' ' -f 1)
else
    sha_license=$(curl -fsSL "https://raw.githubusercontent.com/$repo/usagebar-v$version/LICENSE" | sha256sum | cut -d ' ' -f 1)
fi

sed -i -e "s/^pkgver=.*/pkgver=$version/" -e "s/^pkgrel=.*/pkgrel=1/" \
    -e "s/^sha256sums=('[0-9a-f]*'/sha256sums=('$sha_license'/" \
    -e "s/^sha256sums_x86_64=.*/sha256sums_x86_64=('$sha_x86_64')/" \
    -e "s/^sha256sums_aarch64=.*/sha256sums_aarch64=('$sha_aarch64')/" \
    "$here/PKGBUILD"

if command -v makepkg >/dev/null 2>&1; then
    (cd "$here" && makepkg --printsrcinfo) > "$here/.SRCINFO.new"
else
    engine=${CONTAINER_ENGINE:-$(command -v podman || command -v docker || true)}
    [ -n "$engine" ] || { echo "need makepkg, podman or docker to write .SRCINFO" >&2; exit 1; }
    # makepkg checks it can write its output directories even for this.
    "$engine" run --rm --security-opt label=disable --user 65534:65534 -v "$here:/pkg:ro" -w /pkg \
        -e BUILDDIR=/tmp -e PKGDEST=/tmp -e SRCDEST=/tmp -e SRCPKGDEST=/tmp -e LOGDEST=/tmp \
        docker.io/library/archlinux:latest makepkg --printsrcinfo > "$here/.SRCINFO.new"
fi
mv "$here/.SRCINFO.new" "$here/.SRCINFO"
echo "usagebar-cli-bin PKGBUILD and .SRCINFO now at $version"
