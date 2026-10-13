"""Fixture and real-descriptor tests for the provider metadata generator."""

import contextlib
import importlib.util
import io
import json
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


    def test_explicit_and_shorthand_brand_colors_ignore_widgets(self):
        for constructor in ('ProviderColor', '.init'):
            for arguments in ('hex: 0xFF0000', 'red: 1, green: 0, blue: 0'):
                with self.subTest(constructor=constructor, arguments=arguments):
                    result = self.parse(f'''PluginProviderSpec(id: .fixture,
                        widgetColor: .init(hex: 0x00FF00),
                        color: {constructor}({arguments}),
                        confetti: [ProviderColor(hex: 0x0000FF)])''')
                    self.assertEqual(result[1]['color'], '#ff0000')

    def test_widget_only_and_unsupported_brand_never_fall_back_to_widget(self):
        for color in ('', 'color: Self.brand,'):
            with self.subTest(color=color):
                result = self.parse(f'''PluginProviderSpec(id: .fixture,
                    {color} widgetColor: .init(hex: 0xFF0000))''')
                self.assertNotIn('color', result[1])
        for constructor in ('ProviderColor', '.init'):
            result = self.parse(f'ProviderMetadata(id: .fixture, widgetColor : {constructor}(hex: 0xFF0000))')
            self.assertNotIn('color', result[1])
        result = self.parse('''ProviderMetadata(id: .fixture)
            widgetColor: ProviderColor(hex: 0x00FF00)
            color: ProviderColor(red: 1, green: 0, blue: 0)''')
        self.assertEqual(result[1]['color'], '#ff0000')

    def test_legacy_entries_and_current_descriptor_precedence(self):
        self.parse('PluginProviderSpec(id: .crof, displayName: "Current Crof", color: .init(hex: 0xFF0000))')
        out = Path(self.tmp.name) / 'providermeta.js'
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()) as err:
            gen.main([], descriptor_glob=str(self.path), out=str(out))
        self.assertEqual(err.getvalue(), '')
        text = out.read_text()
        data = json.loads(text[text.index('{'):text.rindex('}') + 1])
        self.assertEqual(data['crof'], {'name': 'Current Crof', 'color': '#ff0000'})
        self.assertEqual(data['crossmodel'], {
            'name': 'CrossModel', 'dashboard': 'https://crossmodel.ai/console/usage', 'color': '#7c3aed'})
        self.assertEqual(data['kimik2'], {
            'name': 'Kimi K2 (unofficial)', 'dashboard': 'https://kimrel.com/my-credits', 'color': '#4c00ff'})
        self.assertEqual(gen.LEGACY_META['crof'], {
            'name': 'Crof', 'dashboard': 'https://crof.ai/dashboard', 'color': '#2eab94'})

    def test_generation_is_deterministic_and_output_is_not_input(self):
        self.parse('PluginProviderSpec(id: .fixture, color: .init(hex: 0xFF0000))')
        out = Path(self.tmp.name) / 'providermeta.js'
        options = {'descriptor_glob': str(self.path), 'out': str(out)}
        with contextlib.redirect_stdout(io.StringIO()):
            gen.main([], **options)
            first = out.read_bytes()
            out.write_text('export const PROVIDER_META = {"injected": {}};')
            gen.main([], **options)
            self.assertEqual(out.read_bytes(), first)
            gen.main([], **options)
            self.assertEqual(out.read_bytes(), first)
        self.assertNotIn('injected', out.read_text())

    def kimi_source(self, domain='kimi.com', console='self.webBaseURL.appendingPathComponent("code/console")'):
        source = r'''public var domain: String { self == .china ? "DOMAIN" : "kimi.ai" }
            public var webBaseURL: URL { URL(string: "https://www.\(self.domain)")! }
            public var consoleURL: URL { CONSOLE }'''
        (self.path.parent / 'KimiRegion.swift').write_text(
            source.replace('DOMAIN', domain).replace('CONSOLE', console))

    def test_kimi_expression_resolves_backing_domain_and_path(self):
        for domain in ('kimi.com', 'fixture.example'):
            with self.subTest(domain=domain):
                self.kimi_source(domain)
                result = self.parse('''ProviderMetadata(id: .kimi,
                    dashboardURL: KimiRegion.china.consoleURL.absoluteString,)''')
                self.assertEqual(result[1]['dashboard'], f'https://www.{domain}/code/console')

        self.kimi_source(console='self.webBaseURL.appendingPathComponent("code/new-console")')
        result = self.parse('ProviderMetadata(id: .kimi, dashboardURL: KimiRegion.china.consoleURL.absoluteString,)')
        self.assertEqual(result[1]['dashboard'], 'https://www.kimi.com/code/new-console')

    def test_kimi_guards_unsupported_source_and_descriptor_expressions(self):
        self.kimi_source(console='URL(string: "https://unhandled.example")!')
        with self.assertRaisesRegex(ValueError, 'unsupported KimiRegion'):
            self.parse('ProviderMetadata(id: .kimi, dashboardURL: KimiRegion.china.consoleURL.absoluteString,)')
        for old, new in [('self == .china', 'self.isChina'),
                         ('https://www.', 'https://'),
                         ('public var webBaseURL', 'private var webBaseURL')]:
            with self.subTest(source_change=old):
                self.kimi_source()
                path = self.path.parent / 'KimiRegion.swift'
                path.write_text(path.read_text().replace(old, new))
                with self.assertRaisesRegex(ValueError, 'unsupported KimiRegion'):
                    self.parse('ProviderMetadata(id: .kimi, dashboardURL: KimiRegion.china.consoleURL.absoluteString,)')
        self.kimi_source()
        with self.assertRaisesRegex(ValueError, 'unsupported Kimi dashboard'):
            self.parse('ProviderMetadata(id: .kimi, dashboardURL: KimiRegion.international.consoleURL.absoluteString,)')
        result = self.parse('ProviderMetadata(id: .kimi, dashboardURL: "https://literal.example")')
        self.assertEqual(result[1]['dashboard'], 'https://literal.example')

    def test_real_descriptors_have_names_and_brand_colors(self):
        paths = sorted(Path(gen.REPO).glob('Sources/CodexBarCore/Providers/*/*ProviderDescriptor.swift'))
        self.assertTrue(paths)
        providers = {}
        for path in paths:
            with self.subTest(path=path.name):
                parsed = gen.parse(path)
                self.assertIsNotNone(parsed)
                provider, entry = parsed
                self.assertNotIn(provider, providers)
                self.assertTrue(entry.get('name'))
                self.assertRegex(entry.get('color', ''), r'^#[0-9a-f]{6}$')
                providers[provider] = entry
        self.assertEqual(providers['manus']['color'], '#34322d')
        self.assertEqual(providers['poe']['color'], '#5d5cde')
        self.assertEqual(providers['kimi']['dashboard'], 'https://www.kimi.com/code/console')
