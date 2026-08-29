import Foundation
import ApplicationServices

enum DictationMode: String, Codable {
    case dictation
}

enum PillState: Equatable {
    case idle
    case recording
    case processing
    case success
    case resultClearing
    case error(String)
}

enum InsertionMethod: String, Codable {
    case capturedAX
    case focusedAX
    case descendantAX
    case nativeKeyEvents
    case unicodeKeyEvents
    case systemEvents
    case none
}

struct InsertionResult: Codable {
    var succeeded: Bool
    var verified: Bool
    var method: InsertionMethod
    var attemptCount: Int
    var failureReason: String?
    var targetApp: String
    var targetBundleID: String?

    static func failed(reason: String,
                       attemptCount: Int,
                       targetApp: String,
                       targetBundleID: String?) -> InsertionResult {
        InsertionResult(succeeded: false,
                        verified: false,
                        method: .none,
                        attemptCount: attemptCount,
                        failureReason: reason,
                        targetApp: targetApp,
                        targetBundleID: targetBundleID)
    }
}

enum AppCategory: String, Codable, CaseIterable {
    case messages
    case email
    case docs
    case aiChat
    case browserSearch
    case terminal
    case ide
    case projectManagement
    case generic
}

struct FormattingContext: Codable {
    var activeAppName: String
    var bundleID: String
    var category: AppCategory
    var selectedText: String?
    var nearbyText: String?
    var textBefore: String? = nil
    var textAfter: String? = nil
    var browserURL: String?
    var stylePreset: StylePreset
    var customStyleName: String? = nil
    var customStylePrompt: String? = nil

    var usesCustomStyle: Bool {
        guard let customStylePrompt else { return false }
        return !customStylePrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

struct DictationSession {
    let id = UUID()
    var mode: DictationMode
    let startedAt = Date()
    var endedAt: Date?
    var metrics = LatencyMetrics()
    var context: FormattingContext?
    var focusedElement: AXUIElement?
    var focusedWindow: AXUIElement?
    var targetProcessIdentifier: pid_t?
    var targetCanInsertText: Bool = false
    var selectedRange: CFRange?
}

struct TranscriptionResult: Codable {
    var text: String
    var model: String
    var provider: String
    var duration: TimeInterval?
    var requestTime: TimeInterval
    var tTicket: TimeInterval? = nil
    var tReceiveAudio: TimeInterval? = nil
    var tGroqHttp: TimeInterval? = nil
    var tTotal: TimeInterval? = nil
    var macToConvexMs: Int? = nil
    var convexUntilGroqStartMs: Int? = nil
    var groqRoundTripMs: Int? = nil
    var convexToMacMs: Int? = nil
    var cerebrasRoundTripMs: Int? = nil
    var cleanupAuthMs: Int? = nil
    var cleanupApplied: Bool = false
    var cleanedText: String? = nil
    var pressEnter: Bool = false
    var confidence: Double? = nil
    var notes: String? = nil
    var hopBreakdown: String? = nil
}

struct CleanupResult: Codable {
    var text: String
    var pressEnter: Bool
    var confidence: Double
    var notes: String
}

struct DictationHistoryItem: Codable, Identifiable {
    var id = UUID()
    var timestamp: Date
    var finalText: String
    var rawTranscript: String?
    var appName: String
    var bundleID: String? = nil
    var category: AppCategory
    var stylePreset: StylePreset? = nil
    var insertionSucceeded: Bool
    var insertion: InsertionResult? = nil
    var metrics: LatencyMetrics

    var displayText: String {
        Self.consumerFacingText(finalText)
    }

    static func consumerFacingText(_ text: String) -> String {
        let lowercased = text.lowercased()
        if lowercased.contains("subscription_required") {
            return "Choose openflow Free, openflow Pro, or add your Groq key in Settings."
        }
        if lowercased.contains("subscription_requires_portal") {
            return "Your openflow Pro subscription needs attention. Open Manage Plan to review it in Stripe."
        }
        if lowercased.contains("checkout_unavailable") || lowercased.contains("stripe_not_configured") {
            return "Checkout is temporarily unavailable. Please try again shortly."
        }
        if lowercased.contains("free_limit_reached") {
            return "You have used this month’s free words. Upgrade to openflow Pro to keep dictating."
        }
        if lowercased.contains("{\"error\"") || lowercased.contains("\"status\":") {
            return "openflow could not complete this dictation. Check your plan in Settings and try again."
        }
        return text
    }
}

struct LatencyMetrics: Codable {
    var hotkeyToRecordingStart: TimeInterval = 0
    var audioDuration: TimeInterval = 0
    var encodingTime: TimeInterval = 0
    var uploadAndTranscriptionTime: TimeInterval = 0
    var cleanupTime: TimeInterval = 0
    var insertionTime: TimeInterval = 0
    var totalTime: TimeInterval = 0
    var provider: String = "groq"
    var model: String = "whisper-large-v3-turbo"
    var activeApp: String = ""
    var category: AppCategory = .generic
    var contextAvailable: Bool = false
    var insertionMethod: String? = nil
    var insertionVerified: Bool? = nil
    var insertionAttempts: Int? = nil
    var insertionFailureReason: String? = nil
    var focusRaceDetected: Bool? = nil
    var focusRaceDescription: String? = nil
    var macToConvexMs: Int? = nil
    var convexUntilGroqStartMs: Int? = nil
    var groqRoundTripMs: Int? = nil
    var convexToMacMs: Int? = nil
    var cerebrasRoundTripMs: Int? = nil
    var cleanupAuthMs: Int? = nil
    var transcribeHopBreakdown: String? = nil
}

enum OpenflowError: LocalizedError {
    case missingAPIKey
    case microphoneUnavailable
    case microphoneInputFailed(String)
    case noAudioCaptured
    case transcriptionFailed(String)
    case cleanupFailed(String)
    case insertionFailed
    case cloudAuthenticationRequired
    case cloudSessionRevoked
    case cloudSubscriptionAlreadyActive
    case cloudProviderUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey: "Add your Groq API key in Settings."
        case .microphoneUnavailable: "Microphone is unavailable."
        case .microphoneInputFailed(let message): message
        case .noAudioCaptured: "No speech captured."
        case .transcriptionFailed(let message): "Transcription failed: \(message)"
        case .cleanupFailed(let message): "Cleanup failed: \(message)"
        case .insertionFailed: "Could not insert text."
        case .cloudAuthenticationRequired: "Sign in to continue."
        case .cloudSessionRevoked: CloudSessionValidator.revokedUserMessage
        case .cloudSubscriptionAlreadyActive: "openflow Pro is already active."
        case .cloudProviderUnavailable(let message): message
        }
    }

    var isCloudSessionRevoked: Bool {
        if case .cloudSessionRevoked = self { return true }
        return false
    }
}
