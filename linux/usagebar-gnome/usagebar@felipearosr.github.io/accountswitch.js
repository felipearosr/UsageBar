// Switching the active Claude account (#171): which account rows offer
// Switch, the serve request behind it, and the progress a switch shows on
// its row. Dependency-free so the Node tests can exercise it without GJS.
//
// Serve advertises the action on /health (providerAccountSwitch) and marks
// each row it can target with `canSwitch: true`: an inactive claude-swap
// slot whose credential claude-swap can activate. Expired, missing and
// unknown credentials never carry it, so they never offer Switch.
//
// One switch at a time, through three phases:
//   switching    POST /accounts/switch is out: "Switching account…"
//   refreshing   serve answered; the extension reloads the accounts:
//                "Refreshing account status…"
//   still        the POST timed out on the extension's side while serve
//                keeps switching (it never cancels one): "Still switching…"
//                until a later reload
//   idle         the reload landed. The card's active account is whatever
//                that reload says; a switch error stays on the row it was
//                for until the next switch.
// The requested row keeps its progress, and every Switch on the card stays
// disabled, through every phase.
//
// A switch remembers claude-swap's configuration (enabled and executable)
// from when it started. When that configuration changes, its progress and
// error go away and its late answers are ignored, so turning claude-swap
// off and on again never brings an old error back.

import {redactEmails} from './accountlabels.js';

export const SWITCH_CAPABILITY = 'providerAccountSwitch';
export const SWITCH_PATH = '/accounts/switch';

export const PHASE_SWITCHING = 'switching';
export const PHASE_REFRESHING = 'refreshing';
export const PHASE_STILL = 'still';

export const PHASE_TEXT = {
    [PHASE_SWITCHING]: 'Switching account…',
    [PHASE_REFRESHING]: 'Refreshing account status…',
    [PHASE_STILL]: 'Still switching…',
};

function has(capabilities, name) {
    return !!capabilities && typeof capabilities.has === 'function' && capabilities.has(name);
}

// Only claude-swap slots can be switched to here.
export function isSwitchableId(id) {
    return typeof id === 'string' && /^claude-swap:[1-9][0-9]*$/.test(id);
}

// No switch out, nothing to show.
export function idleSwitch() {
    return {seq: 0, provider: null, accountId: null, phase: null, error: null, config: null};
}

export function isBusy(state) {
    return state?.phase === PHASE_SWITCHING || state?.phase === PHASE_REFRESHING || state?.phase === PHASE_STILL;
}

// claude-swap's configuration as one comparable string: the Claude entry's
// `claudeSwapEnabled` and `claudeSwapExecutablePath` in the CLI's
// config.json (parsed), or null when there is none.
export function claudeSwapConfigKey(config) {
    const providers = Array.isArray(config?.providers) ? config.providers : [];
    const claude = providers.find(entry => entry?.id === 'claude');
    if (!claude)
        return null;
    const path = typeof claude.claudeSwapExecutablePath === 'string' ? claude.claudeSwapExecutablePath.trim() : '';
    return JSON.stringify([claude.claudeSwapEnabled === true, path]);
}

// Starts a switch to `accountId`, or null while another one is out. `seq`
// tells this switch's answers from a later one's; `config` is
// claudeSwapConfigKey at the start.
export function startSwitch(state, {provider, accountId, config = null}) {
    if (isBusy(state) || !provider || !isSwitchableId(accountId))
        return null;
    return {seq: (state?.seq ?? 0) + 1, provider, accountId, phase: PHASE_SWITCHING, error: null, config};
}

// claude-swap's configuration is now `config`. A switch that started under
// another one loses its progress and error; its answers no longer apply.
export function switchConfigChanged(state, config) {
    if (!state || (!isBusy(state) && !state.error) || state.config === config)
        return state;
    return {...idleSwitch(), seq: state.seq, config};
}

// The POST timed out here; serve still runs the switch.
export function switchTimedOut(state, seq) {
    if (!state || state.seq !== seq || state.phase !== PHASE_SWITCHING)
        return state;
    return {...state, phase: PHASE_STILL};
}

// Serve answered the POST. Either way the accounts are reloaded next, since
// even a failed switch may have changed Claude Code's account; a failure's
// text stays on the row through the reload.
export function switchAnswered(state, seq, {error = null} = {}) {
    if (!state || state.seq !== seq || state.phase !== PHASE_SWITCHING)
        return state;
    return {...state, phase: PHASE_REFRESHING, error: error ? String(error) : null};
}

// The reload after the switch landed.
export function switchRefreshed(state, seq) {
    if (!state || state.seq !== seq || (state.phase !== PHASE_REFRESHING && state.phase !== PHASE_STILL))
        return state;
    return {...state, phase: null};
}

// The POST. The account comes from a row serve sent, never typed text.
export function switchRequest({provider, accountId}) {
    return {method: 'POST', path: SWITCH_PATH, body: {provider, accountId}};
}

// What one account row shows: a Switch button (enabled unless a switch is
// out), the progress text while its own switch is out, and its switch error.
// The error is redacted like row errors with Hide Personal Info.
export function rowSwitchView(account, {provider = null, state = null, capabilities = null,
    hidePersonalInfo = false} = {}) {
    const mine = !!state && state.provider === provider && state.accountId === account?.id;
    const offered = has(capabilities, SWITCH_CAPABILITY) && !!provider && isSwitchableId(account?.id) &&
        account?.active !== true && account?.row?.canSwitch === true;
    let error = mine && state.error ? state.error : null;
    if (error && hidePersonalInfo)
        error = redactEmails(error);
    return {
        button: offered,
        enabled: offered && !isBusy(state),
        progress: mine && isBusy(state) ? PHASE_TEXT[state.phase] : null,
        error,
    };
}

// What a card's switch rendering depends on, for its render cache.
export function switchRenderKey(card, opts = {}) {
    if (!card?.multi)
        return '';
    return JSON.stringify(card.accounts.map(account => {
        const view = rowSwitchView(account, {...opts, provider: card.provider});
        return [account.id, view.button, view.enabled, view.progress, view.error];
    }));
}
