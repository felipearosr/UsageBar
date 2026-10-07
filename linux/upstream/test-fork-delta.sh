#!/usr/bin/env bash
# Tests fork-delta.sh against a throwaway repo with an "upstream" and a "fork"
# branch: linux/, a fork-owned addition, an allowlisted hook, an unlisted edit
# (failure), an upstream deletion, stale and malformed allowlist entries, and
# upstream commits made after the merge-base (never part of the delta).

set -euo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fork-delta.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
FAILURES=0

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  FAILURES=$((FAILURES + 1))
}

expect_contains() {
  local file="$1" needle="$2"
  grep -Fq -- "$needle" "$file" || fail "$file lacks: $needle"
}

expect_lacks() {
  local file="$1" needle="$2"
  ! grep -Fq -- "$needle" "$file" || fail "$file should not contain: $needle"
}

# Runs the script, saving output to $WORK/out and the exit code to $rc.
run() {
  rc=0
  "$SCRIPT" "$@" > "$WORK/out" 2>&1 || rc=$?
}

expect_rc() {
  [[ "$rc" == "$1" ]] || fail "expected exit $1, got $rc: $(cat "$WORK/out")"
}

g() {
  git -c user.name=t -c user.email=t@t -c init.defaultBranch=main "$@"
}

repo="$WORK/repo"
mkdir -p "$repo"
cd "$repo"
g init -q
printf 'a\nb\n' > Hook.swift
printf 'x\n' > Other.swift
printf 'gone\n' > Removed.swift
printf 'later\n' > Later.swift
g add -A
g commit -qm base
g tag v0.1.0
g branch upstream

# Fork: one change of each kind.
mkdir -p linux/upstream Sources
printf 'a\nb-fork\n' > Hook.swift
printf 'ext\n' > linux/extension.js
printf 'fork\n' > Sources/ForkOwned.swift
g rm -q Removed.swift
printf '# path\tfeature\tnote\nHook.swift\tMachine Sync\tsync hook\nRemoved.swift\tRepo plumbing\n' \
  > linux/upstream/hook-allowlist.tsv
g add -A
g commit -qm "fork changes"

# Upstream moves on after the merge-base; its edits are not fork delta.
g switch -q upstream
printf 'later-upstream\n' > Later.swift
g commit -qam "upstream after base"
g switch -q main

# 1. Clean: every group counted, exit 0.
run --upstream upstream
expect_rc 0
expect_contains "$WORK/out" "Merge-base: $(git rev-parse --short=9 v0.1.0) (v0.1.0)"
expect_contains "$WORK/out" "linux/                        2 files"
expect_contains "$WORK/out" "fork-owned                    1 files"
expect_contains "$WORK/out" "allowlisted hooks             2 files"
expect_contains "$WORK/out" "unlisted upstream edits       0 files"
expect_contains "$WORK/out" "  Machine Sync (1)"
expect_contains "$WORK/out" "    M Hook.swift  +1 -1"
expect_contains "$WORK/out" "  Repo plumbing (1)"
expect_contains "$WORK/out" "    D Removed.swift  +0 -1"
expect_contains "$WORK/out" "OK: every upstream file the fork edits is on the allowlist."
expect_lacks "$WORK/out" "Later.swift"
expect_lacks "$WORK/out" "ForkOwned.swift"

run --upstream upstream --verbose
expect_rc 0
expect_contains "$WORK/out" "    A Sources/ForkOwned.swift"

# 2. Unlisted upstream edit in the working tree: exit 1, file named.
printf 'x-fork\n' > Other.swift
run --upstream upstream
expect_rc 1
expect_contains "$WORK/out" "unlisted upstream edits       1 files"
expect_contains "$WORK/out" "    M Other.swift  +1 -1"
expect_contains "$WORK/out" "FAIL: 1 upstream file(s) edited without an allowlist entry."

# 3. --head compares the commit, ignoring the working tree.
run --upstream upstream --head HEAD
expect_rc 0
g checkout -q -- Other.swift

# 4. Committed unlisted edit on a PR branch; allowlisting it makes it pass.
g switch -qc pr
printf 'x-pr\n' > Other.swift
g commit -qam "touch upstream file"
run --upstream upstream --head pr
expect_rc 1
expect_contains "$WORK/out" "    M Other.swift"
printf 'Other.swift\tOpenCode on Linux\n' >> linux/upstream/hook-allowlist.tsv
run --upstream upstream
expect_rc 0
expect_contains "$WORK/out" "  OpenCode on Linux (1)"
g checkout -q -- linux/upstream/hook-allowlist.tsv
g switch -q main

# 5. Stale entry: fails by default, a note with --allow-stale.
printf 'Later.swift\tSpend Buckets\n' >> linux/upstream/hook-allowlist.tsv
run --upstream upstream
expect_rc 1
expect_contains "$WORK/out" "linux/upstream/hook-allowlist.tsv:4 Later.swift (Spend Buckets)"
expect_contains "$WORK/out" "FAIL: 1 stale allowlist entr(y/ies)."
run --upstream upstream --allow-stale
expect_rc 0
expect_contains "$WORK/out" "NOTE: 1 stale allowlist entr(y/ies), allowed by --allow-stale."
g checkout -q -- linux/upstream/hook-allowlist.tsv

# 6. Malformed allowlist entries: exit 2 with the line.
printf 'NoFeature.swift\n' >> linux/upstream/hook-allowlist.tsv
run --upstream upstream
expect_rc 2
expect_contains "$WORK/out" "hook-allowlist.tsv:4: want <path><TAB><fork feature>"
g checkout -q -- linux/upstream/hook-allowlist.tsv
printf 'Hook.swift\tAgain\nlinux/extension.js\tLinux\n' >> linux/upstream/hook-allowlist.tsv
run --upstream upstream
expect_rc 2
expect_contains "$WORK/out" "Hook.swift is already listed on line 2"
expect_contains "$WORK/out" "linux/extension.js is under linux/"
g checkout -q -- linux/upstream/hook-allowlist.tsv

# 7. No allowlist at all: every upstream edit is unlisted.
run --upstream upstream --allowlist linux/upstream/missing.tsv
expect_rc 1
expect_contains "$WORK/out" "unlisted upstream edits       2 files"

# 8. Unknown upstream ref: exit 2 with a fetch hint.
run --upstream nope/main
expect_rc 2
expect_contains "$WORK/out" "git fetch upstream main"

# 9. The merge rehearsal reads the same allowlist format.
rehearsal="$(dirname "$SCRIPT")/merge-rehearsal.sh"
if [[ -f "$rehearsal" ]]; then
  g switch -q upstream
  printf 'a\nb-upstream\n' > Hook.swift
  g commit -qam "upstream hook rewrite"
  g switch -q main
  out="$WORK/rehearsal"
  "$rehearsal" merge upstream "$out" > /dev/null 2>&1 || fail "rehearsal merge exited non-zero"
  expect_contains "$out/conflicts.tsv" $'Hook.swift\tUU\t1\tMachine Sync\t'
  # After taking upstream's side the hook is gone: stale, which the rehearsal tolerates.
  run --upstream upstream --allow-stale
  expect_rc 0
  expect_contains "$WORK/out" "linux/upstream/hook-allowlist.tsv:2 Hook.swift (Machine Sync)"
fi

if [[ "$FAILURES" -gt 0 ]]; then
  printf '%d failure(s)\n' "$FAILURES" >&2
  exit 1
fi
printf 'fork-delta.sh: all tests passed\n'
