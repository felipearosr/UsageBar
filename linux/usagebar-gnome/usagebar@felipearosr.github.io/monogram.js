// Brand-free provider marks. The extensions.gnome.org build ships without
// provider logos, so a provider whose logo file is missing is drawn as a
// short monogram on a badge in its brand color. Pure helpers: no GJS imports,
// so node tests can load them.

const FALLBACK_COLOR = '#6b7280';

// Two characters that identify a provider by its display name:
//   multi-word names  -> word initials        ("OpenCode Go" -> "OG")
//   camel-cased names -> capital initials     ("DeepSeek"    -> "DS")
//   other names       -> first two letters    ("Claude"      -> "Cl")
// Parenthetical notes are ignored ("Kimi K2 (unofficial)" -> "KK").
export function providerMonogram(name, fallback = '') {
    const clean = String(name || fallback || '?').replace(/\([^)]*\)/g, ' ');
    const words = clean.split(/[^\p{L}\p{N}]+/u).filter(Boolean);
    if (!words.length)
        return '?';
    if (words.length >= 2)
        return (words[0][0] + words[1][0]).toUpperCase();
    const word = words[0];
    const capitals = [...word.slice(1)].filter(ch => /\p{Lu}/u.test(ch));
    if (/\p{Lu}/u.test(word[0]) && capitals.length)
        return word[0] + capitals[0];
    return word[0].toUpperCase() + (word[1] ?? '').toLowerCase();
}

function normalizeHex(color) {
    const match = /^#?([0-9a-f]{3}|[0-9a-f]{6})$/i.exec(String(color ?? '').trim());
    if (!match)
        return null;
    const hex = match[1].length === 3
        ? [...match[1]].map(ch => ch + ch).join('')
        : match[1];
    return `#${hex.toLowerCase()}`;
}

// Text color that stays readable on the badge: dark on light brand colors
// (e.g. white or near-white), white on everything else.
export function monogramTextColor(background) {
    const hex = normalizeHex(background) ?? FALLBACK_COLOR;
    const channel = i => {
        const c = parseInt(hex.slice(i, i + 2), 16) / 255;
        return c <= 0.03928 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4;
    };
    const luminance = 0.2126 * channel(1) + 0.7152 * channel(3) + 0.0722 * channel(5);
    return luminance > 0.4 ? '#1a1a1a' : '#ffffff';
}

// Everything the badge needs, sized for an icon slot of `size` px.
export function monogramBadge(meta, provider, size) {
    const background = normalizeHex(meta?.color) ?? FALLBACK_COLOR;
    return {
        text: providerMonogram(meta?.name, provider),
        background,
        foreground: monogramTextColor(background),
        fontPx: Math.max(7, Math.round(size * 0.62)),
        radiusPx: Math.max(2, Math.round(size / 4)),
    };
}
