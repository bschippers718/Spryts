#!/bin/bash
# Run local fixture processes only. No inference, credentials, or app installation.
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/spryts-harness.XXXXXX")"
trap 'rm -rf "$CHECK_DIR"' EXIT

# Exercise the production parser, subprocess lifecycle, and error handling.
# Only runOnce's private access modifier changes so the check can call it.
python3 - "$PROJECT_DIR/Sources/Spryts/Harness.swift" "$CHECK_DIR/HarnessRun.swift" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text()
types = source[source.index("struct AgentStep:"):source.index("/// A past conversation")]
start = source.index("    @MainActor\n    private func runOnce(")
end = source.index("    /// Stops the run in progress.", start)
method = source[start:end].replace("private func runOnce(", "func runOnce(", 1)
Path(sys.argv[2]).write_text("import Foundation\n" + types + "\nextension ChatSession {\n" + method + "\n}\n")
PY

swiftc -parse-as-library -module-cache-path "$CHECK_DIR/module-cache" \
  "$CHECK_DIR/HarnessRun.swift" \
  "$PROJECT_DIR/tools/check_harness.swift" \
  -o "$CHECK_DIR/check-harness"
"$CHECK_DIR/check-harness"
