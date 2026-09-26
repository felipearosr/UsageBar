import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';

import {
    canCreate,
    cleartextHost,
    createArgs,
    createdText,
    forgetArgs,
    friendlyError,
    hourLabels,
    infoArgs,
    leaveArgs,
    otherMachines,
    pairArgs,
    pairedText,
    pairStdin,
    parseResult,
    pushText,
    redactPairingLinks,
    renameArgs,
    reportingDaySummary,
    serverSummary,
    settingsArgs,
    timeZoneChoices,
    tokenField,
} from '../usagebar@felipearosr.github.io/syncprefs.js';

const LINK = 'codexbar-sync://sync.example.com/base#AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8';
const HTTP_LINK = 'codexbar-sync+http://nas.lan:8080#AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8';
const EXT = new URL('../usagebar@felipearosr.github.io/', import.meta.url);

function cliError(reason, message) {
    return JSON.stringify([{provider: 'cli', source: 'cli', error: {code: 1, kind: 'runtime', message, reason}}]);
}

// ---------- token field (§6.2) ----------

test('token field appears only when /info says optional or required', () => {
    assert.deepEqual(tokenField({enrollment: 'required'}), {visible: true, required: true});
    assert.deepEqual(tokenField({enrollment: 'optional'}), {visible: true, required: false});
    assert.deepEqual(tokenField({enrollment: 'none'}), {visible: false, required: false});
    // Before the server answered, or for an unknown value: hidden.
    assert.deepEqual(tokenField(null), {visible: false, required: false});
    assert.deepEqual(tokenField({enrollment: 'maybe'}), {visible: false, required: false});
});

test('create waits for a supported server and a token when one is required', () => {
    const required = {supported: true, enrollment: 'required'};
    assert.equal(canCreate({info: null}), false);
    assert.equal(canCreate({info: {supported: false, enrollment: 'none'}}), false);
    assert.equal(canCreate({info: required}), false);
    assert.equal(canCreate({info: required, token: '   '}), false);
    assert.equal(canCreate({info: required, token: 'tok'}), true);
    assert.equal(canCreate({info: {supported: true, enrollment: 'optional'}}), true);
    assert.equal(canCreate({info: {supported: true, enrollment: 'none'}}), true);
});

test('server summary shows the operator as-is and what enrollment needs', () => {
    assert.equal(serverSummary({supported: true, enrollment: 'required', operator: 'Example Sync',
        retentionDays: 400}), 'Example Sync · Enrollment Token required · keeps 400 days');
    assert.equal(serverSummary({supported: true, enrollment: 'none'}), 'No Enrollment Token needed');
    assert.match(serverSummary({supported: false, enrollment: 'none'}), /protocol v1/);
    assert.equal(serverSummary(null), '');
});

// ---------- ADR 0002: no server named, suggested, or preselected ----------

