import AppKit
import ApplicationServices
import AVFoundation
import Combine
import IOKit.hidsystem

extension Notification.Name {
    static let openflowRestoreHubWindows = Notification.Name("openflowRestoreHubWindows")
    static let openflowCloudSessionDidChange = Notification.Name("openflowCloudSessionDidChange")
}

final class PermissionsService: ObservableObject {
    @Published var microphoneGranted = false
    @Published var accessibilityGranted = false
    @Published var accessibilityPromptIssued = false
    @Published var inputMonitoringGranted = false
    @Published var automationLikelyAvailable = true
    @Published var permissionRecoveryMessage: String?
    private var refreshTimer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var lastInputMonitoringProbeAt: Date = .distantPast
    private var cachedInputMonitoringProbe = false
    private var hubRestoreFollowUp: HubRestoreFollowUp = .none
    private var accessibilityPromptFollowUp: DispatchWorkItem?
    private(set) static var isPermissionPromptLikelyShowing = false

    private enum HubRestoreFollowUp {
        case none
        case whenPromptDismissed
        case whenAppBecomesActive
    }

    var isRunningFromRecommendedInstallLocation: Bool {
        Bundle.main.bundleURL.standardizedFileURL == recommendedInstallURL.standardizedFileURL
    }

    func refresh() {
        microphoneGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        accessibilityGranted = AXIsProcessTrusted()
        inputMonitoringGranted = inputMonitoringAccessGranted()
    }

