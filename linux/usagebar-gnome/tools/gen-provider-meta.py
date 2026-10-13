#!/usr/bin/env python3
"""Regenerate providermeta.js from Swift provider descriptors and legacy entries.

ProviderMetadata and PluginProviderSpec supply literal strings and brand colors.
The three curated legacy entries retain links for older CLIs; current descriptors
always take precedence. Kimi's known China console expression is resolved from
KimiRegion.swift with bounded syntax guards. Other expressions remain absent.
No generated output is ever used as input.

Usage (from the repo root):
    python3 linux/usagebar-gnome/tools/gen-provider-meta.py [--check]
"""

import argparse
import difflib
import glob
import itertools
import json
import os
import re
import sys

REPO = os.path.normpath(os.path.join(os.path.dirname(__file__), '..', '..', '..'))
DESCRIPTOR_GLOB = os.path.join(
    REPO, 'Sources', 'CodexBarCore', 'Providers', '*', '*ProviderDescriptor.swift')
OUT = os.path.join(
    REPO, 'linux', 'usagebar-gnome', 'usagebar@felipearosr.github.io', 'providermeta.js')

# Feed shapes the extension's status strip can parse. statuspage is derived
# from statusPageURL; entries here override that, keyed by status-page URL so
# every provider on the page inherits the fix (incident.io pages whose
# statuspage-compat API strips component tags need their native feed).
STATUS_FEED_OVERRIDES = {
    'https://status.openai.com': {
        'kind': 'incidentio',
        'base': 'https://status.openai.com/proxy/status.openai.com'},
}

# Status-strip scopes per provider: which slices of the status page the
# strip can track. Curated — component/group names are judgment calls per
# page; the first entry is the provider's default. Providers absent here
# (or without a feed) track 'Everything'.
STATUS_SCOPES = {
    'codex': ['Codex', 'APIs', 'ChatGPT', 'Everything'],
    'claude': ['Claude Code', 'Claude API', 'claude.ai', 'Claude Console', 'Everything'],
}

# Explicit compatibility data approved for older CLIs on 2026-10-13. These
# providers no longer have descriptors. Do not infer this from providermeta.js.
LEGACY_META = {
    'crof': {'name': 'Crof', 'dashboard': 'https://crof.ai/dashboard', 'color': '#2eab94'},
    'crossmodel': {
        'name': 'CrossModel', 'dashboard': 'https://crossmodel.ai/console/usage', 'color': '#7c3aed'},
    'kimik2': {
        'name': 'Kimi K2 (unofficial)', 'dashboard': 'https://kimrel.com/my-credits', 'color': '#4c00ff'},
}

STR_FIELDS = {
    'displayName': 'name',
    'dashboardURL': 'dashboard',
    'subscriptionDashboardURL': 'subscriptionDashboard',
    'statusPageURL': 'statusPage',
    'statusLinkURL': 'statusLink',
}


def spec_block(src):
    """The first supported descriptor call, by paren depth."""
    match = re.search(r'(?:ProviderMetadata|PluginProviderSpec)\(', src)
    if not match:
        return None
    start = match.start()
    i = match.end()
    depth = 1
    while i < len(src) and depth:
        if src[i] == '(':
            depth += 1
        elif src[i] == ')':
            depth -= 1
        i += 1
    return src[start:i]


def str_field(block, field):
    m = re.search(rf'\b{field}:\s*"((?:[^"\\]|\\.)*)"', block)
    return m.group(1) if m else None


def color_field(src):
    hex_color = re.search(r'(?:ProviderColor|\.init)\(\s*hex:\s*0x([0-9A-Fa-f]{6})\s*\)', src)
    if hex_color:
        return '#' + hex_color.group(1).lower()
    m = re.search(
        r'(?:ProviderColor|\.init)\(\s*red:\s*([\d.]+(?:\s*/\s*255)?),'
        r'\s*green:\s*([\d.]+(?:\s*/\s*255)?),'
        r'\s*blue:\s*([\d.]+(?:\s*/\s*255)?)\s*\)', src)
    if not m:
        return None
    vals = []
    for raw in m.groups():
        # "0 / 255" keeps the numerator; a bare float like 0.75 is 0-1 scale.
        num = float(raw.split('/')[0])
        vals.append(int(round(num if '/' in raw else num * 255)))
    return '#{:02x}{:02x}{:02x}'.format(*(min(255, max(0, v)) for v in vals))


def descriptor_color(src, block):
    """Prefer the brand argument; never substitute widget colors for it."""
    argument = r'(?<![\w])color:\s*((?:ProviderColor|\.init)\([^)]*\))'
    for text in (block, src):
        own = re.search(argument, text)
        if own:
            return color_field(own.group(1))
        if re.search(r'(?<![\w])color\s*:', text):
            return None  # Unsupported brand expression must not fall through.
    # Older classic descriptors can keep an unlabelled constructor elsewhere.
    without_widgets = re.sub(
        r'\b\w*Color\s*:\s*(?:ProviderColor|\.init)\([^)]*\)', '', src)
    return color_field(without_widgets)


