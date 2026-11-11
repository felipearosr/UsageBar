// Provider Accounts: serve's /usage rows → provider cards, each with one row
// per account (its Quota windows, active marking, freshness and its own
// error). Dependency-free so the Node tests can exercise it without GJS.
//
// A serve that lists `providerAccountRows` on /health answers
// `/usage?accounts=all` with one row per Provider Account for providers that
// have several, each carrying `accountId` ("<source>:<opaque id>"),
// `accountSource`, `accountLabel`, `active` and `updatedAt`. Rows without an
// `accountId` (every provider with one account, and every row from an older
// CLI) are cards on their own, exactly as before.

import {accountLabels, ordinalLabel, scrubRow} from './accountlabels.js';
import {byAccountId, hasAccountId, isStaleSource, primaryRow, windowsOf, worstPercent} from './payload.js';

export const ACCOUNT_ROWS_CAPABILITY = 'providerAccountRows';

// The /usage request: `accounts=all` only for a serve that advertised it,
// `fresh=1` for the refresh button.
export function usagePath({accountRows = false, fresh = false} = {}) {
    const query = [];
    if (accountRows)
        query.push('accounts=all');
    if (fresh)
        query.push('fresh=1');
    return query.length ? `/usage?${query.join('&')}` : '/usage';
}

// Which earlier row a fresh row continues: the same Provider Account, or for
// rows without one, the same provider (as before accounts existed).
export function accountKey(row) {
    return hasAccountId(row) ? `${row.provider}\u0000${row.accountId}` : String(row?.provider ?? '');
}

// "just now", "40s ago", "5m ago", "2h ago".
export function agoText(secs) {
    if (secs < 10)
        return 'just now';
    if (secs < 90)
        return `${Math.floor(secs)}s ago`;
    if (secs < 3600)
        return `${Math.floor(secs / 60)}m ago`;
    return `${Math.floor(secs / 3600)}h ago`;
}

function timeOf(value) {
    const at = typeof value === 'string' ? Date.parse(value) : NaN;
    return Number.isNaN(at) ? null : at;
}

function errorText(row) {
    if (!row?.error)
        return null;
    const message = typeof row.error === 'string' ? row.error : row.error.message;
    return typeof message === 'string' && message.trim() ? message.trim() : 'error';
}

function accountOf(row, now, {single = false} = {}) {
    const updatedAt = timeOf(row.updatedAt) ?? timeOf(row.usage?.updatedAt);
    const ageSecs = updatedAt === null ? null : Math.max(0, (now - updatedAt) / 1000);
    return {
        id: hasAccountId(row) ? row.accountId : null,
        source: typeof row.accountSource === 'string' ? row.accountSource : null,
        // Set per card by labelAccounts (accountlabels.js).
        label: null,
        ordinal: null,
        // A provider's only row is the account its tools use.
        active: single || row.active === true,
        updatedAt,
        ageSecs,
        freshness: ageSecs === null ? null : `updated ${agoText(ageSecs)}`,
        error: errorText(row),
        stale: !!row.stale,
        row,
    };
}

// Labels for one card's accounts (private with Hide Personal Info, told
// apart when two share an email). With Hide Personal Info each account's row
// becomes a scrubbed copy, so nothing that renders a row (card head, account
// blocks, panel chips, issues, notifications) sees the raw label or an email
// in an error. The blocks keep row order either way, so toggling the setting
// never reorders the card (see accountlabels.js on the numbering).
function labelAccounts(card, hidePersonalInfo) {
    const labels = accountLabels(card.accounts.map(account => account.row), {hidePersonalInfo});
    card.accounts.forEach((account, index) => {
        account.label = labels[index].label;
        account.ordinal = labels[index].ordinal;
        if (hidePersonalInfo) {
            account.row = scrubRow(account.row, account.label);
            account.error = errorText(account.row);
        }
    });
}

function singleCard(row, now, hidePersonalInfo) {
    const card = {provider: row.provider, row, multi: false, accounts: [accountOf(row, now, {single: true})]};
    labelAccounts(card, hidePersonalInfo);
    card.row = card.accounts[0].row;
    return card;
}

// The account the rest of the popover (panel chip, compact row, issues,
// notifications) shows for a multi-account card: the active one, else the
// first with Quota, else the first, by account id (payload.js primaryRow,
// which notify.js shares), so Hide Personal Info never changes it.
function primaryAccount(accounts) {
    const row = primaryRow(accounts.map(account => account.row));
    return accounts.find(account => account.row === row) ?? accounts[0];
}

// rows → [{provider, row, multi, accounts: [{id, source, label, ordinal,
// active, updatedAt, ageSecs, freshness, error, stale, row}]}], in row order. Without
// the capability every row is its own card, as before; with it, a provider
// with any row that carries an accountId gets one card holding all its rows.
// Serve tags all or nothing per provider; an untagged row of such a provider
// (an older or odd serve) still joins that card, as an account without an id,
// so nothing renders twice. hidePersonalInfo: see labelAccounts.
export function buildCards(rows, {accountRows = false, now = Date.now(), hidePersonalInfo = false} = {}) {
    const list = Array.isArray(rows) ? rows.filter(row => row && typeof row === 'object') : [];
    if (!accountRows)
        return list.map(row => singleCard(row, now, hidePersonalInfo));
    const tagged = new Set(list.filter(hasAccountId).map(row => row.provider));
    const cards = [];
    const grouped = new Map();
    for (const row of list) {
        if (!tagged.has(row.provider)) {
            cards.push(singleCard(row, now, hidePersonalInfo));
            continue;
        }
        let card = grouped.get(row.provider);
        if (!card) {
            card = {provider: row.provider, row: null, multi: false, accounts: []};
            grouped.set(row.provider, card);
            cards.push(card);
        }
        card.accounts.push(accountOf(row, now));
    }
    for (const card of grouped.values()) {
        card.multi = card.accounts.length > 1;
        if (!card.multi)
            card.accounts[0].active = true;
        labelAccounts(card, hidePersonalInfo);
        card.row = primaryAccount(card.accounts).row;
    }
    return cards;
}

