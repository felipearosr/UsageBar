#!/usr/bin/env python3
"""Generate the light palette at the end of stylesheet.css.

The popover is styled for a dark surface. When the app theme is "system" and
GNOME Shell uses its light style, the extension adds `usagebar-light` to the
popover, cost dashboard, tooltip and model table (setAppTheme), and this
block restyles them: every color in the stylesheet gets a light counterpart,
so a rule added later can't be forgotten (CI runs --check).

  neutral surfaces (navy, greys)  -> light surfaces of the same hue
  translucent white overlays      -> the same overlay in black
  text                            -> dark, and at least 4.5:1 on the surface
  saturated fills and tints       -> unchanged (severity, provider, accents)
  shadows                         -> half as strong

Usage: gen-light-theme.py [--check]
"""

import colorsys
import re
import sys
from pathlib import Path

STYLESHEET = Path(__file__).resolve().parent.parent / 'usagebar@felipearosr.github.io' / 'stylesheet.css'
BEGIN = '/* BEGIN generated light palette (tools/gen-light-theme.py) */'
END = '/* END generated light palette */'

# The light surface text must read on (the mapped navy, about #eef0f3).
SURFACE = (0.937, 0.945, 0.953)
MIN_CONTRAST = 4.5
# Actors setAppTheme marks: a rule on one of these gets a compound selector.
ROOTS = ('.usagebar-menu', '.usagebar-scope-layer', '.usagebar-tooltip', '.usagebar-model-table')
# The top bar keeps the shell's panel colors in either style.
PANEL = re.compile(r'usagebar-(chip|panel)')
# Dots draw their CSS `color` as a fill, not as text.
FILL_COLOR = re.compile(r'round-dot')
COLOR = re.compile(r'#[0-9a-fA-F]{6}\b|#[0-9a-fA-F]{3}\b|rgba?\([^)]*\)|\btransparent\b')
# Saturated fills normally keep their color, and text is darkened until it
# reads. The pace deficit red is pinned instead, so its fill and its text are
# the same darker red on the light surface: (selector, property) -> value.
# A rule takes an override only when every one of its selectors names it.
LIGHT_OVERRIDES = {
    ('.usagebar-pace-deficit', 'background-color'): '#c01c28',
    ('.usagebar-pace-deficit-text', 'color'): '#c01c28',
}


def parse(token):
    if token == 'transparent':
        return (0.0, 0.0, 0.0, 0.0)
    if token.startswith('#'):
        h = token[1:]
        if len(h) == 3:
            h = ''.join(c * 2 for c in h)
        return tuple(int(h[i:i + 2], 16) / 255 for i in (0, 2, 4)) + (1.0,)
    parts = [p.strip() for p in token[token.index('(') + 1:-1].split(',')]
    rgb = tuple(float(p) / 255 for p in parts[:3])
    return rgb + (float(parts[3]) if len(parts) > 3 else 1.0,)


def fmt(r, g, b, a):
    if a <= 0:
        return 'transparent'
    rgb = [round(max(0.0, min(1.0, x)) * 255) for x in (r, g, b)]
    if a >= 0.999:
        return '#%02x%02x%02x' % tuple(rgb)
    return 'rgba(%d, %d, %d, %s)' % (*rgb, ('%.3f' % a).rstrip('0').rstrip('.'))


def luminance(rgb):
    def lin(c):
        return c / 12.92 if c <= 0.03928 else ((c + 0.055) / 1.055) ** 2.4
    r, g, b = (lin(c) for c in rgb)
    return 0.2126 * r + 0.7152 * g + 0.0722 * b


def contrast(a, b):
    la, lb = sorted((luminance(a), luminance(b)), reverse=True)
    return (la + 0.05) / (lb + 0.05)


def over_surface(r, g, b, a):
    return tuple(c * a + s * (1 - a) for c, s in zip((r, g, b), SURFACE))


def neutral(h, l, s):
    return s < 0.3 or l > 0.88


