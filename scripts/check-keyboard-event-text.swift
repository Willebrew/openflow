import Foundation

@main
struct CheckKeyboardEventText {
    static func main() {
        check("ascii is one unit per character",
              text: "Hi!",
              expected: [[0x48], [0x69], [0x21]])
        check("accented and smart quote characters stay single units",
              text: "é’",
              expected: [[0xE9], [0x2019]])
        check("emoji outside the BMP is sent as a surrogate pair",
              text: "👍",
              expected: [[0xD83D, 0xDC4D]])
        check("emoji with skin tone stays one payload",
              text: "👍🏽",
              expected: [[0xD83D, 0xDC4D, 0xD83C, 0xDFFD]])
        check("flag stays one payload",
              text: "🇺🇸",
              expected: [[0xD83C, 0xDDFA, 0xD83C, 0xDDF8]])
        check("combining mark stays with its base letter",
              text: "e\u{301}",
              expected: [[0x65, 0x301]])

        let family = "👨‍👩‍👧‍👦"
        let familyPayloads = KeyboardEventText.unicodePayloads(for: family)
        expect(familyPayloads.allSatisfy { $0.count <= KeyboardEventText.maxUnitsPerEvent },
               "long ZWJ sequence payloads fit in one event each")
        expect(String(decoding: familyPayloads.flatMap { $0 }, as: UTF16.self) == family,
               "long ZWJ sequence round-trips")

        let mixed = "Café naïve résumé, “smart quotes” and it’s fine. Thanks 👍 see you 🎉 at 5. 中文 עברית"
        let mixedPayloads = KeyboardEventText.unicodePayloads(for: mixed)
        expect(String(decoding: mixedPayloads.flatMap { $0 }, as: UTF16.self) == mixed,
               "mixed text round-trips without loss")

        let longCluster = "a" + String(repeating: "\u{301}", count: 30)
        let longPayloads = KeyboardEventText.unicodePayloads(for: longCluster)
        expect(longPayloads.allSatisfy { $0.count <= KeyboardEventText.maxUnitsPerEvent },
               "oversized cluster is split into event-sized payloads")
        expect(String(decoding: longPayloads.flatMap { $0 }, as: UTF16.self) == longCluster,
               "oversized cluster round-trips")

        expect(KeyboardEventText.isLineBreak("\n"), "LF is a line break")
        expect(KeyboardEventText.isLineBreak("\r\n"), "CRLF is a line break")
        expect(!KeyboardEventText.isLineBreak("a"), "letter is not a line break")

        print("keyboard event text checks passed")
    }

    private static func check(_ name: String, text: String, expected: [[UInt16]]) {
        let actual = KeyboardEventText.unicodePayloads(for: text)
        guard actual == expected else {
            fputs("FAIL \(name): expected \(expected), got \(actual)\n", stderr)
            exit(1)
        }
    }

    private static func expect(_ condition: Bool, _ name: String) {
        guard condition else {
            fputs("FAIL \(name)\n", stderr)
            exit(1)
        }
    }
}
