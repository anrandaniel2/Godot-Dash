"""Lossless means identical samples/metadata, not just similar screenshots."""
import io
import json
import plistlib
from pathlib import Path
import struct
import tempfile
import unittest
import zlib

from PIL import Image, PngImagePlugin
from optimize_lossless_assets import asset_paths, atomic_replace, compact_json, compact_plist, optimize_png, png_chunks, verify_png


def png(image, **kwargs):
    data = io.BytesIO()
    image.save(data, format="PNG", compress_level=0, **kwargs)
    return data.getvalue()


class LosslessAssetsTests(unittest.TestCase):
    def test_rgba_preserves_hidden_rgb_and_metadata(self):
        image = Image.new("RGBA", (64, 64), (98, 17, 201, 0))
        image.putpixel((12, 14), (14, 15, 16, 128))
        meta = PngImagePlugin.PngInfo()
        meta.add_text("Copyright", "Keep this metadata")
        meta.add(b"gAMA", struct.pack(">I", 45455))
        meta.add(b"sRGB", b"\0")
        before = png(image, pnginfo=meta)
        after, pixel_hash = optimize_png(before)
        self.assertLess(len(after), len(before))
        self.assertEqual(pixel_hash, verify_png(before, after))
        self.assertEqual(optimize_png(after)[0], after)

    def test_palette_transparency_preserved(self):
        image = Image.new("P", (32, 32), 0)
        image.putpalette([v for i in range(256) for v in (i, 255-i, 17)])
        before = png(image, transparency=bytes([0, 128] + [255] * 254))
        after, _ = optimize_png(before)
        verify_png(before, after)
        for kind in (b"PLTE", b"tRNS", b"IHDR"):
            self.assertEqual([c for c in png_chunks(before) if c[0] == kind],
                             [c for c in png_chunks(after) if c[0] == kind])

    def test_grayscale(self):
        before = png(Image.new("L", (64, 64), 41))
        after, _ = optimize_png(before)
        verify_png(before, after)

    def test_changed_pixel_rejected_even_when_transparent(self):
        before = png(Image.new("RGBA", (8, 8), (55, 6, 7, 0)))
        after = png(Image.new("RGBA", (8, 8), (0, 0, 0, 0)))
        with self.assertRaisesRegex(ValueError, "samples changed"):
            verify_png(before, after)

    def test_changed_metadata_rejected(self):
        image = Image.new("RGB", (8, 8))
        metadata = PngImagePlugin.PngInfo()
        metadata.add_text("Author", "Do not strip")
        with self.assertRaisesRegex(ValueError, "metadata changed"):
            verify_png(png(image, pnginfo=metadata), png(image))

    def test_malformed_pngs_rejected(self):
        good = png(Image.new("RGB", (8, 8)))
        for bad in (b"not png", good[:-4], good + b"trailer", good[:40] + bytes([good[40] ^ 1]) + good[41:]):
            with self.subTest(data=bad[:12]), self.assertRaises(ValueError):
                png_chunks(bad)

    def test_16_bit_input_not_silently_downconverted(self):
        with self.assertRaisesRegex(ValueError, "16-bit"):
            optimize_png(png(Image.new("I;16", (8, 8), 65534)))

    def test_apng_rejected(self):
        good = png(Image.new("RGBA", (8, 8)))
        payload = struct.pack(">II", 1, 0)
        chunk = struct.pack(">I", 8) + b"acTL" + payload + struct.pack(">I", zlib.crc32(b"acTL" + payload))
        with self.assertRaisesRegex(ValueError, "APNG"):
            optimize_png(good[:33] + chunk + good[33:])

    def test_json_keeps_string_whitespace_escapes_and_numeric_tokens(self):
        before = b' { "x" : " spaces \\t \\\" \\\\ ", "n": 1.000e+03, "big": 12345678901234567890, "u": "\\u00e9", "a": [true, null] }\n'
        after = compact_json(before)
        self.assertEqual(json.loads(before), json.loads(after))
        for token in (b'1.000e+03', b'12345678901234567890', b'\\u00e9', b' spaces '):
            self.assertIn(token, after)
        self.assertEqual(after, compact_json(after))
        with self.assertRaises(ValueError):
            compact_json(b'{"bad":}')

    def test_excludes_pinned_fonts_source_sheets_and_other_formats(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            names = ('assets/fonts/font.png', 'assets/textures/gd_atlas/source/sheet.png',
                     'assets/textures/runtime.png', 'assets/data.json', 'assets/sound.ogg',
                     'assets/textures/gd_atlas/source/sheet.plist')
            for name in names:
                path = root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.touch()
            self.assertEqual([p.relative_to(root).as_posix() for p in asset_paths(root)],
                             ['assets/data.json', 'assets/textures/gd_atlas/source/sheet.plist', 'assets/textures/runtime.png'])

    def test_stronger_png_pass_still_preserves_samples_and_metadata(self):
        before = png(Image.new("RGBA", (64, 64), (13, 12, 11, 0)))
        after, _ = optimize_png(before, level=6)
        verify_png(before, after)
        self.assertLessEqual(len(after), len(before))
        self.assertEqual(optimize_png(after, level=6)[0], after)
        with self.assertRaises(ValueError):
            optimize_png(before, level=7)

    def test_plist_keeps_leaf_tokens_comments_and_declarations(self):
        before = b'''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://example.invalid/no-network.dtd">
<plist version="1.0">
  <dict>
    <!-- Preserve attribution and <tags> in this comment. -->
    <key> text </key><string>  &#32; &amp; \n literal whitespace </string>
    <key>n</key><real>1.000e+03</real>
    <key>bytes</key><data> YWJj </data>
    <key>a</key><array>  <true/> <false/> <string>   </string> </array>
  </dict>
</plist>
'''
        after = compact_plist(before)
        self.assertLess(len(after), len(before))
        self.assertEqual(plistlib.loads(before), plistlib.loads(after))
        for literal in (b'<!-- Preserve attribution and <tags> in this comment. -->',
                        b'<string>  &#32; &amp; \n literal whitespace </string>',
                        b'<real>1.000e+03</real>', b'<string>   </string>', b'<data> YWJj </data>'):
            self.assertIn(literal, after)
        self.assertEqual(before[:before.index(b'<plist')], after[:after.index(b'<plist')])
        self.assertEqual(compact_plist(after), after)

    def test_plist_preserves_cdata_and_xml_space(self):
        before = b'<plist version="1.0" xml:space="preserve"> <dict> <key>x</key><string><![CDATA[  <abc>  ]]></string> </dict> </plist>'
        self.assertEqual(compact_plist(before), before)

    def test_plist_crlf_and_utf8_offsets(self):
        before = '<plist version="1.0">\r\n<dict>\r\n<key>café</key> <string>é &#x20;</string>\r\n</dict>\r\n</plist>'.encode()
        after = compact_plist(before)
        self.assertEqual(plistlib.loads(before), plistlib.loads(after))
        self.assertIn('<string>é &#x20;</string>'.encode(), after)
        self.assertEqual(compact_plist(after), after)

    def test_plist_rejects_entity_declarations_and_malformed_input(self):
        import xml.parsers.expat
        with self.assertRaises(ValueError):
            compact_plist(b'<!DOCTYPE plist [<!ENTITY x "expanded">]><plist><string>&x;</string></plist>')
        with self.assertRaises(xml.parsers.expat.ExpatError):
            compact_plist(b'<plist><dict>')

    def test_atomic_replace_does_not_clobber_edits(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'asset'
            path.write_bytes(b'new edit')
            with self.assertRaises(ValueError):
                atomic_replace(path, b'old', b'compressed')
            self.assertEqual(path.read_bytes(), b'new edit')
            atomic_replace(path, b'new edit', b'compressed')
            self.assertEqual(path.read_bytes(), b'compressed')
            self.assertEqual(list(Path(directory).glob('*.tmp')), [])


if __name__ == '__main__':
    unittest.main()
