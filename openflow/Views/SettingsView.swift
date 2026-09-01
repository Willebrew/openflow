import SwiftUI
import AppKit

private enum SettingsDetailTab: String, CaseIterable, Identifiable {
    case general
    case permissions
    case provider
    case shortcuts
    case updates
    case diagnostics

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .permissions: "Permissions"
        case .provider: "Subscription"
        case .shortcuts: "Shortcuts"
        case .updates: "Updates"
        case .diagnostics: "Diagnostics"
        }
    }

    var symbol: String {
        switch self {
        case .general: "switch.2"
        case .permissions: "checkmark.shield"
        case .provider: "creditcard.fill"
        case .shortcuts: "keyboard"
        case .updates: "arrow.down.circle"
        case .diagnostics: "speedometer"
        }
    }
}

private enum CloudBillingAction {
    case checkout
    case portal
}

struct SettingsView: View {
    @EnvironmentObject private var coordinator: DictationCoordinator
    @ObservedObject private var updater = UpdateService.shared
    @State private var selectedTab: SettingsTab
    @State private var settingsTab: SettingsDetailTab = .general
    @State private var apiKey = ""
    @State private var cloudStatus = "Not signed in"
    @State private var cloudEntitled = false
    @State private var cloudTier: String?
    @State private var cloudSignedIn = false
    @State private var checkingCloudEntitlement = false
    @State private var showingGroqSettings = false
    @State private var validatingGroqKey = false
    @State private var groqKeyStatus: String?
    @State private var cloudAuthInFlight = false
    @State private var cloudBillingInFlight = false
    @State private var hoveredSidebarTab: SettingsTab?
    @State private var hoveredSettingsTab: SettingsDetailTab?
    private let cloudAuth = CloudAuthService()
    private let cloudService = OpenFlowCloudService()
    private var cloudBusy: Bool { cloudAuthInFlight || cloudBillingInFlight }
    private let chromeHeight: CGFloat = 128

    init(initialTab: SettingsTab = .general) {
        _selectedTab = State(initialValue: initialTab == .permissions ? .settings : initialTab)
        _settingsTab = State(initialValue: initialTab == .permissions ? .permissions : .general)
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                redesignedBackdrop
                topConsole

                content
                    .frame(width: proxy.size.width,
                           height: max(0, proxy.size.height - chromeHeight),
                           alignment: .topLeading)
                    .offset(y: chromeHeight)
                    .transaction { transaction in
                        transaction.animation = nil
                    }
                    .animation(nil, value: selectedTab)
                    .animation(nil, value: settingsTab)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(
            minWidth: FlowUI.hubWindowWidth,
            maxWidth: FlowUI.hubWindowWidth,
            minHeight: FlowUI.hubWindowHeight,
            maxHeight: FlowUI.hubWindowHeight
        )
        .preferredColorScheme(.dark)
        .onAppear {
            coordinator.permissions.startPolling()
            applyCloudSessionSurface()
            refreshCloudEntitlement()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            applyCloudSessionSurface()
            refreshCloudEntitlement()
            OpenflowHubWindowRestorer.restoreIfSafe()
        }
        .onReceive(NotificationCenter.default.publisher(for: .openflowRestoreHubWindows)) { _ in
            OpenflowHubWindowRestorer.restoreIfSafe()
        }
        .onReceive(NotificationCenter.default.publisher(for: .openflowCloudSessionDidChange)) { _ in
            applyCloudSessionSurface()
        }
    }

    private var redesignedBackdrop: some View {
        FlowWindowBackdrop()
    }

