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
- **Quota notifications** — a desktop notification when any window crosses
  80%, one escalation at 95%, and then silence until the window actually
  resets. Never nags twice.
- **Settings, GNOME-style** — severity thresholds, notification thresholds,
  and per-provider chip visibility in a native libadwaita preferences window.
- **Graceful when providers aren't** — rate-limited fetches keep showing the
  last good data, greyed and banner-marked, instead of a blank card.

Self-contained by design: the extension supervises its own `codexbar serve`
child on a loopback port (spawned on enable, backoff-restarted on crash,
killed on disable). No daemons to babysit, nothing listening beyond
127.0.0.1, no telemetry.

## The two surfaces

| | |
|---|---|
| [`usagebar-gnome/`](usagebar-gnome/) | **GNOME Shell extension** — the primary surface. Pure GJS (St/Clutter), GNOME 49 & 50, Wayland. Everything above lives here. |
| [`codexbar-tray/`](codexbar-tray/) | **Tauri tray app** — fallback for non-GNOME desktops (KDE, XFCE, …). Tray icon, text usage menu, popup window. Rust core, 15 tests. |

Both talk to the same [codexbar CLI](https://github.com/steipete/CodexBar)
(`GET /usage`, `GET /cost` from `codexbar serve`), so they stay in lockstep
with whatever providers upstream supports.

## Quick start

The full from-zero walkthrough (packages, CLI install, config, verification
without logging out) is in [**BOOTSTRAP.md**](BOOTSTRAP.md). The short
version:

1. Install the `codexbar` CLI from upstream's
   [GitHub releases](https://github.com/steipete/CodexBar/releases)
   (`CodexBarCLI-v*-linux-x86_64.tar.gz`, ≥ 0.43.0 — the brew Linux formula
   lags and silently drops the per-model limit data).
2. Enable your providers and pin Claude to the OAuth source in
   `~/.config/codexbar/config.json` (`"source": "oauth"`).
3. Symlink `usagebar-gnome/usagebar@felipearosr.github.io` into
   `~/.local/share/gnome-shell/extensions/`, run
   `gnome-extensions enable usagebar@felipearosr.github.io`, log out/in.

Verified on Fedora 43 / GNOME 49 and Fedora 44 / GNOME 50, both Wayland.

## Status

Private port, moving fast; not yet on extensions.gnome.org (that, Tauri app
packaging, and upstreaming a few CLI niceties are the roadmap). Development
notes and the battle-tested verify loop live in
[`codexbar-tray/NEXT_PHASE.md`](codexbar-tray/NEXT_PHASE.md).

## Credits

All the hard parts — provider integrations, OAuth flows, cost accounting,
the `serve` API — are [steipete/CodexBar](https://github.com/steipete/CodexBar).
Go star it. This port just gives them a GNOME home.
