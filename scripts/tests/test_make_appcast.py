"""The appcast must describe exactly the signed release image, and reject malformed release metadata."""
import base64
from pathlib import Path
import runpy
import tempfile
import unittest
import xml.etree.ElementTree as ET


MAKE_APPCAST = runpy.run_path(str(Path(__file__).parents[1] / "make-appcast.py"))["make_appcast"]
SPARKLE = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
SIGNATURE = base64.b64encode(bytes(range(64))).decode()


class MakeAppcastTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.dmg = Path(temp.name) / "Foldera-1.2.3.dmg"
        self.dmg.write_bytes(b"x" * 1234)

    def test_feed_describes_the_release(self):
        item = ET.fromstring(MAKE_APPCAST("wtw0212/foldera", "1.2.3", "42", self.dmg, SIGNATURE)).find("channel/item")
        self.assertEqual(item.findtext(SPARKLE + "version"), "42")
        self.assertEqual(item.findtext(SPARKLE + "shortVersionString"), "1.2.3")
        self.assertEqual(item.findtext(SPARKLE + "minimumSystemVersion"), "26.0")
        enclosure = item.find("enclosure")
        self.assertEqual(enclosure.get("url"), "https://github.com/wtw0212/foldera/releases/download/v1.2.3/Foldera-1.2.3.dmg")
        self.assertEqual(enclosure.get("length"), "1234")
        self.assertEqual(enclosure.get(SPARKLE + "edSignature"), SIGNATURE)

    def test_rejects_malformed_inputs(self):
        cases = [
            (("owner", "1.2.3", "42", self.dmg, SIGNATURE), "Repository"),
            (("a/b\"><x", "1.2.3", "42", self.dmg, SIGNATURE), "Repository"),
            (("a/b", "v1.2.3", "42", self.dmg, SIGNATURE), "Version"),
            (("a/b", "1.2.3", "0", self.dmg, SIGNATURE), "Build number"),
            (("a/b", "1.2.4", "42", self.dmg, SIGNATURE), "release image"),
            (("a/b", "1.2.3", "42", self.dmg.with_name("Foldera-1.2.3.zip"), SIGNATURE), "release image"),
            (("a/b", "1.2.3", "42", self.dmg, ""), "Signature"),
            (("a/b", "1.2.3", "42", self.dmg, "not base64!"), "Signature"),
            (("a/b", "1.2.3", "42", self.dmg, base64.b64encode(b"short").decode()), "Signature"),
        ]
        for arguments, message in cases:
            with self.subTest(arguments=arguments[:3]):
                with self.assertRaisesRegex(ValueError, message):
                    MAKE_APPCAST(*arguments)


if __name__ == "__main__":
    unittest.main()
