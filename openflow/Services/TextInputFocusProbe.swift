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
}
