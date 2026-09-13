# Plan 001: Reuse the GNOME popup and combine background updates

## Status

- Priority: P1; effort: M; risk: medium; dependencies: none.
- Planned at: `be70cfc0`, 2026-09-12.
- Implementation: Luna max (Luna ultra is unavailable); discovery: Luna medium; review: Astra high.

## Why this matters

The user wants opening the Linux popup to feel immediate. The GNOME extension already fetches asynchronously and warms cost reports, but every render destroys panel chips and popup contents, including on repeated opens and individual background results. Reuse the existing overview, update only changed sections, and avoid repeated cost aggregation and icon filesystem queries.

## Current state and conventions

All paths below are relative to the repository root. `linux/usagebar-gnome/usagebar@felipearosr.github.io/extension.js` contains the UI and asynchronous data callbacks. Its opening callback resets `_selectedProvider` to null, starts best-effort fetches, then calls `_render()`. `_render()` calls `_setPanelText()`, `_publishWindowCatalog()`, and `detail.destroy_all_children()` before building the selected detail or All view. `_setPanelText()` also calls `destroy_all_children()`. `_mergeCosts()` and each status callback call `_render()` individually. `costOverview()` aggregates daily/model data on each All-view render. Icon builders synchronously call `query_exists(null)` repeatedly.

Match existing GJS ES modules, four-space indentation, camelCase methods with underscore private names, St/Clutter actors, and explicit cleanup in `disable()`/actor destruction. Preserve provider/account silos, last-good error data, order/hide settings, countdowns, reset-to-All on opening, keyboard navigation, tooltip/modal cleanup, and refresh behavior. No new dependencies. The serial Swift cost executor is intentional and outside scope.

## Scope and workflow

Allowed source changes: the extension directory's `extension.js`, a small pure performance/state helper module if useful, and focused tests under `linux/usagebar-gnome/tests/`. A fixture-only CLI helper under that tests directory may support nested-shell validation. Documentation changes may update `linux/usagebar-gnome/README.md` for test commands. Do not change styles, prefs, Swift, Tauri, schemas, real account config, or unrelated files.

Implement in isolated worktree `/tmp/codexbar-popup-perf`. Do not commit, push, or post GitHub messages. The user authorized implementation in the current workspace: after review, the executor copies only approved changed files into `/home/faros/Projects/Personal/CodexBar`. The coordinator maintains this plan's status; do not edit the index.

Drift gate: `git diff --stat be70cfc0..HEAD -- linux/usagebar-gnome` must be empty before implementation.

## Implementation steps

1. Add a small render scheduler with at most one pending idle source for data-driven changes. Keep interactive navigation immediate. Cancel pending sources on disable and prevent old callbacks from updating a re-enabled extension. Separate panel updates from popup updates. Hidden popup data changes should mark dirty without constructing hidden detail/chart actors; prepare the overview off the click path when practical. Avoid scheduling a fresh full build on every open.
2. Retain/reuse the All-view container across provider-detail navigation and reopening. Cache overview rows by provider and reconcile additions/removals/order. Update existing labels, bars, styles, and ring state when possible; rebuild a row only for structural changes. Keep header and action callbacks current, especially reorder boundaries, hidden windows, changed provider payloads, and cost-panel summary callbacks. Do not retain unbounded view caches. Reuse panel actors when their structure matches, with mutable repaint state. Countdown tick should update time-dependent UI without destroying the entire overview. Detail/chart reuse may use conservative section invalidation where a full incremental rewrite would be disproportionate.
3. Cache `costOverview()` by report revision/reference and local calendar date, and invalidate on relevant metadata/display-name changes where required. Reuse summary/dashboard when unaffected by usage/status updates. Cache positive and negative icon lookups/Gio.FileIcon objects per enable lifetime; do not share a parented St.Icon actor. Move window-catalog publication to actual usage/settings changes instead of every visual refresh where possible.
4. Add meaningful regression coverage for scheduler burst coalescing and cancellation, no builds on unchanged warm reopen, actor reuse across value/countdown changes, additions/removals/reordering, settings invalidation, cost/date invalidation, and negative icon caching. Prefer pure state seams or controlled St stubs; also execute the actual extension in nested GNOME using fixtures. Avoid tests merely checking implementation text.

## Verification

