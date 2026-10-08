#!/usr/bin/env bash
# Release asset verifier: checks a directory of built release assets against
# the release version resolver's values before anything is published.
#
#   linux/release/verify-assets.sh RESOLVED DIR
#
# RESOLVED is resolve-version.sh's text output saved to a file. DIR holds the
# assets, flat, as they'll be attached to the GitHub release (or as downloaded
# from one). Reports every problem it finds, then exits 1 if there were any.
#
# Checks:
#   - every asset the resolver names for a released component is present
#     (the CLI and tray tarballs for each of cli_arches, the extension zip);
#   - no asset of a known kind carries another name (a stale version, say);
#   - every file has a <file>.sha256 in sha256sum format naming that bare
#     file, every .sha256 has its file, and every checksum matches;
#   - each CLI tarball has upstream's layout (CodexBarCLI, a codexbar symlink
#     to it, VERSION, CodexBar_CodexBarCore.bundle with files, nothing else),
#     VERSION says cli_version, and CodexBarCLI is an ELF for its arch;
#   - the GNOME extension zip holds metadata.json, extension.js, prefs.js,
#     stylesheet.css, the settings schema XML, LICENSE and icons; its
#     metadata.json has the asset's UUID and "version-name" says
#     extension_version_name; and it passes the extensions.gnome.org lint
#     (linux/usagebar-gnome/tools/ego-zip.py) with no errors;
#   - the provider logo pack is JSON the extension accepts for this version
#     (logopack.js parseLogoPack, run with node);
#   - each tray tarball holds one directory named after the asset with
#     codexbar-tray (an executable ELF for its arch whose --version line says
#     "codexbar-tray <version>"), LICENSE and README.md, nothing else.
#
# Adding a component: register its assets in
# the "Expected assets" section with a check_* function, and its name pattern
# in known_patterns.
set -euo pipefail

if [[ $# -ne 2 ]]; then
    sed -n '2,9p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
    exit 2
fi
resolved_file=$1
dir=$2
[[ -r "$resolved_file" ]] || { echo "verify-assets: no resolved values file: $resolved_file" >&2; exit 2; }
[[ -d "$dir" ]] || { echo "verify-assets: no asset directory: $dir" >&2; exit 2; }

problems=0
problem() {
    printf 'verify-assets: %s\n' "$*" >&2
    problems=$((problems + 1))
}

declare -A resolved=()
while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" == *=* ]] || continue
    resolved[${line%%=*}]=${line#*=}
done < "$resolved_file"
require() {
    local key
    for key in "$@"; do
        [[ -n "${resolved[$key]:-}" ]] || { echo "verify-assets: $resolved_file has no $key" >&2; exit 2; }
    done
}
value() { printf '%s' "${resolved[$1]}"; }
require tag version cli_version cli_arches extension_asset extension_version_name logos_asset
read -r -a cli_arches <<< "$(value cli_arches)"
for arch in "${cli_arches[@]}"; do require "cli_asset_$arch" "tray_asset_$arch"; done

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | cut -d ' ' -f 1
    else
        shasum -a 256 "$1" | cut -d ' ' -f 1
    fi
}

# ELF e_machine (bytes 18-19, little-endian) for each release arch.
elf_machine_for() {
    case "$1" in
        x86_64) echo 3e00 ;;
        aarch64) echo b700 ;;
        *) echo unknown ;;
    esac
}

