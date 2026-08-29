#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

fail() {
  echo "release build failed: $1" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage:
  scripts/build-notarized-release.sh

Required environment:
  EXPORT_OPTIONS_PLIST   Path to a Developer ID export options plist.
  NOTARY_PROFILE         notarytool keychain profile name.

Optional environment:
  DEVELOPER_DIR          Full Xcode developer dir. If absent, the script finds Xcode.app or Xcode-beta.app.
  BUILD_DIR              Output directory. Defaults to build/release.
  RELEASE_EVIDENCE       Path to release evidence JSON. Defaults to release/release-evidence.json.
  REQUIRE_RELEASE_EVIDENCE=1
                         Validate live release evidence after notarization.
  SKIP_NOTARIZATION=1    Archive/export/zip only. Use only for internal dry runs.

Before public distribution, do not skip notarization.
Before public distribution, set REQUIRE_RELEASE_EVIDENCE=1.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

find_xcode_developer_dir() {
  if [[ -n "${DEVELOPER_DIR:-}" && -d "$DEVELOPER_DIR" ]]; then
    printf "%s\n" "$DEVELOPER_DIR"
    return 0
  fi
  if [[ -d /Applications/Xcode.app/Contents/Developer ]]; then
    printf "%s\n" "/Applications/Xcode.app/Contents/Developer"
    return 0
  fi
  if [[ -d /Applications/Xcode-beta.app/Contents/Developer ]]; then
    printf "%s\n" "/Applications/Xcode-beta.app/Contents/Developer"
    return 0
  fi
  return 1
}

EXPORT_OPTIONS_PLIST="${EXPORT_OPTIONS_PLIST:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
BUILD_DIR="${BUILD_DIR:-build/release}"
RELEASE_EVIDENCE="${RELEASE_EVIDENCE:-release/release-evidence.json}"
ARCHIVE_PATH="$BUILD_DIR/openflow.xcarchive"
EXPORT_PATH="$BUILD_DIR/export"
APP_PATH="$EXPORT_PATH/openflow.app"
ZIP_PATH="$BUILD_DIR/openflow.zip"
DMG_PATH="$BUILD_DIR/openflow.dmg"
SUBMISSION_ZIP_PATH="$BUILD_DIR/openflow-notarization-submission.zip"
CHECKSUM_PATH="$BUILD_DIR/openflow.zip.sha256"

[[ -n "$EXPORT_OPTIONS_PLIST" ]] || fail "EXPORT_OPTIONS_PLIST is required. Start from release/exportOptions.template.plist."
[[ -f "$EXPORT_OPTIONS_PLIST" ]] || fail "EXPORT_OPTIONS_PLIST does not exist: $EXPORT_OPTIONS_PLIST"
if [[ "${SKIP_NOTARIZATION:-0}" != "1" && -z "$NOTARY_PROFILE" ]]; then
  fail "NOTARY_PROFILE is required unless SKIP_NOTARIZATION=1"
fi

"$ROOT/scripts/check-local-release-gate.sh"

DEVELOPER_DIR_VALUE="$(find_xcode_developer_dir)" || fail "full Xcode is required"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

DEVELOPER_DIR="$DEVELOPER_DIR_VALUE" xcodebuild \
  -project openflow.xcodeproj \
  -scheme openflow \
  -configuration Release \
  -destination 'platform=macOS' \
  -archivePath "$ARCHIVE_PATH" \
  archive

DEVELOPER_DIR="$DEVELOPER_DIR_VALUE" xcodebuild \
  -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_PATH" \
  -exportOptionsPlist "$EXPORT_OPTIONS_PLIST"

[[ -d "$APP_PATH" ]] || fail "export did not produce $APP_PATH"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"

if [[ "${SKIP_NOTARIZATION:-0}" == "1" ]]; then
  ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"
  shasum -a 256 "$ZIP_PATH" > "$CHECKSUM_PATH"
  APP_PATH="$APP_PATH" BUILD_DIR="$BUILD_DIR" SKIP_NOTARIZATION=1 \
    "$ROOT/scripts/build-first-install-dmg.sh"
  echo "Built unsigned/notarization-skipped archive:"
  echo "  $ZIP_PATH"
  echo "  $CHECKSUM_PATH"
  echo "  $DMG_PATH"
  exit 0
fi

ditto -c -k --keepParent "$APP_PATH" "$SUBMISSION_ZIP_PATH"
xcrun notarytool submit "$SUBMISSION_ZIP_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP_PATH"
xcrun stapler validate "$APP_PATH"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
codesign --verify -R='anchor apple generic and identifier "com.neuroquestlabs.openflow" and certificate leaf[subject.OU] = PXAS7J4XKW' --verbose=2 "$APP_PATH"
spctl --assess --type execute --verbose "$APP_PATH"
rm -f "$SUBMISSION_ZIP_PATH"

# The distributed archive must be created after stapling. Reusing the
# notarization submission zip would silently ship an app without its ticket.
ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"
shasum -a 256 "$ZIP_PATH" > "$CHECKSUM_PATH"

APP_PATH="$APP_PATH" BUILD_DIR="$BUILD_DIR" NOTARY_PROFILE="$NOTARY_PROFILE" \
  "$ROOT/scripts/build-first-install-dmg.sh"

if [[ "${REQUIRE_RELEASE_EVIDENCE:-0}" == "1" ]]; then
  "$ROOT/scripts/verify-release-evidence.mjs" "$RELEASE_EVIDENCE"
else
  echo "release evidence validation skipped; set REQUIRE_RELEASE_EVIDENCE=1 before public distribution"
fi

echo "release build passed"
echo "  app: $APP_PATH"
echo "  zip: $ZIP_PATH"
echo "  dmg: $DMG_PATH"
echo "  sha256: $CHECKSUM_PATH"
