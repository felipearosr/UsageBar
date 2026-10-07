# Install UsageBar

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
Settings → Providers. New releases show up in the menu as "UsageBar <version>
is available. Install now?", which asks for your password and installs the
update.

Needs GNOME 46, 49 or 50: Ubuntu 24.04 / 25.10 / 26.04, Fedora 43 / 44.
The package includes this fork's `codexbar` CLI (upstream plus Machine Sync)
under `/usr/libexec/usagebar`, so it doesn't conflict with another `codexbar`
you may have installed.

Verified on Fedora 43 / GNOME 49 and Fedora 44 / GNOME 50 (Wayland), and on
Ubuntu 24.04 / GNOME 46 packages (Wayland and X11, headless).

For a development setup from a checkout, see [BOOTSTRAP.md](BOOTSTRAP.md).
