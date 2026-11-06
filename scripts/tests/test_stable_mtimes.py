"""A file's mtime must follow its content, and nothing else."""
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).parents[1] / "stable-mtimes.py"


class StableMtimesTests(unittest.TestCase):
    def test_mtime_follows_content(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            def git(*args):
                subprocess.run(["git", "-c", "user.name=t", "-c", "user.email=t@example.com", *args], cwd=root, check=True, capture_output=True)
            def stamp():
                subprocess.run([sys.executable, str(SCRIPT)], cwd=root, check=True)
                return (root / "a.txt").stat().st_mtime, (root / "same.txt").stat().st_mtime, (root / "b.txt").stat().st_mtime
            git("init")
            (root / "a.txt").write_text("one")
            (root / "same.txt").write_text("one")
            (root / "b.txt").write_text("two")
            git("add", ".")
            a, same, b = stamp()
            self.assertEqual(a, same)
            self.assertNotEqual(a, b)
            self.assertEqual(stamp(), (a, same, b))
            (root / "a.txt").write_text("uno")
            git("add", ".")
            self.assertNotEqual(stamp()[0], a)


if __name__ == "__main__":
    unittest.main()
