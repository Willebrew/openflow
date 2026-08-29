import SwiftUI

struct AppsView: View {
    @EnvironmentObject private var coordinator: DictationCoordinator
    let cloudSignedIn: Bool
    let onBackToHome: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            FlowCompactPageHeader(
                title: "Apps",
                subtitle: "Hold time by app."
            ) {
                FlowCircleIconButton(
                    systemImage: "chevron.left",
                    accessibilityLabel: "Back to Home",
                    help: "Home"
                ) {
                    onBackToHome()
                }
            }

            ScrollView {
                LazyVStack(spacing: 6) {
                    if apps.isEmpty {
                        emptyState
                    } else {
                        ForEach(apps) { app in
                            appRow(app)
                        }
                    }
                }
                .padding(.bottom, 56)
            }
            .flowHubListScroll()
        }
        .preferredColorScheme(.dark)
        .foregroundStyle(FlowUI.ink)
    }

    private var emptyState: some View {
        FlowCompactEmptyState(
            title: "No apps yet",
            subtitle: "Apps you dictate into will show up here.",
            symbol: "square.grid.2x2"
        )
    }

    private func appRow(_ app: HomeAppStat) -> some View {
        HomeAppUsageRow(app: app, fraction: HomeActivityStats.meterFraction(for: app, among: apps))
            .flowInsetRowPadding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(FlowUI.controlFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var apps: [HomeAppStat] {
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
}
