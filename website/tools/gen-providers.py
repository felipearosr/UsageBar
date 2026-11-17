#!/usr/bin/env python3
"""Writes the provider marquee into website/index.html and styles.css.

    website/tools/gen-providers.py

Copies each provider's icon from Sources/CodexBar/Resources into
website/assets/providers/, then replaces the markup between the
PROVIDERS-START/END comments in index.html and the CSS between the
PROVIDER-ICONS-START/END comments in styles.css. Edit BRANDS, ROW1 and ROW2
below to change which providers show and how each is colored.
"""
import json, pathlib, re, shutil
site = pathlib.Path(__file__).resolve().parent.parent
repo = site.parent
base = 'assets/providers'
icons_dir = repo / 'Sources/CodexBar/Resources'
dest = site / base
dest.mkdir(parents=True, exist_ok=True)
meta_js = (repo / 'linux/usagebar-gnome/usagebar@felipearosr.github.io/providermeta.js').read_text()
meta = json.loads(re.search(r'PROVIDER_META = (\{.*?\n\});', meta_js, re.S).group(1))

MONO = ('mono', None)  # white mark on a black tile, as these brands draw it
# id: (treatment, value). art = the repo's full-color brand artwork;
# ink = the mark in the brand color or gradient; tile = white mark on a brand-colored tile.
BRANDS = {
    'claude': ('art', 'Brand-ProviderIcon-claude.svg'),
    'codex': ('art', 'Brand-ProviderIcon-codex.png'),
    'gemini': ('ink', 'linear-gradient(135deg, #4796e3, #9177c7 55%, #ca6673)'),
    'copilot': MONO,
    'cursor': MONO,
    'openrouter': ('ink', '#6467f2'),
    'opencode': MONO,
    'zai': MONO,
    'kiro': ('tile', '#9046ff'),
    'mistral': ('art', 'Brand-ProviderIcon-mistral.svg'),
    'deepseek': ('ink', '#4d6bfe'),
    'grok': MONO,
    'windsurf': ('ink', '#34e8bb'),
    'warp': MONO,
    'ollama': MONO,
    'jetbrains': ('ink', 'linear-gradient(135deg, #ff318c, #6b57ff 55%, #087cfa)'),
    'amp': ('ink', '#f34e3f'),
    'augment': MONO,
    'factory': ('ink', '#ff6b35'),
    'kimi': MONO,
    'minimax': ('ink', 'linear-gradient(135deg, #e2167e, #fe603c)'),
    'perplexity': ('ink', '#22b8cd'),
    'groq': ('tile', '#f55036'),
    'vertexai': ('art', 'Brand-ProviderIcon-vertexai.svg'),
    'bedrock': ('art', 'Brand-ProviderIcon-bedrock.svg'),
    'elevenlabs': MONO,
    'venice': MONO,
    'zed': MONO,
}
ROW1 = ['claude', 'codex', 'gemini', 'copilot', 'cursor', 'openrouter', 'opencode', 'zai', 'kiro', 'mistral',
        'deepseek', 'grok', 'windsurf', 'warp']
ROW2 = ['ollama', 'jetbrains', 'amp', 'augment', 'factory', 'kimi', 'minimax', 'perplexity', 'groq', 'vertexai',
        'bedrock', 'elevenlabs', 'venice', 'zed']

css = []
def tile(pid):
    kind, value = BRANDS[pid]
    if kind == 'art':
        shutil.copy2(icons_dir / value, dest / value)
        icon = f'<img src="{base}/{value}" alt="" width="26" height="26">'
    else:
        icon = '<span class="prov-mark"></span>'
        shutil.copy2(icons_dir / f'ProviderIcon-{pid}.svg', dest / f'ProviderIcon-{pid}.svg')
        css.append(f'.p-{pid} .prov-mark{{-webkit-mask-image:url({base}/ProviderIcon-{pid}.svg);'
                   f'mask-image:url({base}/ProviderIcon-{pid}.svg)}}')
        if kind == 'ink':
            css.append(f'.p-{pid} .prov-mark{{background:{value}}}')
        elif kind == 'tile':
            css.append(f'.p-{pid} .prov-icon{{background:{value};border-color:transparent}}')
    return (f'<li class="prov p-{pid} is-{kind}"><span class="prov-icon">{icon}</span>'
            f'{meta[pid]["name"]}</li>')

def row(ids, cls):
    items = ''.join(tile(p) for p in ids)
    return (f'<div class="marquee{cls}"><ul class="track">{items}</ul>'
            f'<ul class="track" aria-hidden="true">{items}</ul></div>')

rows = row(ROW1, '') + '\n' + row(ROW2, ' marquee-reverse')
seen = set(); css = [c for c in css if not (c in seen or seen.add(c))]
section = f'''<section class="providers" aria-labelledby="providers-title">
<div class="wrap providers-head">
<h2 id="providers-title">60+ providers, one bar.</h2>
<p class="providers-sub">Subscriptions, API keys and credit balances, side by side. Turn on the ones you use.</p>
</div>
<div class="marquees">
{rows}
</div>
<p class="providers-all"><a class="btn btn-ghost" href="https://github.com/felipearosr/UsageBar/blob/main/docs/providers.md">See every provider</a></p>
</section>'''
def splice(path, start, end, body):
    text = path.read_text()
    i, j = text.index(start) + len(start), text.index(end)
    path.write_text(text[:i] + '\n' + body + '\n' + text[j:])

splice(site / 'index.html', '<!-- PROVIDERS-START -->', '    <!-- PROVIDERS-END -->', '    ' + section)
splice(site / 'styles.css', '/* PROVIDER-ICONS-START */', '/* PROVIDER-ICONS-END */', '\n'.join(css))
print(f'providers: {len(ROW1) + len(ROW2)} tiles, icons in {dest}')
