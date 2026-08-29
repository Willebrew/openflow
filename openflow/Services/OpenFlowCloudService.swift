import AVFoundation
import Foundation

struct OpenFlowCloudEntitlement: Decodable {
    var canUseCloud: Bool
    var canTranscribe: Bool?
    var tier: String?
    var status: String
    var plan: String?
    var expiresAt: Date?
    var periodKey: String?
    var wordsUsed: Int?
    var wordsRemaining: Int?
    var wordLimit: Int?
    var deviceCount: Int?
    var maxDevices: Int?

    private enum CodingKeys: String, CodingKey {
        case canUseCloud
        case canTranscribe
        case tier
        case status
        case plan
        case expiresAt
        case periodKey
        case wordsUsed
        case wordsRemaining
        case wordLimit
        case deviceCount
        case maxDevices
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        canUseCloud = try values.decodeIfPresent(Bool.self, forKey: .canUseCloud) ?? false
        canTranscribe = try values.decodeIfPresent(Bool.self, forKey: .canTranscribe)
        tier = try values.decodeIfPresent(String.self, forKey: .tier)
        status = try values.decodeIfPresent(String.self, forKey: .status)
            ?? (canUseCloud ? "active" : "signed_out")
        plan = try values.decodeIfPresent(String.self, forKey: .plan)
        expiresAt = try values.decodeIfPresent(Date.self, forKey: .expiresAt)
        periodKey = try values.decodeIfPresent(String.self, forKey: .periodKey)
        wordsUsed = try values.decodeIfPresent(Int.self, forKey: .wordsUsed)
        wordsRemaining = try values.decodeIfPresent(Int.self, forKey: .wordsRemaining)
        wordLimit = try values.decodeIfPresent(Int.self, forKey: .wordLimit)
        deviceCount = try values.decodeIfPresent(Int.self, forKey: .deviceCount)
        maxDevices = try values.decodeIfPresent(Int.self, forKey: .maxDevices)
    }
}

extension OpenFlowCloudEntitlement {
    var cancelAtPeriodEndDescription: String {
        if tier == "pro" {
            return "openflow Pro is active."
        }
        if tier == "free", let remaining = wordsRemaining, let limit = wordLimit {
            return "\(remaining.formatted()) of \(limit.formatted()) free words remaining this month."
        }
        return canUseCloud ? "openflow Free is active." : "Sign in to use openflow."
    }
}

struct OpenFlowCloudTranscriptionResponse: Codable {
    var text: String
    var rawText: String?
    var model: String
    var provider: String
    var duration: TimeInterval?
    var requestTime: TimeInterval?
    var tReceiveAudio: TimeInterval?
    var tGroqHttp: TimeInterval?
    var tTotal: TimeInterval?
    var cleanupApplied: Bool?
    var cleanedText: String?
    var pressEnter: Bool?
    var confidence: Double?
    var notes: String?
    var timings: OpenFlowCloudTranscribeTimings?

    enum CodingKeys: String, CodingKey {
        case text
        case rawText
        case model
        case provider
        case duration
        case requestTime
        case tReceiveAudio = "t_receive_audio"
        case tGroqHttp = "t_groq_http"
        case tTotal = "t_total"
        case cleanupApplied
        case cleanedText
        case pressEnter
        case confidence
        case notes
        case timings
    }

    var whisperText: String {
        if let rawText, !rawText.isEmpty { return rawText }
        return text
    }
}

struct OpenFlowCloudTranscribeTimings: Codable {
    var receivedAt: Double?
    var groqStartedAt: Double?
    var groqFinishedAt: Double?
    var groqRoundTripMs: Double?
    var convexHandlerMs: Double?
    var cerebrasRoundTripMs: Double?
    var cleanupAuthMs: Double?
    var introspectMs: Double?
    var blobMs: Double?
    var authorizeMs: Double?
    var formDataMs: Double?
    var introspectionCacheHit: Bool?
}

struct OpenFlowCloudCleanupResponse: Codable {
    var text: String
    var pressEnter: Bool
    var confidence: Double
    var notes: String
}

struct OpenFlowCloudBillingLink: Codable {
    var url: URL
}

struct OpenFlowCloudStats: Codable, Equatable {
    struct Day: Codable, Equatable {
        var dayKey: String
        var words: Int
        var audioSeconds: Double
        var dictations: Int
    }

    struct Lifetime: Codable, Equatable {
        var words: Int = 0
        var audioSeconds: Double = 0
        var dictations: Int = 0
        var averageWPM: Double?
        var audioBytes: Int?
        var timeSavedSeconds: Double?
        var cleanupCount: Int?
        var transcriptionErrors: Int?
        var cleanupErrors: Int?
        var groqCleanupInputTokens: Int?
        var groqCleanupOutputTokens: Int?
        var groqCostMicros: Int?
        var freeDictations: Int?
        var proDictations: Int?
    }

    struct App: Codable, Equatable {
        var appName: String
        var bundleID: String?
        var words: Int
        var dictations: Int?
        var audioSeconds: Double?
    }

    var days: [Day] = []
    var apps: [App]?
    var lifetime: Lifetime?

