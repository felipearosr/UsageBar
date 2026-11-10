import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {spawnSync} from 'node:child_process';
import test from 'node:test';

import {holdOpenArgv, terminalArgv} from '../usagebar@felipearosr.github.io/authlogin.js';
import {
    TIMEOUT_SECS,
    addExitNotice,
    launchFailureText,
    markerPath,
    readMarker,
    watchState,
} from '../usagebar@felipearosr.github.io/terminalwatch.js';

const ID = '3f9a1c2b-7d4e-4f60-9a2b-3c4d5e6f7a8b';

test('each terminal run gets its own marker under the runtime dir', () => {
    assert.equal(markerPath('/run/user/1000', ID), `/run/user/1000/usagebar/terminal-${ID}.status`);
    assert.equal(markerPath('/run/user/1000/', ID), `/run/user/1000/usagebar/terminal-${ID}.status`);
    // Never relative, never a path that leaves the directory.
    for (const [dir, id] of [['run/user/1000', ID], ['', ID], ['/run/user/1000', '../../etc/passwd'],
        ['/run/user/1000', 'a/b'], ['/run/user/1000', ''], ['/run/user/1000', null], [null, ID]])
        assert.equal(markerPath(dir, id), null, `${dir} ${id}`);
});

test('the marker is a positional argument after the trap line', () => {
    const marker = markerPath('/run/user/1000', ID);
    const held = holdOpenArgv(['/opt/my tools/codexbar', 'codex-accounts', 'add'], marker);
    assert.equal(held[0], 'sh');
    assert.match(held[2], /^trap : INT QUIT; m=\$1; shift; "\$@"; status=\$\?; printf %s "\$status" > "\$m";/);
    assert.deepEqual(held.slice(3), ['usagebar-login', marker, '/opt/my tools/codexbar', 'codex-accounts', 'add']);
    // Without a marker the wrapper is unchanged.
    assert.deepEqual(holdOpenArgv(['codex', 'login'], null), holdOpenArgv(['codex', 'login']));
    assert.doesNotMatch(holdOpenArgv(['codex', 'login'])[2], /\$m/);
    const only = name => name === 'xdg-terminal-exec' ? '/usr/bin/xdg-terminal-exec' : null;
    assert.deepEqual(terminalArgv(['codex', 'login'], only, marker),
        ['/usr/bin/xdg-terminal-exec', ...holdOpenArgv(['codex', 'login'], marker)]);
});

test('the wrapper writes the exit status before waiting for Enter', () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'terminalwatch-'));
    try {
        for (const [command, expected] of [[['/bin/sh', '-c', 'exit 0'], 0], [['/bin/sh', '-c', 'exit 3'], 3],
            [['/bin/sh', '-c', 'kill -INT 0; sleep 2; exit 0'], 130]]) {
            const marker = path.join(dir, `m-${expected}`);
            const [sh, ...rest] = holdOpenArgv(command, marker);
            const result = spawnSync(sh, rest, {input: '\n', detached: true, encoding: 'utf8', timeout: 10000});
            assert.equal(result.status, expected);
            assert.equal(readMarker(fs.readFileSync(marker, 'utf8')), expected);
            assert.match(result.stdout, /Press Enter to close/);
        }
    } finally {
        fs.rmSync(dir, {recursive: true, force: true});
    }
});

test('readMarker accepts only an exit status', () => {
    assert.equal(readMarker('0'), 0);
    assert.equal(readMarker('130\n'), 130);
    assert.equal(readMarker('255'), 255);
    for (const text of [null, undefined, '', '  ', '256', '-1', '1.5', 'done', '12a', '1234'])
        assert.equal(readMarker(text), null, String(text));
});

test('watchState waits for the marker, not for the terminal, up to the timeout', () => {
    assert.equal(watchState({status: null, elapsedSecs: 0}), 'wait');
    // A terminal server's launcher exits at once; only the marker ends the wait.
    assert.equal(watchState({status: null, elapsedSecs: 600}), 'wait');
    assert.equal(watchState({status: 0, elapsedSecs: 3}), 'exited');
    assert.equal(watchState({status: 1, elapsedSecs: 3}), 'exited');
    // A status that lands at the deadline still counts.
    assert.equal(watchState({status: 0, elapsedSecs: TIMEOUT_SECS + 5}), 'exited');
    assert.equal(watchState({status: null, elapsedSecs: TIMEOUT_SECS}), 'timeout');
    assert.equal(watchState({status: null, elapsedSecs: 10, timeoutSecs: 5}), 'timeout');
    // The extension was disabled or reloaded: stop without acting.
    assert.equal(watchState({status: 0, stale: true}), 'stop');
    assert.equal(watchState(), 'wait');
});

test('only an unsuccessful add is notified', () => {
    assert.equal(addExitNotice(0, 'Codex'), null);
    assert.equal(addExitNotice(null, 'Codex'), null);
    assert.equal(addExitNotice(130, 'Codex'), 'Adding a Codex account was cancelled.');
    assert.match(addExitNotice(1, 'Codex'), /^Adding a Codex account didn’t finish\. The terminal shows/);
});

test('launch failures name the command to run', () => {
    const argv = ['/usr/bin/codexbar', 'codex-accounts', 'add'];
    assert.equal(launchFailureText(argv, 'Codex', {noTerminal: true}),
        'No terminal found. Run `/usr/bin/codexbar codex-accounts add` in a terminal to add a Codex account.');
    assert.match(launchFailureText(argv, 'Codex'), /^Could not open a terminal\. Run `\/usr\/bin\/codexbar/);
    assert.match(launchFailureText(null, 'Codex'), /codexbar CLI wasn’t found/);
});
