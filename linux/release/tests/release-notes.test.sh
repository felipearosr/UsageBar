#!/usr/bin/env bash
# Tests for linux/release/release-notes.sh: notes for a final release, a
# pre-release and a first release, built from a scratch git repository with
# PR merge commits and usagebar-v* tags.
#
#   linux/release/tests/release-notes.test.sh
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
notes=$here/../release-notes.sh
resolver=$here/../resolve-version.sh
install_md=$here/../../INSTALL.md
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0

pass() { printf 'ok   %s\n' "$1"; }
flunk() { printf 'FAIL %s\n' "$1" >&2; failures=$((failures + 1)); }

# Scratch history: 1.0.0, a PR, 1.1.0-rc.1, another PR and a direct commit.
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
git_() { git -C "$work/repo" -c init.defaultBranch=main -c commit.gpgsign=false -c tag.gpgsign=false "$@"; }
mkdir "$work/repo"
git_ init -q
merge_pr() { # merge_pr NUMBER TITLE
    git_ checkout -q -b "pr-$1"
    git_ commit -q --allow-empty -m "work for $1"
    git_ checkout -q main
    git_ merge -q --no-ff "pr-$1" -m "Merge pull request #$1 from felipearosr/pr-$1" -m "$2"
}
git_ commit -q --allow-empty -m "Initial"
git_ tag usagebar-v1.0.0
merge_pr 101 "Release: GNOME extension zip"
git_ tag usagebar-v1.1.0-rc.1
merge_pr 102 "Release: tray app for x86_64 and aarch64"
git_ commit -q --allow-empty -m "Fix a typo"

resolve() { # resolve VERSION -> resolved values file
    local file=$work/resolved-$1
    printf 'USAGEBAR_VERSION=%s\nUPSTREAM_BASE=0.72.0\n' "$1" > "$work/meta-$1"
    "$resolver" --metadata "$work/meta-$1" > "$file"
    printf '%s\n' "$file"
}