    private var topConsole: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                FlowLogo()
                Text("openflow")
                    .font(.system(size: 20, weight: .heavy))
                    .foregroundStyle(FlowUI.ink)
            }

            HStack(spacing: 8) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 7) {
                        topNav("Home", "house", .general)
                        topNav("History", "clock.arrow.circlepath", .history)
                        topNav("Dictionary", "text.book.closed", .dictionary)
                        topNav("Phrases", "text.quote", .phrases)
                        topNav("Style", "slider.horizontal.3", .style)
                    }
                    .padding(.leading, 5)
                    .padding(.vertical, 5)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                settingsTopButton
                    .padding(.trailing, 5)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.ultraThinMaterial, in: Capsule())
            .background(Color.white.opacity(0.03), in: Capsule())
            .glassEffect(.regular.tint(.white.opacity(0.05)).interactive(), in: Capsule())
            .overlay(Capsule().stroke(FlowUI.glassHairline))
        }
        .padding(.horizontal, 22)
        .padding(.top, 28)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, minHeight: 128, maxHeight: 128, alignment: .topLeading)
    }

    private var statusChip: some View {
        Button {
            if !permissionsReady {
                settingsTab = .permissions
                selectedTab = .settings
            } else if !coordinator.hasAPIKey() {
                settingsTab = .provider
                selectedTab = .settings
            }
        } label: {
            HStack(spacing: 7) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text(topStatusText)
                    .font(.system(size: 12, weight: .bold))
                    .lineLimit(1)
            }
            .foregroundStyle(FlowUI.ink.opacity(0.82))
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(.white.opacity(0.46), in: Capsule())
            .overlay(Capsule().stroke(.white.opacity(0.55)))
        }
        .buttonStyle(.plain)
        .disabled(permissionsReady && coordinator.hasAPIKey())
    }

    private var topStatusText: String {
        if !permissionsReady { return "Needs setup" }
        if !coordinator.hasAPIKey() { return "Needs key" }
        return "Ready"
    }

    private var statusColor: Color {
        if !permissionsReady { return FlowUI.coral }
        if !coordinator.hasAPIKey() { return FlowUI.amber }
        return FlowUI.moss
    }

    private func topNav(_ title: String, _ symbol: String, _ tab: SettingsTab) -> some View {
        Button {
            selectedTab = tab
        } label: {
            HStack(alignment: .center, spacing: 7) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .bold))
                    .frame(width: 14, height: 14)
                Text(title)
                    .font(.system(size: 12, weight: .bold))
                    .lineLimit(1)
            }
            .foregroundStyle(selectedTab == tab ? FlowUI.ink : FlowUI.ink.opacity(0.66))
            .padding(.horizontal, 11)
            .frame(height: 32)
            .background {
                if selectedTab == tab {
                    Capsule()
                        .fill(FlowUI.selectedFill)
                } else if hoveredSidebarTab == tab {
                    Capsule()
                        .fill(FlowUI.hoverFill)
                }
            }
            .overlay {
                if selectedTab == tab {
                    Capsule().stroke(Color.white.opacity(0.17))
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            hoveredSidebarTab = hovering ? tab : nil
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                FlowLogo()
                Text("openflow")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(FlowUI.ink)
            }
            .padding(.bottom, 12)

            nav("Home", "square.grid.2x2", .general)
            nav("History", "clock.arrow.circlepath", .history)
            nav("Dictionary", "text.book.closed", .dictionary)
            nav("Phrases", "text.quote", .phrases)
            nav("Style", "textformat.size", .style)

            Spacer()

            if !permissionsReady {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Setup needed")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Grant mic and Accessibility access.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Button("Fix Permissions") {
                        settingsTab = .permissions
                        selectedTab = .settings
                    }
                        .buttonStyle(FlowPrimaryButtonStyle())
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(FlowUI.panel, in: RoundedRectangle(cornerRadius: 8))
                .glassEffect(.regular.tint(.white.opacity(0.10)), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(FlowUI.glassHairline))
            }

            nav("Settings", "gearshape", .settings)
            Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 6)
        }
        .padding(18)
        .frame(width: 214)
        .background(.ultraThinMaterial)
        .background(Color.white.opacity(0.05))
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(.white.opacity(0.38))
                .frame(width: 1)
        }
    }

    private func nav(_ title: String, _ symbol: String, _ tab: SettingsTab) -> some View {
        Button {
            selectedTab = tab
        } label: {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .frame(width: 18)
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
            }
            .foregroundStyle(selectedTab == tab ? Color.primary : Color.primary.opacity(0.82))
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(sidebarBackground(for: tab), in: RoundedRectangle(cornerRadius: 7))
            .glassEffect(selectedTab == tab || hoveredSidebarTab == tab ? .regular.tint(.white.opacity(0.10)).interactive() : .identity,
                         in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            hoveredSidebarTab = hovering ? tab : nil
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var content: some View {
        switch selectedTab {
        case .general:
            home.flowHubPagePadding()
        case .permissions:
            settingsPanel.padding(30)
        case .dictionary:
            DictionaryView().environmentObject(coordinator).flowHubPagePadding()
        case .phrases:
            PhrasesView().environmentObject(coordinator).flowHubPagePadding()
        case .style:
            StyleView().environmentObject(coordinator).flowHubPagePadding()
        case .history:
            HistoryView().environmentObject(coordinator).flowHubPagePadding()
        case .apps:
            AppsView(
                cloudSignedIn: cloudSignedIn,
                onBackToHome: { selectedTab = .general }
            )
            .environmentObject(coordinator)
            .flowHubPagePadding()
        case .settings:
            settingsPanel.padding(30)
        }
    }

    private var home: some View {
        HomeDashboardView(
            cloudSignedIn: cloudSignedIn,
            onOpenHistory: { selectedTab = .history },
            onOpenApps: { selectedTab = .apps },
            onOpenPlan: {
                settingsTab = .provider
                selectedTab = .settings
            }
        )
        .environmentObject(coordinator)
    }

    private func connectCloud() {
        guard !cloudBusy else { return }
        cloudAuthInFlight = true
        cloudStatus = "Finish signing in in your browser..."
        Task {
            defer {
                Task { @MainActor in
                    cloudAuthInFlight = false
                }
            }
            do {
                let user = try await cloudAuth.connectDevice { code in
                    cloudStatus = "Confirm code \(code) in your browser."
                }
                await MainActor.run {
                    cloudSignedIn = true
                    cloudStatus = "Connected\(user.email.map { " as \($0)" } ?? ""). Checking plan..."
                    coordinator.noteSetupReadinessChanged()
                }
                await refreshCloudEntitlementAsync()
                coordinator.refreshAccountState()
            } catch {
                await MainActor.run {
                    cloudStatus = cloudMessage(for: error)
                }
            }
        }
    }

    private func openCloudBilling(_ action: CloudBillingAction) {
        guard !cloudBusy else { return }
        guard let baseURL = URL(string: coordinator.settings.cloudBaseURL),
              !coordinator.settings.cloudBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            cloudStatus = "Set the cloud backend URL first."
            return
        }
        cloudBillingInFlight = true
        cloudStatus = action == .checkout ? "Opening checkout..." : "Opening billing portal..."
        Task {
            defer {
                Task { @MainActor in
                    cloudBillingInFlight = false
                }
            }
            do {
                if (try? KeychainService.shared.cloudSessionToken())?.isEmpty != false {
                    _ = try await cloudAuth.connectDevice { code in
                        cloudStatus = "Confirm code \(code) in your browser."
                    }
                }
                let url = try await cloudBillingURLRecoveringAuthentication(
                    action,
                    baseURL: baseURL
                )
                await MainActor.run {
                    CloudURLPolicy.openExternal(url)
                    cloudStatus = action == .checkout
                        ? "Checkout opened. Return here when you are finished."
                        : "Billing portal opened."
                }
                coordinator.refreshAccountState()
            } catch OpenflowError.cloudSubscriptionAlreadyActive {
                await refreshCloudEntitlementAsync()
            } catch {
                await MainActor.run {
                    cloudStatus = cloudMessage(for: error)
                }
            }
        }
    }

    private func cloudBillingURLRecoveringAuthentication(
        _ action: CloudBillingAction,
        baseURL: URL
    ) async throws -> URL {
        do {
            return try await cloudBillingURL(action, baseURL: baseURL)
        } catch {
            guard isRecoverableCloudAuthError(error) else { throw error }
            if case OpenflowError.cloudSessionRevoked = error {
                let cleared = await coordinator.confirmRemoteCloudRevocation()
                if !cleared {
                    throw OpenflowError.cloudProviderUnavailable(
                        "Couldn’t connect to openflow right now. Please try again."
                    )
                }
            }
            await MainActor.run {
                cloudStatus = "Opening secure sign in..."
            }
            cloudAuth.signOut()
            _ = try await cloudAuth.connectDevice { code in
                cloudStatus = "Confirm code \(code) in your browser."
            }
            return try await cloudBillingURL(action, baseURL: baseURL)
        }
    }

    private func cloudBillingURL(
        _ action: CloudBillingAction,
        baseURL: URL
    ) async throws -> URL {
        switch action {
        case .checkout:
            return try await cloudService.checkoutURL(baseURL: baseURL)
        case .portal:
            return try await cloudService.portalURL(baseURL: baseURL)
        }
    }

    private func refreshCloudEntitlement() {
        guard !checkingCloudEntitlement,
              let token = try? KeychainService.shared.cloudSessionToken(),
              !token.isEmpty else {
            cloudSignedIn = false
            cloudEntitled = false
            cloudTier = nil
            coordinator.cloudTier = nil
            return
        }
        cloudSignedIn = true
        coordinator.noteSetupReadinessChanged()
        Task {
            await refreshCloudEntitlementAsync()
        }
    }

    private func refreshCloudEntitlementAsync() async {
        guard let baseURL = URL(string: coordinator.settings.cloudBaseURL) else { return }
        await MainActor.run {
            checkingCloudEntitlement = true
        }
        do {
            let entitlement = try await cloudService.entitlement(baseURL: baseURL)
            await MainActor.run {
                cloudSignedIn = true
                cloudEntitled = entitlement.canUseCloud
                cloudTier = entitlement.tier
                coordinator.cloudTier = entitlement.tier
                checkingCloudEntitlement = false
                if coordinator.hasAPIKey() {
                    coordinator.settings.providerMode = .localGroq
                    cloudStatus = entitlement.canUseCloud
                        ? "Using your Groq key. \(entitlement.cancelAtPeriodEndDescription)"
                        : "Using your Groq key."
                } else if entitlement.canUseCloud {
                    coordinator.settings.providerMode = .openflowCloud
                    cloudStatus = entitlement.cancelAtPeriodEndDescription
                } else {
                    cloudStatus = "Signed in. No active subscription."
                }
            }
        } catch {
            var statusError = error
            if case OpenflowError.cloudSessionRevoked = error {
                let cleared = await coordinator.confirmRemoteCloudRevocation()
                if !cleared {
                    statusError = OpenflowError.cloudProviderUnavailable(
                        "Couldn’t connect to openflow right now. Please try again."
                    )
                }
            }
            await MainActor.run {
                applyCloudSessionSurface()
                if case OpenflowError.cloudAuthenticationRequired = statusError {
                    cloudSignedIn = false
                }
                cloudEntitled = false
                cloudTier = nil
                coordinator.cloudTier = nil
                checkingCloudEntitlement = false
                cloudStatus = cloudMessage(for: statusError)
            }
        }
    }

    private func cloudMessage(for error: Error) -> String {
        if case OpenflowError.cloudSessionRevoked = error {
            return CloudSessionValidator.revokedUserMessage
        }
        if case OpenflowError.cloudAuthenticationRequired = error {
            return "Sign in to choose Free or openflow Pro."
        }
        if case OpenflowError.cloudSubscriptionAlreadyActive = error {
            return "openflow Pro is active."
        }
        if let openflowError = error as? OpenflowError {
            return openflowError.localizedDescription
        }
        return "Couldn’t connect to openflow right now. Please try again."
    }

    private var hasCloudSession: Bool {
        guard let token = try? KeychainService.shared.cloudSessionToken() else {
            return false
        }
        return !token.isEmpty
    }

    private func applyCloudSessionSurface() {
        cloudSignedIn = hasCloudSession
        if !hasCloudSession {
            cloudEntitled = false
            cloudTier = nil
            coordinator.cloudTier = nil
            if let notice = coordinator.cloudSessionNotice {
                cloudStatus = notice
            }
        }
    }

    private func isRecoverableCloudAuthError(_ error: Error) -> Bool {
        if case OpenflowError.cloudAuthenticationRequired = error { return true }
        if case OpenflowError.cloudSessionRevoked = error { return true }
        return false
    }

    private func signOutCloudAccount() {
        cloudAuth.signOut()
        coordinator.cloudSessionNotice = nil
        cloudSignedIn = false
        cloudEntitled = false
        cloudTier = nil
        coordinator.cloudTier = nil
        cloudStatus = "Signed out."
        coordinator.refreshAccountState()
        coordinator.noteSetupReadinessChanged()
        if coordinator.hasAPIKey() {
            coordinator.settings.providerMode = .localGroq
        }
    }

    private func openDiagnosticsFolder() {
        let url = InsertionDiagnosticsService.directoryURL
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.open(url)
    }

    private var settingsTopButton: some View {
        Button {
            selectedTab = .settings
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(FlowUI.ink)
                .frame(width: 32, height: 32)
                .background(selectedTab == .settings ? FlowUI.selectedFill : FlowUI.controlFill, in: Capsule())
                .overlay(Capsule().stroke(selectedTab == .settings ? Color.white.opacity(0.17) : FlowUI.hairline))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private var settingsPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                settingsRail
                Rectangle()
                    .fill(FlowUI.hairline)
                    .frame(width: 1)
                settingsDetailScroller
                    .id(settingsTab)
                    .frame(maxWidth: .infinity)
            }
            .background(FlowUI.panel, in: RoundedRectangle(cornerRadius: 8))
            .flowLiquidGlass(cornerRadius: 8, tintOpacity: 0.04)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private var settingsDetailScroller: some View {
        if settingsTab == .provider && !showingGroqSettings {
            settingsDetailColumn
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            ScrollView {
                settingsDetailColumn
            }
        }
    }

    private var settingsPageHeader: some View {
        HStack(alignment: .center, spacing: FlowUI.settingsDetailHeaderIconTitleGap) {
            Image(systemName: settingsTab.symbol)
                .font(.system(size: FlowUI.settingsDetailHeaderIconFont, weight: .bold))
                .foregroundStyle(FlowUI.ink)
                .frame(width: FlowUI.settingsDetailHeaderIconSize, height: FlowUI.settingsDetailHeaderIconSize)
                .background(FlowUI.selectedFill, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.15)))
            Text(settingsTab.title)
                .font(.system(size: FlowUI.settingsDetailHeaderTitleFont, weight: .bold))
                .foregroundStyle(FlowUI.ink)
        }
    }

    private var settingsDetailColumn: some View {
        VStack(alignment: .leading, spacing: FlowUI.settingsDetailTitleContentGap) {
            settingsPageHeader
            settingsDetail
        }
        .padding(FlowUI.settingsDetailHeaderInset)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var subscriptionDetail: some View {
        VStack(alignment: .leading, spacing: 14) {
            EqualHeightPlanRow(spacing: 12) {
                settingsPlanCard(title: "Free",
                                 price: "$0",
                                 detail: CloudPrivacyCopy.freePlanDetail,
                                 symbol: "waveform",
                                 selected: cloudTier == "free",
                                 buttonTitle: cloudTier == "pro"
                                    ? "Downgrade"
                                    : (cloudTier == "free" ? "Current plan" : "Use Free")) {
                    if cloudTier == "pro" {
                        openCloudBilling(.portal)
                    } else {
                        connectCloud()
                    }
                }
                settingsPlanCard(title: "openflow Pro",
                                 price: "$8 / month",
                                 detail: CloudPrivacyCopy.proPlanDetail,
                                 symbol: "infinity",
                                 selected: cloudTier == "pro",
                                 buttonTitle: cloudTier == "pro" ? "Manage plan" : "Get Pro") {
                    if cloudTier == "pro" {
                        openCloudBilling(.portal)
                    } else {
                        openCloudBilling(.checkout)
                    }
                }
            }
            .layoutPriority(1)

            HStack(spacing: 8) {
                Text(coordinator.settings.providerMode == .localGroq
                     ? "Using your own Groq key"
                     : "Prefer your own API key?")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Button(showingGroqSettings ? "Hide" : "Bring your own key") {
                    showingGroqSettings.toggle()
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(FlowUI.ink.opacity(0.74))
                Spacer()
            }
            .padding(.horizontal, 6)

            HStack(spacing: 10) {
                Text(cloudStatus)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                if cloudSignedIn {
                    Button("Sign out") {
                        signOutCloudAccount()
                    }
                    .buttonStyle(FlowSecondaryButtonStyle())
                    .frame(width: 96)
                    .disabled(cloudBusy)
                } else {
                    Button {
                        connectCloud()
                    } label: {
                        if cloudAuthInFlight {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text("Sign in")
                        }
                    }
                    .buttonStyle(FlowSecondaryButtonStyle())
                    .frame(width: 96)
                    .disabled(cloudBusy)
                }
            }
            .padding(.horizontal, 6)

            if showingGroqSettings {
                settingsCard("Bring your own key") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Stored securely in macOS Keychain. Requests go directly from this Mac to Groq.")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                        HStack(spacing: 10) {
                            FlowInputField(placeholder: coordinator.hasAPIKey() ? "Key already stored" : "Paste Groq API key",
                                           text: $apiKey,
                                           isSecure: true)
                                .disabled(validatingGroqKey)
                            Button(validatingGroqKey ? "Checking" : (coordinator.hasAPIKey() ? "Update key" : "Save key")) {
                                validateAndSaveGroqKey()
                            }
                            .buttonStyle(FlowPrimaryButtonStyle(disabled: apiKey.isEmpty || validatingGroqKey))
                            .disabled(apiKey.isEmpty || validatingGroqKey)
                            .frame(width: 104)
                            if coordinator.hasAPIKey() {
                                Button("Remove key") {
                                    removeGroqKey()
                                }
                                .buttonStyle(FlowSecondaryButtonStyle())
                                .frame(width: 104)
                            }
                        }
                        if let groqKeyStatus {
                            Text(groqKeyStatus)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(groqKeyStatus == "Groq key verified." ? FlowUI.success : Color.red.opacity(0.9))
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var settingsRail: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Settings")
                .font(.system(size: 12, weight: .semibold))
                .tracking(0)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.bottom, 4)
            ForEach([SettingsDetailTab.general, .permissions, .provider, .shortcuts, .updates]) { tab in
                settingsRailButton(tab)
            }
            Spacer()
        }
        .padding(16)
        .frame(width: 194, alignment: .topLeading)
        .background(
            UnevenRoundedRectangle(topLeadingRadius: 8,
                                   bottomLeadingRadius: 8,
                                   bottomTrailingRadius: 0,
                                   topTrailingRadius: 0)
                .fill(Color.white.opacity(0.035))
        )
        .clipped()
    }

    @ViewBuilder
    private var settingsDetail: some View {
        switch settingsTab {
        case .general:
            settingsCard("General") {
                settingsToggleRow("History", "Save final dictations locally.", isOn: $coordinator.settings.historyEnabled)
                permissionDivider
                settingsToggleRow("Context awareness", "Use the focused app for spacing and tone. When off, nearby field text stays on this Mac and is not sent for cleanup.", isOn: $coordinator.settings.contextAwarenessEnabled)
                permissionDivider
                settingsToggleRow("Browser detection", "Read supported browser URLs when available.", isOn: $coordinator.settings.browserURLDetectionEnabled)
                permissionDivider
                settingsToggleRow("Spoken press enter", "When on, a trailing press enter, hit enter, or press return sends Return and those words are removed. When off, the words stay in the document.", isOn: $coordinator.settings.pressEnterCommandEnabled)
                permissionDivider
                settingsToggleRow("Hide inactive pill", "Only show the floating UI while recording, processing, or reporting a result.", isOn: $coordinator.settings.hideInactivePill)
                    .onChange(of: coordinator.settings.hideInactivePill) { _, _ in
                        coordinator.refreshPillVisibility()
                    }
                permissionDivider
                microphonePickerRow
            }
        case .permissions:
            permissionsPanel
        case .provider:
            subscriptionDetail
        case .shortcuts:
            settingsCard("Shortcuts") {
                shortcutPickerRow("Push-to-talk", "Hold this shortcut to dictate into the active field.", selection: $coordinator.settings.pushToTalkHotkey)
                permissionDivider
                shortcutPickerRow("Toggle dictation", "Press once to start, press again to stop.", selection: $coordinator.settings.toggleHotkey)
            }
        case .updates:
            settingsCard("Software updates") {
                HStack(spacing: 14) {
                    Image(systemName: updateSymbol)
                        .font(.system(size: 17, weight: .bold))
                        .frame(width: 42, height: 42)
                        .background(FlowUI.controlFill,
                                    in: RoundedRectangle(cornerRadius: 8))

                    VStack(alignment: .leading, spacing: 4) {
                        Text("openflow \(updater.currentVersion)")
                            .font(.system(size: 15, weight: .bold))
                        Text(updater.state.label)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    updateActionButton
                }

                if let checkedAt = updater.lastCheckedAt {
                    Text("Last checked \(checkedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }

                permissionDivider
                settingsToggleRow(
                    "Automatically check for updates",
                    "Looks for new versions in the background.",
                    isOn: $updater.automaticallyChecksForUpdates
                )
            }
        case .diagnostics:
            settingsCard("Latency") {
                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 8) {
                    metric("\(coordinator.settings.pushToTalkHotkey.keycapLabel) to listening", coordinator.currentMetrics.hotkeyToRecordingStart)
                    metric("Audio duration", coordinator.currentMetrics.audioDuration)
                    metric("Groq transcription", coordinator.currentMetrics.uploadAndTranscriptionTime)
                    metric("Cleanup", coordinator.currentMetrics.cleanupTime)
                    metric("Insertion", coordinator.currentMetrics.insertionTime)
                    metric("Total", coordinator.currentMetrics.totalTime)
                }
                ForEach(coordinator.debugLog.prefix(8), id: \.self) { line in
                    Text(line).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                }
            }

            settingsCard("Insertion reports") {
                HStack(alignment: .center, spacing: 14) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(FlowUI.accent)
                        .frame(width: 40, height: 40)
                        .background(FlowUI.controlFill, in: RoundedRectangle(cornerRadius: 8))

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Failed insertion reports")
                            .font(.system(size: 16, weight: .bold))
                        Text("Local metadata-only JSON files for cases where transcription worked but text did not land.")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer()

                    Button("Open Folder") {
                        openDiagnosticsFolder()
                    }
                    .buttonStyle(FlowSecondaryButtonStyle())
                }
            }
        }
    }

    private var updateSymbol: String {
        switch updater.state {
        case .available:
            return "arrow.down.circle.fill"
        case .checking, .downloading, .preparing, .installing:
            return "arrow.triangle.2.circlepath"
        case .failed:
            return "exclamationmark.triangle.fill"
        default:
            return "checkmark.circle.fill"
        }
    }

    @ViewBuilder
    private var updateActionButton: some View {
        switch updater.state {
        case .available:
            Button("Install") {
                updater.installAvailableUpdate()
            }
            .buttonStyle(FlowPrimaryButtonStyle())
            .frame(width: 104)
        case .checking, .downloading, .preparing, .installing:
            ProgressView()
                .controlSize(.small)
                .frame(width: 104)
        default:
            Button("Check now") {
                updater.checkForUpdates()
            }
            .buttonStyle(FlowSecondaryButtonStyle())
            .frame(width: 104)
        }
    }

    private func validateAndSaveGroqKey() {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        groqKeyStatus = nil
        validatingGroqKey = true
        Task {
            do {
                try await GroqAPIKeyValidator().validate(key)
                try coordinator.saveAPIKey(key)
                coordinator.settings.providerMode = .localGroq
                apiKey = ""
                groqKeyStatus = "Groq key verified."
            } catch {
                groqKeyStatus = (error as? LocalizedError)?.errorDescription
                    ?? "The Groq key could not be verified."
            }
            validatingGroqKey = false
        }
    }

    private func removeGroqKey() {
        KeychainService.shared.deleteAPIKey()
        apiKey = ""
        groqKeyStatus = "Groq key removed."
        if cloudEntitled {
            coordinator.settings.providerMode = .openflowCloud
        }
        coordinator.noteSetupReadinessChanged()
    }

    private var permissionsPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            settingsCard("Required access") {
                permissionRow(title: "Microphone",
                              caption: "Record your dictation.",
                              granted: coordinator.permissions.microphoneGranted,
                              symbol: "mic.fill",
                              request: coordinator.permissions.requestMicrophone)
                permissionDivider
                permissionRow(title: "Accessibility",
                              caption: coordinator.permissions.accessibilityPromptIssued
                                ? "Look for the macOS dialog and choose Open System Settings so openflow appears in the list."
                                : "Read focused fields and insert text without using the clipboard.",
                              granted: coordinator.permissions.accessibilityGranted,
                              symbol: "cursorarrow.motionlines",
                              actionTitle: coordinator.permissions.accessibilityPromptIssued ? "Open Settings" : "Enable",
                              request: coordinator.permissions.requestAccessibility)
            }

            if !permissionsReady {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.clockwise")
                    Text(coordinator.permissions.accessibilityPromptIssued
                         ? "Wait for the macOS Accessibility dialog. Click Enable again only if you need the list after the prompt."
                         : "openflow is watching for changes. The checkmarks update as macOS grants access.")
                }
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
            }
        }
        .onAppear {
            coordinator.permissions.refresh()
            coordinator.permissions.startPolling()
        }
    }

    private var permissionButtonColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 138, maximum: 180), spacing: 10, alignment: .leading)]
    }

    private var permissionsReady: Bool {
        coordinator.permissions.microphoneGranted
            && coordinator.permissions.accessibilityGranted
    }

    private func settingsRailButton(_ tab: SettingsDetailTab) -> some View {
        Button {
            settingsTab = tab
        } label: {
            HStack(spacing: 11) {
                Image(systemName: tab.symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 18)
                Text(tab.title)
                    .font(.system(size: 14, weight: .bold))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                Spacer()
            }
            .foregroundStyle(settingsTab == tab ? FlowUI.ink : FlowUI.ink.opacity(0.66))
            .padding(.horizontal, 10)
            .frame(height: 38)
            .background {
                if settingsTab == tab {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(FlowUI.selectedFill)
                } else if hoveredSettingsTab == tab {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(FlowUI.hoverFill)
                }
            }
            .overlay {
                if settingsTab == tab {
                    RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.17))
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            hoveredSettingsTab = hovering ? tab : nil
        }
    }

    private func sidebarBackground(for tab: SettingsTab) -> Color {
        if selectedTab == tab {
            return Color(red: 0.94, green: 0.93, blue: 0.90)
        }
        if hoveredSidebarTab == tab {
            return FlowUI.ink.opacity(0.045)
        }
        return .clear
    }

    private func settingsToggleRow(_ title: String, _ subtitle: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(FlowUI.ink)
                Text(subtitle)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
        }
        .frame(minHeight: 48)
    }

    private func settingsTextRow(_ title: String, _ subtitle: String, text: Binding<String>) -> some View {
        HStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(FlowUI.ink)
                Text(subtitle)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 18)
            FlowInputField(placeholder: title, text: text)
                .frame(width: 270)
        }
        .frame(minHeight: 54)
    }

    private func proBenefitRow(_ title: String, _ detail: String, symbol: String) -> some View {
        HStack(spacing: 13) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(FlowUI.ink)
                .frame(width: 34, height: 34)
                .background(FlowUI.mutedFill, in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(FlowUI.ink)
                Text(detail)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 58)
    }

    private func settingsPlanCard(title: String,
                                  price: String,
                                  detail: String,
                                  symbol: String,
                                  selected: Bool,
                                  buttonTitle: String,
                                  action: @escaping () -> Void) -> some View {
        let disablesButton = cloudBusy || (selected && title == "Free" && cloudTier != "pro")
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .bold))
                    .frame(width: 32, height: 32)
                    .background(FlowUI.controlFill, in: RoundedRectangle(cornerRadius: 8))
                Spacer()
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(FlowUI.success)
                }
            }
            Text(title)
                .font(.system(size: 18, weight: .bold))
            Text(price)
                .font(.system(size: 13, weight: .bold))
            FlowPlanFeatureList(detail: detail)
            Spacer(minLength: 0)
            Button(action: action) {
                if cloudBusy && !selected {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Text(buttonTitle)
                }
            }
                .buttonStyle(FlowPrimaryButtonStyle(disabled: disablesButton))
                .disabled(disablesButton)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .flowLiquidGlass(cornerRadius: 8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(selected ? FlowUI.success.opacity(0.7) : Color.clear)
        )
    }

    private func shortcutPickerRow(_ title: String, _ subtitle: String, selection: Binding<HotkeyMode>) -> some View {
        HStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(FlowUI.ink)
                Text(subtitle)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 18)
            FlowMenuPicker(selection: selection,
                           options: HotkeyMode.allCases,
                           title: \.label,
                           width: 170)
        }
        .frame(minHeight: 54)
    }

    private var microphonePickerRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Microphone")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(FlowUI.ink)
                    Text("System Default uses the macOS input device, not headphones. Pick AirPods here to capture from them.")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 18)
                FlowMenuPicker(selection: $coordinator.settings.microphoneDeviceID,
                               options: microphonePickerOptions,
                               title: microphoneTitle,
                               width: 220)
            }
            if let message = coordinator.inputRouteStatus.message {
                Text(message)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(FlowUI.amber)
            }
        }
        .frame(minHeight: 54)
    }

    private var microphonePickerOptions: [String] {
        var options = [AudioInputDeviceCatalog.systemDefaultUID]
        let devices = coordinator.availableInputDevices()
        options.append(contentsOf: devices.map(\.uid))
        let selected = coordinator.settings.microphoneDeviceID
        if !selected.isEmpty, !options.contains(selected) {
            options.append(selected)
        }
        return options
    }

    private func microphoneTitle(_ uid: String) -> String {
        if uid.isEmpty { return "System Default" }
        if let device = coordinator.availableInputDevices().first(where: { $0.uid == uid }) {
            return device.name
        }
        return "Not connected"
    }

    private var permissionDivider: some View {
        Rectangle()
            .fill(FlowUI.hairline)
            .frame(height: 1)
    }

    private func permissionRow(title: String,
                               caption: String,
                               granted: Bool,
                               symbol: String,
                               actionTitle: String = "Enable",
                               request: @escaping () -> Void) -> some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(granted ? FlowUI.success : FlowUI.mutedFill)
                Image(systemName: granted ? "checkmark" : symbol)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(granted ? Color.black.opacity(0.86) : FlowUI.ink.opacity(0.78))
            }
            .frame(width: 36, height: 36)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 16, weight: .bold))
                Text(caption)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .layoutPriority(1)
            Spacer()
            if granted {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark")
                    Text("Granted")
                }
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(FlowUI.success)
                .padding(.horizontal, 11)
                .frame(width: 94)
                .frame(height: 30)
                .background(FlowUI.success.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(FlowUI.success.opacity(0.26)))
            } else {
                Button(actionTitle, action: request)
                    .buttonStyle(FlowPrimaryButtonStyle())
                    .help("Enable \(title)")
                    .frame(width: 124)
            }
        }
        .frame(minHeight: 62)
    }

    private func settingsLinkButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .bold))
                .lineLimit(1)
                .minimumScaleFactor(0.86)
                .frame(maxWidth: .infinity, minHeight: 34)
        }
        .buttonStyle(FlowSecondaryButtonStyle())
    }

    private func settingsCard<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.system(size: 18, weight: .bold))
            content()
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .flowLiquidGlass(cornerRadius: 8)
    }

    private func metric(_ label: String, _ value: TimeInterval) -> some View {
        GridRow {
            Text(label)
            Text("\(Int(value * 1000)) ms")
                .font(.system(.body, design: .monospaced))
        }
    }
}

