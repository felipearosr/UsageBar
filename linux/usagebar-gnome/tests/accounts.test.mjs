import test from 'node:test';
import assert from 'node:assert/strict';

import {
    ACCOUNT_ROWS_CAPABILITY,
    accountKey,
    accountsRenderKey,
    agoText,
    buildCards,
    ICON_SOURCES,
    mergeStale,
    notificationRows,
    panelAccount,
    panelRows,
    primaryRows,
    usagePath,
} from '../usagebar@felipearosr.github.io/accounts.js';
import {readReport} from '../usagebar@felipearosr.github.io/clicompat.js';

const NOW = Date.parse('2026-11-10T12:00:00Z');
const PERSONAL = 'token:6f0c2a9e-1b4d-4c8a-9e2f-0a1b2c3d4e5f';
const WORK = 'token:0d9e8f7a-6b5c-4d3e-8f1a-2b3c4d5e6f70';

const window = (usedPercent, resetsAt = '2026-11-10T15:00:00Z') => ({usedPercent, windowMinutes: 300, resetsAt});

// What `codexbar serve` answers to /usage?accounts=all: two OpenRouter keys
// (Work active, Personal's key rejected), plus Claude with a single account.
function accountPayload() {
    return [
        {provider: 'claude', source: 'oauth', account: null,
            usage: {primary: window(20), updatedAt: '2026-11-10T11:59:00Z'}},
        {provider: 'openrouter', source: 'api', account: 'Personal', accountId: PERSONAL,
            accountSource: 'token', accountLabel: 'Personal', active: false,
            error: {code: 1, kind: 'provider', message: 'OpenRouter rejected the key'}},
        {provider: 'openrouter', source: 'api', account: 'Work', accountId: WORK,
            accountSource: 'token', accountLabel: 'Work', active: true,
            updatedAt: '2026-11-10T11:55:00Z',
            usage: {primary: window(64), updatedAt: '2026-11-10T11:55:00Z'}},
    ];
}

// What a CLI without the capability answers to plain /usage.
function singlePayload() {
    return [
        {provider: 'claude', source: 'oauth', usage: {primary: window(20), updatedAt: '2026-11-10T11:59:00Z'}},
        {provider: 'openrouter', source: 'api', account: 'Work',
            usage: {primary: window(64), updatedAt: '2026-11-10T11:55:00Z'}},
    ];
}

test('the request asks for account rows only when serve advertised them', () => {
    assert.equal(usagePath(), '/usage');
    assert.equal(usagePath({fresh: true}), '/usage?fresh=1');
    assert.equal(usagePath({accountRows: true}), '/usage?accounts=all');
    assert.equal(usagePath({accountRows: true, fresh: true}), '/usage?accounts=all&fresh=1');
});

test('the /health capability report carries providerAccountRows', () => {
    const report = readReport({status: 'ok', capabilities: ['machineSync', ACCOUNT_ROWS_CAPABILITY]});
    assert.equal(report.capabilities.has('providerAccountRows'), true);
    assert.equal(readReport({status: 'ok', capabilities: ['machineSync']})
        .capabilities.has(ACCOUNT_ROWS_CAPABILITY), false);
});

test('one card per provider with one row per account, active marking and freshness', () => {
    const cards = buildCards(accountPayload(), {accountRows: true, now: NOW});
    assert.deepEqual(cards.map(card => [card.provider, card.multi, card.accounts.length]),
        [['claude', false, 1], ['openrouter', true, 2]]);
    const openrouter = cards[1];
    assert.deepEqual(openrouter.accounts.map(a => ({id: a.id, source: a.source, label: a.label, active: a.active,
        freshness: a.freshness, error: a.error})), [
        {id: PERSONAL, source: 'token', label: 'Personal', active: false, freshness: null,
            error: 'OpenRouter rejected the key'},
        {id: WORK, source: 'token', label: 'Work', active: true, freshness: 'updated 5m ago', error: null},
    ]);
    // Each account row keeps its own Quota; the failing one has none borrowed.
    assert.equal(openrouter.accounts[1].row.usage.primary.usedPercent, 64);
    assert.equal(openrouter.accounts[0].row.usage, undefined);
    // The rest of the popover follows the active account.
    assert.equal(openrouter.row.accountId, WORK);
    assert.deepEqual(primaryRows(cards).map(row => row.provider), ['claude', 'openrouter']);
});

test('without an active account the card follows the first account with Quota', () => {
    const rows = accountPayload().map(row => ({...row, active: false}));
    const card = buildCards(rows, {accountRows: true, now: NOW})[1];
    assert.equal(card.row.accountId, WORK);
    assert.equal(card.accounts.some(account => account.active), false);
});

