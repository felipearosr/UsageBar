import test from 'node:test';
import assert from 'node:assert/strict';
import {extraWindowsOf, feedBadge, isLongWindow, isStaleSource, isStatusLineSource, paceOf, paceSplitOf, resetSecs, windowLabel,
    windowsOf}
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

test('only the stale feed and claude-swap sources count as stale as served', () => {
    assert.equal(isStaleSource({provider: 'claude', source: 'statusline-stale'}), true);
    assert.equal(isStaleSource({provider: 'claude', source: 't3code-stale'}), true);
    assert.equal(isStaleSource({provider: 'claude', source: 'orca-stale'}), true);
    assert.equal(isStaleSource({provider: 'claude', source: 'orca-dev-stale'}), true);
    assert.equal(isStaleSource({provider: 'claude', source: 't3code'}), false);
    assert.equal(isStaleSource({provider: 'claude', source: 'oauth-stale'}), false);
    assert.equal(isStaleSource({provider: 'claude', source: 'claude-swap-stale'}), true);
    assert.equal(isStaleSource({provider: 'claude', source: 'claude-swap'}), false);
    assert.equal(isStaleSource({provider: 'claude', source: 'statusline'}), false);
    assert.equal(isStaleSource({provider: 'claude', source: 'oauth'}), false);
    assert.equal(isStaleSource({}), false);
    assert.equal(isStaleSource(null), false);
});

test('every feed source is labelled with the record it read, other sources are not', () => {
    assert.equal(isStatusLineSource({source: 'statusline'}), true);
    assert.equal(isStatusLineSource({source: 'statusline-stale'}), true);
    assert.equal(isStatusLineSource({source: 't3code'}), true);
    assert.equal(isStatusLineSource({source: 'orca-dev-stale'}), true);
    assert.equal(isStatusLineSource({source: 'oauth'}), false);
    assert.equal(isStatusLineSource({source: 'claude-swap-stale'}), false);
    assert.equal(isStatusLineSource({source: 'constructor'}), false);
    assert.equal(isStatusLineSource(null), false);
    assert.equal(feedBadge({source: 'statusline-stale'}), 'statusLine');
    assert.equal(feedBadge({source: 't3code'}), 'T3 Code');
    assert.equal(feedBadge({source: 'orca'}), 'Orca');
    assert.equal(feedBadge({source: 'orca-dev-stale'}), 'Orca dev');
    assert.equal(feedBadge({source: 'oauth'}), null);
});

test('pace splits the bar at the expected usage unless on track', () => {
    assert.deepEqual(paceSplitOf({stage: 'behind', expectedUsedPercent: 15, deltaPercent: 7}, 22),
        {at: 15, deficit: true});
    assert.deepEqual(paceSplitOf({stage: 'ahead', expectedUsedPercent: 35, deltaPercent: -25}, 10),
        {at: 35, deficit: false});
    // Older payloads without a delta fall back to comparing usage.
    assert.deepEqual(paceSplitOf({expectedUsedPercent: 15}, 22), {at: 15, deficit: true});
    assert.equal(paceSplitOf({stage: 'onTrack', expectedUsedPercent: 40, deltaPercent: 0}, 40), null);
    assert.equal(paceSplitOf({summary: '7% in deficit'}, 22), null);
    assert.equal(paceSplitOf({expectedUsedPercent: 0}, 5), null);
    assert.equal(paceSplitOf({expectedUsedPercent: 100}, 5), null);
    assert.equal(paceSplitOf(null, 5), null);
});
