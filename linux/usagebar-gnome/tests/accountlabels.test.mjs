import test from 'node:test';
import assert from 'node:assert/strict';

import {accountIdentity, accountLabels, redactEmails} from '../usagebar@felipearosr.github.io/accountlabels.js';
import {buildCards, mergeStale, primaryRows} from '../usagebar@felipearosr.github.io/accounts.js';
import {summarizeIssues} from '../usagebar@felipearosr.github.io/providerissues.js';
import {planNotifications} from '../usagebar@felipearosr.github.io/notify.js';

const NOW = Date.parse('2026-11-10T12:00:00Z');
// Ids out of row order on purpose: ordinals follow the ids, not the rows.
const ID_A = 'token:0aaaaaaa-0000-4000-8000-000000000001';
const ID_B = 'token:0bbbbbbb-0000-4000-8000-000000000002';
const ID_C = 'token:0ccccccc-0000-4000-8000-000000000003';

const window = usedPercent => ({usedPercent, windowMinutes: 300, resetsAt: '2026-11-10T15:00:00Z'});

function accountRow(provider, accountId, label, {email, org, identityProvider = provider, active = false,
    usedPercent = 40, error, labelIsDefault} = {}) {
    const row = {provider, source: 'oauth', account: label, accountId, accountSource: accountId.split(':')[0],
        accountLabel: label, active};
    if (labelIsDefault !== undefined)
        row.accountLabelIsDefault = labelIsDefault;
    if (error) {
        row.error = {code: 1, kind: 'provider', message: error};
        return row;
    }
    row.updatedAt = '2026-11-10T11:58:00Z';
    row.usage = {primary: window(usedPercent), updatedAt: '2026-11-10T11:58:00Z'};
    if (email || org) {
        row.usage.identity = {providerID: identityProvider, accountEmail: email, accountOrganization: org};
        row.usage.accountEmail = email;
        row.usage.accountOrganization = org;
    }
    return row;
}

const labelsOf = (rows, options) => accountLabels(rows, options).map(entry => entry.label);
const cardLabels = (rows, options = {}) => buildCards(rows, {accountRows: true, now: NOW, ...options})
    .map(card => [card.provider, card.accounts.map(account => account.label)]);

test('Hide Personal Info gives every account an ordinal label, ordered by account id', () => {
    const rows = [
        accountRow('openrouter', ID_C, 'Work', {active: true}),
        accountRow('openrouter', ID_A, 'Personal'),
        accountRow('openrouter', ID_B, 'Side project'),
    ];
    assert.deepEqual(labelsOf(rows, {hidePersonalInfo: true}), ['Account 3', 'Account 1', 'Account 2']);
    // The blocks keep row order, hidden or not, so the toggle never reorders the card.
    const card = buildCards(rows, {accountRows: true, now: NOW, hidePersonalInfo: true})[0];
    assert.deepEqual(card.accounts.map(account => [account.label, account.id]),
        [['Account 3', ID_C], ['Account 1', ID_A], ['Account 2', ID_B]]);
    assert.deepEqual(buildCards(rows, {accountRows: true, now: NOW})[0].accounts.map(account => account.id),
        [ID_C, ID_A, ID_B]);
    assert.equal(card.row.accountId, ID_C, 'the head still follows the active account');
});

test('the ordinal labels are stable across refreshes that reorder the rows', () => {
    const rows = [
        accountRow('openrouter', ID_C, 'Work'),
        accountRow('openrouter', ID_A, 'Personal'),
        accountRow('openrouter', ID_B, 'Side project'),
    ];
    const byId = list => Object.fromEntries(buildCards(list, {accountRows: true, now: NOW, hidePersonalInfo: true})[0]
        .accounts.map(account => [account.id, account.label]));
    const first = byId(rows);
    assert.deepEqual(byId([rows[2], rows[0], rows[1]]), first);
    assert.deepEqual(byId([...rows].reverse()), first);
    // A refresh where one account failed and was carried forward stale.
    const failed = rows.map(row => row.accountId === ID_A
        ? {...row, usage: undefined, updatedAt: undefined, error: {message: 'timed out'}} : row);
    assert.deepEqual(byId(mergeStale(rows, failed)), first);
});

