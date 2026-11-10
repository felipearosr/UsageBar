import assert from 'node:assert/strict';
import test from 'node:test';

import {
    ADD_CAPABILITY,
    CLAUDE_SWAP_KIND,
    NO_INSTALLER_ERROR,
    addHelperArgv,
    detectRequest,
    installArgv,
    installConfirmLabel,
    installOfferText,
    installerName,
    nextStep,
    readDetect,
} from '../usagebar@felipearosr.github.io/claudeswapadd.js';
import {ADD_CAPABILITIES, addAction, readKinds} from '../usagebar@felipearosr.github.io/accountactions.js';
import {readReport} from '../usagebar@felipearosr.github.io/clicompat.js';

// A fake PATH lookup: name → absolute path, for the programs "installed".
function finder(installed) {
    return name => installed[name] ?? null;
}

test('the claude-swap kind is wired to its capability', () => {
    assert.equal(ADD_CAPABILITIES[CLAUDE_SWAP_KIND], ADD_CAPABILITY);
    const kinds = readKinds({providers: {claude: {kind: 'claude-swap', rename: true, remove: true}}});
    const withIt = readReport({capabilities: ['providerAccountKinds', ADD_CAPABILITY]}).capabilities;
    const without = readReport({capabilities: ['providerAccountKinds']}).capabilities;
    assert.deepEqual(addAction('claude', {kinds, capabilities: withIt}),
        {provider: 'claude', kind: 'claude-swap', placeholder: null, replacesCurrent: false});
    // An older serve that lists the kind but not the action offers nothing.
    assert.equal(addAction('claude', {kinds, capabilities: without}), null);
});

test('detect is a POST to the guarded route', () => {
    assert.deepEqual(detectRequest(), {method: 'POST', path: '/accounts/claude-swap/detect', body: {}});
});

test('installed opens the add helper, anything else the install offer', () => {
    const found = readDetect({installed: true, executablePath: '/home/u/.local/bin/cswap', enabled: true});
    assert.deepEqual(found, {installed: true, path: '/home/u/.local/bin/cswap', message: null});
    assert.equal(nextStep(found), 'add');

    const missing = readDetect({installed: false, enabled: false, message: 'claude-swap is not installed.'});
    assert.deepEqual(missing, {installed: false, path: null, message: 'claude-swap is not installed.'});
    assert.equal(nextStep(missing), 'install');

    // Malformed answers never open the helper.
    for (const json of [null, {}, {installed: 'yes'}, {installed: true}, {installed: true, executablePath: 'cswap'}])
        assert.equal(nextStep(readDetect(json)), 'install', JSON.stringify(json));
    assert.equal(nextStep(null), 'install');
});

test('the add helper is codexbar claude add-account with no shell', () => {
    assert.deepEqual(addHelperArgv('/opt/usagebar/codexbar'), ['/opt/usagebar/codexbar', 'claude', 'add-account']);
    assert.equal(addHelperArgv('codexbar'), null);
    assert.equal(addHelperArgv(null), null);
});

test('install uses uv when it is there', () => {
    const argv = installArgv(finder({uv: '/home/u/.local/bin/uv', pipx: '/usr/bin/pipx'}));
    assert.deepEqual(argv, ['/home/u/.local/bin/uv', 'tool', 'install', 'claude-swap']);
    assert.equal(installerName(argv), 'uv');
    assert.match(installOfferText(argv), /`uv tool install claude-swap`/);
});

test('install falls back to pipx when uv is missing', () => {
    const argv = installArgv(finder({pipx: '/usr/bin/pipx'}));
    assert.deepEqual(argv, ['/usr/bin/pipx', 'install', 'claude-swap']);
    assert.equal(installerName(argv), 'pipx');
    assert.match(installOfferText(argv), /`pipx install claude-swap`/);
});

test('install ignores relative finds and offers instructions without an installer', () => {
    assert.deepEqual(installArgv(finder({uv: 'uv', pipx: '/usr/bin/pipx'})), ['/usr/bin/pipx', 'install', 'claude-swap']);
    const none = installArgv(finder({}));
    assert.equal(none, null);
    assert.equal(installerName(none), null);
    assert.match(installOfferText(none), /Install uv or pipx/);
    // Nothing to run: the button only closes the offer.
    assert.equal(installConfirmLabel(none), 'OK');
    assert.equal(installConfirmLabel(['/bin/uv', 'tool', 'install', 'claude-swap']), 'Install');
    assert.match(NO_INSTALLER_ERROR, /uv nor pipx/);
});

test('no argv this module builds logs out', () => {
    const argvs = [
        addHelperArgv('/opt/codexbar'),
        installArgv(finder({uv: '/bin/uv'})),
        installArgv(finder({pipx: '/bin/pipx'})),
    ];
    for (const argv of argvs)
        assert.ok(!argv.some(part => /logout/i.test(part)), argv.join(' '));
});
