#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

fail() {
  echo "production readiness check failed: $1" >&2
  exit 1
}

deployment_target_count="$(
  rg -n 'MACOSX_DEPLOYMENT_TARGET = 26\.0;' openflow.xcodeproj/project.pbxproj |
    wc -l | tr -d ' '
)"
[[ "$deployment_target_count" == "2" ]] ||
  fail "all build configurations must require macOS 26.0 for native Liquid Glass"

if rg -F 'DEVELOPMENT_TEAM = "";' openflow.xcodeproj/project.pbxproj >/dev/null; then
  fail "DEVELOPMENT_TEAM must be pinned so release cannot ad-hoc-sign"
fi
team_count="$(
  rg -c 'DEVELOPMENT_TEAM = PXAS7J4XKW;' openflow.xcodeproj/project.pbxproj || true
)"
[[ "$team_count" == "4" ]] ||
  fail "all project and target configurations must pin DEVELOPMENT_TEAM PXAS7J4XKW"

if rg -n "pasteTextPreservingClipboard|clipboardPreservingSelectedTextFallback|sendCommandV|clipboard-bridge" openflow; then
  fail "clipboard insertion fallback symbols are present"
fi

if rg -n "gsk_[A-Za-z0-9]{20,}" openflow docs scripts README.md; then
  fail "hardcoded Groq-looking API key is present"
fi

if rg -n "Killebrew" openflow; then
  fail "personal name should not appear in production app sources"
fi

if rg -n "DictionaryEntry.seedTerms|SnippetEntry.seed|PhraseEntry.seed" openflow; then
  fail "seed dictionary or phrase content is still wired for new installs"
fi

rg -F 'Keys.debugLogsEnabled) as? Bool ?? false' openflow/Models/UserSettings.swift >/dev/null ||
  fail "debug logs must default off for production"

if rg -F "Version 0.1" openflow; then
  fail "settings still hardcodes Version 0.1"
fi

if rg -n "operatorMode|\\.agent|case agent|isOperatorActive|MacActionService|agentPrompt|agentStatus|agentIsRunning|agentService" openflow/App openflow/Models openflow/Services openflow/Views; then
  fail "Operator runtime route is present"
fi

# Private runbooks are gitignored. Require presence, not +x -- some clones
# drop the executable bit (Linux CI, FAT/shared mounts).
test -f docs/cloud-mode.md || fail "missing docs/cloud-mode.md"
test -f docs/cloud-e2e-checklist.md || fail "missing docs/cloud-e2e-checklist.md"
test -f docs/insertion-regression-matrix.md || fail "missing docs/insertion-regression-matrix.md"
test -f scripts/check-local-release-gate.sh || fail "missing local release gate"
test -f scripts/build-notarized-release.sh || fail "missing notarized release builder"
test -f scripts/build-first-install-dmg.sh || fail "missing first-install DMG builder"
test -f release/dmg/background.png || fail "missing first-install DMG background"
test -f release/dmg/hero-crop.png || fail "missing live hero crop"
test -f docs/openflow_logo.png || fail "missing README logo"
test -f scripts/publish-update.sh || fail "missing update publisher"
test -f scripts/publish-first-install.sh || fail "missing first-install publisher"
test -f scripts/check-update-system.sh || fail "missing update-system check"
test -f scripts/insertion-regression-report.mjs || fail "missing insertion regression reporter"
test -f scripts/verify-release-evidence.mjs || fail "missing release evidence verifier"
test -f scripts/check-release-evidence-validator.mjs || fail "missing release evidence verifier self-check"
test -f scripts/check-audio-capture-safety.mjs || fail "missing audio capture safety check"
test -f scripts/check-permissions-flow-safety.mjs || fail "missing permissions flow safety check"
test -f scripts/check-history-ui-safety.mjs || fail "missing history UI safety check"
test -f scripts/check-hub-page-chrome.mjs || fail "missing hub page chrome check"
test -f scripts/check-terminal-cleanup-safety.mjs || fail "missing terminal cleanup safety check"
test -f release/exportOptions.template.plist || fail "missing Developer ID export options template"
test -f release/release-evidence.template.json || fail "missing release evidence template"
cloud_client="openflow/Services/OpenFlowCloudService.swift"
test -f "$cloud_client" || fail "missing OpenFlow Cloud client"
for route in \
  "/openflow/entitlement" \
  "/openflow/preferences" \
  "/openflow/stats" \
  "/openflow/activity" \
  "/openflow/stt-ticket" \
  "/openflow/audio-upload-url" \
  "/openflow/transcribe" \
  "/openflow/transcribe-fast" \
  "/openflow/cleanup" \
  "/openflow/generate-style" \
  "/openflow/billing/checkout" \
  "/openflow/billing/portal"; do
  rg -F "$route" "$cloud_client" >/dev/null ||
    fail "missing native cloud-client route $route"
