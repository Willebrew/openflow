#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

fail() {
  echo "local release gate failed: $1" >&2
  exit 1
}

find_xcode_developer_dir() {
  if [[ -d /Applications/Xcode.app/Contents/Developer ]]; then
    printf "%s\n" "/Applications/Xcode.app/Contents/Developer"
    return 0
  fi
  if [[ -d /Applications/Xcode-beta.app/Contents/Developer ]]; then
    printf "%s\n" "/Applications/Xcode-beta.app/Contents/Developer"
    return 0
  fi
  local xcode_path
  xcode_path="$(mdfind 'kMDItemCFBundleIdentifier == "com.apple.dt.Xcode"' | head -1 || true)"
  if [[ -n "$xcode_path" && -d "$xcode_path/Contents/Developer" ]]; then
    printf "%s\n" "$xcode_path/Contents/Developer"
    return 0
  fi
  return 1
}

"$ROOT/scripts/verify-production-readiness.sh"
"$ROOT/scripts/check-update-system.sh"
"$ROOT/scripts/check-startup-hotkey-safety.sh"
if [[ "${REQUIRE_MANUAL_INSERTION_REGRESSION:-0}" == "1" ]]; then
  node "$ROOT/scripts/insertion-regression-report.mjs" validate
fi

DEVELOPER_DIR_VALUE="$(find_xcode_developer_dir)" || fail "full Xcode is required for the macOS build gate"
DERIVED_DATA="$(mktemp -d /tmp/openflow-derived-data.XXXXXX)"
trap 'rm -rf "$DERIVED_DATA"' EXIT

DEVELOPER_DIR="$DEVELOPER_DIR_VALUE" xcodebuild \
  -project openflow.xcodeproj \
  -scheme openflow \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED_DATA" \
  build \
  -quiet

APP_PATH="$DERIVED_DATA/Build/Products/Debug/openflow.app"
test -d "$APP_PATH" || fail "Xcode did not produce openflow.app"
codesign --verify --deep --strict "$APP_PATH" || fail "built app failed codesign verification"
spctl --assess --type execute "$APP_PATH" >/dev/null 2>&1 || echo "spctl assessment did not accept the local debug build; notarized distribution still requires release signing."

echo "local release gate passed"
