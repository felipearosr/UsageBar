import test from 'node:test';
import assert from 'node:assert/strict';
import {extraWindowsOf, isLongWindow, isStaleSource, isStatusLineSource, paceOf, resetSecs, windowLabel, windowsOf}
    from '../usagebar@felipearosr.github.io/payload.js';

const NOW = Date.parse('2026-10-12T12:00:00Z');

test('standard windows filter placeholders and missing percentages without renumbering slots', () => {
    const tertiary = {usedPercent: 0};
    assert.deepEqual(windowsOf({usage: {primary: {usedPercent: 80, isSyntheticPlaceholder: true},
        secondary: {usedPercent: null}, tertiary}}), [{w: tertiary, slot: 2}]);
    assert.deepEqual(windowsOf({usage: {primary: {}, secondary: null}}), []);
    assert.deepEqual(windowsOf({}), []);
});

test('extra windows discard entries without a window', () => {
    const extra = {id: 'fixture', window: {usedPercent: 90}};
    assert.deepEqual(extraWindowsOf({usage: {extraRateWindows: [null, {}, extra]}}), [extra]);
    assert.deepEqual(extraWindowsOf({}), []);
});

test('pace includes tertiary and uses null for missing slots', () => {
    const tertiary = {willLastToReset: false};
    assert.equal(paceOf({pace: {tertiary}}, 2), tertiary);
    assert.equal(paceOf({pace: {tertiary}}, 0), null);
    assert.equal(paceOf({}, 2), null);
    assert.equal(paceOf({pace: {}}, 8), null);
});

test('reset seconds use the injected time and tolerate absent or invalid dates', () => {
    assert.equal(resetSecs({resetsAt: '2026-10-12T13:00:00Z'}, NOW), 3600);
    assert.equal(resetSecs({resetsAt: '2026-10-12T11:00:00Z'}, NOW), -3600);
    assert.equal(resetSecs({resetsAt: 'invalid'}, NOW), null);
    assert.equal(resetSecs({}, NOW), null);
    assert.equal(resetSecs(null, NOW), null);
});

test('long windows prefer duration and otherwise use the reset horizon', () => {
    assert.equal(isLongWindow({windowMinutes: 1440}, NOW), true);
    assert.equal(isLongWindow({windowMinutes: 300, resetsAt: '2026-10-15T12:00:00Z'}, NOW), false);
    assert.equal(isLongWindow({resetsAt: '2026-10-14T12:00:00Z'}, NOW), true);
    assert.equal(isLongWindow({resetsAt: '2026-10-13T12:00:00Z'}, NOW), false);
    assert.equal(isLongWindow({}, NOW), false);
});

test('window labels preserve the full duration ladder', () => {
    for (const [minutes, slot, expected] of [[null, 0, 'Session'], [null, 1, 'Weekly'],
        [null, 2, 'Monthly'], [null, 4, 'Window'], [40000, 2, 'Monthly'],
        [9000, 1, 'Weekly'], [2880, 1, '2-day'], [300, 0, 'Session (5h)'],
        [90, 1, '2h'], [30, 1, '30m']])
        assert.equal(windowLabel(minutes, slot), expected);
});

test('only the stale statusLine source counts as stale as served', () => {
    assert.equal(isStaleSource({provider: 'claude', source: 'statusline-stale'}), true);
    assert.equal(isStaleSource({provider: 'claude', source: 'statusline'}), false);
    assert.equal(isStaleSource({provider: 'claude', source: 'oauth'}), false);
    assert.equal(isStaleSource({}), false);
    assert.equal(isStaleSource(null), false);
});

test('both statusLine sources are labelled, other sources are not', () => {
    assert.equal(isStatusLineSource({source: 'statusline'}), true);
    assert.equal(isStatusLineSource({source: 'statusline-stale'}), true);
    assert.equal(isStatusLineSource({source: 'oauth'}), false);
    assert.equal(isStatusLineSource(null), false);
});
