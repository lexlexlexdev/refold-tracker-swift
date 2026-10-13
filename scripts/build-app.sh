#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"
APP="$PWD/dist/Refold Tracker.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/RefoldTracker" "$APP/Contents/MacOS/RefoldTracker"
RESOURCE_BUNDLE="$BIN_DIR/RefoldTracker_RefoldTracker.bundle"
if [[ -d "$RESOURCE_BUNDLE" ]]; then
  ditto "$RESOURCE_BUNDLE" "$APP/Contents/Resources/RefoldTracker_RefoldTracker.bundle"
fi
cp Resources/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
echo "$APP"
