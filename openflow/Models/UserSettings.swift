import Foundation
import Combine

enum HotkeyMode: String, CaseIterable, Codable, Identifiable {
    case optionHold
    case controlSpace
    case optionSpace
    case fnHold

    var id: String { rawValue }

    var label: String {
        switch self {
        case .optionHold: "Hold Option"
        case .controlSpace: "Control+Space"
        case .optionSpace: "Option+Space"
        case .fnHold: "Hold Fn"
        }
    }

    var keycapLabel: String {
        switch self {
        case .optionHold: "Option"
        case .controlSpace: "Control+Space"
        case .optionSpace: "Option+Space"
        case .fnHold: "Fn"
        }
    }

    var dictationInstruction: String {
        "Hold \(keycapLabel), speak, release."
    }

    /// Tap-style shortcuts must swallow keys (Control+Space vs Spotlight). Hold Fn / Hold Option
    /// are observational and do not need an event tap or Input Monitoring.
    var requiresEventTap: Bool {
        switch self {
        case .controlSpace, .optionSpace:
            true
        case .fnHold, .optionHold:
            false
        }
    }
}

enum DictationActivationMode: String, Codable {
    case pushToTalk
    case toggle
}

enum StylePreset: String, CaseIterable, Codable, Identifiable {
    case auto
    case casual
    case professional
    case concise
    case detailed
    case rawTranscript
    case promptMode
    case technicalCodeSafe
    case emailLetter

    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto: "Auto"
        case .casual: "Casual"
        case .professional: "Professional"
        case .concise: "Concise"
        case .detailed: "Detailed"
        case .rawTranscript: "Raw transcript"
        case .promptMode: "Prompt mode"
        case .technicalCodeSafe: "Technical/code-safe"
        case .emailLetter: "Email letter"
        }
    }

    var symbolName: String {
        switch self {
        case .auto: "textformat"
        case .casual: "message"
        case .professional: "briefcase"
        case .concise: "text.alignleft"
        case .detailed: "doc.text"
        case .rawTranscript: "quote.bubble"
        case .promptMode: "terminal"
        case .technicalCodeSafe: "chevron.left.forwardslash.chevron.right"
        case .emailLetter: "envelope"
        }
    }

    var summary: String {
        switch self {
        case .auto: "Pick the tone from context."
        case .casual: "Natural and conversational."
        case .professional: "Clear and polished."
        case .concise: "Short and direct."
        case .detailed: "Keep more structure."
        case .rawTranscript: "Minimal cleanup."
        case .promptMode: "Preserve instructions."
        case .technicalCodeSafe: "Protect code terms."
        case .emailLetter: "Dear Name, body, then Thanks — with blank lines."
        }
    }
}

struct StyleRef: Hashable, Codable, Identifiable {
    var rawValue: String

    var id: String { rawValue }

    static func preset(_ preset: StylePreset) -> StyleRef {
        StyleRef(rawValue: preset.rawValue)
    }

    static func custom(_ id: UUID) -> StyleRef {
        StyleRef(rawValue: "custom:\(id.uuidString)")
    }

    var preset: StylePreset? {
        StylePreset(rawValue: rawValue)
    }

    var customID: UUID? {
        guard rawValue.hasPrefix("custom:") else { return nil }
        return UUID(uuidString: String(rawValue.dropFirst("custom:".count)))
    }

    var isCustom: Bool { customID != nil }

    func label(customStyles: [CustomStyle]) -> String {
        if let preset { return preset.label }
        if let customID, let match = customStyles.first(where: { $0.id == customID }) {
            return match.name
        }
        return "Custom"
    }

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        rawValue = try container.decode(String.self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

struct CustomStyle: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var prompt: String
}

enum ProviderMode: String, CaseIterable, Codable, Identifiable {
    case automatic
    case localGroq
    case openflowCloud

    var id: String { rawValue }

