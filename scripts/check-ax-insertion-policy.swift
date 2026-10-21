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
