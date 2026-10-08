#!/usr/bin/env bash
# Builds the GNOME extension release zip, plus its .sha256:
#
#   linux/release/package-extension.sh VERSION_NAME OUT_DIR ASSET
#
# The zip is the extensions.gnome.org (EGO) build from
# linux/usagebar-gnome/tools/ego-zip.py, with metadata.json "version-name" set
# to VERSION_NAME (resolve-version.sh's extension_version_name) in the packed
# copy only. The build fails on any EGO lint error. ASSET is the zip name
# (resolve-version.sh's extension_asset). Prints the zip's path.
set -euo pipefail

if [[ $# -ne 3 ]]; then
    sed -n '2,10p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
    exit 2
fi
version_name=$1
out=$2
asset=$3
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)

stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
# ego-zip.py prints the zip path, then the lint report; it exits 1 on errors.
python3 "$repo/linux/usagebar-gnome/tools/ego-zip.py" build --out "$stage" --version-name "$version_name" >&2
built=("$stage"/*.shell-extension.zip)
[[ ${#built[@]} -eq 1 && -f "${built[0]}" ]] || { echo "package-extension: ego-zip.py built no zip" >&2; exit 1; }

mkdir -p "$out"
out=$(cd "$out" && pwd)
mv "${built[0]}" "$out/$asset"
"$repo/Scripts/generate_release_checksum.sh" "$out/$asset" > /dev/null
printf '%s\n' "$out/$asset"
