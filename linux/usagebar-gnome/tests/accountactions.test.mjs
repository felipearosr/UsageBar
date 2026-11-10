import assert from 'node:assert/strict';
import test from 'node:test';

import {
    CLI_LOGIN_HELPERS,
    actionErrorText,
    addAction,
    addKeyRequest,
    cliLoginArgv,
    keyFormError,
    readKinds,
    removeRequest,
    renameFormError,
    renameRequest,
    rowActions,
    wantsKinds,
} from '../usagebar@felipearosr.github.io/accountactions.js';
import {readReport} from '../usagebar@felipearosr.github.io/clicompat.js';

const ALL = readReport({capabilities: [
    'providerAccountRows', 'providerAccountKinds', 'providerAccountAddKey', 'providerAccountAddCliLogin',
    'providerAccountRename', 'providerAccountRemove',
]}).capabilities;

const KINDS = readKinds({providers: {
    openrouter: {kind: 'key', placeholder: 'Paste API key…', rename: true, remove: true, replacesCurrent: false},
    copilot: {kind: 'key', rename: true, remove: true, replacesCurrent: true},
    codex: {kind: 'cli-login', rename: false, remove: false},
    gemini: {kind: 'cli-login'},
    claude: {kind: 'some-later-kind', rename: true, remove: true},
    antigravity: {rename: true, remove: false},
    broken: 'x',
}});

const FAKE_TOKEN = 'fake-token-for-tests';

test('readKinds keeps each provider\'s kind and actions', () => {
    assert.deepEqual([...KINDS.keys()], ['openrouter', 'copilot', 'codex', 'gemini', 'claude', 'antigravity']);
    assert.deepEqual(KINDS.get('openrouter'),
        {kind: 'key', placeholder: 'Paste API key…', rename: true, remove: true, replacesCurrent: false});
    assert.deepEqual(KINDS.get('copilot'),
        {kind: 'key', placeholder: null, rename: true, remove: true, replacesCurrent: true});
    assert.deepEqual(KINDS.get('codex'),
        {kind: 'cli-login', placeholder: null, rename: false, remove: false, replacesCurrent: false});
    // A kind without a handler here, and no kind at all, both read as null.
    assert.equal(KINDS.get('claude').kind, null);
    assert.deepEqual(KINDS.get('antigravity'),
        {kind: null, placeholder: null, rename: true, remove: false, replacesCurrent: false});
    // Missing fields never turn an action on.
    assert.deepEqual(readKinds({providers: {x: {kind: 'key'}}}).get('x'),
        {kind: 'key', placeholder: null, rename: false, remove: false, replacesCurrent: false});
    assert.equal(readKinds(null).size, 0);
    assert.equal(readKinds({providers: 'openrouter'}).size, 0);
});

test('Add account… shows only where the kind and its action are advertised', () => {
    assert.deepEqual(addAction('openrouter', {kinds: KINDS, capabilities: ALL}),
        {provider: 'openrouter', kind: 'key', placeholder: 'Paste API key…', replacesCurrent: false});
    assert.equal(addAction('copilot', {kinds: KINDS, capabilities: ALL}).replacesCurrent, true);
    assert.equal(addAction('claude', {kinds: KINDS, capabilities: ALL}), null);
    // No kind for the provider (no multi-account support, or a kind this
    // extension has no handler for).
    assert.equal(addAction('cursor', {kinds: KINDS, capabilities: ALL}), null);
    // Capability missing: an older CLI, or one without the add-key action.
    assert.equal(addAction('openrouter', {kinds: KINDS, capabilities: new Set()}), null);
    assert.equal(addAction('openrouter', {kinds: KINDS, capabilities: null}), null);
    const noAdd = new Set([...ALL].filter(name => name !== 'providerAccountAddKey'));
    assert.equal(addAction('openrouter', {kinds: KINDS, capabilities: noAdd}), null);
    const noKinds = new Set([...ALL].filter(name => name !== 'providerAccountKinds'));
    assert.equal(addAction('openrouter', {kinds: KINDS, capabilities: noKinds}), null);
    assert.equal(wantsKinds(noKinds), false);
    assert.equal(wantsKinds(ALL), true);
    // Kinds not fetched yet.
    assert.equal(addAction('openrouter', {kinds: null, capabilities: ALL}), null);
});

