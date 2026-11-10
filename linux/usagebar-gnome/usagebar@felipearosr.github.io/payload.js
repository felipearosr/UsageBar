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

// The row's most-used window (standard slots and extras alike), or null:
// the window its panel chip shows. windowsOf already drops unknown
// percents; extras need the same filter.
export function worstWindow(row) {
    const wins = [
        ...windowsOf(row).map(({w}) => w),
        ...extraWindowsOf(row).map(x => x.window)
            .filter(w => w.usedPercent !== null && w.usedPercent !== undefined),
    ];
    return wins.reduce((a, b) => !a || b.usedPercent > a.usedPercent ? b : a, null);
}

export function worstPercent(row) {
    return worstWindow(row)?.usedPercent ?? null;
}

// A row of one Provider Account (serve's /usage?accounts=all).
export function hasAccountId(row) {
    return typeof row?.accountId === 'string' && row.accountId !== '';
}

// A copy of one provider's rows in a stable order: rows with an accountId by
// that id, then the rest in row order. Serve keeps account ids across
// refreshes, so neither response order nor Hide Personal Info's ordinal
// sort changes it.
export function byAccountId(rows) {
    return rows.map((row, index) => ({row, index})).sort((a, b) => {
        const x = hasAccountId(a.row) ? a.row.accountId : null;
        const y = hasAccountId(b.row) ? b.row.accountId : null;
        if (x !== null && y !== null && x !== y)
            return x < y ? -1 : 1;
        if ((x === null) !== (y === null))
            return x === null ? 1 : -1;
        return a.index - b.index;
    }).map(entry => entry.row);
}

// The row of one provider's Provider Accounts that the popover, panel chip
// and notifications treat as the provider's own: the active account, else
// the first with Quota (no error), else the first, in byAccountId order.
export function primaryRow(rows) {
    const ordered = byAccountId(rows);
    return ordered.find(row => row.active === true) ?? ordered.find(row => !row.error) ?? ordered[0];
}
