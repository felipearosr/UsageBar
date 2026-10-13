#!/usr/bin/env bash
set -euo pipefail

# Compile extension GSettings schemas
glib-compile-schemas "$(pwd)/linux/usagebar-gnome/usagebar@felipearosr.github.io/schemas/"

# Ensure extension symlink is active
extensions_dir=~/.local/share/gnome-shell/extensions
installed=$extensions_dir/usagebar@felipearosr.github.io
if [[ -e $installed && ! -L $installed ]]; then
  echo "A UsageBar release is installed at $installed, so the dev kit can't link this checkout there." >&2
  echo "Remove it first: gnome-extensions uninstall usagebar@felipearosr.github.io" >&2
  exit 1
fi
mkdir -p "$extensions_dir"
ln -sfn "$(pwd)/linux/usagebar-gnome/usagebar@felipearosr.github.io" "$extensions_dir/"

# Marks the codexbar serve this dev kit starts, to stop it on exit.
# shellcheck source=linux/reap-serve.sh
source "$(pwd)/linux/reap-serve.sh"
export USAGEBAR_DEVKIT_RUN=$$
trap 'reap_serve "USAGEBAR_DEVKIT_RUN=$USAGEBAR_DEVKIT_RUN"' EXIT

# Setup isolated dconf profile for dev/testing (does not touch main session settings)
printf 'user-db:codexbar_test\n' > /tmp/codexbar-dconf-profile

echo "🚀 Starting nested GNOME Shell dev environment with UsageBar..."
echo "ℹ️  Click the UsageBar chip in the top panel of the nested window to test your changes."
echo "ℹ️  Close the window or press Ctrl+C to exit."

DCONF_PROFILE=/tmp/codexbar-dconf-profile dbus-run-session -- sh -c '
  gsettings set org.gnome.shell disabled-extensions "[]"
  gsettings set org.gnome.shell enabled-extensions "[\"usagebar@felipearosr.github.io\"]"
  exec gnome-shell --devkit' || true
