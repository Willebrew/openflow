import AppKit
import Combine
import SwiftUI

final class OpenflowAppWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func sendEvent(_ event: NSEvent) {
        super.sendEvent(event)
        guard event.type == .leftMouseDown else { return }
        clearTextFocusIfClickingOutside(event)
    }

    private func clearTextFocusIfClickingOutside(_ event: NSEvent) {
        guard let contentView else { return }
        if Self.isTextInput(contentView.hitTest(event.locationInWindow)) { return }
        guard Self.isEditingText(firstResponder) else { return }
        endEditing(for: nil)
        makeFirstResponder(nil)
    }

    private static func isTextInput(_ view: NSView?) -> Bool {
        var current = view
        while let node = current {
            if node is NSTextField || node is NSTextView || node is NSText { return true }
            if node is FlowFieldHitHost { return true }
            if let scroll = node as? NSScrollView, scroll.documentView is NSTextView { return true }
            current = node.superview
        }
        return false
    }

    private static func isEditingText(_ responder: NSResponder?) -> Bool {
        responder is NSTextField || responder is NSTextView || responder is NSText
    }
}

final class MenuBarController: NSObject {
    private var statusItem: NSStatusItem?
    private var menu = NSMenu()
    private weak var coordinator: DictationCoordinator?
    private var cancellables: Set<AnyCancellable> = []

