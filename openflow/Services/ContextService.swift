import AppKit

@MainActor
final class ContextService {
    struct FocusedSnapshot {
        var context: FormattingContext
        var element: AXUIElement?
        var focusedWindow: AXUIElement?
        var processIdentifier: pid_t?
        var selectionSource: String?
        var canInsertText: Bool
        var selectedRange: CFRange?
    }

    private struct TextSelectionSnapshot {
        var selectedText: String?
        var nearbyText: String?
        var textBefore: String?
        var textAfter: String?
        var element: AXUIElement?
        var source: String?
        var selectedRange: CFRange?
    }

    private struct FieldRead {
        var selectedText: String?
        var nearbyText: String?
        var textBefore: String?
        var textAfter: String?
        var element: AXUIElement?
        var focusedWindow: AXUIElement?
        var source: String?
        var canInsertText: Bool
        var selectedRange: CFRange?
    }

    private let browserContext = BrowserContextService()

    func capture(settings: UserSettings) -> FormattingContext {
        captureSnapshot(settings: settings).context
    }

    func captureSnapshot(settings: UserSettings,
                         activeApplication: NSRunningApplication? = nil,
                         searchDescendants: Bool = true) -> FocusedSnapshot {
        let active = activeApplication ?? NSWorkspace.shared.frontmostApplication
        let appName = active?.localizedName ?? "Unknown"
        let bundleID = active?.bundleIdentifier ?? ""
        let fieldContext = focusedTextContext(app: active, searchDescendants: searchDescendants)
        let useContext = settings.contextAwarenessEnabled
        let browserURL = useContext && settings.browserURLDetectionEnabled ? browserContext.currentURL(bundleID: bundleID) : nil
        // Category is a safety input (terminal confirmation, local-only cleanup). It is
        // computed from the focused app even when the user has turned context awareness
        // off; that toggle only controls whether surrounding field text leaves the Mac.
        let category = classify(appName: appName, bundleID: bundleID, browserURL: browserURL)
        let context = FormattingContext(activeAppName: appName,
                                        bundleID: bundleID,
                                        category: category,
                                        selectedText: useContext ? fieldContext.selectedText : nil,
                                        nearbyText: useContext ? fieldContext.nearbyText : nil,
                                        textBefore: useContext ? fieldContext.textBefore : nil,
                                        textAfter: useContext ? fieldContext.textAfter : nil,
                                        browserURL: browserURL,
                                        stylePreset: useContext ? settings.stylePreset : .auto)
        return FocusedSnapshot(context: context,
                               element: fieldContext.element,
                               focusedWindow: fieldContext.focusedWindow,
                               processIdentifier: active?.processIdentifier,
                               selectionSource: fieldContext.source,
                               canInsertText: fieldContext.canInsertText,
                               selectedRange: fieldContext.selectedRange)
    }

    func isKnownBrowser(bundleID: String) -> Bool {
        let normalized = bundleID.lowercased()
        return [
            "company.thebrowser.browser",
            "com.google.chrome",
            "com.apple.safari",
            "com.brave.browser",
            "com.microsoft.edgemac",
            "org.mozilla.firefox"
        ].contains(normalized)
    }

    /// Best-effort terminal names. This list only improves formatting and never decides whether
    /// auto-submit is safe; that gate lives in CommandSubmissionPolicy, which confirms for every
    /// target it cannot positively identify as a message, document, or search surface.
    private static let terminalMarkers = [
        "terminal",
        "iterm",
        "warp",
        "ghostty",
        "ghosty",
        "kitty",
        "alacritty",
        "wezterm",
        "konsole",
        "termius",
        "terminus",
        "tmux",
        "putty",
        "mintty",
        "xterm"
    ]

    /// Terminal names that are short enough to appear inside unrelated words, so they only count as
    /// whole words ("Rio" the terminal, not "prior") and only in the app identity, never in a URL
    /// where they collide with pages such as console.cloud.google.com.
    private static let terminalWordMarkers = ["rio", "hyper", "tabby", "shell", "ssh", "console"]

