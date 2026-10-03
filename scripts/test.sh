#!/bin/bash
# Run the same signed macOS tests locally and in CI. Every invocation keeps its own results.
set -euo pipefail
cd "$(dirname "$0")/.."

SUITE=${1:-unit}
if [[ $# -gt 0 ]]; then shift; fi
case "$SUITE" in
    unit) SCHEME=Foldera; COVERAGE=YES ;;
    ui) SCHEME=FolderaUI; COVERAGE=NO ;;
    *) echo "Usage: bash scripts/test.sh [unit|ui] [xcodebuild test options]" >&2; exit 2 ;;
esac

xcodegen generate --quiet
OUTPUT="${TEST_OUTPUT_DIR:-build.noindex/test-results}/$SUITE"
mkdir -p "$OUTPUT"
RUN=$(mktemp -d "$OUTPUT/run.XXXXXX")
RESULT="$RUN/TestResults.xcresult"
STATUS=0
xcodebuild -project Foldera.xcodeproj -scheme "$SCHEME" \
    -destination 'platform=macOS' -derivedDataPath build.noindex/tests/DerivedData \
    -resultBundlePath "$RESULT" -enableCodeCoverage "$COVERAGE" \
    -parallel-testing-enabled NO \
    CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= \
    "$@" test > "$RUN/test.log" 2>&1 || STATUS=$?

awk '/:[0-9]+:[0-9]+: error:|^error:|Test run with|recorded an issue|Expectation failed|\*\* TEST/ { print }' "$RUN/test.log"
if [[ "$STATUS" -ne 0 ]]; then tail -n 60 "$RUN/test.log"; fi

REPORT_STATUS=0
if xcrun xcresulttool get test-results summary --path "$RESULT" > "$RUN/summary.json"; then
    REPORT_ARGS=(--summary "$RUN/summary.json")
    if [[ "$COVERAGE" == YES ]]; then
        if xcrun xccov view --report --json "$RESULT" > "$RUN/coverage.json"; then
            REPORT_ARGS+=(--coverage "$RUN/coverage.json")
        else
            REPORT_STATUS=1
            echo "Coverage report unavailable; this run cannot pass the coverage gate." >&2
        fi
    fi
    python3 scripts/ci-report.py "${REPORT_ARGS[@]}" > "$RUN/summary.md" || REPORT_STATUS=$?
    cat "$RUN/summary.md"
    if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then cat "$RUN/summary.md" >> "$GITHUB_STEP_SUMMARY"; fi
else
    REPORT_STATUS=1
fi
echo "Results: $RUN"
if [[ "$STATUS" -ne 0 ]]; then exit "$STATUS"; fi
exit "$REPORT_STATUS"