done
rg -F "https://openflow-site-cvx.jottly.ai" \
  openflow/Models/UserSettings.swift >/dev/null ||
  fail "production Convex HTTP-actions URL is missing"
billing_guard_count="$(
  rg -F -c "usage: .billing" "$cloud_client" || true
)"
[[ "$billing_guard_count" == "2" ]] ||
  fail "both billing links must be validated with CloudURLPolicy"
rg -F "CloudURLPolicy.validate(reservation.uploadUrl" "$cloud_client" >/dev/null ||
  fail "audio upload URL is used without CloudURLPolicy validation"
rg -F "CloudURLPolicy.validate(authorization.verificationUriComplete" \
  openflow/Services/CloudAuthService.swift >/dev/null ||
  fail "device verification URL is opened without CloudURLPolicy validation"
if rg -n "NSWorkspace.shared.open\\(" openflow/Services/CloudAuthService.swift |
  rg -v "verificationURL" >/dev/null; then
  fail "device sign-in must only open a CloudURLPolicy-validated URL"
fi
rg -F "static func openExternal(_ url: URL) -> Bool" \
  openflow/Services/CloudURLPolicy.swift >/dev/null ||
  fail "missing https-only open helper in CloudURLPolicy"
if rg -F "NSWorkspace.shared.open(url)" openflow/Views/OnboardingFlowView.swift >/dev/null; then
  fail "onboarding billing links must open through CloudURLPolicy.openExternal"
fi
rg -F "CloudURLPolicy.openExternal(url)" openflow/Views/SettingsView.swift >/dev/null ||
  fail "settings billing links must open through CloudURLPolicy.openExternal"
rg -F "api/openflow/introspect" openflow/Services/CloudSessionValidator.swift >/dev/null ||
  fail "missing NQL Auth introspect path for remote session revocation"
rg -F "enum CloudSessionValidity" openflow/Services/CloudSessionValidator.swift >/dev/null ||
  fail "missing CloudSessionValidity decision type"
rg -F "case cloudSessionRevoked" openflow/Models/DictationModels.swift >/dev/null ||
  fail "authenticated 401 must map to cloudSessionRevoked, not the no-token prompt"
rg -F "applyRemoteCloudRevocation" openflow/Services/DictationCoordinator.swift >/dev/null ||
  fail "revoked sessions must clear cloud UI through applyRemoteCloudRevocation"
rg -F "revalidateStoredCloudSession()" openflow/App/MenuBarController.swift >/dev/null ||
  fail "menu-bar clicks must introspect so revoke is not gated on opening Flow Hub"
rg -F "CloudSessionValidator.menuRevalidateInterval" openflow/Services/DictationCoordinator.swift >/dev/null ||
  fail "menu-bar introspect must be debounced so spam-clicks do not storm NQL Auth"
if rg -A 20 "func beginDictation" openflow/Services/DictationCoordinator.swift |
  rg -F "revalidateStoredCloudSession()" >/dev/null; then
  fail "hold-Fn must not introspect on every utterance"
fi
if rg -F "Timer.scheduledTimer" openflow/Services/DictationCoordinator.swift >/dev/null; then
  fail "cloud session timer must use Timer + RunLoop.common so accessory mode without hub still fires"
fi
if rg -F "cloud.entitlement" openflow/Services/TranscriptionService.swift >/dev/null; then
  fail "transcription warmUp must not poll Convex entitlement"
fi
if rg -F '$6' openflow/Models/CloudPrivacyCopy.swift >/dev/null; then
  fail "Pro copy must not mention \$6 included spend"
fi
rg -F "NSWorkspace.didWakeNotification" openflow/Services/DictationCoordinator.swift >/dev/null ||
  fail "stored sessions must revalidate on system wake"
rg -F "NSWorkspace.screensDidWakeNotification" openflow/Services/DictationCoordinator.swift >/dev/null ||
  fail "stored sessions must revalidate when screens wake"
rg -F "CloudSessionValidator.refreshInterval" openflow/Services/DictationCoordinator.swift >/dev/null ||
  fail "stored sessions must revalidate on the 12-minute timer"
if rg -n "deleteAPIKey" openflow/Services/CloudAuthService.swift \
  openflow/Services/CloudSessionValidator.swift >/dev/null; then
  fail "session revoke must not delete the BYO Groq key"