    var label: String {
        switch self {
        case .automatic: "Automatic"
        case .localGroq: "Bring your own Groq key"
        case .openflowCloud: "openflow Pro"
        }
    }
}

@MainActor
final class UserSettings: ObservableObject {
    @Published var provider: String {
        didSet { defaults.set(provider, forKey: Keys.provider) }
    }
    @Published var providerMode: ProviderMode {
        didSet { defaults.set(providerMode.rawValue, forKey: Keys.providerMode) }
    }
    @Published var cloudBaseURL: String {
        didSet { defaults.set(cloudBaseURL, forKey: Keys.cloudBaseURL) }
    }
    @Published var transcriptionModel: String {
        didSet { defaults.set(transcriptionModel, forKey: Keys.transcriptionModel) }
    }
    @Published var fallbackTranscriptionModel: String {
        didSet { defaults.set(fallbackTranscriptionModel, forKey: Keys.fallbackTranscriptionModel) }
    }
    @Published var cleanupModel: String {
        didSet { defaults.set(cleanupModel, forKey: Keys.cleanupModel) }
    }
    @Published var pushToTalkHotkey: HotkeyMode {
        didSet {
            defaults.set(pushToTalkHotkey.rawValue, forKey: Keys.pushToTalkHotkey)
            defaults.synchronize()
        }
    }
    @Published var toggleHotkey: HotkeyMode {
        didSet {
            defaults.set(toggleHotkey.rawValue, forKey: Keys.toggleHotkey)
            defaults.synchronize()
        }
    }
    @Published var stylePreset: StylePreset {
        didSet { defaults.set(stylePreset.rawValue, forKey: Keys.stylePreset) }
    }
    @Published var microphoneDeviceID: String {
        didSet { defaults.set(microphoneDeviceID, forKey: Keys.microphoneDeviceID) }
    }
    @Published var historyEnabled: Bool {
        didSet { defaults.set(historyEnabled, forKey: Keys.historyEnabled) }
    }
    @Published var storeRawTranscript: Bool {
        didSet { defaults.set(storeRawTranscript, forKey: Keys.storeRawTranscript) }
    }
    @Published var contextAwarenessEnabled: Bool {
        didSet { defaults.set(contextAwarenessEnabled, forKey: Keys.contextAwarenessEnabled) }
    }
    @Published var browserURLDetectionEnabled: Bool {
        didSet { defaults.set(browserURLDetectionEnabled, forKey: Keys.browserURLDetectionEnabled) }
    }
    @Published var pressEnterCommandEnabled: Bool {
        didSet { defaults.set(pressEnterCommandEnabled, forKey: Keys.pressEnterCommandEnabled) }
    }
    @Published var hideInactivePill: Bool {
        didSet { defaults.set(hideInactivePill, forKey: Keys.hideInactivePill) }
    }
    @Published var debugLogsEnabled: Bool {
        didSet { defaults.set(debugLogsEnabled, forKey: Keys.debugLogsEnabled) }
    }
    @Published var showTechnicalInsertionDetails: Bool {
        didSet { defaults.set(showTechnicalInsertionDetails, forKey: Keys.showTechnicalInsertionDetails) }
    }
    @Published var personalDictionary: [DictionaryEntry] {
        didSet { saveDictionary() }
    }
    @Published var phrases: [PhraseEntry] {
        didSet { savePhrases() }
    }
    @Published var stylePreferences: StylePreferences {
        didSet { saveStylePreferences() }
    }
    @Published var appStyleOverrides: [AppStyleOverride] {
        didSet { saveAppStyleOverrides() }
    }
    @Published var customStyles: [CustomStyle] {
        didSet { saveCustomStyles() }
    }

