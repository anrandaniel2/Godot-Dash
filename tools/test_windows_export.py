"""Dependency-free Windows staging/configuration regression checks."""
import pathlib
import struct
import tempfile
import unittest

from pin_windows_extension import DLL, check_pe, pin
from windows_ci import headless_project

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


if __name__ == "__main__":
    unittest.main()
