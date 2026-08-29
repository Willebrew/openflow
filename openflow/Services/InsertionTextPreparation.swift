import Foundation

enum InsertionTextPreparation {
    static func prepare(_ text: String,
                        prefix: String,
                        suffix: String,
                        hasSelection: Bool) -> String {
        var output = normalized(text, prefix: prefix, suffix: suffix, hasSelection: hasSelection)
        guard !output.isEmpty else { return output }

        let context = CursorTextContext(prefix: prefix, suffix: suffix, hasSelection: hasSelection)
        if !hasSelection, shouldAddLeadingSpace(before: context.before, output: output) {
            output = " " + output
        }
        if !hasSelection, shouldAddTrailingSpace(after: context.after, output: output) {
            output += " "
        }
        if shouldLowercaseMidSentence(prefix: prefix, output: output) {
            lowercaseFirstLetter(&output)
        }
        return output
    }

    private struct CursorTextContext {
        var prefix: String
        var suffix: String
        var hasSelection: Bool

        var before: Character? { prefix.last }
        var after: Character? { suffix.first }
    }

    private static func shouldAddLeadingSpace(before: Character?, output: String) -> Bool {
        guard let before, let first = output.first else { return false }
        if before.isWhitespace || before.isNewline { return false }
        if "([{/\"'".contains(before) { return false }
        return first.isLetter || first.isNumber || "\"'(".contains(first)
    }

    private static func shouldAddTrailingSpace(after: Character?, output: String) -> Bool {
        guard let after, let last = output.last else { return false }
        if after.isWhitespace || after.isNewline { return false }
        if ".?!,;:)]}/\"'".contains(after) { return false }
        return last.isLetter || last.isNumber || ".?!".contains(last) || "\"')".contains(last)
    }

    private static func shouldLowercaseMidSentence(prefix: String, output: String) -> Bool {
        guard let firstLetter = output.first(where: { $0.isLetter }), firstLetter.isUppercase else { return false }
        let trimmedPrefix = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmedPrefix.last else { return false }
        if ".?!:;\n".contains(last) { return false }
        let protected = output.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ").first.map(String.init) ?? output
        if protected.dropFirst().contains(where: { $0.isUppercase }) { return false }
        return true
    }

    private static func normalized(_ text: String, prefix: String, suffix: String, hasSelection: Bool) -> String {
        var output = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !output.isEmpty else { return output }

        let suffixTrimmed = suffix.trimmingCharacters(in: .whitespacesAndNewlines)
        if isLikelySignoff(output), startsWithSignatureBlock(suffix) {
            output = output.trimmingCharacters(in: CharacterSet(charactersIn: ".?!,;:"))
            return output + ","
        }

        if let next = suffixTrimmed.first, ".?!,;:".contains(next) {
            output = output.trimmingCharacters(in: CharacterSet(charactersIn: ".?!,;:"))
        }

        let prefixTrimmed = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        let insertingInsideSentence = !hasSelection
            && !prefixTrimmed.isEmpty
            && !suffixTrimmed.isEmpty
            && !(prefixTrimmed.last.map { ".?!\n".contains($0) } ?? true)

        if insertingInsideSentence, let last = output.last, ".?!".contains(last) {
            output.removeLast()
        }
        if !hasSelection,
           let previous = prefixTrimmed.last,
           ".?!".contains(previous),
           let first = output.first,
           first.isLowercase {
            uppercaseFirstLetter(&output)
        }
        return output
    }

    private static func isLikelySignoff(_ text: String) -> Bool {
        let normalized = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".?!,;:"))
            .lowercased()
        return [
            "best", "thanks", "thank you", "regards", "kind regards",
            "best regards", "sincerely", "cheers", "warmly", "talk soon"
        ].contains(normalized)
    }

    private static func startsWithSignatureBlock(_ suffix: String) -> Bool {
        let leadingNewlineCount = suffix.prefix { $0 == "\n" || $0 == "\r" }.count
        guard leadingNewlineCount > 0 else { return false }
        let lines = suffix
            .split(whereSeparator: \.isNewline)
            .prefix(4)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard let first = lines.first else { return false }
        let wordCount = first.split(separator: " ").count
        return wordCount <= 4 && first.first?.isUppercase == true
    }

    private static func lowercaseFirstLetter(_ text: inout String) {
        guard let index = text.firstIndex(where: { $0.isLetter }) else { return }
        text.replaceSubrange(index...index, with: String(text[index]).lowercased())
    }

    private static func uppercaseFirstLetter(_ text: inout String) {
        guard let index = text.firstIndex(where: { $0.isLetter }) else { return }
        text.replaceSubrange(index...index, with: String(text[index]).uppercased())
    }
}
