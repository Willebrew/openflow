import SwiftUI

struct OnboardingFlowView: View {
    @EnvironmentObject private var coordinator: DictationCoordinator
    @State private var step: OnboardingStep = .welcome
    @State private var apiKey = ""
    @State private var cloudStatus = "Sign in to start using openflow Pro."
    @State private var cloudEntitled = false
    @State private var cloudTier: String?
    @State private var cloudWordsRemaining: Int?
    @State private var cloudWordLimit: Int?
    @State private var checkingCloudEntitlement = false
    @State private var localKeyConfigured = false
    @State private var animate = false
    @State private var showingBYOKeySheet = false
    @State private var cloudAuthInFlight = false
    @State private var cloudBillingInFlight = false

    let onComplete: () -> Void
    private let cloudAuth = CloudAuthService()
    private let cloudService = OpenFlowCloudService()
    private var cloudBusy: Bool { cloudAuthInFlight || cloudBillingInFlight }
    private let windowSize = CGSize(width: 920, height: 640)
    private let railWidth: CGFloat = 250
    private let navBottomInset: CGFloat = 26
    private let footerSlotHeight: CGFloat = 76

    var body: some View {
        ZStack {
            background
            HStack(spacing: 0) {
                stageRail
                Rectangle()
                    .fill(FlowUI.ink.opacity(0.08))
                    .frame(width: 1)
                VStack(spacing: 0) {
                    content
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .clipped()
                        .frame(height: windowSize.height - footerSlotHeight)
                    footer
                        .padding(.horizontal, 34)
                        .padding(.bottom, navBottomInset)
                        .frame(height: footerSlotHeight, alignment: .bottom)
                }
                .frame(width: windowSize.width - railWidth - 1, height: windowSize.height)
            }
            .frame(width: windowSize.width, height: windowSize.height)
        }
        .frame(width: windowSize.width, height: windowSize.height)
        .preferredColorScheme(.dark)
        .onAppear {
            animate = true
            localKeyConfigured = coordinator.hasAPIKey()
            coordinator.permissions.startPolling()
            refreshCloudEntitlement()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refocusOnboardingWindow()
            refreshCloudEntitlement()
        }
        .onReceive(NotificationCenter.default.publisher(for: .openflowRestoreHubWindows)) { _ in
            refocusOnboardingWindow()
        }
        .onReceive(NotificationCenter.default.publisher(for: .openflowCloudSessionDidChange)) { _ in
            if !hasCloudToken, let notice = coordinator.cloudSessionNotice {
                cloudStatus = notice
            }
        }
        .sheet(isPresented: $showingBYOKeySheet) {
            BringYourOwnKeySheet(apiKey: $apiKey,
                                 hasAPIKey: hasAPIKey,
                                 onRemove: {
                KeychainService.shared.deleteAPIKey()
                apiKey = ""
                localKeyConfigured = false
                if cloudEntitled {
                    coordinator.settings.providerMode = .openflowCloud
                }
                refocusOnboardingWindow()
            }) { key in
                try coordinator.saveAPIKey(key)
                coordinator.settings.providerMode = .localGroq
                localKeyConfigured = true
                refocusOnboardingWindow()
            }
            .frame(width: 430)
            .preferredColorScheme(.dark)
        }
    }

    private var background: some View {
        FlowWindowBackdrop()
    }

