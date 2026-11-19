#!/bin/bash
# Compile the production store in a temporary directory; never touch the app's real data.
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/spryts-pip.XXXXXX")"
trap 'rm -rf "$CHECK_DIR"' EXIT
swiftc -module-cache-path "$CHECK_DIR/module-cache" \
  "$PROJECT_DIR/Sources/Spryts/PipLibrary.swift" \
  "$PROJECT_DIR/tools/check_pip_library.swift" \
  -o "$CHECK_DIR/check-pip-library"
"$CHECK_DIR/check-pip-library"
