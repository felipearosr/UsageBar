#!/bin/sh
# The checks every packaging smoke test runs against an installed codexbar:
#
#   cli-checks.sh CODEXBAR EXPECTED_VERSION
#
# CODEXBAR is the command as users reach it (usually the PATH symlink), so the
# resource-bundle check also proves the bundle resolves through that link.
set -eu

bin=$1
expected=$2
fail() { printf 'cli-checks: %s\n' "$*" >&2; exit 1; }

# The CLI writes caches under $HOME as it runs; keep those out of the
# before/after comparisons by giving it a scratch home.
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
HOME=$scratch
XDG_CACHE_HOME=$scratch/.cache
XDG_DATA_HOME=$scratch/.local/share
XDG_CONFIG_HOME=$scratch/.config
XDG_STATE_HOME=$scratch/.local/state
export HOME XDG_CACHE_HOME XDG_DATA_HOME XDG_CONFIG_HOME XDG_STATE_HOME

cd /
version=$("$bin" --version) || fail "$bin --version failed"
[ "$version" = "CodexBar $expected" ] || fail "$bin --version printed '$version', expected 'CodexBar $expected'"
"$bin" sync --help >/dev/null || fail "$bin sync --help failed"
smoke=$(CODEXBAR_RESOURCE_SMOKE=1 "$bin") || fail "resource-bundle smoke check failed"
[ "$smoke" = CODEXBAR_RESOURCE_SMOKE_OK ] || fail "resource-bundle smoke check printed '$smoke'"
printf 'cli-checks: %s OK (%s)\n' "$bin" "$version"
