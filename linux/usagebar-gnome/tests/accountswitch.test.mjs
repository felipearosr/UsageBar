import assert from 'node:assert/strict';
import test from 'node:test';

import {
    PHASE_REFRESHING,
    PHASE_STILL,
    PHASE_SWITCHING,
    PHASE_TEXT,
    claudeSwapConfigKey,
    idleSwitch,
    isBusy,
    isSwitchableId,
    rowSwitchView,
    startSwitch,
    switchAnswered,
    switchRefreshed,
    switchRenderKey,
    switchConfigChanged,
    switchRequest,
    switchTimedOut,
} from '../usagebar@felipearosr.github.io/accountswitch.js';
import {buildCards} from '../usagebar@felipearosr.github.io/accounts.js';
import {readReport} from '../usagebar@felipearosr.github.io/clicompat.js';

const WITH_SWITCH = readReport({capabilities: ['providerAccountRows', 'providerAccountSwitch']}).capabilities;
const WITHOUT_SWITCH = readReport({capabilities: ['providerAccountRows']}).capabilities;

// Serve's claude-swap rows: slot 2 active, slot 1 switchable, slot 3 with an
// expired token (no canSwitch), and a stale copy after a failed read.
function rows() {
    const row = (slot, extra) => ({
        provider: 'claude', source: 'claude-swap', accountId: `claude-swap:${slot}`,
        accountSource: 'claude-swap', accountLabel: `slot${slot}@example.com`, active: false, ...extra,
    });
    return [
        row(2, {active: true}),
        row(1, {canSwitch: true}),
        row(3, {error: {message: 'Token expired.'}}),
        row(4, {canSwitch: true, disabled: true}),
    ];
}

function card() {
    return buildCards(rows(), {accountRows: true}).find(c => c.provider === 'claude');
}

const byId = (c, id) => c.accounts.find(account => account.id === id);

test('only inactive rows serve marked canSwitch offer Switch', () => {
    const c = card();
    const view = id => rowSwitchView(byId(c, id), {provider: 'claude', state: idleSwitch(), capabilities: WITH_SWITCH});
    assert.deepEqual(view('claude-swap:1'), {button: true, enabled: true, progress: null, error: null});
    // Active, and an expired credential: no button.
    assert.equal(view('claude-swap:2').button, false);
    assert.equal(view('claude-swap:3').button, false);
    // claude-swap's disabled slots stay explicit targets.
    assert.equal(view('claude-swap:4').button, true);
});

test('no Switch without the capability, a provider, or a claude-swap id', () => {
    const c = card();
    const account = byId(c, 'claude-swap:1');
    assert.equal(rowSwitchView(account, {provider: 'claude', capabilities: WITHOUT_SWITCH}).button, false);
    assert.equal(rowSwitchView(account, {provider: 'claude', capabilities: null}).button, false);
    assert.equal(rowSwitchView(account, {capabilities: WITH_SWITCH}).button, false);
    const token = {...account, id: 'token:1', row: {...account.row, accountId: 'token:1'}};
    assert.equal(rowSwitchView(token, {provider: 'claude', capabilities: WITH_SWITCH}).button, false);
    // An active row never offers it, even if serve said canSwitch.
    const active = {...account, active: true};
    assert.equal(rowSwitchView(active, {provider: 'claude', capabilities: WITH_SWITCH}).button, false);
});

test('slot ids are only claude-swap:<positive number>', () => {
    assert.equal(isSwitchableId('claude-swap:12'), true);
    for (const id of ['claude-swap:0', 'claude-swap:01', 'claude-swap:1 --purge', 'claude-swap:', 'token:1', null, 3])
        assert.equal(isSwitchableId(id), false, String(id));
});

test('a switch goes switching, then refreshing, then idle', () => {
    let state = idleSwitch();
    assert.equal(isBusy(state), false);
    state = startSwitch(state, {provider: 'claude', accountId: 'claude-swap:1'});
    assert.equal(state.phase, PHASE_SWITCHING);
    const seq = state.seq;
    const c = card();
    const target = () => rowSwitchView(byId(c, 'claude-swap:1'),
        {provider: 'claude', state, capabilities: WITH_SWITCH});
    const other = () => rowSwitchView(byId(c, 'claude-swap:4'),
        {provider: 'claude', state, capabilities: WITH_SWITCH});
    assert.deepEqual(target(), {button: true, enabled: false, progress: 'Switching account…', error: null});
    // Every Switch on the card waits; the other row shows no progress.
    assert.deepEqual(other(), {button: true, enabled: false, progress: null, error: null});
    // A second switch while one is out is refused.
    assert.equal(startSwitch(state, {provider: 'claude', accountId: 'claude-swap:4'}), null);

    state = switchAnswered(state, seq);
    assert.equal(state.phase, PHASE_REFRESHING);
    assert.equal(target().progress, 'Refreshing account status…');
    assert.equal(target().enabled, false);

    state = switchRefreshed(state, seq);
    assert.equal(isBusy(state), false);
    assert.deepEqual(target(), {button: true, enabled: true, progress: null, error: null});
    assert.deepEqual(PHASE_TEXT, {[PHASE_SWITCHING]: 'Switching account…',
        [PHASE_REFRESHING]: 'Refreshing account status…', [PHASE_STILL]: 'Still switching…'});
});

