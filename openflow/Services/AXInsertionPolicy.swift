import Foundation

/// What to do after an `AXSelectedText` write.
enum AXInsertionDecision: Equatable {
    /// The write is trusted. Do not write the text again.
    case acceptSelectedText
    /// The value is unchanged so far, and the write may still be applying.
    case recheckLater
    /// The write did not land. Replace the whole `AXValue`.
    case replaceWholeValue

    var logName: String {
        switch self {
        case .acceptSelectedText: return "acceptSelectedText"
        case .recheckLater: return "recheckLater"
        case .replaceWholeValue: return "replaceWholeValue"
        }
    }
}

/// Readback of one element after a write. This is not proof the text missed
/// the live field: a captured ancestor can keep a constant value.
enum AXReadbackVerification: Equatable {
    case verified
    case unverified
    case unreadable
}

enum SelectedTextFollowUp: Equatable {
    /// The attribute set succeeded and this element's readback is not authoritative.
    case acceptWithoutProof
    /// Use the readback samples to decide whether `AXValue` must be replaced.
    case judgeByReadback
}

enum AXStrategyFollowUp: Equatable {
    case stop(verified: Bool)
    case nextStrategy(reason: String)
}

struct AXInsertionResolution: Equatable {
    var decision: AXInsertionDecision
    var rereadCount: Int
}

/// Write counts for one captured-element attempt.
struct CapturedInsertionTrace: Equatable {
    var selectedTextWrites: Int
    var wholeValueWrites: Int
    var rereadCount: Int
    var decision: String
    var verify: String
    var startedFallback: Bool
    var fallbackReason: String

    var totalWrites: Int { selectedTextWrites + wholeValueWrites }
}

/// Decides whether a selected-text accessibility write is enough.
///
/// Electron and other Chromium hosts return success for `AXSelectedText`
/// before the field value updates. An immediate readback still equals the
/// previous value, which used to fall through into a second `AXValue`
/// write. Both writes then landed. Native controls that drop the write
/// (SwiftUI search fields) stay unchanged for the whole recheck window,
/// and those still replace `AXValue`.
enum AXInsertionPolicy {
    /// Delayed readbacks after the immediate one. The immediate sample is
    /// index 0 and is not counted here.
    static let maxDelayedSamples = 4

    /// Pause before each delayed readback. Native controls never wait,
    /// because their value changes on the immediate sample.
    static let recheckIntervalNanoseconds: UInt64 = 50_000_000

    /// Chooses the next step from one value sample.
    ///
    /// - Parameters:
    ///   - setSucceeded: Whether setting `AXSelectedText` returned success.
    ///   - valueBefore: Field value before the write. Nil when unreadable.
    ///   - valueAfter: Field value for this sample. Nil when unreadable.
    ///   - sampleIndex: Zero for the immediate readback. Later indexes are
    ///     delayed samples.
    /// - Returns: Accept the write, read again, or replace `AXValue`.
    static func decide(setSucceeded: Bool,
                       valueBefore: String?,
                       valueAfter: String?,
                       sampleIndex: Int) -> AXInsertionDecision {
        guard setSucceeded else { return .replaceWholeValue }
        // An unreadable value is not proof the write was dropped. A second
        // write can duplicate text that did land.
        guard let valueBefore, let valueAfter else { return .acceptSelectedText }
        if valueAfter != valueBefore { return .acceptSelectedText }
        if sampleIndex < maxDelayedSamples { return .recheckLater }
        return .replaceWholeValue
    }

    /// Whether the whole-value write is still required.
    ///
    /// Call this immediately before replacing `AXValue`. A value that
    /// changed, or that can no longer be read, means the selected-text
    /// write may have landed late.
    ///
    /// - Parameters:
    ///   - valueBefore: Field value sampled before `AXSelectedText` was set.
    ///   - valueNow: Field value sampled at the moment of the decision.
    /// - Returns: True only when the field is readable and still unchanged.
    static func shouldReplaceWholeValue(valueBefore: String?,
                                        valueNow: String?) -> Bool {
        decide(setSucceeded: true,
               valueBefore: valueBefore,
               valueAfter: valueNow,
               sampleIndex: maxDelayedSamples) == .replaceWholeValue
    }

    /// Walks the immediate sample and any delayed samples until the write
    /// is trusted or the whole-value replacement is required.
    ///
    /// - Parameters:
    ///   - setSucceeded: Whether setting `AXSelectedText` returned success.
    ///   - valueBefore: Field value before the write. Nil when unreadable.
    ///   - readSample: Supplies the field value for a sample index. Index 0
    ///     is the immediate readback. The closure is not called when the
    ///     attribute set failed.
    /// - Returns: A terminal decision. Never `recheckLater`.
    static func resolve(setSucceeded: Bool,
                        valueBefore: String?,
                        readSample: (Int) async -> String?) async -> AXInsertionDecision {
        await resolveTracing(setSucceeded: setSucceeded,
                             valueBefore: valueBefore,
                             readSample: readSample).decision
    }

