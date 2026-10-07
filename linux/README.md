# UsageBar

**Every AI coding limit you're about to hit, one glance away — in the GNOME top bar.**

This is the Linux port living inside a fork of
[**CodexBar**](https://github.com/steipete/CodexBar) by
[Peter Steinberger](https://github.com/steipete) — the excellent macOS menu-bar
app that tracks usage limits and spend across AI coding providers. All provider
plumbing is his; this directory brings the experience to Linux desktops,
GNOME-native first.

## UsageBar vs CodexBar

[**CodexBar**](https://github.com/steipete/CodexBar) is the original project:
the macOS menu bar app, the cross-platform `codexbar` CLI, and every provider
integration UsageBar shows. It also ships its own Qt desktop app for Linux
(see its [Linux guide](../Integrations/Linux/README.md)).

UsageBar is a fork of CodexBar that adds:

- a GNOME Shell extension that shows usage in the top bar
  ([`usagebar-gnome/`](usagebar-gnome/)), plus a Tauri tray app for other
  desktops ([`codexbar-tray/`](codexbar-tray/));
- Machine Sync, which shares spend across your machines
  (`codexbar sync` in this fork's CLI). Upstream's CLI doesn't have it.

Which one to use:

- **macOS:** use [CodexBar](https://github.com/steipete/CodexBar).
- **Linux with GNOME:** use UsageBar.
- **Other Linux desktops:** CodexBar's Qt app or UsageBar's tray app. Machine
  Sync needs this fork's CLI either way.

UsageBar doesn't ship a macOS build. It merges in upstream CodexBar changes.

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

Both talk to the `codexbar` CLI (`GET /usage`, `GET /cost` from
`codexbar serve`). UsageBar ships its own build of that CLI: upstream's plus
Machine Sync. Provider support tracks upstream.

## Install

See [INSTALL.md](INSTALL.md#install-usagebar).

### Releasing

Push a `usagebar-v<version>` tag (for example `usagebar-v1.0.1`).
[`release-usagebar.yml`](../.github/workflows/release-usagebar.yml) builds the
fork CLI for x86_64 and aarch64, packages it with the extension
([`packaging/build-packages.sh`](packaging/build-packages.sh)), and publishes
the release the extension's updater reads. The repo must be public for
installed copies to see updates.

### Merging upstream

Each CodexBar release is merged in its own PR, following
[`upstream/RUNBOOK.md`](upstream/RUNBOOK.md). A daily rehearsal
([`usagebar-merge-rehearsal.yml`](../.github/workflows/usagebar-merge-rehearsal.yml))
tries the merge ahead of time and reports conflicts and failing checks in the
pinned `merge-rehearsal` issue.

### Development

The from-zero dev setup (CLI install, config, verification without logging
out) is in [**BOOTSTRAP.md**](BOOTSTRAP.md). A symlinked checkout in
`~/.local/share/gnome-shell/extensions/` takes precedence over the packaged
copy, and dev installs don't self-update.

## Status

Early port, moving fast; not yet on extensions.gnome.org (that, Tauri app
packaging, and upstreaming a few CLI niceties are the roadmap). Development
notes and the battle-tested verify loop live in
[`codexbar-tray/NEXT_PHASE.md`](codexbar-tray/NEXT_PHASE.md).

## Credits

All the hard parts — provider integrations, OAuth flows, cost accounting,
the `serve` API — are [steipete/CodexBar](https://github.com/steipete/CodexBar).
Go star it. This port just gives them a GNOME home.
