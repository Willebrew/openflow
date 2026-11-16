#if canImport(Carbon.HIToolbox)
import Carbon.HIToolbox
#endif

enum KeyboardInputSourcePolicy {
    static func requiresOverride(isKeyboard: Bool, isLayout: Bool, isASCII: Bool) -> Bool {
        !(isKeyboard && isLayout && isASCII)
    }

    static func commitsWithEisu(sourceID: String) -> Bool {
        sourceID.hasPrefix("com.apple.inputmethod.Kotoeri.") ||
            sourceID == "com.apple.inputmethod.SCIM.ITABC"
    }
}

#if canImport(Carbon.HIToolbox)

struct KeyboardInputSourceOverride {
    private let original: TISInputSource?
    private let layout: TISInputSource?
    let commitsWithEisu: Bool

    var changed: Bool { original != nil }

    init?() {
        guard let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return nil }
        if Self.isASCIIKeyboardLayout(current) {
            original = nil
            layout = nil
            commitsWithEisu = false
            return
        }
        guard let layout = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              Self.isASCIIKeyboardLayout(layout) else { return nil }
        original = current
        self.layout = layout
        if let rawID = TISGetInputSourceProperty(current, kTISPropertyInputSourceID) {
            let sourceID = Unmanaged<CFString>.fromOpaque(rawID).takeUnretainedValue() as String
            commitsWithEisu = KeyboardInputSourcePolicy.commitsWithEisu(sourceID: sourceID)
        } else {
            commitsWithEisu = false
        }
    }

    func select() -> OSStatus {
        guard let layout else { return noErr }
        return TISSelectInputSource(layout)
    }

    func restore() -> OSStatus {
        guard let original else { return noErr }
        return TISSelectInputSource(original)
    }

    private static func isASCIIKeyboardLayout(_ source: TISInputSource) -> Bool {
        guard let category = TISGetInputSourceProperty(source, kTISPropertyInputSourceCategory),
              let type = TISGetInputSourceProperty(source, kTISPropertyInputSourceType),
              let ascii = TISGetInputSourceProperty(source, kTISPropertyInputSourceIsASCIICapable) else { return false }
        return !KeyboardInputSourcePolicy.requiresOverride(
            isKeyboard: Unmanaged<CFString>.fromOpaque(category).takeUnretainedValue() == kTISCategoryKeyboardInputSource,
            isLayout: Unmanaged<CFString>.fromOpaque(type).takeUnretainedValue() == kTISTypeKeyboardLayout,
            isASCII: CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(ascii).takeUnretainedValue())
        )
    }
}

/// Reads what a physical key types on a keyboard layout.
struct KeyboardLayoutTranslator {
    private let layoutData: Data

    /// The active layout, or nil when the current input source is an input method.
    init?() {
        guard let inputSource = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              Self.stringProperty(inputSource, kTISPropertyInputSourceType) == (kTISTypeKeyboardLayout as String),
              let layoutSource = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue() else {
            return nil
        }
        self.init(layoutSource: layoutSource)
    }

    /// An installed layout by input source ID, such as `com.apple.keylayout.French`.
    init?(inputSourceID: String) {
        let filter = [kTISPropertyInputSourceID as String: inputSourceID] as CFDictionary
        guard let sources = TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource],
              let layoutSource = sources.first else {
            return nil
        }
        self.init(layoutSource: layoutSource)
    }

    private init?(layoutSource: TISInputSource) {
        guard let raw = TISGetInputSourceProperty(layoutSource, kTISPropertyUnicodeKeyLayoutData) else {
            return nil
        }
        layoutData = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
    }

    /// The text the key produces, or nil when it is a dead key or untranslatable.
    func character(forKeyCode keyCode: CGKeyCode, shift: Bool) -> String? {
        layoutData.withUnsafeBytes { buffer -> String? in
            guard let layout = buffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else {
                return nil
            }
            let modifiers: UInt32 = shift ? UInt32(shiftKey >> 8) & 0xFF : 0
            var deadKeyState: UInt32 = 0
            var length = 0
            var characters = [UniChar](repeating: 0, count: 4)
            let status = UCKeyTranslate(layout,
                                        UInt16(keyCode),
                                        UInt16(kUCKeyActionDown),
                                        modifiers,
                                        UInt32(LMGetKbdType()),
                                        0,
                                        &deadKeyState,
                                        characters.count,
                                        &length,
                                        &characters)
            guard status == noErr, deadKeyState == 0, length > 0 else { return nil }
            return String(utf16CodeUnits: characters, count: length)
        }
    }

    private static func stringProperty(_ source: TISInputSource, _ key: CFString) -> String? {
        guard let raw = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
    }
}
#endif