    private static let maxSyncedDictionaryEntries = 200
    private static let maxSyncedPhrases = 200
    private static let maxSyncedAppOverrides = 80
    private static let maxSyncedCustomStyles = 24

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        provider = defaults.string(forKey: Keys.provider) ?? "groq"
        if let storedMode = ProviderMode(rawValue: defaults.string(forKey: Keys.providerMode) ?? "") {
            providerMode = storedMode == .automatic ? .localGroq : storedMode
        } else {
            providerMode = .openflowCloud
        }
        let storedCloudURL = defaults.string(forKey: Keys.cloudBaseURL)
        let retiredCloudURLs = [
            "https://openflow.neuroquestlabs.ai",
            "https://openflow-convex-site.jottly.ai"
        ]
        cloudBaseURL = storedCloudURL == nil || retiredCloudURLs.contains(storedCloudURL!)
            ? "https://openflow-site-cvx.jottly.ai"
            : storedCloudURL!
        transcriptionModel = defaults.string(forKey: Keys.transcriptionModel) ?? "whisper-large-v3-turbo"
        fallbackTranscriptionModel = defaults.string(forKey: Keys.fallbackTranscriptionModel) ?? "whisper-large-v3"
        cleanupModel = defaults.string(forKey: Keys.cleanupModel) ?? "gpt-oss-20b"
        pushToTalkHotkey = HotkeyMode(rawValue: defaults.string(forKey: Keys.pushToTalkHotkey) ?? "") ?? .fnHold
        toggleHotkey = HotkeyMode(rawValue: defaults.string(forKey: Keys.toggleHotkey) ?? "") ?? .controlSpace
        stylePreset = StylePreset(rawValue: defaults.string(forKey: Keys.stylePreset) ?? "") ?? .auto
        microphoneDeviceID = defaults.string(forKey: Keys.microphoneDeviceID) ?? ""
        historyEnabled = defaults.object(forKey: Keys.historyEnabled) as? Bool ?? true
        storeRawTranscript = defaults.object(forKey: Keys.storeRawTranscript) as? Bool ?? false
        contextAwarenessEnabled = defaults.object(forKey: Keys.contextAwarenessEnabled) as? Bool ?? true
        browserURLDetectionEnabled = defaults.object(forKey: Keys.browserURLDetectionEnabled) as? Bool ?? true
        pressEnterCommandEnabled = defaults.object(forKey: Keys.pressEnterCommandEnabled) as? Bool ?? true
        hideInactivePill = defaults.object(forKey: Keys.hideInactivePill) as? Bool ?? false
        debugLogsEnabled = defaults.object(forKey: Keys.debugLogsEnabled) as? Bool ?? false
        showTechnicalInsertionDetails = defaults.object(forKey: Keys.showTechnicalInsertionDetails) as? Bool ?? false
        if let data = defaults.data(forKey: Keys.personalDictionary),
           let decoded = try? JSONDecoder().decode([DictionaryEntry].self, from: data) {
            personalDictionary = decoded
        } else {
            personalDictionary = []
        }
        let storedPhrases = defaults.data(forKey: Keys.phrases)
        let storedLegacySnippets = defaults.data(forKey: Keys.legacySnippets)
        if let data = storedPhrases ?? storedLegacySnippets,
           let decoded = try? JSONDecoder().decode([PhraseEntry].self, from: data) {
            phrases = decoded
        } else {
            phrases = []
        }
        if let data = defaults.data(forKey: Keys.stylePreferences),
           let decoded = try? JSONDecoder().decode(StylePreferences.self, from: data) {
            stylePreferences = decoded
        } else {
            stylePreferences = StylePreferences()
        }
        if let data = defaults.data(forKey: Keys.appStyleOverrides),
           let decoded = try? JSONDecoder().decode([AppStyleOverride].self, from: data) {
            appStyleOverrides = decoded
        } else {
            appStyleOverrides = []
        }
        if let data = defaults.data(forKey: Keys.customStyles),
           let decoded = try? JSONDecoder().decode([CustomStyle].self, from: data) {
            customStyles = decoded
        } else {
            customStyles = []
        }
        if storedPhrases == nil, storedLegacySnippets != nil, !phrases.isEmpty {
            savePhrases()
        }
    }

    private func saveDictionary() {
        guard let data = try? JSONEncoder().encode(personalDictionary) else { return }
        defaults.set(data, forKey: Keys.personalDictionary)
    }

    private func savePhrases() {
        guard let data = try? JSONEncoder().encode(phrases) else { return }
        defaults.set(data, forKey: Keys.phrases)
        defaults.removeObject(forKey: Keys.legacySnippets)
    }

    private func saveStylePreferences() {
        guard let data = try? JSONEncoder().encode(stylePreferences) else { return }
        defaults.set(data, forKey: Keys.stylePreferences)
    }

    private func saveAppStyleOverrides() {
        guard let data = try? JSONEncoder().encode(appStyleOverrides) else { return }
        defaults.set(data, forKey: Keys.appStyleOverrides)
    }

