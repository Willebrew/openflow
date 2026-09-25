import Foundation
import AppKit

/// Append-only diagnostics file for field debugging. Unlike the in-memory
/// `debugLog` (gated on the Debug logs toggle and capped at 200 lines), this
/// always writes so failures can be captured without reproducing twice.
/// Local only: ~/Library/Application Support/openflow/openflow-debug.log.
/// Rotates by keeping the newest tail once it grows past ~512 KB.
final class DiagnosticsLog {
    static let shared = DiagnosticsLog()

    static var fileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("openflow", isDirectory: true)
            .appendingPathComponent("openflow-debug.log")
    }

    private let queue = DispatchQueue(label: "openflow.diagnostics-log")
    private let url: URL
    private let maxBytes = 512 * 1024
    private let keepBytes = 256 * 1024

    init(url: URL = DiagnosticsLog.fileURL) {
        self.url = url
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true)
    }

    func write(_ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "\(timestamp)  \(message)\n"
        queue.async {
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: self.url) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: self.url, options: .atomic)
            }
            self.rotateIfNeeded()
        }
    }

    @MainActor
    func revealInFinder() {
        if !FileManager.default.fileExists(atPath: url.path) {
            try? "".data(using: .utf8)?.write(to: url, options: .atomic)
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func rotateIfNeeded() {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int,
              size > maxBytes,
              let data = try? Data(contentsOf: url),
              data.count > keepBytes else { return }
        let tail = data.subdata(in: (data.count - keepBytes)..<data.count)
        try? tail.write(to: url, options: .atomic)
    }
}