def map_text(rgba):
    r, g, b, a = rgba
    if a <= 0:
        return 'transparent'
    h, l, s = colorsys.rgb_to_hls(r, g, b)
    if neutral(h, l, s):
        # White text becomes near-black (#1d1f21-ish), not pure black.
        l = 0.12 + (1 - l) * 0.88
    # Darken (and make opaque enough) until it reads on the light surface.
    for _ in range(200):
        rgb = colorsys.hls_to_rgb(h, l, s)
        if contrast(over_surface(*rgb, a), SURFACE) >= MIN_CONTRAST:
            break
        if l > 0.05:
            l -= 0.01
        else:
            a = min(1.0, a + 0.05)
    return fmt(*colorsys.hls_to_rgb(h, l, s), a)


def map_surface(rgba):
    r, g, b, a = rgba
    if a <= 0:
        return 'transparent'
    h, l, s = colorsys.rgb_to_hls(r, g, b)
    if not neutral(h, l, s):
        return fmt(r, g, b, a)
    if a >= 0.8:
        # An opaque surface: navy and charcoal turn into the light surface
        # of the same hue; mid greys (stale fills) stay.
        if l < 0.35:
            l = 1 - l * 0.5
            s = min(s, 0.18)
        return fmt(*colorsys.hls_to_rgb(h, l, s), a)
    # A translucent overlay or line: white becomes black, greys darken.
    return fmt(*colorsys.hls_to_rgb(h, min(1 - l, 0.45), s), a)


def map_shadow(value):
    def soften(match):
        r, g, b, a = parse(match.group(0))
        return fmt(r, g, b, a * 0.5)
    return COLOR.sub(soften, value)


def light_selector(selector):
    selector = re.sub(r'^\.usagebar-theme-system\s*', '', selector.strip())
    first = selector.split()[0]
    if first.startswith(ROOTS):
        return '.usagebar-light' + selector
    return '.usagebar-light ' + selector


def generate(css):
    css = css.split(BEGIN)[0].rstrip() + '\n'
    plain = re.sub(r'/\*.*?\*/', '', css, flags=re.S)
    out = []
    for match in re.finditer(r'([^{}]+)\{([^}]*)\}', plain):
        selectors = [' '.join(sel.split()) for sel in match.group(1).split(',')]
        selectors = [sel for sel in selectors if sel and not PANEL.search(sel)]
        if not selectors:
            continue
        fill = all(FILL_COLOR.search(sel) for sel in selectors)
        decls = []
        for decl in match.group(2).split(';'):
            if ':' not in decl:
                continue
            prop, value = (part.strip() for part in decl.split(':', 1))
            if not COLOR.search(value):
                continue
            overrides = {LIGHT_OVERRIDES.get((sel, prop)) for sel in selectors}
            if len(overrides) == 1 and None not in overrides:
                mapped = overrides.pop()
            elif prop == 'color':
                mapped = COLOR.sub(lambda m: fmt(*parse(m.group(0))) if fill else map_text(parse(m.group(0))), value)
            elif prop == 'box-shadow':
                mapped = map_shadow(value)
            elif prop.startswith('background') or prop.endswith('-color'):
                mapped = COLOR.sub(lambda m: map_surface(parse(m.group(0))), value)
            elif prop.startswith('border'):
                # A border shorthand: restate only its color, so a later
                # `border-width: 0` in the dark rules still wins.
                prop = f'{prop}-color'
                mapped = map_surface(parse(COLOR.search(value).group(0)))
            else:
                continue
            # Every color is restated, changed or not, so the light rules
            # cascade in the same order as the dark ones they shadow.
            decls.append(f'  {prop}: {mapped};')
        if decls:
            out.append(',\n'.join(light_selector(sel) for sel in selectors) + ' {\n' + '\n'.join(decls) + '\n}')
    return css + '\n' + BEGIN + '\n' + '\n\n'.join(out) + '\n' + END + '\n'


def main():
    current = STYLESHEET.read_text()
    fresh = generate(current)
    if '--check' in sys.argv[1:]:
        if fresh != current:
            print('stylesheet.css light palette is stale: run linux/usagebar-gnome/tools/gen-light-theme.py',
                  file=sys.stderr)
            sys.exit(1)
        return
    STYLESHEET.write_text(fresh)


if __name__ == '__main__':
    main()
