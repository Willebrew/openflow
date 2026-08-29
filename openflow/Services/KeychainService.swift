import Foundation
import Security

final class KeychainService {
    static let shared = KeychainService()
    private let service = "openflow.groq"
    private let account = "api-key"
    private let cloudService = "openflow.cloud"
    private let cloudSessionAccount = "session-token"

    func saveAPIKey(_ key: String) throws {
        let data = Data(key.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: data
        ]
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.unhandled(status) }
    }

    func apiKey() throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError.unhandled(status) }
        guard let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func deleteAPIKey() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }

    func saveCloudSessionToken(_ token: String) throws {
        try saveSecret(token, service: cloudService, account: cloudSessionAccount)
    }

    func cloudSessionToken() throws -> String? {
        try secret(service: cloudService, account: cloudSessionAccount)
    }

    func deleteCloudTokens() {
        deleteSecret(service: cloudService, account: cloudSessionAccount)
        deleteSecret(service: cloudService, account: "convex-jwt")
    }

    func saveGenericPassword(_ data: Data, service: String, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: data
        ]
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.unhandled(status) }
    }

    func genericPassword(service: String, account: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError.unhandled(status) }
        return result as? Data
    }

    private func saveSecret(_ value: String, service: String, account: String) throws {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: data
        ]
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.unhandled(status) }
    }

    private func secret(service: String, account: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError.unhandled(status) }
        guard let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func deleteSecret(service: String, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}

enum KeychainError: LocalizedError {
    case unhandled(OSStatus)
    case persistenceVerificationFailed

    var errorDescription: String? {
        switch self {
        case .unhandled(let status):
            return "The API key could not be stored in Keychain (error \(status))."
        case .persistenceVerificationFailed:
            return "The API key could not be verified after saving. Please try again."
        }
    }
}

enum GroqAPIKeyValidationError: LocalizedError {
    case empty
    case invalid
    case forbidden
    case serviceUnavailable
    case unexpectedResponse

    var errorDescription: String? {
        switch self {
        case .empty:
            return "Enter a Groq API key."
        case .invalid:
            return "That Groq API key is not valid."
        case .forbidden:
            return "That Groq API key does not have access."
        case .serviceUnavailable:
            return "Groq could not be reached. Check your connection and try again."
        case .unexpectedResponse:
            return "Groq returned an unexpected response. Try again."
        }
    }
}

struct GroqAPIKeyValidator {
    private static let endpoint = URL(string: "https://api.groq.com/openai/v1/models")!

    func validate(_ rawKey: String, session: URLSession = .shared) async throws {
        let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            throw GroqAPIKeyValidationError.empty
        }

        var request = URLRequest(url: Self.endpoint, timeoutInterval: 15)
        request.httpMethod = "GET"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let response: URLResponse
        do {
            (_, response) = try await session.data(for: request)
        } catch {
            throw GroqAPIKeyValidationError.serviceUnavailable
        }

        guard let http = response as? HTTPURLResponse else {
            throw GroqAPIKeyValidationError.unexpectedResponse
        }
        switch http.statusCode {
        case 200..<300:
            return
        case 401:
            throw GroqAPIKeyValidationError.invalid
        case 403:
            throw GroqAPIKeyValidationError.forbidden
        case 500..<600:
            throw GroqAPIKeyValidationError.serviceUnavailable
        default:
            throw GroqAPIKeyValidationError.unexpectedResponse
        }
    }
}
