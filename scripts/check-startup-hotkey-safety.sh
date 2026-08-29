#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

fail() {
  echo "startup/hotkey safety check failed: $1" >&2
  exit 1
}

APP_DELEGATE="openflow/App/AppDelegate.swift"
MENU_BAR="openflow/App/MenuBarController.swift"
HOTKEY_SERVICE="openflow/Services/HotkeyService.swift"
COORDINATOR="openflow/Services/DictationCoordinator.swift"

rg -F 'case .openflowCloud:' "$APP_DELEGATE" >/dev/null ||
  fail "cloud provider setup is not handled"
rg -U -F $'case .openflowCloud:\n            return false' "$APP_DELEGATE" >/dev/null ||
  fail "cloud users can be forced back into local-key onboarding"
if rg -F '!UserDefaults.standard.bool(forKey: OnboardingWindowController.completionKey) || needsSetup' "$APP_DELEGATE" >/dev/null; then
  fail "completed onboarding must not reopen because setup is incomplete after an update"
fi
rg -F 'hasCompletedInteractiveOnboarding' "$MENU_BAR" >/dev/null ||
  fail "onboarding completion key is missing"
rg -F 'OnboardingWindowController.completionKey' "$APP_DELEGATE" >/dev/null ||
  fail "launch must read the version-independent onboarding completion key"
rg -F 'CFBundleVersion' "$APP_DELEGATE" >/dev/null &&
  fail "onboarding completion must stay version-independent"
rg -F 'func start(settingsProvider:' "$HOTKEY_SERVICE" >/dev/null ||
  fail "hotkey service start is missing"
rg -U -F $'func start(settingsProvider: @escaping () -> UserSettings) {\n        stop()' "$HOTKEY_SERVICE" >/dev/null ||
  fail "hotkey start is not idempotent"
rg -F 'usesSwallowingHotkey' "$HOTKEY_SERVICE" >/dev/null ||
  fail "event tap must be limited to swallowing hotkeys"
rg -F 'HotkeyCapturePolicy.shouldSwallow' "$HOTKEY_SERVICE" >/dev/null ||
  fail "event tap swallow decisions must go through HotkeyCapturePolicy"
rg -F 'installEventTapIfPossible' "$HOTKEY_SERVICE" >/dev/null ||
  fail "swallowing hotkeys must install an event tap only when needed"
rg -F 'startModifierPolling' "$HOTKEY_SERVICE" >/dev/null ||
  fail "Hold Fn must keep an observational polling path"
rg -F 'isModifierOnly: true' "$HOTKEY_SERVICE" >/dev/null ||
  fail "Hold Fn / Option hold must start even when a front-app text field is focused"
if rg -F 'addGlobalMonitorForEvents' "$HOTKEY_SERVICE" >/dev/null; then
  fail "global key monitors prompt Input Monitoring and must not be the Hold Fn fallback"
fi
rg -F 'CFMachPortInvalidate(eventTap)' "$HOTKEY_SERVICE" >/dev/null ||
  fail "event tap is not explicitly invalidated"
rg -F 'pendingOptionStart?.cancel()' "$HOTKEY_SERVICE" >/dev/null ||
  fail "pending modifier work is not cancelled"
rg -F 'private var hasStarted = false' "$COORDINATOR" >/dev/null ||
  fail "coordinator lifecycle guard is missing"
rg -F 'audio.warmUp(deviceID:' "$COORDINATOR" >/dev/null ||
  fail "audio engine is not warmed before the first dictation"
rg -F 'Self.runOnMain' "$COORDINATOR" >/dev/null ||
  fail "hotkey callbacks do not hop to main without Task latency"
rg -F 'isReadyToShowPill' "$COORDINATOR" >/dev/null ||
  fail "pill visibility must wait until setup is complete"
rg -F 'hasCompletedInteractiveOnboarding' "$COORDINATOR" >/dev/null ||
  fail "pill visibility must require interactive onboarding completion"
rg -F 'hasConfiguredProvider()' "$COORDINATOR" >/dev/null ||
  fail "pill visibility must require a configured provider"
rg -U -F $'guard isReadyToShowPill else {\n            floatingWindow.hide(after: 0)' "$COORDINATOR" >/dev/null ||
  fail "pill must stay hidden until the app is fully set up"
rg -U -F $'func beginDictation(mode: DictationMode, requestedAt: Date = Date()) {\n        guard session == nil, processingSessionID == nil else { return }\n        guard isReadyToShowPill else { return }' "$COORDINATOR" >/dev/null ||
  fail "dictation must not start until setup is complete"
rg -U -F $'private func restartHotkeys() {\n        guard hasStarted else { return }\n        guard isReadyToShowPill else {' "$COORDINATOR" >/dev/null ||
  fail "hotkey event tap must not arm until setup is complete"
rg -F 'syncHotkeysWithReadiness()' "$COORDINATOR" >/dev/null ||
  fail "hotkeys must re-arm when setup readiness changes"

echo "startup/hotkey safety checks passed"
