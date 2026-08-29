import Foundation

@main
struct CheckUserSettingsPersistence {
    static func main() async {
        await MainActor.run {
            let suiteName = "openflow.settings.persistence.\(UUID().uuidString)"
            guard let defaults = UserDefaults(suiteName: suiteName) else {
                fail("could not create temporary defaults suite")
            }
            defer { defaults.removePersistentDomain(forName: suiteName) }

            let fresh = UserSettings(defaults: defaults)
            if !fresh.personalDictionary.isEmpty {
                fail("new installs must start with an empty dictionary")
            }
            if !fresh.phrases.isEmpty {
                fail("new installs must start with no phrases")
            }
            if !fresh.customStyles.isEmpty {
                fail("new installs must start with no custom styles")
            }
            if fresh.debugLogsEnabled {
                fail("debug logs must be off by default")
            }

            let first = UserSettings(defaults: defaults)
            first.providerMode = .openflowCloud
            first.cloudBaseURL = "https://example.invalid"
            first.transcriptionModel = "whisper-large-v3"
            first.fallbackTranscriptionModel = "whisper-large-v3-turbo"
            first.cleanupModel = "llama-test"
            first.pushToTalkHotkey = .controlSpace
            first.toggleHotkey = .optionSpace
            first.microphoneDeviceID = "test-microphone-id"
            first.hideInactivePill = true
            first.debugLogsEnabled = false
            first.historyEnabled = false
            first.storeRawTranscript = true
            first.contextAwarenessEnabled = false
            first.browserURLDetectionEnabled = false
            first.pressEnterCommandEnabled = false
            first.personalDictionary = [DictionaryEntry(term: "NeuroQuest Labs", replacement: "NeuroQuest Labs")]
            first.phrases = [PhraseEntry(trigger: "ship it", expansion: "Ship it.")]
            first.stylePreferences = StylePreferences(personalMessages: .rawTranscript,
                                                      workMessages: .promptMode,
                                                      email: .concise,
                                                      other: .technicalCodeSafe,
                                                      emailSignOffName: "Alex")
            first.appStyleOverrides = [AppStyleOverride(appName: "Arc",
                                                        bundleID: "company.thebrowser.Browser",
                                                        style: .promptMode)]
            first.customStyles = [CustomStyle(name: "Court reporter",
                                              prompt: "Keep every spoken word. Do not polish.")]
            defaults.synchronize()

            let second = UserSettings(defaults: defaults)
            assertEqual(second.providerMode, .openflowCloud, "providerMode")
            assertEqual(second.cloudBaseURL, "https://example.invalid", "cloudBaseURL")
            assertEqual(second.transcriptionModel, "whisper-large-v3", "transcriptionModel")
            assertEqual(second.fallbackTranscriptionModel, "whisper-large-v3-turbo", "fallbackTranscriptionModel")
            assertEqual(second.cleanupModel, "llama-test", "cleanupModel")
            assertEqual(second.pushToTalkHotkey, .controlSpace, "pushToTalkHotkey")
            assertEqual(second.toggleHotkey, .optionSpace, "toggleHotkey")
            assertEqual(second.microphoneDeviceID, "test-microphone-id", "microphoneDeviceID")
            assertEqual(second.hideInactivePill, true, "hideInactivePill")
            assertEqual(second.debugLogsEnabled, false, "debugLogsEnabled")
            assertEqual(second.historyEnabled, false, "historyEnabled")
            assertEqual(second.storeRawTranscript, true, "storeRawTranscript")
            assertEqual(second.contextAwarenessEnabled, false, "contextAwarenessEnabled")
            assertEqual(second.browserURLDetectionEnabled, false, "browserURLDetectionEnabled")
            assertEqual(second.pressEnterCommandEnabled, false, "pressEnterCommandEnabled")
            assertEqual(second.personalDictionary.first?.term, "NeuroQuest Labs", "personalDictionary")
            assertEqual(second.phrases.first?.expansion, "Ship it.", "phrases")
            assertEqual(second.stylePreferences.email, .preset(.concise), "stylePreferences")
            assertEqual(second.stylePreferences.emailSignOffName, "Alex", "emailSignOffName")
            assertEqual(second.appStyleOverrides.first?.style, .preset(.promptMode), "appStyleOverrides")
            assertEqual(second.customStyles.first?.name, "Court reporter", "customStyles")
            assertEqual(second.customStyles.first?.prompt, "Keep every spoken word. Do not polish.", "customStyles prompt")

            let snapshot = first.cloudSnapshot()
            guard let snapshotData = try? JSONEncoder().encode(snapshot),
                  let decodedSnapshot = try? JSONDecoder().decode(CloudPreferencesSnapshot.self, from: snapshotData) else {
                fail("cloud snapshot did not encode/decode")
            }
            assertEqual(decodedSnapshot.stylePreferences.emailSignOffName, "Alex", "SettingsSnapshot emailSignOffName")
            assertEqual(decodedSnapshot.phrases.first?.expansion, "Ship it.", "SettingsSnapshot phrases")
            assertEqual(decodedSnapshot.microphoneDeviceID, "test-microphone-id", "SettingsSnapshot microphoneDeviceID")
            if String(data: snapshotData, encoding: .utf8)?.contains("\"snippets\"") == true {
                fail("cloud snapshot must encode phrases, not snippets")
            }
            if String(data: snapshotData, encoding: .utf8)?.contains("\"microphoneDeviceID\"") != true {
                fail("cloud snapshot must encode microphoneDeviceID")
            }
            if String(data: snapshotData, encoding: .utf8)?.contains("\"customStyles\"") != true {
                fail("cloud snapshot must encode customStyles")
            }

            let applySuite = "openflow.settings.snapshot.\(UUID().uuidString)"
            guard let applyDefaults = UserDefaults(suiteName: applySuite) else {
                fail("could not create snapshot defaults suite")
            }
            defer { applyDefaults.removePersistentDomain(forName: applySuite) }
            let applied = UserSettings(defaults: applyDefaults)
            applied.applyCloudSnapshot(decodedSnapshot)
            assertEqual(applied.stylePreferences.emailSignOffName, "Alex", "apply snapshot emailSignOffName")
            assertEqual(applied.stylePreferences.email, .preset(.concise), "apply snapshot email preset")
            assertEqual(applied.phrases.first?.expansion, "Ship it.", "apply snapshot phrases")
            assertEqual(applied.customStyles.first?.name, "Court reporter", "apply snapshot customStyles")
            assertEqual(applied.microphoneDeviceID, "test-microphone-id", "apply snapshot microphoneDeviceID")

            applied.contextAwarenessEnabled = false
            applied.pressEnterCommandEnabled = false
            var enabling = decodedSnapshot
            enabling.contextAwarenessEnabled = true
            enabling.pressEnterCommandEnabled = true
            applied.applyCloudSnapshot(enabling)
            assertEqual(applied.contextAwarenessEnabled, false, "cloud snapshot cannot enable context awareness")
            assertEqual(applied.pressEnterCommandEnabled, false, "cloud snapshot cannot enable spoken press enter")

            applied.contextAwarenessEnabled = true
            applied.pressEnterCommandEnabled = true
            var disabling = decodedSnapshot
            disabling.contextAwarenessEnabled = false
            disabling.pressEnterCommandEnabled = false
            applied.applyCloudSnapshot(disabling)
            assertEqual(applied.contextAwarenessEnabled, true, "cloud snapshot cannot disable context awareness")
            assertEqual(applied.pressEnterCommandEnabled, true, "cloud snapshot cannot disable spoken press enter")

            let legacyJSON = Data(#"{"personalMessages":"casual","workMessages":"professional","email":"concise","other":"auto"}"#.utf8)
            guard let legacyPrefs = try? JSONDecoder().decode(StylePreferences.self, from: legacyJSON) else {
                fail("legacy StylePreferences JSON without emailSignOffName must still decode")
            }
            assertEqual(legacyPrefs.email, .preset(.concise), "legacy stylePreferences email")
            assertEqual(legacyPrefs.emailSignOffName, "", "legacy stylePreferences emailSignOffName")

            let legacySuite = "openflow.settings.legacy-snippets.\(UUID().uuidString)"
            guard let legacyDefaults = UserDefaults(suiteName: legacySuite) else {
                fail("could not create legacy snippets defaults suite")
            }
            defer { legacyDefaults.removePersistentDomain(forName: legacySuite) }
            let legacySnippet = PhraseEntry(trigger: "old trigger", expansion: "Old expansion")
            guard let legacySnippetData = try? JSONEncoder().encode([legacySnippet]) else {
                fail("could not encode legacy snippets")
            }
            legacyDefaults.set(legacySnippetData, forKey: "snippets")
            legacyDefaults.synchronize()
            let migrated = UserSettings(defaults: legacyDefaults)
            assertEqual(migrated.phrases.first?.trigger, "old trigger", "legacy snippets UserDefaults key")
            assertEqual(migrated.phrases.first?.expansion, "Old expansion", "legacy snippets UserDefaults expansion")
            if legacyDefaults.data(forKey: "phrases") == nil {
                fail("legacy snippets must migrate onto the phrases key")
            }

            let legacySnapshotJSON = Data(#"""
            {"pushToTalkHotkey":"fnHold","toggleHotkey":"controlSpace","commandHotkey":"optionSpace","stylePreset":"auto","contextAwarenessEnabled":true,"browserURLDetectionEnabled":true,"pressEnterCommandEnabled":true,"hideInactivePill":false,"personalDictionary":[],"snippets":[{"id":"AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE","trigger":"cloud trigger","expansion":"Cloud expansion"}],"stylePreferences":{"personalMessages":"casual","workMessages":"professional","email":"emailLetter","other":"auto","emailSignOffName":""},"appStyleOverrides":[]}
            """#.utf8)
            guard let legacyCloud = try? JSONDecoder().decode(CloudPreferencesSnapshot.self, from: legacySnapshotJSON) else {
                fail("legacy cloud snapshot with snippets must still decode")
            }
            assertEqual(legacyCloud.phrases.first?.trigger, "cloud trigger", "legacy cloud snippets")
            assertEqual(legacyCloud.phrases.first?.expansion, "Cloud expansion", "legacy cloud snippets expansion")

            let styleSuite = "openflow.settings.style-resolution.\(UUID().uuidString)"
            guard let styleDefaults = UserDefaults(suiteName: styleSuite) else {
                fail("could not create style resolution defaults suite")
            }
            defer { styleDefaults.removePersistentDomain(forName: styleSuite) }
            let styles = UserSettings(defaults: styleDefaults)
            styles.contextAwarenessEnabled = true
            styles.setDefaultStyle(.preset(.professional))
            styles.stylePreferences.email = .preset(.auto)
            styles.stylePreferences.personalMessages = .preset(.casual)
            styles.stylePreferences.workMessages = .preset(.auto)
            assertEqual(styles.stylePreset, .professional, "setDefaultStyle syncs stylePreset")
            assertEqual(styles.defaultStyle, .preset(.professional), "setDefaultStyle writes other")
            assertEqual(styles.resolvedStyleRef(kind: .email, appName: "Mail", bundleID: "com.apple.mail"),
                        .preset(.professional),
                        "email Auto inherits the default style")
            assertEqual(styles.resolvedStyleRef(kind: .personal, appName: "Messages", bundleID: "com.apple.MobileSMS"),
                        .preset(.casual),
                        "personal exception wins over the default")
            assertEqual(styles.resolvedStyleRef(kind: .work, appName: "Linear", bundleID: "com.linear"),
                        .preset(.professional),
                        "work Auto inherits the default style")
            styles.stylePreferences.email = .preset(.emailLetter)
            assertEqual(styles.resolvedStyleRef(kind: .email, appName: "Mail", bundleID: "com.apple.mail"),
                        .preset(.emailLetter),
                        "explicit email exception wins")
            styles.appStyleOverrides = [
                AppStyleOverride(appName: "Slack", bundleID: "com.tinyspeck.slackmacgap", style: .preset(.auto))
            ]
            assertEqual(styles.resolvedStyleRef(kind: .personal, appName: "Slack", bundleID: "com.tinyspeck.slackmacgap"),
                        .preset(.professional),
                        "app override Auto inherits the default style")
            styles.appStyleOverrides = [
                AppStyleOverride(appName: "Slack", bundleID: "com.tinyspeck.slackmacgap", style: .preset(.casual))
            ]
            assertEqual(styles.resolvedStyleRef(kind: .personal, appName: "Slack", bundleID: "com.tinyspeck.slackmacgap"),
                        .preset(.casual),
                        "app override wins over context exception")
            styles.contextAwarenessEnabled = false
            assertEqual(styles.resolvedStyleRef(kind: .email, appName: "Mail", bundleID: "com.apple.mail"),
                        .preset(.professional),
                        "context off always uses the default style")
        }
    }

    private static func assertEqual<T: Equatable>(_ actual: T, _ expected: T, _ label: String) {
        if actual != expected {
            fail("\(label) did not persist. Expected \(expected), got \(actual).")
        }
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("settings persistence check failed: \(message)\n".utf8))
        exit(1)
    }
}