struct SetupJourneyCard: View {
    let completedSteps: Int
    let microphoneGranted: Bool
    let accessibilityGranted: Bool
    let hasProvider: Bool
    let requestMicrophone: () -> Void
    let requestAccessibility: () -> Void
    let openPlan: () -> Void
    var body: some View {
        HStack(spacing: 18) {
            ZStack {
                Circle()
                    .stroke(FlowUI.ink.opacity(0.08), lineWidth: 5)
                Circle()
                    .trim(from: 0, to: CGFloat(completedSteps) / 3.0)
                    .stroke(FlowUI.ink, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("\(completedSteps)/3")
                    .font(.system(size: 12, weight: .bold))
            }
            .frame(width: 46, height: 46)

            VStack(alignment: .leading, spacing: 3) {
                    Text("Set up openflow")
                        .font(.system(size: 15, weight: .bold))
                    Text("Finish these steps before your first dictation.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
            }

            Spacer(minLength: 12)

            HStack(spacing: 8) {
                setupRow("Microphone", microphoneGranted, action: requestMicrophone)
                setupRow("Accessibility", accessibilityGranted, action: requestAccessibility)
                setupRow("Plan", hasProvider, action: openPlan)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .flowLiquidGlass(cornerRadius: 8)
    }

    private func setupRow(_ title: String, _ done: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: done ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(done ? FlowUI.success : .secondary)
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(FlowUI.ink)
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(done ? FlowUI.success.opacity(0.08) : FlowUI.ink.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .disabled(title == "First dictation")
    }
}

/// Sizes Free/Pro to the taller card, then stretches the shorter one so buttons share a baseline.
private struct EqualHeightPlanRow: Layout {
    var spacing: CGFloat = 12

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let count = CGFloat(subviews.count)
        guard count > 0 else { return .zero }
        let innerWidth: CGFloat
        if let width = proposal.width, width.isFinite {
            innerWidth = max(0, (width - spacing * (count - 1)) / count)
        } else {
            innerWidth = 280
        }
        let heights = subviews.map { subview in
            subview.sizeThatFits(ProposedViewSize(width: innerWidth, height: nil)).height
        }
        let height = heights.max() ?? 0
        let width = proposal.width ?? (innerWidth * count + spacing * (count - 1))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let count = CGFloat(subviews.count)
        guard count > 0 else { return }
        let innerWidth = max(0, (bounds.width - spacing * (count - 1)) / count)
        var x = bounds.minX
        for subview in subviews {
            subview.place(
                at: CGPoint(x: x, y: bounds.minY),
                proposal: ProposedViewSize(width: innerWidth, height: bounds.height)
            )
            x += innerWidth + spacing
        }
    }
}

struct FlowLogo: View {
    var body: some View {
        OpenflowGlyph()
            .frame(width: 33, height: 20)
            .shadow(color: FlowUI.ink.opacity(0.18), radius: 8, x: 0, y: 0)
    }
}

struct OpenflowGlyph: View {
    var body: some View {
        Image("OpenflowLogoSmall")
            .resizable()
            .scaledToFit()
            .accessibilityLabel("openflow")
    }
}

