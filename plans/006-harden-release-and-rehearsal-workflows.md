# Plan 006: Make `publish` re-runnable, run the AUR bump as its own job, and isolate the merge rehearsal from the release toolchain and token

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**:
> `git diff --stat bcc721dfd..HEAD -- .github/workflows/release-usagebar.yml .github/workflows/usagebar-merge-rehearsal.yml linux/RELEASING.md linux/upstream/RUNBOOK.md`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition. Open PR #110 touches
> `release-usagebar.yml` (adds a logo-pack asset); rebase on it if merged.

## Status

- **Priority**: P1
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: security / dx
- **Planned at**: commit `bcc721dfd`, 2026-10-12

## Why this matters

Three problems in the fork's own workflows:

1. **Supply chain.** `usagebar-merge-rehearsal.yml` merges the *unreviewed*
   upstream tree on a schedule and runs its scripts and tests
   (`Scripts/install_lint_tools.sh`, `Scripts/lint.sh`, `swift build`,
   `swift test`). The same job restores AND saves the Swift toolchain cache
   under the exact key that `release-usagebar.yml` restores before building
   the published CLI (`swift-<os>-<arch>-<SWIFT_VERSION>-swiftly-<SWIFTLY_VERSION>`).
   Caches saved on `main` are readable by tag builds. A malicious upstream
   commit could therefore alter the toolchain that builds a release; swiftly
   only verifies what it downloads, not a toolchain already in the cache.
2. **Token exposure.** The rehearsal job holds `issues: write` for its whole
   run. Its "copy the script out first" protection does not hold: later
   steps run upstream code on the same runner, which can rewrite the copied
   script or shadow `gh` on `PATH` before the final step uses the token.
3. **Release re-runs.** `publish` calls a plain `gh release create` and then
   runs the AUR bump (network fetches plus a `docker.io/library/archlinux`
   pull). If the bump fails, the release is already public, the run is red,
   and re-running the job fails on `release create` because the release
   exists. `linux/RELEASING.md` says "A failed or cancelled run publishes
   nothing", which is then wrong.

After this plan the rehearsal never writes the toolchain cache and holds
the issue token only in a job that runs no upstream code; `publish` is
idempotent; the AUR bump is a separate job that cannot leave a release
half-done.

## Current state

- `.github/workflows/release-usagebar.yml` (442 lines). Jobs: `resolve`,
  the CLI build matrix (x86_64 / aarch64; cache at lines 109–113), the
  extension/tray/package jobs, `verify`, `publish` (lines 384–442).
  Cache step (lines 109–113):

```yaml
      - name: Restore Swift toolchain cache
        uses: actions/cache@55cc8345863c7cc4c66a329aec7e433d2d1c52a9 # v6.1.0
        with:
          path: ~/.local/share/swiftly
          key: swift-${{ runner.os }}-${{ runner.arch }}-${{ env.SWIFT_VERSION }}-swiftly-${{ env.SWIFTLY_VERSION }}
```

  Publish step (lines 403–418) and the AUR bump after it (420–442):

```yaml
      - name: Publish release
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
          TAG: ${{ needs.resolve.outputs.tag }}
          VERSION: ${{ needs.resolve.outputs.version }}
          PRERELEASE: ${{ needs.resolve.outputs.prerelease }}
        run: |
          set -euo pipefail
          flags=()
          if [[ "$PRERELEASE" == true ]]; then flags+=(--prerelease); fi
          gh release create "$TAG" packages/* \
            --repo "$GITHUB_REPOSITORY" \
            --verify-tag \
            --title "UsageBar $VERSION" \
            --notes-file notes/release-notes.md \
            "${flags[@]}"

      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        if: needs.resolve.outputs.distro_packages == 'true'
        with:
          path: src
          persist-credentials: false

      # The PKGBUILD and .SRCINFO for this release, for whoever pushes to the AUR.
      - name: Bump AUR PKGBUILD
        if: needs.resolve.outputs.distro_packages == 'true'
        env:
          VERSION: ${{ needs.resolve.outputs.version }}
          USAGEBAR_REPO: ${{ github.repository }}
        run: src/linux/packaging/aur/bump.sh "$VERSION"

      - uses: actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a # v7.0.1
        if: needs.resolve.outputs.distro_packages == 'true'
        with:
          name: aur-usagebar-cli-bin
          path: |
            src/linux/packaging/aur/PKGBUILD
            src/linux/packaging/aur/.SRCINFO
          include-hidden-files: true
          if-no-files-found: error
```

  `publish` has `permissions: contents: write`, `needs: [resolve, verify]`,
  and downloads artifacts matching `usagebar-*` into `packages/` (the
  `.sha256` files are among them) plus `release-notes` into `notes/`.

