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
#     (today: the CLI tarball for each of cli_arches);
#   - no asset of a known kind carries another name (a stale version, say);
#   - every file has a <file>.sha256 in sha256sum format naming that bare
#     file, every .sha256 has its file, and every checksum matches;
#   - each CLI tarball has upstream's layout (CodexBarCLI, a codexbar symlink
#     to it, VERSION, CodexBar_CodexBarCore.bundle with files, nothing else),
#     VERSION says cli_version, and CodexBarCLI is an ELF for its arch.
#
# Adding a component (extension zip, tray tarballs): register its assets in
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
require tag cli_version cli_arches
read -r -a cli_arches <<< "$(value cli_arches)"
for arch in "${cli_arches[@]}"; do require "cli_asset_$arch"; done

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
    local asset=$1 arch=$2 path=$dir/$1 listing entry name kind expected_version actual_version magic machine
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
        magic=$(od -An -tx1 -N4 "$work/$asset/CodexBarCLI" | tr -d ' \n')
        machine=$(od -An -tx1 -j18 -N2 "$work/$asset/CodexBarCLI" 2> /dev/null | tr -d ' \n' || true)
        if [[ "$magic" != 7f454c46 ]]; then
            problem "$asset: CodexBarCLI isn't an ELF binary"
        elif [[ "$machine" != "$(elf_machine_for "$arch")" ]]; then
            problem "$asset: CodexBarCLI isn't built for $arch (ELF machine $machine)"
        fi
    fi
}

# Expected assets: name -> "checker args".
declare -A expected=()
for arch in "${cli_arches[@]}"; do
    expected[$(value "cli_asset_$arch")]="check_cli_tarball $arch"
done

# Name patterns of every asset kind the resolver names. A file matching one
# that isn't expected is misnamed or from another version.
known_patterns=('usagebar-cli-*-linux-*.tar.gz')

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
