import {
    extraWindowsOf, hasAccountId, isLongWindow, paceOf, primaryRow, windowLabel, windowsOf,
} from './payload.js';

const EXPIRY_GRACE_MS = 3600000;

// Quota cycle identity is owner:label:resetsAt, with an optional :pace
// suffix. The owner is the provider for a row without a Provider Account
// (every provider with one account: the same keys as before accounts
// existed), else provider#<encoded accountId>, so each account has its own
// cycles and changing which account is active changes no key. The accountId
// is URI-encoded so the owner never holds a colon. An account whose id
// changes (serve re-keys it) is a new owner: its current crossings announce
// once more under the new key.
// Match the ISO timestamp rather than splitting colons inside labels or times.
function cycleResetAt(key) {
    const stamp = key.match(/:(\d{4}-\d{2}-\d{2}(?:T.*?)?)(?::pace)?$/)?.[1];
    return Date.parse(stamp ?? '');
}

export function cycleOwner(row) {
    return hasAccountId(row) ? `${row.provider}#${encodeURIComponent(row.accountId)}` : String(row.provider);
}

function ownerOfKey(key) {
    return key.slice(0, key.indexOf(':'));
}

function providerOfOwner(owner) {
    const hash = owner.indexOf('#');
    return hash < 0 ? owner : owner.slice(0, hash);
}

// The higher of two memo values: thresholds are numbers, pace flags true.
function stronger(a, b) {
    if (a === undefined)
        return b;
    if (b === undefined)
        return a;
    if (typeof a === 'number' && typeof b === 'number')
        return Math.max(a, b);
    return a === true || b === true ? true : a;
}

// Whether a provider-keyed value records more than the accounts had: a
// threshold above all of theirs, or a pace flag none of them had.
function exceeds(value, accountsMax) {
    if (accountsMax === undefined)
        return true;
    if (typeof value === 'number' && typeof accountsMax === 'number')
        return value > accountsMax;
    return value === true && accountsMax !== true;
}

// Memo entries keyed the other way than this payload's rows, carried over so
// the switch never re-announces a crossing:
// - all of a provider's rows have an accountId: its provider-keyed entries
//   (written while its rows had none: an older serve, or the first /usage
//   before the /health report asked for account rows, as on every unlock)
//   go to the primary account (payload.js primaryRow), the one the untagged
//   row stood for. An account keeps its own value for the cycle; it takes
//   the provider-keyed one only when that is above what every account had
//   (a crossing announced while the rows were untagged). The entries move
//   once, so a later change of the active account inherits nothing.
// - none of its rows has one: its account-keyed entries lend their highest
//   value to the provider-keyed cycle. They stay (see planNotifications), so
//   the accounts keep them when account rows come back.
// - a mix (an odd serve): nothing moves; each row keeps its own keys.
// Muted providers, and providers whose primary row is stale, are left alone.
function carryOver(memo, rows, muted) {
    const working = new Map(memo);
    const byProvider = new Map();
    for (const row of rows)
        byProvider.set(row.provider, [...byProvider.get(row.provider) ?? [], row]);
    for (const [provider, list] of byProvider) {
        const tagged = list.filter(hasAccountId);
        const primary = primaryRow(list);
        if (muted.has(provider) || primary.stale)
            continue;
        // The highest account-keyed value per cycle suffix (:label:resetsAt[:pace]).
        const accountsMax = new Map();
        for (const [key, value] of memo) {
            const owner = ownerOfKey(key);
            if (owner === provider || providerOfOwner(owner) !== provider)
                continue;
            const rest = key.slice(owner.length);
            accountsMax.set(rest, stronger(accountsMax.get(rest), value));
        }
        if (tagged.length === list.length) {
            const owner = cycleOwner(primary);
            for (const [key, value] of memo) {
                if (ownerOfKey(key) !== provider)
                    continue;
                working.delete(key);
                const rest = key.slice(provider.length);
                if (exceeds(value, accountsMax.get(rest)))
                    working.set(`${owner}${rest}`, stronger(working.get(`${owner}${rest}`), value));
            }
        } else if (tagged.length === 0) {
            for (const [rest, value] of accountsMax)
                working.set(`${provider}${rest}`, stronger(working.get(`${provider}${rest}`), value));
        }
    }
    return working;
}

