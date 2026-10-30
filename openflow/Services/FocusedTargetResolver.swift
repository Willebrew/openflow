import AppKit
import ApplicationServices

/// Resolves which process actually holds keyboard focus when dictation
/// starts and when text is inserted.
///
/// Banner replies (Messages, Slack, ...) run inside Notification Center,
/// which is never frontmost. `NSWorkspace.shared.frontmostApplication`
/// therefore names the wrong target, and `activate()`ing that app at insert
/// time drops key focus and dismisses the reply panel. Reading the
/// system-wide focused element and its pid finds the real owner.
final class FocusedTargetResolver {
    struct ResolvedTarget {
        /// The process that should receive context capture and insertion.
        var processIdentifier: pid_t?
        /// `NSRunningApplication` for that process when one exists.
        var runningApplication: NSRunningApplication?
        /// The system-wide focused element, retained when it redirected the
        /// target; preferred over re-derived app-level elements.
        var focusedElement: AXUIElement?
        /// True when the target is a non-activating panel: never activate
        /// it, never send `AXFrontmost`, never click its chrome.
        var isNonActivatingPanel: Bool
        /// True when an automatic Return must never be posted to this target.
        var suppressAutoEnter: Bool
    }

    /// Read the system-wide focused element and apply `FocusedTargetPolicy`.
    /// Safe off the main thread: all AX reads carry short messaging timeouts
    /// so a slow owner cannot stall the hotkey path.
    static func resolve(frontmostApp: NSRunningApplication?) -> ResolvedTarget {
        let frontmostPID = frontmostApp?.processIdentifier
        let inactive = ResolvedTarget(processIdentifier: frontmostPID,
                                      runningApplication: frontmostApp,
                                      focusedElement: nil,
                                      isNonActivatingPanel: false,
                                      suppressAutoEnter: false)
        guard AXIsProcessTrusted(),
              let (element, elementPID) = systemFocusedElement() else {
            return inactive
        }
        let elementApp = NSRunningApplication(processIdentifier: elementPID)
        let decision = FocusedTargetPolicy.decide(
            frontmostPID: frontmostPID,
            ownPID: ProcessInfo.processInfo.processIdentifier,
            focusedElementPID: elementPID,
            focusedElementBundleID: elementApp?.bundleIdentifier,
            focusedElementIsEditable: elementSupportsTextInsertion(element)
        )
        guard decision.isNonActivatingPanel else { return inactive }
        return ResolvedTarget(processIdentifier: decision.retargetedProcessIdentifier,
                              runningApplication: elementApp,
                              focusedElement: element,
                              isNonActivatingPanel: true,
                              suppressAutoEnter: decision.suppressAutoEnter)
    }

    /// The element the keyboard is actually feeding right now, plus its
    /// owning pid. `nil` when there is no focused element or the owner
    /// cannot be identified.
    static func systemFocusedElement() -> (element: AXUIElement, pid: pid_t)? {
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, 0.15)
        var focused: AnyObject?
        guard AXUIElementCopyAttributeValue(systemWide,
                                           kAXFocusedUIElementAttribute as CFString,
                                           &focused) == .success,
              let focused,
              CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        let element = focused as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.08)
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success else { return nil }
        return (element, pid)
    }

    /// The system focused element only when `pid` still owns it; used to
    /// confirm a captured panel target has not lost focus to another app.
    static func systemFocusedElement(forProcess pid: pid_t) -> AXUIElement? {
        guard let (element, elementPID) = systemFocusedElement(), elementPID == pid else { return nil }
        return element
    }

    /// Lightweight editable check used only as policy input. Mirrors the
    /// role heuristics in TextInputFocusProbe.
    private static func elementSupportsTextInsertion(_ element: AXUIElement) -> Bool {
        var selectedRange: AnyObject?
        if AXUIElementCopyAttributeValue(element,
                                        kAXSelectedTextRangeAttribute as CFString,
                                        &selectedRange) == .success,
           selectedRange != nil {
            return true
        }
        var editable: AnyObject?
        if AXUIElementCopyAttributeValue(element, "AXEditable" as CFString, &editable) == .success,
           (editable as? Bool) == true {
            return true
        }
        var role: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role) == .success,
              let roleString = role as? String else { return false }
        return [
            kAXTextFieldRole as String,
            kAXTextAreaRole as String,
            "AXComboBox",
            "AXSearchField"
        ].contains(roleString)
    }
}
