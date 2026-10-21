import Foundation

/// Payload from `GET <cloud base>/status/load`.
struct BackendLoadSnapshot: Equatable {
    var level: BackendLoadLevel
    var message: String?
    var updatedAt: Double?
}

enum BackendLoadLevel: String, Equatable {
    case normal
    case elevated
    case high
}

/// What the app may show. `hidden` is the only state for normal load and for
/// any response we refuse to trust.
enum BackendLoadNotice: Equatable {
    case hidden
    case elevated(String)
    case high(String)

    var text: String? {
        switch self {
        case .hidden:
            return nil
        case .elevated(let text), .high(let text):
            return text
        }
    }

    var accessibilityLabel: String {
        guard let text else { return "openflow" }
        return "openflow, \(text)"
    }
}

enum BackendLoadFetchOutcome: Equatable {
    /// Network errors, 404, non-2xx, and unreadable JSON leave the current notice alone.
    case unchanged
    case snapshot(BackendLoadSnapshot)
}

enum BackendLoadSchedule {
    static let activeInterval: TimeInterval = 60
    static let idleInterval: TimeInterval = 5 * 60
    static let idleAfter: TimeInterval = 5 * 60
    static let initialDelay: TimeInterval = 3
    static let opportunisticCooldown: TimeInterval = 20
    static let slowRequestSeconds: TimeInterval = 8

    /// `nil` means do not poll (the machine or the screen is asleep).
    static func pollInterval(idleFor: TimeInterval, asleep: Bool) -> TimeInterval? {
        if asleep { return nil }
        if idleFor >= idleAfter { return idleInterval }
        return activeInterval
    }

    /// A slow or failed backend call is a reason to refresh `/status/load`.
    /// It is not itself a high-load notice.
    static func shouldProbe(duration: TimeInterval, statusCode: Int?, transportFailed: Bool) -> Bool {
        if transportFailed { return true }
        if let statusCode, statusCode == 429 || statusCode >= 500 { return true }
        if duration >= slowRequestSeconds { return true }
        return false
    }
}

enum BackendLoadEndpoint {
    static func url(cloudBase: URL) -> URL {
        cloudBase.appendingPathComponent("status").appendingPathComponent("load")
    }

    /// Full request URL. Host trust is checked separately by `CloudURLPolicy`.
    static func overrideURL(from raw: String?) -> URL? {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty, let url = URL(string: trimmed) else { return nil }
        guard url.scheme?.lowercased() == "https",
              let host = url.host,
              !host.isEmpty,
              url.user == nil,
              url.password == nil else {
            return nil
        }
        return url
    }
}

enum BackendLoadNoticePolicy {
    static let highMessage = "We're experiencing high load, so things may be slower than usual"
    static let elevatedMessage = "Things may be a little slower than usual"

    static func notice(from snapshot: BackendLoadSnapshot) -> BackendLoadNotice {
        switch snapshot.level {
        case .normal:
            return .hidden
        case .elevated:
            return .elevated(snapshot.message ?? elevatedMessage)
        case .high:
            return .high(snapshot.message ?? highMessage)
        }
    }
}

enum BackendLoadReducer {
    static func apply(current: BackendLoadNotice, outcome: BackendLoadFetchOutcome) -> BackendLoadNotice {
        switch outcome {
        case .unchanged:
            return current
        case .snapshot(let snapshot):
            return BackendLoadNoticePolicy.notice(from: snapshot)
        }
    }
}

enum BackendLoadStatusDecoder {
    static func parse(_ data: Data) -> BackendLoadSnapshot? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        guard let rawLevel = object["level"] as? String,
              let level = BackendLoadLevel(rawValue: rawLevel) else {
            return nil
        }
        return BackendLoadSnapshot(
            level: level,
            message: sanitizedMessage(object["message"]),
            updatedAt: number(object["updatedAt"])
        )
    }

    static func interpret(statusCode: Int?, data: Data?, transportFailed: Bool) -> BackendLoadFetchOutcome {
        if transportFailed { return .unchanged }
        guard let statusCode, (200..<300).contains(statusCode), let data else {
            return .unchanged
        }
        guard let snapshot = parse(data) else { return .unchanged }
        return .snapshot(snapshot)
    }

    private static func sanitizedMessage(_ value: Any?) -> String? {
        guard let raw = value as? String else { return nil }
        let collapsed = raw.unicodeScalars.map { scalar -> Character in
            if scalar == "\n" || scalar == "\r" || scalar == "\t" { return " " }
            if CharacterSet.controlCharacters.contains(scalar) { return " " }
            return Character(scalar)
        }
        let trimmed = String(collapsed)
            .split { $0.isWhitespace }
            .joined(separator: " ")
        guard !trimmed.isEmpty else { return nil }
        if trimmed.count <= 160 { return trimmed }
        return String(trimmed.prefix(157)) + "..."
    }

    private static func number(_ value: Any?) -> Double? {
        if value is String || value is NSNull { return nil }
        if let number = value as? NSNumber { return number.doubleValue }
        if let number = value as? Int { return Double(number) }
        if let number = value as? Double { return number }
        return nil
    }
}

/// Thread-safe hook so cloud requests can ask for a status refresh without
/// knowing about the menu bar or the hub.
enum BackendLoadSignals {
    private static let lock = NSLock()
    private static var handler: (@Sendable () -> Void)?

    static func register(_ handler: (@Sendable () -> Void)?) {
        lock.lock()
        self.handler = handler
        lock.unlock()
    }

    static func note(duration: TimeInterval, statusCode: Int?, transportFailed: Bool) {
        guard BackendLoadSchedule.shouldProbe(
            duration: duration,
            statusCode: statusCode,
            transportFailed: transportFailed
        ) else { return }
        lock.lock()
        let handler = handler
        lock.unlock()
        handler?()
    }

    static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
    }
}
