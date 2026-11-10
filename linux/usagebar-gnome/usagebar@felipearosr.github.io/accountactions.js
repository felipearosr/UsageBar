// Provider Account actions: which providers offer "Add account…", which
// account rows offer rename and remove, and the serve requests behind them.
// Dependency-free so the Node tests can exercise it without GJS.
//
// Serve advertises each action on /health (providerAccountKinds,
// providerAccountAddKey, providerAccountRename, providerAccountRemove).
// GET /accounts/kinds names the kind of account each provider can add; the
// extension dispatches "Add account…" on that kind:
//   key          an in-popover dialog asking for a label and the key (#164)
//   cli-login    the provider's own login in a terminal (#169)
//   claude-swap  claude-swap's add flow in a terminal (#172)
// A kind only counts when serve also advertises the action that adds it, so
// a newer serve's kind never reaches an extension without its handler.

export const KINDS_CAPABILITY = 'providerAccountKinds';
export const RENAME_CAPABILITY = 'providerAccountRename';
export const REMOVE_CAPABILITY = 'providerAccountRemove';

// Kind → the capability that adds it. Later tickets add their kind here and
// a handler in the extension's _addAccount.
export const ADD_CAPABILITIES = {
    key: 'providerAccountAddKey',
};

export const LABEL_LIMIT = 100;

function has(capabilities, name) {
    return !!capabilities && typeof capabilities.has === 'function' && capabilities.has(name);
}

// GET /accounts/kinds → Map provider → {kind, placeholder}. Unknown kinds and
// malformed entries are dropped.
export function readKinds(json) {
    const kinds = new Map();
    const providers = json?.providers;
    if (!providers || typeof providers !== 'object')
        return kinds;
    for (const [provider, entry] of Object.entries(providers)) {
        const kind = entry?.kind;
        if (typeof kind !== 'string' || !Object.hasOwn(ADD_CAPABILITIES, kind))
            continue;
        const placeholder = typeof entry.placeholder === 'string' && entry.placeholder.trim()
            ? entry.placeholder.trim() : null;
        kinds.set(provider, {kind, placeholder});
    }
    return kinds;
}

// Should the extension ask serve for the kinds at all?
export function wantsKinds(capabilities) {
    return has(capabilities, KINDS_CAPABILITY);
}

// The "Add account…" action for a provider card, or null when serve doesn't
// advertise one for it.
export function addAction(provider, {kinds = null, capabilities = null} = {}) {
    if (!has(capabilities, KINDS_CAPABILITY))
        return null;
    const entry = kinds?.get?.(provider);
    if (!entry || !has(capabilities, ADD_CAPABILITIES[entry.kind]))
        return null;
    return {provider, kind: entry.kind, placeholder: entry.placeholder};
}

// Only token-account rows (`token:<uuid>`) can be renamed or removed here.
export function isTokenAccount(account) {
    return typeof account?.id === 'string' && account.id.startsWith('token:') && account.id.length > 6;
}

// {rename, remove} for one account row of a card.
export function rowActions(account, capabilities) {
    const token = isTokenAccount(account);
    return {
        rename: token && has(capabilities, RENAME_CAPABILITY),
        remove: token && has(capabilities, REMOVE_CAPABILITY),
    };
}

// The add-key form: null when it can be sent, else what to fix.
export function keyFormError({label = '', token = ''} = {}) {
    if (!String(token).trim())
        return 'Paste the key first.';
    if (String(label).trim().length > LABEL_LIMIT)
        return `Keep the label under ${LABEL_LIMIT} characters.`;
    return null;
}

export function renameFormError({label = ''} = {}) {
    const trimmed = String(label).trim();
    if (!trimmed)
        return 'Enter a label.';
    if (trimmed.length > LABEL_LIMIT)
        return `Keep the label under ${LABEL_LIMIT} characters.`;
    return null;
}

// The serve requests. The add body is the only one that carries a token; it
// goes in the POST body, never the URL.
export function addKeyRequest({provider, label = '', token = ''}) {
    const body = {provider, token: String(token).trim()};
    const trimmed = String(label).trim();
    if (trimmed)
        body.label = trimmed;
    return {method: 'POST', path: '/accounts/add', body};
}

export function renameRequest({provider, accountId, label}) {
    return {method: 'POST', path: '/accounts/rename', body: {provider, accountId, label: String(label).trim()}};
}

export function removeRequest({provider, accountId}) {
    return {method: 'POST', path: '/accounts/remove', body: {provider, accountId}};
}

// What a failed action says in its dialog. Serve's messages never quote the
// request; the token is never part of the text either way.
export function actionErrorText(error, token = '') {
    const detail = typeof error?.detail === 'string' && error.detail.trim() ? error.detail.trim() : null;
    let text = detail ?? (error?.status ? `Serve answered HTTP ${error.status}.` : 'UsageBar’s backend isn’t running.');
    const secret = String(token).trim();
    if (secret && text.includes(secret))
        text = text.split(secret).join('…');
    return text;
}
