#!/bin/sh
# Smoke test for the usagebar-cli RPM, run as root in a throwaway Fedora
# container:
#
#   rpm.sh [ARTIFACT_DIR]
#
# ARTIFACT_DIR (default /artifacts) holds usagebar-cli-*.<arch>.rpm and the CLI
# tarball it was built from (for the expected version). When the SRPM is
# there too, it is rebuilt the way COPR would and the result checked as well.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source-path=SCRIPTDIR source=lib.sh
. "$here/lib.sh"
checks="$here/cli-checks.sh"

install_runtime_deps
stage_artifacts "${1:-/artifacts}"
version=$(tarball_version "$(find_tarball /tmp/art)")
arch=$(uname -m)
set -- /tmp/art/usagebar-cli-*."$arch".rpm
if [ $# -ne 1 ] || [ ! -f "$1" ]; then fail "expected exactly one usagebar-cli-*.$arch.rpm"; fi
rpm=$1

check_package() {
    before_usr=$(snapshot /usr)
    before_etc=$(snapshot /etc)
    dnf install -y -q "$1" >/dev/null
    [ "$(readlink -f /usr/bin/codexbar)" = /usr/lib/usagebar-cli/CodexBarCLI ] || fail "/usr/bin/codexbar doesn't link to the CLI"
    # Container images may skip installing docs, so ask the package itself.
    rpm -qL usagebar-cli | grep -qx /usr/share/licenses/usagebar-cli/LICENSE || fail "no LICENSE"
    sh "$checks" codexbar "$version"
    dnf remove -y -q usagebar-cli >/dev/null
    assert_unchanged "$before_usr" /usr "dnf remove left files under /usr"
    assert_unchanged "$before_etc" /etc "dnf remove left files under /etc"
    if rpm -q usagebar-cli >/dev/null 2>&1; then fail "usagebar-cli still installed"; fi
}

say "install, check through the PATH symlink, dnf remove leaves nothing"
check_package "$rpm"

say "conflicts with another codexbar package"
dnf install -y -q rpm-build >/dev/null
mkdir -p /tmp/fake/SPECS
cat > /tmp/fake/SPECS/codexbar.spec <<'EOF'
Name: codexbar
Version: 1.0
Release: 1
Summary: stand-in upstream codexbar
License: MIT
BuildArch: noarch
%description
stand-in
%install
mkdir -p %{buildroot}/usr/bin
printf '#!/bin/sh\necho upstream\n' > %{buildroot}/usr/bin/codexbar
chmod 0755 %{buildroot}/usr/bin/codexbar
%files
/usr/bin/codexbar
EOF
rpmbuild --quiet -bb --define "_topdir /tmp/fake" /tmp/fake/SPECS/codexbar.spec
rpm -i /tmp/fake/RPMS/noarch/codexbar-1.0-1.noarch.rpm
if rpm -i "$rpm" >/dev/null 2>&1; then fail "usagebar-cli installed next to codexbar"; fi
[ "$(/usr/bin/codexbar)" = upstream ] || fail "the other codexbar was modified"
rpm -e codexbar

set -- /tmp/art/usagebar-cli-*.src.rpm
if [ -f "$1" ]; then
    say "rebuild the SRPM as COPR would"
    dnf install -y -q libcurl sqlite-libs libstdc++ >/dev/null
    rm -rf /tmp/rebuild
    rpmbuild --quiet --rebuild --define "_topdir /tmp/rebuild" "$1"
    set -- /tmp/rebuild/RPMS/"$arch"/usagebar-cli-*.rpm
    check_package "$1"
fi

say "usagebar-cli RPM smoke test passed ($version, $(sed -n 's/^PRETTY_NAME=//p' /etc/os-release | tr -d '"'))"
