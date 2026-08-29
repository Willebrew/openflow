import SwiftUI
import AppKit

struct HomeDashboardView: View {
    @EnvironmentObject private var coordinator: DictationCoordinator
    let cloudSignedIn: Bool
    let onOpenHistory: () -> Void
    let onOpenApps: () -> Void
    let onOpenPlan: () -> Void
    @State private var copiedLatestClip = false

    var body: some View {
        GeometryReader { geo in
            let fit = HomeFit(height: geo.size.height, showingSetup: !isFullySetUp)
            VStack(alignment: .leading, spacing: fit.gap) {
                compactHeader

                if !isFullySetUp {
                    SetupJourneyCard(completedSteps: completedSetupSteps,
                                     microphoneGranted: coordinator.permissions.microphoneGranted,
                                     accessibilityGranted: coordinator.permissions.accessibilityGranted,
                                     hasProvider: hasConfiguredProvider,
                                     requestMicrophone: coordinator.permissions.requestMicrophone,
                                     requestAccessibility: coordinator.permissions.requestAccessibility,
                                     openPlan: onOpenPlan)
                }

                HStack(alignment: .top, spacing: fit.gap) {
                    timeSavedCard(fit: fit)
                    weekCard(fit: fit)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

                HStack(alignment: .top, spacing: fit.gap) {
                    topAppsCard(fit: fit)
                    lastClipCard(fit: fit)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

                if fit.showMore {
                    footerRow
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .preferredColorScheme(.dark)
        .foregroundStyle(FlowUI.ink)
    }

    private var compactHeader: some View {
        FlowCompactPageHeader(
            title: "Home",
            subtitle: coordinator.settings.pushToTalkHotkey.dictationInstruction
        )
    }

    private func timeSavedCard(fit: HomeFit) -> some View {
        HomeStatCard(pad: fit.pad) {
            homeCardTitle("Time saved", symbol: "waveform")
            Text("vs typing")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            HomeTimeGauge(
                progress: typingSavedFraction,
                value: gaugeDisplay.value,
                unit: gaugeDisplay.unit,
                diameter: fit.gauge
            )
            .frame(maxWidth: .infinity)
            Spacer(minLength: 4)
            weekDeltaRow
        }
    }

    private func weekCard(fit: HomeFit) -> some View {
        HomeStatCard(pad: fit.pad) {
            homeCardTitle("This week", symbol: "calendar") {
                Text(weekWords.thisWeek.formatted())
                    .font(.system(size: fit.hero, weight: .bold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            HStack(spacing: 6) {
                Text(HomeActivityStats.weekComparisonCaption())
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                weekWordsDeltaText
                Spacer(minLength: 0)
            }
            Spacer(minLength: 6)
            HomeWeekChart(counts: weekCounts, height: fit.trend)
        }
    }

    private func topAppsCard(fit: HomeFit) -> some View {
        HomeStatCard(pad: fit.pad) {
            homeCardTitle("Top apps", symbol: "square.grid.2x2")
            if topApps.isEmpty {
                Text("Apps you dictate into will show up here.")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer(minLength: 0)
            } else {
                VStack(spacing: 10) {
                    ForEach(topApps) { app in
                        HomeAppUsageRow(app: app, fraction: appMeterFraction(app))
                    }
                }
                Spacer(minLength: 0)
            }
            if allApps.count > topApps.count {
                Button("View all apps →", action: onOpenApps)
                    .buttonStyle(.plain)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(FlowUI.moss)
            }
        }
    }

    private func lastClipCard(fit: HomeFit) -> some View {
        HomeStatCard(pad: fit.pad) {
            homeCardTitle("Last clip", symbol: "doc.on.clipboard")
            if let item = coordinator.history.items.first {
                HStack(alignment: .center, spacing: 10) {
                    AppIconBadge(appName: item.appName, bundleID: item.bundleID, size: 22)
                    Text(item.appName)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .layoutPriority(1)
                    Text(item.timestamp.formatted(date: .omitted, time: .shortened))
                        .font(.system(size: 12, weight: .medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize()
                    Text(item.displayText)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .layoutPriority(-1)
                    Spacer(minLength: 6)
                    copyLatestButton
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(FlowUI.controlFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else {
                Text("Hold \(coordinator.settings.pushToTalkHotkey.keycapLabel) to dictate.")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            Button("View history →", action: onOpenHistory)
                .buttonStyle(.plain)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(FlowUI.moss)
        }
    }

    /// Shared 2x2 title row: moss icon + 14pt title on an 18pt baseline. Trailing
    /// content (This week count) top-aligns so the four titles still line up.
    private func homeCardTitle(_ title: String, symbol: String) -> some View {
        homeCardTitle(title, symbol: symbol) { EmptyView() }
    }

    private func homeCardTitle<Trailing: View>(
        _ title: String,
        symbol: String,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(alignment: .top, spacing: 8) {
            HStack(alignment: .center, spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(FlowUI.moss)
                    .frame(width: 16, height: 16)
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
            }
            .frame(height: 18, alignment: .leading)
            Spacer(minLength: 6)
            trailing()
        }
    }

    private var copyLatestButton: some View {
        Button(action: copyLatestClip) {
            Image(systemName: copiedLatestClip ? "checkmark" : "doc.on.doc")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Color.black.opacity(0.72))
                .frame(width: 28, height: 28)
                .background(FlowUI.moss, in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(latestClipText == nil)
        .accessibilityLabel("Copy latest dictation")
    }

    private var footerRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "bolt.fill")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(FlowUI.moss)
            Text("Words \(totalWords.formatted())")
            Text("·")
                .foregroundStyle(.secondary)
            Text(averageWPM == 0 ? "-- WPM" : "\(averageWPM) WPM")
            Text("·")
                .foregroundStyle(.secondary)
            Text("\(weeklyStreak)d streak")
            Spacer(minLength: 0)
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.secondary)
        .monospacedDigit()
        .padding(.horizontal, 2)
        .padding(.top, 2)
    }

    private var weekDeltaRow: some View {
        let text = weekDeltaCaption
        return HStack(spacing: 4) {
            if !text.isEmpty {
                Image(systemName: weekDeltaIsUp ? "arrow.up" : "arrow.down")
                    .font(.system(size: 10, weight: .bold))
                Text(text)
                    .font(.system(size: 12, weight: .semibold))
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(text.isEmpty ? FlowUI.ink.opacity(0.55) : (weekDeltaIsUp ? FlowUI.moss : FlowUI.coral))
        .opacity(text.isEmpty ? 0 : 1)
    }

    private var weekWordsDeltaText: some View {
        let current = Double(weekWords.thisWeek)
        let previous = Double(weekWords.lastWeek)
        let text: String
        let color: Color
        if previous == 0 && current == 0 {
            text = ""
            color = FlowUI.ink.opacity(0.55)
        } else if previous == 0 {
            text = "New"
            color = FlowUI.moss
        } else if let percent = HomeActivityStats.percentDelta(current: current, previous: previous) {
            text = percent >= 0 ? "+\(percent)%" : "\(percent)%"
            color = percent >= 0 ? FlowUI.moss : FlowUI.coral
        } else {
            text = ""
            color = FlowUI.ink.opacity(0.55)
        }
        return Text(text)
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(color)
            .opacity(text.isEmpty ? 0 : 1)
    }

    private var weekDeltaCaption: String {
        let saved = weekSaved
        if saved.thisWeek > 0 || saved.lastWeek > 0 {
            return deltaPhrase(current: saved.thisWeek, previous: saved.lastWeek)
        }
        let words = weekWords
        if words.thisWeek > 0 || words.lastWeek > 0 {
            return deltaPhrase(current: Double(words.thisWeek), previous: Double(words.lastWeek))
        }
        return ""
    }

    private var weekDeltaIsUp: Bool {
        let saved = weekSaved
        if saved.thisWeek > 0 || saved.lastWeek > 0 {
            return saved.thisWeek >= saved.lastWeek
        }
        return weekWords.thisWeek >= weekWords.lastWeek
    }

    private func appMeterFraction(_ app: HomeAppStat) -> Double {
        HomeActivityStats.meterFraction(for: app, among: topApps)
    }

    private func deltaPhrase(current: Double, previous: Double) -> String {
        if previous == 0 {
            return current > 0 ? "New this week" : ""
        }
        guard let percent = HomeActivityStats.percentDelta(current: current, previous: previous) else {
            return ""
        }
        let signed = percent >= 0 ? "+\(percent)%" : "\(percent)%"
        return "\(signed) this week"
    }

    private var latestClipText: String? {
        guard let text = coordinator.history.items.first?.finalText
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            return nil
        }
        return text
    }

    private func copyLatestClip() {
        guard let text = latestClipText else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copiedLatestClip = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            copiedLatestClip = false
        }
    }

    private var permissionsReady: Bool {
        coordinator.permissions.microphoneGranted
            && coordinator.permissions.accessibilityGranted
    }

    private var hasConfiguredProvider: Bool {
        if coordinator.hasAPIKey() { return true }
        let token = (try? KeychainService.shared.cloudSessionToken()) ?? nil
        return token?.isEmpty == false
    }

    private var completedSetupSteps: Int {
        [coordinator.permissions.microphoneGranted,
         coordinator.permissions.accessibilityGranted,
         hasConfiguredProvider].filter { $0 }.count
    }

    private var isFullySetUp: Bool {
        permissionsReady && hasConfiguredProvider
    }

    private var activityDays: [HomeActivityDay] {
        if cloudSignedIn {
            return HomeActivityStats.aggregate(
                history: [],
                cloudDays: coordinator.cloudStats.days.map {
                    HomeActivityDay(
                        dayKey: $0.dayKey,
                        words: $0.words,
                        audioSeconds: $0.audioSeconds,
                        dictations: $0.dictations
                    )
                }
            )
        }
        return HomeActivityStats.aggregate(
            history: coordinator.history.items.map {
                (timestamp: $0.timestamp, finalText: $0.finalText, audioDuration: $0.metrics.audioDuration)
            },
            cloudDays: []
        )
    }

    private var totalWords: Int {
        if cloudSignedIn {
            return max(coordinator.cloudStats.lifetimeWords, coordinator.history.lifetimeWords)
        }
        return HomeActivityStats.lifetimeWords(
            days: activityDays,
            localLifetime: coordinator.history.lifetimeWords
        )
    }

    private var averageWPM: Int {
        if cloudSignedIn {
            let cloud = coordinator.cloudStats.lifetimeAverageWPM
            if cloud > 0 { return cloud }
        }
        return HomeActivityStats.averageWPM(
            words: coordinator.history.lifetimeWords,
            audioSeconds: coordinator.history.lifetimeAudioSeconds
        )
    }

    private var weeklyStreak: Int {
        HomeActivityStats.consecutiveStreak(days: activityDays)
    }

    private var lifetimeAudioSeconds: Double {
        if cloudSignedIn {
            return max(coordinator.cloudStats.lifetimeAudioSeconds, coordinator.history.lifetimeAudioSeconds)
        }
        return coordinator.history.lifetimeAudioSeconds
    }

    /// Same lifetime words + hold time as the footer, never a never-backfilled stored gauge.
    private var timeSavedSeconds: Double {
        HomeActivityStats.timeSavedSeconds(words: totalWords, audioSeconds: lifetimeAudioSeconds)
    }

    private var typingSavedFraction: Double {
        guard totalWords > 0 else { return 0 }
        return HomeActivityStats.typingSavedFraction(words: totalWords, audioSeconds: lifetimeAudioSeconds)
    }

    private var gaugeDisplay: (value: String, unit: String) {
        HomeActivityStats.gaugeTimeSaved(timeSavedSeconds)
    }

    private var weekWords: (thisWeek: Int, lastWeek: Int) {
        HomeActivityStats.weekWords(days: activityDays)
    }

    private var weekSaved: (thisWeek: Double, lastWeek: Double) {
        HomeActivityStats.weekTimeSaved(days: activityDays)
    }

    private var weekCounts: [Int] {
        HomeActivityStats.calendarWeekWordCounts(days: activityDays)
    }

    private var topApps: [HomeAppStat] {
        Array(allApps.prefix(HomeActivityStats.homeTopAppCount))
    }

    private var allApps: [HomeAppStat] {
        HomeActivityStats.dictationApps(
            preferCloud: cloudSignedIn,
            cloudApps: coordinator.cloudStats.apps?.map {
                (appName: $0.appName, bundleID: $0.bundleID, words: $0.words, audioSeconds: $0.audioSeconds)
            },
            localApps: coordinator.history.appStats,
            history: coordinator.history.items.map {
                (appName: $0.appName, bundleID: $0.bundleID, finalText: $0.finalText, audioDuration: $0.metrics.audioDuration)
            },
            averageWPM: averageWPM
        )
    }
}

private struct HomeFit {
    let gap: CGFloat
    let pad: CGFloat
    let hero: CGFloat
    let trend: CGFloat
    let gauge: CGFloat
    let showMore: Bool

    init(height: CGFloat, showingSetup: Bool) {
        let tight = showingSetup || height < 420
        gap = tight ? 8 : 10
        pad = tight ? 10 : 12
        hero = tight ? 24 : 28
        trend = tight ? 72 : 96
        gauge = tight ? 72 : 108
        showMore = !showingSetup
    }
}

private struct HomeStatCard<Content: View>: View {
    let pad: CGFloat
    let content: Content

    init(pad: CGFloat, @ViewBuilder content: () -> Content) {
        self.pad = pad
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            content
        }
        .padding(pad)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .flowLiquidGlass(cornerRadius: 14)
    }
}

private struct HomeTimeGauge: View {
    let progress: Double
    let value: String
    let unit: String
    let diameter: CGFloat

    var body: some View {
        let clamped = min(1, max(0, progress))
        let line = max(8, diameter * 0.11)
        ZStack {
            Circle()
                .trim(from: 0, to: 0.75)
                .stroke(FlowUI.ink.opacity(0.12), style: StrokeStyle(lineWidth: line, lineCap: .round))
            Circle()
                .trim(from: 0, to: 0.75 * clamped)
                .stroke(FlowUI.moss, style: StrokeStyle(lineWidth: line, lineCap: .round))
            VStack(spacing: 0) {
                Text(value)
                    .font(.system(size: max(22, diameter * 0.30), weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(FlowUI.ink)
                Text(unit)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .rotationEffect(.degrees(135))
        }
        .rotationEffect(.degrees(-135))
        .frame(width: diameter, height: diameter)
        .accessibilityLabel("\(value) \(unit) saved versus typing")
    }
}

struct HomeAppUsageRow: View {
    let app: HomeAppStat
    let fraction: Double

    var body: some View {
        HStack(spacing: 8) {
            AppIconBadge(appName: app.appName, bundleID: app.bundleID, size: 22)
            VStack(alignment: .leading, spacing: 4) {
                Text(app.appName)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                HomeAppMeter(fraction: fraction)
            }
            Text(HomeActivityStats.formattedHoldMinutes(app.audioSeconds))
                .font(.system(size: 12, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

struct HomeAppMeter: View {
    let fraction: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(FlowUI.ink.opacity(0.12))
                Capsule()
                    .fill(FlowUI.moss)
                    .frame(width: max(4, geo.size.width * CGFloat(min(1, max(0, fraction)))))
            }
        }
        .frame(height: 5)
    }
}

struct HomeWeekChart: View {
    let counts: [Int]
    var height: CGFloat = 96
    /// Wide enough for compact ticks like "1k" / "1.2k" on one line; never wrap "1,000".
    private let axisLabelColumnWidth: CGFloat = 36
    /// Weekday row under the plot; keeps the card height unchanged.
    private let weekdayGutter: CGFloat = 14

    var body: some View {
        let peak = counts.max() ?? 0
        let ticks = HomeActivityStats.axisTicks(peak: peak)
        let top = max(ticks.last ?? 1, 1)
        let plotHeight = height - weekdayGutter
        HStack(alignment: .top, spacing: 6) {
            VStack(alignment: .trailing, spacing: 0) {
                ForEach(Array(ticks.reversed().enumerated()), id: \.offset) { index, tick in
                    if index > 0 { Spacer(minLength: 0) }
                    Text(HomeActivityStats.formattedAxisTick(tick))
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(FlowUI.ink.opacity(0.42))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
            }
            .frame(width: axisLabelColumnWidth, height: plotHeight, alignment: .trailing)

            VStack(spacing: 0) {
                ZStack(alignment: .bottom) {
                    HomeWeekChartGrid(ticks: HomeActivityStats.gridTicks(from: ticks), top: top)
                    HStack(alignment: .bottom, spacing: 5) {
                        ForEach(Array(counts.enumerated()), id: \.offset) { _, count in
                            RoundedRectangle(cornerRadius: 3)
                                .fill(count > 0 ? FlowUI.moss.opacity(0.92) : FlowUI.ink.opacity(0.10))
                                .frame(maxWidth: .infinity, minHeight: 3, maxHeight: max(3, CGFloat(count) / CGFloat(top) * plotHeight))
                        }
                    }
                }
                .frame(maxWidth: .infinity, minHeight: plotHeight, maxHeight: plotHeight, alignment: .bottom)

                HStack(spacing: 5) {
                    ForEach(Array(counts.enumerated()), id: \.offset) { index, _ in
                        Text(weekdayLabel(at: index))
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(FlowUI.ink.opacity(0.45))
                            .frame(maxWidth: .infinity)
                    }
                }
                .frame(height: weekdayGutter)
            }
            .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .top)
        }
        .frame(height: height)
        .accessibilityLabel("Words dictated Monday through Sunday")
    }

    private func weekdayLabel(at index: Int) -> String {
        let labels = HomeActivityStats.mondayWeekdayLabels
        guard index >= 0, index < labels.count else { return "" }
        return labels[index]
    }
}

/// Zero / mid / max hairlines sit behind the bars so height is readable on dark glass.
private struct HomeWeekChartGrid: View {
    let ticks: [Int]
    let top: Int
    private let gridLineOpacity: Double = 0.08
    private let gridBaselineOpacity: Double = 0.14

    var body: some View {
        Canvas { context, size in
            let scale = CGFloat(max(top, 1))
            for tick in ticks {
                let fraction = CGFloat(tick) / scale
                let y = min(size.height - 0.25, max(0.25, size.height * (1 - fraction)))
                var path = Path()
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
                let opacity = tick == 0 ? gridBaselineOpacity : gridLineOpacity
                context.stroke(path, with: .color(FlowUI.ink.opacity(opacity)), lineWidth: 0.5)
            }
        }
        .allowsHitTesting(false)
    }
}
