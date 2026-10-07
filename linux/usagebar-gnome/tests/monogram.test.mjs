import test from 'node:test';
import assert from 'node:assert/strict';

import {PROVIDER_META} from '../usagebar@felipearosr.github.io/providermeta.js';
import {
    MONOGRAM_OVERRIDES,
    monogramBadge,
    monogramFor,
    monogramTextColor,
    providerMonogram,
} from '../usagebar@felipearosr.github.io/monogram.js';

test('monograms use word initials, camel-case capitals, or the first two letters', () => {
    assert.equal(providerMonogram('OpenCode Go'), 'OG');
    assert.equal(providerMonogram('Kimi K2 (unofficial)'), 'KK');
    assert.equal(providerMonogram('Moonshot / Kimi API'), 'MK');
    assert.equal(providerMonogram('DeepSeek'), 'DS');
    assert.equal(providerMonogram('LiteLLM'), 'LL');
    assert.equal(providerMonogram('Claude'), 'Cl');
    assert.equal(providerMonogram('Codex'), 'Co');
    assert.equal(providerMonogram('sub2api'), 'Su');
    assert.equal(providerMonogram('z.ai'), 'ZA');
});

test('monograms fall back to the provider id, then a placeholder', () => {
    assert.equal(providerMonogram(undefined, 'newprovider'), 'Ne');
    assert.equal(providerMonogram('', ''), '?');
    assert.equal(providerMonogram('  ', 'x'), '?');
});

test('every known provider gets a short readable monogram', () => {
    for (const [id, meta] of Object.entries(PROVIDER_META)) {
        const text = providerMonogram(meta.name, id);
        assert.ok(text.length >= 1 && text.length <= 2, `${id}: ${text}`);
        assert.match(text, /^[\p{L}\p{N}?]+$/u, id);
    }
});

test('every known provider has a unique monogram', () => {
    const owners = new Map();
    for (const [id, meta] of Object.entries(PROVIDER_META)) {
        const text = monogramFor(id, meta.name);
        assert.ok(!owners.has(text), `${id} and ${owners.get(text)} both show "${text}"`);
        owners.set(text, id);
    }
});

test('overrides replace the computed monogram and name known providers', () => {
    assert.equal(monogramFor('codex', 'Codex'), 'Cx');
    assert.equal(monogramBadge(PROVIDER_META.codex, 'codex', 14).text, 'Cx');
    assert.equal(monogramFor('claude', 'Claude'), 'Cl');
    for (const [id, text] of Object.entries(MONOGRAM_OVERRIDES)) {
        assert.ok(PROVIDER_META[id], `override for unknown provider ${id}`);
        assert.match(text, /^\p{Lu}\p{Ll}?$|^\p{Lu}{2}$/u, id);
    }
});

test('badge text contrasts with the brand color', () => {
    assert.equal(monogramTextColor('#ffffff'), '#1a1a1a');
    assert.equal(monogramTextColor('#ebebe6'), '#1a1a1a');
    assert.equal(monogramTextColor('#44ff00'), '#1a1a1a');
    assert.equal(monogramTextColor('#000000'), '#ffffff');
    assert.equal(monogramTextColor('#cc7c5e'), '#ffffff');
    assert.equal(monogramTextColor('nonsense'), '#ffffff');
});

test('badge falls back to a neutral color and scales with the icon slot', () => {
    const badge = monogramBadge(undefined, 'mystery', 14);
    assert.equal(badge.text, 'My');
    assert.equal(badge.background, '#6b7280');
    assert.equal(badge.fontPx, 9);
    assert.equal(monogramBadge({name: 'Claude', color: '#CC7C5E'}, 'claude', 20).background, '#cc7c5e');
    assert.ok(monogramBadge(PROVIDER_META.claude, 'claude', 12).fontPx >= 7);
});
