#!/bin/bash
# Checks how a Spryt reads what is typed to it and what its body does in answer. No app, no network.
# The result is saved in listening-check.log.
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/spryts-listening.XXXXXX")"
trap 'rm -rf "$CHECK_DIR"' EXIT
{
  swiftc -module-cache-path "$CHECK_DIR/module-cache" \
    "$PROJECT_DIR/Sources/Spryts/Listening.swift" \
    "$PROJECT_DIR/tools/check_listening.swift" \
    -o "$CHECK_DIR/check-listening" && "$CHECK_DIR/check-listening" || echo "LISTENING CHECK DID NOT FINISH"
} 2>&1 | tee "$PROJECT_DIR/listening-check.log"
