#!/usr/bin/env bash
# Takes the website's screenshots from the real extension, in a headless GNOME
# Shell of its own, against website/tools/demo-codexbar (made-up data; no
# account, config or network of yours is read, apart from the public provider
# status pages the extension itself fetches).
#
#   website/tools/capture-screenshots.sh [out-dir]
#
# Writes raw full-stage PNGs and bounds.json to out-dir/<variant>/ (default: a
# new /tmp directory) and the cropped, web-sized files to
# website/assets/screenshots/. Needs gnome-shell, python3 and ImageMagick.
# USAGEBAR_SHOTS_VARIANTS="dark light" picks the runs (default both).
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tools_dir="$repo_dir/website/tools"
extension_dir="$repo_dir/linux/usagebar-gnome/usagebar@felipearosr.github.io"
out_root="${1:-$(mktemp -d /tmp/usagebar-shots.XXXXXX)}"
dest_dir="$repo_dir/website/assets/screenshots"
lock=/tmp/usagebar-devkit.lock # shared with the devkit and the UI smoke
# The virtual screen, in device pixels (scale 2). Tall enough for the longest
# surface, the Claude detail popover: crop-screenshots.py refuses a shot that
# runs off the screen instead of cutting its bottom off.
screen=2880x2000

for tool in gnome-shell python3 magick dbus-run-session; do
    command -v "$tool" > /dev/null || { echo "missing: $tool" >&2; exit 2; }
done

for _ in $(seq 1 600); do
    mkdir "$lock" 2> /dev/null && break
    sleep 1
done
[[ -d $lock ]] || { echo "could not take $lock" >&2; exit 1; }
trap 'rmdir "$lock" 2> /dev/null || true' EXIT

glib-compile-schemas "$extension_dir/schemas"
mkdir -p "$out_root" "$dest_dir"

capture() {
    local variant=$1 color_scheme=$2 app_theme=$3
    local work=$out_root/$variant
    rm -rf "$work"
    mkdir -p "$work/home" "$work/data/gnome-shell/extensions" "$work/config" "$work/cache" "$work/state"
    ln -sfn "$extension_dir" "$work/data/gnome-shell/extensions/usagebar@felipearosr.github.io"
    ln -sfn "$tools_dir/shots-driver" "$work/data/gnome-shell/extensions/usagebar-shots@usagebar.dev"
    # A wallpaper of our own, so no distro artwork ends up on the site.
    if [[ $variant == light ]]; then
        magick -size $screen gradient:'#dfe7f5-#f6efe6' \
            \( -size $screen radial-gradient:'#b9c8ff80-#ffffff00' \) -composite "$work/wallpaper.png"
    else
        magick -size $screen gradient:'#0b1020-#1a1033' \
            \( -size $screen radial-gradient:'#3b5bdb66-#00000000' \) -composite "$work/wallpaper.png"
    fi

    # Its own home and XDG directories: nothing of the real user's is read or written.
    env -u USAGEBAR_UI_SMOKE_RESULT \
        HOME="$work/home" XDG_DATA_HOME="$work/data" XDG_CONFIG_HOME="$work/config" \
        XDG_CACHE_HOME="$work/cache" XDG_STATE_HOME="$work/state" \
        CODEXBAR_BIN="$tools_dir/demo-codexbar" USAGEBAR_SHOTS_OUT="$work" \
        GSETTINGS_SCHEMA_DIR="$extension_dir/schemas" \
        dbus-run-session -- bash -c '
            set -euo pipefail
            work=$1 color_scheme=$2 app_theme=$3 screen=$4
            gsettings set org.gnome.shell.extensions.usagebar app-theme "$app_theme"
            gsettings set org.gnome.shell.extensions.usagebar notify-enabled false
            gsettings set org.gnome.shell.extensions.usagebar providers-bootstrapped true
            gsettings set org.gnome.desktop.interface color-scheme "$color_scheme"
            gsettings set org.gnome.desktop.interface enable-animations false
            gsettings set org.gnome.desktop.interface clock-format 24h
            gsettings set org.gnome.desktop.background picture-uri "file://$work/wallpaper.png"
            gsettings set org.gnome.desktop.background picture-uri-dark "file://$work/wallpaper.png"
            gsettings set org.gnome.shell welcome-dialog-last-shown-version 999
            gsettings set org.gnome.shell enabled-extensions \
                "[\"usagebar@felipearosr.github.io\", \"usagebar-shots@usagebar.dev\"]"

            gnome-shell --headless --virtual-monitor $screen > "$work/gnome-shell.log" 2>&1 &
            shell_pid=$!
            trap "kill -TERM $shell_pid 2> /dev/null || true; wait $shell_pid 2> /dev/null || true" EXIT
            for _ in $(seq 1 900); do
                [[ -e $work/done || -e $work/error ]] && break
                kill -0 "$shell_pid" 2> /dev/null || { echo "GNOME Shell exited early" >&2; break; }
                sleep 0.1
            done
            if [[ ! -e $work/done ]]; then
                cat "$work/error" 2> /dev/null >&2 || true
                tail -n 60 "$work/gnome-shell.log" >&2
                exit 1
            fi
            if grep -En "JS ERROR|Extension .* had error" "$work/gnome-shell.log"; then
                echo "GNOME Shell reported an extension error" >&2
                exit 1
            fi
        ' bash "$work" "$color_scheme" "$app_theme" "$screen"

    python3 "$tools_dir/crop-screenshots.py" "$work" "$dest_dir" "$variant"
}

for variant in ${USAGEBAR_SHOTS_VARIANTS:-dark light}; do
    case $variant in
        dark) capture dark prefer-dark codexbar ;;
        light) capture light prefer-light system ;;
        *) echo "unknown variant: $variant" >&2; exit 2 ;;
    esac
done

printf 'Raw screenshots: %s\nWebsite screenshots: %s\n' "$out_root" "$dest_dir"
