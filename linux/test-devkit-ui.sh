#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
extension_dir="$repo_dir/linux/usagebar-gnome/usagebar@felipearosr.github.io"
artifact_dir="${1:-$(mktemp -d /tmp/codexbar-ui-smoke.XXXXXX)}"
result_path="$artifact_dir/result.json"
log_path="$artifact_dir/gnome-shell.log"
session_log_path="$artifact_dir/session.log"
screenshot_path="$artifact_dir/cost-dashboard.png"
dconf_profile="$artifact_dir/dconf-profile"
assert_script="$repo_dir/linux/usagebar-gnome/tests/assert-ui-smoke.mjs"

mkdir -p "$artifact_dir"
glib-compile-schemas "$extension_dir/schemas"
mkdir -p "$HOME/.local/share/gnome-shell/extensions"
ln -sfn "$extension_dir" \
    "$HOME/.local/share/gnome-shell/extensions/usagebar@felipearosr.github.io"
printf 'user-db:codexbar_ui_smoke\n' > "$dconf_profile"

if ! dbus-run-session -- bash -c '
    set -euo pipefail
    result_path=$1
    log_path=$2
    screenshot_path=$3
    dconf_profile=$4

    export DCONF_PROFILE=$dconf_profile
    export USAGEBAR_UI_SMOKE_RESULT=$result_path
    gsettings set org.gnome.shell enabled-extensions \
        "[\"usagebar@felipearosr.github.io\"]"

    gnome-shell --headless --virtual-monitor 1024x900 >"$log_path" 2>&1 &
    shell_pid=$!
    cleanup() {
        kill -TERM "$shell_pid" 2>/dev/null || true
        wait "$shell_pid" 2>/dev/null || true
    }
    trap cleanup EXIT

    for _ in $(seq 1 200); do
        if [[ -s $result_path ]]; then
            break
        fi
        if ! kill -0 "$shell_pid" 2>/dev/null; then
            echo "GNOME Shell exited before the UI smoke test completed" >&2
            break
        fi
        sleep 0.1
    done

    if [[ ! -s $result_path ]]; then
        echo "Timed out waiting for the UsageBar UI smoke result" >&2
        sed -n "1,240p" "$log_path" >&2
        exit 1
    fi

    if [[ ! -s $screenshot_path ]]; then
        echo "The UI smoke test did not produce a screenshot" >&2
        exit 1
    fi

    if grep -En "JS ERROR|Extension .* had error|usagebar-ui-smoke: FAIL" "$log_path"; then
        echo "GNOME Shell reported an extension error" >&2
        exit 1
    fi
' bash "$result_path" "$log_path" "$screenshot_path" "$dconf_profile" \
    >"$session_log_path" 2>&1; then
    if [[ -s $result_path ]]; then
        node "$assert_script" "$result_path" >&2 || true
    fi
    sed -n '1,240p' "$session_log_path" >&2
    exit 1
fi

node "$assert_script" "$result_path"

printf 'Screenshot: %s\n' "$screenshot_path"
printf 'Result: %s\n' "$result_path"
printf 'Log: %s\n' "$log_path"
printf 'Session log: %s\n' "$session_log_path"
