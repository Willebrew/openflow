import AppKit

final class TextInsertionService {
    private struct CursorTextContext {
        var prefix: String
        var suffix: String
        var hasSelection: Bool

        var before: Character? { prefix.last }
        var after: Character? { suffix.first }
    }

    private enum TerminalTypingVerification {
        case verified
        case unchanged
        case changedButUnverified
        case unreadable
    }

    func insert(_ text: String,
                pressEnter: Bool,
                settings: UserSettings,
                category: AppCategory = .generic,
                targetProcessIdentifier: pid_t? = nil) async -> InsertionResult {
        let target = targetDescription(processIdentifier: targetProcessIdentifier)
        var attempts = 0
        var failures: [String] = []
        await restoreTargetApplication(processIdentifier: targetProcessIdentifier)
        if let targetProcessIdentifier,
           NSWorkspace.shared.frontmostApplication?.processIdentifier != targetProcessIdentifier {
            failures.append("target focus not restored on first attempt")
            try? await Task.sleep(nanoseconds: 120_000_000)
            await restoreTargetApplication(processIdentifier: targetProcessIdentifier)
        }
        releaseShortcutModifiers()
        let browserTarget = isBrowserApp()
        var focused: AXUIElement?
        if !browserTarget {
            focused = focusedElement()
        }
        if !browserTarget, focused == nil {
            try? await Task.sleep(nanoseconds: 90_000_000)
            focused = focusedElement()
        }
        let prepared = browserTarget ? text.trimmingCharacters(in: .newlines) : spacingAdjusted(text, focused: focused)
        let emptyPrepared = prepared.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if emptyPrepared, !pressEnter {
            return .failed(reason: "Final text was empty after spacing adjustment.",
                           attemptCount: attempts,
                           targetApp: target.name,
                           targetBundleID: target.bundleID)
        }
        let submitConfirmationReason = CommandSubmissionPolicy.confirmationReason(category: category,
                                                                                   pressEnter: pressEnter,
                                                                                   text: prepared)
        var submitConfirmationShown = false
        if let submitConfirmationReason {
            let confirmed = await confirmTerminalAutoSubmit(
                text: prepared,
                target: target,
                reason: submitConfirmationReason,
                category: category
            )
            guard confirmed else {
                return .failed(reason: "Terminal insertion canceled by user.",
                               attemptCount: attempts,
                               targetApp: target.name,
                               targetBundleID: target.bundleID)
            }
            submitConfirmationShown = true
        }
        // Fail closed: Return is pressed only when no confirmation was owed or the user granted it.
        let mayPressEnter = pressEnter && (submitConfirmationReason == nil || submitConfirmationShown)
        if category == .terminal {
            await prepareTargetForKeyboardInput(processIdentifier: targetProcessIdentifier, clickWindowChrome: false)
            if submitConfirmationShown {
                guard await waitForTerminalFocus(processIdentifier: targetProcessIdentifier) else {
                    return .failed(
                        reason: "terminal focus not restored after confirmation",
                        attemptCount: attempts,
                        targetApp: target.name,
                        targetBundleID: target.bundleID
                    )
                }
            }
            if emptyPrepared {
                guard mayPressEnter else {
                    return .failed(reason: "Unconfirmed auto-submit blocked.",
                                   attemptCount: attempts,
                                   targetApp: target.name,
                                   targetBundleID: target.bundleID)
                }
                sendEnter()
                return result(method: .nativeKeyEvents, verified: false, attempts: 1, target: target)
            }
            let readableBefore = terminalTextSnapshot(processIdentifier: targetProcessIdentifier, focused: focused)
            try? await Task.sleep(nanoseconds: 55_000_000)
            attempts += 1
            switch await typeTextAsNativeKeyEvents(prepared) {
            case .posted:
                try? await Task.sleep(nanoseconds: 90_000_000)
                switch terminalTypingVerification(prepared,
                                                  previousText: readableBefore,
                                                  processIdentifier: targetProcessIdentifier,
                                                  focused: focused) {
                case .verified:
                    if mayPressEnter {
                        await submitTerminalEnterIfConfirmed(
                            text: prepared,
                            target: target,
                            targetProcessIdentifier: targetProcessIdentifier,
                            useSystemEvents: false
                        )
                    }
                    return result(method: .nativeKeyEvents, verified: true, attempts: attempts, target: target)
                case .unchanged:
                    return .failed(
                        reason: "native key events posted but terminal text was unchanged; not retyping to avoid duplicate entry",
                        attemptCount: attempts,
                        targetApp: target.name,
                        targetBundleID: target.bundleID
                    )
                case .unreadable, .changedButUnverified:
                    if targetIsFrontmost(targetProcessIdentifier) {
                        if mayPressEnter {
                            await submitTerminalEnterIfConfirmed(
                                text: prepared,
                                target: target,
                                targetProcessIdentifier: targetProcessIdentifier,
                                useSystemEvents: false
                            )
                        }
                        return result(method: .nativeKeyEvents, verified: false, attempts: attempts, target: target)
                    }
                    return .failed(
                        reason: "native key events posted but target was no longer frontmost; not retyping",
                        attemptCount: attempts,
                        targetApp: target.name,
                        targetBundleID: target.bundleID
                    )
                }
            case .failedAfterPosting:
                return .failed(
                    reason: "native key events partially posted; not retyping to avoid duplicate entry",
                    attemptCount: attempts,
                    targetApp: target.name,
                    targetBundleID: target.bundleID
                )
            case .failedBeforePosting:
                failures.append("native key events failed")
            }

            await prepareTargetForKeyboardInput(processIdentifier: targetProcessIdentifier, clickWindowChrome: true)
            attempts += 1
            if typeTextWithSystemEvents(prepared, target: target) {
                if mayPressEnter {
                    await submitTerminalEnterIfConfirmed(
                        text: prepared,
                        target: target,
                        targetProcessIdentifier: targetProcessIdentifier,
                        useSystemEvents: true
                    )
                }
                return result(method: .systemEvents, verified: false, attempts: attempts, target: target)
            }
            failures.append("System Events keystroke failed")

            return .failed(reason: failures.joined(separator: "; "),
                           attemptCount: attempts,
                           targetApp: target.name,
                           targetBundleID: target.bundleID)
        }
        if emptyPrepared {
            guard mayPressEnter else {
                return .failed(reason: "Unconfirmed auto-submit blocked.",
                               attemptCount: attempts,
                               targetApp: target.name,
                               targetBundleID: target.bundleID)
            }
            sendEnter()
            return result(method: .nativeKeyEvents, verified: false, attempts: 1, target: target)
        }
        if shouldPreferKeyboardInsertion(category: category, target: target) {
            await prepareTargetForKeyboardInput(processIdentifier: targetProcessIdentifier, clickWindowChrome: false)
            attempts += 1
            switch await typeTextAsNativeKeyEvents(prepared) {
            case .posted:
                if mayPressEnter { sendEnter() }
                return result(method: .nativeKeyEvents, verified: false, attempts: attempts, target: target)
            case .failedAfterPosting:
                return .failed(
                    reason: "native key events partially posted; not retyping to avoid duplicate entry",
                    attemptCount: attempts,
                    targetApp: target.name,
                    targetBundleID: target.bundleID
                )
            case .failedBeforePosting:
                failures.append("native key events failed")
            }
            attempts += 1
            if await typeTextWithKeyboardEvents(prepared) {
                if mayPressEnter { sendEnter() }
                return result(method: .unicodeKeyEvents, verified: false, attempts: attempts, target: target)
            }
            failures.append("unicode CGEvents failed")
            attempts += 1
            if typeTextWithSystemEvents(prepared, target: target) {
                if mayPressEnter { sendEnterWithSystemEvents(target: target) }
                return result(method: .systemEvents, verified: false, attempts: attempts, target: target)
            }
            failures.append("System Events keystroke failed")
        }
        if category == .projectManagement || isLinearTarget(target) {
            await prepareTargetForKeyboardInput(processIdentifier: targetProcessIdentifier, clickWindowChrome: true)
            attempts += 1
            switch await typeTextAsNativeKeyEvents(prepared) {
            case .posted:
                if mayPressEnter { sendEnter() }
                return result(method: .nativeKeyEvents, verified: false, attempts: attempts, target: target)
            case .failedAfterPosting:
                return .failed(
                    reason: "native key events partially posted; not retyping to avoid duplicate entry",
                    attemptCount: attempts,
                    targetApp: target.name,
                    targetBundleID: target.bundleID
                )
            case .failedBeforePosting:
                failures.append("project native key events failed")
            }
            attempts += 1
            if typeTextWithSystemEvents(prepared, target: target) {
                if mayPressEnter { sendEnterWithSystemEvents(target: target) }
                return result(method: .systemEvents, verified: false, attempts: attempts, target: target)
            }
            failures.append("project System Events keystroke failed")
            return .failed(reason: failures.joined(separator: "; "),
                           attemptCount: attempts,
                           targetApp: target.name,
                           targetBundleID: target.bundleID)
        }
        if browserTarget {
            attempts += 1
            switch await typeTextAsNativeKeyEvents(prepared) {
            case .posted:
                if mayPressEnter { sendEnter() }
                return result(method: .nativeKeyEvents, verified: false, attempts: attempts, target: target)
            case .failedAfterPosting:
                return .failed(
                    reason: "native key events partially posted; not retyping to avoid duplicate entry",
                    attemptCount: attempts,
                    targetApp: target.name,
                    targetBundleID: target.bundleID
                )
            case .failedBeforePosting:
                failures.append("browser native key events failed")
            }
            attempts += 1
            if await typeTextWithKeyboardEvents(prepared) {
                if mayPressEnter { sendEnter() }
                return result(method: .unicodeKeyEvents, verified: false, attempts: attempts, target: target)
            }
            failures.append("browser unicode CGEvents failed")
            return .failed(reason: failures.joined(separator: "; "),
                           attemptCount: attempts,
                           targetApp: target.name,
                           targetBundleID: target.bundleID)
        }
        if let focused {
            attempts += 1
            let candidatePrepared = spacingAdjusted(text, focused: focused)
            let before = stringValue(in: focused)
            if tryAXInsertion(candidatePrepared, element: focused) {
                let verified = verifyInsertion(candidatePrepared, element: focused, previousValue: before)
                if verified {
                    if mayPressEnter { sendEnter() }
                    return result(method: .focusedAX, verified: true, attempts: attempts, target: target)
                }
                failures.append("focused AX reported success but could not be verified")
            } else {
                failures.append("focused AX insertion failed")
            }
        }
        if category == .messages || isMessagesApp() {
            attempts += 1
            if await typeTextWithKeyboardEvents(prepared) {
                if mayPressEnter { sendEnter() }
                return result(method: .unicodeKeyEvents, verified: false, attempts: attempts, target: target)
            }
            failures.append("messages unicode CGEvents failed")
        }
        for candidate in insertionCandidates(focused: focused) {
            let candidatePrepared = spacingAdjusted(text, focused: candidate)
            let before = stringValue(in: candidate)
            attempts += 1
            if tryAXInsertion(candidatePrepared, element: candidate) {
                let verified = verifyInsertion(candidatePrepared, element: candidate, previousValue: before)
                if verified {
                    if mayPressEnter { sendEnter() }
                    return result(method: .descendantAX, verified: true, attempts: attempts, target: target)
                }
                failures.append("descendant AX reported success but could not be verified")
            }
        }
        failures.append("editable descendant AX scan found no writable target")
        attempts += 1
        switch await typeTextAsNativeKeyEvents(prepared) {
        case .posted:
            if mayPressEnter { sendEnter() }
            return result(method: .nativeKeyEvents, verified: false, attempts: attempts, target: target)
        case .failedAfterPosting:
            return .failed(
                reason: "native key events partially posted; not retyping to avoid duplicate entry",
                attemptCount: attempts,
                targetApp: target.name,
                targetBundleID: target.bundleID
            )
        case .failedBeforePosting:
            failures.append("native key events failed")
        }
        attempts += 1
        if await typeTextWithKeyboardEvents(prepared) {
            if mayPressEnter { sendEnter() }
            return result(method: .unicodeKeyEvents, verified: false, attempts: attempts, target: target)
        }
        failures.append("unicode CGEvents failed")
        return .failed(reason: failures.joined(separator: "; "),
                       attemptCount: attempts,
                       targetApp: target.name,
                       targetBundleID: target.bundleID)
    }

