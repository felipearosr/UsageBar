// Claude Code statusLine feed setup (docs/claude-statusline-feed.md).
// Anthropic throttles /api/oauth/usage hard; Claude Code already receives the
// 5-hour and weekly windows and passes them to the user's statusLine command.
// With the feed on, that command forwards its stdin to
// `codexbar claude statusline capture` and serve reads the capture instead of
// asking the endpoint. The feed stays opt-in (AGENTS.md): this module only
// describes the setup; prefs.js asks before writing anything.
// Dependency-free so the Node tests can exercise it without GJS.

// The capture script UsageBar installs, under the user data dir.
export const CAPTURE_SCRIPT_DIR = 'usagebar';
export const CAPTURE_SCRIPT_NAME = 'claude-statusline-capture.sh';

// serve uses a capture this fresh instead of the OAuth request, and one up to
// MAX_STALE_MS old (greyed) when OAuth is rate limited.
export const FRESH_MS = 15 * 60 * 1000;
export const MAX_STALE_MS = 6 * 60 * 60 * 1000;

// Whether `"statusLineFeed": true` is set on the claude provider.
export function feedEnabled(config) {
    const entry = config?.providers?.find?.(p => p?.id === 'claude');
    return entry?.statusLineFeed === true;
}

// A new config with the flag set (on) or removed (off); null when the claude
// provider is missing or nothing changes.
export function withStatusLineFeed(config, on) {
    const providers = config?.providers;
    if (!Array.isArray(providers))
        return null;
    const index = providers.findIndex(p => p?.id === 'claude');
    if (index < 0 || feedEnabled(config) === on)
        return null;
    const entry = {...providers[index]};
    if (on)
        entry.statusLineFeed = true;
    else
        delete entry.statusLineFeed;
    const next = providers.slice();
    next[index] = entry;
    return {...config, providers: next};
}

// The capture script. It looks the CLI up when it runs, in cli.js's order
// (findCodexbar), so moving between the per-user install and the packages
// keeps working. It reads the payload, hands it to the CLI in the background
// and prints nothing; a CLI without the command just prints its help to
// /dev/null.
export function captureScript() {
    return `#!/bin/sh
# Installed by UsageBar. Forwards Claude Code's statusLine payload to
# \`codexbar claude statusline capture\`, which keeps only the 5-hour and weekly
# quota windows so UsageBar can skip Anthropic's throttled usage endpoint.
# Prints nothing. See docs/claude-statusline-feed.md in the UsageBar repo.
input=$(cat)
for bin in "\${CODEXBAR_BIN:-}" /usr/libexec/usagebar/codexbar \\
    "$(command -v usagebar 2>/dev/null)" "$HOME/.local/bin/usagebar" \\
    /home/linuxbrew/.linuxbrew/bin/usagebar /usr/local/bin/usagebar \\
    "$(command -v codexbar 2>/dev/null)" "$HOME/.local/bin/codexbar" \\
    /home/linuxbrew/.linuxbrew/bin/codexbar /usr/local/bin/codexbar; do
  if [ -n "$bin" ] && [ -x "$bin" ]; then
    (printf '%s' "$input" | "$bin" claude statusline capture >/dev/null 2>&1 &)
    exit 0
  fi
done
exit 0
`;
}

// The line a user with their own statusLine adds right after it reads stdin
// into $input (most scripts start with `input=$(cat)`; one that doesn't adds
// that first). It never prints, so the status line is unchanged.
export function forwardSnippet(scriptPath) {
    return `printf '%s' "$input" | ${scriptPath}`;
}

// What Claude Code's settings.json says about the statusLine:
//   none     no statusLine command (UsageBar may set its own)
//   ours     the command is UsageBar's capture script
//   other    the user's own command; `forwards` says whether it (or the
//            script file it runs, passed as `scriptText`) already forwards
export function statusLineState(settings, scriptPath, scriptText = null) {
    const command = settings?.statusLine?.command;
    if (typeof command !== 'string' || !command.trim())
        return {kind: 'none', command: null, forwards: false};
    const trimmed = command.trim();
    if (trimmed === scriptPath || trimmed.endsWith(`/${CAPTURE_SCRIPT_DIR}/${CAPTURE_SCRIPT_NAME}`))
        return {kind: 'ours', command: trimmed, forwards: true};
    return {kind: 'other', command: trimmed, forwards: forwardsCapture(trimmed) || forwardsCapture(scriptText)};
}

// Whether a command or script text hands the payload to the capture.
export function forwardsCapture(text) {
    if (typeof text !== 'string')
        return false;
    return /\bstatusline\s+capture\b/.test(text) || text.includes(CAPTURE_SCRIPT_NAME);
}

// The script file a statusLine command runs, when it is a plain path
// (optionally after sh/bash): "~/.claude/statusline.sh", "bash /x/y.sh".
// null for anything more complex; `home` expands a leading "~".
export function commandScriptPath(command, home) {
    if (typeof command !== 'string')
        return null;
    const parts = command.trim().split(/\s+/);
    let path = parts[0];
    if (/^(?:\/(?:usr\/)?bin\/)?(?:ba|da|z)?sh$/.test(path) && parts.length >= 2)
        path = parts[1];
    else if (parts.length > 1)
        return null;
    if (!path)
        return null;
    path = path.replace(/^["']|["']$/g, '');
    if (path === '~' || path.startsWith('~/'))
        path = `${home}${path.slice(1)}`;
    else if (path.startsWith('$HOME/'))
        path = `${home}${path.slice(5)}`;
    return path.startsWith('/') ? path : null;
}

// A new settings object whose statusLine runs the capture script; null when
// the user already has a statusLine (theirs is never replaced).
export function withCaptureStatusLine(settings, scriptPath) {
    if (statusLineState(settings, scriptPath).kind === 'other')
        return null;
    const base = settings && typeof settings === 'object' && !Array.isArray(settings) ? settings : {};
    if (base.statusLine?.command === scriptPath)
        return null;
    return {...base, statusLine: {type: 'command', command: scriptPath, padding: 0}};
}

// The feed's health for Preferences and the rate-limit hint.
//   off        not turned on
//   unwired    on, but the statusLine doesn't forward
//   waiting    on and wired, no capture yet
//   fresh      newest capture within FRESH_MS
//   stale      older, still usable as a fallback (≤ MAX_STALE_MS)
//   old        older than that: serve no longer uses it
export function feedHealth({enabled, wired, lastCaptureMs = null, now = Date.now()}) {
    if (!enabled)
        return 'off';
    if (!Number.isFinite(lastCaptureMs))
        return wired ? 'waiting' : 'unwired';
    const age = now - lastCaptureMs;
    if (age <= FRESH_MS)
        return 'fresh';
    if (age <= MAX_STALE_MS)
        return 'stale';
    return wired ? 'old' : 'unwired';
}

// Whether a rate-limited Claude row should suggest the feed: only when the
// feed would help (off, or on but not delivering captures).
export function suggestFeed(row, state, health) {
    return row?.provider === 'claude' && state === 'rate_limited' &&
        (health === 'off' || health === 'unwired' || health === 'old');
}

// The one-line hint under a rate-limited Claude card.
export function feedHint(health) {
    if (health === 'off')
        return 'Claude throttles this endpoint. UsageBar can read your quota from Claude Code instead.';
    return 'The Claude Code statusLine feed is on but has no recent captures.';
}
