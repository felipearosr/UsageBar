# codexbar-tray — Linux tray app for CodexBar

A native Linux system-tray frontend for [CodexBar](https://github.com/steipete/CodexBar):
AI coding-provider usage limits and reset countdowns in your tray. Built with Tauri v2;
all provider integrations come from the upstream cross-platform `codexbar` CLI, which
this app supervises as a `codexbar serve` child process.

## Requirements

- The `codexbar` CLI on `$PATH`, in `~/.local/bin`, or at `$CODEXBAR_BIN`. The
  UsageBar packages in [`../INSTALL.md`](../INSTALL.md) install it at
  `/usr/libexec/usagebar/codexbar`, which isn't on `PATH`, so set
  `CODEXBAR_BIN=/usr/libexec/usagebar/codexbar`.
- A StatusNotifier tray host. KDE, Cinnamon, and XFCE have one; on GNOME install the
  AppIndicator extension (`gnome-shell-extension-appindicator` — Ubuntu preinstalls it,
  stock Fedora Workstation does not).
- Build deps (Fedora): `webkit2gtk4.1-devel libayatana-appindicator-gtk3-devel librsvg2-devel openssl-devel`
  (Ubuntu/Debian: `libwebkit2gtk-4.1-dev libayatana-appindicator3-dev librsvg2-dev libssl-dev`).

## Release tarball

Each UsageBar release attaches `UsageBarTray-<version>-linux-x86_64.tar.gz`
and `…-aarch64.tar.gz`, each with a `.sha256`. Unpack one and run the binary:

```bash
sha256sum -c UsageBarTray-*-linux-x86_64.tar.gz.sha256
tar -xzf UsageBarTray-*-linux-x86_64.tar.gz
UsageBarTray-*-linux-x86_64/codexbar-tray --version   # codexbar-tray <version>
UsageBarTray-*-linux-x86_64/codexbar-tray &
```

The binary needs the runtime libraries of the build deps above:
WebKitGTK 4.1, libayatana-appindicator3 and librsvg2 (Fedora: `webkit2gtk4.1
libayatana-appindicator-gtk3 librsvg2`; Ubuntu/Debian: `libwebkit2gtk-4.1-0
libayatana-appindicator3-1 librsvg2-2`). It's built on Ubuntu 24.04, so it
needs glibc 2.39 or newer (Ubuntu 24.04+, Fedora 40+). It also needs the
`codexbar` CLI (see Requirements).

A release build reports the UsageBar version: `build.rs` reads
`USAGEBAR_VERSION` at build time and falls back to the Cargo version.

## Build & run

```bash
cd src-tauri
cargo run            # tray app; look for the gauge icon in your tray
cargo test           # unit + fixture tests
cargo test -- --ignored   # integration test against a real `codexbar serve`
```

## How it works

- On launch the app locates `codexbar`, picks a free loopback port, and supervises
  `codexbar serve --refresh-interval 300` (restarts with backoff; killed on quit).
  Five minutes keeps upstream usage endpoints happy — Claude's rate-limits pollers.
- Every ~60s it polls `GET /usage` (a cache hit between serve refreshes) and renders: a
  ring-gauge tray icon showing the worst window's used percent (green → amber → red,
  red dot on provider errors), and menu rows like
  `Codex · weekly · 13% used · resets in 5d 13h` with burn-rate pace summaries.
- If a provider fetch fails (e.g. rate-limited), the last known usage stays visible
  marked `· stale`, with the error underneath.
- Countdowns re-render every 30s without refetching. "Refresh now" forces a poll.
- Providers/API keys are configured with the CLI (`codexbar config providers|enable|disable|set-api-key`)
  or `~/.config/codexbar/config.json`; serve picks changes up automatically.

## Popup window

"Open CodexBar" in the tray menu opens a popup (appindicator trays deliver no
click events, so the menu item is the only trigger). It recreates the macOS
popover: provider tabs with mini usage bars, and per provider a detail card —
plan badge, per-window progress bars with reset countdowns and pace lines,
cost summary (Today / Last 30 days from `GET /cost`), and dashboard/status
links. Stale or failing providers show grey bars plus a warning banner with
the last known data.

The frontend is plain HTML/CSS/JS in `dist/` (no framework, no external
requests, strict CSP), talking to Rust over Tauri IPC (`state`, `cost`,
`open_url` commands). Wayland has no global coordinates, so the window is
centered rather than tray-anchored, and hides on focus loss or Esc — it's
created lazily on first open, then shown/hidden.

## Roadmap (later phases)

Settings UI, libnotify quota notifications, XDG autostart, RPM/deb/AUR
packaging, upstream serve additions (`?status=1` incidents, `?fresh=1` cache
bypass, dashboard/status URLs in `config providers --format json`).
