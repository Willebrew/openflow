import Foundation

@main
struct CheckHistoryPrivacy {
    static func main() async {
        await MainActor.run {
            let suiteName = "openflow.history.privacy.\(UUID().uuidString)"
            guard let defaults = UserDefaults(suiteName: suiteName) else {
                fail("could not create temporary defaults suite")
            }
            defer { defaults.removePersistentDomain(forName: suiteName) }

            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("openflow-history-privacy-\(UUID().uuidString)", isDirectory: true)
            let historyURL = root.appendingPathComponent("history.json")
            let diagnosticsURL = root.appendingPathComponent("diagnostics", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: root) }

            let settings = UserSettings(defaults: defaults)
            let history = HistoryService(url: historyURL)

            settings.historyEnabled = false
            settings.storeRawTranscript = true
            history.add(makeHistoryItem(finalText: "SHOULD_NOT_BE_STORED",
                                        rawTranscript: "RAW_SHOULD_NOT_BE_STORED"),
                        settings: settings)
            history.recordLifetime(text: "SHOULD_NOT_BE_STORED", audioSeconds: 1.5)
            assertEqual(history.items.count, 0, "disabled history item count")
            assertEqual(history.lifetimeWords, 1, "lifetime still counts when history is off")
            assertFileDoesNotContain(historyURL, "SHOULD_NOT_BE_STORED", "disabled history final text")
            assertFileDoesNotContain(historyURL, "RAW_SHOULD_NOT_BE_STORED", "disabled history raw text")
            assertFileDoesNotContain(root.appendingPathComponent("lifetime.json"),
                                     "SHOULD_NOT_BE_STORED",
                                     "lifetime file must not store transcript text")

            settings.historyEnabled = true
            settings.storeRawTranscript = false
            let sanitizedInsertion = InsertionResult(succeeded: true,
                                                     verified: true,
                                                     method: .focusedAX,
                                                     attemptCount: 2,
                                                     failureReason: nil,
                                                     targetApp: "Arc",
                                                     targetBundleID: "company.thebrowser.Browser")
            history.add(makeHistoryItem(finalText: "Clean stored text",
                                        rawTranscript: "RAW_MUST_BE_STRIPPED",
                                        insertion: sanitizedInsertion),
                        settings: settings)
            assertEqual(history.items.count, 1, "sanitized history item count")
            assertEqual(history.items[0].finalText, "Clean stored text", "sanitized final text")
            assertEqual(history.items[0].rawTranscript as String?, nil, "raw transcript stripped")
            assertEqual(history.items[0].insertion?.method, .focusedAX, "insertion method encoded")
            assertFileDoesNotContain(historyURL, "RAW_MUST_BE_STRIPPED", "raw transcript stripped on disk")

            settings.storeRawTranscript = true
            history.add(makeHistoryItem(finalText: "Debug stored text",
                                        rawTranscript: "RAW_DEBUG_ALLOWED"),
                        settings: settings)
            assertEqual(history.items.count, 2, "raw-enabled history item count")
            assertEqual(history.items[0].rawTranscript, "RAW_DEBUG_ALLOWED", "raw transcript opt-in")
            assertFileContains(historyURL, "RAW_DEBUG_ALLOWED", "raw transcript opt-in on disk")

            let diagnostics = InsertionDiagnosticsService(directory: diagnosticsURL)
            var metrics = LatencyMetrics()
            metrics.audioDuration = 1.23
            metrics.uploadAndTranscriptionTime = 0.34
            metrics.cleanupTime = 0.12
            metrics.insertionTime = 0.05
            metrics.totalTime = 1.74
            metrics.contextAvailable = true
            metrics.focusRaceDetected = true
            metrics.focusRaceDescription = "started pid 123, current pid 456"
            let failed = InsertionResult.failed(reason: "No editable element found",
                                                attemptCount: 8,
                                                targetApp: "Arc",
                                                targetBundleID: "company.thebrowser.Browser")
            diagnostics.writeFailedInsertion(result: failed, category: .aiChat, metrics: metrics)

            let reports = (try? FileManager.default.contentsOfDirectory(at: diagnosticsURL,
                                                                        includingPropertiesForKeys: nil)) ?? []
            assertEqual(reports.count, 1, "failed insertion report count")
            let reportText = (try? String(contentsOf: reports[0], encoding: .utf8)) ?? ""
            assertContains(reportText, "No editable element found", "diagnostic failure reason")
            assertContains(reportText, "company.thebrowser.Browser", "diagnostic bundle id")
            assertContains(reportText, "focusRaceDetected", "diagnostic focus race key")
            assertContains(reportText, "started pid 123, current pid 456", "diagnostic focus race description")
            assertNotContains(reportText, "Clean stored text", "diagnostic final text")
            assertNotContains(reportText, "RAW_DEBUG_ALLOWED", "diagnostic raw transcript")
            assertNotContains(reportText, "audioBase64", "diagnostic audio payload")

            let beforeClear = history.lifetimeWords
            history.recordLifetime(text: "one two three four", audioSeconds: 2)
            assertEqual(history.lifetimeWords, beforeClear + 4, "lifetime increments from new dictation")
            history.clear()
            assertEqual(history.items.count, 0, "clear removes history items")
            assertEqual(history.lifetimeWords, beforeClear + 4, "clear must not reset lifetime words")
            history.adoptLifetimeHighWater(words: 50)
            assertEqual(history.lifetimeWords, 50, "cloud lifetime can raise the local high-water mark")
            history.adoptLifetimeHighWater(words: 20)
            assertEqual(history.lifetimeWords, 50, "a smaller cloud window must not lower lifetime")

            history.recordLifetime(text: "mail one two",
                                   audioSeconds: 4,
                                   appName: "Mail",
                                   bundleID: "com.apple.mail")
            history.recordLifetime(text: "xcode one two three four",
                                   audioSeconds: 8,
                                   appName: "Xcode",
                                   bundleID: "com.apple.dt.Xcode")
            assertEqual(history.appStats.count, 2, "lifetime apps accumulate Mail and Xcode")
            assertTrue(history.appStats.contains { $0.appName == "Mail" }, "Mail stays after Xcode is recorded")
            assertTrue(history.appStats.contains { $0.appName == "Xcode" }, "Xcode is added beside Mail")
            history.clear()
            assertTrue(history.appStats.contains { $0.appName == "Mail" }, "clearing History must not drop lifetime apps")
            assertFileDoesNotContain(root.appendingPathComponent("lifetime-apps.json"),
                                     "mail one two",
                                     "lifetime apps file must not store transcript text")
        }
    }

    private static func makeHistoryItem(finalText: String,
                                        rawTranscript: String?,
                                        insertion: InsertionResult? = nil) -> DictationHistoryItem {
        DictationHistoryItem(timestamp: Date(timeIntervalSince1970: 1_778_544_000),
                             finalText: finalText,
                             rawTranscript: rawTranscript,
                             appName: "Arc",
                             bundleID: "company.thebrowser.Browser",
                             category: .aiChat,
                             insertionSucceeded: insertion?.succeeded ?? true,
                             insertion: insertion,
                             metrics: LatencyMetrics())
    }

    private static func assertFileContains(_ url: URL, _ needle: String, _ label: String) {
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        assertContains(text, needle, label)
    }

    private static func assertFileDoesNotContain(_ url: URL, _ needle: String, _ label: String) {
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        assertNotContains(text, needle, label)
    }

    private static func assertContains(_ haystack: String, _ needle: String, _ label: String) {
        if !haystack.contains(needle) {
            fail("\(label) missing \(needle)")
        }
    }

    private static func assertNotContains(_ haystack: String, _ needle: String, _ label: String) {
        if haystack.contains(needle) {
            fail("\(label) unexpectedly contained \(needle)")
        }
    }

    private static func assertEqual<T: Equatable>(_ actual: T, _ expected: T, _ label: String) {
        if actual != expected {
            fail("\(label) expected \(expected), got \(actual)")
        }
    }

    private static func assertTrue(_ condition: Bool, _ label: String) {
        if !condition {
            fail(label)
        }
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("history privacy check failed: \(message)\n".utf8))
        exit(1)
    }
}