    var totalWords: Int { days.reduce(0) { $0 + $1.words } }
    var totalAudioSeconds: Double { days.reduce(0) { $0 + $1.audioSeconds } }
    var lifetimeWords: Int { max(lifetime?.words ?? 0, totalWords) }
    var lifetimeAudioSeconds: Double { max(lifetime?.audioSeconds ?? 0, totalAudioSeconds) }
    var lifetimeAverageWPM: Int {
        if let reported = lifetime?.averageWPM, reported > 0 {
            return Int(reported)
        }
        guard lifetimeWords > 0, lifetimeAudioSeconds > 0 else { return 0 }
        return Int((Double(lifetimeWords) / lifetimeAudioSeconds) * 60.0)
    }

    /// Keep previously shown apps when a later GET is shorter or omits one (race / old top-N cap).
    func mergingIncoming(_ incoming: OpenFlowCloudStats) -> OpenFlowCloudStats {
        var merged = incoming
        let incomingApps = incoming.apps
        if incomingApps == nil {
            merged.apps = apps
        } else if incomingApps?.isEmpty == true, let existing = apps, !existing.isEmpty {
            merged.apps = existing
        } else {
            let previous = (apps ?? []).map {
                HomeAppStat(appName: $0.appName, bundleID: $0.bundleID, words: $0.words, audioSeconds: $0.audioSeconds ?? 0)
            }
            let next = (incomingApps ?? []).map {
                HomeAppStat(appName: $0.appName, bundleID: $0.bundleID, words: $0.words, audioSeconds: $0.audioSeconds ?? 0)
            }
            merged.apps = HomeActivityStats.mergeAppStats([previous, next]).map {
                OpenFlowCloudStats.App(
                    appName: $0.appName,
                    bundleID: $0.bundleID,
                    words: $0.words,
                    dictations: nil,
                    audioSeconds: $0.audioSeconds
                )
            }
        }
        if let previous = lifetime {
            if let next = incoming.lifetime {
                var lifetime = next
                lifetime.words = max(previous.words, next.words)
                lifetime.audioSeconds = max(previous.audioSeconds, next.audioSeconds)
                lifetime.dictations = max(previous.dictations, next.dictations)
                merged.lifetime = lifetime
            } else {
                merged.lifetime = previous
            }
        }
        return merged
    }
}

private struct CloudPreferencesEnvelope: Codable {
    var schemaVersion: Int
    var payload: CloudPreferencesSnapshot?
    var updatedAt: Double?
}

private struct CloudPreferencesWrite: Encodable {
    var schemaVersion: Int
    var payload: CloudPreferencesSnapshot
}

private struct CloudActivityRequest: Encodable {
    var eventID: String
    var words: Int
    var audioSeconds: Double
    var audioBytes: Int
    var occurredAt: Double
    var ticketId: String?
    var model: String?
    var provider: String?
    var durationMs: Double?
    var tTicket: TimeInterval?
    var tReceiveAudio: TimeInterval?
    var tGroqHttp: TimeInterval?
    var tTotal: TimeInterval?
    var success: Bool?
    var errorClass: String?
    var targetApp: String?
    var bundleID: String?

    enum CodingKeys: String, CodingKey {
        case eventID
        case words
        case audioSeconds
        case audioBytes
        case occurredAt
        case ticketId
        case model
        case provider
        case durationMs
        case tTicket = "t_ticket"
        case tReceiveAudio = "t_receive_audio"
        case tGroqHttp = "t_groq_http"
        case tTotal = "t_total"
        case success
        case errorClass
        case targetApp
        case bundleID
    }
}

final class OpenFlowCloudService {
    private static let deviceIDDefaultsKey = "openflow.cloud.deviceID"
    private static let directUploadLimit = 8 * 1024 * 1024
    private static let uploadTokenHeader = "x-openflow-upload-token"
    private static let defaultRedirectDelegate = OpenFlowCloudRedirectDelegate()
    private static let defaultSession = URLSession(configuration: .default,
                                                   delegate: defaultRedirectDelegate,
                                                   delegateQueue: nil)
    private let keychain: KeychainService
    private let session: URLSession
    private let deviceID: String

    init(keychain: KeychainService? = nil) {
        self.keychain = keychain ?? .shared
        self.session = Self.defaultSession
        self.deviceID = Self.loadDeviceID()
    }

    init(keychain: KeychainService? = nil, session: URLSession) {
        self.keychain = keychain ?? .shared
        self.session = session
        self.deviceID = Self.loadDeviceID()
    }

    private static func loadDeviceID() -> String {
        if let existing = UserDefaults.standard.string(forKey: Self.deviceIDDefaultsKey),
           !existing.isEmpty {
            return existing
        }
        let generated = UUID().uuidString.lowercased()
        UserDefaults.standard.set(generated, forKey: Self.deviceIDDefaultsKey)
        return generated
    }

