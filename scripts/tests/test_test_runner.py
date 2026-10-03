"""Exercise the actual runner's exit status with fake Xcode tools on any OS."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


SCRIPTS = Path(__file__).parents[1]


class TestRunnerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / "scripts").mkdir()
        self.tools = self.root / "tools"
        self.tools.mkdir()
        for name in ("test.sh", "ci-report.py"):
            shutil.copy2(SCRIPTS / name, self.root / "scripts" / name)
        self.tool("xcodegen", "pass")
        self.tool("xcodebuild", """
from pathlib import Path
Path(sys.argv[sys.argv.index('-resultBundlePath') + 1]).mkdir()
print('** TEST SUCCEEDED **')
sys.exit(int(os.environ.get('FAKE_BUILD_STATUS', '0')))
""")
        self.tool("xcrun", """
if sys.argv[1] == 'xcresulttool':
    print(os.environ['FAKE_SUMMARY'])
else:
    print(os.environ['FAKE_COVERAGE'])
""")
        self.env = dict(os.environ, PATH=str(self.tools) + os.pathsep + os.environ["PATH"],
            FAKE_SUMMARY=json.dumps(dict(result="Passed", totalTestCount=1, passedTests=1, failedTests=0, skippedTests=0)),
            FAKE_COVERAGE=json.dumps({"targets": [{"name": "Foldera.app", "lineCoverage": 1, "files": [
                {"path": "/repo/Foldera/Model/File.swift", "coveredLines": 100, "executableLines": 100, "lineCoverage": 1}
            ]}]}))
        self.env.pop("GITHUB_STEP_SUMMARY", None)

    def tool(self, name, source):
        path = self.tools / name
        path.write_text(f"#!{sys.executable}\nimport os, sys\n" + source + "\n")
        path.chmod(0o755)

    def run_suite(self, suite="unit"):
        return subprocess.run(["/bin/bash", str(self.root / "scripts/test.sh"), suite],
            env=self.env, capture_output=True, text=True, timeout=15)

    def test_success_keeps_log_result_bundle_and_coverage(self):
        result = self.run_suite()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        output = next((self.root / "build.noindex/test-results/unit").iterdir())
        for name in ("test.log", "TestResults.xcresult", "summary.json", "coverage.json", "summary.md"):
            self.assertTrue((output / name).exists(), name)

    def test_build_failure_is_not_hidden_by_success_text(self):
        self.env["FAKE_BUILD_STATUS"] = "65"
        self.assertEqual(self.run_suite().returncode, 65)

    def test_skipped_tests_fail_even_when_xcode_exits_successfully(self):
        summary = json.loads(self.env["FAKE_SUMMARY"])
        summary.update(passedTests=0, skippedTests=1)
        self.env["FAKE_SUMMARY"] = json.dumps(summary)
        self.assertEqual(self.run_suite().returncode, 1)

    def test_exactly_eighty_percent_fails_the_strict_coverage_gate(self):
        coverage = json.loads(self.env["FAKE_COVERAGE"])
        coverage["targets"][0]["files"][0].update(coveredLines=80, lineCoverage=.8)
        self.env["FAKE_COVERAGE"] = json.dumps(coverage)
        self.assertEqual(self.run_suite().returncode, 1)

    def test_missing_result_report_fails_closed(self):
        self.tool("xcrun", "sys.exit(1)")
        self.assertEqual(self.run_suite().returncode, 1)

    def test_missing_coverage_report_fails_even_with_passing_tests(self):
        self.tool("xcrun", """
if sys.argv[1] == 'xcresulttool':
    print(os.environ['FAKE_SUMMARY'])
else:
    sys.exit(1)
""")
        result = self.run_suite()
        self.assertEqual(result.returncode, 1)
        self.assertIn("Coverage report unavailable", result.stderr)

    def test_repeated_runs_keep_separate_result_bundles(self):
        self.assertEqual(self.run_suite().returncode, 0)
        self.assertEqual(self.run_suite().returncode, 0)
        self.assertEqual(len(list((self.root / "build.noindex/test-results/unit").iterdir())), 2)

    def test_ui_run_does_not_require_a_coverage_report(self):
        self.assertEqual(self.run_suite("ui").returncode, 0)
        output = next((self.root / "build.noindex/test-results/ui").iterdir())
        self.assertFalse((output / "coverage.json").exists())

    def test_invalid_suite_is_rejected(self):
        self.assertEqual(self.run_suite("unknown").returncode, 2)
