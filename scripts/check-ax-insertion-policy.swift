import Foundation

@main
struct CheckAXInsertionPolicy {
    static func main() async {
        await testAttributeSetFailureReplacesWithoutReading()
        await testUnreadableValueTrustsSelectedText()
        await testImmediateChangeTrustsSelectedText()
        await testUnchangedImmediateReadbackRechecks()
        await testDelayedApplyAcceptsWithoutReplacing()
        await testGenuinelyDroppedWriteReplacesWholeValue()
        await testReadbackThatBecomesUnreadableDoesNotReplace()
        await testFinalUnchangedSampleReplaces()
        await testChangeOnFinalSampleAccepts()
        testWholeValueGate()
        await testCapturedReadbackNeverChangesButWriteLanded()
        testMapsStillReplacesWhenTheWriteDidNotLand()
        testUnverifiedSuccessDoesNotStartAnotherStrategy()
        testFailedWriteMayTryNextStrategy()
        testElectronFrameworkDetection()
        print("ax insertion policy checks passed")
    }

    private static func testAttributeSetFailureReplacesWithoutReading() async {
        var reads = 0
        let decision = await AXInsertionPolicy.resolve(setSucceeded: false, valueBefore: "Hi") { _ in
            reads += 1
            return "Hi there"
        }
        expect(decision == .replaceWholeValue, "a failed AXSelectedText set must fall through to AXValue")
        expect(reads == 0, "a failed attribute set must not wait on readbacks")
        expect(
            AXInsertionPolicy.decide(setSucceeded: false,
                                    valueBefore: "Hi",
                                    valueAfter: "Hi there",
                                    sampleIndex: 0) == .replaceWholeValue,
            "a changed value cannot rescue a failed attribute set"
        )
    }

    private static func testUnreadableValueTrustsSelectedText() async {
        let missingBefore = await AXInsertionPolicy.resolve(setSucceeded: true, valueBefore: nil) { _ in
            nil
        }
        expect(missingBefore == .acceptSelectedText, "an unreadable field must trust a successful write")

        let missingAfter = AXInsertionPolicy.decide(setSucceeded: true,
                                                    valueBefore: "Hello",
                                                    valueAfter: nil,
                                                    sampleIndex: 0)
        expect(missingAfter == .acceptSelectedText, "a readback that disappears must not cause a second write")
    }

    private static func testImmediateChangeTrustsSelectedText() async {
        var reads: [Int] = []
        let decision = await AXInsertionPolicy.resolve(setSucceeded: true, valueBefore: "Hello") { index in
            reads.append(index)
            return "Hello there"
        }
        expect(decision == .acceptSelectedText, "a native control whose value changes immediately must be accepted")
        expect(reads == [0], "an immediate change must not take the delayed recheck")
    }

    private static func testUnchangedImmediateReadbackRechecks() async {
        let decision = AXInsertionPolicy.decide(setSucceeded: true,
                                                valueBefore: "Hello",
                                                valueAfter: "Hello",
                                                sampleIndex: 0)
        expect(decision == .recheckLater, "an unchanged immediate readback must recheck before a second write")
    }

    private static func testDelayedApplyAcceptsWithoutReplacing() async {
        let samples = ["Hello", "Hello", "Hello there"]
        var reads: [Int] = []
        let decision = await AXInsertionPolicy.resolve(setSucceeded: true, valueBefore: "Hello") { index in
            reads.append(index)
            return samples[index]
        }
        expect(decision == .acceptSelectedText, "a delayed Electron apply must be accepted once the value changes")
        expect(reads == [0, 1, 2], "delayed apply must keep reading until the value changes and must not replace AXValue")
    }

    private static func testGenuinelyDroppedWriteReplacesWholeValue() async {
        var reads = 0
        let decision = await AXInsertionPolicy.resolve(setSucceeded: true, valueBefore: "Search") { _ in
            reads += 1
            return "Search"
        }
        expect(decision == .replaceWholeValue, "a write that never changes the value must fall through to AXValue")
        expect(
            reads == AXInsertionPolicy.maxDelayedSamples + 1,
            "a dropped write must use the immediate sample and every delayed sample"
        )
    }

