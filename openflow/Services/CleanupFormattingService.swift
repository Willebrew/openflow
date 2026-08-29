import Foundation

@MainActor
final class CleanupFormattingService {
    private let keychain: KeychainService
    private let cloud: OpenFlowCloudService
    private let endpoint = URL(string: "https://api.groq.com/openai/v1/chat/completions")!

    init(keychain: KeychainService? = nil,
         cloud: OpenFlowCloudService? = nil) {
        self.keychain = keychain ?? .shared
        self.cloud = cloud ?? OpenFlowCloudService()
    }

    func fastClean(rawTranscript: String, context: FormattingContext, settings: UserSettings) -> CleanupResult {
        localFallback(rawTranscript: preparedTranscript(rawTranscript, context: context), context: context, settings: settings)
    }

    func requiresRemoteCleanup(rawTranscript: String,
                               context: FormattingContext,
                               settings: UserSettings) -> Bool {
        if context.usesCustomStyle || context.stylePreset == .emailLetter {
            return true
        }
        if context.category == .terminal ||
            context.stylePreset == .rawTranscript ||
            context.stylePreset == .technicalCodeSafe {
            return false
        }

        let normalized = rawTranscript.lowercased()
        let correctionMarkers = [
            "scratch that", "strike that", "delete that", "ignore that",
            "actually make that", "make that", "change that to",
            "i mean", "no, use", "no use"
        ]
        if correctionMarkers.contains(where: normalized.contains) {
            return true
        }

        let structuralCommands = [
            "new paragraph", "bullet point", "numbered list",
            "quote", "end quote"
        ]
        if structuralCommands.contains(where: normalized.contains) {
            return true
        }

        switch context.stylePreset {
        case .concise, .detailed, .promptMode, .emailLetter:
            return true
        case .auto, .casual, .professional, .rawTranscript, .technicalCodeSafe:
            return false
        }
    }

    func styleRequiresRemoteCleanup(context: FormattingContext) -> Bool {
        if context.usesCustomStyle || context.stylePreset == .emailLetter {
            return true
        }
        if context.category == .terminal ||
            context.stylePreset == .rawTranscript ||
            context.stylePreset == .technicalCodeSafe {
            return false
        }
        switch context.stylePreset {
        case .concise, .detailed, .promptMode, .emailLetter:
            return true
        case .auto, .casual, .professional, .rawTranscript, .technicalCodeSafe:
            return false
        }
    }

    func applyLocalFormatters(to result: CleanupResult,
                              context: FormattingContext,
                              settings: UserSettings,
                              rawTranscript: String? = nil) -> CleanupResult {
        var copy = result
        copy.text = formatted(copy.text,
                              context: context,
                              settings: settings,
                              spokenTranscript: rawTranscript)
        return applyPressEnter(copy, rawTranscript: rawTranscript ?? copy.text, context: context, settings: settings)
    }

    func clean(rawTranscript: String, context: FormattingContext, settings: UserSettings) async throws -> CleanupResult {
        if context.stylePreset == .rawTranscript || context.category == .terminal {
            return localFallback(rawTranscript: rawTranscript, context: context, settings: settings)
        }
        let preparedRawTranscript = preparedTranscript(rawTranscript, context: context)
        let localAPIKey = try keychain.apiKey()
        let hasLocalKey = localAPIKey?.isEmpty == false
        let shouldUseCloud = OpenFlowProviderRouting.usesCloudTranscription(
            providerMode: settings.providerMode,
            hasLocalGroqKey: hasLocalKey
        )
        if shouldUseCloud {
            guard let baseURL = URL(string: settings.cloudBaseURL), !settings.cloudBaseURL.isEmpty else {
                throw OpenflowError.cloudProviderUnavailable("Set the openflow service URL.")
            }
            var result = try await cloud.cleanup(rawTranscript: preparedRawTranscript,
                                                 context: context,
                                                 settings: settings,
                                                 baseURL: baseURL)
            result.text = formatted(result.text,
                                    context: context,
                                    settings: settings,
                                    spokenTranscript: preparedRawTranscript)
            return applyPressEnter(result, rawTranscript: preparedRawTranscript, context: context, settings: settings)
        }
        guard let apiKey = localAPIKey, !apiKey.isEmpty else {
            return localFallback(rawTranscript: preparedRawTranscript, context: context, settings: settings)
        }

        var request = URLRequest(url: endpoint, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(ChatRequest(model: OpenFlowProviderRouting.groqChatModelID(settings.cleanupModel),
                                                                messages: [
                                                                    .init(role: "system", content: Self.systemPrompt),
                                                                    .init(role: "user", content: userPrompt(rawTranscript: preparedRawTranscript, context: context, settings: settings))
                                                                ],
                                                                temperature: 0.05,
                                                                responseFormat: .init(type: "json_object")))
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            return localFallback(rawTranscript: preparedRawTranscript, context: context, settings: settings)
        }
        let decoded = try JSONDecoder().decode(ChatResponse.self, from: data)
        let content = decoded.choices.first?.message.content ?? ""
        if let result = parseCleanupJSON(content) {
            var cleaned = sanitize(result, fallback: preparedRawTranscript)
            cleaned.text = formatted(cleaned.text,
                                     context: context,
                                     settings: settings,
                                     spokenTranscript: preparedRawTranscript)
            return applyPressEnter(cleaned, rawTranscript: preparedRawTranscript, context: context, settings: settings)
        }
        var recovered = CleanupResult(text: extractBestText(content, fallback: preparedRawTranscript),
                                      pressEnter: false,
                                      confidence: 0.4,
                                      notes: "Recovered from non-JSON cleanup response")
        recovered.text = formatted(recovered.text,
                                   context: context,
                                   settings: settings,
                                   spokenTranscript: preparedRawTranscript)
        return applyPressEnter(recovered, rawTranscript: preparedRawTranscript, context: context, settings: settings)
    }

