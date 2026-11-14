import Carbon.HIToolbox

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