    private static func testReadbackThatBecomesUnreadableDoesNotReplace() async {
        let samples: [String?] = ["Hello", nil]
        var reads: [Int] = []
        let decision = await AXInsertionPolicy.resolve(setSucceeded: true, valueBefore: "Hello") { index in
            reads.append(index)
            return samples[index]
        }
        expect(decision == .acceptSelectedText, "a delayed unreadable readback must not cause a second write")
        expect(reads == [0, 1], "an unreadable delayed sample must stop the recheck")
    }

    private static func testFinalUnchangedSampleReplaces() async {
        let stillWaiting = AXInsertionPolicy.decide(
            setSucceeded: true,
            valueBefore: "Search",
            valueAfter: "Search",
            sampleIndex: AXInsertionPolicy.maxDelayedSamples - 1
        )
        let exhausted = AXInsertionPolicy.decide(
            setSucceeded: true,
            valueBefore: "Search",
            valueAfter: "Search",
            sampleIndex: AXInsertionPolicy.maxDelayedSamples
        )
        expect(stillWaiting == .recheckLater, "the sample before the last recheck must not replace yet")
        expect(exhausted == .replaceWholeValue, "the final unchanged sample must replace AXValue")
    }

    private static func testChangeOnFinalSampleAccepts() async {
        let sampleCount = AXInsertionPolicy.maxDelayedSamples + 1
        var reads: [Int] = []
        let decision = await AXInsertionPolicy.resolve(setSucceeded: true, valueBefore: "Hello") { index in
            reads.append(index)
            if index == AXInsertionPolicy.maxDelayedSamples {
                return "Hello there"
            }
            return "Hello"
        }
        expect(decision == .acceptSelectedText, "a change on the final sample must be accepted")
        expect(reads.count == sampleCount, "the final sample must still be read")
    }

    private static func testCapturedReadbackNeverChangesButWriteLanded() async {
        let stale = Array(repeating: "Hello", count: AXInsertionPolicy.maxDelayedSamples + 2)
        var reads = 0
        let naive = await AXInsertionPolicy.resolve(setSucceeded: true, valueBefore: "Hello") { _ in
            reads += 1
            return stale[0]
        }
        expect(naive == .replaceWholeValue, "a constant captured value used to demand a second write")
        expect(reads == AXInsertionPolicy.maxDelayedSamples + 1, "the old readback loop exhausts every sample")

        let trace = AXInsertionPolicy.traceCapturedInsertion(
            valueBefore: "Hello",
            readbacks: stale,
            selectedTextSetSucceeded: true,
            trustSuccessDespiteUnchangedReadback: true,
            wholeValueSetSucceeded: true,
            wholeValueReadback: "Hello"
        )
        expect(trace.totalWrites == 1, "a landed write whose captured readback never changes must be the only write")
        expect(trace.selectedTextWrites == 1, "the selected-text call is the one write")
        expect(trace.wholeValueWrites == 0, "AXValue must not be replaced when the captured node stays constant")
        expect(trace.rereadCount == 0, "a constant captured node must not be reread")
        expect(!trace.startedFallback, "no fallback strategy may run after the write landed")
        expect(trace.fallbackReason == "none", "fallback reason stays empty when the attempt stops")
    }

    private static func testMapsStillReplacesWhenTheWriteDidNotLand() {
        let trace = AXInsertionPolicy.traceCapturedInsertion(
            valueBefore: "Search",
            readbacks: Array(repeating: "Search", count: 8),
            selectedTextSetSucceeded: true,
            trustSuccessDespiteUnchangedReadback: false,
            wholeValueSetSucceeded: true,
            wholeValueReadback: "Search maps"
        )
        expect(trace.wholeValueWrites == 1, "Maps still replaces AXValue when the selected-text write is dropped")
        expect(trace.verify == "verified", "the whole-value write is visible on a native field")
        expect(!trace.startedFallback, "Maps does not continue into another insertion strategy")
    }

