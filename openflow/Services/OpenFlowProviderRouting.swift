import Foundation

enum OpenFlowProviderRouting {
    static let styleGenerateProRequiredMessage =
        "Generate with openflow is included with Pro. You can still write a style yourself."

    /// A stored Groq key always goes Mac → Groq. Pro `transcribe-fast` is only for
    /// accounts that have no BYO key.
    static func usesCloudTranscription(providerMode: ProviderMode, hasLocalGroqKey: Bool) -> Bool {
        guard !hasLocalGroqKey else { return false }
        switch providerMode {
        case .localGroq:
            return false
        case .openflowCloud, .automatic:
            return true
        }
    }

    /// Cloud generate spends the server Groq credential and is Pro-only.
    /// A stored BYO key generates on the Mac for any plan.
    static func canGenerateStyleWithOpenflow(hasLocalGroqKey: Bool, cloudTier: String?) -> Bool {
        hasLocalGroqKey || cloudTier == "pro"
    }

    static func groqChatModelID(_ stored: String) -> String {
        let trimmed = stored.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("openai/") { return trimmed }
        if trimmed.hasPrefix("gpt-oss-") { return "openai/\(trimmed)" }
        return trimmed
    }
}
