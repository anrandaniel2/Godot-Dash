import pathlib
import tempfile
import unittest
import zipfile

from tools import rapier_physics


class RapierPhysicsBuildTests(unittest.TestCase):
    def test_set_engine_rewrites_physics_section_once(self):
        with tempfile.TemporaryDirectory() as temporary:
            project = pathlib.Path(temporary) / "project.godot"
            project.write_text(
                "[application]\nconfig/name=\"sample\"\n\n"
                "[physics]\n\n2d/physics_engine=\"GodotPhysics2D\"\n"
                "common/physics_ticks_per_second=240\n",
                encoding="utf-8",
            )
            rapier_physics.set_physics_engine(project, "Rapier2D")
            text = project.read_text(encoding="utf-8")
            self.assertEqual(text.count('2d/physics_engine="Rapier2D"'), 1)
            self.assertNotIn('2d/physics_engine="GodotPhysics2D"', text)
            self.assertIn("common/physics_ticks_per_second=240", text)

    def test_set_engine_adds_missing_physics_section(self):
        with tempfile.TemporaryDirectory() as temporary:
            project = pathlib.Path(temporary) / "project.godot"
            project.write_text("[application]\nconfig/name=\"sample\"\n", encoding="utf-8")
            rapier_physics.set_physics_engine(project, "GodotPhysics2D")
            text = project.read_text(encoding="utf-8")
            self.assertIn('[physics]\n2d/physics_engine="GodotPhysics2D"', text)

    def test_set_engine_rejects_unknown_backend(self):
        with tempfile.TemporaryDirectory() as temporary:
            project = pathlib.Path(temporary) / "project.godot"
            project.write_text("[physics]\n", encoding="utf-8")
            with self.assertRaises(ValueError):
                rapier_physics.set_physics_engine(project, "UnknownPhysics")

    def test_extracts_only_pinned_addon_subtree(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            archive = root / "fixture.zip"
            prefix = "godot-rapier-2d-single/addons/godot-rapier2d/"
            with zipfile.ZipFile(archive, "w") as package:
                package.writestr(
                    prefix + "godot-rapier2d.gdextension",
                    '[configuration]\ncompatibility_minimum = "4.7"\n',
                )
                package.writestr(prefix + "bin/test.so", b"binary")
                package.writestr("godot-rapier-2d-single/project.godot", "not extracted")
            original = rapier_physics._download_asset
            rapier_physics._download_asset = lambda _cache: archive
            try:
                addon = rapier_physics.install_addon(root / "project", root / "cache")
            finally:
                rapier_physics._download_asset = original
            self.assertTrue((addon / "godot-rapier2d.gdextension").is_file())
            self.assertEqual((addon / "bin/test.so").read_bytes(), b"binary")
            self.assertFalse((root / "project/project.godot").exists())

    def test_rejects_unsafe_archive_path(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            archive = root / "fixture.zip"
            prefix = "pkg/addons/godot-rapier2d/"
            with zipfile.ZipFile(archive, "w") as package:
                package.writestr(
                    prefix + "godot-rapier2d.gdextension",
                    '[configuration]\ncompatibility_minimum = "4.7"\n',
                )
                package.writestr(prefix + "../../outside.txt", "unsafe")
            original = rapier_physics._download_asset
            rapier_physics._download_asset = lambda _cache: archive
            try:
                with self.assertRaises(RuntimeError):
                    rapier_physics.install_addon(root / "project", root / "cache")
            finally:
                rapier_physics._download_asset = original
            self.assertFalse((root / "outside.txt").exists())


if __name__ == "__main__":
    unittest.main()
