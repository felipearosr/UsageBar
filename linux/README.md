# UsageBar

**Every AI coding limit you're about to hit, one glance away — in the GNOME top bar.**

This is the Linux port living inside a fork of
[**CodexBar**](https://github.com/steipete/CodexBar) by
[Peter Steinberger](https://github.com/steipete) — the excellent macOS menu-bar
app that tracks usage limits and spend across AI coding providers. All provider
plumbing is his; this directory brings the experience to Linux desktops,
GNOME-native first.

## Why

You're deep in a Claude Code or Codex session and the only warning you get
before a rate limit is the rate limit. UsageBar puts the numbers
where your eyes already are:

- **Live chips in the top bar** — one per provider, worst-window percent with
  a severity dot that walks green → yellow → red as you burn through a window.
- **A popover that answers the next question too** — click the chip: tabbed
  view (**All** for a compact overview, one tab per provider for the full
  story) with progress bars for every rate window, reset countdowns, and
  pace ("at this rate you'll hit the wall before reset").
- **Per-model limits, not just account limits** — Claude's model-scoped
  weekly windows ("Fable only") and feature limits (Daily Routines) render as
  their own bars the moment the API starts reporting them. Plan badge included
  ("Max 5x", "Plus").
- **A real cost dashboard** — Today / 30-day spend and tokens as a KPI grid,
  a daily trend bar chart with hover tooltips, top models by 30-day cost
  ("fable-5 $157.5 · opus-4-8 $77.6"), and Codex credits.
- **Every provider the CLI knows** — all ~60 upstream providers (Cursor,
  Gemini, Copilot, OpenRouter, …) can be switched on from Settings; chips,
  tabs, dashboards, status strips and brand colors come from metadata
  generated out of upstream's provider descriptors. Providers whose only
  data source is macOS-specific (browser cookies, Keychain) show an error
  row instead of numbers — everything token- or CLI-auth-based works.
- **Quota notifications** — desktop notifications at your chosen thresholds
  (separate lists for session and weekly windows), optional pace warnings
  when the projection says a window won't last to its reset, optional sound,
  per-provider muting — and silence until the window actually resets.
  Never nags twice.
- **Settings, GNOME-style** — a native libadwaita preferences window:
  provider enable/disable, panel chip style (percent / name / dot, merged
  single-chip mode, reset countdown when exhausted), used-vs-remaining and
  absolute-vs-relative reset times, severity and notification thresholds,
  refresh interval, per-provider chip/bar visibility and status-page scope.
- **Graceful when providers aren't** — rate-limited fetches keep showing the
  last good data, greyed and banner-marked, instead of a blank card.

Self-contained by design: the extension supervises its own `codexbar serve`
child on a loopback port (spawned on enable, backoff-restarted on crash,
killed on disable). No daemons to babysit, nothing listening beyond
127.0.0.1, no telemetry.

## The two surfaces

| | |
|---|---|
| [`usagebar-gnome/`](usagebar-gnome/) | **GNOME Shell extension** — the primary surface. Pure GJS (St/Clutter), GNOME 46, 49 & 50, Wayland and X11. Everything above lives here. |
| [`codexbar-tray/`](codexbar-tray/) | **Tauri tray app** — fallback for non-GNOME desktops (KDE, XFCE, …). Tray icon, text usage menu, popup window. Rust core, 15 tests. |

Both talk to the same [codexbar CLI](https://github.com/steipete/CodexBar)
(`GET /usage`, `GET /cost` from `codexbar serve`), so they stay in lockstep
with whatever providers upstream supports.

## Install

1. Download the package for your system from
   [Releases](https://github.com/felipearosr/UsageBar/releases/latest):
   - Ubuntu / Debian: `usagebar_<version>_amd64.deb` (`_arm64.deb` on ARM)
   - Fedora: `usagebar-<version>-1.x86_64.rpm` (`.aarch64.rpm` on ARM)
2. Open it. App Center (Ubuntu) or Software (Fedora) installs it along with
   everything it needs. From a terminal: `sudo apt install ./usagebar_*.deb`
   or `sudo dnf install ./usagebar-*.rpm`.
3. Log out and back in once.

UsageBar then turns itself on and enables Claude and Codex if you've signed
in to Claude Code or the Codex CLI on this machine. Other providers are in
Settings → Providers. To update, install the newer package the same way;
UsageBar doesn't download updates itself. Settings → General → codexbar CLI
shows which CLI it runs and that CLI's version.

Needs GNOME 46, 49 or 50: Ubuntu 24.04 / 25.10 / 26.04, Fedora 43 / 44.
The package includes this fork's `codexbar` CLI (upstream plus Machine Sync)
under `/usr/libexec/usagebar`, so it doesn't conflict with another `codexbar`
you may have installed.

Verified on Fedora 43 / GNOME 49 and Fedora 44 / GNOME 50 (Wayland), and on
Ubuntu 24.04 / GNOME 46 packages (Wayland and X11, headless).

### Releasing

Push a `usagebar-v<version>` tag (for example `usagebar-v1.0.1`).
[`release-usagebar.yml`](../.github/workflows/release-usagebar.yml) builds the
fork CLI for x86_64 and aarch64, packages it with the extension
([`packaging/build-packages.sh`](packaging/build-packages.sh)), and publishes
the release.

### Development

The from-zero dev setup (CLI install, config, verification without logging
out) is in [**BOOTSTRAP.md**](BOOTSTRAP.md). A symlinked checkout in
`~/.local/share/gnome-shell/extensions/` takes precedence over the packaged
copy.

## Status

Private port, moving fast; not yet on extensions.gnome.org (that, Tauri app
packaging, and upstreaming a few CLI niceties are the roadmap). Development
notes and the battle-tested verify loop live in
[`codexbar-tray/NEXT_PHASE.md`](codexbar-tray/NEXT_PHASE.md).

## Credits

All the hard parts — provider integrations, OAuth flows, cost accounting,
the `serve` API — are [steipete/CodexBar](https://github.com/steipete/CodexBar).
Go star it. This port just gives them a GNOME home.
