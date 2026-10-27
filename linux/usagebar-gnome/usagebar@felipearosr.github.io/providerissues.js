// Provider issues: turn a row's raw error payload ({message, code?, kind?})
// into a short state the popover can show, and summarize every failing row
// for the issues banner and the Details dialog. Dependency-free so the Node
// tests can exercise it without GJS; extension.js owns the actors.
//
// Serve's error messages are free text (often with an upstream JSON body
// appended), so the message decides the state. Auth detection reuses
// authlogin.js, which already knows which texts a login fixes.

import {isAuthError, loginActionFor} from './authlogin.js';

// Exit codes from Sources/CodexBarCLI/CLIExitCode.swift.
const EXIT_TIMEOUT = 4;

export const ISSUE_GROUPS = ['action', 'retrying', 'unknown'];

export const GROUP_TITLES = {
    action: 'Needs your action',
    retrying: 'Retrying automatically',
    unknown: 'Unknown',
};

// state -> {label, group, tone, summary}. tone picks the pill/dot color
// (error | warn | info | muted).
export const ISSUE_STATES = {
    auth_expired: {
        label: 'Sign-in expired',
        group: 'action',
        tone: 'error',
        summary: name => `Your ${name} session expired. Sign in again to resume tracking.`,
    },
    auth_invalid: {
        label: 'Not signed in',
        group: 'action',
        tone: 'error',
        summary: name => `${name} has no valid credentials. Sign in to start tracking.`,
    },
    rate_limited: {
        label: 'Rate limited',
        group: 'retrying',
        tone: 'warn',
        summary: name => `${name}'s usage endpoint is throttling requests.`,
    },
    offline: {
        label: "Can't reach server",
        group: 'retrying',
        tone: 'warn',
        summary: () => 'The request timed out or the network is down. Check your connection or proxy.',
    },
    provider_down: {
        label: 'Service unavailable',
        group: 'retrying',
        tone: 'info',
        summary: name => `${name}'s API is having problems. This is on their side.`,
    },
    unknown: {
        label: "Couldn't refresh",
        group: 'unknown',
        tone: 'muted',
        summary: () => 'Got an unexpected response.',
    },
};

const EXPIRED_PATTERNS = [
    /\bexpired\b/,
    /\btoken_expired\b/,
    /\brevoked\b/,
    /\balready used\b/,
    /\blog ?in again\b/,
    /\bre-?authenticate\b/,
];

const RATE_LIMIT_PATTERNS = [
    /\brate[- ]?limit(ed)?\b/,
    /\btoo many requests\b/,
    /\b429\b/,
    /\bquota exceeded\b/,
];

const OFFLINE_PATTERNS = [
    /\btimed out\b/,
    /\btimeout\b/,
    /\bnetwork\b/,
    /\boffline\b/,
    /\bcould not connect\b/,
    /\bcould not resolve\b/,
    /\bconnection (refused|reset|closed|failed)\b/,
    /\bname resolution\b/,
    /\bunreachable\b/,
    /\becon(nrefused|nreset)\b/,
];

const PROVIDER_DOWN_PATTERNS = [
    /\b(500|502|503|504|529)\b/,
    /\bservice unavailable\b/,
    /\bbad gateway\b/,
    /\binternal server error\b/,
    /\boverloaded\b/,
];

function messageOf(error) {
    if (!error)
        return '';
    if (typeof error === 'string')
        return error;
    return typeof error.message === 'string' ? error.message : '';
}

export function classifyError(error) {
    const message = messageOf(error);
    const lower = message.toLowerCase();
    // Rate limits first: some rate-limit texts suggest logging in again.
    if (RATE_LIMIT_PATTERNS.some(re => re.test(lower)))
        return 'rate_limited';
    if (isAuthError(error))
        return EXPIRED_PATTERNS.some(re => re.test(lower)) ? 'auth_expired' : 'auth_invalid';
    if ((typeof error === 'object' && error?.code === EXIT_TIMEOUT) ||
        OFFLINE_PATTERNS.some(re => re.test(lower)))
        return 'offline';
    if (PROVIDER_DOWN_PATTERNS.some(re => re.test(lower)))
        return 'provider_down';
    return 'unknown';
}

