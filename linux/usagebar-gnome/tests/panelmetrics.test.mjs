import test from 'node:test';
import assert from 'node:assert/strict';

import {buildCards} from '../usagebar@felipearosr.github.io/accounts.js';
import {
    chipExtras,
    cleanLetter,
    colorHex,
    defaultColor,
    defaultLetter,
    encodeMetrics,
    metricCards,
    metricCatalog,
    metricTitle,
    pickFor,
    readCatalog,
    readMetrics,
    TAG_COLORS,
    updateMetrics,
} from '../usagebar@felipearosr.github.io/panelmetrics.js';

const ONE = 'claude-swap:1';
const TWO = 'claude-swap:2';

const window = (usedPercent, windowMinutes) => ({usedPercent, windowMinutes, resetsAt: '2026-11-12T10:00:00Z'});

// Two claude-swap slots (slot 1 active, Weekly + Fable; slot 2 with a
// session too) and Codex with one account.
function rows() {
    return [
        {
            provider: 'claude', accountId: ONE, active: true, accountLabel: 'me@example.com',
            usage: {secondary: window(45, 10080), extraRateWindows: [{id: 'fable', title: 'Fable only', window: window(2, 10080)}]},
        },
        {
            provider: 'claude', accountId: TWO, active: false, accountLabel: 'work@example.com',
            usage: {
                primary: window(12, 300), secondary: window(2, 10080),
                extraRateWindows: [{id: 'fable', title: 'Fable only', window: window(0, 10080)}],
            },
        },
        {provider: 'codex', usage: {primary: window(30, 300)}},
    ];
}

function cards() {
    const built = buildCards(rows(), {accountRows: true});
    const multi = new Map(built.filter(card => card.multi).map(card => [card.provider, card]));
    return metricCards(built.map(card => card.row), multi);
}

test('the catalog lists every account × bar, with ordinals and never labels', () => {
    const catalog = metricCatalog(cards());
    assert.deepEqual(catalog, [
        {p: 'claude', a: ONE, n: 1, act: true, k: 'w1', l: 'Weekly'},
        {p: 'claude', a: ONE, n: 1, act: true, k: 'x:fable', l: 'Fable only'},
        {p: 'claude', a: TWO, n: 2, act: false, k: 'w0', l: 'Session (5h)'},
        {p: 'claude', a: TWO, n: 2, act: false, k: 'w1', l: 'Weekly'},
        {p: 'claude', a: TWO, n: 2, act: false, k: 'x:fable', l: 'Fable only'},
        {p: 'codex', a: '', n: 0, act: false, k: 'w0', l: 'Session (5h)'},
    ]);
    assert.ok(!JSON.stringify(catalog).includes('@'));
});

test('chip extras resolve each shown pick against its own account', () => {
    const metrics = readMetrics([
        {p: 'claude', a: ONE, k: 'x:fable', letter: 'f', color: 'navy'},
        {p: 'claude', a: TWO, k: 'w0', letter: 'S', color: 'plum'},
        {p: 'claude', a: TWO, k: 'w1', on: false, letter: 'W', color: 'plum'},
        {p: 'codex', a: '', k: 'w0', letter: '', color: 'teal'},
    ].map(entry => JSON.stringify(entry)));
    const resolved = cards();
    assert.deepEqual(chipExtras('claude', resolved, metrics).map(e => [e.percent, e.letter, e.color]),
        [[2, 'F', 'navy'], [12, 'S', 'plum']]);
    assert.deepEqual(chipExtras('codex', resolved, metrics).map(e => [e.percent, e.letter]), [[30, '']]);
});

test('a pick whose account or bar is gone is skipped', () => {
    const metrics = readMetrics([
        JSON.stringify({p: 'claude', a: 'claude-swap:9', k: 'w1', letter: 'W'}),
        JSON.stringify({p: 'claude', a: ONE, k: 'w0', letter: 'S'}),
        JSON.stringify({p: 'gemini', a: '', k: 'w0', letter: 'G'}),
    ]);
    assert.deepEqual(chipExtras('claude', cards(), metrics), []);
    assert.deepEqual(chipExtras('gemini', cards(), metrics), []);
});

