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

import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import * as PanelMenu from 'resource:///org/gnome/shell/ui/panelMenu.js';
import * as PopupMenu from 'resource:///org/gnome/shell/ui/popupMenu.js';

import {PROVIDER_META} from './providermeta.js';
import {defaultScope, scopeMap} from './statusscopes.js';

const REQUEST_TIMEOUT_SECS = 120;
const FETCH_OK_SECS = 55;          // cache hits between serve refreshes
const FETCH_RETRY_SECS = 10;       // serve starting up / transient failure
const TICK_SECS = 30;              // countdown re-render while the menu is open
const COST_TTL_SECS = 120;
const STATUS_TTL_SECS = 900;   // provider status pages refresh slowly
const STATUS_DAYS = 45;        // history strip length, like statuspage.io
const STATUS_BAR_HEIGHT = 18;
const BAR_WIDTH = 320;
const KPI_COL_WIDTH = 180; // left column of the 2x2 cost grid
const CHART_HEIGHT = 44; // daily cost/token trend bars
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

function fmtUSD(v) {
    return v === null || v === undefined
        ? null
        : `$${v.toLocaleString('en-US', {minimumFractionDigits: 2, maximumFractionDigits: 2})}`;
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
// dashboard): a continuous series of the last historyDays days ending
// today — days without usage are zero (1px stub) so the rightmost bar is
// always today. Dollars when the report is priced, tokens otherwise.
// Null when there is no history at all.
function chartPoints(report) {
    const daily = report?.daily ?? [];
    if (!daily.length)
        return null;
    const byDate = new Map(daily.map(d => [d.date, d]));
    const useCost = daily.some(d => typeof d.totalCost === 'number');
    const days = report.historyDays ?? 30;
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
        });
    }
    return points;
}

