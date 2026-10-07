// UsageBar — GNOME Shell extension (Linux port of CodexBar).
//
// Panel chips (one per provider, worst-window percent) opening an anchored
// popover with a tab strip ("All" + one tab per provider, each with a mini
// usage bar) above the detail area: all cards stacked on the All tab, a
// single card per provider tab — rate-window progress bars, reset
// countdowns, pace, cost (Today / 30 days, top models), a statuspage-style
// incident-history strip and links.
//
// Self-contained backend: supervises `codexbar serve` on a free loopback
// port (like the Tauri tray in ../codexbar-tray) and polls GET /usage and
// GET /cost. Payload models mirror Sources/CodexBarCLI/CLIPayloads.swift and
// CLICostCommand.swift; see ../codexbar-tray/fixtures/ for captures.

import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import GObject from 'gi://GObject';
import St from 'gi://St';
import Soup from 'gi://Soup';
import Clutter from 'gi://Clutter';
import Shell from 'gi://Shell';

import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import * as Dialog from 'resource:///org/gnome/shell/ui/dialog.js';
import * as ModalDialog from 'resource:///org/gnome/shell/ui/modalDialog.js';
import * as PanelMenu from 'resource:///org/gnome/shell/ui/panelMenu.js';
import * as PopupMenu from 'resource:///org/gnome/shell/ui/popupMenu.js';

import {PROVIDER_META} from './providermeta.js';
import {monogramBadge} from './monogram.js';
import {
    buildCostDateRange,
    buildDailyCostRows,
    buildSummaryBarSegments,
    costChartMetricOptions,
    CostOverviewCache,
    costRangeOptions,
    formatSummaryUSD,
    LifetimeLookupCache,
    reconcileKeyed,
    RenderScheduler,
    selectCostChartProviders,
    summarizeCostRange,
    StatusMessageState,
} from './renderstate.js';
import {defaultScope, scopeMap} from './statusscopes.js';
import {machinesView, nextPushDelaySecs, planSyncTick} from './machinesync.js';
import {
    compareVersions,
    installCommand,
    latestUsageBarRelease,
    PACKAGED_BIN,
    packageAssetName,
    RELEASES_API,
    updateCompletionMessage,
    updateReadyText,
    withClaudeOAuth,
} from './updates.js';

const REQUEST_TIMEOUT_SECS = 120;
const FETCH_OK_SECS = 55;          // cache hits between serve refreshes
const FETCH_RETRY_SECS = 10;       // serve starting up / transient failure
const TICK_SECS = 30;              // countdown re-render while the menu is open
const COST_TTL_SECS = 120;
const COST_HISTORY_DAYS = 90;
const STATUS_TTL_SECS = 900;   // provider status pages refresh slowly
const STATUS_DAYS = 45;        // history strip length, like statuspage.io
const STATUS_BAR_HEIGHT = 18;
const BAR_WIDTH = 320;
const KPI_COL_WIDTH = 180; // left column of the 2x2 cost grid
const CHART_HEIGHT = 44; // daily cost/token trend bars
const TREND_CHART_DAYS = 30; // mini chart window, matching the macOS inline dashboard
const COST_HINTS = {
    codex: 'Estimated from local Codex logs for the selected account.',
    claude: 'Estimated from local logs · may differ from your bill',
};

// Per-provider dashboard/status URLs, status feeds and branding come from
// providermeta.js, generated out of CodexBarCore's ProviderDescriptors
// (regenerate with linux/usagebar-gnome/tools/gen-provider-meta.py until
// upstream's `config providers --format json` carries them).
//
// The dashboard link prefers the subscription page when the row reports a
// plan (loginMethod) — e.g. claude.ai usage for Max plans vs the API
// console for key users, matching the macOS app.
function providerLinks(row) {
    const meta = PROVIDER_META[row.provider];
    if (!meta)
        return null;
    const dashboard = (planOf(row) && meta.subscriptionDashboard) || meta.dashboard;
    const status = meta.statusPage ?? meta.statusLink;
    return dashboard || status ? {dashboard, status} : null;
}

// ---------- payload helpers (ported from codexbar-tray dist/app.js) ----------

// The row's plan ("claude max", "plus", …) — the payload carries
// loginMethod either on usage or under usage.identity, source-dependent.
function planOf(row) {
    return row.usage?.loginMethod ?? row.usage?.identity?.loginMethod;
}

// Pace projection for a standard window slot (extras carry no pace).
function paceOf(row, slot) {
    return row.pace ? [row.pace.primary, row.pace.secondary][slot] : null;
}

// Seconds until the window resets, or null without a parseable resetsAt.
function resetSecs(w) {
    if (!w?.resetsAt)
        return null;
    const at = Date.parse(w.resetsAt);
    return Number.isNaN(at) ? null : (at - Date.now()) / 1000;
}

function windowsOf(row) {
    const u = row.usage;
    if (!u)
        return [];
    return [u.primary, u.secondary, u.tertiary]
        .map((w, slot) => ({w, slot}))
        .filter(({w}) => w && !w.isSyntheticPlaceholder && w.usedPercent !== null &&
                w.usedPercent !== undefined);
}

// Named per-model/per-feature limits beyond the three standard slots
// (e.g. Claude's Fable weekly bar, "Daily Routines"). Only present from
// the oauth/web sources — the claude CLI source strips them, so the config
// must pin claude to source "oauth" on Linux.
function extraWindowsOf(row) {
    return (row.usage?.extraRateWindows ?? []).filter(x => x?.window);
}

// Stable per-bar identity shared by the card renderer and the prefs catalog,
// so a "provider:key" entry in hidden-windows removes the right bar. Standard
// slots key off their slot index; extra windows off their id (fallback title).
function barKey(provider, {slot, extra} = {}) {
    const key = extra ? `x:${extra.id ?? extra.title}` : `w${slot}`;
    return `${provider}:${key}`;
}

function compactWindowLabel(label) {
    const lower = (label || '').toLowerCase();
    if (lower.startsWith('gemini') && (lower.includes('5-hour') || lower.includes('5 hour') || lower.includes('5h') || lower.includes('session')))
        return '5h';
    if (lower.startsWith('gemini') && (lower.includes('weekly') || lower.includes('week') || lower.includes('7-day') || lower.includes('7d') || lower === 'wk'))
        return 'wk';
    if ((lower.includes('claude') || lower.includes('gpt') || lower.includes('3p')) && (lower.includes('5-hour') || lower.includes('5 hour') || lower.includes('5h') || lower.includes('session')))
        return '5h';
    if ((lower.includes('claude') || lower.includes('gpt') || lower.includes('3p')) && (lower.includes('weekly') || lower.includes('week') || lower.includes('7-day') || lower.includes('7d') || lower === 'wk'))
        return 'wk';
    if (lower.startsWith('gemini'))
        return 'Gemini';
    if (lower.includes('5-hour') || lower.includes('5 hour') || lower.includes('5h') || lower.includes('session'))
        return '5h';
    if (lower.includes('2-hour') || lower.includes('2 hour') || lower.includes('2h'))
        return '2h';
    if (lower.includes('hourly') || lower.includes('1-hour') || lower.includes('1 hour') || lower.includes('1h'))
        return '1h';
    if (lower.includes('weekly') || lower.includes('week') || lower.includes('7-day') || lower.includes('7d') || lower === 'wk')
        return 'wk';
    if (lower.includes('monthly') || lower.includes('month') || lower.includes('30-day') || lower.includes('30d'))
        return '30d';
    if (lower.includes('code review'))
        return 'Review';
    if (lower.includes('requests') || lower.includes('request'))
        return 'req';
    if (lower.includes('balance'))
        return 'bal';
    if (lower.includes('credits') || lower.includes('credit'))
        return 'cr';
    if (lower.includes('sonnet'))
        return 'Sonnet';
    if (lower.includes('opus'))
        return 'Opus';
    if (lower.includes('haiku'))
        return 'Haiku';
    if (lower.includes('gpt-oss') || lower.includes('gpt'))
        return 'GPT';
    if (lower.includes('3.7 flash'))
        return '3.7 Fl';
    if (lower.includes('3.6 flash'))
        return '3.6 Fl';
    if (lower.includes('3.5 flash'))
        return '3.5 Fl';
    if (lower.includes('3.1 pro'))
        return '3.1 Pro';
    if (lower.includes('flash'))
        return 'Flash';
    if (lower.includes('pro'))
        return 'Pro';
    const trimmed = (label || '').trim();
    if (trimmed.length <= 8)
        return trimmed;
    const firstWord = trimmed.split(' ')[0];
    if (firstWord.length <= 8)
        return firstWord;
    return trimmed.slice(0, 7);
}

// The row's most-used window (standard slots and extras alike), or null.
// windowsOf already drops unknown percents; extras need the same filter.
function worstWindow(row) {
    const wins = [
        ...windowsOf(row).map(({w}) => w),
        ...extraWindowsOf(row).map(x => x.window)
            .filter(w => w.usedPercent !== null && w.usedPercent !== undefined),
    ];
    return wins.reduce((a, b) => !a || b.usedPercent > a.usedPercent ? b : a, null);
}

function worstPercent(row) {
    return worstWindow(row)?.usedPercent ?? null;
}

// Serve replaces a failing provider's row with a bare error row; carry the
// last good usage forward, marked stale (port of client.rs merge_stale).
function mergeStale(previous, fresh) {
    for (const row of fresh) {
        if (row.error && windowsOf(row).length === 0) {
            const prev = previous.find(p => p.provider === row.provider &&
                windowsOf(p).length > 0);
            if (prev) {
                row.usage = prev.usage;
                row.pace = prev.pace;
                row.stale = true;
            }
        }
    }
    return fresh;
}

// Enrich Antigravity rows with the 4 core quota summary bars from the local agy server
function enrichAntigravityModels(rows) {
    const agRow = rows.find(r => r.provider === 'antigravity');
    if (!agRow || !agRow.usage)
        return rows;

    try {
        const ports = [];

        // Method 1: ss -tlnp for agy / language_server processes
        try {
            const proc = Gio.Subprocess.new(
                ['ss', '-tlnp'],
                Gio.SubprocessFlags.STDOUT_PIPE | Gio.SubprocessFlags.STDERR_SILENCE
            );
            const [, out] = proc.communicate_utf8(null, null);
            for (const line of (out || '').split('\n')) {
                if (/agy|language_server|antigravity/i.test(line)) {
                    const m = line.match(/127\.0\.0\.1:(\d+)/);
                    if (m) {
                        const p = parseInt(m[1], 10);
                        if (p > 1024) ports.push(p);
                    }
                }
            }
        } catch {
            // fallback
        }

        // Method 2: pgrep agy/language_server + lsof
        if (ports.length === 0) {
            try {
                const proc = Gio.Subprocess.new(
                    ['pgrep', '-f', 'agy|language_server|antigravity'],
                    Gio.SubprocessFlags.STDOUT_PIPE | Gio.SubprocessFlags.STDERR_SILENCE
                );
                const [, out] = proc.communicate_utf8(null, null);
                const pids = (out || '').trim().split('\n').map(s => s.trim()).filter(Boolean);
                if (pids.length > 0) {
                    const lproc = Gio.Subprocess.new(
                        ['lsof', '-nP', '-iTCP', '-sTCP:LISTEN', '-a', '-p', pids.join(',')],
                        Gio.SubprocessFlags.STDOUT_PIPE | Gio.SubprocessFlags.STDERR_SILENCE
                    );
                    const [, lout] = lproc.communicate_utf8(null, null);
                    for (const line of (lout || '').split('\n')) {
                        const m = line.match(/:(\d+)\s+\(LISTEN\)/);
                        if (m) ports.push(parseInt(m[1], 10));
                    }
                }
            } catch {
                // fallback
            }
        }

        const uniquePorts = [...new Set(ports)];
        for (const port of uniquePorts) {
            let handled = false;
            for (const scheme of ['https', 'http']) {
                try {
                    // Try RetrieveUserQuotaSummary first for the 4 core quota summary bars
                    const qProc = Gio.Subprocess.new(
                        ['curl', '-k', '-s', '--connect-timeout', '0.5', '--max-time', '1', '--http1.1', '-X', 'POST',
                         `${scheme}://127.0.0.1:${port}/exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary`,
                         '-H', 'Content-Type: application/json', '-d', '{"forceRefresh": true}'],
                        Gio.SubprocessFlags.STDOUT_PIPE | Gio.SubprocessFlags.STDERR_SILENCE
                    );
                    const [, qOut] = qProc.communicate_utf8(null, null);
                    if (qOut && qOut.startsWith('{')) {
                        const qData = JSON.parse(qOut);
                        const groups = qData.response?.groups || [];
                        if (groups.length > 0) {
                            const extras = [];
                            for (const group of groups) {
                                const isGemini = /gemini/i.test(group.displayName || '');
                                const groupPrefix = isGemini ? 'Gemini' : 'Claude/GPT';
                                for (const bucket of (group.buckets || [])) {
                                    const isWeekly = bucket.window === 'weekly' || /weekly/i.test(bucket.displayName || '');
                                    const timeLabel = isWeekly ? 'weekly' : '5-hour';
                                    const title = `${groupPrefix} ${timeLabel}`;
                                    const id = `antigravity-quota-summary-${isGemini ? 'gemini' : '3p'}-${isWeekly ? 'weekly' : '5h'}`;
                                    const frac = bucket.remainingFraction;
                                    const used = (frac !== null && frac !== undefined)
                                        ? Math.max(0, Math.min(100, Math.round((1 - frac) * 100 * 100) / 100))
                                        : 0;
                                    extras.push({
                                        id,
                                        title,
                                        window: {
                                            usedPercent: used,
                                            resetsAt: bucket.resetTime,
                                            windowMinutes: isWeekly ? 10080 : 300,
                                            resetDescription: bucket.description,
                                        },
                                    });
                                }
                            }
                            if (extras.length > 0) {
                                // Sort: Gemini 5-hour, Gemini weekly, Claude/GPT 5-hour, Claude/GPT weekly
                                extras.sort((a, b) => {
                                    const aGem = a.id.includes('gemini') ? 0 : 1;
                                    const bGem = b.id.includes('gemini') ? 0 : 1;
                                    if (aGem !== bGem) return aGem - bGem;
                                    const a5h = a.id.includes('5h') ? 0 : 1;
                                    const b5h = b.id.includes('5h') ? 0 : 1;
                                    return a5h - b5h;
                                });

                                agRow.usage.extraRateWindows = extras;
                                agRow.usage.primary = null;
                                agRow.usage.secondary = null;

                                // Also try to get userTier from GetUserStatus
                                try {
                                    const uProc = Gio.Subprocess.new(
                                        ['curl', '-k', '-s', '--connect-timeout', '0.5', '--max-time', '1', '--http1.1', '-X', 'POST',
                                         `${scheme}://127.0.0.1:${port}/exa.language_server_pb.LanguageServerService/GetUserStatus`,
                                         '-H', 'Content-Type: application/json', '-d', '{}'],
                                        Gio.SubprocessFlags.STDOUT_PIPE | Gio.SubprocessFlags.STDERR_SILENCE
                                    );
                                    const [, uOut] = uProc.communicate_utf8(null, null);
                                    if (uOut && uOut.startsWith('{')) {
                                        const uData = JSON.parse(uOut);
                                        if (uData.userStatus?.userTier?.name)
                                            agRow.usage.loginMethod = uData.userStatus.userTier.name;
                                    }
                                } catch {}

                                handled = true;
                                break;
                            }
                        }
                    }
                } catch {
                    // try next scheme
                }
            }
            if (handled) break;
        }
    } catch {
        // keep existing
    }
    return rows;
}

// Mutable so enable() can overwrite from GSettings (prefs.js edits them).
const THRESHOLDS = {warn: 60, crit: 85};

function severity(percent, grey) {
    if (grey)
        return 'stale';
    if (percent > THRESHOLDS.crit)
        return 'crit';
    if (percent > THRESHOLDS.warn)
        return 'warn';
    return 'ok';
}

// Notification bucket shared with windowLabel's ladder: a window spanning a
// day or more (windowLabel's "N-day"/"Weekly"/"Monthly" range) uses the
// weekly thresholds; without a duration in the payload, fall back to the
// reset horizon.
function isLongWindow(w) {
    if (w.windowMinutes !== null && w.windowMinutes !== undefined)
        return w.windowMinutes >= 1440;
    return (resetSecs(w) ?? 0) > 86400;
}

