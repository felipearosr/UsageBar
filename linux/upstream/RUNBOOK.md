# Upstream merge runbook

How UsageBar takes each steipete/CodexBar release. Written from the 0.43.1 → 0.68.0 merge (#26), the first
rehearsal against 0.72.0, and the 0.72.0 merge itself (#95). If a step here turns out wrong during a merge, fix
this file in the same PR.

Remotes, as in every checkout of this repo:

```sh
git remote add upstream https://github.com/steipete/CodexBar.git   # once
git fetch origin
git fetch upstream main --tags
```

## 0. Before you start

1. **Read the rehearsal issue** (label `merge-rehearsal`, pinned). It lists the files that will conflict, the
   fork feature each one serves, and which checks fail after taking upstream's side. That is your work list.
2. **Fork `main` must be green.** If `main`'s CI is red, fix that first (#51). A merge on top of a red `main`
   can't use CI as its gate.
3. **No other merge branch is open.** `gh pr list -R felipearosr/UsageBar --search "merge upstream in:title"`
   and `git branch -a --list '*merge-upstream*'`. If one exists, apply the staleness rule (step 8) before
   starting another.

## 1. One PR per upstream release tag

Merge the **release tag**, not `upstream/main`, so the fork's base is a version users can name.

```sh
TAG=v0.72.0                                    # newest tag on steipete/CodexBar
git switch -c felipearosr/merge-upstream-$TAG origin/main
git merge --no-ff $TAG -m "Merge upstream CodexBar $TAG"
```

- Branch name: `felipearosr/merge-upstream-<tag>`. One branch, one PR, one tag.
- If several releases came out since the last merge, take the newest tag only. #26 jumped 2,840 commits in one
  merge; the routine exists so that doesn't happen again, but if it does, one merge is still right.
- `version.env` comes from upstream (`MARKETING_VERSION`, `BUILD_NUMBER`). Take upstream's values; the fork
  never edits that file.
- **Bump the upstream base** in the same PR: set `UPSTREAM_BASE` in
  [`linux/release/usagebar-release.txt`](../release/usagebar-release.txt) to the tag without its `v`
  (`0.72.0` for `v0.72.0`). Releases read it from there: `codexbar --version` prints
  `CodexBar <base>+usagebar.<version>` and the release notes name the base.

## 2. Resolve conflicts: upstream's side, then re-apply the fork change through its hook

For each conflicted file:

```sh
git diff --name-only --diff-filter=U                       # the list
git log --oneline $TAG..origin/main -- <file>              # why the fork touched it
git diff $(git merge-base origin/main $TAG) origin/main -- <file>   # exactly what the fork changed
```

1. Start from upstream's version (`git checkout $TAG -- <file>`, or keep their hunks in the editor).
2. Re-apply the fork change on top of upstream's new code, through the hook named in the fork delta allowlist
   (#52, `linux/upstream/hook-allowlist.tsv`). Don't port the fork's old code over upstream's rewrite: #26
   re-implemented the Spend Bucket loaders on upstream's new scanners instead of reviving the fork's parallel
   caches.
3. If upstream now does what the fork change did, drop the fork change and say so in the PR. (Upstream's
   `CodexBarConfig` started keeping unknown provider entries in 0.68.0, which left #25 needing only its GNOME
   commit.)
4. **macOS-only fork UI loses to upstream.** If upstream rewrote a macOS view the fork had changed, take
   upstream's view and drop the fork change (#26 dropped the Overview row redesign `d85e17f`, `c206772` and
   its `OverviewMenuCardRowViewTests`). List it under "Dropped" in the PR.
5. Never resolve a conflict in `linux/`; upstream doesn't have it. A conflict there means something is wrong
   with the merge base.

### Known hotspots

From #26 (23 conflicted files) and the rehearsal on 2026-10-06 (`upstream/main` at v0.72.0, 442 commits ahead:
1 file, 2 hunks). Each later isolation ticket (#56–#59) should shrink this table.

| Area | Files | Fork feature | How #26 re-applied it |
| --- | --- | --- | --- |
| Cost scanners | `Sources/CodexBarCore/Vendored/CostUsage/`: `CostUsageScanner.swift`, `+Claude.swift`, `+CacheHelpers.swift`, `+TemporalBuckets.swift`, `CostUsageStore+ReadView.swift`; `Sources/CodexBarCore/PiSessionCostScanner.swift` | Machine Sync: Spend Buckets | Codex: optional `CodexSpendBucketCollector` on `buildCodexReportFromCache`, per-row cost factored into `codexRowCost`. Claude: `ClaudeUsageRow.omittedFields` captured at parse time, per-row cost in `claudeRowCost`. Pi: per-file `hourContributions` and `hourKey` on keyed entries. **The one real conflict in #95 (0.72.0) was here**: upstream reworked the Claude row builder (scan-range check before pricing, `cacheCreate1h`) and removed the private `ClaudeTokens` struct. #95 kept upstream's builder and re-applied only `claudeOmittedUsageFields(usage)` → `omittedFields`; `ClaudeSpendBucketLinuxTests` "fields the log omits stay absent" fails until it is. **0.73.0** auto-merged here but added a hand-written `ClaudeUsageRow` decoder (`CostUsageScanner+ClaudeRowDecoding.swift`) that skipped the fork's `"omit"` key; the fork decodes `omittedFields` there. `ClaudeSpendBucketLinuxTests` "omitted fields survive the persisted row encoding" catches it. If upstream adds fields to that decoder, check `omit` is still read. |
| Cache schema versions | `Vendored/CostUsage/CostUsageClaudeCache.swift` (`schemaVersion`), `PiSessionCostCache.swift` (`artifactVersion`, `pi-sessions-vN.json`) | Spend Buckets | See [Cache schema versions](#cache-schema-versions) below. |
| CLI entry and help | `Sources/CodexBarCLI/CLIEntry.swift`, `CLIHelp.swift`, `Tests/CodexBarTests/CLIEntryTests.swift` | Machine Sync: `codexbar sync` | Register `sync` next to upstream's commands; help text in `CLIHelp`. Since 0.73.0, `main()` routes `sync` through its `default:` case to the fork-owned `runForkCommand` (`CLISyncCommand.swift`): upstream's new `plugins` case put the dispatch switch at swiftlint's cyclomatic complexity limit (20), so the fork's own `case` made it 21. |
| CLI errors | `Sources/CodexBarCLI/CLIErrorReporting.swift`, `CLIIO.swift` | Machine Sync: error `reason` | Carry `reason` and `exit(reason:)` into upstream's error reporting. |
| `serve` | `Sources/CodexBarCLI/CLIServeCommand.swift`, `CLILocalHTTPServer.swift` (409, 502 status cases), `Tests/CodexBarTests/CLIServeRouterTests.swift` | Machine Sync: `/sync/status`, `/sync/push`; `/cost?days=N` | `/sync/*` through upstream's data-route auth, `Cache-Control: no-store`; `ServeRuntime` takes `sync` with a default; `/cost?days=N` maps to `CostReportingPeriod.rolling(days:)`. |
| OpenCode | `Sources/CodexBarCore/Providers/OpenCode/OpenCodeProviderDescriptor.swift` | OpenCode on Linux | Browser-support exemption lives in the descriptor, like OpenCode Go. |
| macOS menu | `StatusItemController+MenuCardItems.swift`, `+MenuTypes.swift`, `+Menu.swift` | none (macOS UI) | Upstream's side taken, fork change dropped. |
| Plumbing | `CHANGELOG.md`, `AGENTS.md`, `Makefile`, `Scripts/lint.sh`, `.gitignore`, `docs/cli.md`, `docs/opencode.md` | repo plumbing | Insert the fork's lines into upstream's text; never reorder upstream's. |

### Cache schema versions

The fork's Spend Buckets store extra data in two upstream caches, so the fork runs its own schema numbers:

| Cache | Constant | Fork | Upstream at v0.73.0 |
| --- | --- | --- | --- |
| Claude | `CostUsageClaudeCache.schemaVersion` | 6 (#88: persists `omittedFields`) | 4 |
| Pi | `PiSessionCostCache.artifactVersion` | 10 (hour data) | 9 |

**Rule: when upstream bumps either number to the fork's value or above, bump the fork's above upstream's** in
the merge PR, and list the cache rebuild under "Notes". Otherwise upstream's new version equals an old fork
version and users keep a cache with the wrong shape. Update this table on every merge.
`merge-rehearsal.sh drift` (step 4) prints both pairs and warns when upstream has caught up.

### Fork code that outgrows an upstream file

Upstream files grow between releases. A merge that adds upstream lines to a file the fork also extended can push
it past swiftlint's `file_length` limit (1,500 lines): in #95, `CLIServeCommand.swift` came out at 1,501. Don't
raise the limit or trim upstream's code: move the fork's code into a fork-owned file and leave a one-line hook in
upstream's (#95 moved the `/sync/*` auth and dispatch into `serveSyncRoute` in `CLIServeSync.swift`, leaving one
`case .syncStatus, .syncPush:` line). That also shrinks the next merge's conflict surface.

## 3. Regenerate generated files

Run every generator in write mode, then commit what changed. A stale generated file is how #26 left `main`'s
`lint` red.

```sh
Scripts/regenerate-codex-parser-hash.sh          # hashes Vendored/CostUsage (minus *Claude* and CostUsageStore*)
Scripts/regenerate-provider-manifests.sh
Scripts/regenerate-plugin-js.sh --write
git status --short Sources/                      # commit any change
```

The Codex parser hash changes whenever the fork's Codex scanner hooks change, so expect it on every merge that
touches the scanners. The 0.72.0 rehearsal found it stale even before conflict resolution.

## 4. Format, lint, tests

Without a local Swift toolchain, use containers: `localhost/codexbar-swift:6.3.3` (the image #26 used, Swift
6.3.3 like CI), `ghcr.io/nicklockwood/swiftformat`, `ghcr.io/realm/swiftlint`. Upstream's
`ProcessOwnershipReaperTests` spawns `/usr/bin/python3`; a container without it fails that suite with "The file
doesn't exist", which is the container, not the merge (GitHub's runners have python3).

Mount the checkout with **`:z` (shared label), never `:Z`**. `:Z` relabels `/src` private to one container, so a
second container started while a build runs (swiftlint next to the Swift build, say) relabels it again and the
build dies with permission errors partway through.

```sh
# Format only the Swift files that differ from upstream, so upstream code isn't reformatted.
git diff --name-only $TAG -- '*.swift' | xargs podman run --rm -v "$PWD:/src:z" -w /src \
  ghcr.io/nicklockwood/swiftformat:latest
podman run --rm -v "$PWD:/src:z" -w /src ghcr.io/realm/swiftlint:latest swiftlint lint --strict
./Scripts/lint.sh lint-linux                     # what CI's lint job runs (installs its tools into .build)

# Linux test target and the fork suites. Run the fork suites first: they say whether a fork feature broke.
podman run --rm -v "$PWD:/src:z" -w /src localhost/codexbar-swift:6.3.3 bash -c '
  swift build --build-tests &&
  . Scripts/test_environment.sh &&
  swift test --skip-build --filter "MachineSync|CLIServeSync|CLISync|SpendBucket|OpenCode|CLIServeRouter" &&
  swift test --skip-build --parallel'

# GNOME extension
node --test linux/usagebar-gnome/tests/*.test.mjs
```

The fork suites: Machine Sync create, pair, push, status, management, timer and protocol vectors;
`CLIServeSync`; `CLISync*`; Spend Buckets for Codex, Claude and Pi (and their merging); OpenCode on Linux.
All must pass. #26 had 1,008 tests in 136 suites passing; #95 had 1,095 in 146 (152 tests in 23 fork suites); the 0.73.0 merge had 1,110 in 149.

### macOS-only tests: check them before you push

The Linux test target is `TestsLinux`. `Tests/CodexBarTests` builds only on macOS, so neither the container nor
the rehearsal runs it; the first place its failures show up is the PR's macOS CI shards, about 70 minutes a
round when many PRs are queued (see [Flaky tests and slow runners](#flaky-tests-and-slow-runners)). Upstream
writes those tests against upstream's caches and code, so new ones break on fork differences. #95 hit three:

- `CostUsageClaudeFragmentTests` "save encodes only three changed files…" and the opt-in
  `CostUsageClaudePersistenceBenchmarkTests` set `cache.usage.version = 4`, upstream's Claude schema. The fork's is
  6, so they had to say 6.
- `CostUsageClaudePriceRangeTests` "range rejection preserves golden rows…" expected Claude rows without the
  fork's `omittedFields` (incomplete streaming entries carry `[.cacheRead, .cacheCreation]` in the fork).
- Upstream's new `ProcessEnvironmentStorageTests` walks `Sources/` and flagged fork code:
  `MachineSyncTimerInstaller.environment` stored a `[String: String]` without the `@ProcessEnvironment` wrapper.

0.73.0 added two more: `CostUsageClaudeFragmentTests` "decoded cache and persistence identity…" and
`CostUsageClaudeRowStorageTests` set `version = 4`, and the latter's "row decoding matches synthesized schema"
compares the decoder against a synthesized row struct that must list the fork's `omit` key. The drift grep misses
rows built through a `typealias Row = …ClaudeUsageRow`, so also read any new `Row(` in Claude cache tests.

Before pushing, run the drift check from the merge branch (it reads refs, so the tree can be in any state):

```sh
linux/upstream/merge-rehearsal.sh drift origin/main $TAG
```

It prints the fork's and upstream's cache schema versions (warning if upstream has caught up), every line
upstream added to `Tests/CodexBarTests` since the last merge that sets a cache `version`, names
`schemaVersion`/`artifactVersion`, builds `ClaudeUsageRow`/`PiPackedUsage`, or walks `"Sources"`, and every fork
line that declares an environment dictionary without `@ProcessEnvironment`. It exits 1 when it lists anything.
Not every hit is a bug (a test may pin an old version on purpose); read each, fix the ones that disagree with the
fork, and say in the PR which upstream tests you adjusted and why. The same grep by hand:

```sh
base=$(git merge-base origin/main $TAG)
git diff -U0 $base $TAG -- Tests/CodexBarTests | grep -E '^\+.*(\.version = [0-9]+|schemaVersion|artifactVersion|ClaudeUsageRow\(|PiPackedUsage\(|"Sources")'
git diff -U0 $base origin/main -- Sources | grep -E '^\+.*(let|var) +\w*[Ee]nv\w* *: *\[String: *String\]' | grep -v '@ProcessEnvironment'
```

The rehearsal runs the same check as a warning (it never fails the run).

### Flaky tests and slow runners

Re-run these once before treating them as merge failures:

- `ProviderPluginOptionalPOSTTests` "caller cancellation…" (timing).
- `CLIHooksWatchSleepLinuxTests` "stops promptly…" (timing).
- `ProcessOwnershipReaperTests` "probe reaps detached grandchild…": flaky on runners, and always fails in a
  container without `/usr/bin/python3` (above).

macOS runners queue: with many open PRs, a macOS CI round took about 70 minutes during #95. Run everything above
locally first so a round isn't spent on something Linux could have caught, and push fixes in batches.

## 5. Smoke the merged CLI

From the container build (`.build/debug/CodexBarCLI`), with a scratch `HOME` and no real accounts:

- The upstream base is `version.env` (`MARKETING_VERSION`, `BUILD_NUMBER`), not `--version`: check that it reads
  the tag's values (`git diff $TAG -- version.env` prints nothing). `codexbar --version` reads an adjacent
  `VERSION` file that packaging writes, so a SwiftPM debug build prints just `CodexBar` and a packaged build
  prints the UsageBar version. Only check `--version` on a packaged build (step 9), where it must print the
  UsageBar release.
- `codexbar sync status` runs (not "Unknown command"); unpaired it reports so.
- `codexbar serve`: `/health` is ok, `/sync/status` returns `{"paired":false}`, `POST /sync/push` returns 409
  "Machine Sync is off", `GET /sync/push` returns 405, `/cost?provider=codex&days=7` answers with
  `historyDays: 7`.
- A copy of a real `config.json` gives `Config: OK`.

Don't run live provider fetches or anything that reads the Keychain (AGENTS.md).

## 6. Fork delta report

```sh
linux/upstream/fork-delta.sh --upstream $TAG
```

It must exit 0 ([FORK-DELTA.md](FORK-DELTA.md) explains the groups). If a conflict resolution made the fork edit an
upstream file that isn't on the allowlist, either move the change into a fork-owned file or add an allowlist entry
with the feature it serves, and call that out in the PR: growing the allowlist is a deliberate decision, not a merge
side effect. If upstream now does what a fork edit did and you dropped it (step 2.3), the report flags its allowlist
line as stale: delete the line. The PR's `UsageBar fork delta` check runs the same report against `upstream/main`.

## 7. Open the PR

Title: `Merge upstream CodexBar <tag>`. Body:

- **Summary**: from which upstream base to which tag, how many commits, why now.
- **Conflicts**: every conflicted file, grouped by fork feature, with how the fork change was re-applied (see
  #26's description for the level of detail).
- **Dropped**: fork changes removed because upstream replaced them.
- **Commands run**: steps 3 to 6, with counts (tests, suites, violations).
- **Not verified**, always including:
  - the macOS app build and tests (`swift build`, `make test` on a Mac), and any macOS-only file where
    upstream's side was taken;
  - `make check` / `lint-macos` (needs macOS tools such as `plutil` and SwiftFormat's macOS lint);
  - live provider fetches and Keychain paths (not run, per AGENTS.md);
  - anything else you couldn't run, by name.
- **Notes**: cache rebuilds users will see on first run (schema bumps), PRs this merge affects.
- `Closes`/`Part of` the tracking issue for this release, if any.

**Gate: fork CI green on the PR** (`gh pr checks <n> -R felipearosr/UsageBar`). Jobs the fork can't run are
skipped with a stated reason (#51), never failing. Don't merge red.

Merge with a **merge commit**, never squash or rebase: squashing drops upstream's history and the next merge
replays every upstream commit as a conflict.

## 8. Staleness rule

A merge branch is only good until the next upstream release.

- If a newer upstream tag lands before the PR merges, **re-merge** that tag into the same branch the same day
  (`git merge --no-ff <new tag>`, retitle the PR) or **restart**: close the PR with a link to its replacement,
  delete the branch, start step 1 from the new tag.
- Stopping mid-merge is fine only if the branch is pushed as a draft PR that lists the files still in conflict.
  A local-only half merge is never left behind: the v0.65 merge stalled on a local branch with 9 files in
  conflict and was found only when an install picked up the wrong code.
- Delete merge branches (local and remote) once the PR merges or closes.

## 9. After the merge: cut a UsageBar release

Every upstream merge is followed by a UsageBar release, so users get the new base.

```sh
git switch main && git pull
# USAGEBAR_VERSION in linux/release/usagebar-release.txt must already say <version> (a release-prep PR
# bumps it; the merge PR already set UPSTREAM_BASE). The workflow refuses a tag that doesn't match.
linux/release/resolve-version.sh usagebar-v<version>   # same check, locally
git tag usagebar-v<version> && git push origin usagebar-v<version>
```

The tag runs `.github/workflows/release-usagebar.yml`, which builds the CLI (x86_64, aarch64), packages the
`.deb`/`.rpm`, smoke-tests everything, runs the release asset verifier, and publishes the release
([`linux/README.md`](../README.md#releasing)). Do a dry run first, after the metadata bump lands:
`gh workflow run release-usagebar.yml -R felipearosr/UsageBar --ref main`. The full release checklist (`-rc`
first, clean-machine check, COPR/AUR afterwards) is [`linux/RELEASING.md`](../RELEASING.md).

## The merge rehearsal

`.github/workflows/usagebar-merge-rehearsal.yml` runs daily and on demand. It checks out fork `main`, merges
`upstream/main` (or a tag) into a scratch branch inside the runner, and runs steps 3 to 6, with the macOS-only
test drift check as a warning. Conflicts are resolved to upstream's side first, so failing checks point at fork
code that needs re-applying. It rewrites the body of one pinned issue (label `merge-rehearsal`) with the result.
It pushes nothing, opens no PRs, and doesn't touch `main`'s CI: a conflict or failing test shows up in the
issue, not as a red run.

```sh
gh workflow run usagebar-merge-rehearsal.yml -R felipearosr/UsageBar                       # upstream/main
gh workflow run usagebar-merge-rehearsal.yml -R felipearosr/UsageBar -f upstream_ref=v0.72.0
```

To rehearse locally in a throwaway branch (it commits the merge there; delete the branch afterwards):

```sh
git switch -c scratch/rehearsal origin/main
cp linux/upstream/merge-rehearsal.sh /tmp/mr.sh            # the merge can't change the copy you run
/tmp/mr.sh merge upstream/main /tmp/rehearsal
/tmp/mr.sh check /tmp/rehearsal "GNOME extension JS tests" -- sh -c 'node --test linux/usagebar-gnome/tests/*.test.mjs'
/tmp/mr.sh warn /tmp/rehearsal "macOS-only test drift" -- /tmp/mr.sh drift HEAD^1 HEAD^2
/tmp/mr.sh report /tmp/rehearsal
git switch - && git branch -D scratch/rehearsal
```

`linux/upstream/test-merge-rehearsal.sh` and `test-fork-delta.sh` test the scripts against throwaway repositories;
the workflow runs them first. The rehearsal's fork delta check passes `--allow-stale`: with conflicts resolved to
upstream's side, some fork hooks are gone on purpose, so only an unlisted upstream edit fails it.