    func generateStyleDraft(request: String, settings: UserSettings) async throws -> CustomStyle {
        let trimmed = request.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw OpenflowError.cleanupFailed("Describe the style you want.")
        }
        let localAPIKey = try keychain.apiKey()
        let hasLocalKey = localAPIKey?.isEmpty == false
        let shouldUseCloud = OpenFlowProviderRouting.usesCloudTranscription(
            providerMode: settings.providerMode,
            hasLocalGroqKey: hasLocalKey
        )
        if shouldUseCloud {
            guard let baseURL = URL(string: settings.cloudBaseURL), !settings.cloudBaseURL.isEmpty else {
                throw OpenflowError.cloudProviderUnavailable("Set the openflow service URL.")
            }
            return try await cloud.generateStyle(request: trimmed, baseURL: baseURL)
        }
        guard let apiKey = localAPIKey, !apiKey.isEmpty else {
            throw OpenflowError.missingAPIKey
        }
        var httpRequest = URLRequest(url: endpoint, timeoutInterval: 30)
        httpRequest.httpMethod = "POST"
        httpRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        httpRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        httpRequest.httpBody = try JSONEncoder().encode(ChatRequest(
            model: OpenFlowProviderRouting.groqChatModelID(settings.cleanupModel),
            messages: [
                .init(role: "system", content: Self.styleDraftPrompt),
                .init(role: "user", content: "Create an OpenFlow cleanup style for this request:\n\(trimmed)")
            ],
            temperature: 0.3,
            responseFormat: .init(type: "json_object")
        ))
        let (data, response) = try await URLSession.shared.data(for: httpRequest)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw OpenflowError.cleanupFailed("Could not generate a style.")
        }
        let decoded = try JSONDecoder().decode(ChatResponse.self, from: data)
        let content = decoded.choices.first?.message.content ?? ""
        guard let draft = parseStyleDraftJSON(content) else {
            throw OpenflowError.cleanupFailed("Could not read the generated style.")
        }
        return draft
    }

    private func userPrompt(rawTranscript: String, context: FormattingContext, settings: UserSettings) -> String {
        let payload = CleanupPromptPayload(rawTranscript: rawTranscript,
                                           activeApp: context.activeAppName,
                                           bundleID: context.bundleID,
                                           appCategory: context.category.rawValue,
                                           browserURL: context.browserURL,
                                           selectedText: settings.contextAwarenessEnabled ? context.selectedText : nil,
                                           nearbyText: settings.contextAwarenessEnabled ? context.nearbyText : nil,
                                           textBefore: settings.contextAwarenessEnabled ? context.textBefore : nil,
                                           textAfter: settings.contextAwarenessEnabled ? context.textAfter : nil,
                                           stylePreset: context.stylePreset.rawValue,
                                           customStylePrompt: context.customStylePrompt,
                                           pressEnterVoiceCommandEnabled: settings.pressEnterCommandEnabled,
                                           personalDictionary: settings.personalDictionary,
                                           emailSignOffName: settings.stylePreferences.emailSignOffName)
        let data = (try? JSONEncoder().encode(payload)) ?? Data()
        let json = String(data: data, encoding: .utf8) ?? "{}"
        return "Clean only the raw_transcript value. text_before and text_after are the field around the caret; continue that document and do not repeat them. Use other fields only as metadata. Input JSON:\n\(json)"
    }

    private func preparedTranscript(_ rawTranscript: String, context: FormattingContext) -> String {
        guard context.category != .terminal,
              context.stylePreset != .rawTranscript,
              !rawTranscript.localizedCaseInsensitiveContains("Selected text:\n") else {
            return rawTranscript
        }
        return SelfCorrectionFormatter.apply(to: rawTranscript)
    }

    private func localFallback(rawTranscript: String, context: FormattingContext, settings: UserSettings) -> CleanupResult {
        var text = rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        let firstPass = PressEnterCommand.resolve(rawTranscript: text, cleanedText: text, enabled: settings.pressEnterCommandEnabled)
        text = firstPass.text
        text = ListFormatter.apply(text, context: context)
        text = SpokenCommandFormatter.apply(to: text)
        for entry in settings.personalDictionary where !entry.term.isEmpty {
            text = text.replacingOccurrences(of: entry.term.lowercased(), with: entry.replacement, options: [.caseInsensitive])
        }
        let result = CleanupResult(text: formatted(text,
                                                   context: context,
                                                   settings: settings,
                                                   spokenTranscript: rawTranscript),
                                     pressEnter: firstPass.pressEnter,
                                     confidence: 0.55,
                                     notes: "Local fallback cleanup")
        return applyPressEnter(result, rawTranscript: rawTranscript, context: context, settings: settings)
    }

    private func applyPressEnter(_ result: CleanupResult,
                                 rawTranscript: String,
                                 context: FormattingContext,
                                 settings: UserSettings) -> CleanupResult {
        var copy = result
        let resolved = PressEnterCommand.resolve(
            rawTranscript: rawTranscript,
            cleanedText: copy.text,
            enabled: settings.pressEnterCommandEnabled
        )
        copy.text = resolved.text
        copy.pressEnter = resolved.pressEnter
        return applySafety(copy)
    }

    private func parseCleanupJSON(_ content: String) -> CleanupResult? {
        guard let data = content.data(using: .utf8) else { return nil }
        if let decoded = try? JSONDecoder().decode(CleanupWireResult.self, from: data) {
            return decoded.result
        }
        guard let start = content.firstIndex(of: "{"), let end = content.lastIndex(of: "}") else { return nil }
        let object = String(content[start...end])
        return try? JSONDecoder().decode(CleanupWireResult.self, from: Data(object.utf8)).result
    }

    private func extractBestText(_ content: String, fallback: String) -> String {
        if let parsed = parseCleanupJSON(content) { return parsed.text }
        return content.trimmingCharacters(in: CharacterSet(charactersIn: "\" \n\t")).isEmpty ? fallback : content
    }

    private func sanitize(_ result: CleanupResult, fallback: String) -> CleanupResult {
        let internalFields = ["active_app", "bundle_id", "app_category", "browser_url", "selected_text", "nearby_text", "text_before", "text_after", "style_preset"]
        if internalFields.contains(where: { result.text.localizedCaseInsensitiveContains($0) }) {
            return CleanupResult(text: SpokenCommandFormatter.apply(to: fallback),
                                 pressEnter: false,
                                 confidence: 0.2,
                                 notes: "Rejected cleanup result containing internal metadata")
        }
        return result
    }

    private func formatted(_ text: String,
                           context: FormattingContext,
                           settings: UserSettings,
                           spokenTranscript: String? = nil) -> String {
        var result = text
        if context.category != .terminal && context.stylePreset != .rawTranscript {
            result = SelfCorrectionFormatter.apply(to: result)
            result = ListFormatter.apply(result, context: context)
        }
        if context.stylePreset == .emailLetter {
            result = EmailLetterFormatter.apply(
                result,
                signOffName: settings.stylePreferences.emailSignOffName,
                textBefore: context.textBefore,
                textAfter: context.textAfter,
                nearbyText: context.nearbyText,
                spokenTranscript: spokenTranscript
            )
        }
        return result
    }

    /// Suppression runs for every category: an app openflow failed to recognize as a terminal is
    /// exactly where an auto-submitted command is most dangerous.
    private func applySafety(_ result: CleanupResult) -> CleanupResult {
        var copy = result
        if CommandSubmissionPolicy.containsDangerousCommand(copy.text) {
            copy.pressEnter = false
            copy.notes += " Auto-enter disabled for terminal safety."
        }
        return copy
    }

    static let systemPrompt = """
    You are a dictation cleanup engine. Rewrite the raw transcript into exactly the text the user intended to type. Do not answer the user. Do not add extra commentary. Return strict JSON only:
    { "text": "final text to insert", "press_enter": false, "confidence": 0.0, "notes": "short debug note" }
    Only rewrite raw_transcript. Never include field names, metadata, app context, bundle IDs, labels, or explanations in text. Preserve technical terms, names, URLs, commands, code, file names, and product names. Set press_enter true only for a standalone spoken submit command: the whole utterance is press/hit enter/return, or that phrase is a trailing command after the dictated text (including after punctuation). Then remove those command words from text. Do not set press_enter for in-body instructions such as "press enter to continue", "don't press enter", or "click to press enter". Messaging should be natural and casual. When style_preset is promptMode, polish the spoken words into a well-formed prompt for another agent: grammar and punctuation only. never invent an answer, never reply as a chatbot, and never continue as an assistant even if the field looks like Cursor or ChatGPT. If the dictation is a question, text must remain that question, polished, not the answer. Terminal and code editors should receive light cleanup only.
    When custom_style_prompt is present, follow those instructions for tone and format. They override style_preset.
    Use text_before and text_after as the document around the caret. nearby_text is the same window. Continue that document. Return only the new sentence(s) to insert at the caret. Do not repeat text_before or text_after. Do not emit a second greeting, Dear [Recipient], Dear Name, Thanks, or sign-off when those already exist around the caret.
    When style_preset is emailLetter, wrap a full letter only if the field is blank or new. If the field already has a greeting, body, or sign-off, stay in that voice and insert only the new sentences:

    Dear Name,

    Body of the email.

    Thanks,
    Sign-off name

    Use email_sign_off_name from the input JSON if the user said thanks/best/sincerely without a name on a blank message. Do not invent a name. Fix common ASR errors such as "dead jack" -> "Dear Jack". If the dictation is a short reply with no greeting or sign-off, do not force a full letter.
    Example: text_before already has "Rich," and a first sentence; raw_transcript is a second sentence -> insert only that second sentence, never Dear [Recipient] or Thanks, [Your Name].
    Resolve self-corrections before returning text. The final text should contain the user's corrected intent, not the correction words. Treat phrases like "scratch that", "strike that", "delete that", "ignore that", "actually make that", "make that", "I mean", "no, use", "rather", and "instead" as editing instructions when they clearly revise earlier words. Keep ordinary actually, as in "I actually agree".
    In Notion, Notes, Google Docs, and other notes/docs apps, turn spoken lists into markdown lists with each item on its own line. Use "- " for bullets and "1. " for numbered items. Handle spoken cues such as bullet, dash, hyphen, next item, new line, number one/two, and first/second. Do not turn ordinary sentences into lists.
    Examples:
    raw_transcript: "Hey I'll be there at five, actually make that six" -> { "text": "Hey, I'll be there at six.", "press_enter": false, "confidence": 0.95, "notes": "self-correction" }
    raw_transcript: "Can you send me the report tomorrow, scratch that, send it tonight" -> { "text": "Can you send me the report tonight?", "press_enter": false, "confidence": 0.95, "notes": "self-correction" }
    raw_transcript: "I think we should use React, no use Svelte" -> { "text": "I think we should use Svelte.", "press_enter": false, "confidence": 0.95, "notes": "self-correction" }
    raw_transcript: "I actually agree" -> { "text": "I actually agree.", "press_enter": false, "confidence": 0.95, "notes": "keep adverb" }
    raw_transcript: "bullet milk bullet eggs bullet bread" -> { "text": "- Milk\\n- Eggs\\n- Bread", "press_enter": false, "confidence": 0.95, "notes": "notion list" }
    raw_transcript: "number one ship Groq number two ship Convex" -> { "text": "1. Ship Groq\\n2. Ship Convex", "press_enter": false, "confidence": 0.95, "notes": "numbered list" }
    raw_transcript: "Dead Jack I hope you're well let's meet Thursday thanks" -> { "text": "Dear Jack,\\n\\nI hope you're well. Let's meet Thursday.\\n\\nThanks,", "press_enter": false, "confidence": 0.95, "notes": "email letter" }
    """

    static let styleDraftPrompt = """
    You write OpenFlow dictation cleanup styles.
    Return strict JSON only: { "name": "short title", "prompt": "instructions for the cleanup model" }.
    The prompt tells the cleanup engine how to rewrite spoken dictation into the text the user meant to type.
    If the request is a Prompt style, the generated prompt must polish the user's words only and forbid answering questions.
    Do not answer the user. Do not include raw transcripts. Do not mention OpenFlow by name in the prompt.
    Name: 2 to 4 words. Prompt: 1 to 6 imperative sentences.
    """

    private func parseStyleDraftJSON(_ content: String) -> CustomStyle? {
        struct Draft: Decodable {
            var name: String
            var prompt: String
        }
        func decode(_ raw: String) -> CustomStyle? {
            guard let parsed = try? JSONDecoder().decode(Draft.self, from: Data(raw.utf8)) else { return nil }
            let name = parsed.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let prompt = parsed.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !prompt.isEmpty else { return nil }
            return CustomStyle(name: String(name.prefix(60)), prompt: String(prompt.prefix(1600)))
        }
        if let draft = decode(content) { return draft }
        guard let start = content.firstIndex(of: "{"), let end = content.lastIndex(of: "}") else { return nil }
        return decode(String(content[start...end]))
    }
}

