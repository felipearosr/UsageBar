import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';

import {
    DEFAULT_PANEL_POSITION,
    PANEL_POSITIONS,
    panelPlacement,
} from '../usagebar@felipearosr.github.io/panelposition.js';

const extensionDir = new URL('../usagebar@felipearosr.github.io/', import.meta.url);
const read = name => fs.readFileSync(new URL(name, extensionDir), 'utf8');

test('each position maps to a panel box and a slot in it', () => {
    assert.deepEqual(panelPlacement('left-start'), {box: 'left', index: 0});
    assert.deepEqual(panelPlacement('left-end'), {box: 'left', index: -1});
    assert.deepEqual(panelPlacement('center-start'), {box: 'center', index: 0});
    assert.deepEqual(panelPlacement('center-end'), {box: 'center', index: -1});
    assert.deepEqual(panelPlacement('right'), {box: 'right', index: 0});
    assert.deepEqual(panelPlacement('right-end'), {box: 'right', index: -1});
});

test('the default keeps existing installs where they were', () => {
    // Before the setting, addToStatusArea ran with no position or box:
    // index 0 of the right box.
    assert.equal(DEFAULT_PANEL_POSITION, 'right');
    assert.deepEqual(panelPlacement(DEFAULT_PANEL_POSITION), {box: 'right', index: 0});
});

test('an unknown value falls back to the default', () => {
    assert.deepEqual(panelPlacement('top'), {box: 'right', index: 0});
    assert.deepEqual(panelPlacement(''), {box: 'right', index: 0});
    assert.deepEqual(panelPlacement(undefined), {box: 'right', index: 0});
});

test('every position has a unique value and label', () => {
    assert.equal(new Set(PANEL_POSITIONS.map(p => p.value)).size, PANEL_POSITIONS.length);
    assert.equal(new Set(PANEL_POSITIONS.map(p => p.label)).size, PANEL_POSITIONS.length);
    for (const p of PANEL_POSITIONS) {
        assert.ok(['left', 'center', 'right'].includes(p.box), p.value);
        assert.ok(p.index === 0 || p.index === -1, p.value);
    }
});

test('the schema offers exactly these positions, defaulting to right', () => {
    const schema = read('schemas/org.gnome.shell.extensions.usagebar.gschema.xml');
    const key = schema.match(/<key name="panel-position" type="s">([\s\S]*?)<\/key>/);
    assert.ok(key, 'panel-position key missing');
    const choices = [...key[1].matchAll(/<choice value="([^"]+)"\/>/g)].map(m => m[1]);
    assert.deepEqual(choices, PANEL_POSITIONS.map(p => p.value));
    assert.match(key[1], new RegExp(`<default>'${DEFAULT_PANEL_POSITION}'</default>`));
});