test('Hide Personal Info scrubs every copy of the label and emails in errors', () => {
    const rows = [
        accountRow('claude', ID_A, 'me@example.com', {email: 'me@example.com', active: true}),
        accountRow('claude', ID_B, 'team@example.com',
            {error: 'Claude rejected the token for team@example.com: expired'}),
        {provider: 'openrouter', source: 'api', account: 'boss@example.com',
            usage: {primary: window(95), updatedAt: '2026-11-10T11:59:00Z'}},
    ];
    const cards = buildCards(rows, {accountRows: true, now: NOW, hidePersonalInfo: true});
    const rendered = [];
    for (const card of cards) {
        rendered.push(card.row);
        for (const account of card.accounts)
            rendered.push(account.label, account.error, account.row);
    }
    const issues = summarizeIssues(primaryRows(cards).concat(cards[0].accounts.map(account => account.row)),
        id => id);
    rendered.push(issues);
    const notifications = planNotifications({rows: primaryRows(cards), memo: new Map(),
        sessionThresholds: [50], weeklyThresholds: [], paceEnabled: false, muted: new Set(), now: NOW,
        displayName: id => id}).notifications;
    assert.ok(notifications.length > 0);
    rendered.push(notifications);
    // Everything the popover renders, minus usage.identity, which is never
    // rendered (the Claude plan badge matches on it).
    const text = JSON.stringify(rendered, (key, value) => key === 'identity' ||
        key === 'accountEmail' || key === 'accountOrganization' ? undefined : value);
    assert.doesNotMatch(text, /@example\.com/);
    assert.deepEqual(cards.map(card => card.accounts.map(account => account.label)),
        [['Account 1', 'Account 2'], ['Account 1']]);
    const team = cards[0].accounts[1];
    assert.equal(team.row.account, 'Account 2');
    assert.equal(team.row.accountLabel, 'Account 2');
    assert.equal(team.error, 'Claude rejected the token for [email]: expired');
    assert.equal(cards[1].row.account, 'Account 1');
    // The raw rows are left alone, so turning the setting off restores them.
    assert.equal(rows[1].accountLabel, 'team@example.com');
    assert.deepEqual(cardLabels(rows), [['claude', ['me@example.com', 'team@example.com']],
        ['openrouter', ['boss@example.com']]]);
});

test('accounts sharing an email use the alias, then email · org, then email · Account N', () => {
    const same = 'me@example.com';
    // Alias wins.
    assert.deepEqual(labelsOf([
        accountRow('claude', ID_A, 'Personal', {email: same, org: 'Acme'}),
        accountRow('claude', ID_B, same, {email: same, org: 'Team Org'}),
    ]), ['Personal', `${same} · Team Org`]);
    // No alias: the org.
    assert.deepEqual(labelsOf([
        accountRow('claude', ID_A, same, {email: same, org: 'Personal org'}),
        accountRow('claude', ID_B, same, {email: same, org: 'Team org'}),
    ]), [`${same} · Personal org`, `${same} · Team org`]);
    // No alias, no org: the stable ordinal (by id, not row order).
    assert.deepEqual(labelsOf([
        accountRow('claude', ID_B, same, {email: same}),
        accountRow('claude', ID_A, same, {email: same}),
    ]), [`${same} · Account 2`, `${same} · Account 1`]);
    // Emails compare case-insensitively.
    assert.deepEqual(labelsOf([
        accountRow('claude', ID_A, 'Me@Example.com', {email: 'Me@Example.com'}),
        accountRow('claude', ID_B, same, {email: same}),
    ]), ['Me@Example.com · Account 1', `${same} · Account 2`]);
});

test('labels that would still collide get the ordinal too', () => {
    const same = 'me@example.com';
    assert.deepEqual(labelsOf([
        accountRow('claude', ID_A, same, {email: same, org: 'Acme'}),
        accountRow('claude', ID_B, same, {email: same, org: 'Acme'}),
    ]), [`${same} · Acme · Account 1`, `${same} · Acme · Account 2`]);
    assert.deepEqual(labelsOf([
        accountRow('openrouter', ID_A, 'Work'),
        accountRow('openrouter', ID_B, 'work'),
    ]), ['Work · Account 1', 'work · Account 2']);
});

test('unique emails and plain labels are shown unchanged', () => {
    assert.deepEqual(cardLabels([
        accountRow('claude', ID_A, 'me@example.com', {email: 'me@example.com', org: 'Acme'}),
        accountRow('claude', ID_B, 'other@example.com', {email: 'other@example.com', org: 'Acme'}),
        accountRow('openrouter', ID_A, 'Personal'),
        accountRow('openrouter', ID_B, 'Work'),
    ]), [['claude', ['me@example.com', 'other@example.com']], ['openrouter', ['Personal', 'Work']]]);
    // Token accounts carry their label as accountEmail when the provider has
    // no email: that isn't an email and never triggers disambiguation.
    assert.deepEqual(labelsOf([
        accountRow('openrouter', ID_A, 'Personal', {email: 'Personal'}),
        accountRow('openrouter', ID_B, 'Work', {email: 'Work'}),
    ]), ['Personal', 'Work']);
});

