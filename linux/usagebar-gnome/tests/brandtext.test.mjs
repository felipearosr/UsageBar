import test from 'node:test';
import assert from 'node:assert/strict';

import {PROVIDER_META} from '../usagebar@felipearosr.github.io/providermeta.js';
import {
    MIN_NAME_CONTRAST,
    NAME_MAX_CHARS,
    capName,
    contrastRatio,
    normalizeHex,
    readableBrandColor,
    surfaceColor,
} from '../usagebar@felipearosr.github.io/brandtext.js';

// The GNOME top bar, the CodexBar-theme popover, and a light theme.
const SURFACES = ['#000000', '#161b22', '#ffffff', '#fafafa'];

test('every known provider has a display name to show in place of its logo', () => {
    for (const [id, meta] of Object.entries(PROVIDER_META))
        assert.ok(typeof meta.name === 'string' && meta.name.trim().length > 0, id);
});

test('names past the cap end in an ellipsis; shorter ones are printed whole', () => {
    assert.equal(capName('Claude'), 'Claude');
    assert.equal(capName('Alibaba Token Plan'), 'Alibaba Token Plan');
    assert.equal(capName('Moonshot / Kimi API'), 'Moonshot / Kimi A…');
    assert.equal(capName('Kimi K2 (unofficial)'), 'Kimi K2 (unoffici…');
    assert.equal(capName('A very long provider name', 10), 'A very lo…');
    // No dangling space before the ellipsis.
    assert.equal(capName('Abcdefgh ijk', 10), 'Abcdefgh…');
    for (const meta of Object.values(PROVIDER_META))
        assert.ok([...capName(meta.name)].length <= NAME_MAX_CHARS, meta.name);
});

test('every provider name is readable on dark and light surfaces', () => {
    for (const [id, meta] of Object.entries(PROVIDER_META)) {
        for (const surface of SURFACES) {
            const color = readableBrandColor(meta.color, surface);
            assert.match(color, /^#[0-9a-f]{6}$/);
            assert.ok(contrastRatio(color, surface) >= MIN_NAME_CONTRAST,
                `${id} on ${surface}: ${color}`);
        }
    }
});

test('readable brand colors are kept as they are', () => {
    assert.equal(readableBrandColor('#CC7C5E', '#000000'), '#cc7c5e');
    assert.equal(readableBrandColor('#ffffff', '#161b22'), '#ffffff');
});

test('unreadable brand colors are tinted toward the contrasting end', () => {
    // Black on the black panel turns grey-white; white on white turns dark.
    const onDark = readableBrandColor('#000000', '#000000');
    assert.ok(contrastRatio(onDark, '#000000') >= MIN_NAME_CONTRAST);
    assert.notEqual(onDark, '#ffffff');
    const onLight = readableBrandColor('#ffffff', '#ffffff');
    assert.ok(contrastRatio(onLight, '#ffffff') >= MIN_NAME_CONTRAST);
    assert.notEqual(onLight, '#000000');
});

test('missing or malformed colors fall back to a neutral grey', () => {
    assert.equal(normalizeHex('abc'), '#aabbcc');
    assert.equal(normalizeHex('red'), null);
    const color = readableBrandColor(undefined, '#000000');
    assert.ok(contrastRatio(color, '#000000') >= MIN_NAME_CONTRAST);
});

test('a surface is its opaque background, else the opposite of its text color', () => {
    assert.equal(surfaceColor({red: 22, green: 27, blue: 34, alpha: 250}, null), '#161b22');
    assert.equal(surfaceColor({red: 0, green: 0, blue: 0, alpha: 0},
        {red: 255, green: 255, blue: 255, alpha: 255}), '#000000');
    assert.equal(surfaceColor({red: 0, green: 0, blue: 0, alpha: 0},
        {red: 20, green: 20, blue: 20, alpha: 255}), '#ffffff');
    assert.equal(surfaceColor(null, null), '#000000');
});
