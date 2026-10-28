import XCTest
@testable import openflow

final class SilenceHallucinationFilterTests: XCTestCase {
    func testFiltersStockPhrasesOnShortClips() {
        XCTAssertTrue(SilenceHallucinationFilter.isSilenceHallucination(text: "Thank you.", audioSeconds: 0.8))
        XCTAssertTrue(SilenceHallucinationFilter.isSilenceHallucination(text: "thanks for watching!", audioSeconds: 1.0))
        XCTAssertTrue(SilenceHallucinationFilter.isSilenceHallucination(text: " you ", audioSeconds: 0.4))
        XCTAssertTrue(SilenceHallucinationFilter.isSilenceHallucination(text: "Bye.", audioSeconds: 1.4))
    }

    func testKeepsSamePhraseOnLongerClips() {
        XCTAssertFalse(SilenceHallucinationFilter.isSilenceHallucination(text: "Thank you.", audioSeconds: 1.5))
        XCTAssertFalse(SilenceHallucinationFilter.isSilenceHallucination(text: "Thank you.", audioSeconds: 4.0))
    }

    func testKeepsOtherTextOnShortClips() {
        XCTAssertFalse(SilenceHallucinationFilter.isSilenceHallucination(text: "Hello there", audioSeconds: 0.8))
        XCTAssertFalse(SilenceHallucinationFilter.isSilenceHallucination(text: "thank you very much", audioSeconds: 0.8))
        XCTAssertFalse(SilenceHallucinationFilter.isSilenceHallucination(text: "see you", audioSeconds: 0.9))
    }
}

final class CasualMessagesFormatterTests: XCTestCase {
    private func context(preset: StylePreset = .casual,
                         category: AppCategory = .messages,
                         customStylePrompt: String? = nil) -> FormattingContext {
        FormattingContext(activeAppName: "Messages",
                          bundleID: "com.apple.MobileSMS",
                          category: category,
                          selectedText: nil,
                          nearbyText: nil,
                          textBefore: nil,
                          textAfter: nil,
                          browserURL: nil,
                          stylePreset: preset,
                          customStyleName: nil,
                          customStylePrompt: customStylePrompt)
    }

    func testStripsTrailingPeriodFromSingleSentence() {
        XCTAssertEqual(CasualMessagesFormatter.apply("Sounds good.", context: context()),
                       "Sounds good")
    }

    func testKeepsPeriodOnMultiSentence() {
        XCTAssertEqual(CasualMessagesFormatter.apply("Hi. See you soon.", context: context()),
                       "Hi. See you soon.")
    }

    func testKeepsQuestionAndExclamation() {
        XCTAssertEqual(CasualMessagesFormatter.apply("you sure?", context: context()),
                       "you sure?")
        XCTAssertEqual(CasualMessagesFormatter.apply("that is great!", context: context()),
                       "that is great!")
    }

    func testIgnoresNonCasualPresetAndNonMessagesCategory() {
        XCTAssertEqual(CasualMessagesFormatter.apply("Sounds good.", context: context(preset: .professional)),
                       "Sounds good.")
        XCTAssertEqual(CasualMessagesFormatter.apply("Sounds good.", context: context(category: .email)),
                       "Sounds good.")
    }

    func testCustomStyleStaysAuthoritative() {
        XCTAssertEqual(CasualMessagesFormatter.apply("Sounds good.",
                                                   context: context(customStylePrompt: "be terse")),
                       "Sounds good.")
    }
}

final class MidSentenceCasingFormatterTests: XCTestCase {
    func testLowercasesWhenBeforeEndsMidSentence() {
        XCTAssertEqual(MidSentenceCasingFormatter.apply("Sounds good to me.",
                                                        textBefore: "let me know when"),
                       "sounds good to me.")
        XCTAssertEqual(MidSentenceCasingFormatter.apply("The plan works",
                                                        textBefore: "okay,"),
                       "the plan works")
    }

    func testKeepsCapitalAtSentenceStart() {
        XCTAssertEqual(MidSentenceCasingFormatter.apply("Sounds good.", textBefore: "Done."),
                       "Sounds good.")
        XCTAssertEqual(MidSentenceCasingFormatter.apply("Sounds good.", textBefore: nil),
                       "Sounds good.")
        XCTAssertEqual(MidSentenceCasingFormatter.apply("Sounds good.", textBefore: ""),
                       "Sounds good.")
        XCTAssertEqual(MidSentenceCasingFormatter.apply("Sounds good.", textBefore: "asked?"),
                       "Sounds good.")
    }

    func testProtectsPronounAcronymAndProperNoun() {
        XCTAssertEqual(MidSentenceCasingFormatter.apply("I think so", textBefore: "okay"),
                       "I think so")
        XCTAssertEqual(MidSentenceCasingFormatter.apply("NASA announced it", textBefore: "okay"),
                       "NASA announced it")
        XCTAssertEqual(MidSentenceCasingFormatter.apply("Jack told me Jack left", textBefore: "okay"),
                       "Jack told me Jack left")
    }
}

final class CleanupLengthGuardTests: XCTestCase {
    private func words(_ count: Int) -> String {
        (0..<count).map { "w\($0)" }.joined(separator: " ")
    }

    func testRejectsOverExpansion() {
        // raw 5 words -> bound is 5 * 1.5 + 8 = 15.5
        XCTAssertFalse(CleanupLengthGuard.passes(cleaned: words(16), raw: words(5)))
        XCTAssertFalse(CleanupLengthGuard.passes(cleaned: words(40), raw: words(5)))
    }

    func testAcceptsNormalExpansion() {
        XCTAssertTrue(CleanupLengthGuard.passes(cleaned: words(12), raw: words(5)))
        XCTAssertTrue(CleanupLengthGuard.passes(cleaned: words(8), raw: words(10)))
    }

    func testRejectsOverTruncationWithoutSelfCorrection() {
        XCTAssertFalse(CleanupLengthGuard.passes(cleaned: words(4), raw: words(10)))
    }

    func testAllowsTruncationWithSelfCorrectionCue() {
        let raw = "meet at three scratch that meet at four at five"
        XCTAssertTrue(CleanupLengthGuard.passes(cleaned: "meet at five", raw: raw))
    }

    func testAllowsExpansionForGenerativeStyles() {
        XCTAssertTrue(CleanupLengthGuard.passes(cleaned: words(30), raw: words(5),
                                                allowsExpansion: true))
        XCTAssertFalse(CleanupLengthGuard.passes(cleaned: words(1), raw: words(10),
                                                 allowsExpansion: true))
    }
}
