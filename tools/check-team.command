#!/bin/bash
# Compile the production ledger outside the iCloud-synced copy; no agent or app launch.
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/spryts-team.XXXXXX")"
trap 'rm -rf "$CHECK_DIR"' EXIT

swiftc -module-cache-path "$CHECK_DIR/module-cache" \
  "$PROJECT_DIR/Sources/Spryts/TeamCoordination.swift" \
  "$PROJECT_DIR/tools/check_team.swift" \
  -o "$CHECK_DIR/check-team"
"$CHECK_DIR/check-team"
