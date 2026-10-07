#!/bin/sh
# Build usagebar-cli, a .deb with just the fork's codexbar CLI:
#
#   linux/packaging/build-cli-deb.sh <usagebar-cli-…-linux-ARCH.tar.gz> <version> [out-dir]
#
# The tarball must have its .sha256 next to it; it is verified first. The CLI
# goes to /usr/lib/usagebar-cli exactly as released, /usr/bin/codexbar links
# to it (the CLI resolves the link to find its resource bundle), and LICENSE
# becomes /usr/share/doc/usagebar-cli/copyright. Needs dpkg-deb. Writes
# usagebar-cli_<version>_<arch>.deb and its .sha256.
set -eu

[ $# -ge 2 ] || { sed -n '2,10p' "$0"; exit 1; }
tarball=$1
version=$2
repo=$(cd "$(dirname "$0")/../.." && pwd)
out=${3:-$repo/linux/dist}
maintainer="Felipe Aros <21047325+felipearosr@users.noreply.github.com>"

echo "$version" | grep -Eq '^[0-9]+(\.[0-9]+)*$' || { echo "bad version: $version" >&2; exit 1; }
case "$(basename "$tarball")" in
    *-linux-x86_64.tar.gz) deb_arch=amd64 ;;
    *-linux-aarch64.tar.gz) deb_arch=arm64 ;;
    *) echo "unknown CLI tarball arch: $tarball" >&2; exit 1 ;;
esac
(cd "$(dirname "$tarball")" && sha256sum -c --quiet "$(basename "$tarball").sha256") \
    || { echo "checksum mismatch: $tarball" >&2; exit 1; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
root="$work/root"
lib="$root/usr/lib/usagebar-cli"
mkdir -p "$lib" "$root/usr/bin" "$root/usr/share/doc/usagebar-cli" "$root/DEBIAN"
tar -xzo -f "$tarball" -C "$lib"
[ -x "$lib/CodexBarCLI" ] && [ -f "$lib/VERSION" ] && [ -d "$lib/CodexBar_CodexBarCore.bundle" ] \
    || { echo "unexpected CLI tarball layout" >&2; exit 1; }
ln -s ../lib/usagebar-cli/CodexBarCLI "$root/usr/bin/codexbar"
install -m 0644 "$repo/LICENSE" "$root/usr/share/doc/usagebar-cli/copyright"
find "$root" -type d -exec chmod 0755 {} +
find "$lib/CodexBar_CodexBarCore.bundle" "$lib/VERSION" -type f -exec chmod 0644 {} +
chmod 0755 "$lib/CodexBarCLI"

installed_kb=$(du -sk "$root" | cut -f1)
cat > "$root/DEBIAN/control" <<EOF
Package: usagebar-cli
Version: $version
Architecture: $deb_arch
Maintainer: $maintainer
Installed-Size: $installed_kb
Depends: libc6 (>= 2.38), libcurl4t64 | libcurl4, libsqlite3-0, libstdc++6, libgcc-s1
Conflicts: codexbar, codexbar-cli
Section: utils
Priority: optional
Homepage: https://github.com/felipearosr/UsageBar
Description: codexbar CLI with Machine Sync, from UsageBar
 The codexbar command-line tool from CodexBar by Peter Steinberger, as built
 by the UsageBar fork: AI coding-provider usage limits and costs on the
 command line, the local "codexbar serve" API, and "codexbar sync".
 Conflicts with other codexbar packages, which install the same command.
EOF

mkdir -p "$out"
deb="$out/usagebar-cli_${version}_${deb_arch}.deb"
dpkg-deb --root-owner-group -Zxz --build "$root" "$deb" >/dev/null
(cd "$out" && sha256sum "$(basename "$deb")" > "$(basename "$deb").sha256")
echo "$deb"
