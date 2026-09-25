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
export function machinesView(payload, {now = Date.now(), fetchError = null} = {}) {
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
    const machines = (status.machines ?? []).map(machine => {
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