- `linux/packaging/aur/bump.sh` — `bump.sh <version> [--from DIR]`. With
  `--from DIR` it reads `usagebar-cli-<version>-linux-<arch>.tar.gz.sha256`
  and `LICENSE` from `DIR` instead of GitHub (lines 11–12, 25–41). It still
  needs `makepkg` or podman/docker for `.SRCINFO` (lines 49–58).

- `.github/workflows/usagebar-merge-rehearsal.yml` (231 lines). One job,
  `rehearse`, `permissions: contents: read, issues: write` (lines 42–44).
  It copies `linux/upstream/merge-rehearsal.sh` to `$MR` (in
  `$RUNNER_TEMP`), merges upstream into a scratch branch, runs checks
  through `"$MR" check "$OUT" "<name>" -- <cmd>` (upstream scripts at lines
  ~103–113, `swift build`/`swift test` at 171–198), restores/saves the Swift
  cache (lines 119–124, same key as above), and finally (lines 208–231)
  runs `"$MR" report "$OUT"` and `gh issue edit/create` with
  `GH_TOKEN: ${{ github.token }}` under
  `if: ${{ always() && steps.merge.outcome == 'success' }}`.
  `workflow_dispatch` exists with an `upstream_ref` input (validated by
  regex at lines ~63–70), so the owner can run it on demand.

- `.github/workflows/ci.yml` (upstream file; do NOT edit) also restores
  this key on pushes to `main`, which is how the cache normally gets
  populated by trusted code.

- Every `uses:` in the fork workflows is pinned by SHA; keep that. The
  `actions/cache/restore` sub-action lives in the same repository, so
  `actions/cache/restore@55cc8345863c7cc4c66a329aec7e433d2d1c52a9` is the
  pinned form.

- Docs: `linux/RELEASING.md` (131 lines; the "failed run publishes nothing"
  claim is around lines 124–131) and `linux/upstream/RUNBOOK.md` (describes
  the rehearsal issue, label `merge-rehearsal`, issue #106).

- Owner-only actions in this repo: Claude cannot run `gh workflow run`,
  merge PRs or close issues; the user runs those (give them the exact
  command). `gh` always needs `-R felipearosr/UsageBar`.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| YAML parses | `npx --yes js-yaml@4.1.0 .github/workflows/release-usagebar.yml > /dev/null && npx --yes js-yaml@4.1.0 .github/workflows/usagebar-merge-rehearsal.yml > /dev/null` | exit 0 |
| Workflow lint (if installed) | `actionlint .github/workflows/release-usagebar.yml .github/workflows/usagebar-merge-rehearsal.yml` | no findings (not installed on the dev box; `brew install actionlint` is available but is an install — ask before installing) |
| Bash blocks | extract each changed `run:` block to a file and `bash -n` it | exit 0 |
| Release-script tests | `linux/release/tests/resolve-version.test.sh && linux/release/tests/verify-assets.test.sh` | pass (unchanged, sanity) |
| Rehearsal self-test | `linux/upstream/test-merge-rehearsal.sh` | `merge-rehearsal tests passed` |
| Fork delta | `git fetch upstream main && linux/upstream/fork-delta.sh` | ends with `OK:` |
| Owner dry run (after merge) | `gh workflow run usagebar-merge-rehearsal.yml -R felipearosr/UsageBar --ref main -f upstream_ref=v0.73.0` | run green; issue #106 updated by the new `report` job |

## Scope

**In scope**:
- `.github/workflows/release-usagebar.yml` (`publish` job; new `aur` job)
- `.github/workflows/usagebar-merge-rehearsal.yml` (cache step; job split)
- `linux/RELEASING.md` (re-run semantics; AUR job)
- `linux/upstream/RUNBOOK.md` (one note about the `report` job)

**Out of scope** (do NOT touch):
- `.github/workflows/ci.yml`, `release-cli.yml`, `upstream-monitor.yml` —
  upstream files.
- `linux/packaging/aur/bump.sh`, `PKGBUILD`, `.SRCINFO`.
- `linux/upstream/merge-rehearsal.sh` and its tests (the script's `report`
  subcommand is used as-is from a fresh checkout).
- Adding provenance attestations or signatures (separate plan; see
  `plans/README.md`).
- The rehearsal report's 65 536-character issue-body limit (noted in
  Maintenance).

## Git workflow