// The human part of a raw message: drop any appended JSON/HTML body and the
// trailing colon that introduced it, keep the first line, cap the length.
export function shortMessage(message, max = 140) {
    if (typeof message !== 'string')
        return '';
    let text = message.split('\n')[0];
    const body = text.search(/[{[<]/);
    if (body > 0)
        text = text.slice(0, body);
    text = text.replace(/[\s:–—-]+$/, '').trim();
    if (text.length > max)
        text = `${text.slice(0, max - 1).trimEnd()}…`;
    return text;
}

// Pretty-print a raw message for the Technical details view: the prose,
// then any embedded JSON body indented.
export function technicalDetails(error) {
    const message = messageOf(error);
    const lines = [];
    const meta = [];
    if (typeof error === 'object' && error) {
        if (error.kind)
            meta.push(`kind: ${error.kind}`);
        if (error.code !== undefined && error.code !== null)
            meta.push(`exit code: ${error.code}`);
    }
    if (meta.length)
        lines.push(meta.join(' · '));
    const start = message.indexOf('{');
    const end = message.lastIndexOf('}');
    if (start >= 0 && end > start) {
        try {
            const json = JSON.parse(message.slice(start, end + 1));
            const prose = message.slice(0, start).trim();
            if (prose)
                lines.push(prose);
            lines.push(JSON.stringify(json, null, 2));
            const rest = message.slice(end + 1).trim();
            if (rest)
                lines.push(rest);
            return lines.join('\n');
        } catch {
            // not JSON; fall through to the raw text
        }
    }
    lines.push(message || 'No error message.');
    return lines.join('\n');
}

// One failing row -> the issue the UI shows. `name` is the display name.
export function describeIssue(row, name) {
    if (!row?.error)
        return null;
    const state = classifyError(row.error);
    const def = ISSUE_STATES[state];
    let summary = def.summary(name);
    if (state === 'unknown') {
        const text = shortMessage(messageOf(row.error));
        if (text)
            summary = text;
    }
    if (row.stale && def.group !== 'action')
        summary += ' Showing last known data.';
    return {
        provider: row.provider,
        name,
        state,
        label: def.label,
        group: def.group,
        tone: def.tone,
        summary,
        stale: !!row.stale,
        login: loginActionFor(row),
        details: technicalDetails(row.error),
    };
}

// Every failing row, grouped. `nameOf(provider)` gives display names.
// headline is the banner text; urgent is true when something needs the user.
export function summarizeIssues(rows, nameOf = id => id) {
    const issues = rows
        .map(row => describeIssue(row, nameOf(row.provider)))
        .filter(Boolean);
    const groups = Object.fromEntries(ISSUE_GROUPS.map(group =>
        [group, issues.filter(issue => issue.group === group)]));
    const action = groups.action;
    let headline = null;
    if (action.length === 1) {
        headline = action[0].state === 'auth_expired'
            ? `${action[0].name} needs you to sign in again`
            : `${action[0].name} needs you to sign in`;
    } else if (action.length > 1) {
        headline = `${action.length} providers need you to act`;
    } else if (issues.length === 1) {
        headline = `${issues[0].name}: ${issues[0].label.toLowerCase()}`;
    } else if (issues.length > 1) {
        headline = `${issues.length} providers couldn't refresh`;
    }
    return {
        issues,
        groups,
        total: issues.length,
        urgent: action.length > 0,
        headline,
        // Fix acts on the first actionable issue that has a login command.
        fix: action.find(issue => issue.login) ?? null,
    };
}

// "2h ago" style age for the Details dialog meta line.
export function formatAge(fromMs, nowMs = Date.now()) {
    const secs = Math.max(0, Math.round((nowMs - fromMs) / 1000));
    if (secs < 60)
        return 'just now';
    const mins = Math.round(secs / 60);
    if (mins < 60)
        return `${mins}m ago`;
    const hours = Math.round(mins / 60);
    if (hours < 48)
        return `${hours}h ago`;
    return `${Math.round(hours / 24)}d ago`;
}

// Plain-text dump of every issue, for "Copy all".
export function issuesReport(summary) {
    return summary.issues.map(issue =>
        `## ${issue.name} — ${issue.label}\n${issue.summary}\n\n${issue.details}`).join('\n\n');
}
