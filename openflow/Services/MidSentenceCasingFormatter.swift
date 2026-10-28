import Foundation

/// Whisper always capitalizes the first word. When the field's text_before
/// ends mid-sentence (a letter or a comma), that leading capital is wrong:
/// lowercase it unless the word is "I", an acronym, or a likely proper noun.
enum MidSentenceCasingFormatter {
    static func apply(_ text: String, textBefore: String?) -> String {
        guard let textBefore, !text.isEmpty else { return text }
        let trimmedBefore = textBefore.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmedBefore.last,
              last.isLetter || last == "," else { return text }
        guard let firstIndex = text.firstIndex(where: { $0.isLetter }) else { return text }
        let first = text[firstIndex]
        guard first.isUppercase else { return text }
        let word = leadingWord(of: text)
        guard !isProtected(word, in: text) else { return text }
        var result = text
        result.replaceSubrange(firstIndex...firstIndex, with: String(first).lowercased())
        return result
    }

    private static func leadingWord(of text: String) -> Substring {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(while: { $0.isLetter || $0 == "'" || $0 == "’" })
    }

    private static func isProtected(_ word: Substring, in text: String) -> Bool {
        guard !word.isEmpty else { return true }
        if word == "I" || word.hasPrefix("I'") || word.hasPrefix("I’") { return true }
        let letters = word.filter(\.isLetter)
        // All-caps words are acronyms ("NASA"); internal capitals are
        // camel-cased names ("iPhone").
        if letters.count > 1, letters.allSatisfy(\.isUppercase) { return true }
        if word.dropFirst().contains(where: \.isUppercase) { return true }
        // A word capitalized again later in the same output is a proper noun,
        // not a Whisper sentence-start capital.
        let rest = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .dropFirst(word.count)
        let restWords = rest.split(whereSeparator: { !$0.isLetter && $0 != "'" && $0 != "’" })
        return restWords.contains(where: { $0 == word })
    }
}
