import test from 'node:test';
import assert from 'node:assert/strict';

import {
    buildCostDateRange,
    buildDailyCostRows,
    buildSummaryBarSegments,
    cliUpdateCompletionMessage,
    CostOverviewCache,
    costChartMetricOptions,
    costRangeOptions,
    formatSummaryUSD,
    LifetimeLookupCache,
    reconcileKeyed,
    RenderScheduler,
    selectCostChartProviders,
    summarizeCostRange,
    StatusMessageState,
} from '../usagebar@felipearosr.github.io/renderstate.js';

test('cost chart uses at most four eligible providers', () => {
    const providers = [
        {provider: 'claude', cost: 50},
        {provider: 'codex', cost: 40},
        {provider: 'opencode', cost: 30},
        {provider: 'gemini', cost: 20},
        {provider: 'cursor', cost: 10},
        {provider: 'amp', cost: 5},
    ];

    assert.deepEqual(
        selectCostChartProviders(providers, ['codex']).map(provider => provider.provider),
        ['claude', 'opencode', 'gemini', 'cursor']);
    assert.deepEqual(selectCostChartProviders(providers, [], 2), providers.slice(0, 2));
});

test('cost chart metric control selects matching series and title', () => {
    assert.deepEqual(costChartMetricOptions('tokens'), [
        {
            metric: 'cost',
            label: 'COST',
            title: 'Daily cost',
            seriesKey: 'series',
            edge: 'left',
            selected: false,
        },
        {
            metric: 'tokens',
            label: 'TOKENS',
            title: 'Daily tokens',
            seriesKey: 'tokenSeries',
            edge: 'right',
            selected: true,
        },
    ]);
});

test('cost range control exposes all tabs and selects thirty days by default', () => {
    assert.deepEqual(costRangeOptions(30), [
        {days: 1, label: 'TODAY', edge: 'left', selected: false},
        {days: 7, label: '7 DAYS', edge: null, selected: false},
        {days: 30, label: '30 DAYS', edge: null, selected: true},
        {days: 90, label: '90 DAYS', edge: 'right', selected: false},
    ]);
});

test('cost date ranges end today and include the requested number of local days', () => {
    const today = new Date(2026, 8, 12, 12);
    assert.deepEqual(buildCostDateRange(1, today), ['2026-09-12']);
    assert.deepEqual(buildCostDateRange(7, today), [
        '2026-09-06',
        '2026-09-07',
        '2026-09-08',
        '2026-09-09',
        '2026-09-10',
        '2026-09-11',
        '2026-09-12',
    ]);
});

test('cost range totals include only selected dates', () => {
    const summary = summarizeCostRange([
        {date: '2026-09-05', totalCost: 20, totalTokens: 200},
        {date: '2026-09-11', totalCost: 7, totalTokens: 70, cacheReadTokens: 30},
        {date: '2026-09-12', totalCost: 3, totalTokens: 30, cacheReadTokens: 10},
    ], ['2026-09-11', '2026-09-12']);

    assert.deepEqual(summary.daily.map(day => day.date), ['2026-09-11', '2026-09-12']);
    assert.equal(summary.cost, 10);
    assert.equal(summary.tokens, 100);
    assert.equal(summary.cached, 40);
});

test('spend summary omits cents from values of at least ten dollars', () => {
    assert.equal(formatSummaryUSD(9.99), '$9.99');
    assert.equal(formatSummaryUSD(10), '$10');
    assert.equal(formatSummaryUSD(8936.45), '$8,936');
});

test('spend summary bar reserves one-pixel separators and rounds outer ends', () => {
    assert.deepEqual(buildSummaryBarSegments([
        {cost: 30},
        {cost: 20},
        {cost: 0},
    ], 50, 101), [
        {width: 60, radius: '2px 0 0 2px'},
        {width: 40, radius: '0 2px 2px 0'},
    ]);
    assert.deepEqual(buildSummaryBarSegments([{cost: 10}], 10, 101), [
        {width: 101, radius: '2px'},
    ]);
});

test('daily cost rows combine providers, omit idle dates, and sort newest first', () => {
    const rows = buildDailyCostRows(
        ['2026-09-10', '2026-09-11', '2026-09-12'],
        [
            {series: [10, 0, 4.5], tokenSeries: [100, 0, 45]},
            {series: [20, 2.5, 0], tokenSeries: [200, 25, 0]},
        ]);

    assert.deepEqual(rows, [
        {date: '2026-09-12', costs: [4.5, 0], totalCost: 4.5, totalTokens: 45},
        {date: '2026-09-11', costs: [0, 2.5], totalCost: 2.5, totalTokens: 25},
        {date: '2026-09-10', costs: [10, 20], totalCost: 30, totalTokens: 300},
    ]);
});

test('daily cost rows retain token-only days', () => {
    const rows = buildDailyCostRows(
        ['2026-09-11', '2026-09-12'],
        [{series: [0, 0], tokenSeries: [0, 42]}]);

    assert.deepEqual(rows, [
        {date: '2026-09-12', costs: [0], totalCost: 0, totalTokens: 42},
    ]);
});

