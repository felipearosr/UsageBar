#!/usr/bin/env python3
"""Build and lint the ZIP uploaded to extensions.gnome.org (EGO).

Usage (from anywhere):
    python3 linux/usagebar-gnome/tools/ego-zip.py build [--out DIR] [--version-name V]
    python3 linux/usagebar-gnome/tools/ego-zip.py lint ZIP

`build` packs an allowlist (the GJS modules reachable from extension.js and
prefs.js, stylesheet.css, metadata.json, the settings schema XML, UsageBar's
own symbolic icons and the repo LICENSE) into DIR/<uuid>.shell-extension.zip,
the name `gnome-extensions pack` uses, then lints it. Tests, tools, provider
logos and the compiled schema stay out: GNOME 44+ compiles schemas on
install.

`lint` checks the review guidelines that can be checked mechanically
(https://gjs.guide/extensions/review-guidelines/review-guidelines.html).
Errors fail with exit status 1; warnings are printed for a human reviewer
and don't change the exit status.

Python 3 stdlib only.
"""

import argparse
import json
import os
import re
import sys
import zipfile
import xml.etree.ElementTree as ET

HERE = os.path.dirname(os.path.abspath(__file__))
GNOME_DIR = os.path.dirname(HERE)
REPO = os.path.normpath(os.path.join(GNOME_DIR, '..', '..'))
UUID = 'usagebar@felipearosr.github.io'
SRC = os.path.join(GNOME_DIR, UUID)
LICENSE = os.path.join(REPO, 'LICENSE')
DEFAULT_OUT = os.path.join(REPO, 'linux', 'dist')

# UsageBar's own (non-brand) icons under icons/. Everything else there is a
# provider brand logo and stays out of the ZIP.
OWN_ICONS = (
    'usagebar-machine-symbolic.svg',
    'usagebar-machines-symbolic.svg',
)

# Paths allowed inside the ZIP, relative to its root.
ALLOWED = [
    re.compile(r'^[A-Za-z0-9_-]+\.js$'),
    re.compile(r'^stylesheet(-dark|-light)?\.css$'),
    re.compile(r'^metadata\.json$'),
    re.compile(r'^schemas/[A-Za-z0-9_.-]+\.gschema\.xml$'),
    re.compile(r'^LICENSE$'),
    *(re.compile('^icons/%s$' % re.escape(name)) for name in OWN_ICONS),
]

# https://gjs.guide/extensions/overview/anatomy.html#metadata-json-required
METADATA_REQUIRED = {'uuid', 'name', 'description', 'shell-version'}
METADATA_OPTIONAL = {
    'url', 'settings-schema', 'gettext-domain', 'session-modes',
    'donations', 'version-name',
}
DONATION_KEYS = {
    'buymeacoffee', 'custom', 'github', 'kofi', 'liberapay', 'opencollective',
    'patreon', 'paypal',
}
SESSION_MODES = {'user', 'unlock-dialog'}
# https://gjs.guide/extensions/overview/anatomy.html#version-name
VERSION_NAME_RE = re.compile(r'^(?!^[. ]+$)[a-zA-Z0-9 .]{1,16}$')
UUID_RE = re.compile(r'^[A-Za-z0-9._-]+@[A-Za-z0-9._-]+$')
SCHEMA_ID_BASE = 'org.gnome.shell.extensions.'
SCHEMA_PATH_BASE = '/org/gnome/shell/extensions/'

