#!/bin/bash
# Fixture-only catalog/parser/process checks; no agent, account, service or app is contacted.
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/spryts-connections.XXXXXX")"
trap 'rm -rf "$CHECK_DIR"' EXIT

swiftc -module-cache-path "$CHECK_DIR/module-cache" \
  "$PROJECT_DIR/Sources/Spryts/PipConnectionCatalog.swift" \
  "$PROJECT_DIR/tools/check_connections.swift" \
  -o "$CHECK_DIR/check-connections"
"$CHECK_DIR/check-connections"
