"""Fixture-only tests for the provider metadata generator."""

import contextlib
import importlib.util
import io
from pathlib import Path
import tempfile
import unittest

TOOL = Path(__file__).resolve().parent.parent / 'tools' / 'gen-provider-meta.py'
spec = importlib.util.spec_from_file_location('gen_provider_meta', TOOL)
gen = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gen)


class ProviderMetaTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.path = Path(self.tmp.name) / 'FixtureProviderDescriptor.swift'

    def parse(self, source):
        self.path.write_text(source, encoding='utf-8')
        return gen.parse(self.path)

    def test_classic_rgb_color(self):
        result = self.parse('''ProviderMetadata(id: .fixture, displayName: "Fixture")
            ProviderColor(red: 56 / 255, green: 189 / 255, blue: 248 / 255)''')
        self.assertEqual(result[1]['color'], '#38bdf8')

    def test_plugin_color_precedes_widget_color(self):
        result = self.parse('''PluginProviderSpec(id: .fixture, displayName: "Fixture",
            widgetColor: ProviderColor(hex: 0x18A058),
            color: ProviderColor(hex: 0x3184FF))''')
        self.assertEqual(result[1]['color'], '#3184ff')

    def test_status_feeds(self):
        for page, kind in [('https://status.openai.com', 'incidentio'),
                           ('https://status.example.com/', 'statuspage')]:
            with self.subTest(page=page):
                result = self.parse(f'ProviderMetadata(id: .fixture, statusPageURL: "{page}")')
                self.assertEqual(result[1]['statusFeed']['kind'], kind)
                if kind == 'incidentio':
                    self.assertEqual(result[1]['statusFeed']['base'],
                                     'https://status.openai.com/proxy/status.openai.com')
                else:
                    self.assertEqual(result[1]['statusFeed']['base'], page.rstrip('/'))

    def test_unsupported_file(self):
        self.assertIsNone(self.parse('struct Fixture {}'))

    def test_check_matches_and_detects_drift_without_writing(self):
        self.parse('PluginProviderSpec(id: .fixture, color: ProviderColor(hex: 0x3184FF))')
        out = Path(self.tmp.name) / 'providermeta.js'
        options = {'descriptor_glob': str(self.path), 'out': str(out)}
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()) as err:
            self.assertEqual(gen.main([], **options), 0)
            self.assertEqual(gen.main(['--check'], **options), 0)
            out.write_text(out.read_text() + '\n')
            stale = out.read_text()
            self.assertEqual(gen.main(['--check'], **options), 1)
            self.assertEqual(out.read_text(), stale)
            self.assertIn('providermeta.js is stale', err.getvalue())
            out.unlink()
            self.assertEqual(gen.main(['--check'], **options), 1)
