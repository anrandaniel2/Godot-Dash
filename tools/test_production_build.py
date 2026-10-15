"""Fail closed on release/export/cache regressions; no third-party dependency."""
import configparser
import re
from pathlib import Path
import tempfile
import unittest

from pin_web_extension import LIBRARY, pin

ROOT = Path(__file__).resolve().parents[1]


class ProductionBuildTests(unittest.TestCase):
    def test_presets_keep_bytecode_and_artwork(self):
        cfg = configparser.ConfigParser(interpolation=None, strict=False)
        # Godot allows unindented multiline quoted scripts; this audit only
        # consumes section headers and flat settings, not the SSH script bodies.
        flat = [line for line in (ROOT / 'export_presets.cfg').read_text().splitlines()
                if line.startswith('[') or re.match(r'^[\w/-]+=', line)]
        cfg.read_string('\n'.join(flat))
        for number in (0, 2, 3):
            preset = cfg[f'preset.{number}']
            options = cfg[f'preset.{number}.options']
            self.assertEqual(preset['script_export_mode'], '2')
            self.assertEqual(preset['export_filter'], '"all_resources"')
            self.assertEqual(options['shader_baker/enabled'], 'true')
            for required in ('*.json', '*.plist'):
                self.assertIn(required, preset['include_filter'])
            for excluded in ('native/src/*', 'native/tests/*', 'native/godot-cpp/*',
                             'native/scons-cache/*', 'tools/*', 'docs/*', 'reports/*'):
                self.assertIn(excluded, preset['exclude_filter'])
        self.assertEqual(cfg['preset.2.options']['gradle_build/compress_native_libraries'], 'true')
        self.assertEqual(cfg['preset.2.options']['architectures/arm64-v8a'], 'true')
        for arch in ('armeabi-v7a', 'x86', 'x86_64'):
            self.assertEqual(cfg['preset.2.options'][f'architectures/{arch}'], 'false')
        for flag in ('thread_support', 'extensions_support'):
            self.assertEqual(cfg['preset.3.options'][f'variant/{flag}'], 'true')

    def test_shipping_commands_are_explicit_release(self):
        web = (ROOT / '.github/workflows/web.yml').read_text()
        android = (ROOT / '.github/workflows/main.yml').read_text()
        windows = (ROOT / 'tools/windows_ci.py').read_text()
        self.assertIn('platform=web target=template_release arch=wasm64 threads=yes', web)
        self.assertNotIn('scons platform=web target=template_debug', web)
        self.assertIn('production=yes optimize=speed threads=yes dlink_enabled=yes', web)
        self.assertIn('webgpu=yes vulkan=no opengl3=yes', web)
        self.assertIn('optimize=speed lto=full dev_build=no debug_symbols=no', web)
        self.assertIn('platform=android target=template_release arch=arm64', android)
        self.assertIn('optimize=speed lto=thin dev_build=no debug_symbols=yes', android)
        self.assertIn('"optimize=speed", "lto=full", "dev_build=no", "debug_symbols=no"', windows)
        self.assertIn('"use_static_cpp=yes"', windows)
        for source in (web, android, windows):
            self.assertIn('--export-release', source)
            self.assertNotIn('--export-debug', source)
        self.assertIn('LLVM_STRIP', android)
        self.assertIn('not OS.is_debug_build()', (ROOT / 'src/debug/PerformanceCapture.gd').read_text())

    def test_native_cache_can_accumulate_new_objects_before_tests(self):
        for name in ('main', 'windows', 'web'):
            text = (ROOT / f'.github/workflows/{name}.yml').read_text()
            cache = text[text.index('id: native-cache'):]
            self.assertIn('hashFiles(', cache)
            self.assertIn('restore-keys:', cache)
            self.assertIn('uses: actions/cache/save@v4', cache)
            self.assertIn('key: ${{ steps.native-cache.outputs.cache-primary-key }}', cache)
        self.assertNotIn('scons -c platform=linux', (ROOT / '.github/workflows/main.yml').read_text())

    def test_web_staging_is_idempotent_and_scoped(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            lib = root / 'native/bin/web' / LIBRARY
            lib.parent.mkdir(parents=True)
            descriptor = root / 'native/bin/gdash_native.gdextension'
            original = (ROOT / 'native/bin/gdash_native.gdextension').read_text()
            descriptor.write_text(original)
            with self.assertRaises(FileNotFoundError):
                pin(root)
            self.assertEqual(descriptor.read_text(), original)
            lib.write_bytes(b'not wasm')
            with self.assertRaises(ValueError):
                pin(root)
            self.assertEqual(descriptor.read_text(), original)
            lib.write_bytes(b'\0asm\x01\0\0\0')
            pin(root)
            first = descriptor.read_text()
            pin(root)
            self.assertEqual(descriptor.read_text(), first)
            for line in first.splitlines():
                if line.startswith('web.'):
                    self.assertIn(LIBRARY, line)
                    self.assertNotIn('template_debug', line)
            for line in original.splitlines():
                if not line.startswith('web.'):
                    self.assertIn(line, first)

    def test_no_template_contract_or_gameplay_shortcut(self):
        project = (ROOT / 'project.godot').read_text()
        for setting in ('renderer/rendering_method.web="mobile"',
                        'renderer/rendering_method.windows="forward_plus"',
                        'driver/threads/thread_model=0',
                        'common/physics_ticks_per_second=240'):
            self.assertIn(setting, project)
        native = (ROOT / 'native/SConstruct').read_text()
        for setting in ('"disable_exceptions", "yes"', '"use_hot_reload", "no"',
                        '"deprecated", "no"', '"symbols_visibility", "hidden"'):
            self.assertIn(setting, native)
        for forbidden in ('-ffast-math', '/fp:fast'):
            self.assertNotIn(forbidden, native)


if __name__ == '__main__':
    unittest.main()