- Branch: `felipearosr/release-workflow-hardening` from `main`.
- One commit per step; style: short imperative, e.g.
  `Keep the merge rehearsal from writing the Swift toolchain cache`.
- Do NOT push or open a PR unless the operator instructed it. PRs target
  `main`; `gh` with `-R felipearosr/UsageBar`.

## Steps

### Step 1: The rehearsal only restores the toolchain cache

In `usagebar-merge-rehearsal.yml`, change the cache step (lines ~119–124)
from `actions/cache@55cc83…` to
`actions/cache/restore@55cc8345863c7cc4c66a329aec7e433d2d1c52a9 # v6.1.0`
with the same `path`/`key`. Add a comment: the rehearsal runs unreviewed
upstream code, so it must never write a cache that `release-usagebar.yml`
reads; `ci.yml` on `main` populates it.

**Verify**: `grep -n 'actions/cache' .github/workflows/usagebar-merge-rehearsal.yml`
→ exactly one line, containing `actions/cache/restore@`.

### Step 2: Split the issue update into its own job

In `usagebar-merge-rehearsal.yml`:

1. `rehearse` job: `permissions: contents: read` only. Remove the "Update
   the tracking issue" step. Add, as the last step
   (`if: ${{ always() && steps.merge.outcome == 'success' }}`), an
   `actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a # v7.0.1`
   upload of the `$OUT` directory as `rehearsal-out`
   (`include-hidden-files: true`, `if-no-files-found: error`). Expose the
   merge outcome as a job output: under `jobs.rehearse.outputs:`
   `merged: ${{ steps.merge.outcome }}`.
2. New job `report`: `needs: rehearse`,
   `if: ${{ always() && needs.rehearse.outputs.merged == 'success' }}`,
   `permissions: issues: write`, `runs-on: ubuntu-24.04`, `timeout-minutes: 10`.
   Steps: checkout (pinned SHA, `persist-credentials: false`) of
   `${{ github.sha }}` (the fork's own `main`, never the merged scratch
   tree); download `rehearsal-out` into `$RUNNER_TEMP/out`; run
   `linux/upstream/merge-rehearsal.sh report "$RUNNER_TEMP/out" > "$RUNNER_TEMP/report.md"`;
   then the existing `cat … >> $GITHUB_STEP_SUMMARY` and the
   `gh issue list/edit/create` block moved verbatim, with
   `GH_TOKEN: ${{ github.token }}`.
3. Keep the `workflow_dispatch` input validation where it is.

The `report` subcommand must work from a checkout that has not merged
anything (it only reads `$OUT`); confirm by reading
`linux/upstream/merge-rehearsal.sh` — the `report` case consumes files
under `$OUT` and nothing from the tree. If it needs tree state, STOP.

**Verify**: YAML parses; `grep -n 'issues: write' .github/workflows/usagebar-merge-rehearsal.yml`
→ one match, inside the `report` job; `grep -n 'gh issue' …` → only in
`report`; `linux/upstream/test-merge-rehearsal.sh` → passes (unchanged
script, sanity).

### Step 3: Idempotent `publish`

Replace the `gh release create` block with:

```bash
          set -euo pipefail
          flags=()
          if [[ "$PRERELEASE" == true ]]; then flags+=(--prerelease); fi
          if gh release view "$TAG" --repo "$GITHUB_REPOSITORY" > /dev/null 2>&1; then
            echo "::notice::release $TAG exists; re-uploading assets"
            gh release upload "$TAG" packages/* --repo "$GITHUB_REPOSITORY" --clobber
          else
            gh release create "$TAG" packages/* \
              --repo "$GITHUB_REPOSITORY" \
              --verify-tag \
              --title "UsageBar $VERSION" \
              --notes-file notes/release-notes.md \
              "${flags[@]}"
          fi
```

Add a comment that a re-run after a partial upload replaces assets in place
and never changes the title, notes or pre-release flag of an existing
release.

**Verify**: extract the block to a temp file and `bash -n` it → exit 0.

### Step 4: Move the AUR bump into its own job

Remove the checkout + "Bump AUR PKGBUILD" + upload steps from `publish`.
Add a job:

```yaml
  aur:
    needs: [resolve, verify]
    if: ${{ !cancelled() && needs.verify.result == 'success' && needs.resolve.outputs.distro_packages == 'true' && github.event_name == 'push' && startsWith(github.ref, 'refs/tags/usagebar-v') }}
    runs-on: ubuntu-24.04
    timeout-minutes: 15
    permissions:
      contents: read
```

