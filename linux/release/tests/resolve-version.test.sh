#!/usr/bin/env bash
# Tests for linux/release/resolve-version.sh: given a tag and release
# metadata, the exact values it emits, and the tags it refuses.
#
#   linux/release/tests/resolve-version.test.sh
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
resolver=$here/../resolve-version.sh
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0

pass() { printf 'ok   %s\n' "$1"; }
flunk() { printf 'FAIL %s\n' "$1" >&2; failures=$((failures + 1)); }

metadata() { # metadata VERSION BASE -> path of a metadata file
    local file=$work/meta-$RANDOM.env
    printf '# comment\nUSAGEBAR_VERSION=%s\nUPSTREAM_BASE=%s\n' "$1" "$2" > "$file"
    printf '%s\n' "$file"
}

# expect_output NAME EXPECTED ARGS...: stdout must equal EXPECTED exactly.
expect_output() {
    local name=$1 expected=$2 actual
    shift 2
    if ! actual=$("$resolver" "$@" 2> "$work/stderr"); then
        flunk "$name: exited non-zero: $(cat "$work/stderr")"
        return
    fi
    if [[ "$actual" == "$expected" ]]; then
        pass "$name"
    else
        flunk "$name"
        diff -u <(printf '%s\n' "$expected") <(printf '%s\n' "$actual") >&2 || true
    fi
}

# expect_key NAME KEY VALUE ARGS...: the KEY=VALUE line is in the output.
expect_key() {
    local name=$1 key=$2 value=$3 actual
    shift 3
    actual=$("$resolver" "$@" 2> "$work/stderr") || { flunk "$name: exited non-zero: $(cat "$work/stderr")"; return; }
    if grep -Fxq "$key=$value" <<< "$actual"; then pass "$name"; else flunk "$name: no '$key=$value' in: $actual"; fi
}

# expect_failure NAME MESSAGE-SUBSTRING ARGS...: exit 1, the message on stderr,
# nothing on stdout.
expect_failure() {
    local name=$1 message=$2 status=0 stdout
    shift 2
    stdout=$("$resolver" "$@" 2> "$work/stderr") || status=$?
    if [[ $status -ne 1 ]]; then
        flunk "$name: expected exit 1, got $status"
    elif [[ -n "$stdout" ]]; then
        flunk "$name: printed values despite failing: $stdout"
    elif ! grep -Fq -- "$message" "$work/stderr"; then
        flunk "$name: stderr lacks '$message': $(cat "$work/stderr")"
    else
        pass "$name"
    fi
}

release=$(metadata 1.1.0 0.69.0)
expect_output "release tag emits every value and asset name" \
"tag=usagebar-v1.1.0
version=1.1.0
upstream_base=0.69.0
upstream_tag=v0.69.0
cli_version=0.69.0+usagebar.1.1.0
prerelease=false
distro_packages=true
cli_arches=x86_64 aarch64
cli_asset_x86_64=usagebar-cli-1.1.0-linux-x86_64.tar.gz
cli_asset_aarch64=usagebar-cli-1.1.0-linux-aarch64.tar.gz
extension_asset=usagebar@felipearosr.github.io-1.1.0.shell-extension.zip
extension_version_name=1.1.0
tray_asset_x86_64=UsageBarTray-1.1.0-linux-x86_64.tar.gz
tray_asset_aarch64=UsageBarTray-1.1.0-linux-aarch64.tar.gz" \
    --metadata "$release" usagebar-v1.1.0

expect_output "no tag (dry run) resolves from the metadata alone" \
    "$("$resolver" --metadata "$release" usagebar-v1.1.0)" --metadata "$release"

rc=$(metadata 1.2.0-rc.1 0.72.0)
expect_key "pre-release tag sets prerelease=true" prerelease true --metadata "$rc" usagebar-v1.2.0-rc.1
expect_key "pre-release skips distro packages" distro_packages false --metadata "$rc" usagebar-v1.2.0-rc.1
expect_key "pre-release CLI version string" cli_version 0.72.0+usagebar.1.2.0-rc.1 --metadata "$rc" usagebar-v1.2.0-rc.1
expect_key "pre-release asset names carry the full semver" \
    cli_asset_x86_64 usagebar-cli-1.2.0-rc.1-linux-x86_64.tar.gz --metadata "$rc" usagebar-v1.2.0-rc.1
expect_key "pre-release extension version-name has no hyphen" \
    extension_version_name '1.2.0 rc.1' --metadata "$rc" usagebar-v1.2.0-rc.1
expect_key "every hyphen becomes a space in the version-name" \
    extension_version_name '2.0.0 beta 2' --metadata "$(metadata 2.0.0-beta-2 0.72.0)"