GI_NAMESPACES = (
    'Adw', 'Atk', 'Clutter', 'Cogl', 'Gdk', 'GdkPixbuf', 'Gio', 'GLib',
    'GObject', 'Graphene', 'Gtk', 'Meta', 'Mtk', 'Pango', 'Shell', 'Soup', 'St',
)
GI_CALL_RE = re.compile(r'\b(new\s+)?(%s)\.([A-Za-z_][\w.]*)\s*\(' % '|'.join(GI_NAMESPACES))
SHELL_ONLY_GI = {'Clutter', 'Meta', 'Mtk', 'Shell', 'St'}
PREFS_ONLY_GI = {'Adw', 'Gdk', 'Gtk'}
DEPRECATED_RE = re.compile(r'\bimports\.(lang|mainloop|byteArray)\b')
LEGACY_IMPORTS_RE = re.compile(r'\bimports\.(gi|misc|ui)\b')
IMPORT_RE = re.compile(r'''^\s*import\s[^'"]*?['"]([^'"]+)['"]''', re.M)
LOCAL_IMPORT_RE = re.compile(r'''\bfrom\s+['"]\./([A-Za-z0-9_-]+\.js)['"]''')
SOURCE_ADD_RE = re.compile(r'\bGLib\.(timeout_add|timeout_add_seconds|idle_add)\s*\(')
SOURCE_REMOVE_RE = re.compile(r'\bGLib\.(source_remove|Source\.remove)\s*\(')
GLOBAL_CONNECT_RE = re.compile(r'\b(global|Main)\.[\w.]+\.connect\s*\(')
DEBUG_LOG_RE = re.compile(r'\b(console\.(log|debug|info)|log|print|printerr)\s*\(')
INTERPRETER_RE = re.compile(r'''\[\s*['"](python3?|bash|sh|perl|ruby|node)['"]''')


# ---------- build ----------

def local_imports(path):
    with open(path, encoding='utf-8') as f:
        return LOCAL_IMPORT_RE.findall(strip_js(f.read(), keep_strings=True))


def reachable_modules(src):
    """extension.js, prefs.js and every module they import, transitively."""
    seen, queue = set(), [m for m in ('extension.js', 'prefs.js')
                          if os.path.exists(os.path.join(src, m))]
    while queue:
        name = queue.pop()
        if name in seen:
            continue
        seen.add(name)
        queue.extend(local_imports(os.path.join(src, name)))
    return sorted(seen)


def build(out_dir, version_name=None, src=SRC, license_path=LICENSE):
    with open(os.path.join(src, 'metadata.json'), encoding='utf-8') as f:
        metadata = json.load(f)
    if version_name:
        metadata['version-name'] = version_name

    entries = [(m, os.path.join(src, m)) for m in reachable_modules(src)]
    entries.append(('stylesheet.css', os.path.join(src, 'stylesheet.css')))
    schemas = os.path.join(src, 'schemas')
    for name in sorted(os.listdir(schemas)):
        if name.endswith('.gschema.xml'):
            entries.append((f'schemas/{name}', os.path.join(schemas, name)))
    for name in OWN_ICONS:
        entries.append((f'icons/{name}', os.path.join(src, 'icons', name)))
    entries.append(('LICENSE', license_path))

    os.makedirs(out_dir, exist_ok=True)
    zip_path = os.path.join(out_dir, f'{metadata["uuid"]}.shell-extension.zip')
    # Fixed timestamps and modes keep the ZIP byte-identical across builds.
    def add(zf, arcname, data):
        info = zipfile.ZipInfo(arcname, date_time=(1980, 1, 1, 0, 0, 0))
        info.external_attr = 0o644 << 16
        info.compress_type = zipfile.ZIP_DEFLATED
        zf.writestr(info, data)

    with zipfile.ZipFile(zip_path, 'w') as zf:
        add(zf, 'metadata.json', json.dumps(metadata, indent=2) + '\n')
        for arcname, path in entries:
            with open(path, 'rb') as f:
                add(zf, arcname, f.read())
    return zip_path


# ---------- JS scanning ----------

REGEX_PRECEDERS = set('(,=:[!&|?{};+-*%<>~^')
REGEX_KEYWORDS = ('return', 'typeof', 'case', 'do', 'else', 'in', 'of', 'yield', 'await')