test('a timed-out POST shows Still switching… with Switch disabled until a reload', () => {
    let state = startSwitch(idleSwitch(), {provider: 'claude', accountId: 'claude-swap:1'});
    const seq = state.seq;
    state = switchTimedOut(state, seq);
    assert.equal(state.phase, PHASE_STILL);
    assert.equal(isBusy(state), true);
    const c = card();
    const view = id => rowSwitchView(byId(c, id), {provider: 'claude', state, capabilities: WITH_SWITCH});
    assert.deepEqual(view('claude-swap:1'), {button: true, enabled: false, progress: 'Still switching…', error: null});
    assert.equal(view('claude-swap:4').enabled, false);
    assert.equal(startSwitch(state, {provider: 'claude', accountId: 'claude-swap:4'}), null);
    // A late answer to the timed-out POST changes nothing; the reload ends it.
    assert.equal(switchAnswered(state, seq, {error: 'late'}), state);
    state = switchRefreshed(state, seq);
    assert.equal(isBusy(state), false);
    assert.equal(view('claude-swap:1').error, null);
    // Only a switch that is still waiting for its answer can time out.
    assert.equal(switchTimedOut(state, seq), state);
});

test('claude-swap\'s configuration key reads only its enabled flag and executable', () => {
    const config = path => ({providers: [{id: 'codex', enabled: true},
        {id: 'claude', enabled: true, claudeSwapEnabled: true, claudeSwapExecutablePath: path, apiKey: 'x'}]});
    assert.equal(claudeSwapConfigKey(config('/usr/bin/cswap')), JSON.stringify([true, '/usr/bin/cswap']));
    assert.notEqual(claudeSwapConfigKey(config('/usr/bin/cswap')), claudeSwapConfigKey(config('/opt/cswap')));
    assert.equal(claudeSwapConfigKey({providers: [{id: 'claude'}]}), JSON.stringify([false, '']));
    assert.equal(claudeSwapConfigKey(null), null);
    assert.equal(claudeSwapConfigKey({providers: 'x'}), null);
});

test('a configuration change clears the switch, and turning claude-swap back on never revives it', () => {
    const on = JSON.stringify([true, '/usr/bin/cswap']);
    const off = JSON.stringify([false, '/usr/bin/cswap']);
    let state = startSwitch(idleSwitch(), {provider: 'claude', accountId: 'claude-swap:1', config: on});
    const seq = state.seq;
    // Nothing changed that matters: the switch goes on.
    assert.equal(switchConfigChanged(state, on), state);
    state = switchConfigChanged(state, off);
    assert.equal(isBusy(state), false);
    assert.equal(state.error, null);
    // The old switch's answer and reload no longer apply.
    assert.equal(switchAnswered(state, seq, {error: 'Account switch failed: x'}), state);
    assert.equal(switchRefreshed(state, seq), state);
    state = switchConfigChanged(state, on);
    assert.equal(isBusy(state), false);
    assert.equal(state.error, null);
    const view = rowSwitchView(byId(card(), 'claude-swap:1'), {provider: 'claude', state, capabilities: WITH_SWITCH});
    assert.deepEqual(view, {button: true, enabled: true, progress: null, error: null});

    // A switch error shown after the switch ended goes too.
    let failed = startSwitch(idleSwitch(), {provider: 'claude', accountId: 'claude-swap:1', config: on});
    failed = switchRefreshed(switchAnswered(failed, failed.seq, {error: 'Account switch failed: x'}), failed.seq);
    assert.equal(failed.error, 'Account switch failed: x');
    assert.equal(switchConfigChanged(failed, off).error, null);
    assert.equal(switchConfigChanged(switchConfigChanged(failed, off), on).error, null);
    // A new switch starts from the configuration it sees.
    const next = startSwitch(switchConfigChanged(failed, off), {provider: 'claude', accountId: 'claude-swap:4', config: off});
    assert.equal(next.seq, failed.seq + 1);
});

