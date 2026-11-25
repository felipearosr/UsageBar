// Where the indicator sits in the top bar (the panel-position setting).
// Dependency-free so the Node tests can check it; extension.js maps the box
// name to Main.panel's box, prefs.js shows the labels.

// Order matches the Settings combo row, left to right across the top bar.
// index is the slot in the box: 0 is its start, -1 its end.
export const PANEL_POSITIONS = [
    {value: 'left-start', box: 'left', index: 0, label: 'Far left, before Activities'},
    {value: 'left-end', box: 'left', index: -1, label: 'Left, after Activities'},
    {value: 'center-start', box: 'center', index: 0, label: 'Center, left of the clock'},
    {value: 'center-end', box: 'center', index: -1, label: 'Center, right of the clock'},
    {value: 'right', box: 'right', index: 0, label: 'Right, before the other indicators'},
    {value: 'right-end', box: 'right', index: -1, label: 'Far right, after the system menu'},
];

// Where the indicator sat before this setting existed.
export const DEFAULT_PANEL_POSITION = 'right';

// {box, index} for a stored value; an unknown value gets the default.
export function panelPlacement(value) {
    const entry = PANEL_POSITIONS.find(p => p.value === value) ??
        PANEL_POSITIONS.find(p => p.value === DEFAULT_PANEL_POSITION);
    return {box: entry.box, index: entry.index};
}