fi
if rg -A 25 "func applyRemoteCloudRevocation" openflow/Services/DictationCoordinator.swift |
  rg -n "deleteAPIKey" >/dev/null; then
  fail "applyRemoteCloudRevocation must not delete the BYO Groq key"
fi
rg -F "keychain.deleteCloudTokens()" openflow/Services/CloudAuthService.swift >/dev/null ||
  fail "signOut must keep using KeychainService.deleteCloudTokens"
rg -F "pendingClearAll = true" openflow/Views/HistoryView.swift >/dev/null ||
  fail "History Clear must require confirmation"
settings_direct_opens="$(
  rg -c -F "NSWorkspace.shared.open(url)" openflow/Views/SettingsView.swift || true
)"
[[ "${settings_direct_opens:-0}" == "1" ]] ||
  fail "settings may only open the local diagnostics folder directly"
node scripts/check-browser-insertion-safety.mjs
node scripts/check-audio-capture-safety.mjs
node scripts/check-hotkey-text-input-safety.mjs
node scripts/check-permissions-flow-safety.mjs
node scripts/check-history-ui-safety.mjs
if rg -n 'sparkles|sparkle\.|wand\.and\.stars|"star\.fill"' \
  openflow/Views openflow/Models/UserSettings.swift openflow/App; then
  fail "sparkle/star SF Symbols must not appear in product UI"
fi
if rg -F "openflow Pro is unavailable" openflow; then
  fail "cloud errors must not label generate or HTTP failures as Pro unavailable"
fi
if rg -F "Save raw STT text" openflow/Views/SettingsView.swift; then
  fail "Settings General must not show the raw STT developer toggle"
fi
rg -F "style_generate_pro_required" "$cloud_client" >/dev/null ||
  fail "cloud client must map generate-style Pro rejects"
node scripts/check-hub-page-chrome.mjs
node scripts/check-release-evidence-validator.mjs
node scripts/check-terminal-cleanup-safety.mjs
rg -F 'let succeeded = insertionResult.succeeded' \
  openflow/Services/DictationCoordinator.swift >/dev/null ||
  fail "success flag is not derived from insertionResult.succeeded"
success_state_count="$(rg -n 'pillViewModel\.state = succeeded \? \.success : \.error\("Insertion failed"\)' openflow/Services/DictationCoordinator.swift || true)"
success_state_count="$(printf "%s\n" "$success_state_count" | sed '/^$/d' | wc -l | tr -d ' ')"
if [[ "$success_state_count" != "1" ]]; then
  fail "success UI is not guarded by insertionResult.succeeded after insertion"
fi

if ! command -v xcrun >/dev/null 2>&1 || ! command -v swiftc >/dev/null 2>&1; then
  echo "skipping Xcode swiftc contracts (macOS/Xcode only)"
  echo "production readiness static checks passed"
  exit 0
fi

SDK="$(xcrun --sdk macosx --show-sdk-path)"
xcrun --sdk macosx swiftc -parse -sdk "$SDK" -target arm64-apple-macos14.0 $(find openflow -name '*.swift' -print)

SETTINGS_CHECK="$(mktemp /tmp/openflow-settings-check.XXXXXX)"
xcrun --sdk macosx swiftc -sdk "$SDK" \
  -target arm64-apple-macos14.0 \
  openflow/Models/UserSettings.swift \
  scripts/check-user-settings-persistence.swift \
  -o "$SETTINGS_CHECK"
"$SETTINGS_CHECK"
rm -f "$SETTINGS_CHECK"

INSERTION_PREP_CHECK="$(mktemp /tmp/openflow-insertion-prep-check.XXXXXX)"
xcrun --sdk macosx swiftc -sdk "$SDK" \
  -target arm64-apple-macos14.0 \
  openflow/Services/InsertionTextPreparation.swift \
  scripts/check-insertion-text-preparation.swift \
  -o "$INSERTION_PREP_CHECK"
"$INSERTION_PREP_CHECK"
rm -f "$INSERTION_PREP_CHECK"

HISTORY_PRIVACY_CHECK="$(mktemp /tmp/openflow-history-privacy-check.XXXXXX)"
xcrun --sdk macosx swiftc -sdk "$SDK" \
  -target arm64-apple-macos14.0 \
  openflow/Models/UserSettings.swift \
  openflow/Models/DictationModels.swift \
  openflow/Models/HomeActivityStats.swift \
  openflow/Services/CloudSessionValidator.swift \
  openflow/Services/HistoryService.swift \
  openflow/Services/InsertionDiagnosticsService.swift \
  scripts/check-history-privacy.swift \
  -o "$HISTORY_PRIVACY_CHECK"
