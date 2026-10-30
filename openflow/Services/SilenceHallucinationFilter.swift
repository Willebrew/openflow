import Foundation

/// Whisper pads near-silent clips with stock phrases ("Thank you.",
/// "Thanks for watching", "You", "Bye"). On very short audio those are
/// hallucinations, not speech, so they are dropped before cleanup and
/// insertion instead of landing in the user's field.
enum SilenceHallucinationFilter {
    /// Clips shorter than this cannot plausibly contain the matched phrases.
    static let maximumAudioSeconds: TimeInterval = 1.5

    static func isSilenceHallucination(text: String, audioSeconds: TimeInterval) -> Bool {
        guard audioSeconds < maximumAudioSeconds else { return false }
        return hallucinationPhrases.contains(normalize(text))
    }

    static func normalize(_ text: String) -> String {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static let hallucinationPhrases: Set<String> = [
        "thank you",
        "thanks for watching",
        "you",
        "bye"
    ]
}
