# UsageBar — GNOME Shell extension

A native GNOME panel frontend for AI coding-provider usage limits, ported from
[CodexBar](https://github.com/steipete/CodexBar): per-provider chips in the top
bar, and an anchored popover with a tab strip (All + per provider) — rate-window
progress bars (including per-model limits like "Fable only"), reset countdowns,
pace, a cost dashboard (KPI grid, daily trend chart, top models), quota
notifications, and a libadwaita Settings window. This is the primary
Linux/GNOME surface; the Tauri app in `../codexbar-tray/` is the fallback for
non-GNOME desktops (KDE, XFCE, …).

After installing an update from the UsageBar menu, log out and back in to let
GNOME finish loading the update. UsageBar keeps this instruction in its status
banner until the session ends.

Self-contained: it supervises its own `codexbar serve` child on a free
loopback port (restart with backoff, killed on disable) and polls
`GET /usage` / `GET /cost`. Requires the `codexbar` CLI ≥ 0.43.0 — install
from [upstream's releases](https://github.com/steipete/CodexBar/releases)
(NOT brew; the Linux formula lags and drops per-model limit data), or set
`$CODEXBAR_BIN`.

## Install (development)

```bash
ln -sfn "$PWD/usagebar@felipearosr.github.io" \
  ~/.local/share/gnome-shell/extensions/usagebar@felipearosr.github.io
glib-compile-schemas usagebar@felipearosr.github.io/schemas/
gnome-extensions enable usagebar@felipearosr.github.io
```

GNOME only scans for new extensions at login — log out and back in the first
time. Subsequent code edits also need a fresh shell: verify headless/nested
instead of logging out each time — see `../BOOTSTRAP.md` steps 6–7 for the
exact commands (isolated `DCONF_PROFILE`, `gnome-shell --headless` /
`--devkit`) and `../codexbar-tray/NEXT_PHASE.md` for the gotcha list.
Never point `gsettings set org.gnome.shell enabled-extensions` at your real
dconf from a test session — it clobbers your extension list and wedges
dconf-service.

Health check from a running session:
`gnome-extensions info usagebar@felipearosr.github.io` and
`journalctl --user -b -g 'usagebar|codexbar'` (no `JS ERROR` lines, state
ACTIVE, one `codexbar serve` child).

## Tests

Run the dependency-free render-state regression tests and syntax checks with:

```bash
node --test linux/usagebar-gnome/tests/*.test.mjs
node --input-type=module --check < linux/usagebar-gnome/usagebar@felipearosr.github.io/extension.js
node --input-type=module --check < linux/usagebar-gnome/usagebar@felipearosr.github.io/renderstate.js
```

The pure state tests cover idle-render coalescing and cancellation, bounded
cost-cache invalidation (including empty results), keyed provider-row reuse and
order changes, positive/negative icon lookup caching, and persistent update
completion guidance. Nested GNOME fixture automation separately exercises the
live extension’s warm opens, navigation, value updates, and cleanup.

## Files

- `usagebar@felipearosr.github.io/extension.js` — everything: serve
  supervisor (Gio.Subprocess), Soup 3 HTTP client, stale-merge (port of the
  Rust `merge_stale`), panel indicator + popover UI (St widgets), quota
  notifications.
- `usagebar@felipearosr.github.io/prefs.js` — libadwaita preferences
  (thresholds, notifications, per-provider chip visibility).
- `usagebar@felipearosr.github.io/schemas/` — GSettings schema
  (`org.gnome.shell.extensions.usagebar`); re-run `glib-compile-schemas`
  after editing.
- `usagebar@felipearosr.github.io/stylesheet.css` — chips, tabs, cards,
  bars, chart, tooltip.
- Payload shapes: see `../codexbar-tray/fixtures/` (real `/usage` and `/cost`
  captures) and `Sources/CodexBarCLI/CLIPayloads.swift` / `CLICostCommand.swift`.
  Gotchas: dollar amounts arrive under `totalCost` (daily/totals) but `cost`
  (model breakdowns); per-model bars only exist with claude source `oauth`.
