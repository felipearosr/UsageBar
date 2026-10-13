import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';

import {
    isSafeSvg,
    LOGO_PACK_FORMAT,
    logoPackAsset,
    logoPackState,
    logoPackUrl,
    parseChecksum,
    parseLogoPack,
    releaseVersion,
    wantsLogoPrompt,
} from '../usagebar@felipearosr.github.io/logopack.js';

const iconsDir = new URL('../usagebar@felipearosr.github.io/icons/', import.meta.url);
const SVG = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16"><path d="M0 0h16v16z"/></svg>';

function pack(overrides = {}) {
    return JSON.stringify({format: LOGO_PACK_FORMAT, version: '1.2.0', icons: {claude: SVG}, ...overrides});
}

test('releaseVersion turns the metadata version-name back into the release version', () => {
    assert.equal(releaseVersion('1.1.0'), '1.1.0');
    assert.equal(releaseVersion('1.1.0 rc.2'), '1.1.0-rc.2');
    assert.equal(releaseVersion('2.0.0 beta 2'), '2.0.0-beta-2');
    assert.equal(releaseVersion(undefined), null); // development checkout
    assert.equal(releaseVersion('dev'), null);
    assert.equal(releaseVersion('1.1.0 rc.2/../x'), null);
});

test('the pack is the release asset of the extension’s own release', () => {
    assert.equal(logoPackAsset('1.1.0-rc.2'), 'usagebar-provider-icons-1.1.0-rc.2.json');
    assert.equal(logoPackUrl('1.1.0-rc.2'),
        'https://github.com/felipearosr/UsageBar/releases/download/usagebar-v1.1.0-rc.2/' +
        'usagebar-provider-icons-1.1.0-rc.2.json');
});

test('parseChecksum reads a sha256sum line only when it names the asset', () => {
    const sum = 'a'.repeat(64);
    assert.equal(parseChecksum(`${sum}  pack.json\n`, 'pack.json'), sum);
    assert.equal(parseChecksum(`${sum} *pack.json`, 'pack.json'), sum);
    assert.equal(parseChecksum(`${sum}  other.json`, 'pack.json'), null);
    assert.equal(parseChecksum('not a checksum', 'pack.json'), null);
    assert.equal(parseChecksum(null, 'pack.json'), null);
});

test('isSafeSvg accepts plain SVGs and rejects anything that reaches outside', () => {
    assert.ok(isSafeSvg(SVG));
    assert.ok(isSafeSvg(`<?xml version="1.0"?>\n<!DOCTYPE svg PUBLIC "-//W3C//DTD SVG 1.1//EN" ` +
        `"http://www.w3.org/Graphics/SVG/1.1/DTD/svg11.dtd">\n${SVG}`));
    assert.ok(isSafeSvg('<svg><defs><path id="a"/></defs><use href="#a"/></svg>'));
    for (const bad of [
        '',
        'hello',
        '<html><svg/></html>',
        '<svg><script>alert(1)</script></svg>',
        '<svg onload="x()"></svg>',
        '<svg><foreignObject/></svg>',
        '<!DOCTYPE svg [<!ENTITY x SYSTEM "file:///etc/passwd">]><svg>&x;</svg>',
        '<svg><image href="https://example.com/a.png"/></svg>',
        '<svg><use xlink:href="file:///tmp/a.svg#b"/></svg>',
        `<svg>${'x'.repeat(70000)}</svg>`,
    ])
        assert.equal(isSafeSvg(bad), false, bad.slice(0, 60));
});

test('every bundled logo passes the same check the download does', () => {
    const files = fs.readdirSync(iconsDir).filter(name => /^ProviderIcon-.*\.svg$/.test(name));
    assert.ok(files.length > 0);
    for (const name of files)
        assert.ok(isSafeSvg(fs.readFileSync(new URL(name, iconsDir), 'utf8')), name);
});

test('parseLogoPack returns the icons of a well-formed pack', () => {
    assert.deepEqual(parseLogoPack(pack(), '1.2.0'), {version: '1.2.0', icons: [['claude', SVG]]});
});

test('parseLogoPack rejects broken, foreign or unsafe packs', () => {
    const cases = [
        ['{', /valid JSON/],
        [pack({format: 2}), /format 2/],
        [pack({version: '1.1.0'}), /for version 1\.1\.0, expected 1\.2\.0/],
        [pack({icons: {}}), /0 logos/],
        [pack({icons: {'../claude': SVG}}), /bad provider id/],
        [pack({icons: {claude: '<svg><script/></svg>'}}), /claude logo/],
        ['x'.repeat(3 * 1024 * 1024), /too large/],
    ];
    for (const [text, message] of cases)
        assert.throws(() => parseLogoPack(text, '1.2.0'), message);
});

test('logoPackState offers only the actions that make sense', () => {
    assert.deepEqual(logoPackState({bundled: true, installed: null, version: '1.2.0'}).actions, []);
    assert.deepEqual(logoPackState({bundled: false, installed: null, version: '1.2.0'}).actions,
        ['download']);
    assert.deepEqual(logoPackState({bundled: false, installed: '1.2.0', version: '1.2.0'}).actions,
        ['remove']);
    const outdated = logoPackState({bundled: false, installed: '1.1.0', version: '1.2.0'});
    assert.deepEqual(outdated.actions, ['update', 'remove']);
    assert.match(outdated.status, /1\.1\.0.*1\.2\.0 available/);
    assert.deepEqual(logoPackState({bundled: false, installed: null, version: null}).actions, []);
});

test('the popover asks only when logos are missing and the user hasn’t declined', () => {
    const base = {bundled: false, installed: null, version: '1.2.0', dismissed: false};
    assert.equal(wantsLogoPrompt(base), true);
    assert.equal(wantsLogoPrompt({...base, bundled: true}), false);
    assert.equal(wantsLogoPrompt({...base, installed: '1.1.0'}), false); // no nagging after updates
    assert.equal(wantsLogoPrompt({...base, version: null}), false);
    assert.equal(wantsLogoPrompt({...base, dismissed: true}), false);
});
