// Machine Sync state for the Machines tab: when to push and read through
// `codexbar serve`, and how a GET /sync/status payload becomes rows.
// Dependency-free so the Node tests can exercise it without GJS.

import {formatSummaryUSD} from './renderstate.js';

// Push about every 150 s with ±20 s jitter (protocol §8.1).
export const SYNC_PUSH_SECS = 150;
export const SYNC_PUSH_JITTER_SECS = 20;
// Reads follow the push cadence while the tab is visible, and otherwise only
// once the data is older than 5 minutes (§8.3).
export const SYNC_STALE_SECS = 300;
export const SYNC_MAX_MODELS = 5;
// Days in the detail chart and models listed on a detail view.
export const SYNC_CHART_DAYS = 30;
export const SYNC_DETAIL_MODELS = 10;
// One color per Machine, by its place in the status list (this Machine
// first), so a Machine keeps its color between the summary bar, the chart and
// the legend. Neighbours sit far apart on the color wheel so two or three
// Machines never look alike. The `machine-colors` setting overrides it.
export const MACHINE_PALETTE = [
    '#3584e4', // blue
    '#e66100', // orange
    '#9141ac', // purple
    '#2ec27e', // green
    '#ed333b', // red
    '#f5c211', // yellow
    '#62a0ea', // light blue
    '#c061cb', // light purple
    '#33d17a', // light green
    '#f8e45c', // light yellow
];

// `overrides` maps machine id → "#rrggbb" (the `machine-colors` setting).
export function machineColor(index, machineId, overrides = {}) {
    return overrides[machineId] ?? MACHINE_PALETTE[index % MACHINE_PALETTE.length];
}

export function nextPushDelaySecs(random = Math.random) {
    return SYNC_PUSH_SECS + (random() * 2 - 1) * SYNC_PUSH_JITTER_SECS;
}

// What one refresh-loop tick should do. Times are milliseconds since the
// epoch; missing times mean "never".
//   paired          last known pairing state (false until the first answer)
//   tabVisible      the menu is open on the Machines tab
//   nextPushAt      earliest time for the next push attempt
//   lastReadAt      when the last read (refresh=1) was attempted
//   refreshedAt     when the data we hold was last read successfully
export function planSyncTick({
    now,
    paired,
    tabVisible = false,
    nextPushAt = 0,
    pushInFlight = false,
    lastReadAt = 0,
    refreshedAt = 0,
    readInFlight = false,
}) {
    if (!paired)
        return {push: false, read: false};
    const push = !pushInFlight && now >= nextPushAt;
    const sinceAttempt = (now - (lastReadAt || 0)) / 1000;
    const dataAge = (now - (refreshedAt || 0)) / 1000;
    const read = !readInFlight && sinceAttempt >= SYNC_PUSH_SECS &&
        (tabVisible || dataAge >= SYNC_STALE_SECS);
    return {push, read};
}

export function syncAgoText(secs) {
    if (secs < 60)
        return 'just now';
    if (secs < 3600)
        return `${Math.floor(secs / 60)} min ago`;
    if (secs < 86400)
        return `${Math.floor(secs / 3600)} h ago`;
    return `${Math.floor(secs / 86400)} d ago`;
}

export function spendText(spend) {
    if (!spend)
        return '—';
    const cost = formatSummaryUSD(spend.costUSD ?? 0);
    // Unpriced models make the total a lower bound.
    return spend.costIncomplete ? `${cost}+` : cost;
}

export function countText(n) {
    const value = n ?? 0;
    for (const [size, unit] of [[1e9, 'B'], [1e6, 'M'], [1e3, 'K']]) {
        if (value >= size)
            return `${(value / size).toFixed(1).replace(/\.0$/, '')}${unit}`;
    }
    return String(value);
}

function dayText(date) {
    const [y, m, d] = date.split('-').map(Number);
    return new Date(Date.UTC(y, m - 1, d, 12))
        .toLocaleDateString('en-US', {month: 'short', day: 'numeric', timeZone: 'UTC'});
}