test('the Machine Sync page names, suggests, and preselects no server', () => {
    const page = readFileSync(new URL('syncpage.js', EXT), 'utf8');
    const prefs = readFileSync(new URL('syncprefs.js', EXT), 'utf8');
    for (const source of [page, prefs]) {
        // No hard-coded host of any kind, not even as a placeholder.
        assert.doesNotMatch(source, /https?:\/\/[a-z0-9]/i);
        assert.doesNotMatch(source, /placeholder/i);
    }
    // The server field starts empty and is never filled in by the page.
    assert.doesNotMatch(page, /serverRow\.text\s*=/);
    assert.doesNotMatch(page, /Sync Server URL'[^)]*text:/);
});

// ---------- invocations ----------

test('create passes the token only when given and asks for --yes only when confirmed', () => {
    assert.deepEqual(createArgs({server: ' https://s.test ', token: '', name: ''}),
        ['sync', 'create', '--server', 'https://s.test', '--json-only']);
    assert.deepEqual(createArgs({server: 'http://nas', token: ' t ', name: ' desk ', allowCleartext: true}),
        ['sync', 'create', '--server', 'http://nas', '--token', 't', '--name', 'desk', '--yes', '--json-only']);
    assert.deepEqual(infoArgs(' https://s.test '), ['sync', 'info', '--server', 'https://s.test', '--json-only']);
});

test('the Pairing Link goes on stdin, never in argv', () => {
    const args = pairArgs({name: 'desk'});
    assert.deepEqual(args, ['sync', 'pair', '-', '--name', 'desk', '--json-only']);
    assert.ok(!args.join(' ').includes('codexbar-sync'));
    assert.deepEqual(pairArgs({allowCleartext: true}), ['sync', 'pair', '-', '--yes', '--json-only']);
    assert.equal(pairStdin(`  ${LINK}\n`), `${LINK}\n`);
});

test('destructive actions carry --yes because the page asked first', () => {
    assert.deepEqual(forgetArgs('AAAAAAAAAAAAAAAAAAAAAA'),
        ['sync', 'forget', 'AAAAAAAAAAAAAAAAAAAAAA', '--yes', '--json-only']);
    assert.deepEqual(leaveArgs(), ['sync', 'leave', '--yes', '--json-only']);
    assert.deepEqual(renameArgs(' my laptop '), ['sync', 'rename', 'my laptop', '--json-only']);
});

test('reporting day flags: system timezone and hour', () => {
    assert.deepEqual(settingsArgs(), ['sync', 'settings', '--json-only']);
    assert.deepEqual(settingsArgs({timeZone: 'Europe/Berlin', startHour: 4}),
        ['sync', 'settings', '--timezone', 'Europe/Berlin', '--day-start', '4', '--json-only']);
    assert.deepEqual(settingsArgs({timeZone: null, startHour: 0}),
        ['sync', 'settings', '--timezone', 'system', '--day-start', '0', '--json-only']);
});

test('cleartext host comes from http links only', () => {
    assert.equal(cleartextHost(HTTP_LINK), 'nas.lan');
    assert.equal(cleartextHost('codexbar-sync+http://[fd00::1]:80#k'), '[fd00::1]');
    assert.equal(cleartextHost(LINK), null);
    assert.equal(cleartextHost('garbage'), null);
});

// ---------- answers ----------

test('parses success and error JSON from the CLI', () => {
    assert.deepEqual(parseResult({success: true, stdout: '{"paired":false}\n'}),
        {ok: true, data: {paired: false}});
    assert.deepEqual(
        parseResult({success: false, stdout: cliError('machine_limit', 'This Sync Group has reached its Machine limit.')}),
        {ok: false, reason: 'machine_limit', message: 'This Sync Group has reached its Machine limit.'});
    // Exit status wins even if stdout looks fine; garbage is an error without a reason.
    assert.equal(parseResult({success: false, stdout: '{"paired":true}'}).ok, false);
    assert.deepEqual(parseResult({success: true, stdout: 'not json'}), {ok: false, reason: null, message: ''});
    // An error array with exit 0 is still an error.
    assert.equal(parseResult({success: true, stdout: cliError('network', 'x')}).ok, false);
});

test('enrollment, expiry, and Machine-cap errors read as plain language', () => {
    for (const reason of ['enrollment_required', 'enrollment_invalid', 'enrollment_used',
        'enrollment_expired', 'machine_limit']) {
        const text = friendlyError({reason, message: 'Pass it with --token.'});
        assert.doesNotMatch(text, /--|codexbar |HTTP \d/, reason);
        assert.ok(text.length > 20, reason);
    }
    assert.match(friendlyError({reason: 'enrollment_expired'}), /expired/);
    assert.match(friendlyError({reason: 'machine_limit'}), /Forget/);
    assert.match(friendlyError({reason: 'http_503'}), /Sync Server had a problem/);
    // Unknown reasons fall back to the CLI's sentence, then to a generic one.
    assert.equal(friendlyError({reason: 'something_new', message: 'Server says no.'}), 'Server says no.');
    assert.equal(friendlyError({}), 'Something went wrong. Try again.');
});

// ---------- the Pairing Link never leaks ----------

test('Pairing Links are redacted from every error and status text', () => {
    assert.equal(redactPairingLinks(`bad link ${LINK} here`), 'bad link [Pairing Link] here');
    assert.equal(redactPairingLinks(HTTP_LINK.toUpperCase()), '[Pairing Link]');
    const parsed = parseResult({success: false, stdout: cliError(null, `could not use ${LINK}`)});
    assert.ok(!parsed.message.includes('#AAEC'));
    assert.ok(!friendlyError({message: `oops ${LINK}`}).includes('codexbar-sync'));
    assert.ok(!createdText({server: 'https://s.test', pushError: `x ${LINK}`}).includes('codexbar-sync'));
    assert.ok(!pairedText({pushError: `x ${LINK}`}).includes('codexbar-sync'));
});

test('Machine Sync prefs code never logs', () => {
    for (const file of ['syncpage.js', 'syncprefs.js']) {
        const source = readFileSync(new URL(file, EXT), 'utf8');
        assert.doesNotMatch(source, /\b(console\.\w+|log|logError|print|printerr)\s*\(/, file);
    }
});

// ---------- results ----------

test('result texts', () => {
    assert.equal(createdText({server: 'https://s.test'}), 'Created a Sync Group on https://s.test.');
    assert.match(createdText({server: 'https://s.test', pushError: 'x', pushErrorReason: 'machine_limit'}),
        /retried: This Sync Group already has as many Machines/);
    assert.equal(pairedText({backfilledDays: 1}), 'Joined. Backfilled 1 day of Spend.');
    assert.equal(pairedText({backfilledDays: 12}), 'Joined. Backfilled 12 days of Spend.');
    assert.match(pairedText({pushError: 'x', pushErrorReason: 'enrollment_expired'}), /expired/);
    assert.equal(pushText({status: 'pushed', uploaded: ['profile']}), 'Synced.');
    assert.equal(pushText({status: 'pushed', uploaded: []}), 'Up to date.');
    assert.equal(pushText({status: 'locked'}), 'A push is already running.');
    assert.match(pushText({status: 'backing_off'}), /Waiting/);
});

// ---------- Reporting Day ----------

test('hour labels and timezone choices', () => {
    const hours = hourLabels();
    assert.equal(hours.length, 24);
    assert.equal(hours[0], '00:00');
    assert.equal(hours[23], '23:00');

    const tab = '# comment\nDE\t+5230+01322\tEurope/Berlin\tmost of Germany\n' +
        'US\t+404251-0740023\tAmerica/New_York\n\n';
    assert.deepEqual(timeZoneChoices(tab), ['America/New_York', 'Europe/Berlin', 'UTC']);
    assert.deepEqual(timeZoneChoices('', 'Etc/GMT+3'), ['Etc/GMT+3', 'UTC']);
    assert.equal(reportingDaySummary({timeZone: 'Europe/Berlin', startHour: 4, effectiveTimeZone: 'Europe/Berlin'}),
        'Days start at 04:00, Europe/Berlin');
    assert.equal(reportingDaySummary({timeZone: null, startHour: 0, effectiveTimeZone: 'America/Santiago'}),
        'Days start at 00:00, system timezone (America/Santiago)');
});

// ---------- other Machines ----------

test('other Machines leave out this one and keep retired state', () => {
    const rows = otherMachines({machines: [
        {machineId: 'me', displayName: 'laptop', isThisMachine: true, active: true, retired: false},
        {machineId: 'B', displayName: 'workstation', isThisMachine: false, active: false, retired: true},
        {machineId: 'A', displayName: '', isThisMachine: false, active: true, retired: false},
    ]});
    assert.deepEqual(rows, [
        {machineId: 'A', label: 'A', retired: false, active: true},
        {machineId: 'B', label: 'workstation', retired: true, active: false},
    ]);
    assert.deepEqual(otherMachines(null), []);
});
