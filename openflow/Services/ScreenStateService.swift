import AppKit
import ApplicationServices

struct AgentElement {
    var id: Int
    var role: String
    var title: String
    var description: String
    var value: String
    var frame: CGRect
    var focused: Bool
    var element: AXUIElement
}

struct AgentScreenState {
    var appName: String
    var bundleID: String
    var windowTitle: String
    var elements: [AgentElement]
    var runningApps: [String]

    /// Compact text rendering sent to the decision model as part of `state`.
    func serialized(maxElements: Int = 60) -> String {
        var lines: [String] = []
        lines.append("frontmost app: \(appName) (\(bundleID))")
        if !windowTitle.isEmpty {
            lines.append("window: \(windowTitle)")
        }
        lines.append("actionable elements:")
        for element in elements.prefix(maxElements) {
            lines.append(element.serialized)
        }
        if elements.count > maxElements {
            lines.append("... \(elements.count - maxElements) more elements not listed")
        }
        return lines.joined(separator: "\n")
    }
}

extension AgentElement {
    var serialized: String {
        var parts = ["[\(id)] \(role)"]
        if !title.isEmpty { parts.append("\"\(title)\"") }
        if !description.isEmpty, description != title { parts.append("(\(description))") }
        if !value.isEmpty { parts.append("value=\"\(value)\"") }
        if focused { parts.append("focused") }
        parts.append("@(\(Int(frame.midX)),\(Int(frame.midY)))")
        return parts.joined(separator: " ")
    }
}

/// Reads the frontmost app's accessibility tree and flattens it into a list of
/// elements a decision model can act on. Accessibility permission only; no
/// Screen Recording access is needed because we never look at pixels.
@MainActor
final class ScreenStateService {
    private let maxDepth = 8
    private let maxVisited = 400
    private let maxElements = 60

    /// Roles that carry a concrete action worth offering to the model.
    private let actionableRoles: Set<String> = [
        kAXButtonRole,
        kAXCheckBoxRole,
        kAXRadioButtonRole,
        kAXPopUpButtonRole,
        kAXMenuButtonRole,
        kAXMenuItemRole,
        "AXLink",
        kAXTextFieldRole,
        kAXTextAreaRole,
        kAXSliderRole,
        "AXComboBox",
        "AXSearchField",
        "AXTab",
        "AXCell",
        "AXRow",
        "AXDisclosureTriangle",
        "AXIncrementor",
        "AXSwitch"
    ]

    func capture(frontmostPID: pid_t? = nil) -> AgentScreenState? {
        guard AXIsProcessTrusted() else { return nil }
        let app: NSRunningApplication?
        if let frontmostPID {
            app = NSRunningApplication(processIdentifier: frontmostPID)
        } else {
            app = NSWorkspace.shared.frontmostApplication
        }
        guard let app else { return nil }

        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        // Without this, every attribute read below can block the main run loop
        // for the ~6s AX default when the target app is slow or hung.
        AXUIElementSetMessagingTimeout(axApp, 0.15)
        var elements: [AgentElement] = []
        var visited = 0

        var windowTitle = ""
        var focusedWindow: AnyObject?
        if AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &focusedWindow) == .success,
           let window = focusedWindow {
            windowTitle = stringAttribute(window as! AXUIElement, kAXTitleAttribute) ?? ""
            walk(element: window as! AXUIElement, depth: 0, visited: &visited, into: &elements)
        }
        // Menu bar is a separate tree from windows and holds status items/menus.
        var menuBar: AnyObject?
        if AXUIElementCopyAttributeValue(axApp, kAXMenuBarAttribute as CFString, &menuBar) == .success,
           let bar = menuBar {
            walk(element: bar as! AXUIElement, depth: 0, visited: &visited, into: &elements)
        }

        let running = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { $0.localizedName }
            .sorted()
        return AgentScreenState(appName: app.localizedName ?? "Unknown",
                                bundleID: app.bundleIdentifier ?? "",
                                windowTitle: windowTitle,
                                elements: deduped(elements),
                                runningApps: running)
    }

    private func walk(element: AXUIElement, depth: Int, visited: inout Int, into elements: inout [AgentElement]) {
        guard depth <= maxDepth, visited < maxVisited, elements.count < maxElements else { return }
        visited += 1
        // Messaging timeouts are per-element, not inherited from axApp.
        AXUIElementSetMessagingTimeout(element, 0.1)

        let role = stringAttribute(element, kAXRoleAttribute) ?? ""
        if actionableRoles.contains(role) {
            let frame = frameOf(element)
            if !frame.isEmpty {
                elements.append(AgentElement(id: elements.count,
                                             role: role,
                                             title: truncated(stringAttribute(element, kAXTitleAttribute)),
                                             description: truncated(stringAttribute(element, kAXDescriptionAttribute)),
                                             value: truncated(valueText(of: element)),
                                             frame: frame,
                                             focused: boolAttribute(element, kAXFocusedAttribute),
                                             element: element))
            }
        }

        var children: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
              let list = children as? [AXUIElement] else { return }
        for child in list {
            walk(element: child, depth: depth + 1, visited: &visited, into: &elements)
        }
    }

    private func deduped(_ elements: [AgentElement]) -> [AgentElement] {
        var seen = Set<String>()
        var result: [AgentElement] = []
        for element in elements {
            let key = "\(element.role)|\(element.title)|\(Int(element.frame.midX))|\(Int(element.frame.midY))"
            if seen.insert(key).inserted {
                var copy = element
                copy.id = result.count
                result.append(copy)
            }
        }
        return result
    }

    private func stringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private func boolAttribute(_ element: AXUIElement, _ attribute: String) -> Bool {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return false }
        return (value as? Bool) == true
    }

    private func valueText(of element: AXUIElement) -> String? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success else { return nil }
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    private func frameOf(_ element: AXUIElement) -> CGRect {
        var positionValue: AnyObject?
        var sizeValue: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionRef = positionValue, let sizeRef = sizeValue else { return .zero }
        var point = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(positionRef as! AXValue, .cgPoint, &point)
        AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
        return CGRect(origin: point, size: size)
    }

    private func truncated(_ text: String?, limit: Int = 80) -> String {
        guard let text else { return "" }
        let cleaned = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        return cleaned.count > limit ? String(cleaned.prefix(limit)) + "…" : cleaned
    }
}
