// Per-model preferences: which models the charts and model lists include,
// and the color each model gets in the charts. Shared by the extension and
// the preferences window, and dependency-free so the Node tests can run it.
//
// Settings:
//   known-models  catalog the extension publishes, JSON {"p","m","c"} entries
//                 ranked by 30-day cost within each provider
//   hidden-models "provider:model" entries left out of charts and lists
//   model-colors  "provider:model" → "#rrggbb" overrides

// The biggest model keeps the provider's brand color, the rest walk this
// fixed palette in rank order.
export const MODEL_PALETTE = [
    '#3584e4', // blue
    '#2ec27e', // green
    '#f5c211', // yellow
    '#9141ac', // purple
    '#e66100', // orange
    '#ed333b', // red
    '#62a0ea', // light blue
    '#33d17a', // light green
    '#f8e45c', // light yellow
    '#c061cb', // light purple
];

export function modelKey(provider, model) {
    return `${provider}:${model}`;
}

// Every model seen in the cost reports and the Machine Sync status, ranked
// by cost within its provider. `previous` keeps models that are missing from
// this round's data (a report not loaded yet) so the settings don't flicker.
// A model reported by both sources is counted once, at the larger cost —
// this Machine's spend shows up in both.
export function modelCatalog({reports = [], syncStatus = null, previous = []} = {}) {
    const costs = new Map();
    const note = (provider, model, cost) => {
        if (!provider || !model)
            return;
        const key = modelKey(provider, model);
        const entry = costs.get(key) ?? {p: provider, m: model, local: 0, synced: 0};
        costs.set(key, entry);
        return entry;
    };
    for (const report of reports ?? []) {
        for (const day of report?.daily ?? []) {
            for (const breakdown of day.modelBreakdowns ?? []) {
                const entry = note(report.provider, breakdown.modelName);
                if (entry)
                    entry.local += breakdown.cost ?? 0;
            }
        }
    }
    for (const machine of syncStatus?.machines ?? []) {
        for (const model of machine.models ?? []) {
            const entry = note(model.provider, model.model);
            if (entry)
                entry.synced += model.spend?.costUSD ?? 0;
        }
    }
    const entries = [...costs.values()].map(({p, m, local, synced}) => ({p, m, c: Math.max(local, synced)}));
    const seen = new Set(costs.keys());
    for (const old of previous) {
        if (old?.p && old?.m && !seen.has(modelKey(old.p, old.m)))
            entries.push({p: old.p, m: old.m, c: 0});
    }
    return entries.sort((a, b) =>
        a.p.localeCompare(b.p) || b.c - a.c || a.m.localeCompare(b.m));
}

// Rounded costs keep the published catalog from rewriting on every cent.
export function encodeCatalog(entries) {
    return entries.map(({p, m, c}) => JSON.stringify({p, m, c: Math.round(c)}));
}

export function decodeCatalog(strv) {
    const entries = [];
    for (const text of strv ?? []) {
        try {
            const entry = JSON.parse(text);
            if (typeof entry?.p === 'string' && typeof entry?.m === 'string')
                entries.push({p: entry.p, m: entry.m, c: Number(entry.c) || 0});
        } catch {
            // A hand-edited entry that isn't JSON is skipped.
        }
    }
    return entries;
}

// The provider's models in catalog (rank) order.
export function providerModels(catalog, provider) {
    return catalog.filter(entry => entry.p === provider).map(entry => entry.m);
}

// Color per model name for one provider: an override when set, otherwise its
// rank color. `names` adds models the catalog hasn't seen yet; they take the
// next rank colors.
export function modelColors(provider, {catalog = [], overrides = {}, brand = null, names = []} = {}) {
    const ranked = providerModels(catalog, provider);
    for (const name of names) {
        if (!ranked.includes(name))
            ranked.push(name);
    }
    const colors = new Map();
    ranked.forEach((name, i) => {
        const fallback = i === 0 && brand ? brand : MODEL_PALETTE[(brand ? i - 1 : i) % MODEL_PALETTE.length];
        colors.set(name, overrides[modelKey(provider, name)] ?? fallback);
    });
    return colors;
}

export function isModelHidden(hidden, provider, model) {
    return hidden.has(modelKey(provider, model));
}

// Chart points without hidden models. A day that had a model split is
// re-measured from what's left, so the bar shrinks with it; totals shown
// elsewhere stay the provider's real totals.
export function withoutHiddenModels(points, provider, hidden) {
    if (!points || !hidden.size)
        return points;
    return points.map(point => {
        if (!point.models.length)
            return point;
        const models = point.models.filter(([name]) => !isModelHidden(hidden, provider, name));
        if (models.length === point.models.length)
            return point;
        return {...point, models, value: models.reduce((sum, [, value]) => sum + value, 0)};
    });
}

export function hexColor({red, green, blue}) {
    const channel = v => Math.round(Math.max(0, Math.min(1, v)) * 255).toString(16).padStart(2, '0');
    return `#${channel(red)}${channel(green)}${channel(blue)}`;
}
