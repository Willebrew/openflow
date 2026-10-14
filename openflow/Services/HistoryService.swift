import Foundation
import Combine

private struct LifetimeTotals: Codable, Equatable {
    var words: Int
    var audioSeconds: Double
    var dictations: Int
}

private struct LifetimeAppTotal: Codable, Equatable {
    var appName: String
    var bundleID: String?
    var words: Int
    var audioSeconds: Double
}

@MainActor
final class HistoryService: ObservableObject {
    @Published private(set) var items: [DictationHistoryItem] = []
    @Published private(set) var lifetimeWords: Int = 0
    @Published private(set) var lifetimeAudioSeconds: Double = 0
    @Published private(set) var appStats: [HomeAppStat] = []
    private let url: URL
    private let lifetimeURL: URL
    private let appsURL: URL
    private var lifetime = LifetimeTotals(words: 0, audioSeconds: 0, dictations: 0)
    private var lifetimeApps: [String: LifetimeAppTotal] = [:]

    /// Persistence is debounced onto a background queue: JSON-encoding 300
    /// items (~384KB) synchronously on main for every change stalls the UI
    /// during processing. Value snapshots are captured on the main actor at
    /// schedule time; the latest write always wins.
    private let persistQueue = DispatchQueue(label: "openflow.history-persist", qos: .utility)
    private var pendingHistoryWrite: DispatchWorkItem?
    private var pendingLifetimeWrite: DispatchWorkItem?
    private var pendingAppsWrite: DispatchWorkItem?
    private static let persistDebounce: TimeInterval = 0.3

    init(url: URL? = nil) {
        if let url {
            self.url = url
            let directory = url.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            self.lifetimeURL = directory.appendingPathComponent("lifetime.json")
            self.appsURL = directory.appendingPathComponent("lifetime-apps.json")
        } else {
            let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("openflow", isDirectory: true)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            self.url = directory.appendingPathComponent("history.json")
            self.lifetimeURL = directory.appendingPathComponent("lifetime.json")
            self.appsURL = directory.appendingPathComponent("lifetime-apps.json")
        }
        load()
    }

    func add(_ item: DictationHistoryItem, settings: UserSettings) {
        guard settings.historyEnabled else { return }
        var stored = item
        if !settings.storeRawTranscript { stored.rawTranscript = nil }
        items.insert(stored, at: 0)
        items = Array(items.prefix(300))
        // A new dictation is persisted before add returns (matching the old
        // synchronous save contract); the encode+write still happens on the
        // utility queue, just without the debounce delay.
        save(immediate: true)
        persistQueue.sync { }
    }

    func delete(_ item: DictationHistoryItem) {
        items.removeAll { $0.id == item.id }
        save()
    }

    func clear() {
        items.removeAll()
        save()
    }

    /// Count words even when History is off or old items later roll off the 300-item cap.
    func recordLifetime(text: String,
                        audioSeconds: Double,
                        appName: String = "",
                        bundleID: String? = nil) {
        let words = text.split(whereSeparator: \.isWhitespace).count
        guard words > 0 else { return }
        lifetime.words += words
        lifetime.audioSeconds += max(0, audioSeconds)
        lifetime.dictations += 1
        lifetimeWords = lifetime.words
        lifetimeAudioSeconds = lifetime.audioSeconds
        saveLifetime()
        recordAppUsage(appName: appName, bundleID: bundleID, words: words, audioSeconds: audioSeconds)
    }

    func adoptLifetimeHighWater(words: Int, audioSeconds: Double = 0) {
        var changed = false
        if words > lifetime.words {
            lifetime.words = words
            changed = true
        }
        if audioSeconds > lifetime.audioSeconds {
            lifetime.audioSeconds = audioSeconds
            changed = true
        }
        guard changed else { return }
        lifetimeWords = lifetime.words
        lifetimeAudioSeconds = lifetime.audioSeconds
        saveLifetime()
    }

    func adoptAppHighWater(_ apps: [HomeAppStat]) {
        var changed = false
        for app in apps {
            let key = app.id
            guard key != "n:" else { continue }
            let existing = lifetimeApps[key]
            let nextWords = max(existing?.words ?? 0, app.words)
            let nextAudio = max(existing?.audioSeconds ?? 0, app.audioSeconds)
            let nextName = app.appName.count >= (existing?.appName.count ?? 0) ? app.appName : (existing?.appName ?? app.appName)
            let incomingBundle = app.bundleID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let nextBundle = incomingBundle.isEmpty ? existing?.bundleID : app.bundleID
            if existing?.words != nextWords
                || existing?.audioSeconds != nextAudio
                || existing?.appName != nextName
                || existing?.bundleID != nextBundle {
                lifetimeApps[key] = LifetimeAppTotal(
                    appName: nextName,
                    bundleID: nextBundle,
                    words: nextWords,
                    audioSeconds: nextAudio
                )
                changed = true
            }
        }
        guard changed else { return }
        publishAppStats()
        saveApps()
    }

