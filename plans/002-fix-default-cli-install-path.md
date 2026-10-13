# Plan 002: Make the documented CLI install command work again

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**:
> `git diff --stat bcc721dfd..HEAD -- linux/packaging/install-cli.sh linux/packaging/tests/install-script.sh linux/INSTALL.md linux/README.md`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: bug
- **Planned at**: commit `bcc721dfd`, 2026-10-12

## Why this matters

The main install command in `linux/INSTALL.md` and `linux/README.md` is
`curl … install-cli.sh | sh`. The script asks GitHub for the repository's
*latest* release and dies when that release has no CLI tarball. On
2026-10-12 the latest release is `usagebar-v1.0.0`, which only carries
`.deb`/`.rpm` packages; the CLI tarballs exist only on the pre-releases
`usagebar-v1.1.0-rc.1` and `-rc.2`. So every user who follows the docs gets
`release latest of felipearosr/UsageBar has no CLI tarball for x86_64`.
The same docs still send people to an older `cli-fork-f05433b` build and
say it is x86_64 only, although rc.2 ships aarch64 too. The AUR section
tells Arch users to run `makepkg -si` on a PKGBUILD pinned to 1.0.0 with
all-zero checksums, which fails the same way.

After this plan, the no-argument install picks the newest release that
actually has a CLI tarball (final releases first, then pre-releases, with a
note when it had to fall back), the docs name the current working path, and
the AUR section says what really has to happen first.

## Current state

Files and their roles:

- `linux/packaging/install-cli.sh` — POSIX `sh` installer; downloads a CLI
  tarball plus `.sha256` from a GitHub release, verifies it, stages and swaps
  it into `PREFIX/lib/usagebar-cli`. Release lookup is lines 133–149.
- `linux/packaging/tests/install-script.sh` — the container smoke test for the
  installer. It points the script at a `file://` API fixture via
  `USAGEBAR_API_URL` (lines 106–150). Run by `linux-packaging.yml` in CI.
- `linux/INSTALL.md` — user-facing install guide (CLI section lines 74–115,
  AUR section lines 159–170).
- `linux/README.md` — Linux overview; the "Just the CLI" section is lines
  94–128.
- `linux/packaging/aur/PKGBUILD` — `pkgver=1.0.0` (line 9), zero checksums
  (lines 26–29). Do NOT edit it in this plan; the release workflow bumps it.

Release lookup today (`linux/packaging/install-cli.sh:133-149`):

```sh
    case "$tag" in
        '') api="$API_URL/repos/$REPO/releases/latest" ;;
        [0-9]*) api="$API_URL/repos/$REPO/releases/tags/usagebar-v$tag" ;;
        *) api="$API_URL/repos/$REPO/releases/tags/$tag" ;;
    esac
    fetch "$api" "$work/release.json" || die "couldn't read release ${tag:-latest} of $REPO"
    # The CLI tarball only: usagebar-cli-<version>-linux-<arch>.tar.gz, or
    # CodexBarCLI-… on the older cli-fork-* releases. A release also carries
    # UsageBarTray-<version>-linux-<arch>.tar.gz, which isn't the CLI.
    url=$(grep -oE '"browser_download_url": *"[^"]*/(usagebar-cli|CodexBarCLI)-[^"/]*-linux-'"$arch"'\.tar\.gz"' \
        "$work/release.json" | sed 's/.*"\([^"]*\)"$/\1/' | head -n 1)
    [ -n "$url" ] || die "release ${tag:-latest} of $REPO has no CLI tarball for $arch"
    archive="$work/$(basename "$url")"
    say "Downloading $url"
    fetch "$url" "$archive" || die "download failed: $url"
    fetch "$url.sha256" "$archive.sha256" || die "download failed: $url.sha256"
```

The `fetch` helper (`install-cli.sh:116-124`) runs
`curl -fsSL --retry 3 -o "$2" "$1"` or `wget -q -O "$2" "$1"`.

