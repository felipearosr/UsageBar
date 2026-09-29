#!/usr/bin/env bash
# Build the UsageBar .deb and .rpm: the GNOME extension plus the fork's
# codexbar CLI (with `codexbar sync`), so one package installs everything.
#
#   linux/packaging/build-packages.sh <CodexBarCLI-…-linux-ARCH.tar.gz> <version> [out-dir]
#
# ARCH comes from the tarball name (x86_64 or aarch64). Needs dpkg-deb,
# rpmbuild, glib-compile-schemas and python3. Writes usagebar_<v>_<arch>.deb,
# usagebar-<v>-1.<arch>.rpm and a .sha256 for each (names match updates.js).
set -euo pipefail

cli_tarball="$(realpath "$1")"
version="$2"
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
out="$(realpath -m "${3:-$repo/linux/dist}")"
uuid="usagebar@felipearosr.github.io"
maintainer="Felipe Aros <21047325+felipearosr@users.noreply.github.com>"
homepage="https://github.com/felipearosr/UsageBar"
summary="AI coding-provider usage limits in the GNOME top bar"

[[ "$version" =~ ^[0-9]+(\.[0-9]+)*$ ]] || { echo "bad version: $version" >&2; exit 1; }
case "$(basename "$cli_tarball")" in
    *-linux-x86_64.tar.gz) arch=x86_64; deb_arch=amd64 ;;
    *-linux-aarch64.tar.gz) arch=aarch64; deb_arch=arm64 ;;
    *) echo "unknown CLI tarball arch: $cli_tarball" >&2; exit 1 ;;
esac

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
root="$work/root"

# /usr/libexec/usagebar: the CLI exactly as released, plus the login helper.
libexec="$root/usr/libexec/usagebar"
mkdir -p "$libexec"
tar -xzf "$cli_tarball" -C "$libexec"
[[ -x "$libexec/CodexBarCLI" && -L "$libexec/codexbar" ]] || { echo "unexpected CLI tarball layout" >&2; exit 1; }
install -m 0755 "$repo/linux/packaging/usagebar-first-login" "$libexec/usagebar-first-login"
install -Dm 0644 "$repo/linux/packaging/usagebar-first-login.desktop" \
    "$root/etc/xdg/autostart/usagebar-first-login.desktop"

# The extension, stamped with the release version the updater compares.
ext="$root/usr/share/gnome-shell/extensions/$uuid"
mkdir -p "$ext"
src="$repo/linux/usagebar-gnome/$uuid"
cp -R "$src"/*.js "$src"/stylesheet.css "$src"/metadata.json "$src"/icons "$ext/"
mkdir -p "$ext/schemas"
cp "$src"/schemas/*.gschema.xml "$ext/schemas/"
glib-compile-schemas --strict "$ext/schemas"
python3 - "$ext/metadata.json" "$version" <<'PY'
import json, sys
path, version = sys.argv[1], sys.argv[2]
with open(path) as f:
    meta = json.load(f)
meta["version-name"] = version
with open(path, "w") as f:
    json.dump(meta, f, indent=2)
    f.write("\n")
PY
find "$root" -type d -exec chmod 0755 {} +
find "$ext" "$libexec/CodexBar_CodexBarCore.bundle" -type f -exec chmod 0644 {} +

mkdir -p "$out"
description="UsageBar shows how close you are to the usage limits of Claude, Codex and
other AI coding tools, right in the GNOME top bar: live chips, a popover
with per-window progress bars, reset countdowns, a cost dashboard and
quota notifications. Log out and back in once after installing.
Linux port of CodexBar by Peter Steinberger; includes its codexbar CLI."

# ---------- .deb ----------
deb_dir="$work/deb"
cp -a "$root" "$deb_dir"
mkdir -p "$deb_dir/DEBIAN"
installed_kb="$(du -sk "$root" | cut -f1)"
{
    echo "Package: usagebar"
    echo "Version: $version"
    echo "Architecture: $deb_arch"
    echo "Maintainer: $maintainer"
    echo "Installed-Size: $installed_kb"
    echo "Depends: gnome-shell (>= 46), gjs, libcurl4t64 | libcurl4, libsqlite3-0, libstdc++6, curl, pkexec | policykit-1"
    echo "Recommends: librsvg2-common"
    echo "Section: gnome"
    echo "Priority: optional"
    echo "Homepage: $homepage"
    echo "Description: $summary"
    sed 's/^/ /' <<< "$description"
} > "$deb_dir/DEBIAN/control"
deb="$out/usagebar_${version}_${deb_arch}.deb"
dpkg-deb --root-owner-group -Zxz --build "$deb_dir" "$deb" >/dev/null

# ---------- .rpm ----------
rpm_top="$work/rpmbuild"
mkdir -p "$rpm_top"/{SPECS,RPMS,BUILD}
cat > "$rpm_top/SPECS/usagebar.spec" <<SPEC
# Prebuilt payload: no debuginfo, no stripping or bytecompiling.
%global debug_package %{nil}
%global __os_install_post %{nil}
%global __requires_exclude_from ^/usr/share/gnome-shell/extensions/.*\$
# The CLI links against Debian's versioned libcurl symbols; Fedora's libcurl
# has no symbol versions (hence its harmless "no version information" warning).
%global __requires_exclude ^libcurl[.]so[.]4[(]CURL_OPENSSL_4[)]

Name:           usagebar
Version:        $version
Release:        1
Summary:        $summary
License:        MIT
URL:            $homepage
BuildArch:      $arch
Requires:       gnome-shell >= 46
Requires:       gjs
Requires:       curl
Requires:       libcurl
Requires:       polkit
Recommends:     librsvg2

%description
$description

%install
cp -a "$root/." %{buildroot}/

%files
/usr/libexec/usagebar
/usr/share/gnome-shell/extensions/$uuid
%config(noreplace) /etc/xdg/autostart/usagebar-first-login.desktop
SPEC
rpmbuild --quiet -bb --target "$arch" --define "_topdir $rpm_top" "$rpm_top/SPECS/usagebar.spec"
rpm="$out/usagebar-${version}-1.${arch}.rpm"
cp "$rpm_top/RPMS/$arch/usagebar-${version}-1.${arch}.rpm" "$rpm"

for f in "$deb" "$rpm"; do
    (cd "$out" && sha256sum "$(basename "$f")" > "$(basename "$f").sha256")
    echo "$f"
done
