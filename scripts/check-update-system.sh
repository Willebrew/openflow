#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

fail() {
  echo "update system check failed: $1" >&2
  exit 1
}

test -f openflow/Services/UpdateService.swift ||
  fail "missing UpdateService.swift"
test -f openflow/Resources/install-update.sh ||
  fail "missing external update installer"
test -f scripts/publish-update.sh ||
  fail "publish-update.sh is missing"
test -f scripts/build-first-install-dmg.sh ||
  fail "build-first-install-dmg.sh is missing"
test -f scripts/publish-first-install.sh ||
  fail "publish-first-install.sh is missing"
test -f release/dmg/background.png ||
  fail "missing first-install DMG background release/dmg/background.png"
test -f release/dmg/hero-crop.png ||
  fail "missing live hero crop release/dmg/hero-crop.png"
test -f docs/openflow_logo.png ||
  fail "missing README logo docs/openflow_logo.png"
test -f scripts/compose-dmg-background.py ||
  fail "compose-dmg-background.py is missing"
rg -F 'docs/openflow_logo.png' scripts/compose-dmg-background.py >/dev/null ||
  fail "DMG background must composite the README logo"
if rg -n 'frost_pill|LABEL_PILLS' scripts/compose-dmg-background.py >/dev/null; then
  fail "DMG background must not paint grey label pills"
fi
if rg -n 'rectangle\(\(0, 420' scripts/compose-dmg-background.py >/dev/null; then
  fail "DMG background must not paint a grey horizontal bar"
fi
rg -F 'fade_to_white' scripts/compose-dmg-background.py >/dev/null ||
  fail "DMG background must fade the hero to white above the icon row"
if rg -n 'HUB_TEAL|frost_pill|LABEL_PILLS|ellipse\(' scripts/compose-dmg-background.py >/dev/null; then
  fail "DMG background must not paint glow orbs or label pills"
fi

/bin/zsh -n openflow/Resources/install-update.sh
/bin/bash -n scripts/publish-update.sh
/bin/bash -n scripts/build-first-install-dmg.sh
/bin/bash -n scripts/publish-first-install.sh
if grep -n "CHANNEL:-stable" scripts/publish-first-install.sh >/dev/null; then
  fail "first-install publisher must not default to the stable zip channel"
fi
rg -F 'release/dmg/background.png' scripts/build-first-install-dmg.sh >/dev/null ||
  fail "first-install DMG builder must use the branded Finder background"
rg -F 'background picture of viewOptions' scripts/build-first-install-dmg.sh >/dev/null ||
  fail "first-install DMG builder must set the Finder background picture"

rg -F 'https://updates.jottly.ai' openflow/Services/UpdateService.swift >/dev/null ||
  fail "update server is not pinned"
rg -F 'Curve25519.Signing.PublicKey' openflow/Services/UpdateService.swift >/dev/null ||
  fail "Ed25519 verification is missing"
rg -F 'SHA256' openflow/Services/UpdateService.swift >/dev/null ||
  fail "SHA-256 verification is missing"
rg -F -- '--deep", "--strict' openflow/Services/UpdateService.swift >/dev/null ||
  fail "strict code-signature validation is missing"
if rg -F -- '"-R", UpdateConfiguration.codeRequirement' openflow/Services/UpdateService.swift >/dev/null; then
  fail "codesign -R requirement is passed as a separate filename argument"
fi
rg -F -- '-R=\(UpdateConfiguration.codeRequirement)' openflow/Services/UpdateService.swift >/dev/null ||
  fail "codesign team requirement must use a single -R= argument"
rg -F -- "-R='" openflow/Resources/install-update.sh >/dev/null ||
  fail "install-update.sh codesign -R must use -R=requirement, not a requirement file"
rg -F 'spctl' openflow/Services/UpdateService.swift >/dev/null ||
  fail "Gatekeeper validation is missing"
rg -F -- '--openflow-update-complete' openflow/Services/UpdateService.swift >/dev/null ||
  fail "launch confirmation is missing"
rg -F '.openflow.previous.app' openflow/Services/UpdateService.swift >/dev/null ||
  fail "rollback bundle is missing"
rg -F 'isSupportedInstallLocation' openflow/Services/UpdateService.swift >/dev/null ||
  fail "update installs are not restricted to Applications"
rg -F 'fileURLWithPath: "/Applications"' openflow/Services/UpdateService.swift >/dev/null ||
  fail "update installs must allow /Applications"
rg -F 'appendingPathComponent("Applications"' openflow/Services/UpdateService.swift >/dev/null ||
  fail "update installs must allow ~/Applications"
rg -F 'confirmHeartbeatRollback()' openflow/Services/UpdateService.swift >/dev/null ||
  fail "heartbeat rollback must require a confirmation alert"
rg -F '/bin/launchctl' openflow/Services/UpdateService.swift >/dev/null ||
  fail "update installer is not detached from the terminating app"
rg -F 'v1/installs/register' openflow/Services/UpdateService.swift >/dev/null ||
  fail "protocol v2 install registration is missing"
rg -F 'device_pubkey' openflow/Services/UpdateService.swift >/dev/null ||
  fail "protocol v2 device_pubkey registration is missing"
rg -F 'acceptRemoteUpdateCommand' openflow/Services/UpdateService.swift >/dev/null ||
  fail "remote update commands are not throttled"
rg -F 'maxRemoteTriggeredChecksPerWindow' openflow/Services/UpdateService.swift >/dev/null ||
  fail "remote update-check loop has no per-window cap"
rg -F 'Remote update check throttled' openflow/Services/UpdateService.swift >/dev/null ||
  fail "throttled remote update commands are not acknowledged"
rg -F 'device-ed25519' openflow/Services/UpdateDeviceIdentity.swift >/dev/null ||
  fail "device Ed25519 private key must live in Keychain"
if rg -n 'device-ed25519|device_pubkey' openflow/Services/UpdateDeviceIdentity.swift |
     rg -F 'UserDefaults' >/dev/null; then
  fail "device private key must not be stored in UserDefaults"
fi
rg -F 'publicKeyBase64 = "Xtthrxu0C3E0HYbkMjqGLSOODgIC7YM8m2JeLsoQpis="' \
  openflow/Services/UpdateService.swift >/dev/null ||
  fail "release verify public key must not be rotated"
rg -F 'manifest.asset.url' openflow/Services/UpdateService.swift >/dev/null ||
  fail "downloads must follow asset.url from the manifest"
if rg -n '/v1/files/' openflow/Services/UpdateService.swift >/dev/null; then
  fail "do not hard-code /v1/files/:storageId"
fi

status="$(curl -sS -o /tmp/openflow-update-manifest-check.$$ -w '%{http_code}' \
  https://updates.jottly.ai/v1/apps/openflow/stable/macos-aarch64/latest.json)"
trap 'rm -f /tmp/openflow-update-manifest-check.$$' EXIT
[[ "$status" == "200" || "$status" == "404" ]] ||
  fail "manifest endpoint returned HTTP $status"

echo "update system static checks passed"
