// Plan tag text for a provider row — pure, no gi:// imports, so node can test it.
//
// Claude Code keeps Anthropic's current plan label in its account config
// (`oauthAccount.planDisplayName`, e.g. "Ultra"), while the CLI payload derives
// one from raw tier codes ("Claude Max 20x"), which lags Anthropic's renames.
// The cached label wins only when the config describes the same plan family
// as the row, so a different signed-in account never relabels this one.

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

// {name, family} from Claude's account config text, or null when the config
// is unreadable or carries no usable label.
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
    return {name, family};
}

// The row's raw plan — the payload carries loginMethod on usage or under
// usage.identity, depending on the source.
export function planOf(row) {
    return row.usage?.loginMethod ?? row.usage?.identity?.loginMethod;
}

// Copy of rows with the Claude row's display plan set when the account
// config agrees with the row's own plan family, and cleared otherwise.
export function withClaudePlanName(rows, accountPlan) {
    return rows.map(row => {
        if (row.provider !== 'claude')
            return row;
        const {planDisplayName: _previous, ...rest} = row;
        const words = String(planOf(rest) ?? '').toLowerCase().split(/[^a-z0-9]+/);
        return accountPlan && words.includes(accountPlan.family)
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
