#!/bin/sh
# Install this fork's codexbar CLI (upstream plus `codexbar sync`) from a
# felipearosr/UsageBar release tarball, for distros without a package.
# Run with --help for usage.
#
# Files land in PREFIX/lib/usagebar-cli, with PREFIX/bin/codexbar linking to
# the binary. The script never asks for more privileges: for a prefix you
# can't write to, run it with sudo yourself. It never replaces a codexbar it
# didn't install.
set -eu
umask 022

REPO="${USAGEBAR_REPO:-felipearosr/UsageBar}"
MARKER=.usagebar-cli-install

say() { printf '%s\n' "$*"; }
die() { printf 'install-cli: %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<'EOF'
Usage: install-cli.sh [options] [VERSION|TAG]

Installs the UsageBar fork's codexbar CLI from a felipearosr/UsageBar release.
VERSION 1.0.1 means tag usagebar-v1.0.1; anything else is used as the tag.
Without one, the latest release is used.

  --prefix DIR     install under DIR (default: ~/.local)
  --system         same as --prefix /usr/local (run it with sudo yourself)
  --tarball FILE   install FILE instead of downloading (needs FILE.sha256)
  --uninstall      remove what this script installed under the prefix
EOF
}

prefix="${HOME:-}/.local"
action=install
tag=
tarball=
while [ $# -gt 0 ]; do
    case "$1" in
        --prefix) [ $# -ge 2 ] || die "--prefix needs a directory"; prefix=$2; shift 2 ;;
        --prefix=*) prefix=${1#--prefix=}; shift ;;
        --system) prefix=/usr/local; shift ;;
        --tarball) [ $# -ge 2 ] || die "--tarball needs a file"; tarball=$2; shift 2 ;;
        --tarball=*) tarball=${1#--tarball=}; shift ;;
        --uninstall) action=uninstall; shift ;;
        -h | --help) usage; exit 0 ;;
        -*) die "unknown option: $1 (see --help)" ;;
        *) [ -z "$tag" ] || die "only one version may be given"; tag=$1; shift ;;
    esac
done