test('the new active account comes from the reloaded rows, not the switch', () => {
    let state = startSwitch(idleSwitch(), {provider: 'claude', accountId: 'claude-swap:1'});
    state = switchRefreshed(switchAnswered(state, state.seq), state.seq);
    // The reload says slot 1 is active now.
    const reloaded = rows().map(row => ({...row, active: row.accountId === 'claude-swap:1',
        canSwitch: row.accountId === 'claude-swap:2' || row.accountId === 'claude-swap:4'}));
    const c = buildCards(reloaded, {accountRows: true}).find(x => x.provider === 'claude');
    assert.equal(byId(c, 'claude-swap:1').active, true);
    assert.equal(rowSwitchView(byId(c, 'claude-swap:1'), {provider: 'claude', state, capabilities: WITH_SWITCH})
        .button, false);
    assert.equal(rowSwitchView(byId(c, 'claude-swap:2'), {provider: 'claude', state, capabilities: WITH_SWITCH})
        .button, true);
});

test('a switch error stays on its row through the reload and goes with the next switch', () => {
    let state = startSwitch(idleSwitch(), {provider: 'claude', accountId: 'claude-swap:1'});
    const seq = state.seq;
    state = switchAnswered(state, seq, {error: 'Account switch failed: claude-swap reported slot 3.'});
    const c = card();
    const view = (id, extra = {}) => rowSwitchView(byId(c, id),
        {provider: 'claude', state, capabilities: WITH_SWITCH, ...extra});
    assert.equal(view('claude-swap:1').progress, 'Refreshing account status…');
    assert.equal(view('claude-swap:1').error, 'Account switch failed: claude-swap reported slot 3.');
    assert.equal(view('claude-swap:4').error, null);
    state = switchRefreshed(state, seq);
    assert.equal(view('claude-swap:1').error, 'Account switch failed: claude-swap reported slot 3.');
    assert.equal(view('claude-swap:1').progress, null);
    state = startSwitch(state, {provider: 'claude', accountId: 'claude-swap:4'});
    assert.equal(view('claude-swap:1').error, null);
});

test('Hide Personal Info redacts emails in a switch error', () => {
    let state = startSwitch(idleSwitch(), {provider: 'claude', accountId: 'claude-swap:1'});
    state = switchAnswered(state, state.seq, {error: 'Account switch failed: slot1@example.com is locked'});
    const account = byId(card(), 'claude-swap:1');
    const view = hidePersonalInfo => rowSwitchView(account,
        {provider: 'claude', state, capabilities: WITH_SWITCH, hidePersonalInfo});
    assert.equal(view(true).error, 'Account switch failed: [email] is locked');
    assert.equal(view(false).error, 'Account switch failed: slot1@example.com is locked');
});

test('answers from an older switch are ignored', () => {
    let state = startSwitch(idleSwitch(), {provider: 'claude', accountId: 'claude-swap:1'});
    const first = state.seq;
    state = switchRefreshed(switchAnswered(state, first), first);
    state = startSwitch(state, {provider: 'claude', accountId: 'claude-swap:4'});
    assert.equal(switchAnswered(state, first, {error: 'late'}), state);
    assert.equal(switchRefreshed(state, first), state);
    // Out of order within one switch: a refresh before the answer does nothing.
    assert.equal(switchRefreshed(state, state.seq), state);
});

test('the request names the provider and the row\'s account id', () => {
    assert.deepEqual(switchRequest({provider: 'claude', accountId: 'claude-swap:1'}),
        {method: 'POST', path: '/accounts/switch', body: {provider: 'claude', accountId: 'claude-swap:1'}});
    assert.equal(startSwitch(idleSwitch(), {provider: 'claude', accountId: 'claude-swap:x'}), null);
    assert.equal(startSwitch(idleSwitch(), {provider: null, accountId: 'claude-swap:1'}), null);
});

test('the render key changes with the phase, the error and the buttons', () => {
    const c = card();
    const idle = switchRenderKey(c, {state: idleSwitch(), capabilities: WITH_SWITCH});
    const started = startSwitch(idleSwitch(), {provider: 'claude', accountId: 'claude-swap:1'});
    const switching = switchRenderKey(c, {state: started, capabilities: WITH_SWITCH});
    const refreshing = switchRenderKey(c, {state: switchAnswered(started, started.seq), capabilities: WITH_SWITCH});
    assert.notEqual(idle, switching);
    assert.notEqual(switching, refreshing);
    assert.notEqual(idle, switchRenderKey(c, {state: idleSwitch(), capabilities: WITHOUT_SWITCH}));
    assert.equal(switchRenderKey(null), '');
});
