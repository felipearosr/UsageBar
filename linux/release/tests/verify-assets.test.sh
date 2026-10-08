#!/usr/bin/env bash
# Tests for linux/release/verify-assets.sh: a fixture asset directory that
# passes, then one mutation per failure mode, each of which must fail with
# its own message.
#
#   linux/release/tests/verify-assets.test.sh
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
verifier=$here/../verify-assets.sh
resolver=$here/../resolve-version.sh
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0

pass() { printf 'ok   %s\n' "$1"; }
flunk() { printf 'FAIL %s\n' "$1" >&2; failures=$((failures + 1)); }

printf 'USAGEBAR_VERSION=1.1.0\nUPSTREAM_BASE=0.69.0\n' > "$work/meta.env"
"$resolver" --metadata "$work/meta.env" usagebar-v1.1.0 > "$work/resolved"
cli_version=0.69.0+usagebar.1.1.0

# A stand-in CodexBarCLI: just an ELF header with the arch's e_machine.
fake_elf() { # fake_elf PATH ARCH
    printf '\177ELF\002\001\001\000\000\000\000\000\000\000\000\000\002\000' > "$1"
    case "$2" in
        x86_64) printf '\076\000' >> "$1" ;;
        aarch64) printf '\267\000' >> "$1" ;;
    esac
    chmod 0755 "$1"
}

