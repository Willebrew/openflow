import Foundation

struct FailedInsertionReport: Codable {
    var id: UUID
    var createdAt: Date
    var targetApp: String
    var targetBundleID: String?
    var appCategory: AppCategory
    var method: InsertionMethod
    var attemptCount: Int
    var verified: Bool
    var failureReason: String
    var audioDuration: TimeInterval
    var transcriptionTime: TimeInterval
    var cleanupTime: TimeInterval
    var insertionTime: TimeInterval
    var totalTime: TimeInterval
    var contextAvailable: Bool
    var focusRaceDetected: Bool?
    var focusRaceDescription: String?
}

final class InsertionDiagnosticsService {
    static var directoryURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("openflow", isDirectory: true)
            .appendingPathComponent("diagnostics", isDirectory: true)
    }

    private let directory: URL

    init(directory: URL = InsertionDiagnosticsService.directoryURL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.directory = directory
    }

    func writeFailedInsertion(result: InsertionResult,
                              category: AppCategory,
                              metrics: LatencyMetrics) {
        guard !result.succeeded else { return }
        let report = FailedInsertionReport(id: UUID(),
                                           createdAt: Date(),
                                           targetApp: result.targetApp,
                                           targetBundleID: result.targetBundleID,
                                           appCategory: category,
                                           method: result.method,
                                           attemptCount: result.attemptCount,
                                           verified: result.verified,
                                           failureReason: result.failureReason ?? "Unknown insertion failure",
                                           audioDuration: metrics.audioDuration,
                                           transcriptionTime: metrics.uploadAndTranscriptionTime,
                                           cleanupTime: metrics.cleanupTime,
                                           insertionTime: metrics.insertionTime,
                                           totalTime: metrics.totalTime,
                                           contextAvailable: metrics.contextAvailable,
                                           focusRaceDetected: metrics.focusRaceDetected,
                                           focusRaceDescription: metrics.focusRaceDescription)
        guard let data = try? JSONEncoder.openflowDiagnostics.encode(report) else { return }
        let file = directory.appendingPathComponent("\(report.createdAt.openflowDiagnosticTimestamp)-\(report.id.uuidString).json")
        try? data.write(to: file, options: .atomic)
    }
}

private extension JSONEncoder {
    static var openflowDiagnostics: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension Date {
    var openflowDiagnosticTimestamp: String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: self)
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: ".", with: "-")
    }
}
