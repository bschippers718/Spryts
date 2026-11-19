#!/bin/bash
# Fixture-only: does not contact X, open a browser or access Keychain.
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/spryts-x.XXXXXX")"
trap 'rm -rf "$CHECK_DIR"' EXIT
swiftc -parse-as-library -module-cache-path "$CHECK_DIR/module-cache" \
  "$PROJECT_DIR/Sources/Spryts/PipXConnection.swift" \
  "$PROJECT_DIR/tools/check_x_connection.swift" -o "$CHECK_DIR/check-x"
"$CHECK_DIR/check-x"
