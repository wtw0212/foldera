#!/bin/bash
# Run the same signed macOS tests locally and in CI. Every invocation keeps its own results.
set -euo pipefail
cd "$(dirname "$0")/.."

SUITE=${1:-unit}
if [[ $# -gt 0 ]]; then shift; fi
case "$SUITE" in
    # Unit tests print their failures, and their SwiftUI runtime warnings would trigger a log archive on every run.
    unit) SCHEME=Foldera; COVERAGE=YES; DIAGNOSTICS=never; PARALLEL=YES ;;
    # UI tests need the desktop to themselves.
    ui) SCHEME=FolderaUI; COVERAGE=NO; DIAGNOSTICS=on-failure; PARALLEL=NO ;;
    *) echo "Usage: bash scripts/test.sh [unit|ui] [xcodebuild test options]" >&2; exit 2 ;;
esac

xcodegen generate --quiet
# XcodeGen can't set this on the test action. The checker's priority-inversion warnings count as issues, so xcodebuild
# otherwise collects a 360 MB log archive even when every test passes.
sed -i '' 's/<TestAction/<TestAction disablePerformanceAntipatternChecker = "YES"/' Foldera.xcodeproj/xcshareddata/xcschemes/*.xcscheme 2>/dev/null || true
OUTPUT="build.noindex/test-results/$SUITE"
mkdir -p "$OUTPUT"
RUN=$(mktemp -d "$OUTPUT/run.XXXXXX")
RESULT="$RUN/TestResults.xcresult"

if [[ "$SUITE" == ui ]]; then
    export TEST_RUNNER_FOLDERA_PRESERVE_SYSTEM_SETTINGS=false
    if pgrep -x "System Settings" > /dev/null; then export TEST_RUNNER_FOLDERA_PRESERVE_SYSTEM_SETTINGS=true; fi
fi

# UI tests run sandboxed and can't listen on a port, so the SFTP UI test's throwaway OpenSSH server
# (key login on 127.0.0.1 only) starts here. xcodebuild hands TEST_RUNNER_* variables to the tests.
if [[ "$SUITE" == ui && -x /usr/sbin/sshd && -x /usr/libexec/sftp-server ]]; then
    SFTP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/foldera-sftp.XXXXXX")
    trap 'if [[ -f "$SFTP_DIR/sshd.pid" ]]; then kill "$(cat "$SFTP_DIR/sshd.pid")" 2>/dev/null || true; fi; rm -rf "$SFTP_DIR"' EXIT
    ssh-keygen -q -t ed25519 -N "" -f "$SFTP_DIR/host"
    ssh-keygen -q -t ed25519 -N "" -f "$SFTP_DIR/client"
    cp "$SFTP_DIR/client.pub" "$SFTP_DIR/authorized_keys"
    mkdir "$SFTP_DIR/served"
    printf 'remote' > "$SFTP_DIR/served/remote.txt"
    SFTP_PORT=$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
    printf '%s\n' "Port $SFTP_PORT" "ListenAddress 127.0.0.1" "HostKey $SFTP_DIR/host" "PidFile $SFTP_DIR/sshd.pid" \
        "AuthorizedKeysFile $SFTP_DIR/authorized_keys" "PasswordAuthentication no" "KbdInteractiveAuthentication no" \
        "UsePAM no" "StrictModes no" "Subsystem sftp /usr/libexec/sftp-server" > "$SFTP_DIR/sshd_config"
    /usr/sbin/sshd -f "$SFTP_DIR/sshd_config" -E "$SFTP_DIR/sshd.log"
    export TEST_RUNNER_FOLDERA_SFTP_PORT="$SFTP_PORT"
    export TEST_RUNNER_FOLDERA_SFTP_KEY="$SFTP_DIR/client"
    export TEST_RUNNER_FOLDERA_SFTP_ROOT="$SFTP_DIR/served"
fi

STATUS=0
export TEST_RUNNER_FOLDERA_CI="${GITHUB_ACTIONS:-false}"
# TEMPORARY: timeline, samples and hang stacks. Remove before merging.
export NSUnbufferedIO=YES
if [[ "${GITHUB_ACTIONS:-}" == true && "$(uname)" == Darwin ]]; then
    : > "$RUN/test.log"
    ( tail -F -n +1 "$RUN/test.log" | python3 -uc 'import sys, time
for line in sys.stdin: print(f"{time.time():.1f} {line}", end="", flush=True)' > "$RUN/timeline.log" ) > /dev/null 2>&1 &
    ( end=$((SECONDS + 45)); while (( SECONDS < end )); do echo "--- $(date +%T)"; ps -axo pid,ppid,pcpu,etime,args | grep -E 'swift|git |sandbox-exec|SWBBuild|xcodebuild|xcrun' | grep -v grep | cut -c1-170; sleep 1; done > "$RUN/ps.log" ) > /dev/null 2>&1 &
    if [[ "${FOLDERA_UI_SHARD:-}" == options-rename ]]; then
        ( until pgrep -x xcodebuild; do sleep 0.1; done; sudo sample xcodebuild 25 20 -file "$RUN/xcodebuild.txt" ) > /dev/null 2>&1 &
    fi
    if [[ "${FOLDERA_UI_SHARD:-}" == tabs-search ]]; then
        ( until pid=$(pgrep -nx Foldera); do sleep 0.1; done; sudo sample "$pid" 80 20 -mayDie -file "$RUN/long.txt" ) > /dev/null 2>&1 &
    fi
    if [[ "$SUITE" == unit ]]; then
        ( while sleep 15; do
            if (( $(date +%s) - $(stat -f %m "$RUN/test.log") > 100 )); then
                sudo sample Foldera 5 10 -file "$RUN/hang.txt"; sudo pkill -x xcodebuild; sudo pkill -x Foldera; break
            fi
        done ) > /dev/null 2>&1 &
    fi
fi
# -onlyUsePackageVersionsFromResolvedFile: packages come only from the committed Package.resolved.
xcodebuild -project Foldera.xcodeproj -scheme "$SCHEME" -onlyUsePackageVersionsFromResolvedFile \
    -destination 'platform=macOS,arch=arm64' -derivedDataPath "${FOLDERA_TEST_DERIVED_DATA:-build.noindex/tests/DerivedData}" \
    -resultBundlePath "$RESULT" -enableCodeCoverage "$COVERAGE" -collect-test-diagnostics "$DIAGNOSTICS" \
    -parallel-testing-enabled "$PARALLEL" ARCHS=arm64 ONLY_ACTIVE_ARCH=YES COMPILER_INDEX_STORE_ENABLE=NO \
    CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= \
    "$@" test > "$RUN/test.log" 2>&1 || STATUS=$?

DESCRIPTIONS=$(ls -dt "${FOLDERA_TEST_DERIVED_DATA:-build.noindex/tests/DerivedData}"/Build/Intermediates.noindex/XCBuildData/*.xcbuilddata 2>/dev/null || true)
echo "Build descriptions: $(echo "$DESCRIPTIONS" | wc -l)"
n=0; for d in $(echo "$DESCRIPTIONS" | head -2); do n=$((n + 1)); cp "$d/manifest.json" "$RUN/manifest-$n.json" 2>/dev/null || true; done
awk '/:[0-9]+:[0-9]+: error:|^error:|Test run with|recorded an issue|Expectation failed|\*\* TEST|Test Suite .(All|Selected) tests. started/ { print }' "$RUN/test.log"
echo "Swift modules compiled: $(grep -cE '^SwiftDriver ' "$RUN/test.log" || true)"
if [[ "$STATUS" -ne 0 ]]; then tail -n 60 "$RUN/test.log"; fi

REPORT_STATUS=0
if xcrun xcresulttool get test-results summary --path "$RESULT" > "$RUN/summary.json"; then
    REPORT_ARGS=(--summary "$RUN/summary.json" --minimum-app-coverage "${MINIMUM_APP_COVERAGE:-80}")
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
