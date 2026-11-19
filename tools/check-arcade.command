#!/bin/bash
# Checks that Joy's games can build a fair level from any desktop: every ledge reachable, bricks tidy. No app, no network.
# The result is saved in arcade-check.log.
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/spryts-arcade.XXXXXX")"
trap 'rm -rf "$CHECK_DIR"' EXIT
{
  swiftc -module-cache-path "$CHECK_DIR/module-cache" \
    "$PROJECT_DIR/Sources/Spryts/ArcadeLevels.swift" \
    "$PROJECT_DIR/tools/check_arcade.swift" \
    -o "$CHECK_DIR/check-arcade" && "$CHECK_DIR/check-arcade" || echo "ARCADE CHECK DID NOT FINISH"
  # Then the games themselves: real scenes, scripted keys, and pictures saved in arcade-shots.
  swiftc -module-cache-path "$CHECK_DIR/module-cache" \
    "$PROJECT_DIR/Sources/Spryts/ArcadeLevels.swift" \
    "$PROJECT_DIR/Sources/Spryts/Arcade.swift" \
    "$PROJECT_DIR/tools/check_arcade_play.swift" \
    -o "$CHECK_DIR/check-arcade-play" && "$CHECK_DIR/check-arcade-play" "$PROJECT_DIR" || echo "ARCADE PLAY CHECK DID NOT FINISH"
} 2>&1 | tee "$PROJECT_DIR/arcade-check.log"
