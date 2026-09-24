import AppKit
import ApplicationServices
import CoreGraphics

enum AgentAction {
    case click(elementID: Int)
    case typeText(elementID: Int, text: String)
    case pressKey(String)
    case scroll(elementID: Int?, direction: ScrollDirection)
    case openApp(String)
    case openURL(String)

    enum ScrollDirection: String {
        case up, down, left, right
    }
}

/// Executes one agent step against the previously captured AX tree.
/// Prefers AX actions (AXPress, AXFocused, AXValue) and falls back to posting
/// CGEvent input at the element's frame center.
@MainActor
final class AgentActionExecutor {
    struct Outcome {
        var ok: Bool
        var detail: String
    }

    func execute(_ action: AgentAction, in state: AgentScreenState) -> Outcome {
        switch action {
        case .click(let elementID):
            guard let element = element(elementID, in: state) else {
                return Outcome(ok: false, detail: "element \(elementID) no longer exists")
            }
            if AXUIElementPerformAction(element.element, kAXPressAction as CFString) == .success {
                return Outcome(ok: true, detail: "pressed \(element.serialized)")
            }
            let point = CGPoint(x: element.frame.midX, y: element.frame.midY)
            return postMouseClick(at: point)
                ? Outcome(ok: true, detail: "clicked \(element.serialized) via CGEvent")
                : Outcome(ok: false, detail: "click failed on \(element.serialized)")

        case .typeText(let elementID, let text):
            guard let element = element(elementID, in: state) else {
                return Outcome(ok: false, detail: "element \(elementID) no longer exists")
            }
            _ = AXUIElementSetAttributeValue(element.element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            if AXUIElementSetAttributeValue(element.element, kAXValueAttribute as CFString, text as CFString) == .success {
                return Outcome(ok: true, detail: "typed \(text.count) chars into \(element.serialized)")
            }
            return postText(text)
                ? Outcome(ok: true, detail: "typed \(text.count) chars via CGEvent")
                : Outcome(ok: false, detail: "typing failed into \(element.serialized)")

        case .pressKey(let name):
            guard let keyCode = Self.keyCodes[name.lowercased()] else {
                return Outcome(ok: false, detail: "unknown key \(name)")
            }
            return postKey(keyCode)
                ? Outcome(ok: true, detail: "pressed \(name)")
                : Outcome(ok: false, detail: "key press \(name) failed")

        case .scroll(let elementID, let direction):
            let anchor = elementID.flatMap { element($0, in: state)?.frame }
                ?? state.elements.first { $0.focused }?.frame
                ?? NSScreen.main?.frame
            guard let point = anchor.map({ CGPoint(x: $0.midX, y: $0.midY) }) else {
                return Outcome(ok: false, detail: "no scroll target")
            }
            return postScroll(at: point, direction: direction)
                ? Outcome(ok: true, detail: "scrolled \(direction.rawValue)")
                : Outcome(ok: false, detail: "scroll failed")

        case .openApp(let name):
            return openApp(named: name)

        case .openURL(let raw):
            return openURL(raw)
        }
    }

    /// Element labels that should never be actuated without a user confirm.
    private static let destructivePattern = try! NSRegularExpression(
        pattern: #"\b(delete|remove|erase|send|submit|purchase|buy|pay|checkout|sign out|log out|empty trash|format|discard|overwrite)\b"#,
        options: [.caseInsensitive])

    static func looksDestructive(_ element: AgentElement) -> Bool {
        let text = "\(element.title) \(element.description) \(element.role)"
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return destructivePattern.firstMatch(in: text, range: range) != nil
    }

    static func confirmDestructive(description: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = "openflow agent wants to \(description)"
        alert.informativeText = "This action can change or send data. Allow it?"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Stop")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func element(_ id: Int, in state: AgentScreenState) -> AgentElement? {
        state.elements.first { $0.id == id }
    }

    // MARK: - CGEvent posting

    private func postMouseClick(at point: CGPoint) -> Bool {
        let source = CGEventSource(stateID: .combinedSessionState)
        guard let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left),
              let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) else {
            return false
        }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }

    private func postText(_ text: String) -> Bool {
        let source = CGEventSource(stateID: .combinedSessionState)
        var utf16 = Array(text.utf16)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
            return false
        }
        down.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
        up.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }

    private func postKey(_ keyCode: CGKeyCode) -> Bool {
        let source = CGEventSource(stateID: .combinedSessionState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
            return false
        }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }

    private func postScroll(at point: CGPoint, direction: AgentAction.ScrollDirection) -> Bool {
        let (dx, dy): (Int32, Int32) = switch direction {
        case .up: (0, 8)
        case .down: (0, -8)
        case .left: (-8, 0)
        case .right: (8, 0)
        }
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0) else {
            return false
        }
        event.location = point
        event.post(tap: .cghidEventTap)
        return true
    }

    /// Opens a URL in the default handler. Adds https:// when the speech
    /// transcript produced a bare domain, and falls back to opening System
    /// Settings itself when an x-apple.systempreferences deep link fails.
    private func openURL(_ raw: String) -> Outcome {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let withScheme = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let url = URL(string: withScheme) else {
            return Outcome(ok: false, detail: "bad URL \(raw)")
        }
        if NSWorkspace.shared.open(url) {
            return Outcome(ok: true, detail: "opened \(withScheme)")
        }
        if trimmed.hasPrefix("x-apple.systempreferences") {
            return openApp(named: "System Settings")
        }
        return Outcome(ok: false, detail: "could not open \(withScheme)")
    }

    /// True when the string looks like a web address rather than an app name:
    /// no spaces, and a trailing label of at least two letters (a TLD), which
    /// also excludes version strings like 1.0.71.
    static func looksLikeDomain(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(" ") else { return false }
        let pattern = #"^(?:https?://|www\.)?[a-zA-Z0-9][a-zA-Z0-9.-]*\.[a-zA-Z]{2,}(?::\d+)?(?:/[^\s]*)?$"#
        return trimmed.range(of: pattern, options: .regularExpression) != nil
    }

    /// Spoken app names -> bundle identifiers, so ASR output like "settings",
    /// "imessage", or "arc" resolves to the real app. Tried in order.
    private static let appAliases: [String: [String]] = [
        "settings": ["com.apple.systempreferences"],
        "system settings": ["com.apple.systempreferences"],
        "system preferences": ["com.apple.systempreferences"],
        "preferences": ["com.apple.systempreferences"],
        "prefs": ["com.apple.systempreferences"],
        "messages": ["com.apple.MobileSMS", "com.apple.iChat"],
        "imessage": ["com.apple.MobileSMS", "com.apple.iChat"],
        "terminal": ["com.apple.Terminal"],
        "iterm": ["com.googlecode.iterm2"],
        "iterm2": ["com.googlecode.iterm2"],
        "ghostty": ["com.mitchellh.ghostty"],
        "safari": ["com.apple.Safari"],
        "chrome": ["com.google.Chrome"],
        "google chrome": ["com.google.Chrome"],
        "arc": ["company.thebrowser.Browser"],
        "dia": ["company.thebrowser.dia"],
        "firefox": ["org.mozilla.firefox"],
        "edge": ["com.microsoft.edgemac"],
        "microsoft edge": ["com.microsoft.edgemac"],
        "brave": ["com.brave.Browser"],
        "notes": ["com.apple.Notes"],
        "mail": ["com.apple.mail"],
        "calendar": ["com.apple.iCal"],
        "reminders": ["com.apple.reminders"],
        "photos": ["com.apple.Photos"],
        "music": ["com.apple.Music"],
        "finder": ["com.apple.finder"],
        "calculator": ["com.apple.calculator"],
        "preview": ["com.apple.Preview"],
        "xcode": ["com.apple.dt.Xcode"],
        "slack": ["com.tinyspeck.slackmacgap"],
        "discord": ["com.hnc.Discord"],
        "spotify": ["com.spotify.client"],
        "notion": ["notion.id"],
        "zoom": ["us.zoom.xos"],
        "code": ["com.microsoft.VSCode"],
        "vs code": ["com.microsoft.VSCode"],
        "visual studio code": ["com.microsoft.VSCode"],
        "telegram": ["ru.keepcoder.Telegram"],
        "whatsapp": ["net.whatsapp.WhatsApp"],
        "facetime": ["com.apple.FaceTime"],
        "maps": ["com.apple.Maps"],
        "podcasts": ["com.apple.podcasts"],
        "app store": ["com.apple.AppStore"],
        "textedit": ["com.apple.TextEdit"],
        "text edit": ["com.apple.TextEdit"],
        "activity monitor": ["com.apple.ActivityMonitor"],
        "pages": ["com.apple.iWork.Pages"],
        "numbers": ["com.apple.iWork.Numbers"],
        "keynote": ["com.apple.iWork.Keynote"],
        "freeform": ["com.apple.freeform"]
    ]

    /// Directories that can hold launchable .app bundles. /System/Applications
    /// is where Messages, System Settings, and most bundled apps live.
    private static var appDirectories: [URL] {
        var dirs = [
            "/Applications",
            "/Applications/Utilities",
            "/System/Applications",
            "/System/Applications/Utilities"
        ].map { URL(fileURLWithPath: $0) }
        if let home = ProcessInfo.processInfo.environment["HOME"] {
            dirs.append(URL(fileURLWithPath: home).appendingPathComponent("Applications"))
        }
        return dirs
    }

    private static func normalizedAppName(_ name: String) -> String {
        var needle = name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["the ", "open ", "launch ", "start ", "go to "] where needle.hasPrefix(prefix) {
            needle = String(needle.dropFirst(prefix.count))
        }
        if needle.hasSuffix(" app"), needle.count > 4 {
            needle = String(needle.dropLast(4))
        }
        return needle.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func openApp(named name: String) -> Outcome {
        let needle = Self.normalizedAppName(name)
        guard !needle.isEmpty else {
            return Outcome(ok: false, detail: "no app matching \(name)")
        }
        if needle == "spotlight" {
            return postCommandSpace()
                ? Outcome(ok: true, detail: "opened Spotlight")
                : Outcome(ok: false, detail: "could not open Spotlight")
        }

        let bundleIDs = Self.appAliases[needle] ?? []
        // Already frontmost: activating again is a no-op, so short-circuit
        // instead of letting the loop burn a step on it.
        if let frontmost = NSWorkspace.shared.frontmostApplication,
           appMatches(frontmost, needle: needle, bundleIDs: bundleIDs) {
            return Outcome(ok: true, detail: "\(frontmost.localizedName ?? name) already frontmost")
        }
        for bundleID in bundleIDs {
            if let running = NSWorkspace.shared.runningApplications.first(where: {
                $0.bundleIdentifier?.caseInsensitiveCompare(bundleID) == .orderedSame
            }) {
                running.activate(options: [.activateAllWindows])
                return Outcome(ok: true, detail: "activated \(running.localizedName ?? name)")
            }
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                launch(at: url)
                return Outcome(ok: true, detail: "launched \(url.deletingPathExtension().lastPathComponent)")
            }
        }
        // Running apps by name: exact first, then substring.
        let running = NSWorkspace.shared.runningApplications
        if let match = running.first(where: {
            ($0.localizedName ?? "").caseInsensitiveCompare(needle) == .orderedSame
        }) ?? running.first(where: {
            ($0.localizedName ?? "").lowercased().contains(needle) ||
            ($0.bundleIdentifier ?? "").lowercased().contains(needle)
        }) {
            match.activate(options: [.activateAllWindows])
            return Outcome(ok: true, detail: "activated \(match.localizedName ?? name)")
        }
        // Installed apps: exact name, then substring across all app dirs.
        for dir in Self.appDirectories {
            guard let urls = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { continue }
            if let match = urls.first(where: {
                $0.pathExtension == "app" &&
                $0.deletingPathExtension().lastPathComponent.caseInsensitiveCompare(needle) == .orderedSame
            }) {
                launch(at: match)
                return Outcome(ok: true, detail: "launched \(match.deletingPathExtension().lastPathComponent)")
            }
        }
        for dir in Self.appDirectories {
            guard let urls = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { continue }
            if let match = urls.first(where: {
                $0.pathExtension == "app" &&
                $0.deletingPathExtension().lastPathComponent.lowercased().contains(needle)
            }) {
                launch(at: match)
                return Outcome(ok: true, detail: "launched \(match.deletingPathExtension().lastPathComponent)")
            }
        }
        return Outcome(ok: false, detail: "no app matching \(name)")
    }

    private func appMatches(_ app: NSRunningApplication, needle: String, bundleIDs: [String]) -> Bool {
        if let name = app.localizedName, name.caseInsensitiveCompare(needle) == .orderedSame {
            return true
        }
        if let bundleID = app.bundleIdentifier {
            if bundleIDs.contains(where: { $0.caseInsensitiveCompare(bundleID) == .orderedSame }) ||
                bundleID.caseInsensitiveCompare(needle) == .orderedSame {
                return true
            }
        }
        return false
    }

    private func launch(at url: URL) {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in }
    }

    private func postCommandSpace() -> Bool {
        let source = CGEventSource(stateID: .combinedSessionState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: 49, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 49, keyDown: false) else {
            return false
        }
        down.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }

    // MARK: - Key table

    private static let keyCodes: [String: CGKeyCode] = [
        "return": 36, "enter": 36,
        "tab": 48,
        "escape": 53, "esc": 53,
        "space": 49,
        "delete": 51, "backspace": 51,
        "up": 126, "down": 125, "left": 123, "right": 124,
        "home": 115, "end": 119,
        "pageup": 116, "pagedown": 121
    ]
}
