// Small, dependency-free state helpers shared by the GNOME renderer and its
// focused Node tests.  Keep the scheduling and cache rules here so they can
// be exercised without importing GJS modules.

export class RenderScheduler {
    constructor(schedule, cancel, render) {
        this._schedule = schedule;
        this._cancel = cancel;
        this._render = render;
        this._pending = null;
    }

    request() {
        if (this._pending !== null)
            return false;
        this._pending = this._schedule(() => {
            this._pending = null;
            this._render();
        });
        return true;
    }

    cancel() {
        if (this._pending === null)
            return false;
        this._cancel(this._pending);
        this._pending = null;
        return true;
    }

    get pending() {
        return this._pending !== null;
    }
}

export function buildCostDateRange(days, now = new Date()) {
    const count = Math.max(1, Math.trunc(days));
    const dates = [];
    for (let offset = count - 1; offset >= 0; offset--) {
        const date = new Date(now.getFullYear(), now.getMonth(), now.getDate() - offset);
        const year = date.getFullYear();
        const month = String(date.getMonth() + 1).padStart(2, '0');
        const day = String(date.getDate()).padStart(2, '0');
        dates.push(`${year}-${month}-${day}`);
    }
    return dates;
}

export function costRangeOptions(selectedDays = 30) {
    return [
        {days: 1, label: 'TODAY', edge: 'left'},
        {days: 7, label: '7 DAYS', edge: null},
        {days: 30, label: '30 DAYS', edge: null},
        {days: 90, label: '90 DAYS', edge: 'right'},
    ].map(option => ({...option, selected: option.days === selectedDays}));
}

export function costChartMetricOptions(selectedMetric = 'cost') {
    return [
        {
            metric: 'cost',
            label: 'COST',
            title: 'Daily cost',
            seriesKey: 'series',
            edge: 'left',
        },
        {
            metric: 'tokens',
            label: 'TOKENS',
            title: 'Daily tokens',
            seriesKey: 'tokenSeries',
            edge: 'right',
        },
    ].map(option => ({...option, selected: option.metric === selectedMetric}));
}

export function selectCostChartProviders(providers, hiddenProviders = [], limit = 4) {
    const hidden = new Set(hiddenProviders);
    return providers
        .filter(provider => !hidden.has(provider.provider))
        .slice(0, Math.max(0, Math.trunc(limit)));
}

export function resolveProviderOrder(providerIds, explicitOrder = [], alphabeticalNames = null) {
    const ids = [...new Set(providerIds)];
    if (alphabeticalNames) {
        return ids.sort((a, b) => (alphabeticalNames[a] ?? a)
            .localeCompare(alphabeticalNames[b] ?? b));
    }
    const rank = new Map(explicitOrder.map((provider, index) => [provider, index]));
    return ids.sort((a, b) => {
        const aRank = rank.get(a) ?? Number.MAX_SAFE_INTEGER;
        const bRank = rank.get(b) ?? Number.MAX_SAFE_INTEGER;
        return aRank - bRank;
    });
}

export function moveProviderOrder(providerIds, provider, direction) {
    const next = [...providerIds];
    const index = next.indexOf(provider);
    const target = index + direction;
    if (index < 0 || target < 0 || target >= next.length)
        return next;
    [next[index], next[target]] = [next[target], next[index]];
    return next;
}

export function summarizeCostRange(daily, dates) {
    const included = new Set(dates);
    const selected = daily.filter(day => included.has(day.date));
    const sum = key => selected.reduce((total, day) => total + (day[key] ?? 0), 0);
    return {
        daily: selected,
        cost: sum('totalCost'),
        tokens: sum('totalTokens'),
        cached: sum('cacheReadTokens'),
        input: sum('inputTokens'),
        writes: sum('cacheCreationTokens'),
        output: sum('outputTokens'),
    };
}

// Build newest-first rows for the cost panel's Day breakdown. Provider
// series are aligned to `dates`; omit completely idle days so the table stays
// useful (and bounded) even when the report covers a long sparse window.
export function buildDailyCostRows(dates, providers) {
    return dates.map((date, index) => {
        const costs = providers.map(provider => provider.series?.[index] ?? 0);
        const tokens = providers.map(provider => provider.tokenSeries?.[index] ?? 0);
        return {
            date,
            costs,
            totalCost: costs.reduce((sum, value) => sum + value, 0),
            totalTokens: tokens.reduce((sum, value) => sum + value, 0),
        };
    }).filter(row => row.totalCost > 0 || row.totalTokens > 0).reverse();
}

export function formatSummaryUSD(value) {
    if (Math.abs(value) < 10) {
        return `$${value.toLocaleString('en-US', {
            minimumFractionDigits: 2,
            maximumFractionDigits: 2,
        })}`;
    }
    return `$${Math.trunc(value).toLocaleString('en-US')}`;
}

