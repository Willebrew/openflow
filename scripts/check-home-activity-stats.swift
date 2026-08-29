import Foundation

@main
struct CheckHomeActivityStats {
    static func main() {
        var mountain = Calendar(identifier: .gregorian)
        mountain.timeZone = TimeZone(secondsFromGMT: -6 * 3600)!
        mountain.locale = Locale(identifier: "en_US_POSIX")
        mountain.firstWeekday = 1

        // 2026-08-16 10:11 MDT — same scenario that zeroed Home streak with UTC day keys.
        let now = date(2026, 8, 16, 10, 11, calendar: mountain)
        let morning = date(2026, 8, 16, 9, 0, calendar: mountain)
        let yesterday = date(2026, 8, 15, 14, 0, calendar: mountain)
        let twoDaysAgo = date(2026, 8, 14, 11, 0, calendar: mountain)

        let days = HomeActivityStats.aggregate(
            history: [
                (timestamp: morning, finalText: "hello world today", audioDuration: 12),
                (timestamp: yesterday, finalText: "yesterday words here", audioDuration: 20),
                (timestamp: twoDaysAgo, finalText: "older dictation text", audioDuration: 15),
            ],
            cloudDays: [],
            timeZone: mountain.timeZone
        )

        let streak = HomeActivityStats.consecutiveStreak(days: days, now: now, calendar: mountain)
        assertEqual(streak, 3, "MDT morning dictation should count toward today's streak")

        // Reproduce the pre-fix bug: UTC day keys compared via local startOfDay.
        let utcFormatter = DateFormatter()
        utcFormatter.calendar = Calendar(identifier: .gregorian)
        utcFormatter.locale = Locale(identifier: "en_US_POSIX")
        utcFormatter.timeZone = TimeZone(secondsFromGMT: 0)
        utcFormatter.dateFormat = "yyyy-MM-dd"
        let utcKeyedDays = [
            HomeActivityDay(dayKey: utcFormatter.string(from: morning), words: 3, audioSeconds: 12, dictations: 1),
            HomeActivityDay(dayKey: utcFormatter.string(from: yesterday), words: 3, audioSeconds: 20, dictations: 1),
            HomeActivityDay(dayKey: utcFormatter.string(from: twoDaysAgo), words: 3, audioSeconds: 15, dictations: 1),
        ]
        let brokenUTCStreak = legacyUTCStreak(days: utcKeyedDays, now: now, calendar: mountain)
        assertEqual(brokenUTCStreak, 0, "legacy UTC parse path still demonstrates the bug")

        let words = HomeActivityStats.totalWords(days: days)
        assertEqual(words, 9, "total words from local history")
        assertEqual(
            HomeActivityStats.lifetimeWords(days: days, cloudLifetime: 40, localLifetime: 12),
            40,
            "lifetime must keep the largest of merged days, cloud, and local"
        )
        assertEqual(
            HomeActivityStats.lifetimeWords(days: days, cloudLifetime: 4, localLifetime: 3),
            9,
            "a smaller cloud lifetime must not replace a larger merged-day total"
        )
        assertEqual(
            HomeActivityStats.wordCount(in: "hello   world\nthere"),
            3,
            "word count splits on any whitespace"
        )

        let wpm = HomeActivityStats.averageWPM(days: days)
        assertTrue(wpm > 0, "average WPM should be positive when audio exists")
        assertEqual(
            HomeActivityStats.averageWPM(words: 100, audioSeconds: 50),
            120,
            "lifetime WPM is words divided by recording seconds"
        )
        assertEqual(
            HomeActivityStats.averageWPM(words: 100, audioSeconds: 0),
            0,
            "lifetime WPM is zero without recording time"
        )

        let offsets = HomeActivityStats.recentUsageOffsets(days: days, now: now, calendar: mountain)
        assertTrue(offsets.contains(27), "today should appear at the end of the 28-day grid")
        assertTrue(offsets.contains(26), "yesterday should appear")
        assertTrue(offsets.contains(25), "two days ago should appear")

        let todayKey = HomeActivityStats.dayFormatter(timeZone: mountain.timeZone).string(from: now)
        let withoutToday = days.filter { $0.dayKey != todayKey }
        let liveStreak = HomeActivityStats.consecutiveStreak(days: withoutToday, now: now, calendar: mountain)
        assertEqual(liveStreak, 2, "yesterday still counts until the local day ends")

        let twoDaysAgoOnly = days.filter { $0.dayKey == HomeActivityStats.dayFormatter(timeZone: mountain.timeZone).string(from: twoDaysAgo) }
        let expiredStreak = HomeActivityStats.consecutiveStreak(days: twoDaysAgoOnly, now: now, calendar: mountain)
        assertEqual(expiredStreak, 0, "a gap of more than one local day resets the streak")

        let todayAndGap = days.filter { $0.dayKey == todayKey || $0.dayKey == HomeActivityStats.dayFormatter(timeZone: mountain.timeZone).string(from: twoDaysAgo) }
        let todayOnlyStreak = HomeActivityStats.consecutiveStreak(days: todayAndGap, now: now, calendar: mountain)
        assertEqual(todayOnlyStreak, 1, "a missing yesterday breaks consecutive days")

        let overlapping = HomeActivityStats.aggregate(
            history: [
                (timestamp: morning, finalText: "hello world today", audioDuration: 12),
            ],
            cloudDays: [
                HomeActivityDay(dayKey: utcFormatter.string(from: morning), words: 3, audioSeconds: 12, dictations: 1),
            ],
            timeZone: mountain.timeZone
        )
        assertEqual(overlapping.count, 1, "overlapping local+cloud morning should be one local day")
        assertEqual(overlapping[0].dayKey, todayKey, "UTC cloud morning key should land on local today")
        assertEqual(overlapping[0].words, 3, "overlapping days must max, not sum twice")
        assertEqual(
            HomeActivityStats.consecutiveStreak(days: overlapping, now: now, calendar: mountain),
            1,
            "west-of-UTC morning cloud key must count as today"
        )

        let richerCloud = HomeActivityStats.aggregate(
            history: [
                (timestamp: morning, finalText: "hello world today", audioDuration: 12),
            ],
            cloudDays: [
                HomeActivityDay(dayKey: utcFormatter.string(from: morning), words: 10, audioSeconds: 40, dictations: 2),
            ],
            timeZone: mountain.timeZone
        )
        assertEqual(richerCloud[0].words, 10, "cloud can raise the per-day max without adding a second day")

        let evening = date(2026, 8, 16, 22, 0, calendar: mountain)
        let eveningUTCKey = utcFormatter.string(from: evening)
        assertEqual(eveningUTCKey, "2026-08-17", "10pm MDT is the next UTC date")
        let eveningMerged = HomeActivityStats.aggregate(
            history: [
                (timestamp: evening, finalText: "ten pm dictation here", audioDuration: 18),
            ],
            cloudDays: [
                HomeActivityDay(dayKey: eveningUTCKey, words: 4, audioSeconds: 18, dictations: 1),
            ],
            timeZone: mountain.timeZone
        )
        assertEqual(eveningMerged.count, 1, "evening UTC split must not create two local days")
        assertEqual(eveningMerged[0].dayKey, todayKey, "UTC next-day cloud key folds onto local evening")
        assertEqual(eveningMerged[0].words, 4, "evening overlap must max, not sum local+cloud")

        let cloudOnlyMorning = HomeActivityStats.aggregate(
            history: [],
            cloudDays: [
                HomeActivityDay(dayKey: utcFormatter.string(from: morning), words: 5, audioSeconds: 10, dictations: 1),
            ],
            timeZone: mountain.timeZone
        )
        assertEqual(cloudOnlyMorning.count, 1, "cloud-only morning should keep one day")
        assertEqual(cloudOnlyMorning[0].dayKey, todayKey, "do not shift cloud-only morning onto yesterday via UTC midnight")
        assertEqual(
            HomeActivityStats.consecutiveStreak(days: cloudOnlyMorning, now: now, calendar: mountain),
            1,
            "cloud-only UTC morning still counts as today's local streak"
        )

        let foldedUTCBuckets = HomeActivityStats.aggregate(
            history: [
                (timestamp: evening, finalText: "ten pm dictation here", audioDuration: 18),
            ],
            cloudDays: [
                HomeActivityDay(dayKey: utcFormatter.string(from: morning), words: 3, audioSeconds: 12, dictations: 1),
                HomeActivityDay(dayKey: eveningUTCKey, words: 4, audioSeconds: 18, dictations: 1),
            ],
            timeZone: mountain.timeZone
        )
        assertEqual(foldedUTCBuckets.count, 1, "morning+evening UTC buckets should fold onto one local day")
        assertEqual(foldedUTCBuckets[0].words, 7, "distinct UTC buckets on one local day sum, then max with local")

        assertEqual(
            HomeActivityStats.timeSavedSeconds(words: 6_000, audioSeconds: 0),
            9_000,
            "6,000 lifetime words is 150 minutes at 40 WPM, not a stored 50-minute gauge"
        )
        assertEqual(
            HomeActivityStats.formattedTimeSaved(3_660),
            "1h 1m",
            "time saved formats hours and minutes"
        )

        let week = HomeActivityStats.weekWords(days: days, now: now, calendar: mountain)
        assertEqual(week.thisWeek, 9, "Mon–Sun week includes Friday through Sunday")
        assertEqual(week.lastWeek, 0, "prior Mon–Sun week is empty in this fixture")

        let priorMonday = date(2026, 8, 3, 9, 0, calendar: mountain)
        let daysWithLastWeek = HomeActivityStats.aggregate(
            history: [
                (timestamp: morning, finalText: "hello world today", audioDuration: 12),
                (timestamp: yesterday, finalText: "yesterday words here", audioDuration: 20),
                (timestamp: twoDaysAgo, finalText: "older dictation text", audioDuration: 15),
                (timestamp: priorMonday, finalText: "last week only here", audioDuration: 30),
            ],
            cloudDays: [],
            timeZone: mountain.timeZone
        )
        let weekWithPrior = HomeActivityStats.weekWords(days: daysWithLastWeek, now: now, calendar: mountain)
        assertEqual(weekWithPrior.lastWeek, 4, "prior Monday counts as last week")
        let savedFixture = [
            HomeActivityDay(dayKey: "2026-08-16", words: 40, audioSeconds: 0, dictations: 1),
            HomeActivityDay(dayKey: "2026-08-03", words: 40, audioSeconds: 30, dictations: 1),
        ]
        let saved = HomeActivityStats.weekTimeSaved(days: savedFixture, now: now, calendar: mountain)
        assertEqual(saved.thisWeek, 60.0, "this week time-saved uses Monday–Sunday words and audio")
        assertEqual(saved.lastWeek, 30.0, "last week time-saved uses the prior Monday–Sunday")
        assertEqual(
            HomeActivityStats.weekComparisonCaption(now: now, calendar: mountain),
            "Last week",
            "Sunday compares the full week and keeps the Last week label"
        )
        assertEqual(HomeActivityStats.weekToDateDayCount(now: now, calendar: mountain), 7, "Sunday is seven WTD days")

        // Tuesday Aug 25 2026: Mon–Tue this week vs Mon–Tue last week, not the full last week.
        let tuesday = date(2026, 8, 25, 13, 47, calendar: mountain)
        assertEqual(HomeActivityStats.weekToDateDayCount(now: tuesday, calendar: mountain), 2, "Tuesday is two WTD days")
        assertEqual(
            HomeActivityStats.weekComparisonCaption(now: tuesday, calendar: mountain),
            "Same time last week",
            "mid-week labels the matched weekday window"
        )
        let midWeekDays = [
            HomeActivityDay(dayKey: "2026-08-24", words: 1_000, audioSeconds: 0, dictations: 1),
            HomeActivityDay(dayKey: "2026-08-25", words: 359, audioSeconds: 0, dictations: 1),
            HomeActivityDay(dayKey: "2026-08-17", words: 400, audioSeconds: 0, dictations: 1),
            HomeActivityDay(dayKey: "2026-08-18", words: 200, audioSeconds: 0, dictations: 1),
            HomeActivityDay(dayKey: "2026-08-19", words: 4_691, audioSeconds: 0, dictations: 1),
        ]
        let midWeek = HomeActivityStats.weekWords(days: midWeekDays, now: tuesday, calendar: mountain)
        assertEqual(midWeek.thisWeek, 1_359, "this week is Monday plus Tuesday only")
        assertEqual(midWeek.lastWeek, 600, "last week for percent is last Monday plus Tuesday, not Wed–Sun")
        assertEqual(
            HomeActivityStats.percentDelta(current: Double(midWeek.thisWeek), previous: Double(midWeek.lastWeek)),
            126,
            "percent uses matched weekdays, not WTD vs a full last week"
        )
        let midWeekSaved = HomeActivityStats.weekTimeSaved(days: midWeekDays, now: tuesday, calendar: mountain)
        assertEqual(midWeekSaved.thisWeek, 2_038.5, "time saved this week uses Mon–Tue words at 40 WPM")
        assertEqual(midWeekSaved.lastWeek, 900.0, "time saved last week uses last Mon–Tue, not the rest of last week")
        assertEqual(
            HomeActivityStats.percentDelta(current: midWeekSaved.thisWeek, previous: midWeekSaved.lastWeek),
            126,
            "time-saved percent is WTD vs same weekdays last week"
        )

        let mondayMorning = date(2026, 8, 24, 9, 0, calendar: mountain)
        let emptyPriorMonday = [
            HomeActivityDay(dayKey: "2026-08-24", words: 40, audioSeconds: 0, dictations: 1),
            HomeActivityDay(dayKey: "2026-08-18", words: 400, audioSeconds: 0, dictations: 1),
        ]
        let mondayWords = HomeActivityStats.weekWords(days: emptyPriorMonday, now: mondayMorning, calendar: mountain)
        assertEqual(mondayWords.thisWeek, 40, "Monday WTD is Monday only")
        assertEqual(mondayWords.lastWeek, 0, "last Tuesday must not count on Monday")
        assertTrue(
            HomeActivityStats.percentDelta(current: Double(mondayWords.thisWeek), previous: Double(mondayWords.lastWeek)) == nil,
            "zero last-week same days is New, not a fake drop"
        )

        let trend = HomeActivityStats.trendWordCounts(days: days, now: now, calendar: mountain, window: 4)
        assertEqual(trend, [0, 3, 3, 3], "trend is oldest-to-newest word counts")

        let mondayWeek = HomeActivityStats.calendarWeekWordCounts(days: days, now: now, calendar: mountain)
        assertEqual(mondayWeek.count, 7, "Home week chart is seven days")
        assertEqual(mondayWeek, [0, 0, 0, 0, 3, 3, 3], "Mon–Sun chart is Monday-first")

        let apps = HomeActivityStats.topApps(
            history: [
                (appName: "Cursor", bundleID: "com.cursor", finalText: "one two three", audioDuration: 90),
                (appName: "Slack", bundleID: "com.slack", finalText: "hi", audioDuration: 10),
                (appName: "Cursor", bundleID: "com.cursor", finalText: "four five", audioDuration: 30),
            ]
        )
        assertEqual(apps.count, 2, "top apps collapse by bundle")
        assertEqual(apps[0].appName, "Cursor", "highest word app is first")
        assertEqual(apps[0].words, 5, "Cursor words sum across clips")
        assertEqual(apps[0].audioSeconds, 120.0, "Cursor hold seconds sum across clips")
        assertEqual(HomeActivityStats.formattedHoldMinutes(120), "2 min", "hold minutes come from audio seconds")

        let defaultTrend = HomeActivityStats.trendWordCounts(days: days, now: now, calendar: mountain)
        assertEqual(defaultTrend.count, 7, "rolling trend stays seven days")

        let cappedApps = HomeActivityStats.topApps(
            history: [
                (appName: "A", bundleID: "a", finalText: "one two three four", audioDuration: 40),
                (appName: "B", bundleID: "b", finalText: "one two three", audioDuration: 30),
                (appName: "C", bundleID: "c", finalText: "one two", audioDuration: 20),
                (appName: "D", bundleID: "d", finalText: "one", audioDuration: 10),
            ]
        )
        assertEqual(cappedApps.count, 2, "topApps helper still defaults to two")
        assertEqual(cappedApps[0].appName, "A", "highest word app is first among the compact list")
        assertEqual(HomeActivityStats.homeTopAppCount, 3, "Home Top apps shows three rows so a new app does not instantly evict Mail")

        let cloudApps = HomeActivityStats.dictationApps(
            preferCloud: true,
            cloudApps: [
                (appName: "Cursor", bundleID: "com.cursor", words: 12, audioSeconds: 120),
                (appName: "Slack", bundleID: "com.slack", words: 8, audioSeconds: 60),
                (appName: "Mail", bundleID: "com.apple.mail", words: 4, audioSeconds: 30),
            ],
            history: [
                (appName: "Local", bundleID: "local", finalText: "one two", audioDuration: 10),
            ],
            averageWPM: 120
        )
        assertEqual(cloudApps.count, 4, "Apps page unions cloud with local instead of replacing")
        assertEqual(cloudApps[0].appName, "Cursor", "highest word app is first")
        assertTrue(cloudApps.contains { $0.appName == "Local" }, "local-only apps stay after cloud stats arrive")
        assertEqual(
            HomeActivityStats.meterFraction(for: cloudApps.first { $0.appName == "Mail" }!, among: cloudApps),
            0.25,
            "usage bars are relative to the longest hold"
        )

        let mailThenXcodeCloudOnly = HomeActivityStats.dictationApps(
            preferCloud: true,
            cloudApps: [
                (appName: "Xcode", bundleID: "com.apple.dt.Xcode", words: 20, audioSeconds: 40),
            ],
            localApps: [
                HomeAppStat(appName: "Mail", bundleID: "com.apple.mail", words: 12, audioSeconds: 25),
            ],
            history: [
                (appName: "Mail", bundleID: "com.apple.mail", finalText: "hello from mail here", audioDuration: 25),
            ],
            averageWPM: 120
        )
        assertEqual(mailThenXcodeCloudOnly.count, 2, "Mail must remain after an Xcode clip even if GET only returns Xcode")
        assertEqual(mailThenXcodeCloudOnly[0].appName, "Xcode", "Xcode ranks first with more words")
        assertEqual(mailThenXcodeCloudOnly[1].appName, "Mail", "Mail stays on the full Apps list")
        let homeSlice = Array(mailThenXcodeCloudOnly.prefix(HomeActivityStats.homeTopAppCount))
        assertTrue(homeSlice.contains { $0.appName == "Mail" }, "with two apps, Home still shows Mail next to Xcode")

        let truncatedCloud = HomeActivityStats.mergeAppStats([
            [
                HomeAppStat(appName: "Mail", bundleID: "com.apple.mail", words: 8, audioSeconds: 20),
                HomeAppStat(appName: "Notes", bundleID: "com.apple.notes", words: 6, audioSeconds: 15),
            ],
            [
                HomeAppStat(appName: "Xcode", bundleID: "com.apple.dt.Xcode", words: 30, audioSeconds: 50),
            ],
        ])
        assertEqual(truncatedCloud.count, 3, "a shorter later payload must union, not replace")
        assertTrue(truncatedCloud.contains { $0.appName == "Mail" }, "Mail survives a shorter cloud list")
        assertTrue(truncatedCloud.contains { $0.appName == "Xcode" }, "Xcode is added without dropping others")

        let estimatedCloud = HomeActivityStats.dictationApps(
            preferCloud: true,
            cloudApps: [
                (appName: "Notes", bundleID: "com.apple.notes", words: 120, audioSeconds: 0),
            ],
            history: [],
            averageWPM: 120
        )
        assertEqual(estimatedCloud[0].audioSeconds, 60.0, "zero cloud audio falls back to WPM estimate")

        let localApps = HomeActivityStats.dictationApps(
            preferCloud: false,
            cloudApps: cloudApps.map { (appName: $0.appName, bundleID: $0.bundleID, words: $0.words, audioSeconds: $0.audioSeconds) },
            history: [
                (appName: "A", bundleID: "a", finalText: "one two three four", audioDuration: 40),
                (appName: "B", bundleID: "b", finalText: "one two three", audioDuration: 30),
                (appName: "C", bundleID: "c", finalText: "one two", audioDuration: 20),
                (appName: "D", bundleID: "d", finalText: "one", audioDuration: 10),
            ],
            averageWPM: 100
        )
        assertEqual(localApps.count, 4, "signed-out Apps page lists every local app")
        let homeThree = HomeActivityStats.dictationApps(
            preferCloud: false,
            cloudApps: nil,
            history: [
                (appName: "A", bundleID: "a", finalText: "one two three four", audioDuration: 40),
                (appName: "B", bundleID: "b", finalText: "one two three", audioDuration: 30),
                (appName: "C", bundleID: "c", finalText: "one two", audioDuration: 20),
                (appName: "D", bundleID: "d", finalText: "one", audioDuration: 10),
            ],
            averageWPM: 100,
            limit: HomeActivityStats.homeTopAppCount
        )
        assertEqual(homeThree.count, 3, "Home prefixes three ranked apps")
        assertEqual(homeThree.map(\.appName), ["A", "B", "C"], "Home ranking stays by words")
        assertTrue(!homeThree.contains { $0.appName == "D" }, "fourth app is only on View all")

        assertEqual(HomeActivityStats.axisTicks(peak: 50), [0, 15, 30, 45, 60], "Y-axis scales to data instead of a hardcoded 0–60")
        assertEqual(HomeActivityStats.axisTicks(peak: 7), [0, 2, 4, 6, 8], "small peaks get a tight Y-axis")
        assertEqual(
            HomeActivityStats.gridTicks(from: [0, 15, 30, 45, 60]),
            [0, 30, 60],
            "chart hairlines are zero, mid, and max, not a full vertical grid"
        )
        assertEqual(
            HomeActivityStats.gridTicks(from: [0, 8]),
            [0, 8],
            "short axes keep both endpoints"
        )
        assertEqual(HomeActivityStats.formattedAxisTick(0), "0", "zero stays a single digit")
        assertEqual(HomeActivityStats.formattedAxisTick(250), "250", "sub-thousand ticks stay raw")
        assertEqual(HomeActivityStats.formattedAxisTick(750), "750", "three-digit ticks stay raw")
        assertEqual(HomeActivityStats.formattedAxisTick(1000), "1k", "1000 must be one-line 1k, not 1,000")
        assertEqual(HomeActivityStats.formattedAxisTick(1500), "1.5k", "1500 compact to 1.5k")
        assertEqual(HomeActivityStats.formattedAxisTick(2000), "2k", "even thousands drop the decimal")
        assertEqual(HomeActivityStats.formattedAxisTick(10_000), "10k", "10,000 compact to 10k")
        assertTrue(!HomeActivityStats.formattedAxisTick(1000).contains(","), "axis labels never use grouping commas")
        assertTrue(!HomeActivityStats.formattedAxisTick(1000).contains("\n"), "axis labels stay on one line")
        assertEqual(HomeActivityStats.gaugeTimeSaved(960).value, "16", "gauge shows minutes in the center")
        assertEqual(HomeActivityStats.gaugeTimeSaved(960).unit, "min", "gauge unit is min under an hour")
        assertEqual(HomeActivityStats.percentDelta(current: 2629, previous: 617), 326, "week delta matches the mock percent")
        assertEqual(HomeActivityStats.typingSavedFraction(words: 40, audioSeconds: 0), 1, "full ring when hold time is zero")

        print("home activity stats checks passed")
    }

