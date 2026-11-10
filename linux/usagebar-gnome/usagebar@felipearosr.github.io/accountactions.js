// Provider Account actions: which providers offer "Add account…", which
// account rows offer rename and remove, and the serve requests behind them.
// Dependency-free so the Node tests can exercise it without GJS.
//
// Serve advertises each action on /health (providerAccountKinds,
// providerAccountAddKey, providerAccountAddCliLogin, providerAccountRename,
// providerAccountRemove).
// GET /accounts/kinds says, per provider, the kind of account it can add,
// whether its account rows can be renamed and removed, and whether the first
// add replaces a credential UsageBar can't keep. The extension dispatches
// "Add account…" on the kind:
//   key          an in-popover dialog asking for a label and the key (#164)
//   cli-login    the provider's own login in a terminal (#169): `codexbar
//                codex-accounts add` for Codex (CLI_LOGIN_HELPERS)
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
    'cli-login': 'providerAccountAddCliLogin',
    'claude-swap': 'providerAccountAddClaudeSwap',
};

// cli-login (#169): per provider, the `codexbar` arguments of the helper that
// signs in to a new account in a terminal. A provider without an entry gets
// no Add account… even when serve reports cli-login for it. How the extension
// learns that the helper finished is terminalwatch.js.
export const CLI_LOGIN_HELPERS = {
    codex: ['codex-accounts', 'add'],
};

export const LABEL_LIMIT = 100;

// Serve's mutating routes need the secret the serve supervisor started it
// with (servesupervisor.js), sent back in this header.
export const ACTION_TOKEN_HEADER = 'X-UsageBar-Action-Token';

function has(capabilities, name) {
    return !!capabilities && typeof capabilities.has === 'function' && capabilities.has(name);
}

// GET /accounts/kinds → Map provider → {kind, placeholder, rename, remove,
// replacesCurrent}. `kind` is null when the provider can't add an account
// here, or adds a kind this extension has no handler for. Actions default to
// off, so a missing or malformed field never offers one.
export function readKinds(json) {
    const kinds = new Map();
    const providers = json?.providers;
    if (!providers || typeof providers !== 'object')
        return kinds;
    for (const [provider, entry] of Object.entries(providers)) {
        if (!entry || typeof entry !== 'object')
            continue;
        const kind = typeof entry.kind === 'string' && Object.hasOwn(ADD_CAPABILITIES, entry.kind)
            ? entry.kind : null;
        const placeholder = typeof entry.placeholder === 'string' && entry.placeholder.trim()
            ? entry.placeholder.trim() : null;
        kinds.set(provider, {
            kind,
            placeholder,
            rename: entry.rename === true,
            remove: entry.remove === true,
            replacesCurrent: entry.replacesCurrent === true,
        });
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
    if (!entry?.kind || !has(capabilities, ADD_CAPABILITIES[entry.kind]))
        return null;
    if (entry.kind === 'cli-login' && !Object.hasOwn(CLI_LOGIN_HELPERS, provider))
        return null;
    return {provider, kind: entry.kind, placeholder: entry.placeholder, replacesCurrent: entry.replacesCurrent};
}

// The add dialog's warning when the first account takes over from a key
// UsageBar uses now and can't keep (a cookie, or a key from the environment).
export const REPLACES_CURRENT_NOTE = 'This replaces the key UsageBar uses now.';

// Only token-account rows (`token:<uuid>`) can be renamed or removed here.
export function isTokenAccount(account) {
    return typeof account?.id === 'string' && account.id.startsWith('token:') && account.id.length > 6;
}

// {rename, remove} for one account row of `provider`'s card: a token
// account, the action's capability, and the provider's own entry in the
// kinds (Antigravity's accounts can be renamed but not removed here).
export function rowActions(account, {provider = null, kinds = null, capabilities = null} = {}) {
    const token = isTokenAccount(account);
    const entry = provider ? kinds?.get?.(provider) : null;
    return {
        rename: token && entry?.rename === true && has(capabilities, RENAME_CAPABILITY),
        remove: token && entry?.remove === true && has(capabilities, REMOVE_CAPABILITY),
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

// The cli-login helper's argv (fixed, no shell) for `provider`, run with the
// extension's own codexbar `bin`; null without a bin or a helper.
export function cliLoginArgv(provider, bin) {
    if (typeof bin !== 'string' || !bin.startsWith('/') || !Object.hasOwn(CLI_LOGIN_HELPERS, provider))
        return null;
    return [bin, ...CLI_LOGIN_HELPERS[provider]];
}
