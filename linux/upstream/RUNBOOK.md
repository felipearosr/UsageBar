# Upstream merge runbook

How UsageBar takes each steipete/CodexBar release. Written from the 0.43.1 → 0.68.0 merge (#26) and the
first rehearsal against 0.72.0. If a step here turns out wrong during a merge, fix this file in the same PR.

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
| Cost scanners | `Sources/CodexBarCore/Vendored/CostUsage/`: `CostUsageScanner.swift`, `+Claude.swift`, `+CacheHelpers.swift`, `+TemporalBuckets.swift`, `CostUsageStore+ReadView.swift`; `Sources/CodexBarCore/PiSessionCostScanner.swift` | Machine Sync: Spend Buckets | Codex: optional `CodexSpendBucketCollector` on `buildCodexReportFromCache`, per-row cost factored into `codexRowCost`. Claude: `ClaudeUsageRow.omittedFields` captured at parse time, per-row cost in `claudeRowCost`. Pi: per-file `hourContributions` and `hourKey` on keyed entries. **The only conflict in the 0.72.0 rehearsal is here**: upstream reworked the Claude row builder (`cacheCreate1h`); the fork's `omittedFields` and `tokens` struct have to be re-applied, and `ClaudeSpendBucketLinuxTests` "fields the log omits stay absent" fails until they are. |
| Cache schema versions | `Vendored/CostUsage/CostUsageClaudeCache.swift` (`schemaVersion`), `PiSessionCostCache.swift` (`pi-sessions-vN.json`) | Spend Buckets | The fork bumped Claude 4 → 5 and Pi v9 → v10 to carry hour data. **If upstream bumps either, the fork's number must end above both**, or upstream's new version silently equals the fork's old one and users keep a stale cache. Today: upstream Claude is 4, fork 5. |
| CLI entry and help | `Sources/CodexBarCLI/CLIEntry.swift`, `CLIHelp.swift`, `Tests/CodexBarTests/CLIEntryTests.swift` | Machine Sync: `codexbar sync` | Register `sync` next to upstream's commands; help text in `CLIHelp`. |
| CLI errors | `Sources/CodexBarCLI/CLIErrorReporting.swift`, `CLIIO.swift` | Machine Sync: error `reason` | Carry `reason` and `exit(reason:)` into upstream's error reporting. |
| `serve` | `Sources/CodexBarCLI/CLIServeCommand.swift`, `CLILocalHTTPServer.swift` (409, 502 status cases), `Tests/CodexBarTests/CLIServeRouterTests.swift` | Machine Sync: `/sync/status`, `/sync/push`; `/cost?days=N` | `/sync/*` through upstream's data-route auth, `Cache-Control: no-store`; `ServeRuntime` takes `sync` with a default; `/cost?days=N` maps to `CostReportingPeriod.rolling(days:)`. |
| OpenCode | `Sources/CodexBarCore/Providers/OpenCode/OpenCodeProviderDescriptor.swift` | OpenCode on Linux | Browser-support exemption lives in the descriptor, like OpenCode Go. |
| macOS menu | `StatusItemController+MenuCardItems.swift`, `+MenuTypes.swift`, `+Menu.swift` | none (macOS UI) | Upstream's side taken, fork change dropped. |
| Plumbing | `CHANGELOG.md`, `AGENTS.md`, `Makefile`, `Scripts/lint.sh`, `.gitignore`, `docs/cli.md`, `docs/opencode.md` | repo plumbing | Insert the fork's lines into upstream's text; never reorder upstream's. |

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

```sh
# Format only the Swift files that differ from upstream, so upstream code isn't reformatted.
git diff --name-only $TAG -- '*.swift' | xargs podman run --rm -v "$PWD:/src:Z" -w /src \
  ghcr.io/nicklockwood/swiftformat:latest
podman run --rm -v "$PWD:/src:Z" -w /src ghcr.io/realm/swiftlint:latest swiftlint lint --strict
./Scripts/lint.sh lint-linux                     # what CI's lint job runs (installs its tools into .build)

# Linux test target and the fork suites. Run the fork suites first: they say whether a fork feature broke.
podman run --rm -v "$PWD:/src:Z" -w /src localhost/codexbar-swift:6.3.3 bash -c '
  swift build --build-tests &&
  . Scripts/test_environment.sh &&
  swift test --skip-build --filter "MachineSync|CLIServeSync|CLISync|SpendBucket|OpenCode" &&
  swift test --skip-build --parallel'

# GNOME extension
node --test linux/usagebar-gnome/tests/*.test.mjs
```

The fork suites: Machine Sync create, pair, push, status, management, timer and protocol vectors;
`CLIServeSync`; `CLISync*`; Spend Buckets for Codex, Claude and Pi (and their merging); OpenCode on Linux.
All must pass. #26 had 1,008 tests in 136 suites passing.

## 5. Smoke the merged CLI

From the container build (`.build/debug/CodexBarCLI`), with a scratch `HOME` and no real accounts:

- `codexbar --version` reports the new upstream base.
- `codexbar sync status` runs (not "Unknown command"); unpaired it reports so.
- `codexbar serve`: `/health` is ok, `/sync/status` returns `{"paired":false}`, `POST /sync/push` returns 409
  "Machine Sync is off", `GET /sync/push` returns 405, `/cost?provider=codex&days=7` answers with
  `historyDays: 7`.
- A copy of a real `config.json` gives `Config: OK`.

Don't run live provider fetches or anything that reads the Keychain (AGENTS.md).

## 6. Fork delta report

```sh
linux/upstream/fork-delta.sh                     # lands with #52
```

It must exit 0. If a conflict resolution made the fork edit an upstream file that isn't on the allowlist, either
move the change into a fork-owned file or add an allowlist entry with the feature it serves, and call that out in
the PR: growing the allowlist is a deliberate decision, not a merge side effect.

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
# Record the new upstream base and bump the UsageBar version in the release metadata (#41, #36).
git tag usagebar-v<version> && git push origin usagebar-v<version>
```

The tag runs `.github/workflows/release-usagebar.yml`, which builds the CLI (x86_64, aarch64), packages the
`.deb`/`.rpm`, checks that `codexbar sync` is present, and publishes the release. Do a dry run first with
`gh workflow run release-usagebar.yml -R felipearosr/UsageBar --ref main -f version=<version>`. The release
checklist lives with the release workflow (#48).

## The merge rehearsal

`.github/workflows/usagebar-merge-rehearsal.yml` runs daily and on demand. It checks out fork `main`, merges
`upstream/main` (or a tag) into a scratch branch inside the runner, and runs steps 3 to 6. Conflicts are resolved
to upstream's side first, so failing checks point at fork code that needs re-applying. It rewrites the body of
one pinned issue (label `merge-rehearsal`) with the result. It pushes nothing, opens no PRs, and doesn't touch
`main`'s CI: a conflict or failing test shows up in the issue, not as a red run.

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
/tmp/mr.sh report /tmp/rehearsal
git switch - && git branch -D scratch/rehearsal
```

`linux/upstream/test-merge-rehearsal.sh` tests the script against a throwaway repository; the workflow runs it
first.
