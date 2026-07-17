// Status-strip scope selection, shared by extension.js (reader) and
// prefs.js (writer). Scopes live in the `status-scopes` strv as
// "provider:scope" entries; a provider without an entry tracks its
// default — the first curated scope from providermeta.js, or the whole
// status page.

import {PROVIDER_META} from './providermeta.js';

export function defaultScope(provider) {
    return PROVIDER_META[provider]?.statusScopes?.[0] ?? 'Everything';
}

// The strv decoded as provider → scope (defaults not applied).
export function scopeMap(settings) {
    const map = new Map();
    for (const entry of settings.get_strv('status-scopes')) {
        const i = entry.indexOf(':');
        if (i > 0)
            map.set(entry.slice(0, i), entry.slice(i + 1));
    }
    return map;
}

export function scopeOf(settings, provider) {
    return scopeMap(settings).get(provider) ?? defaultScope(provider);
}

export function setScope(settings, provider, scope) {
    const rest = settings.get_strv('status-scopes')
        .filter(s => !s.startsWith(`${provider}:`));
    if (scope)
        rest.push(`${provider}:${scope}`);
    settings.set_strv('status-scopes', rest.sort());
}
