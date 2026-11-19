#!/bin/bash
# Exercise the production Codex adapter against a local fake JSON-RPC peer. No model inference.
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/spryts-codex.XXXXXX")"
trap 'rm -rf "$CHECK_DIR"' EXIT

swiftc -module-cache-path "$CHECK_DIR/module-cache" \
  "$PROJECT_DIR/Sources/Spryts/CodexAgent.swift" \
  "$PROJECT_DIR/tools/check_codex.swift" \
  -o "$CHECK_DIR/check-codex"
"$CHECK_DIR/check-codex"
