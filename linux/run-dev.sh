#!/usr/bin/env bash
set -euo pipefail

# Compile extension GSettings schemas
glib-compile-schemas "$(pwd)/linux/usagebar-gnome/usagebar@felipearosr.github.io/schemas/"

# Ensure extension symlink is active
mkdir -p ~/.local/share/gnome-shell/extensions
ln -sfn "$(pwd)/linux/usagebar-gnome/usagebar@felipearosr.github.io" ~/.local/share/gnome-shell/extensions/

# Setup isolated dconf profile for dev/testing (does not touch main session settings)
printf 'user-db:codexbar_test\n' > /tmp/codexbar-dconf-profile

echo "🚀 Starting nested GNOME Shell dev environment with UsageBar..."
echo "ℹ️  Click the UsageBar chip in the top panel of the nested window to test your changes."
echo "ℹ️  Close the window or press Ctrl+C to exit."

DCONF_PROFILE=/tmp/codexbar-dconf-profile dbus-run-session -- sh -c '
  gsettings set org.gnome.shell enabled-extensions "[\"usagebar@felipearosr.github.io\"]"
  exec gnome-shell --devkit'
