#!/bin/bash
# Runs the X Feed's production code against Sift's real files and a stand-in page in a real web view.
# No X account, no network. The result is saved in sift-check.log.
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/spryts-sift.XXXXXX")"
trap 'rm -rf "$CHECK_DIR"' EXIT
LOG="$PROJECT_DIR/sift-check.log"
{
  swiftc -module-cache-path "$CHECK_DIR/module-cache" \
    "$PROJECT_DIR/Sources/Spryts/PipSift.swift" \
    "$PROJECT_DIR/Sources/Spryts/PipSiftWeb.swift" \
    "$PROJECT_DIR/tools/check_sift.swift" \
    -o "$CHECK_DIR/check-sift" && "$CHECK_DIR/check-sift" "$PROJECT_DIR" || echo "SIFT CHECK DID NOT FINISH"
} 2>&1 | tee "$LOG"
