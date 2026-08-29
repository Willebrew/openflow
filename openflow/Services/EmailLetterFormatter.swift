import Foundation

/// Turns spoken mail dictation into a short letter with blank lines.
enum EmailLetterFormatter {
    static func apply(_ raw: String,
                      signOffName: String,
                      textBefore: String? = nil,
                      textAfter: String? = nil,
                      nearbyText: String? = nil,
                      spokenTranscript: String? = nil) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return raw }
        text = text.replacingOccurrences(of: "\r\n", with: "\n")
        text = fixDeadGreeting(text)
        let surrounding = surroundingField(textBefore: textBefore, textAfter: textAfter, nearbyText: nearbyText)
        if fieldAlreadyStarted(surrounding) {
            return stripContinuationTemplates(from: text,
                                              existingField: surrounding,
                                              rawTranscript: spokenTranscript ?? raw,
                                              signOffName: signOffName)
        }

        let greeting = matchGreeting(in: text)
        guard greeting != nil || matchSignOff(in: text) != nil else { return text }

        var body = text
        var greetingLine: String?
        if let greeting {
            greetingLine = "\(greeting.salutation) \(greeting.name),"
            body = String(text[greeting.end...])
        }

        var closingWord: String?
        var spokenName: String?
        if let signOff = matchSignOff(in: body) {
            closingWord = signOff.phrase
            spokenName = signOff.name
            body = String(body[..<signOff.start])
        }
        body = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.hasPrefix(",") {
            body = String(body.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var lines: [String] = []
        if let greetingLine {
            lines.append(greetingLine)
            lines.append("")
        }
        if !body.isEmpty {
            lines.append(capitalizeFirst(body))
        }
        if let closingWord {
            if !body.isEmpty || greetingLine != nil {
                lines.append("")
            }
            lines.append("\(closingWord),")
            let name = firstNonEmpty(spokenName, signOffName)
            if let name {
                lines.append(name)
            }
        }
        return lines.joined(separator: "\n")
    }

    static func surroundingField(textBefore: String?, textAfter: String?, nearbyText: String?) -> String {
        let before = textBefore ?? ""
        let after = textAfter ?? ""
        if !before.isEmpty || !after.isEmpty {
            return before + after
        }
        return nearbyText ?? ""
    }

    static func fieldAlreadyStarted(_ surrounding: String) -> Bool {
        !surrounding.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func stripContinuationTemplates(from raw: String,
                                           existingField: String,
                                           rawTranscript: String,
                                           signOffName: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        text = text.replacingOccurrences(of: "\r\n", with: "\n")
        text = stripLeadingTemplateGreeting(from: text, existingField: existingField)
        text = stripTrailingPlaceholderSignOff(from: text)
        if !spokenClosing(in: rawTranscript) {
            text = stripTrailingTemplateSignOff(from: text, signOffName: signOffName)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stripLeadingTemplateGreeting(from text: String, existingField: String) -> String {
        let placeholder = try? NSRegularExpression(
            pattern: "^(dear|hi|hello|hey)\\s+(\\[recipient\\]|recipient)\\s*,\\s*",
            options: [.caseInsensitive]
        )
        var result = text
        if let placeholder {
            let ns = NSRange(result.startIndex..<result.endIndex, in: result)
            result = placeholder.stringByReplacingMatches(in: result, options: [], range: ns, withTemplate: "")
        }
        if existingFieldHasGreeting(existingField),
           let greeting = matchGreeting(in: result) {
            result = String(result[greeting.end...])
            if result.hasPrefix(",") {
                result = String(result.dropFirst())
            }
            result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return result
    }

    private static func existingFieldHasGreeting(_ field: String) -> Bool {
        let trimmed = field.trimmingCharacters(in: .whitespacesAndNewlines)
        if matchGreeting(in: trimmed) != nil { return true }
        let firstLine = trimmed.split(whereSeparator: \.isNewline).first.map(String.init) ?? trimmed
        return firstLine.hasSuffix(",") && firstLine.split(separator: " ").count <= 4
    }

    private static func stripTrailingPlaceholderSignOff(from text: String) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: "\\n*(thanks|thank you|best regards|kind regards|take care|sincerely|cheers|regards|best)\\s*,\\s*(\\[your name\\]|your name)\\s*$",
            options: [.caseInsensitive]
        ) else { return text }
        let ns = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: ns, withTemplate: "")
    }

    private static func stripTrailingTemplateSignOff(from text: String, signOffName: String) -> String {
        let escapedName = NSRegularExpression.escapedPattern(for: signOffName.trimmingCharacters(in: .whitespacesAndNewlines))
        let namePattern = escapedName.isEmpty
            ? "\\[your name\\]|your name"
            : "\\[your name\\]|your name|\(escapedName)"
        guard let regex = try? NSRegularExpression(
            pattern: "\\n*(thanks|thank you|best regards|kind regards|take care|sincerely|cheers|regards|best)\\s*,\\s*(\(namePattern))?\\s*$",
            options: [.caseInsensitive]
        ) else { return text }
        let ns = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: ns, withTemplate: "")
    }

    private static func spokenClosing(in rawTranscript: String) -> Bool {
        let lowered = rawTranscript.lowercased()
        return ["thanks", "thank you", "best regards", "kind regards", "take care", "sincerely"].contains {
            lowered.contains($0)
        }
    }

    private static func fixDeadGreeting(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "^(dead|deer)\\b", options: .caseInsensitive) else {
            return text
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "Dear")
    }

    private static func matchGreeting(in text: String) -> (salutation: String, name: String, end: String.Index)? {
        guard let regex = try? NSRegularExpression(
            pattern: "^(dear|hi|hello|hey)\\s+([A-Za-z][A-Za-z .'-]{0,40}?)(?=,|\\s+|$)",
            options: .caseInsensitive
        ) else { return nil }
        let ns = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: ns),
              let salRange = Range(match.range(at: 1), in: text),
              let nameRange = Range(match.range(at: 2), in: text),
              let end = Range(match.range, in: text)?.upperBound else { return nil }
        let salutation = capitalizeFirst(String(text[salRange]))
        let name = String(text[nameRange]).trimmingCharacters(in: .whitespaces)
        let blocked = ["i", "i'm", "im", "we", "just", "hope", "wanted", "thanks", "thank"]
        guard !name.isEmpty, !blocked.contains(name.lowercased()) else { return nil }
        return (salutation, name, end)
    }

    private static func matchSignOff(in text: String) -> (phrase: String, name: String?, start: String.Index)? {
        guard let regex = try? NSRegularExpression(
            pattern: "(thank you|thanks|best regards|kind regards|take care|sincerely|cheers|regards|best)\\s*,?\\s*([A-Za-z][A-Za-z .'-]{0,40})?\\s*$",
            options: .caseInsensitive
        ) else { return nil }
        let ns = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: ns),
              let phraseRange = Range(match.range(at: 1), in: text),
              let start = Range(match.range, in: text)?.lowerBound else { return nil }
        let phrase = canonicalClosing(String(text[phraseRange]))
        var name: String?
        if match.range(at: 2).location != NSNotFound,
           let nameRange = Range(match.range(at: 2), in: text) {
            let spoken = String(text[nameRange]).trimmingCharacters(in: .whitespaces)
            if !spoken.isEmpty, spoken.lowercased() != "you" { name = spoken }
        }
        return (phrase, name, start)
    }

    private static func canonicalClosing(_ raw: String) -> String {
        switch raw.lowercased() {
        case "thank you": return "Thank you"
        case "best regards": return "Best regards"
        case "kind regards": return "Kind regards"
        case "take care": return "Take care"
        default: return capitalizeFirst(raw)
        }
    }

    private static func capitalizeFirst(_ text: String) -> String {
        guard let first = text.first else { return text }
        return String(first).uppercased() + text.dropFirst()
    }

    private static func firstNonEmpty(_ values: String?...) -> String? {
        values
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }
}