    /// Same walk as `resolve`, plus how many delayed samples were read.
    static func resolveTracing(setSucceeded: Bool,
                               valueBefore: String?,
                               readSample: (Int) async -> String?) async -> AXInsertionResolution {
        var sampleIndex = 0
        var rereadCount = 0
        while sampleIndex <= maxDelayedSamples {
            let valueAfter = setSucceeded ? await readSample(sampleIndex) : nil
            let decision = decide(setSucceeded: setSucceeded,
                                  valueBefore: valueBefore,
                                  valueAfter: valueAfter,
                                  sampleIndex: sampleIndex)
            if decision != .recheckLater {
                return AXInsertionResolution(decision: decision, rereadCount: rereadCount)
            }
            sampleIndex += 1
            rereadCount += 1
        }
        return AXInsertionResolution(decision: .replaceWholeValue, rereadCount: rereadCount)
    }

    /// Electron captured nodes report success and then never change `AXValue`.
    /// A second write still lands in the live composer.
    static func followUpAfterSelectedTextSet(setSucceeded: Bool,
                                             trustSuccessDespiteUnchangedReadback: Bool) -> SelectedTextFollowUp {
        if setSucceeded && trustSuccessDespiteUnchangedReadback {
            return .acceptWithoutProof
        }
        return .judgeByReadback
    }

    /// A write call that reported success ends the attempt. `.unverified` does
    /// not start another strategy: the text may already be in the live field.
    static func afterWrite(accepted: Bool,
                           verification: AXReadbackVerification) -> AXStrategyFollowUp {
        guard accepted else {
            return .nextStrategy(reason: "write call failed")
        }
        switch verification {
        case .verified:
            return .stop(verified: true)
        case .unreadable, .unverified:
            return .stop(verified: false)
        }
    }

    /// Plans a captured-element attempt.
    ///
    /// `readbacks` are `AXValue` samples after the selected-text write. When
    /// every sample equals `valueBefore`, that element never reflected the
    /// edit. If the write landed anyway (`trustSuccessDespiteUnchangedReadback`),
    /// the plan is exactly one write: no whole-value replacement and no fallback.
    ///
    /// - Parameters:
    ///   - valueBefore: Captured value before the selected-text write.
    ///   - readbacks: Post-write samples. A constant list means the element is stale.
    ///   - selectedTextSetSucceeded: Whether `AXSelectedText` returned success.
    ///   - trustSuccessDespiteUnchangedReadback: True when success is authoritative
    ///     even if this element's value stays constant.
    ///   - wholeValueSetSucceeded: Whether a following `AXValue` set would succeed.
    ///   - wholeValueReadback: Value after a whole-value write. Nil when unreadable.
    /// - Returns: The writes that would be issued and whether a fallback starts.
    static func traceCapturedInsertion(valueBefore: String?,
                                       readbacks: [String?],
                                       selectedTextSetSucceeded: Bool,
                                       trustSuccessDespiteUnchangedReadback: Bool,
                                       wholeValueSetSucceeded: Bool,
                                       wholeValueReadback: String?) -> CapturedInsertionTrace {
        var trace = CapturedInsertionTrace(selectedTextWrites: 1,
                                           wholeValueWrites: 0,
                                           rereadCount: 0,
                                           decision: "none",
                                           verify: "skipped",
                                           startedFallback: false,
                                           fallbackReason: "none")
        let follow = followUpAfterSelectedTextSet(
            setSucceeded: selectedTextSetSucceeded,
            trustSuccessDespiteUnchangedReadback: trustSuccessDespiteUnchangedReadback
        )
        if follow == .acceptWithoutProof {
            trace.decision = AXInsertionDecision.acceptSelectedText.logName
            trace.verify = "unverified"
            return trace
        }

        let samples = readbacks.isEmpty ? [valueBefore] : readbacks
        var sampleIndex = 0
        var decision = AXInsertionDecision.replaceWholeValue
        while sampleIndex <= maxDelayedSamples {
            let sample = sampleIndex < samples.count ? samples[sampleIndex] : samples[samples.count - 1]
            decision = decide(setSucceeded: selectedTextSetSucceeded,
                              valueBefore: valueBefore,
                              valueAfter: selectedTextSetSucceeded ? sample : nil,
                              sampleIndex: sampleIndex)
            if decision != .recheckLater {
                break
            }
            sampleIndex += 1
            trace.rereadCount += 1
        }
        trace.decision = decision.logName
        if decision != .replaceWholeValue {
            trace.verify = "verified"
            return trace
        }
        let latest = samples[samples.count - 1]
        if selectedTextSetSucceeded && !shouldReplaceWholeValue(valueBefore: valueBefore, valueNow: latest) {
            trace.verify = "verified"
            return trace
        }

        trace.wholeValueWrites = 1
        guard wholeValueSetSucceeded else {
            trace.fallbackReason = "write call failed"
            trace.startedFallback = true
            return trace
        }
        let verification = readbackVerification(previous: valueBefore, after: wholeValueReadback)
        switch afterWrite(accepted: true, verification: verification) {
        case .stop(let verified):
            trace.verify = verified ? "verified" : verification.logName
            trace.startedFallback = false
            trace.fallbackReason = "none"
        case .nextStrategy(let reason):
            trace.verify = verification.logName
            trace.startedFallback = true
            trace.fallbackReason = reason
        }
        return trace
    }

    private static func readbackVerification(previous: String?,
                                             after: String?) -> AXReadbackVerification {
        guard let after else { return .unreadable }
        if let previous, previous != after { return .verified }
        if previous == nil { return .verified }
        return .unverified
    }
}

private extension AXReadbackVerification {
    var logName: String {
        switch self {
        case .verified: return "verified"
        case .unverified: return "unverified"
        case .unreadable: return "unreadable"
        }
    }
}
