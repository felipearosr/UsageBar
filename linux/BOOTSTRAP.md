# UsageBar — new machine bootstrap (Fedora)

Prompt for Claude Code on a fresh Fedora box. Goal: get the UsageBar GNOME
Shell extension (private fork `felipearosr/UsageBar`, branch `linux-port`)
installed, verified headless, and testable in a nested GNOME window.
Verified on Fedora 43 / GNOME 49 and Fedora 44 / GNOME 50, both Wayland.
Full gotcha list lives in `linux/codexbar-tray/NEXT_PHASE.md` — read it
after cloning (step 2).

## Step 1 — install packages

```
sudo dnf install -y git gh nodejs mutter-devkit
```

- `nodejs` — only for `node --check` syntax checks.
- `mutter-devkit` — ships `/usr/libexec/mutter-devkit`, the viewer for the
  nested GNOME instance in step 7. Without it `gnome-shell --devkit` runs
  but shows NO window. On Fedora 43 / mutter 49 the viewer lived in
  `mutter-devel`; on Fedora 44 / mutter 50 it is this separate package
  (`mutter-devel` no longer contains it — check
  `ls /usr/libexec/mutter-devkit` after installing).
- `glib2` (schema compiler) and `python3` ship with Workstation.

Also sign in where needed:

- `gh auth login` (account felipearosr — repo is private).
- Log into **Claude Code** once (`claude`) — codexbar reads its OAuth
  creds from `~/.claude/.credentials.json` for the claude provider.
- Log into the **Codex CLI** once — codexbar reads its auth for the codex
  provider.

## Step 2 — clone the fork

```
gh repo clone felipearosr/UsageBar && cd UsageBar && git checkout linux-port
```

Remote layout on the main dev box: `origin` = felipearosr/UsageBar
(private), `upstream` = steipete/CodexBar. Add upstream if syncing:
`git remote add upstream https://github.com/steipete/CodexBar`.

Now read `linux/codexbar-tray/NEXT_PHASE.md` (iterate/verify loop +
gotchas) before touching code.

## Step 3 — install the codexbar CLI (NOT from brew)

Brew's Linux formula lags badly (0.37.2 drops the `limits` array → no
per-model Fable bar, no "Max 5x" plan badge). Install from upstream's
GitHub releases instead — need ≥ 0.43.0:

```
gh release download -R steipete/CodexBar -p 'CodexBarCLI-v*-linux-x86_64.tar.gz*' -D /tmp/codexbar-dl
cd /tmp/codexbar-dl
# .sha256 embeds the builder's temp path — compare hashes manually:
[ "$(awk '{print $1}' *.sha256)" = "$(sha256sum *.tar.gz | awk '{print $1}')" ] && echo OK
mkdir -p ~/.local/bin && tar xzf *.tar.gz -C /tmp/codexbar-dl
install -m755 CodexBarCLI ~/.local/bin/CodexBarCLI
ln -sf CodexBarCLI ~/.local/bin/codexbar
codexbar --version   # a libcurl "no version information" warning is normal
```

If a brew codexbar is already on the machine, `brew uninstall codexbar` —
linuxbrew precedes `~/.local/bin` in PATH, so a stale brew binary silently
shadows the one installed above (`which -a codexbar` to check).

## Step 4 — codexbar config

```
codexbar config enable --provider codex
codexbar config enable --provider claude
```

(Once the extension is running, any of the CLI's ~60 providers can also be
enabled from Settings → Providers — it writes through the same
`codexbar config enable/disable`. Providers whose only source is
macOS-specific — browser cookies, Keychain — will show an error row on
Linux; token/CLI-auth providers work.)

Then in `~/.config/codexbar/config.json`, set the claude entry to
`"source": "oauth"` — REQUIRED: the default/cli source strips
`extraRateWindows` (per-model bars like "Fable only") and `loginMethod`
(plan badge). Verify:

```
codexbar usage --provider claude --source oauth --format json
```

Expect `extraRateWindows` and `loginMethod` in the payload. (The `web`
source is macOS-only; claude.ai rate-limits pollers — error rows are
normal, the extension's stale handling covers it.)

## Step 5 — symlink the extension

```
mkdir -p ~/.local/share/gnome-shell/extensions
ln -s "$(pwd)/linux/usagebar-gnome/usagebar@felipearosr.github.io" \
      ~/.local/share/gnome-shell/extensions/
glib-compile-schemas "$(pwd)/linux/usagebar-gnome/usagebar@felipearosr.github.io/schemas/"
```

Symlink means edits in the repo apply on next shell start — no reinstall.

Check `gnome-shell --version` against `"shell-version"` in the
extension's `metadata.json` — if the running major (e.g. 50) isn't
listed, the shell rejects the extension as out-of-date. Add it and it
loads fine (49 and 50 are known-good).

## Step 6 — verify headless (no logout, real dconf never touched)

```
printf 'user-db:codexbar_test\n' > /tmp/codexbar-dconf-profile
DCONF_PROFILE=/tmp/codexbar-dconf-profile dbus-run-session -- sh -c '
  gsettings set org.gnome.shell enabled-extensions "[\"usagebar@felipearosr.github.io\"]"
  gnome-shell --headless --virtual-monitor 800x600 & sleep 12
  gnome-extensions info usagebar@felipearosr.github.io; kill %1'
```

Pass = `State: ACTIVE` and no `JS ERROR` in the output. Three traps:

- The dconf db name MUST be underscore_only — a hyphen makes an invalid
  D-Bus writer path and `gsettings` hangs forever.
- NEVER run this without DCONF_PROFILE: a second writer on the real user
  db clobbers enabled-extensions AND wedges the session's dconf-service
  (writes ack but never persist until `pkill dconf-service`).
- `codexbar serve` children leak when the shell is killed (no PDEATHSIG)
  — `pgrep -af 'codexbar serve'` and kill test leftovers, but NOT the
  real session's one.

## Step 7 — nested GNOME window (interactive testing, no logout)

```
DCONF_PROFILE=/tmp/codexbar-dconf-profile dbus-run-session -- sh -c '
  gsettings set org.gnome.shell enabled-extensions "[\"usagebar@felipearosr.github.io\"]"
  exec gnome-shell --devkit'
```

Run from a terminal inside the graphical session. GNOME 49 removed
`--nested`; `--devkit` is the replacement and needs the devkit viewer
(step 1: `mutter-devkit` on F44+, `mutter-devel` on F43). Do NOT add
`--virtual-monitor` here (that's for `--headless`, which has no monitor):
the devkit provides its own, and an extra virtual one gives the nested
shell two screens with the panel often on the invisible primary. A window with a full GNOME panel appears — click the UsageBar
chip and check: tab strip (All | Codex | Claude) with mini usage bars,
All view = stacked compact cards (no cost lines), provider tabs = full
card with plan badge ("Max 5x"), extra bars ("Fable only", "Daily
Routines"), cost + top-model lines, Settings item → prefs dialog
(General / Notifications / Providers). Ctrl-C to quit, then kill the
leaked serve child.

## Step 8 — enable for real

```
gnome-extensions enable usagebar@felipearosr.github.io
```

Then log out/in (Wayland shell only loads extension code at login;
disable/enable re-runs old cached code). Health check afterwards:
`gnome-extensions info usagebar@felipearosr.github.io` and
`journalctl --user -b -g codexbar`.