    /// Old SettingsView path: UTC dayKey → Date → local startOfDay (zeros west-of-UTC streaks).
    private static func legacyUTCStreak(days: [HomeActivityDay], now: Date, calendar: Calendar) -> Int {
        let utcFormatter = DateFormatter()
        utcFormatter.calendar = Calendar(identifier: .gregorian)
        utcFormatter.locale = Locale(identifier: "en_US_POSIX")
        utcFormatter.timeZone = TimeZone(secondsFromGMT: 0)
        utcFormatter.dateFormat = "yyyy-MM-dd"

        let parsed = Set(days.compactMap { utcFormatter.date(from: $0.dayKey) }.map { calendar.startOfDay(for: $0) })
        guard !parsed.isEmpty else { return 0 }
        var streak = 0
        var day = calendar.startOfDay(for: now)
        while parsed.contains(day) {
            streak += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: day) else { break }
            day = previous
        }
        return streak
    }

    private static func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int, calendar: Calendar) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        guard let value = calendar.date(from: components) else {
            fail("could not build date")
        }
        return value
    }

    private static func assertEqual<T: Equatable>(_ actual: T, _ expected: T, _ label: String) {
        guard actual == expected else {
            fail("\(label): expected \(expected), got \(actual)")
        }
    }

    private static func assertTrue(_ condition: Bool, _ label: String) {
        guard condition else { fail(label) }
    }

    private static func fail(_ message: String) -> Never {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}
