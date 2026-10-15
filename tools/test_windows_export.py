"""Dependency-free Windows staging/configuration regression checks."""
import pathlib
import struct
import tempfile
import unittest
from unittest.mock import patch

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

    def test_installer_has_stable_identity_safe_path_and_default_shortcut(self):
        script = (ROOT / "tools/windows/GodotDash.iss").read_text()
        for setting in (
            "AppId=GodotDash",
            "DefaultDirName={code:GetDefaultInstallDir}",
            "UsePreviousAppDir=no",
            "UsePreviousTasks=no",
            "PrivilegesRequired=lowest",
            "SetupMutex=GodotDash-Installer",
        ):
            self.assertIn(setting, script)
        self.assertIn('Name: "desktopicon"; Description: "Create a desktop shortcut"', script)
        self.assertNotIn('Name: "desktopicon"; Description: "Create a desktop shortcut"; Flags: unchecked', script)
        self.assertIn("function CanWriteToDirectory", script)
        self.assertIn("PreviousInstallNotWritable := True", script)
        self.assertIn("if CurPageID = wpSelectDir then", script)
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


    def test_build_runs_color_and_spin_correctness_and_benchmark_gates(self):
        import windows_ci
        outputs = {
            "renderer-cache": "DECORATION_CACHE_SUMMARY checks=1 failed=0",
            "compact-sections": "COMPACT_SECTIONS_TEST checks=1 failed=0",
            "frustum-transition": "FRUSTUM_TRANSITION_TEST checks=1 failed=0",
            "ui-alignment": "ALL UI TRIGGER TESTS PASSED",
            "decoration-spin": "decoration spin: all checks passed",
            "decoration-spin-cache": "SPIN_CACHE_TEST checks=1 failed=0",
            "channel-tint": "CHANNEL_TINT_TEST checks=1 failed=0",
        }
        with patch.object(windows_ci, "check_pe"), patch("builtins.print"), patch.object(
            windows_ci, "run", side_effect=lambda args, name, **kwargs: outputs.get(name, "")
        ) as runner:
            windows_ci.build()
        calls = {call.args[1]: call.args[0] for call in runner.call_args_list}
        self.assertEqual(calls["decoration-spin"][0].name, "spin-test.exe")
        self.assertEqual(calls["decoration-spin-cache"][0].name, "spin-cache-test.exe")
        self.assertIn("--benchmark", calls["decoration-spin-cache"])
        self.assertEqual(calls["channel-tint"][0].name, "channel-tint-test.exe")
        self.assertIn("--benchmark", calls["channel-tint"])
        self.assertEqual(calls["compact-sections"][0].name, "compact-sections-test.exe")
        self.assertIn("--benchmark", calls["compact-sections"])
        self.assertEqual(calls["frustum-transition"][0].name, "frustum-transition-test.exe")
        self.assertIn("--benchmark", calls["frustum-transition"])

    def test_build_rejects_missing_optimization_gate_markers(self):
        import windows_ci
        for broken in (
            "decoration-spin",
            "decoration-spin-cache",
            "channel-tint",
            "compact-sections",
            "frustum-transition",
        ):
            with self.subTest(gate=broken):
                outputs = {
                    "renderer-cache": "DECORATION_CACHE_SUMMARY checks=1 failed=0",
                    "compact-sections": "COMPACT_SECTIONS_TEST checks=1 failed=0",
                    "frustum-transition": "FRUSTUM_TRANSITION_TEST checks=1 failed=0",
                    "ui-alignment": "ALL UI TRIGGER TESTS PASSED",
                    "decoration-spin": "decoration spin: all checks passed",
                    "decoration-spin-cache": "SPIN_CACHE_TEST checks=1 failed=0",
                    "channel-tint": "CHANNEL_TINT_TEST checks=1 failed=0",
                }
                outputs[broken] = "incomplete output"
                with patch.object(windows_ci, "check_pe"), patch("builtins.print"), patch.object(
                    windows_ci, "run", side_effect=lambda args, name, **kwargs: outputs.get(name, "")
                ), self.assertRaisesRegex(RuntimeError, "spin|tint|sections|frustum"):
                    windows_ci.build()



if __name__ == "__main__":
    unittest.main()