function chartTooltipText(point) {
    const day = new Date(`${point.date}T12:00:00`)
        .toLocaleDateString('en-US', {month: 'short', day: 'numeric'});
    const bits = [
        fmtUSD(point.cost),
        point.tokens !== null ? `${fmtTokens(point.tokens)} tokens` : null,
    ].filter(Boolean);
    return bits.length ? `${day} · ${bits.join(' · ')}` : `${day} · no usage`;
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

// Top models by summed cost across the report's daily entries, e.g.
// "fable-5 $157.5 · opus-4-8 $77.6". Breakdown dollars arrive under the
// upstream key "cost" (unlike daily totals' "totalCost") and are absent for
// providers without pricing (codex) — return null and show nothing then.
function topModelsLine(report) {
    const byModel = new Map();
    for (const day of report?.daily ?? []) {
        for (const m of day.modelBreakdowns ?? []) {
            if (typeof m.cost !== 'number' || !m.modelName)
                continue;
            byModel.set(m.modelName, (byModel.get(m.modelName) ?? 0) + m.cost);
        }
    }
    const top = [...byModel.entries()].sort((a, b) => b[1] - a[1]).slice(0, 2);
    if (!top.length)
        return null;
    return top
        .map(([name, usd]) => `${name.replace(/^claude-/, '')} $${usd.toFixed(1)}`)
        .join(' · ');
}

// ---------- serve supervisor ----------

function findBinary() {
    const explicit = GLib.getenv('CODEXBAR_BIN');
    if (explicit && GLib.file_test(explicit, GLib.FileTest.IS_EXECUTABLE))
        return explicit;
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

// ---------- indicator ----------

const Indicator = GObject.registerClass(
class UsageBarIndicator extends PanelMenu.Button {
    _init(dir) {
        super._init(0.5, 'UsageBar', false);
        this._dir = dir;

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
        this._refreshButton.add_child(new St.Icon({
            icon_name: 'view-refresh-symbolic',
            style_class: 'usagebar-btn-icon',
        }));
        header.add_child(this._refreshButton);
        this.menu.addMenuItem(header);

        // Status banner (serve problems, fetch errors).
        this._statusItem = new PopupMenu.PopupBaseMenuItem({reactive: false, can_focus: false});
        this._statusLabel = new St.Label({style_class: 'usagebar-banner', x_expand: true});
        this._statusLabel.clutter_text.line_wrap = true;
        this._statusItem.add_child(this._statusLabel);
        this._statusItem.visible = false;
        this.menu.addMenuItem(this._statusItem);

        const detailItem = new PopupMenu.PopupBaseMenuItem({reactive: false, can_focus: false});
        this._detailBox = new St.BoxLayout({vertical: true, x_expand: true});
        detailItem.add_child(this._detailBox);
        this.menu.addMenuItem(detailItem);

        // Floating tooltip for chart-bar hover. Lives in the shell's UI
        // group so it can escape the menu; hidden with the menu and
        // destroyed with the indicator.
        this._tooltip = new St.Label({style_class: 'usagebar-tooltip', visible: false});
        Main.uiGroup.add_child(this._tooltip);
        this.menu.connect('open-state-changed', (_menu, open) => {
            if (!open)
                this._tooltip?.hide();
        });
        this.connect('destroy', () => {
            this._tooltip?.destroy();
            this._tooltip = null;
        });

        this.menu.addMenuItem(new PopupMenu.PopupSeparatorMenuItem());
        this._settingsItem = new PopupMenu.PopupMenuItem('Settings');
        this.menu.addMenuItem(this._settingsItem);
    }

    _setPanelText(chips) {
        this._chipBox.destroy_all_children();
        if (!chips.length) {
            this._chipBox.add_child(new St.Label({
                text: 'UB',
                style_class: 'usagebar-chip-label',
                y_align: Clutter.ActorAlign.CENTER,
            }));
            return;
        }
        for (const chip of chips) {
            const box = new St.BoxLayout({style_class: 'usagebar-chip'});

            if (chip.mode === 'dot') {
                box.add_child(new St.Widget({
                    style_class: `usagebar-dot usagebar-bg-${chip.sev}`,
                    width: 8,
                    height: 8,
                    y_align: Clutter.ActorAlign.CENTER,
                }));
            } else {
                // 1. Provider Brand Icon (pure white)
                let iconAdded = false;
                if (this._dir && chip.provider) {
                    const iconFile = this._dir.get_child('icons').get_child(`ProviderIcon-${chip.provider}.svg`);
                    if (iconFile.query_exists(null)) {
                        const gicon = new Gio.FileIcon({file: iconFile});
                        box.add_child(new St.Icon({
                            gicon,
                            icon_size: 14,
                            style_class: 'usagebar-chip-icon',
                            y_align: Clutter.ActorAlign.CENTER,
                        }));
                        iconAdded = true;
                    }
                }
                if (!iconAdded) {
                    box.add_child(new St.Icon({
                        icon_name: 'application-x-executable-symbolic',
                        icon_size: 14,
                        style_class: 'usagebar-chip-icon',
                        y_align: Clutter.ActorAlign.CENTER,
                    }));
                }

                // 2. Circular Progress Ring (if not percent-only mode)
                if (chip.mode !== 'percent') {
                    const ring = new St.DrawingArea({
                        style_class: 'usagebar-chip-ring',
                        width: 14,
                        height: 14,
                        y_align: Clutter.ActorAlign.CENTER,
                    });
                    const percent = chip.percent;
                    const sev = chip.sev;
                    ring.connect('repaint', area => {
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

                        // Background track
                        cr.arc(xc, yc, radius, 0, 2 * Math.PI);
                        cr.setSourceRGBA(1.0, 1.0, 1.0, 0.22);
                        cr.setLineWidth(lineWidth);
                        cr.stroke();

                        // Progress arc
                        if (percent > 0) {
                            const startAngle = -Math.PI / 2;
                            const progressFrac = Math.min(1.0, Math.max(0.0, percent / 100.0));
                            const endAngle = startAngle + progressFrac * 2 * Math.PI;

                            cr.arc(xc, yc, radius, startAngle, endAngle);

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
                    box.add_child(ring);
                }
            }

            // 3. Percentage or name label (if enabled and present)
            if (chip.text) {
                box.add_child(new St.Label({
                    text: chip.text,
                    style_class: 'usagebar-chip-label',
                    y_align: Clutter.ActorAlign.CENTER,
                }));
            }
            this._chipBox.add_child(box);
        }
    }

    setStatus(message) {
        this._statusItem.visible = !!message;
        this._statusLabel.text = message ? `⚠ ${message}` : '';
    }

    setUpdated(text) {
        this._updatedLabel.text = text;
    }
});

// ---------- extension ----------

export default class UsageBarExtension extends Extension {
    enable() {
        this._rows = [];
        this._names = {};
        this._selectedProvider = null;
        this._optionsProvider = null;
        this._notified = new Map();
        this._costs = null;
        this._costFetchedAt = 0;
        this._status = {};
        this._lastFetchAt = 0;
        this._fetchId = 0;
        this._tickId = 0;
        this._session = new Soup.Session({timeout: REQUEST_TIMEOUT_SECS + 10});
        this._cancellable = new Gio.Cancellable();

        this._settings = this.getSettings();
        const applySettings = () => {
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
            'status-scopes', 'status-checks-enabled',
        ]);
        this._settingsChangedId = this._settings.connect('changed', (_s, key) => {
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
                        this._supervisor?.restart(
                            this._settings.get_int('refresh-interval-secs'));
                        return GLib.SOURCE_REMOVE;
                    });
            }
            if (DISPLAY_KEYS.has(key))
                this._render();
        });

        this._indicator = new Indicator(this.dir);
        this._indicator._settingsItem.connect('activate', () => this.openPreferences());
        this._indicator._refreshButton.connect('clicked', () => this._fetchUsage());
        this._indicator.menu.connect('open-state-changed', (_menu, open) => {
            if (open) {
                this._selectedProvider = null; // default to the All tab each open
                this._optionsProvider = null;
                if (this._settings.get_boolean('refresh-on-open'))
                    this._fetchUsage();
                this._fetchCost();
                this._fetchStatus();
                this._render();
            }
        });
        Main.panel.addToStatusArea(this.uuid, this._indicator);

        const binary = findBinary();
        if (!binary) {
            this._indicator.setStatus('codexbar CLI not found — install it from ' +
                'github.com/steipete/CodexBar releases or set $CODEXBAR_BIN');
            this._render();
            return;
        }
        this._binary = binary;
        this._loadDisplayNames(binary);

        // Refetch when the CLI config changes — prefs toggles, terminal
        // `codexbar config enable`, hand edits alike. Serve re-reads the
        // config per request, so a fresh fetch is all it takes; display
        // names may be new too. Debounced: writers fire several events.
        try {
            this._configMonitor = Gio.File.new_for_path(GLib.build_filenamev(
                [GLib.get_user_config_dir(), 'codexbar', 'config.json']))
                .monitor_file(Gio.FileMonitorFlags.WATCH_MOVES, null);
            this._configMonitor.connect('changed', () => {
                if (this._configDebounceId)
                    GLib.source_remove(this._configDebounceId);
                this._configDebounceId = GLib.timeout_add_seconds(
                    GLib.PRIORITY_DEFAULT, 1, () => {
                        this._configDebounceId = 0;
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
                if (status)
                    this._indicator.setStatus(status);
                if (port)
                    this._scheduleFetch(2);
            });
        this._supervisor.start();

        // Countdown/"updated ago" ticker while the menu is open.
        this._tickId = GLib.timeout_add_seconds(GLib.PRIORITY_DEFAULT, TICK_SECS, () => {
            if (this._indicator?.menu.isOpen)
                this._render();
            return GLib.SOURCE_CONTINUE;
        });
    }

    disable() {
        if (this._settingsChangedId) {
            this._settings.disconnect(this._settingsChangedId);
            this._settingsChangedId = 0;
        }
        this._settings = null;
        if (this._fetchId) {
            GLib.source_remove(this._fetchId);
            this._fetchId = 0;
        }
        if (this._tickId) {
            GLib.source_remove(this._tickId);
            this._tickId = 0;
        }
        if (this._restartDebounceId) {
            GLib.source_remove(this._restartDebounceId);
            this._restartDebounceId = 0;
        }
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
        this._indicator?.destroy();
        this._indicator = null;
        this._rows = [];
        this._notified = null;
        this._costs = null;
        this._status = null;
    }

    // ----- data -----

    _loadDisplayNames(binary) {
        try {
            const proc = Gio.Subprocess.new(
                [binary, 'config', 'providers', '--format', 'json'],
                Gio.SubprocessFlags.STDOUT_PIPE | Gio.SubprocessFlags.STDERR_SILENCE);
            proc.communicate_utf8_async(null, this._cancellable, (p, res) => {
                try {
                    const [, out] = p.communicate_utf8_finish(res);
                    for (const entry of JSON.parse(out))
                        this._names[entry.provider] = entry.displayName;
                    this._render();
                } catch {
                    // cosmetic only — fall back to capitalized ids
                }
            });
        } catch {
            // ignore
        }
    }

    _fetchJSON(url, cb) {
        const msg = Soup.Message.new('GET', url);
        this._session.send_and_read_async(msg, GLib.PRIORITY_DEFAULT, this._cancellable,
            (session, res) => {
                try {
                    const bytes = session.send_and_read_finish(res);
                    if (msg.get_status() !== Soup.Status.OK)
                        throw new Error(`HTTP ${msg.get_status()}`);
                    cb(JSON.parse(new TextDecoder().decode(bytes.get_data())), null);
                } catch (e) {
                    cb(null, e);
                }
            });
    }

    _get(path, cb) {
        const port = this._supervisor?.port;
        if (!port) {
            cb(null, new Error('serve not running'));
            return;
        }
        this._fetchJSON(`http://127.0.0.1:${port}${path}`, cb);
    }

    _scheduleFetch(secs) {
        if (this._fetchId)
            GLib.source_remove(this._fetchId);
        this._fetchId = GLib.timeout_add_seconds(GLib.PRIORITY_DEFAULT, secs, () => {
            this._fetchId = 0;
            this._fetchUsage();
            return GLib.SOURCE_REMOVE;
        });
    }

    _fetchUsage() {
        if (this._fetchInFlight)
            return;
        this._fetchInFlight = true;
        this._get('/usage', (rows, error) => {
            this._fetchInFlight = false;
            if (!this._indicator)
                return; // disabled while in flight
            if (error) {
                this._indicator.setStatus(`usage fetch failed: ${error.message}`);
                this._scheduleFetch(FETCH_RETRY_SECS);
            } else {
                this._rows = enrichAntigravityModels(mergeStale(this._rows, rows));
                this._lastFetchAt = Date.now();
                this._indicator.setStatus('');
                this._scheduleFetch(FETCH_OK_SECS);
                this._maybeNotify();
            }
            this._render();
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

    _fetchCost() {
        if (this._costs && (Date.now() - this._costFetchedAt) / 1000 < COST_TTL_SECS)
            return;
        this._get('/cost', (reports, error) => {
            if (!this._indicator || error)
                return; // cost is best-effort
            this._costs = reports;
            this._costFetchedAt = Date.now();
            this._render();
        });
    }

    // Incident history for the status strips, straight from each provider's
    // public status page (the serve API doesn't carry status). Only enabled
    // providers (rows in the feed) are polled. Everything is best-effort.
    _fetchStatus() {
        if (!this._settings?.get_boolean('status-checks-enabled'))
            return;
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
                if (!this._indicator || !this._status || !result)
                    return;
                this._status[provider] = {...result, scope, fetchedAt: Date.now()};
                this._render();
            };
            if (feed.kind === 'statuspage') {
                this._fetchJSON(`${feed.base}/api/v2/incidents.json`, (data, error) =>
                    done(error ? null : statuspageIntervals(data.incidents, scope)));
            } else {
                // incident.io: the component/group structure lives in the
                // summary document, the impact windows in /incidents.
                this._fetchJSON(feed.base, (summary, error) => {
                    if (error || !this._indicator)
                        return;
                    const ids = incidentIoScopeIds(summary.summary, scope);
                    this._fetchJSON(`${feed.base}/incidents`, (data, err2) =>
                        done(err2 ? null : incidentIoIntervals(data.incidents, ids)));
                });
            }
        }
    }

    // ----- rendering -----

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

        this._publishWindowCatalog();

        // Selection determines view: null means the All / overview view
        // (compact cards with chevron arrow). Selecting a provider shows
        // that provider's full detail view with a back button.
        const selectedRow = rows.find(r => r.provider === this._selectedProvider) ?? null;

        const detail = this._indicator._detailBox;
        detail.destroy_all_children();
        if (!rows.length) {
            detail.add_child(new St.Label({
                text: 'No usage data yet.',
                style_class: 'usagebar-dim',
            }));
        } else if (selectedRow) {
            detail.add_child(this._buildCard(selectedRow, {flat: true, showBackButton: true}));
        } else {
            // All view: compact cards, one per provider, with brand icon,
            // reset countdown, chevron navigation to detail view, and inline mini bars.
            rows.forEach((row, i) => {
                if (i > 0)
                    detail.add_child(new St.Widget({
                        style_class: 'usagebar-separator',
                        height: 1,
                        x_expand: true,
                    }));
                detail.add_child(this._buildCompactRow(row, i, rows.length));
            });
        }
    }

    _moveProvider(provider, direction) {
        const rows = this._sortedRows();
        const currentOrder = rows.map(r => r.provider);
        const idx = currentOrder.indexOf(provider);
        if (idx < 0)
            return;
        const targetIdx = idx + direction;
        if (targetIdx < 0 || targetIdx >= currentOrder.length)
            return;

        const temp = currentOrder[idx];
        currentOrder[idx] = currentOrder[targetIdx];
        currentOrder[targetIdx] = temp;

        DISPLAY.providerOrder = currentOrder;
        if (this._settings) {
            this._settings.set_strv('provider-order', currentOrder);
            if (DISPLAY.sortAlphabetical) {
                DISPLAY.sortAlphabetical = false;
                this._settings.set_boolean('sort-alphabetical', false);
            }
        }
        this._render();
    }

    // Mini daily-trend bar chart (port of the macOS MiniUsageBars): equal
    // bars bottom-aligned over a 1px baseline, height and opacity scaled
    // linearly to the max value.
    _buildTrendChart(points, provider) {
        const wrap = new St.BoxLayout({vertical: true, x_expand: true, style_class: 'usagebar-chart-wrap'});
        const chart = new St.BoxLayout({x_expand: true, height: CHART_HEIGHT, style_class: 'usagebar-chart'});
        const max = Math.max(...points.map(p => p.value), 0);
        // Each day is a full-height reactive slot (so short bars are easy
        // to hover) holding the bottom-aligned bar.
        const brand = PROVIDER_META[provider]?.color;
        const slots = points.map(point => {
            const ratio = max > 0 && point.value > 0 ? Math.min(point.value / max, 1) : 0;
            const bar = new St.Widget({style_class: 'usagebar-chart-bar'});
            if (brand)
                bar.set_style(`background-color: ${brand};`);
            bar.set_opacity(Math.round(255 * (0.42 + 0.58 * Math.max(0.18, ratio))));
            bar.set_size(4, ratio > 0 ? Math.max(3, Math.round(ratio * CHART_HEIGHT)) : 1);
            // Vertical box with an expanding spacer: keeps the bar pinned
            // to the baseline (St.Bin centers its child).
            const slot = new St.BoxLayout({vertical: true, reactive: true, track_hover: true});
            slot.add_child(new St.Widget({y_expand: true}));
            slot.add_child(bar);
            slot._ratio = ratio;
            slot._bar = bar;
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
                const h = slot._ratio > 0 ? Math.max(3, Math.round(slot._ratio * CHART_HEIGHT)) : 1;
                slot._bar.set_size(bw, h);
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
        const prev = this._settings.get_strv('known-windows');
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
        });
        const meta = PROVIDER_META[row.provider];
        const iconFile = this.dir.get_child('icons').get_child(`ProviderIcon-${row.provider}.svg`);
        let iconActor;
        if (iconFile.query_exists(null)) {
            const gicon = new Gio.FileIcon({file: iconFile});
            iconActor = new St.Icon({
                gicon,
                icon_size: 20,
                style_class: 'usagebar-compact-icon',
                y_align: Clutter.ActorAlign.CENTER,
            });
            if (meta?.color)
                iconActor.set_style(`color: ${meta.color};`);
        } else {
            iconActor = new St.Icon({
                icon_name: 'application-x-executable-symbolic',
                icon_size: 20,
                style_class: 'usagebar-compact-icon',
                y_align: Clutter.ActorAlign.CENTER,
            });
            if (meta?.color)
                iconActor.set_style(`color: ${meta.color};`);
        }
        iconWrap.set_child(iconActor);
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
        const models = topModelsLine(report);
        if (flat && (credits || kpis || models))
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
        const trend = chartPoints(report);
        if (trend)
            card.add_child(this._buildTrendChart(trend, row.provider));

        if (models) {
            card.add_child(new St.Label({
                text: models,
                style_class: 'usagebar-dim usagebar-models',
            }));
        }
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

    _buildCompactRow(row, index, totalCount) {
        const rowBox = new St.BoxLayout({
            vertical: true,
            style_class: 'usagebar-compact-row',
            x_expand: true,
        });

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
            this._selectedProvider = row.provider;
            this._render();
        });

        const contentBox = new St.BoxLayout({
            x_expand: true,
            y_align: Clutter.ActorAlign.CENTER,
            style_class: 'usagebar-compact-content-box',
        });

        // Brand icon
        const iconWrap = new St.Bin({
            style_class: 'usagebar-compact-icon-wrap',
            y_align: Clutter.ActorAlign.CENTER,
        });
        const meta = PROVIDER_META[row.provider];
        const iconFile = this.dir.get_child('icons').get_child(`ProviderIcon-${row.provider}.svg`);
        let iconActor;
        if (iconFile.query_exists(null)) {
            const gicon = new Gio.FileIcon({file: iconFile});
            iconActor = new St.Icon({
                gicon,
                icon_size: 20,
                style_class: 'usagebar-compact-icon',
                y_align: Clutter.ActorAlign.CENTER,
            });
            if (meta?.color)
                iconActor.set_style(`color: ${meta.color};`);
        } else {
            iconActor = new St.Icon({
                icon_name: 'application-x-executable-symbolic',
                icon_size: 20,
                style_class: 'usagebar-compact-icon',
                y_align: Clutter.ActorAlign.CENTER,
            });
            if (meta?.color)
                iconActor.set_style(`color: ${meta.color};`);
        }
        iconWrap.set_child(iconActor);
        contentBox.add_child(iconWrap);

        // Body: Top line (Title + Subtitle), Bottom line (Metrics)
        const body = new St.BoxLayout({
            vertical: true,
            style_class: 'usagebar-compact-body',
            x_expand: true,
        });

        const head = new St.BoxLayout({x_expand: true, style_class: 'usagebar-compact-head'});
        head.add_child(new St.Label({
            text: this._displayName(row.provider),
            style_class: 'usagebar-compact-title',
            y_align: Clutter.ActorAlign.CENTER,
        }));

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
            head.add_child(new St.Label({
                text: subtitle,
                style_class: row.error ? 'usagebar-banner usagebar-compact-subtitle' : 'usagebar-dim usagebar-compact-subtitle',
                y_align: Clutter.ActorAlign.CENTER,
            }));
        }
        body.add_child(head);

        // Bottom line: metrics
        const metricsBox = new St.BoxLayout({
            style_class: 'usagebar-compact-metrics',
            x_expand: true,
        });

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
            // Antigravity in All view: user switch selects Gemini (default) vs Claude/GPT models
            const useGemini = DISPLAY.antigravityOverviewGemini !== false;
            for (const x of extras) {
                if (DISPLAY.hiddenWindows.has(barKey(row.provider, {extra: x})))
                    continue;
                const isGemini = x.id.includes('gemini');
                if ((useGemini && isGemini) || (!useGemini && !isGemini)) {
                    items.push({
                        label: compactWindowLabel(x.title ?? x.id),
                        w: x.window,
                    });
                }
            }
        } else if (row.provider === 'codex') {
            // Codex in All view: ensure 5h session bar is present (from Spark 5h if primary is null)
            const has5h = items.some(it => it.label === '5h');
            for (const x of extras) {
                if (DISPLAY.hiddenWindows.has(barKey(row.provider, {extra: x})))
                    continue;
                const label = compactWindowLabel(x.title ?? x.id);
                if (!has5h && label === '5h') {
                    items.unshift({
                        label,
                        w: x.window,
                    });
                } else if (DISPLAY.showExtras) {
                    items.push({
                        label,
                        w: x.window,
                    });
                }
            }
        } else if (row.provider === 'claude') {
            // Claude in All view: include Fable only window alongside 5h and wk
            for (const x of extras) {
                if (DISPLAY.hiddenWindows.has(barKey(row.provider, {extra: x})))
                    continue;
                const label = compactWindowLabel(x.title ?? x.id);
                if (label === 'Fable' || DISPLAY.showExtras) {
                    items.push({
                        label,
                        w: x.window,
                    });
                }
            }
        } else if (DISPLAY.showExtras) {
            for (const x of extras) {
                if (DISPLAY.hiddenWindows.has(barKey(row.provider, {extra: x})))
                    continue;
                items.push({
                    label: compactWindowLabel(x.title ?? x.id),
                    w: x.window,
                });
            }
        }

        let displayItems = [];
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
        const extraCount = items.length - displayItems.length;

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

                metricsBox.add_child(metricItem);
            }
            if (extraCount > 0) {
                metricsBox.add_child(new St.Label({
                    text: `+${extraCount}`,
                    style_class: 'usagebar-dim usagebar-compact-metric-label',
                    y_align: Clutter.ActorAlign.CENTER,
                }));
            }
        } else if (row.error) {
            metricsBox.add_child(new St.Label({
                text: 'Unavailable',
                style_class: 'usagebar-dim',
            }));
        }

        body.add_child(metricsBox);
        contentBox.add_child(body);
        contentBtn.set_child(contentBox);
        mainRow.add_child(contentBtn);

        // Actions: 3 dots button + right chevron arrow button
        const actionsBox = new St.BoxLayout({
            style_class: 'usagebar-compact-actions',
            y_align: Clutter.ActorAlign.CENTER,
        });

        const dotsBtn = new St.Button({
            style_class: this._optionsProvider === row.provider
                ? 'usagebar-btn usagebar-dots-btn usagebar-btn-active'
                : 'usagebar-btn usagebar-dots-btn',
            can_focus: true,
            reactive: true,
            child: new St.Icon({
                icon_name: 'view-more-symbolic',
                icon_size: 11,
                style_class: 'usagebar-btn-icon',
            }),
            y_align: Clutter.ActorAlign.CENTER,
        });
        dotsBtn.connect('clicked', () => {
            this._optionsProvider = (this._optionsProvider === row.provider) ? null : row.provider;
            this._render();
        });
        actionsBox.add_child(dotsBtn);

        const nextBtn = new St.Button({
            style_class: 'usagebar-btn usagebar-next-btn',
            can_focus: true,
            reactive: true,
            child: new St.Icon({
                icon_name: 'go-next-symbolic',
                icon_size: 11,
                style_class: 'usagebar-btn-icon',
            }),
            y_align: Clutter.ActorAlign.CENTER,
        });
        nextBtn.connect('clicked', () => {
            this._selectedProvider = row.provider;
            this._render();
        });
        actionsBox.add_child(nextBtn);

        mainRow.add_child(actionsBox);
        rowBox.add_child(mainRow);

        // Options dropdown panel (Move Up / Move Down)
        if (this._optionsProvider === row.provider) {
            const optionsPanel = new St.BoxLayout({
                style_class: 'usagebar-options-panel',
                x_expand: true,
                y_align: Clutter.ActorAlign.CENTER,
            });

            const upContent = new St.BoxLayout({
                style_class: 'usagebar-option-btn-content',
                y_align: Clutter.ActorAlign.CENTER,
            });
            upContent.add_child(new St.Icon({
                icon_name: 'go-up-symbolic',
                icon_size: 12,
                style_class: 'usagebar-btn-icon',
            }));
            upContent.add_child(new St.Label({
                text: 'Move Up',
                style_class: 'usagebar-option-label',
            }));

            const upBtn = new St.Button({
                style_class: index > 0 ? 'usagebar-btn usagebar-option-btn' : 'usagebar-btn usagebar-option-btn usagebar-btn-disabled',
                can_focus: index > 0,
                reactive: index > 0,
                child: upContent,
                y_align: Clutter.ActorAlign.CENTER,
            });
            if (index > 0) {
                upBtn.connect('clicked', () => {
                    this._moveProvider(row.provider, -1);
                });
            }
            optionsPanel.add_child(upBtn);

            const downContent = new St.BoxLayout({
                style_class: 'usagebar-option-btn-content',
                y_align: Clutter.ActorAlign.CENTER,
            });
            downContent.add_child(new St.Icon({
                icon_name: 'go-down-symbolic',
                icon_size: 12,
                style_class: 'usagebar-btn-icon',
            }));
            downContent.add_child(new St.Label({
                text: 'Move Down',
                style_class: 'usagebar-option-label',
            }));

            const downBtn = new St.Button({
                style_class: index < totalCount - 1 ? 'usagebar-btn usagebar-option-btn' : 'usagebar-btn usagebar-option-btn usagebar-btn-disabled',
                can_focus: index < totalCount - 1,
                reactive: index < totalCount - 1,
                child: downContent,
                y_align: Clutter.ActorAlign.CENTER,
            });
            if (index < totalCount - 1) {
                downBtn.connect('clicked', () => {
                    this._moveProvider(row.provider, 1);
                });
            }
            optionsPanel.add_child(downBtn);

            rowBox.add_child(optionsPanel);
        }

        return rowBox;
    }
}
