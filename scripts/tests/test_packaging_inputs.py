"""Invalid release metadata must fail before invoking build or signing tools."""
import os
from pathlib import Path
import subprocess
import unittest


SCRIPT = Path(__file__).parents[1] / "make-dmg.sh"


class PackagingInputTests(unittest.TestCase):
    def reject(self, version, build, message):
        env = dict(os.environ, VERSION=version, BUILD_NUMBER=build)
        result = subprocess.run(["/bin/bash", str(SCRIPT)], env=env, capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn(message, result.stderr)
        self.assertNotIn("Building Foldera", result.stdout)

    def test_invalid_versions(self):
        for version in ("invalid", "v1.2.3", "1.2", "1.2.3.4", "01.2.3", "1.02.3", "1.2.03", "1.2.3-beta", "1.2.3\n"):
            with self.subTest(version=version):
                self.reject(version, "1", "Version must be MAJOR.MINOR.PATCH")

    def test_invalid_build_numbers(self):
        for build in ("invalid", "0", "-1", "01", "1.5", "1\n"):
            with self.subTest(build=build):
                self.reject("1.2.3", build, "Build number must be a positive integer")


if __name__ == "__main__":
    unittest.main()
