"""Verify the release marker's binding to the application that is actually packaged."""
import hashlib
from pathlib import Path
import plistlib
import runpy
import tempfile
import unittest
from uuid import uuid4


WRITE_RECEIPT = runpy.run_path(str(Path(__file__).parents[1] / "installer-receipt.py"))["write_receipt"]


class InstallerReceiptTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        self.app = self.root / "Foldera.app"
        self.executable = self.app / "Contents/MacOS/Foldera"
        self.executable.parent.mkdir(parents=True)
        self.executable.write_bytes(b"signed executable")
        self.info = dict(CFBundleIdentifier="com.wtw0212.foldera", CFBundleExecutable="Foldera",
                         CFBundleShortVersionString="1.2.3", CFBundleVersion="42", FolderaInstallerID=str(uuid4()))
        self.marker = self.root / ".foldera-installer.plist"
        self.save_info()

    def save_info(self):
        with (self.app / "Contents/Info.plist").open("wb") as output:
            plistlib.dump(self.info, output)

    def test_marker_records_the_signed_executable_and_packaging_identity(self):
        WRITE_RECEIPT(self.app, self.marker)
        with self.marker.open("rb") as source:
            record = plistlib.load(source)
        self.assertEqual(record, dict(format=1, installerID=self.info["FolderaInstallerID"],
            bundleIdentifier="com.wtw0212.foldera", version="1.2.3", build="42",
            executableSHA256=hashlib.sha256(self.executable.read_bytes()).hexdigest()))

    def test_missing_or_invalid_identity_cannot_produce_a_marker(self):
        for value in ("", "invalid"):
            with self.subTest(value=value):
                self.info["FolderaInstallerID"] = value
                self.save_info()
                with self.assertRaises(ValueError):
                    WRITE_RECEIPT(self.app, self.marker)
                self.assertFalse(self.marker.exists())

    def test_an_unrelated_application_cannot_produce_a_marker(self):
        self.info["CFBundleIdentifier"] = "com.example.other"
        self.save_info()
        with self.assertRaises(ValueError):
            WRITE_RECEIPT(self.app, self.marker)
        self.assertFalse(self.marker.exists())

    def test_symlinked_executable_cannot_bind_an_outside_file(self):
        outside = self.root / "outside"
        outside.write_bytes(b"outside")
        self.executable.unlink()
        self.executable.symlink_to(outside)
        with self.assertRaises(ValueError):
            WRITE_RECEIPT(self.app, self.marker)
        self.assertFalse(self.marker.exists())


if __name__ == "__main__":
    unittest.main()
