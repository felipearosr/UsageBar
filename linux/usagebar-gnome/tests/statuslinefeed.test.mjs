import test from 'node:test';
import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, symlinkSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';

import {
    FRESH_MS,
    MAX_STALE_MS,
    captureScript,
    commandScriptPath,
    feedEnabled,
    feedHealth,
    feedHint,
    feedOriginLabel,
    forwardSnippet,
    forwardsCapture,
    statusLineState,
    suggestFeed,
    withCaptureStatusLine,
    withStatusLineFeed,
} from '../usagebar@felipearosr.github.io/statuslinefeed.js';

const SCRIPT = '/home/u/.local/share/usagebar/claude-statusline-capture.sh';
const config = (claude = {id: 'claude', enabled: true, source: 'oauth'}) =>
    ({version: 1, providers: [{id: 'codex', enabled: true}, claude]});

test('feedEnabled reads only the claude entry', () => {
    assert.equal(feedEnabled(config()), false);
    assert.equal(feedEnabled(config({id: 'claude', statusLineFeed: true})), true);
    assert.equal(feedEnabled({providers: [{id: 'codex', statusLineFeed: true}]}), false);
    assert.equal(feedEnabled(null), false);
});

test('withStatusLineFeed sets and removes the flag, keeping the rest', () => {
    const on = withStatusLineFeed(config(), true);
    assert.deepEqual(on.providers[1], {id: 'claude', enabled: true, source: 'oauth', statusLineFeed: true});
    assert.deepEqual(on.providers[0], {id: 'codex', enabled: true});
    assert.equal(on.version, 1);
    assert.equal(withStatusLineFeed(on, true), null);
    const off = withStatusLineFeed(on, false);
    assert.equal('statusLineFeed' in off.providers[1], false);
    assert.equal(withStatusLineFeed({providers: [{id: 'codex'}]}, true), null);
    assert.equal(withStatusLineFeed({}, true), null);
});

test('statusLineState tells none, ours and the user\'s own apart', () => {
    assert.equal(statusLineState({}, SCRIPT).kind, 'none');
    assert.equal(statusLineState({statusLine: {command: '  '}}, SCRIPT).kind, 'none');
    assert.equal(statusLineState(null, SCRIPT).kind, 'none');
    const ours = statusLineState({statusLine: {command: SCRIPT}}, SCRIPT);
    assert.deepEqual([ours.kind, ours.forwards], ['ours', true]);
    const own = statusLineState({statusLine: {command: '~/.claude/statusline.sh'}}, SCRIPT);
    assert.deepEqual([own.kind, own.forwards], ['other', false]);
    const forwarding = statusLineState({statusLine: {command: '~/.claude/statusline.sh'}}, SCRIPT,
        'input=$(cat)\nprintf "%s" "$input" | codexbar claude statusline capture &');
    assert.equal(forwarding.forwards, true);
});

test('forwardsCapture spots the CLI command and the installed script', () => {
    assert.equal(forwardsCapture('x | /usr/libexec/usagebar/codexbar claude statusline capture'), true);
    assert.equal(forwardsCapture(`printf '%s' "$input" | ${SCRIPT}`), true);
    assert.equal(forwardsCapture('echo hi'), false);
    assert.equal(forwardsCapture(null), false);
});

test('commandScriptPath finds the script a plain command runs', () => {
    assert.equal(commandScriptPath('~/.claude/statusline.sh', '/home/u'), '/home/u/.claude/statusline.sh');
    assert.equal(commandScriptPath('bash ~/x.sh', '/home/u'), '/home/u/x.sh');
    assert.equal(commandScriptPath('/bin/sh /opt/s.sh', '/home/u'), '/opt/s.sh');
    assert.equal(commandScriptPath('$HOME/s.sh', '/home/u'), '/home/u/s.sh');
    assert.equal(commandScriptPath('npx ccstatusline', '/home/u'), null);
    assert.equal(commandScriptPath('relative.sh', '/home/u'), null);
    assert.equal(commandScriptPath(undefined, '/home/u'), null);
});

test('withCaptureStatusLine never replaces the user\'s statusLine', () => {
    const settings = {model: 'opus', hooks: {Stop: []}};
    const next = withCaptureStatusLine(settings, SCRIPT);
    assert.deepEqual(next, {...settings, statusLine: {type: 'command', command: SCRIPT, padding: 0}});
    assert.equal(withCaptureStatusLine(next, SCRIPT), null);
    assert.equal(withCaptureStatusLine({statusLine: {type: 'command', command: '~/s.sh'}}, SCRIPT), null);
    assert.deepEqual(withCaptureStatusLine(null, SCRIPT).statusLine.command, SCRIPT);
});

