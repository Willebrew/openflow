import Foundation

// Voice-agent safety contract:
//  1. The focus probe never blocks past its timeout -- a wedged probe yields
//     .inconclusive fast, so dictation is never parked.
//  2. VoiceAgentRouting only sends a transcript to Jev on a confident
//     "no text field" verdict; every uncertain signal dictates.
//  3. The Jev fallback predicate recovers any aborted/failed/0-step run.
//  4. A WAV travels through the real OpenFlowCloudService.transcribe request
//     builder to the transcribe-fast endpoint path, byte-identical on the wire.

final class StubURLProtocol: URLProtocol {
    struct Captured {
        var method: String
        var url: URL
        var headers: [String: String]
        var body: Data
    }

    static var captured: Captured?
    static var responseBody = Data(#"{"text":"check transcript","model":"whisper","provider":"groq"}"#.utf8)

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = Data()
        if let stream = request.httpBodyStream {
            stream.open()
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 1 << 16)
            defer { buffer.deallocate() }
            while true {
                let read = stream.read(buffer, maxLength: 1 << 16)
                if read <= 0 { break }
                body.append(buffer, count: read)
            }
            stream.close()
        }
        var headers: [String: String] = [:]
        for (key, value) in request.allHTTPHeaderFields ?? [:] {
            headers[key.lowercased()] = value
        }
        StubURLProtocol.captured = Captured(method: request.httpMethod ?? "",
                                            url: request.url!,
                                            headers: headers,
                                            body: body)
        let response = HTTPURLResponse(url: request.url!,
                                       statusCode: 200,
                                       httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: StubURLProtocol.responseBody)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@main
struct CheckVoiceAgentSafety {
    static func main() async {
        do {
            try await checkProbeTimeout()
            checkRoutingDecisions()
            checkTranscriptRecovery()
            try await checkTranscribeFastRequest()
            print("voice agent safety check passed")
        } catch {
            fail("unexpected error: \(error)")
        }
    }

    // MARK: - Probe timeout

    /// A probe that sleeps 3s must be cut off by a 0.3s timeout. If the wait
    /// ever stretches past ~2s, the regression that parked the main thread at
    /// dictation start is back.
    static func checkProbeTimeout() async throws {
        let started = Date()
        let result = await TextInputFocusProbe.axStrictDecisionAsync(timeout: 0.3) {
            Thread.sleep(forTimeInterval: 3)
            return FocusProbeResult(verdict: .noTextInput, report: "slow-probe", elapsed: 3)
        }
        let waited = Date().timeIntervalSince(started)
        assertEqual(result.verdict, .inconclusive, "a hanging probe must degrade to inconclusive")
        assertTrue(result.report.contains("probe-timeout"),
                   "timeout report should name the bound, got \(result.report)")
        assertTrue(waited < 2.0,
                   "probe timeout must abandon the slow probe: waited \(waited)s")
    }

    /// A fast probe result must beat the timeout and pass through untouched.
    static func checkRoutingDecisions() {
        // Toggle off always dictates.
        assertEqual(VoiceAgentRouting.decide(voiceAgentEnabled: false,
                                             probeAtStart: nil,
                                             probeAtEnd: .noTextInput),
                    .dictate, "voice agent off must dictate")
        // A field seen at start wins even if the end probe disagrees.
        assertEqual(VoiceAgentRouting.decide(voiceAgentEnabled: true,
                                             probeAtStart: .textInput,
                                             probeAtEnd: .noTextInput),
                    .dictate, "text field at start dictates")
        // Confident no-text at end (with no start field) routes to Jev.
        assertEqual(VoiceAgentRouting.decide(voiceAgentEnabled: true,
                                             probeAtStart: .inconclusive,
                                             probeAtEnd: .noTextInput),
                    .voiceAgent, "confident no-text routes to agent")
        assertEqual(VoiceAgentRouting.decide(voiceAgentEnabled: true,
                                             probeAtStart: nil,
                                             probeAtEnd: .noTextInput),
                    .voiceAgent, "missing start probe still honors confident end probe")
        // Every other shape dictates -- inconclusive, AX errors, text fields.
        for end in [FocusProbeVerdict.inconclusive, .textInput] {
            for start in [FocusProbeVerdict?.some(.inconclusive), .some(.noTextInput), nil] {
                assertEqual(VoiceAgentRouting.decide(voiceAgentEnabled: true,
                                                     probeAtStart: start,
                                                     probeAtEnd: end),
                            .dictate, "start=\(String(describing: start)) end=\(end) must dictate")
            }
        }
    }

