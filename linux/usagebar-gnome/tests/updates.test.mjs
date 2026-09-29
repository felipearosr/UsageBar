import test from 'node:test';
import assert from 'node:assert/strict';

import {
    compareVersions,
    installCommand,
    latestUsageBarRelease,
    packageAssetName,
    withClaudeOAuth,
} from '../usagebar@felipearosr.github.io/updates.js';

test('compareVersions orders dotted versions numerically', () => {
    assert.ok(compareVersions('1.10.0', '1.9.3') > 0);
    assert.ok(compareVersions('1.0', '1.0.1') < 0);
    assert.equal(compareVersions('1.2.0', '1.2'), 0);
});

test('latestUsageBarRelease skips other tags, drafts and prereleases', () => {
    const release = (tag_name, extra = {}) => ({tag_name, assets: [], ...extra});
    const latest = latestUsageBarRelease([
        release('cli-fork-f05433b', {prerelease: true}),
        release('usagebar-v1.3.0', {draft: true}),
        release('usagebar-v1.2.0-rc1'),
        release('usagebar-v1.1.0'),
        release('usagebar-v1.10.0'),
        release('v0.70.0'),
        release('usagebar-v1.9.0'),
    ]);
    assert.equal(latest.version, '1.10.0');
    assert.equal(latest.release.tag_name, 'usagebar-v1.10.0');
    assert.equal(latestUsageBarRelease([release('v0.70.0')]), null);
    assert.equal(latestUsageBarRelease(null), null);
});

test('packageAssetName matches the names build-packages.sh produces', () => {
    assert.equal(packageAssetName('deb', '1.2.0', 'x86_64'), 'usagebar_1.2.0_amd64.deb');
    assert.equal(packageAssetName('deb', '1.2.0', 'aarch64'), 'usagebar_1.2.0_arm64.deb');
    assert.equal(packageAssetName('rpm', '1.2.0', 'x86_64'), 'usagebar-1.2.0-1.x86_64.rpm');
    assert.equal(packageAssetName('rpm', '1.2.0', 'riscv64'), null);
    assert.equal(packageAssetName('flatpak', '1.2.0', 'x86_64'), null);
});

test('installCommand goes through pkexec and the native package manager', () => {
    assert.deepEqual(installCommand('deb', '/c/u.deb'), ['pkexec', 'apt-get', 'install', '-y', '/c/u.deb']);
    assert.deepEqual(installCommand('rpm', '/c/u.rpm'), ['pkexec', 'dnf', 'install', '-y', '/c/u.rpm']);
    assert.equal(installCommand('pacman', '/c/u'), null);
});

test('withClaudeOAuth adds the OAuth source only to an enabled claude without one', () => {
    const config = {
        version: 1,
        providers: [
            {id: 'codex', enabled: true},
            {id: 'claude', enabled: true, apiKey: 'kept'},
        ],
    };
    const next = withClaudeOAuth(config);
    assert.deepEqual(next.providers[1], {id: 'claude', enabled: true, apiKey: 'kept', source: 'oauth'});
    assert.deepEqual(next.providers[0], {id: 'codex', enabled: true});
    assert.equal(next.version, 1);
    assert.equal(config.providers[1].source, undefined, 'input is not mutated');

    const explicit = {providers: [{id: 'claude', enabled: true, source: 'cli'}]};
    assert.equal(withClaudeOAuth(explicit), null);
    assert.equal(withClaudeOAuth({providers: [{id: 'claude', enabled: false}]}), null);
    assert.equal(withClaudeOAuth({providers: [{id: 'codex', enabled: true}]}), null);
    assert.equal(withClaudeOAuth({}), null);
});
