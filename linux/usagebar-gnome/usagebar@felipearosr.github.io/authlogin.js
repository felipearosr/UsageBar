// "Log in" action for provider error banners: which errors are auth
// problems, which command logs each provider in, and how to open that
// command in a terminal. Dependency-free so the Node tests can exercise it
// without GJS; extension.js resolves binaries and spawns.
//
// Error payloads (Sources/CodexBarCLI/CLIErrorReporting.swift) carry
// {code, message, kind}; neither code nor kind marks auth failures, so they
// only rule errors out and the message decides. The markers mirror the
// Swift error texts (CodexOAuthCredentials, CodexOAuthUsageFetcher,
// CodexTokenRefresher, ClaudeOAuth*, ClaudeStatusProbe, Grok*, Kilo*,
// Codebuff*).

// Provider id -> login argv. Only commands the CLI itself documents:
// `codex login`; `claude auth login` (Claude Code 2.x `claude auth --help`;
// the Swift texts still say `claude login`); grok/kilo/codebuff as named in
// their CodexBar error texts.
export const LOGIN_COMMANDS = {
    codex: ['codex', 'login'],
    claude: ['claude', 'auth', 'login'],
    grok: ['grok', 'login'],
    kilo: ['kilo', 'auth', 'login'],
    codebuff: ['codebuff', 'login'],
};

// Exit codes from Sources/CodexBarCLI/CLIExitCode.swift that are never auth:
// binaryNotFound, timeout, usage.
const NON_AUTH_CODES = new Set([2, 4, 64]);
const NON_AUTH_KINDS = new Set(['args', 'config']);

// Checked first: these texts mention a login command or expiry but logging
// in again does not fix them.
// Not plain "rate limit": Codex's app-server auth error reads "account
// authentication required to read rate limits".
const NON_AUTH_MARKERS = [
    'rate limited',            // Claude usage endpoint rate limit suggests `claude logout && claude login`
    'rate-limited',
    'too many requests',
    'closed stdout',           // codex app-server transport failure
    'timed out',
    'not installed',
    'cannot read them back',   // Claude keychain consent, not a login problem
];

const AUTH_PATTERNS = [
    /\b(codex|claude|grok|codebuff)\s+login\b/,
    /\b(claude|kilo)\s+auth\s+login\b/,
    /\brun\s+\/login\b/,
    /\brun `(codex|claude)` to (log in|re-?authenticate|authenticate)\b/,
    /\blog ?in again\b/,
    /\bre-?authenticate\b/,
    /\bnot (logged|signed) in\b/,
    /\bnot authenticated\b/,
    /\bauthentication (required|failed|error)\b/,
    /\bauthentication_error\b/,
    /\bunauthori[sz]ed\b/,
    /\b401\b/,
    /\btoken(_| )(has )?expired\b/,
    /\btoken expired or invalid\b/,
    /\b(refresh )?token was (revoked|already used)\b/,
    /\btoken revoked\b/,
    /\binvalid (access |oauth )?token\b/,
    /\bcredentials (missing|not found|expired|are invalid)\b/,
    /\bauth\.json (not found|needs refresh)\b/,
];

export function loginCommandFor(provider) {
    return LOGIN_COMMANDS[provider] ?? null;
}

// error: the row.error payload ({message, code?, kind?}) or a bare string.
export function isAuthError(error) {
    if (!error)
        return false;
    const message = typeof error === 'string' ? error : error.message;
    if (typeof message !== 'string' || !message.trim())
        return false;
    if (typeof error === 'object') {
        if (NON_AUTH_CODES.has(error.code) || NON_AUTH_KINDS.has(error.kind))
            return false;
    }
    const lower = message.toLowerCase();
    if (NON_AUTH_MARKERS.some(m => lower.includes(m)))
        return false;
    return AUTH_PATTERNS.some(re => re.test(lower));
}

// The login argv for a card row, or null when no Log in button applies.
export function loginActionFor(row) {
    if (!row?.error)
        return null;
    const argv = loginCommandFor(row.provider);
    if (!argv || !isAuthError(row.error))
        return null;
    return argv;
}

// Keeps the terminal open after the login command exits so its outcome
// stays readable; `sh -c` gets the command as positional args, no quoting.
export function holdOpenArgv(argv) {
    return ['sh', '-c', '"$@"; status=$?; echo; printf "Press Enter to close. "; read _; exit $status',
        'usagebar-login', ...argv];
}

// Terminal launchers in preference order: the user's default terminal via
// xdg-terminal-exec, then common terminals. Each entry is the prefix placed
// before the command argv.
export const TERMINALS = [
    ['xdg-terminal-exec'],
    ['gnome-terminal', '--'],
    ['ptyxis', '--'],
    ['kgx', '-e'],
    ['konsole', '-e'],
    ['xterm', '-e'],
];

// First launchable terminal argv for `argv`, or null. `findProgram(name)`
// returns an absolute path or null (GLib.find_program_in_path in GJS).
export function terminalArgv(argv, findProgram) {
    for (const [bin, ...prefix] of TERMINALS) {
        const path = findProgram(bin);
        if (path)
            return [path, ...prefix, ...holdOpenArgv(argv)];
    }
    return null;
}