    init(coordinator: DictationCoordinator) {
        self.coordinator = coordinator
        super.init()
        configureMenu()
        // After an update relaunch Control Center may still be tearing down the
        // previous status item. A zero-size positioningRect makes AppKit pin the
        // menu to the trailing edge (clock / Control Center) instead of the icon.
        DispatchQueue.main.async { [weak self] in
            self?.installStatusItem()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.reinstallStatusItemIfUnlaidOut()
        }
        coordinator.permissions.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    self?.configureMenu()
                }
            }
            .store(in: &cancellables)
        coordinator.history.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    self?.configureMenu()
                }
            }
            .store(in: &cancellables)
        UpdateService.shared.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    self?.configureMenu()
                }
            }
            .store(in: &cancellables)
    }

    private func installStatusItem() {
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
        }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item
        guard let button = item.button else { return }
        button.image = .openflowStatusIcon
        button.imagePosition = .imageOnly
        button.target = self
        button.action = #selector(showStatusMenu(_:))
        button.sendAction(on: .leftMouseDown)
    }

    private func reinstallStatusItemIfUnlaidOut() {
        guard let button = statusItem?.button else {
            installStatusItem()
            return
        }
        if button.window == nil || button.bounds.width <= 0 {
            installStatusItem()
        }
    }

    private func configureMenu() {
        statusItem?.button?.image = .openflowStatusIcon
        statusItem?.button?.imagePosition = .imageOnly

        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(NSMenuItem(title: "Open Flow Hub", action: #selector(openSettings), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "History", action: #selector(openHistory), keyEquivalent: "h"))
        menu.addItem(NSMenuItem(title: "Dictionary", action: #selector(openDictionary), keyEquivalent: "d"))
        let phrasesItem = NSMenuItem(title: "Phrases", action: #selector(openPhrases), keyEquivalent: "p")
        phrasesItem.image = NSImage(systemSymbolName: "text.quote", accessibilityDescription: "Phrases")
        menu.addItem(phrasesItem)
        let copyLatestItem = NSMenuItem(title: "Copy latest dictation",
                                        action: #selector(copyLatestDictation),
                                        keyEquivalent: "")
        copyLatestItem.isEnabled = latestDictationText != nil
        menu.addItem(copyLatestItem)
        if needsPermissions {
            menu.addItem(.separator())
            menu.addItem(NSMenuItem(title: "Fix Permissions", action: #selector(fixPermissions), keyEquivalent: ""))
        }
        switch UpdateService.shared.state {
        case let .available(manifest):
            menu.addItem(.separator())
            menu.addItem(NSMenuItem(
                title: "Install openflow \(manifest.version)...",
                action: #selector(installUpdate),
                keyEquivalent: ""
            ))
        case .checking, .downloading, .preparing, .installing:
            menu.addItem(.separator())
            let item = NSMenuItem(title: UpdateService.shared.state.label,
                                  action: nil,
                                  keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        default:
            break
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit openflow", action: #selector(quit), keyEquivalent: "q"))
        menu.items.forEach { $0.target = self }
        self.menu = menu
    }

    @objc private func showStatusMenu(_ sender: Any?) {
        coordinator?.revalidateStoredCloudSession()
        configureMenu()
        guard let button = statusItem?.button else { return }
        if statusButtonCanAnchorMenu(button) {
            presentMenu(from: button)
            return
        }
        presentMenuAtMouseLocation()
        DispatchQueue.main.async { [weak self] in
            self?.installStatusItem()
        }
    }

    private func statusButtonCanAnchorMenu(_ button: NSStatusBarButton) -> Bool {
        guard let window = button.window else { return false }
        guard button.bounds.width > 0, window.frame.width > 0 else { return false }
        let screenRect = window.convertToScreen(button.convert(button.bounds, to: nil))
        guard screenRect.width > 0, screenRect.height > 0 else { return false }
        let mouse = NSEvent.mouseLocation
        let slop: CGFloat = 64
        return mouse.x >= screenRect.minX - slop
            && mouse.x <= screenRect.maxX + slop
            && mouse.y >= screenRect.minY - slop
            && mouse.y <= screenRect.maxY + slop
    }

    private func presentMenu(from button: NSStatusBarButton) {
        button.isHighlighted = true
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height), in: button)
        button.isHighlighted = false
    }

    private func presentMenuAtMouseLocation() {
        statusItem?.button?.isHighlighted = true
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        statusItem?.button?.isHighlighted = false
    }

    private var latestDictationText: String? {
        guard let text = coordinator?.history.items.first?.finalText
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            return nil
        }
        return text
    }

    private var needsPermissions: Bool {
        guard let coordinator else { return true }
        return !coordinator.permissions.microphoneGranted
            || !coordinator.permissions.accessibilityGranted
    }

    @objc private func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        guard let coordinator else { return }
        SettingsWindowController.shared.show(coordinator: coordinator)
    }

    @objc private func openHistory() {
        NSApp.activate(ignoringOtherApps: true)
        guard let coordinator else { return }
        SettingsWindowController.shared.show(coordinator: coordinator, selectedTab: .history)
    }

    @objc private func openDictionary() {
        NSApp.activate(ignoringOtherApps: true)
        guard let coordinator else { return }
        SettingsWindowController.shared.show(coordinator: coordinator, selectedTab: .dictionary)
    }

    @objc private func openPhrases() {
        NSApp.activate(ignoringOtherApps: true)
        guard let coordinator else { return }
        SettingsWindowController.shared.show(coordinator: coordinator, selectedTab: .phrases)
    }

    @objc private func copyLatestDictation() {
        guard let text = latestDictationText else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc private func fixPermissions() {
        NSApp.activate(ignoringOtherApps: true)
        guard let coordinator else { return }
        SettingsWindowController.shared.show(coordinator: coordinator, selectedTab: .permissions)
    }

    @objc private func installUpdate() {
        UpdateService.shared.installAvailableUpdate()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

private extension NSImage {
    static var openflowStatusIcon: NSImage {
        let image = NSImage(named: "OpenflowLogoSmall") ?? NSImage(size: NSSize(width: 18, height: 18))
        image.size = NSSize(width: 18, height: 10)
        image.isTemplate = true
        image.accessibilityDescription = "openflow"
        return image
    }
}

enum SettingsTab: Hashable {
    case general
    case permissions
    case dictionary
    case phrases
    case style
    case history
    case apps
    case settings
}

enum OpenflowHubWindowRestorer {
    private static var observers: [NSObjectProtocol] = []

    static func install() {
        guard observers.isEmpty else { return }
        let active = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                                            object: nil,
                                                            queue: .main) { _ in
            restoreIfSafe()
        }
        let restore = NotificationCenter.default.addObserver(forName: .openflowRestoreHubWindows,
                                                             object: nil,
                                                             queue: .main) { _ in
            restoreIfSafe()
        }
        observers = [active, restore]
    }

    static func restoreIfSafe() {
        guard !PermissionsService.isPermissionPromptLikelyShowing else { return }
        guard !PermissionsService.isSystemPermissionUIFrontmost() else { return }
        let onboardingVisible = OnboardingWindowController.shared.hasVisibleWindow
        let settingsVisible = SettingsWindowController.shared.hasVisibleWindow
        guard onboardingVisible || settingsVisible else { return }
        DispatchQueue.main.async {
            guard !PermissionsService.isPermissionPromptLikelyShowing else { return }
            guard !PermissionsService.isSystemPermissionUIFrontmost() else { return }
            NSApp.activate(ignoringOtherApps: true)
            OnboardingWindowController.shared.bringToFrontIfVisible()
            SettingsWindowController.shared.bringToFrontIfVisible()
        }
    }
}

final class SettingsWindowController {
    static let shared = SettingsWindowController()
    private static let hubContentSize = NSSize(width: FlowUI.hubWindowWidth, height: FlowUI.hubWindowHeight)
    private var window: NSWindow?

    var hasVisibleWindow: Bool {
        window?.isVisible == true
    }

    func bringToFrontIfVisible() {
        guard let window, window.isVisible else { return }
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    func show(coordinator: DictationCoordinator, selectedTab: SettingsTab = .general) {
        let view = SettingsView(initialTab: selectedTab)
        let hosting = NSHostingController(rootView: view.environmentObject(coordinator))
        configureHostingView(hosting.view)
        if window == nil {
            let newWindow = OpenflowAppWindow(contentViewController: hosting)
            newWindow.title = "openflow"
            configureWindow(newWindow)
            newWindow.center()
            window = newWindow
        } else {
            window?.contentViewController = hosting
            if let window {
                configureWindow(window)
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }

    private func configureWindow(_ window: NSWindow) {
        window.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isOpaque = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = .clear
        window.hasShadow = true
        window.titlebarSeparatorStyle = .none
        window.contentMinSize = Self.hubContentSize
        window.contentMaxSize = Self.hubContentSize
        window.setContentSize(Self.hubContentSize)
        if #available(macOS 11.0, *) {
            window.toolbarStyle = .unifiedCompact
        }
    }

    private func configureHostingView(_ view: NSView) {
        view.wantsLayer = true
        view.layer?.isOpaque = false
        view.layer?.backgroundColor = NSColor.clear.cgColor
    }
}

final class OnboardingWindowController {
    static let shared = OnboardingWindowController()
    static let completionKey = "hasCompletedInteractiveOnboarding"
    private var window: NSWindow?

    var hasVisibleWindow: Bool {
        window?.isVisible == true
    }

    func bringToFrontIfVisible() {
        guard let window, window.isVisible else { return }
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    func show(coordinator: DictationCoordinator) {
        let view = OnboardingFlowView {
            UserDefaults.standard.set(true, forKey: Self.completionKey)
            UserDefaults.standard.synchronize()
            coordinator.noteSetupReadinessChanged()
            self.window?.close()
            self.window = nil
            NSApp.activate(ignoringOtherApps: true)
            SettingsWindowController.shared.show(coordinator: coordinator)
        }
        let hosting = NSHostingController(rootView: view.environmentObject(coordinator))
        configureHostingView(hosting.view)
        if window == nil {
            let newWindow = OpenflowAppWindow(contentViewController: hosting)
            newWindow.title = "Welcome to openflow"
            newWindow.setContentSize(NSSize(width: 920, height: 640))
            configureWindow(newWindow)
            newWindow.center()
            window = newWindow
        } else {
            window?.contentViewController = hosting
            if let window {
                configureWindow(window)
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }

    private func configureWindow(_ window: NSWindow) {
        window.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isOpaque = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = .clear
        window.hasShadow = true
        window.titlebarSeparatorStyle = .none
        if #available(macOS 11.0, *) {
            window.toolbarStyle = .unifiedCompact
        }
    }

    private func configureHostingView(_ view: NSView) {
        view.wantsLayer = true
        view.layer?.isOpaque = false
        view.layer?.backgroundColor = NSColor.clear.cgColor
    }
}