    private var stageRail: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                FlowLogo()
                Text("openflow")
                    .font(.system(size: 22, weight: .bold))
            }
            .padding(.bottom, 16)

            ForEach(OnboardingStep.allCases) { item in
                HStack(spacing: 11) {
                    ZStack {
                        Circle()
                            .fill(item.index < step.index ? FlowUI.success : item.index == step.index ? FlowUI.ink : FlowUI.ink.opacity(0.08))
                        if item.index < step.index {
                            Image(systemName: "checkmark")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(Color.black.opacity(0.86))
                        } else {
                            Text("\(item.index + 1)")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(item.index <= step.index ? Color.black.opacity(0.86) : .secondary)
                        }
                    }
                    .frame(width: 24, height: 24)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.railTitle)
                            .font(.system(size: 13, weight: .bold))
                        Text(item.railCaption)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                .opacity(item.index <= step.index ? 1 : 0.48)
            }

            Spacer()
        }
        .padding(26)
        .frame(width: railWidth, height: windowSize.height, alignment: .topLeading)
        .background(.ultraThinMaterial)
        .background(Color.white.opacity(0.03))
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .welcome:
            welcome
        case .tour:
            tour
        case .permissions:
            permissions
        case .key:
            apiKeyStep
        case .ready:
            ready
        }
    }

    private var welcome: some View {
        onboardingPage(title: "Welcome to openflow",
                       subtitle: "Dictation that feels native to your Mac: fast, quiet, and ready wherever you type.") {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 18) {
                    Text(coordinator.settings.pushToTalkHotkey.keycapLabel)
                        .font(.system(size: 34, weight: .black))
                        .foregroundStyle(Color.black.opacity(0.88))
                        .frame(width: 118, height: 82)
                        .background(FlowUI.ink, in: RoundedRectangle(cornerRadius: 18, style: .continuous))

                    VStack(alignment: .leading, spacing: 7) {
                        Text("Hold to speak")
                            .font(.system(size: 22, weight: .bold))
                        Text("Release when you are done. openflow cleans the words and places them at your cursor.")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                }
                .padding(22)
                .background(FlowUI.panel, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(FlowUI.glassHairline))

                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 12) {
                    welcomeFeature("Works where you type", "text.cursor", "Messages, browsers, documents, and terminals.")
                    welcomeFeature("Keeps your intent", "quote.bubble", "Corrections, names, and technical language stay intact.")
                    welcomeFeature("Matches the app", "slider.horizontal.3", "Casual in chat, polished in email, careful in code.")
                }
            }
        }
    }

    private var tour: some View {
        onboardingPage(title: "One shortcut. Three moments.",
                       subtitle: "There is nothing new to learn. openflow follows the same rhythm every time.") {
            VStack(spacing: 12) {
                tourStep(number: "1",
                         title: "Hold \(coordinator.settings.pushToTalkHotkey.keycapLabel)",
                         detail: "The floating pill wakes at the bottom edge without taking focus.",
                         symbol: "keyboard",
                         preview: AnyView(
                            Capsule()
                                .fill(Color.black.opacity(0.92))
                                .frame(width: 92, height: 26)
                                .overlay(Capsule().stroke(Color.white.opacity(0.20)))
                         ))
                tourStep(number: "2",
                         title: "Speak naturally",
                         detail: "Pause, correct yourself, and say punctuation when you need it.",
                         symbol: "waveform",
                         preview: AnyView(TourWaveform(animate: animate)))
                tourStep(number: "3",
                         title: "Release",
                         detail: "Polished text lands in the app and field you were already using.",
                         symbol: "checkmark",
                         preview: AnyView(
                            Text("Text inserted")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(Color.black.opacity(0.84))
                                .padding(.horizontal, 12)
                                .frame(height: 28)
                                .background(FlowUI.ink, in: Capsule())
                         ))
            }
        }
    }

    private var permissions: some View {
        onboardingPage(title: "Give openflow access",
                       subtitle: "These are required before dictation can work reliably. This step cannot be skipped.") {
            VStack(spacing: 12) {
                permissionCard(title: "Microphone",
                               caption: "Lets openflow hear your dictation.",
                               granted: coordinator.permissions.microphoneGranted,
                               symbol: "mic.fill",
                               action: coordinator.permissions.requestMicrophone)
                permissionCard(title: "Accessibility",
                               caption: coordinator.permissions.accessibilityPromptIssued
                                ? "Look for the macOS dialog and choose Open System Settings so openflow appears in the list."
                                : "Lets openflow find the focused field and insert text invisibly.",
                               granted: coordinator.permissions.accessibilityGranted,
                               symbol: "cursorarrow.motionlines",
                               actionTitle: coordinator.permissions.accessibilityPromptIssued ? "Open Settings" : "Enable",
                               action: coordinator.permissions.requestAccessibility)
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
    }

    private var apiKeyStep: some View {
        onboardingPage(title: "Choose your plan",
                       subtitle: "Start free, or remove the monthly limit with openflow Pro.") {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    planChoiceCard(title: "Free",
                                   price: "$0",
                                   detail: CloudPrivacyCopy.freePlanDetail,
                                   symbol: "waveform",
                                   selected: cloudTier == "free",
                                   buttonTitle: cloudTier == "pro"
                                    ? "Downgrade"
                                    : (cloudTier == "free" ? "Selected" : "Start free")) {
                        if cloudTier == "pro" {
                            openCloudPortal()
                        } else {
                            connectCloud()
                        }
                    }
                    planChoiceCard(title: "openflow Pro",
                                   price: "$8 / month",
                                   detail: CloudPrivacyCopy.proPlanDetail,
                                   symbol: "infinity",
                                   selected: cloudTier == "pro",
                                   buttonTitle: cloudTier == "pro" ? "Manage plan" : "Get Pro") {
                        if cloudTier == "pro" {
                            openCloudPortal()
                        } else {
                            startCloudSubscribe()
                        }
                    }
                }

                Text(cloudStatus)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .fixedSize(horizontal: false, vertical: true)

                HStack {
                    Text("Have a Groq API key?")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(hasAPIKey ? "Manage key" : "Bring your own key") {
                        showingBYOKeySheet = true
                        refocusOnboardingWindow()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(FlowUI.ink.opacity(0.72))
                }
                .padding(.horizontal, 6)
            }
        }
    }

    private func planChoiceCard(title: String,
                                price: String,
                                detail: String,
                                symbol: String,
                                selected: Bool,
                                buttonTitle: String,
                                action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: symbol)
                    .font(.system(size: 16, weight: .bold))
                    .frame(width: 36, height: 36)
                    .background(FlowUI.controlFill, in: RoundedRectangle(cornerRadius: 10))
                Spacer()
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(FlowUI.success)
                }
            }
            Text(title)
                .font(.system(size: 20, weight: .bold))
            Text(price)
                .font(.system(size: 14, weight: .bold))
            FlowPlanFeatureList(detail: detail)
                .frame(maxWidth: .infinity, minHeight: 52, alignment: .topLeading)
            Button(action: action) {
                if cloudBusy {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Text(buttonTitle)
                }
            }
            .buttonStyle(FlowPrimaryButtonStyle(disabled: cloudBusy || (selected && cloudTier != "pro")))
            .disabled(cloudBusy || (selected && cloudTier != "pro"))
        }
        .padding(18)
        .frame(maxWidth: .infinity, minHeight: 248, alignment: .topLeading)
        .background(FlowUI.panel, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(selected ? FlowUI.success.opacity(0.7) : FlowUI.glassHairline)
        )
    }

    private var ready: some View {
        VStack(spacing: 24) {
            Spacer()
            OnboardingPillDemo()
                .frame(width: 380, height: 80)
            VStack(spacing: 10) {
                Text("You are ready")
                    .font(.system(size: 38, weight: .bold))
                Text("Click into any text field, hold \(coordinator.settings.pushToTalkHotkey.keycapLabel), speak, then release. The idle pill stays visible and click-through; it lights up while recording, processing, or reporting a result.")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 560)
            }
            Spacer()
        }
        .padding(44)
    }

    private var footer: some View {
        ZStack {
            HStack {
                navButton(title: "Back", symbol: "chevron.left", primary: false, disabled: step == .welcome) {
                    step = step.previous
                    refocusOnboardingWindow()
                }
                .frame(width: 112, alignment: .leading)
                Spacer()
                navButton(title: step == .ready ? "Finish" : "Continue",
                          symbol: step == .ready ? "checkmark" : "arrow.right",
                          primary: true,
                          disabled: !canContinue) {
                    if step == .ready {
                        onComplete()
                    } else {
                        step = step.next
                        refocusOnboardingWindow()
                    }
                }
                .frame(width: 138, alignment: .trailing)
            }
            Text(step.blockingMessage(permissionsReady: permissionsReady,
                                      hasAPIKey: hasAPIKey,
                                      hasCloudToken: cloudEntitled) ?? "")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 270)
        }
        .frame(height: 42)
    }

    private var canContinue: Bool {
        switch step {
        case .welcome, .tour:
            true
        case .permissions:
            permissionsReady
        case .key:
            hasAPIKey || cloudEntitled
        case .ready:
            true
        }
    }

    private var permissionsReady: Bool {
        coordinator.permissions.microphoneGranted
            && coordinator.permissions.accessibilityGranted
    }

    private var hasAPIKey: Bool {
        localKeyConfigured
    }

    private var hasCloudToken: Bool {
        guard let token = try? KeychainService.shared.cloudSessionToken() else { return false }
        return !token.isEmpty
    }

    private func onboardingPage<Content: View>(title: String, subtitle: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(FlowUI.ink)
                    .tracking(-0.25)
                Text(subtitle)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 585, alignment: .leading)
            }
            .frame(height: 88, alignment: .topLeading)

            content()
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .padding(.horizontal, 44)
        .padding(.top, 42)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func welcomeFeature(_ title: String, _ symbol: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(FlowUI.ink.opacity(0.9))
                .frame(width: 30, height: 30)
                .background(FlowUI.controlFill, in: RoundedRectangle(cornerRadius: 9, style: .continuous))

            Text(title)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(FlowUI.ink)
                .lineLimit(1)

            Text(detail)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 142, maxHeight: 142, alignment: .topLeading)
        .background(FlowUI.panel, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(FlowUI.glassHairline))
    }

    private func tourStep(number: String,
                          title: String,
                          detail: String,
                          symbol: String,
                          preview: AnyView) -> some View {
        HStack(spacing: 18) {
            Text(number)
                .font(.system(size: 11, weight: .black))
                .monospacedDigit()
                .foregroundStyle(FlowUI.ink.opacity(0.48))
                .frame(width: 22)

            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(FlowUI.ink)
                .frame(width: 42, height: 42)
                .background(FlowUI.controlFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(FlowUI.ink)
                Text(detail)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 14)

            preview
                .frame(width: 118, height: 38)
        }
        .padding(.horizontal, 18)
        .frame(height: 104)
        .background(FlowUI.panel, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(FlowUI.glassHairline))
    }

    private func planBenefit(_ title: String, _ detail: String, _ symbol: String) -> some View {
        HStack(spacing: 13) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(FlowUI.ink.opacity(0.86))
                .frame(width: 30, height: 30)
                .background(FlowUI.controlFill, in: RoundedRectangle(cornerRadius: 9, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(FlowUI.ink)
                Text(detail)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(.vertical, 10)
    }

    private func compactPlanBenefit(_ title: String, _ symbol: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 24, height: 24)
                .background(FlowUI.mutedFill, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            Text(title)
                .font(.system(size: 12, weight: .bold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, minHeight: 42)
        .background(FlowUI.controlFill, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(FlowUI.glassHairline))
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
                    cloudStatus = "Connected\(user.email.map { " as \($0)" } ?? ""). Checking plan..."
                    refocusOnboardingWindow()
                }
                await refreshCloudEntitlementAsync()
                coordinator.refreshAccountState()
            } catch {
                await MainActor.run {
                    cloudStatus = cloudMessage(for: error)
                    refocusOnboardingWindow()
                }
            }
        }
    }

    private func startCloudSubscribe() {
        guard !cloudBusy else { return }
        guard let baseURL = URL(string: coordinator.settings.cloudBaseURL) else {
            cloudStatus = "Set the openflow Pro service URL in Settings first."
            return
        }
        cloudBillingInFlight = true
        cloudStatus = hasCloudToken ? "Opening checkout..." : "Opening secure sign in..."
        Task {
            defer {
                Task { @MainActor in
                    cloudBillingInFlight = false
                }
            }
            do {
                if !hasCloudToken {
                    _ = try await cloudAuth.connectDevice { code in
                        cloudStatus = "Confirm code \(code) in your browser."
                    }
                }
                let url = try await checkoutURLRecoveringAuthentication(baseURL: baseURL)
                await MainActor.run {
                    CloudURLPolicy.openExternal(url)
                    cloudStatus = "Checkout opened. Return here when you are finished."
                    refocusOnboardingWindow()
                }
                coordinator.refreshAccountState()
            } catch OpenflowError.cloudSubscriptionAlreadyActive {
                await refreshCloudEntitlementAsync()
                await MainActor.run {
                    refocusOnboardingWindow()
                }
            } catch {
                await MainActor.run {
                    cloudStatus = cloudMessage(for: error)
                    refocusOnboardingWindow()
                }
            }
        }
    }

    private func openCloudPortal() {
        guard let baseURL = URL(string: coordinator.settings.cloudBaseURL) else {
            cloudStatus = "The billing service is unavailable."
            return
        }
        cloudStatus = "Opening billing..."
        Task {
            do {
                let url = try await cloudService.portalURL(baseURL: baseURL)
                await MainActor.run {
                    CloudURLPolicy.openExternal(url)
                    cloudStatus = "Billing opened."
                    refocusOnboardingWindow()
                }
            } catch {
                await MainActor.run {
                    cloudStatus = cloudMessage(for: error)
                    refocusOnboardingWindow()
                }
            }
        }
    }

    private func checkoutURLRecoveringAuthentication(baseURL: URL) async throws -> URL {
        do {
            return try await cloudService.checkoutURL(baseURL: baseURL)
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
            return try await cloudService.checkoutURL(baseURL: baseURL)
        }
    }

    private func refreshCloudEntitlement() {
        guard hasCloudToken, !checkingCloudEntitlement else {
            if !hasCloudToken {
                cloudEntitled = false
            }
            return
        }
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
                cloudEntitled = entitlement.canUseCloud
                cloudTier = entitlement.tier
                coordinator.cloudTier = entitlement.tier
                cloudWordsRemaining = entitlement.wordsRemaining
                cloudWordLimit = entitlement.wordLimit
                checkingCloudEntitlement = false
                if coordinator.hasAPIKey() {
                    coordinator.settings.providerMode = .localGroq
                    cloudStatus = "Using your Groq key."
                } else if entitlement.canUseCloud {
                    coordinator.settings.providerMode = .openflowCloud
                    cloudStatus = entitlement.cancelAtPeriodEndDescription
                } else {
                    cloudStatus = "Connect your account to use openflow."
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
                cloudEntitled = false
                cloudTier = nil
                coordinator.cloudTier = nil
                checkingCloudEntitlement = false
                cloudStatus = cloudMessage(for: statusError)
            }
        }
    }

    private func isRecoverableCloudAuthError(_ error: Error) -> Bool {
        if case OpenflowError.cloudAuthenticationRequired = error { return true }
        if case OpenflowError.cloudSessionRevoked = error { return true }
        return false
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

    private func feature(_ title: String, _ caption: String, _ symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 38, height: 38)
                 .background(FlowUI.ink, in: RoundedRectangle(cornerRadius: 8))
            Text(title)
                .font(.system(size: 17, weight: .bold))
            Text(caption)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .frame(maxWidth: .infinity, minHeight: 140, maxHeight: 140, alignment: .leading)
        .background(FlowUI.panel, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(FlowUI.glassHairline))
    }

    private func permissionCard(title: String, caption: String, granted: Bool, symbol: String, actionTitle: String = "Enable", action: @escaping () -> Void) -> some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(granted ? FlowUI.success : FlowUI.mutedFill)
                Image(systemName: granted ? "checkmark" : symbol)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(granted ? Color.black.opacity(0.86) : FlowUI.ink.opacity(0.78))
            }
            .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 16, weight: .bold))
                Text(caption)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            permissionActionButton(granted: granted, actionTitle: actionTitle, action: action)
        }
        .padding(.horizontal, 16)
        .frame(height: 82)
        .background(FlowUI.panel, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(FlowUI.glassHairline))
    }

    private func permissionActionButton(granted: Bool, actionTitle: String, action: @escaping () -> Void) -> some View {
        Button(action: granted ? {} : action) {
            HStack(spacing: 7) {
                Image(systemName: granted ? "checkmark" : "arrow.up.right")
                    .font(.system(size: 12, weight: .bold))
                Text(granted ? "Granted" : actionTitle)
                    .font(.system(size: 13, weight: .bold))
            }
            .foregroundStyle(granted ? FlowUI.success : FlowUI.ink.opacity(0.9))
            .padding(.horizontal, 14)
            .frame(height: 32)
            .background(granted ? FlowUI.success.opacity(0.16) : FlowUI.controlFill, in: Capsule())
            .overlay(Capsule().stroke(granted ? FlowUI.success.opacity(0.38) : FlowUI.glassHairline))
        }
        .buttonStyle(.plain)
        .disabled(granted)
    }

    private func cloudBenefit(_ title: String, _ symbol: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(FlowUI.ink.opacity(0.82))
            Text(title)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(FlowUI.ink.opacity(0.84))
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(FlowUI.mutedFill, in: Capsule())
        .overlay(Capsule().stroke(FlowUI.glassHairline.opacity(0.7)))
    }

    private func navButton(title: String, symbol: String, primary: Bool, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if !primary {
                    Image(systemName: symbol)
                        .font(.system(size: 12, weight: .bold))
                }
                Text(title)
                    .font(.system(size: 14, weight: .bold))
                if primary {
                    Image(systemName: symbol)
                        .font(.system(size: 12, weight: .bold))
                }
            }
            .foregroundStyle(primary ? Color.black.opacity(0.88) : FlowUI.ink)
            .padding(.horizontal, 18)
            .frame(height: 40)
            .background(primary ? FlowUI.ink : FlowUI.controlFill, in: Capsule())
            .overlay(Capsule().stroke(primary ? Color.clear : FlowUI.glassHairline))
            .shadow(color: primary ? .black.opacity(0.16) : .clear, radius: 10, x: 0, y: 5)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.36 : 1)
    }

    private func flowChip(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 13, weight: .bold))
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(FlowUI.panel, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(FlowUI.glassHairline))
    }

    private var flowArrow: some View {
        Image(systemName: "arrow.right")
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(.secondary)
    }

    private func refocusOnboardingWindow() {
        OpenflowHubWindowRestorer.restoreIfSafe()
    }
}

