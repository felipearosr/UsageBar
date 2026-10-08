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

### Just the CLI

To get only this fork's `codexbar` CLI (with `codexbar sync`) on any x86_64
or aarch64 distro with glibc 2.38 or newer, libcurl, libsqlite3 and libstdc++:

```sh
curl -fsSL https://raw.githubusercontent.com/felipearosr/UsageBar/main/linux/packaging/install-cli.sh | sh
```

[`packaging/install-cli.sh`](packaging/install-cli.sh) downloads the CLI
tarball from the latest release (or the one you name: `| sh -s -- 1.0.1`),
checks its `.sha256`, and installs it into `~/.local/lib/usagebar-cli` with
`~/.local/bin/codexbar` pointing at it. `--system` installs under `/usr/local`
instead (run it with `sudo`; the script never asks for privileges itself),
`--prefix DIR` anywhere else, and `--uninstall` removes exactly what it
installed. It refuses to replace a `codexbar` it didn't install.

On Ubuntu / Debian, each release also has a CLI-only package,
`usagebar-cli_<version>_amd64.deb` (`_arm64.deb` on ARM):
`sudo apt install ./usagebar-cli_*.deb`. On Fedora, it's
`usagebar-cli-<version>-1.x86_64.rpm` (`.aarch64.rpm` on ARM):
`sudo dnf install ./usagebar-cli-*.rpm`. Either one puts the CLI in
`/usr/lib/usagebar-cli` with `/usr/bin/codexbar` linking to it, and conflicts
with other packages that ship a `codexbar` command. You don't need it next to
the full `usagebar` package, which carries its own copy.

On Arch, [`packaging/aur/`](packaging/aur/) holds the `usagebar-cli-bin`
PKGBUILD and `.SRCINFO`. It downloads the release tarball with pinned
checksums, uses the same layout (`/usr/lib/usagebar-cli`, `/usr/bin/codexbar`),
and conflicts with other `codexbar` packages. Until it is on the AUR, build it
from a checkout with `makepkg -si` in that directory.

To bump it for a new release, run one command:
`linux/packaging/aur/bump.sh <version>`. It sets `pkgver`, resets `pkgrel`,
pins the checksums from the release's `.sha256` files and the LICENSE at the
tag, and regenerates `.SRCINFO`, in an archlinux container when `makepkg`
isn't installed. The release workflow runs it after publishing and uploads
the result as the `aur-usagebar-cli-bin` artifact.

#### COPR

[`packaging/rpm/usagebar-cli.spec`](packaging/rpm/usagebar-cli.spec)
repackages the release tarball (checked against pinned SHA-256s in `%prep`),
and COPR accepts that: its rules
([What I can build in Copr?](https://docs.copr.fedorainfracloud.org/user_documentation.html#what-i-can-build-in-copr))
only restrict licenses and legality, and say packages "do **not** need to
follow the Fedora Packaging Guidelines", the document that asks for builds
from source. So the chosen path is a COPR project that builds this spec as
is. Either:

- point a COPR package at this repo with the SCM source type and spec path
  `linux/packaging/rpm/usagebar-cli.spec`. COPR downloads the `Source` URLs
  from the release itself. Or
- upload the release's `usagebar-cli-<version>-1.src.rpm`
  (`copr-cli build <project> usagebar-cli-*.src.rpm`).

After each release, run `linux/packaging/rpm/bump-spec.sh <version>` and
commit the result. It sets the version and both checksums from the release's
`.sha256` files and adds a changelog entry. The `.rpm` files attached to each
release don't depend on COPR.

### Releasing

UsageBar has its own semver, independent of CodexBar's numbers.
[`release/usagebar-release.txt`](release/usagebar-release.txt) records two
facts:

- `USAGEBAR_VERSION`: the UsageBar release this commit becomes (`1.1.0`, or
  `1.2.0-rc.1` for a pre-release). Release prep bumps it.
- `UPSTREAM_BASE`: the CodexBar release last merged in (`0.72.0`). **Upstream
  merge PRs bump the base**
  ([`upstream/RUNBOOK.md`](upstream/RUNBOOK.md), step 1).

[`release/resolve-version.sh`](release/resolve-version.sh) turns a
`usagebar-v<semver>` tag plus that file into every value a release uses: the
version, the base, the CLI version string `<base>+usagebar.<semver>` (what
`codexbar --version` prints after `CodexBar`), whether it's a pre-release, and
every asset name. It refuses a tag that doesn't match `USAGEBAR_VERSION`, an
upstream-style `v0.x.y` tag, and anything that isn't a semver. Run it with no
tag to see what the current commit would release:

```sh
linux/release/resolve-version.sh                    # from the metadata alone
linux/release/resolve-version.sh usagebar-v1.1.0    # validates a tag
linux/release/tests/resolve-version.test.sh         # its tests (also in PR CI)
```

Push a `usagebar-v<version>` tag (for example `usagebar-v1.0.1`).
[`release-usagebar.yml`](../.github/workflows/release-usagebar.yml) builds the
fork CLI for x86_64 and aarch64, packages it with the extension
([`packaging/build-packages.sh`](packaging/build-packages.sh)), smoke-tests
`install-cli.sh` against the CLI tarball in clean containers
([`packaging/tests/`](packaging/tests/)), and publishes the packages plus
`usagebar-cli-<version>-linux-<arch>.tar.gz` (and `.sha256`) as the release.

### Merging upstream

Each CodexBar release is merged in its own PR, following
[`upstream/RUNBOOK.md`](upstream/RUNBOOK.md). A daily rehearsal
([`usagebar-merge-rehearsal.yml`](../.github/workflows/usagebar-merge-rehearsal.yml))
tries the merge ahead of time and reports conflicts and failing checks in the
pinned `merge-rehearsal` issue.

To keep those merges small, the fork changes upstream's files only through
declared hooks. [`upstream/FORK-DELTA.md`](upstream/FORK-DELTA.md) explains
fork-owned vs upstream files and how to add a hook; CI runs
`linux/upstream/fork-delta.sh` on every PR.

### Development

The from-zero dev setup (CLI install, config, verification without logging
out) is in [**BOOTSTRAP.md**](BOOTSTRAP.md). A symlinked checkout in
`~/.local/share/gnome-shell/extensions/` takes precedence over the packaged
copy.

## Status

Early port, moving fast; not yet on extensions.gnome.org (that, Tauri app
packaging, and upstreaming a few CLI niceties are the roadmap). Development
notes and the battle-tested verify loop live in
[`codexbar-tray/NEXT_PHASE.md`](codexbar-tray/NEXT_PHASE.md).

## Credits

All the hard parts — provider integrations, OAuth flows, cost accounting,
the `serve` API — are [steipete/CodexBar](https://github.com/steipete/CodexBar).
Go star it. This port just gives them a GNOME home.
