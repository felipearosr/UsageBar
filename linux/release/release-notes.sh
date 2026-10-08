#!/usr/bin/env bash
# Release notes for a UsageBar release, in Markdown on stdout:
#
#   linux/release/release-notes.sh [--repo OWNER/NAME] [--ref REF] RESOLVED DIR
#
# RESOLVED is resolve-version.sh's output saved to a file; DIR holds the
# release assets (what verify-assets.sh checked). Run it inside the git
# checkout being released, with full history and tags: the changes are the
# first-parent commits since the previous usagebar-v* tag (for a final
# release, the previous final one). --repo (default $GITHUB_REPOSITORY, else
# felipearosr/UsageBar) and --ref (default the release tag) build the links.
#
# The notes name the UsageBar version, the CodexBar release it's based on,
# the changes, every asset with what it is and where its install steps are
# (linux/INSTALL.md), and how to verify the download. A pre-release says so
# up front. Exits 1 on an asset it can't describe, so a new kind of asset
# gets a line here before it ships.
set -euo pipefail

repo=${GITHUB_REPOSITORY:-felipearosr/UsageBar}
ref=
usage() { sed -n '2,11p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2; exit 2; }
while (($#)); do
    case "$1" in
        --repo) (($# >= 2)) || usage; repo=$2; shift 2 ;;
        --ref) (($# >= 2)) || usage; ref=$2; shift 2 ;;
        -h | --help) usage ;;
        -*) usage ;;
        *) break ;;
    esac
done
(($# == 2)) || usage
resolved_file=$1
dir=$2
[[ -r "$resolved_file" ]] || { echo "release-notes: no resolved values file: $resolved_file" >&2; exit 2; }
[[ -d "$dir" ]] || { echo "release-notes: no asset directory: $dir" >&2; exit 2; }

declare -A resolved=()
while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" == *=* ]] || continue
    resolved[${line%%=*}]=${line#*=}
done < "$resolved_file"
for key in tag version upstream_base upstream_tag cli_version prerelease distro_packages cli_arches extension_asset; do
    [[ -n "${resolved[$key]:-}" ]] || { echo "release-notes: $resolved_file has no $key" >&2; exit 2; }
done
tag=${resolved[tag]}
version=${resolved[version]}
ref=${ref:-$tag}
read -r -a arches <<< "${resolved[cli_arches]}"

github=https://github.com/$repo
install_doc="$github/blob/$ref/linux/INSTALL.md"
install_script="https://raw.githubusercontent.com/$repo/$ref/linux/packaging/install-cli.sh"
upstream_url=https://github.com/steipete/CodexBar/releases/tag/${resolved[upstream_tag]}

# ---------- changes ----------

if [[ "$(git rev-parse --is-shallow-repository)" == true ]]; then
    echo "release-notes: shallow clone; the changes need the full history and tags (fetch-depth: 0)" >&2
    exit 1
fi
describe=(git describe --tags --abbrev=0 --match 'usagebar-v*' --exclude "$tag")
# A final release lists everything since the previous final release.
[[ "${resolved[prerelease]}" == true ]] || describe+=(--exclude 'usagebar-v*-*')
previous=$("${describe[@]}" HEAD 2> /dev/null || true)

changes() {
    local commit subject body
    while IFS= read -r commit; do
        subject=$(git log -1 --format=%s "$commit")
        if [[ "$subject" =~ ^Merge\ pull\ request\ \#([0-9]+)\ from\  ]]; then
            body=$(git log -1 --format=%b "$commit" | sed -n '/[^[:space:]]/{p;q;}')
            printf -- '- %s (#%s)\n' "${body:-$subject}" "${BASH_REMATCH[1]}"
        else
            printf -- '- %s (%s)\n' "$subject" "$(git rev-parse --short "$commit")"
        fi
    done < <(git log --first-parent --format=%H "$previous..HEAD")
}

# ---------- assets ----------

# describe_asset NAME: prints "what|install-doc-anchor", or fails.
describe_asset() {
    local name=$1 arch
    for arch in "${arches[@]}"; do
        if [[ "$name" == "${resolved[cli_asset_$arch]:-}" ]]; then
            echo "\`codexbar\` CLI (fork build with Machine Sync), $arch, upstream's tarball layout|install-script-any-distro"
            return
        fi
        if [[ "$name" == "${resolved[tray_asset_$arch]:-}" ]]; then
            echo "Tray app for desktops without GNOME Shell, $arch|the-tray-app-desktops-without-gnome-shell"
            return
        fi
    done
    case "$name" in
        "${resolved[extension_asset]}")
            echo "GNOME Shell extension (the extensions.gnome.org build)|the-extension-from-extensionsgnomeorg" ;;
        usagebar_"$version"_*.deb | usagebar-"$version"-1.*.rpm)
            echo "UsageBar package: the extension and the CLI|the-usagebar-package" ;;
        usagebar-cli_"$version"_*.deb)
            echo "CLI-only package for Ubuntu / Debian|ubuntu--debian-usagebar-cli-deb" ;;
        usagebar-cli-"$version"-1.src.rpm)
            echo "CLI source RPM, for COPR or mock|fedora-copr-and-usagebar-cli-rpm" ;;
        usagebar-cli-"$version"-1.*.rpm)
            echo "CLI-only package for Fedora|fedora-copr-and-usagebar-cli-rpm" ;;
        *) return 1 ;;
    esac
}

assets=()
shopt -s nullglob
for path in "$dir"/*; do
    name=$(basename "$path")
    [[ "$name" == *.sha256 ]] && continue
    assets+=("$name")
done
((${#assets[@]})) || { echo "release-notes: no assets in $dir" >&2; exit 1; }
table=$(
    for name in "${assets[@]}"; do
        if ! info=$(describe_asset "$name"); then
            echo "release-notes: no description for asset $name; add it to describe_asset" >&2
            exit 1
        fi
        # shellcheck disable=SC2016 # literal Markdown backticks
        printf '| `%s` | %s | [steps](%s#%s) |\n' "$name" "${info%|*}" "$install_doc" "${info##*|}"
    done
) || exit 1

# ---------- notes ----------

if [[ "${resolved[prerelease]}" == true ]]; then
    cat << EOF
> **Pre-release** for testing, not the latest release. It ships the tarballs and the extension zip only: the \`.deb\`/\`.rpm\` packages, the SRPM and the AUR update wait for the final release. The install script picks the latest final release unless you name this one (below).

EOF
fi
cat << EOF
UsageBar $version, based on [CodexBar ${resolved[upstream_base]}]($upstream_url) (upstream tag \`${resolved[upstream_tag]}\`). Its CLI reports \`CodexBar ${resolved[cli_version]}\`.

EOF
if [[ -n "$previous" ]]; then
    echo "## Changes since $previous"
    echo
    list=$(changes)
    if [[ -n "$list" ]]; then printf '%s\n' "$list"; else echo "No changes."; fi
    echo
    echo "Full diff: [\`$previous...$ref\`]($github/compare/$previous...$ref)"
else
    echo "## Changes"
    echo
    echo "First UsageBar release."
fi
cat << EOF

## Install

Every install path is in [linux/INSTALL.md]($install_doc).

EOF
if [[ "${resolved[distro_packages]}" == true ]]; then
    echo "- **GNOME on Ubuntu, Debian or Fedora:** the UsageBar package (\`.deb\` or \`.rpm\` below) holds the extension and the CLI. Open it, or \`sudo apt install ./usagebar_*.deb\` / \`sudo dnf install ./usagebar-*.rpm\`, then log out and back in once."
fi
cat << EOF
- **The CLI on any distro**, in upstream's layout (\`CodexBarCLI\`, the \`codexbar\` symlink, \`VERSION\`, the resource bundle) under \`~/.local/lib/usagebar-cli\`: \`curl -fsSL $install_script | sh -s -- $version\`. The script downloads this release's tarball and checks its \`.sha256\` before installing.
- **The extension from the zip:** \`gnome-extensions install --force ${resolved[extension_asset]}\`, log out and back in, then \`gnome-extensions enable usagebar@felipearosr.github.io\`. It needs the CLI.
- **The tray app** (KDE, Cinnamon, XFCE…): unpack the \`UsageBarTray\` tarball for your architecture and run \`codexbar-tray\`. It needs the CLI too.

## Assets

| File | What it is | Install |
|---|---|---|
$table

Every file has a \`<file>.sha256\` next to it.

## Verify

\`\`\`sh
sha256sum --ignore-missing -c ./*.sha256   # in the folder you downloaded to
codexbar --version      # CodexBar ${resolved[cli_version]}
codexbar sync --help    # lists the Machine Sync commands
\`\`\`
EOF
