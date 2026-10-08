#!/usr/bin/env bash
# Packs a built CodexBarCLI into a release tarball in upstream's layout, plus
# its .sha256:
#
#   linux/release/package-cli.sh BIN_DIR CLI_VERSION OUT_DIR ASSET
#
# BIN_DIR is `swift build -c release --product CodexBarCLI --show-bin-path`.
# CLI_VERSION (resolve-version.sh's cli_version) goes into VERSION, which is
# what `codexbar --version` prints after "CodexBar". ASSET is the tarball name
# (resolve-version.sh's cli_asset_<arch>). Prints the tarball's path.
set -euo pipefail

if [[ $# -ne 4 ]]; then
    sed -n '2,10p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
    exit 2
fi
bin_dir=$1
cli_version=$2
out=$3
asset=$4
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)

[[ -x "$bin_dir/CodexBarCLI" ]] || { echo "package-cli: no CodexBarCLI in $bin_dir" >&2; exit 1; }
resources=
for candidate in "$bin_dir/CodexBar_CodexBarCore.bundle" "$bin_dir/CodexBar_CodexBarCore.resources"; do
    if [[ -d "$candidate" ]]; then
        resources=$candidate
        break
    fi
done
[[ -n "$resources" ]] || { echo "package-cli: no CodexBarCore resource bundle in $bin_dir" >&2; exit 1; }

stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
install -m 0755 "$bin_dir/CodexBarCLI" "$stage/CodexBarCLI"
ln -s CodexBarCLI "$stage/codexbar"
printf '%s\n' "$cli_version" > "$stage/VERSION"
cp -R "$resources" "$stage/CodexBar_CodexBarCore.bundle"

mkdir -p "$out"
out=$(cd "$out" && pwd)
(cd "$stage" && tar -czf "$out/$asset" CodexBarCLI codexbar VERSION CodexBar_CodexBarCore.bundle)
"$repo/Scripts/generate_release_checksum.sh" "$out/$asset" > /dev/null
printf '%s\n' "$out/$asset"
