#!/bin/sh
# Build usagebar-cli RPMs from local release tarballs with rpm/usagebar-cli.spec:
#
#   linux/packaging/build-cli-rpm.sh <version> <out-dir> <usagebar-cli-…-linux-ARCH.tar.gz>...
#
# Each tarball needs its .sha256 next to it. Writes
# usagebar-cli-<version>-1.<arch>.rpm (and a .sha256) per tarball. Given both
# the x86_64 and the aarch64 tarball, it also writes
# usagebar-cli-<version>-1.src.rpm, which COPR (or mock) can rebuild for
# either architecture. Needs rpmbuild.
set -eu

[ $# -ge 3 ] || { sed -n '2,10p' "$0"; exit 1; }
version=$1
out=$2
shift 2
repo=$(cd "$(dirname "$0")/../.." && pwd)
echo "$version" | grep -Eq '^[0-9]+(\.[0-9]+)*$' || { echo "bad version: $version" >&2; exit 1; }

top=$(mktemp -d)
trap 'rm -rf "$top"' EXIT
mkdir -p "$top/SOURCES" "$top/SPECS" "$out"
cp "$repo/linux/packaging/rpm/usagebar-cli.spec" "$top/SPECS/"
cp "$repo/LICENSE" "$top/SOURCES/LICENSE"

# The spec checks both checksums; a missing architecture keeps the placeholder
# and an empty source file, which only that architecture's build would read.
sha_x86_64=0000000000000000000000000000000000000000000000000000000000000000
sha_aarch64=$sha_x86_64
arches=
for tarball in "$@"; do
    case "$(basename "$tarball")" in
        *-linux-x86_64.tar.gz) arch=x86_64 ;;
        *-linux-aarch64.tar.gz) arch=aarch64 ;;
        *) echo "unknown CLI tarball arch: $tarball" >&2; exit 1 ;;
    esac
    (cd "$(dirname "$tarball")" && sha256sum -c --quiet "$(basename "$tarball").sha256") \
        || { echo "checksum mismatch: $tarball" >&2; exit 1; }
    cp "$tarball" "$top/SOURCES/usagebar-cli-$version-linux-$arch.tar.gz"
    sha=$(cut -d ' ' -f 1 "$tarball.sha256")
    if [ "$arch" = x86_64 ]; then sha_x86_64=$sha; else sha_aarch64=$sha; fi
    arches="$arches $arch"
done
for arch in x86_64 aarch64; do
    touch "$top/SOURCES/usagebar-cli-$version-linux-$arch.tar.gz"
done

# Stamp version and checksums into the spec itself, so an SRPM carries them.
sed -i -e "s/^%{!?cli_version:%global cli_version .*}$/%{!?cli_version:%global cli_version $version}/" \
    -e "s/^%{!?sha256_x86_64:%global sha256_x86_64 .*}$/%{!?sha256_x86_64:%global sha256_x86_64 $sha_x86_64}/" \
    -e "s/^%{!?sha256_aarch64:%global sha256_aarch64 .*}$/%{!?sha256_aarch64:%global sha256_aarch64 $sha_aarch64}/" \
    "$top/SPECS/usagebar-cli.spec"
grep -q "cli_version $version}" "$top/SPECS/usagebar-cli.spec" || { echo "couldn't stamp the spec" >&2; exit 1; }

# --nodeps: build hosts like Ubuntu runners have no rpm database to satisfy
# BuildRequires from (COPR and mock do).
set -- --nodeps --define "_topdir $top" --define "dist %{nil}"
host=$(uname -m)
for arch in $arches; do
    # %check runs the CLI, which only works on its own architecture.
    check=
    [ "$arch" = "$host" ] || check=--nocheck
    # shellcheck disable=SC2086 # $check is empty or one flag
    rpmbuild --quiet -bb --target "$arch" $check "$@" "$top/SPECS/usagebar-cli.spec"
    rpm="usagebar-cli-$version-1.$arch.rpm"
    cp "$top/RPMS/$arch/$rpm" "$out/$rpm"
    (cd "$out" && sha256sum "$rpm" > "$rpm.sha256")
    echo "$out/$rpm"
done

case "$arches" in
    *x86_64*aarch64* | *aarch64*x86_64*)
        rpmbuild --quiet -bs "$@" "$top/SPECS/usagebar-cli.spec" >/dev/null
        srpm="usagebar-cli-$version-1.src.rpm"
        cp "$top/SRPMS/$srpm" "$out/$srpm"
        (cd "$out" && sha256sum "$srpm" > "$srpm.sha256")
        echo "$out/$srpm"
        ;;
esac
