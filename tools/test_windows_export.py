"""Dependency-free Windows staging/configuration regression checks."""
import pathlib
import struct
import tempfile
import unittest

from pin_windows_extension import DLL, check_pe, pin
from windows_ci import headless_project, windows_project

ROOT = pathlib.Path(__file__).resolve().parents[1]


class WindowsExportTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = pathlib.Path(self.temp.name)
        self.dll = self.root / "native/bin/windows" / DLL
        self.dll.parent.mkdir(parents=True)
        self.pe = bytearray(128)
        self.pe[:2] = b"MZ"
        struct.pack_into("<I", self.pe, 0x3C, 64)
        self.pe[64:68] = b"PE\0\0"
        struct.pack_into("<H", self.pe, 68, 0x8664)
        self.dll.write_bytes(self.pe)
        self.manifest = self.root / "native/bin/gdash_native.gdextension"
        self.original = (ROOT / "native/bin/gdash_native.gdextension").read_text()
        self.manifest.write_text(self.original)

    def test_x64_pe(self):
        check_pe(self.dll)

    def test_rejects_x86(self):
        struct.pack_into("<H", self.pe, 68, 0x14C)
        self.dll.write_bytes(self.pe)
        with self.assertRaises(ValueError):
            check_pe(self.dll)

    def test_rejects_non_pe(self):
        self.dll.write_bytes(b"not a DLL")
        with self.assertRaises(ValueError):
            check_pe(self.dll)

    def test_missing_dll_does_not_rewrite_manifest(self):
        self.dll.unlink()
        with self.assertRaises(FileNotFoundError):
            pin(self.root)
        self.assertEqual(self.manifest.read_text(), self.original)

    def test_pin_is_idempotent_and_preserves_other_platforms(self):
        pin(self.root)
        first = self.manifest.read_text()
        pin(self.root)
        self.assertEqual(self.manifest.read_text(), first)
        for line in self.original.splitlines():
            if line.startswith(("web.", "linux.", "android.")):
                self.assertIn(line, first)
        for target in ("debug", "release"):
            self.assertEqual(first.count(f'windows.{target}.x86_64 = "./windows/{DLL}"'), 1)

    def test_headless_plugin_filter_is_scoped_and_idempotent(self):
        project = (ROOT / "project.godot").read_text()
        filtered = headless_project(project)
        self.assertNotIn('"res://addons/script-ide/plugin.cfg"', filtered)
        self.assertIn('"res://addons/debug_menu/plugin.cfg"', filtered)
        self.assertEqual(filtered, project.replace('"res://addons/script-ide/plugin.cfg", ', '', 1))
        self.assertEqual(filtered, headless_project(filtered))

    def test_renderer_overrides(self):
        project = (ROOT / "project.godot").read_text()
        for feature, renderer in (("windows", "forward_plus"), ("mobile", "mobile"), ("web", "mobile")):
            self.assertIn(f'renderer/rendering_method.{feature}="{renderer}"', project)
        self.assertIn('driver/threads/thread_model=0', project)

    def test_display_name_keeps_existing_user_directory(self):
        project = (ROOT / "project.godot").read_text()
        self.assertIn('config/name="Godot Dash"', project)
        self.assertIn('config/use_custom_user_dir=true', project)
        self.assertIn('config/custom_user_dir_name="godot-dash"', project)
        self.assertIn('config/version="1.0.0-alpha.5"', project)  # replay version unchanged
        self.assertIn('common/physics_ticks_per_second=240', project)

    def test_windows_build_metadata_does_not_change_game_version(self):
        project = (ROOT / "project.godot").read_text()
        result = windows_project(project, "a" * 40, "42", "arena/example")
        self.assertIn('config/windows_update_channel="windows-arena-example"', result)
        self.assertIn('config/windows_build_number=42', result)
        self.assertIn('config/version="1.0.0-alpha.5"', result)
        with self.assertRaises(ValueError):
            windows_project(project, 'invalid"', "42", "arena/example")

    def test_installer_has_stable_identity_and_no_user_data_deletions(self):
        script = (ROOT / "tools/windows/GodotDash.iss").read_text()
        for setting in ("AppId=GodotDash", "UsePreviousAppDir=yes", "PrivilegesRequired=lowest"):
            self.assertIn(setting, script)
        self.assertNotIn("[UninstallDelete]", script)
        self.assertNotIn("{userappdata}", script)
        for line in script.splitlines():
            if line.startswith("Type:"):
                self.assertIn("Type: files;", line)
                self.assertNotIn("*", line)
                self.assertTrue(line.endswith(('.exe"', '.pck"')))


    def test_no_monitor_status_text_or_polling_in_settings(self):
        scene = (ROOT / "scenes/components/game_components/SettingsMenu.tscn").read_text()
        script = (ROOT / "src/SettingsMenu.gd").read_text()
        self.assertNotIn('name="DisplayStatus"', scene)
        self.assertNotIn('_update_display_status', script)
        self.assertNotIn('screen_get_refresh_rate', script)
        watcher = (ROOT / "src/DisplayPacingWatcher.gd").read_text()
        self.assertIn('window_get_current_screen()', watcher)
        self.assertIn('screen_get_refresh_rate(screen)', watcher)
        self.assertNotIn('Engine.max_fps', watcher)
        self.assertNotIn('window_set_current_screen', watcher)


    def test_asset_import_retry_is_narrow(self):
        from windows_ci import needs_asset_import_retry
        prefix = 'ERROR: res://resources/Theme.tres:929 - Parse Error: [ext_resource] referenced non-existent resource at: '
        self.assertTrue(needs_asset_import_retry(prefix + 'res://assets/fonts/Inter.ttc.\n'))
        self.assertFalse(needs_asset_import_retry(prefix + 'res://assets/fonts/missing.ttf.\n'))
        self.assertFalse(needs_asset_import_retry(prefix + 'res://src/SettingsMenu.gd.\n'))
        self.assertFalse(needs_asset_import_retry('SCRIPT ERROR: Parse Error: broken GDScript'))



if __name__ == "__main__":
    unittest.main()
