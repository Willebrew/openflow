import Foundation

/// What to do after an `AXSelectedText` write.
enum AXInsertionDecision: Equatable {
    /// The write is trusted. Do not write the text again.
    case acceptSelectedText
    /// The value is unchanged so far, and the write may still be applying.
    case recheckLater
    /// The write did not land. Replace the whole `AXValue`.
    case replaceWholeValue
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
        var sampleIndex = 0
        while sampleIndex <= maxDelayedSamples {
            let valueAfter = setSucceeded ? await readSample(sampleIndex) : nil
            let decision = decide(setSucceeded: setSucceeded,
                                  valueBefore: valueBefore,
                                  valueAfter: valueAfter,
                                  sampleIndex: sampleIndex)
            if decision != .recheckLater {
                return decision
            }
            sampleIndex += 1
        }
        return .replaceWholeValue
    }
}
