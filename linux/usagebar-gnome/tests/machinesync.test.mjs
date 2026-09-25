import test from 'node:test';
import assert from 'node:assert/strict';

import {
    coverageText,
    machinesView,
    nextPushDelaySecs,
    planSyncTick,
    spendText,
    SYNC_PUSH_SECS,
    SYNC_STALE_SECS,
} from '../usagebar@felipearosr.github.io/machinesync.js';

const NOW = Date.parse('2026-09-24T12:30:00Z');
const secs = n => n * 1000;

function spend(costUSD, extra = {}) {
    return {costUSD, costIncomplete: false, totalTokens: 0, requests: 0, ...extra};
}

function payload(overrides = {}) {
    return {
        paired: true,
        refreshedAt: '2026-09-24T12:29:00Z',
        status: {
            generatedAt: '2026-09-24T12:29:00Z',
            today: '2026-09-24',
            total: {today: spend(2.5, {costIncomplete: true}), last30Days: spend(4)},
            errors: [],
            machines: [
                {
                    machineId: 'laptopAAAAAAAAAAAAAAAA',
                    displayName: 'laptop',
                    isThisMachine: true,
                    active: true,
                    retired: false,
                    lastSeen: '2026-09-24T12:28:00Z',
                    today: spend(2),
                    last30Days: spend(3),
                    models: [
                        {provider: 'claude', model: 'claude-sonnet-4-5', spend: spend(2)},
                        {provider: 'codex', model: 'gpt-5', spend: spend(1)},
                    ],
                    coverage: {from: '2026-06-25', to: '2026-09-24'},
                },
                {
                    machineId: 'deskAAAAAAAAAAAAAAAAAA',
                    displayName: 'desk',
                    isThisMachine: false,
                    active: true,
                    retired: false,
                    lastSeen: '2026-09-24T12:27:00Z',
                    today: spend(0.5, {costIncomplete: true}),
                    last30Days: spend(1, {costIncomplete: true}),
                    models: [],
                    coverage: {from: '2026-09-24', to: '2026-09-24'},
                },
            ],
        },
        ...overrides,
    };
}

test('push jitter stays within 150 s ± 20 s', () => {
    assert.equal(nextPushDelaySecs(() => 0), 130);
    assert.equal(nextPushDelaySecs(() => 0.5), 150);
    assert.equal(nextPushDelaySecs(() => 1), 170);
});

test('nothing is pushed or read while this Machine is not paired', () => {
    assert.deepEqual(planSyncTick({now: NOW, paired: false, tabVisible: true}), {push: false, read: false});
});

test('push runs once due and never overlaps itself', () => {
    assert.equal(planSyncTick({now: NOW, paired: true, nextPushAt: 0}).push, true);
    assert.equal(planSyncTick({now: NOW, paired: true, nextPushAt: NOW + secs(10)}).push, false);
    assert.equal(planSyncTick({now: NOW, paired: true, pushInFlight: true}).push, false);
});

test('reads poll on the push cadence only while the tab is visible', () => {
    const fresh = {now: NOW, paired: true, refreshedAt: NOW - secs(SYNC_PUSH_SECS), lastReadAt: NOW - secs(SYNC_PUSH_SECS)};
    assert.equal(planSyncTick({...fresh, tabVisible: true}).read, true);
    assert.equal(planSyncTick({...fresh, tabVisible: false}).read, false);
    // Just read: wait for the next cadence even when visible.
    assert.equal(planSyncTick({...fresh, tabVisible: true, lastReadAt: NOW - secs(30)}).read, false);
    assert.equal(planSyncTick({...fresh, tabVisible: true, readInFlight: true}).read, false);
});