    private func saveCustomStyles() {
        guard let data = try? JSONEncoder().encode(customStyles) else { return }
        defaults.set(data, forKey: Keys.customStyles)
    }

    var styleChoices: [StyleRef] {
        StylePreset.allCases.map(StyleRef.preset) + customStyles.map { StyleRef.custom($0.id) }
    }

    /// Default voice: used unless a context or app exception applies.
    var defaultStyle: StyleRef { stylePreferences.other }

    enum StyleContextKind {
        case personal
        case work
        case email
        case other
    }

    func label(for ref: StyleRef) -> String {
        ref.label(customStyles: customStyles)
    }

    func summary(for ref: StyleRef) -> String {
        if let preset = ref.preset { return preset.summary }
        if let customID = ref.customID,
           let match = customStyles.first(where: { $0.id == customID }) {
            let prompt = match.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            return prompt.isEmpty ? "Custom cleanup instructions." : prompt
        }
        return "Custom cleanup instructions."
    }

    func symbolName(for ref: StyleRef) -> String {
        ref.preset?.symbolName ?? "paintbrush.pointed"
    }

    func setDefaultStyle(_ ref: StyleRef) {
        var prefs = stylePreferences
        prefs.other = ref
        stylePreferences = prefs
        stylePreset = ref.preset ?? .auto
    }

    func inheritIfAuto(_ ref: StyleRef) -> StyleRef {
        ref.preset == .auto ? defaultStyle : ref
    }

    func resolvedStyleRef(kind: StyleContextKind, appName: String, bundleID: String) -> StyleRef {
        guard contextAwarenessEnabled else { return defaultStyle }
        if let override = appStyleOverrides.first(where: { entry in
            if !entry.bundleID.isEmpty, !bundleID.isEmpty {
                return entry.bundleID == bundleID
            }
            return entry.appName.localizedCaseInsensitiveCompare(appName) == .orderedSame
        }) {
            return inheritIfAuto(override.style)
        }
        switch kind {
        case .personal: return inheritIfAuto(stylePreferences.personalMessages)
        case .work: return inheritIfAuto(stylePreferences.workMessages)
        case .email: return inheritIfAuto(stylePreferences.email)
        case .other: return defaultStyle
        }
    }

    func removeCustomStyle(_ style: CustomStyle) {
        customStyles.removeAll { $0.id == style.id }
        let fallback = StyleRef.preset(.auto)
        if stylePreferences.personalMessages.customID == style.id {
            stylePreferences.personalMessages = fallback
        }
        if stylePreferences.workMessages.customID == style.id {
            stylePreferences.workMessages = fallback
        }
        if stylePreferences.email.customID == style.id {
            stylePreferences.email = fallback
        }
        if stylePreferences.other.customID == style.id {
            setDefaultStyle(fallback)
        }
        for index in appStyleOverrides.indices where appStyleOverrides[index].style.customID == style.id {
            appStyleOverrides[index].style = fallback
        }
    }

    func cloudSnapshot() -> CloudPreferencesSnapshot {
        CloudPreferencesSnapshot(
            pushToTalkHotkey: pushToTalkHotkey,
            toggleHotkey: toggleHotkey,
            stylePreset: stylePreset,
            microphoneDeviceID: microphoneDeviceID,
            historyEnabled: historyEnabled,
            storeRawTranscript: storeRawTranscript,
            showTechnicalInsertionDetails: showTechnicalInsertionDetails,
            contextAwarenessEnabled: contextAwarenessEnabled,
            browserURLDetectionEnabled: browserURLDetectionEnabled,
            pressEnterCommandEnabled: pressEnterCommandEnabled,
            hideInactivePill: hideInactivePill,
            personalDictionary: personalDictionary,
            phrases: phrases,
            stylePreferences: stylePreferences,
            appStyleOverrides: appStyleOverrides,
            customStyles: customStyles
        )
    }

