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
// this Machine first (id 'this', which keeps the local cost reports), then
// the rest of the Sync Group, then 'all'. Empty unless at least two Machines
// synced, since there is nothing to pick otherwise.
export function spendScopeOptions(payload, {colors = {}} = {}) {
    const machines = payload?.paired ? payload.status?.machines ?? [] : [];
    if (machines.length < 2)
        return [];
    return [
        ...machines.map((machine, index) => ({
            id: machine.isThisMachine ? 'this' : machine.machineId,
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

// ---------- scoped cost reports (the cost dashboard) ----------

const DAY_COUNT_KEYS = ['inputTokens', 'outputTokens', 'cacheReadTokens', 'cacheCreationTokens',
    'totalTokens', 'requests'];

// Null when neither side was priced, so an unpriced day stays token-only.
function addCost(a, b) {
    return typeof a !== 'number' && typeof b !== 'number' ? null : (a ?? 0) + (b ?? 0);
}

function isPricedReport(report) {
    return typeof (report?.last30DaysCostUSD ?? report?.totals?.totalCost) === 'number';
}

// Folds one `daily` entry (a cost report's, or one provider of a synced day)
// into `byDate`, merging models by name.
function addDay(byDate, day) {
    const into = byDate.get(day.date) ?? {
        date: day.date,
        totalCost: null,
        costIncomplete: false,
        ...Object.fromEntries(DAY_COUNT_KEYS.map(key => [key, 0])),
        models: new Map(),
    };
    into.totalCost = addCost(into.totalCost, day.totalCost);
    into.costIncomplete ||= !!day.costIncomplete;
    for (const key of DAY_COUNT_KEYS)
        into[key] += day[key] ?? 0;
    for (const model of day.modelBreakdowns ?? []) {
        if (!model?.modelName)
            continue;
        const entry = into.models.get(model.modelName) ??
            {modelName: model.modelName, cost: null, totalTokens: 0};
        entry.cost = addCost(entry.cost, model.cost);
        entry.totalTokens += model.totalTokens ?? 0;
        into.models.set(model.modelName, entry);
    }
    byDate.set(day.date, into);
}

// One provider's cost report from its local report (or none) and the days
// other Machines synced for it.
function mergedReport(provider, local, syncedDays) {
    const byDate = new Map();
    for (const day of local?.daily ?? [])
        addDay(byDate, day);
    for (const day of syncedDays)
        addDay(byDate, day);
    const daily = [...byDate.values()]
        .sort((a, b) => a.date.localeCompare(b.date))
        .map(({models, ...day}) => {
            const modelBreakdowns = [...models.values()].sort((a, b) =>
                (b.cost ?? -1) - (a.cost ?? -1) || b.totalTokens - a.totalTokens ||
                a.modelName.localeCompare(b.modelName));
            return {...day, modelBreakdowns, modelsUsed: modelBreakdowns.map(model => model.modelName)};
        });
    const priced = isPricedReport(local) || daily.some(day => typeof day.totalCost === 'number');
    const totals = Object.fromEntries(DAY_COUNT_KEYS.map(key =>
        [key, daily.reduce((sum, day) => sum + day[key], 0)]));
    totals.totalCost = priced ? daily.reduce((sum, day) => sum + (day.totalCost ?? 0), 0) : null;
    return {provider, source: 'machine-sync', currencyCode: 'USD', daily, totals};
}

// Cost reports for the cost dashboard and the Providers tab's spend row in a
// Machine scope, shaped like the local cost reports so the cost overview
// reads them unchanged. `scope` is 'this', 'all' or a Machine id.
//   'this'      this Machine's local reports, as they are
//   'all'       the local reports plus every other Machine's synced `daily`,
//               merged per provider and day. This Machine's synced copy is
//               skipped, so its Spend counts once and is as fresh as the
//               local scan. Retired Machines count.
//   a Machine   only that Machine's synced `daily`
// Unpaired, or paired before the first status read, it is always 'this'. A
// Machine that left the Sync Group falls back to 'all'. Returns
//   scope     the scope the reports are for, after those fallbacks
//   reports   one per provider; `localReports` itself when nothing synced
//             changes it
//   coverage  the synced Machines the reports draw on, as {id, name, from}
//             with `from` the first day of their Coverage (null without
//             one); empty for 'this'. coverageShortfall() picks out the ones
//             whose history is shorter than a range.
//   shortCoverage  with `rangeDays` (and `today`, the dashboard's local
//             date) given, coverageShortfall() for that range
export function scopedCostReports(localReports, payload, scope = 'all', {rangeDays = null, today = null} = {}) {
    const result = scopedCostReportsFor(localReports, payload, scope);
    if (rangeDays)
        result.shortCoverage = coverageShortfall(result.coverage, rangeDays, today);
    return result;
}

function scopedCostReportsFor(localReports, payload, scope) {
    const local = localReports ?? [];
    const machines = payload?.paired ? payload.status?.machines ?? null : null;
    if (!machines || scope === 'this')
        return {scope: 'this', reports: local, coverage: []};
    const machine = scope === 'all' ? null : machines.find(m => m.machineId === scope);
    if (machine?.isThisMachine)
        return {scope: 'this', reports: local, coverage: []};
    const effective = machine ? machine.machineId : 'all';
    const picked = machine ? [machine] : machines.filter(m => !m.isThisMachine);
    const coverage = picked.map(m => ({
        id: m.machineId,
        name: m.displayName || m.machineId,
        from: m.coverage?.from ?? null,
    }));

    const synced = new Map(); // provider → its days on the picked Machines
    for (const m of picked) {
        for (const day of m.daily ?? []) {
            for (const entry of day.providers ?? []) {
                if (!entry?.provider || !day.date)
                    continue;
                const days = synced.get(entry.provider) ?? [];
                days.push({...entry, date: day.date});
                synced.set(entry.provider, days);
            }
        }
    }
    if (effective === 'all' && !synced.size)
        return {scope: 'all', reports: local, coverage};

    const base = effective === 'all' ? local : [];
    const reports = base.map(report => synced.has(report.provider)
        ? mergedReport(report.provider, report, synced.get(report.provider)) : report);
    const seen = new Set(base.map(report => report.provider));
    for (const provider of [...synced.keys()].sort()) {
        if (!seen.has(provider))
            reports.push(mergedReport(provider, null, synced.get(provider)));
    }
    return {scope: effective, reports, coverage};
}

// `date` (YYYY-MM-DD) moved by `days`.
function shiftDate(date, days) {
    const [y, m, d] = date.split('-').map(Number);
    return new Date(Date.UTC(y, m - 1, d + days, 12)).toISOString().slice(0, 10);
}

// The Machines of scopedCostReports' `coverage` whose synced history starts
// inside a range of `rangeDays` days ending `today`, so the range's earlier
// days are missing for them rather than zero. A Machine without Coverage
// has no synced history at all and counts as short.
export function coverageShortfall(coverage, rangeDays, today = null) {
    const end = today ?? new Date().toISOString().slice(0, 10);
    const start = shiftDate(end, -(Math.max(1, rangeDays) - 1));
    return (coverage ?? []).filter(entry => !entry.from || entry.from > start);
}

// The cost dashboard's note for Machines with short Coverage, or null.
export function shortCoverageText(short) {
    if (!short?.length)
        return null;
    const since = entry => (entry.from ? `from ${dayText(entry.from)}` : 'none yet');
    if (short.length === 1) {
        const [entry] = short;
        return entry.from
            ? `${entry.name}'s synced history starts ${dayText(entry.from)}; its earlier days are missing, not $0.`
            : `${entry.name} has no synced history yet; its days are missing, not $0.`;
    }
    const names = short.map(entry => `${entry.name} (${since(entry)})`);
    const list = `${names.slice(0, -1).join(', ')} and ${names.at(-1)}`;
    return `Synced history is shorter on ${list}; their earlier days are missing, not $0.`;
}

// What the cost dashboard flags about synced data in a scope, for a range
// of `rangeDays` days ending `today`. `scoped` is scopedCostReports' result.
// Nothing unless other Machines' data is shown (paired, scope not 'this').
//   note    shortCoverageText for Machines whose Coverage starts in range
//   banner  the Machines tab's banner when the last Sync Server read
//           failed, serve isn't answering (`fetchError`), or the data is
//           older than 5 minutes; null when it is current
//   stale   the synced contribution is greyed out
export function costSyncNotice(payload, scoped, {now = Date.now(), fetchError = null, rangeDays = 30, today = null} = {}) {
    const none = {short: [], note: null, banner: null, stale: false};
    if (!payload?.paired || !payload.status || !scoped || scoped.scope === 'this')
        return none;
    const short = coverageShortfall(scoped.coverage, rangeDays, today);
    const banner = staleBanner(payload, now, fetchError);
    return {short, note: shortCoverageText(short), banner, stale: !!banner};
}

// Entries of the cost dashboard's Machine scope switch: All Machines, then
// every Machine in the Sync Group in the Machines tab order (this Machine
// first), each in its Machine color. This Machine's id is 'this', so it
// reads its local reports. Empty, so no switch, while this Machine isn't
// paired or before the first status read.
export function costScopeOptions(payload, {colors = {}} = {}) {
    const machines = payload?.paired ? payload.status?.machines ?? [] : [];
    if (!machines.length)
        return [];
    const entries = machines.map((machine, index) => ({
        id: machine.isThisMachine ? 'this' : machine.machineId,
        name: machine.displayName || machine.machineId,
        color: machineColor(index, machine.machineId, colors),
    }));
    return [
        {id: 'all', name: 'All Machines', color: null},
        ...entries.filter(entry => entry.id === 'this'),
        ...entries.filter(entry => entry.id !== 'this'),
    ];
}

// What the spend row names after "Spend · last N days" for the scope
// scopedCostReports settled on: "all Machines", a Machine's name, or null
// while this Machine isn't paired (there is nothing to tell apart).
export function costScopeLabel(payload, scope) {
    const machines = payload?.paired ? payload.status?.machines ?? [] : [];
    if (!machines.length)
        return null;
    if (scope === 'all')
        return 'all Machines';
    const machine = machines.find(m => scope === 'this' ? m.isThisMachine : m.machineId === scope);
    return machine ? machine.displayName || machine.machineId : null;
}

// How the scope switch is drawn: 'segmented' while it fits beside the range
// switch in the dashboard header (`available` px wide), else 'dropdown'.
export function scopeControlMode({segmentedWidth, rangeWidth, spacing = 0, available}) {
    return segmentedWidth + spacing + rangeWidth <= available ? 'segmented' : 'dropdown';
}
