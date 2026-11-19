#!/bin/bash
# Compiles Spryts without installing or restarting it. The result is the last line of build.log.
cd "$(dirname "$0")/.." || exit 1
bash "Run Spryts.command" --build-only