    func applyCloudSnapshot(_ snapshot: CloudPreferencesSnapshot) {
        pushToTalkHotkey = snapshot.pushToTalkHotkey
        toggleHotkey = snapshot.toggleHotkey
        stylePreset = snapshot.stylePreset
        if let microphoneDeviceID = snapshot.microphoneDeviceID {
            self.microphoneDeviceID = microphoneDeviceID
        }
        if let historyEnabled = snapshot.historyEnabled {
            self.historyEnabled = historyEnabled
        }
        if let storeRawTranscript = snapshot.storeRawTranscript {
            self.storeRawTranscript = storeRawTranscript
        }
        if let showTechnicalInsertionDetails = snapshot.showTechnicalInsertionDetails {
            self.showTechnicalInsertionDetails = showTechnicalInsertionDetails
        }
        // contextAwarenessEnabled and pressEnterCommandEnabled stay device-local.
        // A compromised preferences payload must not hide terminal classification
        // or turn spoken Return on.
        browserURLDetectionEnabled = snapshot.browserURLDetectionEnabled
        hideInactivePill = snapshot.hideInactivePill
        personalDictionary = boundedDictionary(snapshot.personalDictionary)
        phrases = boundedPhrases(snapshot.phrases)
        stylePreferences = snapshot.stylePreferences
        appStyleOverrides = boundedAppStyleOverrides(snapshot.appStyleOverrides)
        customStyles = boundedCustomStyles(snapshot.customStyles)
    }

    private func boundedDictionary(_ entries: [DictionaryEntry]) -> [DictionaryEntry] {
        Array(entries.prefix(Self.maxSyncedDictionaryEntries)).map { entry in
            DictionaryEntry(id: entry.id,
                            term: String(entry.term.prefix(80)),
                            replacement: String(entry.replacement.prefix(120)))
        }
    }

    private func boundedPhrases(_ entries: [PhraseEntry]) -> [PhraseEntry] {
        Array(entries.prefix(Self.maxSyncedPhrases)).map { entry in
            PhraseEntry(id: entry.id,
                        trigger: String(entry.trigger.prefix(80)),
                        expansion: String(entry.expansion.prefix(500)))
        }
    }

    private func boundedAppStyleOverrides(_ entries: [AppStyleOverride]) -> [AppStyleOverride] {
        Array(entries.prefix(Self.maxSyncedAppOverrides))
    }

    private func boundedCustomStyles(_ entries: [CustomStyle]) -> [CustomStyle] {
        Array(entries.prefix(Self.maxSyncedCustomStyles)).map { style in
            CustomStyle(id: style.id,
                        name: String(style.name.prefix(60)),
                        prompt: String(style.prompt.prefix(1_600)))
        }
    }

    var usesSwallowingHotkey: Bool {
        pushToTalkHotkey.requiresEventTap
            || toggleHotkey.requiresEventTap
    }

    private enum Keys {
        static let provider = "provider"
        static let providerMode = "providerMode"
        static let cloudBaseURL = "cloudBaseURL"
        static let transcriptionModel = "transcriptionModel"
        static let fallbackTranscriptionModel = "fallbackTranscriptionModel"
        static let cleanupModel = "cleanupModel"
        static let pushToTalkHotkey = "pushToTalkHotkey"
        static let toggleHotkey = "toggleHotkey"
        static let stylePreset = "stylePreset"
        static let microphoneDeviceID = "microphoneDeviceID"
        static let historyEnabled = "historyEnabled"
        static let storeRawTranscript = "storeRawTranscript"
        static let contextAwarenessEnabled = "contextAwarenessEnabled"
        static let browserURLDetectionEnabled = "browserURLDetectionEnabled"
        static let pressEnterCommandEnabled = "pressEnterCommandEnabled"
        static let hideInactivePill = "hideInactivePill"
        static let debugLogsEnabled = "debugLogsEnabled"
        static let showTechnicalInsertionDetails = "showTechnicalInsertionDetails"
        static let personalDictionary = "personalDictionary"
        static let phrases = "phrases"
        static let legacySnippets = "snippets"
        static let stylePreferences = "stylePreferences"
        static let appStyleOverrides = "appStyleOverrides"
        static let customStyles = "customStyles"
    }
}