def strip_js(src, keep_strings=False):
    """Blank out comments (and string/template/regex bodies unless
    keep_strings) with spaces, keeping offsets and newlines so line numbers
    still line up. Template `${...}` expressions stay as code."""
    out = list(src)
    i, n = 0, len(src)
    # Stack of contexts: 'code' (with its brace depth) or 'tpl'.
    stack = [['code', 0]]

    def blank(a, b, keep):
        if keep:
            return
        for k in range(a, b):
            if out[k] != '\n':
                out[k] = ' '

    def prev_significant(pos):
        k = pos - 1
        while k >= 0 and src[k] in ' \t\r\n':
            k -= 1
        return k

    while i < n:
        ctx = stack[-1]
        c = src[i]
        if ctx[0] == 'tpl':
            if c == '\\':
                blank(i, i + 2, keep_strings)
                i += 2
            elif c == '`':
                stack.pop()
                i += 1
            elif c == '$' and i + 1 < n and src[i + 1] == '{':
                stack.append(['code', 0])
                i += 2
            else:
                blank(i, i + 1, keep_strings)
                i += 1
            continue
        if c == '/' and i + 1 < n and src[i + 1] == '/':
            j = src.find('\n', i)
            j = n if j < 0 else j
            blank(i, j, False)
            i = j
        elif c == '/' and i + 1 < n and src[i + 1] == '*':
            j = src.find('*/', i + 2)
            j = n if j < 0 else j + 2
            blank(i, j, False)
            i = j
        elif c in '\'"':
            j = i + 1
            while j < n and src[j] != c and src[j] != '\n':
                j += 2 if src[j] == '\\' else 1
            blank(i + 1, j, keep_strings)
            i = j + 1
        elif c == '`':
            stack.append(['tpl'])
            i += 1
        elif c == '/':
            k = prev_significant(i)
            word = re.search(r'([A-Za-z_$][\w$]*)$', src[max(0, k - 10):k + 1]) if k >= 0 else None
            is_regex = k < 0 or src[k] in REGEX_PRECEDERS or (word and word.group(1) in REGEX_KEYWORDS)
            if not is_regex:
                i += 1
                continue
            j, in_class = i + 1, False
            while j < n and src[j] != '\n':
                if src[j] == '\\':
                    j += 2
                    continue
                if src[j] == '[':
                    in_class = True
                elif src[j] == ']':
                    in_class = False
                elif src[j] == '/' and not in_class:
                    break
                j += 1
            blank(i + 1, j, keep_strings)
            i = j + 1
        elif c == '{':
            ctx[1] += 1
            i += 1
        elif c == '}':
            if ctx[1] == 0 and len(stack) > 1:
                stack.pop()  # closes a template ${...}
            else:
                ctx[1] -= 1
            i += 1
        else:
            i += 1
    return ''.join(out)


def brace_depths(code):
    """Brace depth before each character of comment/string-free code."""
    depths, d = [], 0
    for ch in code:
        depths.append(d)
        if ch == '{':
            d += 1
        elif ch == '}':
            d = max(0, d - 1)
    return depths


def line_of(text, pos):
    return text.count('\n', 0, pos) + 1


def statement_prefix(code, pos):
    """Code between the start of the statement containing pos and pos."""
    k = pos - 1
    while k >= 0 and code[k] not in ';{}\n':
        k -= 1
    return code[k + 1:pos].strip()


def handle_discarded(code, pos):
    """True when the value of the call at pos is thrown away, so the source or
    handler it returns can't be removed later."""
    prefix = statement_prefix(code, pos)
    if prefix == '':
        return True
    return not re.search(r'(=|\breturn|=>|\(|,|\?|:|\|\||&&|\[)\s*$', prefix)


def module_scope_work(code):
    """GI calls that run when the module is imported (before enable())."""
    depths = brace_depths(code)
    findings = []
    gi_functions = {}
    for m in re.finditer(r'\bfunction\s+([A-Za-z_$][\w$]*)\s*\(', code):
        if depths[m.start()] != 0:
            continue
        body_start = code.find('{', m.end())
        if body_start < 0:
            continue
        end = body_start
        while end < len(code) and (depths[end] > 0 or end == body_start):
            end += 1
        if GI_CALL_RE.search(code, body_start, end):
            gi_functions[m.group(1)] = (body_start, end)
    for m in GI_CALL_RE.finditer(code):
        if depths[m.start()] != 0:
            continue
        if m.group(2) == 'GObject' and m.group(3) == 'registerClass':
            continue
        if any(a <= m.start() < b for a, b in gi_functions.values()):
            continue
        findings.append((m.start(), f'{m.group(0).rstrip("(").strip()}()'))
    if gi_functions:
        call_re = re.compile(r'(?<![\w$.])(%s)\s*\(' % '|'.join(map(re.escape, gi_functions)))
        for m in call_re.finditer(code):
            if depths[m.start()] != 0 or re.search(r'function\s+$', code[max(0, m.start() - 12):m.start()]):
                continue
            if any(a <= m.start() < b for a, b in gi_functions.values()):
                continue
            findings.append((m.start(), f'{m.group(1)}() (calls GI)'))
    return sorted(findings)