    func transcribe(audioURL: URL,
                    model: String,
                    baseURL: URL,
                    needsCleanup: Bool = false,
                    cleanupContext: Data? = nil,
                    appName: String? = nil,
                    bundleID: String? = nil) async throws -> TranscriptionResult {
        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            throw OpenflowError.transcriptionFailed("Audio file is missing.")
        }
        let started = Date()
        let byteCount = audioByteCount(at: audioURL)
        let audioSeconds = audioDuration(at: audioURL) ?? 0
        do {
            if byteCount > 0, byteCount <= Self.directUploadLimit {
                return try await transcribeDirect(audioURL: audioURL,
                                                  model: model,
                                                  baseURL: baseURL,
                                                  needsCleanup: needsCleanup,
                                                  cleanupContext: cleanupContext,
                                                  appName: appName,
                                                  bundleID: bundleID,
                                                  started: started)
            }
            return try await transcribeViaTicket(audioURL: audioURL,
                                                 model: model,
                                                 baseURL: baseURL,
                                                 audioSeconds: audioSeconds,
                                                 audioBytes: byteCount == Int.max ? 0 : byteCount,
                                                 appName: appName,
                                                 bundleID: bundleID,
                                                 started: started)
        } catch {
            if isMissingCloudRoute(error) {
                if byteCount > 0, byteCount <= Self.directUploadLimit {
                    return try await transcribeViaTicket(audioURL: audioURL,
                                                         model: model,
                                                         baseURL: baseURL,
                                                         audioSeconds: audioSeconds,
                                                         audioBytes: byteCount == Int.max ? 0 : byteCount,
                                                         appName: appName,
                                                         bundleID: bundleID,
                                                         started: started)
                }
                return try await transcribeViaConvexStorage(audioURL: audioURL,
                                                            model: model,
                                                            baseURL: baseURL,
                                                            appName: appName,
                                                            bundleID: bundleID,
                                                            started: started)
            }
            throw error
        }
    }

    private func transcribeViaTicket(audioURL: URL,
                                     model: String,
                                     baseURL: URL,
                                     audioSeconds: Double,
                                     audioBytes: Int,
                                     appName: String? = nil,
                                     bundleID: String? = nil,
                                     started: Date) async throws -> TranscriptionResult {
        let ticket: CloudSttTicketResponse = try await post(
            path: "/openflow/stt-ticket",
            body: CloudSttTicketRequest(model: model,
                                        audioSeconds: audioSeconds,
                                        audioBytes: audioBytes),
            baseURL: baseURL
        )
        let tTicket = Date().timeIntervalSince(started)
        let uploadURL = try CloudURLPolicy.validate(ticket.uploadUrl,
                                                    usage: .audioUpload,
                                                    baseURL: baseURL)
        var request = URLRequest(url: uploadURL, timeoutInterval: 120)
        request.httpMethod = "POST"
        request.setValue(AudioFileFormat.mimeType(for: audioURL), forHTTPHeaderField: "Content-Type")
        request.setValue(AudioFileFormat.uploadFilename(for: audioURL),
                         forHTTPHeaderField: "X-Openflow-Filename")
        request.setValue(ticket.model, forHTTPHeaderField: "X-Openflow-Model")
        request.setValue("Bearer \(ticket.ticket)", forHTTPHeaderField: "Authorization")

        do {
            let uploadStarted = Date()
            let (data, response, metrics) = try await timedUpload(request, fromFile: audioURL)
            let decoded: OpenFlowCloudTranscriptionResponse = try decode(data: data, response: response)
            let hop = hopTimings(uploadStarted: uploadStarted,
                                 metrics: metrics,
                                 decoded: decoded,
                                 totalStarted: started)
            let result = transcriptionResult(from: decoded,
                                             hop: hop,
                                             started: started,
                                             duration: decoded.duration ?? audioSeconds,
                                             tTicket: tTicket,
                                             tReceiveAudio: decoded.tReceiveAudio,
                                             tGroqHttp: decoded.tGroqHttp ?? hop.groqSeconds,
                                             tTotal: decoded.tTotal ?? Date().timeIntervalSince(started))
            try? await recordActivity(id: UUID(),
                                      words: wordCount(result.text),
                                      audioSeconds: result.duration ?? audioSeconds,
                                      audioBytes: audioBytes,
                                      timestamp: Date(),
                                      baseURL: baseURL,
                                      ticketId: ticket.ticketId,
                                      model: result.model,
                                      provider: result.provider,
                                      durationMs: result.requestTime * 1_000,
                                      tTicket: result.tTicket,
                                      tReceiveAudio: result.tReceiveAudio,
                                      tGroqHttp: result.tGroqHttp,
                                      tTotal: result.tTotal,
                                      success: true,
                                      targetApp: appName,
                                      bundleID: bundleID)
            return result
        } catch {
            try? await recordActivity(id: UUID(),
                                      words: 0,
                                      audioSeconds: 0,
                                      audioBytes: audioBytes,
                                      timestamp: Date(),
                                      baseURL: baseURL,
                                      ticketId: ticket.ticketId,
                                      model: ticket.model,
                                      provider: "openflow-pro-groq",
                                      durationMs: Date().timeIntervalSince(started) * 1_000,
                                      tTicket: tTicket,
                                      tTotal: Date().timeIntervalSince(started),
                                      success: false,
                                      errorClass: "stt_proxy_failed",
                                      targetApp: appName,
                                      bundleID: bundleID)
            throw error
        }
    }

    private func transcribeViaConvexStorage(audioURL: URL,
                                            model: String,
                                            baseURL: URL,
                                            appName: String? = nil,
                                            bundleID: String? = nil,
                                            started: Date) async throws -> TranscriptionResult {
        let reservation: CloudAudioUploadReservation = try await post(
            path: "/openflow/audio-upload-url",
            body: EmptyCloudRequest(),
            baseURL: baseURL
        )
        let uploaded = try await uploadAudio(
            audioURL,
            to: CloudURLPolicy.validate(reservation.uploadUrl,
                                        usage: .audioUpload,
                                        baseURL: baseURL),
            token: reservation.uploadToken,
            tokenHeader: reservation.uploadTokenHeader
        )
        let body = CloudTranscriptionRequest(model: model,
                                             filename: AudioFileFormat.uploadFilename(for: audioURL),
                                             mimeType: AudioFileFormat.mimeType(for: audioURL),
                                             uploadId: reservation.uploadId,
                                             storageId: uploaded.storageId,
                                             targetApp: appName,
                                             targetBundleID: bundleID)
        let transcribeStarted = Date()
        let response: OpenFlowCloudTranscriptionResponse = try await post(path: "/openflow/transcribe",
                                                                          body: body,
                                                                          baseURL: baseURL)
        let hop = hopTimings(uploadStarted: transcribeStarted,
                             metrics: nil,
                             decoded: response,
                             totalStarted: started)
        return transcriptionResult(from: response, hop: hop, started: started, duration: response.duration)
    }

    private func transcribeDirect(audioURL: URL,
                                  model: String,
                                  baseURL: URL,
                                  needsCleanup: Bool,
                                  cleanupContext: Data?,
                                  appName: String? = nil,
                                  bundleID: String? = nil,
                                  started: Date) async throws -> TranscriptionResult {
        var request = URLRequest(url: try endpoint(path: "/openflow/transcribe-fast", baseURL: baseURL))
        request.httpMethod = "POST"
        request.setValue(AudioFileFormat.mimeType(for: audioURL), forHTTPHeaderField: "Content-Type")
        request.setValue(model, forHTTPHeaderField: "X-Openflow-Model")
        request.setValue(AudioFileFormat.uploadFilename(for: audioURL),
                         forHTTPHeaderField: "X-Openflow-Filename")
        if let appName, !appName.isEmpty {
            request.setValue(appName, forHTTPHeaderField: "X-Openflow-App-Name")
        }
        if let bundleID, !bundleID.isEmpty {
            request.setValue(bundleID, forHTTPHeaderField: "X-Openflow-Bundle-ID")
        }
        if needsCleanup {
            request.setValue("true", forHTTPHeaderField: "X-Openflow-Needs-Cleanup")
            if let cleanupContext, !cleanupContext.isEmpty {
                request.setValue(cleanupContext.base64EncodedString(),
                                 forHTTPHeaderField: "X-Openflow-Cleanup-Context")
            }
        }
        if let audioSeconds = audioDuration(at: audioURL) {
            request.setValue(String(format: "%.3f", audioSeconds),
                             forHTTPHeaderField: "X-Openflow-Audio-Seconds")
        }
        try authorize(&request)

        let uploadStarted = Date()
        let (data, response, metrics) = try await timedUpload(request, fromFile: audioURL)
        let decoded: OpenFlowCloudTranscriptionResponse = try decode(data: data, response: response)
        let hop = hopTimings(uploadStarted: uploadStarted,
                             metrics: metrics,
                             decoded: decoded,
                             totalStarted: started)
        return transcriptionResult(from: decoded, hop: hop, started: started, duration: decoded.duration)
    }

    @MainActor
    func cleanup(rawTranscript: String,
                 context: FormattingContext,
                 settings: UserSettings,
                 baseURL: URL) async throws -> CleanupResult {
        let body = CloudCleanupRequest(rawTranscript: rawTranscript,
                                       activeAppName: context.activeAppName,
                                       bundleID: context.bundleID,
                                       category: context.category,
                                       selectedText: context.selectedText,
                                       nearbyText: context.nearbyText,
                                       textBefore: context.textBefore,
                                       textAfter: context.textAfter,
                                       browserURL: context.browserURL,
                                          stylePreset: context.stylePreset,
                                          customStylePrompt: context.customStylePrompt,
                                          pressEnterVoiceCommandEnabled: settings.pressEnterCommandEnabled,
                                          personalDictionary: settings.personalDictionary,
                                          emailSignOffName: settings.stylePreferences.emailSignOffName,
                                          model: settings.cleanupModel)
        let response: OpenFlowCloudCleanupResponse = try await post(path: "/openflow/cleanup",
                                                                    body: body,
                                                                    baseURL: baseURL)
        return CleanupResult(text: response.text,
                             pressEnter: settings.pressEnterCommandEnabled && response.pressEnter,
                             confidence: response.confidence,
                             notes: response.notes)
    }

    func entitlement(baseURL: URL) async throws -> OpenFlowCloudEntitlement {
        try await get(path: "/openflow/entitlement", baseURL: baseURL)
    }

    func checkoutURL(baseURL: URL) async throws -> URL {
        let response: OpenFlowCloudBillingLink = try await post(path: "/openflow/billing/checkout",
                                                                body: EmptyCloudRequest(),
                                                                baseURL: baseURL)
        return try CloudURLPolicy.validate(response.url, usage: .billing, baseURL: baseURL)
    }

    func portalURL(baseURL: URL) async throws -> URL {
        let response: OpenFlowCloudBillingLink = try await post(path: "/openflow/billing/portal",
                                                                body: EmptyCloudRequest(),
                                                                baseURL: baseURL)
        return try CloudURLPolicy.validate(response.url, usage: .billing, baseURL: baseURL)
    }

    func preferences(baseURL: URL) async throws -> CloudPreferencesSnapshot? {
        let response: CloudPreferencesEnvelope = try await get(
            path: "/openflow/preferences",
            baseURL: baseURL
        )
        return response.payload
    }

    func generateStyle(request: String, baseURL: URL) async throws -> CustomStyle {
        let response: CloudStyleDraftResponse = try await post(
            path: "/openflow/generate-style",
            body: CloudStyleDraftRequest(request: request),
            baseURL: baseURL
        )
        let name = response.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = response.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !prompt.isEmpty else {
            throw OpenflowError.cleanupFailed("Could not read the generated style.")
        }
        return CustomStyle(name: String(name.prefix(60)), prompt: String(prompt.prefix(1600)))
    }

    func savePreferences(_ snapshot: CloudPreferencesSnapshot,
                         baseURL: URL) async throws {
        let _: CloudWriteResponse = try await put(
            path: "/openflow/preferences",
            body: CloudPreferencesWrite(schemaVersion: 1, payload: snapshot),
            baseURL: baseURL
        )
    }

    func stats(baseURL: URL) async throws -> OpenFlowCloudStats {
        try await get(path: "/openflow/stats", baseURL: baseURL)
    }

    func recordActivity(id: UUID,
                        words: Int,
                        audioSeconds: Double,
                        audioBytes: Int,
                        timestamp: Date,
                        baseURL: URL,
                        ticketId: String? = nil,
                        model: String? = nil,
                        provider: String? = nil,
                        durationMs: Double? = nil,
                        tTicket: TimeInterval? = nil,
                        tReceiveAudio: TimeInterval? = nil,
                        tGroqHttp: TimeInterval? = nil,
                        tTotal: TimeInterval? = nil,
                        success: Bool = true,
                        errorClass: String? = nil,
                        targetApp: String? = nil,
                        bundleID: String? = nil) async throws {
        let _: CloudActivityResponse = try await post(
            path: "/openflow/activity",
            body: CloudActivityRequest(
                eventID: id.uuidString.lowercased(),
                words: words,
                audioSeconds: audioSeconds,
                audioBytes: max(0, audioBytes),
                occurredAt: timestamp.timeIntervalSince1970 * 1_000,
                ticketId: ticketId,
                model: model,
                provider: provider,
                durationMs: durationMs,
                tTicket: tTicket,
                tReceiveAudio: tReceiveAudio,
                tGroqHttp: tGroqHttp,
                tTotal: tTotal,
                success: success,
                errorClass: errorClass,
                targetApp: targetApp,
                bundleID: bundleID
            ),
            baseURL: baseURL
        )
    }

    private func post<Request: Encodable, Response: Decodable>(path: String,
                                                               body: Request,
                                                               baseURL: URL) async throws -> Response {
        var request = URLRequest(url: try endpoint(path: path, baseURL: baseURL))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        try authorize(&request)
        request.httpBody = try JSONEncoder().encode(body)
        return try await send(request)
    }

    private func get<Response: Decodable>(path: String, baseURL: URL) async throws -> Response {
        var request = URLRequest(url: try endpoint(path: path, baseURL: baseURL))
        request.httpMethod = "GET"
        try authorize(&request)
        return try await send(request)
    }

    private func put<Request: Encodable, Response: Decodable>(path: String,
                                                              body: Request,
                                                              baseURL: URL) async throws -> Response {
        var request = URLRequest(url: try endpoint(path: path, baseURL: baseURL))
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        try authorize(&request)
        request.httpBody = try JSONEncoder().encode(body)
        return try await send(request)
    }

    private func authorize(_ request: inout URLRequest) throws {
        guard let sessionToken = try keychain.cloudSessionToken(), !sessionToken.isEmpty else {
            throw OpenflowError.cloudAuthenticationRequired
        }
        request.setValue("Bearer \(sessionToken)", forHTTPHeaderField: "Authorization")
        request.setValue(deviceID, forHTTPHeaderField: "X-Openflow-Device-ID")
    }

    private func endpoint(path: String, baseURL: URL) throws -> URL {
        let trusted = try CloudURLPolicy.validateServiceBaseURL(baseURL)
        return trusted.appendingPathComponent(path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
    }

    private func send<Response: Decodable>(_ request: URLRequest) async throws -> Response {
        let (data, response) = try await session.data(for: request)
        return try decode(data: data, response: response)
    }

    private func decode<Response: Decodable>(data: Data,
                                             response: URLResponse) throws -> Response {
        guard let http = response as? HTTPURLResponse else {
            throw OpenflowError.cloudProviderUnavailable("No HTTP response.")
        }
        guard 200..<300 ~= http.statusCode else {
            let code = (try? JSONDecoder().decode(CloudErrorResponse.self, from: data).error) ?? ""
            if http.statusCode == 401 {
                throw OpenflowError.cloudSessionRevoked
            }
            if code == "unauthorized" {
                throw OpenflowError.cloudAuthenticationRequired
            }
            if code == "subscription_already_exists" {
                throw OpenflowError.cloudSubscriptionAlreadyActive
            }
            throw OpenflowError.cloudProviderUnavailable(
                cloudErrorMessage(data: data, statusCode: http.statusCode)
            )
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(Response.self, from: data)
        } catch {
            throw OpenflowError.cloudProviderUnavailable(
                "The service returned an unexpected response. Please try again."
            )
        }
    }

    private func cloudErrorMessage(data: Data, statusCode: Int) -> String {
        let code = (try? JSONDecoder().decode(CloudErrorResponse.self, from: data).error) ?? ""
        switch code {
        case "free_limit_reached":
            return "You have used this month’s free words. Upgrade to openflow Pro to keep dictating."
        case "subscription_required":
            return "Choose openflow Free, openflow Pro, or add your Groq key in Settings."
        case "subscription_requires_portal":
            return "Your openflow Pro subscription needs attention. Open Manage Plan to review it in Stripe."
        case "style_generate_pro_required":
            return OpenFlowProviderRouting.styleGenerateProRequiredMessage
        case "style_generate_unavailable":
            return "Could not generate that style. Check your connection and try again."
        case "style_generate_rate_limited":
            return "Too many style generations this hour. Try again shortly."
        case "stripe_not_configured", "checkout_unavailable":
            return "Checkout is temporarily unavailable. Please try again shortly."
        case "rate_limit_exceeded":
            return "Too many requests at once. Wait a moment and try again."
        case "provider_budget_exceeded":
            return "This account has reached its monthly fair-use limit. Contact support if this seems wrong."
        case "provider_not_configured":
            return "The openflow service is not configured yet."
        default:
            return "openflow could not complete that request (HTTP \(statusCode))."
        }
    }

    private func uploadAudio(
        _ audioURL: URL,
        to uploadURL: URL,
        token: String?,
        tokenHeader: String?
    ) async throws -> CloudAudioUploadResponse {
        var request = URLRequest(url: uploadURL)
        request.httpMethod = "POST"
        request.setValue(AudioFileFormat.mimeType(for: audioURL), forHTTPHeaderField: "Content-Type")
        if let token, !token.isEmpty {
            let header: String
            if let tokenHeader,
               tokenHeader.caseInsensitiveCompare(Self.uploadTokenHeader) == .orderedSame {
                header = tokenHeader
            } else {
                header = Self.uploadTokenHeader
            }
            request.setValue(token, forHTTPHeaderField: header)
        }
        let (data, response) = try await session.upload(for: request, fromFile: audioURL)
        guard let http = response as? HTTPURLResponse else {
            throw OpenflowError.cloudProviderUnavailable("No upload response.")
        }
        guard 200..<300 ~= http.statusCode else {
            throw OpenflowError.cloudProviderUnavailable(
                "Audio upload failed (HTTP \(http.statusCode))."
            )
        }
        return try JSONDecoder().decode(CloudAudioUploadResponse.self, from: data)
    }

    private func timedUpload(_ request: URLRequest,
                             fromFile fileURL: URL) async throws -> (Data, URLResponse, URLSessionTaskMetrics?) {
        let timingID = UUID().uuidString.lowercased()
        var timed = request
        timed.setValue(timingID, forHTTPHeaderField: "X-Openflow-Timing-ID")
        let (data, response) = try await session.upload(for: timed, fromFile: fileURL)
        let metrics = await Self.defaultRedirectDelegate.takeMetrics(id: timingID)
        return (data, response, metrics)
    }

    private func hopTimings(uploadStarted: Date,
                            metrics: URLSessionTaskMetrics?,
                            decoded: OpenFlowCloudTranscriptionResponse,
                            totalStarted _: Date) -> CloudTranscribeHopTimings {
        let totalClientMs = max(0, Int(Date().timeIntervalSince(uploadStarted) * 1_000))
        let macToConvexMs = requestSendMs(from: metrics)
        let convexUntilGroqStartMs: Int? = {
            if let received = decoded.timings?.receivedAt,
               let groqStarted = decoded.timings?.groqStartedAt {
                return max(0, Int(groqStarted - received))
            }
            return nil
        }()
        let groqRoundTripMs: Int? = {
            if let value = decoded.timings?.groqRoundTripMs {
                return max(0, Int(value.rounded()))
            }
            if let seconds = decoded.tGroqHttp {
                return max(0, Int(seconds * 1_000))
            }
            return nil
        }()
        let cerebrasRoundTripMs: Int? = {
            guard let value = decoded.timings?.cerebrasRoundTripMs, value > 0 else { return nil }
            return max(0, Int(value.rounded()))
        }()
        let cleanupAuthMs: Int? = {
            guard let value = decoded.timings?.cleanupAuthMs, value > 0 else { return nil }
            return max(0, Int(value.rounded()))
        }()
        let convexToMacMs: Int? = {
            if let mac = macToConvexMs {
                return max(0, totalClientMs
                    - mac
                    - (convexUntilGroqStartMs ?? 0)
                    - (groqRoundTripMs ?? 0)
                    - (cerebrasRoundTripMs ?? 0)
                    - (cleanupAuthMs ?? 0))
            }
            return responseReceiveMs(from: metrics)
        }()
        let macLabel = macToConvexMs.map(String.init) ?? "?"
        let untilLabel = convexUntilGroqStartMs.map(String.init) ?? "?"
        let groqLabel = groqRoundTripMs.map(String.init) ?? "?"
        let cerebrasLabel = cerebrasRoundTripMs.map(String.init) ?? "0"
        let cleanupAuthLabel = cleanupAuthMs.map(String.init) ?? "0"
        let backLabel = convexToMacMs.map(String.init) ?? "?"
        let timings = decoded.timings
        let introspectLabel = timings?.introspectMs.map { String(Int($0.rounded())) } ?? "?"
        let blobLabel = timings?.blobMs.map { String(Int($0.rounded())) } ?? "?"
        let authorizeLabel = timings?.authorizeMs.map { String(Int($0.rounded())) } ?? "?"
        let formLabel = timings?.formDataMs.map { String(Int($0.rounded())) } ?? "?"
        let cacheHitLabel = timings?.introspectionCacheHit.map { $0 ? "true" : "false" } ?? "?"
        let rawTimings: String = {
            guard let timings, let data = try? JSONEncoder().encode(timings),
                  let json = String(data: data, encoding: .utf8) else {
                return "{}"
            }
            return json
        }()
        let breakdown =
            "macToConvexMs=\(macLabel) convexUntilGroqStartMs=\(untilLabel) groqRoundTripMs=\(groqLabel) cerebrasRoundTripMs=\(cerebrasLabel) cleanupAuthMs=\(cleanupAuthLabel) convexToMacMs=\(backLabel) totalClientMs=\(totalClientMs) introspectMs=\(introspectLabel) blobMs=\(blobLabel) authorizeMs=\(authorizeLabel) formDataMs=\(formLabel) introspectionCacheHit=\(cacheHitLabel) timingsJSON=\(rawTimings) (WAV already in Convex memory at handler start; macToConvexMs is URLSession request-send; cerebrasRoundTripMs is Cerebras fetch start→body)"
        NSLog("[openflow-latency] %@", breakdown)
        return CloudTranscribeHopTimings(macToConvexMs: macToConvexMs,
                                         convexUntilGroqStartMs: convexUntilGroqStartMs,
                                         groqRoundTripMs: groqRoundTripMs,
                                         convexToMacMs: convexToMacMs,
                                         cerebrasRoundTripMs: cerebrasRoundTripMs,
                                         cleanupAuthMs: cleanupAuthMs,
                                         groqSeconds: groqRoundTripMs.map { Double($0) / 1_000 },
                                         breakdown: breakdown)
    }

    private func transcriptionResult(from decoded: OpenFlowCloudTranscriptionResponse,
                                     hop: CloudTranscribeHopTimings,
                                     started: Date,
                                     duration: TimeInterval?,
                                     tTicket: TimeInterval? = nil,
                                     tReceiveAudio: TimeInterval? = nil,
                                     tGroqHttp: TimeInterval? = nil,
                                     tTotal: TimeInterval? = nil) -> TranscriptionResult {
        TranscriptionResult(text: decoded.whisperText,
                            model: decoded.model,
                            provider: decoded.provider,
                            duration: duration,
                            requestTime: Date().timeIntervalSince(started),
                            tTicket: tTicket,
                            tReceiveAudio: tReceiveAudio,
                            tGroqHttp: tGroqHttp,
                            tTotal: tTotal,
                            macToConvexMs: hop.macToConvexMs,
                            convexUntilGroqStartMs: hop.convexUntilGroqStartMs,
                            groqRoundTripMs: hop.groqRoundTripMs,
                            convexToMacMs: hop.convexToMacMs,
                            cerebrasRoundTripMs: hop.cerebrasRoundTripMs,
                            cleanupAuthMs: hop.cleanupAuthMs,
                            cleanupApplied: decoded.cleanupApplied == true,
                            cleanedText: decoded.cleanedText ?? (decoded.cleanupApplied == true ? decoded.text : nil),
                            pressEnter: decoded.pressEnter ?? false,
                            confidence: decoded.confidence,
                            notes: decoded.notes,
                            hopBreakdown: hop.breakdown)
    }

    @MainActor
    func encodeCleanupContext(context: FormattingContext, settings: UserSettings) -> Data? {
        let payload = CloudCleanupRequest(rawTranscript: "",
                                          activeAppName: context.activeAppName,
                                          bundleID: context.bundleID,
                                          category: context.category,
                                          selectedText: settings.contextAwarenessEnabled ? context.selectedText : nil,
                                          nearbyText: settings.contextAwarenessEnabled ? context.nearbyText : nil,
                                          textBefore: settings.contextAwarenessEnabled ? context.textBefore : nil,
                                          textAfter: settings.contextAwarenessEnabled ? context.textAfter : nil,
                                          browserURL: context.browserURL,
                                          stylePreset: context.stylePreset,
                                          customStylePrompt: context.customStylePrompt,
                                          pressEnterVoiceCommandEnabled: settings.pressEnterCommandEnabled,
                                          personalDictionary: settings.personalDictionary,
                                          emailSignOffName: settings.stylePreferences.emailSignOffName,
                                          model: settings.cleanupModel)
        return try? JSONEncoder().encode(payload)
    }

    private func requestSendMs(from metrics: URLSessionTaskMetrics?) -> Int? {
        guard let transaction = metrics?.transactionMetrics.last,
              let start = transaction.requestStartDate,
              let end = transaction.requestEndDate else {
            return nil
        }
        return max(0, Int(end.timeIntervalSince(start) * 1_000))
    }

    private func responseReceiveMs(from metrics: URLSessionTaskMetrics?) -> Int? {
        guard let transaction = metrics?.transactionMetrics.last,
              let start = transaction.responseStartDate,
              let end = transaction.responseEndDate else {
            return nil
        }
        return max(0, Int(end.timeIntervalSince(start) * 1_000))
    }

    private func audioByteCount(at url: URL) -> Int {
        if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = attributes[.size] as? NSNumber {
            return size.intValue
        }
        return Int.max
    }

    private func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }

    private func isMissingCloudRoute(_ error: Error) -> Bool {
        let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        return message.contains("HTTP 404")
    }

    private func audioDuration(at url: URL) -> Double? {
        if url.pathExtension.caseInsensitiveCompare("wav") == .orderedSame {
            return wavDuration(at: url)
        }
        guard let audioFile = try? AVAudioFile(forReading: url),
              audioFile.processingFormat.sampleRate > 0 else {
            return nil
        }
        return Double(audioFile.length) / audioFile.processingFormat.sampleRate
    }

    private func wavDuration(at url: URL) -> Double? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 44),
              header.count >= 44 else { return nil }
        let byteRate = header.withUnsafeBytes {
            $0.loadUnaligned(fromByteOffset: 28, as: UInt32.self).littleEndian
        }
        let dataBytes = header.withUnsafeBytes {
            $0.loadUnaligned(fromByteOffset: 40, as: UInt32.self).littleEndian
        }
        guard byteRate > 0 else { return nil }
        return Double(dataBytes) / Double(byteRate)
    }
}