struct CloudPreferencesSnapshot: Codable, Equatable {
    var pushToTalkHotkey: HotkeyMode
    var toggleHotkey: HotkeyMode
    var stylePreset: StylePreset
    var microphoneDeviceID: String?
    var historyEnabled: Bool?
    var storeRawTranscript: Bool?
    var showTechnicalInsertionDetails: Bool?
    var contextAwarenessEnabled: Bool
    var browserURLDetectionEnabled: Bool
    var pressEnterCommandEnabled: Bool
    var hideInactivePill: Bool
    var personalDictionary: [DictionaryEntry]
    var phrases: [PhraseEntry]
    var stylePreferences: StylePreferences
    var appStyleOverrides: [AppStyleOverride]
    var customStyles: [CustomStyle]

    enum CodingKeys: String, CodingKey {
        case pushToTalkHotkey
        case toggleHotkey
        case stylePreset
        case microphoneDeviceID
        case historyEnabled
        case storeRawTranscript
        case showTechnicalInsertionDetails
        case contextAwarenessEnabled
        case browserURLDetectionEnabled
        case pressEnterCommandEnabled
        case hideInactivePill
        case personalDictionary
        case phrases
        case snippets
        case stylePreferences
        case appStyleOverrides
        case customStyles
    }

    init(pushToTalkHotkey: HotkeyMode,
         toggleHotkey: HotkeyMode,
         stylePreset: StylePreset,
         microphoneDeviceID: String? = nil,
         historyEnabled: Bool?,
         storeRawTranscript: Bool?,
         showTechnicalInsertionDetails: Bool?,
         contextAwarenessEnabled: Bool,
         browserURLDetectionEnabled: Bool,
         pressEnterCommandEnabled: Bool,
         hideInactivePill: Bool,
         personalDictionary: [DictionaryEntry],
         phrases: [PhraseEntry],
         stylePreferences: StylePreferences,
         appStyleOverrides: [AppStyleOverride],
         customStyles: [CustomStyle] = []) {
        self.pushToTalkHotkey = pushToTalkHotkey
        self.toggleHotkey = toggleHotkey
        self.stylePreset = stylePreset
        self.microphoneDeviceID = microphoneDeviceID
        self.historyEnabled = historyEnabled
        self.storeRawTranscript = storeRawTranscript
        self.showTechnicalInsertionDetails = showTechnicalInsertionDetails
        self.contextAwarenessEnabled = contextAwarenessEnabled
        self.browserURLDetectionEnabled = browserURLDetectionEnabled
        self.pressEnterCommandEnabled = pressEnterCommandEnabled
        self.hideInactivePill = hideInactivePill
        self.personalDictionary = personalDictionary
        self.phrases = phrases
        self.stylePreferences = stylePreferences
        self.appStyleOverrides = appStyleOverrides
        self.customStyles = customStyles
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        pushToTalkHotkey = try values.decode(HotkeyMode.self, forKey: .pushToTalkHotkey)
        toggleHotkey = try values.decode(HotkeyMode.self, forKey: .toggleHotkey)
        stylePreset = try values.decode(StylePreset.self, forKey: .stylePreset)
        microphoneDeviceID = try values.decodeIfPresent(String.self, forKey: .microphoneDeviceID)
        historyEnabled = try values.decodeIfPresent(Bool.self, forKey: .historyEnabled)
        storeRawTranscript = try values.decodeIfPresent(Bool.self, forKey: .storeRawTranscript)
        showTechnicalInsertionDetails = try values.decodeIfPresent(Bool.self, forKey: .showTechnicalInsertionDetails)
        contextAwarenessEnabled = try values.decode(Bool.self, forKey: .contextAwarenessEnabled)
        browserURLDetectionEnabled = try values.decode(Bool.self, forKey: .browserURLDetectionEnabled)
        pressEnterCommandEnabled = try values.decode(Bool.self, forKey: .pressEnterCommandEnabled)
        hideInactivePill = try values.decode(Bool.self, forKey: .hideInactivePill)
        personalDictionary = try values.decode([DictionaryEntry].self, forKey: .personalDictionary)
        phrases = try values.decodeIfPresent([PhraseEntry].self, forKey: .phrases)
            ?? values.decodeIfPresent([PhraseEntry].self, forKey: .snippets)
            ?? []
        stylePreferences = try values.decode(StylePreferences.self, forKey: .stylePreferences)
        appStyleOverrides = try values.decode([AppStyleOverride].self, forKey: .appStyleOverrides)
        customStyles = try values.decodeIfPresent([CustomStyle].self, forKey: .customStyles) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(pushToTalkHotkey, forKey: .pushToTalkHotkey)
        try container.encode(toggleHotkey, forKey: .toggleHotkey)
        try container.encode(stylePreset, forKey: .stylePreset)
        try container.encodeIfPresent(microphoneDeviceID, forKey: .microphoneDeviceID)
        try container.encodeIfPresent(historyEnabled, forKey: .historyEnabled)
        try container.encodeIfPresent(storeRawTranscript, forKey: .storeRawTranscript)
        try container.encodeIfPresent(showTechnicalInsertionDetails, forKey: .showTechnicalInsertionDetails)
        try container.encode(contextAwarenessEnabled, forKey: .contextAwarenessEnabled)
        try container.encode(browserURLDetectionEnabled, forKey: .browserURLDetectionEnabled)
        try container.encode(pressEnterCommandEnabled, forKey: .pressEnterCommandEnabled)
        try container.encode(hideInactivePill, forKey: .hideInactivePill)
        try container.encode(personalDictionary, forKey: .personalDictionary)
        try container.encode(phrases, forKey: .phrases)
        try container.encode(stylePreferences, forKey: .stylePreferences)
        try container.encode(appStyleOverrides, forKey: .appStyleOverrides)
        try container.encode(customStyles, forKey: .customStyles)
    }
}

