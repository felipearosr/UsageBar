import test from 'node:test';
import assert from 'node:assert/strict';

import {
    ACCOUNT_ROWS_CAPABILITY,
    accountKey,
    accountsRenderKey,
    agoText,
    buildCards,
    forgetAccount,
    mergeStale,
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

test('malformed payloads yield no cards', () => {
    assert.deepEqual(buildCards(null, {accountRows: true}), []);
    assert.deepEqual(buildCards([null, 3], {accountRows: true}), []);
});

test('forgetAccount keeps a removed account from coming back as a stale row', () => {
    const window = {usedPercent: 40, windowMinutes: 300};
    const tagged = (id, label) => ({provider: 'openrouter', accountId: `token:${id}`, accountLabel: label,
        usage: {primary: window, updatedAt: '2026-11-10T10:00:00Z'}});
    const rows = [{provider: 'claude', usage: {primary: window}}, tagged('a', 'Personal'), tagged('b', 'Work')];

    // Two accounts left after removing one of three: only that one goes.
    const three = [...rows, tagged('c', 'Side')];
    assert.deepEqual(forgetAccount(three, 'openrouter', 'token:c').map(r => r.accountLabel ?? r.provider),
        ['claude', 'Personal', 'Work']);

    // One left: serve now answers the provider untagged, so its tagged rows go.
    const pruned = forgetAccount(rows, 'openrouter', 'token:a');
    assert.deepEqual(pruned.map(r => r.provider), ['claude']);
    // A provider-level error on the next poll no longer expands into the old accounts.
    const fresh = () => [{provider: 'claude', usage: {primary: window}},
        {provider: 'openrouter', error: {message: 'timed out'}}];
    const merged = mergeStale(pruned, fresh());
    assert.equal(merged.filter(r => r.provider === 'openrouter').length, 1);
    assert.ok(!merged.some(r => r.accountLabel === 'Personal'));
    // Without forgetting, the removed account would come back.
    assert.ok(mergeStale(rows, fresh()).some(r => r.accountLabel === 'Personal'));
});