private struct CleanupPromptPayload: Encodable {
    let rawTranscript: String
    let activeApp: String
    let bundleID: String
    let appCategory: String
    let browserURL: String?
    let selectedText: String?
    let nearbyText: String?
    let textBefore: String?
    let textAfter: String?
    let stylePreset: String
    let customStylePrompt: String?
    let pressEnterVoiceCommandEnabled: Bool
    let personalDictionary: [DictionaryEntry]
    let emailSignOffName: String

    enum CodingKeys: String, CodingKey {
        case rawTranscript = "raw_transcript"
        case activeApp = "active_app"
        case bundleID = "bundle_id"
        case appCategory = "app_category"
        case browserURL = "browser_url"
        case selectedText = "selected_text"
        case nearbyText = "nearby_text"
        case textBefore = "text_before"
        case textAfter = "text_after"
        case stylePreset = "style_preset"
        case customStylePrompt = "custom_style_prompt"
        case pressEnterVoiceCommandEnabled = "press_enter_voice_command_enabled"
        case personalDictionary = "personal_dictionary"
        case emailSignOffName = "email_sign_off_name"
    }
}

private struct CleanupWireResult: Decodable {
    let text: String
    let pressEnter: Bool?
    let press_enter: Bool?
    let confidence: Double?
    let notes: String?