    func classify(appName: String, bundleID: String, browserURL: String?) -> AppCategory {
        let haystack = "\(appName) \(bundleID) \(browserURL ?? "")".lowercased()
        let appIdentity = "\(appName) \(bundleID)".lowercased()
        if Self.terminalMarkers.contains(where: haystack.contains)
            || Self.terminalWordMarkers.contains(where: { Self.containsWord($0, in: appIdentity) }) {
            return .terminal
        }
        if haystack.contains("xcode")
            || haystack.contains("cursor")
            || haystack.contains("windsurf")
            || haystack.contains("visual studio code")
            || haystack.contains("vscode")
            || haystack.contains("devin")
            || haystack.contains("devon") {
            return .ide
        }
        if haystack.contains("codex") || haystack.contains("chatgpt") || haystack.contains("claude") || haystack.contains("openai.com") || haystack.contains("anthropic.com") { return .aiChat }
        if haystack.contains("mail") || haystack.contains("gmail") { return .email }
        if haystack.contains("messages") || haystack.contains("slack") || haystack.contains("discord") || haystack.contains("whatsapp") { return .messages }
        if haystack.contains("docs.google") || haystack.contains("notion") || haystack.contains("notes") { return .docs }
        if haystack.contains("github") || haystack.contains("linear") || haystack.contains("jira") { return .projectManagement }
        if haystack.contains("google.com/search") || haystack.contains("duckduckgo") { return .browserSearch }
        return .generic
    }

