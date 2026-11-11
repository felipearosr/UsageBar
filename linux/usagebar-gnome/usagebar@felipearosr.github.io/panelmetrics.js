// Extra percentages on a provider's panel chip: any usage bar of any of the
// provider's Provider Accounts, each with an optional 1–2 letter tag on a
// colored pill so several numbers can share one chip. Shared by the
// extension and the preferences window, and dependency-free so the Node
// tests can run it.
//
// Settings:
//   known-panel-metrics  catalog the extension publishes, JSON
//                        {"p","a","n","act","k","l"} entries: provider,
//                        account id ('' for a provider's only row), the
//                        account's ordinal (0 for a provider's only row),
//                        whether it is the active account, bar key and bar
//                        label. Account emails and labels are never written,
//                        only ordinals ("Account 2").
//   panel-metrics        the user's picks, JSON {"p","a","k","on","letter",
//                        "color"} entries in chip order. `on` false keeps a
//                        bar's tag and color without showing it.

import {extraWindowsOf, windowLabel, windowsOf} from './payload.js';

// Dark enough that a white letter stays readable at panel size.
export const TAG_COLORS = [
    {id: 'navy', hex: '#0b4a8b', name: 'Navy'},
    {id: 'plum', hex: '#5b2a6e', name: 'Plum'},
    {id: 'teal', hex: '#0f5d5a', name: 'Teal'},
    {id: 'rust', hex: '#7a3a00', name: 'Rust'},
    {id: 'wine', hex: '#8a1c3a', name: 'Wine'},
    {id: 'slate', hex: '#3d3846', name: 'Slate'},
];

export const MAX_LETTERS = 2;

export function metricKey({p, a, k}) {
    return `${p}|${a ?? ''}|${k}`;
}

export function colorHex(id) {
    return (TAG_COLORS.find(color => color.id === id) ?? TAG_COLORS[0]).hex;
}

// Each account gets its own color by default, in ordinal order.
export function defaultColor(ordinal) {
    const index = Math.max(0, (Number.isInteger(ordinal) ? ordinal : 1) - 1);
    return TAG_COLORS[index % TAG_COLORS.length].id;
}

// The bar label's first letter or digit: "Weekly" → W, "Session (5h)" → S,
// "Fable only" → F.
export function defaultLetter(label) {
    const match = /[\p{L}\p{N}]/u.exec(typeof label === 'string' ? label : '');
    return match ? match[0].toUpperCase() : '';
}

export function cleanLetter(text) {
    return [...(typeof text === 'string' ? text : '').replace(/\s+/g, '')]
        .slice(0, MAX_LETTERS).join('').toUpperCase();
}

function parse(entries) {
    return (Array.isArray(entries) ? entries : []).map(entry => {
        try {
            return typeof entry === 'string' ? JSON.parse(entry) : entry;
        } catch {
            return null;
        }
    }).filter(entry => entry && typeof entry === 'object' &&
        typeof entry.p === 'string' && entry.p !== '' &&
        typeof entry.k === 'string' && entry.k !== '' &&
        (entry.a === undefined || typeof entry.a === 'string'));
}

// The `panel-metrics` picks, cleaned and deduplicated (first wins).
export function readMetrics(entries) {
    const seen = new Set();
    const metrics = [];
    for (const entry of parse(entries)) {
        const metric = {
            p: entry.p,
            a: entry.a ?? '',
            k: entry.k,
            on: entry.on !== false,
            letter: cleanLetter(entry.letter),
            color: TAG_COLORS.some(color => color.id === entry.color) ? entry.color : TAG_COLORS[0].id,
        };
        const key = metricKey(metric);
        if (seen.has(key))
            continue;
        seen.add(key);
        metrics.push(metric);
    }
    return metrics;
}

export function encodeMetrics(metrics) {
    return metrics.map(({p, a, k, on, letter, color}) =>
        JSON.stringify({p, a, k, on, letter: cleanLetter(letter), color}));
}

// The `known-panel-metrics` catalog.
export function readCatalog(entries) {
    return parse(entries).map(entry => ({
        p: entry.p,
        a: entry.a ?? '',
        n: Number.isInteger(entry.n) ? entry.n : 0,
        act: entry.act === true,
        k: entry.k,
        l: typeof entry.l === 'string' ? entry.l : entry.k,
    }));
}

