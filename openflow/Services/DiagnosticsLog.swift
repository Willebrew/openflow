import Foundation
import AppKit
import Combine
import os

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

/// Live diagnostics state for the Settings diagnostics page only. It sits on
/// its own ObservableObject so appends and metric updates never invalidate the
/// hub window or unrelated pages during processing.
@MainActor
final class DiagnosticsStore: ObservableObject {
    @Published var entries: [String] = []
    @Published var currentMetrics = LatencyMetrics()
}

/// os_signpost instrumentation for the two latency budgets this app cares
/// about: hub tab switches and dictation stop -> insert. Each interval is also
/// written to `DiagnosticsLog` so timings can be read back from the debug log
/// without Instruments attached.
enum OpenflowSignpost {
    private static let poster = OSSignposter(subsystem: "com.neuroquestlabs.openflow",
                                           category: .pointsOfInterest)

    private static var tabSwitchState: OSSignpostIntervalState?
    private static var tabSwitchBegan: Date?
    private static var tabSwitchDestination: String?

    private static var dictationState: OSSignpostIntervalState?
    private static var dictationBegan: Date?

    @MainActor
    static func beginTabSwitch(to tab: String) {
        endPendingTabSwitch(reason: "superseded")
        tabSwitchState = poster.beginInterval("HubTabSwitch")
        tabSwitchBegan = Date()
        tabSwitchDestination = tab
    }

    /// Ends the pending tab-switch interval. Called when the destination page
    /// reports it is visible; extra calls are no-ops so both the page's own
    /// onAppear and the post-commit tick can race here safely.
    @MainActor
    static func endTabSwitch(arrived tab: String) {
        guard let state = tabSwitchState, let began = tabSwitchBegan else { return }
        poster.endInterval("HubTabSwitch", state)
        let elapsed = Date().timeIntervalSince(began)
        tabSwitchState = nil
        tabSwitchBegan = nil
        tabSwitchDestination = nil
        DiagnosticsLog.shared.write("hub tab switch to \(tab): \(String(format: "%.0f", elapsed * 1000))ms")
    }

    @MainActor
    private static func endPendingTabSwitch(reason: String) {
        guard let state = tabSwitchState else { return }
        poster.endInterval("HubTabSwitch", state)
        DiagnosticsLog.shared.write("hub tab switch to \(tabSwitchDestination ?? "?"): \(reason)")
        tabSwitchState = nil
        tabSwitchBegan = nil
        tabSwitchDestination = nil
    }

    @MainActor
    static func beginDictationPipeline() {
        endDictationPipeline(outcome: "superseded")
        dictationState = poster.beginInterval("DictationStopToInsert")
        dictationBegan = Date()
    }

    /// Ends the dictation stop -> insert interval and logs the wall-clock
    /// duration. `outcome` is e.g. "inserted", "voice-agent", "error".
    @MainActor
    static func endDictationPipeline(outcome: String) {
        guard let state = dictationState, let began = dictationBegan else { return }
        poster.endInterval("DictationStopToInsert", state)
        let elapsed = Date().timeIntervalSince(began)
        dictationState = nil
        dictationBegan = nil
        DiagnosticsLog.shared.write("dictation stop->insert (\(outcome)): \(String(format: "%.0f", elapsed * 1000))ms")
    }
}
