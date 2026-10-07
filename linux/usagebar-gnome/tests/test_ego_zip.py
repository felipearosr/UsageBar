"""Tests for tools/ego-zip.py: the real ZIP passes, and fixture ZIPs that
each break one review rule fail with that rule's error.

Run with: python3 -m unittest discover -s linux/usagebar-gnome/tests -p 'test_*.py'
"""

import importlib.util
import json
import os
import tempfile
import unittest
import zipfile

TOOL = os.path.join(os.path.dirname(__file__), '..', 'tools', 'ego-zip.py')
spec = importlib.util.spec_from_file_location('ego_zip', TOOL)
ego = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ego)

SCHEMA = 'schemas/org.gnome.shell.extensions.usagebar.gschema.xml'


class EgoZipTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        cls.zip_path = ego.build(cls.tmp.name)
        with zipfile.ZipFile(cls.zip_path) as zf:
            cls.entries = {name: zf.read(name) for name in zf.namelist()}

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def fixture(self, name, replace=None, drop=()):
        files = {k: v for k, v in self.entries.items() if k not in drop}
        files.update(replace or {})
        path = os.path.join(self.tmp.name, f'{name}.zip')
        with zipfile.ZipFile(path, 'w') as zf:
            for arcname, data in files.items():
                zf.writestr(arcname, data)
        return ego.lint(path)

    def metadata_with(self, **changes):
        meta = json.loads(self.entries['metadata.json'])
        meta.update(changes)
        return {'metadata.json': json.dumps(meta)}

    def assert_error(self, report, fragment):
        self.assertTrue(any(fragment in e for e in report.errors),
                        f'expected an error containing {fragment!r}, got {report.errors}')

    def test_real_zip_passes(self):
        report = ego.lint(self.zip_path)
        self.assertEqual(report.errors, [])

    def test_real_zip_has_only_allowlisted_files(self):
        names = set(self.entries)
        self.assertIn('LICENSE', names)
        self.assertIn('extension.js', names)
        self.assertIn('prefs.js', names)
        self.assertIn(SCHEMA, names)
        self.assertFalse([n for n in names if 'ProviderIcon' in n or n.startswith(('icons/', 'tests/', 'tools/'))])
        self.assertNotIn('schemas/gschemas.compiled', names)
        self.assertNotIn('version', json.loads(self.entries['metadata.json']))

    def test_build_stamps_version_name(self):
        with tempfile.TemporaryDirectory() as out:
            with zipfile.ZipFile(ego.build(out, version_name='1.2.3')) as zf:
                self.assertEqual(json.loads(zf.read('metadata.json'))['version-name'], '1.2.3')

    def test_binary_fails(self):
        self.assert_error(self.fixture('elf', {'helper.js': b'\x7fELF\x02\x01\x01' + b'\0' * 64}), 'ELF binary')

    def test_extra_file_fails(self):
        self.assert_error(self.fixture('extra', {'tests/renderstate.test.mjs': b'// test'}), 'not in the EGO allowlist')

    def test_provider_logo_fails(self):
        self.assert_error(self.fixture('logo', {'icons/ProviderIcon-claude.svg': b'<svg/>'}), 'provider brand logo')

    def test_version_key_fails(self):
        self.assert_error(self.fixture('version', self.metadata_with(version=3)), '"version"')

    def test_unknown_metadata_key_fails(self):
        self.assert_error(self.fixture('key', self.metadata_with(homepage='x')), 'unknown key "homepage"')

    def test_unstable_shell_version_fails(self):
        self.assert_error(self.fixture('shell', self.metadata_with(**{'shell-version': ['50', '51.beta']})),
                          'shell-version "51.beta"')

    def test_bad_uuid_fails(self):
        self.assert_error(self.fixture('uuid', self.metadata_with(uuid='usagebar')), 'uuid')
        self.assert_error(self.fixture('uuid2', self.metadata_with(uuid='usagebar@gnome.org')), 'gnome.org')

    def test_bad_schema_path_fails(self):
        xml = self.entries[SCHEMA].replace(b'path="/org/gnome/shell/extensions/usagebar/"', b'path="/com/example/usagebar/"')
        self.assertNotEqual(xml, self.entries[SCHEMA])
        self.assert_error(self.fixture('schema-path', {SCHEMA: xml}), 'schema path "/com/example/usagebar/"')

    def test_bad_schema_id_fails(self):
        xml = self.entries[SCHEMA].replace(b'id="org.gnome.shell.extensions.usagebar"', b'id="com.example.usagebar"')
        self.assert_error(self.fixture('schema-id', {SCHEMA: xml}), 'schema id "com.example.usagebar"')

    def test_missing_schema_fails(self):
        self.assert_error(self.fixture('no-schema', drop=(SCHEMA,)), 'no schema XML')

    def test_minified_js_fails(self):
        minified = ('var a=1;' * 400).encode()
        self.assert_error(self.fixture('minified', {'renderstate.js': minified}), 'minified')

    def test_gtk_in_shell_process_fails(self):
        js = self.entries['statusscopes.js'] + b"\nimport Gtk from 'gi://Gtk';\n"
        self.assert_error(self.fixture('gtk', {'statusscopes.js': js}), 'imports Gtk into the gnome-shell process')

    def test_deprecated_module_fails(self):
        js = self.entries['statusscopes.js'] + b'\nconst Lang = imports.lang;\n'
        self.assert_error(self.fixture('lang', {'statusscopes.js': js}), 'deprecated module imports.lang')


class StripJsTests(unittest.TestCase):
    def test_comments_strings_and_regex_are_blanked_with_offsets_kept(self):
        src = "const a = '{'; // }\nconst r = /[{]/g; const t = `x${ {b: 1}.b }y`;\n"
        out = ego.strip_js(src)
        self.assertEqual(len(out), len(src))
        self.assertEqual(out.count('\n'), src.count('\n'))
        self.assertEqual(out.count('{'), out.count('}'))
        self.assertNotIn("'{'", out)

    def test_module_scope_gi_call_is_reported(self):
        code = ego.strip_js(
            "function lang() { return GLib.get_language_names(); }\n"
            "const L = lang();\n"
            "export default class X { enable() { GLib.idle_add(0, () => false); } }\n")
        found = [what for _pos, what in ego.module_scope_work(code)]
        self.assertEqual(found, ['lang() (calls GI)'])


if __name__ == '__main__':
    unittest.main()
