import test from 'node:test';
import assert from 'node:assert/strict';

import {
    compareVersions,
    featureState,
    FEATURES,
    isUnknownCommand,
    meetsMinimum,
    needsCliNote,
    parseVersion,
    readReport,
    supportSummary,
    syncProbeFromHttpStatus,
} from '../usagebar@felipearosr.github.io/clicompat.js';
import {INSTALL_URL} from '../usagebar@felipearosr.github.io/onboarding.js';

// ---------- versions ----------

test('parseVersion reads plain, pre-release and build versions', () => {
    assert.deepEqual(parseVersion('0.69.0'), {core: [0, 69, 0], pre: [], build: null});
    assert.deepEqual(parseVersion('CodexBar 0.68.0-fork.f05433b'),
        {core: [0, 68, 0], pre: ['fork', 'f05433b'], build: null});
    assert.deepEqual(parseVersion('v0.69.0+usagebar.1.1.0'),
        {core: [0, 69, 0], pre: [], build: 'usagebar.1.1.0'});
    assert.deepEqual(parseVersion('1.2'), {core: [1, 2, 0], pre: [], build: null});
    assert.equal(parseVersion('no version here'), null);
    assert.equal(parseVersion(null), null);
});

test('compareVersions follows semver precedence and ignores build metadata', () => {
    assert.equal(compareVersions('0.69.0', '0.68.9'), 1);
    assert.equal(compareVersions('0.68.0', '0.69.0'), -1);
    assert.equal(compareVersions('0.69.0+usagebar.1.1.0', '0.69.0'), 0);
    assert.equal(compareVersions('0.68.0-fork.f05433b', '0.68.0'), -1);
    assert.equal(compareVersions('1.0.0-rc.2', '1.0.0-rc.10'), -1);
    assert.equal(compareVersions('1.0.0-alpha', '1.0.0-alpha.1'), -1);
    assert.equal(compareVersions('1.0.0-1', '1.0.0-alpha'), -1);
    assert.equal(compareVersions('garbage', '0.1.0'), -1);
});

test('meetsMinimum compares against a minimum version', () => {
    assert.equal(meetsMinimum('0.69.0+usagebar.1.1.0', FEATURES.machineSync.minVersion), true);
    assert.equal(meetsMinimum('0.68.0-fork.f05433b', '0.69.0'), false);
    assert.equal(meetsMinimum(null, '0.69.0'), false);
});

// ---------- capability report ----------

test('no report means no capability report at all', () => {
    assert.equal(readReport(null), null);
    assert.equal(readReport({status: 'ok', version: '0.69.0'}), null);
    assert.equal(readReport({capabilities: 'machineSync'}), null);
});

test('readReport keeps known capabilities and ignores unknown ones', () => {
    const report = readReport({
        status: 'ok',
        capabilities: ['machineSync', 'teleport', 42],
        usagebarVersion: '0.69.0+usagebar.1.1.0',
        upstreamVersion: '0.69.0',
    });
    assert.deepEqual([...report.capabilities], ['machineSync']);
    assert.equal(report.version, '0.69.0+usagebar.1.1.0');
    assert.equal(report.upstream, '0.69.0');
    assert.deepEqual([...readReport({capabilities: ['teleport']}).capabilities], []);
});

// ---------- probes and feature state ----------

test('serve answering 404 on /sync/status means no Machine Sync', () => {
    assert.equal(syncProbeFromHttpStatus(200), true);
    assert.equal(syncProbeFromHttpStatus(404), false);
    for (const status of [undefined, 0, 401, 500, 503])
        assert.equal(syncProbeFromHttpStatus(status), null);
});

test('isUnknownCommand recognises the CLI parser error', () => {
    assert.equal(isUnknownCommand("Unknown command 'sync'"), true);
    assert.equal(isUnknownCommand('Unknown command'), true);
    assert.equal(isUnknownCommand('Couldn’t reach the Sync Server'), false);
    assert.equal(isUnknownCommand(undefined), false);
});

test('featureState: a report decides, unknown capabilities change nothing', () => {
    const withSync = readReport({capabilities: ['machineSync', 'teleport']});
    const without = readReport({capabilities: ['teleport']});
    assert.deepEqual(featureState('machineSync', {report: withSync}),
        {state: 'available', minVersion: '0.69.0'});
    assert.deepEqual(featureState('machineSync', {report: without}),
        {state: 'needs-upgrade', minVersion: '0.69.0'});
    // The report wins over a contradicting probe.
    assert.equal(featureState('machineSync', {report: without, probe: true}).state, 'needs-upgrade');
});

test('featureState without a report falls back to the probe', () => {
    assert.equal(featureState('machineSync').state, 'unknown');
    assert.equal(featureState('machineSync', {probe: null}).state, 'unknown');
    assert.equal(featureState('machineSync', {probe: true}).state, 'available');
    assert.equal(featureState('machineSync', {probe: false}).state, 'needs-upgrade');
    assert.equal(featureState('teleport', {probe: true}).state, 'needs-upgrade');
});

// ---------- plain language ----------

test('needsCliNote names the feature, the minimum version and the install page', () => {
    const note = needsCliNote('machineSync');
    assert.equal(note.title, 'Machine Sync needs the UsageBar CLI');
    assert.match(note.body, /0\.69\.0 or newer/);
    assert.doesNotMatch(note.body, /Unknown command/i);
    assert.equal(note.url, INSTALL_URL);
    assert.equal(note.button, 'Install instructions');
});

test('supportSummary says which features the CLI lacks', () => {
    assert.equal(supportSummary({machineSync: {state: 'available'}}), 'supports every UsageBar feature');
    assert.equal(supportSummary({machineSync: {state: 'needs-upgrade'}}),
        'no Machine Sync (needs the UsageBar CLI)');
    assert.equal(supportSummary({machineSync: {state: 'unknown'}}), 'checking features…');
});
