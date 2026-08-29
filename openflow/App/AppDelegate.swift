import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    let coordinator = DictationCoordinator()
    private var menuBarController: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        UpdateLaunchConfirmation.confirmIfNeeded()
        NSApp.setActivationPolicy(.accessory)
        menuBarController = MenuBarController(coordinator: coordinator)
        OpenflowHubWindowRestorer.install()
        coordinator.start()
        UpdateService.shared.start()
        Task { @MainActor in
            await coordinator.validateCloudSessionAtLaunch()
            if needsInteractiveOnboarding {
                NSApp.activate(ignoringOtherApps: true)
                OnboardingWindowController.shared.show(coordinator: coordinator)
            } else if needsSetup {
                NSApp.activate(ignoringOtherApps: true)
                SettingsWindowController.shared.show(coordinator: coordinator, selectedTab: .permissions)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        UpdateService.shared.stop()
        coordinator.stop()
    }

    private var needsSetup: Bool {
        !coordinator.permissions.microphoneGranted
            || !coordinator.permissions.accessibilityGranted
            || needsLocalProviderKey
    }

    private var needsLocalProviderKey: Bool {
        switch coordinator.settings.providerMode {
        case .localGroq:
            return !coordinator.hasAPIKey()
        case .openflowCloud:
            return false
        case .automatic:
            return !coordinator.hasAPIKey()
        }
    }

    private var needsInteractiveOnboarding: Bool {
        if hasCompletedOnboarding { return false }
        if hasExistingUserEvidence {
            persistOnboardingCompletion()
            return false
        }
        return true
    }

    private var hasCompletedOnboarding: Bool {
        UserDefaults.standard.bool(forKey: OnboardingWindowController.completionKey)
    }

    /// Returning users (history, API key, or cloud session) skip the walkthrough even if the
    /// completion flag was missing. The flag itself is version-independent, so app updates
    /// must not reopen onboarding.
    private var hasExistingUserEvidence: Bool {
        if !coordinator.history.items.isEmpty { return true }
        if coordinator.hasAPIKey() { return true }
        if let token = try? KeychainService.shared.cloudSessionToken(), !token.isEmpty { return true }
        return false
    }

    private func persistOnboardingCompletion() {
        UserDefaults.standard.set(true, forKey: OnboardingWindowController.completionKey)
        UserDefaults.standard.synchronize()
        coordinator.noteSetupReadinessChanged()
    }
}
