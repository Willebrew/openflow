import Foundation

enum PressEnterCommand {
    struct Resolution {
        var text: String
        var pressEnter: Bool
    }

    private static let commandCore = #"(?:please\s+)?(?:press|hit)\s+(?:the\s+)?(?:enter|return)(?:\s+key)?"#

    /// Submit intent comes from the spoken transcript only. Cleanup output is remote,
    /// prompt-injectable text, so a submit phrase that appears only there is stripped from the
    /// insertion but never turned into a Return keypress.
    static func resolve(rawTranscript: String, cleanedText: String, enabled: Bool) -> Resolution {
        guard enabled else {
            return Resolution(text: cleanedText, pressEnter: false)
        }
        let fromCleaned = extract(from: cleanedText)
        let fromRaw = extract(from: rawTranscript)
        let text = fromCleaned.matched ? fromCleaned.body : cleanedText
        return Resolution(text: text, pressEnter: fromRaw.matched)
    }

    static func extract(from text: String) -> (body: String, matched: Bool) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return (text, false) }
        let nsText = trimmed as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        let options: NSRegularExpression.Options = [.caseInsensitive]
        guard let whole = try? NSRegularExpression(pattern: "^\\s*\(commandCore)\\s*[.!?]*\\s*$", options: options) else {
            return (text, false)
        }
        if whole.firstMatch(in: trimmed, options: [], range: fullRange) != nil {
            return ("", true)
        }
        guard let trailing = try? NSRegularExpression(
            pattern: "^(.*?)\\s+(\(commandCore))\\s*[.!?]*\\s*$",
            options: options.union(.dotMatchesLineSeparators)
        ) else {
            return (text, false)
        }
        guard let match = trailing.firstMatch(in: trimmed, options: [], range: fullRange),
              match.numberOfRanges >= 2 else {
            return (text, false)
        }
        let bodyRange = match.range(at: 1)
        guard bodyRange.location != NSNotFound else { return (text, false) }
        var body = nsText.substring(with: bodyRange).trimmingCharacters(in: .whitespacesAndNewlines)
        while body.hasSuffix(",") || body.hasSuffix(";") {
            body.removeLast()
            body = body.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if isNegatedPreface(body) {
            return (text, false)
        }
        return (body, true)
    }

    private static func isNegatedPreface(_ body: String) -> Bool {
        let normalized = body
            .lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "‘", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.isEmpty { return true }
        if normalized == "to" || normalized.hasSuffix(" to") { return true }
        if normalized.hasSuffix("don't") || normalized.hasSuffix("dont") { return true }
        if normalized.hasSuffix("never") { return true }
        if normalized == "not" || normalized.hasSuffix(" not") { return true }
        return false
    }
}
