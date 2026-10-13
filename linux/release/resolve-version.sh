#!/usr/bin/env bash
# Release version resolver: the one place UsageBar release versions and asset
# names come from.
#
#   linux/release/resolve-version.sh [--metadata FILE] [--format text|github] [TAG]
#
# TAG is a pushed release tag, usagebar-v<semver>; it must match
# USAGEBAR_VERSION in the metadata file (default: usagebar-release.txt next to
# this script). Without TAG (a dry run of some ref) the version comes from the
# metadata alone.
#
# Prints KEY=value lines on stdout. --format github also appends them to
# $GITHUB_OUTPUT and reports errors as workflow annotations. Exits 1 with a
# message on stderr when the tag or the metadata is invalid, 2 on bad usage.
#
# Keys:
#   tag                 usagebar-v<version>
#   version             UsageBar semver, e.g. 1.1.0 or 1.2.0-rc.1
#   upstream_base       CodexBar release the fork is based on, e.g. 0.72.0
#   upstream_tag        that release's tag on steipete/CodexBar, e.g. v0.72.0
#   cli_version         <upstream_base>+usagebar.<version>; the CLI tarball's
#                       VERSION file, so `codexbar --version` prints
#                       "CodexBar <cli_version>"
#   prerelease          true when the semver has a pre-release part
#   distro_packages     true when the .deb/.rpm/SRPM/AUR packages are built:
#                       their version fields can't hold a semver pre-release,
#                       so pre-releases ship the tarballs only
#   cli_arches          architectures the CLI is released for
#   cli_asset_<arch>    CLI tarball name for each of cli_arches
#   extension_asset     GNOME extension zip name
#   extension_version_name
#                       the zip's metadata.json "version-name": the version
#                       with "-" as a space (1.2.0 rc.1), since
#                       extensions.gnome.org allows only letters, digits,
#                       spaces and periods, 16 at most
#   tray_asset_<arch>   tray app tarball name for each of cli_arches
#   logos_asset         provider logo pack the extension downloads on the
#                       user's click (logopack.js), since the extension zip
#                       leaves the logos out
# Every asset also ships as <asset>.sha256.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
metadata=$here/usagebar-release.txt
format=text
tag=
have_tag=false

usage() { sed -n '2,13p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2; exit 2; }

fail() {
    if [[ "$format" == github ]]; then
        printf '::error title=Release version::%s\n' "$*"
    fi
    printf 'resolve-version: %s\n' "$*" >&2
    exit 1
}

while (($#)); do
    case "$1" in
        --metadata) (($# >= 2)) || usage; metadata=$2; shift 2 ;;
        --format) (($# >= 2)) || usage; format=$2; shift 2 ;;
        -h | --help) usage ;;
        -*) usage ;;
        *) $have_tag && usage; tag=$1; have_tag=true; shift ;;
    esac
done
[[ "$format" == text || "$format" == github ]] || usage
if [[ "$format" == github && -z "${GITHUB_OUTPUT:-}" ]]; then
    fail "--format github needs GITHUB_OUTPUT"
fi

# Semver 2.0 core plus optional pre-release, without build metadata: the "+"
# belongs to cli_version, which appends the UsageBar version as build metadata.
num='(0|[1-9][0-9]*)'
ident='([0-9]*[A-Za-z-][0-9A-Za-z-]*|0|[1-9][0-9]*)'
semver_re="^$num\.$num\.$num(-$ident(\.$ident)*)?$"

is_semver() { [[ "$1" =~ $semver_re ]]; }

# read_key KEY VAR: sets VAR to KEY's value in the metadata file.
read_key() {
    local key=$1 line value='' count=0
    while IFS= read -r line || [[ -n "$line" ]]; do
        line=${line%$'\r'}
        if [[ "$line" == "$key="* ]]; then
            value=${line#"$key="}
            count=$((count + 1))
        fi
    done < "$metadata"
    ((count == 1)) || fail "$metadata must set $key exactly once (found $count)"
    printf -v "$2" '%s' "$value"
}

[[ -f "$metadata" ]] || fail "release metadata not found: $metadata"
version='' upstream_base=''
read_key USAGEBAR_VERSION version
read_key UPSTREAM_BASE upstream_base
is_semver "$version" \
    || fail "USAGEBAR_VERSION=$version in $metadata is not a semver (x.y.z or x.y.z-pre.N, no +build)"
[[ "$upstream_base" =~ ^$num\.$num\.$num$ ]] \
    || fail "UPSTREAM_BASE=$upstream_base in $metadata is not an upstream release version (x.y.z, no v)"

if $have_tag; then
    case "$tag" in
        usagebar-v*)
            tag_version=${tag#usagebar-v}
            is_semver "$tag_version" \
                || fail "tag $tag: '$tag_version' is not a semver (x.y.z or x.y.z-pre.N, no +build)"
            [[ "$tag_version" == "$version" ]] \
                || fail "tag $tag doesn't match USAGEBAR_VERSION=$version in $metadata; bump the metadata or fix the tag"
            ;;
        v[0-9]*)
            fail "tag $tag looks like an upstream CodexBar tag; UsageBar release tags are usagebar-v<semver>"
            ;;
        *)
            fail "tag $tag is missing the usagebar-v prefix; UsageBar release tags are usagebar-v<semver>"
            ;;
    esac
fi

prerelease=false
[[ "$version" == *-* ]] && prerelease=true
distro_packages=true
$prerelease && distro_packages=false
arches=(x86_64 aarch64)
# https://gjs.guide/extensions/overview/anatomy.html#version-name
extension_version_name=${version//-/ }
((${#extension_version_name} <= 16)) \
    || fail "version $version is too long for the extension's version-name (16 characters at most)"

out=$(
    printf 'tag=usagebar-v%s\n' "$version"
    printf 'version=%s\n' "$version"
    printf 'upstream_base=%s\n' "$upstream_base"
    printf 'upstream_tag=v%s\n' "$upstream_base"
    printf 'cli_version=%s+usagebar.%s\n' "$upstream_base" "$version"
    printf 'prerelease=%s\n' "$prerelease"
    printf 'distro_packages=%s\n' "$distro_packages"
    printf 'cli_arches=%s\n' "${arches[*]}"
    for arch in "${arches[@]}"; do
        printf 'cli_asset_%s=usagebar-cli-%s-linux-%s.tar.gz\n' "$arch" "$version" "$arch"
    done
    printf 'extension_asset=usagebar@felipearosr.github.io-%s.shell-extension.zip\n' "$version"
    printf 'extension_version_name=%s\n' "$extension_version_name"
    for arch in "${arches[@]}"; do
        printf 'tray_asset_%s=UsageBarTray-%s-linux-%s.tar.gz\n' "$arch" "$version" "$arch"
    done
    printf 'logos_asset=usagebar-provider-icons-%s.json\n' "$version"
)

printf '%s\n' "$out"
if [[ "$format" == github ]]; then
    printf '%s\n' "$out" >> "$GITHUB_OUTPUT"
fi