private struct TourFlowPanel: View {
    let animate: Bool
    let hotkeyLabel: String

    var body: some View {
        HStack(spacing: 18) {
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Color.white.opacity(0.055))
                    .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(FlowUI.glassHairline.opacity(0.85)))

                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 7) {
                        Circle().fill(Color.red.opacity(0.75)).frame(width: 8, height: 8)
                        Circle().fill(Color.yellow.opacity(0.8)).frame(width: 8, height: 8)
                        Circle().fill(Color.green.opacity(0.72)).frame(width: 8, height: 8)
                        Spacer()
                        Text("Messages")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 9) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(FlowUI.controlFill)
                            .frame(width: 132, height: 9)
                        Text("Thanks for this. I’ll review it this afternoon and send notes by the end of the day.")
                            .font(.system(size: 15, weight: .semibold))
                            .lineSpacing(4)
                            .foregroundStyle(FlowUI.ink.opacity(0.9))
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 0) {
                            Text("Best,")
                            Rectangle()
                                .fill(FlowUI.ink)
                                .frame(width: 2, height: 18)
                                .opacity(animate ? 0.25 : 1)
                                .animation(.easeInOut(duration: 0.72).repeatForever(autoreverses: true), value: animate)
                        }
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(FlowUI.ink.opacity(0.9))
                    }

                    Spacer()
                }
                .padding(20)

                VStack(spacing: 7) {
                    TourWaveform(animate: animate)
                    Text("Polished")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .frame(height: 24)
                        .background(Color.black.opacity(0.82), in: Capsule())
                }
                .padding(.bottom, 18)
            }
            .frame(width: 318)

            VStack(spacing: 12) {
                TourTimelineRow(number: "1",
                                title: "Hold \(hotkeyLabel)",
                                detail: "The recorder appears instantly.",
                                symbol: "keyboard")
                TourTimelineRow(number: "2", title: "Speak freely", detail: "Names and corrections stay intact.", symbol: "waveform")
                TourTimelineRow(number: "3", title: "Release", detail: "Text lands in the focused field.", symbol: "checkmark")
            }
            .frame(maxWidth: .infinity)
        }
        .padding(18)
        .background(FlowUI.panel.opacity(0.74), in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).stroke(FlowUI.glassHairline.opacity(0.82)))
    }
}

