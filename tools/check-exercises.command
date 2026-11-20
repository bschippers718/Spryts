#!/bin/bash
# Checks Rally's movement breaks: the rep counting, and a picture of him doing each one.
# The result is saved in exercise-check.log and arcade-shots/rally-breaks.png.
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/spryts-exercises.XXXXXX")"
trap 'rm -rf "$CHECK_DIR"' EXIT
{
  swiftc -module-cache-path "$CHECK_DIR/module-cache" \
    "$PROJECT_DIR/Sources/Spryts/Config.swift" \
    "$PROJECT_DIR/Sources/Spryts/Bodies.swift" \
    "$PROJECT_DIR/Sources/Spryts/Exercises.swift" \
    "$PROJECT_DIR/tools/check_exercises.swift" \
    -o "$CHECK_DIR/check-exercises" && "$CHECK_DIR/check-exercises" "$PROJECT_DIR" || echo "EXERCISE CHECK DID NOT FINISH"
} 2>&1 | tee "$PROJECT_DIR/exercise-check.log"
