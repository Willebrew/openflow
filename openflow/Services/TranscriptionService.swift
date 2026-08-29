import Foundation

protocol TranscriptionProvider {
    var name: String { get }
    func transcribe(audioURL: URL, model: String, apiKey: String) async throws -> TranscriptionResult
}

@MainActor
final class TranscriptionService {
    private let provider: TranscriptionProvider
    private let keychain: KeychainService
    private let cloud: OpenFlowCloudService

    init(provider: TranscriptionProvider? = nil,
         keychain: KeychainService? = nil,
         cloud: OpenFlowCloudService? = nil) {
        self.provider = provider ?? GroqTranscriptionProvider()
        self.keychain = keychain ?? .shared
        self.cloud = cloud ?? OpenFlowCloudService()
    }

    func transcribe(audioURL: URL,
                    settings: UserSettings,
                    needsCleanup: Bool = false,
                    cleanupContext: Data? = nil,
                    appName: String? = nil,
                    bundleID: String? = nil) async throws -> TranscriptionResult {
        let apiKey = try keychain.apiKey()
        let hasLocalKey = apiKey?.isEmpty == false
        let shouldUseCloud = OpenFlowProviderRouting.usesCloudTranscription(
            providerMode: settings.providerMode,
            hasLocalGroqKey: hasLocalKey
        )
        if shouldUseCloud {
            guard let baseURL = URL(string: settings.cloudBaseURL), !settings.cloudBaseURL.isEmpty else {
                throw OpenflowError.cloudProviderUnavailable("Set the openflow service URL.")
            }
            return try await cloud.transcribe(audioURL: audioURL,
                                              model: settings.transcriptionModel,
                                              baseURL: baseURL,
                                              needsCleanup: needsCleanup,
                                              cleanupContext: cleanupContext,
                                              appName: appName,
                                              bundleID: bundleID)
        }
        guard let apiKey, !apiKey.isEmpty else {
            throw OpenflowError.missingAPIKey
        }
        do {
            return try await retrying {
                try await self.provider.transcribe(audioURL: audioURL, model: settings.transcriptionModel, apiKey: apiKey)
            }
        } catch {
            if settings.fallbackTranscriptionModel != settings.transcriptionModel {
                return try await retrying {
                    try await self.provider.transcribe(audioURL: audioURL, model: settings.fallbackTranscriptionModel, apiKey: apiKey)
                }
            }
            throw error
        }
    }

    func warmUp(settings _: UserSettings) {
        // Do not GET /entitlement. Session checks use NQL Auth. Cloud 401 revokes.
    }

    private func retrying(_ operation: @escaping () async throws -> TranscriptionResult) async throws -> TranscriptionResult {
        var lastError: Error?
        for attempt in 0..<3 {
            do { return try await operation() } catch {
                lastError = error
                if String(describing: error).contains("401") { throw error }
                try await Task.sleep(nanoseconds: UInt64(pow(2.0, Double(attempt)) * 250_000_000))
            }
        }
        throw lastError ?? OpenflowError.transcriptionFailed("Unknown error")
    }
}

final class GroqTranscriptionProvider: TranscriptionProvider {
    let name = "groq"
    private let endpoint = URL(string: "https://api.groq.com/openai/v1/audio/transcriptions")!

    func transcribe(audioURL: URL, model: String, apiKey: String) async throws -> TranscriptionResult {
        let started = Date()
        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: endpoint, timeoutInterval: 600)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let audioData = try Data(contentsOf: audioURL)
        request.httpBody = MultipartBuilder(boundary: boundary)
            .field(name: "model", value: model)
            .field(name: "response_format", value: "json")
            .file(name: "file",
                  filename: AudioFileFormat.uploadFilename(for: audioURL),
                  mimeType: AudioFileFormat.mimeType(for: audioURL),
                  data: audioData)
            .finalize()

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OpenflowError.transcriptionFailed("No HTTP response")
        }
        guard 200..<300 ~= http.statusCode else {
            let body = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            throw OpenflowError.transcriptionFailed(body)
        }
        let decoded = try JSONDecoder().decode(GroqTranscriptionResponse.self, from: data)
        return TranscriptionResult(text: decoded.text,
                                   model: model,
                                   provider: name,
                                   duration: nil,
                                   requestTime: Date().timeIntervalSince(started))
    }
}

private struct GroqTranscriptionResponse: Decodable {
    let text: String
}

private struct MultipartBuilder {
    let boundary: String
    private var data = Data()

    init(boundary: String) {
        self.boundary = boundary
    }

    func field(name: String, value: String) -> MultipartBuilder {
        var copy = self
        copy.data.appendString("--\(boundary)\r\n")
        copy.data.appendString("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
        copy.data.appendString("\(value)\r\n")
        return copy
    }

    func file(name: String, filename: String, mimeType: String, data fileData: Data) -> MultipartBuilder {
        var copy = self
        copy.data.appendString("--\(boundary)\r\n")
        copy.data.appendString("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n")
        copy.data.appendString("Content-Type: \(mimeType)\r\n\r\n")
        copy.data.append(fileData)
        copy.data.appendString("\r\n")
        return copy
    }

    func finalize() -> Data {
        var copy = data
        copy.appendString("--\(boundary)--\r\n")
        return copy
    }
}

private extension Data {
    mutating func appendString(_ string: String) {
        append(Data(string.utf8))
    }
}