    private func load() {
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([DictationHistoryItem].self, from: data) {
            items = decoded
        }
        if let data = try? Data(contentsOf: lifetimeURL),
           let decoded = try? JSONDecoder().decode(LifetimeTotals.self, from: data) {
            lifetime = decoded
        }
        let fromItems = items.reduce(0) { $0 + $1.finalText.split(whereSeparator: \.isWhitespace).count }
        lifetime.words = max(lifetime.words, fromItems)
        lifetimeWords = lifetime.words
        lifetimeAudioSeconds = lifetime.audioSeconds
        if lifetime.words > 0 {
            saveLifetime()
        }
        loadApps()
        adoptAppsFromHistoryItems()
        publishAppStats()
    }

    private func save(immediate: Bool = false) {
        let snapshot = items
        let target = url
        pendingHistoryWrite?.cancel()
        let work = DispatchWorkItem {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: target, options: .atomic)
        }
        pendingHistoryWrite = work
        if immediate {
            persistQueue.async(execute: work)
        } else {
            persistQueue.asyncAfter(deadline: .now() + Self.persistDebounce, execute: work)
        }
    }

    private func saveLifetime() {
        let snapshot = lifetime
        let target = lifetimeURL
        pendingLifetimeWrite?.cancel()
        let work = DispatchWorkItem {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: target, options: .atomic)
        }
        pendingLifetimeWrite = work
        persistQueue.asyncAfter(deadline: .now() + Self.persistDebounce, execute: work)
    }

    private func recordAppUsage(appName: String, bundleID: String?, words: Int, audioSeconds: Double) {
        let name = appName.trimmingCharacters(in: .whitespacesAndNewlines)
        let bundle = bundleID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let key = bundle.isEmpty ? "n:\(name.lowercased())" : "b:\(bundle.lowercased())"
        guard key != "n:" else { return }
        let existing = lifetimeApps[key]
        lifetimeApps[key] = LifetimeAppTotal(
            appName: name.isEmpty ? (existing?.appName ?? "Unknown") : name,
            bundleID: bundle.isEmpty ? existing?.bundleID : bundle,
            words: (existing?.words ?? 0) + words,
            audioSeconds: (existing?.audioSeconds ?? 0) + max(0, audioSeconds)
        )
        publishAppStats()
        saveApps()
    }

    private func adoptAppsFromHistoryItems() {
        var fromItems: [String: LifetimeAppTotal] = [:]
        for item in items {
            let name = item.appName.trimmingCharacters(in: .whitespacesAndNewlines)
            let bundle = item.bundleID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let key = bundle.isEmpty ? "n:\(name.lowercased())" : "b:\(bundle.lowercased())"
            guard key != "n:" else { continue }
            let words = item.finalText.split(whereSeparator: \.isWhitespace).count
            let existing = fromItems[key]
            fromItems[key] = LifetimeAppTotal(
                appName: name.isEmpty ? (existing?.appName ?? "Unknown") : name,
                bundleID: bundle.isEmpty ? existing?.bundleID : bundle,
                words: (existing?.words ?? 0) + words,
                audioSeconds: (existing?.audioSeconds ?? 0) + max(0, item.metrics.audioDuration)
            )
        }
        var byKey = lifetimeApps
        for (key, summed) in fromItems {
            let existing = byKey[key]
            byKey[key] = LifetimeAppTotal(
                appName: summed.appName.count >= (existing?.appName.count ?? 0)
                    ? summed.appName
                    : (existing?.appName ?? summed.appName),
                bundleID: (summed.bundleID?.isEmpty ?? true) ? existing?.bundleID : summed.bundleID,
                words: max(existing?.words ?? 0, summed.words),
                audioSeconds: max(existing?.audioSeconds ?? 0, summed.audioSeconds)
            )
        }
        lifetimeApps = byKey
        if !lifetimeApps.isEmpty {
            saveApps()
        }
    }

    private func loadApps() {
        guard let data = try? Data(contentsOf: appsURL),
              let decoded = try? JSONDecoder().decode([String: LifetimeAppTotal].self, from: data) else {
            return
        }
        lifetimeApps = decoded
    }

    private func saveApps() {
        let snapshot = lifetimeApps
        let target = appsURL
        pendingAppsWrite?.cancel()
        let work = DispatchWorkItem {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: target, options: .atomic)
        }
        pendingAppsWrite = work
        persistQueue.asyncAfter(deadline: .now() + Self.persistDebounce, execute: work)
    }

    /// Runs any queued writes now. Called on app termination so the debounce
    /// window cannot drop the last dictation's history.
    func flushPendingWrites() {
        for work in [pendingHistoryWrite, pendingLifetimeWrite, pendingAppsWrite] {
            work?.cancel()
            work?.perform()
        }
        pendingHistoryWrite = nil
        pendingLifetimeWrite = nil
        pendingAppsWrite = nil
        persistQueue.sync { }
    }

    private func publishAppStats() {
        appStats = lifetimeApps.values
            .map {
                HomeAppStat(
                    appName: $0.appName,
                    bundleID: $0.bundleID,
                    words: $0.words,
                    audioSeconds: $0.audioSeconds
                )
            }
            .sorted {
                if $0.words != $1.words { return $0.words > $1.words }
                return $0.appName.localizedCaseInsensitiveCompare($1.appName) == .orderedAscending
            }
    }
}
