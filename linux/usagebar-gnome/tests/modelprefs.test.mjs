import test from 'node:test';
import assert from 'node:assert/strict';

import {
    decodeCatalog,
    encodeCatalog,
    hexColor,
    MODEL_PALETTE,
    modelCatalog,
    modelColors,
    providerModels,
    withoutHiddenModels,
} from '../usagebar@felipearosr.github.io/modelprefs.js';

const report = (provider, days) => ({
    provider,
    daily: days.map(models => ({
        date: '2026-09-24',
        modelBreakdowns: Object.entries(models).map(([modelName, cost]) => ({modelName, cost})),
    })),
});

test('the catalog ranks models by cost within each provider', () => {
    const catalog = modelCatalog({
        reports: [
            report('codex', [{'gpt-5': 2}, {'gpt-5': 1, 'gpt-5-mini': 4}]),
            report('claude', [{'claude-sonnet-4-5': 1}]),
        ],
    });
    assert.deepEqual(catalog, [
        {p: 'claude', m: 'claude-sonnet-4-5', c: 1},
        {p: 'codex', m: 'gpt-5-mini', c: 4},
        {p: 'codex', m: 'gpt-5', c: 3},
    ]);
});

test('synced models join the catalog, counted once when both sources have them', () => {
    const catalog = modelCatalog({
        reports: [report('claude', [{'claude-sonnet-4-5': 3}])],
        syncStatus: {
            machines: [
                {models: [{provider: 'claude', model: 'claude-sonnet-4-5', spend: {costUSD: 2}}]},
                {models: [
                    {provider: 'claude', model: 'claude-sonnet-4-5', spend: {costUSD: 3}},
                    {provider: 'claude', model: 'claude-haiku-4-5', spend: {costUSD: 1}},
                ]},
            ],
        },
    });
    assert.deepEqual(catalog, [
        {p: 'claude', m: 'claude-sonnet-4-5', c: 5},
        {p: 'claude', m: 'claude-haiku-4-5', c: 1},
    ]);
});

test('models missing from this round stay listed at the bottom', () => {
    const catalog = modelCatalog({
        reports: [report('codex', [{'gpt-5': 1}])],
        previous: [{p: 'codex', m: 'gpt-4.1', c: 9}, {p: 'codex', m: 'gpt-5', c: 9}],
    });
    assert.deepEqual(providerModels(catalog, 'codex'), ['gpt-5', 'gpt-4.1']);
});

test('the catalog round-trips through its settings encoding', () => {
    const entries = [{p: 'codex', m: 'gpt-5', c: 3.4}];
    assert.deepEqual(decodeCatalog(encodeCatalog(entries)), [{p: 'codex', m: 'gpt-5', c: 3}]);
    assert.deepEqual(decodeCatalog(['not json', '{"p":1}']), []);
});

test('model colors follow rank, with overrides winning', () => {
    const catalog = [{p: 'codex', m: 'gpt-5', c: 5}, {p: 'codex', m: 'gpt-5-mini', c: 1}];
    const colors = modelColors('codex', {catalog, brand: '#10a37f', names: ['gpt-4.1']});
    assert.deepEqual([...colors], [
        ['gpt-5', '#10a37f'],
        ['gpt-5-mini', MODEL_PALETTE[0]],
        ['gpt-4.1', MODEL_PALETTE[1]],
    ]);
    const custom = modelColors('codex', {catalog, brand: '#10a37f', overrides: {'codex:gpt-5-mini': '#ff0000'}});
    assert.equal(custom.get('gpt-5-mini'), '#ff0000');
    // Without a brand color the palette starts at its first entry.
    assert.equal(modelColors('codex', {catalog}).get('gpt-5'), MODEL_PALETTE[0]);
});

test('hidden models leave the chart and the bar shrinks with them', () => {
    const points = [
        {date: 'a', value: 3, cost: 3, models: [['gpt-5', 2], ['gpt-5-mini', 1]]},
        {date: 'b', value: 0, cost: null, models: []},
    ];
    const hidden = new Set(['codex:gpt-5']);
    const [first, second] = withoutHiddenModels(points, 'codex', hidden);
    assert.deepEqual(first.models, [['gpt-5-mini', 1]]);
    assert.equal(first.value, 1);
    assert.equal(second, points[1]);
    assert.equal(withoutHiddenModels(points, 'codex', new Set()), points);
    // Another provider's hidden model does not apply.
    assert.equal(withoutHiddenModels(points, 'claude', hidden)[0], points[0]);
});

test('GTK colors become hex', () => {
    assert.equal(hexColor({red: 1, green: 0.5, blue: 0}), '#ff8000');
});
