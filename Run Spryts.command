#!/bin/bash
# Builds Spryts and starts it. Double-click this file.
cd "$(dirname "$0")" || exit 1
export SPRYTS_HOME="$(pwd)"

if ! xcrun --find swift >/dev/null 2>&1; then
  echo "Swift is not installed on this Mac."
  echo "Install Xcode from the App Store, or run:  xcode-select --install"
  echo "NO SWIFT" > build.log
  exit 1
fi

# Build in a folder iCloud does not sync. Building inside a synced Desktop
# folder lets iCloud move files mid-build, which stalls or fails the build.
WORK="$HOME/Library/Caches/Spryts"
mkdir -p "$WORK/src"
rm -rf .build
rsync -a --delete Package.swift Sources "$WORK/src/"

pkill -x Spryts 2>/dev/null
echo "Building Spryts (the first build takes a minute)…"
swift --version > build.log 2>&1
( cd "$WORK/src" && swift build -c release --scratch-path "$WORK/build" 2>&1 ) | tee -a build.log
if [ "${PIPESTATUS[0]}" -ne 0 ]; then
  echo "BUILD FAILED" >> build.log
  echo
  echo "The build failed. The details are saved in build.log — tell Claude and it will fix it."
  exit 1
fi
echo "BUILD OK" >> build.log

nohup "$WORK/build/release/Spryts" > run.log 2>&1 &
echo
echo "Spryts is running. Use the ✦ icon in the menu bar to quit."
