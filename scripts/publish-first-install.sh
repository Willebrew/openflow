#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

fail() {
  echo "first-install publish failed: $1" >&2
  exit 1
}

VERSION="${VERSION:-${1:-}}"
ARCHIVE="${ARCHIVE:-build/release/openflow.dmg}"
CHANNEL="${CHANNEL:-installer}"
ROLLOUT="${ROLLOUT:-100}"
NOTES_FILE="${NOTES_FILE:-}"
UPDATE_HOST="${UPDATE_HOST:-}"
REMOTE_ROOT="${REMOTE_ROOT:-}"
PUBLISHED_BY="${PUBLISHED_BY:-$(id -un)}"

[[ -n "$UPDATE_HOST" ]] ||
  fail "set UPDATE_HOST, for example UPDATE_HOST=user@updates.internal.example"
[[ -n "$REMOTE_ROOT" ]] ||
  fail "set REMOTE_ROOT, for example REMOTE_ROOT=/path/to/update-payloads"
[[ -n "$VERSION" ]] || fail "set VERSION, for example VERSION=1.1.0"
[[ "$VERSION" =~ ^[0-9]+(\.[0-9]+){1,3}$ ]] ||
  fail "VERSION must be a numeric version such as 1.1.0"
[[ -f "$ARCHIVE" ]] || fail "disk image does not exist: $ARCHIVE"
[[ "$ROLLOUT" =~ ^[0-9]+$ ]] || fail "ROLLOUT must be an integer from 0 to 100"
(( ROLLOUT >= 0 && ROLLOUT <= 100 )) ||
  fail "ROLLOUT must be from 0 to 100"
if [[ -n "$NOTES_FILE" && ! -f "$NOTES_FILE" ]]; then
  fail "notes file does not exist: $NOTES_FILE"
fi
if [[ "$CHANNEL" == "stable" ]]; then
  fail "refusing to publish a DMG onto the stable zip updater channel"
fi

REMOTE_TEMP="/tmp/openflow-installer-${VERSION}-$$"
REMOTE_ARCHIVE="$REMOTE_TEMP/openflow.dmg"
REMOTE_NOTES="$REMOTE_TEMP/release-notes.txt"

cleanup() {
  ssh "$UPDATE_HOST" "/bin/rm -rf '$REMOTE_TEMP'" >/dev/null 2>&1 || true
}
trap cleanup EXIT

ssh "$UPDATE_HOST" "/bin/mkdir -p '$REMOTE_TEMP'"
scp -q "$ARCHIVE" "$UPDATE_HOST:$REMOTE_ARCHIVE"
if [[ -n "$NOTES_FILE" ]]; then
  scp -q "$NOTES_FILE" "$UPDATE_HOST:$REMOTE_NOTES"
else
  printf 'openflow %s first-install disk image\n' "$VERSION" |
    ssh "$UPDATE_HOST" "/bin/cat > '$REMOTE_NOTES'"
fi

ssh "$UPDATE_HOST" \
  /bin/zsh -s -- \
  "$REMOTE_ROOT" "$REMOTE_ARCHIVE" "$REMOTE_NOTES" \
  "$VERSION" "$CHANNEL" "$ROLLOUT" "$PUBLISHED_BY" <<'REMOTE_SCRIPT'
set -euo pipefail

ROOT="$1"
ARCHIVE="$2"
NOTES_FILE="$3"
VERSION="$4"
CHANNEL="$5"
ROLLOUT="$6"
PUBLISHED_BY="$7"
CLI="$ROOT/nq-sign/target/release/nq-sign"
KEY="$ROOT/data/.signing/openflow.key"

[[ -x "$CLI" ]] || { echo "nq-sign is missing" >&2; exit 1; }
[[ -f "$KEY" ]] || { echo "OpenFlow signing key is missing" >&2; exit 1; }
[[ -f "$HOME/.nq-portal-token" ]] ||
  { echo "portal token is missing" >&2; exit 1; }

export NQ_ADMIN_TOKEN="$(/bin/cat "$HOME/.nq-portal-token")"
"$CLI" publish \
  --app openflow \
  --channel "$CHANNEL" \
  --version "$VERSION" \
  --platform macos-aarch64 \
  --file "$ARCHIVE" \
  --file-name "openflow.dmg" \
  --notes "$NOTES_FILE" \
  --rollout "$ROLLOUT" \
  --server https://updates.jottly.ai \
  --key-file "$KEY" \
  --published-by "$PUBLISHED_BY"
REMOTE_SCRIPT

echo "Published openflow $VERSION first-install DMG to $CHANNEL at ${ROLLOUT}% rollout."
echo "Download: https://updates.jottly.ai/v1/apps/openflow/stable/macos-aarch64/download"
echo "Installer manifest: https://updates.jottly.ai/v1/apps/openflow/$CHANNEL/macos-aarch64/latest.json"
echo "Stable zip updater is unchanged."
