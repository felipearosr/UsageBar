import test from 'node:test';
import assert from 'node:assert/strict';

import {
    classifyError,
    describeIssue,
    formatAge,
    issuesReport,
    shortMessage,
    summarizeIssues,
    technicalDetails,
} from '../usagebar@felipearosr.github.io/providerissues.js';

const CODEX_EXPIRED = 'Codex connection failed: failed to fetch codex rate limits: ' +
    '{"error": {"message": "Provided authentication token is expired. Please try signing in again.", ' +
    '"type": "invalid_request_error", "code": "token_expired", "param": null}, "status": 401, ' +
    '"detail": {"code": "token_expired"}}';
const CLAUDE_RATE = 'Claude OAuth usage endpoint is rate limited by Anthropic. Try `claude logout && claude login`.';

test('classifies the errors seen in the popover', () => {
    assert.equal(classifyError({message: CODEX_EXPIRED, code: 1, kind: 'provider'}), 'auth_expired');
    assert.equal(classifyError({message: CLAUDE_RATE, code: 1}), 'rate_limited');
    assert.equal(classifyError({message: 'Not logged in. Run `codex login`.'}), 'auth_invalid');
    assert.equal(classifyError({message: 'Request timed out', code: 4}), 'offline');
    assert.equal(classifyError({message: 'anything', code: 4}), 'offline');
    assert.equal(classifyError({message: 'HTTP 503 Service Unavailable'}), 'provider_down');
    assert.equal(classifyError({message: 'Could not parse usage: unexpected key'}), 'unknown');
    assert.equal(classifyError('HTTP 429 Too Many Requests'), 'rate_limited');
});

test('shortMessage drops appended JSON bodies and caps length', () => {
    assert.equal(shortMessage(CODEX_EXPIRED), 'Codex connection failed: failed to fetch codex rate limits');
    assert.equal(shortMessage('line one\nline two'), 'line one');
    assert.equal(shortMessage('x'.repeat(200), 20).length, 20);
    assert.equal(shortMessage(undefined), '');
});

test('technicalDetails pretty-prints the embedded JSON body', () => {
    const text = technicalDetails({message: CODEX_EXPIRED, code: 1, kind: 'provider'});
    assert.match(text, /^kind: provider · exit code: 1\n/);
    assert.match(text, /"code": "token_expired"/);
    assert.match(text, /\n {2}"status": 401/);
    assert.equal(technicalDetails({message: 'plain'}), 'plain');
});

test('describeIssue gives a human summary and a login action for auth errors', () => {
    const issue = describeIssue({provider: 'codex', error: {message: CODEX_EXPIRED, code: 1}}, 'Codex');
    assert.equal(issue.label, 'Sign-in expired');
    assert.equal(issue.group, 'action');
    assert.deepEqual(issue.login, ['codex', 'login']);
    assert.doesNotMatch(issue.summary, /\{/);

    const stale = describeIssue({provider: 'claude', stale: true, error: {message: CLAUDE_RATE}}, 'Claude');
    assert.equal(stale.login, null);
    assert.match(stale.summary, /Showing last known data\.$/);

    assert.equal(describeIssue({provider: 'codex'}, 'Codex'), null);
});

test('summarizeIssues groups rows and words the banner', () => {
    const names = {codex: 'Codex', claude: 'Claude', gemini: 'Gemini'};
    const nameOf = id => names[id] ?? id;
    const healthy = {provider: 'opencode', usage: {}};
    const codex = {provider: 'codex', error: {message: CODEX_EXPIRED}};
    const claude = {provider: 'claude', error: {message: CLAUDE_RATE}};
    const gemini = {provider: 'gemini', error: {message: 'not signed in'}};

    const none = summarizeIssues([healthy], nameOf);
    assert.equal(none.total, 0);
    assert.equal(none.headline, null);

    const one = summarizeIssues([codex, healthy, claude], nameOf);
    assert.equal(one.headline, 'Codex needs you to sign in again');
    assert.equal(one.urgent, true);
    assert.equal(one.fix.provider, 'codex');
    assert.deepEqual(one.groups.retrying.map(i => i.provider), ['claude']);

    const two = summarizeIssues([codex, gemini, claude], nameOf);
    assert.equal(two.headline, '2 providers need you to act');
    assert.equal(two.fix.provider, 'codex');

    const quiet = summarizeIssues([claude], nameOf);
    assert.equal(quiet.urgent, false);
    assert.equal(quiet.headline, 'Claude: rate limited');
    assert.equal(quiet.fix, null);

    assert.match(issuesReport(two), /## Codex — Sign-in expired/);
});

test('formatAge buckets elapsed time', () => {
    const now = 10_000_000;
    assert.equal(formatAge(now - 5_000, now), 'just now');
    assert.equal(formatAge(now - 6 * 60_000, now), '6m ago');
    assert.equal(formatAge(now - 2 * 3_600_000, now), '2h ago');
    assert.equal(formatAge(now - 3 * 86_400_000, now), '3d ago');
});
