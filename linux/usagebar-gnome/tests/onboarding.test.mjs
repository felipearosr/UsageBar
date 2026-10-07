import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';

import {INSTALL_URL, MISSING_CLI} from '../usagebar@felipearosr.github.io/onboarding.js';

const extensionDir = new URL('../usagebar@felipearosr.github.io/', import.meta.url);
const installPage = new URL('../../INSTALL.md', import.meta.url);

test('the install URL is INSTALL.md on main, at its stable heading', () => {
    assert.equal(INSTALL_URL,
        'https://github.com/felipearosr/UsageBar/blob/main/linux/INSTALL.md#install-usagebar');
    // GitHub derives #install-usagebar from this heading; renaming it breaks
    // the link in every installed extension.
    const page = fs.readFileSync(installPage, 'utf8');
    assert.match(page, /^# Install UsageBar$/m);
});

test('the empty state says what is missing and offers the install page', () => {
    assert.equal(MISSING_CLI.title, 'UsageBar needs its command-line helper');
    assert.equal(MISSING_CLI.button, 'Install instructions');
    assert.match(MISSING_CLI.body, /codexbar/);
});

test('no extension text sends users to upstream releases for the CLI', () => {
    for (const name of fs.readdirSync(extensionDir).filter(file => file.endsWith('.js'))) {
        const source = fs.readFileSync(new URL(name, extensionDir), 'utf8');
        assert.doesNotMatch(source, /steipete\/CodexBar\/releases/i, name);
        assert.doesNotMatch(source, /brew install steipete/i, name);
    }
});