    private static func containsWord(_ word: String, in haystack: String) -> Bool {
        haystack.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).contains(where: { $0 == word })
    }

    func mergeFieldText(from snapshot: FocusedSnapshot, into context: inout FormattingContext) {
        context.selectedText = snapshot.context.selectedText
        context.nearbyText = snapshot.context.nearbyText
        context.textBefore = snapshot.context.textBefore
        context.textAfter = snapshot.context.textAfter
    }

    private func focusedTextContext(app: NSRunningApplication?,
                                    searchDescendants: Bool) -> FieldRead {
        let empty = FieldRead(selectedText: nil,
                              nearbyText: nil,
                              textBefore: nil,
                              textAfter: nil,
                              element: nil,
                              focusedWindow: nil,
                              source: nil,
                              canInsertText: false,
                              selectedRange: nil)
        guard AXIsProcessTrusted(),
              let app else { return empty }
        let isBrowser = isKnownBrowser(bundleID: app.bundleIdentifier ?? "")
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(axApp, 0.12)
        var fallbackElement: AXUIElement?
        var focusedWindowElement: AXUIElement?
        var canInsertText = isBrowser

        var focused: AnyObject?
        if AXUIElementCopyAttributeValue(axApp, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
           let focusedElement = focused,
           CFGetTypeID(focusedElement) == AXUIElementGetTypeID() {
            let element = focusedElement as! AXUIElement
            AXUIElementSetMessagingTimeout(element, 0.12)
            fallbackElement = element
            canInsertText = canInsertText || elementSupportsTextInsertion(element, assumeWebContentCanType: isBrowser)
            if let snapshot = usableFieldSnapshot(snapshot: selectionSnapshot(in: element)) {
                return fieldRead(from: snapshot, focusedWindow: focusedWindowElement, canInsertText: true)
            }
            if searchDescendants,
               !isBrowser,
               let snapshot = usableFieldSnapshot(snapshot: descendantSelectionSnapshot(from: element)) {
                return fieldRead(from: snapshot, focusedWindow: focusedWindowElement, canInsertText: true)
            }
        }

        if isBrowser {
            let range = fallbackElement.flatMap { selectedRange(in: $0) }
            return FieldRead(selectedText: nil,
                             nearbyText: nil,
                             textBefore: nil,
                             textAfter: nil,
                             element: fallbackElement,
                             focusedWindow: focusedWindowElement,
                             source: nil,
                             canInsertText: canInsertText,
                             selectedRange: range)
        }

        var focusedWindow: AnyObject?
        if AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &focusedWindow) == .success,
           let focusedWindow,
           CFGetTypeID(focusedWindow) == AXUIElementGetTypeID() {
            let window = focusedWindow as! AXUIElement
            focusedWindowElement = window
            fallbackElement = fallbackElement ?? window
            if searchDescendants {
                canInsertText = canInsertText || descendantSupportsTextInsertion(from: window, assumeWebContentCanType: false)
            }
            if searchDescendants,
               let snapshot = usableFieldSnapshot(snapshot: descendantSelectionSnapshot(from: window)) {
                return fieldRead(from: snapshot, focusedWindow: focusedWindowElement, canInsertText: true)
            }
        }

        if searchDescendants {
            canInsertText = canInsertText || descendantSupportsTextInsertion(from: axApp, assumeWebContentCanType: false)
        }
        if searchDescendants,
           let snapshot = usableFieldSnapshot(snapshot: descendantSelectionSnapshot(from: axApp)) {
            return fieldRead(from: snapshot, focusedWindow: focusedWindowElement, canInsertText: true)
        }

        let range = fallbackElement.flatMap { selectedRange(in: $0) }
        return FieldRead(selectedText: nil,
                         nearbyText: nil,
                         textBefore: nil,
                         textAfter: nil,
                         element: fallbackElement,
                         focusedWindow: focusedWindowElement,
                         source: nil,
                         canInsertText: canInsertText,
                         selectedRange: range)
    }

    private func usableFieldSnapshot(snapshot: TextSelectionSnapshot?) -> TextSelectionSnapshot? {
        guard let snapshot else { return nil }
        if snapshot.selectedText?.isEmpty == false { return snapshot }
        if snapshot.nearbyText?.isEmpty == false { return snapshot }
        if snapshot.textBefore?.isEmpty == false { return snapshot }
        if snapshot.textAfter?.isEmpty == false { return snapshot }
        return nil
    }

    private func fieldRead(from snapshot: TextSelectionSnapshot,
                           focusedWindow: AXUIElement?,
                           canInsertText: Bool) -> FieldRead {
        FieldRead(selectedText: snapshot.selectedText,
                  nearbyText: snapshot.nearbyText,
                  textBefore: snapshot.textBefore,
                  textAfter: snapshot.textAfter,
                  element: snapshot.element,
                  focusedWindow: focusedWindow,
                  source: snapshot.source,
                  canInsertText: canInsertText,
                  selectedRange: snapshot.selectedRange)
    }

    private func elementSupportsTextInsertion(_ element: AXUIElement, assumeWebContentCanType: Bool) -> Bool {
        if selectedRange(in: element) != nil { return true }
        if editableAttribute(in: element) == true { return true }
        if hasTextMarkerInsertionPoint(in: element) { return true }
        var role: AnyObject?
        if AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role) == .success,
           let roleString = role as? String {
            let textRoles = [
                kAXTextFieldRole as String,
                kAXTextAreaRole as String,
                "AXComboBox",
                "AXSearchField"
            ]
            if textRoles.contains(roleString) { return true }
            if assumeWebContentCanType && ["AXWebArea", "AXGroup", "AXUnknown"].contains(roleString) {
                return focusedAttribute(in: element) == true
            }
        }
        return false
    }

    private func descendantSupportsTextInsertion(from root: AXUIElement, assumeWebContentCanType: Bool) -> Bool {
        var queue: [AXUIElement] = [root]
        var visited = 0

        while !queue.isEmpty, visited < 180 {
            let element = queue.removeFirst()
            visited += 1

            if elementSupportsTextInsertion(element, assumeWebContentCanType: assumeWebContentCanType) {
                return true
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
        return false
    }

    private func editableAttribute(in element: AXUIElement) -> Bool? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, "AXEditable" as CFString, &value) == .success else { return nil }
        return value as? Bool
    }

    private func focusedAttribute(in element: AXUIElement) -> Bool {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXFocusedAttribute as CFString, &value) == .success else { return false }
        return (value as? Bool) == true
    }

    private func hasTextMarkerInsertionPoint(in element: AXUIElement) -> Bool {
        var markerRange: AnyObject?
        return AXUIElementCopyAttributeValue(element, "AXSelectedTextMarkerRange" as CFString, &markerRange) == .success && markerRange != nil
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

    private func selectionSnapshot(in element: AXUIElement) -> TextSelectionSnapshot? {
        var selectedText = selectedTextAttribute(in: element)
        if selectedText?.isEmpty != false {
            selectedText = selectedTextFromRange(in: element)
        }
        if selectedText?.isEmpty != false {
            selectedText = selectedTextFromTextMarkerRange(in: element)
        }

        let range = selectedRange(in: element)
        let slice: FieldTextWindow.Slice?
        if let range, let full = stringValue(in: element) {
            slice = FieldTextWindow.slice(fullText: full,
                                          utf16Location: range.location,
                                          utf16Length: range.length)
        } else if let range {
            slice = parameterizedSlice(in: element, range: range, selectedText: selectedText)
        } else if let full = stringValue(in: element), !full.isEmpty {
            slice = FieldTextWindow.slice(fullText: full,
                                          utf16Location: (full as NSString).length,
                                          utf16Length: 0)
        } else {
            slice = nil
        }

        let textBefore = emptyToNil(slice?.textBefore)
        let textAfter = emptyToNil(slice?.textAfter)
        let nearbyText = emptyToNil(slice?.nearbyText)
        if selectedText?.isEmpty != false {
            selectedText = slice?.selectedText
        }
        guard selectedText?.isEmpty == false
                || nearbyText != nil
                || textBefore != nil
                || textAfter != nil else { return nil }
        return TextSelectionSnapshot(selectedText: selectedText,
                                     nearbyText: nearbyText,
                                     textBefore: textBefore,
                                     textAfter: textAfter,
                                     element: element,
                                     source: "accessibility",
                                     selectedRange: range)
    }

    private func descendantSelectionSnapshot(from root: AXUIElement) -> TextSelectionSnapshot? {
        var queue: [AXUIElement] = [root]
        var visited = 0

        while !queue.isEmpty, visited < 160 {
            let element = queue.removeFirst()
            visited += 1

            if let snapshot = usableFieldSnapshot(snapshot: selectionSnapshot(in: element)) {
                return snapshot
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
        return nil
    }

    private func selectedTextAttribute(in element: AXUIElement) -> String? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private func selectedTextFromRange(in element: AXUIElement) -> String? {
        var selectedRangeValue: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &selectedRangeValue) == .success,
              let axValue = selectedRangeValue,
              CFGetTypeID(axValue) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(axValue as! AXValue, .cfRange, &range), range.length > 0 else { return nil }
        return stringForRange(in: element, location: range.location, length: range.length)
    }

    private func selectedTextFromTextMarkerRange(in element: AXUIElement) -> String? {
        var markerRange: AnyObject?
        guard AXUIElementCopyAttributeValue(element, "AXSelectedTextMarkerRange" as CFString, &markerRange) == .success,
              let markerRange else { return nil }
        var value: AnyObject?
        let result = AXUIElementCopyParameterizedAttributeValue(element,
                                                               "AXStringForTextMarkerRange" as CFString,
                                                               markerRange,
                                                               &value)
        guard result == .success else { return nil }
        return value as? String
    }

    private func stringValue(in element: AXUIElement) -> String? {
        var fullValue: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &fullValue) == .success else {
            return nil
        }
        let string = fullValue as? String
        return string?.isEmpty == false ? string : nil
    }

    private func parameterizedSlice(in element: AXUIElement,
                                    range: CFRange,
                                    selectedText: String?) -> FieldTextWindow.Slice {
        let prefixStart = max(0, range.location - FieldTextWindow.maxSideUTF16)
        let prefix = stringForRange(in: element, location: prefixStart, length: max(0, range.location - prefixStart)) ?? ""
        let suffix = stringForRange(in: element,
                                    location: range.location + max(0, range.length),
                                    length: FieldTextWindow.maxSideUTF16) ?? ""
        return FieldTextWindow.Slice(selectedText: selectedText,
                                     textBefore: prefix,
                                     textAfter: suffix)
    }

    private func emptyToNil(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    private func nearbyTextForRange(in element: AXUIElement, range: CFRange, selectedText: String?) -> String? {
        if let full = stringValue(in: element) {
            return FieldTextWindow.slice(fullText: full,
                                         utf16Location: range.location,
                                         utf16Length: range.length).nearbyText
        }
        return parameterizedSlice(in: element, range: range, selectedText: selectedText).nearbyText
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
}

final class BrowserContextService {
    private struct CachedURL {
        var value: String?
        var refreshedAt: Date
    }

    private let lock = NSLock()
    private var cache: [String: CachedURL] = [:]
    private var refreshesInFlight = Set<String>()

    func currentURL(bundleID: String) -> String? {
        guard let source = scriptSource(bundleID: bundleID) else { return nil }
        let now = Date()
        let cached = cachedURL(bundleID: bundleID, now: now)
        scheduleRefreshIfNeeded(bundleID: bundleID, source: source)
        return cached
    }

    private func cachedURL(bundleID: String, now: Date) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let cached = cache[bundleID] else { return nil }
        return now.timeIntervalSince(cached.refreshedAt) < 8 ? cached.value : cached.value
    }

    private func scheduleRefreshIfNeeded(bundleID: String, source: String) {
        lock.lock()
        if refreshesInFlight.contains(bundleID) {
            lock.unlock()
            return
        }
        if let cached = cache[bundleID],
           Date().timeIntervalSince(cached.refreshedAt) < 2 {
            lock.unlock()
            return
        }
        refreshesInFlight.insert(bundleID)
        lock.unlock()

        DispatchQueue.global(qos: .utility).async { [weak self] in
            let value = Self.runAppleScript(source)
            self?.lock.lock()
            self?.cache[bundleID] = CachedURL(value: value, refreshedAt: Date())
            self?.refreshesInFlight.remove(bundleID)
            self?.lock.unlock()
        }
    }

    private func scriptSource(bundleID: String) -> String? {
        switch bundleID {
        case "com.apple.Safari":
            return "tell application \"Safari\" to get URL of front document"
        case "com.google.Chrome":
            return "tell application \"Google Chrome\" to get URL of active tab of front window"
        case "company.thebrowser.Browser":
            return "tell application \"Arc\" to get URL of active tab of front window"
        case "com.brave.Browser":
            return "tell application \"Brave Browser\" to get URL of active tab of front window"
        case "com.microsoft.edgemac":
            return "tell application \"Microsoft Edge\" to get URL of active tab of front window"
        default:
            return nil
        }
    }

    private static func runAppleScript(_ source: String) -> String? {
        var error: NSDictionary?
        let script = NSAppleScript(source: source)
        let result = script?.executeAndReturnError(&error)
        return result?.stringValue
    }
}