// One row per card, for everything outside the card's account list.
export function primaryRows(cards) {
    return cards.map(card => card.row);
}

// The `panel-icon-source` preference: what a multi-account card's panel
// chip reflects. prefs.js lists its choices in this order.
export const ICON_SOURCES = ['active', 'most-headroom'];

// The account a card's panel chip reflects. 'active' (the default, and any
// unknown value): the card's primary account, the one the popover shows.
// 'most-headroom': the account whose chip percent is lowest. The chip
// percent is the row's most-used window, standard and extra windows alike
// (payload.js worstWindow, what the chip has always shown), so the account
// with most headroom is the one whose tightest window is least used. Rows
// with an error (stale carried Quota included) or without any known percent
// (a stale row without usage) never win; a stale row without an error that
// still has usage counts with that usage. A tie keeps the primary, then the
// first by account id. With no eligible account, or a card with one account,
// it is the primary.
export function panelAccount(card, source = 'active') {
    const primary = card.accounts.find(account => account.row === card.row) ?? card.accounts[0];
    if (source !== 'most-headroom' || !card.multi)
        return primary;
    let best = null;
    let bestPercent = Infinity;
    const others = byAccountId(card.accounts.filter(a => a !== primary).map(a => a.row))
        .map(row => card.accounts.find(a => a.row === row));
    for (const account of [primary, ...others]) {
        if (account.error || account.row?.error)
            continue;
        const percent = worstPercent(account.row);
        if (percent === null || !Number.isFinite(percent))
            continue;
        if (percent < bestPercent) {
            best = account;
            bestPercent = percent;
        }
    }
    return best ?? primary;
}

// The row each panel chip renders. rows are the popover's rows (primaryRows,
// possibly enriched); cards maps provider → its multi-account card. A row
// whose card picks its primary account stays the very same row, so with one
// account, or the 'active' source, the panel is exactly as before.
export function panelRows(rows, cards, source = 'active') {
    return rows.map(row => {
        const card = cards?.get(row.provider);
        if (!card?.multi)
            return row;
        const account = panelAccount(card, source);
        return account.row === card.row ? row : account.row;
    });
}

// The rows quota notifications are planned over: every Provider Account of
// a multi-account card (each carrying its display label as accountLabel,
// which is the ordinal label with Hide Personal Info), every other card's
// row as it is. The primary account keeps the popover's own row.
export function notificationRows(rows, cards) {
    return rows.flatMap(row => {
        const card = cards?.get(row.provider);
        if (!card?.multi)
            return [row];
        return card.accounts.map(account => ({
            ...(account.row === card.row ? row : account.row),
            accountLabel: account.label ?? ordinalLabel(account.ordinal),
        }));
    });
}

// Serve replaces a failing provider's row with a bare error row; carry the
// last good usage of the same Provider Account forward, marked stale and with
// the time of that usage (port of client.rs merge_stale). Another account's
// Quota is never borrowed. A Claude row answered from an old statusLine
// capture is stale as served.
//
// An untagged error row for a provider whose previous rows were tagged (an
// older serve's provider timeout) stands for all of that provider's accounts:
// it becomes stale copies of their previous rows, each with the error, so
// the card stays multi-account.
export function mergeStale(previous, fresh) {
    const prior = Array.isArray(previous) ? previous : [];
    const freshTagged = new Set(fresh.filter(hasAccountId).map(row => row.provider));
    const merged = [];
    for (const row of fresh) {
        if (isStaleSource(row))
            row.stale = true;
        if (row.error && !hasAccountId(row) && !freshTagged.has(row.provider)) {
            const accounts = prior.filter(p => p.provider === row.provider && hasAccountId(p));
            if (accounts.length) {
                // Which account is active is unknown now: no stale copy
                // keeps the old active marker.
                for (const prev of accounts)
                    merged.push({...prev, error: row.error, stale: true, active: false});
                continue;
            }
        }
        if (row.error && windowsOf(row).length === 0) {
            const key = accountKey(row);
            const prev = prior.find(p => accountKey(p) === key && windowsOf(p).length > 0);
            if (prev) {
                row.usage = prev.usage;
                row.pace = prev.pace;
                if (prev.updatedAt !== undefined)
                    row.updatedAt = prev.updatedAt;
                row.stale = true;
            }
        }
        merged.push(row);
    }
    return merged;
}

// What a multi-account card's detail view depends on, for its render cache.
export function accountsRenderKey(card) {
    if (!card?.multi)
        return '';
    return JSON.stringify(card.accounts.map(account => [
        account.id, account.label, account.active, account.freshness, account.error, account.stale,
    ]));
}

// After serve removed a Provider Account: drop its row, and when fewer than
// two tagged rows of that provider remain, drop the provider's tagged rows
// altogether, since serve now answers it with one untagged row. Otherwise
// a later provider-level error row would bring the removed account back
// through mergeStale's expansion of the previous tagged rows.
export function forgetAccount(rows, provider, accountId) {
    const list = Array.isArray(rows) ? rows : [];
    const kept = list.filter(row => !(row.provider === provider && row.accountId === accountId));
    const tagged = kept.filter(row => row.provider === provider && hasAccountId(row));
    if (tagged.length >= 2)
        return kept;
    return kept.filter(row => !(row.provider === provider && hasAccountId(row)));
}
