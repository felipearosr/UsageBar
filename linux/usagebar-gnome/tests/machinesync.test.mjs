import test from 'node:test';
import assert from 'node:assert/strict';

import {
    costScopeLabel,
    costScopeOptions,
    countText,
    coverageText,
    MACHINE_PALETTE,
    machineDetailView,
    machinesView,
    nextPushDelaySecs,
    planSyncTick,
    scopedCostReports,
    scopedProviderKpis,
    scopeControlMode,
    scopedSpend,
    spendScopeOptions,
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

function detailPayload() {
    const p = payload();
    const [laptop, desk] = p.status.machines;
    Object.assign(laptop, {
        platform: 'linux',
        clientVersion: '0.20.0',
        last30Days: spend(3, {totalTokens: 1_500_000, requests: 40}),
        days: [
            {date: '2026-09-23', spend: spend(1, {totalTokens: 500_000})},
            {date: '2026-09-24', spend: spend(2, {totalTokens: 1_000_000})},
        ],
    });
    Object.assign(desk, {
        last30Days: spend(1, {costIncomplete: true, totalTokens: 200_000, requests: 5}),
        models: [
            {provider: 'codex', model: 'gpt-5', spend: spend(0.5, {totalTokens: 100_000})},
            {provider: 'claude', model: 'claude-sonnet-4-5', spend: spend(0.5, {totalTokens: 100_000})},
        ],
        days: [{date: '2026-09-24', spend: spend(1, {totalTokens: 200_000})}],
    });
    return p;
}

test('each Machine keeps a stable color by its place in the list', () => {
    const view = machinesView(detailPayload(), {now: NOW});
    assert.deepEqual(view.machines.map(m => m.color), MACHINE_PALETTE.slice(0, 2));
    assert.deepEqual(view.machines.map(m => m.cost30), [3, 1]);
});

test('one Machine detail shows its own spend, chart and models only', () => {
    const view = machineDetailView(detailPayload(), 'deskAAAAAAAAAAAAAAAAAA', {now: NOW});
    assert.equal(view.title, 'desk');
    assert.equal(view.all, false);
    assert.equal(view.state, 'active');
    assert.equal(view.thisMachine, false);
    assert.equal(view.share, 0.25);
    assert.deepEqual(view.kpis.map(k => k.value), ['$0.50+', '$1.00+', '200K', '5']);
    assert.equal(view.chart.points.length, 30);
    assert.equal(view.chart.points.at(-1).date, '2026-09-24');
    assert.deepEqual(view.chart.points.at(-1).models, [['desk', 1]]);
    assert.equal(view.chart.points.at(-2).value, 0);
    assert.deepEqual(view.chart.colors, [['desk', MACHINE_PALETTE[1]]]);
    // Equal spend ties break by model name.
    assert.deepEqual(view.models.map(m => m.model), ['claude-sonnet-4-5', 'gpt-5']);
    assert.deepEqual(view.info, ['Coverage Sep 24', 'Last seen 3 min ago']);
});

test('the All detail merges every Machine', () => {
    const view = machineDetailView(detailPayload(), 'all', {now: NOW});
    assert.equal(view.title, 'All Machines');
    assert.equal(view.share, null);
    assert.deepEqual(view.kpis.map(k => k.value), ['$2.50+', '$4.00+', '1.7M', '45']);
    const today = view.chart.points.at(-1);
    assert.equal(today.value, 3);
    assert.deepEqual(today.models, [['laptop', 2], ['desk', 1]]);
    assert.deepEqual(view.chart.points.at(-2).models, [['laptop', 1]]);
    // Same model on both Machines is one row.
    assert.deepEqual(view.models.map(m => [m.model, m.spend]),
        [['claude-sonnet-4-5', '$2.50'], ['gpt-5', '$1.50']]);
    assert.deepEqual(view.info, ['2 Machines · 2 active']);
});

test('a single Machine detail lists platform and client version', () => {
    const view = machineDetailView(detailPayload(), 'laptopAAAAAAAAAAAAAAAA', {now: NOW});
    assert.equal(view.thisMachine, true);
    assert.equal(view.info[0], 'linux · codexbar 0.20.0');
});

test('the chart falls back to tokens when nothing is priced', () => {
    const p = detailPayload();
    for (const machine of p.status.machines)
        machine.days = machine.days.map(day => ({...day, spend: {...day.spend, costUSD: 0}}));
    const view = machineDetailView(p, 'all', {now: NOW});
    assert.equal(view.chart.points.at(-1).cost, null);
    assert.equal(view.chart.points.at(-1).value, 1_200_000);
});

test('detail is null for a Machine that left, and has no chart without history', () => {
    assert.equal(machineDetailView(detailPayload(), 'goneAAAAAAAAAAAAAAAAAA', {now: NOW}), null);
    assert.equal(machineDetailView({paired: true}, 'all', {now: NOW}), null);
    assert.equal(machineDetailView(payload(), 'all', {now: NOW}).chart, null);
});

test('token and request counts are compact', () => {
    assert.equal(countText(0), '0');
    assert.equal(countText(999), '999');
    assert.equal(countText(1000), '1K');
    assert.equal(countText(1_250_000), '1.3M');
    assert.equal(countText(2_000_000_000), '2B');
});

test('hidden models leave the detail list but not the totals', () => {
    const view = machineDetailView(detailPayload(), 'all', {
        now: NOW,
        hiddenModels: new Set(['codex:gpt-5']),
    });
    assert.deepEqual(view.models.map(m => m.model), ['claude-sonnet-4-5']);
    assert.equal(view.kpis[1].value, '$4.00+');
});

test('a Machine color set in prefs replaces its palette color everywhere', () => {
    const colors = {deskAAAAAAAAAAAAAAAAAA: '#ff00ff'};
    const view = machinesView(detailPayload(), {now: NOW, colors});
    assert.deepEqual(view.machines.map(m => m.color), [MACHINE_PALETTE[0], '#ff00ff']);
    const all = machineDetailView(detailPayload(), 'all', {now: NOW, colors});
    assert.deepEqual(all.chart.colors, [['laptop', MACHINE_PALETTE[0]], ['desk', '#ff00ff']]);
    assert.equal(machineDetailView(detailPayload(), 'deskAAAAAAAAAAAAAAAAAA', {now: NOW, colors}).color, '#ff00ff');
});

test('the first Machines get far-apart default colors', () => {
    assert.deepEqual(MACHINE_PALETTE.slice(0, 3), ['#3584e4', '#e66100', '#9141ac']);
});

function scopedPayload() {
    const p = payload();
    p.status.machines[1].models = [
        {provider: 'codex', model: 'gpt-5', spend: spend(0.75, {totalTokens: 900, requests: 3})},
        {provider: 'pi', model: 'pi-1', spend: spend(0.25, {costIncomplete: true, totalTokens: 100, requests: 1})},
    ];
    return p;
}

test('the Machine picker lists this Machine first, the others, then All', () => {
    const options = spendScopeOptions(scopedPayload());
    assert.deepEqual(options.map(o => [o.id, o.name]),
        [['this', 'laptop'], ['deskAAAAAAAAAAAAAAAAAA', 'desk'], ['all', 'All']]);
    assert.equal(options[1].color, MACHINE_PALETTE[1]);
    assert.deepEqual(spendScopeOptions({paired: false}), []);
    const alone = scopedPayload();
    alone.status.machines.pop();
    assert.deepEqual(spendScopeOptions(alone), []); // nothing to pick
});

test('scoped spend follows one Machine, split by provider and model', () => {
    const s = scopedSpend(scopedPayload(), 'deskAAAAAAAAAAAAAAAAAA');
    assert.equal(s.name, 'desk');
    assert.equal(s.color, MACHINE_PALETTE[1]);
    assert.deepEqual(s.providers.map(p => [p.provider, p.spend.costUSD, p.spend.costIncomplete]),
        [['codex', 0.75, false], ['pi', 0.25, true]]);
    assert.deepEqual(s.providers[0].models.map(m => m.model), ['gpt-5']);
    assert.equal(s.last30.costUSD, 1);
});

test('scoped spend for All sums every Machine per provider', () => {
    const s = scopedSpend(scopedPayload(), 'all');
    assert.equal(s.all, true);
    assert.deepEqual(s.providers.map(p => [p.provider, p.spend.costUSD]),
        [['claude', 2], ['codex', 1.75], ['pi', 0.25]]);
    assert.equal(s.providers[1].models.length, 1); // same model on two Machines
    assert.equal(s.today.costUSD, 2.5);
});

test('scoped spend is null for this Machine, a Machine that left, or no Sync', () => {
    assert.equal(scopedSpend(scopedPayload(), null), null);
    assert.equal(scopedSpend(scopedPayload(), 'this'), null);
    assert.equal(scopedSpend(scopedPayload(), 'goneAAAAAAAAAAAAAAAAAA'), null);
    assert.equal(scopedSpend({paired: false}, 'all'), null);
});

test('a provider the scoped Machine never used shows zero, not the local cost', () => {
    const s = scopedSpend(scopedPayload(), 'deskAAAAAAAAAAAAAAAAAA');
    assert.deepEqual(scopedProviderKpis(s.providers.find(p => p.provider === 'claude')).map(k => k.value),
        ['$0.00', '0', '0', '0']);
    assert.deepEqual(scopedProviderKpis(s.providers[1]).map(k => k.value), ['$0.25+', '100', '1', '1']);
});

// ---------- scoped cost reports ----------

function providerDay(provider, totalCost, totalTokens, models = [], extra = {}) {
    return {
        provider,
        totalCost,
        costIncomplete: false,
        inputTokens: totalTokens,
        outputTokens: 0,
        cacheReadTokens: 0,
        cacheCreationTokens: 0,
        totalTokens,
        requests: 1,
        modelBreakdowns: models,
        ...extra,
    };
}

// laptop (this Machine) and desk both synced `daily`; laptop's synced copy
// matches its local report and must not be added again.
function dailyPayload() {
    const p = payload();
    const [laptop, desk] = p.status.machines;
    laptop.daily = [{date: '2026-09-24', providers: [
        providerDay('claude', 2, 200, [{modelName: 'claude-sonnet-4-5', cost: 2, totalTokens: 200}]),
    ]}];
    desk.daily = [
        {date: '2026-09-23', providers: [
            providerDay('codex', 1, 100, [{modelName: 'gpt-5', cost: 1, totalTokens: 100}]),
        ]},
        {date: '2026-09-24', providers: [
            providerDay('claude', 0.5, 50, [{modelName: 'claude-sonnet-4-5', cost: 0.5, totalTokens: 50}]),
            providerDay('pi', null, 70, [{modelName: 'pi-1', cost: null, totalTokens: 70}],
                {costIncomplete: true}),
        ]},
    ];
    return p;
}

function laptopReports() {
    return [{
        provider: 'claude',
        source: 'local',
        last30DaysCostUSD: 2,
        totals: {totalCost: 2},
        daily: [{
            date: '2026-09-24', totalCost: 2, totalTokens: 200, inputTokens: 200,
            modelBreakdowns: [{modelName: 'claude-sonnet-4-5', cost: 2, totalTokens: 200}],
        }],
    }];
}

const totalCost = reports => reports.reduce((sum, r) => sum + (r.totals?.totalCost ?? 0), 0);

test('All Machines adds the other Machines to the local reports, counting this one once', () => {
    const local = laptopReports();
    const {scope, reports} = scopedCostReports(local, dailyPayload(), 'all');
    assert.equal(scope, 'all');
    assert.deepEqual(reports.map(r => r.provider), ['claude', 'codex', 'pi']);
    // Local claude $2 + desk claude $0.50 + desk codex $1; laptop's synced $2 is skipped.
    assert.equal(totalCost(reports), 3.5);
    const claude = reports[0];
    assert.deepEqual(claude.daily.map(d => [d.date, d.totalCost, d.totalTokens]), [['2026-09-24', 2.5, 250]]);
    // The same model on two Machines is one breakdown row.
    assert.deepEqual(claude.daily[0].modelBreakdowns,
        [{modelName: 'claude-sonnet-4-5', cost: 2.5, totalTokens: 250}]);
    assert.deepEqual(reports[1].daily.map(d => d.date), ['2026-09-23']);
    assert.equal(local[0].daily[0].totalCost, 2); // inputs are left alone
});

test('unpriced synced days stay token-only', () => {
    const {reports} = scopedCostReports(laptopReports(), dailyPayload(), 'all');
    const pi = reports.find(r => r.provider === 'pi');
    assert.equal(pi.totals.totalCost, null); // the cost overview leaves it out
    assert.equal(pi.totals.totalTokens, 70);
    assert.deepEqual(pi.daily.map(d => [d.totalCost, d.costIncomplete, d.totalTokens]), [[null, true, 70]]);
    assert.deepEqual(pi.daily[0].modelBreakdowns, [{modelName: 'pi-1', cost: null, totalTokens: 70}]);
    // An unpriced day next to a priced one keeps the priced cost.
    const p = dailyPayload();
    p.status.machines[1].daily[1].providers[0].totalCost = null;
    const claude = scopedCostReports(laptopReports(), p, 'all').reports[0];
    assert.equal(claude.daily[0].totalCost, 2);
    assert.equal(claude.daily[0].totalTokens, 250);
});

test('unpaired or not yet read, the scope is this Machine and the reports are the local ones', () => {
    const local = laptopReports();
    for (const p of [null, {paired: false}, {paired: true, status: null}]) {
        const result = scopedCostReports(local, p, 'all');
        assert.equal(result.scope, 'this');
        assert.equal(result.reports, local);
    }
    assert.deepEqual(scopedCostReports(null, null, 'all').reports, []);
});

test('All Machines with no synced daily keeps the local reports as they are', () => {
    const local = laptopReports();
    const result = scopedCostReports(local, payload(), 'all'); // a CLI without `daily`
    assert.equal(result.scope, 'all');
    assert.equal(result.reports, local);
});

test('Retired Machines count in All Machines', () => {
    const p = dailyPayload();
    Object.assign(p.status.machines[1], {retired: true, active: false});
    assert.equal(totalCost(scopedCostReports(laptopReports(), p, 'all').reports), 3.5);
});

test('one Machine scope holds only that Machine; this Machine is its local reports', () => {
    const local = laptopReports();
    const desk = scopedCostReports(local, dailyPayload(), 'deskAAAAAAAAAAAAAAAAAA');
    assert.equal(desk.scope, 'deskAAAAAAAAAAAAAAAAAA');
    assert.deepEqual(desk.reports.map(r => [r.provider, r.totals.totalCost]),
        [['claude', 0.5], ['codex', 1], ['pi', null]]);
    for (const scope of ['this', 'laptopAAAAAAAAAAAAAAAA']) {
        const result = scopedCostReports(local, dailyPayload(), scope);
        assert.equal(result.scope, 'this');
        assert.equal(result.reports, local);
    }
});

test('a Machine that left the Sync Group falls back to All Machines', () => {
    const result = scopedCostReports(laptopReports(), dailyPayload(), 'goneAAAAAAAAAAAAAAAAAA');
    assert.equal(result.scope, 'all');
    assert.equal(totalCost(result.reports), 3.5);
});

// ---------- the dashboard's Machine scope switch ----------

test('the scope switch lists All Machines, then this Machine first, in Machine colors', () => {
    const p = dailyPayload();
    p.status.machines.reverse(); // this Machine first even when the status lists it later
    const options = costScopeOptions(p, {colors: {laptopAAAAAAAAAAAAAAAA: '#ff00ff'}});
    assert.deepEqual(options, [
        {id: 'all', name: 'All Machines', color: null},
        {id: 'this', name: 'laptop', color: '#ff00ff'},
        {id: 'deskAAAAAAAAAAAAAAAAAA', name: 'desk', color: MACHINE_PALETTE[0]},
    ]);
});

test('no scope switch while unpaired or before the first status read', () => {
    for (const p of [null, {paired: false}, {paired: true, status: null}, {paired: false, status: payload().status}])
        assert.deepEqual(costScopeOptions(p), []);
});

test('a Machine that left the Sync Group drops out of the switch', () => {
    const p = dailyPayload();
    p.status.machines = p.status.machines.filter(m => m.isThisMachine);
    assert.deepEqual(costScopeOptions(p).map(o => o.id), ['all', 'this']);
    // The dashboard's scope falls back with it.
    const result = scopedCostReports(laptopReports(), p, 'deskAAAAAAAAAAAAAAAAAA');
    assert.equal(result.scope, 'all');
    assert.equal(costScopeLabel(p, result.scope), 'all Machines');
});

test('a single Machine scope covers only that Machine and is named after it', () => {
    const p = dailyPayload();
    const desk = scopedCostReports(laptopReports(), p, 'deskAAAAAAAAAAAAAAAAAA');
    // desk's $0.50 claude and $1 codex; nothing of the local $2.
    assert.equal(totalCost(desk.reports), 1.5);
    assert.ok(desk.reports.every(r => r.source === 'machine-sync'));
    assert.equal(costScopeLabel(p, desk.scope), 'desk');
    assert.equal(costScopeLabel(p, 'this'), 'laptop');
    assert.equal(costScopeLabel(p, 'all'), 'all Machines');
    assert.equal(costScopeLabel(null, 'this'), null);
    assert.equal(costScopeLabel({paired: false}, 'all'), null);
});

test('the scope switch is segmented while it fits and a dropdown once it does not', () => {
    assert.equal(scopeControlMode({segmentedWidth: 300, rangeWidth: 250, spacing: 12, available: 732}),
        'segmented');
    assert.equal(scopeControlMode({segmentedWidth: 470, rangeWidth: 250, spacing: 12, available: 732}),
        'segmented');
    assert.equal(scopeControlMode({segmentedWidth: 471, rangeWidth: 250, spacing: 12, available: 732}),
        'dropdown');
});
