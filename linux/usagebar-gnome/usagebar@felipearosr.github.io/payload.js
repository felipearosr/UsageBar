// Pure /usage row and window helpers. Times are milliseconds since the epoch.

export function paceOf(row, slot) {
    return row.pace ? [row.pace.primary, row.pace.secondary, row.pace.tertiary][slot] ?? null : null;
}

export function resetSecs(w, now = Date.now()) {
    if (!w?.resetsAt)
        return null;
    const at = Date.parse(w.resetsAt);
    return Number.isNaN(at) ? null : (at - now) / 1000;
}

export function windowsOf(row) {
    const u = row.usage;
    if (!u)
        return [];
    return [u.primary, u.secondary, u.tertiary]
        .map((w, slot) => ({w, slot}))
        .filter(({w}) => w && !w.isSyntheticPlaceholder && w.usedPercent !== null &&
                w.usedPercent !== undefined);
}

// Rows serve answered from the user's own Claude Code statusLine (opt-in feed),
// which the card labels as such.
export function isStatusLineSource(row) {
    return row?.source === 'statusline' || row?.source === 'statusline-stale';
}

// Rows serve answered from an old Claude statusLine capture while OAuth was rate limited.
export function isStaleSource(row) {
    return row?.source === 'statusline-stale';
}

export function extraWindowsOf(row) {
    return (row.usage?.extraRateWindows ?? []).filter(x => x?.window);
}

export function isLongWindow(w, now = Date.now()) {
    if (w.windowMinutes !== null && w.windowMinutes !== undefined)
        return w.windowMinutes >= 1440;
    return (resetSecs(w, now) ?? 0) > 86400;
}

export function windowLabel(minutes, slot) {
    if (minutes === null || minutes === undefined)
        return ['Session', 'Weekly', 'Monthly'][slot] ?? 'Window';
    if (minutes >= 40000)
        return 'Monthly';
    if (minutes >= 9000)
        return 'Weekly';
    if (minutes >= 1440)
        return `${Math.ceil(minutes / 1440)}-day`;
    if (slot === 0)
        return `Session (${Math.ceil(minutes / 60)}h)`;
    if (minutes >= 60)
        return `${Math.ceil(minutes / 60)}h`;
    return `${minutes}m`;
}
