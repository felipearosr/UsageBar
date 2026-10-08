# UsageBar release checklist

The steps to cut a UsageBar release with
[`release-usagebar.yml`](../.github/workflows/release-usagebar.yml). How the
pipeline works is in [README.md](README.md#releasing). Every command runs from
a checkout of `main`. `<version>` is a semver such as `1.1.0` or
`1.1.0-rc.1`.

Always tag a release candidate (`-rc.N`) first, check it on a clean machine,
then tag the final release from the same commit or a later one.

## Upstream base

- [ ] Each upstream merge PR sets `UPSTREAM_BASE` in
  [`release/usagebar-release.txt`](release/usagebar-release.txt) to the
  merged CodexBar tag without its `v`
  ([RUNBOOK.md](upstream/RUNBOOK.md#1-one-pr-per-upstream-release-tag),
  step 1). The release notes name that base and link its upstream release,
  and `codexbar --version` prints `CodexBar <base>+usagebar.<version>`. A
  release-prep PR never changes the base.

## Once, before the first publish

- [ ] Disable the release workflows inherited from upstream (#42). They run
  on `release: published`. The UsageBar release is created with
  `GITHUB_TOKEN`, so it doesn't trigger them, but a release published by
  hand does:

  ```sh
  gh workflow disable release-cli.yml -R felipearosr/UsageBar
  gh workflow disable release-linux-desktop.yml -R felipearosr/UsageBar
  gh workflow list -R felipearosr/UsageBar --all | grep -E 'release-(cli|linux-desktop)'   # both "disabled_manually"
  ```

## 1. Release prep

- [ ] Open a PR that sets `USAGEBAR_VERSION=<version>` in
  [`release/usagebar-release.txt`](release/usagebar-release.txt): an `-rc.N`
  first, then the final version. Merge it.
- [ ] Check what the merged commit will release:
  `linux/release/resolve-version.sh usagebar-v<version>`.

## 2. Dry run

- [ ] Run the workflow on `main` without publishing:

  ```sh
  gh workflow run release-usagebar.yml -R felipearosr/UsageBar --ref main
  gh run watch -R felipearosr/UsageBar "$(gh run list -R felipearosr/UsageBar -w release-usagebar.yml -L 1 --json databaseId -q '.[0].databaseId')"
  ```

- [ ] Every job is green. The run summary shows the resolved values and the
  release notes the tag would publish: the version, the upstream base and
  its link, the changes since the previous `usagebar-v*` tag, every asset,
  and, for an `-rc`, the pre-release banner.
- [ ] Optionally download the assets and verify them again locally:

  ```sh
  gh run download <run-id> -R felipearosr/UsageBar -p 'usagebar-*' -D /tmp/usagebar-assets
  mkdir -p /tmp/usagebar-flat && find /tmp/usagebar-assets -type f -exec cp {} /tmp/usagebar-flat/ \;
  linux/release/verify-assets.sh <(linux/release/resolve-version.sh) /tmp/usagebar-flat
  ```

## 3. Tag the release candidate

- [ ] Tag the commit the dry run built and push the tag:

  ```sh
  linux/release/resolve-version.sh usagebar-v<version>-rc.N   # refuses a tag that doesn't match the metadata
  git tag usagebar-v<version>-rc.N origin/main
  git push origin usagebar-v<version>-rc.N
  ```

- [ ] The run publishes a GitHub **pre-release**. Pre-releases skip the
  distro packages: no `.deb`, `.rpm`, SRPM or AUR bump, because those version
  fields can't hold `-rc.N`. A pre-release ships the CLI and tray tarballs,
  the extension zip, their `.sha256` files and the notes.

## 4. Check the candidate on a clean machine

Use a Fedora GNOME machine with no checkout and no Swift toolchain (#49):

- [ ] Download every asset, then
  `sha256sum --ignore-missing -c ./*.sha256`.
- [ ] Install the CLI with the version named, because without one the
  script installs the latest *final* release:
  `curl -fsSL https://raw.githubusercontent.com/felipearosr/UsageBar/usagebar-v<version>-rc.N/linux/packaging/install-cli.sh | sh -s -- <version>-rc.N`.
- [ ] `codexbar --version` prints `CodexBar <base>+usagebar.<version>-rc.N`,
  and `codexbar sync --help` lists the Machine Sync commands.
- [ ] Install the extension from the zip
  (`gnome-extensions install --force usagebar@felipearosr.github.io-<version>-rc.N.shell-extension.zip`),
  log out and back in, then enable it. It shows usage, and Settings → Machine
  Sync loads without an "Unknown command" error.
- [ ] Run the tray tarball on a session without GNOME Shell, or note that
  check as skipped.
- [ ] File each problem as a new ticket under #36. Fix it, then repeat from
  step 1 with `-rc.N+1`.

## 5. Final release

- [ ] Release-prep PR to `USAGEBAR_VERSION=<version>` (step 1), then a dry
  run (step 2).
- [ ] Tag it the same way as the candidate:
  `linux/release/resolve-version.sh usagebar-v<version> && git tag usagebar-v<version> origin/main && git push origin usagebar-v<version>`.
- [ ] The release is published as Latest, with the `.deb`/`.rpm` packages,
  the SRPM and their checksums. The notes list the changes since the previous
  final release.

## 6. After a final release

- [ ] **COPR (#72):** point the spec at the release and commit the result:
  `linux/packaging/rpm/bump-spec.sh <version>`. Then build it in the COPR
  project, either from the SCM source (spec
  `linux/packaging/rpm/usagebar-cli.spec`) or from the release's SRPM:
  `copr-cli build <project> usagebar-cli-<version>-1.src.rpm`
  ([README.md](README.md#copr)).
- [ ] **AUR (#73):** the run uploads the bumped `PKGBUILD` and `.SRCINFO` as
  the `aur-usagebar-cli-bin` artifact. Or run
  `linux/packaging/aur/bump.sh <version>` yourself. Commit them here, then
  push both to the `usagebar-cli-bin` AUR repository.
- [ ] **extensions.gnome.org:** once listed, upload the release's extension
  zip. It's the build the EGO lint already passed.

## If a run fails

A failed or cancelled run publishes nothing: `publish` runs only after
`verify` succeeds. Fix the problem on `main`, then move the tag to the fixed
commit **only if no release was created for it**:
`git push origin :refs/tags/usagebar-v<version>`, then tag again. Once a
version is published, don't reuse it. Bump to the next `-rc.N` or patch
version instead.