private struct TourWaveform: View {
    let animate: Bool

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<10, id: \.self) { index in
                Capsule()
                    .fill(Color.white.opacity(index % 3 == 0 ? 0.95 : 0.68))
                    .frame(width: 4, height: animate ? CGFloat(8 + ((index * 7) % 18)) : 8)
                    .animation(.easeInOut(duration: 0.42 + Double(index) * 0.018).repeatForever(autoreverses: true), value: animate)
            }
        }
        .frame(width: 118, height: 34)
        .background(.black.opacity(0.9), in: Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.15), lineWidth: 1))
    }
}

private struct TourTimelineRow: View {
    let number: String
    let title: String
    let detail: String
    let symbol: String

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(FlowUI.ink.opacity(0.1))
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(FlowUI.ink)
            }
            .frame(width: 38, height: 38)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Text(number)
                        .font(.system(size: 10, weight: .black))
                        .foregroundStyle(FlowUI.ink.opacity(0.72))
                        .monospacedDigit()
                    Text(title)
                        .font(.system(size: 14, weight: .bold))
                        .lineLimit(1)
                }
                Text(detail)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .frame(height: 96)
        .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(FlowUI.glassHairline.opacity(0.65)))
    }
}

private enum OnboardingStep: Int, CaseIterable, Identifiable {
    case welcome
    case tour
    case permissions
    case key
    case ready

