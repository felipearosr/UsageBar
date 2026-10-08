#!/bin/sh
# Smoke test for install-cli.sh, run as root in a throwaway container:
#
#   install-script.sh [ARTIFACT_DIR]
#
# ARTIFACT_DIR (default /artifacts) holds the CLI tarball for this machine's
# architecture and its .sha256. Set INSTALL_CLI_TAG to also install that
# release tag from GitHub (for example cli-fork-f05433b).
set -eu

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source-path=SCRIPTDIR source=lib.sh
. "$here/lib.sh"
script="$here/../install-cli.sh"
checks="$here/cli-checks.sh"

install_runtime_deps
if command -v dnf >/dev/null 2>&1; then dnf install -y -q shadow-utils >/dev/null; fi
id tester >/dev/null 2>&1 || useradd -m tester
stage_artifacts "${1:-/artifacts}"
# A release directory also holds the tray tarballs, under the same
# -linux-<arch>.tar.gz suffix. Neither find_tarball nor install-cli.sh may
# take one for the CLI.
mkdir -p /tmp/tray
echo 'not the CLI' > /tmp/tray/codexbar-tray
tray="UsageBarTray-9.9.9-linux-$(uname -m).tar.gz"
tar -czf "/tmp/art/$tray" -C /tmp/tray codexbar-tray
(cd /tmp/art && sha256sum "$tray" > "$tray.sha256")
chmod a+r "/tmp/art/$tray" "/tmp/art/$tray.sha256"
tarball=$(find_tarball /tmp/art)
version=$(tarball_version "$tarball")
home=$(getent passwd tester | cut -d : -f 6)

as_tester() {
    su tester -s /bin/sh -c "cd && PATH=$home/.local/bin:/usr/local/bin:/usr/bin:/bin && $1"
}

say "per-user install, check, uninstall"
mkdir -p "$home/.local/bin"
echo keep > "$home/.local/bin/other-tool"
chown -R tester: "$home/.local"
before=$(snapshot "$home/.local")
as_tester "sh $script --tarball $tarball"
[ -L "$home/.local/bin/codexbar" ] || fail "no ~/.local/bin/codexbar symlink"
[ "$(stat -c %U "$home/.local/lib/usagebar-cli/CodexBarCLI")" = tester ] || fail "per-user files not owned by tester"
as_tester "sh $checks codexbar $version"
as_tester "sh $script --tarball $tarball"
as_tester "sh $checks codexbar $version"
as_tester "sh $script --uninstall"
assert_unchanged "$before" "$home/.local" "per-user uninstall left changes behind"

say "uninstall drops the directories the install created"
rm -rf "$home/.local"
before=$(snapshot "$home/.local")
as_tester "sh $script --tarball $tarball"
as_tester "sh $script --uninstall"
assert_unchanged "$before" "$home/.local" "uninstall left created directories behind"

say "a tampered tarball fails the checksum and installs nothing"
mkdir /tmp/bad
cp "$tarball" "$tarball.sha256" /tmp/bad/
printf 'x' >> "/tmp/bad/$(basename "$tarball")"
chmod -R a+rX /tmp/bad
before=$(snapshot "$home/.local")
if as_tester "sh $script --tarball /tmp/bad/$(basename "$tarball")" 2>/tmp/bad.err; then
    fail "tampered tarball installed"
fi
grep -q "checksum mismatch" /tmp/bad.err || fail "no checksum message: $(cat /tmp/bad.err)"
assert_unchanged "$before" "$home/.local" "tampered install changed files"

say "a codexbar the script didn't install is left alone"
mkdir -p "$home/.local/bin"
printf '#!/bin/sh\necho upstream\n' > "$home/.local/bin/codexbar"
chown -R tester: "$home/.local"
before=$(snapshot "$home/.local")
if as_tester "sh $script --tarball $tarball" 2>/tmp/foreign.err; then
    fail "install replaced a foreign codexbar"
fi
grep -q "wasn't installed by this script" /tmp/foreign.err || fail "no foreign-codexbar message"
assert_unchanged "$before" "$home/.local" "foreign codexbar case changed files"
[ "$(cat "$home/.local/bin/codexbar")" = "$(printf '#!/bin/sh\necho upstream')" ] || fail "foreign codexbar modified"
if as_tester "sh $script --uninstall" 2>/dev/null; then fail "uninstall claimed a foreign codexbar"; fi
rm -rf "$home/.local"

