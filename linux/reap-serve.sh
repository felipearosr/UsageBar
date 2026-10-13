# shellcheck shell=bash
# Sourced by run-dev.sh and test-devkit-ui.sh.
#
# A nested GNOME Shell (dev kit, UI smoke) leaves its codexbar serve running:
# the shell quits on SIGTERM or a closed window without disabling extensions,
# and outside a systemd unit nothing stops its children. (A desktop session's
# shell is org.gnome.Shell@wayland.service, KillMode=control-group, so its
# serve stops with it.)
#
#   reap_serve KEY=VALUE
#
# stops each codexbar serve whose environment holds KEY=VALUE, an entry the
# run exported before starting the shell. It never matches command lines,
# which would also match the shell running this.
reap_serve() {
    local entry=$1 pid
    for pid in $(pgrep -x codexbar; pgrep -x CodexBarCLI); do
        if tr '\0' '\n' < "/proc/$pid/environ" 2> /dev/null | grep -qxF -- "$entry"; then
            kill "$pid" 2> /dev/null || true
        fi
    done
}
