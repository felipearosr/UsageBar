// Account helpers in a terminal (#169 Codex, #172 claude-swap): how the
// extension knows one finished. Dependency-free so the Node tests can
// exercise it without GJS.
//
// Terminal launchers that hand the window to a terminal server
// (gnome-terminal, ptyxis, and xdg-terminal-exec when it picks one of them)
// exit as soon as the window opens, so the launcher's process exiting says
// nothing about the helper. Instead the extension passes the helper
// `--result-file <path>` under its runtime dir, and the helper writes
// {"status": "done" | "failed", "message": "..."} there when it ends
// (CLIAccountHelperResult.swift). The extension polls that file every
// POLL_SECS until it appears or TIMEOUT_SECS pass (the user may leave the
// browser sign-in open for a while, or close the terminal first).

export const RESULT_OPTION = '--result-file';
export const POLL_SECS = 1;
export const TIMEOUT_SECS = 15 * 60;

// The result file for one helper run: `<runtimeDir>/usagebar/helper-<id>.json`.
// `id` is random per run (GLib.uuid_string_random()); null when either part
// is unusable, so a run never shares or escapes the directory.
export function resultPath(runtimeDir, id) {
    if (typeof runtimeDir !== 'string' || !runtimeDir.startsWith('/'))
        return null;
    if (typeof id !== 'string' || !/^[A-Za-z0-9-]{8,64}$/.test(id))
        return null;
    return `${runtimeDir.replace(/\/+$/, '')}/usagebar/helper-${id}.json`;
}

// The helper's argv with the result file appended (fixed argv, no shell).
export function withResultFile(argv, path) {
    if (!Array.isArray(argv) || !argv.length || typeof path !== 'string' || !path.startsWith('/'))
        return null;
    return [...argv, RESULT_OPTION, path];
}

// The file's text → {status, message}, or null while it is missing, empty or
// not (yet) a result. Messages are trimmed and capped; a result without one
// gets a plain default.
export function readResult(text) {
    if (typeof text !== 'string' || !text.trim())
        return null;
    let json;
    try {
        json = JSON.parse(text);
    } catch {
        return null;
    }
    if (!json || (json.status !== 'done' && json.status !== 'failed'))
        return null;
    const message = typeof json.message === 'string' && json.message.trim()
        ? json.message.trim().slice(0, 300)
        : json.status === 'done' ? 'Done.' : 'The helper failed.';
    return {status: json.status, message};
}

// What to do on a poll: 'done' or 'failed' once the result is there,
// 'timeout' when it never came, else 'wait'.
export function pollState({result = null, elapsedSecs = 0, timeoutSecs = TIMEOUT_SECS} = {}) {
    if (result?.status === 'done' || result?.status === 'failed')
        return result.status;
    return elapsedSecs >= timeoutSecs ? 'timeout' : 'wait';
}

// The notification after a run: null for 'done' (the refreshed card says
// it), the helper's own step for 'failed', and nothing for 'timeout' (the
// user may simply have closed the terminal).
export function resultNotice(state, result, name) {
    if (state !== 'failed')
        return null;
    return `Adding a ${name} account failed. ${result?.message ?? ''}`.trim();
}

// What the notification says when the helper can't open in a terminal.
export function launchFailureText(argv, name, {noTerminal = false} = {}) {
    const command = (argv ?? []).join(' ');
    if (!command)
        return `UsageBar’s codexbar CLI wasn’t found, so a ${name} account can’t be added here.`;
    return noTerminal
        ? `No terminal found. Run \`${command}\` in a terminal to add a ${name} account.`
        : `Could not open a terminal. Run \`${command}\` to add a ${name} account.`;
}