The fixture helper in the test (`linux/packaging/tests/install-script.sh:106-110`)
writes one `release.json` per tag under
`/tmp/api/repos/felipearosr/UsageBar/releases/tags/<TAG>`; the script is
then run with `USAGEBAR_API_URL=file:///tmp/api`. Read lines 100–160 of that
test before editing it; model new cases on the existing `9.9.9` / `9.9.8`
cases there.

Docs that are wrong today:

- `linux/INSTALL.md:85-89`:
  > The CLI tarball and the CLI-only `.deb` and `.rpm` are attached to UsageBar
  > releases from the first release after 1.0.0 on. UsageBar 1.0.0 doesn't have
  > them. Until that release is out, use the
  > [install script](#install-script-any-distro) with the `cli-fork-f05433b`
  > pre-release (x86_64 only).
- `linux/INSTALL.md:97` and `linux/README.md:100`: the bare `| sh` command.
- `linux/INSTALL.md:109-110`: examples `sh -s -- 1.0.1` and
  `sh -s -- cli-fork-f05433b` (1.0.1 does not exist).
- `linux/INSTALL.md:161-168`: "build the same PKGBUILD from a checkout:
  `makepkg -si`".
- `linux/README.md:122-126`: "Until it is on the AUR, build it from a checkout
  with `makepkg -si` in that directory."

Live facts (checked 2026-10-12 with `gh release list -R felipearosr/UsageBar`):
latest = `usagebar-v1.0.0` (deb/rpm only); `usagebar-v1.1.0-rc.2` and
`-rc.1` are pre-releases with `usagebar-cli-1.1.0-rc.2-linux-{x86_64,aarch64}.tar.gz`;
`cli-fork-f05433b` is an older pre-release. `linux/packaging/aur/bump.sh:23`
only accepts versions matching `^[0-9]+(\.[0-9]+)*$`, so the PKGBUILD cannot
be bumped to a pre-release.

Conventions: the installer is strict POSIX `sh` (`set -eu`, no bashisms, no
`jq`); error messages go through `die`; the script never escalates
privileges. Docs are plain Markdown, sentences under ~100 columns, no
em-dashes. Commit messages are short imperative clauses
(e.g. `Gate UsageBar releases on resolved versions, CLI smoke tests and an asset verifier`).

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Installer syntax | `sh -n linux/packaging/install-cli.sh` | exit 0 |
| Installer help | `sh linux/packaging/install-cli.sh --help` | usage text, exit 0 |
| Shell lint (CI) | `shellcheck linux/packaging/install-cli.sh linux/packaging/tests/install-script.sh` | exit 0 (shellcheck is not installed on the dev box; CI runs it in `linux-packaging.yml`) |
| Container smoke | `linux/packaging/tests/run-in-container.sh` (read its header for arguments; needs podman and a CLI tarball) | "install-script.sh passed" or equivalent, exit 0 |
| Fork delta | `git fetch upstream main && linux/upstream/fork-delta.sh` | last line `OK: every upstream file the fork edits is on the allowlist.` |
| Live check (optional, network) | `sh linux/packaging/install-cli.sh --prefix "$(mktemp -d)/p"` | installs 1.1.0-rc.2 with the fallback note |

## Scope

**In scope** (the only files you should modify):
- `linux/packaging/install-cli.sh`
- `linux/packaging/tests/install-script.sh`
- `linux/INSTALL.md`
- `linux/README.md`

**Out of scope** (do NOT touch):
- `linux/packaging/aur/PKGBUILD`, `.SRCINFO`, `bump.sh` — bumped by the
  release workflow; a pre-release can't be pinned there.
- `.github/workflows/*` — plan 006 covers the release workflow.
- The root `README.md` — it is an upstream file; editing it grows the fork
  delta (see `linux/upstream/FORK-DELTA.md`).
- Anything under `Sources/` or `Scripts/`.

## Git workflow

- Branch: `felipearosr/install-cli-fallback` from `main`.
- One commit per step is fine; message style: short imperative, e.g.
  `Fall back to the newest release with a CLI tarball`.
- Do NOT push or open a PR unless the operator instructed it. PRs always
  target `main`. Use `-R felipearosr/UsageBar` on every `gh` call.

## Steps

### Step 1: Fall back from `latest` to the newest release that has a CLI tarball

In `linux/packaging/install-cli.sh`, keep the three-way `case "$tag"` but
change the no-tag branch so that, when `releases/latest` has no matching
tarball, the script fetches the release list and takes the first matching
`browser_download_url`:

- Fetch `"$API_URL/repos/$REPO/releases?per_page=30"` into
  `"$work/releases.json"`. GitHub returns releases newest-first and omits
  drafts for unauthenticated callers, so the first matching URL belongs to
  the newest release that has a CLI tarball (pre-releases included).
- Reuse the exact `grep -oE … | sed … | head -n 1` pattern already used on
  `release.json`, applied to `releases.json`.
- When the fallback URL is used, print one line with `say`, for example:
  `Note: the latest release has no CLI tarball; installing from <tag> instead.`
  Derive `<tag>` from the URL (`…/releases/download/<tag>/<file>`), e.g.
  `tag_used=$(printf '%s\n' "$url" | sed 's|.*/releases/download/\([^/]*\)/.*|\1|')`.
- Keep the explicit-tag branches unchanged: a named tag that lacks a tarball
  must still `die` with the existing message.
- Keep it POSIX `sh`: no arrays, no `[[`, no process substitution.

Also harden `fetch`: add `--proto '=https' --tlsv1.2` to the `curl` call
only when the URL starts with `https://` (the tests use `file://` URLs, which
`--proto '=https'` would reject). The simplest shape:

```sh
fetch() {
    case "$1" in
        https://*) proto="--proto =https --tlsv1.2" ;;
        *) proto= ;;
    esac
    if command -v curl >/dev/null 2>&1; then
        # shellcheck disable=SC2086 # $proto is intentionally word-split
        curl -fsSL --retry 3 $proto -o "$2" "$1"
    …
```

**Verify**: `sh -n linux/packaging/install-cli.sh` → exit 0;
`sh linux/packaging/install-cli.sh --help` → usage text.

### Step 2: Cover the fallback in the container test

In `linux/packaging/tests/install-script.sh`, next to the existing fixture
cases (lines ~106–150), add fixtures and three cases:

1. `releases/latest` lists only `.deb`/`.rpm` assets (no tarball) and the
   list endpoint lists a newer pre-release with the tarball for this arch →
   the install succeeds, the output contains `Note:` and the fallback tag,
   and `codexbar --version` passes `cli-checks.sh`.
2. `releases/latest` has the tarball → it is used and no `Note:` line is
   printed.
3. Neither has a tarball → the script dies with
   `has no CLI tarball for <arch>` and installs nothing
   (use the existing `snapshot`/`assert_unchanged` helpers from `lib.sh`).

Fixture layout under `/tmp/api/repos/felipearosr/UsageBar/`:
`releases/latest` (a file) and a sibling file literally named
`releases?per_page=30` (curl treats the `?` as part of the file name for
`file://` URLs, so the fixture must carry it in the name; the `releases/`
directory and that file can coexist). Build the JSON the same way
`release_fixture` does (`browser_download_url` entries pointing at
`file:///tmp/art/<tarball>`), and reset `/tmp/api` between cases.

**Verify**: `linux/packaging/tests/run-in-container.sh` (see its header for
how to pass an artifact directory; `linux/packaging/tests/make-fake-tarball.sh`
builds a stand-in CLI tarball) → all `say` sections pass, exit 0. If podman
is unavailable, STOP and report; do not skip this step silently.

### Step 3: Fix the install docs

`linux/INSTALL.md`:
- Replace lines 85–89 with text saying: UsageBar 1.0.0 shipped packages only;
  the CLI tarballs are on the `usagebar-v1.1.0-rc.*` pre-releases (x86_64
  and aarch64); the install script picks the newest release that has one
  and says so; `sh -s -- 1.1.0-rc.2` pins it.
- Replace the examples at lines 109–110 with `sh -s -- 1.1.0-rc.2` and
  `sh -s -- usagebar-v1.1.0-rc.2` (one version form, one tag form). Drop
  `cli-fork-f05433b` and `1.0.1`.
- In the AUR section (lines 159–170): keep the "coming soon" line, then say
  that the checked-in PKGBUILD targets the last final release and only works
  once a final release ≥ 1.1.0 carries the CLI tarball; until then use the
  install script. Keep the `makepkg -si` block but prefix it with
  `linux/packaging/aur/bump.sh <version>` and note that `bump.sh` needs
  `makepkg` or podman/docker. Do not claim the PKGBUILD builds as-is today.

`linux/README.md` (lines 94–128): make the "latest release" sentence match
the script's new behaviour ("the newest release that has a CLI tarball, final
releases first"), fix the example version to `1.1.0-rc.2`, and apply the same
AUR correction as above in the paragraph at lines 122–126.

**Verify**: `grep -n 'cli-fork-f05433b\|1\.0\.1' linux/INSTALL.md linux/README.md`
→ no matches; `grep -c '1.1.0-rc.2' linux/INSTALL.md` → ≥ 2.

### Step 4: Fork delta and whole-tree check

**Verify**: `git fetch upstream main && linux/upstream/fork-delta.sh` → ends
with `OK: …`; `git status --porcelain` lists only the four in-scope files.

## Test plan

- New container cases (Step 2) in `linux/packaging/tests/install-script.sh`:
  fallback used, latest used, nothing found. Model them on the `9.9.9`,
  explicit-tag and `9.9.8` cases already there.
- Existing cases must keep passing: per-user install/uninstall, created-dir
  cleanup, tampered tarball, `--system`, explicit tag.
- Verification: `linux/packaging/tests/run-in-container.sh …` → exit 0.

## Done criteria

- [ ] `sh -n linux/packaging/install-cli.sh` exits 0 and `--help` prints usage
- [ ] Container smoke test passes with the three new cases
- [ ] `grep -n 'cli-fork-f05433b\|1\.0\.1' linux/INSTALL.md linux/README.md` prints nothing
- [ ] `grep -n "releases?per_page=30" linux/packaging/install-cli.sh` prints one match
- [ ] `linux/upstream/fork-delta.sh` ends with `OK:`
- [ ] `git status --porcelain` shows only the four in-scope files
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- `install-cli.sh` lines 133–149 no longer match the excerpt above.
- The container test harness cannot run on this machine (no podman) — report
  which step is unverified rather than skipping it.
- GitHub's list endpoint turns out not to be newest-first in your check
  (`gh api repos/felipearosr/UsageBar/releases --jq '.[].tag_name'` should
  print rc.2 before rc.1 before 1.0.0).
- Fixing the docs seems to require editing the root `README.md` or the
  PKGBUILD — those are out of scope.

## Maintenance notes

- Once a final release ≥ 1.1.0 ships with the CLI tarball, the fallback
  stops triggering; the docs' explicit `1.1.0-rc.2` pins should then be
  replaced with the final version (small follow-up, not this plan).
- Reviewer focus: the fallback must never pick a tray tarball
  (`UsageBarTray-*-linux-<arch>.tar.gz`); the grep pattern restricts names to
  `usagebar-cli-`/`CodexBarCLI-`. The container test's existing tray decoy
  covers this.
- Deferred: committing a bumped PKGBUILD after each final release (the
  workflow only uploads it as an artifact) — see plan 006's notes.