// The gap between two pieces of a split bar: between providers in the spend
// bar, and at the pace point in a usage window bar.
export const BAR_GAP = 3;
// The narrowest a provider's piece of the spend bar gets, so a provider with a
// tiny share (a few dollars of thousands) still shows.
export const SUMMARY_BAR_MIN_SEGMENT = 8;

// One rounded piece per provider, separated by BAR_GAP (the BoxLayout's
// spacing). Every piece is at least SUMMARY_BAR_MIN_SEGMENT wide when the bar
// has room for that. Zero-cost providers do not consume space in the bar.
export function buildSummaryBarSegments(providers, totalCost, width) {
    const visible = providers.filter(provider => provider.cost > 0);
    if (visible.length === 0)
        return [];

    const available = Math.max(0, width - BAR_GAP * (visible.length - 1));
    const floor = Math.min(SUMMARY_BAR_MIN_SEGMENT, Math.floor(available / visible.length));
    let used = 0;
    return visible.map((provider, index) => {
        const remaining = visible.length - index - 1;
        const segmentWidth = index === visible.length - 1
            ? available - used
            : Math.max(floor, Math.min(
                Math.round(provider.cost / totalCost * available),
                available - used - remaining * floor));
        used += segmentWidth;
        return {width: Math.max(0, segmentWidth), radius: '2px'};
    });
}

// Geometry of a usage window bar `width` px wide. Without a pace split it is
// one track; with one (paceSplitOf) the track breaks into two pieces with a
// BAR_GAP gap centred on the expected-usage point. The usage fill runs through
// the first piece; usage past the split fills the second piece as `deficit`.
// The first fill keeps a 3px minimum, as the single bar always has.
export function windowBarLayout(width, usedPercent, split) {
    const used = Math.min(100, Math.max(0, usedPercent ?? 0));
    const usedX = Math.round(width * used / 100);
    if (!split)
        return [{x: 0, width, fill: Math.min(width, Math.max(3, usedX)), deficit: false}];

    const at = Math.round(width * split.at / 100);
    const firstEnd = Math.max(0, at - Math.floor(BAR_GAP / 2));
    const secondStart = Math.min(width, firstEnd + BAR_GAP);
    const over = Math.max(0, usedX - secondStart);
    return [
        {x: 0, width: firstEnd, fill: Math.min(firstEnd, Math.max(3, usedX)), deficit: false},
        {
            x: secondStart,
            width: width - secondStart,
            fill: split.deficit ? Math.min(width - secondStart, Math.max(2, over)) : 0,
            deficit: true,
        },
    ];
}

// Cost aggregation is cheap compared with the provider scan, but it is still
// needlessly repeated by every panel tick and navigation event.  The caller
// supplies a monotonically increasing revision when reports change.  The
// local date is part of the key because a cached 30-day series must roll over
// at midnight even when no provider response arrived in between.
export class CostOverviewCache {
    constructor(maxEntries = 2) {
        this._maxEntries = Math.max(1, maxEntries);
        this._entries = [];
    }

    get(reports, revision, localDate, compute, variant = '') {
        const hit = this._entries.find(entry => entry.reports === reports &&
            entry.revision === revision && entry.localDate === localDate &&
            entry.variant === variant);
        if (hit)
            return hit.value;

        const value = compute();
        this._entries.unshift({reports, revision, localDate, variant, value});
        if (this._entries.length > this._maxEntries)
            this._entries.length = this._maxEntries;
        return value;
    }

    clear() {
        this._entries.length = 0;
    }

    get size() {
        return this._entries.length;
    }
}

// Reconcile a bounded set of keyed views while retaining entries whose key is
// still present.  `update` may return a replacement when an entry's internal
// structure changed; returning undefined keeps the existing entry.  This is
// intentionally small so the renderer can supply the actor-specific cleanup.
export function reconcileKeyed(previous, items, keyOf, create, update, remove) {
    const next = new Map();
    items.forEach((item, index) => {
        const key = keyOf(item);
        let entry = previous.get(key);
        if (!entry)
            entry = create(item, index, items.length);
        const replacement = update(entry, item, index, items.length);
        if (replacement !== undefined)
            entry = replacement;
        next.set(key, entry);
    });
    for (const [key, entry] of previous) {
        if (!next.has(key))
            remove(entry, key);
    }
    return next;
}

// Gio.FileIcon creation and file existence checks are synchronous. Cache the
// result, including `null` for missing assets, for one extension lifetime.
export class LifetimeLookupCache {
    constructor(lookup) {
        this._lookup = lookup;
        this._values = new Map();
    }

    get(key) {
        if (!this._values.has(key))
            this._values.set(key, this._lookup(key));
        return this._values.get(key);
    }

    clear() {
        this._values.clear();
    }

    get size() {
        return this._values.size;
    }
}
