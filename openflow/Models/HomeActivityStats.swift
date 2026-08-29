import Foundation

    /// Day-bucketed Home stats. Signed-in Home uses cloud days only; signed-out uses local history.
struct HomeActivityDay: Equatable {
    var dayKey: String
    var words: Int
    var audioSeconds: Double
    var dictations: Int
}

struct HomeAppStat: Equatable, Identifiable {
    var appName: String
    var bundleID: String?
    var words: Int
    var audioSeconds: Double = 0

    var id: String {
        let bundle = bundleID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !bundle.isEmpty { return "b:\(bundle.lowercased())" }
        return "n:\(appName.lowercased())"
    }
}

enum HomeActivityStats {
    /// Local calendar day keys (`yyyy-MM-dd`) so Home streak/grid match the user's days.
    static func dayFormatter(timeZone: TimeZone = .current) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }

    static func aggregate(
        history: [(timestamp: Date, finalText: String, audioDuration: TimeInterval)],
        cloudDays: [HomeActivityDay],
        timeZone: TimeZone = .current
    ) -> [HomeActivityDay] {
        let formatter = dayFormatter(timeZone: timeZone)
        var localByDay: [String: HomeActivityDay] = [:]
        for item in history {
            let key = formatter.string(from: item.timestamp)
            let existing = localByDay[key]
            localByDay[key] = HomeActivityDay(
                dayKey: key,
                words: (existing?.words ?? 0)
                    + wordCount(in: item.finalText),
                audioSeconds: (existing?.audioSeconds ?? 0) + max(0, item.audioDuration),
                dictations: (existing?.dictations ?? 0) + 1
            )
        }

        let localDayKeys = Set(localByDay.keys)
        var cloudByLocalDay: [String: HomeActivityDay] = [:]
        for cloudDay in cloudDays {
            let key = localizedCloudDayKey(
                utcDayKey: cloudDay.dayKey,
                localDayKeys: localDayKeys,
                timeZone: timeZone
            )
            let localized = HomeActivityDay(
                dayKey: key,
                words: cloudDay.words,
                audioSeconds: cloudDay.audioSeconds,
                dictations: cloudDay.dictations
            )
            if let existing = cloudByLocalDay[key] {
                // Distinct UTC buckets that fold onto one local day are different events.
                cloudByLocalDay[key] = summing(existing, localized)
            } else {
                cloudByLocalDay[key] = localized
            }
        }

        var merged = localByDay
        for (key, cloudDay) in cloudByLocalDay {
            guard let localDay = merged[key] else {
                merged[key] = cloudDay
                continue
            }
            merged[key] = maximizing(localDay, cloudDay)
        }
        return merged.values.sorted { $0.dayKey < $1.dayKey }
    }

    /// Map a cloud UTC `yyyy-MM-dd` onto the user's local calendar day.
    ///
    /// `/openflow/stats` stores `toISOString().slice(0, 10)` (UTC). Parsing that
    /// string as UTC midnight and then taking `Calendar.current.startOfDay`
    /// shifts west-of-UTC mornings onto yesterday and zeroed Home streak.
    /// Use UTC noon as the civil date so a US morning stays on the same local
    /// date; if local history already has the previous local evening, fold the
    /// next UTC date back onto that evening instead of splitting one day in two.
    static func localizedCloudDayKey(
        utcDayKey: String,
        localDayKeys: Set<String>,
        timeZone: TimeZone = .current
    ) -> String {
        let civilKey = civilLocalDayKey(fromUTCCloudDayKey: utcDayKey, timeZone: timeZone) ?? utcDayKey
        if localDayKeys.contains(civilKey) {
            return civilKey
        }
        if let previousLocalKey = previousLocalDayKey(fromUTCCloudDayKey: utcDayKey, timeZone: timeZone),
           localDayKeys.contains(previousLocalKey) {
            return previousLocalKey
        }
        return civilKey
    }

    /// UTC noon of the cloud day, formatted in `timeZone`.
    static func civilLocalDayKey(fromUTCCloudDayKey utcDayKey: String, timeZone: TimeZone) -> String? {
        guard let utcNoon = utcInstant(fromDayKey: utcDayKey, hour: 12) else { return nil }
        return dayFormatter(timeZone: timeZone).string(from: utcNoon)
    }

    /// UTC midnight of the cloud day, formatted in `timeZone` (previous local evening west of UTC).
    static func previousLocalDayKey(fromUTCCloudDayKey utcDayKey: String, timeZone: TimeZone) -> String? {
        guard let utcMidnight = utcInstant(fromDayKey: utcDayKey, hour: 0) else { return nil }
        return dayFormatter(timeZone: timeZone).string(from: utcMidnight)
    }

    /// Consecutive local calendar days with activity.
    /// Counts backward from today when today has activity; otherwise from yesterday
    /// so a streak stays alive until the local day ends.
    static func consecutiveStreak(
        days: [HomeActivityDay],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Int {
        let formatter = dayFormatter(timeZone: calendar.timeZone)
        let dayKeys = Set(days.map(\.dayKey))
        guard !dayKeys.isEmpty else { return 0 }

        var day = calendar.startOfDay(for: now)
        if !dayKeys.contains(formatter.string(from: day)) {
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: day) else { return 0 }
            day = yesterday
            guard dayKeys.contains(formatter.string(from: day)) else { return 0 }
        }

        var streak = 0
        while dayKeys.contains(formatter.string(from: day)) {
            streak += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: day) else { break }
            day = previous
        }
        return streak
    }

    static func wordCount(in text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }

    static func totalWords(days: [HomeActivityDay]) -> Int {
        days.reduce(0) { $0 + $1.words }
    }

    /// Lifetime total: never take a recent window over a larger retained or stored count.
    static func lifetimeWords(days: [HomeActivityDay],
                              cloudLifetime: Int = 0,
                              localLifetime: Int = 0) -> Int {
        max(totalWords(days: days), max(cloudLifetime, localLifetime))
    }

    static func averageWPM(days: [HomeActivityDay]) -> Int {
        averageWPM(
            words: totalWords(days: days),
            audioSeconds: days.reduce(0.0) { $0 + $1.audioSeconds }
        )
    }

    static func averageWPM(words: Int, audioSeconds: Double) -> Int {
        guard words > 0, audioSeconds > 0 else { return 0 }
        return Int((Double(words) / audioSeconds) * 60.0)
    }

    static let typingWPM = 40.0

    static func timeSavedSeconds(words: Int, audioSeconds: Double) -> Double {
        max(0, (Double(max(0, words)) / typingWPM) * 60 - max(0, audioSeconds))
    }

    static func formattedTimeSaved(_ seconds: Double) -> String {
        let parts = gaugeTimeSaved(seconds)
        if parts.unit == "hr" {
            let total = max(0, Int(seconds.rounded()))
            let minutes = (total % 3_600) / 60
            return minutes > 0 ? "\(parts.value)h \(minutes)m" : "\(parts.value)h 0m"
        }
        if parts.unit == "sec" {
            return "\(parts.value) sec"
        }
        return "\(parts.value) min"
    }

    /// Large gauge center: one number plus a short unit (`min` / `hr` / `sec`).
    static func gaugeTimeSaved(_ seconds: Double) -> (value: String, unit: String) {
        let total = max(0, Int(seconds.rounded()))
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        if hours > 0 {
            return ("\(hours)", "hr")
        }
        if minutes > 0 {
            return ("\(minutes)", "min")
        }
        if total > 0 {
            return ("\(total)", "sec")
        }
        return ("0", "min")
    }

    /// Fraction of typing time saved. `1` means hold time was ~0 versus 40 WPM typing.
    static func typingSavedFraction(words: Int, audioSeconds: Double) -> Double {
        let typingSeconds = (Double(max(0, words)) / typingWPM) * 60
        guard typingSeconds > 0 else { return 0 }
        let saved = timeSavedSeconds(words: words, audioSeconds: audioSeconds)
        return min(1, max(0, saved / typingSeconds))
    }

    static func formattedHoldMinutes(_ audioSeconds: Double) -> String {
        let clamped = max(0, audioSeconds)
        let minutes = Int((clamped / 60.0).rounded())
        if minutes == 0 && clamped > 0 { return "<1 min" }
        return "\(minutes) min"
    }

    static func estimatedAudioSeconds(words: Int, averageWPM: Int) -> Double {
        guard words > 0, averageWPM > 0 else { return 0 }
        return Double(words) / Double(averageWPM) * 60.0
    }

    /// Percent change, or `nil` when both values are zero. Previous `0` with a positive current is `nil` (callers show "New").
    static func percentDelta(current: Double, previous: Double) -> Int? {
        if previous == 0 && current == 0 { return nil }
        if previous == 0 { return nil }
        return Int(((current - previous) / previous * 100.0).rounded())
    }

    /// Monday 00:00 of the week containing `date` (Mon–Sun Home week).
    static func startOfMondayWeek(for date: Date, calendar: Calendar = .current) -> Date {
        let day = calendar.startOfDay(for: date)
        let weekday = calendar.component(.weekday, from: day)
        let daysFromMonday = (weekday + 5) % 7
        return calendar.date(byAdding: .day, value: -daysFromMonday, to: day) ?? day
    }

    /// Inclusive Mon–today count in the current Monday week (1 on Monday, 7 on Sunday).
    static func weekToDateDayCount(now: Date = Date(), calendar: Calendar = .current) -> Int {
        let thisStart = startOfMondayWeek(for: now, calendar: calendar)
        let today = calendar.startOfDay(for: now)
        let daysFromMonday = calendar.dateComponents([.day], from: thisStart, to: today).day ?? 0
        return min(7, max(1, daysFromMonday + 1))
    }

    /// Mid-week uses matched weekdays; Sunday is a full Mon–Sun vs last Mon–Sun.
    /// Percent stays beside this caption; do not interpolate the prior-week word count.
    static func weekComparisonCaption(now: Date = Date(), calendar: Calendar = .current) -> String {
        weekToDateDayCount(now: now, calendar: calendar) >= 7 ? "Last week" : "Same time last week"
    }

    static func weekWords(
        days: [HomeActivityDay],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> (thisWeek: Int, lastWeek: Int) {
        let totals = weekTotals(days: days, now: now, calendar: calendar)
        return (totals.thisWeek.words, totals.lastWeek.words)
    }

    static func weekTimeSaved(
        days: [HomeActivityDay],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> (thisWeek: Double, lastWeek: Double) {
        let totals = weekTotals(days: days, now: now, calendar: calendar)
        return (
            timeSavedSeconds(words: totals.thisWeek.words, audioSeconds: totals.thisWeek.audioSeconds),
            timeSavedSeconds(words: totals.lastWeek.words, audioSeconds: totals.lastWeek.audioSeconds)
        )
    }

    /// This week so far vs the same weekdays last week (Mon–Tue vs last Mon–Tue).
    /// Sunday compares the full Mon–Sun week to the prior Mon–Sun week.
    static func weekTotals(
        days: [HomeActivityDay],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> (thisWeek: (words: Int, audioSeconds: Double), lastWeek: (words: Int, audioSeconds: Double)) {
        let thisStart = startOfMondayWeek(for: now, calendar: calendar)
        let elapsedDays = weekToDateDayCount(now: now, calendar: calendar)
        guard let lastStart = calendar.date(byAdding: .day, value: -7, to: thisStart),
              let thisEnd = calendar.date(byAdding: .day, value: elapsedDays, to: thisStart),
              let lastEnd = calendar.date(byAdding: .day, value: elapsedDays, to: lastStart) else {
            return ((0, 0), (0, 0))
        }
        let formatter = dayFormatter(timeZone: calendar.timeZone)
        var thisWords = 0
        var thisAudio = 0.0
        var lastWords = 0
        var lastAudio = 0.0
        for day in days {
            guard let date = formatter.date(from: day.dayKey) else { continue }
            // DateInterval is closed on the end, so compare half-open [start, end).
            if date >= thisStart && date < thisEnd {
                thisWords += day.words
                thisAudio += day.audioSeconds
            } else if date >= lastStart && date < lastEnd {
                lastWords += day.words
                lastAudio += day.audioSeconds
            }
        }
        return ((thisWords, thisAudio), (lastWords, lastAudio))
    }

    /// Word counts for the current Mon–Sun week, oldest (Mon) first.
    static func calendarWeekWordCounts(
        days: [HomeActivityDay],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [Int] {
        let monday = startOfMondayWeek(for: now, calendar: calendar)
        let formatter = dayFormatter(timeZone: calendar.timeZone)
        let byDay = Dictionary(uniqueKeysWithValues: days.map { ($0.dayKey, $0.words) })
        return (0..<7).map { offset in
            guard let date = calendar.date(byAdding: .day, value: offset, to: monday) else { return 0 }
            return byDay[formatter.string(from: date)] ?? 0
        }
    }

    static let mondayWeekdayLabels = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]

    /// Compact one-line Y-axis labels. Never uses grouping commas, so "1000" cannot wrap to "1,00" / "0".
    static func formattedAxisTick(_ value: Int) -> String {
        guard value >= 1000 else { return String(value) }
        let thousands = Double(value) / 1000.0
        let tenths = (thousands * 10).rounded() / 10
        if abs(tenths - tenths.rounded()) < 1e-9 {
            return "\(Int(tenths.rounded()))k"
        }
        return String(format: "%.1fk", tenths)
    }

    /// Zero, mid, and max ticks for faint chart hairlines. Keeps the full Y-axis labels.
    static func gridTicks(from ticks: [Int]) -> [Int] {
        guard ticks.count >= 3 else { return ticks }
        return [ticks[0], ticks[ticks.count / 2], ticks[ticks.count - 1]]
    }

    /// Light Y-axis ticks scaled to `peak` (never a hardcoded 0–60 unless the data needs it).
    static func axisTicks(peak: Int, tickCount: Int = 5) -> [Int] {
        let count = max(2, tickCount)
        guard peak > 0 else {
            return (0..<count).map { $0 }
        }
        let rawStep = Double(peak) / Double(count - 1)
        var step = niceCeil(rawStep)
        while step * (count - 1) < peak {
            step = niceCeil(Double(step) + Double(step) / 2)
        }
        return (0..<count).map { $0 * step }
    }

    private static func niceCeil(_ value: Double) -> Int {
        guard value > 0 else { return 1 }
        let exponent = floor(log10(value))
        let magnitude = pow(10.0, exponent)
        let residual = value / magnitude
        let nice: Double
        if residual <= 1 {
            nice = 1
        } else if residual <= 1.5 {
            nice = 1.5
        } else if residual <= 2 {
            nice = 2
        } else if residual <= 2.5 {
            nice = 2.5
        } else if residual <= 5 {
            nice = 5
        } else {
            nice = 10
        }
        return max(1, Int(ceil(nice * magnitude - 1e-9)))
    }

    static func trendWordCounts(
        days: [HomeActivityDay],
        now: Date = Date(),
        calendar: Calendar = .current,
        window: Int = 7
    ) -> [Int] {
        let formatter = dayFormatter(timeZone: calendar.timeZone)
        let today = calendar.startOfDay(for: now)
        let byDay = Dictionary(uniqueKeysWithValues: days.map { ($0.dayKey, $0.words) })
        return (0..<window).map { offset in
            let daysAgo = window - 1 - offset
            guard let date = calendar.date(byAdding: .day, value: -daysAgo, to: today) else { return 0 }
            return byDay[formatter.string(from: date)] ?? 0
        }
    }

    /// Home Top apps row count. Short ranked list; the Apps hub keeps everyone.
    static let homeTopAppCount = 3

    /// Union of cloud, persisted local, and history. Never drop an app because a later
    /// payload was shorter. Home prefixes `homeTopAppCount`; the Apps page passes no limit.
    static func dictationApps(
        preferCloud: Bool,
        cloudApps: [(appName: String, bundleID: String?, words: Int, audioSeconds: Double?)]?,
        localApps: [HomeAppStat] = [],
        history: [(appName: String, bundleID: String?, finalText: String, audioDuration: TimeInterval)],
        averageWPM: Int,
        limit: Int? = nil
    ) -> [HomeAppStat] {
        var groups: [[HomeAppStat]] = [topApps(history: history, limit: Int.max), localApps]
        if preferCloud, let cloudApps, !cloudApps.isEmpty {
            groups.append(cloudApps.map { app in
                let reported = app.audioSeconds ?? 0
                let audio = reported > 0
                    ? reported
                    : estimatedAudioSeconds(words: app.words, averageWPM: averageWPM)
                return HomeAppStat(
                    appName: app.appName,
                    bundleID: app.bundleID,
                    words: app.words,
                    audioSeconds: audio
                )
            })
        }
        let merged = mergeAppStats(groups)
        guard let limit else { return merged }
        return Array(merged.prefix(limit))
    }

    /// High-water merge by bundle, then name. Summing would double-count the same Mac.
    static func mergeAppStats(_ groups: [[HomeAppStat]]) -> [HomeAppStat] {
        var byKey: [String: HomeAppStat] = [:]
        for app in groups.joined() {
            let key = app.id
            guard !key.isEmpty, key != "n:" else { continue }
            guard let existing = byKey[key] else {
                byKey[key] = app
                continue
            }
            let incomingBundle = app.bundleID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            byKey[key] = HomeAppStat(
                appName: app.appName.count >= existing.appName.count ? app.appName : existing.appName,
                bundleID: incomingBundle.isEmpty ? existing.bundleID : app.bundleID,
                words: max(existing.words, app.words),
                audioSeconds: max(existing.audioSeconds, app.audioSeconds)
            )
        }
        return byKey.values.sorted {
            if $0.words != $1.words { return $0.words > $1.words }
            return $0.appName.localizedCaseInsensitiveCompare($1.appName) == .orderedAscending
        }
    }

    static func meterFraction(for app: HomeAppStat, among apps: [HomeAppStat]) -> Double {
        let peak = max(apps.map(\.audioSeconds).max() ?? 0, 1)
        return max(0, min(1, app.audioSeconds / peak))
    }

    static func topApps(
        history: [(appName: String, bundleID: String?, finalText: String, audioDuration: TimeInterval)],
        limit: Int = 2
    ) -> [HomeAppStat] {
        var byKey: [String: HomeAppStat] = [:]
        for item in history {
            let name = item.appName.trimmingCharacters(in: .whitespacesAndNewlines)
            let bundle = item.bundleID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let key = bundle.isEmpty ? "n:\(name.lowercased())" : "b:\(bundle.lowercased())"
            let words = wordCount(in: item.finalText)
            let existing = byKey[key]
            byKey[key] = HomeAppStat(
                appName: name.isEmpty ? (existing?.appName ?? "Unknown") : name,
                bundleID: bundle.isEmpty ? existing?.bundleID : bundle,
                words: (existing?.words ?? 0) + words,
                audioSeconds: (existing?.audioSeconds ?? 0) + max(0, item.audioDuration)
            )
        }
        return byKey.values.sorted { $0.words > $1.words }.prefix(limit).map { $0 }
    }

    /// Grid offsets in a trailing window: `window - 1` is today, `0` is oldest.
    static func recentUsageOffsets(
        days: [HomeActivityDay],
        now: Date = Date(),
        calendar: Calendar = .current,
        window: Int = 28
    ) -> Set<Int> {
        let formatter = dayFormatter(timeZone: calendar.timeZone)
        let today = calendar.startOfDay(for: now)
        var offsets: Set<Int> = []
        for day in days {
            guard let timestamp = formatter.date(from: day.dayKey) else { continue }
            let dayStart = calendar.startOfDay(for: timestamp)
            guard let diff = calendar.dateComponents([.day], from: dayStart, to: today).day,
                  diff >= 0,
                  diff < window else { continue }
            offsets.insert(window - 1 - diff)
        }
        return offsets
    }

    private static func utcInstant(fromDayKey key: String, hour: Int) -> Date? {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        guard let midnight = formatter.date(from: key) else { return nil }
        return midnight.addingTimeInterval(TimeInterval(hour * 3_600))
    }

    private static func summing(_ a: HomeActivityDay, _ b: HomeActivityDay) -> HomeActivityDay {
        HomeActivityDay(
            dayKey: a.dayKey,
            words: a.words + b.words,
            audioSeconds: a.audioSeconds + b.audioSeconds,
            dictations: a.dictations + b.dictations
        )
    }

    private static func maximizing(_ a: HomeActivityDay, _ b: HomeActivityDay) -> HomeActivityDay {
        HomeActivityDay(
            dayKey: a.dayKey,
            words: max(a.words, b.words),
            audioSeconds: max(a.audioSeconds, b.audioSeconds),
            dictations: max(a.dictations, b.dictations)
        )
    }
}
