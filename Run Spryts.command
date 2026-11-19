#!/bin/bash
# Builds Spryts Studio, installs it in /Applications and starts it. Double-click this file.
cd "$(dirname "$0")" || exit 1
HOME_DIR="$(pwd)"
BUILD_ONLY=false
if [ "${1:-}" = "--build-only" ]; then BUILD_ONLY=true; fi

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

if [ "$BUILD_ONLY" = false ]; then pkill -x Spryts 2>/dev/null; fi
echo "Building Spryts Studio (the first build takes a minute)…"
swift --version > build.log 2>&1
( cd "$WORK/src" && swift build -c release --scratch-path "$WORK/build" 2>&1 ) | tee -a build.log
if [ "${PIPESTATUS[0]}" -ne 0 ]; then
  echo "BUILD FAILED" >> build.log
  echo
  echo "The build failed. The details are saved in build.log — tell Claude and it will fix it."
  exit 1
fi

if [ "$BUILD_ONLY" = true ]; then
  echo "BUILD OK (running app left untouched)" >> build.log
  echo "Build verified. Run without --build-only when you are ready to install and relaunch."
  exit 0
fi

# A real app bundle, so macOS can grant Calendar, Reminders, speech and notifications.
APP="$WORK/Spryts Studio.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$WORK/build/release/Spryts" "$APP/Contents/MacOS/Spryts"
cp Info.plist "$APP/Contents/Info.plist"
[ -f AppIcon.icns ] && cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP" >> build.log 2>&1

# The app finds this folder (characters, .env) through this note, wherever it is launched from.
SUPPORT="$HOME/Library/Application Support/Spryts"
mkdir -p "$SUPPORT"
printf '%s' "$HOME_DIR" > "$SUPPORT/home"

rm -rf "/Applications/Spryts Studio.app"
if ditto "$APP" "/Applications/Spryts Studio.app" 2>>build.log; then
  TARGET="/Applications/Spryts Studio.app"
else
  TARGET="$APP"
  echo "Couldn't install in /Applications; running from the build folder." | tee -a build.log
fi
echo "BUILD OK" >> build.log

open "$TARGET"
echo
echo "Spryts Studio is running. Use the menu bar icon to quit."
