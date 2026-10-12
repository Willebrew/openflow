import Foundation

/// Where a finished transcription goes next.
enum VoiceAgentRoute: String {
    case dictate
    case voiceAgent
}

/// Pure routing policy between normal dictation and the Jev voice agent.
/// Kept free of AX/AppKit so the decision is unit-testable on its own.
enum VoiceAgentRouting {
    /// Dictate unless the end-of-dictation probe is *confident* there is no
    /// text field. Any inconclusive probe result -- AX error, timeout, missing
    /// focused element, generic role -- routes to normal dictation so a spoken
    /// transcript is never fed to the agent by mistake.
    static func decide(voiceAgentEnabled: Bool,
                       probeAtStart: FocusProbeVerdict?,
                       probeAtEnd: FocusProbeVerdict) -> VoiceAgentRoute {
        guard voiceAgentEnabled else { return .dictate }
        if probeAtStart == .textInput { return .dictate }
        return probeAtEnd == .noTextInput ? .voiceAgent : .dictate
    }

    /// A run that aborted, failed, or took zero actions never consumed the
    /// instruction, so the transcript must be recovered through the normal
    /// dictation insertion path rather than dropped.
    static func needsTranscriptRecovery(completed: Bool, steps: Int) -> Bool {
        !completed || steps <= 0
    }
}
