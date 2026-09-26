import AppKit
import ApplicationServices

/// Detects a focused text input or IME composition so typed hotkeys can pass through.
/// A true result must only affect keyDown swallow / typed-shortcut start -- never Fn or Option hold.
enum TextInputFocusProbe {
    private static let cacheLock = NSLock()
    private static var cachedAt: TimeInterval = 0
    private static var cachedValue = false
    private static let cacheTTL: TimeInterval = 0.05

    static func isTextInputActive() -> Bool {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        let now = ProcessInfo.processInfo.systemUptime
        if now - cachedAt < cacheTTL {
            return cachedValue
        }
        let value = appKitTextInputActive() || accessibilityTextInputActive()
        cachedAt = now
        cachedValue = value
        return value
    }

    private static func appKitTextInputActive() -> Bool {
        guard NSApp.isActive, let responder = NSApp.keyWindow?.firstResponder else {
            return false
        }
        if let client = responder as? any NSTextInputClient, client.hasMarkedText() {
            return true
        }
        if responder is NSTextView || responder is NSTextField || responder is NSText {
            return true
        }
        return false
    }

    private static func accessibilityTextInputActive() -> Bool {
        guard AXIsProcessTrusted() else { return false }
        guard let app = NSWorkspace.shared.frontmostApplication else { return false }
        if app.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            return false
        }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(axApp, 0.08)
        var focused: AnyObject?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focusedElement = focused,
              CFGetTypeID(focusedElement) == AXUIElementGetTypeID() else {
            return false
        }
        // Messaging timeouts are per-element; the attribute reads below would
        // otherwise stall ~6s each when the frontmost app is slow to answer.
        AXUIElementSetMessagingTimeout(focusedElement as! AXUIElement, 0.08)
        return isTextInputElement(focusedElement as! AXUIElement)
    }

    private static func isTextInputElement(_ element: AXUIElement) -> Bool {
        var role: AnyObject?
        if AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role) == .success,
           let roleString = role as? String {
            let textRoles: Set<String> = [
                kAXTextFieldRole as String,
                kAXTextAreaRole as String,
                kAXComboBoxRole as String,
                "AXSearchField",
                "AXSecureTextField"
            ]
            if textRoles.contains(roleString) { return true }
        }
        var subrole: AnyObject?
        if AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole) == .success,
           let subroleString = subrole as? String,
           subroleString == (kAXSearchFieldSubrole as String) {
            return true
        }
        var editable: AnyObject?
        if AXUIElementCopyAttributeValue(element, "AXEditable" as CFString, &editable) == .success,
           let flag = editable as? Bool, flag {
            return true
        }
        if let clientMarked = markedTextAttribute(in: element), !clientMarked.isEmpty {
            return true
        }
        var selectedRange: AnyObject?
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &selectedRange) == .success,
           selectedRange != nil {
            return true
        }
        return false
    }

    private static func markedTextAttribute(in element: AXUIElement) -> String? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, "AXMarkedText" as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }

    /// Stricter variant for routing a spoken command vs typed text. The loose
    /// probe treats bare AXSelectedTextRange / AXEditable as sufficient because
    /// a false positive only costs a swallowed hotkey; for routing, Chromium
    /// and Electron apps expose those attributes on non-text elements, which
    /// would mark every focused window as a text box.
    static func isTextInputStrict() -> Bool {
        strictDecision().isText
    }

    /// Strict routing verdict plus a one-line dump of every signal that fed
    /// it, so field logs show exactly why a focus was (not) treated as text.
    static func strictDecision() -> (isText: Bool, report: String) {
        var signals: [String] = []
        if appKitTextInputActive() {
            return (true, "strict=text appKitField=1")
        }
        signals.append("appKit=0")
        guard AXIsProcessTrusted() else {
            signals.append("axTrusted=0")
            return (false, "strict=no-text " + signals.joined(separator: " "))
        }
        signals.append("axTrusted=1")
        guard let app = NSWorkspace.shared.frontmostApplication else {
            signals.append("frontmost=none")
            return (false, "strict=no-text " + signals.joined(separator: " "))
        }
        signals.append("app=\(app.localizedName ?? "?")")
        guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            signals.append("selfApp=1")
            return (false, "strict=no-text " + signals.joined(separator: " "))
        }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(axApp, 0.08)
        var focused: AnyObject?
        let focusResult = AXUIElementCopyAttributeValue(axApp, kAXFocusedUIElementAttribute as CFString, &focused)
        guard focusResult == .success,
              let focusedElement = focused,
              CFGetTypeID(focusedElement) == AXUIElementGetTypeID() else {
            signals.append("focusedElement=\(focusResult.rawValue)")
            return (false, "strict=no-text " + signals.joined(separator: " "))
        }
        AXUIElementSetMessagingTimeout(focusedElement as! AXUIElement, 0.08)
        return strictElementDecision(focusedElement as! AXUIElement, signals: signals)
    }

    private static func strictElementDecision(_ element: AXUIElement,
                                              signals: [String]) -> (isText: Bool, report: String) {
        var signals = signals
        var role: AnyObject?
        let roleString = (AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role) == .success
            ? role as? String
            : nil) ?? ""
        signals.append("role=\(roleString.isEmpty ? "?" : roleString)")
        let textRoles: Set<String> = [
            kAXTextFieldRole as String,
            kAXTextAreaRole as String,
            kAXComboBoxRole as String,
            "AXSearchField",
            "AXSecureTextField",
            "AXTextView"
        ]
        if textRoles.contains(roleString) {
            return (true, "strict=text " + signals.joined(separator: " "))
        }
        var subrole: AnyObject?
        let subroleString = (AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole) == .success
            ? subrole as? String
            : nil) ?? ""
        signals.append("subrole=\(subroleString.isEmpty ? "-" : subroleString)")
        if subroleString == (kAXSearchFieldSubrole as String) {
            return (true, "strict=text " + signals.joined(separator: " "))
        }
        let marked = markedTextAttribute(in: element)
        signals.append("marked=\((marked?.isEmpty == false) ? 1 : 0)")
        if let marked, !marked.isEmpty {
            return (true, "strict=text " + signals.joined(separator: " "))
        }
        var selectedRange: AnyObject?
        let hasSelectedRange = AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &selectedRange) == .success
            && selectedRange != nil
        signals.append("selRange=\(hasSelectedRange ? 1 : 0)")
        var editable: AnyObject?
        let editableFlag = AXUIElementCopyAttributeValue(element, "AXEditable" as CFString, &editable) == .success
            && (editable as? Bool) == true
        signals.append("editable=\(editableFlag ? 1 : 0)")
        // AXEditable only counts on roles web content reports it for;
        // standalone AXSelectedTextRange is intentionally not a signal here.
        let editableCapableRoles: Set<String> = [
            "AXWebArea", "AXGroup", "AXScrollArea", "AXUnknown", "AXTextField", "AXTextArea"
        ]
        if editableFlag, editableCapableRoles.contains(roleString) {
            return (true, "strict=text " + signals.joined(separator: " "))
        }
        return (false, "strict=no-text " + signals.joined(separator: " "))
    }
}
