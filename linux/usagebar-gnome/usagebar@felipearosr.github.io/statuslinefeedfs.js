// File access for the Claude Code statusLine feed (statuslinefeed.js holds
// the logic). Shared by the extension (health for the rate-limit hint) and
// the preferences window (status and setup). Reads are cheap local files;
// writes happen only from the preferences window after the user asks.

import Gio from 'gi://Gio';
import GLib from 'gi://GLib';

import {
    CAPTURE_SCRIPT_DIR,
    CAPTURE_SCRIPT_NAME,
    captureScript,
    commandScriptPath,
    feedEnabled,
    feedHealth,
    statusLineState,
    withCaptureStatusLine,
    withStatusLineFeed,
} from './statuslinefeed.js';

const decoder = new TextDecoder();
const encoder = new TextEncoder();

export function codexbarConfigPath() {
    return GLib.build_filenamev([GLib.get_user_config_dir(), 'codexbar', 'config.json']);
}

// Claude Code's settings.json: $CLAUDE_CONFIG_DIR, else ~/.claude.
export function claudeSettingsPath() {
    const dir = GLib.getenv('CLAUDE_CONFIG_DIR') ||
        GLib.build_filenamev([GLib.get_home_dir(), '.claude']);
    return GLib.build_filenamev([dir, 'settings.json']);
}

export function captureScriptPath() {
    return GLib.build_filenamev([GLib.get_user_data_dir(), CAPTURE_SCRIPT_DIR, CAPTURE_SCRIPT_NAME]);
}

// Where the CLI stores captures (Foundation's applicationSupport on Linux is
// the XDG data dir): ~/.local/share/CodexBar/claude-statusline/.
export function captureDir() {
    return GLib.build_filenamev([GLib.get_user_data_dir(), 'CodexBar', 'claude-statusline']);
}

function readText(path) {
    try {
        const [, bytes] = GLib.file_get_contents(path);
        return decoder.decode(bytes);
    } catch {
        return null;
    }
}

function readJson(path) {
    const text = readText(path);
    if (text === null)
        return {missing: true, value: null};
    try {
        return {missing: false, value: JSON.parse(text)};
    } catch {
        return {missing: false, value: null, invalid: true};
    }
}

// Newest capture's modification time in ms, or null.
export function lastCaptureMs() {
    const dir = captureDir();
    let newest = null;
    let handle = null;
    try {
        handle = GLib.Dir.open(dir, 0);
        let name;
        while ((name = handle.read_name()) !== null) {
            if (!name.endsWith('.json'))
                continue;
            const path = GLib.build_filenamev([dir, name]);
            const ms = mtimeMs(path);
            if (ms !== null && (newest === null || ms > newest))
                newest = ms;
        }
    } catch {
        return null;
    } finally {
        handle?.close();
    }
    return newest;
}

function mtimeMs(path) {
    try {
        const info = Gio.File.new_for_path(path)
            .query_info('time::modified', Gio.FileQueryInfoFlags.NONE, null);
        const seconds = info.get_modification_date_time()?.to_unix();
        return Number.isFinite(seconds) ? seconds * 1000 : null;
    } catch {
        return null;
    }
}

// Everything Preferences and the hint need, from local files only.
export function readFeedStatus() {
    const config = readJson(codexbarConfigPath()).value;
    const settingsRead = readJson(claudeSettingsPath());
    const scriptPath = captureScriptPath();
    const command = settingsRead.value?.statusLine?.command;
    const userScript = commandScriptPath(command, GLib.get_home_dir());
    const state = statusLineState(settingsRead.value, scriptPath,
        userScript ? readText(userScript) : null);
    const enabled = feedEnabled(config);
    const last = lastCaptureMs();
    return {
        enabled,
        hasClaude: !!config?.providers?.some?.(p => p?.id === 'claude'),
        settingsInvalid: !!settingsRead.invalid,
        statusLine: state,
        userScript,
        scriptPath,
        lastCaptureMs: last,
        health: feedHealth({enabled, wired: state.forwards, lastCaptureMs: last}),
    };
}

function writeJson(path, value, mode) {
    GLib.mkdir_with_parents(GLib.path_get_dirname(path), 0o700);
    GLib.file_set_contents_full(path, encoder.encode(`${JSON.stringify(value, null, 2)}\n`),
        GLib.FileSetContentsFlags.CONSISTENT, mode);
}

// Turns the feed on or off in config.json. Throws when the config can't be
// read or has no claude provider.
export function setFeedEnabled(on) {
    const path = codexbarConfigPath();
    const read = readJson(path);
    if (!read.value)
        throw new Error('Could not read ~/.config/codexbar/config.json');
    const next = withStatusLineFeed(read.value, on);
    if (next === null && feedEnabled(read.value) !== on)
        throw new Error('Claude is not in the codexbar config');
    if (next)
        writeJson(path, next, 0o600);
}

// Writes the capture script (always refreshed, so a newer UsageBar's lookup
// order lands on the next setup).
export function installCaptureScript() {
    const path = captureScriptPath();
    GLib.mkdir_with_parents(GLib.path_get_dirname(path), 0o755);
    GLib.file_set_contents_full(path, encoder.encode(captureScript()),
        GLib.FileSetContentsFlags.CONSISTENT, 0o755);
    GLib.chmod(path, 0o755);
    return path;
}

// Points Claude Code's statusLine at the capture script when the user has
// none. Keeps a one-time backup of an existing settings.json. Returns false
// when the user has a statusLine of their own (never replaced); throws when
// settings.json exists but isn't valid JSON.
export function wireCaptureStatusLine() {
    const path = claudeSettingsPath();
    const read = readJson(path);
    if (read.invalid)
        throw new Error(`${path} is not valid JSON; not changing it`);
    const scriptPath = installCaptureScript();
    const next = withCaptureStatusLine(read.value ?? {}, scriptPath);
    if (next === null)
        return statusLineState(read.value, scriptPath).kind === 'ours';
    if (!read.missing) {
        const backup = `${path}.usagebar-backup`;
        if (!GLib.file_test(backup, GLib.FileTest.EXISTS))
            GLib.file_set_contents(backup, readText(path));
    }
    writeJson(path, next, 0o644);
    return true;
}

// Puts settings.json back when its statusLine is UsageBar's script (turning
// the feed off). A user's own statusLine is left alone.
export function unwireCaptureStatusLine() {
    const path = claudeSettingsPath();
    const read = readJson(path);
    if (!read.value || statusLineState(read.value, captureScriptPath()).kind !== 'ours')
        return;
    const next = {...read.value};
    delete next.statusLine;
    writeJson(path, next, 0o644);
}