test('CLI update completion tells Linux users to start a new login session', () => {
    const status = new StatusMessageState();
    status.setTransient('Installing codexbar update…');
    assert.equal(status.current, 'Installing codexbar update…');

    const completion = cliUpdateCompletionMessage('0.60.0');
    status.setPersistent(completion);
    status.setTransient('codexbar serve exited — restarting…');
    assert.equal(status.current, completion);
    status.setTransient('');
    assert.equal(
        status.current,
        'codexbar 0.60.0 installed — log out and back in to finish the update');
});

test('RenderScheduler coalesces a burst and can be cancelled', () => {
    const queued = [];
    const cancelled = [];
    let renders = 0;
    const scheduler = new RenderScheduler(
        callback => {
            queued.push(callback);
            return queued.length;
        },
        id => cancelled.push(id),
        () => renders++
    );

    assert.equal(scheduler.request(), true);
    assert.equal(scheduler.request(), false);
    assert.equal(scheduler.pending, true);
    assert.equal(queued.length, 1);
    queued.shift()();
    assert.equal(renders, 1);
    assert.equal(scheduler.pending, false);

    assert.equal(scheduler.request(), true);
    assert.equal(scheduler.cancel(), true);
    assert.deepEqual(cancelled, [1]);
    assert.equal(scheduler.pending, false);
    assert.equal(scheduler.cancel(), false);
});

test('CostOverviewCache retains negative results and invalidates by revision/date', () => {
    const reports = [];
    const cache = new CostOverviewCache(2);
    let computes = 0;
    const compute = () => {
        computes++;
        return null;
    };

    assert.equal(cache.get(reports, 1, '2026-09-12', compute), null);
    assert.equal(cache.get(reports, 1, '2026-09-12', compute), null);
    assert.equal(computes, 1);
    cache.get(reports, 1, '2026-09-13', compute);
    cache.get(reports, 2, '2026-09-13', compute);
    assert.equal(computes, 3);
});

test('keyed state seam reuses value/countdown actors across updates and handles order', () => {
    let builds = 0;
    const removed = [];
    const make = item => ({
        id: item.id,
        builds: ++builds,
        updates: [],
        valueActor: {text: item.value},
        countdownActor: {text: `reset-${item.value}`},
    });
    const update = (state, item) => {
        state.updates.push(item.value);
        state.valueActor.text = item.value;
        state.countdownActor.text = `reset-${item.value}`;
    };
    const drop = state => removed.push(state.id);
    let views = new Map();

    views = reconcileKeyed(views, [
        {id: 'codex', value: 10},
        {id: 'claude', value: 20},
    ], item => item.id, make, update, drop);
    const codex = views.get('codex');
    const claude = views.get('claude');
    const codexValueActor = codex.valueActor;
    const codexCountdownActor = codex.countdownActor;

    views = reconcileKeyed(views, [
        {id: 'claude', value: 21},
        {id: 'codex', value: 11},
        {id: 'gemini', value: 30},
    ], item => item.id, make, update, drop);
    assert.equal(builds, 3);
    assert.equal(views.get('codex'), codex);
    assert.equal(views.get('claude'), claude);
    assert.equal(views.get('codex').valueActor, codexValueActor);
    assert.equal(views.get('codex').countdownActor, codexCountdownActor);
    assert.equal(views.get('codex').valueActor.text, 11);
    assert.equal(views.get('codex').countdownActor.text, 'reset-11');
    assert.deepEqual([...views.keys()], ['claude', 'codex', 'gemini']);

    views = reconcileKeyed(views, [{id: 'gemini', value: 31}], item => item.id,
        make, update, drop);
    assert.deepEqual(removed.sort(), ['claude', 'codex']);
    assert.deepEqual(views.get('gemini').updates, [30, 31]);
});

test('keyed state seam leaves warm reopen at zero builds and invalidates shape changes', () => {
    let builds = 0;
    let views = new Map();
    const create = item => ({provider: item.provider, shape: item.shape, actor: {}, builds: ++builds});
    const update = (state, item) => {
        if (state.shape !== item.shape)
            return create(item);
        state.value = item.value;
    };
    const remove = () => {};
    const render = items => {
        views = reconcileKeyed(views, items, item => item.provider,
            create, update, remove);
    };
    render([{provider: 'codex', shape: 'bars', value: 10},
        {provider: 'claude', shape: 'bars', value: 20}]);
    const codexActor = views.get('codex').actor;
    assert.equal(builds, 2);

    // The same provider set on a warm reopen only updates values.
    render([{provider: 'codex', shape: 'bars', value: 11},
        {provider: 'claude', shape: 'bars', value: 21}]);
    assert.equal(builds, 2);
    assert.equal(views.get('codex').actor, codexActor);

    // A display setting that changes the row shape replaces only that row.
    render([{provider: 'codex', shape: 'bars-with-extras', value: 12},
        {provider: 'claude', shape: 'bars', value: 22}]);
    assert.equal(builds, 3);
    assert.notEqual(views.get('codex').actor, codexActor);
});

test('LifetimeLookupCache caches both existing and missing icons', () => {
    let lookups = 0;
    const cache = new LifetimeLookupCache(name => {
        lookups++;
        return name === 'codex' ? {name} : null;
    });
    assert.deepEqual(cache.get('codex'), {name: 'codex'});
    assert.equal(cache.get('codex'), cache.get('codex'));
    assert.equal(cache.get('missing'), null);
    assert.equal(cache.get('missing'), null);
    assert.equal(lookups, 2);
});
