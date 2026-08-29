import Foundation

/// Applies spoken self-corrections locally so they still work when remote cleanup is skipped.
enum SelfCorrectionFormatter {
    static func apply(to input: String) -> String {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return text }

        if let reset = textAfterLastHardReset(in: text) {
            text = reset
        }

        text = applyMakeThatCorrection(to: text)
        text = applyUseCorrection(to: text)
        text = applyIMeanCorrection(to: text)
        text = applyRatherInsteadCorrection(to: text)
        text = applyBareActuallyCorrection(to: text)
        text = removeRestartFillers(from: text)
        return collapseWhitespace(text).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func textAfterLastHardReset(in text: String) -> String? {
        let markers = ["scratch that", "strike that", "delete that", "ignore that", "cancel that", "start over"]
        guard let range = lastMarker(in: text, markers: markers) else { return nil }
        let suffix = cleanedFragment(String(text[range.upperBound...]))
        return suffix.isEmpty ? nil : suffix
    }

    private static func applyMakeThatCorrection(to text: String) -> String {
        let patterns = [
            #"actually\s*,\s*change\s+that\s+to"#,
            #"actually\s+change\s+that\s+to"#,
            #"change\s+that\s+to"#,
            #"actually\s*,\s*make\s+that"#,
            #"actually\s+make\s+that"#,
            #"make\s+that"#,
            #"(?:,|\.)\s*(?:actually\s*,\s*)?make\s+it"#
        ]
        guard let match = lastRegex(in: text, patterns: patterns) else { return text }
        let matched = String(text[match])
        let prefix = cleanedFragment(String(text[..<match.lowerBound]))
        let replacement = cleanedFragment(String(text[match.upperBound...]))
        guard !prefix.isEmpty, !replacement.isEmpty else { return text }
        if !isAnchoredRevision(matched), wordCount(prefix) < 3 {
            return text
        }
        return replaceEditableTail(of: prefix, with: replacement)
    }

    private static func applyUseCorrection(to text: String) -> String {
        let markers = [" no use ", ", no use ", ". no use ", " no, use ", ", no, use ", ". no, use "]
        guard let match = lastMarker(in: text, markers: markers) else { return text }
        let prefix = cleanedFragment(String(text[..<match.lowerBound]))
        let replacement = cleanedFragment(String(text[match.upperBound...]))
        guard !prefix.isEmpty, !replacement.isEmpty else { return text }
        if let useRange = prefix.range(of: " use ", options: [.caseInsensitive, .backwards]) {
            return String(prefix[..<useRange.upperBound]) + replacement
        }
        return replaceEditableTail(of: prefix, with: replacement)
    }