"$HISTORY_PRIVACY_CHECK"
rm -f "$HISTORY_PRIVACY_CHECK"

HOME_ACTIVITY_CHECK="$(mktemp /tmp/openflow-home-activity-check.XXXXXX)"
xcrun --sdk macosx swiftc -sdk "$SDK" \
  -target arm64-apple-macos14.0 \
  openflow/Models/HomeActivityStats.swift \
  scripts/check-home-activity-stats.swift \
  -o "$HOME_ACTIVITY_CHECK"
"$HOME_ACTIVITY_CHECK"
rm -f "$HOME_ACTIVITY_CHECK"

CLEANUP_CONTEXT_CHECK="$(mktemp /tmp/openflow-cleanup-context-check.XXXXXX)"
xcrun --sdk macosx swiftc -sdk "$SDK" \
  -target arm64-apple-macos14.0 \
  openflow/Models/UserSettings.swift \
  openflow/Models/DictationModels.swift \
  openflow/Models/HomeActivityStats.swift \
  openflow/Services/KeychainService.swift \
  openflow/Services/CloudURLPolicy.swift \
  openflow/Services/CloudSessionValidator.swift \
  openflow/Services/AudioFileFormat.swift \
  openflow/Services/OpenFlowCloudService.swift \
  openflow/Services/OpenFlowProviderRouting.swift \
  openflow/Services/CommandSubmissionPolicy.swift \
  openflow/Services/CleanupFormattingService.swift \
  openflow/Services/PressEnterCommand.swift \
  openflow/Services/EmailLetterFormatter.swift \
  openflow/Services/FieldTextWindow.swift \
  openflow/Services/SelfCorrectionFormatter.swift \
  openflow/Services/ListFormatter.swift \
  openflow/Services/ContextService.swift \
  scripts/check-cleanup-context.swift \
  -o "$CLEANUP_CONTEXT_CHECK"
"$CLEANUP_CONTEXT_CHECK"
rm -f "$CLEANUP_CONTEXT_CHECK"

PROVIDER_ROUTING_CHECK="$(mktemp /tmp/openflow-provider-routing-check.XXXXXX)"
xcrun --sdk macosx swiftc -sdk "$SDK" \
  -target arm64-apple-macos14.0 \
  openflow/Models/UserSettings.swift \
  openflow/Services/OpenFlowProviderRouting.swift \
  scripts/check-provider-routing.swift \
  -o "$PROVIDER_ROUTING_CHECK"
"$PROVIDER_ROUTING_CHECK"
rm -f "$PROVIDER_ROUTING_CHECK"

CLOUD_URL_POLICY_CHECK="$(mktemp /tmp/openflow-cloud-url-policy-check.XXXXXX)"
xcrun --sdk macosx swiftc -sdk "$SDK" \
  -target arm64-apple-macos14.0 \
  openflow/Models/UserSettings.swift \
  openflow/Models/DictationModels.swift \
  openflow/Services/CloudSessionValidator.swift \
  openflow/Services/CloudURLPolicy.swift \
  scripts/check-cloud-url-policy.swift \
  -o "$CLOUD_URL_POLICY_CHECK"
"$CLOUD_URL_POLICY_CHECK"
rm -f "$CLOUD_URL_POLICY_CHECK"

CLOUD_SESSION_CHECK="$(mktemp /tmp/openflow-cloud-session-check.XXXXXX)"
xcrun --sdk macosx swiftc -sdk "$SDK" \
  -target arm64-apple-macos14.0 \
  openflow/Services/CloudSessionValidator.swift \
  scripts/check-cloud-session-validator.swift \
  -o "$CLOUD_SESSION_CHECK"
"$CLOUD_SESSION_CHECK"
rm -f "$CLOUD_SESSION_CHECK"

HOTKEY_POLICY_CHECK="$(mktemp /tmp/openflow-hotkey-policy-check.XXXXXX)"
xcrun --sdk macosx swiftc -sdk "$SDK" \
  -target arm64-apple-macos14.0 \
  openflow/Services/HotkeyCapturePolicy.swift \
  scripts/check-hotkey-capture-policy.swift \
  -o "$HOTKEY_POLICY_CHECK"
"$HOTKEY_POLICY_CHECK"
rm -f "$HOTKEY_POLICY_CHECK"

echo "production readiness static checks passed"