check_cli_tarball() { # check_cli_tarball ASSET ARCH
    local asset=$1 arch=$2 path=$dir/$1 listing entry name kind expected_version actual_version
    if ! listing=$(LC_ALL=C tar -tvzf "$path" 2> /dev/null); then
        problem "$asset: not a readable .tar.gz"
        return
    fi
    local has_bin=false has_link=false has_version=false bundle_files=0
    while IFS= read -r entry; do
        # Name is the 6th field on; GNU tar and bsdtar both print "name -> target" for links.
        name=$(awk '{ for (i = 6; i <= NF; i++) printf "%s%s", $i, (i < NF ? " " : "") }' <<< "$entry")
        name=${name#./}
        case "$entry" in
            -*) kind='file' ;;
            l*) kind='link' ;;
            d*) kind='dir' ;;
            *) kind='other' ;;
        esac
        case "$kind:$name" in
            file:CodexBarCLI)
                has_bin=true
                [[ "${entry:3:1}" == x ]] || problem "$asset: CodexBarCLI isn't executable"
                ;;
            link:"codexbar -> CodexBarCLI") has_link=true ;;
            link:codexbar*) problem "$asset: codexbar must be a symlink to CodexBarCLI, found '$name'" ;;
            file:VERSION) has_version=true ;;
            dir:CodexBar_CodexBarCore.bundle | dir:CodexBar_CodexBarCore.bundle/ | dir:CodexBar_CodexBarCore.bundle/*) ;;
            file:CodexBar_CodexBarCore.bundle/*) bundle_files=$((bundle_files + 1)) ;;
            *) problem "$asset: unexpected entry '$name' ($kind)" ;;
        esac
    done <<< "$listing"
    $has_bin || problem "$asset: no CodexBarCLI"
    $has_link || problem "$asset: no codexbar symlink to CodexBarCLI"
    ((bundle_files > 0)) || problem "$asset: no CodexBar_CodexBarCore.bundle resources"
    if $has_version; then
        expected_version=$(value cli_version)
        actual_version=$(tar -xzO -f "$path" VERSION 2> /dev/null || tar -xzO -f "$path" ./VERSION)
        actual_version=${actual_version%$'\n'}
        [[ "$actual_version" == "$expected_version" ]] \
            || problem "$asset: VERSION says '$actual_version', expected '$expected_version'"
    else
        problem "$asset: no VERSION file"
    fi
    if $has_bin; then
        mkdir -p "$work/$asset"
        tar -xzf "$path" -C "$work/$asset" CodexBarCLI 2> /dev/null \
            || tar -xzf "$path" -C "$work/$asset" ./CodexBarCLI
        check_elf "$asset" "$work/$asset/CodexBarCLI" "$arch" CodexBarCLI
    fi
}

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ego_zip=$here/../usagebar-gnome/tools/ego-zip.py

check_extension_zip() { # check_extension_zip ASSET
    local asset=$1 path=$dir/$1 uuid line lint
    uuid=${asset%"-$(value version).shell-extension.zip"}
    # Prints one problem per line; GNOME 44+ compiles the schema XML on install.
    while IFS= read -r line; do
        [[ -n "$line" ]] && problem "$asset: $line"
    done < <(python3 - "$path" "$uuid" "$(value extension_version_name)" <<'PY'
import json, sys, zipfile
path, uuid, version_name = sys.argv[1:]
try:
    with zipfile.ZipFile(path) as zf:
        names = set(zf.namelist())
        raw = zf.read('metadata.json') if 'metadata.json' in names else None
except (OSError, zipfile.BadZipFile):
    print('not a readable zip')
    sys.exit()
for required in ('metadata.json', 'extension.js', 'prefs.js', 'stylesheet.css', 'LICENSE'):
    if required not in names:
        print(f'no {required}')
if not any(n.startswith('icons/') and not n.endswith('/') for n in names):
    print('no icons')
if raw is None:
    sys.exit()
try:
    meta = json.loads(raw)
except ValueError:
    print('metadata.json is not valid JSON')
    sys.exit()
if meta.get('uuid') != uuid:
    print(f"metadata.json uuid is '{meta.get('uuid')}', expected '{uuid}'")
if meta.get('version-name') != version_name:
    print(f"metadata.json version-name is '{meta.get('version-name')}', expected '{version_name}'")
schema = meta.get('settings-schema')
if not schema or f'schemas/{schema}.gschema.xml' not in names:
    print(f'no settings schema XML (schemas/{schema}.gschema.xml)')
PY
    )
    if ! lint=$(python3 "$ego_zip" lint "$path" 2>&1); then
        problem "$asset: fails the extensions.gnome.org lint:"$'\n'"$(grep -E '^(error|FAIL):' <<< "$lint")"
    fi
}

# The extension downloads this pack on the user's click and runs the same check.
check_logo_pack() { # check_logo_pack ASSET
    local asset=$1 why
    if ! why=$(node --input-type=module - "$here/../usagebar-gnome/usagebar@felipearosr.github.io/logopack.js" \
        "$dir/$asset" "$(value version)" 2>&1 <<'JS'
import fs from 'node:fs';
import {pathToFileURL} from 'node:url';
const [module, pack, version] = process.argv.slice(2);
const {parseLogoPack} = await import(pathToFileURL(module).href);
try {
    parseLogoPack(fs.readFileSync(pack, 'utf8'), version);
} catch (e) {
    console.error(e.message);
    process.exit(1);
}
JS
    ); then
        problem "$asset: the extension would reject it: $why"
    fi
}

# check_elf ASSET FILE ARCH NAME: FILE is an ELF binary for ARCH.
check_elf() {
    local magic machine
    magic=$(od -An -tx1 -N4 "$2" | tr -d ' \n')
    machine=$(od -An -tx1 -j18 -N2 "$2" 2> /dev/null | tr -d ' \n' || true)
    if [[ "$magic" != 7f454c46 ]]; then
        problem "$1: $4 isn't an ELF binary"
    elif [[ "$machine" != "$(elf_machine_for "$3")" ]]; then
        problem "$1: $4 isn't built for $3 (ELF machine $machine)"
    fi
}

check_tray_tarball() { # check_tray_tarball ASSET ARCH
    local asset=$1 arch=$2 path=$dir/$1 top=${1%.tar.gz} listing entry name kind
    if ! listing=$(LC_ALL=C tar -tvzf "$path" 2> /dev/null); then
        problem "$asset: not a readable .tar.gz"
        return
    fi
    local has_bin=false has_license=false has_readme=false
    while IFS= read -r entry; do
        name=$(awk '{ for (i = 6; i <= NF; i++) printf "%s%s", $i, (i < NF ? " " : "") }' <<< "$entry")
        name=${name#./}
        case "$entry" in
            -*) kind='file' ;;
            d*) kind='dir' ;;
            *) kind='other' ;;
        esac
        case "$kind:$name" in
            dir:"$top" | dir:"$top/") ;;
            file:"$top/codexbar-tray")
                has_bin=true
                [[ "${entry:3:1}" == x ]] || problem "$asset: codexbar-tray isn't executable"
                ;;
            file:"$top/LICENSE") has_license=true ;;
            file:"$top/README.md") has_readme=true ;;
            *) problem "$asset: unexpected entry '$name' ($kind); expected $top/ with codexbar-tray, LICENSE, README.md" ;;
        esac
    done <<< "$listing"
    $has_license || problem "$asset: no $top/LICENSE"
    $has_readme || problem "$asset: no $top/README.md"
    if ! $has_bin; then
        problem "$asset: no $top/codexbar-tray"
        return
    fi
    mkdir -p "$work/$asset"
    tar -xzf "$path" -C "$work/$asset" "$top/codexbar-tray"
    check_elf "$asset" "$work/$asset/$top/codexbar-tray" "$arch" codexbar-tray
    # The line --version prints is one string literal in the binary (main.rs).
    python3 - "$work/$asset/$top/codexbar-tray" "$(value version)" <<'PY' \
        || problem "$asset: codexbar-tray doesn't report version $(value version)"
import sys
with open(sys.argv[1], 'rb') as f:
    sys.exit(0 if b'codexbar-tray %s\n' % sys.argv[2].encode() in f.read() else 1)
PY
}

# Expected assets: name -> "checker args".
declare -A expected=()
for arch in "${cli_arches[@]}"; do
    expected[$(value "cli_asset_$arch")]="check_cli_tarball $arch"
    expected[$(value "tray_asset_$arch")]="check_tray_tarball $arch"
done
expected[$(value extension_asset)]=check_extension_zip
expected[$(value logos_asset)]=check_logo_pack

# Name patterns of every asset kind the resolver names. A file matching one
# that isn't expected is misnamed or from another version.
known_patterns=('usagebar-cli-*-linux-*.tar.gz' '*.shell-extension.zip' 'UsageBarTray-*-linux-*.tar.gz'
    'usagebar-provider-icons-*.json')

# Presence and per-asset checks.
for asset in "${!expected[@]}"; do
    if [[ ! -f "$dir/$asset" ]]; then
        problem "missing asset: $asset"
        continue
    fi
    read -r -a check <<< "${expected[$asset]}"
    "${check[0]}" "$asset" "${check[@]:1}"
done

# Names and checksums of everything in the directory.
shopt -s nullglob dotglob
for path in "$dir"/*; do
    file=$(basename "$path")
    if [[ ! -f "$path" ]]; then
        problem "not a regular file: $file"
        continue
    fi
    if [[ "$file" == *.sha256 ]]; then
        [[ -f "$dir/${file%.sha256}" ]] || problem "checksum without its asset: $file"
        continue
    fi
    if [[ -z "${expected[$file]+set}" ]]; then
        for pattern in "${known_patterns[@]}"; do
            # shellcheck disable=SC2053 # pattern match intended
            [[ "$file" == $pattern ]] && problem "unexpected asset name: $file (expected ${!expected[*]})"
        done
    fi
    sum=$path.sha256
    if [[ ! -f "$sum" ]]; then
        problem "no checksum: $file.sha256"
        continue
    fi
    line=$(cat "$sum")
    if [[ ! "$line" =~ ^([0-9a-f]{64})\ [\ *](.+)$ ]]; then
        problem "$file.sha256 isn't one '<sha256>  <file>' line"
        continue
    fi
    if [[ "${BASH_REMATCH[2]}" != "$file" ]]; then
        problem "$file.sha256 names '${BASH_REMATCH[2]}', expected the bare file name '$file'"
    elif [[ "${BASH_REMATCH[1]}" != "$(sha256_of "$path")" ]]; then
        problem "checksum mismatch: $file"
    fi
done

if ((problems)); then
    printf 'verify-assets: %d problem(s) in %s\n' "$problems" "$dir" >&2
    exit 1
fi
printf 'verify-assets: %s OK (%s, %d asset(s) checked)\n' "$dir" "$(value tag)" "${#expected[@]}"
