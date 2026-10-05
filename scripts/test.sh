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
# -onlyUsePackageVersionsFromResolvedFile: packages come only from the committed Package.resolved.
xcodebuild -project Foldera.xcodeproj -scheme "$SCHEME" -onlyUsePackageVersionsFromResolvedFile \
    -destination 'platform=macOS,arch=arm64' -derivedDataPath "${FOLDERA_TEST_DERIVED_DATA:-build.noindex/tests/DerivedData}" \
    -resultBundlePath "$RESULT" -enableCodeCoverage "$COVERAGE" \
    -parallel-testing-enabled NO ARCHS=arm64 ONLY_ACTIVE_ARCH=YES COMPILER_INDEX_STORE_ENABLE=NO \
    CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= \
    "$@" test > "$RUN/test.log" 2>&1 || STATUS=$?

awk '/:[0-9]+:[0-9]+: error:|^error:|Test run with|recorded an issue|Expectation failed|\*\* TEST/ { print }' "$RUN/test.log"
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
