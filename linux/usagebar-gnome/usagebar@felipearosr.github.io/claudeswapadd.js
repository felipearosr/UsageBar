// "Add account…" on Claude (#172): claude-swap's add flow. Dependency-free
// so the Node tests can exercise it without GJS; extension.js sends the
// requests, finds the binaries and opens the terminal.
//
// The flow, decided here:
//   1. POST /accounts/claude-swap/detect (guarded by the action token). Serve
//      finds `cswap` (PATH, ~/.local/bin, uv's and pipx's tool dirs), saves
//      its path and turns claude-swap on.
//   2. Installed: open `codexbar claude add-account` in a terminal. That
//      helper runs `cswap add`, `claude auth login`, `cswap add`, and never
//      logs out.
//      Not installed: offer to install it. The offer opens a terminal running
//      `uv tool install claude-swap`, or `pipx install claude-swap` when uv is
//      missing, then runs detect again when the terminal exits.
// Every command is a fixed argv; nothing goes through a shell string.

export const CLAUDE_SWAP_KIND = 'claude-swap';
export const ADD_CAPABILITY = 'providerAccountAddClaudeSwap';
export const PACKAGE = 'claude-swap';

export function detectRequest() {
    return {method: 'POST', path: '/accounts/claude-swap/detect', body: {}};
}

// Serve's detect answer → {installed, path, message}. Anything malformed
// counts as not installed, which only ever leads to the install offer.
export function readDetect(json) {
    const installed = json?.installed === true &&
        typeof json.executablePath === 'string' && json.executablePath.startsWith('/');
    return {
        installed,
        path: installed ? json.executablePath : null,
        message: typeof json?.message === 'string' && json.message.trim()
            ? json.message.trim() : (installed ? null : 'claude-swap is not installed.'),
    };
}

// What "Add account…" does after detect: 'add' or 'install'.
export function nextStep(detect) {
    return detect?.installed ? 'add' : 'install';
}

// The add helper's argv: the same codexbar the serve supervisor runs.
export function addHelperArgv(codexbarPath) {
    if (typeof codexbarPath !== 'string' || !codexbarPath.startsWith('/'))
        return null;
    return [codexbarPath, 'claude', 'add-account'];
}

// The install argv: uv when it can be found, else pipx, else null.
// `findProgram(name)` returns an absolute path or null.
export function installArgv(findProgram) {
    const uv = absolute(findProgram('uv'));
    if (uv)
        return [uv, 'tool', 'install', PACKAGE];
    const pipx = absolute(findProgram('pipx'));
    if (pipx)
        return [pipx, 'install', PACKAGE];
    return null;
}

// Which installer `installArgv` picked, for the offer's text.
export function installerName(argv) {
    if (!argv)
        return null;
    return argv[1] === 'tool' ? 'uv' : 'pipx';
}

export function installOfferText(argv) {
    const lead = 'Adding Claude accounts uses claude-swap, which isn’t installed.';
    if (!argv)
        return `${lead} Install uv or pipx, then run \`uv tool install ${PACKAGE}\` or \`pipx install ${PACKAGE}\`.`;
    const command = installerName(argv) === 'uv' ? `uv tool install ${PACKAGE}` : `pipx install ${PACKAGE}`;
    return `${lead} UsageBar can open a terminal running \`${command}\`.`;
}

// The offer's button: Install when there is an installer to run, else OK
// (it only closes the offer, whose text says what to install).
export function installConfirmLabel(argv) {
    return argv ? 'Install' : 'OK';
}

export const NO_INSTALLER_ERROR = 'Neither uv nor pipx was found. Install one of them first.';

function absolute(path) {
    return typeof path === 'string' && path.startsWith('/') ? path : null;
}

// What to do when a claude-swap terminal run ends (terminalwatch.js reports
// the command's exit status from its marker; null when no marker could be
// made and only the launcher's exit is known). `run` is 'install' or 'add'.
//   install: detect again on success (or when the status is unknown), else
//            only say it was cancelled (130, Ctrl-C) or didn't finish.
//   add:     always refresh the cards; a failed or cancelled run also gets a
//            notice (the terminal shows the failing step).
// → {detect, refresh, notice}
export function afterTerminal(run, status) {
    const known = Number.isInteger(status);
    if (run === 'install') {
        if (!known || status === 0)
            return {detect: true, refresh: true, notice: null};
        return {
            detect: false,
            refresh: false,
            notice: status === 130
                ? 'Installing claude-swap was cancelled.'
                : 'Installing claude-swap didn’t finish. The terminal shows what went wrong.',
        };
    }
    if (!known || status === 0)
        return {detect: false, refresh: true, notice: null};
    return {
        detect: false,
        refresh: true,
        notice: status === 130
            ? 'Adding a Claude account was cancelled.'
            : 'Adding a Claude account didn’t finish. The terminal shows the step that failed.',
    };
}
