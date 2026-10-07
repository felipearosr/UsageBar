#!/bin/sh
# Smoke test for the usagebar-cli .deb, run as root in a throwaway Debian or
# Ubuntu container:
#
#   deb.sh [ARTIFACT_DIR]
#
# ARTIFACT_DIR (default /artifacts) holds usagebar-cli_*_<arch>.deb and the
# CLI tarball it was built from (for the expected version).
set -eu

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source-path=SCRIPTDIR source=lib.sh
. "$here/lib.sh"
checks="$here/cli-checks.sh"

install_runtime_deps
stage_artifacts "${1:-/artifacts}"
version=$(tarball_version "$(find_tarball /tmp/art)")
deb_arch=$(dpkg --print-architecture)
set -- /tmp/art/usagebar-cli_*_"$deb_arch".deb
if [ $# -ne 1 ] || [ ! -f "$1" ]; then fail "expected exactly one usagebar-cli_*_$deb_arch.deb"; fi
deb=$1

say "install, check through the PATH symlink"
before_usr=$(snapshot /usr)
before_etc=$(snapshot /etc)
apt-get install -y -qq "$deb" >/dev/null
[ "$(readlink -f /usr/bin/codexbar)" = /usr/lib/usagebar-cli/CodexBarCLI ] || fail "/usr/bin/codexbar doesn't link to the CLI"
[ -f /usr/share/doc/usagebar-cli/copyright ] || fail "no LICENSE in the docs directory"
sh "$checks" codexbar "$version"

say "apt remove leaves no files behind"
apt-get remove -y -qq usagebar-cli >/dev/null
assert_unchanged "$before_usr" /usr "apt remove left files under /usr"
assert_unchanged "$before_etc" /etc "apt remove left files under /etc"
dpkg -s usagebar-cli >/dev/null 2>&1 && fail "usagebar-cli still known to dpkg after remove"

say "conflicts with another codexbar package"
fake=/tmp/fake-codexbar
mkdir -p "$fake/DEBIAN" "$fake/usr/bin"
printf '#!/bin/sh\necho upstream\n' > "$fake/usr/bin/codexbar"
chmod 0755 "$fake/usr/bin/codexbar"
printf 'Package: codexbar\nVersion: 1.0\nArchitecture: all\nMaintainer: test <t@example.com>\nDescription: stand-in upstream codexbar\n' \
    > "$fake/DEBIAN/control"
dpkg-deb --root-owner-group --build "$fake" /tmp/codexbar.deb >/dev/null
dpkg -i /tmp/codexbar.deb >/dev/null
if dpkg -i "$deb" >/dev/null 2>&1; then fail "usagebar-cli installed next to codexbar"; fi
[ "$(cat /usr/bin/codexbar)" = "$(printf '#!/bin/sh\necho upstream')" ] || fail "the other codexbar was modified"
dpkg -r codexbar >/dev/null

say "usagebar-cli .deb smoke test passed ($version, $(sed -n 's/^PRETTY_NAME=//p' /etc/os-release | tr -d '"'))"
