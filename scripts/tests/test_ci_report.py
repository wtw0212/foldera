import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("ci_report", Path(__file__).parents[1] / "ci-report.py")
ci_report = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ci_report)


class CIReportTests(unittest.TestCase):
    def summary(self, **changes):
        return dict(result="Passed", totalTestCount=5, passedTests=5, failedTests=0, skippedTests=0, **changes)

    def coverage(self, covered=810, target="Foldera.app", path="/repo/Foldera/Model/BrowserTab.swift"):
        return {"targets": [{"name": target, "lineCoverage": .5, "files": [
            {"path": path, "coveredLines": covered, "executableLines": 1000, "lineCoverage": covered / 1000},
            {"path": "/repo/Foldera/Views/ExplorerWindow.swift", "coveredLines": 81, "executableLines": 100, "lineCoverage": .81},
        ]}]}

    def test_passing_tests_and_threshold_boundary(self):
        markdown, passed = ci_report.report(self.summary(), self.coverage())
        self.assertTrue(passed)
        self.assertIn("81.00% (891/1100)", markdown)
        self.assertIn("Model/BrowserTab.swift", markdown)

    def test_coverage_below_threshold_fails(self):
        self.assertFalse(ci_report.report(self.summary(), self.coverage(700))[1])

    def test_exactly_eighty_percent_is_not_above_eighty(self):
        coverage = self.coverage(800)
        coverage["targets"][0]["files"][1].update(coveredLines=80, lineCoverage=.8)
        self.assertFalse(ci_report.report(self.summary(), coverage)[1])

    def test_uncovered_views_are_included_in_the_gate(self):
        coverage = self.coverage(1000)
        coverage["targets"][0]["files"][1].update(coveredLines=0, executableLines=1000, lineCoverage=0)
        self.assertFalse(ci_report.report(self.summary(), coverage)[1])

    def test_empty_failed_and_skipped_test_runs_fail(self):
        for change in ({"totalTestCount": 0, "passedTests": 0}, {"result": "Failed"},
                       {"failedTests": 1, "passedTests": 4}, {"skippedTests": 1, "passedTests": 4}):
            summary = self.summary()
            summary.update(change)
            with self.subTest(change=change):
                self.assertFalse(ci_report.report(summary)[1])

    def test_ui_runs_can_report_without_coverage(self):
        self.assertTrue(ci_report.report(self.summary())[1])

    def test_missing_app_or_core_coverage_fails_closed(self):
        for coverage in (self.coverage(target="FolderaTests.xctest"), self.coverage(path="/repo/Other/Model/File.swift")):
            with self.subTest(coverage=coverage), self.assertRaises(ValueError):
                ci_report.report(self.summary(), coverage)

    def test_file_counts_are_weighted_and_test_target_is_ignored(self):
        coverage = self.coverage(810)
        coverage["targets"][0]["files"].append({"path": "/repo/Foldera/Services/FileOperations.swift",
            "coveredLines": 90, "executableLines": 100, "lineCoverage": .9})
        coverage["targets"].append({"name": "FolderaTests.xctest", "lineCoverage": 1, "files": []})
        markdown, passed = ci_report.report(self.summary(), coverage)
        self.assertTrue(passed)
        self.assertIn("81.82% (900/1100)", markdown)

    def test_failure_diagnostics_are_preserved(self):
        summary = self.summary()
        summary.update(result="Failed", failedTests=1, passedTests=4,
                       testFailures=[{"testName": "navigation", "failureText": "wrong path"}])
        self.assertIn("navigation: wrong path", ci_report.report(summary)[0])


if __name__ == "__main__":
    unittest.main()