def looks_minified(text):
    lines = text.split('\n')
    longest = max((len(line) for line in lines), default=0)
    average = len(text) / max(1, len(lines))
    return longest > 1000 or (len(text) > 2000 and average > 150)


# ---------- lint ----------

class Report:
    def __init__(self):
        self.errors, self.warnings = [], []

    def error(self, where, msg):
        self.errors.append(f'{where}: {msg}')

    def warn(self, where, msg):
        self.warnings.append(f'{where}: {msg}')


def lint_metadata(files, report):
    raw = files.get('metadata.json')
    if raw is None:
        report.error('metadata.json', 'missing')
        return None
    try:
        meta = json.loads(raw.decode('utf-8'))
    except (UnicodeDecodeError, json.JSONDecodeError) as e:
        report.error('metadata.json', f'not valid JSON: {e}')
        return None
    if not isinstance(meta, dict):
        report.error('metadata.json', 'not a JSON object')
        return None
    for key in sorted(METADATA_REQUIRED - meta.keys()):
        report.error('metadata.json', f'missing required key "{key}"')
    if 'version' in meta:
        report.error('metadata.json', '"version" is set by extensions.gnome.org; drop it (use "version-name")')
    for key in sorted(meta.keys() - METADATA_REQUIRED - METADATA_OPTIONAL - {'version'}):
        report.error('metadata.json', f'unknown key "{key}"')
    version_name = meta.get('version-name')
    if version_name is not None and (not isinstance(version_name, str)
                                     or not VERSION_NAME_RE.match(version_name)):
        report.error('metadata.json', f'version-name "{version_name}" must be 1-16 letters, digits, '
                     'spaces or periods, with at least one letter or digit')
    uuid = meta.get('uuid', '')
    if not isinstance(uuid, str) or not UUID_RE.match(uuid):
        report.error('metadata.json', f'uuid "{uuid}" must look like extension-id@namespace')
    elif re.search(r'(^|[.@])gnome\.org$', uuid.split('@', 1)[1]):
        report.error('metadata.json', f'uuid "{uuid}" must not use a gnome.org namespace')
    versions = meta.get('shell-version')
    if not isinstance(versions, list) or not versions:
        report.error('metadata.json', '"shell-version" must be a non-empty list')
    else:
        for v in versions:
            if not isinstance(v, str) or not re.fullmatch(r'\d+', v) or int(v) < 45:
                report.error('metadata.json', f'shell-version "{v}" is not a stable ESM-era release (45+)')
    modes = meta.get('session-modes')
    if modes is not None:
        bad = [m for m in modes if m not in SESSION_MODES] if isinstance(modes, list) else [modes]
        if bad:
            report.error('metadata.json', f'invalid session-modes {bad}')
        elif modes == ['user']:
            report.warn('metadata.json', 'session-modes ["user"] is the default; drop the key')
    donations = meta.get('donations')
    if donations is not None:
        if not isinstance(donations, dict) or not donations:
            report.error('metadata.json', '"donations" must be a non-empty object; drop it if unused')
        else:
            for key in sorted(donations.keys() - DONATION_KEYS):
                report.error('metadata.json', f'unknown donations key "{key}"')
    return meta