    var id: Int { rawValue }
    var index: Int { rawValue }

    var railTitle: String {
        switch self {
        case .welcome: "Welcome"
        case .tour: "Tour"
        case .permissions: "Permissions"
        case .key: "Plan"
        case .ready: "Ready"
        }
    }

    var railCaption: String {
        switch self {
        case .welcome: "Meet the flow"
        case .tour: "What it does"
        case .permissions: "Required access"
        case .key: "Pro or API key"
        case .ready: "Try it anywhere"
        }
    }

    var next: OnboardingStep {
        OnboardingStep(rawValue: min(rawValue + 1, Self.allCases.count - 1)) ?? .ready
    }

    var previous: OnboardingStep {
        OnboardingStep(rawValue: max(rawValue - 1, 0)) ?? .welcome
    }

    func blockingMessage(permissionsReady: Bool, hasAPIKey: Bool, hasCloudToken: Bool = false) -> String? {
        switch self {
        case .permissions where !permissionsReady:
            "Enable all permissions to continue"
        default:
            nil
        }
    }
}

private struct StaticFlowMark: View {
    var body: some View {
        ZStack {
            OpenflowGlyph()
                .frame(width: 112, height: 72)
        }
    }
}

private struct BringYourOwnKeySheet: View {
    @Binding var apiKey: String
    let hasAPIKey: Bool
    let onRemove: () -> Void
    let onSave: (String) throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var isValidating = false
    @State private var validationError: String?
    @State private var validationSucceeded = false
    private let validator = GroqAPIKeyValidator()