private final class OpenFlowCloudRedirectDelegate: NSObject, URLSessionTaskDelegate {
    private let metricsLock = NSLock()
    private var collectedMetrics: [String: URLSessionTaskMetrics] = [:]

    func takeMetrics(id: String) async -> URLSessionTaskMetrics? {
        let deadline = Date().addingTimeInterval(0.25)
        while Date() < deadline {
            metricsLock.lock()
            let metrics = collectedMetrics.removeValue(forKey: id)
            metricsLock.unlock()
            if let metrics {
                return metrics
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        metricsLock.lock()
        defer { metricsLock.unlock() }
        return collectedMetrics.removeValue(forKey: id)
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didFinishCollecting metrics: URLSessionTaskMetrics) {
        guard let timingID = task.originalRequest?.value(forHTTPHeaderField: "X-Openflow-Timing-ID"),
              !timingID.isEmpty else {
            return
        }
        metricsLock.lock()
        collectedMetrics[timingID] = metrics
        metricsLock.unlock()
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        guard let destination = request.url,
              let original = task.originalRequest,
              let originalURL = original.url else {
            completionHandler(nil)
            return
        }
        let uploadRequest = original.value(forHTTPHeaderField: "x-openflow-upload-token") != nil
        guard let originalHost = originalURL.host,
              let destinationHost = destination.host,
              originalHost.caseInsensitiveCompare(destinationHost) == .orderedSame else {
            completionHandler(nil)
            return
        }
        let usage: CloudURLPolicy.Usage = uploadRequest ? .audioUpload : .serviceBase
        do {
            let validated = try CloudURLPolicy.validate(
                destination,
                usage: usage,
                baseURL: originalURL
            )
            var safeRequest = request
            safeRequest.url = validated
            completionHandler(safeRequest)
        } catch {
            completionHandler(nil)
        }
    }
}

private struct CloudErrorResponse: Decodable {
    let error: String
}

private struct CloudWriteResponse: Decodable {
    var updatedAt: Double
}

private struct CloudActivityResponse: Decodable {
    var duplicate: Bool
}

private struct CloudSttTicketRequest: Encodable {
    var model: String
    var audioSeconds: Double
    var audioBytes: Int
}

private struct CloudSttTicketResponse: Decodable {
    var ticket: String
    var ticketId: String
    var uploadUrl: URL
    var expiresAt: TimeInterval
    var model: String
}

private struct CloudTranscriptionRequest: Encodable {
    var model: String
    var filename: String
    var mimeType: String
    var uploadId: String
    var storageId: String
    var targetApp: String?
    var targetBundleID: String?
}

private struct EmptyCloudRequest: Encodable {}

private struct CloudAudioUploadReservation: Decodable {
    var uploadId: String
    var uploadUrl: URL
    var uploadToken: String?
    var uploadTokenHeader: String?
    var expiresAt: TimeInterval
}

private struct CloudAudioUploadResponse: Decodable {
    var storageId: String
}

private struct CloudTranscribeHopTimings {
    var macToConvexMs: Int?
    var convexUntilGroqStartMs: Int?
    var groqRoundTripMs: Int?
    var convexToMacMs: Int?
    var cerebrasRoundTripMs: Int?
    var cleanupAuthMs: Int?
    var groqSeconds: TimeInterval?
    var breakdown: String
}

private struct CloudStyleDraftRequest: Encodable {
    var request: String
}

private struct CloudStyleDraftResponse: Decodable {
    var name: String
    var prompt: String
}

private struct CloudCleanupRequest: Encodable {
    var rawTranscript: String
    var activeAppName: String
    var bundleID: String
    var category: AppCategory
    var selectedText: String?
    var nearbyText: String?
    var textBefore: String?
    var textAfter: String?
    var browserURL: String?
    var stylePreset: StylePreset
    var customStylePrompt: String?
    var pressEnterVoiceCommandEnabled: Bool
    var personalDictionary: [DictionaryEntry]
    var emailSignOffName: String
    var model: String

    enum CodingKeys: String, CodingKey {
        case rawTranscript
        case activeAppName
        case bundleID
        case category
        case selectedText
        case nearbyText
        case textBefore = "text_before"
        case textAfter = "text_after"
        case browserURL
        case stylePreset
        case customStylePrompt = "custom_style_prompt"
        case pressEnterVoiceCommandEnabled
        case personalDictionary
        case emailSignOffName = "email_sign_off_name"
        case model
    }
}
