import AppKit
import ApplicationServices

/// How confident the strict focus probe is about the frontmost text context.
/// Only `.noTextInput` may route a dictation to the voice agent; anything
/// uncertain falls back to normal dictation + insertion.
enum FocusProbeVerdict: String {
    case textInput
    case noTextInput
    case inconclusive
}

/// Strict probe outcome plus the signals behind it and how long the AX walk
/// took, so field logs can reconstruct every routing decision.
struct FocusProbeResult {
    var verdict: FocusProbeVerdict
    var report: String
    var elapsed: TimeInterval
}

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

    /// AppKit first-responder check. Reads NSApp state, so it must only run on
    /// the main thread; it is pure property access and never blocks.
    static func appKitTextInputActive() -> Bool {
        guard let app = NSApp, app.isActive,
              let responder = app.keyWindow?.firstResponder else {
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
        // Chromium/Electron only populate their web AX tree once an assistive
        // client opts in; without these the focused-element read comes back
        // empty and a focused field looks like no text input.
        AXUIElementSetAttributeValue(axApp, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(axApp, "AXManualAccessibility" as CFString, kCFBooleanTrue)
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

    // MARK: - Strict probe (voice-agent routing)

    /// Stricter probe for routing a spoken command vs typed text. The loose
    /// probe treats bare AXSelectedTextRange / AXEditable as sufficient because
    /// a false positive only costs a swallowed hotkey; for routing, Chromium
    /// and Electron apps expose those attributes on non-text elements, which
    /// would mark every focused window as a text box.
    ///
    /// Async variant: the AppKit check runs on the caller (AppKit is
    /// main-thread-only and non-blocking), then the AX half runs off the
    /// caller's executor with a bounded wait. A slow, hung, or uncooperative
    /// frontmost app produces `.inconclusive` after `timeout` instead of
    /// stalling dictation. `probe` is injectable so tests can exercise the
    /// timeout without an AX environment.
    static func strictDecisionAsync(
        timeout: TimeInterval = 0.6,
        probe: (@Sendable () -> FocusProbeResult)? = nil
    ) async -> FocusProbeResult {
        if appKitTextInputActive() {
            return FocusProbeResult(verdict: .textInput,
                                    report: "strict=text appKitField=1",
                                    elapsed: 0)
        }
        return await axStrictDecisionAsync(timeout: timeout, probe: probe)
    }

    /// Runs the AX-only half of the strict probe off the main thread with a
    /// bounded wait. The timeout is real: the probe races a sleeper task and
    /// the loser is abandoned, so a wedged frontmost app can never stretch the
    /// wait past `timeout`. The abandoned probe keeps its own per-call AX
    /// messaging timeouts (~0.08s each) and finishes in the background.
    static func axStrictDecisionAsync(
        timeout: TimeInterval,
        probe: (@Sendable () -> FocusProbeResult)? = nil
    ) async -> FocusProbeResult {
        let run = probe ?? { axStrictDecision(signals: ["appKit=skipped"], started: Date()) }
        let timeoutResult = FocusProbeResult(
            verdict: .inconclusive,
            report: "probe-timeout>\(Int(timeout * 1000))ms",
            elapsed: timeout)
        return await withCheckedContinuation { continuation in
            let latch = ResumeLatch()
            Task.detached(priority: .userInitiated) {
                latch.resume(continuation, with: run())
            }
            Task.detached(priority: .utility) {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                latch.resume(continuation, with: timeoutResult)
            }
        }
    }

    /// First resume wins; the loser's continuation resume is dropped.
    private final class ResumeLatch: @unchecked Sendable {
        private var resumed = false
        private let lock = NSLock()

        func resume(_ continuation: CheckedContinuation<FocusProbeResult, Never>,
                    with result: FocusProbeResult) {
            lock.lock()
            defer { lock.unlock() }
            guard !resumed else { return }
            resumed = true
            continuation.resume(returning: result)
        }
    }

    /// AX half of the strict decision. Safe to call off-main: NSWorkspace
    /// reads and AX calls are not main-bound. Each attribute read carries a
    /// short messaging timeout so a slow app degrades to `.inconclusive`
    /// quickly rather than blocking.
    static func axStrictDecision(signals: [String], started: Date) -> FocusProbeResult {
        var signals = signals
        func finish(_ verdict: FocusProbeVerdict, _ prefix: String) -> FocusProbeResult {
            FocusProbeResult(verdict: verdict,
                             report: prefix + signals.joined(separator: " "),
                             elapsed: Date().timeIntervalSince(started))
        }
        guard AXIsProcessTrusted() else {
            signals.append("axTrusted=0")
            return finish(.inconclusive, "strict=inconclusive ")
        }
        signals.append("axTrusted=1")
        guard let app = NSWorkspace.shared.frontmostApplication else {
            signals.append("frontmost=none")
            return finish(.inconclusive, "strict=inconclusive ")
        }
        signals.append("app=\(app.localizedName ?? "?")")
        guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            signals.append("selfApp=1")
            return finish(.inconclusive, "strict=inconclusive ")
        }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(axApp, 0.08)
        // Chromium/Electron only populate their web AX tree once an assistive
        // client opts in; these are set at dictation start, so by the time the
        // end-of-dictation probe runs the tree has had seconds to appear.
        AXUIElementSetAttributeValue(axApp, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(axApp, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        var focused: AnyObject?
        let focusResult = AXUIElementCopyAttributeValue(axApp, kAXFocusedUIElementAttribute as CFString, &focused)
        // No retry loop: apps that refuse the focused-element read (error
        // -25211 covered Messages, Slack, Ghostty, and Dia while their fields
        // were focused) are inconclusive -- never "no text field".
        guard focusResult == .success,
              let focusedElement = focused,
              CFGetTypeID(focusedElement) == AXUIElementGetTypeID() else {
            signals.append("focusedElement=err\(focusResult.rawValue)")
            return finish(.inconclusive, "strict=inconclusive ")
        }
        AXUIElementSetMessagingTimeout(focusedElement as! AXUIElement, 0.08)
        return strictElementDecision(focusedElement as! AXUIElement,
                                     signals: signals,
                                     started: started,
                                     finish: finish)
    }

    private static func strictElementDecision(
        _ element: AXUIElement,
        signals: [String],
        started: Date,
        finish: (FocusProbeVerdict, String) -> FocusProbeResult
    ) -> FocusProbeResult {
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
            return finish(.textInput, "strict=text ")
        }
        var subrole: AnyObject?
        let subroleString = (AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole) == .success
            ? subrole as? String
            : nil) ?? ""
        signals.append("subrole=\(subroleString.isEmpty ? "-" : subroleString)")
        if subroleString == (kAXSearchFieldSubrole as String) {
            return finish(.textInput, "strict=text ")
        }
        let marked = markedTextAttribute(in: element)
        signals.append("marked=\((marked?.isEmpty == false) ? 1 : 0)")
        if let marked, !marked.isEmpty {
            return finish(.textInput, "strict=text ")
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
            return finish(.textInput, "strict=text ")
        }
        // Confident "no text field" only for roles that can never hold typed
        // text, plus non-editable container/web roles once their focused
        // element read fully succeeded. Generic or unreadable roles stay
        // inconclusive so dictation is never stolen by a vague AX shape.
        let nonTextRoles: Set<String> = [
            kAXButtonRole as String,
            kAXWindowRole as String,
            kAXMenuBarRole as String,
            kAXMenuRole as String,
            kAXMenuItemRole as String,
            kAXRadioButtonRole as String,
            kAXCheckBoxRole as String,
            kAXPopUpButtonRole as String,
            kAXMenuButtonRole as String,
            kAXStaticTextRole as String,
            "AXSheet",
            "AXToolbar",
            "AXMenuBarItem",
            "AXImage",
            "AXLink",
            "AXScrollBar",
            "AXTabGroup",
            "AXTab",
            "AXSplitter",
            "AXSplitGroup",
            "AXProgressIndicator",
            "AXValueIndicator",
            "AXSlider",
            "AXIncrementor",
            "AXColorWell",
            "AXApplication",
            "AXSystemWide",
            "AXDock",
            "AXDisclosureTriangle",
            "AXLayoutArea",
            "AXHeading",
            "AXWebArea",
            "AXScrollArea",
            "AXGroup"
        ]
        if nonTextRoles.contains(roleString) {
            return finish(.noTextInput, "strict=no-text ")
        }
        return finish(.inconclusive, "strict=inconclusive ")
    }
}