    func startPolling() {
        refresh()
        refreshTimer?.invalidate()
        let timer = Timer(timeInterval: 10.0, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                self?.refresh()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
        installActivationObservers()
    }

    func stopPolling() {
        accessibilityPromptFollowUp?.cancel()
        accessibilityPromptFollowUp = nil
        refreshTimer?.invalidate()
        refreshTimer = nil
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
    }

    func requestMicrophone() {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .authorized:
            refresh()
            requestHubWindowRestore()
        case .denied, .restricted:
            openMicrophoneSettings()
            refresh()
            hubRestoreFollowUp = .whenAppBecomesActive
        case .notDetermined:
            beginPermissionPrompt()
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
                DispatchQueue.main.async {
                    self?.endPermissionPrompt()
                    self?.refresh()
                    self?.hubRestoreFollowUp = .none
                    self?.requestHubWindowRestore()
                }
            }
        @unknown default:
            refresh()
        }
    }

    func requestAccessibility() {
        if AXIsProcessTrusted() {
            refresh()
            requestHubWindowRestore()
            return
        }
        accessibilityPromptFollowUp?.cancel()
        // Opening Accessibility Settings on the same click as the TCC prompt steals
        // focus. The grant dialog is owned by this LSUIElement process, so we stay
        // "frontmost" and the previous ~3s fallback opened Settings, which is why
        // a fresh Mac showed an empty list. Prompt first; deep-link only later.
        let alreadyPrompted = accessibilityPromptIssued
        accessibilityPromptIssued = true
        NSApp.activate(ignoringOtherApps: true)
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as NSString
        let options: NSDictionary = [promptKey: kCFBooleanTrue as Any]
        _ = AXIsProcessTrustedWithOptions(options)
        registerAccessibilityClientIdentity()
        refresh()
        refreshAfterPermissionRequest()
        beginPermissionPrompt()
        if alreadyPrompted {
            openPrivacySettings()
            hubRestoreFollowUp = .whenAppBecomesActive
            return
        }
        scheduleAccessibilityPromptFollowUp(attempt: 0)
    }

    private func registerAccessibilityClientIdentity() {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedApp: AnyObject?
        _ = AXUIElementCopyAttributeValue(systemWide, kAXFocusedApplicationAttribute as CFString, &focusedApp)
    }

    private func scheduleAccessibilityPromptFollowUp(attempt: Int) {
        let delays: [TimeInterval] = [0.6, 1.2, 2.4]
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.refresh()
            if self.accessibilityGranted {
                self.accessibilityPromptFollowUp = nil
                self.endPermissionPrompt()
                self.hubRestoreFollowUp = .none
                self.requestHubWindowRestore()
                return
            }
            if Self.isTCCPromptFrontmost() || Self.isSystemSettingsFrontmost() {
                if attempt + 1 < delays.count {
                    self.scheduleAccessibilityPromptFollowUp(attempt: attempt + 1)
                    return
                }
                self.accessibilityPromptFollowUp = nil
                self.endPermissionPrompt()
                self.hubRestoreFollowUp = .whenAppBecomesActive
                return
            }
            if attempt + 1 < delays.count {
                self.scheduleAccessibilityPromptFollowUp(attempt: attempt + 1)
                return
            }
            // First Enable click never opens Settings. Leave the system dialog alone
            // even if this LSUIElement process still looks frontmost.
            self.accessibilityPromptFollowUp = nil
            self.endPermissionPrompt()
            self.hubRestoreFollowUp = .whenPromptDismissed
        }
        accessibilityPromptFollowUp = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delays[attempt], execute: work)
    }

    func requestInputMonitoring() {
        primeInputMonitoringRegistration()
        _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        _ = CGRequestListenEventAccess()
        let granted = inputMonitoringSystemGranted()
        cachedInputMonitoringProbe = granted
        lastInputMonitoringProbeAt = Date()
        refresh()
        refreshAfterPermissionRequest()
        if !granted {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                self.primeInputMonitoringRegistration()
                self.refresh()
                guard !self.inputMonitoringGranted else { return }
                self.openInputMonitoringSettings()
            }
        }
    }

    private func installActivationObservers() {
        guard observers.isEmpty else { return }
        let appObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                                                 object: nil,
                                                                 queue: .main) { [weak self] _ in
            self?.handleAppBecameActive()
        }
        let workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                                                  object: nil,
                                                                                  queue: .main) { [weak self] _ in
            self?.handleWorkspaceActivation()
        }
        observers = [appObserver, workspaceObserver]
    }

    private func refreshAfterPermissionRequest() {
        let delays: [TimeInterval] = [0, 0.5, 1.5, 3.0]
        for delay in delays {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.refresh()
            }
        }
    }

    private func handleAppBecameActive() {
        refreshAfterPermissionRequest()
        finishHubRestoreIfNeeded(promptDismissed: false)
    }

    private func handleWorkspaceActivation() {
        refreshAfterPermissionRequest()
        if Self.isTCCPromptFrontmost() {
            return
        }
        if Self.isSystemSettingsFrontmost() {
            if hubRestoreFollowUp == .whenPromptDismissed {
                endPermissionPrompt()
                hubRestoreFollowUp = .whenAppBecomesActive
            }
            return
        }
        finishHubRestoreIfNeeded(promptDismissed: true)
    }

    private func finishHubRestoreIfNeeded(promptDismissed: Bool) {
        switch hubRestoreFollowUp {
        case .none:
            return
        case .whenPromptDismissed:
            guard promptDismissed else { return }
            guard !Self.isSystemPermissionUIFrontmost() else { return }
            endPermissionPrompt()
            hubRestoreFollowUp = .none
            requestHubWindowRestore()
        case .whenAppBecomesActive:
            guard NSApp.isActive else { return }
            guard !Self.isSystemPermissionUIFrontmost() else { return }
            endPermissionPrompt()
            hubRestoreFollowUp = .none
            requestHubWindowRestore()
        }
    }

    private func requestHubWindowRestore() {
        guard !Self.isSystemPermissionUIFrontmost() else { return }
        guard !Self.isPermissionPromptLikelyShowing else { return }
        NotificationCenter.default.post(name: .openflowRestoreHubWindows, object: nil)
    }

    private func beginPermissionPrompt() {
        Self.isPermissionPromptLikelyShowing = true
        hubRestoreFollowUp = .whenPromptDismissed
    }

    private func endPermissionPrompt() {
        Self.isPermissionPromptLikelyShowing = false
    }

    static func isSystemPermissionUIFrontmost() -> Bool {
        isTCCPromptFrontmost() || isSystemSettingsFrontmost()
    }

    static func isTCCPromptFrontmost() -> Bool {
        guard let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else {
            return false
        }
        return tccPromptBundleIDs.contains { bundleID == $0 || bundleID.hasPrefix($0 + ".") }
    }

    static func isSystemSettingsFrontmost() -> Bool {
        guard let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else {
            return false
        }
        return systemSettingsBundleIDs.contains { bundleID == $0 || bundleID.hasPrefix($0 + ".") }
    }

    private static let tccPromptBundleIDs = [
        "com.apple.UserNotificationCenter",
        "com.apple.TCC",
        "com.apple.AccessibilityUIServer",
        "com.apple.CoreServicesUIAgent",
        "com.apple.accessibility.universalAccessAuthWarn",
        "com.apple.accessibility.AXVisualSupportAgent",
        "com.apple.localauthentication.UIAgent"
    ]

    private static let systemSettingsBundleIDs = [
        "com.apple.systempreferences",
        "com.apple.Preferences",
        "com.apple.Settings",
        "com.apple.Setting"
    ]

    private func inputMonitoringAccessGranted() -> Bool {
        let now = Date()
        if now.timeIntervalSince(lastInputMonitoringProbeAt) < 15 {
            return cachedInputMonitoringProbe
        }
        lastInputMonitoringProbeAt = now

        cachedInputMonitoringProbe = inputMonitoringSystemGranted()
        return cachedInputMonitoringProbe
    }

    private func inputMonitoringSystemGranted() -> Bool {
        if IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted {
            return true
        }
        if CGPreflightListenEventAccess() {
            return true
        }
        return false
    }

    private func primeInputMonitoringRegistration() {
        let mask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
        let callback: CGEventTapCallBack = { _, _, event, _ in
            Unmanaged.passUnretained(event)
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                          place: .headInsertEventTap,
                                          options: .defaultTap,
                                          eventsOfInterest: CGEventMask(mask),
                                          callback: callback,
                                          userInfo: nil) else {
            return
        }
        if let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        CFMachPortInvalidate(tap)
    }

    func openPrivacySettings() {
        let specs = [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        ]
        for spec in specs {
            if let url = URL(string: spec), NSWorkspace.shared.open(url) {
                break
            }
        }
        hubRestoreFollowUp = .whenAppBecomesActive
        refreshAfterPermissionRequest()
    }

    func openMicrophoneSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
        hubRestoreFollowUp = .whenAppBecomesActive
        refreshAfterPermissionRequest()
    }

    func openInputMonitoringSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"),
           NSWorkspace.shared.open(url) {
            return
        }
        openKeyboardSettingsFallback()
    }

    func revealOpenflowInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }

    func installToUserApplicationsForPermissions() {
        let source = Bundle.main.bundleURL.standardizedFileURL
        let destination = recommendedInstallURL.standardizedFileURL
        if source == destination {
            permissionRecoveryMessage = "openflow is already running from Applications."
            revealOpenflowInFinder()
            return
        }

        do {
            let applicationsDirectory = destination.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: applicationsDirectory, withIntermediateDirectories: true)

            let stagingURL = applicationsDirectory.appendingPathComponent(".openflow-install-\(UUID().uuidString).app")
            try FileManager.default.copyItem(at: source, to: stagingURL)

            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: stagingURL, to: destination)

            permissionRecoveryMessage = "Installed openflow to Applications. Relaunching..."
            NSWorkspace.shared.openApplication(at: destination, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                DispatchQueue.main.async {
                    if let error {
                        self.permissionRecoveryMessage = "Installed openflow, but relaunch failed: \(error.localizedDescription)"
                        NSWorkspace.shared.activateFileViewerSelecting([destination])
                    } else {
                        NSApp.terminate(nil)
                    }
                }
            }
        } catch {
            permissionRecoveryMessage = "Could not install openflow: \(error.localizedDescription)"
            NSWorkspace.shared.activateFileViewerSelecting([source])
        }
    }

    private var recommendedInstallURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications", isDirectory: true)
            .appendingPathComponent("openflow.app", isDirectory: true)
    }

    func openKeyboardSettingsFallback() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Keyboard") {
            NSWorkspace.shared.open(url)
        } else {
            openInputMonitoringSettings()
        }
    }
}
