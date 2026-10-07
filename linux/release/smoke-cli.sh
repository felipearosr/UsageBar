#!/usr/bin/env bash
# Smoke tests a packed CLI release tarball on this machine:
#
#   linux/release/smoke-cli.sh TARBALL CLI_VERSION
#
# Unpacks TARBALL and checks, with a scratch HOME and no real accounts:
#   - `codexbar --version` prints exactly "CodexBar <CLI_VERSION>";
#   - `codexbar --help` succeeds;
#   - `codexbar sync --help` succeeds and lists the sync commands, and
#     `codexbar sync status` isn't an unknown command (this is the fork build);
#   - the resource-bundle smoke check passes through CodexBarCLI and through
#     the codexbar symlink;
#   - `codexbar config validate --format json` exits 0.
# The tarball must be for this machine's architecture.
set -euo pipefail

if [[ $# -ne 2 ]]; then
    sed -n '2,13p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
    exit 2
fi
tarball=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
cli_version=$2

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
fail() { printf 'smoke-cli: %s\n' "$*" >&2; exit 1; }

# Nothing the CLI writes or reads may be the runner's (or a developer's) own.
scratch=$work/home
mkdir -p "$scratch"
export HOME=$scratch XDG_CACHE_HOME=$scratch/.cache XDG_CONFIG_HOME=$scratch/.config \
    XDG_DATA_HOME=$scratch/.local/share XDG_STATE_HOME=$scratch/.local/state
export CODEXBAR_DISABLE_KEYCHAIN_ACCESS=1
unset CODEXBAR_CONFIG

cli=$work/cli
mkdir -p "$cli"
tar -xzf "$tarball" -C "$cli"

# run NAME CMD...: runs CMD from / with a time limit; stdout in $work/NAME,
# stderr in $work/NAME.err (loader warnings such as Fedora's unversioned
# libcurl go there and don't count).
run() {
    local name=$1 status=0
    shift
    (cd / && timeout 60 "$@") > "$work/$name" 2> "$work/$name.err" || status=$?
    if ((status)); then
        cat "$work/$name" "$work/$name.err" >&2
        fail "'$*' exited $status"
    fi
}

run version "$cli/codexbar" --version
version=$(cat "$work/version")
[[ "$version" == "CodexBar $cli_version" ]] \
    || fail "--version printed '$version', expected 'CodexBar $cli_version'"

run help "$cli/codexbar" --help
grep -q '^Usage:' "$work/help" || { cat "$work/help" >&2; fail "--help printed no usage"; }

# Top-level --help shows the default `usage` command's help (upstream routes
# flag-first argv to `usage`), so the fork check reads `sync --help`: an
# upstream build answers that with its root help, which has no sync commands.
run sync-help "$cli/codexbar" sync --help
grep -Eq '^[[:space:]]*codexbar sync (status|pair|push)' "$work/sync-help" \
    || { cat "$work/sync-help" >&2; fail "sync --help lists no codexbar sync commands: not the UsageBar build"; }
# The failure users saw with an upstream CLI (unpaired here, so any other
# answer is fine).
(cd / && timeout 60 "$cli/codexbar" sync status --json-only) > "$work/sync-status" 2>&1 || true
if grep -q 'Unknown command' "$work/sync-status"; then
    cat "$work/sync-status" >&2
    fail "codexbar sync is an unknown command"
fi

for bin in CodexBarCLI codexbar; do
    run "resources-$bin" env CODEXBAR_RESOURCE_SMOKE=1 "$cli/$bin"
    [[ "$(cat "$work/resources-$bin")" == CODEXBAR_RESOURCE_SMOKE_OK ]] \
        || fail "resource smoke through $bin printed '$(cat "$work/resources-$bin")'"
done

run config-validate "$cli/codexbar" config validate --format json

printf 'smoke-cli: %s OK (%s)\n' "$(basename "$tarball")" "$version"
