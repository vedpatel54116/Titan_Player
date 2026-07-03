#!/usr/bin/env bash
# scripts/run-and-verify.sh
# Builds the app in debug mode, launches it, and verifies it stays running.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TITAN_DIR="$PROJECT_ROOT/TitanPlayer"
LOG_FILE="$PROJECT_ROOT/console.log"

cd "$TITAN_DIR"

echo "== Building TitanPlayer in debug mode..."
swift build -c debug

EXECUTABLE_PATH="$TITAN_DIR/.build/debug/TitanPlayer"

if [[ ! -f "$EXECUTABLE_PATH" ]]; then
    echo "ERROR: Built executable not found at $EXECUTABLE_PATH"
    exit 1
fi

echo "== Launching TitanPlayer..."
"$EXECUTABLE_PATH" > "$LOG_FILE" 2>&1 &
APP_PID=$!

echo "== App started with PID $APP_PID, waiting 5 seconds to verify..."
sleep 5

if kill -0 "$APP_PID" 2>/dev/null; then
    echo "== App is running (PID $APP_PID). Logs at $LOG_FILE"
    exit 0
else
    echo "ERROR: App crashed within 5 seconds. Check logs at $LOG_FILE"
    cat "$LOG_FILE"
    exit 1
fi
