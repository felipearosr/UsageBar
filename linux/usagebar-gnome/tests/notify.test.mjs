import test from 'node:test';
import assert from 'node:assert/strict';
import {notificationTitle, planNotifications} from '../usagebar@felipearosr.github.io/notify.js';

const NOW = Date.parse('2026-10-12T12:00:00Z');
const RESET = '2026-10-12T15:00:00Z';
const CYCLE = `fixture:Session (5h):${RESET}`;
function row(percent = 84, overrides = {}) {
    return {provider: 'fixture', usage: {primary: {usedPercent: percent,
        windowMinutes: 300, resetsAt: RESET, ...overrides}}};
}
function plan(rows, memo = new Map(), options = {}) {
    return planNotifications({rows, memo, sessionThresholds: [80, 95],
        weeklyThresholds: [80, 95], paceEnabled: false, muted: new Set(),
        now: NOW, displayName: p => `Name ${p}`, ...options});
}

test('a threshold crossing announces once with the injected provider name', () => {
    const first = plan([row()]);
    assert.equal(first.notifications.length, 1);
    assert.equal(first.notifications[0].name, 'Name fixture');
    assert.equal(first.notifications[0].percent, 84);
    assert.equal(first.notifications[0].kind, 'threshold');
    assert.equal(first.memo.get(CYCLE), 80);
    assert.deepEqual(plan([row()], first.memo).notifications, []);
});

test('a higher crossing escalates and never lowers the recorded threshold', () => {
    const first = plan([row()]);
    const higher = plan([row(96)], first.memo);
    assert.equal(higher.notifications.length, 1);
    assert.equal(higher.memo.get(CYCLE), 95);
    const lower = plan([row(81)], higher.memo);
    assert.equal(lower.notifications.length, 0);
    assert.equal(lower.memo.get(CYCLE), 95);
});

test('a new reset timestamp re-arms a window and removes the old visited cycle', () => {
    const first = plan([row()]);
    const next = plan([row(84, {resetsAt: '2026-10-12T20:00:00Z'})], first.memo);
    assert.equal(next.notifications.length, 1);
    assert.equal(next.memo.has(CYCLE), false);
});

test('stale rows carry threshold and pace memory through recovery', () => {
    const r = {...row(), pace: {primary: {willLastToReset: false}}};
    const first = plan([r], new Map(), {paceEnabled: true});
    const stale = plan([{...r, stale: true}], first.memo, {paceEnabled: true});
    assert.equal(stale.notifications.length, 0);
    assert.deepEqual(stale.memo, first.memo);
    assert.equal(plan([r], stale.memo, {paceEnabled: true}).notifications.length, 0);
});

test('muting suppresses announcements and preserves only the matching provider prefix', () => {
    const first = plan([row()]);
    first.memo.set('fixture-other:Session:', 95);
    const muted = plan([row()], first.memo, {muted: new Set(['fixture'])});
    assert.equal(muted.notifications.length, 0);
    assert.equal(muted.memo.get(CYCLE), 80);
    assert.equal(muted.memo.has('fixture-other:Session:'), false);
    assert.equal(plan([row()], muted.memo).notifications.length, 0);
    assert.equal(plan([row()], new Map(), {muted: new Set(['fixture'])}).notifications.length, 0);
});

test('pace announces once per cycle and never while disabled', () => {
    const r = {...row(20), pace: {primary: {willLastToReset: false, summary: 'Fixture pace'}}};
    assert.equal(plan([r]).notifications.length, 0);
    const first = plan([r], new Map(), {paceEnabled: true});
    assert.deepEqual(first.notifications.map(n => n.kind), ['pace']);
    assert.equal(first.memo.get(`${CYCLE}:pace`), true);
    assert.equal(plan([r], first.memo, {paceEnabled: true}).notifications.length, 0);
    const next = {...r, usage: {primary: {...r.usage.primary, resetsAt: '2026-10-13T15:00:00Z'}}};
    assert.equal(plan([next], first.memo, {paceEnabled: true}).notifications.length, 1);
});

test('long and short windows choose their respective threshold lists', () => {
    const short = row(85);
    const long = {...row(85, {windowMinutes: 10080}), provider: 'longfixture'};
    const result = plan([short, long], new Map(), {sessionThresholds: [95], weeklyThresholds: [80]});
    assert.deepEqual(result.notifications.map(n => n.provider), ['longfixture']);
});

