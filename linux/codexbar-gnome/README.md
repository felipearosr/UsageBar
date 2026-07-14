# CodexBar Tray — GNOME Shell extension

A native GNOME panel frontend for [CodexBar](https://github.com/steipete/CodexBar):
per-provider usage chips in the top bar, and an anchored popover with cards —
rate-window progress bars, reset countdowns, pace, cost (Today / 30 days) and
dashboard/status links. This is the primary Linux/GNOME surface; the Tauri app
in `../codexbar-tray/` is the fallback for non-GNOME desktops (KDE, XFCE, …).

Like the Tauri app, it is self-contained: it supervises its own
`codexbar serve` child on a free loopback port (restart with backoff, killed on
disable) and polls `GET /usage` / `GET /cost`. Requires the `codexbar` CLI
(`brew install steipete/tap/codexbar`, or set `$CODEXBAR_BIN`).

## Install (development)

```bash
ln -sfn "$PWD/codexbar-tray@steipete.github.io" \
  ~/.local/share/gnome-shell/extensions/codexbar-tray@steipete.github.io
gnome-extensions enable codexbar-tray@steipete.github.io
```

GNOME only scans for new extensions at login — log out and back in the first
time (subsequent file edits need the same, or test in a nested/headless shell).

## Headless smoke test (no logout needed)

```bash
dbus-run-session -- sh -c '
  gsettings set org.gnome.shell enabled-extensions "[\"codexbar-tray@steipete.github.io\"]"
  gnome-shell --headless --virtual-monitor 800x600 & sleep 12
  gnome-extensions info codexbar-tray@steipete.github.io; kill %1'
```

⚠ dconf is per-user, not per-session: the `gsettings set` above **overwrites
your real enabled-extensions list**. Save it first (`gsettings get …`) and
restore it after.

Check `journalctl --user -b -g codexbar` (or the nested shell's stderr) for
`JS ERROR` lines; extension state should be ACTIVE and a
`CodexBarCLI serve` child should appear while the shell runs.

## Files

- `codexbar-tray@steipete.github.io/extension.js` — everything: serve
  supervisor (Gio.Subprocess), Soup 3 HTTP client, stale-merge (port of the
  Rust `merge_stale`), panel indicator + popover UI (St widgets).
- `codexbar-tray@steipete.github.io/stylesheet.css` — chips, cards, bars.
- Payload shapes: see `../codexbar-tray/fixtures/` (real `/usage` and `/cost`
  captures) and `Sources/CodexBarCLI/CLIPayloads.swift` / `CLICostCommand.swift`.
  Gotcha: dollar amounts arrive under the JSON key `totalCost`.
