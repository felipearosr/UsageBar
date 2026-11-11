// Knowing when a command run in a terminal has finished (Sign in, and the
// account add helpers: Codex #169, claude-swap #172). Dependency-free so the
// Node tests can exercise it without GJS.
//
// gnome-terminal, ptyxis and kgx return as soon as they hand the window to
// their server, and xdg-terminal-exec (tried first) can't be asked to wait,
// so the launcher's process exiting says nothing about the command. Instead
// holdOpenArgv (authlogin.js) gets a marker path and writes the command's
// exit status there the moment it ends. The extension makes a fresh marker
// path per run under $XDG_RUNTIME_DIR/usagebar/, polls it every POLL_SECS,
// and gives up after TIMEOUT_SECS (the user may leave a browser sign-in open
// for a while, or close the terminal without finishing). The launcher's own
// exit stays only as a fallback when no marker can be made.

export const POLL_SECS = 2;
export const TIMEOUT_SECS = 30 * 60;

// The marker for one run: `<runtimeDir>/usagebar/terminal-<id>.status`.
// `id` is random per run (GLib.uuid_string_random()); null when either part
// is unusable, so a run never shares or escapes the directory.
export function markerPath(runtimeDir, id) {
    if (typeof runtimeDir !== 'string' || !runtimeDir.startsWith('/'))
        return null;
    if (typeof id !== 'string' || !/^[A-Za-z0-9-]{8,64}$/.test(id))
        return null;
    return `${runtimeDir.replace(/\/+$/, '')}/usagebar/terminal-${id}.status`;
}

// The marker's text → the command's exit status (0-255), or null while it is
// missing, empty or not a status.
export function readMarker(text) {
    const trimmed = typeof text === 'string' ? text.trim() : '';
    if (!/^\d{1,3}$/.test(trimmed))
        return null;
    const status = Number(trimmed);
    return status <= 255 ? status : null;
}

// What to do on a poll: 'exited' once the status is there, 'stop' when the
// extension was disabled or reloaded since the run started, 'timeout' when
// the status never came, else 'wait'.
export function watchState({status = null, elapsedSecs = 0, timeoutSecs = TIMEOUT_SECS, stale = false} = {}) {
    if (stale)
        return 'stop';
    if (Number.isInteger(status))
        return 'exited';
    return elapsedSecs >= timeoutSecs ? 'timeout' : 'wait';
}

// The notification after an add helper's terminal run: null on success (the
// refreshed card says it), else a pointer to the terminal, which shows the
// failing step. 130 is Ctrl-C.
export function addExitNotice(status, name) {
    if (status === 0 || !Number.isInteger(status))
        return null;
    if (status === 130)
        return `Adding a ${name} account was cancelled.`;
    return `Adding a ${name} account didn’t finish. The terminal shows the step that failed.`;
}

// What the notification says when a helper can't open in a terminal.
export function launchFailureText(argv, name, {noTerminal = false} = {}) {
    const command = (argv ?? []).join(' ');
    if (!command)
        return `UsageBar’s codexbar CLI wasn’t found, so a ${name} account can’t be added here.`;
    return noTerminal
        ? `No terminal found. Run \`${command}\` in a terminal to add a ${name} account.`
        : `Could not open a terminal. Run \`${command}\` to add a ${name} account.`;
}