    private static func testUnverifiedSuccessDoesNotStartAnotherStrategy() {
        let follow = AXInsertionPolicy.afterWrite(accepted: true, verification: .unverified)
        guard case .stop(let verified) = follow else {
            expect(false, "unverified success must stop")
            return
        }
        expect(!verified, "an unverified successful write is reported unverified")

        let trace = AXInsertionPolicy.traceCapturedInsertion(
            valueBefore: "Hello",
            readbacks: Array(repeating: "Hello", count: 8),
            selectedTextSetSucceeded: true,
            trustSuccessDespiteUnchangedReadback: false,
            wholeValueSetSucceeded: true,
            wholeValueReadback: "Hello"
        )
        expect(!trace.startedFallback, "an unchanged readback after a successful write must not fall back")
        expect(trace.fallbackReason == "none", "stopping is not a fallback")
    }

    private static func testFailedWriteMayTryNextStrategy() {
        let follow = AXInsertionPolicy.afterWrite(accepted: false, verification: .unverified)
        guard case .nextStrategy(let reason) = follow else {
            expect(false, "a failed write may try the next strategy")
            return
        }
        expect(reason == "write call failed", "fallback reason names the failed write")

        let trace = AXInsertionPolicy.traceCapturedInsertion(
            valueBefore: "Search",
            readbacks: Array(repeating: "Search", count: 4),
            selectedTextSetSucceeded: false,
            trustSuccessDespiteUnchangedReadback: false,
            wholeValueSetSucceeded: false,
            wholeValueReadback: "Search"
        )
        expect(trace.startedFallback, "Maps can still leave the accessibility path when both writes fail")
        expect(trace.fallbackReason == "write call failed", "the fallback reason is the failed write")
    }

    private static func testElectronFrameworkDetection() {
        let app = "/Applications/Grok Bot.app"
        expect(
            ElectronAppDetection.isElectronBundle(bundlePath: app) { candidate in
                candidate == ElectronAppDetection.frameworkPath(bundlePath: app)
            },
            "a bundle that contains Electron Framework.framework is Electron"
        )

        let helper = "/Applications/Grok Bot.app/Contents/Frameworks/Grok Bot Helper.app"
        let hostFramework = ElectronAppDetection.frameworkPath(bundlePath: app)
        expect(
            ElectronAppDetection.isElectronBundle(bundlePath: helper) { $0 == hostFramework },
            "a nested Electron helper still resolves the host framework"
        )
        expect(
            !ElectronAppDetection.isElectronBundle(bundlePath: "/System/Applications/Notes.app") { _ in false },
            "Notes is not Electron"
        )
        expect(
            !ElectronAppDetection.isElectronBundle(bundlePath: "/Applications/Safari.app") { _ in false },
            "Safari is not Electron"
        )
        expect(
            !ElectronAppDetection.isElectronBundle(bundlePath: "") { _ in true },
            "an empty bundle path is not Electron"
        )
    }

    private static func testWholeValueGate() {
        expect(
            AXInsertionPolicy.shouldReplaceWholeValue(valueBefore: "Search", valueNow: "Search"),
            "an unchanged readable field still needs the AXValue fallback"
        )
        expect(
            !AXInsertionPolicy.shouldReplaceWholeValue(valueBefore: "Hello", valueNow: "Hello there"),
            "a late apply must block the second write"
        )
        expect(
            !AXInsertionPolicy.shouldReplaceWholeValue(valueBefore: nil, valueNow: "Hello"),
            "an unreadable before-value must block the second write"
        )
        expect(
            !AXInsertionPolicy.shouldReplaceWholeValue(valueBefore: "Hello", valueNow: nil),
            "an unreadable current value must block the second write"
        )
        expect(
            !AXInsertionPolicy.shouldReplaceWholeValue(valueBefore: nil, valueNow: nil),
            "two unreadable samples must block the second write"
        )
    }

    private static func expect(_ condition: Bool, _ message: String) {
        guard condition else {
            FileHandle.standardError.write(Data("ax insertion policy check failed: \(message)\n".utf8))
            exit(1)
        }
    }
}
