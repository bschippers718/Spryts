#!/bin/bash
# Exercise the real chat lifecycle with isolated persistence and intercepted API streams.
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/spryts-chat.XXXXXX")"
trap 'rm -rf "$CHECK_DIR"' EXIT

swiftc -module-cache-path "$CHECK_DIR/module-cache" \
  "$PROJECT_DIR/Sources/Spryts/PipLibrary.swift" \
  "$PROJECT_DIR/Sources/Spryts/ChatService.swift" \
  "$PROJECT_DIR/tools/check_chat.swift" \
  -o "$CHECK_DIR/check-chat"
"$CHECK_DIR/check-chat"