// Pure planner. memo is Map<cycleKey, number|true>; no actors or timer
// sources. rows may hold several Provider Accounts of one provider (rows
// with an accountId, labelled by accountLabel); each is planned on its own,
// and its notifications name the account when its provider has several.
export function planNotifications({rows, memo, sessionThresholds, weeklyThresholds,
    paceEnabled, muted, now, displayName}) {
    const seen = new Map();
    const notifications = [];
    const present = new Set(rows.map(cycleOwner));
    // Providers answered with no account rows at all this time: their
    // accounts' undated cycles wait for the account rows to come back.
    const untaggedProviders = new Set(rows.map(row => row.provider));
    for (const row of rows.filter(hasAccountId))
        untaggedProviders.delete(row.provider);
    const staleOwners = new Set(rows.filter(row => row.stale).map(cycleOwner));
    const staleProviders = new Set(rows.filter(row => row.stale).map(row => row.provider));
    const accountsOf = new Map();
    for (const row of rows.filter(hasAccountId))
        accountsOf.set(row.provider, (accountsOf.get(row.provider) ?? 0) + 1);
    const working = carryOver(memo, rows, muted);
    for (const [key, value] of working) {
        const owner = ownerOfKey(key);
        const provider = providerOfOwner(owner);
        const resetAt = cycleResetAt(key);
        const dated = Number.isFinite(resetAt);
        if (dated && resetAt < now - EXPIRY_GRACE_MS)
            continue;
        // Preserve outages/mutes, and recently missing dated cycles. Undated
        // entries survive only while their owner is present in the payload,
        // or for an account, while its provider is answered untagged. A
        // provider-keyed entry also waits out any stale row of its provider.
        const skipped = muted.has(provider) || staleOwners.has(owner) ||
            (owner === provider && staleProviders.has(provider)) ||
            (owner !== provider && untaggedProviders.has(provider));
        if (skipped || (!present.has(owner) && dated))
            seen.set(key, value);
    }
    for (const row of rows) {
        if (row.stale || muted.has(row.provider))
            continue;
        const name = displayName(row.provider);
        const owner = cycleOwner(row);
        const account = hasAccountId(row) && accountsOf.get(row.provider) > 1
            ? (typeof row.accountLabel === 'string' && row.accountLabel.trim() ? row.accountLabel.trim() : null)
            : null;
        const wins = [
            ...windowsOf(row).map(({w, slot}) =>
                ({w, label: windowLabel(w.windowMinutes, slot), pace: paceOf(row, slot)})),
            ...extraWindowsOf(row)
                .filter(x => x.window.usedPercent !== null && x.window.usedPercent !== undefined)
                .map(x => ({w: x.window, label: x.title ?? x.id, pace: null})),
        ];
        for (const {w, label, pace} of wins) {
            const cycle = `${owner}:${label}:${w.resetsAt ?? ''}`;
            const crossed = (isLongWindow(w, now) ? weeklyThresholds : sessionThresholds)
                .filter(t => w.usedPercent >= t);
            const prev = working.get(cycle);
            if (prev !== undefined)
                seen.set(cycle, prev);
            const notification = {provider: row.provider, name, label, w,
                percent: Math.round(w.usedPercent), pace,
                accountId: hasAccountId(row) ? row.accountId : null, account};
            if (crossed.length) {
                const highest = Math.max(...crossed);
                if (prev === undefined || highest > prev) {
                    notifications.push({kind: 'threshold', ...notification});
                    seen.set(cycle, highest);
                }
            }
            const paceKey = `${cycle}:pace`;
            const pacePrev = working.get(paceKey);
            if (pacePrev !== undefined)
                seen.set(paceKey, pacePrev);
            if (paceEnabled && pace?.willLastToReset === false && !pacePrev) {
                notifications.push({kind: 'pace', ...notification});
                seen.set(paceKey, true);
            }
        }
    }
    return {notifications, memo: seen};
}

// A notification's title. With one account per provider it reads as it
// always has ("Claude Session (5h) at 84%"); otherwise the account label
// follows the provider name ("OpenRouter (Work) Session (5h) at 84%").
export function notificationTitle({kind, name, label, percent, account}) {
    const who = account ? `${name} (${account})` : name;
    return kind === 'pace' ? `${who} ${label} won't last to reset` : `${who} ${label} at ${percent}%`;
}