    var result: CleanupResult {
        CleanupResult(text: text,
                      pressEnter: pressEnter ?? press_enter ?? false,
                      confidence: confidence ?? 0.7,
                      notes: notes ?? "")
    }
}

private struct ChatRequest: Encodable {
    let model: String
    let messages: [Message]
    let temperature: Double
    let responseFormat: ResponseFormat

    enum CodingKeys: String, CodingKey {
        case model, messages, temperature
        case responseFormat = "response_format"
    }

    struct Message: Encodable {
        let role: String
        let content: String
    }

    struct ResponseFormat: Encodable {
        let type: String
    }
}

private struct ChatResponse: Decodable {
    let choices: [Choice]

    struct Choice: Decodable {
        let message: Message
    }

    struct Message: Decodable {
        let content: String
    }
}

enum SpokenCommandFormatter {
    static func apply(to input: String) -> String {
        var text = input
        let replacements: [(String, String)] = [
            (#"\bnew paragraph\b"#, "\n\n"),
            (#"\bnew line\b"#, "\n"),
            (#"\bperiod\b"#, "."),
            (#"\bcomma\b"#, ","),
            (#"\bquestion mark\b"#, "?"),
            (#"\bexclamation point\b"#, "!"),
            (#"\bcolon\b"#, ":"),
            (#"\bsemicolon\b"#, ";"),
            (#"\bopen parenthesis\b"#, " ("),
            (#"\bclose parenthesis\b"#, ")"),
            (#"\bdash\b"#, " - "),
            (#"\bbullet point\b"#, "\n- "),
            (#"\bquote\b"#, " \""),
            (#"\bend quote\b"#, "\"")
        ]
        for (pattern, symbol) in replacements {
            text = regexReplace(text, pattern: pattern, replacement: symbol)
        }
        text = regexReplace(text, pattern: #"[ \t]+([,.?!:;])"#, replacement: "$1")
        text = regexReplace(text, pattern: #"\n-\s+"#, replacement: "\n- ")
        text = regexReplace(text, pattern: #" {2,}"#, replacement: " ")
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func regexReplace(_ text: String, pattern: String, replacement: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: replacement)
    }
}
