import Combine
import Foundation

/// Cached result of the Home/Apps aggregation. Views read these fields instead
/// of recomputing `HomeActivityStats` helpers on every render.
struct HomeStatsSnapshot {
    var activityDays: [HomeActivityDay] = []
    var allApps: [HomeAppStat] = []
    var topApps: [HomeAppStat] = []
    var totalWords = 0
    var averageWPM = 0
    var weeklyStreak = 0
    var lifetimeAudioSeconds: Double = 0
    var timeSavedSeconds: Double = 0
    var typingSavedFraction: Double = 0
    var gaugeDisplay: (value: String, unit: String) = ("0", "s")
    var weekWords: (thisWeek: Int, lastWeek: Int) = (0, 0)
    var weekSaved: (thisWeek: Double, lastWeek: Double) = (0, 0)
    var calendarWeekWordCounts: [Int] = Array(repeating: 0, count: 7)
}

/// Raw inputs the snapshot builder needs. Captured on the main actor so the
/// aggregation itself can run detached.
struct HomeStatsInput {
    var preferCloud = false
    var items: [DictationHistoryItem] = []
    var lifetimeWords = 0
    var lifetimeAudioSeconds: Double = 0
    var appStats: [HomeAppStat] = []
    var cloudStats = OpenFlowCloudStats()
}

/// Owns Home/Apps stats. Recomputes the snapshot off the main thread
/// (debounced) whenever history, cloud stats, or session state change; views
/// only ever read the published result.
@MainActor
final class HomeStatsStore: ObservableObject {
    @Published private(set) var snapshot = HomeStatsSnapshot()

    private var latestInput = HomeStatsInput()
    private var scheduledRecompute: DispatchWorkItem?

    /// Debounce so a processing burst (history add + lifetime + apps +
    /// post-dictation stats refresh) becomes a single recompute.
    private static let debounceInterval: TimeInterval = 0.15

    func update(input: HomeStatsInput, immediate: Bool = false) {
        latestInput = input
        guard scheduledRecompute == nil else { return }
        let delay = immediate ? 0 : Self.debounceInterval
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.scheduledRecompute = nil
            let inputs = self.latestInput
            Task.detached(priority: .utility) {
                let computed = Self.buildSnapshot(input: inputs)
                await MainActor.run { [weak self] in
                    self?.snapshot = computed
                }
            }
        }
        scheduledRecompute = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Mirrors the reads HomeDashboardView used to do inline. Pure and
    /// detached-safe: everything it touches comes from `input`.
    nonisolated static func buildSnapshot(input: HomeStatsInput) -> HomeStatsSnapshot {
        var snapshot = HomeStatsSnapshot()

        let cloudDays = input.cloudStats.days.map {
            HomeActivityDay(dayKey: $0.dayKey,
                            words: $0.words,
                            audioSeconds: $0.audioSeconds,
                            dictations: $0.dictations)
        }
        let days: [HomeActivityDay]
        if input.preferCloud {
            days = HomeActivityStats.aggregate(history: [], cloudDays: cloudDays)
        } else {
            days = HomeActivityStats.aggregate(
                history: input.items.map {
                    (timestamp: $0.timestamp, finalText: $0.finalText, audioDuration: $0.metrics.audioDuration)
                },
                cloudDays: []
            )
        }
        snapshot.activityDays = days

        if input.preferCloud {
            snapshot.totalWords = max(input.cloudStats.lifetimeWords, input.lifetimeWords)
        } else {
            snapshot.totalWords = HomeActivityStats.lifetimeWords(days: days,
                                                                  localLifetime: input.lifetimeWords)
        }

        var wpm = HomeActivityStats.averageWPM(words: input.lifetimeWords,
                                             audioSeconds: input.lifetimeAudioSeconds)
        if input.preferCloud {
            let cloud = input.cloudStats.lifetimeAverageWPM
            if cloud > 0 { wpm = cloud }
        }
        snapshot.averageWPM = wpm

        snapshot.weeklyStreak = HomeActivityStats.consecutiveStreak(days: days)
        snapshot.lifetimeAudioSeconds = input.preferCloud
            ? max(input.cloudStats.lifetimeAudioSeconds, input.lifetimeAudioSeconds)
            : input.lifetimeAudioSeconds
        snapshot.timeSavedSeconds = HomeActivityStats.timeSavedSeconds(
            words: snapshot.totalWords,
            audioSeconds: snapshot.lifetimeAudioSeconds)
        snapshot.typingSavedFraction = snapshot.totalWords > 0
            ? HomeActivityStats.typingSavedFraction(words: snapshot.totalWords,
                                                    audioSeconds: snapshot.lifetimeAudioSeconds)
            : 0
        snapshot.gaugeDisplay = HomeActivityStats.gaugeTimeSaved(snapshot.timeSavedSeconds)
        snapshot.weekWords = HomeActivityStats.weekWords(days: days)
        snapshot.weekSaved = HomeActivityStats.weekTimeSaved(days: days)
        snapshot.calendarWeekWordCounts = HomeActivityStats.calendarWeekWordCounts(days: days)
        snapshot.allApps = HomeActivityStats.dictationApps(
            preferCloud: input.preferCloud,
            cloudApps: input.cloudStats.apps?.map {
                (appName: $0.appName, bundleID: $0.bundleID, words: $0.words, audioSeconds: $0.audioSeconds)
            },
            localApps: input.appStats,
            history: input.items.map {
                (appName: $0.appName, bundleID: $0.bundleID, finalText: $0.finalText, audioDuration: $0.metrics.audioDuration)
            },
            averageWPM: snapshot.averageWPM
        )
        snapshot.topApps = Array(snapshot.allApps.prefix(HomeActivityStats.homeTopAppCount))
        return snapshot
    }
}
