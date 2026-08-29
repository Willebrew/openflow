#!/usr/bin/env node
import fs from "node:fs";
import path from "node:path";

const root = path.resolve(import.meta.dirname, "..");
const source = fs.readFileSync(path.join(root, "openflow/Services/PermissionsService.swift"), "utf8");
const onboarding = fs.readFileSync(path.join(root, "openflow/Views/OnboardingFlowView.swift"), "utf8");
const settings = fs.readFileSync(path.join(root, "openflow/Views/SettingsView.swift"), "utf8");
const home = fs.readFileSync(path.join(root, "openflow/Views/HomeDashboardView.swift"), "utf8");

function fail(message) {
  console.error(`permissions flow safety check failed: ${message}`);
  process.exit(1);
}

function assert(condition, message) {
  if (!condition) fail(message);
}

assert(source.includes("func requestInputMonitoring()"), "missing Input Monitoring request flow");
assert(source.includes("_ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)"), "Input Monitoring request should ask IOHID to register the app");
assert(source.includes("_ = CGRequestListenEventAccess()"), "Input Monitoring request should ask CoreGraphics to register the app");
assert(source.includes("let granted = inputMonitoringSystemGranted()"), "Input Monitoring request must use system grant state, not a temporary event tap");
assert(source.includes("private func inputMonitoringSystemGranted() -> Bool"), "missing system grant helper");
assert(source.includes("IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted"), "system grant helper must check IOHID access");
assert(source.includes("CGPreflightListenEventAccess()"), "system grant helper must check CoreGraphics preflight access");
assert(!source.includes("canCreateInputMonitoringEventTap"), "temporary event tap probes must not determine Input Monitoring grant state");
assert(source.includes("openInputMonitoringSettings()"), "missing Input Monitoring settings opener");
assert(source.includes("Privacy_ListenEvent"), "Input Monitoring settings opener must target the ListenEvent privacy pane");
assert(source.includes("func revealOpenflowInFinder()"), "missing Finder reveal helper for manual Input Monitoring add");
assert(source.includes("activateFileViewerSelecting([Bundle.main.bundleURL])"), "Finder reveal helper must select the running app bundle");
assert(source.includes("func installToUserApplicationsForPermissions()"), "missing stable install helper for debug Input Monitoring recovery");
assert(source.includes("appendingPathComponent(\"Applications\", isDirectory: true)"), "stable install helper must use the user's Applications folder");
assert(source.includes("NSWorkspace.shared.openApplication(at: destination"), "stable install helper must relaunch the installed app");
assert(!onboarding.includes("Input Monitoring"), "onboarding must not require Input Monitoring");
assert(!onboarding.includes("inputMonitoringGranted"), "onboarding readiness must not gate on Input Monitoring");
assert(!onboarding.includes("requestInputMonitoring"), "onboarding must not request Input Monitoring");
assert(!onboarding.includes("polling fallback"), "onboarding must not warn about Input Monitoring polling");
assert(!settings.includes("Input Monitoring"), "Settings must not surface Input Monitoring in the permission flow");
assert(!settings.includes("polling fallback"), "Settings must not warn about Input Monitoring polling");
assert(!settings.includes("requestInputMonitoring"), "Settings must not request Input Monitoring");
assert(source.includes("AXIsProcessTrustedWithOptions"), "Accessibility request must prompt TCC so the app appears in the list");
assert(source.includes("kAXTrustedCheckOptionPrompt"), "Accessibility request must set AXTrustedCheckOptionPrompt");
assert(source.includes("kCFBooleanTrue"), "Accessibility prompt option must be CFBoolean true");
assert(source.includes("AXUIElementCreateSystemWide"), "Accessibility request must touch AX so TCC records this process");
assert(source.includes("AXUIElementCopyAttributeValue"), "Accessibility request must perform a real AX read after prompting");
assert(source.includes("accessibilityPromptIssued"), "must remember the first Accessibility prompt so Settings opens only on a later click");
const requestAx = source.slice(source.indexOf("func requestAccessibility()"), source.indexOf("func requestInputMonitoring()"));
assert(requestAx.includes("AXIsProcessTrustedWithOptions"), "first-time Accessibility request must call AXIsProcessTrustedWithOptions");
assert(requestAx.includes("alreadyPrompted"), "second Enable click may open Settings after the prompt");
assert(requestAx.includes("scheduleAccessibilityPromptFollowUp"), "Accessibility request must wait for the TCC prompt before opening Settings");
assert(requestAx.indexOf("AXIsProcessTrustedWithOptions") < requestAx.indexOf("openPrivacySettings()"), "must prompt Accessibility before opening System Settings");
assert(requestAx.includes("isTCCPromptFrontmost"), "Accessibility follow-up must detect the TCC prompt");
const followUp = source.slice(source.indexOf("private func scheduleAccessibilityPromptFollowUp"), source.indexOf("func requestInputMonitoring()"));
assert(!followUp.includes("openPrivacySettings()"), "first Enable click must not race-open Accessibility Settings");
assert(requestAx.indexOf("AXIsProcessTrustedWithOptions") < requestAx.indexOf("if alreadyPrompted"), "first Enable click must prompt before any Settings deep-link");
assert(source.includes("case .notDetermined:"), "first-time microphone request must use the notDetermined path");
assert(source.includes("beginPermissionPrompt()"), "permission requests must mark the TCC prompt so hub windows do not steal focus");
assert(source.includes("requestHubWindowRestore()"), "permission completion must restore Flow Hub / onboarding");
assert(source.includes("isSystemPermissionUIFrontmost()"), "missing system permission UI frontmost check");
assert(source.includes("whenAppBecomesActive"), "System Settings must restore the hub only after openflow becomes active again");
assert(settings.includes("OpenflowHubWindowRestorer.restoreIfSafe()"), "Settings / Flow Hub must restore on activation like onboarding");
assert(onboarding.includes("OpenflowHubWindowRestorer.restoreIfSafe()"), "onboarding must restore through the shared hub restorer");
assert(home.includes("if cloudSignedIn"), "signed-in Home must use cloud stats instead of local history");
assert(home.includes("history: []"), "signed-in Home must not mix local clips into cloud days");
const homeBody = home.slice(home.indexOf("var body: some View"), home.indexOf("private var compactHeader"));
assert(!homeBody.includes("ScrollView"), "ready Home must not scroll; the dashboard must fit the Flow Hub pane");
assert(home.includes("Button(\"View all apps →\", action: onOpenApps)"),
       "View all apps must open an Apps hub page, not History");
