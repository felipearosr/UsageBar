#!/bin/sh
# Smoke test for the usagebar-cli-bin PKGBUILD, run as root in a throwaway
# archlinux container:
#
#   aur.sh [ARTIFACT_DIR]
#
# ARTIFACT_DIR (default /artifacts) holds a CLI tarball for this machine's
# architecture. The test bumps a copy of the PKGBUILD to it with bump.sh
# --from, then runs makepkg -si, namcap, the shared CLI checks, and
# pacman -R.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source-path=SCRIPTDIR source=lib.sh
. "$here/lib.sh"
checks="$here/cli-checks.sh"
aur="$here/../aur"
pkgver=9.9.9

install_runtime_deps
pacman -S --noconfirm --needed --quiet base-devel namcap sudo >/dev/null
id builder >/dev/null 2>&1 || useradd -m builder
echo 'builder ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/builder
stage_artifacts "${1:-/artifacts}"
tarball=$(find_tarball /tmp/art)
version=$(tarball_version "$tarball")
arch=$(uname -m)
as_builder() { su builder -s /bin/sh -c "$1"; }

say "the committed .SRCINFO matches the committed PKGBUILD"
rm -rf /tmp/committed && cp -R "$aur" /tmp/committed && chown -R builder: /tmp/committed
as_builder "cd /tmp/committed && makepkg --printsrcinfo" > /tmp/srcinfo
diff -u "$aur/.SRCINFO" /tmp/srcinfo || fail ".SRCINFO is stale; run bump.sh or makepkg --printsrcinfo"

say "bump a copy of the PKGBUILD to the test tarball"
from=/tmp/from
pkg=/tmp/pkg
rm -rf "$from" "$pkg"
mkdir -p "$from"
cp "$tarball" "$from/usagebar-cli-$pkgver-linux-$arch.tar.gz"
(cd "$from" && sha256sum "usagebar-cli-$pkgver-linux-$arch.tar.gz" > "usagebar-cli-$pkgver-linux-$arch.tar.gz.sha256")
for other in x86_64 aarch64; do
    [ -f "$from/usagebar-cli-$pkgver-linux-$other.tar.gz.sha256" ] \
        || printf '%064d  stand-in\n' 0 > "$from/usagebar-cli-$pkgver-linux-$other.tar.gz.sha256"
done
cp "$here/../../../LICENSE" "$from/LICENSE"
cp -R "$aur" "$pkg"
chown -R builder: "$from" "$pkg"
as_builder "sh $pkg/bump.sh $pkgver --from $from"
grep -qx "pkgver=$pkgver" "$pkg/PKGBUILD" || fail "bump.sh didn't set pkgver"
grep -q "pkgver = $pkgver" "$pkg/.SRCINFO" || fail "bump.sh didn't regenerate .SRCINFO"
# makepkg uses sources already in the build directory instead of downloading.
cp "$from/usagebar-cli-$pkgver-linux-$arch.tar.gz" "$pkg/"
cp "$from/LICENSE" "$pkg/LICENSE-$pkgver"
chown -R builder: "$pkg"

say "namcap on the PKGBUILD"
namcap "$pkg/PKGBUILD" | tee /tmp/namcap.pkgbuild
grep -q ' E: ' /tmp/namcap.pkgbuild && fail "namcap reported errors on the PKGBUILD"

say "makepkg -si, check through the PATH symlink"
before_usr=$(snapshot /usr)
before_etc=$(snapshot /etc)
as_builder "cd $pkg && makepkg -si --noconfirm"
set -- "$pkg"/usagebar-cli-bin-"$pkgver"-1-"$arch".pkg.tar.*
[ -f "$1" ] || fail "makepkg built no package"
built=$1
[ "$(readlink -f /usr/bin/codexbar)" = /usr/lib/usagebar-cli/CodexBarCLI ] || fail "/usr/bin/codexbar doesn't link to the CLI"
[ -f /usr/share/licenses/usagebar-cli-bin/LICENSE ] || fail "no LICENSE"
sh "$checks" codexbar "$version"

say "namcap on the package"
namcap "$built" | tee /tmp/namcap.pkg
grep -q ' E: ' /tmp/namcap.pkg && fail "namcap reported errors on the package"

say "pacman -R leaves no files behind"
pacman -R --noconfirm usagebar-cli-bin >/dev/null
assert_unchanged "$before_usr" /usr "pacman -R left files under /usr"
assert_unchanged "$before_etc" /etc "pacman -R left files under /etc"

say "a tampered tarball fails makepkg's checksum"
printf 'x' >> "$pkg/usagebar-cli-$pkgver-linux-$arch.tar.gz"
if as_builder "cd $pkg && makepkg -f --noconfirm" >/dev/null 2>&1; then fail "makepkg accepted a tampered tarball"; fi

say "conflicts with another codexbar package"
fake=/tmp/fake-codexbar
rm -rf "$fake" && mkdir -p "$fake"
cat > "$fake/PKGBUILD" <<'EOF'
pkgname=codexbar
pkgver=1.0
pkgrel=1
pkgdesc="stand-in upstream codexbar"
arch=('any')
license=('MIT')
package() {
    install -d "$pkgdir/usr/bin"
    printf '#!/bin/sh\necho upstream\n' > "$pkgdir/usr/bin/codexbar"
    chmod 0755 "$pkgdir/usr/bin/codexbar"
}
EOF
chown -R builder: "$fake"
as_builder "cd $fake && makepkg --noconfirm" >/dev/null
pacman -U --noconfirm "$fake"/codexbar-1.0-1-any.pkg.tar.* >/dev/null
if pacman -U --noconfirm "$built" >/dev/null 2>&1; then fail "usagebar-cli-bin installed next to codexbar"; fi
[ "$(/usr/bin/codexbar)" = upstream ] || fail "the other codexbar was modified"
pacman -R --noconfirm codexbar >/dev/null

say "usagebar-cli-bin PKGBUILD smoke test passed ($version)"