test('forwardSnippet pipes $input to the script', () => {
    assert.equal(forwardSnippet(SCRIPT), `printf '%s' "$input" | ${SCRIPT}`);
});

test('feedHealth', () => {
    const now = 10 * MAX_STALE_MS;
    assert.equal(feedHealth({enabled: false, wired: true, lastCaptureMs: now, now}), 'off');
    assert.equal(feedHealth({enabled: true, wired: false, lastCaptureMs: null, now}), 'unwired');
    assert.equal(feedHealth({enabled: true, wired: true, lastCaptureMs: null, now}), 'waiting');
    assert.equal(feedHealth({enabled: true, wired: true, lastCaptureMs: now - FRESH_MS, now}), 'fresh');
    assert.equal(feedHealth({enabled: true, wired: false, lastCaptureMs: now - FRESH_MS - 1, now}), 'stale');
    assert.equal(feedHealth({enabled: true, wired: true, lastCaptureMs: now - MAX_STALE_MS - 1, now}), 'old');
    assert.equal(feedHealth({enabled: true, wired: false, lastCaptureMs: now - MAX_STALE_MS - 1, now}), 'unwired');
});

test('suggestFeed only for a rate-limited Claude row the feed would help', () => {
    const claude = {provider: 'claude'};
    assert.equal(suggestFeed(claude, 'rate_limited', 'off'), true);
    assert.equal(suggestFeed(claude, 'rate_limited', 'unwired'), true);
    assert.equal(suggestFeed(claude, 'rate_limited', 'old'), true);
    for (const health of ['waiting', 'fresh', 'stale', null])
        assert.equal(suggestFeed(claude, 'rate_limited', health), false);
    assert.equal(suggestFeed(claude, 'offline', 'off'), false);
    assert.equal(suggestFeed({provider: 'codex'}, 'rate_limited', 'off'), false);
    assert.match(feedHint('off'), /Claude Code/);
    assert.match(feedHint('unwired'), /no recent captures/);
});

test('feedOriginLabel names where the newest capture came from', () => {
    assert.equal(feedOriginLabel('t3code'), 'T3 Code');
    assert.equal(feedOriginLabel('orca'), 'Orca');
    assert.equal(feedOriginLabel('orca-dev'), 'Orca dev');
    assert.equal(feedOriginLabel('statusline'), 'your Claude Code statusLine');
    // Captures written before origins existed carry none.
    assert.equal(feedOriginLabel(null), 'your Claude Code statusLine');
});

test('the capture script forwards stdin to the CLI and prints nothing', () => {
    const dir = mkdtempSync(join(tmpdir(), 'usagebar-feed-'));
    const out = join(dir, 'received');
    const stub = join(dir, 'stub');
    writeFileSync(stub, `#!/bin/sh\n[ "$1 $2 $3" = "claude statusline capture" ] && cat > "${out}"\n`);
    chmodSync(stub, 0o755);
    const script = join(dir, 'capture.sh');
    writeFileSync(script, captureScript());
    chmodSync(script, 0o755);
    const printed = execFileSync(script, {
        input: '{"rate_limits":{}}',
        env: {...process.env, CODEXBAR_BIN: stub},
        encoding: 'utf8',
    });
    assert.equal(printed, '');
    // The CLI runs in the background; give it a moment.
    for (let i = 0; i < 50 && !existsSync(out); i++)
        execFileSync('sleep', ['0.05']);
    for (let i = 0; i < 50 && readFileSync(out, 'utf8') === ''; i++)
        execFileSync('sleep', ['0.05']);
    assert.equal(readFileSync(out, 'utf8'), '{"rate_limits":{}}');
});

test('the capture script exits quietly with no CLI anywhere', () => {
    const dir = mkdtempSync(join(tmpdir(), 'usagebar-feed-'));
    const script = join(dir, 'capture.sh');
    writeFileSync(script, captureScript());
    chmodSync(script, 0o755);
    // A PATH with only `cat`, so the script reads its stdin but finds no CLI.
    const bin = join(dir, 'bin');
    mkdirSync(bin);
    symlinkSync(execFileSync('sh', ['-c', 'command -v cat'], {encoding: 'utf8'}).trim(), join(bin, 'cat'));
    const printed = execFileSync(script, {
        input: '{}',
        env: {PATH: bin, HOME: dir},
        encoding: 'utf8',
    });
    assert.equal(printed, '');
});
