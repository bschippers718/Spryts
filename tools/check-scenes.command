#!/bin/bash
# Exercise production Scene storage and request preparation using temporary files only.
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/spryts-scenes.XXXXXX")"
trap 'rm -rf "$CHECK_DIR"' EXIT
swiftc -module-cache-path "$CHECK_DIR/module-cache" \
  "$PROJECT_DIR/Sources/Spryts/PipScenes.swift" \
  "$PROJECT_DIR/tools/check_scenes.swift" \
  -o "$CHECK_DIR/check-scenes"
"$CHECK_DIR/check-scenes"