export function coverageText(coverage) {
    if (!coverage?.from || !coverage?.to)
        return null;
    const from = dayText(coverage.from);
    const to = dayText(coverage.to);
    return from === to ? `Coverage ${from}` : `Coverage ${from} – ${to}`;
}

// Why the shown data may be out of date, or null when it is current.
//   payload     last good GET /sync/status answer
//   fetchError  the last request to serve failed (serve down or restarting)
function staleBanner(payload, now, fetchError) {
    const refreshedAt = payload?.refreshedAt ? Date.parse(payload.refreshedAt) : NaN;
    const age = Number.isFinite(refreshedAt) ? Math.max(0, (now - refreshedAt) / 1000) : null;
    const from = age === null ? '' : ` Showing data from ${syncAgoText(age)}.`;
    if (fetchError)
        return `codexbar serve isn't answering.${from}`;
    if (payload?.error)
        return `Can't reach the Sync Server.${from}`;
    if (age !== null && age >= SYNC_STALE_SECS)
        return `Machine data is out of date.${from}`;
    return null;
}

// Rows for the Machines tab, or {hidden: true} when this Machine isn't paired.
export function machinesView(payload, {now = Date.now(), fetchError = null, colors = {}} = {}) {
    if (!payload?.paired)
        return {hidden: true};
    const status = payload.status ?? null;
    const banner = staleBanner(payload, now, fetchError);
    if (!status) {
        return {
            hidden: false,
            loading: !banner,
            stale: !!banner,
            banner,
            machines: [],
            total: null,
        };
    }
    const total30 = status.total?.last30Days?.costUSD ?? 0;
    const machines = (status.machines ?? []).map((machine, index) => {
        const cost30 = machine.last30Days?.costUSD ?? 0;
        const models = (machine.models ?? []).slice(0, SYNC_MAX_MODELS).map(model => ({
            provider: model.provider,
            model: model.model,
            spend: spendText(model.spend),
            share: cost30 > 0 ? (model.spend?.costUSD ?? 0) / cost30 : 0,
        }));
        const lastSeen = machine.lastSeen ? Date.parse(machine.lastSeen) : NaN;
        return {
            id: machine.machineId,
            color: machineColor(index, machine.machineId, colors),
            cost30,
            name: machine.displayName || machine.machineId,
            thisMachine: !!machine.isThisMachine,
            active: !!machine.active,
            retired: !!machine.retired,
            today: spendText(machine.today),
            last30: spendText(machine.last30Days),
            share: total30 > 0 ? cost30 / total30 : null,
            models,
            moreModels: Math.max(0, (machine.models ?? []).length - models.length),
            coverage: coverageText(machine.coverage),
            lastSeen: Number.isFinite(lastSeen)
                ? `Last seen ${syncAgoText(Math.max(0, (now - lastSeen) / 1000))}` : 'Never seen',
        };
    });
    return {
        hidden: false,
        loading: false,
        stale: !!banner,
        banner,
        machines,
        activeCount: machines.filter(machine => machine.active).length,
        total: {
            today: spendText(status.total?.today),
            last30: spendText(status.total?.last30Days),
        },
        errors: (status.errors ?? []).length,
    };
}

// The Reporting Days of the chart, oldest first, ending with `today`.
function chartDates(today, count) {
    const [y, m, d] = today.split('-').map(Number);
    return Array.from({length: count}, (_, i) =>
        new Date(Date.UTC(y, m - 1, d - (count - 1 - i), 12)).toISOString().slice(0, 10));
}

function addSpend(into, spend) {
    into.costUSD += spend?.costUSD ?? 0;
    into.costIncomplete ||= !!spend?.costIncomplete;
    into.totalTokens += spend?.totalTokens ?? 0;
    into.requests += spend?.requests ?? 0;
    return into;
}

function sumSpend(spends) {
    return spends.reduce(addSpend, {costUSD: 0, costIncomplete: false, totalTokens: 0, requests: 0});
}

