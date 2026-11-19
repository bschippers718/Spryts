#!/bin/bash
# Exercise the actual WorkspaceModel outside the iCloud-synced working copy.
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/spryts-workspace.XXXXXX")"
trap 'rm -rf "$CHECK_DIR"' EXIT

# The editor model shares a file with SwiftUI screens. Extract it unchanged; the
# only stub is conversation history, which is unrelated to editing and saving.
python3 - "$PROJECT_DIR/Sources/Spryts/Workspace.swift" "$CHECK_DIR/WorkspaceModel.swift" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text()
start = source.index("final class FileNode:")
end = source.index("// MARK: - The workspace window", start)
prefix = """import AppKit
import SwiftUI
struct Conversation {}
enum Harness {
    static func conversations(for folder: URL) -> [Conversation] { [] }
}
"""
Path(sys.argv[2]).write_text(prefix + source[start:end])
PY

swiftc -module-cache-path "$CHECK_DIR/module-cache" \
  "$CHECK_DIR/WorkspaceModel.swift" \
  "$PROJECT_DIR/tools/check_workspace.swift" \
  -o "$CHECK_DIR/check-workspace"
"$CHECK_DIR/check-workspace"
