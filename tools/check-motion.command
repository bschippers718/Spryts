#!/bin/bash
# Compile outside the iCloud-synced working copy; no app launch or installation.
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/spryts-motion.XXXXXX")"
trap 'rm -rf "$CHECK_DIR"' EXIT

swiftc -module-cache-path "$CHECK_DIR/module-cache" \
  "$PROJECT_DIR/Sources/Spryts/WalkingMotion.swift" \
  "$PROJECT_DIR/tools/check_motion.swift" \
  -o "$CHECK_DIR/check-motion"
"$CHECK_DIR/check-motion"
