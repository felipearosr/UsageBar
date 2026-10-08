#!/usr/bin/env bash
# Packs a built tray app (linux/codexbar-tray) into a release tarball, plus
# its .sha256:
#
#   linux/release/package-tray.sh BINARY VERSION OUT_DIR ASSET
#
# BINARY is the release build of codexbar-tray, built with USAGEBAR_VERSION
# set to VERSION (resolve-version.sh's version), so `codexbar-tray --version`
# must print "codexbar-tray VERSION". ASSET is the tarball name
# (resolve-version.sh's tray_asset_<arch>). The tarball holds one directory,
# named after ASSET without .tar.gz, with codexbar-tray, LICENSE and
# README.md. Prints the tarball's path.
set -euo pipefail

if [[ $# -ne 4 ]]; then
    sed -n '2,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
    exit 2
fi
binary=$1
version=$2
out=$3
asset=$4
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)

[[ -x "$binary" ]] || { echo "package-tray: no executable at $binary" >&2; exit 1; }
[[ "$asset" == *.tar.gz ]] || { echo "package-tray: $asset isn't a .tar.gz name" >&2; exit 1; }
reported=$("$binary" --version)
[[ "$reported" == "codexbar-tray $version" ]] \
    || { echo "package-tray: $binary --version says '$reported', expected 'codexbar-tray $version'" >&2; exit 1; }

top=${asset%.tar.gz}
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
install -Dm 0755 "$binary" "$stage/$top/codexbar-tray"
install -m 0644 "$repo/LICENSE" "$stage/$top/LICENSE"
install -m 0644 "$repo/linux/codexbar-tray/README.md" "$stage/$top/README.md"

mkdir -p "$out"
out=$(cd "$out" && pwd)
(cd "$stage" && tar -czf "$out/$asset" "$top")
"$repo/Scripts/generate_release_checksum.sh" "$out/$asset" > /dev/null
printf '%s\n' "$out/$asset"
