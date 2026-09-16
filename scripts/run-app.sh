#!/bin/zsh

set -euo pipefail

SCRIPT_DIR="${0:A:h}"

# Match locally previewed builds to an installed Developer ID-signed Wordmate
# whenever that identity is available. macOS Accessibility permissions are
# tied to the designated signing requirement, not just the bundle name.
if [[ -z "${WORDMATE_SIGNING_IDENTITY:-}" ]]; then
    PREVIEW_SIGNING_IDENTITY="$({ security find-identity -v -p codesigning 2>/dev/null || true; } \
        | sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' \
        | head -1)"

    if [[ -n "$PREVIEW_SIGNING_IDENTITY" ]]; then
        export WORDMATE_SIGNING_IDENTITY="$PREVIEW_SIGNING_IDENTITY"
    fi
fi

APP_PATH="$($SCRIPT_DIR/build-app.sh)"

# `open` reuses an already-running process with the same bundle identifier,
# even when APP_PATH points at a newly rebuilt bundle. Quit that process first
# so preview restarts always run the code that was just compiled.
pkill -TERM -x LocalTranscriber 2>/dev/null || true

for _ in {1..30}; do
    if ! pgrep -f '/Wordmate.app/Contents/MacOS/LocalTranscriber' >/dev/null 2>&1; then
        break
    fi
    sleep 0.1
done

open -n "$APP_PATH"