def kimi_dashboard(block, region_path):
    """Resolve only the known China domain -> web base -> console URL chain.

    Fail closed if its descriptor expression or any relevant property changes
    shape. Literal domain/path changes are reflected in the generated URL.
    """
    if not re.search(r'\bdashboardURL:\s*KimiRegion\.china\.consoleURL\.absoluteString\s*,', block):
        raise ValueError('unsupported Kimi dashboard expression; update the bounded resolver')
    with open(region_path, encoding='utf-8') as f:
        src = f.read()

    def property_body(name, type_name):
        match = re.search(rf'public var {name}: {type_name}\s*\{{([^{{}}]*)\}}', src)
        if not match:
            raise ValueError(f'unsupported KimiRegion.{name}; update the bounded resolver')
        return match.group(1).strip()

    domain = re.fullmatch(
        r'self\s*==\s*\.china\s*\?\s*"([a-z0-9.-]+)"\s*:\s*"[a-z0-9.-]+"',
        property_body('domain', 'String'))
    web_base = re.fullmatch(
        r'URL\(string:\s*"https://www\.\\\(self\.domain\)"\)!', property_body('webBaseURL', 'URL'))
    console = re.fullmatch(
        r'self\.webBaseURL\.appendingPathComponent\("([a-zA-Z0-9-]+(?:/[a-zA-Z0-9-]+)*)"\)',
        property_body('consoleURL', 'URL'))
    if not (domain and web_base and console):
        raise ValueError('unsupported KimiRegion URL chain; update the bounded resolver')
    return f'https://www.{domain.group(1)}/{console.group(1)}'


def parse(path):
    with open(path, encoding='utf-8') as f:
        src = f.read()
    block = spec_block(src)
    if not block:
        return None
    pid = re.search(r'\bid:\s*\.(\w+)', block)
    if not pid:
        return None
    entry = {}
    for swift, js in STR_FIELDS.items():
        val = str_field(block, swift)
        if val:
            entry[js] = val
    color = descriptor_color(src, block)
    if color:
        entry['color'] = color
    provider = pid.group(1)
    if provider == 'kimi' and 'dashboard' not in entry:
        entry['dashboard'] = kimi_dashboard(block, os.path.join(os.path.dirname(path), 'KimiRegion.swift'))
    page = (entry.get('statusPage') or '').rstrip('/')
    feed = STATUS_FEED_OVERRIDES.get(page)
    if not feed and page:
        feed = {'kind': 'statuspage', 'base': page}
    if feed:
        entry['statusFeed'] = feed
        scopes = STATUS_SCOPES.get(provider)
        if scopes:
            entry['statusScopes'] = scopes
    return provider, entry


def render(meta):
    lines = [
        '// GENERATED by linux/usagebar-gnome/tools/gen-provider-meta.py; do not edit.',
        '// Inputs: Swift provider descriptors, KimiRegion.swift and curated LEGACY_META in the generator.',
        '// Regenerate after syncing with upstream:',
        '//   python3 linux/usagebar-gnome/tools/gen-provider-meta.py',
        '',
        '/* eslint-disable */',
        f'export const PROVIDER_META = {json.dumps(dict(sorted(meta.items())), indent=4, ensure_ascii=False)};',
    ]
    return '\n'.join(lines) + '\n'


def main(argv=None, *, descriptor_glob=DESCRIPTOR_GLOB, out=OUT):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true', help='fail if the table is stale')
    args = parser.parse_args(argv)
    paths = sorted(glob.glob(descriptor_glob))
    if not paths:
        sys.exit(f'no descriptors found under {descriptor_glob}')
    meta = {provider: dict(entry) for provider, entry in LEGACY_META.items()}
    seen = set()
    for path in paths:
        parsed = parse(path)
        if not parsed:
            print(f'warning: no ProviderMetadata/PluginProviderSpec in {path}', file=sys.stderr)
            continue
        provider, entry = parsed
        if provider in seen:
            print(f'warning: duplicate provider {provider} from {path}', file=sys.stderr)
        seen.add(provider)
        meta[provider] = entry

    content = render(meta)
    if args.check:
        try:
            with open(out, encoding='utf-8') as f:
                current = f.read()
        except FileNotFoundError:
            current = ''
        if current == content:
            print('providermeta.js is current')
            return 0
        print('providermeta.js is stale; run: python3 linux/usagebar-gnome/tools/gen-provider-meta.py',
              file=sys.stderr)
        diff = difflib.unified_diff(current.splitlines(), content.splitlines(),
                                    fromfile=out, tofile='generated', lineterm='')
        print('\n'.join(itertools.islice(diff, 20)), file=sys.stderr)
        return 1
    with open(out, 'w', encoding='utf-8') as f:
        f.write(content)
    print(f'{len(meta)} providers -> {os.path.relpath(out, REPO)}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
