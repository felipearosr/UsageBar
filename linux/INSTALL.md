# Install UsageBar

UsageBar has two parts:

- the GNOME Shell extension, which draws the top-bar chips and the popover;
- its command-line helper, this fork's build of the `codexbar` CLI. The
  extension runs `codexbar serve` in the background to fetch usage. The fork
  adds Machine Sync (`codexbar sync`) to upstream's CLI.

Pick one:

- **Ubuntu, Debian or Fedora with GNOME:** install the
  [UsageBar package](#the-usagebar-package). It contains both parts.
- **Any other setup**, or the extension from extensions.gnome.org: install the
  extension, then the [command-line helper](#the-command-line-helper) from
  one of its channels.

Then [check the install](#check-the-install). If you set UsageBar up by hand
before these packages existed, read
[Moving from a manual install](#moving-from-a-manual-install) first.

Needs GNOME 46, 49 or 50: Ubuntu 24.04 / 25.10 / 26.04, Fedora 43 / 44.

## The UsageBar package

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

The package puts its CLI at `/usr/libexec/usagebar/codexbar`, which is not on
`PATH`, so it doesn't conflict with another `codexbar` you may have
installed. The extension uses that copy unless `CODEXBAR_BIN` points at
another executable. To run it from a terminal, call
it by its full path, or also install a [CLI channel](#the-command-line-helper)
below; you don't need one for the extension.

Verified on Fedora 43 / GNOME 49 and Fedora 44 / GNOME 50 (Wayland), and on
Ubuntu 24.04 / GNOME 46 packages (Wayland and X11, headless).

## The extension from extensions.gnome.org

**Not listed yet.** UsageBar isn't on
[extensions.gnome.org](https://extensions.gnome.org) yet, so Extension Manager
can't find it either. Once it is listed, you'll install it from the website or
by searching for UsageBar in Extension Manager, and then install the
[command-line helper](#the-command-line-helper) separately, because the
extensions.gnome.org version doesn't include it.

Until then, use the [UsageBar package](#the-usagebar-package), or install the
same zip extensions.gnome.org will get from a release:

1. Download `usagebar@felipearosr.github.io-<version>.shell-extension.zip`
   and its `.sha256` from
   [Releases](https://github.com/felipearosr/UsageBar/releases), then check
   it: `sha256sum -c usagebar@felipearosr.github.io-*.shell-extension.zip.sha256`.
2. `gnome-extensions install --force usagebar@felipearosr.github.io-*.shell-extension.zip`
3. Log out and back in once, then
   `gnome-extensions enable usagebar@felipearosr.github.io`.
4. Install the [command-line helper](#the-command-line-helper).

This build leaves out the provider logos, which are other companies'
trademarks, and shows provider names instead. To get the logos, click
Download on the "Show provider logos?" card in the popover, or use Settings →
General → Provider logos. UsageBar then downloads them from the same release
and checks them first. It never downloads them on its own.

For a development setup from a checkout, see [BOOTSTRAP.md](BOOTSTRAP.md).

## The command-line helper

Every channel below installs the same fork build of `codexbar`. Upstream's
`codexbar` (Homebrew `steipete/tap`, or CodexBar's own releases) works for
usage, but it has no Machine Sync: `codexbar sync` doesn't exist there.

The extension looks for the CLI in this order and uses the first it finds:
`$CODEXBAR_BIN`, `/usr/libexec/usagebar/codexbar` (the UsageBar package),
`codexbar` on `PATH`, then `~/.local/bin`, `/home/linuxbrew/.linuxbrew/bin`
and `/usr/local/bin`.

UsageBar 1.0.0 shipped the full packages only. The CLI tarball and the
CLI-only `.deb` and `.rpm` are on the `usagebar-v1.1.0-rc.*` pre-releases, for
x86_64 and aarch64. The [install script](#install-script-any-distro) picks the
newest release that has a CLI tarball and says so when it isn't the latest
release; `sh -s -- 1.1.0-rc.2` pins one.

The CLI needs x86_64 or aarch64, glibc 2.38 or newer, libcurl, libsqlite3 and
libstdc++. The packages pull these in for you.

### Install script (any distro)

```sh
curl -fsSL https://raw.githubusercontent.com/felipearosr/UsageBar/main/linux/packaging/install-cli.sh | sh
```

It downloads the CLI tarball from the latest UsageBar release, or from the
newest release (pre-releases included) that has one when the latest doesn't,
checks its `.sha256`, and installs it into `~/.local/lib/usagebar-cli`, with
`~/.local/bin/codexbar` linking to it. If `~/.local/bin` isn't on your `PATH`,
the extension still finds it there.

To pick a release, add it after `sh -s --`. A plain version means the
`usagebar-v<version>` tag; anything else is used as the tag name:

```sh
curl -fsSL https://raw.githubusercontent.com/felipearosr/UsageBar/main/linux/packaging/install-cli.sh | sh -s -- 1.1.0-rc.2
curl -fsSL https://raw.githubusercontent.com/felipearosr/UsageBar/main/linux/packaging/install-cli.sh | sh -s -- usagebar-v1.1.0-rc.2
```

For every user, install under `/usr/local` (`/usr/local/bin/codexbar`). The
script never asks for privileges itself, so run it with `sudo`:

```sh
curl -fsSL https://raw.githubusercontent.com/felipearosr/UsageBar/main/linux/packaging/install-cli.sh | sudo sh -s -- --system
```

`--prefix DIR` installs anywhere else. The script refuses to replace a
`codexbar` it didn't install; see
[Moving from a manual install](#moving-from-a-manual-install). Run it again to
update.

### Ubuntu / Debian: `usagebar-cli` .deb

Download `usagebar-cli_<version>_amd64.deb` (`_arm64.deb` on ARM) from
[Releases](https://github.com/felipearosr/UsageBar/releases/latest), then:

```sh
sudo apt install ./usagebar-cli_*.deb
```

It installs the CLI into `/usr/lib/usagebar-cli` with `/usr/bin/codexbar`
linking to it. There is no APT repository yet, so install new releases the same
way. The package conflicts with other packages that ship a `codexbar`
command. You don't need it next to the UsageBar package, which carries its own
copy.

### Fedora: COPR and `usagebar-cli` .rpm

**COPR: coming soon.** The spec is ready
([`packaging/rpm/usagebar-cli.spec`](packaging/rpm/usagebar-cli.spec)), but
no COPR project is published yet. This page will list the `dnf copr enable`
command once one exists.

Until then, download `usagebar-cli-<version>-1.x86_64.rpm` (`.aarch64.rpm` on
ARM) from [Releases](https://github.com/felipearosr/UsageBar/releases/latest),
then:

```sh
sudo dnf install ./usagebar-cli-*.rpm
```

It uses the same layout as the `.deb` (`/usr/lib/usagebar-cli`,
`/usr/bin/codexbar`) and the same conflicts. You don't need it next to the
UsageBar package.

### Arch: AUR `usagebar-cli-bin`

**AUR: coming soon.** `usagebar-cli-bin` isn't on the AUR yet. The PKGBUILD
in a checkout targets the last final release, and it only builds once a final
release of 1.1.0 or later carries the CLI tarball. Until then, use the
[install script](#install-script-any-distro).

After such a release, pin the PKGBUILD to it and build it from a checkout
(`bump.sh` needs `makepkg`, or podman or docker for an archlinux container):

```sh
git clone https://github.com/felipearosr/UsageBar.git
cd UsageBar/linux/packaging/aur
./bump.sh <version>
makepkg -si
```

It installs into `/usr/lib/usagebar-cli` with `/usr/bin/codexbar` linking to
it, and conflicts with the other `codexbar` packages.

## The tray app (desktops without GNOME Shell)

On KDE, Cinnamon, XFCE and other desktops with a system tray, the tray app
shows the same usage instead of the extension. Each release attaches
`UsageBarTray-<version>-linux-x86_64.tar.gz` and `…-aarch64.tar.gz`. It's an
unpack-and-run binary, not a package, and it needs the
[command-line helper](#the-command-line-helper) too. Its runtime libraries
and the steps are in [`codexbar-tray/README.md`](codexbar-tray/README.md#release-tarball).

## Check the install

```sh
codexbar --version
codexbar sync --help
```

`--version` prints the version. `sync --help` prints the Machine Sync
commands. If it fails because there is no `sync` command, the `codexbar` on your
`PATH` is upstream's: run `which -a codexbar` to see every copy and remove the
one you don't want (see the next section).

With only the UsageBar package installed, use the full path:
`/usr/libexec/usagebar/codexbar --version`.

A libcurl "no version information available" warning on stderr is harmless.

## Moving from a manual install

Earlier setups (the old [BOOTSTRAP.md](BOOTSTRAP.md) steps) copied the CLI by
hand into `~/.local/bin`, and the extension's old CLI updater left backups
next to it. Because `~/.local/bin` usually comes before `/usr/bin` on `PATH`,
that old copy would shadow a packaged one, and the install script won't
replace it. Remove it before installing from a channel above. First check
what's there: only remove `~/.local/bin/codexbar` if it is a file or a link to
`CodexBarCLI`. A link into `~/.local/lib/usagebar-cli` came from the install
script; keep it, or remove it with `--uninstall`.

```sh
ls -l ~/.local/bin/codexbar ~/.local/bin/CodexBarCLI*
rm -f ~/.local/bin/codexbar ~/.local/bin/CodexBarCLI \
      ~/.local/bin/CodexBarCLI.bak-usagebar ~/.local/bin/CodexBarCLI.new \
      ~/.local/bin/VERSION
rm -rf ~/.local/bin/CodexBar_CodexBarCore.bundle \
       ~/.local/bin/CodexBar_CodexBarCore.bundle.bak \
       ~/.cache/usagebar/cli-update
```

If you installed `codexbar` with Homebrew, remove it too:
`brew uninstall codexbar`.

Your settings in `~/.config/codexbar/` stay as they are; every channel reads
the same config.

## Uninstall

| Installed with | Remove with |
|---|---|
| UsageBar package | `sudo apt remove usagebar` or `sudo dnf remove usagebar` |
| extensions.gnome.org or the release zip | Extension Manager, or `gnome-extensions uninstall usagebar@felipearosr.github.io` |
| Install script | `curl -fsSL https://raw.githubusercontent.com/felipearosr/UsageBar/main/linux/packaging/install-cli.sh \| sh -s -- --uninstall` (add the same `--system` or `--prefix` you installed with) |
| `usagebar-cli` .deb | `sudo apt remove usagebar-cli` |
| `usagebar-cli` .rpm | `sudo dnf remove usagebar-cli` |
| `usagebar-cli-bin` | `sudo pacman -R usagebar-cli-bin` |

None of these delete your settings and provider configuration in
`~/.config/codexbar/`. Remove that directory yourself if you want it gone.

### Shared Claude quota cache

Linux UsageBar processes running as the same OS user share Claude OAuth quota
results for five minutes under `$XDG_CACHE_HOME/usagebar/claude-oauth` (normally
`~/.cache/usagebar/claude-oauth`). A per-credential file lock allows only one
upstream quota request at a time, including when the desktop and devkit run
together. Different credentials have separate hashed cache keys.

HTTP 429 responses establish a shared cooldown of 5, 10, 20, 40, then 60 minutes
for repeated failures, or longer when Anthropic supplies a longer `Retry-After`.
Manual refresh respects that cooldown. Success resets the backoff. Requests for
other providers are unaffected. Existing stale display data remains available
through each client's normal error handling; a cooldown is not reported as a
fresh successful fetch.

The user-private cache contains quota fields, not access tokens, account identity,
or reset-credit grant inventory. Optional reset-credit inventory is available
only on a live response. Cache files are written atomically with user-only
permissions; the request lock releases when the owning process exits.

### Claude Code statusLine feed (opt-in)

Anthropic throttles `/api/oauth/usage` hard: one machine polling every five
minutes still sees 429s. Claude Code already receives your 5-hour and 7-day
windows on every response and passes them to your `statusLine` command. With the
feed on, UsageBar reads them from there instead of asking the endpoint.

1. Turn it on for the `claude` provider in `~/.config/codexbar/config.json`:

   ```json
   { "id": "claude", "enabled": true, "source": "oauth", "statusLineFeed": true }
   ```

2. Have your statusLine command forward its stdin. If you already have one, add
   this near the top of it (it prints nothing and runs in the background):

   ```sh
   input=$(cat)
   (printf '%s' "$input" | /usr/libexec/usagebar/codexbar claude statusline capture >/dev/null 2>&1 &)
   ```

   Without a statusLine of your own, point `statusLine.command` in
   `~/.claude/settings.json` at a script that does only that.

A capture from the last 15 minutes is used instead of the OAuth request. When
there is none, OAuth runs as before; if it is rate limited, a capture up to 6
hours old is shown instead of an error, minus any window whose reset time has
passed. Captures are stored under `~/.local/share/CodexBar/claude-statusline/`
(mode 0600) and hold only the two windows, the capture time, and one-way hashes
of the Claude profile and account. A capture from another account is ignored.
The feed has no model-scoped weekly limits, extra usage or credits; those appear
when an OAuth refresh succeeds. See `docs/claude-statusline-feed.md`.
