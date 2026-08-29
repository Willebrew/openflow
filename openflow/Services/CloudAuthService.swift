import AppKit
import Foundation

struct CloudAuthUser: Codable {
    var id: String
    var email: String?
    var name: String?
    var image: String?
}

private struct DeviceAuthorizationResponse: Codable {
    var deviceCode: String
    var userCode: String
    var verificationUri: URL
    var verificationUriComplete: URL?
    var expiresIn: TimeInterval
    var interval: TimeInterval
}

private struct DeviceTokenResponse: Codable {
    var sessionToken: String
    var expiresAt: Date?
    var user: CloudAuthUser
}

final class CloudAuthService {
    private let keychain: KeychainService
    private let session: URLSession
    private let authBaseURL = URL(string: "https://auth.neuroquestlabs.ai")!

    init(keychain: KeychainService = .shared, session: URLSession = .shared) {
        self.keychain = keychain
        self.session = session
    }

    func connectDevice(
        onAuthorization: (@MainActor (String) -> Void)? = nil
    ) async throws -> CloudAuthUser {
        let device = Host.current().localizedName ?? "Mac"
        var request = URLRequest(url: authBaseURL.appendingPathComponent("api/openflow/device/start"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["deviceName": device])
        let authorization: DeviceAuthorizationResponse = try await send(request)
        if let onAuthorization {
            await onAuthorization(Self.formattedUserCode(authorization.userCode))
        }
        let verificationURL = try CloudURLPolicy.validate(authorization.verificationUriComplete
                                                              ?? authorization.verificationUri,
                                                          usage: .deviceVerification,
                                                          baseURL: authBaseURL)

        _ = await MainActor.run {
            CloudURLPolicy.openExternal(verificationURL)
        }

        let deadline = Date().addingTimeInterval(authorization.expiresIn)
        let pollInterval = max(1, authorization.interval)
        while Date() < deadline {
            try Task.checkCancellation()
            try await Task.sleep(for: .seconds(pollInterval))

            var tokenRequest = URLRequest(url: authBaseURL.appendingPathComponent("api/openflow/device/token"))
            tokenRequest.httpMethod = "POST"
            tokenRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            tokenRequest.httpBody = try JSONEncoder().encode(["deviceCode": authorization.deviceCode])
            let (data, response) = try await session.data(for: tokenRequest)
            guard let http = response as? HTTPURLResponse else {
                throw OpenflowError.cloudProviderUnavailable("No auth response.")
            }
            if http.statusCode == 202 {
                continue
            }
            guard 200..<300 ~= http.statusCode else {
                throw cloudError(data: data, statusCode: http.statusCode)
            }

            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let token = try decoder.decode(DeviceTokenResponse.self, from: data)
            try keychain.saveCloudSessionToken(token.sessionToken)
            return token.user
        }
        throw OpenflowError.cloudProviderUnavailable("Sign-in approval expired. Please try again.")
    }

    func signOut() {
        keychain.deleteCloudTokens()
    }

    func validateStoredSession() async -> CloudSessionValidity {
        guard let token = try? keychain.cloudSessionToken(), !token.isEmpty else {
            return .indeterminate
        }
        return await CloudSessionValidator(session: session, authBaseURL: authBaseURL)
            .validate(token: token)
    }

    private static func formattedUserCode(_ code: String) -> String {
        let compact = code
            .uppercased()
            .filter { $0.isLetter || $0.isNumber }
        guard compact.count > 4 else { return compact }
        let midpoint = compact.index(compact.startIndex, offsetBy: compact.count / 2)
        return "\(compact[..<midpoint])-\(compact[midpoint...])"
    }

    private func send<Response: Decodable>(_ request: URLRequest) async throws -> Response {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OpenflowError.cloudProviderUnavailable("No auth response.")
        }
        guard 200..<300 ~= http.statusCode else {
            throw cloudError(data: data, statusCode: http.statusCode)
        }
        return try JSONDecoder().decode(Response.self, from: data)
    }

    private func cloudError(data: Data, statusCode: Int) -> OpenflowError {
        let message = (try? JSONSerialization.jsonObject(with: data))
            .flatMap { $0 as? [String: Any] }?["error"] as? String
        return .cloudProviderUnavailable(message ?? "Authentication failed (HTTP \(statusCode)).")
    }
}
