import assert from 'node:assert/strict';
import test from 'node:test';

import {
    actionErrorText,
    addAction,
    addKeyRequest,
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
    'providerAccountRows', 'providerAccountKinds', 'providerAccountAddKey',
    'providerAccountRename', 'providerAccountRemove',
]}).capabilities;

const KINDS = readKinds({providers: {
    openrouter: {kind: 'key', placeholder: 'Paste API key…'},
    copilot: {kind: 'key'},
    codex: {kind: 'cli-login'},
    claude: {kind: 'claude-swap'},
    broken: {placeholder: 'x'},
}});

const FAKE_TOKEN = 'fake-token-for-tests';

test('readKinds keeps the kinds this extension can add', () => {
    assert.deepEqual([...KINDS.keys()], ['openrouter', 'copilot']);
    assert.deepEqual(KINDS.get('openrouter'), {kind: 'key', placeholder: 'Paste API key…'});
    assert.deepEqual(KINDS.get('copilot'), {kind: 'key', placeholder: null});
    assert.equal(readKinds(null).size, 0);
    assert.equal(readKinds({providers: 'openrouter'}).size, 0);
});

test('Add account… shows only where the kind and its action are advertised', () => {
    assert.deepEqual(addAction('openrouter', {kinds: KINDS, capabilities: ALL}),
        {provider: 'openrouter', kind: 'key', placeholder: 'Paste API key…'});
    // No kind for the provider (no multi-account support, or a kind this
    // extension has no handler for).
    assert.equal(addAction('gemini', {kinds: KINDS, capabilities: ALL}), null);
    assert.equal(addAction('codex', {kinds: KINDS, capabilities: ALL}), null);
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
    assert.deepEqual(rowActions(token, ALL), {rename: true, remove: true});
    assert.deepEqual(rowActions({id: 'codex-home:abc'}, ALL), {rename: false, remove: false});
    assert.deepEqual(rowActions({id: null}, ALL), {rename: false, remove: false});
    assert.deepEqual(rowActions({id: 'token:'}, ALL), {rename: false, remove: false});
    assert.deepEqual(rowActions(token, new Set(['providerAccountRename'])), {rename: true, remove: false});
    assert.deepEqual(rowActions(token, null), {rename: false, remove: false});
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
