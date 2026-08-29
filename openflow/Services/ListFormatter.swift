import Foundation

/// Turns spoken list dictation into markdown lines that paste as lists in Notion and other notes apps.
enum ListFormatter {
    static func apply(_ input: String, context: FormattingContext) -> String {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return input }
        if context.category == .terminal || context.stylePreset == .rawTranscript {
            return text
        }
        if looksLikeExistingList(text) {
            return tidyExistingList(text)
        }

        if let explicit = convertExplicitList(text) {
            return explicit
        }
        if let numbered = convertSpokenNumberedList(text) {
            return numbered
        }
        if shouldUseNotesListStyle(context) {
            if let ordinal = convertOrdinalList(text) {
                return ordinal
            }
            if let colonList = convertColonList(text) {
                return colonList
            }
        }
        return text
    }

    static func shouldUseNotesListStyle(_ context: FormattingContext) -> Bool {
        if context.category == .docs { return true }
        let haystack = "\(context.activeAppName) \(context.bundleID) \(context.browserURL ?? "")".lowercased()
        return haystack.contains("notion")
            || haystack.contains("docs.google")
            || haystack.contains("notes")
    }

    private static func convertExplicitList(_ text: String) -> String? {
        let dashCount = matchCount(text, pattern: #"\b(?:dash|hyphen)\b"#)
        var working = text
        if dashCount >= 2 {
            working = regexReplace(working, pattern: #"\b(?:dash|hyphen)\b"#, replacement: sentinel)
        }
        working = regexReplace(
            working,
            pattern: #"\b(?:bullet(?:\s+points?)?|asterisk|(?:next|new)\s+item|next\s+line)\b"#,
            replacement: sentinel
        )
        let parts = splitSentinel(working)
        guard parts.items.count >= 2 || (parts.items.count == 1 && hasSingleBulletMarker(text)) else {
            return nil
        }
        var intro = parts.intro
        var items = parts.items
        if items.count == 1, let firstItem = intro, !firstItem.isEmpty {
            items = [firstItem] + items
            intro = nil
        }
        return render(intro: intro, items: items, numbered: false)
    }

    private static func convertSpokenNumberedList(_ text: String) -> String? {
        let pattern = #"\bnumber\s+(?:one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|\d+)\b"#
        guard matchCount(text, pattern: pattern) >= 2 else { return nil }
        let working = regexReplace(text, pattern: pattern, replacement: sentinel)
        let parts = splitSentinel(working)
        guard parts.items.count >= 2 else { return nil }
        return render(intro: parts.intro, items: parts.items, numbered: true)
    }

    private static func convertOrdinalList(_ text: String) -> String? {
        if regexHasMatch(text, pattern: #"\b(?:first|second|third)\s+(?:time|times|glance|place|day|week|month|year|thought|thoughts|guess|guessing|nature|class|person|half|impression)\b"#) {
            return nil
        }
        let pattern = #"\b(?:firstly|secondly|thirdly|fourthly|first|second|third|fourth|fifth|sixth|seventh|eighth|ninth|tenth)\b"#
        guard matchCount(text, pattern: pattern) >= 2 else { return nil }
        let working = regexReplace(text, pattern: pattern, replacement: sentinel)
        let parts = splitSentinel(working)
        guard parts.items.count >= 2 else { return nil }
        return render(intro: parts.intro, items: parts.items, numbered: true)
    }

    private static func convertColonList(_ text: String) -> String? {
        guard let colon = text.range(of: ":") else { return nil }
        let intro = String(text[..<colon.upperBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        let remainder = String(text[colon.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !remainder.isEmpty else { return nil }
        let introLooksLikeList = regexHasMatch(
            intro,
            pattern: #"\b(?:list|items?|todos?|bullets?|points?|agenda|following|these|steps?)\s*:$"#
        )
        let items: [String]
        if remainder.contains(",") {
            items = remainder
                .split(separator: ",", omittingEmptySubsequences: true)
                .map { stripLeadingAnd(String($0)) }
                .filter { !$0.isEmpty }
        } else if matchCount(remainder, pattern: #"\sand\s"#) >= 2 {
            items = remainder
                .components(separatedBy: " and ")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        } else {
            return nil
        }
        guard items.count >= 2, items.allSatisfy({ wordCount($0) <= 8 }) else { return nil }
        if !introLooksLikeList, items.count < 3, items.contains(where: { wordCount($0) > 5 }) {
            return nil
        }
        return render(intro: intro, items: items, numbered: false)
    }

    private static func hasSingleBulletMarker(_ text: String) -> Bool {
        regexHasMatch(text, pattern: #"\b(?:bullet(?:\s+points?)?|asterisk|(?:next|new)\s+item)\b"#)
    }

    private static func looksLikeExistingList(_ text: String) -> Bool {
        let lines = text.split(whereSeparator: \.isNewline)
        let marked = lines.filter { line in
            regexHasMatch(String(line), pattern: #"^\s*(?:[-*•]|\d+\.)\s+\S"#)
        }
        return marked.count >= 2 || (marked.count == 1 && lines.count == 1)
    }

    private static func tidyExistingList(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in
                regexReplace(String(line), pattern: #"^\s*[-*•]\s+"#, replacement: "- ")
            }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func render(intro: String?, items: [String], numbered: Bool) -> String {
        var lines: [String] = []
        if let intro, !intro.isEmpty {
            lines.append(trimListIntro(intro))
        }
        for (index, item) in items.enumerated() {
            let cleaned = capitalizeItem(item.trimmingCharacters(in: .whitespacesAndNewlines))
            guard !cleaned.isEmpty else { continue }
            if numbered {
                lines.append("\(index + 1). \(cleaned)")
            } else {
                lines.append("- \(cleaned)")
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func splitSentinel(_ text: String) -> (intro: String?, items: [String]) {
        let chunks = text
            .components(separatedBy: sentinel)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let first = chunks.first else { return (nil, []) }
        if chunks.count == 1 {
            return (nil, first.isEmpty ? [] : [first])
        }
        let rest = Array(chunks.dropFirst()).filter { !$0.isEmpty }
        if first.isEmpty {
            return (nil, rest)
        }
        if regexHasMatch(first, pattern: #"^(?:new\s+line|new\s+paragraph|next\s+line)$"#) {
            return (nil, rest)
        }
        if shouldTreatAsIntro(first, items: rest) {
            return (first, rest)
        }
        return (nil, [first] + rest)
    }

    private static func shouldTreatAsIntro(_ first: String, items: [String]) -> Bool {
        if first.hasSuffix(":") { return true }
        if regexHasMatch(first, pattern: #"\b(?:need|needed|following|list|agenda|items?|todos?|steps?)\b"#) {
            return true
        }
        if items.count == 1 && wordCount(first) <= 8 {
            return false
        }
        let typical = items.map(wordCount).max() ?? 0
        return wordCount(first) > max(8, typical + 4)
    }

    private static func trimListIntro(_ intro: String) -> String {
        var result = intro.trimmingCharacters(in: .whitespacesAndNewlines)
        while result.hasSuffix(",") || result.hasSuffix(";") {
            result = String(result.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return result
    }

    private static func stripLeadingAnd(_ text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.lowercased().hasPrefix("and ") {
            result = String(result.dropFirst(4)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return result
    }

    private static func capitalizeItem(_ item: String) -> String {
        guard let first = item.first else { return item }
        guard first.isLetter else { return item }
        return String(first).uppercased() + item.dropFirst()
    }

    private static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace }).count
    }

    private static func matchCount(_ text: String, pattern: String) -> Int {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return 0 }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.numberOfMatches(in: text, options: [], range: range)
    }

    private static func regexHasMatch(_ text: String, pattern: String) -> Bool {
        matchCount(text, pattern: pattern) > 0
    }

    private static func regexReplace(_ text: String, pattern: String, replacement: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: replacement)
    }

    private static let sentinel = "\u{1E}"
}
