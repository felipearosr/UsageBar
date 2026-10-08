// Brand-colored provider names. The extensions.gnome.org build ships without
// provider logos, so where a logo would stand alone the provider's name is
// printed instead, in its brand color adjusted to stay readable on the
// surface behind it. Pure helpers: no GJS imports, so node tests can load them.

const FALLBACK_COLOR = '#6b7280';

// Longest name printed in place of a logo; longer ones are cut with an
// ellipsis. Every known provider fits except "Kimi K2 (unofficial)" and
// "Moonshot / Kimi API"; the cap is for names the CLI adds later.
export const NAME_MAX_CHARS = 18;

export function capName(name, max = NAME_MAX_CHARS) {
    const text = String(name ?? '').trim();
    const chars = [...text];
    if (chars.length <= max)
        return text;
    return `${chars.slice(0, max - 1).join('').trimEnd()}…`;
}

// WCAG AA contrast for normal-size text.
export const MIN_NAME_CONTRAST = 4.5;

export function normalizeHex(color) {
    const match = /^#?([0-9a-f]{3}|[0-9a-f]{6})$/i.exec(String(color ?? '').trim());
    if (!match)
        return null;
    const hex = match[1].length === 3
        ? [...match[1]].map(ch => ch + ch).join('')
        : match[1];
    return `#${hex.toLowerCase()}`;
}

function channels(hex) {
    return [1, 3, 5].map(i => parseInt(hex.slice(i, i + 2), 16));
}

export function rgbToHex(r, g, b) {
    return `#${[r, g, b].map(c => Math.round(Math.min(255, Math.max(0, c)))
        .toString(16).padStart(2, '0')).join('')}`;
}

// WCAG relative luminance of a #rrggbb color, 0 (black) to 1 (white).
export function relativeLuminance(color) {
    const hex = normalizeHex(color) ?? FALLBACK_COLOR;
    const [r, g, b] = channels(hex).map(c => {
        const v = c / 255;
        return v <= 0.03928 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4;
    });
    return 0.2126 * r + 0.7152 * g + 0.0722 * b;
}

export function contrastRatio(a, b) {
    const [hi, lo] = [relativeLuminance(a), relativeLuminance(b)].sort((x, y) => y - x);
    return (hi + 0.05) / (lo + 0.05);
}

function mix(from, to, t) {
    const a = channels(from);
    const b = channels(to);
    return rgbToHex(...a.map((c, i) => c + (b[i] - c) * t));
}

// The provider's brand color, or the closest tint of it (toward white on dark
// surfaces, toward black on light ones) that reaches `minRatio` contrast
// against `surface`.
export function readableBrandColor(color, surface, minRatio = MIN_NAME_CONTRAST) {
    const brand = normalizeHex(color) ?? FALLBACK_COLOR;
    const bg = normalizeHex(surface) ?? '#000000';
    if (contrastRatio(brand, bg) >= minRatio)
        return brand;
    const target = contrastRatio('#ffffff', bg) >= contrastRatio('#000000', bg)
        ? '#ffffff' : '#000000';
    for (let step = 1; step <= 20; step++) {
        const tint = mix(brand, target, step / 20);
        if (contrastRatio(tint, bg) >= minRatio)
            return tint;
    }
    return target;
}

// The color a surface's text sits on: its background when that is mostly
// opaque, else black or white opposite its (theme-chosen) text color.
export function surfaceColor(background, foreground) {
    if (background && background.alpha >= 128)
        return rgbToHex(background.red, background.green, background.blue);
    if (foreground) {
        const fg = rgbToHex(foreground.red, foreground.green, foreground.blue);
        return relativeLuminance(fg) > 0.5 ? '#000000' : '#ffffff';
    }
    return '#000000';
}
