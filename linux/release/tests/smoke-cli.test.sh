#!/usr/bin/env bash
# Tests for linux/release/smoke-cli.sh against stand-in CLI tarballs
# (linux/packaging/tests/make-fake-tarball.sh): the fork build passes; a
# wrong version, an upstream build without sync, and a broken resource
# bundle fail.
#
#   linux/release/tests/smoke-cli.test.sh
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
smoke=$here/../smoke-cli.sh
make_fake=$here/../../packaging/tests/make-fake-tarball.sh
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0
version=0.69.0+usagebar.1.1.0

pass() { printf 'ok   %s\n' "$1"; }
flunk() { printf 'FAIL %s\n' "$1" >&2; failures=$((failures + 1)); }

good=$("$make_fake" "$work/good" "$version")

# variant NAME SED-SCRIPT: the stand-in with its CodexBarCLI script edited
# (or, for no-bundle, without its resource bundle).
variant() {
    local name=$1 edit=$2 stage=$work/$1
    mkdir -p "$stage"
    tar -xzf "$good" -C "$stage"
    if [[ "$edit" == no-bundle ]]; then
        rm -rf "$stage/CodexBar_CodexBarCore.bundle"
        mkdir "$stage/CodexBar_CodexBarCore.bundle"
    else
        sed -i "$edit" "$stage/CodexBarCLI"
    fi
    (cd "$stage" && tar -czf "$work/$name.tar.gz" CodexBarCLI codexbar VERSION CodexBar_CodexBarCore.bundle)
    printf '%s\n' "$work/$name.tar.gz"
}

expect() { # expect NAME pass|fail TARBALL VERSION [MESSAGE]
    local name=$1 want=$2 status=0
    "$smoke" "$3" "$4" > "$work/out" 2>&1 || status=$?
    if [[ $want == pass && $status -eq 0 ]]; then
        pass "$name"
    elif [[ $want == fail && $status -ne 0 ]] && grep -Fq -- "$5" "$work/out"; then
        pass "$name"
    else
        flunk "$name: exit $status: $(cat "$work/out")"
    fi
}

expect "fork build passes" pass "$good" "$version"
expect "wrong version string" fail "$good" 0.69.0 "expected 'CodexBar 0.69.0'"
# Upstream's CLI answers `sync --help` with its root help and `sync status`
# with "Unknown command".
# shellcheck disable=SC2016 # the sed script writes shell code literally
upstream=$(variant upstream 's/^    sync) .*$/    sync) [ "${2:-}" = --help ] \&\& printf "Usage:\\n  codexbar usage\\n" \&\& exit 0; echo "Unknown command sync" >\&2; exit 1 ;;/')
expect "upstream build without sync" fail "$upstream" "$version" "not the UsageBar build"
expect "broken resource bundle" fail "$(variant no-bundle no-bundle)" "$version" "CODEXBAR_RESOURCE_SMOKE=1"
expect "failing config validate" fail "$(variant config 's/^    \*) echo "fake codexbar" ;;$/    config) exit 3 ;;\n    *) echo "fake codexbar" ;;/')" \
    "$version" "config validate --format json' exited 3"

if ((failures)); then
    printf '%d CLI smoke test(s) failed\n' "$failures" >&2
    exit 1
fi
echo "CLI smoke script tests passed."
