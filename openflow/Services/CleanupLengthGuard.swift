import Foundation

/// Remote cleanup occasionally expands a short utterance into an essay or
/// collapses a long one to nothing. When the cleaned text lands far outside
/// the raw length -- and the raw transcript carries no self-correction cue
/// that could explain a real rewrite -- fall back to deterministic cleanup.
enum CleanupLengthGuard {
    /// `allowsExpansion` is set for styles that intentionally turn a short
    /// utterance into a longer document (email letters, custom styles); the
    /// truncation check still applies to them.
    static func passes(cleaned: String, raw: String, allowsExpansion: Bool = false) -> Bool {
        let rawWords = wordCount(raw)
        let cleanedWords = wordCount(cleaned)
        if !allowsExpansion, Double(cleanedWords) > Double(rawWords) * 1.5 + 8 { return false }
        if Double(cleanedWords) < Double(rawWords) * 0.5, !hasSelfCorrectionCue(raw) {
            return false
        }
        return true
    }

    static func hasSelfCorrectionCue(_ text: String) -> Bool {
        let normalized = text.lowercased()
        return selfCorrectionMarkers.contains(where: normalized.contains)
    }

    static let selfCorrectionMarkers = [
        "scratch that", "strike that", "delete that", "ignore that",
        "actually make that", "make that", "change that to",
        "i mean", "no, use", "no use"
    ]

    private static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }
}