def lint_schemas(files, meta, report):
    schema_files = [p for p in files if p.startswith('schemas/') and p.endswith('.gschema.xml')]
    wanted = meta.get('settings-schema') if meta else None
    if wanted and not schema_files:
        report.error('schemas/', f'settings-schema "{wanted}" is set but no schema XML is included')
        return
    ids = set()
    for path in schema_files:
        try:
            root = ET.fromstring(files[path])
        except ET.ParseError as e:
            report.error(path, f'not well-formed XML: {e}')
            continue
        for schema in root.iter('schema'):
            sid = schema.get('id', '')
            spath = schema.get('path')
            ids.add(sid)
            if not sid.startswith(SCHEMA_ID_BASE):
                report.error(path, f'schema id "{sid}" is not under {SCHEMA_ID_BASE.rstrip(".")}')
            if spath is not None and not spath.startswith(SCHEMA_PATH_BASE):
                report.error(path, f'schema path "{spath}" is not under {SCHEMA_PATH_BASE}')
        expected = [f'schemas/{sid}.gschema.xml' for sid in ids]
        if path not in expected:
            report.error(path, f'file name should be <schema-id>.gschema.xml ({", ".join(expected)})')
    if wanted and wanted not in ids:
        report.error('metadata.json', f'settings-schema "{wanted}" not defined in any included schema')


def process_sets(files, js):
    """Modules loaded by gnome-shell vs by the prefs process."""
    def closure(entry):
        seen, queue = set(), [entry] if entry in js else []
        while queue:
            name = queue.pop()
            if name in seen or name not in js:
                continue
            seen.add(name)
            queue.extend(LOCAL_IMPORT_RE.findall(js[name][1]))
        return seen
    return closure('extension.js'), closure('prefs.js')


def lint_js(files, report):
    js = {}
    for path, raw in files.items():
        if not path.endswith('.js'):
            continue
        try:
            text = raw.decode('utf-8')
        except UnicodeDecodeError:
            continue  # reported as binary
        js[path] = (text, strip_js(text, keep_strings=True), strip_js(text))
    if 'extension.js' not in js:
        report.error('extension.js', 'missing')
    shell_set, prefs_set = process_sets(files, js)
    for path in sorted(set(js) - shell_set - prefs_set):
        report.warn(path, 'not imported by extension.js or prefs.js; drop it from the ZIP')

    for path, (text, with_strings, code) in sorted(js.items()):
        if looks_minified(text):
            report.error(path, 'looks minified or obfuscated (very long lines)')
        for m in DEPRECATED_RE.finditer(code):
            report.error(f'{path}:{line_of(text, m.start())}', f'deprecated module imports.{m.group(1)}')
        for m in LEGACY_IMPORTS_RE.finditer(code):
            report.error(f'{path}:{line_of(text, m.start())}', f'legacy imports.{m.group(1)}; use ESM imports')
        imported = IMPORT_RE.findall(with_strings)
        gi = {spec[len('gi://'):].split('?')[0] for spec in imported if spec.startswith('gi://')}
        if path in shell_set:
            for ns in sorted(gi & PREFS_ONLY_GI):
                report.error(path, f'imports {ns} into the gnome-shell process')
            if any('/extensions/prefs.js' in s for s in imported):
                report.error(path, 'imports the prefs API into the gnome-shell process')
        if path in prefs_set:
            for ns in sorted(gi & SHELL_ONLY_GI):
                report.error(path, f'imports {ns} into the preferences process')
            if any(s.startswith('resource:///org/gnome/shell/') for s in imported):
                report.error(path, 'imports gnome-shell UI modules into the preferences process')

        for pos, what in module_scope_work(code):
            report.warn(f'{path}:{line_of(text, pos)}',
                        f'{what} runs at import time; do it in enable() (or the prefs window)')
        for m in re.finditer(r'\bclass\s+\w+\s+extends\s+(Extension|ExtensionPreferences)\b[^{]*\{', code):
            body = code[m.end():]
            ctor = re.search(r'\bconstructor\s*\(', body)
            depth_ok = ctor and brace_depths(body)[ctor.start()] == 0
            if depth_ok:
                report.warn(f'{path}:{line_of(text, m.end() + ctor.start())}',
                            f'{m.group(1)} subclass has a constructor; keep it to super(metadata) only')
            if m.group(1) == 'Extension':
                for method in ('enable', 'disable'):
                    if not re.search(r'^\s*%s\s*\(\s*\)\s*\{' % method, body, re.M):
                        report.error(path, f'Extension subclass has no {method}()')

        adds = list(SOURCE_ADD_RE.finditer(code))
        for m in adds:
            if handle_discarded(code, m.start()):
                report.warn(f'{path}:{line_of(text, m.start())}',
                            f'GLib.{m.group(1)}() source ID is discarded, so disable() cannot remove it')
        if adds and not SOURCE_REMOVE_RE.search(code):
            report.warn(path, 'adds main-loop sources but never removes one')
        for m in GLOBAL_CONNECT_RE.finditer(code):
            if handle_discarded(code, m.start()):
                report.warn(f'{path}:{line_of(text, m.start())}',
                            'signal handler ID on a shell object is discarded, so disable() cannot disconnect it')

        for m in DEBUG_LOG_RE.finditer(code):
            if code[max(0, m.start() - 1)] == '.' and not m.group(1).startswith('console'):
                continue  # obj.log(...)
            report.warn(f'{path}:{line_of(text, m.start())}', f'{m.group(1)}() debug logging; keep logs to errors')
        for m in INTERPRETER_RE.finditer(with_strings):
            report.warn(f'{path}:{line_of(text, m.start())}',
                        f'spawns {m.group(1)}; reviewers expect GJS unless a subprocess is unavoidable')
        for m in re.finditer(r'\bpkexec\b', with_strings):
            report.warn(f'{path}:{line_of(text, m.start())}',
                        'pkexec: the privileged command must not be user-writable')
        for m in re.finditer(r'ProviderIcon-', with_strings):
            report.warn(f'{path}:{line_of(text, m.start())}',
                        'references a provider brand logo (ProviderIcon-*), which is not shipped')


