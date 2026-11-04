import test from 'node:test';
import assert from 'node:assert/strict';

import {
    claudeAccountConfigPaths,
    parseClaudeAccountPlan,
    planLabel,
    withClaudePlanName,
} from '../usagebar@felipearosr.github.io/planlabel.js';
import {PROVIDER_META} from '../usagebar@felipearosr.github.io/providermeta.js';

const claudeRow = loginMethod => ({provider: 'claude', usage: {loginMethod}});
const config = oauthAccount => JSON.stringify({oauthAccount});

test('account config paths follow Claude Code lookup order', () => {
    assert.deepEqual(claudeAccountConfigPaths({}, '/home/u'),
        ['/home/u/.claude/.config.json', '/home/u/.claude.json']);
    assert.deepEqual(claudeAccountConfigPaths({CLAUDE_CONFIG_DIR: '/p'}, '/home/u'),
        ['/p/.config.json', '/p/.claude.json']);
    // Relative roots resolve against Claude's CWD, which the extension can't know.
    assert.deepEqual(claudeAccountConfigPaths({CLAUDE_CONFIG_DIR: 'rel'}, '/home/u'),
        ['/home/u/.claude/.config.json', '/home/u/.claude.json']);
});

test('parses the cached plan label with its family', () => {
    assert.deepEqual(
        parseClaudeAccountPlan(config({planDisplayName: ' Ultra ', organizationType: 'claude_max'})),
        {name: 'Ultra', family: 'max'});
});

test('rejects configs without a usable label', () => {
    assert.equal(parseClaudeAccountPlan('not json'), null);
    assert.equal(parseClaudeAccountPlan(config({organizationType: 'claude_max'})), null);
    assert.equal(parseClaudeAccountPlan(config({planDisplayName: 'Ultra'})), null);
    assert.equal(parseClaudeAccountPlan(config({planDisplayName: 'x'.repeat(40), organizationType: 'claude_max'})),
        null);
    assert.equal(parseClaudeAccountPlan('{}'), null);
});

test('cached label replaces the derived Claude plan when families match', () => {
    const [row] = withClaudePlanName([claudeRow('Claude Max 20x')], {name: 'Ultra', family: 'max'});
    assert.equal(planLabel(row, 'Claude'), 'Ultra');
});

test('cached label is ignored for a different plan family or provider', () => {
    const plan = {name: 'Ultra', family: 'max'};
    const [pro] = withClaudePlanName([claudeRow('Claude Pro')], plan);
    assert.equal(planLabel(pro, 'Claude'), 'Pro');
    const [codex] = withClaudePlanName([{provider: 'codex', usage: {loginMethod: 'max'}}], plan);
    assert.equal(planLabel(codex, 'Codex'), 'Max');
});

test('a missing config clears a previously applied label', () => {
    const [labelled] = withClaudePlanName([claudeRow('Claude Max 20x')], {name: 'Ultra', family: 'max'});
    const [cleared] = withClaudePlanName([labelled], null);
    assert.equal(planLabel(cleared, 'Claude'), 'Max 20x');
});

test('plan label strips the provider prefix and capitalizes', () => {
    assert.equal(planLabel(claudeRow('Claude Max 5x'), 'Claude'), 'Max 5x');
    assert.equal(planLabel({provider: 'codex', usage: {identity: {loginMethod: 'plus'}}}, 'Codex'), 'Plus');
});

test('auth-method values and empty plans show no tag', () => {
    for (const value of ['API key', 'Browser session', 'api', '', undefined])
        assert.equal(planLabel({provider: 'x', usage: {loginMethod: value}}, 'X'), '');
});

test('provider plan tables turn raw codes into display names', () => {
    const codex = PROVIDER_META.codex.planLabels;
    const row = loginMethod => ({provider: 'codex', usage: {loginMethod}});
    assert.equal(planLabel(row('prolite'), 'Codex', codex), 'Pro 5x');
    assert.equal(planLabel(row(' Pro '), 'Codex', codex), 'Pro 20x');
    // Unknown codes keep the capitalised fallback.
    assert.equal(planLabel(row('newtier'), 'Codex', codex), 'Newtier');
});

test('the cached Claude label wins over the plan table', () => {
    const [row] = withClaudePlanName([claudeRow('Claude Max 20x')], {name: 'Ultra', family: 'max'});
    assert.equal(planLabel(row, 'Claude', PROVIDER_META.claude.planLabels), 'Ultra');
    assert.equal(planLabel(claudeRow('Claude Max 20x'), 'Claude', PROVIDER_META.claude.planLabels), 'Max 20x');
});
