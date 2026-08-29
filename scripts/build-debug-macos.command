#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
APP_DIR="$(mktemp -d /tmp/openflow-debug.XXXXXX)"
if [[ -d /Applications/Xcode.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
elif [[ -d /Applications/Xcode-beta.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
fi
xcodebuild \
  -project openflow.xcodeproj \
  -scheme openflow \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath "$APP_DIR" \
  build
APP="$APP_DIR/Build/Products/Debug/openflow.app"
test -d "$APP"
killall openflow 2>/dev/null || true
open "$APP"
echo "launched $APP"
