import Foundation

@main
struct CheckProviderRouting {
    static func main() {
        assertEqual(
            OpenFlowProviderRouting.usesCloudTranscription(providerMode: .openflowCloud, hasLocalGroqKey: true),
            false,
            "BYO key must skip transcribe-fast even if Pro is selected"
        )
        assertEqual(
            OpenFlowProviderRouting.usesCloudTranscription(providerMode: .automatic, hasLocalGroqKey: true),
            false,
            "BYO key must skip cloud on automatic"
        )
        assertEqual(
            OpenFlowProviderRouting.usesCloudTranscription(providerMode: .localGroq, hasLocalGroqKey: true),
            false,
            "localGroq stays on the Mac"
        )
        assertEqual(
            OpenFlowProviderRouting.usesCloudTranscription(providerMode: .openflowCloud, hasLocalGroqKey: false),
            true,
            "Pro without a key uses cloud"
        )
        assertEqual(
            OpenFlowProviderRouting.usesCloudTranscription(providerMode: .automatic, hasLocalGroqKey: false),
            true,
            "automatic without a key uses cloud"
        )
        assertEqual(
            OpenFlowProviderRouting.usesCloudTranscription(providerMode: .localGroq, hasLocalGroqKey: false),
            false,
            "localGroq without a key still does not call transcribe-fast"
        )
        assertEqual(
            OpenFlowProviderRouting.groqChatModelID("gpt-oss-20b"),
            "openai/gpt-oss-20b",
            "BYO cleanup uses Groq chat model IDs"
        )
        assertEqual(
            OpenFlowProviderRouting.groqChatModelID("openai/gpt-oss-20b"),
            "openai/gpt-oss-20b",
            "already-prefixed Groq IDs stay"
        )
        assertEqual(
            OpenFlowProviderRouting.canGenerateStyleWithOpenflow(hasLocalGroqKey: false, cloudTier: "free"),
            false,
            "Free cloud must not spend the server Groq credential on generate"
        )
        assertEqual(
            OpenFlowProviderRouting.canGenerateStyleWithOpenflow(hasLocalGroqKey: false, cloudTier: "pro"),
            true,
            "Pro cloud can generate with the server key"
        )
        assertEqual(
            OpenFlowProviderRouting.canGenerateStyleWithOpenflow(hasLocalGroqKey: true, cloudTier: "free"),
            true,
            "BYO Groq can generate on any plan"
        )
        assertEqual(
            OpenFlowProviderRouting.canGenerateStyleWithOpenflow(hasLocalGroqKey: true, cloudTier: nil),
            true,
            "BYO Groq can generate without a cloud tier"
        )
        print("provider routing check passed")
    }

    private static func assertEqual<T: Equatable>(_ actual: T, _ expected: T, _ label: String) {
        if actual != expected {
            fail("\(label) expected \(expected), got \(actual)")
        }
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("provider routing check failed: \(message)\n".utf8))
        exit(1)
    }
}
