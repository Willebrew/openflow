import Foundation

/// UTF-16 window around an AX caret/selection. Accessibility ranges are NSString units.
enum FieldTextWindow {
    static let maxSideUTF16 = 600

    struct Slice: Equatable {
        var selectedText: String?
        var textBefore: String
        var textAfter: String

        var nearbyText: String {
            let selected = selectedText ?? ""
            let combined = textBefore + selected + textAfter
            return combined.isEmpty ? "" : combined
        }
    }

    static func slice(fullText: String,
                      utf16Location: Int,
                      utf16Length: Int,
                      maxSide: Int = maxSideUTF16) -> Slice {
        let ns = fullText as NSString
        let length = ns.length
        let location = min(max(0, utf16Location), length)
        let selectedLength = min(max(0, utf16Length), length - location)
        let beforeStart = max(0, location - maxSide)
        let afterStart = location + selectedLength
        let before = ns.substring(with: NSRange(location: beforeStart, length: location - beforeStart))
        let after = ns.substring(with: NSRange(location: afterStart, length: min(maxSide, length - afterStart)))
        let selected = selectedLength > 0
            ? ns.substring(with: NSRange(location: location, length: selectedLength))
            : nil
        return Slice(
            selectedText: selected?.isEmpty == false ? selected : nil,
            textBefore: before,
            textAfter: after
        )
    }
}
