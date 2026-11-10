import assert from 'node:assert/strict';
import test from 'node:test';

import {
    RESULT_OPTION,
    TIMEOUT_SECS,
    launchFailureText,
    pollState,
    readResult,
    resultNotice,
    resultPath,
    withResultFile,
} from '../usagebar@felipearosr.github.io/helperrun.js';

const ID = '3f9a1c2b-7d4e-4f60-9a2b-3c4d5e6f7a8b';

test('each helper run gets its own result file under the runtime dir', () => {
    assert.equal(resultPath('/run/user/1000', ID), `/run/user/1000/usagebar/helper-${ID}.json`);
    assert.equal(resultPath('/run/user/1000/', ID), `/run/user/1000/usagebar/helper-${ID}.json`);
    // Never relative, never a path that leaves the directory.
    assert.equal(resultPath('run/user/1000', ID), null);
    assert.equal(resultPath('', ID), null);
    assert.equal(resultPath('/run/user/1000', '../../etc/passwd'), null);
    assert.equal(resultPath('/run/user/1000', 'a/b'), null);
    assert.equal(resultPath('/run/user/1000', ''), null);
    assert.equal(resultPath('/run/user/1000', null), null);
});

test('the result file is passed as a trailing option, argv stays fixed', () => {
    const argv = ['/usr/bin/codexbar', 'codex-accounts', 'add'];
    const path = resultPath('/run/user/1000', ID);
    assert.deepEqual(withResultFile(argv, path), [...argv, RESULT_OPTION, path]);
    assert.deepEqual(argv, ['/usr/bin/codexbar', 'codex-accounts', 'add']);
    assert.equal(withResultFile(argv, 'relative.json'), null);
    assert.equal(withResultFile([], path), null);
    assert.equal(withResultFile(null, path), null);
});

test('readResult accepts only a finished result', () => {
    assert.deepEqual(readResult('{"status":"done","message":"Added a Codex account."}'),
        {status: 'done', message: 'Added a Codex account.'});
    assert.deepEqual(readResult('{"status":"failed","message":"  Failed: `codex login` exited with status 1. "}'),
        {status: 'failed', message: 'Failed: `codex login` exited with status 1.'});
    assert.deepEqual(readResult('{"status":"failed"}'), {status: 'failed', message: 'The helper failed.'});
    assert.deepEqual(readResult('{"status":"done","message":7}'), {status: 'done', message: 'Done.'});
    // Half a file reads as not there yet.
    assert.equal(readResult('{"status":"do'), null);
    for (const text of [null, undefined, '', '  ', 'null', '[]', '{}', '{"status":"running"}', 'not json'])
        assert.equal(readResult(text), null, String(text));
    assert.equal(readResult(JSON.stringify({status: 'failed', message: 'x'.repeat(1000)})).message.length, 300);
});

test('pollState waits for the result, not for the terminal, up to the timeout', () => {
    assert.equal(pollState({result: null, elapsedSecs: 0}), 'wait');
    // A terminal server's launcher exits at once; only the result ends the wait.
    assert.equal(pollState({result: null, elapsedSecs: 600}), 'wait');
    assert.equal(pollState({result: {status: 'done', message: ''}, elapsedSecs: 3}), 'done');
    assert.equal(pollState({result: {status: 'failed', message: ''}, elapsedSecs: 3}), 'failed');
    // A result that lands at the deadline still counts.
    assert.equal(pollState({result: {status: 'done'}, elapsedSecs: TIMEOUT_SECS + 5}), 'done');
    assert.equal(pollState({result: null, elapsedSecs: TIMEOUT_SECS}), 'timeout');
    assert.equal(pollState({result: null, elapsedSecs: 10, timeoutSecs: 5}), 'timeout');
    assert.equal(pollState(), 'wait');
});

test('only a failure is notified, with the helper\'s own step', () => {
    assert.equal(resultNotice('done', {status: 'done', message: 'Added a Codex account.'}, 'Codex'), null);
    assert.equal(resultNotice('timeout', null, 'Codex'), null);
    assert.equal(resultNotice('failed', {status: 'failed', message: 'Failed: `codex login` exited with status 1.'},
        'Codex'), 'Adding a Codex account failed. Failed: `codex login` exited with status 1.');
});

test('launch failures name the command to run', () => {
    const argv = ['/usr/bin/codexbar', 'codex-accounts', 'add'];
    assert.equal(launchFailureText(argv, 'Codex', {noTerminal: true}),
        'No terminal found. Run `/usr/bin/codexbar codex-accounts add` in a terminal to add a Codex account.');
    assert.match(launchFailureText(argv, 'Codex'), /^Could not open a terminal\. Run `\/usr\/bin\/codexbar/);
    assert.match(launchFailureText(null, 'Codex'), /codexbar CLI wasn’t found/);
});