# make_cli_tarball OUT_DIR ARCH [VERSION] [MUTATION]: a CLI tarball in
# upstream's layout plus its .sha256. MUTATION drops or breaks one part.
make_cli_tarball() {
    local out=$1 arch=$2 version=${3:-$cli_version} mutation=${4:-} stage name
    stage=$(mktemp -d "$work/stage.XXXXXX")
    fake_elf "$stage/CodexBarCLI" "$arch"
    ln -s CodexBarCLI "$stage/codexbar"
    printf '%s\n' "$version" > "$stage/VERSION"
    mkdir -p "$stage/CodexBar_CodexBarCore.bundle/plugins"
    echo '// prelude' > "$stage/CodexBar_CodexBarCore.bundle/provider-plugin-prelude.js"
    echo '{}' > "$stage/CodexBar_CodexBarCore.bundle/plugins/manifest.json"
    case "$mutation" in
        no-bundle) rm -rf "$stage/CodexBar_CodexBarCore.bundle" ;;
        empty-bundle) rm -rf "$stage/CodexBar_CodexBarCore.bundle"/* ;;
        no-symlink) rm "$stage/codexbar" ;;
        bad-symlink) rm "$stage/codexbar" && ln -s VERSION "$stage/codexbar" ;;
        no-version) rm "$stage/VERSION" ;;
        not-executable) chmod 0644 "$stage/CodexBarCLI" ;;
        extra-entry) echo hi > "$stage/README" ;;
        wrong-arch) fake_elf "$stage/CodexBarCLI" "$([[ $arch == x86_64 ]] && echo aarch64 || echo x86_64)" ;;
        not-elf) printf '#!/bin/sh\n' > "$stage/CodexBarCLI" ;;
    esac
    name="usagebar-cli-1.1.0-linux-$arch.tar.gz"
    (cd "$stage" && tar -czf "$out/$name" -- *)
    (cd "$out" && sha256sum "$name" > "$name.sha256")
    rm -rf "$stage"
}

# make_tray_tarball OUT_DIR ARCH [VERSION] [MUTATION]: a tray tarball in the
# release layout plus its .sha256. Its codexbar-tray is a stand-in ELF that
# carries the --version line, as the real binary does.
make_tray_tarball() {
    local out=$1 arch=$2 version=${3:-1.1.0} mutation=${4:-} stage name top
    name="UsageBarTray-1.1.0-linux-$arch.tar.gz"
    top=${name%.tar.gz}
    stage=$(mktemp -d "$work/stage.XXXXXX")
    mkdir "$stage/$top"
    fake_elf "$stage/$top/codexbar-tray" "$arch"
    printf 'codexbar-tray %s\n' "$version" >> "$stage/$top/codexbar-tray"
    echo MIT > "$stage/$top/LICENSE"
    echo '# tray' > "$stage/$top/README.md"
    case "$mutation" in
        no-license) rm "$stage/$top/LICENSE" ;;
        no-binary) rm "$stage/$top/codexbar-tray" ;;
        not-executable) chmod 0644 "$stage/$top/codexbar-tray" ;;
        wrong-arch) fake_elf "$stage/$top/codexbar-tray" "$([[ $arch == x86_64 ]] && echo aarch64 || echo x86_64)"
            printf 'codexbar-tray %s\n' "$version" >> "$stage/$top/codexbar-tray" ;;
        extra-entry) echo hi > "$stage/$top/notes.txt" ;;
    esac
    if [[ "$mutation" == flat ]]; then
        (cd "$stage/$top" && tar -czf "$out/$name" -- *)
    else
        (cd "$stage" && tar -czf "$out/$name" "$top")
    fi
    (cd "$out" && sha256sum "$name" > "$name.sha256")
    rm -rf "$stage"
}

# The real extension zip, built once with the release's version-name.
ext=usagebar@felipearosr.github.io-1.1.0.shell-extension.zip
"$here/../package-extension.sh" 1.1.0 "$work/ext" "$ext" > /dev/null 2> "$work/ext.log" \
    || { cat "$work/ext.log" >&2; echo "could not build the extension zip" >&2; exit 1; }

# The real logo pack.
logos=usagebar-provider-icons-1.1.0.json
"$here/../package-logos.sh" 1.1.0 "$work/logos" "$logos" > /dev/null 2> "$work/logos.log" \
    || { cat "$work/logos.log" >&2; echo "could not build the logo pack" >&2; exit 1; }

# repack_logos DIR PYTHON: rewrites DIR's logo pack; PYTHON edits `pack`.
repack_logos() {
    python3 - "$1/$logos" "$2" <<'PY'
import json, sys
path, change = sys.argv[1:]
with open(path) as f:
    pack = json.load(f)
exec(change)
with open(path, 'w') as f:
    json.dump(pack, f)
PY
    (cd "$1" && sha256sum "$logos" > "$logos.sha256")
}

# rezip_extension DIR CHANGE: rewrites DIR's extension zip with one change:
# drop=PATH removes an entry, meta=JSON merges keys into metadata.json.
rezip_extension() {
    python3 - "$1/$ext" "$2" <<'PY'
import json, sys, zipfile
path, change = sys.argv[1:]
kind, _, arg = change.partition('=')
with zipfile.ZipFile(path) as zf:
    files = {n: zf.read(n) for n in zf.namelist()}
if kind == 'drop':
    files = {n: d for n, d in files.items() if not (n == arg or n.startswith(arg + '/'))}
elif kind == 'meta':
    meta = json.loads(files['metadata.json'])
    meta.update(json.loads(arg))
    files['metadata.json'] = json.dumps(meta).encode()
with zipfile.ZipFile(path, 'w') as zf:
    for name, data in files.items():
        zf.writestr(name, data)
PY
    (cd "$1" && sha256sum "$ext" > "$ext.sha256")
}

# A passing release directory: both CLI tarballs, both tray tarballs, the
# extension zip, plus a package the verifier doesn't know by name (it must
# still have a valid checksum).
make_release() { # make_release DIR
    mkdir -p "$1"
    make_cli_tarball "$1" x86_64
    make_cli_tarball "$1" aarch64
    make_tray_tarball "$1" x86_64
    make_tray_tarball "$1" aarch64
    cp "$work/ext/$ext" "$work/ext/$ext.sha256" "$1/"
    cp "$work/logos/$logos" "$work/logos/$logos.sha256" "$1/"
    echo 'deb' > "$1/usagebar_1.1.0_amd64.deb"
    (cd "$1" && sha256sum usagebar_1.1.0_amd64.deb > usagebar_1.1.0_amd64.deb.sha256)
}

fixture() { # fixture -> a fresh passing release dir
    local d
    d=$(mktemp -d "$work/release.XXXXXX")
    make_release "$d"
    printf '%s\n' "$d"
}

expect_pass() { # expect_pass NAME DIR
    if "$verifier" "$work/resolved" "$2" > "$work/out" 2>&1; then
        pass "$1"
    else
        flunk "$1: $(cat "$work/out")"
    fi
}

expect_fail() { # expect_fail NAME DIR MESSAGE-SUBSTRING
    local status=0
    "$verifier" "$work/resolved" "$2" > "$work/out" 2>&1 || status=$?
    if [[ $status -ne 1 ]]; then
        flunk "$1: expected exit 1, got $status: $(cat "$work/out")"
    elif ! grep -Fq -- "$3" "$work/out"; then
        flunk "$1: output lacks '$3': $(cat "$work/out")"
    else
        pass "$1"
    fi
}

x86=usagebar-cli-1.1.0-linux-x86_64.tar.gz
arm=usagebar-cli-1.1.0-linux-aarch64.tar.gz

expect_pass "complete release passes" "$(fixture)"

d=$(fixture); rm "$d/$x86" "$d/$x86.sha256"
expect_fail "missing x86_64 CLI tarball" "$d" "missing asset: $x86"
d=$(fixture); rm "$d/$arm" "$d/$arm.sha256"
expect_fail "missing aarch64 CLI tarball" "$d" "missing asset: $arm"

d=$(fixture); printf '%064d  %s\n' 0 "$x86" > "$d/$x86.sha256"
expect_fail "bad checksum" "$d" "checksum mismatch: $x86"
d=$(fixture); printf 'x' >> "$d/usagebar_1.1.0_amd64.deb"
expect_fail "bad checksum on another asset" "$d" "checksum mismatch: usagebar_1.1.0_amd64.deb"
d=$(fixture); rm "$d/$x86.sha256"
expect_fail "missing .sha256" "$d" "no checksum: $x86.sha256"
d=$(fixture); rm "$d/usagebar_1.1.0_amd64.deb"
expect_fail "orphan .sha256" "$d" "checksum without its asset: usagebar_1.1.0_amd64.deb.sha256"
d=$(fixture); (cd "$d" && sha256sum "$PWD/$x86" > "$x86.sha256")
expect_fail ".sha256 with a path" "$d" "expected the bare file name"
d=$(fixture); echo 'not a checksum' > "$d/$x86.sha256"
expect_fail "malformed .sha256" "$d" "$x86.sha256 isn't one"

d=$(fixture); make_cli_tarball "$d" x86_64 0.69.0
expect_fail "wrong VERSION" "$d" "VERSION says '0.69.0', expected '$cli_version'"
d=$(fixture); make_cli_tarball "$d" x86_64 "" no-version
expect_fail "missing VERSION" "$d" "$x86: no VERSION file"
d=$(fixture); make_cli_tarball "$d" aarch64 "" no-bundle
expect_fail "missing resource bundle" "$d" "$arm: no CodexBar_CodexBarCore.bundle resources"
d=$(fixture); make_cli_tarball "$d" aarch64 "" empty-bundle
expect_fail "empty resource bundle" "$d" "$arm: no CodexBar_CodexBarCore.bundle resources"
d=$(fixture); make_cli_tarball "$d" x86_64 "" no-symlink
expect_fail "missing codexbar symlink" "$d" "$x86: no codexbar symlink"
d=$(fixture); make_cli_tarball "$d" x86_64 "" bad-symlink
expect_fail "codexbar symlink to the wrong target" "$d" "codexbar must be a symlink to CodexBarCLI"
d=$(fixture); make_cli_tarball "$d" x86_64 "" not-executable
expect_fail "CodexBarCLI not executable" "$d" "CodexBarCLI isn't executable"
d=$(fixture); make_cli_tarball "$d" x86_64 "" extra-entry
expect_fail "unexpected tarball entry" "$d" "unexpected entry 'README'"
d=$(fixture); make_cli_tarball "$d" x86_64 "" wrong-arch
expect_fail "binary for the wrong arch" "$d" "$x86: CodexBarCLI isn't built for x86_64"
d=$(fixture); make_cli_tarball "$d" aarch64 "" not-elf
expect_fail "binary isn't ELF" "$d" "$arm: CodexBarCLI isn't an ELF binary"
d=$(fixture); echo junk > "$d/$x86"; (cd "$d" && sha256sum "$x86" > "$x86.sha256")
expect_fail "tarball isn't a tarball" "$d" "$x86: not a readable .tar.gz"

d=$(fixture); cp "$d/$x86" "$d/usagebar-cli-1.0.0-linux-x86_64.tar.gz"
(cd "$d" && sha256sum usagebar-cli-1.0.0-linux-x86_64.tar.gz > usagebar-cli-1.0.0-linux-x86_64.tar.gz.sha256)
expect_fail "stale-version asset name" "$d" "unexpected asset name: usagebar-cli-1.0.0-linux-x86_64.tar.gz"

d=$(fixture); rm "$d/$ext" "$d/$ext.sha256"
expect_fail "missing extension zip" "$d" "missing asset: $ext"
d=$(fixture); rezip_extension "$d" drop=schemas
expect_fail "extension zip without the settings schema" "$d" \
    "$ext: no settings schema XML (schemas/org.gnome.shell.extensions.usagebar.gschema.xml)"
d=$(fixture); rezip_extension "$d" 'meta={"version-name": "1.0.0"}'
expect_fail "extension zip with a wrong version-name" "$d" \
    "$ext: metadata.json version-name is '1.0.0', expected '1.1.0'"
d=$(fixture); rezip_extension "$d" 'meta={"version-name": null}'
expect_fail "extension zip without a version-name" "$d" "metadata.json version-name is 'None', expected '1.1.0'"
d=$(fixture); rezip_extension "$d" 'meta={"uuid": "codexbar@example.com"}'
expect_fail "extension zip with another UUID" "$d" \
    "metadata.json uuid is 'codexbar@example.com', expected 'usagebar@felipearosr.github.io'"
d=$(fixture); rezip_extension "$d" drop=extension.js
expect_fail "extension zip without extension.js" "$d" "$ext: no extension.js"
d=$(fixture); rezip_extension "$d" drop=prefs.js
expect_fail "extension zip without prefs.js" "$d" "$ext: no prefs.js"
d=$(fixture); rezip_extension "$d" drop=icons
expect_fail "extension zip without icons" "$d" "$ext: no icons"
d=$(fixture); rezip_extension "$d" 'meta={"version": 7}'
expect_fail "extension zip failing the EGO lint" "$d" "$ext: fails the extensions.gnome.org lint"
d=$(fixture); echo junk > "$d/$ext"; (cd "$d" && sha256sum "$ext" > "$ext.sha256")
expect_fail "extension zip isn't a zip" "$d" "$ext: not a readable zip"
d=$(fixture); old=usagebar@felipearosr.github.io-1.0.0.shell-extension.zip
cp "$d/$ext" "$d/$old"; (cd "$d" && sha256sum "$old" > "$old.sha256")
expect_fail "stale-version extension zip name" "$d" "unexpected asset name: $old"

d=$(fixture); rm "$d/$logos" "$d/$logos.sha256"
expect_fail "missing logo pack" "$d" "missing asset: $logos"
d=$(fixture); repack_logos "$d" "pack['version'] = '1.0.0'"
expect_fail "logo pack for another version" "$d" "$logos: the extension would reject it: the logo pack is for version 1.0.0"
d=$(fixture); repack_logos "$d" "pack['icons']['claude'] = '<svg><script/></svg>'"
expect_fail "logo pack with an unsafe SVG" "$d" "$logos: the extension would reject it: the claude logo"
d=$(fixture); repack_logos "$d" "pack['icons'] = {}"
expect_fail "empty logo pack" "$d" "$logos: the extension would reject it: the logo pack has 0 logos"
d=$(fixture); old=usagebar-provider-icons-1.0.0.json
cp "$d/$logos" "$d/$old"; (cd "$d" && sha256sum "$old" > "$old.sha256")
expect_fail "stale-version logo pack name" "$d" "unexpected asset name: $old"

tray_x86=UsageBarTray-1.1.0-linux-x86_64.tar.gz
tray_arm=UsageBarTray-1.1.0-linux-aarch64.tar.gz
d=$(fixture); rm "$d/$tray_x86" "$d/$tray_x86.sha256"
expect_fail "missing x86_64 tray tarball" "$d" "missing asset: $tray_x86"
d=$(fixture); rm "$d/$tray_arm" "$d/$tray_arm.sha256"
expect_fail "missing aarch64 tray tarball" "$d" "missing asset: $tray_arm"
d=$(fixture); make_tray_tarball "$d" x86_64 1.0.0
expect_fail "tray reporting another version" "$d" "$tray_x86: codexbar-tray doesn't report version 1.1.0"
d=$(fixture); make_tray_tarball "$d" x86_64 1.1.0-rc.1
expect_fail "tray version must match exactly" "$d" "$tray_x86: codexbar-tray doesn't report version 1.1.0"
d=$(fixture); make_tray_tarball "$d" aarch64 "" wrong-arch
expect_fail "tray binary for the wrong arch" "$d" "$tray_arm: codexbar-tray isn't built for aarch64"
d=$(fixture); make_tray_tarball "$d" x86_64 "" not-executable
expect_fail "tray binary not executable" "$d" "$tray_x86: codexbar-tray isn't executable"
d=$(fixture); make_tray_tarball "$d" x86_64 "" no-binary
expect_fail "tray tarball without the binary" "$d" "$tray_x86: no UsageBarTray-1.1.0-linux-x86_64/codexbar-tray"
d=$(fixture); make_tray_tarball "$d" x86_64 "" no-license
expect_fail "tray tarball without LICENSE" "$d" "$tray_x86: no UsageBarTray-1.1.0-linux-x86_64/LICENSE"
d=$(fixture); make_tray_tarball "$d" x86_64 "" extra-entry
expect_fail "unexpected tray tarball entry" "$d" "unexpected entry 'UsageBarTray-1.1.0-linux-x86_64/notes.txt'"
d=$(fixture); make_tray_tarball "$d" x86_64 "" flat
expect_fail "tray tarball without its directory" "$d" "$tray_x86: unexpected entry 'codexbar-tray'"
d=$(fixture); echo junk > "$d/$tray_arm"; (cd "$d" && sha256sum "$tray_arm" > "$tray_arm.sha256")
expect_fail "tray tarball isn't a tarball" "$d" "$tray_arm: not a readable .tar.gz"
d=$(fixture); old=UsageBarTray-1.0.0-linux-x86_64.tar.gz
cp "$d/$tray_x86" "$d/$old"; (cd "$d" && sha256sum "$old" > "$old.sha256")
expect_fail "stale-version tray tarball name" "$d" "unexpected asset name: $old"

d=$(fixture); rm "$d/$x86" "$d/$x86.sha256"; printf '%064d  %s\n' 0 "$arm" > "$d/$arm.sha256"
"$verifier" "$work/resolved" "$d" > "$work/out" 2>&1 || true
if grep -Fq "missing asset: $x86" "$work/out" && grep -Fq "checksum mismatch: $arm" "$work/out" \
    && grep -Fq "2 problem(s)" "$work/out"; then
    pass "reports every problem, not just the first"
else
    flunk "multiple problems: $(cat "$work/out")"
fi

# The resolver's values decide what's expected: a pre-release wants its own names.
printf 'USAGEBAR_VERSION=1.2.0-rc.1\nUPSTREAM_BASE=0.69.0\n' > "$work/rc.env"
"$resolver" --metadata "$work/rc.env" > "$work/resolved-rc"
d=$(fixture)
if "$verifier" "$work/resolved-rc" "$d" > "$work/out" 2>&1; then
    flunk "a 1.1.0 release passed as 1.2.0-rc.1"
elif grep -Fq "missing asset: usagebar-cli-1.2.0-rc.1-linux-x86_64.tar.gz" "$work/out"; then
    pass "expected names follow the resolved version"
else
    flunk "pre-release names: $(cat "$work/out")"
fi

status=0
"$verifier" "$work/resolved" > /dev/null 2>&1 || status=$?
if [[ $status -eq 2 ]]; then pass "missing argument is a usage error"; else flunk "usage exited $status"; fi
printf 'tag=usagebar-v1.1.0\n' > "$work/partial"
status=0
"$verifier" "$work/partial" "$(fixture)" > "$work/out" 2>&1 || status=$?
if [[ $status -eq 2 ]] && grep -Fq "has no version" "$work/out"; then
    pass "incomplete resolved values are rejected"
else
    flunk "partial resolved values: status $status: $(cat "$work/out")"
fi

if ((failures)); then
    printf '%d verifier test(s) failed\n' "$failures" >&2
    exit 1
fi
echo "Release asset verifier tests passed."
