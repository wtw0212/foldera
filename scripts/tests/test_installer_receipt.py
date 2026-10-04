"""Verify the release marker's binding to the application that is actually packaged."""
import hashlib
from pathlib import Path
import plistlib
import runpy
import shutil
import subprocess
import sys
import tempfile
import unittest
from uuid import uuid4


WRITE_RECEIPT = runpy.run_path(str(Path(__file__).parents[1] / "installer-receipt.py"))["write_receipt"]


class InstallerReceiptTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.project = Path(temp.name)
        self.root = self.project / "build.noindex/dmg"
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
        WRITE_RECEIPT(self.root)
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
                    WRITE_RECEIPT(self.root)
                self.assertFalse(self.marker.exists())

    def test_an_unrelated_application_cannot_produce_a_marker(self):
        self.info["CFBundleIdentifier"] = "com.example.other"
        self.save_info()
        with self.assertRaises(ValueError):
            WRITE_RECEIPT(self.root)
        self.assertFalse(self.marker.exists())

    def test_symlinked_executable_cannot_bind_an_outside_file(self):
        outside = self.root / "outside"
        outside.write_bytes(b"outside")
        self.executable.unlink()
        self.executable.symlink_to(outside)
        with self.assertRaises(ValueError):
            WRITE_RECEIPT(self.root)
        self.assertFalse(self.marker.exists())

    def test_cli_writes_only_its_fixed_staging_marker_without_overwriting(self):
        scripts = self.project / "scripts"
        scripts.mkdir()
        script = scripts / "installer-receipt.py"
        shutil.copyfile(Path(__file__).parents[1] / script.name, script)
        outside = self.project / "outside.plist"
        rejected = subprocess.run([sys.executable, str(script), str(self.app), str(outside)], capture_output=True)
        self.assertNotEqual(rejected.returncode, 0)
        self.assertFalse(outside.exists())
        self.assertFalse(self.marker.exists())
        subprocess.run([sys.executable, str(script)], check=True, capture_output=True)
        original = self.marker.read_bytes()
        repeated = subprocess.run([sys.executable, str(script)], capture_output=True)
        self.assertNotEqual(repeated.returncode, 0)
        self.assertEqual(self.marker.read_bytes(), original)


if __name__ == "__main__":
    unittest.main()