function windowLabel(minutes, slot) {
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

// Locale table for the handful of strings this extension formats itself in the
// usage foot (the % descriptor and the reset countdown). The pace verdict/ETA
// lines already arrive localized from the backend, which follows the system
// locale — mirror that here so the whole foot reads in one language. English is
// the fallback for any locale not listed.
function currentLang() {
    for (const name of GLib.get_language_names()) {
        const code = name.split(/[_.@]/)[0];
        if (code && code !== 'C' && code !== 'POSIX')
            return code;
    }
    return 'en';
}

const STRINGS = {
    en: {
        remaining: p => `${p}% remaining`,
        used: p => `${p}% used`,
        unavailable: 'unavailable',
        resetsIn: dur => `Resets in ${dur}`,
        resetsNow: 'Resets now',
        resetsAt: t => `Resets ${t}`,
        resetsDesc: desc => `Resets ${desc}`,
        dur: {d: n => `${n}d`, h: n => `${n}h`, m: n => `${n}m`, under: 'under 1m'},
    },
    es: {
        remaining: p => `${p}% restante`,
        used: p => `${p}% usado`,
        unavailable: 'no disponible',
        resetsIn: dur => `Se reinicia en ${dur}`,
        resetsNow: 'Se reinicia ahora',
        resetsAt: t => `Se reinicia ${t}`,
        resetsDesc: desc => `Se reinicia ${desc}`,
        dur: {d: n => `${n} d`, h: n => `${n} h`, m: n => `${n} min`, under: 'menos de 1 min'},
    },
};

const T = STRINGS[currentLang()] ?? STRINGS.en;

function humanizeSecs(secs) {
    const d = Math.floor(secs / 86400);
    const h = Math.floor((secs % 86400) / 3600);
    const m = Math.floor((secs % 3600) / 60);
    if (d > 0)
        return `${T.dur.d(d)} ${T.dur.h(h)}`;
    if (h > 0)
        return `${T.dur.h(h)} ${T.dur.m(m)}`;
    if (m > 0)
        return T.dur.m(m);
    return T.dur.under;
}

function agoText(secs) {
    if (secs < 10)
        return 'just now';
    if (secs < 90)
        return `${Math.floor(secs)}s ago`;
    if (secs < 3600)
        return `${Math.floor(secs / 60)}m ago`;
    return `${Math.floor(secs / 3600)}h ago`;
}

// Mutable display preferences, refreshed from GSettings on every settings
// change (same pattern as THRESHOLDS) so render paths never hit GSettings.
const DISPLAY = {
    appTheme: 'codexbar',
    absoluteResets: false,
    barsShowUsed: false,
    sortAlphabetical: false,
    providerOrder: [],
    mergeChips: false,
    resetWhenExhausted: false,
    chipMode: 'ring',
    showExtras: true,
    antigravityOverviewGemini: true,
    hiddenChips: new Set(),
    hiddenWindows: new Set(),
    hiddenCostChartProviders: new Set(),
};

function resetText(w) {
    const secs = resetSecs(w);
    if (secs !== null) {
        if (secs <= 0)
            return T.resetsNow;
        if (DISPLAY.absoluteResets) {
            const when = new Date(Date.parse(w.resetsAt));
            const opts = {hour: '2-digit', minute: '2-digit'};
            if (secs >= 86400)
                opts.weekday = 'short';
            return T.resetsAt(when.toLocaleString([], opts));
        }
        return T.resetsIn(humanizeSecs(secs));
    }
    return w.resetDescription ? T.resetsDesc(w.resetDescription) : '';
}

function fmtTokens(n) {
    if (n === null || n === undefined)
        return null;
    if (n >= 1e9)
        return `${(n / 1e9).toFixed(1)}B`;
    if (n >= 1e6)
        return `${(n / 1e6).toFixed(1)}M`;
    if (n >= 1e3)
        return `${(n / 1e3).toFixed(1)}K`;
    return String(n);
}

// All dollar amounts share formatSummaryUSD's rule: cents under $10,
// whole dollars (truncated) otherwise. Null-safe for the "—" placeholders.
function fmtUSD(v) {
    return v === null || v === undefined ? null : formatSummaryUSD(v);
}

// Cost as a 2x2 label-over-value grid, like the macOS inline dashboard:
// Today | Last Nd Cost / Last Nd tokens | Latest tokens. Values the report
// doesn't carry render as "—", as on macOS (codex has no pricing, and a
// fresh install has no history yet).
function costKpis(report) {
    if (!report)
        return null;
    const today = new Date().toLocaleDateString('en-CA'); // local YYYY-MM-DD
    const daily = report.daily ?? [];
    // Dollar values arrive under the upstream key "totalCost".
    const entry = daily.find(d => d.date === today);
    const latest = daily.length ? daily[daily.length - 1] : null;
    const totals = report.totals ?? {};
    const days = report.historyDays ?? 30;
    const kpis = [
        {title: 'Today', value: fmtUSD(entry?.totalCost) ?? '—'},
        {title: `Last ${days} days Cost`, value: fmtUSD(report.last30DaysCostUSD ?? totals.totalCost) ?? '—'},
        {title: `Last ${days} days tokens`, value: fmtTokens(report.last30DaysTokens ?? totals.totalTokens) ?? '—'},
        {title: 'Latest tokens', value: fmtTokens(latest?.totalTokens) ?? '—'},
    ];
    return kpis;
}

// Daily trend values for the mini bar chart (port of the macOS inline
// dashboard): a continuous series of the last `limit` days ending today —
// days without usage are zero (1px stub) so the rightmost bar is always
// today. The macOS inline dashboard caps this at 30 days; the cost report
// carries more (up to 90) for the dashboard's range selector. Dollars when
// the report is priced, tokens otherwise. Null when there is no history.
function chartPoints(report, limit = TREND_CHART_DAYS) {
    const daily = report?.daily ?? [];
    if (!daily.length)
        return null;
    const byDate = new Map(daily.map(d => [d.date, d]));
    const useCost = daily.some(d => typeof d.totalCost === 'number');
    const days = Math.min(report.historyDays ?? TREND_CHART_DAYS, limit);
    const now = new Date();
    const points = [];
    for (let i = days - 1; i >= 0; i--) {
        const day = new Date(now.getFullYear(), now.getMonth(), now.getDate() - i)
            .toLocaleDateString('en-CA'); // local YYYY-MM-DD
        const entry = byDate.get(day);
        points.push({
            value: entry ? ((useCost ? entry.totalCost : entry.totalTokens) ?? 0) : 0,
            date: day,
            cost: entry?.totalCost ?? null,
            tokens: entry?.totalTokens ?? null,
            // Per-model slices of the day in the chart's metric — the stacked
            // bar segments and the colored legend below the chart both read
            // these.
            models: entry ? (entry.modelBreakdowns ?? [])
                .map(m => [m.modelName, useCost ? m.cost : (m.totalTokens ?? 0)])
                .filter(([name, v]) => name && typeof v === 'number' && v > 0)
                .sort((a, b) => b[1] - a[1])
            : [],
        });
    }
    return points;
}

// Per-model colors for the stacked chart: the biggest model keeps the
// provider's brand color, the rest walk a fixed distinguishable palette.
const MODEL_PALETTE = [
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

function modelColorsFromPoints(points, brand) {
    const totals = new Map();
    for (const p of points) {
        for (const [name, v] of p.models)
            totals.set(name, (totals.get(name) ?? 0) + v);
    }
    const sorted = [...totals.entries()].sort((a, b) => b[1] - a[1]);
    const colors = new Map();
    sorted.forEach(([name], i) => {
        colors.set(name,
            i === 0 && brand ? brand : MODEL_PALETTE[(i - 1) % MODEL_PALETTE.length]);
    });
    return colors;
}

function chartTooltipText(point) {
    const day = new Date(`${point.date}T12:00:00`)
        .toLocaleDateString('en-US', {month: 'short', day: 'numeric'});
    if (!point.models.length)
        return `${day} · no usage`;
    const lines = point.models.map(([name, v]) =>
        `${name.replace(/^claude-/, '')} ${point.cost !== null ? (fmtUSD(v) ?? '$0.00') : fmtTokens(v)}`);
    return [day, ...lines].join('\n');
}

// ---------- local cost reports ----------
//
// The CLI's /cost prices only a few providers. OpenCode records each
// response's billed cost, tokens and model in its SQLite history, so for
// OpenCode Go the same report shape is built from there (read-only, last
// historyDays local days). Needs python3's stdlib sqlite3 only.

const LOCAL_COST_PROVIDERS = new Set(['opencodego']);
const OPENCODE_GO_COST_PY = `
import datetime, json, sqlite3, sys
path, days = sys.argv[1], int(sys.argv[2])
today = datetime.date.today()
start = today - datetime.timedelta(days=days - 1)
start_ms = int(datetime.datetime.combine(start, datetime.time()).timestamp() * 1000)
db = sqlite3.connect("file:" + path + "?mode=ro", uri=True)
db.execute("PRAGMA busy_timeout = 250")
rows = db.execute("""
  SELECT COALESCE(json_extract(data, '$.time.created'), time_created),
         json_extract(data, '$.modelID'), json_extract(data, '$.cost'),
         json_extract(data, '$.tokens.input'), json_extract(data, '$.tokens.output'),
         json_extract(data, '$.tokens.reasoning'), json_extract(data, '$.tokens.cache.read'),
         json_extract(data, '$.tokens.cache.write'), json_extract(data, '$.tokens.total')
  FROM message
  WHERE time_created >= ? AND json_valid(data)
    AND json_extract(data, '$.providerID') = 'opencode-go'
    AND json_extract(data, '$.role') = 'assistant'""", (start_ms,)).fetchall()
keys = ("inputTokens", "outputTokens", "cacheReadTokens", "cacheCreationTokens", "totalTokens")
num = lambda v: v if isinstance(v, (int, float)) else 0
def blank():
    b = {k: 0 for k in keys}
    b["totalCost"] = 0.0
    b["models"] = {}
    return b
daily, totals = {}, blank()
for created, model, cost, inp, out, reasoning, cread, cwrite, total in rows:
    date = datetime.datetime.fromtimestamp(created / 1000).date()
    if date < start:
        continue
    vals = {"inputTokens": num(inp), "outputTokens": num(out) + num(reasoning),
            "cacheReadTokens": num(cread), "cacheCreationTokens": num(cwrite)}
    vals["totalTokens"] = num(total) or sum(vals.values())
    for b in (daily.setdefault(date.isoformat(), blank()), totals):
        b["totalCost"] += num(cost)
        for k in keys:
            b[k] += vals[k]
        m = b["models"].setdefault(model or "unknown", [0.0, 0])
        m[0] += num(cost)
        m[1] += vals["totalTokens"]
def breakdown(b):
    models = sorted(b.pop("models").items(), key=lambda kv: -kv[1][0])
    return [{"modelName": k, "cost": v[0], "totalTokens": v[1]} for k, v in models]
entries = []
for date in sorted(daily):
    b = daily[date]
    mb = breakdown(b)
    entries.append(dict(b, date=date, modelBreakdowns=mb, modelsUsed=[m["modelName"] for m in mb]))
totals.pop("models")
print(json.dumps({
    "provider": "opencodego", "source": "local", "currencyCode": "USD",
    "provenance": "reported", "historyDays": days, "daily": entries, "totals": totals,
    "last30DaysCostUSD": totals["totalCost"], "last30DaysTokens": totals["totalTokens"],
    "sessionCostUSD": daily.get(today.isoformat(), {}).get("totalCost", 0.0),
    "updatedAt": datetime.datetime.now(datetime.timezone.utc).isoformat(),
}))
`;

// ---------- cost overview (All-view summary + hover panel) ----------

const OV_LEFT_WIDTH = 270;
const OV_CHART_HEIGHT = 170;
const OV_MAX_MODELS = 12;
const OV_MAX_DAYS = 12;
// Codex counts cache reads inside inputTokens; the other priced providers
// (claude) report fresh input only.
const INPUT_INCLUDES_CACHE = new Set(['codex']);

function hexRGB(hex) {
    const m = /^#?([0-9a-f]{6})$/i.exec(hex ?? '');
    const n = m ? parseInt(m[1], 16) : 0x9a9996;
    return [((n >> 16) & 255) / 255, ((n >> 8) & 255) / 255, (n & 255) / 255];
}

function fmtDay(date) {
    return new Date(`${date}T12:00:00`)
        .toLocaleDateString('en-US', {month: 'short', day: 'numeric'});
}

function localDateKey(date = new Date()) {
    const y = date.getFullYear();
    const m = String(date.getMonth() + 1).padStart(2, '0');
    const d = String(date.getDate()).padStart(2, '0');
    return `${y}-${m}-${d}`;
}

function fmtPct(frac) {
    return `${(Number.isFinite(frac) ? frac * 100 : 0).toFixed(1)}%`;
}

// Round an axis max up to 1, 2, 2.5 or 5 × 10^n.
function niceCeil(v) {
    if (!(v > 0))
        return 1;
    const pow = 10 ** Math.floor(Math.log10(v));
    return [1, 2, 2.5, 5, 10].find(m => m * pow >= v) * pow;
}

// Catmull-Rom through pts as cubic Béziers. Control points are clamped to
// [top, bot], so the curve (inside their convex hull) never dips below the
// baseline around zero days.
function smoothPath(cr, pts, top, bot) {
    const c = y => Math.max(top, Math.min(bot, y));
    cr.moveTo(pts[0][0], pts[0][1]);
    for (let i = 0; i < pts.length - 1; i++) {
        const p0 = pts[Math.max(0, i - 1)];
        const p1 = pts[i];
        const p2 = pts[i + 1];
        const p3 = pts[Math.min(pts.length - 1, i + 2)];
        cr.curveTo(
            p1[0] + (p2[0] - p0[0]) / 6, c(p1[1] + (p2[1] - p0[1]) / 6),
            p2[0] - (p3[0] - p1[0]) / 6, c(p2[1] - (p3[1] - p1[1]) / 6),
            p2[0], p2[1]);
    }
}

function isPricedCostReport(report) {
    return typeof (report?.last30DaysCostUSD ?? report?.totals?.totalCost) === 'number';
}

// Cross-provider rollup of every priced cost report: total, per-provider
// split with a daily cost series each, token KPIs and a per-model
// breakdown. Null when no report carries a dollar figure.
function costOverview(reports, rangeDays = 30) {
    const priced = (reports ?? []).filter(r =>
        typeof (r.last30DaysCostUSD ?? r.totals?.totalCost) === 'number');
    if (!priced.length)
        return null;
    const dates = buildCostDateRange(rangeDays);
    const active = new Set();
    const models = new Map();
    const providers = priced.map(r => {
        const range = summarizeCostRange(r.daily ?? [], dates);
        const daily = range.daily;
        const cached = range.cached;
        const input = range.input;
        const byDate = new Map();
        const tokensByDate = new Map();
        for (const d of daily) {
            byDate.set(d.date, d.totalCost ?? 0);
            tokensByDate.set(d.date, d.totalTokens ?? 0);
            if ((d.totalTokens ?? 0) > 0)
                active.add(d.date);
            for (const m of d.modelBreakdowns ?? []) {
                if (!m.modelName)
                    continue;
                const e = models.get(m.modelName) ??
                    {name: m.modelName, provider: r.provider, cost: 0, tokens: 0};
                e.cost += m.cost ?? 0;
                e.tokens += m.totalTokens ?? 0;
                models.set(m.modelName, e);
            }
        }
        return {
            provider: r.provider,
            color: PROVIDER_META[r.provider]?.color ?? '#9a9996',
            cost: range.cost,
            tokens: range.tokens,
            cached,
            uncached: INPUT_INCLUDES_CACHE.has(r.provider) ? Math.max(0, input - cached) : input,
            writes: range.writes,
            output: range.output,
            series: dates.map(d => byDate.get(d) ?? 0),
            tokenSeries: dates.map(d => tokensByDate.get(d) ?? 0),
        };
    }).sort((a, b) => b.cost - a.cost);
    const sum = key => providers.reduce((a, p) => a + p[key], 0);
    return {
        dates,
        providers,
        cost: sum('cost'),
        tokens: sum('tokens'),
        cached: sum('cached'),
        uncached: sum('uncached'),
        writes: sum('writes'),
        output: sum('output'),
        activeDays: active.size,
        models: [...models.values()].sort((a, b) => b.cost - a.cost || b.tokens - a.tokens),
        dailyRows: buildDailyCostRows(dates, providers),
    };
}

// ---------- provider status (public status-page incident feeds) ----------

// Both feeds normalize to impact intervals {rank, name, start, end,
// ongoing}: rank 1 → yellow, 2/3 → red (matching the usage-bar palette),
// plus `covered` — the feed is a bounded page, so when it looks truncated,
// days wholly before its oldest entry are unknown, not a clean green.
const IMPACT_SEV = ['ok', 'warn', 'crit', 'crit'];
const STATUSPAGE_IMPACT_RANK = {minor: 1, major: 2, critical: 3};
const INCIDENTIO_STATUS_RANK = {
    degraded_performance: 1,
    partial_outage: 2,
    full_outage: 3,
};

function feedCoverage(incidents, dateOf) {
    const starts = (incidents ?? []).map(dateOf).filter(t => !Number.isNaN(t));
    return (incidents ?? []).length >= 20 && starts.length
        ? Math.min(...starts) : 0;
}

// Classic Atlassian Statuspage /api/v2/incidents.json.
//
// 'Everything': one interval per incident, spanning its whole lifetime,
// ranked by page-level impact — the page's overall incident history.
//
// Component scope (name prefix, case-insensitive — 'Claude API' matches
// 'Claude API (api.anthropic.com)'): reconstruct that component's outage
// windows from the per-update status transitions, exactly what the page's
// per-component uptime bars show. Like those bars, degraded_performance
// does NOT color a day (an incident can sit at "degraded" for weeks —
// e.g. a model-access notice — while the page stays green),
// partial_outage colors it yellow and major_outage red.
const STATUSPAGE_COMPONENT_RANK = {partial_outage: 1, major_outage: 3};

function statuspageIntervals(incidents, scope) {
    const now = Date.now();
    const covered = feedCoverage(incidents, inc => Date.parse(inc.created_at));
    if (!scope || scope === 'Everything') {
        return {
            covered,
            intervals: (incidents ?? [])
                .map(inc => ({
                    rank: STATUSPAGE_IMPACT_RANK[inc.impact] ?? 0,
                    name: inc.name ?? 'incident',
                    start: Date.parse(inc.started_at ?? inc.created_at),
                    end: inc.resolved_at ? Date.parse(inc.resolved_at) : now,
                    ongoing: !inc.resolved_at,
                }))
                .filter(inc => !Number.isNaN(inc.start) && inc.rank > 0),
        };
    }
    const lower = scope.toLowerCase();
    const intervals = [];
    for (const inc of incidents ?? []) {
        const updates = [...(inc.incident_updates ?? [])]
            .sort((a, b) => Date.parse(a.created_at) - Date.parse(b.created_at));
        let open = null; // {rank, start}
        for (const u of updates) {
            const ac = (u.affected_components ?? []).find(c =>
                (c.name ?? '').toLowerCase().startsWith(lower));
            if (!ac)
                continue;
            const t = Date.parse(u.created_at);
            if (Number.isNaN(t))
                continue;
            const rank = STATUSPAGE_COMPONENT_RANK[ac.new_status] ?? 0;
            if (open && rank !== open.rank) {
                intervals.push({...open, name: inc.name ?? 'incident',
                    end: t, ongoing: false});
                open = null;
            }
            if (rank && !open)
                open = {rank, start: t};
        }
        if (open) {
            // Never transitioned back in the feed: closed at resolution,
            // or genuinely still open.
            intervals.push({...open, name: inc.name ?? 'incident',
                end: inc.resolved_at ? Date.parse(inc.resolved_at) : now,
                ongoing: !inc.resolved_at});
        }
    }
    return {intervals, covered};
}

// Resolve an incident.io scope to component ids: the members of the
// structure group named like it, plus any component whose own name
// contains it (catches "Codex in ChatGPT Desktop" living in the ChatGPT
// group). 'Everything' — or a scope matching nothing — is all components.
function incidentIoScopeIds(summary, scope) {
    const all = (summary?.components ?? []).map(c => c.id);
    if (!scope || scope === 'Everything')
        return new Set(all);
    const lower = scope.toLowerCase();
    const ids = new Set();
    for (const item of summary?.structure?.items ?? []) {
        if ((item.group?.name ?? '').toLowerCase() === lower) {
            for (const c of item.group.components ?? [])
                ids.add(c.component_id);
        }
    }
    for (const c of summary?.components ?? []) {
        if ((c.name ?? '').toLowerCase().includes(lower))
            ids.add(c.id);
    }
    return ids.size ? ids : new Set(all);
}

// incident.io native feed (<base>/incidents): one interval per
// component_impact window on a matching component — the same data the
// page's per-component uptime bars are drawn from.
function incidentIoIntervals(incidents, componentIds) {
    const now = Date.now();
    const intervals = [];
    for (const inc of incidents ?? []) {
        for (const imp of inc.component_impacts ?? []) {
            if (!componentIds.has(imp.component_id))
                continue;
            const rank = INCIDENTIO_STATUS_RANK[imp.status] ?? 0;
            const start = Date.parse(imp.start_at);
            if (!rank || Number.isNaN(start))
                continue;
            intervals.push({
                rank,
                name: inc.name ?? 'incident',
                start,
                end: imp.end_at ? Date.parse(imp.end_at) : now,
                ongoing: !imp.end_at,
            });
        }
    }
    return {
        intervals,
        covered: feedCoverage(incidents, inc => Date.parse(inc.published_at)),
    };
}

// One entry per day, oldest first: worst impact overlapping that day.
// Days are UTC, not local: the status pages bucket their uptime bars by
// UTC day, and matching them bar-for-bar is the whole point (a 03:28 UTC
// outage must land on the same day here as there).
function statusDays(intervals, numDays, covered) {
    const now = new Date();
    const days = [];
    for (let i = numDays - 1; i >= 0; i--) {
        const dayStart = Date.UTC(now.getUTCFullYear(), now.getUTCMonth(),
            now.getUTCDate() - i);
        const dayEnd = dayStart + 86400000;
        const hits = intervals.filter(iv => iv.start < dayEnd && iv.end >= dayStart);
        const worst = hits.reduce((m, iv) => Math.max(m, iv.rank), 0);
        days.push({
            date: new Date(dayStart).toLocaleDateString('en-US',
                {month: 'short', day: 'numeric', timeZone: 'UTC'}),
            sev: worst > 0 ? IMPACT_SEV[worst] : (dayEnd <= covered ? 'stale' : 'ok'),
            names: [...new Set(hits.filter(h => h.rank === worst).map(h => h.name))],
            count: new Set(hits.map(h => h.name)).size,
            ongoing: hits.some(h => h.ongoing),
        });
    }
    return days;
}

function statusTooltipText(day) {
    if (day.sev === 'stale')
        return `${day.date} · no incident data`;
    if (!day.count)
        return `${day.date} · operational`;
    let name = day.names[0] ?? 'incident';
    if (name.length > 48)
        name = `${name.slice(0, 47)}…`;
    const more = day.count > 1 ? ` (+${day.count - 1} more)` : '';
    return `${day.date} · ${name}${more}${day.ongoing ? ' · ongoing' : ''}`;
}

// Right-hand summary over the strip, from still-open impact intervals.
function currentStatus(intervals) {
    let worst = 0;
    for (const iv of intervals ?? []) {
        if (iv.ongoing)
            worst = Math.max(worst, iv.rank);
    }
    return [
        {text: 'Operational', sev: 'ok'},
        {text: 'Minor incident', sev: 'warn'},
        {text: 'Major incident', sev: 'crit'},
        {text: 'Critical incident', sev: 'crit'},
    ][worst];
}

// Codex limit-reset credits (usage.codexResetCredits, oauth source only):
// "N reset(s) available" + countdown to the nearest expiry. Null when the
// provider has none available.
function creditsInfo(row) {
    const rc = row.usage?.codexResetCredits;
    if (!rc)
        return null;
    const avail = (rc.credits ?? []).filter(c => c.status === 'available');
    const count = rc.availableCount ?? avail.length;
    if (!count)
        return null;
    const expiries = avail.map(c => Date.parse(c.expires_at)).filter(t => !Number.isNaN(t));
    let expiryLine = null;
    if (expiries.length) {
        const secs = (Math.min(...expiries) - Date.now()) / 1000;
        expiryLine = secs <= 0 ? 'Next expires now' : `Next expires in ${humanizeSecs(secs)}`;
    }
    return {
        text: count === 1 ? '1 reset available' : `${count} resets available`,
        expiryLine,
    };
}

const LEGEND_COLLAPSED_COUNT = 2;

// Colored legend under the chart: one dot + summed metric per model,
// largest first. Shows the top two in a row (plus a "+N" hint); hovering
// shows a floating table of every model ranked by share of the total
// (onHoverChange(anchor, rows)). Colors match the stacked bar segments
// above it. Null when no day carries a model breakdown.
function buildModelLegend(points, colors, onHoverChange) {
    const totals = new Map();
    for (const p of points) {
        for (const [name, v] of p.models)
            totals.set(name, (totals.get(name) ?? 0) + v);
    }
    if (!totals.size)
        return null;
    const useCost = points.some(p => p.cost !== null);
    const ordered = [...totals.entries()].sort((a, b) => b[1] - a[1]);
    const total = ordered.reduce((sum, [, v]) => sum + v, 0);
    const legend = new St.BoxLayout({
        style_class: 'usagebar-models',
        reactive: true,
        track_hover: true,
    });
    const entries = [];
    for (const [name, value] of ordered) {
        const entry = new St.BoxLayout({style_class: 'usagebar-model-entry'});
        entry.add_child(new St.Widget({
            style: `width: 8px; height: 8px; border-radius: 4px;` +
                `background-color: ${colors.get(name) ?? '#9a9996'};`,
            y_align: Clutter.ActorAlign.CENTER,
        }));
        const shown = useCost
            ? (fmtUSD(value) ?? `$${value.toFixed(1)}`)
            : `${fmtTokens(value)} tok`;
        entry.add_child(new St.Label({
            text: `${name.replace(/^claude-/, '')} ${shown}`,
            style_class: 'usagebar-dim',
            y_align: Clutter.ActorAlign.CENTER,
        }));
        legend.add_child(entry);
        entries.push(entry);
    }
    const hiddenCount = entries.length - LEGEND_COLLAPSED_COUNT;
    if (hiddenCount <= 0)
        return legend;
    const more = new St.Label({
        text: `+${hiddenCount}`,
        style_class: 'usagebar-dim',
        y_align: Clutter.ActorAlign.CENTER,
    });
    legend.add_child(more);
    entries.forEach((e, i) => {
        e.visible = i < LEGEND_COLLAPSED_COUNT;
    });
    const rows = ordered.map(([name, value]) => ({
        name: name.replace(/^claude-/, ''),
        color: colors.get(name) ?? '#9a9996',
        value: useCost
            ? (fmtUSD(value) ?? `$${value.toFixed(1)}`)
            : `${fmtTokens(value)} tok`,
        pct: total > 0 ? value / total * 100 : 0,
    }));
    legend.connect('notify::hover', () => {
        if (legend.hover)
            onHoverChange?.(legend, rows);
        else
            onHoverChange?.(null, null);
    });
    return legend;
}

// ---------- serve supervisor ----------

function findBinary() {
    const explicit = GLib.getenv('CODEXBAR_BIN');
    if (explicit && GLib.file_test(explicit, GLib.FileTest.IS_EXECUTABLE))
        return explicit;
    if (GLib.file_test(PACKAGED_BIN, GLib.FileTest.IS_EXECUTABLE))
        return PACKAGED_BIN;
    const inPath = GLib.find_program_in_path('codexbar');
    if (inPath)
        return inPath;
    for (const dir of [`${GLib.get_home_dir()}/.local/bin`,
        '/home/linuxbrew/.linuxbrew/bin', '/usr/local/bin']) {
        const p = `${dir}/codexbar`;
        if (GLib.file_test(p, GLib.FileTest.IS_EXECUTABLE))
            return p;
    }
    return null;
}

function freePort() {
    const listener = Gio.SocketListener.new();
    const port = listener.add_any_inet_port(null);
    listener.close();
    return port;
}

class ServeSupervisor {
    constructor(binary, interval, onState) {
        this._binary = binary;
        this._interval = interval;
        this._onState = onState; // (portOrNull, statusMessage)
        this._enabled = false;
        this._proc = null;
        this._restartId = 0;
        this._backoff = 2;
        this.port = 0;
    }

    // Serve only reads --refresh-interval at startup — bounce the child to
    // apply a new one (the exit handler is inert while _enabled is false).
    restart(interval) {
        this._interval = interval;
        this.stop();
        this.start();
    }

    start() {
        this._enabled = true;
        try {
            this.port = freePort();
        } catch (e) {
            this._onState(null, `no free loopback port: ${e.message}`);
            return;
        }
        this._spawn();
    }

    _spawn() {
        try {
            this._proc = Gio.Subprocess.new(
                [
                    this._binary, 'serve',
                    '--port', String(this.port),
                    '--refresh-interval', String(this._interval),
                    '--request-timeout', String(REQUEST_TIMEOUT_SECS),
                ],
                Gio.SubprocessFlags.STDOUT_SILENCE | Gio.SubprocessFlags.STDERR_SILENCE);
        } catch (e) {
            this._proc = null;
            this._onState(null, `failed to start codexbar serve: ${e.message}`);
            this._scheduleRestart();
            return;
        }
        this._proc.wait_async(null, (proc, res) => {
            try {
                proc.wait_finish(res);
            } catch {
                // cancelled or reaped — nothing to do
            }
            this._proc = null;
            if (this._enabled) {
                this._onState(null, 'codexbar serve exited — restarting…');
                this._scheduleRestart();
            }
        });
        // Readiness is handled by the fetch retry loop, not a /health gate.
        this._backoff = 2;
        this._onState(this.port, '');
    }

    _scheduleRestart() {
        if (!this._enabled || this._restartId)
            return;
        this._restartId = GLib.timeout_add_seconds(GLib.PRIORITY_DEFAULT, this._backoff, () => {
            this._restartId = 0;
            this._backoff = Math.min(this._backoff * 2, 30);
            if (this._enabled)
                this._spawn();
            return GLib.SOURCE_REMOVE;
        });
    }

    stop() {
        this._enabled = false;
        if (this._restartId) {
            GLib.source_remove(this._restartId);
            this._restartId = 0;
        }
        if (this._proc) {
            this._proc.force_exit();
            this._proc = null;
        }
    }
}

// ---------- self-update ----------
//
// The macOS app updates through Sparkle. Here, a .deb/.rpm install checks
// UsageBar's own GitHub releases, stages the matching package (sha256-verified)
// under the cache dir, and on "Install now" hands it to the package manager
// behind a pkexec password prompt. Extension and CLI update together, so the
// fork's CLI is never swapped for an upstream build. Dev installs (symlinked
// checkout, hand-installed CLI) update from git and get no updater.

const UPSTREAM_URL = 'https://github.com/steipete/CodexBar';
const UPDATE_FIRST_CHECK_SECS = 30;
const UPDATE_CHECK_SECS = 6 * 3600;

function runAsync(argv, cancellable) {
    return new Promise((resolve, reject) => {
        let proc;
        try {
            proc = Gio.Subprocess.new(argv,
                Gio.SubprocessFlags.STDOUT_PIPE | Gio.SubprocessFlags.STDERR_PIPE);
        } catch (e) {
            reject(e);
            return;
        }
        // Cancelling communicate() leaves the child running — kill it.
        const cancelId = cancellable?.connect(() => proc.force_exit()) ?? 0;
        proc.communicate_utf8_async(null, null, (p, res) => {
            if (cancelId)
                cancellable.disconnect(cancelId);
            try {
                const [, out, err] = p.communicate_utf8_finish(res);
                if (cancellable?.is_cancelled())
                    throw new Error('cancelled');
                if (!p.get_successful()) {
                    const why = (err ?? '').trim() || `exit ${p.get_exit_status()}`;
                    throw new Error(`${GLib.path_get_basename(argv[0])}: ${why}`);
                }
                resolve(out ?? '');
            } catch (e) {
                reject(e);
            }
        });
    });
}

// 'deb' or 'rpm' when this extension and its CLI came from the package,
// null for dev installs.
function packageFormat(extensionPath, binary) {
    if (binary !== PACKAGED_BIN || !extensionPath.startsWith('/usr/share/gnome-shell/extensions/'))
        return null;
    if (GLib.file_test('/var/lib/dpkg/info/usagebar.list', GLib.FileTest.EXISTS))
        return 'deb';
    if (GLib.find_program_in_path('rpm'))
        return 'rpm';
    return null;
}

class PackageUpdater {
    constructor(format, version, session, onReady) {
        this._format = format;
        this._version = version;
        this._session = session;
        this._onReady = onReady; // (version)
        this._cancellable = new Gio.Cancellable();
        this._stageRoot = GLib.build_filenamev(
            [GLib.get_user_cache_dir(), 'usagebar', 'update']);
        this._busy = false;
        this.ready = null; // {version, file} once a verified package is staged
    }

    async check() {
        if (this._busy)
            return;
        this._busy = true;
        try {
            const latest = latestUsageBarRelease(await this._fetchReleases());
            if (!latest || compareVersions(latest.version, this._version) <= 0)
                return;
            const file = await this._stage(latest.release, latest.version);
            this.ready = {version: latest.version, file};
            this._onReady(latest.version);
        } catch (e) {
            if (!this._cancellable.is_cancelled())
                console.warn(`usagebar: update check failed: ${e.message}`);
        } finally {
            this._busy = false;
        }
    }

    _fetchReleases() {
        return new Promise((resolve, reject) => {
            const msg = Soup.Message.new('GET', RELEASES_API);
            // GitHub rejects requests without a User-Agent.
            msg.request_headers.append('User-Agent', 'UsageBar-GNOME');
            msg.request_headers.append('Accept', 'application/vnd.github+json');
            this._session.send_and_read_async(msg, GLib.PRIORITY_LOW, this._cancellable,
                (session, res) => {
                    try {
                        const bytes = session.send_and_read_finish(res);
                        if (msg.get_status() !== Soup.Status.OK)
                            throw new Error(`GitHub HTTP ${msg.get_status()}`);
                        resolve(JSON.parse(new TextDecoder().decode(bytes.get_data())));
                    } catch (e) {
                        reject(e);
                    }
                });
        });
    }

    async _stage(release, version) {
        const c = this._cancellable;
        const machine = (await runAsync(['uname', '-m'], c)).trim();
        const name = packageAssetName(this._format, version, machine);
        if (!name)
            throw new Error(`no ${this._format} package for ${machine}`);
        const file = `${this._stageRoot}/${name}`;
        const marker = `${file}.verified`;
        if (GLib.file_test(marker, GLib.FileTest.EXISTS))
            return file;
        const assetUrl = n => release.assets?.find(a => a.name === n)?.browser_download_url;
        const url = assetUrl(name);
        const sumUrl = assetUrl(`${name}.sha256`);
        if (!url || !sumUrl)
            throw new Error(`release has no ${name}`);

        // A newer release supersedes anything staged before.
        await runAsync(['rm', '-rf', this._stageRoot], c);
        GLib.mkdir_with_parents(this._stageRoot, 0o755);
        // curl, not Soup: a large body shouldn't sit in the shell's heap.
        await runAsync(['curl', '-fsSL', '--max-time', '900', '-o', file, url], c);
        const expected = (await runAsync(['curl', '-fsSL', '--max-time', '60', sumUrl], c))
            .trim().split(/\s+/)[0];
        const actual = (await runAsync(['sha256sum', file], c)).trim().split(/\s+/)[0];
        if (!expected || expected !== actual)
            throw new Error(`checksum mismatch for ${name}`);
        GLib.file_set_contents(marker, version);
        return file;
    }

    // Install the staged package; the new code loads at the next login.
    async apply() {
        const ready = this.ready;
        if (!ready)
            throw new Error('no update staged');
        if (this._busy)
            throw new Error('update check in progress');
        this._busy = true;
        try {
            await runAsync(installCommand(this._format, ready.file), this._cancellable);
            this.ready = null;
            await runAsync(['rm', '-rf', this._stageRoot], this._cancellable).catch(() => {});
            return ready.version;
        } finally {
            this._busy = false;
        }
    }

    stop() {
        this._cancellable.cancel();
    }
}

// The CLI's version sits in a VERSION file beside the binary (the release
// tarball layout); `codexbar --version` reads the same file.
function cliVersion(binary) {
    try {
        const real = GLib.canonicalize_filename(binary, null);
        const target = GLib.file_test(real, GLib.FileTest.IS_SYMLINK)
            ? GLib.build_filenamev([GLib.path_get_dirname(real), GLib.file_read_link(real)])
            : real;
        const [, bytes] = GLib.file_get_contents(`${GLib.path_get_dirname(target)}/VERSION`);
        return new TextDecoder().decode(bytes).trim() || null;
    } catch {
        return null;
    }
}

// ---------- provider marks ----------

// Development checkouts carry provider logos in icons/. The build shipped to
// extensions.gnome.org leaves them out (third-party trademarks), and
// USAGEBAR_HIDE_PROVIDER_ICONS=1 simulates that for testing.
function providerLogo(dir, provider) {
    if (!dir || !provider || GLib.getenv('USAGEBAR_HIDE_PROVIDER_ICONS') === '1')
        return null;
    const file = dir.get_child('icons').get_child(`ProviderIcon-${provider}.svg`);
    try {
        return file.query_exists(null) ? new Gio.FileIcon({file}) : null;
    } catch {
        return null;
    }
}

// Brand-colored monogram badge standing in for a missing logo.
function providerMonogramActor(provider, size) {
    const badge = monogramBadge(PROVIDER_META[provider], provider, size);
    const actor = new St.Bin({
        style_class: 'usagebar-monogram',
        style: `background-color: ${badge.background}; border-radius: ${badge.radiusPx}px; ` +
            `min-width: ${size}px;`,
        height: size,
        y_align: Clutter.ActorAlign.CENTER,
        child: new St.Label({
            text: badge.text,
            style: `color: ${badge.foreground}; font-size: ${badge.fontPx}px; font-weight: bold;`,
            x_align: Clutter.ActorAlign.CENTER,
            y_align: Clutter.ActorAlign.CENTER,
        }),
    });
    actor._usagebarMonogram = badge.text;
    return actor;
}

// ---------- indicator ----------

const Indicator = GObject.registerClass(
class UsageBarIndicator extends PanelMenu.Button {
    _init(dir) {
        super._init(0.5, 'UsageBar', false);
        this._dir = dir;
        this._panelEntries = new Map();
        this._statusState = new StatusMessageState();
        this._panelIconCache = new LifetimeLookupCache(provider => providerLogo(this._dir, provider));

        this._chipBox = new St.BoxLayout({style_class: 'usagebar-panel-box'});
        this.add_child(this._chipBox);
        this._setPanelText([]);

        this.menu.box.add_style_class_name('usagebar-menu');
        // Header: title left, "updated Xs ago" then a refresh icon button right.
        const header = new PopupMenu.PopupBaseMenuItem({reactive: false, can_focus: false});
        header.add_child(new St.Label({
            text: 'UsageBar',
            style_class: 'usagebar-title',
            x_expand: true,
            y_align: Clutter.ActorAlign.CENTER,
        }));
        this._updatedLabel = new St.Label({
            text: '',
            style_class: 'usagebar-dim',
            y_align: Clutter.ActorAlign.CENTER,
        });
        header.add_child(this._updatedLabel);
        this._refreshButton = new St.Button({
            style_class: 'usagebar-btn usagebar-refresh-btn',
            can_focus: true,
            reactive: true,
            y_align: Clutter.ActorAlign.CENTER,
        });
        this._refreshIcon = new St.Icon({
            icon_name: 'view-refresh-symbolic',
            style_class: 'usagebar-btn-icon',
        });
        this._refreshIcon.set_pivot_point(0.5, 0.5);
        this._refreshButton.add_child(this._refreshIcon);
        this._refreshAnimationId = 0;
        header.add_child(this._refreshButton);
        this.menu.addMenuItem(header);

        // Status banner (serve problems, fetch errors).
        this._statusItem = new PopupMenu.PopupBaseMenuItem({reactive: false, can_focus: false});
        this._statusLabel = new St.Label({style_class: 'usagebar-banner', x_expand: true});
        this._statusLabel.clutter_text.line_wrap = true;
        this._statusItem.add_child(this._statusLabel);
        this._statusItem.visible = false;
        this.menu.addMenuItem(this._statusItem);

        // Providers | Machines. Shown only while this Machine is in a Sync
        // Group; otherwise the popover looks exactly as before.
        this._tabItem = new PopupMenu.PopupBaseMenuItem({reactive: false, can_focus: false});
        this._tabItem.add_style_class_name('usagebar-tab-item');
        const tabs = new St.BoxLayout({
            style_class: 'usagebar-ov-switch usagebar-tabs',
            x_expand: true,
            x_align: Clutter.ActorAlign.CENTER,
        });
        this._tabButtons = new Map();
        for (const [name, label, edge] of [['providers', 'Providers', 'left'], ['machines', 'Machines', 'right']]) {
            const button = new St.Button({
                label,
                can_focus: true,
                style_class: `usagebar-ov-switch-button usagebar-tab-button usagebar-ov-switch-${edge}`,
            });
            this._tabButtons.set(name, button);
            tabs.add_child(button);
        }
        this._tabItem.add_child(tabs);
        this._tabItem.visible = false;
        this.menu.addMenuItem(this._tabItem);

        const detailItem = new PopupMenu.PopupBaseMenuItem({reactive: false, can_focus: false});
        detailItem.add_style_class_name('usagebar-detail-item');
        this._detailBox = new St.BoxLayout({vertical: true, x_expand: true});
        detailItem.add_child(this._detailBox);
        this.menu.addMenuItem(detailItem);

        // Floating tooltip for chart-bar hover. Lives in the shell's UI
        // group so it can escape the menu; hidden with the menu and
        // destroyed with the indicator.
        this._tooltip = new St.Label({style_class: 'usagebar-tooltip', visible: false});
        Main.uiGroup.add_child(this._tooltip);
        // Floating model-share table shown while the chart legend is
        // hovered; same lifecycle as the tooltip.
        this._modelTable = new St.BoxLayout({
            vertical: true,
            style_class: 'usagebar-model-table',
            visible: false,
        });
        Main.uiGroup.add_child(this._modelTable);
        // Full cost dashboard shown while the All-view spend row is
        // hovered; same lifecycle as the tooltip.
        // It sits outside the menu, and the menu's grab closes the menu on
        // any press outside it — so while open the panel holds its own grab:
        // presses outside it (or Escape) close just the panel.
        this._costPanel = new St.Bin({visible: false});
        this._costGrab = null;
        Main.uiGroup.add_child(this._costPanel);
        this._costPanel.connect('captured-event', (actor, event) => {
            const type = event.type();
            const outside = (type === Clutter.EventType.BUTTON_PRESS ||
                type === Clutter.EventType.TOUCH_BEGIN) &&
                !actor.contains(global.stage.get_event_actor(event));
            const escape = type === Clutter.EventType.KEY_PRESS &&
                event.get_key_symbol() === Clutter.KEY_Escape;
            if (!outside && !escape)
                return Clutter.EVENT_PROPAGATE;
            this._closeCostPanel();
            return Clutter.EVENT_STOP;
        });
        this.menu.connect('open-state-changed', (_menu, open) => {
            if (!open) {
                this._tooltip?.hide();
                this._modelTable?.hide();
                this._closeCostPanel();
            }
        });
        this.connect('destroy', () => {
            this.setRefreshing(false);
            this._tooltip?.destroy();
            this._tooltip = null;
            this._modelTable?.destroy();
            this._modelTable = null;
            this._closeCostPanel();
            this._costPanel?.destroy();
            this._costPanel = null;
            for (const entry of this._panelEntries.values())
                entry.box.destroy();
            this._panelEntries.clear();
            this._panelIconCache.clear();
            this._panelEmptyLabel?.destroy();
            this._panelEmptyLabel = null;
        });

        // Footer, mirroring the macOS app menu. The update row only shows
        // once a verified package update is staged.
        this.menu.addMenuItem(new PopupMenu.PopupSeparatorMenuItem());
        const footerItem = (text, icon, accel) => {
            const item = new PopupMenu.PopupImageMenuItem(text, icon);
            item.add_style_class_name('usagebar-footer-item');
            if (accel) {
                item.add_child(new St.Label({
                    text: accel,
                    style_class: 'usagebar-accel',
                    x_expand: true,
                    x_align: Clutter.ActorAlign.END,
                    y_align: Clutter.ActorAlign.CENTER,
                }));
            }
            this.menu.addMenuItem(item);
            return item;
        };
        this._updateItem = footerItem('', 'software-update-available-symbolic');
        this._updateItem.visible = false;
        this._settingsItem = footerItem('Settings…', 'emblem-system-symbolic', 'Ctrl+,');
        this._aboutItem = footerItem('About UsageBar', 'help-about-symbolic');
        this._quitItem = footerItem('Quit', 'application-exit-symbolic', 'Ctrl+Q');

        // Accelerators, live while the menu holds the keyboard grab.
        const accels = {
            [Clutter.KEY_r]: event => this._refreshButton.emit('clicked', event),
            [Clutter.KEY_R]: event => this._refreshButton.emit('clicked', event),
            [Clutter.KEY_comma]: event => this._settingsItem.activate(event),
            [Clutter.KEY_q]: event => this._quitItem.activate(event),
            [Clutter.KEY_Q]: event => this._quitItem.activate(event),
        };
        this.menu.actor.connect('key-press-event', (_actor, event) => {
            const activate = accels[event.get_key_symbol()];
            if (!activate || !(event.get_state() & Clutter.ModifierType.CONTROL_MASK))
                return Clutter.EVENT_PROPAGATE;
            activate(event);
            return Clutter.EVENT_STOP;
        });
    }

    setAppTheme(theme) {
        const system = theme === 'system';
        for (const actor of [this.menu.box, this._tooltip, this._costPanel]) {
            if (system)
                actor.add_style_class_name('usagebar-theme-system');
            else
                actor.remove_style_class_name('usagebar-theme-system');
        }
    }

    setRefreshing(refreshing) {
        if (this._refreshAnimationId)
            GLib.source_remove(this._refreshAnimationId);
        this._refreshAnimationId = 0;
        this._refreshIcon.rotation_angle_z = 0;
        if (refreshing) {
            this._refreshAnimationStartedAt = GLib.get_monotonic_time();
            this._refreshAnimationId = GLib.timeout_add(GLib.PRIORITY_DEFAULT, 16, () => {
                const elapsed = (GLib.get_monotonic_time() - this._refreshAnimationStartedAt) / 1000;
                this._refreshIcon.rotation_angle_z = elapsed % 650 / 650 * 360;
                return GLib.SOURCE_CONTINUE;
            });
        }
    }

    setUpdateReady(version) {
        this._updateItem.visible = !!version;
        if (version)
            this._updateItem.label.text = updateReadyText(version);
    }

    _openCostPanel() {
        if (!this._costPanel)
            return;
        this._costPanel.show();
        this._costGrab ??= Main.pushModal(this._costPanel);
    }

    _closeCostPanel() {
        if (this._costGrab) {
            Main.popModal(this._costGrab);
            this._costGrab = null;
        }
        this._costPanel?.hide();
    }

    _panelIcon(provider) {
        return this._panelIconCache.get(provider);
    }

    _newPanelEntry(chip) {
        const entry = {
            provider: chip.provider,
            mode: chip.mode,
            hasText: !!chip.text,
            box: new St.BoxLayout({style_class: 'usagebar-chip'}),
            dot: null,
            ring: null,
            label: null,
            state: {percent: chip.percent, sev: chip.sev},
        };
        if (chip.mode === 'dot') {
            entry.dot = new St.Widget({
                style_class: `usagebar-dot usagebar-bg-${chip.sev}`,
                width: 8,
                height: 8,
                y_align: Clutter.ActorAlign.CENTER,
            });
            entry.box.add_child(entry.dot);
        } else {
            const gicon = this._panelIcon(chip.provider);
            entry.box.add_child(gicon
                ? new St.Icon({
                    gicon,
                    icon_size: 14,
                    style_class: 'usagebar-chip-icon',
                    y_align: Clutter.ActorAlign.CENTER,
                })
                : providerMonogramActor(chip.provider, 14));

            if (chip.mode !== 'percent') {
                entry.ring = new St.DrawingArea({
                    style_class: 'usagebar-chip-ring',
                    width: 14,
                    height: 14,
                    y_align: Clutter.ActorAlign.CENTER,
                });
                entry.ring.connect('repaint', area => {
                    const cr = area.get_context();
                    const [w, h] = area.get_surface_size();
                    if (w <= 0 || h <= 0) {
                        cr.$dispose();
                        return;
                    }
                    const xc = w / 2;
                    const yc = h / 2;
                    const lineWidth = 2.0;
                    const radius = Math.max(1, Math.min(w, h) / 2 - lineWidth / 2 - 0.5);

                    cr.arc(xc, yc, radius, 0, 2 * Math.PI);
                    cr.setSourceRGBA(1.0, 1.0, 1.0, 0.22);
                    cr.setLineWidth(lineWidth);
                    cr.stroke();

                    const {percent, sev} = entry.state;
                    if (percent > 0) {
                        const startAngle = -Math.PI / 2;
                        const progressFrac = Math.min(1.0, Math.max(0.0, percent / 100.0));
                        cr.arc(xc, yc, radius, startAngle,
                            startAngle + progressFrac * 2 * Math.PI);

                        let r = 0.18, g = 0.76, b = 0.49; // ok (#2ec27e)
                        if (sev === 'crit') {
                            r = 0.93; g = 0.20; b = 0.23; // crit (#ed333b)
                        } else if (sev === 'warn') {
                            r = 0.96; g = 0.76; b = 0.07; // warn (#f5c211)
                        } else if (sev === 'stale') {
                            r = 0.60; g = 0.60; b = 0.59; // stale (#9a9996)
                        }

                        cr.setSourceRGBA(r, g, b, 1.0);
                        cr.setLineWidth(lineWidth);
                        cr.setLineCap(1); // CAIRO_LINE_CAP_ROUND
                        cr.stroke();
                    }
                    cr.$dispose();
                });
                entry.box.add_child(entry.ring);
            }
        }

        if (chip.text) {
            entry.label = new St.Label({
                text: chip.text,
                style_class: 'usagebar-chip-label',
                y_align: Clutter.ActorAlign.CENTER,
            });
            entry.box.add_child(entry.label);
        }
        return entry;
    }

    _setPanelText(chips) {
        if (!chips.length) {
            for (const entry of this._panelEntries.values())
                entry.box.destroy();
            this._panelEntries.clear();
            if (!this._panelEmptyLabel) {
                this._panelEmptyLabel = new St.Label({
                    text: 'UB',
                    style_class: 'usagebar-chip-label',
                    y_align: Clutter.ActorAlign.CENTER,
                });
            }
            for (const child of this._chipBox.get_children())
                this._chipBox.remove_child(child);
            this._chipBox.add_child(this._panelEmptyLabel);
            return;
        }

        if (this._panelEmptyLabel?.get_parent() === this._chipBox)
            this._chipBox.remove_child(this._panelEmptyLabel);
        const wanted = new Set(chips.map(chip => chip.provider));
        for (const [provider, entry] of this._panelEntries) {
            if (!wanted.has(provider)) {
                entry.box.destroy();
                this._panelEntries.delete(provider);
            }
        }

        const ordered = [];
        for (const chip of chips) {
            let entry = this._panelEntries.get(chip.provider);
            const hasText = !!chip.text;
            if (entry && (entry.mode !== chip.mode || entry.hasText !== hasText)) {
                entry.box.destroy();
                this._panelEntries.delete(chip.provider);
                entry = null;
            }
            if (!entry) {
                entry = this._newPanelEntry(chip);
                this._panelEntries.set(chip.provider, entry);
            } else {
                entry.state.percent = chip.percent;
                entry.state.sev = chip.sev;
                if (entry.dot)
                    entry.dot.style_class = `usagebar-dot usagebar-bg-${chip.sev}`;
                if (entry.label)
                    entry.label.text = chip.text;
                entry.ring?.queue_repaint();
            }
            ordered.push(entry.box);
        }

        // Reparenting existing actors keeps their signal handlers and child
        // actors alive while still applying a changed provider order. Skip
        // even that small relayout when the identity/order is unchanged.
        const current = this._chipBox.get_children();
        const same = current.length === ordered.length &&
            current.every((child, i) => child === ordered[i]);
        if (!same) {
            for (const child of current)
                this._chipBox.remove_child(child);
            for (const child of ordered)
                this._chipBox.add_child(child);
        }
    }

    setStatus(message) {
        this._statusState.setTransient(message);
        this._syncStatus();
    }

    setPersistentStatus(message) {
        this._statusState.setPersistent(message);
        this._syncStatus();
    }

    _syncStatus() {
        const message = this._statusState.current;
        this._statusItem.visible = !!message;
        this._statusLabel.text = message ? `⚠ ${message}` : '';
    }

    setUpdated(text) {
        this._updatedLabel.text = text;
    }

    setTabs(visible, selected) {
        this._tabItem.visible = visible;
        for (const [name, button] of this._tabButtons) {
            if (name === selected)
                button.add_style_class_name('selected');
            else
                button.remove_style_class_name('selected');
        }
    }
});

// ---------- extension ----------

export default class UsageBarExtension extends Extension {
    enable() {
        this._generation = (this._generation ?? 0) + 1;
        const generation = this._generation;
        this._rows = [];
        this._names = {};
        this._namesVersion = 0;
        this._selectedProvider = null;
        this._notified = new Map();
        this._costs = null;
        this._costVersion = 0;
        this._costProviderVersions = new Map();
        this._costOverviewReports = {};
        this._costOverviewCache = new CostOverviewCache(2);
        this._costFetchedAt = 0;
        this._costInFlight = false;
        this._status = {};
        this._view = 'providers';
        this._sync = {
            payload: null,       // last good GET /sync/status answer
            paired: false,
            fetchError: null,    // serve itself didn't answer
            nextPushAt: 0,
            pushInFlight: false,
            readInFlight: false,
            lastReadAt: 0,
            pushError: null,
        };
        this._machinesRenderKey = null;
        this._lastFetchAt = 0;
        this._fetchId = 0;
        this._tickId = 0;
        this._popupDirty = true;
        this._popupView = null;
        this._detailRenderKey = null;
        this._overviewView = null;
        this._windowCatalogSignature = null;
        this._uiSmokeTimeoutIds = [];
        this._providerIconCache = new LifetimeLookupCache(provider => providerLogo(this.dir, provider));
        this._session = new Soup.Session({timeout: REQUEST_TIMEOUT_SECS + 10});
        this._cancellable = new Gio.Cancellable();
        this._renderScheduler = new RenderScheduler(
            callback => GLib.idle_add(GLib.PRIORITY_DEFAULT, () => {
                callback();
                return GLib.SOURCE_REMOVE;
            }),
            sourceId => GLib.source_remove(sourceId),
            () => {
                if (this._generation === generation && this._indicator)
                    this._render();
            });

        this._settings = this.getSettings();
        const applySettings = () => {
            DISPLAY.appTheme = this._settings.get_string('app-theme');
            THRESHOLDS.warn = this._settings.get_int('warn-threshold');
            THRESHOLDS.crit = this._settings.get_int('crit-threshold');
            DISPLAY.absoluteResets = this._settings.get_boolean('absolute-reset-times');
            DISPLAY.barsShowUsed = this._settings.get_boolean('bars-show-used');
            DISPLAY.sortAlphabetical = this._settings.get_boolean('sort-alphabetical');
            DISPLAY.providerOrder = this._settings.get_strv('provider-order');
            DISPLAY.mergeChips = this._settings.get_boolean('merge-chips');
            DISPLAY.resetWhenExhausted = this._settings.get_boolean('show-reset-when-exhausted');
            DISPLAY.chipMode = this._settings.get_string('chip-display-mode');
            DISPLAY.showExtras = this._settings.get_boolean('show-credits-extras');
            DISPLAY.antigravityOverviewGemini = this._settings.get_boolean('antigravity-overview-gemini');
            DISPLAY.hiddenChips = new Set(this._settings.get_strv('hidden-chips'));
            DISPLAY.hiddenWindows = new Set(this._settings.get_strv('hidden-windows'));
            DISPLAY.hiddenCostChartProviders = new Set(
                this._settings.get_strv('hidden-cost-chart-providers'));
        };
        applySettings();
        this._statusScopes = scopeMap(this._settings);
        // Keys whose change alters what's on screen; the rest (notify-*,
        // refresh knobs, the extension's own known-windows writes) skip the
        // full popover rebuild.
        const DISPLAY_KEYS = new Set([
            'warn-threshold', 'crit-threshold', 'absolute-reset-times',
            'bars-show-used', 'sort-alphabetical', 'provider-order', 'merge-chips',
            'show-reset-when-exhausted', 'chip-display-mode',
            'show-credits-extras', 'antigravity-overview-gemini', 'hidden-chips', 'hidden-windows',
            'hidden-cost-chart-providers',
            'status-scopes', 'status-checks-enabled',
        ]);
        this._settingsChangedId = this._settings.connect('changed', (_s, key) => {
            if (generation !== this._generation)
                return;
            applySettings();
            if (key === 'status-scopes' && this._status) {
                // Drop only rescoped providers' caches so they refetch.
                const next = scopeMap(this._settings);
                for (const p of new Set([...next.keys(), ...this._statusScopes.keys()])) {
                    if (next.get(p) !== this._statusScopes.get(p))
                        delete this._status[p];
                }
                this._statusScopes = next;
                this._fetchStatus();
            }
            if (key === 'status-checks-enabled') {
                if (this._settings.get_boolean(key))
                    this._fetchStatus();
                else
                    this._status = {}; // strips hide via the empty cache
            }
            if (key === 'refresh-interval-secs') {
                // The prefs spin row writes on every click — coalesce before
                // bouncing the serve child.
                if (this._restartDebounceId)
                    GLib.source_remove(this._restartDebounceId);
                this._restartDebounceId = GLib.timeout_add_seconds(
                    GLib.PRIORITY_DEFAULT, 2, () => {
                        this._restartDebounceId = 0;
                        if (generation !== this._generation || !this._indicator)
                            return GLib.SOURCE_REMOVE;
                        this._supervisor?.restart(
                            this._settings.get_int('refresh-interval-secs'));
                        return GLib.SOURCE_REMOVE;
                    });
            }
            if (key === 'app-theme')
                this._indicator?.setAppTheme(DISPLAY.appTheme);
            if (DISPLAY_KEYS.has(key))
                this._requestRender();
        });

        this._indicator = new Indicator(this.dir);
        this._indicator.setAppTheme(DISPLAY.appTheme);
        this._indicator._settingsItem.connect('activate', () => this.openPreferences());
        this._indicator._refreshButton.connect('clicked', () => this._fetchUsage(true));
        this._indicator._tabButtons.get('providers').connect('clicked', () => {
            this._view = 'providers';
            this._render();
        });
        this._indicator._tabButtons.get('machines').connect('clicked', () => {
            this._view = 'machines';
            this._syncTick();
            this._render();
        });
        this._indicator._aboutItem.connect('activate', () => this._showAbout());
        this._indicator._updateItem.connect('activate', () => this._applyUpdate());
        this._indicator._quitItem.connect('activate', () => {
            // Deferred: disabling destroys the menu emitting this signal.
            GLib.idle_add(GLib.PRIORITY_DEFAULT, () => {
                if (generation !== this._generation)
                    return GLib.SOURCE_REMOVE;
                Main.extensionManager.disableExtension(this.uuid);
                return GLib.SOURCE_REMOVE;
            });
        });
        this._indicator.menu.connect('open-state-changed', (_menu, open) => {
            if (open) {
                this._selectedProvider = null; // default to the All tab each open
                this._view = 'providers';
                this._syncTick();
                if (this._settings.get_boolean('refresh-on-open'))
                    this._fetchUsage();
                this._fetchCost();
                this._fetchStatus();
                this._render();
            }
        });
        Main.panel.addToStatusArea(this.uuid, this._indicator);

        const uiSmokeResult = GLib.getenv('USAGEBAR_UI_SMOKE_RESULT');
        if (uiSmokeResult)
            this._scheduleUISmoke(uiSmokeResult);

        const binary = findBinary();
        if (!binary) {
            this._indicator.setStatus('codexbar CLI not found — reinstall UsageBar from ' +
                'github.com/felipearosr/UsageBar/releases or set $CODEXBAR_BIN');
            this._render();
            return;
        }
        this._binary = binary;
        this._loadDisplayNames(binary);
        this._bootstrapProviders(binary);

        // Refetch when the CLI config changes — prefs toggles, terminal
        // `codexbar config enable`, hand edits alike. Serve re-reads the
        // config per request, so a fresh fetch is all it takes; display
        // names may be new too. Debounced: writers fire several events.
        try {
            this._configMonitor = Gio.File.new_for_path(GLib.build_filenamev(
                [GLib.get_user_config_dir(), 'codexbar', 'config.json']))
                .monitor_file(Gio.FileMonitorFlags.WATCH_MOVES, null);
            this._configMonitor.connect('changed', () => {
                if (generation !== this._generation || !this._indicator)
                    return;
                if (this._configDebounceId)
                    GLib.source_remove(this._configDebounceId);
                this._configDebounceId = GLib.timeout_add_seconds(
                    GLib.PRIORITY_DEFAULT, 1, () => {
                        this._configDebounceId = 0;
                        if (generation !== this._generation || !this._indicator)
                            return GLib.SOURCE_REMOVE;
                        this._loadDisplayNames(this._binary);
                        this._fetchUsage();
                        return GLib.SOURCE_REMOVE;
                    });
            });
        } catch {
            // no monitor — the regular poll still picks changes up
        }

        this._supervisor = new ServeSupervisor(binary,
            this._settings.get_int('refresh-interval-secs'), (port, status) => {
                if (generation !== this._generation || !this._indicator)
                    return;
                if (status)
                    this._indicator.setStatus(status);
                if (port)
                    this._scheduleFetch(2);
            });
        this._supervisor.start();

        const format = packageFormat(this.path, binary);
        const version = this.metadata['version-name'];
        if (format && version) {
            this._updater = new PackageUpdater(format, version, this._session, ready => {
                if (generation === this._generation)
                    this._indicator?.setUpdateReady(ready);
            });
        }
        this._updateToggleId = this._settings.connect('changed::update-check-enabled', () => {
            if (generation !== this._generation)
                return;
            if (this._settings.get_boolean('update-check-enabled'))
                this._scheduleUpdateCheck(5);
        });
        this._scheduleUpdateCheck(UPDATE_FIRST_CHECK_SECS);

        // Countdown/"updated ago" ticker while the menu is open.
        this._tickId = GLib.timeout_add_seconds(GLib.PRIORITY_DEFAULT, TICK_SECS, () => {
            if (this._indicator?.menu.isOpen) {
                // Keeps the Machines tab on the push cadence while it is open.
                this._syncTick();
                this._render();
            }
            return GLib.SOURCE_CONTINUE;
        });
    }

    disable() {
        this._generation = (this._generation ?? 0) + 1;
        this._renderScheduler?.cancel();
        this._renderScheduler = null;
        if (this._settingsChangedId) {
            this._settings.disconnect(this._settingsChangedId);
            this._settingsChangedId = 0;
        }
        if (this._updateToggleId) {
            this._settings.disconnect(this._updateToggleId);
            this._updateToggleId = 0;
        }
        if (this._updateCheckId) {
            GLib.source_remove(this._updateCheckId);
            this._updateCheckId = 0;
        }
        this._updater?.stop();
        this._updater = null;
        this._aboutDialog?.destroy();
        this._aboutDialog = null;
        this._settings = null;
        if (this._fetchId) {
            GLib.source_remove(this._fetchId);
            this._fetchId = 0;
        }
        this._fetchInFlight = false;
        this._costInFlight = false;
        if (this._tickId) {
            GLib.source_remove(this._tickId);
            this._tickId = 0;
        }
        if (this._restartDebounceId) {
            GLib.source_remove(this._restartDebounceId);
            this._restartDebounceId = 0;
        }
        for (const id of this._uiSmokeTimeoutIds ?? [])
            GLib.source_remove(id);
        this._uiSmokeTimeoutIds = [];
        if (this._configDebounceId) {
            GLib.source_remove(this._configDebounceId);
            this._configDebounceId = 0;
        }
        this._configMonitor?.cancel();
        this._configMonitor = null;
        this._cancellable?.cancel();
        this._cancellable = null;
        this._session?.abort();
        this._session = null;
        this._supervisor?.stop();
        this._supervisor = null;
        this._destroyOverviewView();
        this._indicator?.destroy();
        this._indicator = null;
        this._rows = [];
        this._notified = null;
        this._costs = null;
        this._costOverviewReports = null;
        this._costProviderVersions?.clear();
        this._costProviderVersions = null;
        this._costOverviewCache?.clear();
        this._costOverviewCache = null;
        this._status = null;
        this._sync = null;
        this._machinesRenderKey = null;
        this._overviewView = null;
        this._popupView = null;
        this._detailRenderKey = null;
        this._providerIconCache?.clear();
        this._providerIconCache = null;
    }

    _destroyOverviewView() {
        const view = this._overviewView;
        if (!view)
            return;
        this._indicator?._tooltip?.hide();
        this._indicator?._closeCostPanel();
        for (const child of view.rowsBox.get_children())
            view.rowsBox.remove_child(child);
        for (const state of view.rows.values()) {
            state.rowBox.destroy();
            state.separator?.destroy();
        }
        view.rows.clear();
        view.emptyLabel.destroy();
        view.summaryHost.destroy_all_children();
        view.container.destroy();
        this._overviewView = null;
    }

    // ----- footer actions -----

    _scheduleUpdateCheck(secs) {
        if (this._updateCheckId)
            GLib.source_remove(this._updateCheckId);
        const generation = this._generation;
        this._updateCheckId = GLib.timeout_add_seconds(GLib.PRIORITY_LOW, secs, () => {
            this._updateCheckId = 0;
            if (generation !== this._generation)
                return GLib.SOURCE_REMOVE;
            if (this._settings.get_boolean('update-check-enabled'))
                this._updater?.check();
            this._scheduleUpdateCheck(UPDATE_CHECK_SECS);
            return GLib.SOURCE_REMOVE;
        });
    }

    async _applyUpdate() {
        const generation = this._generation;
        this._indicator.setUpdateReady(null);
        this._indicator.setStatus('Installing UsageBar update…');
        try {
            const version = await this._updater.apply();
            if (generation !== this._generation || !this._indicator)
                return;
            const message = updateCompletionMessage(version);
            this._indicator.setStatus('');
            this._indicator.setPersistentStatus(message);
            Main.notify('UsageBar', message);
        } catch (e) {
            if (generation !== this._generation || !this._indicator)
                return;
            this._indicator.setStatus(`UsageBar update failed: ${e.message}`);
            if (this._updater?.ready)
                this._indicator.setUpdateReady(this._updater.ready.version);
        }
    }

    _showAbout() {
        this._aboutDialog?.destroy();
        const dialog = new ModalDialog.ModalDialog({destroyOnClose: true});
        this._aboutDialog = dialog;
        dialog.connect('destroy', () => {
            if (this._aboutDialog === dialog)
                this._aboutDialog = null;
        });
        const version = this.metadata['version-name'] ?? 'dev';
        const cli = this._binary ? cliVersion(this._binary) ?? 'unknown' : 'not found';
        dialog.contentLayout.add_child(new Dialog.MessageDialogContent({
            title: 'UsageBar',
            description: `Version ${version} · codexbar CLI ${cli}\n\n` +
                'AI coding-provider usage limits in the GNOME panel. ' +
                'Linux port of CodexBar by Peter Steinberger.',
        }));
        const link = (label, url) => ({
            label,
            action: () => {
                Gio.AppInfo.launch_default_for_uri(url, null);
                dialog.close();
            },
        });
        dialog.addButton(link('CodexBar', UPSTREAM_URL));
        dialog.addButton(link('UsageBar', this.metadata.url));
        dialog.addButton({
            label: 'Close',
            action: () => dialog.close(),
            default: true,
            key: Clutter.KEY_Escape,
        });
        dialog.open();
    }

    // ----- data -----

    // First run for this user: turn on the providers they're already signed
    // in to, and give claude the OAuth source it needs on Linux (the CLI's
    // default source drops per-model limits and the plan badge). Runs once;
    // an existing config keeps its provider choices.
    async _bootstrapProviders(binary) {
        const settings = this._settings;
        if (settings.get_boolean('providers-bootstrapped'))
            return;
        const home = GLib.get_home_dir();
        const configPath = GLib.build_filenamev(
            [GLib.get_user_config_dir(), 'codexbar', 'config.json']);
        const credentials = {
            claude: `${GLib.getenv('CLAUDE_CONFIG_DIR') ?? `${home}/.claude`}/.credentials.json`,
            codex: `${GLib.getenv('CODEX_HOME') ?? `${home}/.codex`}/auth.json`,
        };
        try {
            if (!GLib.file_test(configPath, GLib.FileTest.EXISTS)) {
                for (const [provider, path] of Object.entries(credentials)) {
                    if (GLib.file_test(path, GLib.FileTest.EXISTS))
                        await runAsync([binary, 'config', 'enable', '--provider', provider]);
                }
            }
            if (GLib.file_test(configPath, GLib.FileTest.EXISTS)) {
                const [, bytes] = GLib.file_get_contents(configPath);
                const next = withClaudeOAuth(JSON.parse(new TextDecoder().decode(bytes)));
                // 0600 like the CLI: the config can hold API keys.
                if (next) {
                    GLib.file_set_contents_full(configPath,
                        new TextEncoder().encode(`${JSON.stringify(next, null, 2)}\n`),
                        GLib.FileSetContentsFlags.CONSISTENT, 0o600);
                }
            }
            settings.set_boolean('providers-bootstrapped', true);
        } catch (e) {
            console.warn(`usagebar: provider setup failed: ${e.message}`);
        }
    }

    _loadDisplayNames(binary) {
        const generation = this._generation;
        try {
            const proc = Gio.Subprocess.new(
                [binary, 'config', 'providers', '--format', 'json'],
                Gio.SubprocessFlags.STDOUT_PIPE | Gio.SubprocessFlags.STDERR_SILENCE);
            proc.communicate_utf8_async(null, this._cancellable, (p, res) => {
                try {
                    if (generation !== this._generation || !this._indicator)
                        return;
                    const [, out] = p.communicate_utf8_finish(res);
                    let changed = false;
                    for (const entry of JSON.parse(out)) {
                        if (entry.displayName && this._names[entry.provider] !== entry.displayName) {
                            this._names[entry.provider] = entry.displayName;
                            changed = true;
                        }
                    }
                    if (changed)
                        this._namesVersion++;
                    this._requestRender();
                } catch {
                    // cosmetic only — fall back to capitalized ids
                }
            });
        } catch {
            // ignore
        }
    }

    _fetchJSON(url, cb, method = 'GET') {
        const generation = this._generation;
        const msg = Soup.Message.new(method, url);
        this._session.send_and_read_async(msg, GLib.PRIORITY_DEFAULT, this._cancellable,
            (session, res) => {
                try {
                    if (generation !== this._generation || !this._indicator)
                        return;
                    const bytes = session.send_and_read_finish(res);
                    if (msg.get_status() !== Soup.Status.OK) {
                        const error = new Error(`HTTP ${msg.get_status()}`);
                        error.status = msg.get_status();
                        try {
                            error.detail = JSON.parse(new TextDecoder().decode(bytes.get_data())).error;
                        } catch {
                            // no JSON error body
                        }
                        throw error;
                    }
                    cb(JSON.parse(new TextDecoder().decode(bytes.get_data())), null);
                } catch (e) {
                    cb(null, e);
                }
            });
    }

    _get(path, cb, method = 'GET') {
        const port = this._supervisor?.port;
        if (!port) {
            cb(null, new Error('serve not running'));
            return;
        }
        this._fetchJSON(`http://127.0.0.1:${port}${path}`, cb, method);
    }

    // ----- Machine Sync -----
    //
    // Serve does the work: POST /sync/push runs one push cycle (§8.1) and
    // GET /sync/status answers from its decrypted cache, pulling new blobs
    // first when asked with ?refresh=1. The cheap cache read on every tick
    // is how the popover learns whether this Machine is paired at all.

    _machinesTabVisible() {
        return !!(this._indicator?.menu.isOpen && this._view === 'machines' && this._sync?.paired);
    }

    _syncPlan() {
        const sync = this._sync;
        return planSyncTick({
            now: Date.now(),
            paired: sync.paired,
            tabVisible: this._machinesTabVisible(),
            nextPushAt: sync.nextPushAt,
            pushInFlight: sync.pushInFlight,
            lastReadAt: sync.lastReadAt,
            refreshedAt: Date.parse(sync.payload?.refreshedAt ?? '') || 0,
            readInFlight: sync.readInFlight,
        });
    }

    _syncTick() {
        const sync = this._sync;
        if (!sync || sync.readInFlight || this._syncFixture || !this._supervisor?.port)
            return;
        const plan = this._syncPlan();
        if (plan.push)
            this._syncPush();
        this._syncFetchStatus(plan.read);
    }

    _syncFetchStatus(refresh) {
        const sync = this._sync;
        sync.readInFlight = true;
        if (refresh)
            sync.lastReadAt = Date.now();
        this._get(refresh ? '/sync/status?refresh=1' : '/sync/status', (payload, error) => {
            if (this._sync !== sync)
                return;
            sync.readInFlight = false;
            if (error) {
                // Serve is down or restarting: keep the last good data.
                sync.fetchError = error;
                this._requestRender();
                return;
            }
            const wasPaired = sync.paired;
            sync.fetchError = null;
            sync.paired = !!payload?.paired;
            if (!sync.paired) {
                sync.payload = null;
                sync.nextPushAt = 0;
                sync.lastReadAt = 0;
            } else {
                // A cache-only read carries no error of its own; keep the one
                // from the last failed refresh until a read succeeds.
                if (!refresh && sync.payload?.error && payload.refreshedAt === sync.payload.refreshedAt)
                    payload.error = sync.payload.error;
                sync.payload = payload;
            }
            if (!refresh && sync.paired && !wasPaired) {
                // Just paired (or serve just started): push and read right away.
                const plan = this._syncPlan();
                if (plan.push)
                    this._syncPush();
                if (plan.read)
                    this._syncFetchStatus(true);
            }
            this._requestRender();
        });
    }

    _syncPush() {
        const sync = this._sync;
        sync.pushInFlight = true;
        sync.nextPushAt = Date.now() + nextPushDelaySecs() * 1000;
        this._get('/sync/push', (_result, error) => {
            if (this._sync !== sync)
                return;
            sync.pushInFlight = false;
            const message = error ? error.detail ?? error.message : null;
            if (message && message !== sync.pushError)
                console.warn(`usagebar: machine sync push failed: ${message}`);
            sync.pushError = message;
        }, 'POST');
    }

    _scheduleFetch(secs) {
        if (this._fetchId)
            GLib.source_remove(this._fetchId);
        const generation = this._generation;
        this._fetchId = GLib.timeout_add_seconds(GLib.PRIORITY_DEFAULT, secs, () => {
            this._fetchId = 0;
            if (generation !== this._generation)
                return GLib.SOURCE_REMOVE;
            // The refresh loop also drives Machine Sync pushes and reads.
            this._syncTick();
            this._fetchUsage();
            return GLib.SOURCE_REMOVE;
        });
    }

    _fetchUsage(force) {
        if (this._fetchInFlight)
            return;
        const generation = this._generation;
        this._fetchInFlight = true;
        if (force)
            this._indicator?.setRefreshing(true);
        // force asks serve to bypass its response cache (?fresh=1) so the
        // refresh button fetches live data even inside the cache TTL; older
        // CLIs without the flag just answer from cache as before.
        this._get(force ? '/usage?fresh=1' : '/usage', (rows, error) => {
            if (generation !== this._generation || !this._indicator)
                return;
            this._fetchInFlight = false;
            if (force)
                this._indicator.setRefreshing(false);
            if (error) {
                this._indicator.setStatus(`usage fetch failed: ${error.message}`);
                this._scheduleFetch(FETCH_RETRY_SECS);
            } else {
                this._rows = enrichAntigravityModels(mergeStale(this._rows, rows));
                this._lastFetchAt = Date.now();
                this._indicator.setStatus('');
                this._scheduleFetch(FETCH_OK_SECS);
                this._maybeNotify();
                this._publishWindowCatalog();
                // Warm the cost scan in the background so the chart is
                // ready before the menu opens (a cold scan takes tens of
                // seconds). TTL-gated, so this is a no-op most polls.
                this._fetchCost();
            }
            this._requestRender();
        });
    }

    _notify(title, body) {
        Main.notify(title, body);
        if (this._settings.get_boolean('notify-sound')) {
            global.display.get_sound_player()
                .play_from_theme('dialog-warning', 'UsageBar quota alert', null);
        }
    }

    // Quota warnings: one notification per crossed threshold per window per
    // reset cycle — session (short) and weekly (long) windows have their own
    // threshold lists, like the macOS app. Cycle identity is
    // provider+window+resetsAt, so a reset (new resetsAt) re-arms; keys
    // absent from the payload are pruned. The per-cycle memo stores the
    // highest threshold already announced (Infinity once fully escalated is
    // unnecessary — a higher crossing just compares numerically).
    //
    // Pace warnings ride the same cycle: when the backend projection says
    // the window won't last to reset (pace.willLastToReset === false),
    // notify once per cycle, tracked under a ":pace" memo key.
    _maybeNotify() {
        if (!this._settings.get_boolean('notify-enabled'))
            return;
        const muted = new Set(this._settings.get_strv('notify-muted-providers'));
        const sessionAt = this._settings.get_value('notify-session-thresholds').deepUnpack();
        const weeklyAt = this._settings.get_value('notify-weekly-thresholds').deepUnpack();
        const paceEnabled = this._settings.get_boolean('notify-pace-enabled');
        const seen = new Map();
        for (const row of this._rows) {
            if (row.stale || muted.has(row.provider))
                continue;
            const name = this._displayName(row.provider);
            const wins = [
                ...windowsOf(row).map(({w, slot}) =>
                    ({w, label: windowLabel(w.windowMinutes, slot),
                        pace: paceOf(row, slot)})),
                ...extraWindowsOf(row)
                    .filter(x => x.window.usedPercent !== null &&
                        x.window.usedPercent !== undefined)
                    .map(x => ({w: x.window, label: x.title ?? x.id, pace: null})),
            ];
            for (const {w, label, pace} of wins) {
                const cycle = `${row.provider}:${label}:${w.resetsAt ?? ''}`;
                const crossed = (isLongWindow(w) ? weeklyAt : sessionAt)
                    .filter(t => w.usedPercent >= t);
                const prev = this._notified.get(cycle);
                seen.set(cycle, prev);
                if (crossed.length) {
                    const highest = Math.max(...crossed);
                    if (prev === undefined || highest > prev) {
                        this._notify(`${name} ${label} at ${Math.round(w.usedPercent)}%`,
                            resetText(w) || 'usage limit approaching');
                        seen.set(cycle, highest);
                    }
                }
                const paceKey = `${cycle}:pace`;
                const pacePrev = this._notified.get(paceKey);
                seen.set(paceKey, pacePrev);
                if (paceEnabled && pace?.willLastToReset === false && !pacePrev) {
                    this._notify(`${name} ${label} won't last to reset`,
                        pace.summary ?? 'current pace exceeds the window');
                    seen.set(paceKey, true);
                }
            }
        }
        this._notified = seen;
    }

    // One /cost?provider= request per provider, in parallel. Scoped requests
    // skip the per-project breakdown the unscoped /cost builds (unused here,
    // and most of its scan time), and serve runs them concurrently instead
    // of one provider after another. Each report renders as it lands, so a
    // fast provider's bars don't wait on a slow one's scan.
    _fetchCost() {
        if (this._costInFlight || !this._rows.length)
            return;
        if (this._costs && (Date.now() - this._costFetchedAt) / 1000 < COST_TTL_SECS)
            return;
        const generation = this._generation;
        const providers = [...new Set(this._rows.map(r => r.provider))];
        this._costInFlight = true;
        let pending = providers.length;
        const done = () => {
            if (generation !== this._generation)
                return;
            if (--pending === 0) {
                this._costInFlight = false;
                this._costFetchedAt = Date.now();
            }
        };
        for (const provider of providers) {
            // Never asked of serve: its answer could overwrite the local report.
            if (LOCAL_COST_PROVIDERS.has(provider)) {
                this._fetchLocalCost(provider).finally(done);
                continue;
            }
            this._get(`/cost?provider=${encodeURIComponent(provider)}&days=${COST_HISTORY_DAYS}`,
                (reports, error) => {
                    if (generation !== this._generation || !this._indicator)
                        return; // disabled while in flight
                    if (!error && Array.isArray(reports)) // cost is best-effort
                        this._mergeCosts(reports);
                    done();
                });
        }
    }

    _mergeCosts(reports, generation = this._generation) {
        if (generation !== this._generation || !this._indicator)
            return;
        this._costProviderVersions ??= new Map();
        const next = [...(this._costs ?? [])];
        let overviewChanged = false;
        for (const report of reports) {
            const i = next.findIndex(c => c.provider === report.provider);
            const previous = i >= 0 ? next[i] : null;
            if (i >= 0)
                next[i] = report;
            else
                next.push(report);
            if (previous !== report) {
                this._costProviderVersions.set(
                    report.provider,
                    (this._costProviderVersions.get(report.provider) ?? 0) + 1);
                overviewChanged = overviewChanged || isPricedCostReport(previous) ||
                    isPricedCostReport(report);
            }
        }
        this._costs = next;
        if (overviewChanged) {
            this._costVersion++;
            this._costOverviewReports = {};
        }
        this._costOverview(); // prepare the small aggregation off the click path
        this._requestRender();
    }

    // Resolves either way — cost is best-effort.
    _fetchLocalCost(provider) {
        const generation = this._generation;
        const db = GLib.build_filenamev([GLib.get_user_data_dir(), 'opencode', 'opencode.db']);
        if (!GLib.file_test(db, GLib.FileTest.EXISTS))
            return Promise.resolve();
        return runAsync(['python3', '-c', OPENCODE_GO_COST_PY, db, String(COST_HISTORY_DAYS)],
            this._cancellable)
            .then(out => this._mergeCosts([JSON.parse(out)], generation))
            .catch(e => {
                if (generation === this._generation && !this._cancellable?.is_cancelled())
                    console.warn(`usagebar: ${provider} local cost failed: ${e.message}`);
            });
    }

    // Incident history for the status strips, straight from each provider's
    // public status page (the serve API doesn't carry status). Only enabled
    // providers (rows in the feed) are polled. Everything is best-effort.
    _fetchStatus() {
        if (!this._settings?.get_boolean('status-checks-enabled'))
            return;
        const generation = this._generation;
        const scopes = scopeMap(this._settings);
        for (const row of this._rows) {
            const provider = row.provider;
            const feed = PROVIDER_META[provider]?.statusFeed;
            if (!feed)
                continue;
            const cached = this._status[provider];
            if (cached && (Date.now() - cached.fetchedAt) / 1000 < STATUS_TTL_SECS)
                continue;
            const scope = scopes.get(provider) ?? defaultScope(provider);
            const done = result => {
                if (generation !== this._generation || !this._indicator || !this._status || !result)
                    return;
                this._status[provider] = {...result, scope, fetchedAt: Date.now()};
                this._requestRender();
            };
            if (feed.kind === 'statuspage') {
                this._fetchJSON(`${feed.base}/api/v2/incidents.json`, (data, error) =>
                    done(error ? null : statuspageIntervals(data.incidents, scope)));
            } else {
                // incident.io: the component/group structure lives in the
                // summary document, the impact windows in /incidents.
                this._fetchJSON(feed.base, (summary, error) => {
                    if (generation !== this._generation || error || !this._indicator)
                        return;
                    const ids = incidentIoScopeIds(summary.summary, scope);
                    this._fetchJSON(`${feed.base}/incidents`, (data, err2) =>
                        done(err2 ? null : incidentIoIntervals(data.incidents, ids)));
                });
            }
        }
    }

    // ----- rendering -----

    _requestRender() {
        this._renderScheduler?.request();
    }

    _scheduleUISmoke(resultPath) {
        const generation = this._generation;
        const later = (delay, callback) => {
            const id = GLib.timeout_add(GLib.PRIORITY_DEFAULT, delay, () => {
                this._uiSmokeTimeoutIds = this._uiSmokeTimeoutIds.filter(value => value !== id);
                if (generation === this._generation && this._indicator)
                    callback();
                return GLib.SOURCE_REMOVE;
            });
            this._uiSmokeTimeoutIds.push(id);
        };
        // Shell.Screenshot crashes a nested `gnome-shell --devkit`, so the
        // devkit runs the smoke with USAGEBAR_UI_SMOKE_SCREENSHOTS=0.
        const screenshots = GLib.getenv('USAGEBAR_UI_SMOKE_SCREENSHOTS') !== '0';
        const finish = (assertions, error = null) => {
            const failures = assertions.filter(assertion => !assertion.ok);
            const result = {
                ok: !error && failures.length === 0,
                assertions,
                ...(error ? {error: error.message ?? String(error)} : {}),
            };
            if (!screenshots) {
                GLib.file_set_contents(resultPath, JSON.stringify(result, null, 2));
                console.log(`usagebar-ui-smoke: ${result.ok ? 'PASS' : 'FAIL'}`);
                return;
            }
            const screenshotPath = GLib.build_filenamev([
                GLib.path_get_dirname(resultPath),
                'cost-dashboard.png',
            ]);
            try {
                const stream = Gio.File.new_for_path(screenshotPath).replace(
                    null,
                    false,
                    Gio.FileCreateFlags.REPLACE_DESTINATION,
                    null);
                const screenshot = new Shell.Screenshot();
                screenshot.screenshot(false, stream, (source, screenshotResult) => {
                    try {
                        source.screenshot_finish(screenshotResult);
                        stream.close(null);
                    } catch (screenshotError) {
                        result.ok = false;
                        result.screenshotError = screenshotError.message ?? String(screenshotError);
                    }
                    GLib.file_set_contents(resultPath, JSON.stringify(result, null, 2));
                    console.log(`usagebar-ui-smoke: ${result.ok ? 'PASS' : 'FAIL'}`);
                });
            } catch (screenshotError) {
                result.ok = false;
                result.screenshotError = screenshotError.message ?? String(screenshotError);
                GLib.file_set_contents(resultPath, JSON.stringify(result, null, 2));
                console.log('usagebar-ui-smoke: FAIL');
            }
        };
        const assertion = (name, ok, details = {}) => ({name, ok: Boolean(ok), ...details});
        // Extra full-stage screenshot next to the result; best-effort.
        const capture = (fileName, callback) => {
            if (!screenshots) {
                callback();
                return;
            }
            try {
                const stream = Gio.File.new_for_path(GLib.build_filenamev([
                    GLib.path_get_dirname(resultPath), fileName])).replace(
                    null, false, Gio.FileCreateFlags.REPLACE_DESTINATION, null);
                new Shell.Screenshot().screenshot(false, stream, (source, res) => {
                    try {
                        source.screenshot_finish(res);
                        stream.close(null);
                    } catch {
                        // ignored: only the final screenshot is required
                    }
                    callback();
                });
            } catch {
                callback();
            }
        };
        const painted = (name, actor) => {
            const [x, y] = actor?.get_transformed_position?.() ?? [0, 0];
            const state = {
                visible: actor?.visible ?? false,
                mapped: actor?.mapped ?? false,
                width: actor?.get_width?.() ?? 0,
                height: actor?.get_height?.() ?? 0,
                paintOpacity: actor?.get_paint_opacity?.() ?? 0,
                x,
                y,
            };
            const onStage = state.x < global.stage.width && state.y < global.stage.height &&
                state.x + state.width > 0 && state.y + state.height > 0;
            return assertion(name, state.visible && state.mapped && state.width > 0 &&
                state.height > 0 && state.paintOpacity > 0 && onStage, {...state, onStage});
        };

        // Machines tab against a fixed GET /sync/status payload: two Machines
        // active at once, then a failed refresh, then unpaired.
        const machinesSmoke = (assertions, done) => {
            const machinesBox = () => this._indicator._detailBox.get_children()
                .find(child => child._usagebarMachineCards);
            const iso = new Date().toISOString();
            const spend = costUSD => ({costUSD, costIncomplete: false, totalTokens: 0, requests: 0});
            const machine = (id, thisMachine, cost, provider) => ({
                machineId: id,
                displayName: id,
                isThisMachine: thisMachine,
                active: true,
                retired: false,
                lastSeen: iso,
                today: spend(cost / 3),
                last30Days: spend(cost),
                models: [{provider, model: `${id}-model`, spend: spend(cost)}],
                coverage: {from: '2026-06-25', to: '2026-09-24'},
            });
            this._indicator._closeCostPanel();
            this._syncFixture = true;
            this._sync.paired = true;
            this._sync.fetchError = null;
            this._sync.payload = {
                paired: true,
                refreshedAt: iso,
                status: {
                    total: {today: spend(10 / 3), last30Days: spend(10)},
                    errors: [],
                    machines: [machine('qa-laptop', true, 6, 'claude'), machine('qa-desk', false, 4, 'codex')],
                },
            };
            this._indicator.menu.open();
            this._indicator._tabButtons.get('machines').emit('clicked', 1);
            later(400, () => {
                try {
                    const box = machinesBox();
                    const cards = [...(box?._usagebarMachineCards?.values() ?? [])];
                    assertions.push(painted('Machines tab is painted', this._indicator._tabButtons.get('machines')));
                    assertions.push(assertion('Machines tab lists both Machines', cards.length === 2,
                        {actual: cards.length}));
                    cards.forEach((card, i) => assertions.push(painted(`Machine card ${i + 1} is painted`, card)));
                    assertions.push(assertion('both Machines show as active', cards.length === 2 &&
                        cards.every(card => card._usagebarDot.has_style_class_name('usagebar-machine-dot-active'))));
                    assertions.push(assertion('fresh data is not greyed',
                        box?._usagebarContent.opacity === 255));
                    assertions.push(noGenericIcons('Machines tab has no generic icons', box));
                    if (logosHidden) {
                        assertions.push(assertion('Machines tab shows monograms',
                            descendants(box).some(actor => actor._usagebarMonogram)));
                    }
                } catch (error) {
                    done(error);
                    return;
                }
                capture('machines-tab.png', () => {
                    this._sync.payload = {...this._sync.payload, error: "Couldn't reach the Sync Server"};
                    this._render();
                    later(200, () => {
                        try {
                            const staleBox = machinesBox();
                            assertions.push(assertion('failed refresh keeps the last good data',
                                staleBox?._usagebarMachineCards.size === 2));
                            assertions.push(assertion('stale data is greyed',
                                staleBox?._usagebarContent.opacity < 255,
                                {opacity: staleBox?._usagebarContent.opacity}));
                            assertions.push(assertion('stale data shows a banner', staleBox?.get_children()
                                .some(child => child.has_style_class_name?.('usagebar-machines-banner'))));
                        } catch (error) {
                            done(error);
                            return;
                        }
                        capture('machines-stale.png', () => {
                            try {
                                this._sync.paired = false;
                                this._sync.payload = null;
                                this._render();
                                assertions.push(assertion('tab strip is hidden when not paired',
                                    !this._indicator._tabItem.visible));
                                assertions.push(assertion('unpairing returns to the Providers tab',
                                    this._view === 'providers'));
                                this._indicator.menu.close();
                                this._syncFixture = false;
                                done();
                            } catch (error) {
                                done(error);
                            }
                        });
                    });
                });
            });
        };

        // Provider marks: logos when icons/ is present, brand-colored
        // monograms when it is not (USAGEBAR_HIDE_PROVIDER_ICONS=1).
        const logosHidden = GLib.getenv('USAGEBAR_HIDE_PROVIDER_ICONS') === '1';
        const descendants = actor => actor
            ? [actor, ...actor.get_children().flatMap(descendants)] : [];
        const noGenericIcons = (name, root) => assertion(name, !descendants(root).some(actor =>
            actor instanceof St.Icon && actor.icon_name === 'application-x-executable-symbolic'));
        const markSmoke = (assertions, done) => {
            const providers = ['claude', 'codex', 'opencodego', 'alibabatokenplan'];
            let marks;
            try {
                this._indicator._setPanelText(providers.map(provider => ({
                    provider, percent: 40, hasUsage: true, text: '40%', sev: 'ok', mode: 'ring-percent',
                })));
                // Checked before any live render can replace the fixture chips.
                marks = new Map(providers.map(provider => [provider,
                    this._indicator._panelEntries.get(provider)?.box.get_first_child()]));
                for (const [provider, mark] of marks) {
                    if (logosHidden || provider === 'alibabatokenplan') {
                        assertions.push(assertion(`${provider} panel chip shows a monogram`,
                            typeof mark?._usagebarMonogram === 'string' &&
                            mark._usagebarMonogram.length > 0,
                            {actual: mark?._usagebarMonogram ?? null}));
                    } else {
                        assertions.push(assertion(`${provider} panel chip shows its logo`,
                            mark instanceof St.Icon && !!mark.gicon));
                    }
                }
                assertions.push(noGenericIcons('panel chips have no generic icons',
                    this._indicator._chipBox));
            } catch (error) {
                done(error);
                return;
            }
            later(300, () => {
                try {
                    for (const [provider, mark] of marks)
                        assertions.push(painted(`${provider} panel mark is painted`, mark));
                } catch (error) {
                    done(error);
                    return;
                }
                capture(logosHidden ? 'panel-monograms.png' : 'panel-logos.png', () => {
                    this._indicator._setPanelText([]);
                    this._render();
                    done();
                });
            });
        };

        later(800, () => {
            const assertions = [];
            const steps = [markSmoke, machinesSmoke];
            const next = error => {
                if (error)
                    finish(assertions, error);
                else if (steps.length)
                    steps.shift()(assertions, next);
                else
                    costSmoke(assertions);
            };
            next();
        });

        const costSmoke = assertions => {
            try {
                const dates = buildCostDateRange(COST_HISTORY_DAYS);
                const providers = ['claude', 'codex', 'opencodego', 'gemini', 'cursor'];
                const compact = this._buildCompactRow({
                    provider: 'claude',
                    usage: {primary: {usedPercent: 25}},
                });
                assertions.push(assertion('overview row exposes a single details action',
                    compact._usagebarRowState.contentBtn?.reactive === true));
                assertions.push(assertion('overview row tracks hover',
                    compact._usagebarRowState.rowBox.reactive === true &&
                    compact._usagebarRowState.rowBox.track_hover === true));
                assertions.push(noGenericIcons('overview row has no generic icon', compact));
                if (logosHidden) {
                    assertions.push(assertion('overview row shows a monogram',
                        descendants(compact).some(actor => actor._usagebarMonogram)));
                }
                compact.destroy();
                const trendReport = {
                    historyDays: COST_HISTORY_DAYS,
                    daily: dates.map(date => ({
                        date, totalCost: 1, totalTokens: 1, modelBreakdowns: [],
                    })),
                };
                assertions.push(assertion('mini trend chart caps at 30 days',
                    chartPoints(trendReport).length === TREND_CHART_DAYS,
                    {actual: chartPoints(trendReport).length}));
                this._costs = providers.map((provider, providerIndex) => ({
                    provider,
                    source: 'qa-fixture',
                    totals: {totalCost: 1},
                    daily: dates.map((date, dateIndex) => {
                        const active = dateIndex % (providerIndex + 3) === 0;
                        const totalTokens = active ? (providerIndex + 1) * (dateIndex + 1) * 1000 : 0;
                        const totalCost = active ? totalTokens / (providerIndex + 2) / 10000 : 0;
                        return {
                            date,
                            totalCost,
                            totalTokens,
                            inputTokens: Math.round(totalTokens * 0.8),
                            outputTokens: Math.round(totalTokens * 0.2),
                            modelBreakdowns: active ? [{
                                modelName: `qa-model-${providerIndex + 1}`,
                                cost: totalCost,
                                totalTokens,
                            }] : [],
                        };
                    }),
                }));
                this._costVersion++;
                this._costOverviewReports = {};
                this._costOverviewCache.clear();
                const overview = this._costOverview(30);
                this._showCostPanel(this._indicator, overview, 30);

                later(500, () => {
                    try {
                        const refs = this._indicator._costPanel.child?._usagebarSmoke;
                        assertions.push(assertion('system theme is applied to the popover',
                            this._indicator.menu.box.has_style_class_name('usagebar-theme-system')));
                        assertions.push(assertion('system theme is applied to the cost panel',
                            this._indicator._costPanel.has_style_class_name('usagebar-theme-system')));
                        assertions.push(painted('cost panel is painted', refs?.panel));
                        assertions.push(painted('dashboard header is painted', refs?.header));
                        assertions.push(painted('day filter group is painted', refs?.rangeSwitch));
                        for (const days of [1, 7, 30, 90])
                            assertions.push(painted(`${days}-day filter is painted`, refs?.rangeButtons.get(days)));
                        assertions.push(painted('Cost tab is painted', refs?.metricButtons.get('cost')));
                        assertions.push(painted('Tokens tab is painted', refs?.metricButtons.get('tokens')));
                        assertions.push(painted('Model tab is painted', refs?.modelButton));
                        assertions.push(painted('Day tab is painted', refs?.dayButton));
                        assertions.push(noGenericIcons('cost dashboard has no generic icons',
                            this._indicator._costPanel));
                        if (logosHidden) {
                            assertions.push(assertion('cost dashboard legends show monograms',
                                descendants(this._indicator._costPanel)
                                    .some(actor => actor._usagebarMonogram)));
                        }
                        assertions.push(assertion('chart is capped at four providers',
                            refs?.chartProviderCount === 4,
                            {actual: refs?.chartProviderCount ?? null}));

                        refs.metricButtons.get('tokens').emit('clicked', 1);
                        refs.dayButton.emit('clicked', 1);
                        later(150, () => {
                            try {
                                assertions.push(assertion('Tokens tab changes the chart',
                                    refs.chartTitle.text === 'Daily tokens',
                                    {actual: refs.chartTitle.text}));
                                assertions.push(assertion('Day tab changes the breakdown',
                                    refs.dayTable.visible && !refs.modelTable.visible));
                                refs.rangeButtons.get(7).emit('clicked', 1);
                                later(250, () => {
                                    try {
                                        const next = this._indicator._costPanel.child?._usagebarSmoke;
                                        assertions.push(assertion('7-day filter changes the range',
                                            this._indicator._costPanel._usagebarRangeDays === 7));
                                        assertions.push(painted('selected 7-day filter remains painted',
                                            next?.rangeButtons.get(7)));
                                        finish(assertions);
                                    } catch (error) {
                                        finish(assertions, error);
                                    }
                                });
                            } catch (error) {
                                finish(assertions, error);
                            }
                        });
                    } catch (error) {
                        finish(assertions, error);
                    }
                });
            } catch (error) {
                finish(assertions, error);
            }
        };
    }

    _costOverview(rangeDays = 30) {
        if (!this._costs)
            return null;
        if (!this._costOverviewCache)
            return costOverview(this._costs, rangeDays);
        return this._costOverviewCache.get(
            this._costOverviewReports,
            this._costVersion,
            localDateKey(),
            () => costOverview(this._costs, rangeDays),
            String(rangeDays)
        );
    }

    _displayName(provider) {
        return this._names[provider] ?? PROVIDER_META[provider]?.name ??
            provider.charAt(0).toUpperCase() + provider.slice(1);
    }

    // Rows in display order (chips and popover share it).
    _sortedRows() {
        const rows = [...this._rows];
        if (DISPLAY.sortAlphabetical) {
            rows.sort((a, b) => this._displayName(a.provider)
                .localeCompare(this._displayName(b.provider)));
            return rows;
        }
        if (DISPLAY.providerOrder && DISPLAY.providerOrder.length > 0) {
            const orderMap = new Map(DISPLAY.providerOrder.map((p, i) => [p, i]));
            rows.sort((a, b) => {
                const posA = orderMap.has(a.provider) ? orderMap.get(a.provider) : 9999;
                const posB = orderMap.has(b.provider) ? orderMap.get(b.provider) : 9999;
                if (posA !== posB)
                    return posA - posB;
                return 0;
            });
        }
        return rows;
    }

    // One panel chip for a row, honoring the display mode ('ring',
    // 'ring-percent', 'percent', 'name-percent', 'dot') and the exhausted-shows-reset option.
    _chipFor(row) {
        const w = worstWindow(row);
        const worst = w?.usedPercent ?? null;
        const grey = row.stale || (row.error && worst === null);
        const mode = DISPLAY.chipMode;
        let text = '';
        if (mode === 'ring-percent' || mode === 'percent' || mode === 'name-percent') {
            let value = worst === null ? '—' : `${Math.round(worst)}%`;
            if (worst !== null && worst >= 100 && DISPLAY.resetWhenExhausted) {
                const secs = resetSecs(w);
                if (secs > 0)
                    value = humanizeSecs(secs);
            }
            text = mode === 'name-percent'
                ? `${this._displayName(row.provider)} ${value}` : value;
        }
        return {
            provider: row.provider,
            percent: worst ?? 0,
            hasUsage: worst !== null,
            text,
            sev: severity(worst ?? 0, grey),
            mode,
        };
    }

    _render() {
        if (!this._indicator)
            return;

        const rows = this._sortedRows();

        // Panel chips (minus providers hidden in prefs). Merged mode shows a
        // single chip for the provider with the highest worst-window percent.
        let chipRows = rows.filter(row => !DISPLAY.hiddenChips.has(row.provider));
        if (DISPLAY.mergeChips && chipRows.length > 1) {
            chipRows = [chipRows.reduce((best, row) =>
                (worstPercent(row) ?? -1) > (worstPercent(best) ?? -1) ? row : best)];
        }
        this._indicator._setPanelText(chipRows.map(row => this._chipFor(row)));

        this._indicator.setUpdated(this._lastFetchAt
            ? `updated ${agoText((Date.now() - this._lastFetchAt) / 1000)}`
            : 'fetching…');

        const machines = machinesView(this._sync?.payload, {
            now: Date.now(),
            fetchError: this._sync?.fetchError,
        });
        if (machines.hidden && this._view === 'machines')
            this._view = 'providers';
        this._indicator.setTabs(!machines.hidden, this._view);

        // A closed menu only needs the panel and state caches refreshed. The
        // retained overview is attached lazily on the next open, so a burst
        // of provider responses cannot build hidden cards or charts.
        if (!this._indicator.menu.isOpen) {
            this._popupDirty = true;
            return;
        }

        if (this._view === 'machines') {
            this._renderMachines(machines);
            this._popupDirty = false;
            return;
        }

        const selectedRow = rows.find(r => r.provider === this._selectedProvider) ?? null;
        if (selectedRow)
            this._renderDetail(selectedRow);
        else
            this._renderOverview(rows);
        this._popupDirty = false;
    }

    // Machines tab: every Machine in the Sync Group with an active dot, its
    // Spend today and over 30 days, its share, a provider/model breakdown,
    // and Coverage. Provider cards on the other tab stay this Machine only.
    _renderMachines(view) {
        const key = JSON.stringify(view);
        if (this._popupView === 'machines' && this._machinesRenderKey === key)
            return;
        const detail = this._indicator._detailBox;
        this._indicator._closeCostPanel();
        this._indicator._tooltip?.hide();
        this._hideModelTable();
        for (const child of detail.get_children()) {
            if (child === this._overviewView?.container)
                detail.remove_child(child);
            else
                child.destroy();
        }

        const box = new St.BoxLayout({
            vertical: true,
            x_expand: true,
            style_class: 'usagebar-machines',
        });
        if (view.banner) {
            const banner = new St.Label({
                text: `⚠ ${view.banner}`,
                style_class: 'usagebar-banner usagebar-machines-banner',
                x_expand: true,
            });
            banner.clutter_text.line_wrap = true;
            box.add_child(banner);
        }

        // Stale data stays readable but greyed out.
        const content = new St.BoxLayout({vertical: true, x_expand: true});
        if (view.stale) {
            content.add_style_class_name('usagebar-machines-stale');
            content.opacity = 128; // St CSS has no opacity property
        }
        box.add_child(content);

        if (view.loading || (!view.machines.length && !view.banner)) {
            content.add_child(new St.Label({
                text: view.loading ? 'Reading Machines…' : 'No Machines have synced yet.',
                style_class: 'usagebar-dim usagebar-detail-empty',
            }));
        }

        if (view.total && view.machines.length) {
            const head = new St.BoxLayout({x_expand: true, style_class: 'usagebar-machines-head'});
            head.add_child(new St.Label({
                text: 'All Machines',
                style_class: 'usagebar-card-title',
                x_expand: true,
                y_align: Clutter.ActorAlign.CENTER,
            }));
            head.add_child(new St.Label({
                text: `Today ${view.total.today} · 30 days ${view.total.last30}`,
                style_class: 'usagebar-dim',
                y_align: Clutter.ActorAlign.CENTER,
            }));
            content.add_child(head);
        }

        const refs = new Map();
        for (const machine of view.machines) {
            const card = this._buildMachineCard(machine);
            refs.set(machine.id, card);
            content.add_child(card);
        }

        if (view.errors) {
            content.add_child(new St.Label({
                text: `${view.errors} synced item${view.errors === 1 ? '' : 's'} couldn't be read.`,
                style_class: 'usagebar-dim usagebar-machines-note',
            }));
        }
        content.add_child(new St.Label({
            text: 'Cost on the Providers tab covers this Machine only.',
            style_class: 'usagebar-dim usagebar-machines-note',
        }));

        box._usagebarMachineCards = refs;
        box._usagebarContent = content;
        detail.add_child(box);
        this._popupView = 'machines';
        this._machinesRenderKey = key;
    }

    _buildMachineCard(machine) {
        const card = new St.BoxLayout({
            vertical: true,
            x_expand: true,
            style_class: 'usagebar-card usagebar-machine-card',
        });
        const head = new St.BoxLayout({x_expand: true, style_class: 'usagebar-machine-head'});
        const state = machine.retired ? 'retired' : machine.active ? 'active' : 'idle';
        const dot = new St.Widget({
            style_class: `usagebar-machine-dot usagebar-machine-dot-${state}`,
            y_align: Clutter.ActorAlign.CENTER,
        });
        card._usagebarDot = dot;
        head.add_child(dot);
        head.add_child(new St.Label({
            text: machine.name,
            style_class: 'usagebar-compact-title',
            y_align: Clutter.ActorAlign.CENTER,
        }));
        const tags = [];
        if (machine.thisMachine)
            tags.push('this Machine');
        if (machine.retired)
            tags.push('retired');
        else if (machine.active)
            tags.push('active');
        head.add_child(new St.Label({
            text: tags.join(' · '),
            style_class: 'usagebar-dim usagebar-machine-tags',
            x_expand: true,
            y_align: Clutter.ActorAlign.CENTER,
        }));
        if (machine.share !== null) {
            head.add_child(new St.Label({
                text: `${Math.round(machine.share * 100)}%`,
                style_class: 'usagebar-worst',
                y_align: Clutter.ActorAlign.CENTER,
            }));
        }
        card.add_child(head);

        card.add_child(new St.Label({
            text: `Today ${machine.today} · 30 days ${machine.last30}`,
            style_class: 'usagebar-machine-spend',
        }));

        for (const model of machine.models) {
            const row = new St.BoxLayout({x_expand: true, style_class: 'usagebar-machine-model'});
            const icon = this._providerIcon(model.provider, 12);
            if (icon)
                row.add_child(icon);
            row.add_child(new St.Label({
                text: model.model,
                style_class: 'usagebar-dim',
                x_expand: true,
                y_align: Clutter.ActorAlign.CENTER,
            }));
            row.add_child(new St.Label({
                text: model.spend,
                style_class: 'usagebar-dim',
                y_align: Clutter.ActorAlign.CENTER,
            }));
            card.add_child(row);
        }
        if (machine.moreModels) {
            card.add_child(new St.Label({
                text: `+${machine.moreModels} more`,
                style_class: 'usagebar-dim usagebar-machine-model',
            }));
        }

        card.add_child(new St.Label({
            text: [machine.coverage, machine.lastSeen].filter(Boolean).join(' · '),
            style_class: 'usagebar-dim usagebar-machine-foot',
        }));
        return card;
    }

    _detailPayloadKey(row) {
        const usage = row.usage ?? {};
        const windowKey = window => window ? {
            usedPercent: window.usedPercent,
            resetsAt: window.resetsAt,
            resetDescription: window.resetDescription,
            windowMinutes: window.windowMinutes,
            isSyntheticPlaceholder: !!window.isSyntheticPlaceholder,
        } : null;
        const resetCredits = usage.codexResetCredits;
        return JSON.stringify({
            provider: row.provider,
            stale: !!row.stale,
            error: row.error ? {
                kind: row.error.kind,
                message: row.error.message,
                code: row.error.code,
            } : null,
            usage: {
                loginMethod: usage.loginMethod,
                identityLoginMethod: usage.identity?.loginMethod,
                primary: windowKey(usage.primary),
                secondary: windowKey(usage.secondary),
                tertiary: windowKey(usage.tertiary),
                extras: extraWindowsOf(row).map(x => ({
                    id: x.id,
                    title: x.title,
                    window: windowKey(x.window),
                })),
                resetCredits: resetCredits ? {
                    availableCount: resetCredits.availableCount,
                    credits: (resetCredits.credits ?? []).map(c => ({
                        status: c.status,
                        expiresAt: c.expires_at,
                    })),
                } : null,
            },
            pace: [row.pace?.primary?.summary, row.pace?.secondary?.summary],
            creditsRemaining: row.credits?.remaining,
        });
    }

    _detailKey(row) {
        const provider = row.provider;
        const hidden = [...DISPLAY.hiddenWindows]
            .filter(key => key.startsWith(`${provider}:`))
            .sort()
            .join(',');
        const status = this._status?.[provider];
        const scope = this._statusScopes?.get(provider) ?? '';
        const costVersion = this._costProviderVersions?.get(provider) ?? 0;
        const timeBucket = Math.floor(Date.now() / 1000 / TICK_SECS);
        return [
            provider,
            this._detailPayloadKey(row),
            this._displayName(provider),
            DISPLAY.absoluteResets,
            DISPLAY.barsShowUsed,
            DISPLAY.showExtras,
            THRESHOLDS.warn,
            THRESHOLDS.crit,
            hidden,
            scope,
            status?.fetchedAt ?? 0,
            costVersion,
            localDateKey(),
            timeBucket,
        ].join('|');
    }

    _renderDetail(row) {
        const key = this._detailKey(row);
        if (this._popupView === `detail:${row.provider}` && this._detailRenderKey === key)
            return;
        const detail = this._indicator._detailBox;
        this._indicator._closeCostPanel();
        this._indicator._tooltip?.hide();
        this._hideModelTable();
        for (const child of detail.get_children()) {
            if (child === this._overviewView?.container)
                detail.remove_child(child);
            else
                child.destroy();
        }
        detail.add_child(this._buildCard(row, {flat: true, showBackButton: true}));
        this._popupView = `detail:${row.provider}`;
        this._detailRenderKey = key;
    }

    _overviewSummaryKey(overview) {
        if (!overview)
            return 'none';
        const names = overview.providers
            .map(provider => `${provider.provider}:${this._displayName(provider.provider)}`)
            .join('|');
        const hiddenChartProviders = [...DISPLAY.hiddenCostChartProviders].sort().join(',');
        return `${this._costVersion}:${localDateKey()}:${this._namesVersion}:${names}:${hiddenChartProviders}`;
    }

    _renderOverview(rows) {
        const detail = this._indicator._detailBox;
        this._indicator._tooltip?.hide();
        this._hideModelTable();
        let view = this._overviewView;
        if (!view) {
            const container = new St.BoxLayout({vertical: true, x_expand: true});
            view = {
                container,
                summaryHost: new St.BoxLayout({vertical: true, x_expand: true}),
                rowsBox: new St.BoxLayout({vertical: true, x_expand: true}),
                emptyLabel: new St.Label({
                    text: 'No usage data yet.',
                    style_class: 'usagebar-dim usagebar-detail-empty',
                }),
                rows: new Map(),
                summaryButton: null,
                summaryKey: null,
            };
            container.add_child(view.summaryHost);
            container.add_child(view.rowsBox);
            this._overviewView = view;
        }

        // Remove a detail card while keeping the overview container and all
        // its provider rows alive for an immediate back/reopen.
        for (const child of detail.get_children()) {
            if (child === view.container)
                continue;
            child.destroy();
        }
        if (view.container.get_parent() !== detail)
            detail.add_child(view.container);

        const overview = this._costOverview();
        const summaryKey = this._overviewSummaryKey(overview);
        if (view.summaryKey !== summaryKey) {
            view.summaryHost.destroy_all_children();
            view.summaryButton = null;
            if (overview) {
                view.summaryButton = this._buildCostSummary(overview);
                view.summaryHost.add_child(view.summaryButton);
                view.summaryHost.add_child(new St.Widget({
                    style_class: 'usagebar-separator usagebar-row-sep',
                    height: 1,
                    x_expand: true,
                }));
            }
            view.summaryKey = summaryKey;
        }

        const holder = this._indicator._costPanel;
        if (holder?.visible) {
            holder._usagebarAnchor = view.summaryButton;
            const rangeDays = holder._usagebarRangeDays ?? 30;
            const panelOverview = this._costOverview(rangeDays);
            const panelKey = this._overviewSummaryKey(panelOverview);
            if (holder._usagebarSummaryKey !== panelKey) {
                holder.child?.destroy();
                if (panelOverview) {
                    holder.set_child(this._buildCostPanel(
                        panelOverview,
                        holder._usagebarAnchor,
                        rangeDays));
                    holder._usagebarSummaryKey = panelKey;
                } else {
                    this._indicator._closeCostPanel();
                    holder._usagebarSummaryKey = null;
                }
            }
        }

        view.rows = reconcileKeyed(
            view.rows,
            rows,
            row => row.provider,
            row => this._buildCompactRow(row)._usagebarRowState,
            (state, row) => {
                const structureKey = this._compactRowStructureKey(row);
                if (state.structureKey !== structureKey) {
                    state.rowBox.destroy();
                    state.separator?.destroy();
                    const replacement = this._buildCompactRow(row)._usagebarRowState;
                    replacement.update(row);
                    return replacement;
                }
                state.update(row);
            },
            state => {
                state.rowBox.destroy();
                state.separator?.destroy();
            }
        );

        const desired = [];
        if (!rows.length) {
            desired.push(view.emptyLabel);
        } else {
            for (const [index, row] of rows.entries()) {
                const state = view.rows.get(row.provider);
                if (index > 0) {
                    state.separator ??= new St.Widget({
                        style_class: 'usagebar-separator usagebar-row-sep',
                        height: 1,
                        x_expand: true,
                    });
                    desired.push(state.separator);
                }
                desired.push(state.rowBox);
            }
        }
        const current = view.rowsBox.get_children();
        const same = current.length === desired.length &&
            current.every((child, i) => child === desired[i]);
        if (!same) {
            for (const child of current)
                view.rowsBox.remove_child(child);
            for (const child of desired)
                view.rowsBox.add_child(child);
        }
        this._popupView = 'all';
    }

    // Mini daily-trend bar chart (port of the macOS MiniUsageBars): equal
    // bars bottom-aligned over a 1px baseline, height scaled linearly to
    // the max value. When the report carries per-model
    // breakdowns, each bar is a stack of model-colored segments (largest
    // slice at the bottom); providers without pricing fall back to one
    // plain brand-colored bar.
    _buildTrendChart(points, brand, colors) {
        const wrap = new St.BoxLayout({vertical: true, x_expand: true, style_class: 'usagebar-chart-wrap'});
        const chart = new St.BoxLayout({x_expand: true, height: CHART_HEIGHT, style_class: 'usagebar-chart'});
        const max = Math.max(...points.map(p => p.value), 0);
        // Each day is a full-height reactive slot (so short bars are easy
        // to hover) holding the bottom-aligned stack.
        const slots = points.map(point => {
            const ratio = max > 0 && point.value > 0 ? Math.min(point.value / max, 1) : 0;
            const barH = ratio > 0 ? Math.max(3, Math.round(ratio * CHART_HEIGHT)) : 1;
            const stack = new St.BoxLayout({vertical: true});
            const segs = [];
            // Zero slices are dropped entirely.
            const slices = point.models.filter(([, v]) => v > 0).reverse();
            if (!slices.length) {
                const bar = new St.Widget({style_class: 'usagebar-chart-bar'});
                if (brand)
                    bar.set_style(`background-color: ${brand};`);
                stack.add_child(bar);
                segs.push({widget: bar, h: barH});
            } else {
                // Children pack top-down, so the slices run reversed —
                // smallest on top, largest resting on the baseline. Every
                // slice is at least MIN_SEG_H tall with a SEG_GAP gap between
                // neighbours; the stack grows past barH when the minimums
                // don't fit.
                const MIN_SEG_H = 2;
                const SEG_GAP = 1;
                const sum = slices.reduce((a, [, v]) => a + v, 0);
                const avail = Math.max(barH - SEG_GAP * (slices.length - 1), MIN_SEG_H * slices.length);
                const hs = slices.map(([, v]) => Math.max(MIN_SEG_H, Math.round(v / sum * avail)));
                // Settle rounding and minimum-height drift on the tallest slice.
                const big = hs.indexOf(Math.max(...hs));
                hs[big] = Math.max(MIN_SEG_H, hs[big] + avail - hs.reduce((a, h) => a + h, 0));
                stack.set_style(`spacing: ${SEG_GAP}px;`);
                slices.forEach(([name], i) => {
                    const seg = new St.Widget({style_class: 'usagebar-chart-bar'});
                    // Only the topmost (first-packed) segment keeps the
                    // rounded cap; the ones beneath it are square.
                    const radius = i > 0 ? ' border-radius: 0;' : '';
                    seg.set_style(`background-color: ${colors.get(name) ?? brand ?? '#9a9996'};${radius}`);
                    stack.add_child(seg);
                    segs.push({widget: seg, h: hs[i]});
                });
            }
            const slot = new St.BoxLayout({vertical: true, reactive: true, track_hover: true});
            slot.add_child(new St.Widget({y_expand: true}));
            slot.add_child(stack);
            slot._segs = segs;
            slot.connect('notify::hover', () => {
                if (slot.hover)
                    this._showTooltip(slot, chartTooltipText(point));
                else
                    this._indicator?._tooltip?.hide();
            });
            chart.add_child(slot);
            return slot;
        });
        chart.connect('notify::allocation', () => {
            const w = chart.allocation.get_width();
            if (w <= 0)
                return;
            const n = slots.length;
            const bw = Math.min(12, Math.max(2, Math.floor((w - 2 * (n - 1)) / n)));
            for (const slot of slots) {
                slot.set_width(bw);
                for (const s of slot._segs)
                    s.widget.set_size(bw, s.h);
            }
        });
        wrap.add_child(chart);
        wrap.add_child(new St.Widget({style_class: 'usagebar-chart-baseline', height: 1, x_expand: true}));
        return wrap;
    }

    _showTooltip(anchor, text) {
        const tip = this._indicator?._tooltip;
        if (!tip)
            return;
        tip.text = text;
        // The open menu is a later addition to uiGroup — restack or the
        // tooltip renders behind it.
        Main.uiGroup.set_child_above_sibling(tip, null);
        tip.show();
        const [ax, ay] = anchor.get_transformed_position();
        const [tw, th] = tip.get_size();
        const monitor = Main.layoutManager.currentMonitor;
        let x = Math.round(ax + anchor.get_width() / 2 - tw / 2);
        x = Math.max(monitor.x + 4, Math.min(x, monitor.x + monitor.width - tw - 4));
        tip.set_position(x, Math.round(ay - th - 6));
    }

    // Floating table of every model in the chart legend, ranked with its
    // share of the total. Shown beside the legend while it is hovered.
    _showModelTable(anchor, rows) {
        const table = this._indicator?._modelTable;
        if (!table)
            return;
        table.destroy_all_children();
        for (const row of rows) {
            const line = new St.BoxLayout({style_class: 'usagebar-model-table-row', x_expand: true});
            line.add_child(new St.Widget({
                style: `width: 8px; height: 8px; border-radius: 4px;` +
                    `background-color: ${row.color};`,
                y_align: Clutter.ActorAlign.CENTER,
            }));
            line.add_child(new St.Label({
                text: row.name,
                style_class: 'usagebar-dim',
                x_expand: true,
                y_align: Clutter.ActorAlign.CENTER,
            }));
            line.add_child(new St.Label({
                text: row.value,
                style_class: 'usagebar-model-table-value',
                x_align: Clutter.ActorAlign.END,
                y_align: Clutter.ActorAlign.CENTER,
            }));
            line.add_child(new St.Label({
                text: `${row.pct.toFixed(1)}%`,
                style_class: 'usagebar-model-table-pct',
                x_align: Clutter.ActorAlign.END,
                y_align: Clutter.ActorAlign.CENTER,
            }));
            table.add_child(line);
        }
        // The open menu is a later addition to uiGroup — restack or the
        // table renders behind it.
        Main.uiGroup.set_child_above_sibling(table, null);
        table.show();
        const [ax, ay] = anchor.get_transformed_position();
        const [, natW] = table.get_preferred_width(-1);
        const [, natH] = table.get_preferred_height(-1);
        const monitor = Main.layoutManager.currentMonitor;
        let x = Math.round(ax + anchor.get_width() + 10);
        if (x + natW > monitor.x + monitor.width - 8)
            x = Math.round(ax - natW - 10);
        const y = Math.max(monitor.y + 8,
            Math.min(Math.round(ay), monitor.y + monitor.height - natH - 8));
        table.set_position(x, y);
    }

    _hideModelTable() {
        this._indicator?._modelTable?.hide();
    }

    _providerIcon(provider, size) {
        this._providerIconCache ??= new LifetimeLookupCache(provider => providerLogo(this.dir, provider));
        const gicon = this._providerIconCache.get(provider);
        if (!gicon)
            return providerMonogramActor(provider, size);
        const icon = new St.Icon({
            icon_size: size,
            y_align: Clutter.ActorAlign.CENTER,
            gicon,
        });
        const color = PROVIDER_META[provider]?.color;
        if (color)
            icon.set_style(`color: ${color};`);
        return icon;
    }

    // Compact spend row for the All view: window total, a provider-colored
    // split bar and per-provider totals. Clicking it toggles the full cost
    // dashboard beside the menu.
    _buildCostSummary(ov) {
        const row = new St.BoxLayout({vertical: true, x_expand: true, style_class: 'usagebar-ov-summary'});
        const head = new St.BoxLayout({x_expand: true});
        head.add_child(new St.Label({
            text: `Spend · last ${ov.dates.length} days`,
            style_class: 'usagebar-compact-title',
            x_expand: true,
            y_align: Clutter.ActorAlign.CENTER,
        }));
        head.add_child(new St.Label({
            text: formatSummaryUSD(ov.cost),
            style_class: 'usagebar-kpi-value',
            y_align: Clutter.ActorAlign.CENTER,
        }));
        row.add_child(head);

        const split = new St.BoxLayout({x_expand: true, style_class: 'usagebar-ov-split'});
        const visibleProviders = ov.providers.filter(provider => provider.cost > 0);
        const segs = visibleProviders.map(provider => {
            const seg = new St.Widget({height: 4});
            split.add_child(seg);
            return [seg, provider];
        });
        split.connect('notify::allocation', () => {
            const w = split.allocation.get_width();
            const layout = buildSummaryBarSegments(visibleProviders, ov.cost, w);
            segs.forEach(([seg, provider], index) => {
                const {width, radius} = layout[index];
                seg.set_style(`background-color: ${provider.color}; border-radius: ${radius};`);
                if (seg.width !== width)
                    seg.set_width(width);
            });
        });
        row.add_child(split);

        const legend = new St.BoxLayout({style_class: 'usagebar-ov-summary-legend'});
        for (const p of ov.providers) {
            const entry = new St.BoxLayout({style_class: 'usagebar-model-entry'});
            entry.add_child(this._providerIcon(p.provider, 12));
            entry.add_child(new St.Label({
                text: `${this._displayName(p.provider)} ${formatSummaryUSD(p.cost)}`,
                style_class: 'usagebar-dim',
                y_align: Clutter.ActorAlign.CENTER,
            }));
            legend.add_child(entry);
        }
        row.add_child(legend);

        const button = new St.Button({
            child: row,
            x_expand: true,
            can_focus: true,
            style_class: 'usagebar-compact-row',
        });
        // Opens only: while the panel is open its grab turns a click here
        // into an outside press that closes it.
        button.connect('clicked', () => this._showCostPanel(button, ov));
        return button;
    }

    _showCostPanel(anchor, ov, rangeDays = 30) {
        const holder = this._indicator?._costPanel;
        if (!holder)
            return;
        holder.child?.destroy();
        holder.set_child(this._buildCostPanel(ov, anchor, rangeDays));
        holder._usagebarSummaryKey = this._overviewSummaryKey(ov);
        holder._usagebarRangeDays = rangeDays;
        holder._usagebarAnchor = anchor;
        Main.uiGroup.set_child_above_sibling(holder, null);
        this._indicator._openCostPanel();
        const [, pw] = holder.get_preferred_width(-1);
        const [, ph] = holder.get_preferred_height(pw);
        const [ax, ay] = anchor.get_transformed_position();
        const monitor = Main.layoutManager.currentMonitor;
        // Left of the menu when it fits, else to its right.
        let x = ax - pw - 16;
        if (x < monitor.x + 8)
            x = Math.min(ax + anchor.get_width() + 16, monitor.x + monitor.width - pw - 8);
        const y = Math.max(monitor.y + 8, Math.min(ay - 12, monitor.y + monitor.height - ph - 8));
        holder.set_position(Math.round(x), Math.round(y));
    }

    // The hover dashboard: range, total + per-provider split, a smoothed
    // daily cost line per provider, token KPIs and a per-model table.
    _buildCostPanel(ov, anchor, rangeDays) {
        const chartProviders = selectCostChartProviders(
            ov.providers,
            DISPLAY.hiddenCostChartProviders);
        const panel = new St.BoxLayout({vertical: true, style_class: 'usagebar-ov-panel'});
        const header = new St.BoxLayout({
            style_class: 'usagebar-ov-header',
            x_align: Clutter.ActorAlign.END,
        });
        const rangeSwitch = new St.BoxLayout({
            style_class: 'usagebar-ov-switch',
            y_align: Clutter.ActorAlign.CENTER,
        });
        const rangeButtons = new Map();
        costRangeOptions(rangeDays).forEach(option => {
            const edge = option.edge ? ` usagebar-ov-switch-${option.edge}` : '';
            const button = new St.Button({
                label: option.label,
                can_focus: true,
                style_class: `usagebar-ov-switch-button${edge}${option.selected ? ' selected' : ''}`,
            });
            button.connect('clicked', () => {
                if (option.selected)
                    return;
                const overview = this._costOverview(option.days);
                if (overview)
                    this._showCostPanel(anchor, overview, option.days);
            });
            rangeButtons.set(option.days, button);
            rangeSwitch.add_child(button);
        });
        header.add_child(rangeSwitch);
        panel.add_child(header);

        const top = new St.BoxLayout({style_class: 'usagebar-ov-top'});
        const left = new St.BoxLayout({vertical: true, width: OV_LEFT_WIDTH});
        left.add_child(new St.Label({text: 'RAW TOKEN COST', style_class: 'usagebar-ov-caption'}));
        left.add_child(new St.Label({text: `${fmtUSD(ov.cost)}*`, style_class: 'usagebar-ov-total'}));
        left.add_child(new St.Label({text: '* if billed at full API rate', style_class: 'usagebar-ov-small'}));
        for (const p of chartProviders) {
            const share = ov.cost > 0 ? p.cost / ov.cost : 0;
            const block = new St.BoxLayout({vertical: true, style_class: 'usagebar-ov-provider'});
            const head = new St.BoxLayout({style_class: 'usagebar-ov-provider-head'});
            head.add_child(this._providerIcon(p.provider, 16));
            head.add_child(new St.Label({
                text: this._displayName(p.provider),
                style_class: 'usagebar-ov-text',
                x_expand: true,
                y_align: Clutter.ActorAlign.CENTER,
            }));
            head.add_child(new St.Label({
                text: fmtUSD(p.cost),
                style_class: 'usagebar-ov-text',
                y_align: Clutter.ActorAlign.CENTER,
            }));
            block.add_child(head);
            const track = new St.BoxLayout({width: OV_LEFT_WIDTH, height: 4, style_class: 'usagebar-ov-track'});
            track.add_child(new St.Widget({
                width: Math.round(share * OV_LEFT_WIDTH),
                height: 4,
                style: `background-color: ${p.color};`,
            }));
            block.add_child(track);
            block.add_child(new St.Label({
                text: `${fmtPct(share)} of cost · ${fmtTokens(p.tokens)} tokens`,
                style_class: 'usagebar-ov-small',
            }));
            left.add_child(block);
        }
        top.add_child(left);

        const right = new St.BoxLayout({vertical: true, x_expand: true, style_class: 'usagebar-ov-right'});
        const chartHead = new St.BoxLayout({style_class: 'usagebar-ov-chart-head'});
        const chartTitle = new St.Label({
            text: 'Daily cost',
            style_class: 'usagebar-ov-heading',
            x_expand: true,
            y_align: Clutter.ActorAlign.CENTER,
        });
        chartHead.add_child(chartTitle);
        const metricSwitch = new St.BoxLayout({
            style_class: 'usagebar-ov-switch',
            y_align: Clutter.ActorAlign.CENTER,
        });
        const metricButtons = new Map();
        costChartMetricOptions().forEach(option => {
            const button = new St.Button({
                label: option.label,
                can_focus: true,
                style_class: `usagebar-ov-switch-button usagebar-ov-switch-${option.edge}`,
            });
            metricButtons.set(option.metric, button);
            metricSwitch.add_child(button);
        });
        chartHead.add_child(metricSwitch);
        for (const p of chartProviders) {
            const entry = new St.BoxLayout({style_class: 'usagebar-model-entry'});
            entry.add_child(this._providerIcon(p.provider, 12));
            entry.add_child(new St.Label({
                text: this._displayName(p.provider),
                style_class: 'usagebar-ov-small',
                y_align: Clutter.ActorAlign.CENTER,
            }));
            chartHead.add_child(entry);
        }
        right.add_child(chartHead);
        const chartHost = new St.BoxLayout({vertical: true, x_expand: true});
        right.add_child(chartHost);
        const selectMetric = metric => {
            const options = costChartMetricOptions(metric);
            const selected = options.find(option => option.selected);
            chartTitle.text = selected.title;
            chartHost.destroy_all_children();
            if (chartProviders.length) {
                chartHost.add_child(this._buildCostLineChart(ov, selected, chartProviders));
            } else {
                chartHost.add_child(new St.Label({
                    text: 'Choose providers in Settings → Providers',
                    style_class: 'usagebar-ov-small usagebar-ov-chart-empty',
                    x_align: Clutter.ActorAlign.CENTER,
                    x_expand: true,
                }));
            }
            for (const option of options) {
                metricButtons.get(option.metric).set_style_class_name(
                    `usagebar-ov-switch-button usagebar-ov-switch-${option.edge}` +
                    `${option.selected ? ' selected' : ''}`);
            }
        };
        for (const [metric, button] of metricButtons)
            button.connect('clicked', () => selectMetric(metric));
        selectMetric('cost');
        top.add_child(right);
        panel.add_child(top);

        const observed = ov.cached + ov.uncached + ov.writes;
        const kpis = new St.BoxLayout({x_expand: true, style_class: 'usagebar-ov-kpis'});
        [
            ['Processed tokens', fmtTokens(ov.tokens),
                `${fmtTokens(Math.round(ov.tokens / Math.max(1, ov.activeDays)))} per active day`],
            ['Cached input', fmtTokens(ov.cached), `${fmtPct(ov.cached / observed)} of observed input`],
            ['Uncached input', fmtTokens(ov.uncached), `${fmtTokens(ov.writes)} cache writes`],
            ['Output', fmtTokens(ov.output), `${fmtPct(ov.output / ov.tokens)} of processed`],
        ].forEach(([title, value, sub], i) => {
            const cell = new St.BoxLayout({
                vertical: true,
                x_expand: true,
                style_class: i ? 'usagebar-ov-kpi usagebar-ov-kpi-sep' : 'usagebar-ov-kpi',
            });
            cell.add_child(new St.Label({text: title, style_class: 'usagebar-ov-small'}));
            cell.add_child(new St.Label({text: value, style_class: 'usagebar-ov-kpi-value'}));
            cell.add_child(new St.Label({text: sub, style_class: 'usagebar-ov-small'}));
            kpis.add_child(cell);
        });
        panel.add_child(kpis);

        const breakdownHead = new St.BoxLayout({style_class: 'usagebar-ov-breakdown'});
        breakdownHead.add_child(new St.Label({
            text: 'Breakdown',
            style_class: 'usagebar-ov-heading',
            x_expand: true,
            y_align: Clutter.ActorAlign.CENTER,
        }));
        const breakdownSwitch = new St.BoxLayout({style_class: 'usagebar-ov-switch'});
        const modelButton = new St.Button({
            label: 'MODEL',
            can_focus: true,
            style_class: 'usagebar-ov-switch-button usagebar-ov-switch-left',
        });
        const dayButton = new St.Button({
            label: 'DAY',
            can_focus: true,
            style_class: 'usagebar-ov-switch-button usagebar-ov-switch-right',
        });
        breakdownSwitch.add_child(modelButton);
        breakdownSwitch.add_child(dayButton);
        breakdownHead.add_child(breakdownSwitch);
        panel.add_child(breakdownHead);

        const tableRow = (cells, cls) => {
            const r = new St.BoxLayout({style_class: cls});
            for (const c of cells)
                r.add_child(c);
            return r;
        };
        const num = (text, cls = 'usagebar-ov-text') => new St.Label({
            text,
            width: 96,
            style_class: `${cls} usagebar-ov-num`,
            y_align: Clutter.ActorAlign.CENTER,
        });

        const modelTable = new St.BoxLayout({vertical: true});
        modelTable.add_child(tableRow([
            new St.Label({text: 'Model', style_class: 'usagebar-ov-small', x_expand: true}),
            num('Cost', 'usagebar-ov-small'),
            num('Share', 'usagebar-ov-small'),
            num('Tokens', 'usagebar-ov-small'),
        ], 'usagebar-ov-table-head'));
        for (const m of ov.models.slice(0, OV_MAX_MODELS)) {
            const name = new St.BoxLayout({x_expand: true, style_class: 'usagebar-model-entry'});
            name.add_child(this._providerIcon(m.provider, 14));
            name.add_child(new St.Label({
                text: m.name,
                style_class: 'usagebar-ov-text',
                y_align: Clutter.ActorAlign.CENTER,
            }));
            modelTable.add_child(tableRow([
                name,
                num(fmtUSD(m.cost)),
                num(fmtPct(ov.cost > 0 ? m.cost / ov.cost : 0), 'usagebar-ov-dimtext'),
                num(fmtTokens(m.tokens), 'usagebar-ov-dimtext'),
            ], 'usagebar-ov-table-row'));
        }
        const hidden = ov.models.length - OV_MAX_MODELS;
        if (hidden > 0) {
            modelTable.add_child(new St.Label({
                text: `+${hidden} more models`,
                style_class: 'usagebar-ov-small usagebar-ov-more',
            }));
        }
        panel.add_child(modelTable);

        const dayTable = new St.BoxLayout({vertical: true});
        dayTable.add_child(tableRow([
            new St.Label({text: 'Day', style_class: 'usagebar-ov-small', x_expand: true}),
            ...ov.providers.map(p => num(this._displayName(p.provider), 'usagebar-ov-small')),
            num('Total', 'usagebar-ov-small'),
            num('Tokens', 'usagebar-ov-small'),
        ], 'usagebar-ov-table-head'));
        for (const day of ov.dailyRows.slice(0, OV_MAX_DAYS)) {
            dayTable.add_child(tableRow([
                new St.Label({
                    text: fmtDay(day.date),
                    style_class: 'usagebar-ov-text',
                    x_expand: true,
                    y_align: Clutter.ActorAlign.CENTER,
                }),
                ...day.costs.map(cost => num(fmtUSD(cost), 'usagebar-ov-dimtext')),
                num(fmtUSD(day.totalCost)),
                num(fmtTokens(day.totalTokens), 'usagebar-ov-dimtext'),
            ], 'usagebar-ov-table-row'));
        }
        const hiddenDays = ov.dailyRows.length - OV_MAX_DAYS;
        if (hiddenDays > 0) {
            dayTable.add_child(new St.Label({
                text: `+${hiddenDays} earlier active days`,
                style_class: 'usagebar-ov-small usagebar-ov-more',
            }));
        }
        dayTable.hide();
        panel.add_child(dayTable);

        const selectBreakdown = mode => {
            const modelSelected = mode === 'model';
            modelTable.visible = modelSelected;
            dayTable.visible = !modelSelected;
            modelButton.set_style_class_name(
                `usagebar-ov-switch-button usagebar-ov-switch-left${modelSelected ? ' selected' : ''}`);
            dayButton.set_style_class_name(
                `usagebar-ov-switch-button usagebar-ov-switch-right${modelSelected ? '' : ' selected'}`);
        };
        modelButton.connect('clicked', () => selectBreakdown('model'));
        dayButton.connect('clicked', () => selectBreakdown('day'));
        selectBreakdown('model');
        panel._usagebarSmoke = {
            panel,
            header,
            rangeSwitch,
            rangeButtons,
            metricButtons,
            chartTitle,
            modelButton,
            dayButton,
            modelTable,
            dayTable,
            chartProviderCount: chartProviders.length,
        };
        return panel;
    }

    // Daily cost as one smoothed, lightly filled line per provider over
    // three gridlines (0, half, nice max), dates along the bottom.
    _buildCostLineChart(ov, metric, providers) {
        const max = niceCeil(Math.max(0, ...providers.flatMap(p => p[metric.seriesKey])));
        const formatValue = metric.metric === 'tokens' ? fmtTokens : fmtUSD;
        const box = new St.BoxLayout({x_expand: true, style_class: 'usagebar-ov-chart'});
        // Axis labels sit on the gridlines: the plot's top/bottom insets
        // (PAD) match half a label's height.
        const PAD = 7;
        const axis = new St.BoxLayout({vertical: true, height: OV_CHART_HEIGHT, style_class: 'usagebar-ov-axis'});
        [formatValue(max), formatValue(max / 2), '0'].forEach((text, i) => {
            if (i > 0)
                axis.add_child(new St.Widget({y_expand: true}));
            axis.add_child(new St.Label({text, style_class: 'usagebar-ov-tick usagebar-ov-num'}));
        });
        box.add_child(axis);

        const plot = new St.BoxLayout({vertical: true, x_expand: true});
        const area = new St.DrawingArea({height: OV_CHART_HEIGHT, x_expand: true});
        area.connect('repaint', a => {
            const cr = a.get_context();
            const [w, h] = a.get_surface_size();
            const n = ov.dates.length;
            if (w <= 0 || h <= 0 || n < 1) {
                cr.$dispose();
                return;
            }
            const top = PAD;
            const bot = h - PAD;
            cr.setLineWidth(1);
            cr.setSourceRGBA(1, 1, 1, 0.12);
            for (const y of [top, (top + bot) / 2, bot]) {
                cr.moveTo(0, Math.round(y) + 0.5);
                cr.lineTo(w, Math.round(y) + 0.5);
                cr.stroke();
            }
            // Smallest provider drawn first so the biggest line sits on top.
            for (const p of [...providers].reverse()) {
                if (n === 1) {
                    const [r, g, b] = hexRGB(p.color);
                    const y = bot - Math.min(p[metric.seriesKey][0] / max, 1) * (bot - top);
                    cr.arc(w / 2, y, 3, 0, Math.PI * 2);
                    cr.setSourceRGBA(r, g, b, 1);
                    cr.fill();
                    continue;
                }
                const pts = p[metric.seriesKey].map((v, i) => [
                    1 + i * (w - 2) / (n - 1),
                    bot - Math.min(v / max, 1) * (bot - top),
                ]);
                const [r, g, b] = hexRGB(p.color);
                smoothPath(cr, pts, top, bot);
                cr.lineTo(pts[n - 1][0], bot);
                cr.lineTo(pts[0][0], bot);
                cr.closePath();
                cr.setSourceRGBA(r, g, b, 0.16);
                cr.fill();
                smoothPath(cr, pts, top, bot);
                cr.setSourceRGBA(r, g, b, 1);
                cr.setLineWidth(2);
                cr.stroke();
            }
            cr.$dispose();
        });
        plot.add_child(area);
        const dates = new St.BoxLayout({x_expand: true});
        if (ov.dates.length === 1) {
            dates.add_child(new St.Widget({x_expand: true}));
            dates.add_child(new St.Label({
                text: fmtDay(ov.dates[0]).toUpperCase(),
                style_class: 'usagebar-ov-tick',
            }));
            dates.add_child(new St.Widget({x_expand: true}));
        } else {
            const mid = ov.dates[Math.floor(ov.dates.length / 2)];
            [ov.dates[0], mid, ov.dates[ov.dates.length - 1]].forEach((d, i) => {
                if (i > 0)
                    dates.add_child(new St.Widget({x_expand: true}));
                dates.add_child(new St.Label({
                    text: fmtDay(d).toUpperCase(),
                    style_class: 'usagebar-ov-tick',
                }));
            });
        }
        plot.add_child(dates);
        box.add_child(plot);
        return box;
    }

    // Statuspage-style history strip: one same-height bar per day, colored
    // by that day's worst incident impact (green clean, yellow minor, red
    // major/critical, grey before the feed's coverage), hover tooltip with
    // the incident name. Null until the feed has been fetched.
    _buildStatusStrip(provider) {
        // No settings gate here: disabling status checks empties the cache.
        const cached = this._status?.[provider];
        if (!cached)
            return null;
        const wrap = new St.BoxLayout({
            vertical: true,
            x_expand: true,
            style_class: 'usagebar-status-wrap',
        });
        const head = new St.BoxLayout({x_expand: true});
        const scoped = cached.scope && cached.scope !== 'Everything';
        head.add_child(new St.Label({
            text: `${scoped ? `${cached.scope} status` : 'Status'} — last ${STATUS_DAYS} days`,
            style_class: 'usagebar-window-label',
        }));
        head.add_child(new St.Widget({x_expand: true}));
        const now = currentStatus(cached.intervals);
        head.add_child(new St.Label({
            text: now.text,
            style_class: `usagebar-status-now usagebar-fg-${now.sev}`,
        }));
        wrap.add_child(head);

        const strip = new St.BoxLayout({x_expand: true, style_class: 'usagebar-status-strip'});
        const bars = statusDays(cached.intervals, STATUS_DAYS, cached.covered).map(day => {
            // Small natural width: the request must fit the popover even
            // before the allocation-follow below grows bars to fill it.
            const bar = new St.Widget({
                style_class: `usagebar-status-day usagebar-bg-${day.sev}`,
                width: 2,
                height: STATUS_BAR_HEIGHT,
                reactive: true,
                track_hover: true,
            });
            bar.connect('notify::hover', () => {
                if (bar.hover)
                    this._showTooltip(bar, statusTooltipText(day));
                else
                    this._indicator?._tooltip?.hide();
            });
            strip.add_child(bar);
            return bar;
        });
        // Fill the card width: same allocation-follow as the trend chart
        // (the 2px gaps come from the strip's CSS spacing). Flooring the
        // width would leave a gap on the right, so spread the remainder
        // over the leading bars (+1px each — imperceptible).
        strip.connect('notify::allocation', () => {
            const w = strip.allocation.get_width();
            if (w <= 0)
                return;
            const avail = w - 2 * (bars.length - 1);
            const bw = Math.max(2, Math.floor(avail / bars.length));
            const rem = Math.max(0, avail - bw * bars.length);
            bars.forEach((bar, i) => bar.set_width(bw + (i < rem ? 1 : 0)));
        });
        wrap.add_child(strip);
        return wrap;
    }

    // One usage metric: window label, severity bar, then a two-line foot —
    // left column is "% used" over the pace verdict, right column is the reset
    // countdown over the pace ETA (when it runs out). Values are unchanged from
    // before; they're just relaid out. Handles unknown percent ("unavailable").
    _addWindowRow(card, label, w, stale, paceSummary) {
        const known = w.usedPercent !== null && w.usedPercent !== undefined;
        const percent = known ? Math.min(100, Math.max(0, w.usedPercent)) : 0;
        const sev = severity(percent, stale || !known);

        const labels = new St.BoxLayout({x_expand: true, style_class: 'usagebar-window-row'});
        labels.add_child(new St.Label({
            text: label,
            style_class: 'usagebar-window-label',
        }));
        labels.add_child(new St.Widget({x_expand: true}));
        card.add_child(labels);

        const track = new St.Widget({
            style_class: 'usagebar-track',
            width: BAR_WIDTH,
            height: 6,
        });
        const fill = new St.Widget({style_class: `usagebar-fill usagebar-bg-${sev}`});
        fill.set_size(Math.max(3, Math.round(BAR_WIDTH * percent / 100)), 6);
        track.add_child(fill);
        // The box layout stretches the track past BAR_WIDTH; size the fill
        // against the real allocation or the percentage reads short.
        track.connect('notify::allocation', () => {
            const w = track.allocation.get_width();
            if (w > 0)
                fill.set_size(Math.max(3, Math.round(w * percent / 100)), 6);
        });
        card.add_child(track);

        // The backend summary is "<verdict> | Expected N% used | <eta>"
        // (older builds use " · " and omit the middle). Keep the verdict for
        // the left column and the ETA for the right; the "expected" middle is
        // dropped, matching the macOS layout.
        let paceLeft = '';
        let paceRight = '';
        if (paceSummary) {
            const parts = paceSummary.replace(/^Pace:\s*/, '').split(/\s+[|·]\s+/);
            paceLeft = parts[0];
            if (parts.length > 1) {
                const eta = parts[parts.length - 1];
                paceRight = eta.charAt(0).toUpperCase() + eta.slice(1);
            }
        }

        const reset = resetText(w);
        const used = Math.max(0, Math.min(100, Math.round(w.usedPercent)));
        const percentText = !known ? T.unavailable
            : DISPLAY.barsShowUsed ? T.used(used) : T.remaining(100 - used);

        const foot = new St.BoxLayout({x_expand: true, style_class: 'usagebar-window-foot'});
        const leftCol = new St.BoxLayout({vertical: true});
        leftCol.add_child(new St.Label({
            text: percentText,
            style_class: 'usagebar-dim',
        }));
        if (paceLeft) {
            leftCol.add_child(new St.Label({
                text: paceLeft,
                style_class: 'usagebar-dim usagebar-pace',
            }));
        }
        foot.add_child(leftCol);
        foot.add_child(new St.Widget({x_expand: true}));
        const rightCol = new St.BoxLayout({vertical: true});
        if (reset) {
            rightCol.add_child(new St.Label({
                text: reset,
                style_class: 'usagebar-dim',
                x_expand: true,
                x_align: Clutter.ActorAlign.END,
            }));
        }
        if (paceRight) {
            rightCol.add_child(new St.Label({
                text: paceRight,
                style_class: 'usagebar-dim usagebar-pace',
                x_expand: true,
                x_align: Clutter.ActorAlign.END,
            }));
        }
        foot.add_child(rightCol);
        card.add_child(foot);
    }

    // Publish the set of bars that can currently render so the prefs window can
    // show one hide toggle per bar without fetching usage itself. Writes only on
    // change — set_strv with an equal value emits no 'changed', but guarding
    // also avoids a redundant render pass.
    _publishWindowCatalog() {
        if (!this._settings)
            return;
        const catalog = [];
        for (const row of this._rows) {
            for (const {w, slot} of windowsOf(row))
                catalog.push({p: row.provider, k: `w${slot}`, l: windowLabel(w.windowMinutes, slot)});
            for (const x of extraWindowsOf(row))
                catalog.push({p: row.provider, k: `x:${x.id ?? x.title}`, l: x.title ?? x.id});
        }
        const encoded = catalog.map(e => JSON.stringify(e));
        const signature = encoded.join('\u0000');
        if (signature === this._windowCatalogSignature)
            return;
        const prev = this._settings.get_strv('known-windows');
        this._windowCatalogSignature = signature;
        if (encoded.length !== prev.length || encoded.some((v, i) => v !== prev[i]))
            this._settings.set_strv('known-windows', encoded);
    }

    // flat: no card background; thin separator lines between sections
    // (usage | credits/cost | links) — used on the per-provider tabs.
    _buildCard(row, {showCost = true, flat = false, showLinks = true, showBackButton = false} = {}) {
        const card = new St.BoxLayout({
            vertical: true,
            style_class: flat ? 'usagebar-card-flat' : 'usagebar-card',
            x_expand: true,
        });
        const addSeparator = () => card.add_child(new St.Widget({
            style_class: 'usagebar-separator',
            height: 1,
            x_expand: true,
        }));
        const worst = worstPercent(row);
        const grey = row.stale || (row.error && worst === null);

        // Head: [back button] + [brand icon] + name + badges left, worst% right.
        const head = new St.BoxLayout({x_expand: true, style_class: 'usagebar-detail-head'});
        if (showBackButton) {
            const backBtn = new St.Button({
                style_class: 'usagebar-btn usagebar-back-btn',
                can_focus: true,
                reactive: true,
                y_align: Clutter.ActorAlign.CENTER,
            });
            backBtn.add_child(new St.Icon({
                icon_name: 'go-previous-symbolic',
                icon_size: 14,
                style_class: 'usagebar-btn-icon',
            }));
            backBtn.connect('clicked', () => {
                this._selectedProvider = null;
                this._render();
            });
            head.add_child(backBtn);
        }

        const iconWrap = new St.Bin({
            style_class: 'usagebar-compact-icon-wrap',
            y_align: Clutter.ActorAlign.CENTER,
            child: this._providerIcon(row.provider, 20),
        });
        head.add_child(iconWrap);

        head.add_child(new St.Label({
            text: this._displayName(row.provider),
            style_class: 'usagebar-card-title',
            y_align: Clutter.ActorAlign.CENTER,
        }));
        let plan = planOf(row);
        if (plan) {
            plan = plan.charAt(0).toUpperCase() + plan.slice(1);
            // Drop a leading provider name ("Claude Max" → "Max"): the card
            // title already says it.
            const name = this._displayName(row.provider);
            if (plan.toLowerCase().startsWith(`${name.toLowerCase()} `))
                plan = plan.slice(name.length + 1);
            head.add_child(new St.Label({
                text: plan,
                style_class: 'usagebar-badge',
                y_align: Clutter.ActorAlign.CENTER,
            }));
        }
        if (row.stale) {
            head.add_child(new St.Label({
                text: 'stale',
                style_class: 'usagebar-badge usagebar-badge-stale',
                y_align: Clutter.ActorAlign.CENTER,
            }));
        }
        head.add_child(new St.Widget({x_expand: true}));
        if (worst !== null) {
            head.add_child(new St.Label({
                text: `${Math.round(worst)}%`,
                style_class: `usagebar-worst usagebar-fg-${severity(worst, grey)}`,
                y_align: Clutter.ActorAlign.CENTER,
            }));
        }
        card.add_child(head);

        if (row.error) {
            const msg = row.error.message ?? 'provider fetch failed';
            const suffix = row.stale ? ' — showing last known data' : '';
            const banner = new St.Label({
                text: `⚠ ${msg}${suffix}`,
                style_class: 'usagebar-banner',
                x_expand: true,
            });
            banner.clutter_text.line_wrap = true;
            card.add_child(banner);
        }

        for (const {w, slot} of windowsOf(row)) {
            if (DISPLAY.hiddenWindows.has(barKey(row.provider, {slot})))
                continue;
            this._addWindowRow(card, windowLabel(w.windowMinutes, slot), w,
                row.stale, paceOf(row, slot)?.summary);
        }

        // Extra named limits (per-model bars like Fable, Daily Routines, Codex Spark, Antigravity models) —
        // rendered like the standard windows, as in the macOS card. The
        // show-credits-extras setting hides optional extras, but
        // provider-core extra quotas (like Antigravity, Codex Spark 5h, Claude Fable) are always shown.
        const showExtras = DISPLAY.showExtras || row.provider === 'antigravity' || row.provider === 'codex' || row.provider === 'claude';
        if (showExtras) {
            for (const x of extraWindowsOf(row)) {
                if (DISPLAY.hiddenWindows.has(barKey(row.provider, {extra: x})))
                    continue;
                this._addWindowRow(card, x.title ?? x.id, x.window, row.stale, null);
            }
        }

        const report = showCost
            ? (this._costs ?? []).find(c => c.provider === row.provider)
            : null;

        // Limit Reset Credits header (codex): count right-aligned, nearest
        // expiry below — matches the macOS card. Full card only, like cost.
        const credits = showCost && DISPLAY.showExtras ? creditsInfo(row) : null;
        const kpis = costKpis(report);
        const brand = PROVIDER_META[row.provider]?.color;
        const trend = chartPoints(report);
        const colors = trend ? modelColorsFromPoints(trend, brand) : new Map();
        const legend = trend ? buildModelLegend(trend, colors, (anchor, rows) => {
            if (anchor)
                this._showModelTable(anchor, rows);
            else
                this._hideModelTable();
        }) : null;
        if (flat && (credits || kpis || legend))
            addSeparator();
        if (credits) {
            const head = new St.BoxLayout({x_expand: true, style_class: 'usagebar-credits'});
            head.add_child(new St.Label({text: 'Limit Reset Credits', style_class: 'usagebar-window-label'}));
            head.add_child(new St.Widget({x_expand: true}));
            head.add_child(new St.Label({text: credits.text, style_class: 'usagebar-credits-count'}));
            card.add_child(head);
            if (credits.expiryLine)
                card.add_child(new St.Label({text: credits.expiryLine, style_class: 'usagebar-dim'}));
        }

        // Generic credits balance (row.credits.remaining — Cursor on-demand
        // budget and the like), distinct from codex's reset credits above.
        const balance = showCost && DISPLAY.showExtras ? row.credits?.remaining : null;
        if (balance !== null && balance !== undefined) {
            const head = new St.BoxLayout({x_expand: true, style_class: 'usagebar-credits'});
            head.add_child(new St.Label({text: 'Credits', style_class: 'usagebar-window-label'}));
            head.add_child(new St.Widget({x_expand: true}));
            head.add_child(new St.Label({
                text: fmtUSD(balance) ?? String(balance),
                style_class: 'usagebar-credits-count',
            }));
            card.add_child(head);
        }

        if (kpis) {
            for (let i = 0; i < kpis.length; i += 2) {
                const kpiRow = new St.BoxLayout({x_expand: true, style_class: 'usagebar-kpi-row'});
                kpis.slice(i, i + 2).forEach((kpi, col) => {
                    // Fixed-width left column so the right column lines up
                    // across rows (natural widths differ per label).
                    const cell = new St.BoxLayout({
                        vertical: true,
                        ...(col === 0 ? {width: KPI_COL_WIDTH} : {x_expand: true}),
                    });
                    cell.add_child(new St.Label({text: kpi.title, style_class: 'usagebar-dim'}));
                    cell.add_child(new St.Label({text: kpi.value, style_class: 'usagebar-kpi-value'}));
                    kpiRow.add_child(cell);
                });
                card.add_child(kpiRow);
            }
        }
        if (trend)
            card.add_child(this._buildTrendChart(trend, brand, colors));

        if (legend)
            card.add_child(legend);
        if (report && COST_HINTS[row.provider]) {
            const hintLabel = new St.Label({
                text: COST_HINTS[row.provider],
                style_class: 'usagebar-dim usagebar-hint',
            });
            hintLabel.clutter_text.line_wrap = true;
            card.add_child(hintLabel);
        }

        const urls = showLinks ? providerLinks(row) : null;
        // Status strip and links only on the detail tabs — All stays compact.
        const statusStrip = showCost ? this._buildStatusStrip(row.provider) : null;
        if (flat && (urls || statusStrip))
            addSeparator();
        if (statusStrip)
            card.add_child(statusStrip);
        if (urls) {
            const links = new St.BoxLayout({style_class: 'usagebar-links'});
            for (const [label, url] of [['Dashboard', urls.dashboard], ['Status', urls.status]]) {
                if (!url)
                    continue;
                const btn = new St.Button({
                    label,
                    style_class: 'usagebar-link',
                    y_align: Clutter.ActorAlign.CENTER,
                });
                btn.connect('clicked', () => {
                    Gio.AppInfo.launch_default_for_uri(url, null);
                    this._indicator.menu.close();
                });
                links.add_child(btn);
            }
            card.add_child(links);
        }

        return card;
    }

    _compactDisplayItems(row) {
        const items = [];
        for (const {w, slot} of windowsOf(row)) {
            if (DISPLAY.hiddenWindows.has(barKey(row.provider, {slot})))
                continue;
            items.push({
                label: compactWindowLabel(windowLabel(w.windowMinutes, slot)),
                w,
            });
        }

        const extras = extraWindowsOf(row);
        if (row.provider === 'antigravity') {
            const useGemini = DISPLAY.antigravityOverviewGemini !== false;
            for (const x of extras) {
                if (DISPLAY.hiddenWindows.has(barKey(row.provider, {extra: x})))
                    continue;
                const isGemini = x.id.includes('gemini');
                if ((useGemini && isGemini) || (!useGemini && !isGemini))
                    items.push({label: compactWindowLabel(x.title ?? x.id), w: x.window});
            }
        } else if (row.provider === 'codex') {
            const has5h = items.some(it => it.label === '5h');
            for (const x of extras) {
                if (DISPLAY.hiddenWindows.has(barKey(row.provider, {extra: x})))
                    continue;
                const label = compactWindowLabel(x.title ?? x.id);
                if (!has5h && label === '5h')
                    items.unshift({label, w: x.window});
                else if (DISPLAY.showExtras)
                    items.push({label, w: x.window});
            }
        } else if (row.provider === 'claude') {
            for (const x of extras) {
                if (DISPLAY.hiddenWindows.has(barKey(row.provider, {extra: x})))
                    continue;
                const isRoutine = x.id === 'claude-routines' ||
                    (x.id && x.id.includes('routine')) ||
                    (x.title && x.title.toLowerCase().includes('routine'));
                if (isRoutine)
                    continue;
                const label = compactWindowLabel(x.title ?? x.id);
                if (label === 'Fable' || DISPLAY.showExtras)
                    items.push({label, w: x.window});
            }
        } else if (DISPLAY.showExtras) {
            for (const x of extras) {
                if (DISPLAY.hiddenWindows.has(barKey(row.provider, {extra: x})))
                    continue;
                items.push({label: compactWindowLabel(x.title ?? x.id), w: x.window});
            }
        }

        const displayItems = [];
        const seenLabels = new Set();
        for (const item of items) {
            if (!seenLabels.has(item.label)) {
                seenLabels.add(item.label);
                displayItems.push(item);
                if (displayItems.length >= 4)
                    break;
            }
        }
        if (displayItems.length < 4) {
            for (const item of items) {
                if (!displayItems.includes(item)) {
                    displayItems.push(item);
                    if (displayItems.length >= 4)
                        break;
                }
            }
        }
        displayItems.extraCount = items.length - displayItems.length;
        return displayItems;
    }

    _compactRowStructureKey(row) {
        const items = this._compactDisplayItems(row);
        return JSON.stringify({
            provider: row.provider,
            error: !!row.error,
            subtitle: !!(row.error || windowsOf(row).some(({w}) => resetText(w))),
            labels: items.map(item => item.label),
            extraCount: items.extraCount,
        });
    }

    _buildCompactRow(row) {
        const rowBox = new St.BoxLayout({
            vertical: true,
            style_class: 'usagebar-compact-row',
            x_expand: true,
            reactive: true,
            track_hover: true,
        });
        const state = {
            rowBox,
            provider: row.provider,
            structureKey: this._compactRowStructureKey(row),
            titleLabel: null,
            subtitleLabel: null,
            metricRefs: [],
            extraLabel: null,
            unavailableLabel: null,
            contentBtn: null,
            separator: null,
        };

        const mainRow = new St.BoxLayout({
            style_class: 'usagebar-compact-inner',
            x_expand: true,
            y_align: Clutter.ActorAlign.CENTER,
        });

        // 1. Clickable content area: brand icon + body (title, subtitle, metrics)
        const contentBtn = new St.Button({
            style_class: 'usagebar-compact-content-btn',
            x_expand: true,
            reactive: true,
            can_focus: true,
        });
        contentBtn.connect('clicked', () => {
            this._selectedProvider = state.provider;
            this._render();
        });
        state.contentBtn = contentBtn;

        const contentBox = new St.BoxLayout({
            x_expand: true,
            y_align: Clutter.ActorAlign.CENTER,
            style_class: 'usagebar-compact-content-box',
        });

        // Brand icon
        const iconWrap = new St.Bin({
            style_class: 'usagebar-compact-icon-wrap',
            y_align: Clutter.ActorAlign.CENTER,
            child: this._providerIcon(row.provider, 20),
        });
        contentBox.add_child(iconWrap);

        // Body: Top line (Title + Subtitle), Bottom line (Metrics)
        const body = new St.BoxLayout({
            vertical: true,
            style_class: 'usagebar-compact-body',
            x_expand: true,
        });

        const head = new St.BoxLayout({x_expand: true, style_class: 'usagebar-compact-head'});
        state.titleLabel = new St.Label({
            text: this._displayName(row.provider),
            style_class: 'usagebar-compact-title',
            y_align: Clutter.ActorAlign.CENTER,
        });
        head.add_child(state.titleLabel);

        let subtitle = '';
        if (row.error) {
            subtitle = row.error.message ?? 'fetch failed';
        } else {
            for (const {w} of windowsOf(row)) {
                const rt = resetText(w);
                if (rt) {
                    subtitle = rt;
                    break;
                }
            }
        }
        if (subtitle) {
            state.subtitleLabel = new St.Label({
                text: subtitle,
                style_class: row.error ? 'usagebar-banner usagebar-compact-subtitle' : 'usagebar-dim usagebar-compact-subtitle',
                y_align: Clutter.ActorAlign.CENTER,
            });
            head.add_child(state.subtitleLabel);
        }
        body.add_child(head);

        // Bottom line: metrics
        const metricsBox = new St.BoxLayout({
            style_class: 'usagebar-compact-metrics',
            x_expand: true,
        });

        const displayItems = this._compactDisplayItems(row);
        const extraCount = displayItems.extraCount;

        if (displayItems.length > 0) {
            for (const item of displayItems) {
                const metricItem = new St.BoxLayout({
                    style_class: 'usagebar-compact-metric-item',
                    y_align: Clutter.ActorAlign.CENTER,
                });

                metricItem.add_child(new St.Label({
                    text: item.label,
                    style_class: 'usagebar-dim usagebar-compact-metric-label',
                    y_align: Clutter.ActorAlign.CENTER,
                }));

                const known = item.w.usedPercent !== null && item.w.usedPercent !== undefined;
                const used = known ? Math.max(0, Math.min(100, Math.round(item.w.usedPercent))) : 0;
                const dispPercent = DISPLAY.barsShowUsed ? used : (100 - used);
                const sev = severity(used, row.stale || !known);

                const COMPACT_TRACK_WIDTH = 24;
                const track = new St.Widget({
                    style_class: 'usagebar-track usagebar-compact-track',
                    width: COMPACT_TRACK_WIDTH,
                    height: 4,
                    y_align: Clutter.ActorAlign.CENTER,
                });
                const fill = new St.Widget({
                    style_class: `usagebar-fill usagebar-bg-${sev}`,
                    y_align: Clutter.ActorAlign.CENTER,
                });
                const fillWidth = (known && used > 0)
                    ? Math.max(2, Math.round(COMPACT_TRACK_WIDTH * used / 100))
                    : 0;
                fill.set_size(fillWidth, 4);
                track.add_child(fill);
                metricItem.add_child(track);

                const percentLabel = new St.Label({
                    text: known ? `${dispPercent}%` : T.unavailable,
                    style_class: `usagebar-compact-metric-val usagebar-fg-${sev}`,
                    y_align: Clutter.ActorAlign.CENTER,
                });
                metricItem.add_child(percentLabel);
                state.metricRefs.push({fill, track, percentLabel});

                metricsBox.add_child(metricItem);
            }
            if (extraCount > 0) {
                state.extraLabel = new St.Label({
                    text: `+${extraCount}`,
                    style_class: 'usagebar-dim usagebar-compact-metric-label',
                    y_align: Clutter.ActorAlign.CENTER,
                });
                metricsBox.add_child(state.extraLabel);
            }
        } else if (row.error) {
            state.unavailableLabel = new St.Label({
                text: 'Unavailable',
                style_class: 'usagebar-dim',
            });
            metricsBox.add_child(state.unavailableLabel);
        }

        body.add_child(metricsBox);
        contentBox.add_child(body);
        contentBtn.set_child(contentBox);
        mainRow.add_child(contentBtn);
        rowBox.add_child(mainRow);

        state.update = next => {
            state.provider = next.provider;
            state.titleLabel.text = this._displayName(next.provider);
            if (state.subtitleLabel) {
                let nextSubtitle = '';
                if (next.error) {
                    nextSubtitle = next.error.message ?? 'fetch failed';
                } else {
                    for (const {w} of windowsOf(next)) {
                        const rt = resetText(w);
                        if (rt) {
                            nextSubtitle = rt;
                            break;
                        }
                    }
                }
                state.subtitleLabel.text = nextSubtitle;
            }
            const items = this._compactDisplayItems(next);
            state.metricRefs.forEach((ref, i) => {
                const item = items[i];
                if (!item)
                    return;
                const known = item.w.usedPercent !== null && item.w.usedPercent !== undefined;
                const used = known ? Math.max(0, Math.min(100, Math.round(item.w.usedPercent))) : 0;
                const dispPercent = DISPLAY.barsShowUsed ? used : (100 - used);
                const sev = severity(used, next.stale || !known);
                ref.percentLabel.text = known ? `${dispPercent}%` : T.unavailable;
                ref.percentLabel.style_class = `usagebar-compact-metric-val usagebar-fg-${sev}`;
                ref.fill.style_class = `usagebar-fill usagebar-bg-${sev}`;
                ref.fill.set_size((known && used > 0)
                    ? Math.max(2, Math.round(24 * used / 100)) : 0, 4);
            });
            if (state.unavailableLabel)
                state.unavailableLabel.visible = !!next.error && !items.length;
            if (state.extraLabel)
                state.extraLabel.text = `+${items.extraCount}`;
        };
        rowBox._usagebarRowState = state;

        return rowBox;
    }
}