    private var trimmedKey: String {
        apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(FlowUI.controlFill)
                    Image(systemName: "key.fill")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(FlowUI.ink)
                }
                .frame(width: 44, height: 44)

                VStack(alignment: .leading, spacing: 3) {
                    Text(hasAPIKey ? "Update Groq key" : "Bring your own key")
                        .font(.system(size: 22, weight: .black))
                        .foregroundStyle(FlowUI.ink)
                    Text("Stored locally in macOS Keychain.")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }

            FlowNativeTextField(placeholder: hasAPIKey ? "Paste a replacement key" : "gsk_...",
                                text: $apiKey,
                                isSecure: true,
                                fontSize: 14,
                                weight: .semibold,
                                insets: NSEdgeInsets(top: 0, left: 14, bottom: 0, right: 14))
                .frame(height: 44)
                .background(FlowUI.mutedFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(FlowUI.glassHairline))
                .disabled(isValidating)

            if validationSucceeded {
                Label("Groq key verified and saved.", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(FlowUI.success)
            } else if let validationError {
                Label(validationError, systemImage: "exclamationmark.circle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.red.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("Local mode sends audio and cleanup requests directly from this Mac to Groq using your key.")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                if hasAPIKey {
                    Button("Remove key") {
                        onRemove()
                        dismiss()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color.red.opacity(0.9))
                    .frame(width: 100, height: 38)
                    .background(FlowUI.controlFill, in: Capsule())
                    .overlay(Capsule().stroke(FlowUI.glassHairline))
                }

                Button("Cancel") {
                    apiKey = ""
                    dismiss()
                }
                .buttonStyle(.plain)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(FlowUI.ink.opacity(0.82))
                .frame(width: 92, height: 38)
                .background(FlowUI.controlFill, in: Capsule())
                .overlay(Capsule().stroke(FlowUI.glassHairline))

                Spacer()

                Button {
                    validateAndSave()
                } label: {
                    HStack(spacing: 7) {
                        if isValidating {
                            ProgressView()
                                .controlSize(.small)
                                .tint(Color.black.opacity(0.9))
                        }
                        Text(validationSucceeded
                             ? "Verified"
                             : (isValidating ? "Checking" : (hasAPIKey ? "Update key" : "Save key")))
                    }
                }
                .buttonStyle(.plain)
                .font(.system(size: 13, weight: .black))
                .foregroundStyle(Color.black.opacity(0.9))
                .frame(width: 116, height: 38)
                .background(FlowUI.ink, in: Capsule())
                .disabled(trimmedKey.isEmpty || isValidating || validationSucceeded)
                .opacity(trimmedKey.isEmpty || isValidating ? 0.55 : 1)
            }
        }
        .padding(24)
        .background(FlowWindowBackdrop())
    }

    private func validateAndSave() {
        validationError = nil
        validationSucceeded = false
        isValidating = true
        Task {
            do {
                try await validator.validate(trimmedKey)
                try onSave(trimmedKey)
                apiKey = ""
                isValidating = false
                validationSucceeded = true
                try? await Task.sleep(for: .milliseconds(550))
                dismiss()
            } catch {
                validationError = (error as? LocalizedError)?.errorDescription
                    ?? "The Groq key could not be verified."
                isValidating = false
            }
        }
    }
}