    private static func applyIMeanCorrection(to text: String) -> String {
        guard let match = lastRegex(in: text, patterns: [#"\bI\s+mean\b"#]) else { return text }
        if match.lowerBound == text.startIndex {
            return text
        }
        let prefix = cleanedFragment(String(text[..<match.lowerBound]))
        let replacement = cleanedFragment(String(text[match.upperBound...]))
        guard !prefix.isEmpty, !replacement.isEmpty, wordCount(replacement) <= 6 else { return text }
        return replaceEditableTail(of: prefix, with: replacement)
    }

    private static func applyRatherInsteadCorrection(to text: String) -> String {
        guard let match = lastRegex(in: text, patterns: [#"\b(?:rather|instead)\b"#]) else { return text }
        let matched = String(text[match]).lowercased()
        let prefix = cleanedFragment(String(text[..<match.lowerBound]))
        let remainder = String(text[match.upperBound...])
        if matched == "rather", remainder.lowercased().trimmingCharacters(in: .whitespaces).hasPrefix("than") {
            return text
        }
        if matched == "instead", remainder.lowercased().trimmingCharacters(in: .whitespaces).hasPrefix("of") {
            return text
        }
        let replacement = cleanedFragment(remainder)
        guard !prefix.isEmpty, !replacement.isEmpty, wordCount(replacement) <= 6 else { return text }
        if isAdverbialLeader(lastWord(prefix)) { return text }
        return replaceEditableTail(of: prefix, with: replacement)
    }

    private static func applyBareActuallyCorrection(to text: String) -> String {
        guard let match = lastRegex(in: text, patterns: [#"\bactually\b"#]) else { return text }
        let prefix = String(text[..<match.lowerBound])
        let remainder = String(text[match.upperBound...])
        if remainder.lowercased().contains("make that") || remainder.lowercased().contains("change that") {
            return text
        }
        let replacement = cleanedFragment(remainder)
        guard !replacement.isEmpty, wordCount(replacement) <= 4 else { return text }
        if isAdverbialLeader(lastWord(prefix)) { return text }
        let trimmedPrefix = cleanedFragment(prefix)
        guard !trimmedPrefix.isEmpty else { return text }
        return replaceEditableTail(of: trimmedPrefix, with: replacement)
    }

    private static func removeRestartFillers(from text: String) -> String {
        var result = text
        let replacements: [(String, String)] = [
            (#"\blet me say that again\s*"#, ""),
            (#"\bI messed that up\s*"#, "")
        ]
        for (pattern, replacement) in replacements {
            result = regexReplace(result, pattern: pattern, replacement: replacement)
        }
        return result
    }

    private static func replaceEditableTail(of prefix: String, with replacement: String) -> String {
        let trimmedPrefix = prefix.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",.;:")))
        let anchors = [" at ", " by ", " around ", " about ", " for ", " to ", " on ", " in "]
        for anchor in anchors {
            guard let range = trimmedPrefix.range(of: anchor, options: [.caseInsensitive, .backwards]) else { continue }
            let tail = trimmedPrefix[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            if !tail.isEmpty, tail.count <= 36 {
                return String(trimmedPrefix[..<range.upperBound]) + replacement
            }
        }

        var end = trimmedPrefix.endIndex
        while end > trimmedPrefix.startIndex {
            let previous = trimmedPrefix.index(before: end)
            if !trimmedPrefix[previous].isMember(of: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",.;:"))) { break }
            end = previous
        }

        var start = end
        while start > trimmedPrefix.startIndex {
            let previous = trimmedPrefix.index(before: start)
            if trimmedPrefix[previous].isMember(of: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)) { break }
            start = previous
        }

        return String(trimmedPrefix[..<start]) + replacement
    }

    private static func isAnchoredRevision(_ matched: String) -> Bool {
        let lowered = matched.lowercased()
        return lowered.contains("actually") || lowered.contains(",") || lowered.contains(".")
    }

    private static func isAdverbialLeader(_ word: String) -> Bool {
        let leaders: Set<String> = [
            "i", "i'm", "im", "i'll", "ill", "i'd", "id", "i've", "ive",
            "we", "we're", "we'll", "we'd", "we've",
            "you", "you're", "you'll", "you'd",
            "they", "they'd", "they'll", "he", "she", "it",
            "that's", "thats", "it's", "its", "there's", "theres",
            "is", "was", "are", "were", "be", "been", "being",
            "do", "does", "did", "can", "could", "would", "should", "will",
            "really", "so", "not", "very", "pretty"
        ]
        return leaders.contains(word.lowercased().trimmingCharacters(in: .punctuationCharacters))
    }

    private static func lastWord(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).last.map(String.init) ?? ""
    }

    private static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace }).count
    }

    private static func preferredRange(_ current: Range<String.Index>?, _ candidate: Range<String.Index>) -> Range<String.Index> {
        guard let current else { return candidate }
        if candidate.lowerBound >= current.lowerBound && candidate.lowerBound < current.upperBound {
            return current
        }
        if current.lowerBound >= candidate.lowerBound && current.lowerBound < candidate.upperBound {
            return candidate.lowerBound <= current.lowerBound ? candidate : current
        }
        return candidate.lowerBound >= current.lowerBound ? candidate : current
    }

    private static func lastMarker(in text: String, markers: [String]) -> Range<String.Index>? {
        var best: Range<String.Index>?
        for marker in markers {
            if let range = text.range(of: marker, options: [.caseInsensitive, .backwards]) {
                if best == nil || range.lowerBound > best!.lowerBound {
                    best = range
                }
            }
        }
        return best
    }

    private static func lastRegex(in text: String, patterns: [String]) -> Range<String.Index>? {
        var best: Range<String.Index>?
        let full = NSRange(text.startIndex..<text.endIndex, in: text)
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let matches = regex.matches(in: text, options: [], range: full)
            guard let match = matches.last, let range = Range(match.range, in: text) else { continue }
            best = preferredRange(best, range)
        }
        return best
    }

    private static func cleanedFragment(_ text: String) -> String {
        text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",.;:")))
    }

    private static func collapseWhitespace(_ text: String) -> String {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false)
        return lines
            .map { regexReplace(String($0), pattern: #" {2,}"#, replacement: " ").trimmingCharacters(in: .whitespaces) }
            .joined(separator: "\n")
    }

    private static func regexReplace(_ text: String, pattern: String, replacement: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: replacement)
    }
}

private extension Character {
    func isMember(of set: CharacterSet) -> Bool {
        unicodeScalars.allSatisfy { set.contains($0) }
    }
}
