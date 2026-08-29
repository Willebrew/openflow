import Foundation

@main
struct CheckInsertionTextPreparation {
    static func main() {
        check("mid sentence insertion lowercases and adds space",
              raw: "Wonderful.",
              prefix: "Thank you for this",
              suffix: " information.",
              expected: " wonderful")

        check("punctuation before existing period is removed",
              raw: "Very much.",
              prefix: "Cool, thank you",
              suffix: ".",
              expected: " very much")

        check("signoff before signature uses comma",
              raw: "Best.",
              prefix: "Professor Manor, thank you so much.\n\n",
              suffix: "\nWill Killebrew\nFounder & CEO",
              expected: "Best,")

        check("new sentence capitalizes after punctuation",
              raw: "sounds good",
              prefix: "I will review it. ",
              suffix: "",
              expected: "Sounds good")

        check("selected text replacement does not add surrounding spaces",
              raw: "replacement.",
              prefix: "Please ",
              suffix: " this.",
              hasSelection: true,
              expected: "replacement.")

        check("technical capitalization is preserved mid sentence",
              raw: "CAN FD",
              prefix: "use",
              suffix: " here",
              expected: " CAN FD")
    }

    private static func check(_ label: String,
                              raw: String,
                              prefix: String,
                              suffix: String,
                              hasSelection: Bool = false,
                              expected: String) {
        let actual = InsertionTextPreparation.prepare(raw,
                                                      prefix: prefix,
                                                      suffix: suffix,
                                                      hasSelection: hasSelection)
        if actual != expected {
            FileHandle.standardError.write(Data("""
            insertion text preparation check failed: \(label)
            expected: \(debug(expected))
            actual:   \(debug(actual))

            """.utf8))
            exit(1)
        }
    }

    private static func debug(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
    }
}
