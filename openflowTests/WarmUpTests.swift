import XCTest
@testable import openflow

@MainActor
final class WarmUpThrottleTests: XCTestCase {
    private func makeSettings() -> UserSettings {
        let defaults = UserDefaults(suiteName: "openflowTests-\(UUID().uuidString)")!
        let settings = UserSettings(defaults: defaults)
        settings.providerMode = .openflowCloud
        settings.cloudBaseURL = "https://openflow-site-cvx.jottly.ai"
        return settings
    }

    func testWarmUpSendsAtMostOncePerSixtySeconds() {
        var calls = 0
        let service = TranscriptionService(provider: nil, keychain: nil, cloud: nil)
        service.warmPing = { _ in calls += 1 }
        let settings = makeSettings()
        let start = Date()

        service.warmUp(settings: settings, now: start, hasLocalGroqKey: false)
        service.warmUp(settings: settings, now: start.addingTimeInterval(30), hasLocalGroqKey: false)
        XCTAssertEqual(calls, 1)

        service.warmUp(settings: settings, now: start.addingTimeInterval(61), hasLocalGroqKey: false)
        XCTAssertEqual(calls, 2)
    }

    func testWarmUpSkipsLocalGroqProvider() {
        var calls = 0
        let service = TranscriptionService(provider: nil, keychain: nil, cloud: nil)
        service.warmPing = { _ in calls += 1 }
        let settings = makeSettings()
        settings.providerMode = .localGroq

        service.warmUp(settings: settings, now: Date(), hasLocalGroqKey: true)
        XCTAssertEqual(calls, 0)
    }

    func testWarmUpSkipsWhenBaseURLMissing() {
        var calls = 0
        let service = TranscriptionService(provider: nil, keychain: nil, cloud: nil)
        service.warmPing = { _ in calls += 1 }
        let settings = makeSettings()
        settings.cloudBaseURL = ""

        service.warmUp(settings: settings, now: Date(), hasLocalGroqKey: false)
        XCTAssertEqual(calls, 0)
    }

    func testCloudWarmUpGateBoundary() {
        var gate = CloudWarmUpGate(minimumInterval: 60)
        let start = Date()
        XCTAssertTrue(gate.shouldWarm(now: start))
        XCTAssertFalse(gate.shouldWarm(now: start.addingTimeInterval(59.9)))
        XCTAssertTrue(gate.shouldWarm(now: start.addingTimeInterval(60)))
        XCTAssertEqual(gate.lastWarmAt, start.addingTimeInterval(60))
    }
}

@MainActor
final class StyleResolutionTests: XCTestCase {
    private func makeSettings() -> UserSettings {
        UserSettings(defaults: UserDefaults(suiteName: "openflowTests-\(UUID().uuidString)")!)
    }

    func testMessagesAutoResolvesToCasual() {
        let settings = makeSettings()
        var prefs = settings.stylePreferences
        prefs.personalMessages = .preset(.auto)
        prefs.other = .preset(.professional)
        settings.stylePreferences = prefs

        let ref = settings.resolvedStyleRef(kind: .personal,
                                            appName: "Messages",
                                            bundleID: "com.apple.MobileSMS")
        XCTAssertEqual(ref.preset, .casual)
    }

    func testMessagesExplicitPresetStaysAuthoritative() {
        let settings = makeSettings()
        var prefs = settings.stylePreferences
        prefs.personalMessages = .preset(.professional)
        settings.stylePreferences = prefs

        let ref = settings.resolvedStyleRef(kind: .personal,
                                            appName: "Messages",
                                            bundleID: "com.apple.MobileSMS")
        XCTAssertEqual(ref.preset, .professional)
    }

    func testAppStyleOverrideStillWins() {
        let settings = makeSettings()
        settings.appStyleOverrides = [
            AppStyleOverride(appName: "Messages",
                             bundleID: "com.apple.MobileSMS",
                             style: .preset(.concise))
        ]
        let ref = settings.resolvedStyleRef(kind: .personal,
                                            appName: "Messages",
                                            bundleID: "com.apple.MobileSMS")
        XCTAssertEqual(ref.preset, .concise)
    }
}
