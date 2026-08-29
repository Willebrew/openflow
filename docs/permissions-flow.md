# Permissions and First Run

openflow is an `LSUIElement` agent, so every TCC prompt it triggers competes for
focus with its own Flow Hub and onboarding windows. `PermissionsService` owns
that choreography; `OpenflowHubWindowRestorer` (in
`openflow/App/MenuBarController.swift`) owns bringing openflow's windows back.

## What onboarding requires

Only two permissions gate setup: **Microphone** and **Accessibility**, plus a
configured provider (Groq key or openflow Pro). Input Monitoring is deliberately
absent from onboarding and Settings, and
`scripts/check-permissions-flow-safety.mjs` fails the build if either surface
mentions or requests it.

## Microphone

`requestMicrophone()` branches on `AVCaptureDevice.authorizationStatus`:

- `.notDetermined`: call `requestAccess` -- the first click must show the system
  prompt, never System Settings.
- `.denied` / `.restricted`: deep-link the Microphone privacy pane and restore
  the hub once openflow becomes active again.
- `.authorized`: refresh and restore the hub.

## Accessibility: prompt first, deep-link only on the second click

The Accessibility grant dialog belongs to this process, so openflow still looks
frontmost while it is up. An earlier fallback used that as a signal and opened
System Settings a few seconds after the prompt, which stole focus and showed a
fresh Mac an empty Accessibility list. The current flow:

1. If `AXIsProcessTrusted()` is already true, refresh and restore the hub.
2. Otherwise set `accessibilityPromptIssued`, activate the app, and call
   `AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt: true])`.
3. Perform a real AX read (`registerAccessibilityClientIdentity`) so TCC records
   this process and openflow appears in the list.
4. First click: `scheduleAccessibilityPromptFollowUp` polls at 0.6s / 1.2s /
   2.4s. It restores the hub if the grant landed, backs off while the TCC prompt
   or System Settings is frontmost, and otherwise waits for the prompt to be
   dismissed. It never opens System Settings.
5. Later clicks (`accessibilityPromptIssued == true`): the button reads "Open
   Settings" and `openPrivacySettings()` deep-links the Accessibility pane.

Both Settings and onboarding swap their copy on `accessibilityPromptIssued`, so
the caption after the first click points at the macOS dialog instead of the
button.

## Hub window restore

`beginPermissionPrompt()` sets `PermissionsService.isPermissionPromptLikelyShowing`
and arms one of two follow-ups:

- `.whenPromptDismissed`: restore once the frontmost app is no longer a TCC
  prompt or System Settings.
- `.whenAppBecomesActive`: used after a Settings deep-link -- restore only when
  openflow is active again.

`requestHubWindowRestore()` posts `.openflowRestoreHubWindows`, and
`OpenflowHubWindowRestorer.restoreIfSafe()` re-checks both frontmost guards
before activating and re-fronting whichever of onboarding / Settings is visible.
Anything new that triggers a prompt must go through `beginPermissionPrompt()` and
`requestHubWindowRestore()` rather than calling `NSApp.activate` directly.

## Grant state polling

`startPolling()` refreshes every 10 seconds and also on
`NSApplication.didBecomeActive` and `NSWorkspace.didActivateApplication`, and
`refreshAfterPermissionRequest()` re-checks at 0s / 0.5s / 1.5s / 3s after a
request. That is why checkmarks flip without relaunching the app.

## Input Monitoring

Input Monitoring is only needed by hotkeys that swallow keystrokes.
`UserSettings.usesSwallowingHotkey` is true when any configured shortcut has
`requiresEventTap` (Control+Space, Option+Space); Hold Fn and Hold Option are
observational and use a 60Hz modifier poll instead. `HotkeyService.start`
installs a `CGEvent` tap only for swallowing shortcuts, so a default Hold Fn
setup never triggers the Input Monitoring prompt on first run.

When a tap cannot be created, `onAccessChanged(false)` makes
`DictationCoordinator` clear `permissions.inputMonitoringGranted` and log
`hotkey event tap unavailable for <label>`, so a denial is reported instead of
silently degrading. Grant state is probed with `IOHIDCheckAccess` plus
`CGPreflightListenEventAccess` (cached for 15s) -- never by creating a throwaway
event tap.

## Troubleshooting

- **openflow is missing from the Accessibility list**: click Enable once and
  answer the macOS dialog. Only click again if you need the list; the second
  click is what opens System Settings.
- **Grant toggled but openflow still fails**: TCC keys on the bundle path.
  `installToUserApplicationsForPermissions()` copies the bundle to
  `~/Applications/openflow.app` and relaunches, and
  `isRunningFromRecommendedInstallLocation` reports whether the running copy is
  already there. `revealOpenflowInFinder()` supports adding it manually.
- **Swallowing shortcut does nothing**: check the diagnostic log for
  `hotkey event tap unavailable`, then grant Input Monitoring (Privacy &
  Security > Input Monitoring) or switch back to Hold Fn.

## Verification

```sh
node scripts/check-permissions-flow-safety.mjs
scripts/check-startup-hotkey-safety.sh
```

The first pins the ordering rules above (prompt before deep-link, no Input
Monitoring in onboarding or Settings, shared hub restore); the second pins
hotkey startup, including the event-tap-only-when-swallowing rule. Both run in
`scripts/ci-linux.sh`.
