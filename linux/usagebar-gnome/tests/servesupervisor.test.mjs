import test from 'node:test';
import assert from 'node:assert/strict';
import {ServeSupervisor} from '../usagebar@felipearosr.github.io/servesupervisor.js';

function harness() {
    const timers = new Map();
    const removed = [];
    const states = [];
    const procs = [];
    let clock = 0;
    let nextId = 0;
    let port = 42000;
    const deps = {
        pickPort: () => ++port,
        spawn: argv => {
            const proc = {
                argv, terminated: 0, killed: 0,
                wait(cb) { this.exit = cb; },
                terminate() { this.terminated++; },
                kill() { this.killed++; },
            };
            procs.push(proc);
            return proc;
        },
        addTimeout: (secs, cb) => {
            timers.set(++nextId, {secs, cb});
            return nextId;
        },
        removeTimeout: id => {
            removed.push(id);
            timers.delete(id);
        },
        now: () => clock,
    };
    const supervisor = new ServeSupervisor('/stub', 60, (...args) => states.push(args), deps, 120);
    return {
        supervisor, deps, timers, procs, states, removed,
        advance(ms) { clock += ms; },
        fire(id = timers.keys().next().value) {
            const timer = timers.get(id);
            assert.ok(timer, `timer ${id} exists`);
            timers.delete(id);
            timer.cb();
            return timer.secs;
        },
    };
}

test('start spawns once with the existing serve arguments and reports its port', () => {
    const h = harness();
    h.supervisor.start();
    h.supervisor.start();
    assert.equal(h.procs.length, 1);
    assert.deepEqual(h.procs[0].argv, ['/stub', 'serve', '--port', '42001',
        '--refresh-interval', '60', '--request-timeout', '120']);
    assert.deepEqual(h.states, [[42001, '']]);
});

test('late exit after restart cannot clear the replacement or schedule another child', () => {
    const h = harness();
    h.supervisor.start();
    h.supervisor.restart(120);
    h.procs[0].exit();
    assert.equal(h.supervisor.port, 42002);
    assert.deepEqual(h.states, [[42001, ''], [42002, '']]);
    assert.equal(h.timers.size, 0);
    assert.equal(h.procs[1].argv[5], '120');
    h.procs[1].exit();
    assert.equal(h.timers.size, 1);
    assert.match(h.states.at(-1)[1], /exited/);
});

test('crash loops back off at 2, 4, 8, 16 and at most 30 seconds', () => {
    const h = harness();
    h.supervisor.start();
    const delays = [];
    for (let i = 0; i < 7; i++) {
        h.procs.at(-1).exit();
        delays.push(h.fire());
    }
    assert.deepEqual(delays, [2, 4, 8, 16, 30, 30, 30]);
});

test('a child alive for thirty seconds resets the backoff', () => {
    const h = harness();
    h.supervisor.start();
    for (let i = 0; i < 3; i++) {
        h.procs.at(-1).exit();
        h.fire();
    }
    h.advance(31000);
    h.procs.at(-1).exit();
    assert.equal(h.fire(), 2);
});

test('each respawn chooses a fresh port', () => {
    const h = harness();
    h.supervisor.start();
    h.procs[0].exit();
    h.fire();
    assert.deepEqual(h.procs.map(p => p.argv[3]), ['42001', '42002']);
});

test('stop sends SIGTERM before the three second SIGKILL fallback', () => {
    const h = harness();
    h.supervisor.start();
    h.supervisor.stop();
    assert.equal(h.supervisor.port, 0);
    assert.equal(h.procs[0].terminated, 1);
    assert.equal(h.procs[0].killed, 0);
    assert.equal(h.fire(), 3);
    assert.equal(h.procs[0].killed, 1);
    h.procs[0].exit();
    assert.equal(h.timers.size, 0);
});

test('an exit during the grace period removes the kill timer and never restarts', () => {
    const h = harness();
    h.supervisor.start();
    h.supervisor.stop();
    const id = [...h.timers.keys()][0];
    h.procs[0].exit();
    assert.deepEqual(h.removed, [id]);
    assert.equal(h.timers.size, 0);
    assert.equal(h.procs[0].killed, 0);
});

test('port allocation failure reports the error and retries', () => {
    const h = harness();
    h.deps.pickPort = () => { throw new Error('unavailable'); };
    h.supervisor.start();
    assert.deepEqual(h.states, [[null, 'no free loopback port: unavailable']]);
    assert.equal(h.procs.length, 0);
    assert.equal(h.fire(), 2);
    assert.equal(h.fire(), 4);
});

test('spawn failure backs off and stop cancels its pending restart', () => {
    const h = harness();
    h.deps.spawn = () => { throw new Error('not executable'); };
    h.supervisor.start();
    assert.match(h.states[0][1], /failed to start codexbar serve: not executable/);
    assert.equal(h.supervisor.port, 0);
    h.fire();
    assert.equal([...h.timers.values()][0].secs, 4);
    h.supervisor.stop();
    assert.equal(h.timers.size, 0);
});

test('rapid restarts keep independent shutdown timers for all retiring children', () => {
    const h = harness();
    h.supervisor.start();
    h.supervisor.restart(90);
    h.supervisor.restart(120);
    assert.equal(h.timers.size, 2);
    h.procs[0].exit();
    assert.equal(h.timers.size, 1);
    h.fire();
    assert.deepEqual(h.procs.map(p => [p.terminated, p.killed]), [[1, 0], [1, 1], [0, 0]]);
    assert.equal(h.supervisor.port, 42003);
    h.procs[1].exit();
    assert.equal(h.timers.size, 0);
});

test('repeated stop never replaces a pending kill timer', () => {
    const h = harness();
    h.supervisor.start();
    h.supervisor.stop();
    h.supervisor.stop();
    assert.equal(h.procs[0].terminated, 1);
    assert.equal(h.timers.size, 1);
});