    static func checkTranscriptRecovery() {
        assertTrue(VoiceAgentRouting.needsTranscriptRecovery(completed: false, steps: 0),
                   "aborted run must recover the transcript")
        assertTrue(VoiceAgentRouting.needsTranscriptRecovery(completed: false, steps: 4),
                   "failed run must recover the transcript")
        assertTrue(VoiceAgentRouting.needsTranscriptRecovery(completed: true, steps: 0),
                   "0-step run must recover the transcript")
        assertTrue(!VoiceAgentRouting.needsTranscriptRecovery(completed: true, steps: 3),
                   "completed run with steps does not recover")
    }

    // MARK: - transcribe-fast wire contract

    /// Sends a real WAV through OpenFlowCloudService.transcribe with a stubbed
    /// URLSession, then inspects the captured request: it must hit the
    /// transcribe-fast path on the service base URL, carry auth/device/model
    /// headers, and upload the file byte-for-byte.
    static func checkTranscribeFastRequest() async throws {
        let wavURL = try makeTestWAV()
        defer { try? FileManager.default.removeItem(at: wavURL) }
        let wavBytes = try Data(contentsOf: wavURL)

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: config)
        let cloud = OpenFlowCloudService(session: session, sessionToken: "check-session-token")
        let baseURL = try require(URL(string: "https://openflow-site-cvx.jottly.ai/http"),
                                  "fixture base URL")

        let result = try await cloud.transcribe(audioURL: wavURL,
                                                model: "whisper-large-v3-turbo",
                                                baseURL: baseURL,
                                                appName: "SafetyCheck",
                                                bundleID: "ai.jottly.check")

        let captured = try require(StubURLProtocol.captured, "request was captured")
        assertEqual(captured.method, "POST", "transcribe-fast is a POST")
        assertEqual(captured.url.path, "/http/openflow/transcribe-fast",
                    "request path keeps the service prefix")
        assertEqual(captured.headers["authorization"], "Bearer check-session-token",
                    "session token authorizes the upload")
        assertEqual(captured.headers["x-openflow-model"], "whisper-large-v3-turbo",
                    "model header travels")
        assertEqual(captured.headers["content-type"], "audio/wav", "WAV mime type")
        assertEqual(captured.headers["x-openflow-filename"], wavURL.lastPathComponent,
                    "upload filename travels")
        assertEqual(captured.headers["x-openflow-app-name"], "SafetyCheck", "app name header")
        assertEqual(captured.headers["x-openflow-bundle-id"], "ai.jottly.check", "bundle id header")
        assertTrue(captured.headers["x-openflow-device-id"]?.isEmpty == false,
                   "device id header present")
        assertEqual(captured.body, wavBytes, "audio body is the WAV byte-for-byte")
        assertEqual(result.text, "check transcript", "decoded transcript text")
        assertTrue(result.requestTime > 0, "request time recorded")
    }

    /// Minimal but valid 44-byte-header PCM16 mono WAV -- enough for
    /// wavDuration to read byteRate/dataSize from the header.
    static func makeTestWAV() throws -> URL {
        let sampleRate: UInt32 = 16_000
        let frameCount = sampleRate // 1 second
        let dataSize = frameCount * 2
        var data = Data()
        data.append(contentsOf: "RIFF".utf8)
        data.appendLE(UInt32(36 + dataSize))
        data.append(contentsOf: "WAVE".utf8)
        data.append(contentsOf: "fmt ".utf8)
        data.appendLE(UInt32(16))
        data.appendLE(UInt16(1))
        data.appendLE(UInt16(1))
        data.appendLE(sampleRate)
        data.appendLE(sampleRate * 2)
        data.appendLE(UInt16(2))
        data.appendLE(UInt16(16))
        data.append(contentsOf: "data".utf8)
        data.appendLE(dataSize)
        // Tiny alternating amplitude so the payload is not all zeros.
        for i in 0..<frameCount {
            data.appendLE(UInt16(i % 2 == 0 ? 200 : 0))
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("check-voice-agent-\(UUID().uuidString).wav")
        try data.write(to: url)
        return url
    }

    // MARK: - helpers

    static func assertEqual<T: Equatable>(_ actual: T, _ expected: T, _ label: String) {
        if actual != expected {
            fail("\(label): expected \(expected), got \(actual)")
        }
    }

    static func assertTrue(_ value: Bool, _ label: String) {
        if !value { fail(label) }
    }

    static func require<T>(_ value: T?, _ label: String) throws -> T {
        guard let value else { throw CheckError.missing(label) }
        return value
    }

    static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("voice agent safety check failed: \(message)\n".utf8))
        exit(1)
    }

    enum CheckError: Error {
        case missing(String)
    }
}

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }
}