test('a payload without the capability gives today\'s single-account cards', () => {
    const rows = singlePayload();
    for (const options of [{now: NOW}, {accountRows: false, now: NOW}]) {
        const cards = buildCards(rows, options);
        assert.deepEqual(cards.map(card => [card.provider, card.multi, card.accounts.length]),
            [['claude', false, 1], ['openrouter', false, 1]]);
        assert.deepEqual(primaryRows(cards), rows);
        assert.equal(cards[1].accounts[0].active, true);
        assert.equal(cards[1].accounts[0].label, 'Work');
        assert.equal(cards[1].accounts[0].freshness, 'updated 5m ago');
        assert.equal(accountsRenderKey(cards[1]), '');
    }
    // Even account rows stay one card each when the capability is missing.
    const cards = buildCards(accountPayload(), {now: NOW});
    assert.deepEqual(cards.map(card => card.multi), [false, false, false]);
    assert.deepEqual(primaryRows(cards), accountPayload());
});

test('with the capability, rows without an account id still render as before', () => {
    const rows = singlePayload();
    const cards = buildCards(rows, {accountRows: true, now: NOW});
    assert.deepEqual(primaryRows(cards), rows);
    assert.deepEqual(cards.map(card => card.multi), [false, false]);
});

test('a stale error row borrows only its own account\'s last Quota', () => {
    const previous = accountPayload().map(row => row.accountId === PERSONAL
        ? {...row, error: undefined, usage: {primary: window(12)}} : row);
    const fresh = accountPayload().map(row => row.accountId === WORK
        ? {...row, usage: undefined, updatedAt: undefined, error: {message: 'timed out'}} : row);
    const merged = mergeStale(previous, fresh);
    const byId = new Map(merged.map(row => [row.accountId ?? row.provider, row]));
    assert.equal(byId.get(WORK).usage.primary.usedPercent, 64);
    assert.equal(byId.get(WORK).stale, true);
    // The carried Quota keeps the time it was fetched, so the card never says "just now" over old numbers.
    assert.equal(byId.get(WORK).updatedAt, '2026-11-10T11:55:00Z');
    const work = buildCards(merged, {accountRows: true, now: NOW})[1].accounts[1];
    assert.equal(work.freshness, 'updated 5m ago');
    assert.equal(work.error, 'timed out');
    // Personal had Quota before, but its fresh row was the error row: Work's never moves onto it.
    assert.equal(byId.get(PERSONAL).usage.primary.usedPercent, 12);

    // A provider without accounts still continues by provider.
    const plain = mergeStale(singlePayload(), [{provider: 'claude', source: 'oauth', error: {message: 'x'}}]);
    assert.equal(plain[0].stale, true);
    assert.equal(plain[0].usage.primary.usedPercent, 20);
});

test('an untagged provider error keeps every account\'s last Quota, stale', () => {
    const previous = accountPayload();
    const timeout = {provider: 'openrouter', source: 'auto',
        error: {code: 1, kind: 'provider', message: 'openrouter usage timed out'}};
    const merged = mergeStale(previous, [previous[0], timeout]);
    const openrouter = merged.filter(row => row.provider === 'openrouter');
    assert.deepEqual(openrouter.map(row => row.accountId), [PERSONAL, WORK]);
    assert.ok(openrouter.every(row => row.stale && row.error.message === 'openrouter usage timed out'));
    assert.equal(openrouter[1].usage.primary.usedPercent, 64);
    assert.equal(openrouter[1].updatedAt, '2026-11-10T11:55:00Z');
    const cards = buildCards(merged, {accountRows: true, now: NOW});
    assert.deepEqual(cards.map(card => [card.provider, card.multi]), [['claude', false], ['openrouter', true]]);
    assert.equal(cards[1].row.accountId, WORK);
    // Nothing tagged before: the row stays a provider error as it always was.
    const plain = mergeStale(singlePayload(), [timeout]);
    assert.equal(plain.length, 1);
    assert.equal(plain[0].usage.primary.usedPercent, 64);
});

test('an untagged row joins its provider\'s account card instead of a second card', () => {
    const rows = [...accountPayload(), {provider: 'openrouter', source: 'api', error: {message: 'odd'}}];
    const cards = buildCards(rows, {accountRows: true, now: NOW});
    assert.deepEqual(cards.map(card => card.provider), ['claude', 'openrouter']);
    assert.deepEqual(cards[1].accounts.map(account => account.id), [PERSONAL, WORK, null]);
    assert.equal(cards[1].row.accountId, WORK);
});

test('account keys separate accounts and fall back to the provider', () => {
    const [claude, personal, work] = accountPayload();
    assert.equal(accountKey(claude), 'claude');
    assert.notEqual(accountKey(personal), accountKey(work));
});