case "$prefix" in
    /*) ;;
    *) die "the prefix must be an absolute path: $prefix" ;;
esac
prefix=${prefix%/}
libdir="$prefix/lib/usagebar-cli"
link="$prefix/bin/codexbar"

link_is_ours() {
    [ -L "$link" ] && [ "$(readlink "$link")" = "$libdir/CodexBarCLI" ]
}

# The closest existing ancestor of $1 must be writable, or nothing can be made.
check_writable() {
    dir=$1
    while [ ! -e "$dir" ]; do dir=$(dirname "$dir"); done
    [ -w "$dir" ] || die "can't write to $dir. Re-run with sudo (for example: sudo sh install-cli.sh --prefix $prefix), or pick a --prefix you own."
}

uninstall() {
    [ -f "$libdir/$MARKER" ] || die "nothing installed by this script under $prefix"
    check_writable "$libdir"
    if link_is_ours; then
        rm -f "$link"
    elif [ -e "$link" ] || [ -L "$link" ]; then
        say "Leaving $link alone: it wasn't installed by this script."
    fi
    created=$(sed -n 's/^created-dir=//p' "$libdir/$MARKER")
    rm -rf "$libdir"
    # Directories this script created, deepest first, only if now empty.
    printf '%s\n' "$created" | while IFS= read -r dir; do
        if [ -n "$dir" ]; then rmdir "$dir" 2>/dev/null || true; fi
    done
    say "Removed codexbar from $prefix."
}

if [ "$action" = uninstall ]; then
    uninstall
    exit 0
fi

# ---------- install ----------

if [ -e "$link" ] || [ -L "$link" ]; then
    link_is_ours || die "$link already exists and wasn't installed by this script (an upstream codexbar?). Remove it yourself, or install with a different --prefix."
fi
if [ -e "$libdir" ] && [ ! -f "$libdir/$MARKER" ]; then
    die "$libdir exists but wasn't installed by this script; not touching it."
fi
check_writable "$prefix/bin"
check_writable "$prefix/lib"

case "$(uname -m)" in
    x86_64 | amd64) arch=x86_64 ;;
    aarch64 | arm64) arch=aarch64 ;;
    *) die "no codexbar build for $(uname -m); only x86_64 and aarch64 are released" ;;
esac

work=$(mktemp -d "${TMPDIR:-/tmp}/usagebar-cli.XXXXXX")
trap 'rm -rf "$work"' EXIT
trap 'exit 130' INT TERM

fetch() {
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --retry 3 -o "$2" "$1"
    elif command -v wget >/dev/null 2>&1; then
        wget -q -O "$2" "$1"
    else
        die "need curl or wget to download"
    fi
}

if [ -n "$tarball" ]; then
    [ -f "$tarball" ] || die "no such file: $tarball"
    [ -f "$tarball.sha256" ] || die "missing $tarball.sha256 next to the tarball"
    archive="$work/$(basename "$tarball")"
    cp "$tarball" "$archive"
    cp "$tarball.sha256" "$archive.sha256"
else
    case "$tag" in
        '') api="https://api.github.com/repos/$REPO/releases/latest" ;;
        [0-9]*) api="https://api.github.com/repos/$REPO/releases/tags/usagebar-v$tag" ;;
        *) api="https://api.github.com/repos/$REPO/releases/tags/$tag" ;;
    esac
    fetch "$api" "$work/release.json" || die "couldn't read release ${tag:-latest} of $REPO"
    url=$(grep -o '"browser_download_url": *"[^"]*-linux-'"$arch"'\.tar\.gz"' "$work/release.json" \
        | sed 's/.*"\(https[^"]*\)"$/\1/' | head -n 1)
    [ -n "$url" ] || die "release ${tag:-latest} of $REPO has no CLI tarball for $arch"
    archive="$work/$(basename "$url")"
    say "Downloading $url"
    fetch "$url" "$archive" || die "download failed: $url"
    fetch "$url.sha256" "$archive.sha256" || die "download failed: $url.sha256"
fi

if command -v sha256sum >/dev/null 2>&1; then
    actual=$(sha256sum "$archive" | cut -d ' ' -f 1)
elif command -v shasum >/dev/null 2>&1; then
    actual=$(shasum -a 256 "$archive" | cut -d ' ' -f 1)
else
    die "need sha256sum or shasum to verify the download"
fi
expected=$(cut -d ' ' -f 1 "$archive.sha256" | head -n 1)
if [ -z "$expected" ] || [ "$actual" != "$expected" ]; then
    die "checksum mismatch for $(basename "$archive"); nothing was installed"
fi

stage="$work/stage"
mkdir "$stage"
tar -xzo -f "$archive" -C "$stage" || die "couldn't unpack $(basename "$archive")"
if [ ! -f "$stage/CodexBarCLI" ] || [ ! -x "$stage/CodexBarCLI" ] || [ ! -f "$stage/VERSION" ] \
    || [ ! -d "$stage/CodexBar_CodexBarCore.bundle" ]; then
    die "unexpected tarball layout; nothing was installed"
fi
"$stage/CodexBarCLI" --version >/dev/null 2>&1 \
    || die "the CLI doesn't run on this system (it needs glibc >= 2.38, libcurl, libsqlite3 and libstdc++); nothing was installed"

# Remember the directories this install creates so --uninstall can drop them.
created=
for dir in "$prefix/bin" "$prefix/lib" "$prefix"; do
    [ -e "$dir" ] || created="$created$dir
"
done
if [ -f "$libdir/$MARKER" ]; then
    created="$created$(sed -n 's/^created-dir=//p' "$libdir/$MARKER")"
fi
mkdir -p "$prefix/bin" "$prefix/lib"

new="$prefix/lib/.usagebar-cli.new.$$"
old="$prefix/lib/.usagebar-cli.old.$$"
rm -rf "$new" "$old"
mkdir "$new"
(cd "$stage" && tar -cf - .) | (cd "$new" && tar -xo -f -)
{
    say "# Written by install-cli.sh; --uninstall reads it."
    say "$created" | sed '/^$/d' | sort -ru | sed 's/^/created-dir=/'
} > "$new/$MARKER"
if [ -e "$libdir" ]; then mv "$libdir" "$old"; fi
mv "$new" "$libdir"
rm -rf "$old"
ln -sf "$libdir/CodexBarCLI" "$link"

version=$("$link" --version 2>/dev/null | sed 's/^CodexBar //')
say "Installed codexbar $version to $libdir"
say "  $link -> $libdir/CodexBarCLI"
case ":${PATH:-}:" in
    *":$prefix/bin:"*)
        found=$(command -v codexbar 2>/dev/null || true)
        if [ -n "$found" ] && [ "$found" != "$link" ]; then
            say "Note: $found comes first on PATH, so plain 'codexbar' runs that one."
        fi
        ;;
    *) say "Note: $prefix/bin is not on your PATH; add it to run 'codexbar'." ;;
esac
