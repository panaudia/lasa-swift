#!/bin/sh
# The live suite from this Mac against a server: S1, S2, S3 (a), the
# S3 (b) and (e) send smokes and the S4 pump smoke. Leaves the log and
# the records in the directory given (default ./live-runs).
# Usage: scripts/live-suite.sh [host:port] [out dir]
# Before any timing read, `ifconfig awdl0` must be inactive
# (lasa-planning/plan/ios-transport-tests.md §7.10).
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
export PROBE_LIVE="${1:-test.panaudia.com:443}"
OUT="${2:-$ROOT/live-runs}"; mkdir -p "$OUT"
STAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
export PROBE_CAPTURE_PATH="$OUT/mac-swift-s3a-$STAMP.rec"
export PROBE_CAPTURE_DIR="$OUT"
LOG="$OUT/live-$STAMP.log"
swift test --package-path "$ROOT" --filter PartBLiveTests > "$LOG" 2>&1
echo "log: $LOG"
grep -E "Test Case .*(passed|failed)|error:" "$LOG"