test('an account id of "" follows the primary account', () => {
    const metrics = readMetrics([JSON.stringify({p: 'claude', a: '', k: 'w1', letter: 'W'})]);
    assert.deepEqual(chipExtras('claude', cards(), metrics).map(e => e.percent), [45]);
});

test('a stale or failing account greys its extras', () => {
    const built = rows();
    built[1].stale = true;
    const all = buildCards(built, {accountRows: true});
    const resolved = metricCards(all.map(card => card.row),
        new Map(all.filter(card => card.multi).map(card => [card.provider, card])));
    const metrics = readMetrics([JSON.stringify({p: 'claude', a: TWO, k: 'w0', letter: 'S'})]);
    assert.equal(chipExtras('claude', resolved, metrics)[0].stale, true);
});

test('readMetrics drops malformed and duplicate entries and cleans the rest', () => {
    const metrics = readMetrics([
        'not json',
        JSON.stringify({p: '', k: 'w0'}),
        JSON.stringify({p: 'claude', a: ONE, k: 'w1', letter: ' week ', color: 'hotpink'}),
        JSON.stringify({p: 'claude', a: ONE, k: 'w1', letter: 'X'}),
    ]);
    assert.deepEqual(metrics, [{p: 'claude', a: ONE, k: 'w1', on: true, letter: 'WE', color: 'navy'}]);
});

test('encodeMetrics round-trips through readMetrics', () => {
    const metrics = [{p: 'claude', a: TWO, k: 'x:fable', on: false, letter: 'F', color: 'wine'}];
    assert.deepEqual(readMetrics(encodeMetrics(metrics)), metrics);
});

test('defaults: the bar label initial and one color per account', () => {
    assert.equal(defaultLetter('Weekly'), 'W');
    assert.equal(defaultLetter('Session (5h)'), 'S');
    assert.equal(defaultLetter('(5h)'), '5');
    assert.equal(defaultLetter(''), '');
    assert.equal(defaultColor(1), 'navy');
    assert.equal(defaultColor(2), 'plum');
    assert.equal(defaultColor(TAG_COLORS.length + 1), 'navy');
    assert.equal(cleanLetter('abc'), 'AB');
    assert.equal(colorHex('teal'), '#0f5d5a');
    assert.equal(colorHex('nope'), TAG_COLORS[0].hex);
});

test('updateMetrics keeps picks in catalog order', () => {
    const catalog = metricCatalog(cards());
    let metrics = updateMetrics([], catalog, catalog[2], {on: true});
    metrics = updateMetrics(metrics, catalog, catalog[1], {on: true});
    metrics = updateMetrics(metrics, catalog, catalog[2], {letter: 'ss', color: 'teal'});
    assert.deepEqual(metrics.map(m => [m.k, m.a, m.on, m.letter, m.color]), [
        ['x:fable', ONE, true, 'F', 'navy'],
        ['w0', TWO, true, 'SS', 'teal'],
    ]);
    assert.deepEqual(pickFor(metrics, catalog[3]),
        {p: 'claude', a: TWO, k: 'w1', on: false, letter: 'W', color: 'plum'});
});

test('catalog entries read back and get titles', () => {
    const [entry] = readCatalog([JSON.stringify({p: 'claude', a: TWO, n: 2, act: true, k: 'w0', l: 'Session (5h)'})]);
    assert.equal(metricTitle(entry, {multi: true}), 'Account 2 (active) · Session (5h)');
    assert.equal(metricTitle({...entry, act: false}, {multi: true}), 'Account 2 · Session (5h)');
    assert.equal(metricTitle(entry, {multi: false}), 'Session (5h)');
});