expect_key "alphanumeric pre-release" prerelease true --metadata "$(metadata 2.0.0-beta 0.72.0)" usagebar-v2.0.0-beta

expect_key "the checked-in metadata resolves" tag "usagebar-v$(sed -n 's/^USAGEBAR_VERSION=//p' "$here/../usagebar-release.txt")"

crlf=$work/crlf.env
printf 'USAGEBAR_VERSION=1.1.0\r\nUPSTREAM_BASE=0.69.0\r\n' > "$crlf"
expect_key "CRLF metadata" version 1.1.0 --metadata "$crlf" usagebar-v1.1.0

# Refusals.
expect_failure "tag/metadata mismatch" "doesn't match USAGEBAR_VERSION=1.1.0" --metadata "$release" usagebar-v1.1.1
expect_failure "pre-release tag against final metadata" "doesn't match" --metadata "$release" usagebar-v1.1.0-rc.1
expect_failure "upstream-style v0.69.0" "looks like an upstream CodexBar tag" --metadata "$release" v0.69.0
expect_failure "missing prefix" "missing the usagebar-v prefix" --metadata "$release" 1.1.0
expect_failure "other prefix" "missing the usagebar-v prefix" --metadata "$release" cli-fork-f05433b
for bad in 1.1 1.1.0.0 01.1.0 1.01.0 v1.1.0 1.1.0- 1.1.0-rc..1 1.1.0-rc.01 1.1.0+build 1.1.0-rc.1+build \
    '1.1.0-rc 1' ''; do
    expect_failure "bad semver '$bad'" "is not a semver" --metadata "$release" "usagebar-v$bad"
done
expect_failure "version too long for the extension's version-name" "too long for the extension's version-name" \
    --metadata "$(metadata 10.20.30-alpha.10 0.72.0)"
expect_failure "bad semver in metadata" "USAGEBAR_VERSION=1.1 " --metadata "$(metadata 1.1 0.69.0)"
expect_failure "bad upstream base" "UPSTREAM_BASE=v0.69.0" --metadata "$(metadata 1.1.0 v0.69.0)"
missing=$work/missing.env
printf 'USAGEBAR_VERSION=1.1.0\n' > "$missing"
expect_failure "missing upstream base" "must set UPSTREAM_BASE exactly once" --metadata "$missing"
twice=$work/twice.env
printf 'USAGEBAR_VERSION=1.1.0\nUSAGEBAR_VERSION=1.2.0\nUPSTREAM_BASE=0.69.0\n' > "$twice"
expect_failure "duplicated key" "must set USAGEBAR_VERSION exactly once" --metadata "$twice"
expect_failure "missing metadata file" "release metadata not found" --metadata "$work/nope.env"

# Bad usage exits 2.
status=0
"$resolver" --format yaml > /dev/null 2>&1 || status=$?
if [[ $status -eq 2 ]]; then pass "unknown format is a usage error"; else flunk "unknown format exited $status"; fi
status=0
"$resolver" --metadata "$release" usagebar-v1.1.0 usagebar-v1.1.0 > /dev/null 2>&1 || status=$?
if [[ $status -eq 2 ]]; then pass "two tags is a usage error"; else flunk "two tags exited $status"; fi

# GitHub Actions output format.
gh_out=$work/github_output
printf 'earlier=line\n' > "$gh_out"
if stdout=$(GITHUB_OUTPUT=$gh_out "$resolver" --format github --metadata "$release" usagebar-v1.1.0) \
    && [[ "$(cat "$gh_out")" == "earlier=line"$'\n'"$stdout" ]] \
    && grep -Fxq "cli_version=0.69.0+usagebar.1.1.0" "$gh_out"; then
    pass "--format github appends every value to GITHUB_OUTPUT"
else
    flunk "--format github output: $(cat "$gh_out")"
fi
status=0
stdout=$(GITHUB_OUTPUT=$gh_out "$resolver" --format github --metadata "$release" v0.69.0 2> /dev/null) || status=$?
if [[ $status -eq 1 && "$stdout" == "::error title=Release version::"*"upstream CodexBar tag"* ]]; then
    pass "--format github reports failures as annotations"
else
    flunk "--format github failure: status $status, stdout '$stdout'"
fi
status=0
env -u GITHUB_OUTPUT "$resolver" --format github --metadata "$release" > /dev/null 2>&1 || status=$?
if [[ $status -eq 1 ]]; then pass "--format github without GITHUB_OUTPUT fails"; else flunk "no GITHUB_OUTPUT exited $status"; fi

if ((failures)); then
    printf '%d resolver test(s) failed\n' "$failures" >&2
    exit 1
fi
echo "Release version resolver tests passed."
