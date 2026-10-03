#!/usr/bin/env python3
"""Summarize xcresulttool/xccov JSON and reject empty, failed or under-covered runs."""
import argparse
import json
from pathlib import Path


def report(summary, coverage=None, minimum=80.0):
    total = summary["totalTestCount"]
    passed = summary["passedTests"]
    failed = summary["failedTests"]
    skipped = summary["skippedTests"]
    successful = summary["result"] == "Passed" and total > 0 and passed == total and failed == skipped == 0
    lines = ["## Test results", "", f"{passed}/{total} passed; {failed} failed; {skipped} skipped.", ""]
    for failure in summary.get("testFailures", []):
        lines.append(f"- {failure['testName']}: {failure['failureText']}")
    if coverage is not None:
        targets = [t for t in coverage["targets"] if t["name"] == "Foldera.app"]
        if len(targets) != 1:
            raise ValueError("Expected exactly one Foldera.app coverage target")
        target = targets[0]
        files = [f for f in target["files"] if any(
            f"/Foldera/{group}/" in f["path"] for group in ("Model", "Services")
        )]
        executable = sum(f["executableLines"] for f in files)
        covered = sum(f["coveredLines"] for f in files)
        if not executable or not 0 <= covered <= executable:
            raise ValueError("Missing or invalid Model/Services coverage")
        percent = covered / executable * 100
        app_executable = sum(f["executableLines"] for f in target["files"])
        app_covered = sum(f["coveredLines"] for f in target["files"])
        if not app_executable or not 0 <= app_covered <= app_executable:
            raise ValueError("Missing or invalid whole-app coverage")
        app_percent = app_covered / app_executable * 100
        successful = successful and app_percent > minimum
        lines += ["## Line coverage", "", "| Scope | Coverage | Required |", "|---|---:|---:|",
                  f"| Entire app (including Views, Theme and App) | {app_percent:.2f}% ({app_covered}/{app_executable}) | >{minimum:g}% |",
                  f"| Model + Services | {percent:.2f}% ({covered}/{executable}) | Report only |", "",
                  "| App file | Coverage |", "|---|---:|"]
        for file in sorted(target["files"], key=lambda f: f["path"]):
            relative = file["path"].split("/Foldera/", 1)[1]
            lines.append(f"| {relative} | {file['lineCoverage'] * 100:.2f}% |")
    if not successful:
        lines += ["", "**Failed:** all tests must pass without skips, and whole-app coverage must exceed the threshold."]
    return "\n".join(lines) + "\n", successful


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--summary", type=Path, required=True)
    parser.add_argument("--coverage", type=Path)
    parser.add_argument("--minimum-app-coverage", type=float, default=80.0)
    args = parser.parse_args()
    if not 0 <= args.minimum_app_coverage < 100:
        parser.error("coverage threshold must be between 0 and 100")
    summary = json.loads(args.summary.read_text())
    coverage = json.loads(args.coverage.read_text()) if args.coverage else None
    markdown, successful = report(summary, coverage, args.minimum_app_coverage)
    print(markdown, end="")
    return 0 if successful else 1


if __name__ == "__main__":
    raise SystemExit(main())
