# UsageBar (Linux port) agent notes

Fork-owned agent instructions for work under `linux/`. The root `AGENTS.md` is upstream's (steipete/CodexBar) and still
applies; keep it identical to upstream and put fork notes here. Commands below run from the repository root.

## GNOME extension (`linux/usagebar-gnome`)
- After **any** change, always open the dev kit via `./linux/run-dev.sh` (backgrounded;
  `setsid ./linux/run-dev.sh > /tmp/codexbar-devkit.log 2>&1 < /dev/null &`), then confirm the extension is enabled and
  there are no extension JS errors in its log.
- After every change, close the running dev kit and reopen it (do not just reload the extension):
  `pkill -f 'gnome-shell --dev[k]it'`, then `setsid ./linux/run-dev.sh > /tmp/codexbar-devkit.log 2>&1 < /dev/null &`,
  then confirm the extension is enabled and there are no extension JS errors in its log.
- Never use `pkill -f 'gnome-shell --devkit'` verbatim — the pattern matches and kills the invoking shell; use the
  bracketed form.

## Fork plumbing (keep upstream files untouched)
- Changelog: fork entries go in `linux/CHANGELOG.md`, not the root `CHANGELOG.md`.
- Make targets: add fork targets to `linux/fork.mk` (the root `Makefile` includes it with one hook line), e.g.
  `make test-linux-ui`.
- Lint: add fork checks to `linux/lint-fork.sh` (`Scripts/lint.sh` calls it with one hook line).
- Ignores: fork build outputs go in `linux/.gitignore`; `.scratch/` ignores itself.
- Any edit to an upstream file must be listed in `linux/upstream/hook-allowlist.tsv`; run
  `./linux/upstream/fork-delta.sh` (see `linux/upstream/FORK-DELTA.md`).