- Run new tests with Node's built-in test runner: `node --test linux/usagebar-gnome/tests/*.test.mjs` (test suffix may be adjusted and documented). No dependency installation.
- Syntax-check ES modules using `node --input-type=module --check < path/to/file.js`.
- Run `git diff --check`; expect exit 0 and only allowed file changes.
- Run `make test` and `make check`, as required by AGENTS.md. Swift is currently absent, so report environmental failures explicitly; do not install tooling without authorization or confuse those failures with passing checks.
- After integration launch `./linux/run-dev.sh` backgrounded, with `CODEXBAR_BIN` pointing to a fixture-only executable and isolated XDG_CONFIG_HOME/XDG_DATA_HOME/XDG_CACHE_HOME in /tmp. Check the nested shell log for extension JS errors. User instruction requires this dev-kit check. Do not invoke live provider probes, browser-cookie imports, account data, or Keychain operations. Use controlled fixture data rather than private usage captures in output.
- Measure warm-open render work/build counts before and after using identical controlled fixture data. Report measured JS processing separately from click-to-first-frame latency; do not claim a sub-100ms visible latency unless actually measured.

## Done criteria and review

New focused tests pass, module syntax and diff checks pass, unchanged warm opens reuse the overview and panel actors, burst updates coalesce, close/reopen and disable/re-enable remain correct, cost and icon caches invalidate correctly, and Astra high has reviewed the full diff. Fix substantive review findings and rerun affected tests. Runtime verification must show no extension JS errors; if the environment prevents interaction, report the precise limitation instead of claiming visual proof.

Stop and report if correct reuse requires broad UI redesign, source/account behavior changes, or new dependencies. Routine adaptations and test harness changes within scope are allowed if documented. Preserve user edits during integration. Future new UI fields must participate in the appropriate state/invalidation key; reviews should check callback freshness and actor/source cleanup.

## Implementation and review results

Implemented in the isolated checkout and copied into the workspace after Astra high review. No commit or push. Four source/test/documentation files changed: extension.js, renderstate.js, tests/renderstate.test.mjs, and the GNOME README.

The All view and panel chips retain actors, update values in place, and skip unchanged parenting operations. Background updates share one cancellable idle callback. Cost summaries and positive/negative icon lookups are cached. Selected-detail invalidation is conservative; changed detail data or the countdown time bucket can still rebuild that card. Hidden popup content is prepared on first opening, so the measured result below describes repeated opening rather than a guaranteed first-frame latency.

Astra identified and Luna fixed boundary reorder callbacks, detached-actor teardown, unrelated-provider detail invalidation, and null extra-window compatibility. The final source matches the package used by the GNOME fixture runner byte for byte.

Validation:

- Five pure Node helper tests passed; these cover scheduling, cache behavior and keyed state, not actual GJS actors.
- Changed ES modules pass syntax checks; `git diff --check` passes.
- Real GNOME 50.4 fixture automation: ten opens build 2 provider rows instead of 20; actor identities persist. Mean synchronous open call: 5.38 ms versus 11.97 ms baseline with two fictional providers. These timings include the first measured open and do not measure physical click-to-first-frame latency.
- Actual actor tests passed for reorder/move-back controls, in-place percentage updates, selected-detail invalidation, cost-panel navigation, cached actor destruction and pending-render cancellation. No extension JS errors in that run.
- Required `./linux/run-dev.sh` was launched backgrounded with the integrated repo-symlinked extension, temporary XDG settings and a fictional CLI; fixture usage and costs loaded with no extension JS errors in the initial log.
- `make test` cannot run because `swift` is absent; `make check` stops at absent `plutil`. No tooling was installed.

Disposable reproduction harness and evidence: `/tmp/codexbar-popup-qa/automation/popup-qa.js`, `baseline-result.json`, `final-pre-reenable-result.json`, `final-result.json`, and corresponding shell logs/screenshots under `/tmp/codexbar-popup-qa`. The final disable/re-enable run passed with fresh actor identities, both fixture providers, no pending-render leak, and no extension JS errors. An earlier harness run timed out during re-enable; no source change was needed for the passing final run. Concurrent dev-kit runs can emit GNOME's own shared-runtime marker warnings (extensionSystem.js), distinct from UsageBar errors.

Final runtime reproduction (fixture-only, requires an available GNOME Shell and loopback/session-bus access):

```sh
dbus-run-session -- env \
  CODEXBAR_QA_REQUIRE_REUSE=1 \
  CODEXBAR_BIN=/tmp/codexbar-popup-qa/bin/codexbar \
  CODEXBAR_FIXTURE_CONTROL=/tmp/codexbar-popup-qa/control.json \
  CODEXBAR_FIXTURE_LOG=/tmp/codexbar-popup-qa/logs/requests.jsonl \
  gnome-shell-test-tool --headless --disable-animations \
  --extension /tmp/codexbar-popup-qa/optimized-final.shell-extension.zip \
  /tmp/codexbar-popup-qa/automation/popup-qa.js
```

Final package SHA-256: `6d9c4d4390faea660df0972b042a81695ae88146a0d3affd51e155d7f2349019`.