test('missing durations use the injected reset horizon to choose thresholds', () => {
    const result = plan([row(85, {windowMinutes: null, resetsAt: '2026-10-14T12:00:00Z'})],
        new Map(), {sessionThresholds: [95], weeklyThresholds: [80]});
    assert.equal(result.notifications.length, 1);
});

test('absent rows keep recent dated cycles and prune cycles over an hour past reset', () => {
    const recent = 'fixture:Weekly:2026-10-12T11:50:00Z';
    const old = 'fixture:Weekly:2026-10-12T10:00:00Z';
    const boundary = 'fixture:Weekly:2026-10-12T11:00:00Z';
    const result = plan([], new Map([[recent, 80], [`${recent}:pace`, true],
        [old, 95], [`${old}:pace`, true], [boundary, 80]]));
    assert.deepEqual(result.memo, new Map([[recent, 80], [`${recent}:pace`, true], [boundary, 80]]));
});

test('expired carried cycles are pruned even while their provider is stale or muted', () => {
    const key = 'fixture:Session:2026-10-12T10:00:00Z';
    for (const options of [{stale: true}, {muted: true}]) {
        const result = plan([{...row(), stale: !!options.stale}], new Map([[key, 80], [`${key}:pace`, true]]),
            {muted: new Set(options.muted ? ['fixture'] : [])});
        assert.equal(result.memo.size, 0);
    }
});

test('undated or invalid cycles survive only while their row is present', () => {
    const memo = new Map([['fixture:Session:', 80], ['fixture:Session::pace', true],
        ['fixture:Session:invalid', 95]]);
    assert.deepEqual(plan([{...row(), stale: true}], memo).memo, memo);
    assert.equal(plan([], memo).memo.size, 0);
});

test('ISO timezone offsets and colons in model titles do not defeat expiry pruning', () => {
    const old = 'fixture:Model: Monthly:2026-10-12T12:00:00+02:00';
    const recent = 'fixture:Model: Monthly:2026-10-12T13:50:00+02:00';
    const result = plan([], new Map([[old, 80], [`${old}:pace`, true], [recent, 80]]));
    assert.deepEqual(result.memo, new Map([[recent, 80]]));
});

test('re-enable reuses a plain memo without repeating the current cycle', () => {
    const beforeDisable = plan([row()]);
    const afterEnable = plan([row()], beforeDisable.memo);
    assert.deepEqual(afterEnable.notifications, []);
    assert.deepEqual(afterEnable.memo, beforeDisable.memo);
});

test('tertiary and named windows participate without inventing pace for extras', () => {
    const r = {provider: 'fixture', usage: {tertiary: {usedPercent: 84, resetsAt: RESET},
        extraRateWindows: [{id: 'model', title: 'Fixture model', window: {usedPercent: 84, resetsAt: RESET}},
            {id: 'missing', window: {usedPercent: null}}]}, pace: {tertiary: {willLastToReset: false}}};
    const result = plan([r], new Map(), {paceEnabled: true});
    assert.deepEqual(result.notifications.map(n => [n.kind, n.label]),
        [['threshold', 'Monthly'], ['pace', 'Monthly'], ['threshold', 'Fixture model']]);
    assert.equal(result.notifications[2].pace, null);
});

test('planning does not mutate its input memo or announce below all thresholds', () => {
    const memo = new Map();
    const result = plan([row(20)], memo);
    assert.equal(memo.size, 0);
    assert.equal(result.notifications.length, 0);
    assert.equal(result.memo.size, 0);
    assert.notEqual(result.memo, memo);
});

// Provider Accounts: two accounts of the fixture provider, Work active.
const WORK = 'token:0d9e8f7a-6b5c';
const HOME = 'token:6f0c2a9e-1b4d';
function account(id, percent, overrides = {}) {
    return {...row(percent), accountId: id, accountLabel: id === WORK ? 'Work' : 'Home',
        active: id === WORK, ...overrides};
}
const WORK_CYCLE = `fixture#${encodeURIComponent(WORK)}:Session (5h):${RESET}`;

test('two accounts crossing a threshold give two notifications naming each account', () => {
    const first = plan([account(WORK, 84), account(HOME, 90)]);
    assert.deepEqual(first.notifications.map(n => [n.accountId, n.account, n.percent]),
        [[WORK, 'Work', 84], [HOME, 'Home', 90]]);
    assert.equal(first.memo.get(WORK_CYCLE), 80);
    assert.deepEqual(plan([account(WORK, 85), account(HOME, 91)], first.memo).notifications, []);
});