say "a system prefix needs privileges the script never takes itself"
before=$(snapshot /usr/local)
if as_tester "sh $script --system --tarball $tarball" 2>/tmp/sys.err; then
    fail "non-root --system install succeeded"
fi
grep -q "can't write" /tmp/sys.err || fail "no permission message: $(cat /tmp/sys.err)"
assert_unchanged "$before" /usr/local "failed --system install changed /usr/local"

say "system-prefix install as root, check, uninstall"
sh "$script" --system --tarball "$tarball"
[ "$(stat -c %U /usr/local/lib/usagebar-cli/CodexBarCLI)" = root ] || fail "system files not owned by root"
as_tester "sh $checks /usr/local/bin/codexbar $version"
sh "$script" --system --uninstall
assert_unchanged "$before" /usr/local "system uninstall left changes behind"

say "custom --prefix"
sh "$script" --prefix /opt/usagebar --tarball "$tarball"
sh "$checks" /opt/usagebar/bin/codexbar "$version"
sh "$script" --prefix /opt/usagebar --uninstall
[ ! -e /opt/usagebar ] || fail "custom prefix not removed"

# release_fixture TAG ASSET...: a release.json for TAG under /tmp/api listing
# ASSETs (in /tmp/art, in that order) as file:// downloads.
release_fixture() {
    dir=/tmp/api/repos/felipearosr/UsageBar/releases/tags
    mkdir -p "$dir"
    name=$1
    json="{\"tag_name\": \"$name\", \"assets\": ["
    shift
    sep=
    for asset in "$@"; do
        json="$json$sep{\"name\": \"$asset\", \"browser_download_url\": \"file:///tmp/art/$asset\"}"
        sep=', '
    done
    printf '%s]}\n' "$json" > "$dir/$name"
    chmod -R a+rX /tmp/api
}

say "a release download picks the CLI tarball, not the tray tarball listed before it"
tag=usagebar-v9.9.9
release_fixture "$tag" "$tray" "$tray.sha256" "$(basename "$tarball")" "$(basename "$tarball").sha256"
as_tester "USAGEBAR_API_URL=file:///tmp/api sh $script 9.9.9" > /tmp/fixture.out 2>&1 \
    || fail "install from the release fixture failed: $(cat /tmp/fixture.out)"
grep -q "Downloading file:///tmp/art/$(basename "$tarball")" /tmp/fixture.out \
    || fail "didn't download the CLI tarball: $(cat /tmp/fixture.out)"
as_tester "sh $checks codexbar $version"
as_tester "sh $script --uninstall"

say "a cli-fork-* release's CodexBarCLI-* tarball still installs"
legacy="CodexBarCLI-v0.68.0-fork.test-linux-$(uname -m).tar.gz"
cp "$tarball" "/tmp/art/$legacy"
(cd /tmp/art && sha256sum "$legacy" > "$legacy.sha256")
chmod a+r "/tmp/art/$legacy" "/tmp/art/$legacy.sha256"
tag=cli-fork-test
release_fixture "$tag" "$tray" "$legacy" "$legacy.sha256"
as_tester "USAGEBAR_API_URL=file:///tmp/api sh $script $tag" > /tmp/fixture.out 2>&1 \
    || fail "install of a CodexBarCLI-* release failed: $(cat /tmp/fixture.out)"
grep -q "Downloading file:///tmp/art/$legacy" /tmp/fixture.out \
    || fail "didn't download the CodexBarCLI tarball: $(cat /tmp/fixture.out)"
as_tester "sh $script --uninstall"

say "a release with only a tray tarball has no CLI to install"
tag=usagebar-v9.9.8
release_fixture "$tag" "$tray" "$tray.sha256"
if as_tester "USAGEBAR_API_URL=file:///tmp/api sh $script 9.9.8" > /tmp/fixture.out 2>&1; then
    fail "installed a tray tarball as the CLI"
fi
grep -q "has no CLI tarball for" /tmp/fixture.out || fail "no 'has no CLI tarball' message: $(cat /tmp/fixture.out)"

if [ -n "${INSTALL_CLI_TAG:-}" ]; then
    say "download and install release $INSTALL_CLI_TAG"
    as_tester "sh $script $INSTALL_CLI_TAG"
    tag_version=$(cat "$home/.local/lib/usagebar-cli/VERSION")
    as_tester "sh $checks codexbar $tag_version"
    as_tester "sh $script --uninstall"
fi

say "install-cli.sh smoke test passed ($version)"