test('the render key changes with an account\'s state', () => {
    const before = buildCards(accountPayload(), {accountRows: true, now: NOW})[1];
    const later = buildCards(accountPayload(), {accountRows: true, now: NOW + 10 * 60 * 1000})[1];
    assert.notEqual(accountsRenderKey(before), accountsRenderKey(later));
    assert.equal(accountsRenderKey(before),
        accountsRenderKey(buildCards(accountPayload(), {accountRows: true, now: NOW})[1]));
});

test('freshness text', () => {
    assert.equal(agoText(3), 'just now');
    assert.equal(agoText(45), '45s ago');
    assert.equal(agoText(300), '5m ago');
    assert.equal(agoText(7200), '2h ago');
});

// Three OpenRouter accounts for the panel icon source: Work active at 64%,
// Personal at 30% in its session but 50% in its weekly window, Spare with
// most headroom but a stale carried Quota behind an error, Old stale with no
// usage at all.
const SPARE = 'token:9a8b7c6d-5e4f';
const OLD = 'token:1a2b3c4d-5e6f';
function headroomPayload({personalWeekly = 50} = {}) {
    return [
        {provider: 'claude', source: 'oauth', usage: {primary: window(20)}},
        {provider: 'openrouter', accountId: WORK, accountLabel: 'work@example.com', active: true,
            usage: {primary: window(64)}},
        {provider: 'openrouter', accountId: PERSONAL, accountLabel: 'me@example.com', active: false,
            usage: {primary: window(30), secondary: {...window(personalWeekly), windowMinutes: 10080}}},
        {provider: 'openrouter', accountId: SPARE, accountLabel: 'Spare', active: false, stale: true,
            error: {message: 'timed out'}, usage: {primary: window(5)}},
        {provider: 'openrouter', accountId: OLD, accountLabel: 'Old', active: false, stale: true},
    ];
}
const cardMap = cards => new Map(cards.filter(card => card.multi).map(card => [card.provider, card]));

test('the panel icon source defaults to the active account', () => {
    const cards = buildCards(headroomPayload(), {accountRows: true, now: NOW});
    const rows = primaryRows(cards);
    assert.deepEqual(ICON_SOURCES, ['active', 'most-headroom']);
    assert.equal(panelAccount(cards[1]).id, WORK);
    assert.deepEqual(panelRows(rows, cardMap(cards)), rows);
    assert.equal(panelRows(rows, cardMap(cards), 'active')[1], rows[1]);
    assert.equal(panelRows(rows, cardMap(cards), 'bogus')[1], rows[1]);
});

test('most headroom picks the lowest chip percent, skipping error and usage-less rows', () => {
    const cards = buildCards(headroomPayload(), {accountRows: true, now: NOW});
    assert.equal(panelAccount(cards[1], 'most-headroom').id, PERSONAL);
    const chips = panelRows(primaryRows(cards), cardMap(cards), 'most-headroom');
    assert.equal(chips[0], cards[0].row);
    assert.equal(chips[1].accountId, PERSONAL);
});

test('an account\'s chip percent is its most-used window, as the chip shows', () => {
    // Personal's 30% session hides a 70% weekly window: Work's 64% has more headroom.
    const cards = buildCards(headroomPayload({personalWeekly: 70}), {accountRows: true, now: NOW});
    assert.equal(panelAccount(cards[1], 'most-headroom').id, WORK);
});

test('most headroom ties keep the active account and falls back to it without candidates', () => {
    const tie = buildCards(headroomPayload({personalWeekly: 64}), {accountRows: true, now: NOW});
    assert.equal(panelAccount(tie[1], 'most-headroom').id, WORK);
    const none = buildCards(headroomPayload().map(row => row.provider === 'openrouter'
        ? {...row, usage: undefined, stale: true} : row), {accountRows: true, now: NOW});
    assert.equal(panelAccount(none[1], 'most-headroom').id, WORK);
});

test('with one account the panel rows are exactly the popover rows for either source', () => {
    for (const [payload, accountRows] of [[singlePayload(), false], [accountPayload().slice(0, 1), true],
        [[headroomPayload()[1]], true]]) {
        const cards = buildCards(payload, {accountRows, now: NOW});
        const rows = primaryRows(cards);
        for (const source of ICON_SOURCES) {
            const chips = panelRows(rows, cardMap(cards), source);
            assert.equal(chips.length, rows.length);
            chips.forEach((chip, index) => assert.equal(chip, rows[index]));
        }
    }
});

test('notification rows expand multi-account cards with their display labels', () => {
    const cards = buildCards(headroomPayload(), {accountRows: true, now: NOW});
    const rows = primaryRows(cards).map(row => ({...row, enriched: true}));
    const notify = notificationRows(rows, cardMap(cards));
    assert.deepEqual(notify.map(row => [row.provider, row.accountId ?? null, row.accountLabel ?? null]), [
        ['claude', null, null],
        ['openrouter', WORK, 'work@example.com'],
        ['openrouter', PERSONAL, 'me@example.com'],
        ['openrouter', SPARE, 'Spare'],
        ['openrouter', OLD, 'Old'],
    ]);
    // The primary account keeps the popover's own (enriched) row.
    assert.equal(notify[1].enriched, true);
    assert.equal(notify[2].enriched, undefined);
    // Single-account cards pass through untouched.
    assert.equal(notify[0], rows[0]);
});