test('one account crossing does not silence the other account', () => {
    const first = plan([account(WORK, 84), account(HOME, 20)]);
    assert.equal(first.notifications.length, 1);
    const second = plan([account(WORK, 86), account(HOME, 82)], first.memo);
    assert.deepEqual(second.notifications.map(n => n.accountId), [HOME]);
    assert.deepEqual(plan([account(WORK, 86), account(HOME, 83)], second.memo).notifications, []);
});

test('changing the active account re-fires nothing', () => {
    const first = plan([account(WORK, 84), account(HOME, 90)]);
    const switched = plan([account(WORK, 84, {active: false}), account(HOME, 90, {active: true})], first.memo);
    assert.deepEqual(switched.notifications, []);
    assert.deepEqual(plan([account(WORK, 84), account(HOME, 90)], switched.memo).notifications, []);
});

test('provider-keyed memory moves to the account the popover showed, once', () => {
    // The first /usage before the /health report: one untagged row (the active account).
    const before = plan([row(84)]);
    assert.equal(before.notifications.length, 1);
    const after = plan([account(WORK, 84), account(HOME, 30)], before.memo);
    assert.deepEqual(after.notifications, []);
    assert.equal(after.memo.get(WORK_CYCLE), 80);
    assert.equal(after.memo.has(CYCLE), false);
    // Home becoming active later inherits nothing: its own first crossing announces.
    const home = plan([account(WORK, 84, {active: false}), account(HOME, 84, {active: true})], after.memo);
    assert.deepEqual(home.notifications.map(n => n.accountId), [HOME]);
});

test('provider-keyed memory waits while the active account is stale or the provider muted', () => {
    const before = plan([row(84)]);
    const stale = plan([account(WORK, 84, {stale: true}), account(HOME, 30)], before.memo);
    assert.equal(stale.memo.get(CYCLE), 80);
    assert.deepEqual(plan([account(WORK, 84), account(HOME, 30)], stale.memo).notifications, []);
    const muted = plan([account(WORK, 84), account(HOME, 30)], before.memo, {muted: new Set(['fixture'])});
    assert.equal(muted.memo.get(CYCLE), 80);
    assert.deepEqual(plan([account(WORK, 84), account(HOME, 30)], muted.memo).notifications, []);
});

test('back to one untagged row, the accounts\' memory keeps it quiet', () => {
    const accounts = plan([account(WORK, 84), account(HOME, 96)]);
    const single = plan([row(90)], accounts.memo);
    assert.deepEqual(single.notifications, []);
    assert.equal(single.memo.get(CYCLE), 95);
    // The accounts' own dated cycles are kept, should they come back.
    assert.deepEqual(plan([account(WORK, 84), account(HOME, 96)], single.memo).notifications, []);
});

test('a stale account keeps its memory while the other account is planned', () => {
    const first = plan([account(WORK, 84), account(HOME, 84)]);
    const stale = plan([account(WORK, 84), account(HOME, 84, {stale: true})], first.memo);
    assert.deepEqual(stale.notifications, []);
    assert.deepEqual(plan([account(WORK, 84), account(HOME, 84)], stale.memo).notifications, []);
});

test('a single tagged account or an untagged row carries no account name', () => {
    assert.equal(plan([account(WORK, 84)]).notifications[0].account, null);
    const single = plan([row()]).notifications[0];
    assert.equal(single.account, null);
    assert.equal(single.accountId, null);
});

test('titles name the account only when the provider has several', () => {
    const base = {kind: 'threshold', name: 'OpenRouter', label: 'Session (5h)', percent: 84, account: null};
    assert.equal(notificationTitle(base), 'OpenRouter Session (5h) at 84%');
    assert.equal(notificationTitle({...base, account: 'Account 2'}), 'OpenRouter (Account 2) Session (5h) at 84%');
    assert.equal(notificationTitle({...base, kind: 'pace'}), 'OpenRouter Session (5h) won\'t last to reset');
    assert.equal(notificationTitle({...base, kind: 'pace', account: 'Work'}),
        'OpenRouter (Work) Session (5h) won\'t last to reset');
});