# assets VERSION DISTRO -> a directory with every asset the release ships.
assets() {
    local d=$work/assets-$1 v=$1 arch
    mkdir -p "$d"
    for arch in x86_64 aarch64; do
        touch "$d/usagebar-cli-$v-linux-$arch.tar.gz" "$d/UsageBarTray-$v-linux-$arch.tar.gz"
    done
    touch "$d/usagebar@felipearosr.github.io-$v.shell-extension.zip"
    if [[ $2 == distro ]]; then
        touch "$d/usagebar_${v}_amd64.deb" "$d/usagebar_${v}_arm64.deb" \
            "$d/usagebar-$v-1.x86_64.rpm" "$d/usagebar-$v-1.aarch64.rpm" \
            "$d/usagebar-cli_${v}_amd64.deb" "$d/usagebar-cli_${v}_arm64.deb" \
            "$d/usagebar-cli-$v-1.x86_64.rpm" "$d/usagebar-cli-$v-1.aarch64.rpm" \
            "$d/usagebar-cli-$v-1.src.rpm"
    fi
    for f in "$d"/*; do [[ $f == *.sha256 ]] || touch "$f.sha256"; done
    printf '%s\n' "$d"
}

run_notes() { # run_notes OUT ARGS... (in the scratch repo)
    local out=$1
    shift
    (cd "$work/repo" && "$notes" --repo felipearosr/UsageBar "$@") > "$out" 2> "$work/stderr"
}

has() { # has NAME FILE TEXT
    if grep -Fq -- "$3" "$2"; then pass "$1"; else flunk "$1: no '$3' in: $(cat "$2")"; fi
}
lacks() { # lacks NAME FILE TEXT
    if grep -Fq -- "$3" "$2"; then flunk "$1: unexpected '$3' in: $(cat "$2")"; else pass "$1"; fi
}

# Every #anchor the notes link to is a heading in linux/INSTALL.md.
anchors_exist() { # anchors_exist FILE
    python3 - "$1" "$install_md" << 'PY'
import re, sys
notes, install = (open(p, encoding='utf-8').read() for p in sys.argv[1:])
def slug(heading):
    s = heading.strip().lower()
    s = re.sub(r'[^\w\- ]', '', s)
    return s.replace(' ', '-')
slugs = {slug(h) for h in re.findall(r'^#+ (.+)$', install, re.M)}
used = set(re.findall(r'INSTALL\.md#([\w-]+)', notes))
missing = sorted(used - slugs)
if missing or not used:
    print('missing anchors:', missing, 'used:', sorted(used))
    sys.exit(1)
PY
}

# ---------- final release ----------
git_ tag usagebar-v1.1.0
final=$work/final.md
if run_notes "$final" "$(resolve 1.1.0)" "$(assets 1.1.0 distro)"; then
    pass "final release notes render"
else
    flunk "final release notes: $(cat "$work/stderr")"
fi
has "names the UsageBar version" "$final" "UsageBar 1.1.0, based on"
has "names and links the upstream base" "$final" \
    "[CodexBar 0.72.0](https://github.com/steipete/CodexBar/releases/tag/v0.72.0) (upstream tag \`v0.72.0\`)"
has "names the CLI version string" "$final" "CodexBar 0.72.0+usagebar.1.1.0"
has "changes since the previous final release, skipping the rc" "$final" "## Changes since usagebar-v1.0.0"
has "lists merged PRs by title" "$final" "- Release: GNOME extension zip (#101)"
has "lists the later PR" "$final" "- Release: tray app for x86_64 and aarch64 (#102)"
has "lists direct commits" "$final" "- Fix a typo ("
lacks "PR lines use the PR title, not the merge subject" "$final" "Merge pull request"
has "links the full diff" "$final" \
    "(https://github.com/felipearosr/UsageBar/compare/usagebar-v1.0.0...usagebar-v1.1.0)"
lacks "a final release isn't marked as a pre-release" "$final" "Pre-release"
has "links INSTALL.md at the tag" "$final" \
    "[linux/INSTALL.md](https://github.com/felipearosr/UsageBar/blob/usagebar-v1.1.0/linux/INSTALL.md)"
has "install script for this version" "$final" \
    "curl -fsSL https://raw.githubusercontent.com/felipearosr/UsageBar/usagebar-v1.1.0/linux/packaging/install-cli.sh | sh -s -- 1.1.0"
has "extension install uses the resolved zip name" "$final" \
    "gnome-extensions install --force usagebar@felipearosr.github.io-1.1.0.shell-extension.zip"
has "UsageBar package for a final release" "$final" "the UsageBar package (\`.deb\` or \`.rpm\` below)"
missing_rows=()
for f in "$work/assets-1.1.0"/*; do
    name=$(basename "$f")
    [[ $name == *.sha256 ]] && continue
    grep -Fq "| \`$name\` |" "$final" || missing_rows+=("$name")
done
if ((${#missing_rows[@]} == 0)); then pass "every asset has a row"; else flunk "assets without a row: ${missing_rows[*]}"; fi
if anchors_exist "$final" > "$work/anchors" 2>&1; then
    pass "every INSTALL.md anchor exists"
else
    flunk "INSTALL.md anchors: $(cat "$work/anchors")"
fi

# ---------- pre-release ----------
git_ tag usagebar-v1.2.0-rc.1
rc=$work/rc.md
if run_notes "$rc" "$(resolve 1.2.0-rc.1)" "$(assets 1.2.0-rc.1 tarballs)"; then
    pass "pre-release notes render"
else
    flunk "pre-release notes: $(cat "$work/stderr")"
fi
has "a pre-release says so first" "$rc" "> **Pre-release** for testing"
if [[ "$(head -c 17 "$rc")" == "> **Pre-release**" ]]; then pass "the pre-release banner leads"; else flunk "banner isn't first: $(head -3 "$rc")"; fi
has "a pre-release lists changes since the nearest usagebar-v* tag" "$rc" "## Changes since usagebar-v1.1.0"
has "pre-release install script names the version" "$rc" "| sh -s -- 1.2.0-rc.1"
lacks "no UsageBar package bullet for a pre-release" "$rc" "the UsageBar package (\`.deb\`"
has "pre-release CLI version string" "$rc" "CodexBar 0.72.0+usagebar.1.2.0-rc.1"

# --ref: a dry run of an untagged commit links that commit.
dry=$work/dry.md
run_notes "$dry" --ref 0123abc "$(resolve 1.2.0-rc.1)" "$work/assets-1.2.0-rc.1" || flunk "dry run: $(cat "$work/stderr")"
has "--ref sets the link target" "$dry" "/blob/0123abc/linux/INSTALL.md"
has "--ref sets the diff end" "$dry" "compare/usagebar-v1.1.0...0123abc"

# ---------- first release ----------
git_ checkout -q usagebar-v1.0.0 2> /dev/null
first=$work/first.md
run_notes "$first" "$(resolve 1.0.0)" "$(assets 1.0.0 distro)" || flunk "first release: $(cat "$work/stderr")"
has "no previous tag is the first release" "$first" "First UsageBar release."
lacks "the first release has no diff link" "$first" "compare/"
git_ checkout -q main

# ---------- refusals ----------
d=$(assets 1.1.0 distro)
touch "$d/mystery.bin"
status=0
run_notes "$work/x.md" "$(resolve 1.1.0)" "$d" || status=$?
rm "$d/mystery.bin"
if [[ $status -eq 1 ]] && grep -Fq "no description for asset mystery.bin" "$work/stderr"; then
    pass "an asset without a description fails"
else
    flunk "unknown asset: status $status: $(cat "$work/stderr")"
fi

git clone -q --depth 1 "file://$work/repo" "$work/shallow" 2> /dev/null
status=0
(cd "$work/shallow" && "$notes" "$(resolve 1.1.0)" "$d") > /dev/null 2> "$work/stderr" || status=$?
if [[ $status -eq 1 ]] && grep -Fq "shallow clone" "$work/stderr"; then
    pass "a shallow clone fails instead of listing nothing"
else
    flunk "shallow clone: status $status: $(cat "$work/stderr")"
fi

status=0
"$notes" "$(resolve 1.1.0)" > /dev/null 2>&1 || status=$?
if [[ $status -eq 2 ]]; then pass "missing argument is a usage error"; else flunk "usage exited $status"; fi

if ((failures)); then
    printf '%d release notes test(s) failed\n' "$failures" >&2
    exit 1
fi
echo "Release notes tests passed."