test('no label uses identity fields from a different provider', () => {
    const same = 'me@example.com';
    // Codex rows whose identity names Claude: neither the email nor the org is used.
    const codex = [
        accountRow('codex', ID_A, 'Personal', {email: same, org: 'Claude Org', identityProvider: 'claude'}),
        accountRow('codex', ID_B, 'Work', {email: same, org: 'Other Claude Org', identityProvider: 'claude'}),
    ];
    assert.deepEqual(accountIdentity(codex[0]), {email: null, org: null});
    assert.deepEqual(labelsOf(codex), ['Personal', 'Work']);
    // Same-email rows labelled by email: the foreign org never appears.
    const foreign = [
        accountRow('codex', ID_A, same, {email: same, org: 'Claude Org', identityProvider: 'claude'}),
        accountRow('codex', ID_B, same, {email: same, org: 'Claude Org', identityProvider: 'claude'}),
    ];
    assert.deepEqual(labelsOf(foreign), [`${same} · Account 1`, `${same} · Account 2`]);
    // An identity without a providerID isn't trusted either.
    assert.deepEqual(accountIdentity({provider: 'codex', usage: {identity: {accountEmail: same}}}),
        {email: null, org: null});
    // The same email on another provider's card doesn't make this card's labels ambiguous.
    assert.deepEqual(cardLabels([
        accountRow('claude', ID_A, same, {email: same, org: 'Claude Org'}),
        accountRow('claude', ID_B, 'other@example.com', {email: 'other@example.com'}),
        accountRow('codex', ID_A, same, {email: same, org: 'Codex Org'}),
        accountRow('codex', ID_B, 'Work', {email: 'work@example.com'}),
    ]), [['claude', [same, 'other@example.com']], ['codex', [same, 'Work']]]);
});

test('without the capability or account ids nothing changes unless Hide Personal Info is on', () => {
    const rows = [
        {provider: 'claude', source: 'oauth', usage: {primary: window(20)}},
        {provider: 'openrouter', source: 'api', account: 'Work', usage: {primary: window(64)}},
    ];
    const cards = buildCards(rows, {now: NOW});
    assert.deepEqual(primaryRows(cards), rows);
    // No label and no email: the ordinal, never a bare "Account".
    assert.deepEqual(cards.map(card => card.accounts[0].label), ['Account 1', 'Work']);
    const hidden = buildCards(rows, {now: NOW, hidePersonalInfo: true});
    assert.deepEqual(hidden.map(card => card.accounts[0].label), ['Account 1', 'Account 1']);
    assert.equal(hidden[1].row.account, 'Account 1');
    assert.equal('account' in hidden[0].row, false);
});

test('email redaction in free text', () => {
    assert.equal(redactEmails('no access for a.b+c@mail.example.org, retry'), 'no access for [email], retry');
    assert.equal(redactEmails('GET /v1/users/me%40example.com failed'), 'GET /v1/users/[email] failed');
    assert.equal(redactEmails('nothing here'), 'nothing here');
    assert.equal(redactEmails(undefined), undefined);
});

// Serve labels an account the user didn't name "Account N" by store index;
// that is not an alias, and the numbers are the extension's own.
test('serve\'s default label is not an alias: same email, different orgs show the orgs', () => {
    const same = 'me@example.com';
    for (const labelIsDefault of [true, undefined]) { // flagged, and an older serve without the flag
        assert.deepEqual(labelsOf([
            accountRow('claude', ID_B, 'Account 1', {email: same, org: 'Personal org', labelIsDefault}),
            accountRow('claude', ID_A, 'Account 2', {email: same, org: 'Team org', labelIsDefault}),
        ]), [`${same} · Personal org`, `${same} · Team org`]);
    }
    // The flag alone decides, whatever the default label reads.
    assert.deepEqual(labelsOf([
        accountRow('claude', ID_A, 'Konto 1', {email: same, labelIsDefault: true}),
        accountRow('claude', ID_B, 'Konto 2', {email: same, labelIsDefault: true}),
    ]), [`${same} · Account 1`, `${same} · Account 2`]);
});

test('default labels keep their number when Hide Personal Info is turned on', () => {
    // Store order B, A: serve numbers them 1, 2; the ids sort A, B.
    const rows = [
        accountRow('openrouter', ID_B, 'Account 1', {labelIsDefault: true}),
        accountRow('openrouter', ID_A, 'Account 2', {labelIsDefault: true}),
    ];
    const shown = labelsOf(rows);
    assert.deepEqual(shown, ['Account 2', 'Account 1']);
    assert.deepEqual(labelsOf(rows, {hidePersonalInfo: true}), shown);
});

test('a labelled and an unlabelled account sharing an email never read alike', () => {
    const same = 'me@example.com';
    // Store order [B labelled with the email, A blank].
    const labels = labelsOf([
        accountRow('claude', ID_B, same, {email: same}),
        accountRow('claude', ID_A, 'Account 2', {email: same, labelIsDefault: true}),
    ]);
    assert.deepEqual(labels, [`${same} · Account 2`, `${same} · Account 1`]);
    // A blank label with a unique email reads as the email.
    assert.deepEqual(labelsOf([
        accountRow('claude', ID_A, 'Account 1', {email: same, labelIsDefault: true}),
        accountRow('claude', ID_B, 'Work', {email: 'work@example.com'}),
    ]), [same, 'Work']);
});
