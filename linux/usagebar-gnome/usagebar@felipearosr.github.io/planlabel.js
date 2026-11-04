// Plan tag text for a provider row — pure, no gi:// imports, so node can test it.
//
// Claude Code keeps Anthropic's current plan label in its account config
// (`oauthAccount.planDisplayName`, e.g. "Ultra"), while the CLI payload derives
// one from raw tier codes ("Claude Max 20x"), which lags Anthropic's renames.
// The cached label applies only to the row of the same account: matching
// email when both sides carry one, else the only Claude row; and only when
// the config describes the row's own plan family.

const MAX_PLAN_CHARS = 24;

// loginMethod values that name how the user authenticated, not a plan.
const AUTH_ONLY = new Set([
    'api', 'api key', 'browser', 'browser session', 'dashboard session', 'oauth',
]);

// Candidate account-config paths in Claude Code's own lookup order
// (mirrors CodexBarCore's ClaudeConfigPaths.accountConfigURL).
export function claudeAccountConfigPaths(env, home) {
    const configDir = env.CLAUDE_CONFIG_DIR;
    if (configDir && configDir.startsWith('/'))
        return [`${configDir}/.config.json`, `${configDir}/.claude.json`];
    return [`${home}/.claude/.config.json`, `${home}/.claude.json`];
}

// {name, family, email} from Claude's account config text, or null when the
// config is unreadable or carries no usable label. The email only matches
// rows; it is never displayed.
export function parseClaudeAccountPlan(text) {
    let account;
    try {
        account = JSON.parse(text)?.oauthAccount;
    } catch {
        return null;
    }
    const name = typeof account?.planDisplayName === 'string' ? account.planDisplayName.trim() : '';
    const orgType = typeof account?.organizationType === 'string' ? account.organizationType : '';
    const family = orgType.toLowerCase().replace(/^claude_/, '');
    if (!name || name.length > MAX_PLAN_CHARS || !family)
        return null;
    const email = typeof account?.emailAddress === 'string' ? account.emailAddress.trim().toLowerCase() : '';
    return {name, family, email};
}

// The row's raw plan — the payload carries loginMethod on usage or under
// usage.identity, depending on the source.
export function planOf(row) {
    return row.usage?.loginMethod ?? row.usage?.identity?.loginMethod;
}

function rowEmail(row) {
    return String(row.usage?.identity?.accountEmail ?? row.usage?.accountEmail ?? '')
        .trim().toLowerCase();
}

// Copy of rows with the cached Claude label applied to the row it belongs to,
// and cleared from every other Claude row (or all of them when accountPlan is
// null, e.g. after sign-out).
export function applyClaudeAccountPlan(rows, accountPlan) {
    const claudeRows = rows.filter(row => row.provider === 'claude').length;
    return rows.map(row => {
        if (row.provider !== 'claude')
            return row;
        const {planDisplayName: _previous, ...rest} = row;
        if (!accountPlan)
            return rest;
        const email = rowEmail(rest);
        const sameAccount = email && accountPlan.email ? email === accountPlan.email : claudeRows === 1;
        const words = String(planOf(rest) ?? '').toLowerCase().split(/[^a-z0-9]+/);
        return sameAccount && words.includes(accountPlan.family)
            ? {...rest, planDisplayName: accountPlan.name} : rest;
    });
}

// Tag text shown next to the provider name, or '' for none. `planLabels`
// is the provider's raw-plan → display-name table (CodexBarCore's
// sharePlanLabels, keyed by trimmed lowercase plan), e.g. "prolite" → "Pro 5x".
export function planLabel(row, displayName, planLabels = {}) {
    if (row.planDisplayName)
        return row.planDisplayName;
    let plan = String(planOf(row) ?? '').trim();
    const key = plan.toLowerCase();
    if (!plan || AUTH_ONLY.has(key))
        return '';
    if (Object.hasOwn(planLabels, key))
        return planLabels[key];
    plan = plan.charAt(0).toUpperCase() + plan.slice(1);
    // Drop a leading provider name ("Claude Max" → "Max"): the title says it.
    const name = String(displayName ?? '');
    if (name && plan.toLowerCase().startsWith(`${name.toLowerCase()} `))
        plan = plan.slice(name.length + 1);
    return plan;
}
