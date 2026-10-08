# UsageBar — GNOME Shell extension

A native GNOME panel frontend for AI coding-provider usage limits, ported from
[CodexBar](https://github.com/steipete/CodexBar): per-provider chips in the top
bar, and an anchored popover with a tab strip (All + per provider) — rate-window
progress bars (including per-model limits like "Fable only"), reset countdowns,
pace, a cost dashboard (KPI grid, daily trend chart, top models), quota
notifications, and a libadwaita Settings window. This is the primary
Linux/GNOME surface; the Tauri app in `../codexbar-tray/` is the fallback for
non-GNOME desktops (KDE, XFCE, …).

Self-contained: it supervises its own `codexbar serve` child on a free
loopback port (restart with backoff, killed on disable) and polls
`GET /usage` / `GET /cost`. It runs `$CODEXBAR_BIN` when that points at an
executable; otherwise the fork's CLI that the .deb/.rpm (see
[`../INSTALL.md`](../INSTALL.md)) ship at `/usr/libexec/usagebar/codexbar`,
then the first `codexbar` on `PATH`, then `~/.local/bin`,
`/home/linuxbrew/.linuxbrew/bin` and `/usr/local/bin`. The extension never
downloads or updates the CLI; Settings → General → codexbar CLI shows the path
in use and its version. Machine Sync needs the fork's CLI.

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

## extensions.gnome.org ZIP

Build the ZIP uploaded to extensions.gnome.org and lint it against the
mechanically checkable review guidelines:

```bash
python3 linux/usagebar-gnome/tools/ego-zip.py build    # → linux/dist/usagebar@felipearosr.github.io.shell-extension.zip
python3 linux/usagebar-gnome/tools/ego-zip.py lint path/to/extension.zip
python3 -m unittest discover -s linux/usagebar-gnome/tests -p 'test_*.py'
```

The ZIP holds only an allowlist: the modules `extension.js` and `prefs.js`
import, `stylesheet.css`, `metadata.json`, the schema XML, UsageBar's own
`icons/usagebar-machine{,s}-symbolic.svg` and `LICENSE` (no tests, tools,
provider logos or compiled schema; GNOME 44+ compiles schemas on install).
Lint errors (files outside the allowlist, provider logos, binaries, bad
`metadata.json` keys or `shell-version`, schema ID/path outside
`org.gnome.shell.extensions`, minified JS, deprecated modules, Gtk in the shell
process or St in prefs) fail the build; warnings (import-time work, discarded
source/signal IDs, debug logging, interpreter subprocesses, brand logos) are
for the reviewer. CI runs both, plus a warning-only ESLint report
(`eslint.config.mjs`), on pull requests that touch the extension.

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
order changes, and positive/negative icon lookup caching. `tests/cli.test.mjs`
covers the codexbar lookup order and `--version` parsing.

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
checkouts and the .deb/.rpm packages. The build submitted to
extensions.gnome.org leaves them out (third-party trademarks). Without a logo:

- where the logo stands alone (panel chips, the providers a Machine used), the
  provider's full name is printed in its place, in its brand color lightened
  or darkened to stay readable on the panel or popover (`brandtext.js`); names
  over 18 characters are cut with an ellipsis;
- where the name is already printed beside it (All tab rows, the detail
  header, model rows, the cost dashboard), the logo is left out and the row
  closes up. In the spend and chart legends, where the tinted logo was the
  color key, the name takes the brand color instead.

Set `USAGEBAR_HIDE_PROVIDER_ICONS=1` to see that build's look with the logos
in place, e.g. `USAGEBAR_HIDE_PROVIDER_ICONS=1 ./linux/run-dev.sh`. The UI
smoke test runs once with logos and once with them hidden.

## Files

- `usagebar@felipearosr.github.io/extension.js` — everything: serve
  supervisor (Gio.Subprocess), Soup 3 HTTP client, stale-merge (port of the
  Rust `merge_stale`), panel indicator + popover UI (St widgets), quota
  notifications.
- `usagebar@felipearosr.github.io/brandtext.js` — brand-colored provider
  names for builds without logos: contrast-safe tints of each provider's
  color (pure; tested in `tests/brandtext.test.mjs`).
- `usagebar@felipearosr.github.io/authlogin.js` — which provider errors are
  auth failures, each provider's login command, and the terminal launcher
  order for the error banner's "Log in" button (pure; tested in
  `tests/authlogin.test.mjs`).
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