Steps: pinned checkout (`persist-credentials: false`); download the
`usagebar-*` artifacts into `packages/` (merge-multiple, as `publish`
does); run `linux/packaging/aur/bump.sh "$VERSION" --from packages`
with `VERSION: ${{ needs.resolve.outputs.version }}` (the `--from` mode
reads the `.sha256` files there and `LICENSE` from the checkout — check
`bump.sh:37-41`: it reads `"$from/LICENSE"`, so copy the checkout's
`LICENSE` into `packages/` first); upload `PKGBUILD` and `.SRCINFO` as
`aur-usagebar-cli-bin` exactly as before. `publish` must NOT depend on
`aur`, and `aur` must NOT depend on `publish`.

**Verify**: YAML parses; `grep -n 'bump.sh' .github/workflows/release-usagebar.yml`
→ one match inside the `aur` job; `grep -n 'needs:' …` shows `publish`
still `needs: [resolve, verify]`.

### Step 5: Docs

- `linux/RELEASING.md`: replace the "A failed or cancelled run publishes
  nothing" paragraph with: `publish` runs only after `verify`; a re-run of a
  failed `publish` re-uploads assets to the existing release; the AUR
  PKGBUILD artifact comes from the separate `aur` job, which can be re-run
  alone and never blocks or un-publishes a release.
- `linux/upstream/RUNBOOK.md`: where the rehearsal issue is described, add
  one sentence that the issue is updated by the `report` job, which runs
  on the fork's `main` checkout with the only write token in the workflow.

**Verify**: `grep -n 'publishes nothing' linux/RELEASING.md` → no match;
`grep -c 'report' linux/upstream/RUNBOOK.md` → increased by at least 1.

### Step 6: Whole-tree checks and hand-off

**Verify**: both YAML files parse; `linux/upstream/fork-delta.sh` → `OK:`;
`git status --porcelain` → only the four in-scope files. Then report the
owner command for the live check after merge:
`gh workflow run usagebar-merge-rehearsal.yml -R felipearosr/UsageBar --ref main -f upstream_ref=v0.73.0`
and state that the `publish`/`aur` changes are exercised by the next
`usagebar-v*` tag (a release candidate is enough).

## Test plan

- No unit tests exist for workflow YAML; the gates are: YAML parse,
  `bash -n` on changed `run:` blocks, the unchanged script self-tests, and
  the owner-run `workflow_dispatch` of the rehearsal after merge (the
  `report` job must update issue #106).
- The `publish` idempotency path is verified on the next tag push; record
  the run URL in the PR description when it exists.

## Done criteria

- [ ] `grep -c 'actions/cache@' .github/workflows/usagebar-merge-rehearsal.yml` → `0`; `grep -c 'actions/cache/restore@' …` → `1`
- [ ] `issues: write` appears once, in the `report` job; `rehearse` has only `contents: read`
- [ ] `release-usagebar.yml` has an `aur` job and `publish` contains `gh release view`
- [ ] Both workflow files parse with `npx --yes js-yaml@4.1.0 <file>`
- [ ] `linux/upstream/test-merge-rehearsal.sh` and `linux/release/tests/*.test.sh` still pass
- [ ] `linux/RELEASING.md` no longer says a failed run publishes nothing
- [ ] `linux/upstream/fork-delta.sh` ends with `OK:`
- [ ] `git status --porcelain` lists only in-scope files
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- The workflow excerpts no longer match (PR #110 adds a logo-pack asset to
  `release-usagebar.yml`; rebase first, then re-check the `publish` block).
- `merge-rehearsal.sh report` needs the merged tree (not just `$OUT`).
- `bump.sh --from` cannot run on the runner without podman/docker — it
  uses docker when `makepkg` is absent; if the runner image lacks both,
  report rather than adding a package install step.
- You are asked to run `gh workflow run` — only the owner can; hand them
  the command.

## Maintenance notes

- Any new job that runs upstream code must use `actions/cache/restore`,
  never `actions/cache`, and must not hold a write token.
- The rehearsal report can exceed GitHub's 65 536-character issue-body
  limit on a bad merge (40 log lines per failing check); capping it in
  `merge-rehearsal.sh report` is a small follow-up.
- Provenance attestations for release assets (`actions/attest-build-provenance`,
  `id-token: write` + `attestations: write` on `publish`) and
  `--proto '=https'` in the installer are the next supply-chain steps; they
  were deliberately left out of this plan to keep it small.
- Reviewer focus: the `if:` on the new `aur` and `report` jobs, and that
  `report` checks out `github.sha` (the fork's `main`), not the scratch
  merge.