assert(!home.includes("allAppsOverlay"),
       "View all apps must not dim or cover the Home dashboard");
assert(!home.includes("showingAllApps"),
       "View all apps must not keep an overlay on Home");
assert(!home.includes("Button(\"View all apps →\", action: onOpenHistory)"),
       "View all apps must not open History");
assert(home.includes("Button(\"View history →\", action: onOpenHistory)"),
       "Last clip View history may still open History");
assert(home.includes("GeometryReader"), "Home must fit-to-page with GeometryReader instead of a tall stack");
assert(home.includes("calendarWeekWordCounts"), "Home week chart is the current Mon–Sun week");
assert(home.includes("copyLatestClip"), "last clip must copy dictation text to the pasteboard");
assert(home.includes("NSPasteboard.general.setString"), "last clip copy must write the clip to the pasteboard");
assert(!home.includes("HomeBoardHairline"), "ready Home is 2×2 rounded cards, not one hairline board");
assert(!home.includes("HomePanel"), "ready Home must not stack HomePanel glass slabs");
assert(!home.includes("FlowLogo"), "time saved must not add an extra logo on the board");
assert(!home.includes("every Mac"), "Home copy must not talk about Macs or devices");
assert(!home.includes("this Mac"), "Home copy must not talk about Macs or devices");
assert(home.includes("HomeStatCard"), "ready Home uses rounded stat cards");
const cardUses = home.match(/HomeStatCard\(/g) ?? [];
assert(cardUses.length >= 4, "ready Home must be four rounded glass cards");
assert((home.match(/flowLiquidGlass/g) ?? []).length >= 1, "Home cards must use FlowUI glass");

const requestMic = source.slice(source.indexOf("func requestMicrophone()"), source.indexOf("func requestAccessibility()"));
assert(requestMic.includes("AVCaptureDevice.requestAccess"), "microphone request must call requestAccess");
const notDetermined = requestMic.slice(requestMic.indexOf("case .notDetermined:"), requestMic.indexOf("@unknown default"));
assert(!notDetermined.includes("openMicrophoneSettings()"), "first-time microphone request must not open System Settings");
assert(notDetermined.includes("requestAccess"), "first-time microphone request must call requestAccess");

console.log("permissions flow safety checks passed");
