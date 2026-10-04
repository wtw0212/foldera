#!/bin/bash
# Optimize the copied helper before Xcode signs the enclosing app. Keep the vendor binary intact.
set -euo pipefail
if [[ "$CONFIGURATION" != Release ]]; then exit 0; fi

HELPER="$TARGET_BUILD_DIR/$EXECUTABLE_FOLDER_PATH/7zz"
# An incremental build may already contain the ARM64 helper from the previous run.
if [[ "$(lipo -archs "$HELPER")" != arm64 ]]; then
    lipo "$HELPER" -thin arm64 -output "$HELPER.arm64"
    mv "$HELPER.arm64" "$HELPER"
fi
strip -u -r "$HELPER"

if [[ "$CODE_SIGNING_ALLOWED" == YES ]]; then
    SIGN_ARGS=(--force --sign "$EXPANDED_CODE_SIGN_IDENTITY"
        "--preserve-metadata=identifier,entitlements,flags" --generate-entitlement-der)
    if [[ "$ENABLE_HARDENED_RUNTIME" == YES ]]; then SIGN_ARGS+=(--options runtime); fi
    if [[ "$EXPANDED_CODE_SIGN_IDENTITY" == "-" ]]; then
        SIGN_ARGS+=(--timestamp=none)
    else
        SIGN_ARGS+=(--timestamp)
    fi
    codesign "${SIGN_ARGS[@]}" "$HELPER"
fi
