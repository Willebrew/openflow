import Foundation

enum CloudSessionValidity: Equatable {
    case valid
    case revoked
    case indeterminate
}

protocol CloudHTTPSession {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: CloudHTTPSession {}

struct CloudSessionIntrospectResponse: Decodable {
    var active: Bool?
    var subject: String?
    var subscriptionStatus: String?
    var canUseCloud: Bool?
    var expiresAt: Date?
}

/// Owns stored-session introspect: valid, revoked, or indeterminate.
/// Never treats transport failure as revoke.
struct CloudSessionValidator {
    static let authBaseURL = URL(string: "https://auth.neuroquestlabs.ai")!
    static let introspectPath = "api/openflow/introspect"
    static let product = "openflow"
    static let refreshInterval: TimeInterval = 12 * 60
    static let menuRevalidateInterval: TimeInterval = 15
    static let revokedUserMessage =
        "Your session was signed out from your account settings. Sign in again to use openflow cloud."

    private let session: any CloudHTTPSession
    private let authBaseURL: URL

    init(session: any CloudHTTPSession = URLSession.shared,
         authBaseURL: URL = CloudSessionValidator.authBaseURL) {
        self.session = session
        self.authBaseURL = authBaseURL
    }

    var introspectURL: URL {
        authBaseURL.appendingPathComponent(Self.introspectPath)
    }

    func validate(token: String) async -> CloudSessionValidity {
        var request = URLRequest(url: introspectURL, timeoutInterval: 5)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try? JSONEncoder().encode(["product": Self.product])

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            return .indeterminate
        }
        guard let http = response as? HTTPURLResponse else {
            return .indeterminate
        }
        return Self.validity(statusCode: http.statusCode, body: data)
    }

    static func validity(statusCode: Int, body: Data) -> CloudSessionValidity {
        if statusCode == 401 {
            return .revoked
        }
        guard (200..<300).contains(statusCode) else {
            return .indeterminate
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let parsed = try? decoder.decode(CloudSessionIntrospectResponse.self, from: body) else {
            return .indeterminate
        }
        if parsed.active == true {
            return .valid
        }
        if parsed.active == false {
            return .revoked
        }
        return .indeterminate
    }
}
