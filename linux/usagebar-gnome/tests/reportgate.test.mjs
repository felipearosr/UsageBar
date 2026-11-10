import test from 'node:test';
import assert from 'node:assert/strict';

import {RETRY_MS, ReportGate, WAIT_MS} from '../usagebar@felipearosr.github.io/reportgate.js';

// Runs the gate the way the extension does, against a fake clock and timers.
// `health(now)` decides how /health answers: {ok, after} (ms until it answers).
function simulate({health, requests = [0], until = 10000}) {
    const gate = new ReportGate();
    const log = {health: [], usage: []};
    let now = 0;
    let queue = [];
    const at = (time, kind, fn) => queue.push({time, kind, fn});
    const run = actions => {
        for (const action of actions) {
            if (action.type === 'health') {
                log.health.push(now);
                const answer = health(now);
                at(now + answer.after, 'answer', () => run(gate.healthResult(answer.ok, now)));
            } else if (action.type === 'window') {
                at(now + action.ms, 'timer', () => run(gate.windowClosed(now)));
            } else if (action.type === 'retry') {
                at(now + action.ms, 'timer', () => run(gate.retryDue(now)));
            } else if (action.type === 'cancelTimers') {
                queue = queue.filter(item => item.kind !== 'timer');
            } else if (action.type === 'usage') {
                log.usage.push(now);
            }
        }
    };
    for (const time of requests)
        at(time, 'request', () => run(gate.request(now)));
    let steps = 0;
    while (queue.length && steps++ < 10000) {
        queue.sort((a, b) => a.time - b.time);
        const next = queue.shift();
        if (next.time > until)
            break;
        now = next.time;
        next.fn();
    }
    return {log, steps, gate};
}

test('a /health that fails instantly is retried on a bounded cadence, and /usage goes when the window closes', () => {
    const {log, steps} = simulate({health: () => ({ok: false, after: 0})});
    assert.ok(steps < 100, `ran ${steps} steps`);
    // One immediate try, then one per RETRY_MS until the window closes.
    assert.ok(log.health.length <= WAIT_MS / RETRY_MS + 1, `sent ${log.health.length} /health`);
    assert.ok(log.health.length >= 2);
    assert.deepEqual(log.usage, [WAIT_MS]);
    // Retries never move the window, and nothing runs after it closes.
    assert.ok(log.health.every(time => time < WAIT_MS));
});

test('a /health that never answers lets /usage go at the end of the window', () => {
    const {log} = simulate({health: () => ({ok: false, after: 60000})});
    assert.deepEqual(log.health, [0]);
    assert.deepEqual(log.usage, [WAIT_MS]);
});

test('a successful /health lets /usage go at once', () => {
    const {log} = simulate({health: now => ({ok: now >= 500, after: 10})});
    assert.deepEqual(log.health, [0, 260, 520]);
    assert.deepEqual(log.usage, [530]);
});

test('several waiting polls send one /usage, and later polls pass straight through', () => {
    const {log, gate} = simulate({health: () => ({ok: true, after: 100}), requests: [0, 20, 40]});
    assert.deepEqual(log.health, [0]);
    assert.deepEqual(log.usage, [100]);
    assert.deepEqual(gate.request(5000), [{type: 'usage'}]);
});

test('a reset waits again', () => {
    const gate = new ReportGate();
    gate.request(0);
    gate.healthResult(true, 10);
    gate.reset();
    assert.deepEqual(gate.request(100).map(action => action.type), ['window', 'health']);
});
