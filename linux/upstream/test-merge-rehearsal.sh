#!/usr/bin/env bash
# Tests merge-rehearsal.sh against a throwaway repo with an "upstream" and a
# shellcheck disable=SC2016  # Backticks in single quotes are Markdown, not command substitution.
# "fork" branch: clean merge, a content conflict on an allowlisted hook, a
# modify/delete conflict, the rendered report, and the macOS-only test drift
# check with its warn status.

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

# 4. macOS-only test drift (drift) and the warn status.
drift_repo="$WORK/drift-repo"
mkdir -p "$drift_repo"
cd "$drift_repo"
claude_cache=Sources/CodexBarCore/Vendored/CostUsage/CostUsageClaudeCache.swift
pi_cache=Sources/CodexBarCore/PiSessionCostCache.swift
mkdir -p "$(dirname "$claude_cache")" Tests/CodexBarTests
g init -q
printf '    private static let schemaVersion = 4\n' > "$claude_cache"
printf '    private static let artifactVersion = 9\n' > "$pi_cache"
g add -A
g commit -qm base

g switch -qc upstream
printf '        cache.usage.version = 4\n        let row = CostUsageScanner.ClaudeUsageRow(\n' \
  > Tests/CodexBarTests/NewUpstreamTests.swift
g add -A
g commit -qm "upstream test pins the cache version"

g switch -q main
printf '    private static let schemaVersion = 6\n' > "$claude_cache"
printf '    private static let artifactVersion = 10\n' > "$pi_cache"
g commit -qam "fork bumps caches"
g tag fork-caches
printf '    public var environment: [String: String]\n    @ProcessEnvironment var safeEnvironment: [String: String]\n' \
  > Sources/CodexBarCore/ForkTimer.swift
g add -A
g commit -qm "fork stores an environment"

if "$SCRIPT" drift main upstream > "$WORK/drift.txt"; then
  fail "drift should exit 1 when it finds something"
fi
expect_contains "$WORK/drift.txt" "Cache schema: Claude fork 6, upstream 4; Pi fork 10, upstream 9"
expect_contains "$WORK/drift.txt" "NewUpstreamTests.swift:         cache.usage.version = 4"
expect_contains "$WORK/drift.txt" "NewUpstreamTests.swift:         let row = CostUsageScanner.ClaudeUsageRow("
expect_contains "$WORK/drift.txt" "ForkTimer.swift:     public var environment: [String: String]"
grep -q safeEnvironment "$WORK/drift.txt" && fail "drift flagged a @ProcessEnvironment property"
grep -q WARN "$WORK/drift.txt" && fail "drift warned about cache versions the fork is above"

g switch -q upstream
printf '    private static let schemaVersion = 6\n' > "$claude_cache"
g commit -qam "upstream catches up with the fork's Claude schema"
g switch -q main
"$SCRIPT" drift main upstream > "$WORK/drift-bump.txt" || true
expect_contains "$WORK/drift-bump.txt" "WARN: upstream Claude schema 6 >= fork 6: bump the fork above it"

"$SCRIPT" drift fork-caches fork-caches~1 > "$WORK/drift-none.txt" || fail "drift with nothing new should exit 0"
expect_contains "$WORK/drift-none.txt" "No macOS-only test drift found."

warned="$WORK/warned"
"$SCRIPT" merge upstream "$warned" || fail "drift merge exited non-zero"
"$SCRIPT" warn "$warned" "macOS-only test drift" -- "$SCRIPT" drift HEAD^1 HEAD^2
[[ "$(cat "$warned/checks/macOS_only_test_drift.status")" == warn ]] || fail "warn should record warn"
"$SCRIPT" report "$warned" > "$WORK/warned.md"
expect_contains "$WORK/warned.md" "## Merge rehearsal: Clean pass, 1 warning(s)"
expect_contains "$WORK/warned.md" "| macOS-only test drift | warn |"
expect_contains "$WORK/warned.md" "<details><summary>macOS-only test drift (warn)"

if [[ "$FAILURES" -gt 0 ]]; then
  printf '%s failure(s)\n' "$FAILURES" >&2
  exit 1
fi
printf 'merge-rehearsal tests passed\n'
