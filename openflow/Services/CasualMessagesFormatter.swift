import Foundation

/// Casual messages (Messages, Slack DMs) should read like a text, not an
/// email: a single-sentence reply drops its trailing period. Only the
/// built-in casual preset is touched -- user-chosen custom styles stay
/// authoritative.
enum CasualMessagesFormatter {
    static func apply(_ text: String, context: FormattingContext) -> String {
        guard context.category == .messages,
              context.stylePreset == .casual,
              !context.usesCustomStyle else { return text }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 1,
              trimmed.hasSuffix("."),
              let dotIndex = text.lastIndex(of: ".") else { return text }
        // Only a single sentence loses its period; abbreviations and
        // multi-sentence replies keep their punctuation.
        let body = trimmed.dropLast()
        guard !body.contains(where: { ".!?".contains($0) }) else { return text }
        var result = text
        result.remove(at: dotIndex)
        return result
    }
}