def lint(zip_path):
    report = Report()
    try:
        zf = zipfile.ZipFile(zip_path)
    except (OSError, zipfile.BadZipFile) as e:
        report.error(zip_path, f'cannot open ZIP: {e}')
        return report
    files = {}
    with zf:
        for info in zf.infolist():
            if info.is_dir():
                continue
            name = info.filename
            files[name] = zf.read(info)
            if not any(p.match(name) for p in ALLOWED):
                report.error(name, 'not in the EGO allowlist')
            if re.search(r'(^|/)ProviderIcon-', name):
                report.error(name, 'provider brand logo')
            mode = (info.external_attr >> 16) & 0o777
            if mode & 0o111:
                report.error(name, 'executable bit set')
    for name, data in files.items():
        if data[:4] == b'\x7fELF':
            report.error(name, 'ELF binary')
        elif b'\0' in data[:8192]:
            report.error(name, 'binary file')
    if 'LICENSE' not in files:
        report.warn('LICENSE', 'missing')
    meta = lint_metadata(files, report)
    lint_schemas(files, meta, report)
    lint_js(files, report)
    return report


def print_report(zip_path, report):
    for line in report.errors:
        print(f'error: {line}')
    for line in report.warnings:
        print(f'warning: {line}')
    status = 'FAIL' if report.errors else 'OK'
    print(f'{status}: {zip_path}: {len(report.errors)} error(s), {len(report.warnings)} warning(s)')


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    sub = parser.add_subparsers(dest='command', required=True)
    b = sub.add_parser('build', help='build the EGO ZIP and lint it')
    b.add_argument('--out', default=DEFAULT_OUT, help=f'output directory (default {DEFAULT_OUT})')
    b.add_argument('--version-name', help='stamp metadata.json "version-name"')
    b.add_argument('--no-lint', action='store_true', help='skip the lint step')
    l = sub.add_parser('lint', help='lint an extension ZIP')
    l.add_argument('zip')
    args = parser.parse_args(argv)

    if args.command == 'build':
        zip_path = build(args.out, args.version_name)
        print(zip_path)
        if args.no_lint:
            return 0
    else:
        zip_path = args.zip
    report = lint(zip_path)
    print_report(zip_path, report)
    return 1 if report.errors else 0


if __name__ == '__main__':
    sys.exit(main())