// Detail view for one Machine, or for every Machine at once ('all'). Null
// when the selection is no longer in the Sync Group. `hiddenModels` holds
// "provider:model" keys left out of the model list.
//   chart.points  one per day, each split by Machine as [name, value]
//   chart.colors  [name, color] pairs for the bars and the legend
export function machineDetailView(payload, selection, {now = Date.now(), hiddenModels = new Set(), colors = {}} = {}) {
    const status = payload?.status;
    if (!payload?.paired || !status)
        return null;
    const all = selection === 'all';
    const raw = (status.machines ?? []).map((machine, index) => ({
        machine,
        name: machine.displayName || machine.machineId,
        color: machineColor(index, machine.machineId, colors),
    }));
    const picked = all ? raw : raw.filter(({machine}) => machine.machineId === selection);
    if (!picked.length)
        return null;

    const today = sumSpend(picked.map(({machine}) => machine.today));
    const last30 = sumSpend(picked.map(({machine}) => machine.last30Days));
    const total30 = status.total?.last30Days?.costUSD ?? 0;

    // Chart in dollars, or tokens when nothing selected is priced.
    const useCost = picked.some(({machine}) =>
        (machine.days ?? []).some(day => (day.spend?.costUSD ?? 0) > 0));
    const metric = spend => (useCost ? spend?.costUSD : spend?.totalTokens) ?? 0;
    const byDay = picked.map(({machine}) =>
        new Map((machine.days ?? []).map(day => [day.date, day.spend])));
    const points = chartDates(status.today ?? new Date(now).toISOString().slice(0, 10), SYNC_CHART_DAYS)
        .map(date => {
            const spends = byDay.map(days => days.get(date)).filter(Boolean);
            const sum = sumSpend(spends);
            return {
                date,
                value: metric(sum),
                cost: useCost ? sum.costUSD : null,
                tokens: sum.totalTokens,
                models: picked
                    .map(({name}, i) => [name, metric(byDay[i].get(date))])
                    .filter(([, value]) => value > 0)
                    .sort((a, b) => b[1] - a[1]),
            };
        });
    const hasHistory = points.some(point => point.value > 0);

    // Models merged across the selected Machines, most expensive first.
    // Models hidden in prefs leave the list; the totals above keep them.
    const merged = new Map();
    for (const {machine} of picked) {
        for (const model of machine.models ?? []) {
            if (hiddenModels.has(`${model.provider}:${model.model}`))
                continue;
            const key = `${model.provider}/${model.model}`;
            const entry = merged.get(key) ?? {provider: model.provider, model: model.model, spend: sumSpend([])};
            addSpend(entry.spend, model.spend);
            merged.set(key, entry);
        }
    }
    const allModels = [...merged.values()].sort((a, b) =>
        b.spend.costUSD - a.spend.costUSD || b.spend.totalTokens - a.spend.totalTokens ||
        a.model.localeCompare(b.model));
    const models = allModels.slice(0, SYNC_DETAIL_MODELS).map(entry => ({
        provider: entry.provider,
        model: entry.model,
        spend: spendText(entry.spend),
        tokens: countText(entry.spend.totalTokens),
        share: last30.costUSD > 0 ? entry.spend.costUSD / last30.costUSD : 0,
    }));

    const kpis = [
        {title: 'Today', value: spendText(today)},
        {title: 'Last 30 days', value: spendText(last30)},
        {title: 'Tokens · 30 days', value: countText(last30.totalTokens)},
        {title: 'Requests · 30 days', value: countText(last30.requests)},
    ];

    let info;
    if (all) {
        const active = picked.filter(({machine}) => machine.active).length;
        const count = picked.length;
        info = [`${count} Machine${count === 1 ? '' : 's'} · ${active} active`];
    } else {
        const {machine} = picked[0];
        const lastSeen = machine.lastSeen ? Date.parse(machine.lastSeen) : NaN;
        info = [
            [machine.platform, machine.clientVersion && `codexbar ${machine.clientVersion}`]
                .filter(Boolean).join(' · ') || null,
            coverageText(machine.coverage),
            Number.isFinite(lastSeen)
                ? `Last seen ${syncAgoText(Math.max(0, (now - lastSeen) / 1000))}` : 'Never seen',
        ].filter(Boolean);
    }

    const single = all ? null : picked[0];
    return {
        id: all ? 'all' : single.machine.machineId,
        all,
        title: all ? 'All Machines' : single.name,
        color: all ? null : single.color,
        state: all ? null
            : single.machine.retired ? 'retired' : single.machine.active ? 'active' : 'idle',
        thisMachine: !all && !!single.machine.isThisMachine,
        share: !all && total30 > 0 ? (single.machine.last30Days?.costUSD ?? 0) / total30 : null,
        kpis,
        chart: hasHistory ? {points, colors: picked.map(({name, color}) => [name, color])} : null,
        models,
        moreModels: allModels.length - models.length,
        info,
    };
}

