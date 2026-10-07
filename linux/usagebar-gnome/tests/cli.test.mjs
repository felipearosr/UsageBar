import test from 'node:test';
import assert from 'node:assert/strict';

import {
    findCodexbar,
    PACKAGED_BIN,
    parseCliVersion,
    withClaudeOAuth,
} from '../usagebar@felipearosr.github.io/cli.js';

function lookupEnv({vars = {}, executables = [], path = {}} = {}) {
    return {
        getenv: name => vars[name] ?? null,
        isExecutable: file => executables.includes(file),
        findInPath: name => path[name] ?? null,
        home: '/home/u',
    };
}

test('findCodexbar prefers $CODEXBAR_BIN, then the packaged CLI, then PATH', () => {
    const all = lookupEnv({
        vars: {CODEXBAR_BIN: '/opt/cb'},
        executables: ['/opt/cb', PACKAGED_BIN, '/home/u/.local/bin/codexbar'],
        path: {codexbar: '/usr/bin/codexbar'},
    });
    assert.equal(findCodexbar(all), '/opt/cb');
    assert.equal(findCodexbar({...all, getenv: () => null}), PACKAGED_BIN);
    assert.equal(findCodexbar(lookupEnv({
        vars: {CODEXBAR_BIN: '/missing'},
        path: {codexbar: '/usr/bin/codexbar'},
    })), '/usr/bin/codexbar');
});

test('findCodexbar falls back when $CODEXBAR_BIN is set but unusable', () => {
    const env = lookupEnv({
        vars: {CODEXBAR_BIN: '/opt/not-executable'},
        executables: [PACKAGED_BIN, '/usr/local/bin/codexbar'],
        path: {codexbar: '/usr/bin/codexbar'},
    });
    assert.equal(findCodexbar(env), PACKAGED_BIN);
    assert.equal(findCodexbar({...env, isExecutable: file => file === '/usr/local/bin/codexbar',
        findInPath: () => null}), '/usr/local/bin/codexbar');
    assert.equal(findCodexbar(lookupEnv({vars: {CODEXBAR_BIN: ''},
        executables: ['/home/linuxbrew/.linuxbrew/bin/codexbar']})),
    '/home/linuxbrew/.linuxbrew/bin/codexbar');
});

test('findCodexbar finds a manual ~/.local/bin install off PATH', () => {
    assert.equal(findCodexbar(lookupEnv({executables: ['/home/u/.local/bin/codexbar']})),
        '/home/u/.local/bin/codexbar');
    assert.equal(findCodexbar(lookupEnv({executables: ['/usr/local/bin/codexbar']})),
        '/usr/local/bin/codexbar');
    assert.equal(findCodexbar(lookupEnv()), null);
});

test('parseCliVersion reads the number from `codexbar --version`', () => {
    assert.equal(parseCliVersion('CodexBar 0.69.0\n'), '0.69.0');
    assert.equal(parseCliVersion('\nCodexBar 1.2.3-fork.4\n'), '1.2.3-fork.4');
    assert.equal(parseCliVersion('dev build'), 'dev build');
    assert.equal(parseCliVersion(''), null);
    assert.equal(parseCliVersion(null), null);
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
