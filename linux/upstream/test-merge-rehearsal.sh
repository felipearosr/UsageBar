#!/usr/bin/env bash
# Tests merge-rehearsal.sh against a throwaway repo with an "upstream" and a
# shellcheck disable=SC2016  # Backticks in single quotes are Markdown, not command substitution.
# "fork" branch: clean merge, a content conflict on an allowlisted hook, a
# modify/delete conflict, and the rendered report.

set -euo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/merge-rehearsal.sh"
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

g() {
  git -c user.name=t -c user.email=t@t -c init.defaultBranch=main "$@"
}

repo="$WORK/repo"
mkdir -p "$repo"
cd "$repo"
g init -q
printf 'a\nb\nc\n' > Hook.swift
printf 'keep\n' > Doomed.swift
printf 'top\nmiddle\nbottom\n' > Shared.swift
g add -A
g commit -qm base
g tag v0.1.0

g switch -qc upstream
printf 'a\nB-upstream\nc\n' > Hook.swift
g rm -q Doomed.swift
printf 'top\nmiddle\nbottom-upstream\n' > Shared.swift
g commit -qam "upstream release"
g tag v0.2.0

g switch -q main
printf 'a\nB-fork\nc\n' > Hook.swift
printf 'keep-fork\n' > Doomed.swift
printf 'top-fork\nmiddle\nbottom\n' > Shared.swift
mkdir -p linux/upstream
printf '# path\tfeature\nHook.swift\tMachine Sync\n' > linux/upstream/hook-allowlist.tsv
g add -A
g commit -qm "feat(sync): fork hook"
fork_main="$(git rev-parse HEAD)"

# 1. Conflicting merge.
out="$WORK/out"
"$SCRIPT" merge v0.2.0 "$out" || fail "merge exited non-zero"
[[ "$(cat "$out/merge-status")" == conflicts ]] || fail "merge-status should be conflicts"
[[ "$(wc -l < "$out/conflicts.tsv" | tr -d ' ')" == 2 ]] || fail "expected 2 conflicts: $(cat "$out/conflicts.tsv")"
expect_contains "$out/conflicts.tsv" $'Hook.swift\tUU\t1\tMachine Sync\t'
expect_contains "$out/conflicts.tsv" $'Doomed.swift\tUD\t0\tNOT ALLOWLISTED\t'
expect_contains "$out/conflicts.tsv" "feat(sync): fork hook"
expect_contains "$out/meta" "upstream_tag=v0.2.0"
[[ "$(git rev-parse HEAD^1)" == "$fork_main" ]] || fail "HEAD should be a merge onto fork main"
[[ "$(git rev-parse HEAD^2)" == "$(git rev-parse v0.2.0)" ]] || fail "HEAD^2 should be upstream"
[[ "$(sed -n 2p Hook.swift)" == B-upstream ]] || fail "conflict not resolved to upstream's side"
[[ ! -e Doomed.swift ]] || fail "modify/delete should take upstream's deletion"
[[ "$(cat Shared.swift)" == $'top-fork\nmiddle\nbottom-upstream' ]] || fail "non-conflicting fork hunk lost"
[[ -z "$(git status --porcelain)" ]] || fail "tree not clean after merge"

"$SCRIPT" check "$out" "Passing check" -- true
"$SCRIPT" check "$out" "Failing check" -- sh -c 'echo boom-output; exit 3'
"$SCRIPT" skip "$out" "Fork delta report" "not available yet"
"$SCRIPT" report "$out" > "$WORK/report.md"
expect_contains "$WORK/report.md" "## Merge rehearsal: 2 conflicting file(s), 1 failing check(s)"
expect_contains "$WORK/report.md" "### Conflicts: 2 file(s), 1 hunk(s)"
expect_contains "$WORK/report.md" '| `Hook.swift` | UU | 1 | Machine Sync |'
expect_contains "$WORK/report.md" "| Passing check | pass |"
expect_contains "$WORK/report.md" "| Failing check | fail |"
expect_contains "$WORK/report.md" "| Fork delta report | skip: not available yet |"
expect_contains "$WORK/report.md" "boom-output"

# 2. Clean merge, and the up-to-date case right after it.
g reset -q --hard "$fork_main"
g switch -qc upstream2 v0.1.0
printf 'new\n' > Added.swift
g add -A
g commit -qm "upstream adds a file"
g switch -q main
clean="$WORK/clean"
"$SCRIPT" merge upstream2 "$clean" || fail "clean merge exited non-zero"
[[ "$(cat "$clean/merge-status")" == clean ]] || fail "merge-status should be clean"
[[ ! -s "$clean/conflicts.tsv" ]] || fail "clean merge listed conflicts"
"$SCRIPT" check "$clean" "Build" -- true
"$SCRIPT" report "$clean" > "$WORK/clean.md"
expect_contains "$WORK/clean.md" "## Merge rehearsal: Clean pass"

same="$WORK/same"
"$SCRIPT" merge upstream2 "$same"
[[ "$(cat "$same/merge-status")" == up-to-date ]] || fail "merge-status should be up-to-date"

# 3. Refuses a dirty tree.
printf 'dirty\n' >> Hook.swift
if "$SCRIPT" merge v0.2.0 "$WORK/dirty" 2>/dev/null; then
  fail "merge should refuse a dirty tree"
fi

if [[ "$FAILURES" -gt 0 ]]; then
  printf '%s failure(s)\n' "$FAILURES" >&2
  exit 1
fi
printf 'merge-rehearsal tests passed\n'
