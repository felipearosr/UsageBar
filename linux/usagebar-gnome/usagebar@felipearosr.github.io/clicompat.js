// Which fork-only features the installed codexbar CLI supports, and what
// UsageBar says when one is missing. Upstream's CLI has no `codexbar sync`
// and no `/sync/*` routes in `serve`; UsageBar then hides Machine Sync and
// points to the install page instead of showing a raw CLI error.
// Dependency-free so the Node tests can exercise it without GJS.

import {INSTALL_URL} from './onboarding.js';

// Every fork-only feature this extension uses, with the first UsageBar CLI
// version that has it. Declared once; the note and the Settings summary read
// it from here.
export const FEATURES = {
    machineSync: {label: 'Machine Sync', minVersion: '0.69.0'},
};

// ---------- versions ----------

// "0.69.0", "CodexBar 0.68.0-fork.f05433b", "v0.69.0+usagebar.1.1.0" →
// {core: [0, 69, 0], pre: [...], build}; null when there is no version.
// Missing minor/patch count as 0.
export function parseVersion(text) {
    const match = /v?(\d+)(?:\.(\d+))?(?:\.(\d+))?(?:-([0-9A-Za-z.-]+))?(?:\+([0-9A-Za-z.-]+))?/
        .exec(String(text ?? ''));
    if (!match)
        return null;
    return {
        core: [match[1], match[2], match[3]].map(part => Number(part ?? 0)),
        pre: match[4] ? match[4].split('.') : [],
        build: match[5] ?? null,
    };
}

function comparePre(a, b) {
    // A release outranks its pre-releases (1.0.0-rc < 1.0.0).
    if (!a.length || !b.length)
        return (b.length ? 1 : 0) - (a.length ? 1 : 0);
    for (let i = 0; i < Math.max(a.length, b.length); i++) {
        if (a[i] === undefined)
            return -1;
        if (b[i] === undefined)
            return 1;
        const na = /^\d+$/.test(a[i]);
        const nb = /^\d+$/.test(b[i]);
        if (na && nb && Number(a[i]) !== Number(b[i]))
            return Number(a[i]) < Number(b[i]) ? -1 : 1;
        if (na !== nb)
            return na ? -1 : 1;
        if (a[i] !== b[i])
            return a[i] < b[i] ? -1 : 1;
    }
    return 0;
}

// Semver precedence: -1, 0 or 1. Build metadata (after "+") never counts.
// Unparseable versions sort first.
export function compareVersions(a, b) {
    const va = typeof a === 'string' ? parseVersion(a) : a;
    const vb = typeof b === 'string' ? parseVersion(b) : b;
    if (!va || !vb)
        return (va ? 1 : 0) - (vb ? 1 : 0);
    for (let i = 0; i < 3; i++) {
        if (va.core[i] !== vb.core[i])
            return va.core[i] < vb.core[i] ? -1 : 1;
    }
    return comparePre(va.pre, vb.pre);
}

export function meetsMinimum(version, minimum) {
    return !!parseVersion(version) && compareVersions(version, minimum) >= 0;
}

// ---------- capability report ----------

// A capability report (serve's /health JSON, or the CLI's JSON capability
// command) → {capabilities, version, upstream}, or null when the CLI sent
// none (upstream's CLI, older fork builds, a failed probe). Capabilities
// this extension doesn't know are dropped.
export function readReport(json) {
    if (!json || typeof json !== 'object' || !Array.isArray(json.capabilities))
        return null;
    return {
        capabilities: new Set(json.capabilities.filter(name =>
            typeof name === 'string' && Object.hasOwn(FEATURES, name))),
        version: stringOrNull(json.usagebarVersion ?? json.version),
        upstream: stringOrNull(json.upstreamVersion ?? json.upstreamBase),
    };
}

function stringOrNull(value) {
    return typeof value === 'string' && value.trim() ? value.trim() : null;
}

// ---------- probes ----------

// Without a report, the CLI is asked directly. serve's GET /sync/status:
// 200 means the route exists, 404 means this serve has no Machine Sync, and
// anything else (serve down, 401, 5xx) says nothing yet.
export function syncProbeFromHttpStatus(status) {
    if (status === 200)
        return true;
    if (status === 404)
        return false;
    return null;
}

// What a CLI without the `sync` command prints for `codexbar sync …`
// ("Unknown command 'sync'" from the argument parser).
export function isUnknownCommand(text) {
    return /\bunknown command\b/i.test(String(text ?? ''));
}

// ---------- per-feature state ----------

// One feature's state: 'available', 'needs-upgrade' (with the minimum
// UsageBar CLI version), or 'unknown' while nothing has answered yet. A
// report wins; without one a direct probe (true / false / null) decides.
export function featureState(feature, {report = null, probe = null} = {}) {
    const minVersion = FEATURES[feature]?.minVersion ?? null;
    if (!FEATURES[feature])
        return {state: 'needs-upgrade', minVersion};
    let available = null;
    if (report)
        available = report.capabilities.has(feature);
    else if (probe === true || probe === false)
        available = probe;
    if (available === null)
        return {state: 'unknown', minVersion};
    return {state: available ? 'available' : 'needs-upgrade', minVersion};
}

// ---------- plain language ----------

// The note shown in place of a feature this CLI lacks.
export function needsCliNote(feature) {
    const {label, minVersion} = FEATURES[feature] ?? {label: feature, minVersion: null};
    const version = minVersion ? `, version ${minVersion} or newer` : '';
    return {
        title: `${label} needs the UsageBar CLI`,
        body: `The codexbar command-line tool installed here doesn’t include ${label}. ` +
            `It comes with UsageBar’s own build of codexbar${version}. Install that ` +
            `build, then reopen Settings. The panel shows ${label} again once its ` +
            'backend restarts, for example after you log out and back in.',
        button: 'Install instructions',
        url: INSTALL_URL,
    };
}

// One line for Settings' "codexbar CLI" row: which fork-only features the
// installed CLI lacks. `states` maps feature → featureState(); unknown ones
// are left out until they resolve.
export function supportSummary(states) {
    const entries = Object.entries(states ?? {});
    if (entries.some(([, s]) => s?.state === 'unknown') &&
        !entries.some(([, s]) => s?.state === 'needs-upgrade'))
        return 'checking features…';
    const missing = entries
        .filter(([, s]) => s?.state === 'needs-upgrade')
        .map(([name]) => FEATURES[name]?.label ?? name);
    if (!missing.length)
        return 'supports every UsageBar feature';
    return `no ${missing.join(', ')} (needs the UsageBar CLI)`;
}
