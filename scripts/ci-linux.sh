#!/usr/bin/env bash
# Portable openflow checks for Linux CI. Does not run Xcode.
# Full macOS gate remains scripts/check-local-release-gate.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if ! command -v rg >/dev/null 2>&1; then
  echo "ripgrep (rg) is required" >&2
  exit 1
fi
if ! command -v node >/dev/null 2>&1; then
  echo "node is required" >&2
  exit 1
fi

# Scripts on /mnt/d lose +x; invoke via the interpreter instead of relying on mode.
"$ROOT/scripts/verify-production-readiness.sh"
"$ROOT/scripts/check-startup-hotkey-safety.sh"
"$ROOT/scripts/check-update-system.sh"

node "$ROOT/scripts/check-audio-capture-safety.mjs"
node "$ROOT/scripts/check-browser-insertion-safety.mjs"
node "$ROOT/scripts/check-hotkey-text-input-safety.mjs"
node "$ROOT/scripts/check-permissions-flow-safety.mjs"
node "$ROOT/scripts/check-history-ui-safety.mjs"
node "$ROOT/scripts/check-release-evidence-validator.mjs"
node "$ROOT/scripts/check-terminal-cleanup-safety.mjs"

# Linux runners may have Swift, but these contracts need AppKit sources.
# Full Swift checks stay on macOS / Xcode.
if [[ "$(uname -s)" == "Darwin" ]] && command -v swift >/dev/null 2>&1; then
  echo "running Swift contract checks"
  # check-cleanup-context.swift is compiled with its sources in
  # verify-production-readiness.sh; a bare `swift` invocation cannot see them.
  swift "$ROOT/scripts/check-cloud-auth-contract.swift"
  swift "$ROOT/scripts/check-cloud-url-policy.swift"
  SESSION_BIN="$(mktemp /tmp/openflow-cloud-session-check.XXXXXX)"
  swiftc \
    "$ROOT/openflow/Services/CloudSessionValidator.swift" \
    "$ROOT/scripts/check-cloud-session-validator.swift" \
    -o "$SESSION_BIN"
  "$SESSION_BIN"
  rm -f "$SESSION_BIN"
  swift "$ROOT/scripts/check-history-privacy.swift"
  HOME_ACTIVITY_BIN="$(mktemp /tmp/openflow-home-activity-check.XXXXXX)"
  swiftc \
    "$ROOT/openflow/Models/HomeActivityStats.swift" \
    "$ROOT/scripts/check-home-activity-stats.swift" \
    -o "$HOME_ACTIVITY_BIN"
  "$HOME_ACTIVITY_BIN"
  rm -f "$HOME_ACTIVITY_BIN"
  swift "$ROOT/scripts/check-insertion-text-preparation.swift"
  swift "$ROOT/scripts/check-user-settings-persistence.swift"
  POLICY_BIN="$(mktemp /tmp/openflow-hotkey-policy-check.XXXXXX)"
  swiftc \
    "$ROOT/openflow/Services/HotkeyCapturePolicy.swift" \
    "$ROOT/scripts/check-hotkey-capture-policy.swift" \
    -o "$POLICY_BIN"
  "$POLICY_BIN"
  rm -f "$POLICY_BIN"
else
  echo "skipping Swift contract checks (macOS only)"
fi

echo "openflow linux CI passed"
