#!/bin/bash
# Compile the production, pure request builder; no app, account, network or Keychain access.
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/spryts-x-evidence.XXXXXX")"
trap 'rm -rf "$CHECK_DIR"' EXIT
swiftc -module-cache-path "$CHECK_DIR/module-cache" \
  "$PROJECT_DIR/Sources/Spryts/PipXEvidence.swift" \
  "$PROJECT_DIR/tools/check_x_evidence.swift" \
  -o "$CHECK_DIR/check-x-evidence"
"$CHECK_DIR/check-x-evidence"