test('hidden tab reads only once the data is older than 5 minutes', () => {
    const base = {now: NOW, paired: true, tabVisible: false};
    assert.equal(planSyncTick({...base, refreshedAt: NOW - secs(SYNC_STALE_SECS - 1),
        lastReadAt: NOW - secs(SYNC_STALE_SECS - 1)}).read, false);
    assert.equal(planSyncTick({...base, refreshedAt: NOW - secs(SYNC_STALE_SECS),
        lastReadAt: NOW - secs(SYNC_STALE_SECS)}).read, true);
    // Never read at all.
    assert.equal(planSyncTick(base).read, true);
    // An unreachable server keeps the data old, but attempts stay on the push cadence.
    assert.equal(planSyncTick({...base, refreshedAt: NOW - secs(3600), lastReadAt: NOW - secs(60)}).read, false);
});

test('the tab is hidden entirely when not paired', () => {
    assert.deepEqual(machinesView(null), {hidden: true});
    assert.deepEqual(machinesView({paired: false}), {hidden: true});
});

test('paired but never read shows a loading state', () => {
    const view = machinesView({paired: true}, {now: NOW});
    assert.equal(view.hidden, false);
    assert.equal(view.loading, true);
    assert.equal(view.stale, false);
    assert.deepEqual(view.machines, []);
});

test('two Machines used at once both show as active with their share', () => {
    const view = machinesView(payload(), {now: NOW});
    assert.equal(view.stale, false);
    assert.equal(view.banner, null);
    assert.equal(view.activeCount, 2);
    assert.deepEqual(view.machines.map(m => [m.name, m.active, m.thisMachine]),
        [['laptop', true, true], ['desk', true, false]]);
    const [laptop, desk] = view.machines;
    assert.equal(laptop.today, '$2.00');
    assert.equal(laptop.last30, '$3.00');
    assert.equal(laptop.share, 0.75);
    assert.deepEqual(laptop.models.map(m => [m.provider, m.model, m.spend]),
        [['claude', 'claude-sonnet-4-5', '$2.00'], ['codex', 'gpt-5', '$1.00']]);
    assert.equal(laptop.coverage, 'Coverage Jun 25 – Sep 24');
    assert.equal(laptop.lastSeen, 'Last seen 2 min ago');
    assert.equal(desk.today, '$0.50+');
    assert.equal(desk.share, 0.25);
    assert.equal(desk.coverage, 'Coverage Sep 24');
    assert.deepEqual(view.total, {today: '$2.50+', last30: '$4.00'});
});

test('a failed read keeps the last good data, greyed, with a banner', () => {
    const view = machinesView(payload({error: "Couldn't reach the Sync Server: offline"}), {now: NOW});
    assert.equal(view.stale, true);
    assert.equal(view.machines.length, 2);
    assert.match(view.banner, /Can't reach the Sync Server\. Showing data from 1 min ago\./);
});

test('data older than 5 minutes is stale even without an error', () => {
    const view = machinesView(payload({refreshedAt: '2026-09-24T12:20:00Z'}), {now: NOW});
    assert.equal(view.stale, true);
    assert.match(view.banner, /out of date\. Showing data from 10 min ago\./);
});

test('serve failing keeps the last payload and says so', () => {
    const view = machinesView(payload(), {now: NOW, fetchError: new Error('HTTP 500')});
    assert.equal(view.stale, true);
    assert.match(view.banner, /codexbar serve isn't answering/);
    assert.equal(view.machines.length, 2);
});

test('model breakdown is capped and counts the rest', () => {
    const models = Array.from({length: 7}, (_, i) => ({provider: 'claude', model: `m${i}`, spend: spend(1)}));
    const p = payload();
    p.status.machines[0].models = models;
    const view = machinesView(p, {now: NOW});
    assert.equal(view.machines[0].models.length, 5);
    assert.equal(view.machines[0].moreModels, 2);
});

test('spend and coverage text', () => {
    assert.equal(spendText(null), '—');
    assert.equal(spendText(spend(12.7)), '$12');
    assert.equal(coverageText(null), null);
    assert.equal(coverageText({from: '2026-01-02', to: '2026-02-03'}), 'Coverage Jan 2 – Feb 3');
});
