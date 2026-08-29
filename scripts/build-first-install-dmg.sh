#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

fail() {
  echo "first-install dmg failed: $1" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage:
  scripts/build-first-install-dmg.sh

Builds a classic Finder disk image from a stapled openflow.app:
  openflow.app + Applications symlink on the live /openflow hero background,
  then signs, notarizes, and staples the DMG. Does not replace the in-app
  zip updater archive.

Required environment:
  NOTARY_PROFILE         notarytool keychain profile name.

Optional environment:
  APP_PATH               Stapled .app. Defaults to build/release/export/openflow.app.
  BUILD_DIR              Output directory. Defaults to build/release.
  DMG_VOLNAME            Volume name. Defaults to openflow.
  CODESIGN_IDENTITY      Developer ID Application identity.
  SKIP_NOTARIZATION=1    Create and sign the DMG only. Internal dry runs.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

APP_PATH="${APP_PATH:-build/release/export/openflow.app}"
BUILD_DIR="${BUILD_DIR:-build/release}"
DMG_VOLNAME="${DMG_VOLNAME:-openflow}"
DMG_PATH="${DMG_PATH:-$BUILD_DIR/openflow.dmg}"
RW_DMG_PATH="$BUILD_DIR/openflow.rw.dmg"
CHECKSUM_PATH="$BUILD_DIR/openflow.dmg.sha256"
BACKGROUND_PATH="${BACKGROUND_PATH:-$ROOT/release/dmg/background.png}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:-Developer ID Application: WILLIAM MARTIN KILLEBREW (PXAS7J4XKW)}"

[[ -d "$APP_PATH" ]] || fail "APP_PATH does not exist: $APP_PATH"
[[ -f "$BACKGROUND_PATH" ]] || fail "DMG background is missing: $BACKGROUND_PATH"
if [[ "${SKIP_NOTARIZATION:-0}" != "1" && -z "$NOTARY_PROFILE" ]]; then
  fail "NOTARY_PROFILE is required unless SKIP_NOTARIZATION=1"
fi

mkdir -p "$BUILD_DIR"
rm -f "$DMG_PATH" "$RW_DMG_PATH" "$CHECKSUM_PATH"

STAGE="$(mktemp -d /tmp/openflow-dmg-stage.XXXXXX)"
MOUNT=""
DEVICE=""
cleanup() {
  if [[ -n "$DEVICE" ]]; then
    hdiutil detach "$DEVICE" -quiet >/dev/null 2>&1 || \
      hdiutil detach "$DEVICE" -force >/dev/null 2>&1 || true
  fi
  if [[ -n "$MOUNT" && -d "$MOUNT" ]]; then
    hdiutil detach "$MOUNT" -quiet >/dev/null 2>&1 || \
      hdiutil detach "$MOUNT" -force >/dev/null 2>&1 || true
  fi
  rm -rf "$STAGE"
  rm -f "$RW_DMG_PATH"
}
trap cleanup EXIT

ditto "$APP_PATH" "$STAGE/openflow.app"
ln -s /Applications "$STAGE/Applications"
mkdir -p "$STAGE/.background"
cp "$BACKGROUND_PATH" "$STAGE/.background/background.png"
[[ -d "$STAGE/openflow.app" ]] || fail "failed to copy openflow.app into the DMG stage"
[[ -L "$STAGE/Applications" ]] || fail "failed to create Applications symlink"
[[ -f "$STAGE/.background/background.png" ]] || fail "failed to stage the Finder background"

hdiutil create \
  -volname "$DMG_VOLNAME" \
  -srcfolder "$STAGE" \
  -ov \
  -format UDRW \
  "$RW_DMG_PATH" >/dev/null

# A leftover /Volumes/openflow (for example a downloaded 1.0.70 DMG) makes
# this image mount as "/Volumes/openflow 1". Parse the full path, not $NF.
if [[ -d /Volumes/openflow ]]; then
  hdiutil detach /Volumes/openflow -quiet >/dev/null 2>&1 || \
    hdiutil detach /Volumes/openflow -force >/dev/null 2>&1 || true
fi
ATTACH_OUT="$(hdiutil attach -readwrite -noverify -noautoopen "$RW_DMG_PATH")"
DEVICE="$(printf '%s\n' "$ATTACH_OUT" | awk '/^\/dev\// { print $1; exit }')"
MOUNT="$(printf '%s\n' "$ATTACH_OUT" | awk 'match($0, /\/Volumes\/.+$/) { print substr($0, RSTART, RLENGTH); exit }')"
[[ -n "$DEVICE" && -n "$MOUNT" && -d "$MOUNT" ]] || fail "could not mount writable DMG"
if [[ ! -f "$MOUNT/.background/background.png" ]]; then
  mkdir -p "$MOUNT/.background"
  cp "$BACKGROUND_PATH" "$MOUNT/.background/background.png"
fi
[[ -f "$MOUNT/.background/background.png" ]] || fail "writable DMG is missing the Finder background"

# Hide Finder clutter so the window is the branded background plus two icons.
rm -rf "$MOUNT/.fseventsd" "$MOUNT/.Trashes" "$MOUNT/.TemporaryItems" || true
if command -v SetFile >/dev/null 2>&1; then
  SetFile -a V "$MOUNT" >/dev/null 2>&1 || true
fi

# Classic two-icon drag layout on the live /openflow hero sparkle field.
# Window is 540x360 points; background.png is the 1080x720 @ 144dpi crop.
osascript <<EOF
tell application "Finder"
  tell disk "$DMG_VOLNAME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set sidebar width of container window to 0
    set the bounds of container window to {240, 160, 780, 520}
    set viewOptions to the icon view options of container window
    set arrangement of viewOptions to not arranged
    set icon size of viewOptions to 80
    set text size of viewOptions to 12
    set background picture of viewOptions to file ".background:background.png"
    set position of item "openflow.app" of container window to {150, 180}
    set position of item "Applications" of container window to {390, 180}
    close
    open
    update without registering applications
    delay 2
    close
  end tell
end tell
EOF

if command -v SetFile >/dev/null 2>&1; then
  SetFile -a V "$MOUNT/.background" >/dev/null 2>&1 || true
fi
if [[ -d "$MOUNT/.background" ]]; then
  chflags hidden "$MOUNT/.background" >/dev/null 2>&1 || true
fi

sync
hdiutil detach "$DEVICE" -quiet || hdiutil detach "$DEVICE" -force
DEVICE=""
MOUNT=""

hdiutil convert "$RW_DMG_PATH" -format UDZO -imagekey zlib-level=9 -o "$DMG_PATH" >/dev/null
rm -f "$RW_DMG_PATH"
[[ -f "$DMG_PATH" ]] || fail "hdiutil convert did not produce $DMG_PATH"

codesign --force --sign "$CODESIGN_IDENTITY" --timestamp "$DMG_PATH"
codesign --verify --verbose=2 "$DMG_PATH"

if [[ "${SKIP_NOTARIZATION:-0}" != "1" ]]; then
  xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG_PATH"
  xcrun stapler validate "$DMG_PATH"
  spctl --assess --type open --context context:primary-signature --verbose "$DMG_PATH"
fi

VERIFY_MOUNT="$(mktemp -d /tmp/openflow-dmg-verify.XXXXXX)"
hdiutil attach -readonly -nobrowse -mountpoint "$VERIFY_MOUNT" "$DMG_PATH" >/dev/null
if [[ ! -d "$VERIFY_MOUNT/openflow.app" ]]; then
  hdiutil detach "$VERIFY_MOUNT" -quiet >/dev/null 2>&1 || true
  fail "DMG is missing openflow.app"
fi
if [[ ! -L "$VERIFY_MOUNT/Applications" ]]; then
  hdiutil detach "$VERIFY_MOUNT" -quiet >/dev/null 2>&1 || true
  fail "DMG is missing the Applications symlink"
fi
if [[ ! -f "$VERIFY_MOUNT/.background/background.png" ]]; then
  hdiutil detach "$VERIFY_MOUNT" -quiet >/dev/null 2>&1 || true
  fail "DMG is missing the Finder background"
fi
LINK_TARGET="$(readlink "$VERIFY_MOUNT/Applications")"
if [[ "$LINK_TARGET" != "/Applications" ]]; then
  hdiutil detach "$VERIFY_MOUNT" -quiet >/dev/null 2>&1 || true
  fail "Applications symlink must point at /Applications, got $LINK_TARGET"
fi
codesign --verify --deep --strict --verbose=2 "$VERIFY_MOUNT/openflow.app"
codesign --verify -R='anchor apple generic and identifier "com.neuroquestlabs.openflow" and certificate leaf[subject.OU] = PXAS7J4XKW' --verbose=2 "$VERIFY_MOUNT/openflow.app"
hdiutil detach "$VERIFY_MOUNT" -quiet || hdiutil detach "$VERIFY_MOUNT" -force
rmdir "$VERIFY_MOUNT" >/dev/null 2>&1 || true

shasum -a 256 "$DMG_PATH" > "$CHECKSUM_PATH"

echo "first-install dmg ready"
echo "  dmg: $DMG_PATH"
echo "  sha256: $CHECKSUM_PATH"
