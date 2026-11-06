"""An mtime must follow its content, and nothing else."""
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
            def commit():
                for args in (["add", "."], ["commit", "-m", "x"]):
                    subprocess.run(["git", "-c", "user.name=t", "-c", "user.email=t@example.com", *args], cwd=root, check=True, capture_output=True)
            def stamp():
                subprocess.run([sys.executable, str(SCRIPT)], cwd=root, check=True)
                return {name: (root / name).stat().st_mtime for name in ("a.txt", "same.txt", "b.txt", "folder", "folder/inner.txt", "other")}
            subprocess.run(["git", "init"], cwd=root, check=True, capture_output=True)
            (root / "folder").mkdir()
            (root / "other").mkdir()
            for name, text in (("a.txt", "one"), ("same.txt", "one"), ("b.txt", "two"), ("folder/inner.txt", "three"), ("other/inner.txt", "four")):
                (root / name).write_text(text)
            commit()
            first = stamp()
            self.assertEqual(first["a.txt"], first["same.txt"])
            self.assertNotEqual(first["a.txt"], first["b.txt"])
            self.assertEqual(stamp(), first)
            (root / "folder/inner.txt").write_text("changed")
            commit()
            second = stamp()
            self.assertNotEqual(second["folder/inner.txt"], first["folder/inner.txt"])
            self.assertNotEqual(second["folder"], first["folder"])
            self.assertEqual(second["other"], first["other"])
            self.assertEqual(second["a.txt"], first["a.txt"])


if __name__ == "__main__":
    unittest.main()
