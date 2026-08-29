import CryptoKit
import Foundation
import Security

/// Protocol v2 device identity for the update server. The Ed25519 *device* key is
/// distinct from `UpdateConfiguration.publicKeyBase64` (the baked-in *release*
/// verify key, which must not be rotated here).
enum UpdateDeviceIdentity {
    static let installIDKey = "updates.installID"
    static let registeredKey = "updates.deviceRegistered"
    static let lastHeartbeatTsKey = "updates.lastHeartbeatTs"

    private static let keychainService = "com.neuroquestlabs.openflow.nq-updates"
    private static let keychainAccount = "device-ed25519"
    private static let installIDLength = 8...128
    private static let maxUserLabel = 64
    private static let maxFutureSkewMs: Int64 = 60_000

    static func installID() -> String {
        if let existing = UserDefaults.standard.string(forKey: installIDKey),
           installIDLength.contains(existing.count) {
            return existing
        }
        let value = randomInstallID()
        UserDefaults.standard.set(value, forKey: installIDKey)
        UserDefaults.standard.set(false, forKey: registeredKey)
        return value
    }

    static func rotateInstallID() -> String {
        let value = randomInstallID()
        UserDefaults.standard.set(value, forKey: installIDKey)
        UserDefaults.standard.set(false, forKey: registeredKey)
        UserDefaults.standard.removeObject(forKey: lastHeartbeatTsKey)
        return value
    }

    static var isRegistered: Bool {
        UserDefaults.standard.bool(forKey: registeredKey)
    }

    static func markRegistered() {
        UserDefaults.standard.set(true, forKey: registeredKey)
    }

    static func markUnregistered() {
        UserDefaults.standard.set(false, forKey: registeredKey)
    }

    static func deviceKeyPair() throws -> Curve25519.Signing.PrivateKey {
        if let stored = try KeychainService.shared.genericPassword(
            service: keychainService,
            account: keychainAccount
        ), stored.count == 32,
           let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: stored) {
            return key
        }
        let key = Curve25519.Signing.PrivateKey()
        try KeychainService.shared.saveGenericPassword(
            key.rawRepresentation,
            service: keychainService,
            account: keychainAccount
        )
        UserDefaults.standard.set(false, forKey: registeredKey)
        return key
    }

    static func devicePublicKeyBase64(_ key: Curve25519.Signing.PrivateKey) -> String {
        key.publicKey.rawRepresentation.base64EncodedString()
    }

    static func nextHeartbeatTimestamp(nowMs: Int64 = currentUnixMs()) -> Int64? {
        let last = (UserDefaults.standard.object(forKey: lastHeartbeatTsKey) as? NSNumber)?
            .int64Value ?? 0
        var ts = nowMs
        if last >= ts {
            ts = last + 1
        }
        if ts > nowMs + maxFutureSkewMs {
            return nil
        }
        return ts
    }

    static func recordHeartbeatTimestamp(_ ts: Int64) {
        UserDefaults.standard.set(NSNumber(value: ts), forKey: lastHeartbeatTsKey)
    }

    static func canonicalHeartbeatPayload(installID: String,
                                          app: String,
                                          channel: String,
                                          platform: String,
                                          currentVersion: String,
                                          ts: Int64) -> Data {
        let fields = [
            "install_id=\(installID)",
            "app=\(app)",
            "channel=\(channel)",
            "platform=\(platform)",
            "current_version=\(currentVersion)",
            "ts=\(ts)",
        ]
        return Data(fields.joined(separator: "\n").utf8)
    }

    static func signHeartbeat(privateKey: Curve25519.Signing.PrivateKey,
                              payload: Data) throws -> String {
        try privateKey.signature(for: payload).base64EncodedString()
    }

    static func userLabel() -> String? {
        let raw = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let clipped = String(trimmed.prefix(maxUserLabel))
        if clipped.contains("@") || clipped.contains("\n") || clipped.contains("\r") {
            return nil
        }
        return clipped
    }

    static func currentUnixMs() -> Int64 {
        Int64((Date().timeIntervalSince1970 * 1000.0).rounded(.down))
    }

    private static func randomInstallID() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status != errSecSuccess {
            let key = SymmetricKey(size: .bits256)
            return key.withUnsafeBytes { raw in
                raw.map { String(format: "%02x", $0) }.joined()
            }
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}