    func insert(_ text: String,
                into element: AXUIElement,
                pressEnter: Bool,
                settings: UserSettings,
                category: AppCategory = .generic,
                targetProcessIdentifier: pid_t? = nil) async -> InsertionResult {
        let target = targetDescription(processIdentifier: targetProcessIdentifier)
        await restoreTargetApplication(processIdentifier: targetProcessIdentifier)
        if let targetProcessIdentifier,
           NSWorkspace.shared.frontmostApplication?.processIdentifier != targetProcessIdentifier {
            try? await Task.sleep(nanoseconds: 120_000_000)
            await restoreTargetApplication(processIdentifier: targetProcessIdentifier)
        }
        releaseShortcutModifiers()
        let browserTarget = isBrowserApp()
        let prepared = browserTarget ? text.trimmingCharacters(in: .newlines) : spacingAdjusted(text, focused: element)
        if prepared.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard pressEnter else {
                return .failed(reason: "Final text was empty after spacing adjustment.",
                               attemptCount: 0,
                               targetApp: target.name,
                               targetBundleID: target.bundleID)
            }
            return await insert("",
                                pressEnter: true,
                                settings: settings,
                                category: category,
                                targetProcessIdentifier: targetProcessIdentifier)
        }
        let submitConfirmationReason = CommandSubmissionPolicy.confirmationReason(category: category,
                                                                                   pressEnter: pressEnter,
                                                                                   text: prepared)
        // Anything that owes the user a confirmation before Return goes through the single gated
        // path in the primary insert overload.
        if category == .terminal || submitConfirmationReason != nil {
            return await insert(text,
                                pressEnter: pressEnter,
                                settings: settings,
                                category: category,
                                targetProcessIdentifier: targetProcessIdentifier)
        }
        if browserTarget || shouldPreferKeyboardInsertion(category: category, target: target) {
            return await insert(text,
                                pressEnter: pressEnter,
                                settings: settings,
                                category: category,
                                targetProcessIdentifier: targetProcessIdentifier)
        }
        if !isBrowserApp() {
            let before = stringValue(in: element)
            if tryAXInsertion(prepared, element: element) {
                let verified = verifyInsertion(prepared, element: element, previousValue: before)
                if verified {
                    if pressEnter, submitConfirmationReason == nil { sendEnter() }
                    return result(method: .capturedAX, verified: true, attempts: 1, target: target)
                }
            }
        }
        await refocusCapturedElement(element)
        var fallback = await insert(text,
                                    pressEnter: pressEnter,
                                    settings: settings,
                                    category: category,
                                    targetProcessIdentifier: targetProcessIdentifier)
        fallback.attemptCount += 1
        if fallback.failureReason != nil {
            fallback.failureReason = "captured AX insertion failed; \(fallback.failureReason ?? "")"
        }
        return fallback
    }

    private func result(method: InsertionMethod,
                        verified: Bool,
                        attempts: Int,
                        target: (name: String, bundleID: String?)) -> InsertionResult {
        InsertionResult(succeeded: true,
                        verified: verified,
                        method: method,
                        attemptCount: attempts,
                        failureReason: nil,
                        targetApp: target.name,
                        targetBundleID: target.bundleID)
    }

    private func targetDescription(processIdentifier: pid_t?) -> (name: String, bundleID: String?) {
        if let processIdentifier,
           let app = NSRunningApplication(processIdentifier: processIdentifier) {
            return (app.localizedName ?? "PID \(processIdentifier)", app.bundleIdentifier)
        }
        let app = NSWorkspace.shared.frontmostApplication
        return (app?.localizedName ?? "Unknown", app?.bundleIdentifier)
    }

    private func verifyInsertion(_ insertedText: String,
                                 element: AXUIElement,
                                 previousValue: String?) -> Bool {
        guard let after = stringValue(in: element) else { return false }
        if let previousValue, previousValue != after {
            let normalizedInserted = insertedText.trimmingCharacters(in: .whitespacesAndNewlines)
            return normalizedInserted.isEmpty || after.contains(normalizedInserted) || after.count > previousValue.count
        }
        return after.contains(insertedText.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func restoreTargetApplication(processIdentifier: pid_t?) async {
        guard let processIdentifier,
              NSWorkspace.shared.frontmostApplication?.processIdentifier != processIdentifier,
              let app = NSRunningApplication(processIdentifier: processIdentifier) else { return }
        app.activate(options: [.activateAllWindows])
        try? await Task.sleep(nanoseconds: 95_000_000)
    }

    private func focusedElement() -> AXUIElement? {
        guard AXIsProcessTrusted(),
              let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var focused: AnyObject?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focusedElement = focused,
              CFGetTypeID(focusedElement) == AXUIElementGetTypeID() else { return nil }
        return (focusedElement as! AXUIElement)
    }

    private func insertionCandidates(focused: AXUIElement?) -> [AXUIElement] {
        guard AXIsProcessTrusted(),
              let app = NSWorkspace.shared.frontmostApplication else {
            return focused.map { [$0] } ?? []
        }

        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var roots: [AXUIElement] = []
        if let focused { roots.append(focused) }

        var focusedWindow: AnyObject?
        if AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &focusedWindow) == .success,
           let focusedWindow,
           CFGetTypeID(focusedWindow) == AXUIElementGetTypeID() {
            roots.append(focusedWindow as! AXUIElement)
        }
        roots.append(axApp)

        var candidates: [AXUIElement] = []
        var seen = Set<AXUIElementID>()
        for root in roots {
            for element in editableDescendants(from: root) {
                let id = AXUIElementID(element)
                guard !seen.contains(id) else { continue }
                seen.insert(id)
                candidates.append(element)
                if candidates.count >= 12 { return candidates }
            }
        }
        return candidates
    }

    private func editableDescendants(from root: AXUIElement) -> [AXUIElement] {
        var queue: [AXUIElement] = [root]
        var visited = 0
        var matches: [AXUIElement] = []

        while !queue.isEmpty, visited < 220 {
            let element = queue.removeFirst()
            visited += 1

            if isEditableElement(element) {
                matches.append(element)
            }

            for attribute in [kAXChildrenAttribute, kAXContentsAttribute] {
                var value: AnyObject?
                guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
                      let value else { continue }
                if let children = value as? [AXUIElement] {
                    queue.append(contentsOf: children)
                } else if CFGetTypeID(value) == AXUIElementGetTypeID() {
                    queue.append(value as! AXUIElement)
                }
            }
        }

        return matches
    }

    private func isEditableElement(_ element: AXUIElement) -> Bool {
        if selectedRange(in: element) != nil { return true }
        if editableAttribute(in: element) == true { return true }
        if hasTextMarkerInsertionPoint(in: element) { return true }

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

    private func editableAttribute(in element: AXUIElement) -> Bool? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, "AXEditable" as CFString, &value) == .success else { return nil }
        return value as? Bool
    }

    private func hasTextMarkerInsertionPoint(in element: AXUIElement) -> Bool {
        var markerRange: AnyObject?
        return AXUIElementCopyAttributeValue(element, "AXSelectedTextMarkerRange" as CFString, &markerRange) == .success && markerRange != nil
    }

    private func isMessagesApp() -> Bool {
        guard let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier?.lowercased() else {
            return false
        }
        return bundleID == "com.apple.mobilesms"
            || bundleID.contains("messages")
            || bundleID.contains("mobilesms")
    }

    private func isBrowserApp() -> Bool {
        guard let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier?.lowercased() else {
            return false
        }
        return [
            "company.thebrowser.browser",
            "com.google.chrome",
            "com.apple.safari",
            "com.brave.browser",
            "com.microsoft.edgemac",
            "org.mozilla.firefox"
        ].contains(bundleID)
    }

    private func isCodexApp() -> Bool {
        guard let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier?.lowercased() else {
            return false
        }
        return bundleID.contains("codex") || bundleID == "com.openai.codex"
    }

    private func isLinearTarget(_ target: (name: String, bundleID: String?)) -> Bool {
        let bundleID = target.bundleID?.lowercased() ?? ""
        let name = target.name.lowercased()
        return bundleID == "com.linear" || bundleID.contains(".linear")
            || name == "linear"
    }

    private func shouldPreferKeyboardInsertion(category: AppCategory,
                                               target: (name: String, bundleID: String?)) -> Bool {
        switch category {
        case .messages, .ide, .aiChat, .projectManagement:
            return true
        default:
            break
        }

        let bundleID = target.bundleID?.lowercased() ?? ""
        let name = target.name.lowercased()
        return isMessagesApp()
            || isCodexApp()
            || isLinearTarget(target)
            || bundleID.contains("devin")
            || bundleID.contains("cursor")
            || bundleID.contains("windsurf")
            || bundleID.contains("vscode")
            || bundleID.contains("visual-studio-code")
            || name.contains("devin")
            || name.contains("cursor")
            || name.contains("windsurf")
            || name.contains("code")
    }

    private func refocusCapturedElement(_ element: AXUIElement) async {
        guard AXIsProcessTrusted() else { return }
        _ = AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, true as CFTypeRef)
        _ = AXUIElementPerformAction(element, kAXPressAction as CFString)
        try? await Task.sleep(nanoseconds: 70_000_000)
    }

    private func tryAXInsertion(_ text: String, element: AXUIElement) -> Bool {
        if selectedRange(in: element) != nil {
            let result = AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFTypeRef)
            if result == .success { return true }
        }
        return replaceAXValue(text, element: element)
    }

    private func spacingAdjusted(_ text: String, focused: AXUIElement?) -> String {
        let output = text.trimmingCharacters(in: .newlines)
        guard let focused,
              let range = selectedRange(in: focused),
              let context = cursorTextContext(in: focused, range: range) else { return output }

        return InsertionTextPreparation.prepare(output,
                                                prefix: context.prefix,
                                                suffix: context.suffix,
                                                hasSelection: context.hasSelection)
    }

    private func cursorTextContext(in element: AXUIElement, range: CFRange) -> CursorTextContext? {
        if let value = stringValue(in: element), range.location <= value.count {
            let safeLength = max(0, min(range.length, value.count - range.location))
            let selectionStart = value.index(value.startIndex, offsetBy: range.location)
            let selectionEnd = value.index(value.startIndex, offsetBy: range.location + safeLength)
            return CursorTextContext(prefix: String(value[..<selectionStart]),
                                     suffix: String(value[selectionEnd...]),
                                     hasSelection: safeLength > 0)
        }

        let prefixStart = max(0, range.location - 120)
        let prefixLength = max(0, range.location - prefixStart)
        let suffixStart = max(0, range.location + max(0, range.length))
        let prefix = stringForRange(in: element, location: prefixStart, length: prefixLength) ?? ""
        let suffix = stringForRange(in: element, location: suffixStart, length: 120) ?? ""
        guard !prefix.isEmpty || !suffix.isEmpty else { return nil }
        return CursorTextContext(prefix: prefix, suffix: suffix, hasSelection: range.length > 0)
    }

    private func replaceAXValue(_ text: String, element: AXUIElement) -> Bool {
        guard let range = selectedRange(in: element),
              let value = stringValue(in: element),
              range.location <= value.count else { return false }

        let safeLength = max(0, min(range.length, value.count - range.location))
        let start = value.index(value.startIndex, offsetBy: range.location)
        let end = value.index(value.startIndex, offsetBy: range.location + safeLength)
        let replacement = String(value[..<start]) + text + String(value[end...])
        guard AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, replacement as CFTypeRef) == .success else {
            return false
        }

        var newRange = CFRange(location: range.location + text.count, length: 0)
        if let axRange = AXValueCreate(.cfRange, &newRange) {
            _ = AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, axRange)
        }
        return true
    }

    private func selectedRange(in element: AXUIElement) -> CFRange? {
        var selectedRangeValue: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &selectedRangeValue) == .success,
              let axValue = selectedRangeValue,
              CFGetTypeID(axValue) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(axValue as! AXValue, .cfRange, &range) else { return nil }
        return range
    }

    private func stringValue(in element: AXUIElement) -> String? {
        var value: AnyObject?
        if AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success {
            return value as? String
        }
        return nil
    }

    private func stringForRange(in element: AXUIElement, location: Int, length: Int) -> String? {
        guard length > 0 else { return "" }
        var range = CFRange(location: location, length: length)
        guard let axRange = AXValueCreate(.cfRange, &range) else { return nil }
        var value: AnyObject?
        let result = AXUIElementCopyParameterizedAttributeValue(element,
                                                               kAXStringForRangeParameterizedAttribute as CFString,
                                                               axRange,
                                                               &value)
        guard result == .success else { return nil }
        return value as? String
    }

    private func targetIsFrontmost(_ processIdentifier: pid_t?) -> Bool {
        guard let processIdentifier else { return true }
        return NSWorkspace.shared.frontmostApplication?.processIdentifier == processIdentifier
    }

    private func waitForTerminalFocus(processIdentifier: pid_t?) async -> Bool {
        let openflowProcessIdentifier = ProcessInfo.processInfo.processIdentifier
        for _ in 0..<20 {
            let frontmostProcessIdentifier = NSWorkspace.shared.frontmostApplication?.processIdentifier
            let leftOpenflow = frontmostProcessIdentifier != openflowProcessIdentifier
            let targetIsFocused = processIdentifier == nil || frontmostProcessIdentifier == processIdentifier
            if leftOpenflow && targetIsFocused {
                return true
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return false
    }

    private func prepareTargetForKeyboardInput(processIdentifier: pid_t?, clickWindowChrome: Bool) async {
        let neededActivation = processIdentifier.map {
            NSWorkspace.shared.frontmostApplication?.processIdentifier != $0
        } ?? false
        await restoreTargetApplication(processIdentifier: processIdentifier)
        guard let processIdentifier,
              AXIsProcessTrusted() else { return }

        let axApp = AXUIElementCreateApplication(processIdentifier)
        _ = AXUIElementSetAttributeValue(axApp, kAXFrontmostAttribute as CFString, true as CFTypeRef)

        var windowValue: AnyObject?
        let focusedWindow: AXUIElement?
        if AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &windowValue) == .success,
           let windowValue,
           CFGetTypeID(windowValue) == AXUIElementGetTypeID() {
            focusedWindow = windowValue as! AXUIElement
        } else {
            focusedWindow = nil
        }
        if let window = focusedWindow {
            _ = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            if clickWindowChrome {
                clickWindowContent(window)
            }
        }
        if clickWindowChrome {
            try? await Task.sleep(nanoseconds: 90_000_000)
        } else if neededActivation {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private func clickWindowContent(_ window: AXUIElement) {
        guard let frame = windowFrame(window), frame.width > 80, frame.height > 40 else { return }
        let point = CGPoint(x: frame.midX, y: frame.maxY - min(56, max(24, frame.height / 4)))
        let source = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)
        let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    private func windowFrame(_ window: AXUIElement) -> CGRect? {
        var positionValue: AnyObject?
        var sizeValue: AnyObject?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue,
              let sizeValue,
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }

        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: position, size: size)
    }

    private func terminalTypingVerification(_ insertedText: String,
                                            previousText: String?,
                                            processIdentifier: pid_t?,
                                            focused: AXUIElement?) -> TerminalTypingVerification {
        guard let previousText else { return .unreadable }
        guard let after = terminalTextSnapshot(processIdentifier: processIdentifier, focused: focused) else { return .unreadable }
        let needle = insertedText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !needle.isEmpty, after.contains(needle) {
            return .verified
        }
        if after == previousText {
            return .unchanged
        }
        return .changedButUnverified
    }

    private func terminalTextSnapshot(processIdentifier: pid_t?, focused: AXUIElement?) -> String? {
        guard AXIsProcessTrusted() else { return nil }
        var roots: [AXUIElement] = []
        if let focused { roots.append(focused) }
        if let processIdentifier {
            let axApp = AXUIElementCreateApplication(processIdentifier)
            var focusedWindow: AnyObject?
            if AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &focusedWindow) == .success,
               let focusedWindow,
               CFGetTypeID(focusedWindow) == AXUIElementGetTypeID() {
                roots.append(focusedWindow as! AXUIElement)
            }
            roots.append(axApp)
        }

        var values: [String] = []
        var seen = Set<AXUIElementID>()
        for root in roots {
            collectReadableText(from: root, values: &values, seen: &seen)
            if values.joined(separator: "\n").count > 8_000 { break }
        }
        let joined = values.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.isEmpty ? nil : joined
    }

    private func collectReadableText(from root: AXUIElement,
                                     values: inout [String],
                                     seen: inout Set<AXUIElementID>) {
        var queue: [AXUIElement] = [root]
        var visited = 0
        while !queue.isEmpty, visited < 260, values.joined(separator: "\n").count < 10_000 {
            let element = queue.removeFirst()
            visited += 1
            let id = AXUIElementID(element)
            guard !seen.contains(id) else { continue }
            seen.insert(id)

            if let value = stringValue(in: element), !value.isEmpty {
                values.append(value)
            } else {
                var selectedText: AnyObject?
                if AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &selectedText) == .success,
                   let value = selectedText as? String,
                   !value.isEmpty {
                    values.append(value)
                }
            }

            for attribute in [kAXChildrenAttribute, kAXContentsAttribute] {
                var value: AnyObject?
                guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
                      let value else { continue }
                if let children = value as? [AXUIElement] {
                    queue.append(contentsOf: children)
                } else if CFGetTypeID(value) == AXUIElementGetTypeID() {
                    queue.append(value as! AXUIElement)
                }
            }
        }
    }

    private func typeTextWithSystemEvents(_ text: String, target: (name: String, bundleID: String?)) -> Bool {
        guard !text.isEmpty else { return false }
        let appTarget: String
        if let bundleID = target.bundleID, !bundleID.isEmpty {
            appTarget = "tell application id \(appleScriptString(bundleID)) to activate"
        } else {
            appTarget = "tell application \(appleScriptString(target.name)) to activate"
        }
        let source = """
        \(appTarget)
        delay 0.05
        tell application "System Events"
            keystroke \(appleScriptString(text))
        end tell
        """
        return runAppleScript(source)
    }

    private func sendEnterWithSystemEvents(target: (name: String, bundleID: String?)) {
        let appTarget: String
        if let bundleID = target.bundleID, !bundleID.isEmpty {
            appTarget = "tell application id \(appleScriptString(bundleID)) to activate"
        } else {
            appTarget = "tell application \(appleScriptString(target.name)) to activate"
        }
        let source = """
        \(appTarget)
        delay 0.02
        tell application "System Events"
            key code 36
        end tell
        """
        _ = runAppleScript(source)
    }

    private func runAppleScript(_ source: String) -> Bool {
        var error: NSDictionary?
        let script = NSAppleScript(source: source)
        _ = script?.executeAndReturnError(&error)
        return error == nil
    }

    private func appleScriptString(_ text: String) -> String {
        let escaped = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "\"\(escaped)\""
    }

    private func sendEnter() {
        sendKey(.init(keyCode: 36, flags: []))
    }

    /// Submits text into a terminal after the caller has confirmed the complete action before typing.
    /// Because both the text and the `pressEnter` decision originate from the (untrusted) cloud cleanup
    /// backend, the pre-typing confirmation surfaces the exact command before any keystrokes are sent.
    private func submitTerminalEnterIfConfirmed(text: String,
                                                target: (name: String, bundleID: String?),
                                                targetProcessIdentifier: pid_t?,
                                                useSystemEvents: Bool) async {
        await restoreTargetApplication(processIdentifier: targetProcessIdentifier)
        try? await Task.sleep(nanoseconds: 120_000_000)
        if useSystemEvents {
            sendEnterWithSystemEvents(target: target)
        } else if targetIsFrontmost(targetProcessIdentifier) {
            sendEnter()
        } else {
            sendEnterWithSystemEvents(target: target)
        }
    }

    private enum NativeKeyEventResult {
        case posted
        case failedBeforePosting
        case failedAfterPosting

        var succeeded: Bool {
            if case .posted = self { return true }
            return false
        }
    }

    private func confirmTerminalAutoSubmit(text: String,
                                           target: (name: String, bundleID: String?),
                                           reason: CommandSubmissionPolicy.ConfirmationReason,
                                           category: AppCategory) async -> Bool {
        let appName = target.name
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let preview = trimmed.count > 500 ? String(trimmed.prefix(500)) + "…" : trimmed
        // openflow cannot prove the target is not a shell, so the copy stays honest about that.
        let surface = category == .terminal ? "a terminal" : "\(appName)"
        return await MainActor.run {
            let previousApp = NSWorkspace.shared.frontmostApplication
            NSApp.activate(ignoringOtherApps: true)
            defer { previousApp?.activate() }

            let alert = NSAlert()
            alert.alertStyle = .critical
            switch reason {
            case .pressEnter:
                let embeddedLineBreakWarning = text.contains("\n")
                    ? " The dictated text contains embedded line breaks; each one presses Return and can execute a command."
                    : ""
                alert.messageText = "Press Return in \(appName)?"
                alert.informativeText = """
                openflow is about to press Return in \(surface). If this is a terminal or any shell prompt, that executes the dictated text as a command.\(embeddedLineBreakWarning)

                \(preview)
                """
            case .multilineTyping:
                alert.messageText = "Type multi-line text into \(appName)?"
                alert.informativeText = """
                openflow is about to type text that contains line breaks into \(surface). Each line break presses Return and can execute a command:

                \(preview)
                """
            }
            // First button is the default (Return/Enter), so the safe choice is the default.
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: reason == .pressEnter ? "Press Return" : "Type Text")
            return alert.runModal() == .alertSecondButtonReturn
        }
    }

    private func typeTextWithKeyboardEvents(_ text: String) async -> Bool {
        guard AXIsProcessTrusted(), !text.isEmpty else { return false }
        let source = CGEventSource(stateID: .combinedSessionState)
        let chunks = text.chunkedForKeyboardInsertion(maxScalars: text.contains("\n") ? 300 : 700)
        for chunk in chunks {
            for scalar in chunk.unicodeScalars {
                var value = UniChar(scalar.value)
                guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                      let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
                    return false
                }
                down.keyboardSetUnicodeString(stringLength: 1, unicodeString: &value)
                up.keyboardSetUnicodeString(stringLength: 1, unicodeString: &value)
                down.post(tap: .cghidEventTap)
                up.post(tap: .cghidEventTap)
            }
            if chunks.count > 1 {
                try? await Task.sleep(nanoseconds: 45_000_000)
            }
        }
        return true
    }

    private func typeTextAsNativeKeyEvents(_ text: String) async -> NativeKeyEventResult {
        guard AXIsProcessTrusted(), !text.isEmpty else { return .failedBeforePosting }
        let source = CGEventSource(stateID: .combinedSessionState)
        var usedFallback = false
        var postedAny = false

        for scalar in text.unicodeScalars {
            if scalar == "\n" {
                postedAny = true
                sendKey(.init(keyCode: 36, flags: []))
                continue
            }
            guard let key = nativeKeyPress(for: scalar) else {
                usedFallback = true
                var value = UniChar(scalar.value)
                guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                      let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
                    return postedAny ? .failedAfterPosting : .failedBeforePosting
                }
                down.keyboardSetUnicodeString(stringLength: 1, unicodeString: &value)
                up.keyboardSetUnicodeString(stringLength: 1, unicodeString: &value)
                down.post(tap: .cghidEventTap)
                up.post(tap: .cghidEventTap)
                postedAny = true
                continue
            }

            guard let down = CGEvent(keyboardEventSource: source, virtualKey: key.keyCode, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: key.keyCode, keyDown: false) else {
                return postedAny ? .failedAfterPosting : .failedBeforePosting
            }
            down.flags = key.flags
            up.flags = key.flags
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
            postedAny = true
        }

        if usedFallback {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return .posted
    }

    private func sendKey(_ key: KeyPress) {
        let source = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: key.keyCode, keyDown: true)
        down?.flags = key.flags
        let up = CGEvent(keyboardEventSource: source, virtualKey: key.keyCode, keyDown: false)
        up?.flags = key.flags
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    private func releaseShortcutModifiers() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let modifierKeyCodes: [CGKeyCode] = [58, 61, 59, 62, 55, 54]
        for keyCode in modifierKeyCodes {
            let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
            up?.flags = []
            up?.post(tap: .cghidEventTap)
        }
    }

    private func nativeKeyPress(for scalar: UnicodeScalar) -> KeyPress? {
        let shift: CGEventFlags = [.maskShift]
        switch Character(scalar) {
        case "a": return KeyPress(keyCode: 0, flags: [])
        case "s": return KeyPress(keyCode: 1, flags: [])
        case "d": return KeyPress(keyCode: 2, flags: [])
        case "f": return KeyPress(keyCode: 3, flags: [])
        case "h": return KeyPress(keyCode: 4, flags: [])
        case "g": return KeyPress(keyCode: 5, flags: [])
        case "z": return KeyPress(keyCode: 6, flags: [])
        case "x": return KeyPress(keyCode: 7, flags: [])
        case "c": return KeyPress(keyCode: 8, flags: [])
        case "v": return KeyPress(keyCode: 9, flags: [])
        case "b": return KeyPress(keyCode: 11, flags: [])
        case "q": return KeyPress(keyCode: 12, flags: [])
        case "w": return KeyPress(keyCode: 13, flags: [])
        case "e": return KeyPress(keyCode: 14, flags: [])
        case "r": return KeyPress(keyCode: 15, flags: [])
        case "y": return KeyPress(keyCode: 16, flags: [])
        case "t": return KeyPress(keyCode: 17, flags: [])
        case "1": return KeyPress(keyCode: 18, flags: [])
        case "2": return KeyPress(keyCode: 19, flags: [])
        case "3": return KeyPress(keyCode: 20, flags: [])
        case "4": return KeyPress(keyCode: 21, flags: [])
        case "6": return KeyPress(keyCode: 22, flags: [])
        case "5": return KeyPress(keyCode: 23, flags: [])
        case "=": return KeyPress(keyCode: 24, flags: [])
        case "9": return KeyPress(keyCode: 25, flags: [])
        case "7": return KeyPress(keyCode: 26, flags: [])
        case "-": return KeyPress(keyCode: 27, flags: [])
        case "8": return KeyPress(keyCode: 28, flags: [])
        case "0": return KeyPress(keyCode: 29, flags: [])
        case "]": return KeyPress(keyCode: 30, flags: [])
        case "o": return KeyPress(keyCode: 31, flags: [])
        case "u": return KeyPress(keyCode: 32, flags: [])
        case "[": return KeyPress(keyCode: 33, flags: [])
        case "i": return KeyPress(keyCode: 34, flags: [])
        case "p": return KeyPress(keyCode: 35, flags: [])
        case "l": return KeyPress(keyCode: 37, flags: [])
        case "j": return KeyPress(keyCode: 38, flags: [])
        case "'": return KeyPress(keyCode: 39, flags: [])
        case "k": return KeyPress(keyCode: 40, flags: [])
        case ";": return KeyPress(keyCode: 41, flags: [])
        case "\\": return KeyPress(keyCode: 42, flags: [])
        case ",": return KeyPress(keyCode: 43, flags: [])
        case "/": return KeyPress(keyCode: 44, flags: [])
        case "n": return KeyPress(keyCode: 45, flags: [])
        case "m": return KeyPress(keyCode: 46, flags: [])
        case ".": return KeyPress(keyCode: 47, flags: [])
        case "`": return KeyPress(keyCode: 50, flags: [])
        case " ": return KeyPress(keyCode: 49, flags: [])

        case "A": return KeyPress(keyCode: 0, flags: shift)
        case "S": return KeyPress(keyCode: 1, flags: shift)
        case "D": return KeyPress(keyCode: 2, flags: shift)
        case "F": return KeyPress(keyCode: 3, flags: shift)
        case "H": return KeyPress(keyCode: 4, flags: shift)
        case "G": return KeyPress(keyCode: 5, flags: shift)
        case "Z": return KeyPress(keyCode: 6, flags: shift)
        case "X": return KeyPress(keyCode: 7, flags: shift)
        case "C": return KeyPress(keyCode: 8, flags: shift)
        case "V": return KeyPress(keyCode: 9, flags: shift)
        case "B": return KeyPress(keyCode: 11, flags: shift)
        case "Q": return KeyPress(keyCode: 12, flags: shift)
        case "W": return KeyPress(keyCode: 13, flags: shift)
        case "E": return KeyPress(keyCode: 14, flags: shift)
        case "R": return KeyPress(keyCode: 15, flags: shift)
        case "Y": return KeyPress(keyCode: 16, flags: shift)
        case "T": return KeyPress(keyCode: 17, flags: shift)
        case "O": return KeyPress(keyCode: 31, flags: shift)
        case "U": return KeyPress(keyCode: 32, flags: shift)
        case "I": return KeyPress(keyCode: 34, flags: shift)
        case "P": return KeyPress(keyCode: 35, flags: shift)
        case "L": return KeyPress(keyCode: 37, flags: shift)
        case "J": return KeyPress(keyCode: 38, flags: shift)
        case "K": return KeyPress(keyCode: 40, flags: shift)
        case "N": return KeyPress(keyCode: 45, flags: shift)
        case "M": return KeyPress(keyCode: 46, flags: shift)

        case "!": return KeyPress(keyCode: 18, flags: shift)
        case "@": return KeyPress(keyCode: 19, flags: shift)
        case "#": return KeyPress(keyCode: 20, flags: shift)
        case "$": return KeyPress(keyCode: 21, flags: shift)
        case "^": return KeyPress(keyCode: 22, flags: shift)
        case "%": return KeyPress(keyCode: 23, flags: shift)
        case "+": return KeyPress(keyCode: 24, flags: shift)
        case "(": return KeyPress(keyCode: 25, flags: shift)
        case "&": return KeyPress(keyCode: 26, flags: shift)
        case "_": return KeyPress(keyCode: 27, flags: shift)
        case "*": return KeyPress(keyCode: 28, flags: shift)
        case ")": return KeyPress(keyCode: 29, flags: shift)
        case "}": return KeyPress(keyCode: 30, flags: shift)
        case "{": return KeyPress(keyCode: 33, flags: shift)
        case "\"": return KeyPress(keyCode: 39, flags: shift)
        case ":": return KeyPress(keyCode: 41, flags: shift)
        case "|": return KeyPress(keyCode: 42, flags: shift)
        case "<": return KeyPress(keyCode: 43, flags: shift)
        case "?": return KeyPress(keyCode: 44, flags: shift)
        case ">": return KeyPress(keyCode: 47, flags: shift)
        case "~": return KeyPress(keyCode: 50, flags: shift)
        default: return nil
        }
    }
}

private struct KeyPress {
    var keyCode: CGKeyCode
    var flags: CGEventFlags
}

private struct AXUIElementID: Hashable {
    private let raw: UInt

    init(_ element: AXUIElement) {
        raw = UInt(bitPattern: Unmanaged.passUnretained(element).toOpaque())
    }
}

private extension String {
    func chunkedForKeyboardInsertion(maxScalars: Int) -> [String] {
        guard unicodeScalars.count > maxScalars else { return [self] }
        var chunks: [String] = []
        var current = ""
        current.reserveCapacity(maxScalars)
        for scalar in unicodeScalars {
            current.unicodeScalars.append(scalar)
            if current.unicodeScalars.count >= maxScalars {
                chunks.append(current)
                current = ""
            }
        }
        if !current.isEmpty {
            chunks.append(current)
        }
        return chunks
    }
}
