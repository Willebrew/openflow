import AppKit
import ApplicationServices
import CoreGraphics

enum AgentAction {
    case click(elementID: Int)
    case typeText(elementID: Int, text: String)
    case pressKey(String)
    case scroll(elementID: Int?, direction: ScrollDirection)
    case openApp(String)

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
            _ = AXUIElementSetAttribute(element.element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            if AXUIElementSetAttribute(element.element, kAXValueAttribute as CFString, text as CFString) == .success {
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

    private func openApp(named name: String) -> Outcome {
        let needle = name.lowercased()
        if let running = NSWorkspace.shared.runningApplications.first(where: {
            ($0.localizedName ?? "").lowercased() == needle ||
            ($0.bundleIdentifier ?? "").lowercased().contains(needle)
        }) {
            running.activate(from: nil, options: [.activateAllWindows])
            return Outcome(ok: true, detail: "activated \(running.localizedName ?? name)")
        }
        let applications = URL(fileURLWithPath: "/Applications")
        if let urls = try? FileManager.default.contentsOfDirectory(at: applications, includingPropertiesForKeys: nil),
           let match = urls.first(where: { $0.deletingPathExtension().lastPathComponent.lowercased() == needle }) {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            NSWorkspace.shared.openApplication(at: match, configuration: config)
            return Outcome(ok: true, detail: "launched \(match.deletingPathExtension().lastPathComponent)")
        }
        return Outcome(ok: false, detail: "no app matching \(name)")
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