struct DictionaryEntry: Codable, Identifiable, Hashable {
    var id = UUID()
    var term: String
    var replacement: String
}

struct PhraseEntry: Codable, Identifiable, Hashable {
    var id = UUID()
    var trigger: String
    var expansion: String
}

struct StylePreferences: Codable, Hashable {
    var personalMessages: StyleRef = .preset(.casual)
    var workMessages: StyleRef = .preset(.professional)
    var email: StyleRef = .preset(.emailLetter)
    var other: StyleRef = .preset(.auto)
    var emailSignOffName: String = ""

    enum CodingKeys: String, CodingKey {
        case personalMessages
        case workMessages
        case email
        case other
        case emailSignOffName
    }

    init(personalMessages: StylePreset = .casual,
         workMessages: StylePreset = .professional,
         email: StylePreset = .emailLetter,
         other: StylePreset = .auto,
         emailSignOffName: String = "") {
        self.personalMessages = .preset(personalMessages)
        self.workMessages = .preset(workMessages)
        self.email = .preset(email)
        self.other = .preset(other)
        self.emailSignOffName = emailSignOffName
    }

    init(personalMessages: StyleRef,
         workMessages: StyleRef,
         email: StyleRef,
         other: StyleRef,
         emailSignOffName: String = "") {
        self.personalMessages = personalMessages
        self.workMessages = workMessages
        self.email = email
        self.other = other
        self.emailSignOffName = emailSignOffName
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        personalMessages = try values.decodeIfPresent(StyleRef.self, forKey: .personalMessages) ?? .preset(.casual)
        workMessages = try values.decodeIfPresent(StyleRef.self, forKey: .workMessages) ?? .preset(.professional)
        email = try values.decodeIfPresent(StyleRef.self, forKey: .email) ?? .preset(.emailLetter)
        other = try values.decodeIfPresent(StyleRef.self, forKey: .other) ?? .preset(.auto)
        emailSignOffName = try values.decodeIfPresent(String.self, forKey: .emailSignOffName) ?? ""
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(personalMessages, forKey: .personalMessages)
        try container.encode(workMessages, forKey: .workMessages)
        try container.encode(email, forKey: .email)
        try container.encode(other, forKey: .other)
        try container.encode(emailSignOffName, forKey: .emailSignOffName)
    }
}

struct AppStyleOverride: Codable, Identifiable, Hashable {
    var id = UUID()
    var appName: String
    var bundleID: String
    var style: StyleRef

    init(id: UUID = UUID(), appName: String, bundleID: String, style: StyleRef) {
        self.id = id
        self.appName = appName
        self.bundleID = bundleID
        self.style = style
    }

    init(id: UUID = UUID(), appName: String, bundleID: String, style: StylePreset) {
        self.init(id: id, appName: appName, bundleID: bundleID, style: .preset(style))
    }
}
