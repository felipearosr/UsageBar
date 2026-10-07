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
`GET /usage` / `GET /cost`. The .deb/.rpm (see `../README.md`) ship the
fork's `codexbar` CLI at `/usr/libexec/usagebar/codexbar`, which the
extension prefers; otherwise it uses `$CODEXBAR_BIN` or the first `codexbar`
on `PATH`. Machine Sync needs the fork's CLI; everything else works with
upstream's ≥ 0.43.0 (NOT brew; the Linux formula lags and drops per-model
limit data).

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

## Machine Sync

Once this Machine is paired (`codexbar sync create` / `codexbar sync pair`),
the refresh loop asks the `codexbar serve` child to push (`POST /sync/push`,
about every 150 s ± 20 s) and a Providers | Machines tab strip appears. The
Machines tab lists every Machine with an active dot, today and 30-day Spend,
its share, the top provider/model split, and Coverage. It reads the Sync
Server (`GET /sync/status?refresh=1`) on the push cadence while the tab is
open, and otherwise only once its data is older than 5 minutes. When a read
fails or serve stops answering, the last good data stays on screen, greyed,
under a banner. Unpaired Machines never see the tab strip.

Settings → **Machine Sync** sets it up without a terminal. Unpaired, it offers
two paths: create a Sync Group (type the server URL; the page asks the server's
`GET /v1/info` and shows the Enrollment Token field only when the server says
the token is optional or required; no server is named or suggested) or join
one by pasting a Pairing Link. Paired, it shows the Sync Server, shows or
copies the Pairing Link with recovery-key guidance, renames this Machine, sets
the Reporting Day (timezone and start hour), lists the other Machines with
Retire and Forget, runs a push on demand, and leaves the group. Every action
runs a `codexbar sync …` command with `--json-only`; failures carry a `reason`
(`machine_limit`, `enrollment_expired`, …) that `syncprefs.js` turns into
plain language. The Pairing Link reaches `codexbar sync pair -` on stdin, never
in argv, and the page doesn't log.

The pure state tests cover idle-render coalescing and cancellation, bounded
cost-cache invalidation (including empty results), keyed provider-row reuse and
order changes, positive/negative icon lookup caching, and persistent update
completion guidance.

Run the rendered dashboard smoke test on a Linux host with GNOME Shell using:

```bash
make test-linux-ui
```

It starts an isolated headless GNOME session, injects deterministic cost data,
opens the real dashboard, verifies that its range/metric/breakdown controls are
painted on-screen, exercises each control family, checks the four-provider cap,
and fails on extension JavaScript errors. Every run prints paths to its JSON
result, GNOME log, and full-stage PNG screenshot under `/tmp`.

## Provider logos

Provider logos live in `usagebar@felipearosr.github.io/icons/` for development
checkouts only. The build submitted to extensions.gnome.org leaves them out
(third-party trademarks); a provider without a logo file is drawn as a
two-letter monogram on a badge in its brand color (`monogram.js`). Set
`USAGEBAR_HIDE_PROVIDER_ICONS=1` to see that build's look with the logos in
place, e.g. `USAGEBAR_HIDE_PROVIDER_ICONS=1 ./linux/run-dev.sh`. The UI smoke
test runs once with logos and once with them hidden.

## Files

- `usagebar@felipearosr.github.io/extension.js` — everything: serve
  supervisor (Gio.Subprocess), Soup 3 HTTP client, stale-merge (port of the
  Rust `merge_stale`), panel indicator + popover UI (St widgets), quota
  notifications.
- `usagebar@felipearosr.github.io/machinesync.js` — Machine Sync push/read
  cadence and the Machines tab view model (pure; tested in
  `tests/machinesync.test.mjs`).
- `usagebar@felipearosr.github.io/prefs.js` — libadwaita preferences
  (thresholds, notifications, per-provider chip visibility).
- `usagebar@felipearosr.github.io/syncpage.js` — the Machine Sync preferences
  page; `syncprefs.js` holds its CLI invocations and error texts (pure; tested
  in `tests/syncprefs.test.mjs`).
- `usagebar@felipearosr.github.io/schemas/` — GSettings schema
  (`org.gnome.shell.extensions.usagebar`); re-run `glib-compile-schemas`
  after editing.
- `usagebar@felipearosr.github.io/stylesheet.css` — chips, tabs, cards,
  bars, chart, tooltip.
- Payload shapes: see `../codexbar-tray/fixtures/` (real `/usage` and `/cost`
  captures) and `Sources/CodexBarCLI/CLIPayloads.swift` / `CLICostCommand.swift`.
  Gotchas: dollar amounts arrive under `totalCost` (daily/totals) but `cost`
  (model breakdowns); per-model bars only exist with claude source `oauth`.
