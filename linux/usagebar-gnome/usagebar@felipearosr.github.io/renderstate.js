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

// A completed update needs a new GNOME login session. Keep that instruction
// visible even when the old serve child exits or a fetch later succeeds.
export class StatusMessageState {
    constructor() {
        this._transient = '';
        this._persistent = '';
    }

    setTransient(message) {
        this._transient = message;
    }

    setPersistent(message) {
        this._persistent = message;
    }

    get current() {
        return this._persistent || this._transient;
    }
}

export function cliUpdateCompletionMessage(version) {
    return `codexbar ${version} installed — log out and back in to finish the update`;
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

// Keep provider colors visually distinct while preserving a continuous bar:
// the BoxLayout supplies a one-pixel gap and these radii round only the two
// outer ends. Zero-cost providers do not consume space in the bar.
export function buildSummaryBarSegments(providers, totalCost, width) {
    const visible = providers.filter(provider => provider.cost > 0);
    if (visible.length === 0)
        return [];

    const available = Math.max(0, width - Math.max(0, visible.length - 1));
    let used = 0;
    return visible.map((provider, index) => {
        const remaining = visible.length - index - 1;
        const segmentWidth = index === visible.length - 1
            ? available - used
            : Math.max(2, Math.min(
                Math.round(provider.cost / totalCost * available),
                available - used - remaining * 2));
        used += segmentWidth;
        const radius = visible.length === 1 ? '2px'
            : index === 0 ? '2px 0 0 2px'
                : index === visible.length - 1 ? '0 2px 2px 0' : '0';
        return {width: Math.max(0, segmentWidth), radius};
    });
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