test('rename and remove are offered on token account rows only', () => {
    const token = {id: 'token:6f0c2a9e-1b4d-4c8a-9e2f-0a1b2c3d4e5f'};
    const on = (account, provider = 'openrouter', capabilities = ALL) =>
        rowActions(account, {provider, kinds: KINDS, capabilities});
    assert.deepEqual(on(token), {rename: true, remove: true});
    assert.deepEqual(on({id: 'codex-home:abc'}), {rename: false, remove: false});
    assert.deepEqual(on({id: null}), {rename: false, remove: false});
    assert.deepEqual(on({id: 'token:'}), {rename: false, remove: false});
    assert.deepEqual(on(token, 'openrouter', new Set(['providerAccountRename'])), {rename: true, remove: false});
    assert.deepEqual(on(token, 'openrouter', null), {rename: false, remove: false});
    // Claude's token rows: no Add account… here, but rename and remove work.
    assert.deepEqual(on(token, 'claude'), {rename: true, remove: true});
    // Antigravity: serve can't remove its accounts (409), so no Remove.
    assert.deepEqual(on(token, 'antigravity'), {rename: true, remove: false});
    // No kinds entry (not fetched yet, or not a token-account provider).
    assert.deepEqual(on(token, 'gemini'), {rename: false, remove: false});
    assert.deepEqual(rowActions(token, {capabilities: ALL}), {rename: false, remove: false});
});

test('form checks', () => {
    assert.equal(keyFormError({label: 'Work', token: '  '}), 'Paste the key first.');
    assert.equal(keyFormError({label: '', token: FAKE_TOKEN}), null);
    assert.match(keyFormError({label: 'x'.repeat(101), token: FAKE_TOKEN}), /under 100/);
    assert.equal(renameFormError({label: ' '}), 'Enter a label.');
    assert.equal(renameFormError({label: 'Home'}), null);
});

test('requests put the token in the body only and trim fields', () => {
    const add = addKeyRequest({provider: 'openrouter', label: '  Work ', token: ` ${FAKE_TOKEN}\n`});
    assert.deepEqual(add, {
        method: 'POST', path: '/accounts/add',
        body: {provider: 'openrouter', token: FAKE_TOKEN, label: 'Work'},
    });
    assert.ok(!add.path.includes(FAKE_TOKEN));
    assert.deepEqual(addKeyRequest({provider: 'openrouter', label: ' ', token: FAKE_TOKEN}).body,
        {provider: 'openrouter', token: FAKE_TOKEN});
    assert.deepEqual(renameRequest({provider: 'openrouter', accountId: 'token:a', label: ' Home '}), {
        method: 'POST', path: '/accounts/rename',
        body: {provider: 'openrouter', accountId: 'token:a', label: 'Home'},
    });
    assert.deepEqual(removeRequest({provider: 'openrouter', accountId: 'token:a'}), {
        method: 'POST', path: '/accounts/remove', body: {provider: 'openrouter', accountId: 'token:a'},
    });
});

test('error text uses serve\'s message and never shows the token', () => {
    assert.equal(actionErrorText({status: 404, detail: 'No such account.'}), 'No such account.');
    assert.equal(actionErrorText({status: 500}), 'Serve answered HTTP 500.');
    assert.equal(actionErrorText(new Error('serve not running')), 'UsageBar’s backend isn’t running.');
    const text = actionErrorText({status: 400, detail: `bad ${FAKE_TOKEN}`}, FAKE_TOKEN);
    assert.ok(!text.includes(FAKE_TOKEN));
});

test('Codex offers cli-login only with its capability and a helper', () => {
    assert.deepEqual(addAction('codex', {kinds: KINDS, capabilities: ALL}),
        {provider: 'codex', kind: 'cli-login', placeholder: null, replacesCurrent: false});
    const noCliLogin = new Set([...ALL].filter(name => name !== 'providerAccountAddCliLogin'));
    assert.equal(addAction('codex', {kinds: KINDS, capabilities: noCliLogin}), null);
    // Each kind needs its own capability: the key action still shows.
    assert.notEqual(addAction('openrouter', {kinds: KINDS, capabilities: noCliLogin}), null);
    // cli-login for a provider this extension has no helper for.
    assert.equal(addAction('gemini', {kinds: KINDS, capabilities: ALL}), null);
    // Codex's managed rows are never renamed or removed here.
    assert.deepEqual(rowActions({id: 'codex-managed:abc'}, {provider: 'codex', kinds: KINDS, capabilities: ALL}),
        {rename: false, remove: false});
});

test('the cli-login helper runs the extension\'s own codexbar with fixed arguments', () => {
    assert.deepEqual(cliLoginArgv('codex', '/usr/libexec/usagebar/codexbar'),
        ['/usr/libexec/usagebar/codexbar', 'codex-accounts', 'add']);
    // Never a relative or missing binary (a PATH lookup could run another CLI).
    assert.equal(cliLoginArgv('codex', 'codexbar'), null);
    assert.equal(cliLoginArgv('codex', null), null);
    assert.equal(cliLoginArgv('gemini', '/usr/bin/codexbar'), null);
    assert.equal(cliLoginArgv('__proto__', '/usr/bin/codexbar'), null);
    // The argv is a fresh array each time; callers can't change the table.
    cliLoginArgv('codex', '/usr/bin/codexbar').push('--evil');
    assert.deepEqual(CLI_LOGIN_HELPERS.codex, ['codex-accounts', 'add']);
});
