#!/bin/sh
# Point usagebar-cli.spec at a published release:
#
#   linux/packaging/rpm/bump-spec.sh <version> [owner/repo]
#
# Sets the version, the two tarball checksums (read from the release's
# .sha256 files), and adds a %changelog entry. Commit the result; COPR builds
# from the spec as committed.
set -eu

version=$1
repo=${2:-felipearosr/UsageBar}
# Overridable for tests (a file:// URL works).
base=${USAGEBAR_RELEASE_BASE:-https://github.com/$repo/releases/download}
spec="$(cd "$(dirname "$0")" && pwd)/usagebar-cli.spec"
echo "$version" | grep -Eq '^[0-9]+(\.[0-9]+)*$' || { echo "bad version: $version" >&2; exit 1; }

sha() {
    url="$base/usagebar-v$version/usagebar-cli-$version-linux-$1.tar.gz.sha256"
    value=$(curl -fsSL "$url" | cut -d ' ' -f 1)
    echo "$value" | grep -Eq '^[0-9a-f]{64}$' || { echo "no checksum at $url" >&2; exit 1; }
    echo "$value"
}
sha_x86_64=$(sha x86_64)
sha_aarch64=$(sha aarch64)

date=$(LC_ALL=C date -u '+%a %b %d %Y')
packager="Felipe Aros <21047325+felipearosr@users.noreply.github.com>"
sed -i -e "s/^%{!?cli_version:%global cli_version .*}$/%{!?cli_version:%global cli_version $version}/" \
    -e "s/^%{!?sha256_x86_64:%global sha256_x86_64 .*}$/%{!?sha256_x86_64:%global sha256_x86_64 $sha_x86_64}/" \
    -e "s/^%{!?sha256_aarch64:%global sha256_aarch64 .*}$/%{!?sha256_aarch64:%global sha256_aarch64 $sha_aarch64}/" \
    -e "s/^%changelog$/%changelog\\n* $date $packager - $version-1\\n- Update to UsageBar $version\\n/" \
    "$spec"
grep -q "cli_version $version}" "$spec" || { echo "couldn't update $spec" >&2; exit 1; }
echo "usagebar-cli.spec now at $version"
