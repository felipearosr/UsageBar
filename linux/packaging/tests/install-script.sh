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

if [ -n "${INSTALL_CLI_TAG:-}" ]; then
    say "download and install release $INSTALL_CLI_TAG"
    as_tester "sh $script $INSTALL_CLI_TAG"
    tag_version=$(cat "$home/.local/lib/usagebar-cli/VERSION")
    as_tester "sh $checks codexbar $tag_version"
    as_tester "sh $script --uninstall"
fi

say "install-cli.sh smoke test passed ($version)"
