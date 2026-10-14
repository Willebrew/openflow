import SwiftUI

struct AppsView: View {
    @EnvironmentObject private var coordinator: DictationCoordinator
    @EnvironmentObject private var homeStats: HomeStatsStore
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

    /// Reads the shared off-main snapshot. The store's builder keeps the same
    /// merge semantics this list used to compute inline: cloud apps preferred
    /// when signed in, with `localApps: coordinator.history.appStats`-equivalent
    /// persisted data always feeding the merge.
    private var apps: [HomeAppStat] {
        homeStats.snapshot.allApps
    }

    private var averageWPM: Int {
        homeStats.snapshot.averageWPM
    }
}
