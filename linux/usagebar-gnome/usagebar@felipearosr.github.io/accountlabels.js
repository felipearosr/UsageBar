// Provider Account labels: private when Hide Personal Info is on, never
// ambiguous otherwise. Dependency-free so the Node tests can exercise it
// without GJS; accounts.js applies it to every card it builds.
//
// Each account has an ordinal N (1-based): accounts with an accountId sort
// by that id, which serve keeps across refreshes, renames and store
// reorders; accounts without one follow in row order. Response order is
// never used, because it can change between refreshes and "Account 2" must
// stay the same account. The cost: the id is opaque, so N needn't match the
// order the blocks are listed in (row order, which the card keeps whether
// labels are hidden or not), and adding or removing an account can renumber
// the accounts whose ids sort after it.
//
// - Hide Personal Info: every label is "Account N".
// - Otherwise the label serve sent is kept, except when two accounts of the
//   card share an email: then the user's alias, else "email · org", else
//   "email · Account N". Labels that still collide get " · Account N".
// - An account the user gave no label (serve's made-up "Account N", flagged
//   accountLabelIsDefault) has no alias: it reads as its email, else as the
//   extension's own "Account N", so the numbers match Hide Personal Info.
//
// Identity (email, org) comes only from the row's own usage.identity, and
// only when that identity names the row's provider: another provider's
// identity never labels an account.

// Plain and URL-encoded (%40) addresses.
const EMAIL = /[A-Z0-9._%+-]+(?:@|%40)[A-Z0-9.-]+\.[A-Z]{2,}/gi;
// What serve sends for an account without a label. Older serves don't send
// accountLabelIsDefault, so the shape is the fallback.
const DEFAULT_LABEL = /^Account \d+$/;

function text(value) {
    return typeof value === 'string' && value.trim() ? value.trim() : null;
}

function looksLikeEmail(value) {
    return typeof value === 'string' && /^[^\s@]+@[^\s@]+$/.test(value);
}

export function ordinalLabel(n) {
    return `Account ${n}`;
}

// The label serve sent for the row: accountLabel, else the older `account`.
export function rawLabel(row) {
    return text(row?.accountLabel) ?? text(row?.account);
}

// The label the user chose, or null when serve made the label up.
export function userLabel(row) {
    const raw = rawLabel(row);
    if (!raw || row?.accountLabelIsDefault === true || DEFAULT_LABEL.test(raw))
        return null;
    return raw;
}

// {email, org} from the row's own provider identity only. An identity whose
// providerID names another provider (or none) is ignored, as are the
// unscoped usage.accountEmail/accountOrganization copies. Token accounts
// without a known email carry their label as accountEmail; that is not an
// email and is ignored here.
export function accountIdentity(row) {
    const identity = row?.usage?.identity;
    if (!identity || typeof identity !== 'object' || identity.providerID !== row.provider)
        return {email: null, org: null};
    const email = text(identity.accountEmail);
    return {
        email: looksLikeEmail(email) ? email : null,
        org: text(identity.accountOrganization),
    };
}

// Email addresses in free text (error messages) replaced, for Hide
// Personal Info.
export function redactEmails(value) {
    if (typeof value !== 'string')
        return value;
    return value.replace(EMAIL, '[email]');
}

// 1-based ordinal per row, by accountId, then row order for rows without one.
export function accountOrdinals(rows) {
    const order = rows.map((row, index) => ({index, id: text(row?.accountId)}));
    order.sort((a, b) => {
        if (a.id && b.id)
            return a.id < b.id ? -1 : a.id > b.id ? 1 : a.index - b.index;
        if (a.id || b.id)
            return a.id ? -1 : 1;
        return a.index - b.index;
    });
    const ordinals = new Array(rows.length);
    order.forEach((entry, position) => {
        ordinals[entry.index] = position + 1;
    });
    return ordinals;
}

// rows of ONE provider card → [{label, ordinal}] in the same order.
export function accountLabels(rows, {hidePersonalInfo = false} = {}) {
    const ordinals = accountOrdinals(rows);
    if (hidePersonalInfo)
        return ordinals.map(ordinal => ({label: ordinalLabel(ordinal), ordinal}));

    const facts = rows.map((row, index) => {
        const raw = userLabel(row);
        const identity = accountIdentity(row);
        const email = identity.email ?? (looksLikeEmail(raw) ? raw : null);
        // A label that is just the email isn't an alias the user chose.
        const alias = raw && (!email || raw.toLowerCase() !== email.toLowerCase()) ? raw : null;
        return {raw, email, org: identity.org, alias, ordinal: ordinals[index]};
    });

    const byEmail = new Map();
    for (const fact of facts) {
        if (fact.email) {
            const key = fact.email.toLowerCase();
            byEmail.set(key, (byEmail.get(key) ?? 0) + 1);
        }
    }
    const labels = facts.map(fact => {
        if (!fact.email || byEmail.get(fact.email.toLowerCase()) < 2)
            return fact.raw ?? fact.email ?? ordinalLabel(fact.ordinal);
        if (fact.alias)
            return fact.alias;
        if (fact.org)
            return `${fact.email} · ${fact.org}`;
        return `${fact.email} · ${ordinalLabel(fact.ordinal)}`;
    });

    // Anything still shared (two aliases alike, same email and org) gets the
    // ordinal too, so no two rows of a card read the same.
    const counts = new Map();
    for (const label of labels) {
        if (label)
            counts.set(label.toLowerCase(), (counts.get(label.toLowerCase()) ?? 0) + 1);
    }
    return labels.map((label, index) => ({
        label: label && counts.get(label.toLowerCase()) > 1
            ? `${label} · ${ordinalLabel(facts[index].ordinal)}` : label,
        ordinal: facts[index].ordinal,
    }));
}

// A copy of the row with nothing personal left in what the popover renders:
// both label fields become `label`, and email addresses in the error text are
// redacted. usage.identity stays: it is never rendered, and the Claude plan
// badge matches on it.
export function scrubRow(row, label) {
    const copy = {...row};
    if ('account' in copy)
        copy.account = label;
    if ('accountLabel' in copy)
        copy.accountLabel = label;
    if (typeof copy.error === 'string')
        copy.error = redactEmails(copy.error);
    else if (copy.error && typeof copy.error === 'object' && typeof copy.error.message === 'string')
        copy.error = {...copy.error, message: redactEmails(copy.error.message)};
    return copy;
}
