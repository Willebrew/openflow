import Foundation

/// Splits text into the UTF-16 payloads posted with `keyboardSetUnicodeString`.
///
/// A payload is one grapheme cluster, so emoji, skin tones, flags and combining
/// marks arrive whole. Characters outside the Basic Multilingual Plane need a
/// surrogate pair; truncating a scalar to a single `UniChar` traps at runtime.
enum KeyboardEventText {
    /// The largest string one keyboard CGEvent carries.
    static let maxUnitsPerEvent = 20

    static func unicodePayloads(for text: String) -> [[UInt16]] {
        var payloads: [[UInt16]] = []
        for character in text {
            payloads.append(contentsOf: Self.payloads(for: character))
        }
        return payloads
    }

    static func payloads(for character: Character) -> [[UInt16]] {
        let units = Array(character.utf16)
        if units.count <= maxUnitsPerEvent {
            return [units]
        }
        return character.unicodeScalars.map { Array(String($0).utf16) }
    }

    static func isLineBreak(_ character: Character) -> Bool {
        character == "\n" || character == "\r\n" || character == "\r"
    }
}