// The Machines the Providers tab's spend can follow, for its Machine picker:
// this Machine first (id null, which keeps the local cost reports), then the
// rest of the Sync Group, then 'all'. Empty unless at least two Machines
// synced, since there is nothing to pick otherwise.
export function spendScopeOptions(payload, {colors = {}} = {}) {
    const machines = payload?.paired ? payload.status?.machines ?? [] : [];
    if (machines.length < 2)
        return [];
    return [
        ...machines.map((machine, index) => ({
            id: machine.isThisMachine ? null : machine.machineId,
            name: machine.displayName || machine.machineId,
            color: machineColor(index, machine.machineId, colors),
        })),
        {id: 'all', name: 'All', color: null},
    ];
}

// Spend on the Providers tab when it follows another Machine or 'all',
// from that Machine's synced Spend. Null for this Machine (scope null) and
// when the Machine left the Sync Group. Machine Sync carries, per Machine,
// the last 30 days split by provider and model but no daily split by
// provider, so there is no per-provider Today or daily chart here.
//   providers  one per provider, most expensive first, each with its models
export function scopedSpend(payload, scope, {colors = {}} = {}) {
    const status = payload?.paired ? payload.status : null;
    if (!scope || !status)
        return null;
    const all = scope === 'all';
    const machines = status.machines ?? [];
    const index = machines.findIndex(machine => machine.machineId === scope);
    const picked = all ? machines : index >= 0 ? [machines[index]] : [];
    if (!picked.length || (all && machines.length < 2))
        return null;
    const byProvider = new Map();
    for (const machine of picked) {
        for (const model of machine.models ?? []) {
            const entry = byProvider.get(model.provider) ??
                {provider: model.provider, spend: sumSpend([]), models: new Map()};
            addSpend(entry.spend, model.spend);
            entry.models.set(model.model, addSpend(entry.models.get(model.model) ?? sumSpend([]), model.spend));
            byProvider.set(model.provider, entry);
        }
    }
    const bySpend = (a, b) => b.spend.costUSD - a.spend.costUSD || b.spend.totalTokens - a.spend.totalTokens;
    const providers = [...byProvider.values()].map(entry => ({
        provider: entry.provider,
        spend: entry.spend,
        models: [...entry.models].map(([model, spend]) => ({model, spend}))
            .sort((a, b) => bySpend(a, b) || a.model.localeCompare(b.model)),
    })).sort((a, b) => bySpend(a, b) || a.provider.localeCompare(b.provider));
    const machine = all ? null : picked[0];
    return {
        id: all ? 'all' : machine.machineId,
        all,
        name: all ? 'All Machines' : machine.displayName || machine.machineId,
        color: all ? null : machineColor(index, machine.machineId, colors),
        today: sumSpend(picked.map(m => m.today)),
        last30: sumSpend(picked.map(m => m.last30Days)),
        providers,
    };
}

// The four cost figures of a provider's detail card when the Providers tab
// follows another Machine: `provider` is one entry of scopedSpend's
// providers, or undefined when that Machine has no Spend for it.
export function scopedProviderKpis(provider) {
    const spend = provider?.spend ?? sumSpend([]);
    return [
        {title: 'Last 30 days Cost', value: spendText(spend)},
        {title: 'Last 30 days tokens', value: countText(spend.totalTokens)},
        {title: 'Requests · 30 days', value: countText(spend.requests)},
        {title: 'Models · 30 days', value: countText(provider?.models.length ?? 0)},
    ];
}
