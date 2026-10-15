"""Fail closed on release/export/cache regressions; no third-party dependency."""
import base64
import configparser
import struct
import re
from pathlib import Path
import tempfile
import unittest

from pin_web_extension import LIBRARY, pin
from check_texture_compression import audit, check_ctex, check_defaults, check_import, check_webp, flat_config, texture_mode, apply_policy

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
        for family in ('for_desktop', 'for_mobile'):
            self.assertEqual(cfg['preset.3.options'][f'vram_texture_compression/{family}'], 'true')
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

    def test_windows_channel_tint_benchmark_sets_msvc_language_mode(self):
        sconstruct = (ROOT / 'tools/benchmarks/channel_tint/SConstruct').read_text()
        self.assertIn("'/std:c++17'", sconstruct)
        self.assertIn("'/Zc:__cplusplus'", sconstruct)

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


class TextureCompressionTests(unittest.TestCase):
    # Real one-pixel images; container fixtures are not GPU/pixel parity tests.
    PNG = base64.b64decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC")
    WEBP = base64.b64decode("UklGRhwAAABXRUJQVlA4TA8AAAAvAAAAAAcQ/Y/+ByKi/wEA")
    LOSSY = base64.b64decode("UklGRjwAAABXRUJQVlA4IDAAAADQAQCdASoBAAEAAUAmJaACdLoB+AADsAD+8ut//NgVzXPv9//S4P0uD9Lg/9KQAAA=")
    DEFAULTS = ('[importer_defaults]\ntexture={"compress/mode": 0, "detect_3d/compress_to": 0}\n'
                '[rendering]\ntextures/vram_compression/import_s3tc_bptc=true\n'
                'textures/vram_compression/import_etc2_astc=true\n')
    IMPORT = (ROOT / 'assets/textures/gd_atlas/gd_objects_atlas_0.png.import').read_text()

    @staticmethod
    def ctex(codec, images, flags=0):
        header = b'GST2' + struct.pack('<8I', 1, 1, 1, flags, 0, 0, 0, 0)
        header += struct.pack('<IHHII', codec, 1, 1, len(images) - 1, 4)
        return header + b''.join(struct.pack('<I', len(image)) + image for image in images)

    def test_repository_texture_policy(self):
        result = audit(ROOT)
        self.assertGreater(result['texture_imports'], 0)
        self.assertEqual(result['ctex_files'], 0)  # Explicitly source settings only.
        self.assertEqual(set(result['modes']), {'0', '1', '2'})

    def test_defaults_cannot_be_missing_or_lossy(self):
        check_defaults(self.DEFAULTS)
        for text in ('', self.DEFAULTS.replace('"compress/mode": 0', '"compress/mode": 2'),
                     self.DEFAULTS.replace('"detect_3d/compress_to": 0', '"detect_3d/compress_to": 1'),
                     self.DEFAULTS.replace('"compress/mode": 0', '"compress/mode": false')):
            with self.subTest(text=text), self.assertRaises(ValueError):
                check_defaults(text)

    def test_import_rejects_wrong_gameplay_mode_autoswitch_resize_and_overrides(self):
        check_import(flat_config(self.IMPORT), 2)
        bad = [self.IMPORT.replace('compress/mode=2', f'compress/mode={mode}') for mode in (0, 1, 3, 4)]
        bad += [self.IMPORT.replace('compress/mode=2', ''),
                self.IMPORT.replace('detect_3d/compress_to=0', 'detect_3d/compress_to=1'),
                self.IMPORT.replace('process/size_limit=0', 'process/size_limit=1024'),
                self.IMPORT + '\ncompress/mode.mobile=2\n']
        for text in bad:
            with self.subTest(text=text), self.assertRaises(ValueError):
                check_import(flat_config(text), 2)

    def test_ctex_accepts_png_and_lossless_webp(self):
        self.assertEqual(check_ctex(self.ctex(1, [self.PNG])), ('png', 1))
        self.assertEqual(check_ctex(self.ctex(2, [self.WEBP])), ('webp_lossless', 1))

    def test_ctex_checks_every_mipmap_not_just_first(self):
        self.assertEqual(check_ctex(self.ctex(2, [self.WEBP, self.WEBP])), ('webp_lossless', 2))
        with self.assertRaisesRegex(ValueError, 'bitstream'):
            check_ctex(self.ctex(2, [self.WEBP, self.LOSSY]))

    def test_ctex_rejects_other_codecs_stale_flags_and_corruption(self):
        good = self.ctex(1, [self.PNG])
        bad = [b'', good[:-1], good + b'junk', good[:4] + struct.pack('<I', 2) + good[8:],
               self.ctex(0, [self.PNG]), self.ctex(3, [self.PNG]),
               self.ctex(1, [self.WEBP]), self.ctex(1, [self.PNG], 1 << 24),
               self.ctex(2, [self.LOSSY])]
        for data in bad:
            with self.subTest(data=data[:16]), self.assertRaises(ValueError):
                check_ctex(data)

    def test_webp_rejects_missing_lossless_bitstream_and_truncation(self):
        for data in (b'RIFF' + struct.pack('<I', 4) + b'WEBP', self.WEBP[:-1],
                     self.WEBP.replace(b'VP8L', b'ANIM'),
                     self.WEBP[:16] + struct.pack('<I', 5000) + self.WEBP[20:]):
            with self.subTest(data=data[:20]), self.assertRaises(ValueError):
                check_webp(data)

    def test_imported_gate_requires_real_files_and_checks_payload(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'project.godot').write_text(self.DEFAULTS)
            (root / 'assets/fonts').mkdir(parents=True)
            (root / 'assets/fonts/image.png').write_bytes(b'fixture')
            (root / 'assets/fonts/image.png.import').write_text(self.IMPORT.replace('compress/mode=2', 'compress/mode=0'))
            with self.assertRaises(ValueError):
                audit(root, imported=True)
            remap = flat_config(self.IMPORT)['remap']['path'].strip('"')
            target = root / remap.removeprefix('res://')
            target.parent.mkdir(parents=True)
            target.write_bytes(self.ctex(2, [self.WEBP]))
            result = audit(root, imported=True)
            self.assertEqual(result['ctex_files'], 1)
            self.assertEqual(result['ctex_bytes'], target.stat().st_size)
            self.assertEqual(result['codecs'], {'webp_lossless': 1})
            target.write_bytes(self.ctex(2, [self.LOSSY]))
            with self.assertRaises(ValueError):
                audit(root, imported=True)

    def test_generator_and_builds_keep_the_policy(self):
        # Parse the literal without importing Pillow or regenerating any artwork.
        generator = (ROOT / 'tools/build_godot_atlas.py').read_text()
        template = generator.split('IMPORT_TEMPLATE = """', 1)[1].split('"""', 1)[0]
        check_import(flat_config(template), 2)
        for workflow in ('main', 'web'):
            self.assertIn('python3 tools/check_texture_compression.py --imported',
                          (ROOT / f'.github/workflows/{workflow}.yml').read_text())
        self.assertIn('ROOT / "tools/check_texture_compression.py", "--imported"',
                      (ROOT / 'tools/windows_ci.py').read_text())

    @staticmethod
    def gpu_ctex(image_format, width=4, height=4, mipmaps=0):
        header = b'GST2' + struct.pack('<8I', 1, width, height, 0, 0, 0, 0, 0)
        header += struct.pack('<IHHII', 0, width, height, mipmaps, image_format)
        # Independent fixture sizing for tested DXT1/DXT5/ETC2 RGB/RGBA formats.
        stride = 8 if image_format in (17, 30) else 16
        size = 0
        for level in range(mipmaps + 1):
            w, h = max(1, width >> level), max(1, height >> level)
            size += ((w + 3) // 4) * ((h + 3) // 4) * stride
        return header + bytes(size)

    def test_imported_gate_reports_but_skips_stale_orphan_sidecars(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'project.godot').write_text(self.DEFAULTS)
            ui_source = root / 'assets/textures/guis/button.png'
            ui_source.parent.mkdir(parents=True)
            ui_source.write_bytes(b'fixture')
            ui_import = self.IMPORT.replace('compress/mode=2', 'compress/mode=1')
            ui_import = ui_import.replace('compress/lossy_quality=0.7', 'compress/lossy_quality=0.9')
            ui_import = re.sub(r'(?m)^path=.*$', 'path="res://.godot/imported/button.ctex"', ui_import)
            ui_import = re.sub(r'(?m)^source_file=.*$', 'source_file="res://assets/textures/guis/button.png"', ui_import)
            ui_import = re.sub(r'(?m)^dest_files=.*$', 'dest_files=["res://.godot/imported/button.ctex"]', ui_import)
            (ui_source.parent / 'button.png.import').write_text(ui_import)
            orphan_dir = root / 'assets/textures/orbs'
            orphan_dir.mkdir(parents=True)
            orphan = ui_import.replace('compress/mode=1', 'compress/mode=2')
            orphan = re.sub(r'(?m)^source_file=.*$', 'source_file="res://assets/textures/orbs/Legacy.svg"', orphan)
            (orphan_dir / 'Legacy.svg.import').write_text(orphan)
            imported = root / '.godot/imported'
            imported.mkdir(parents=True)
            (imported / 'button.ctex').write_bytes(self.ctex(2, [self.LOSSY]))
            result = audit(root, imported=True)
            self.assertEqual(result['orphan_imports'], 1)
            self.assertEqual(result['texture_imports'], 1)
            self.assertEqual(result['ctex_files'], 1)

    def test_usage_classification_and_unknown_paths(self):
        for name in ('gd_atlas/page.png', 'gd_art/backgrounds/bg.png', 'solids/block.svg', 'player/trail/x.png'):
            self.assertEqual(texture_mode(Path('assets/textures') / name), 2)
        for name in ('assets/textures/guis/button.svg', 'assets/textures/triggers/ToggleOn.svg', 'assets/logo/logo.png'):
            self.assertEqual(texture_mode(Path(name)), 1)
        for name in ('assets/fonts/gd/font.png', 'assets/textures/particle_emission_masks/mask.svg'):
            self.assertEqual(texture_mode(Path(name)), 0)
        with self.assertRaises(ValueError):
            texture_mode(Path('assets/mystery.png'))

    def test_ui_quality_and_apply_idempotence(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            path = root / 'assets/textures/guis/button.png.import'
            path.parent.mkdir(parents=True)
            path.write_text(self.IMPORT)
            self.assertEqual(apply_policy(root), 1)
            text = path.read_text()
            check_import(flat_config(text), 1)
            self.assertIn('compress/lossy_quality=0.9', text)
            self.assertEqual(apply_policy(root), 0)
            with self.assertRaises(ValueError):
                check_import(flat_config(text.replace('compress/lossy_quality=0.9', 'compress/lossy_quality=0.7')), 1)
            self.assertEqual(check_ctex(self.ctex(2, [self.LOSSY]), 1), ('webp_lossy', 1))
            for payload in (self.ctex(2, [self.WEBP]), self.ctex(1, [self.PNG])):
                with self.assertRaises(ValueError):
                    check_ctex(payload, 1)

    def test_gpu_blocks_sizes_mipmaps_and_raw_pixel_rejection(self):
        for image_format, codec in ((17, 's3tc_dxt1'), (19, 's3tc_dxt5'), (30, 'etc2_rgb8'), (31, 'etc2_rgba8')):
            # Non-power-of-two dimensions exercise block rounding at every mip.
            data = self.gpu_ctex(image_format, 9, 5, 3)
            self.assertEqual(check_ctex(data, 2), (codec, 4))
            with self.assertRaises(ValueError):
                check_ctex(data[:-1], 2)
            with self.assertRaises(ValueError):
                check_ctex(data, 0)
        for data in (self.gpu_ctex(5), self.ctex(2, [self.WEBP]), self.ctex(2, [self.LOSSY])):
            with self.assertRaises(ValueError):
                check_ctex(data, 2)

    def test_both_gpu_families_are_required(self):
        for setting in ('import_s3tc_bptc', 'import_etc2_astc'):
            with self.assertRaises(ValueError):
                check_defaults(self.DEFAULTS.replace(setting + '=true', setting + '=false'))

    def test_imported_gate_checks_both_gpu_variants(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'project.godot').write_text(self.DEFAULTS)
            sidecar = root / 'assets/textures/gd_atlas/page.png.import'
            sidecar.parent.mkdir(parents=True)
            (sidecar.parent / 'page.png').write_bytes(b'fixture')
            s3tc = 'res://.godot/imported/page.s3tc.ctex'
            etc2 = 'res://.godot/imported/page.etc2.ctex'
            text = re.sub(r'(?m)^path=.*$', f'path.s3tc="{s3tc}"\npath.etc2="{etc2}"', self.IMPORT)
            sidecar.write_text(text)
            outputs = root / '.godot/imported'
            outputs.mkdir(parents=True)
            (outputs / 'page.s3tc.ctex').write_bytes(self.gpu_ctex(19))
            with self.assertRaises(ValueError):
                audit(root, True)
            (outputs / 'page.etc2.ctex').write_bytes(self.gpu_ctex(31))
            self.assertEqual(audit(root, True)['ctex_files'], 2)
            (outputs / 'page.etc2.ctex').write_bytes(self.gpu_ctex(19))
            with self.assertRaises(ValueError):
                audit(root, True)
            sidecar.write_text(self.IMPORT)  # Old lossless remap before reimport.
            with self.assertRaises(ValueError):
                audit(root, True)

    def test_cpu_readback_gates_are_wired(self):
        smoke = (ROOT / 'tools/runtime_visual_smoke_test.gd').read_text()
        cpu = (ROOT / 'tools/renderer_cache_selftest.gd').read_text()
        self.assertIn('\t_test_compressed_atlas_thumbnails()', smoke)
        self.assertIn('\t_test_texture_readback()', cpu)
        self.assertIn('TextureReadback.read(child.texture)', (ROOT / 'src/LayeredSprite.gd').read_text())
        self.assertIn('TextureReadback.read(texture.atlas)', (ROOT / 'src/static/ObjectThumbnail.gd').read_text())


if __name__ == '__main__':
    unittest.main()
