import Foundation

final class MockCloudHTTPSession: CloudHTTPSession {
    var statusCode: Int
    var body: Data
    var transportError: Error?
    var lastRequest: URLRequest?

    init(statusCode: Int = 200, body: Data = Data(), transportError: Error? = nil) {
        self.statusCode = statusCode
        self.body = body
        self.transportError = transportError
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        lastRequest = request
        if let transportError {
            throw transportError
        }
        let url = request.url ?? URL(string: "https://example.invalid")!
        let response = HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
        return (body, response)
    }
}

enum CheckCloudSessionValidator {
    static func run() async {
        checkStaticDecision()
        await checkMockedSession()
        print("Cloud session validator checks passed")
    }

    private static func checkStaticDecision() {
        precondition(
            CloudSessionValidator.validity(statusCode: 401, body: Data(#"{"active":false}"#.utf8)) == .revoked,
            "401 with active:false must be revoked"
        )
        precondition(
            CloudSessionValidator.validity(statusCode: 401, body: Data()) == .indeterminate,
            "401 without an introspect body must be indeterminate"
        )
        precondition(
            CloudSessionValidator.validity(
                statusCode: 401,
                body: Data("<html>unauthorized</html>".utf8)
            ) == .indeterminate,
            "401 HTML must be indeterminate"
        )
        precondition(
            CloudSessionValidator.validity(
                statusCode: 200,
                body: Data(#"{"active":true,"subject":"user_1"}"#.utf8)
            ) == .valid,
            "200 active must be valid"
        )
        precondition(
            CloudSessionValidator.validity(
                statusCode: 200,
                body: Data(#"{"active":false}"#.utf8)
            ) == .revoked,
            "200 inactive must be revoked"
        )
        precondition(
            CloudSessionValidator.validity(statusCode: 503, body: Data()) == .indeterminate,
            "non-401 HTTP must be indeterminate"
        )
        precondition(
            CloudSessionValidator.validity(statusCode: 500, body: Data("oops".utf8)) == .indeterminate,
            "5xx must be indeterminate"
        )
        precondition(
            CloudSessionValidator.validity(statusCode: 200, body: Data("not-json".utf8)) == .indeterminate,
            "unreadable 200 must be indeterminate"
        )
    }

    private static func checkMockedSession() async {
        let revoked = MockCloudHTTPSession(
            statusCode: 401,
            body: Data(#"{"active":false}"#.utf8)
        )
        let revokedResult = await CloudSessionValidator(session: revoked).validate(token: "tok")
        precondition(revokedResult == .revoked, "mocked 401 active:false must be revoked")
        let html401 = MockCloudHTTPSession(statusCode: 401, body: Data("<html>nope</html>".utf8))
        let htmlResult = await CloudSessionValidator(session: html401).validate(token: "tok")
        precondition(htmlResult == .indeterminate, "mocked 401 HTML must be indeterminate")
        precondition(
            revoked.lastRequest?.url?.path.hasSuffix("/api/openflow/introspect") == true,
            "introspect path must be /api/openflow/introspect"
        )
        precondition(
            revoked.lastRequest?.value(forHTTPHeaderField: "Authorization") == "Bearer tok",
            "introspect must send the bearer token"
        )
        let body = revoked.lastRequest?.httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        precondition(body.contains("\"product\":\"openflow\""), "introspect body must name openflow")

        let valid = MockCloudHTTPSession(
            statusCode: 200,
            body: Data(#"{"active":true,"subject":"user_1","canUseCloud":true}"#.utf8)
        )
        let validResult = await CloudSessionValidator(session: valid).validate(token: "tok")
        precondition(validResult == .valid, "mocked 200 active must be valid")

        struct Offline: Error {}
        let offline = MockCloudHTTPSession(transportError: Offline())
        let offlineResult = await CloudSessionValidator(session: offline).validate(token: "tok")
        precondition(offlineResult == .indeterminate, "transport error must be indeterminate")

        let otherHTTP = MockCloudHTTPSession(statusCode: 429, body: Data())
        let otherResult = await CloudSessionValidator(session: otherHTTP).validate(token: "tok")
        precondition(otherResult == .indeterminate, "non-401 HTTP must be indeterminate")
    }
}

@main
enum CheckCloudSessionValidatorMain {
    static func main() async {
        await CheckCloudSessionValidator.run()
    }
}
