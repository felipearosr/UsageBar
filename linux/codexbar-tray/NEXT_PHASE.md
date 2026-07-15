# Task: UsageBar GNOME extension — tabbed popover

## Context (all verified 2026-07-14 on Fedora 43, GNOME 49.8 Wayland — don't re-derive)

Working dir: `/home/faros/projects/CodexBar`. The primary Linux surface is the
**GNOME Shell extension** at
`linux/usagebar-gnome/usagebar@felipearosr.github.io/` (extension.js +
stylesheet.css + metadata.json), symlinked into
`~/.local/share/gnome-shell/extensions/`, currently **ACTIVE in the user's
session and confirmed working end-to-end** (panel chips render, popover opens,
cards show live data). It is self-contained GJS: supervises its own
`codexbar serve` child (free loopback port, backoff restart, killed in
disable()), polls `GET /usage` (55s ok / 10s retry) and `GET /cost` (120s
cache, fetched on menu open), ports merge_stale from the Rust client
(stale rows keep last usage, grey + banner).

Current popover layout: header (title + "updated Xs ago"), status banner,
then **stacked cards, one per provider** (Codex, Claude), each with: name,
plan badge, stale badge, worst-% (right), per-window rows (label, "% · resets
in …", color-severity progress bar, pace line), cost line (Today / 30d),
Dashboard/Status link buttons; below cards a Refresh row. Panel shows one
chip per provider (severity dot + worst %).

Secondary surface (untouched, keep working): Tauri app in
`linux/codexbar-tray/` — tray icon, text menu, "Open CodexBar" popup window.
15 cargo tests green. Fallback for non-GNOME; not running by default.

## Goal

Replace the stacked cards with **tabs in the popover**, like the macOS
CodexBar popover:

- A tab strip at the top of the card area: one tab per provider (user says
  "per model tabs" — providers ARE what they call models: Codex, Claude).
  Each tab = provider name + a mini usage bar underneath (worst window %,
  severity-colored, grey when stale). Active tab visually distinct
  (St.Button, add/remove 'checked' pseudo-class or a style class).
- Below the strip, ONE detail card: the selected provider's current card
  content (windows, pace, cost, links). Selection persists while the menu is
  open; default to the first provider on open.
- Bonus if cheap: inside the cost section, a per-model breakdown line or two
  from `/cost` `daily[].modelBreakdowns` / top models by 30d cost
  (`modelName`, dollar under key `cost`, `totalTokens`) — e.g.
  "opus-4-8 $77.6 · fable-5 $157.5". Ask nothing; if it clutters, skip it.

## How to iterate & verify (the loop that works)

1. Edit files in the repo dir (symlink means no reinstall step).
2. Syntax check: `node --check extension.js` (and prefs.js). After editing
   `schemas/*.gschema.xml`, re-run `glib-compile-schemas schemas/` or
   getSettings() throws on enable.
3. Headless smoke test (NO logout needed), with dconf ISOLATED via
   `DCONF_PROFILE` so the user's real settings are never touched (verified
   2026-07-14 — no save/restore needed):
   ```
   printf 'user-db:codexbar_test\n' > /tmp/codexbar-dconf-profile
   DCONF_PROFILE=/tmp/codexbar-dconf-profile dbus-run-session -- sh -c '
     gsettings set org.gnome.shell enabled-extensions "[\"usagebar@felipearosr.github.io\"]"
     gnome-shell --headless --virtual-monitor 800x600 & sleep 12
     gnome-extensions info usagebar@felipearosr.github.io; kill %1'
   ```
   The db name MUST be underscore_only ("codexbar-test" with a hyphen makes
   an invalid D-Bus writer path — gsettings hangs forever). Watch stderr/log
   for `JS ERROR`; state must be ACTIVE; a `CodexBarCLI serve` child appears
   (kill leftovers after: they leak when the nested shell is SIGKILLed —
   GJS has no PDEATHSIG; the user's real session also owns one, don't kill it).
4. Visual check without logout: same command from a terminal inside the
   session with `--devkit` instead of `--headless` (GNOME 49 removed
   `--nested`; the viewer lives in `/usr/libexec/mutter-devkit` — from the
   `mutter-devel` package on Fedora 43, the separate `mutter-devkit`
   package on Fedora 44 / mutter 50 — without it the shell runs but NO
   window appears). Keep DCONF_PROFILE, drop the `kill %1` AND drop
   `--virtual-monitor` (devkit brings its own monitor; adding a virtual
   one makes a second, often-primary invisible screen), click around in
   the window. Panel chip, popover, tabs are all interactable there.
5. The REAL session only loads new code at login (Wayland shell can't
   restart in place; GJS caches ESM imports, so disable/enable re-runs old
   code) — batch changes, verify nested/headless, then log out/in ONCE.
   `gnome-extensions info usagebar@felipearosr.github.io` + journalctl
   (`journalctl --user -b -g codexbar`) confirm health from the shell.
   NEVER run the old un-isolated loop (gsettings set against the real
   dconf): besides clobbering enabled-extensions, a second dconf writer on
   the same user db WEDGES the session's dconf-service — writes then ack
   but never persist until `pkill dconf-service` (it respawns on demand).

## Gotchas

- GNOME 49, GJS ESM imports (`gi://St`, `resource:///org/gnome/shell/ui/*`).
- St widths are px (BAR_WIDTH=320, mini bars were 26px in tabs planning);
  set fill size with set_size(), heights via constructor props, colors via
  stylesheet classes `usagebar-bg-{ok,warn,crit,stale}` / `usagebar-fg-*`.
- Rebuild UI by `destroy_all_children()` on containers; ALL timeouts/sources
  removed and actors destroyed in disable() (e.g.o. review rule).
- Cost JSON: dollars under key `totalCost` (daily/totals), `cost` (model
  breakdowns); exact keys `sessionCostUSD`, `last30DaysCostUSD`,
  `last30DaysTokens`. Fixtures: `linux/codexbar-tray/fixtures/{usage_live,cost}.json`.
- Claude rate-limits → error rows are NORMAL; stale handling covers it.
- The codexbar CLI is hand-installed at ~/.local/bin/CodexBarCLI (+
  `codexbar` symlink) from upstream's GitHub release tarballs
  (CodexBarCLI-vX-linux-x86_64.tar.gz) — brew's Linux formula lags (was
  0.37.2, which silently DROPS the `limits` array = no Fable bar, no
  "Max 5x" plan). Upgrade = download new tarball, `install` over it.
- Per-model extra bars (Fable weekly, Daily Routines) arrive as
  `usage.extraRateWindows[] = {id, title, window}` ONLY from the oauth/web
  sources; the claude CLI source strips them. The config
  (~/.config/codexbar/config.json) pins claude to `"source": "oauth"` —
  don't revert it to "cli" or the extra bars (and loginMethod plan badge)
  vanish.
- Don't touch `codexbar@inled.es` (third-party, disabled) or sysmonitor.

## Later phases (not now)

prefs.js + GSettings are DONE (Settings item in popover; General =
warn/crit thresholds, Notifications = quota alerts with enable switch +
80/95 thresholds, Providers = per-provider chip visibility via
`hidden-chips` strv). Quota notifications are DONE (Main.notify once per
window per reset cycle keyed provider:label:resetsAt, warn + one crit
escalation, implemented in _maybeNotify). Still later: e.g.o. submission,
Tauri app packaging, upstream PRs (URLs in `config providers --format
json`, serve `?status=1`, `?fresh=1`).
