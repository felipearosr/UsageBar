import {extraWindowsOf, isLongWindow, paceOf, windowLabel, windowsOf} from './payload.js';

const EXPIRY_GRACE_MS = 3600000;

// Quota cycle identity is provider:label:resetsAt, with an optional :pace suffix.
// Match the ISO timestamp rather than splitting colons inside labels or times.
function cycleResetAt(key) {
    const stamp = key.match(/:(\d{4}-\d{2}-\d{2}(?:T.*?)?)(?::pace)?$/)?.[1];
    return Date.parse(stamp ?? '');
}

// Pure planner. memo is Map<cycleKey, number|true>; no actors or timer sources.
export function planNotifications({rows, memo, sessionThresholds, weeklyThresholds,
    paceEnabled, muted, now, displayName}) {
    const seen = new Map();
    const notifications = [];
    const present = new Set(rows.map(row => row.provider));
    const skipped = new Set(rows.filter(row => row.stale || muted.has(row.provider))
        .map(row => row.provider));
    for (const [key, value] of memo) {
        const provider = key.slice(0, key.indexOf(':'));
        const resetAt = cycleResetAt(key);
        const dated = Number.isFinite(resetAt);
        if (dated && resetAt < now - EXPIRY_GRACE_MS)
            continue;
        // Preserve outages/mutes, and recently missing dated cycles. Undated
        // entries survive only while their provider is present in the payload.
        if (skipped.has(provider) || (!present.has(provider) && dated))
            seen.set(key, value);
    }
    for (const row of rows) {
        if (row.stale || muted.has(row.provider))
            continue;
        const name = displayName(row.provider);
        const wins = [
            ...windowsOf(row).map(({w, slot}) =>
                ({w, label: windowLabel(w.windowMinutes, slot), pace: paceOf(row, slot)})),
            ...extraWindowsOf(row)
                .filter(x => x.window.usedPercent !== null && x.window.usedPercent !== undefined)
                .map(x => ({w: x.window, label: x.title ?? x.id, pace: null})),
        ];
        for (const {w, label, pace} of wins) {
            const cycle = `${row.provider}:${label}:${w.resetsAt ?? ''}`;
            const crossed = (isLongWindow(w, now) ? weeklyThresholds : sessionThresholds)
                .filter(t => w.usedPercent >= t);
            const prev = memo.get(cycle);
            if (prev !== undefined)
                seen.set(cycle, prev);
            const notification = {provider: row.provider, name, label, w,
                percent: Math.round(w.usedPercent), pace};
            if (crossed.length) {
                const highest = Math.max(...crossed);
                if (prev === undefined || highest > prev) {
                    notifications.push({kind: 'threshold', ...notification});
                    seen.set(cycle, highest);
                }
            }
            const paceKey = `${cycle}:pace`;
            const pacePrev = memo.get(paceKey);
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