private struct CloudConnectSheet: View {
    @Binding var code: String
    let status: String
    let onOpenLogin: () -> Void
    let onConnect: () -> Void
    @Environment(\.dismiss) private var dismiss

    private var trimmedCode: String {
        code.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "person.crop.circle.badge.checkmark")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(FlowUI.ink)
                    .frame(width: 44, height: 44)
                    .background(FlowUI.controlFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    Text("Connect openflow Pro")
                        .font(.system(size: 21, weight: .bold))
                    Text("Sign in, then paste the one-time code.")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }

            Button("Open secure sign in") {
                onOpenLogin()
            }
            .buttonStyle(FlowSecondaryButtonStyle())

            FlowNativeTextField(placeholder: "One-time code",
                                text: $code,
                                fontSize: 14,
                                weight: .semibold,
                                insets: NSEdgeInsets(top: 0, left: 14, bottom: 0, right: 14))
                .frame(height: 44)
                .background(FlowUI.mutedFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(FlowUI.glassHairline))

            Text(status)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .buttonStyle(FlowSecondaryButtonStyle())

                Spacer()

                Button("Connect") {
                    onConnect()
                    dismiss()
                }
                .buttonStyle(FlowPrimaryButtonStyle())
                .disabled(trimmedCode.isEmpty)
                .opacity(trimmedCode.isEmpty ? 0.4 : 1)
            }
        }
        .padding(24)
        .background(FlowWindowBackdrop())
    }
}