test('with Hide Personal Info the notification rows carry ordinal labels only', () => {
    const cards = buildCards(headroomPayload(), {accountRows: true, now: NOW, hidePersonalInfo: true});
    const notify = notificationRows(primaryRows(cards), cardMap(cards));
    const labels = new Map(notify.filter(row => row.accountId).map(row => [row.accountId, row.accountLabel]));
    assert.deepEqual([...labels.values()].sort(), ['Account 1', 'Account 2', 'Account 3', 'Account 4']);
    assert.doesNotMatch(JSON.stringify(notify), /@example\.com/);
});

test('without an active account the primary is picked by account id, not row order or privacy', () => {
    const rows = headroomPayload().map(row => ({...row, active: false}));
    const reversed = [rows[0], ...rows.slice(1).reverse()];
    // Work's id sorts first and has Quota.
    for (const payload of [rows, reversed]) {
        for (const hidePersonalInfo of [false, true]) {
            const card = buildCards(payload, {accountRows: true, now: NOW, hidePersonalInfo})[1];
            assert.equal(card.row.accountId, WORK);
        }
    }
});

test('most headroom ties among other accounts go to the lowest account id', () => {
    const rows = headroomPayload().slice(0, 2).concat([
        {provider: 'openrouter', accountId: SPARE, accountLabel: 'Spare', usage: {primary: window(10)}},
        {provider: 'openrouter', accountId: PERSONAL, accountLabel: 'Personal', usage: {primary: window(10)}},
    ]);
    for (const payload of [rows, [rows[0], rows[1], rows[3], rows[2]]]) {
        const card = buildCards(payload, {accountRows: true, now: NOW})[1];
        assert.equal(panelAccount(card, 'most-headroom').id, PERSONAL);
    }
});

test('malformed payloads yield no cards', () => {
    assert.deepEqual(buildCards(null, {accountRows: true}), []);
    assert.deepEqual(buildCards([null, 3], {accountRows: true}), []);
});

// Managed Codex accounts (#168): serve tags the everyday login `codex-system`
// (active) and each managed account `codex-managed`, in one Codex card.
test('managed Codex accounts and the everyday login share one Codex card', () => {
    const rows = [
        {provider: 'codex', source: 'oauth', account: 'me@example.com', accountId: 'codex-system:3f9a1c2b7d4e8f60',
            accountSource: 'codex-system', accountLabel: 'me@example.com', active: true,
            updatedAt: '2026-11-10T11:59:00Z', usage: {primary: window(18), updatedAt: '2026-11-10T11:59:00Z'}},
        {provider: 'codex', source: 'oauth', account: 'old@example.com',
            accountId: 'codex-managed:7a1e2d3c-4b5a-4c6d-8e7f-9a0b1c2d3e4f',
            accountSource: 'codex-managed', accountLabel: 'old@example.com', active: false,
            error: {code: 1, kind: 'provider', message: 'Codex OAuth token expired'}},
        {provider: 'codex', source: 'oauth', account: 'work@example.com',
            accountId: 'codex-managed:1b2c3d4e-5f60-4718-9a2b-3c4d5e6f7a8b',
            accountSource: 'codex-managed', accountLabel: 'work@example.com', active: false,
            updatedAt: '2026-11-10T11:58:00Z', usage: {primary: window(71), updatedAt: '2026-11-10T11:58:00Z'}},
    ];
    const cards = buildCards(rows, {accountRows: true, now: NOW});
    assert.equal(cards.length, 1);
    const [card] = cards;
    assert.equal(card.multi, true);
    assert.deepEqual(card.accounts.map(account => account.source),
        ['codex-system', 'codex-managed', 'codex-managed']);
    assert.deepEqual(card.accounts.map(account => account.active), [true, false, false]);
    assert.deepEqual(card.accounts.map(account => account.error), [null, 'Codex OAuth token expired', null]);
    assert.equal(card.row.accountLabel, 'me@example.com');

    // Without managed accounts serve sends upstream's untagged row: today's card.
    const plain = buildCards([{provider: 'codex', source: 'oauth', account: 'me@example.com',
        usage: {primary: window(18), updatedAt: '2026-11-10T11:59:00Z'}}], {accountRows: true, now: NOW});
    assert.equal(plain.length, 1);
    assert.equal(plain[0].multi, false);
    assert.equal(plain[0].accounts[0].id, null);
});
