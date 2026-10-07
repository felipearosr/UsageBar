import test from 'node:test';
import assert from 'node:assert/strict';

import {
    holdOpenArgv,
    isAuthError,
    loginActionFor,
    loginCommandFor,
    terminalArgv,
} from '../usagebar@felipearosr.github.io/authlogin.js';

const provider = message => ({code: 1, kind: 'provider', message});

test('auth error texts from the Swift providers classify as auth', () => {
    for (const message of [
        'Codex OAuth token expired or invalid. Run `codex login` to re-authenticate.',
        'Codex auth.json not found. Run `codex login` to sign in.',
        'Codex auth.json needs refresh. Reauthenticate this account or run `codex login` in the same Codex home.',
        'Refresh token expired. Please run `codex` to log in again.',
        'Refresh token was revoked. Please run `codex` to log in again.',
        'codex account authentication required to read rate limits',
        'Claude OAuth request unauthorized. Run `claude` to re-authenticate.',
        'Claude OAuth credentials missing. Run `claude` to authenticate.',
        'Claude OAuth credentials are invalid.',
        'Claude CLI is not logged in.',
        'Claude CLI token expired. Run `claude login` to refresh.',
        'Claude OAuth token expired. CodexBar CLI does not launch Claude to refresh credentials. Run `claude login`, then retry.',
        'API Error: 401 {"type":"error","error":{"type":"authentication_error"}}',
        'Not authenticated to Grok. Run `grok login`.',
        'Kilo authentication failed (401/403). Refresh KILO_API_KEY or run `kilo auth login`.',
        'Codebuff API token not configured. Set CODEBUFF_API_KEY or run `codebuff login` to create one.',
    ])
        assert.equal(isAuthError(provider(message)), true, message);
});

test('transport, rate-limit and setup errors are not auth', () => {
    for (const message of [
        'codex app-server closed stdout',
        'Claude OAuth usage endpoint is rate limited by Anthropic right now. Wait a few minutes, '
            + 'then click Refresh. If it keeps happening, run `claude logout && claude login`, then try again.',
        'Codex is configured for Amazon Bedrock; ChatGPT rate limits are unavailable. '
            + 'Disable the Codex usage card or use cost-based tracking.',
        'Claude OAuth credentials expired and CodexBar cannot read them back: Claude Code keeps them only in '
            + 'its own Keychain item.',
        'Found sessions, but no rate limit events yet.',
        'Claude OAuth credentials read failed: permission denied',
        'provider fetch failed',
        '',
    ])
        assert.equal(isAuthError(provider(message)), false, message);
});

test('structured code and kind rule errors out before the message is read', () => {
    assert.equal(isAuthError({code: 2, kind: 'provider', message: 'Run `codex login`'}), false);
    assert.equal(isAuthError({code: 4, kind: 'provider', message: 'token expired'}), false);
    assert.equal(isAuthError({code: 1, kind: 'config', message: 'unauthorized'}), false);
    assert.equal(isAuthError({message: 'Claude CLI is not logged in.'}), true);
    assert.equal(isAuthError('Not authenticated to Grok.'), true);
    assert.equal(isAuthError(null), false);
});

test('login commands exist only for providers with a documented login CLI', () => {
    assert.deepEqual(loginCommandFor('codex'), ['codex', 'login']);
    assert.deepEqual(loginCommandFor('claude'), ['claude', 'auth', 'login']);
    assert.equal(loginCommandFor('gemini'), null);
    assert.equal(loginCommandFor('cursor'), null);
});

test('loginActionFor needs both an auth error and a known provider', () => {
    const authError = provider('Codex OAuth token expired or invalid. Run `codex login` to re-authenticate.');
    assert.deepEqual(loginActionFor({provider: 'codex', error: authError}), ['codex', 'login']);
    assert.equal(loginActionFor({provider: 'codex', error: provider('codex app-server closed stdout')}), null);
    assert.equal(loginActionFor({provider: 'gemini', error: authError}), null);
    assert.equal(loginActionFor({provider: 'codex'}), null);
    assert.equal(loginActionFor(null), null);
});

test('terminalArgv prefers xdg-terminal-exec then falls back in order', () => {
    const argv = ['/usr/bin/codex', 'login'];
    const only = names => bin => (names.includes(bin) ? `/usr/bin/${bin}` : null);

    assert.deepEqual(terminalArgv(argv, only(['xdg-terminal-exec', 'gnome-terminal'])),
        ['/usr/bin/xdg-terminal-exec', ...holdOpenArgv(argv)]);
    assert.deepEqual(terminalArgv(argv, only(['ptyxis', 'xterm'])),
        ['/usr/bin/ptyxis', '--', ...holdOpenArgv(argv)]);
    assert.deepEqual(terminalArgv(argv, only(['kgx'])),
        ['/usr/bin/kgx', '-e', ...holdOpenArgv(argv)]);
    assert.equal(terminalArgv(argv, only([])), null);
});

test('holdOpenArgv passes the command as positional args, not interpolated text', () => {
    const held = holdOpenArgv(['/opt/my tools/codex', 'login']);
    assert.equal(held[0], 'sh');
    assert.equal(held[1], '-c');
    assert.match(held[2], /"\$@"/);
    assert.deepEqual(held.slice(-2), ['/opt/my tools/codex', 'login']);
});