private struct OnboardingPillDemo: View {
    @StateObject private var viewModel = FloatingPillViewModel()
    @State private var cycleTask: Task<Void, Never>?
    @State private var levelPhase = false

    var body: some View {
        FloatingPillView(viewModel: viewModel,
                         startContinuous: {},
                         stopRecording: {},
                         openSettings: {},
                         forceDarkBase: true)
            .allowsHitTesting(false)
            .scaleEffect(1.05)
            .onAppear {
                syncAppearance()
                startCycle()
            }
            .onDisappear {
                cycleTask?.cancel()
            }
    }

    private func syncAppearance() {
        viewModel.glassIntensity = 1.0
        viewModel.tintStrength = 1.0
        viewModel.tintColorHex = "#000000"
        viewModel.inactiveOpacity = 0.72
    }

    private func startCycle() {
        cycleTask?.cancel()
        cycleTask = Task { @MainActor in
            while !Task.isCancelled {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                    viewModel.state = .idle
                    viewModel.level = 0
                }
                try? await Task.sleep(nanoseconds: 650_000_000)

                withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                    viewModel.state = .recording
                }
                for tick in 0..<18 {
                    guard !Task.isCancelled else { return }
                    let wave = 0.28 + 0.55 * abs(sin(Double(tick) * 0.72))
                    viewModel.level = Float(wave)
                    try? await Task.sleep(nanoseconds: 95_000_000)
                }

                withAnimation(.easeInOut(duration: 0.18)) {
                    viewModel.state = .processing
                    viewModel.level = 0.04
                }
                try? await Task.sleep(nanoseconds: 900_000_000)

                withAnimation(.spring(response: 0.24, dampingFraction: 0.78)) {
                    viewModel.state = .success
                }
                try? await Task.sleep(nanoseconds: 700_000_000)
            }
        }
    }
}