// What the chip extras resolve against, per provider: the popover's row for
// a provider with one account (enrichments included), else each account's
// own row, with the popover's row standing in for the primary account (the
// same substitution accounts.js panelRows makes). rows: the popover's rows;
// multiCards: provider → multi-account card (accounts.js buildCards).
export function metricCards(rows, multiCards) {
    const cards = new Map();
    for (const row of Array.isArray(rows) ? rows : []) {
        const card = multiCards?.get(row.provider);
        if (card?.multi) {
            cards.set(row.provider, {
                multi: true,
                accounts: card.accounts.map(account => ({
                    id: account.id ?? '',
                    ordinal: account.ordinal ?? 0,
                    active: account.active === true,
                    primary: account.row === card.row,
                    row: account.row === card.row ? row : account.row,
                })),
            });
        } else {
            cards.set(row.provider, {
                multi: false,
                accounts: [{id: '', ordinal: 0, active: true, primary: true, row}],
            });
        }
    }
    return cards;
}

function barsOf(row) {
    return [
        ...windowsOf(row).map(({w, slot}) => ({k: `w${slot}`, l: windowLabel(w.windowMinutes, slot), w})),
        ...extraWindowsOf(row).map(x => ({k: `x:${x.id ?? x.title}`, l: x.title ?? x.id, w: x.window})),
    ];
}

// Every account × bar the user could add, in card and bar order. Accounts
// without an id on a multi-account card can't be addressed and are left out.
export function metricCatalog(cards) {
    const catalog = [];
    for (const [provider, card] of cards) {
        for (const account of card.accounts) {
            if (card.multi && !account.id)
                continue;
            for (const bar of barsOf(account.row)) {
                catalog.push({
                    p: provider,
                    a: card.multi ? account.id : '',
                    n: card.multi ? account.ordinal : 0,
                    act: card.multi && account.active,
                    k: bar.k,
                    l: bar.l,
                });
            }
        }
    }
    return catalog;
}

function accountFor(card, id) {
    if (!card.multi || id === '')
        return card.accounts.find(account => account.primary) ?? card.accounts[0];
    return card.accounts.find(account => account.id === id) ?? null;
}

// The shown picks for `provider`'s chip that resolve to a known percent, in
// settings order: [{key, percent, stale, letter, color}]. A pick whose
// account or bar is gone is skipped until it comes back.
export function chipExtras(provider, cards, metrics) {
    const card = cards?.get(provider);
    if (!card)
        return [];
    const extras = [];
    for (const metric of metrics ?? []) {
        if (metric.p !== provider || !metric.on)
            continue;
        const account = accountFor(card, metric.a);
        if (!account?.row)
            continue;
        const bar = barsOf(account.row).find(candidate => candidate.k === metric.k);
        const percent = bar?.w?.usedPercent;
        if (percent === null || percent === undefined || !Number.isFinite(percent))
            continue;
        extras.push({
            key: metricKey(metric),
            percent,
            stale: !!account.row.stale || !!account.row.error,
            letter: metric.letter,
            color: metric.color,
        });
    }
    return extras;
}

// The title a catalog entry gets in the preferences window.
export function metricTitle(entry, {multi}) {
    if (!multi)
        return entry.l;
    const account = entry.n > 0 ? `Account ${entry.n}` : 'Account';
    return `${account}${entry.act ? ' (active)' : ''} · ${entry.l}`;
}

// The picks after the user changed one entry: `patch` merged over the
// existing pick (or a fresh one with the default letter and color), then
// sorted into catalog order so the chip reads like the settings list. Picks
// the catalog doesn't list right now keep their place at the end.
export function updateMetrics(metrics, catalog, entry, patch) {
    const key = metricKey(entry);
    const base = pickFor(metrics, entry);
    const next = {...base, ...patch, letter: cleanLetter(patch.letter ?? base.letter)};
    const rest = metrics.filter(metric => metricKey(metric) !== key);
    const order = new Map(catalog.map((item, index) => [metricKey(item), index]));
    const ranked = [...rest, next].map((metric, index) => ({metric, index}));
    ranked.sort((x, y) => {
        const ox = order.get(metricKey(x.metric)) ?? Infinity;
        const oy = order.get(metricKey(y.metric)) ?? Infinity;
        return ox !== oy ? ox - oy : x.index - y.index;
    });
    return ranked.map(item => item.metric);
}

// The pick for a catalog entry, or the defaults it would get.
export function pickFor(metrics, entry) {
    const key = metricKey(entry);
    return metrics.find(metric => metricKey(metric) === key) ?? {
        p: entry.p,
        a: entry.a ?? '',
        k: entry.k,
        on: false,
        letter: defaultLetter(entry.l),
        color: defaultColor(entry.n || 1),
    };
}
