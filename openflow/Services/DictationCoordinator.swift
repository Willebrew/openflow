import AppKit
import AudioToolbox
import AVFAudio
import Combine
import os
import SwiftUI

@MainActor
final class DictationCoordinator: ObservableObject {
    /// Views do not observe the coordinator itself. They observe the focused
    /// stores below, so a publish only re-renders the pages that display that
    /// state. The coordinator stays an ObservableObject purely so it can keep
    /// flowing through the environment as the shared service locator.
    let pillViewModel = FloatingPillViewModel()
    let settings = UserSettings()
    let permissions = PermissionsService()
    let history = HistoryService()
    let credentials = CredentialStore()
    let cloudAccount = CloudAccountStore()
    let audioRoute = AudioRouteStore()
    let diagnostics = DiagnosticsStore()
    let homeStats = HomeStatsStore()

    private let audio = AudioCaptureService()
    private let hotkeys = HotkeyService()
    private let transcription = TranscriptionService()
    private let cleanup = CleanupFormattingService()
    private let context = ContextService()
    private let insertion = TextInsertionService()
    private let insertionDiagnostics = InsertionDiagnosticsService()
    private let cloud = OpenFlowCloudService()
    private let cloudAuth = CloudAuthService()
    private var sessionValidationInFlight = false
    private var lastMenuRevalidateAt: Date?
    private var sessionRefreshTimer: Timer?
    private var sessionObservers: [NSObjectProtocol] = []
    private var sessionLaunchCheck: Task<Void, Never>?
    private lazy var floatingWindow = FloatingDictationWindow(viewModel: pillViewModel)
    private var session: DictationSession?
    private var processingSessionID: UUID?
    private var recordingWarningTask: Task<Void, Never>?
    private var recordingLimitTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()
    private var applyingCloudPreferences = false
    private var hasStarted = false
    private var hotkeysArmed = false
    private let processStartDate = Date()
    private let staleAudioMinimumAge: TimeInterval = 5 * 60

    init() {
        audio.$inputLevel.assign(to: &pillViewModel.$level)
        audio.$inputRouteStatus.assign(to: &audioRoute.$inputRouteStatus)
        audio.onAudioUnavailable = { [weak self] message in
            Task { @MainActor in
                self?.handleAudioUnavailable(message)
            }
        }
        audio.onDiagnostic = { [weak self] message in
            Task { @MainActor in
                self?.log("audio: \(message)")
            }
        }
        permissions.objectWillChange
            .sink { [weak self] _ in
                self?.applyPillVisibility()
            }
            .store(in: &cancellables)
        Publishers.MergeMany(
            history.$items.map { _ in () }.eraseToAnyPublisher(),
            history.$lifetimeWords.map { _ in () }.eraseToAnyPublisher(),
            history.$lifetimeAudioSeconds.map { _ in () }.eraseToAnyPublisher(),
            history.$appStats.map { _ in () }.eraseToAnyPublisher(),
            cloudAccount.$stats.map { _ in () }.eraseToAnyPublisher(),
            credentials.$hasCloudSessionToken.map { _ in () }.eraseToAnyPublisher()
        )
        .sink { [weak self] _ in self?.pushHomeStatsInputs() }
        .store(in: &cancellables)
        settings.objectWillChange
            .debounce(for: .milliseconds(900), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                self?.pushCloudPreferences()
            }
            .store(in: &cancellables)
        settings.$hideInactivePill
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.applyPillVisibility()
            }
            .store(in: &cancellables)
        Publishers.Merge(settings.$pushToTalkHotkey, settings.$toggleHotkey)
            .dropFirst()
            .sink { [weak self] _ in
                self?.restartHotkeys()
            }
            .store(in: &cancellables)
        settings.$microphoneDeviceID
            .dropFirst()
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] deviceID in
                self?.audio.warmUp(deviceID: deviceID)
            }
            .store(in: &cancellables)
        audio.$availableMicrophones
            .receive(on: DispatchQueue.main)
            .sink { [weak self] devices in
                self?.audioRoute.availableMicrophones = devices
                self?.rematchSelectedMicrophone(devices)
            }
            .store(in: &cancellables)
        permissions.$microphoneGranted
            .dropFirst()
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] granted in
                guard granted, let self else { return }
                self.audio.warmUp(deviceID: self.settings.microphoneDeviceID)
                self.applyPillVisibility()
            }
            .store(in: &cancellables)
        permissions.$accessibilityGranted
            .dropFirst()
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.applyPillVisibility()
            }
            .store(in: &cancellables)
        pillViewModel.startContinuousRecording = { [weak self] in
            self?.beginDictation(mode: .dictation)
        }
        pillViewModel.stopRecording = { [weak self] in
            self?.endDictation()
        }
        pillViewModel.openSettings = { [weak self] in
            guard let self else { return }
            NSApp.activate(ignoringOtherApps: true)
            SettingsWindowController.shared.show(coordinator: self, selectedTab: .settings)
        }
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        credentials.refresh()
        pushHomeStatsInputs(immediate: true)
        removeStaleAudioFiles()
        permissions.refresh()
        permissions.startPolling()
        pillViewModel.state = .idle
        pillViewModel.subtitle = "Ready"
        configureHotkeys()
        applyPillVisibility()
        restartHotkeys()
        startCloudSessionMonitoring()
        runDictationInjectionIfRequested()
        sessionLaunchCheck = Task { [weak self] in
            await self?.validateStoredCloudSession()
            self?.refreshAccountState()
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.permissions.microphoneGranted {
                self.audio.warmUp(deviceID: self.settings.microphoneDeviceID)
            }
            self.transcription.warmUp(settings: self.settings)
        }
    }

    func availableInputDevices() -> [AudioInputDevice] {
        audio.availableMicrophones.isEmpty
            ? audio.availableMicrophonesSnapshot()
            : audio.availableMicrophones
    }

    private func rematchSelectedMicrophone(_ devices: [AudioInputDevice]) {
        let selected = settings.microphoneDeviceID
        guard !selected.isEmpty, !devices.contains(where: { $0.uid == selected }) else { return }
        let hint = UserDefaults.standard.string(forKey: AudioInputDeviceCatalog.nameHintDefaultsKey) ?? ""
        guard let match = AudioInputDeviceCatalog.resolveDevice(preferredUID: selected, nameHint: hint),
              match.uid != selected else { return }
        settings.microphoneDeviceID = match.uid
        log("audio: rematched microphone \(selected) -> \(match.uid) (\(match.name))")
    }

    private func configureHotkeys() {
        hotkeys.onBegin = { [weak self] mode, requestedAt in
            Self.runOnMain {
                self?.beginDictation(mode: mode, requestedAt: requestedAt)
            }
        }
        hotkeys.onEnd = { [weak self] in
            Self.runOnMain {
                self?.endDictation()
            }
        }
        hotkeys.onToggle = { [weak self] mode in
            Self.runOnMain {
                guard let self else { return }
                if self.session == nil && self.processingSessionID == nil {
                    self.beginDictation(mode: mode)
                } else if self.session != nil {
                    self.endDictation()
                }
            }
        }
        hotkeys.onAccessChanged = { [weak self] granted in
            Task { @MainActor in
                guard let self else { return }
                self.permissions.refresh()
                if !granted {
                    self.permissions.inputMonitoringGranted = false
                    self.log("hotkey event tap unavailable for \(self.settings.pushToTalkHotkey.label)")
                }
            }
        }
    }

    private nonisolated static func runOnMain(_ work: @escaping @MainActor () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                work()
            }
        } else {
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    work()
                }
            }
        }
    }

    private func restartHotkeys() {
        guard hasStarted else { return }
        guard isReadyToShowPill else {
            hotkeysArmed = false
            hotkeys.stop()
            return
        }
        hotkeysArmed = true
        hotkeys.start { [weak self] in
            self?.settings ?? UserSettings()
        }
    }

    func stop() {
        guard hasStarted else { return }
        hasStarted = false
        hotkeysArmed = false
        hotkeys.stop()
        permissions.stopPolling()
        sessionLaunchCheck?.cancel()
        sessionLaunchCheck = nil
        stopCloudSessionMonitoring()
        cancelRecordingLimit()
        audio.discard()
        history.flushPendingWrites()
    }

    func validateCloudSessionAtLaunch() async {
        if let sessionLaunchCheck {
            await sessionLaunchCheck.value
            return
        }
        await validateStoredCloudSession()
    }

    /// Accessory apps rarely become active until a window is shown. Menu-bar
    /// clicks call this so revoke is not gated on opening Flow Hub. Debounced
    /// so spam-clicking the menu does not storm NQL Auth. Introspect only.
    func revalidateStoredCloudSession() {
        let now = Date()
        if let last = lastMenuRevalidateAt,
           now.timeIntervalSince(last) < CloudSessionValidator.menuRevalidateInterval {
            return
        }
        lastMenuRevalidateAt = now
        Task { await validateStoredCloudSession() }
    }

    func applyRemoteCloudRevocation() {
        let hadToken = ((try? KeychainService.shared.cloudSessionToken()) ?? nil)?.isEmpty == false
        cloudAuth.signOut()
        credentials.setCloudSessionPresent(false)
        cloudAccount.stats = OpenFlowCloudStats()
        cloudAccount.tier = nil
        cloudAccount.sessionNotice = CloudSessionValidator.revokedUserMessage
        if hasAPIKey() {
            settings.providerMode = .localGroq
        }
        noteSetupReadinessChanged()
        if hadToken {
            NSLog("[openflow-session] signed out after nql-auth reported an inactive session")
            log("cloud session revoked remotely")
        }
        NotificationCenter.default.post(name: .openflowCloudSessionDidChange, object: nil)
    }

    /// Convex 401 is not proof the NQL Auth session is dead. Confirm with introspect.
    @discardableResult
    func confirmRemoteCloudRevocation() async -> Bool {
        switch await cloudAuth.validateStoredSession() {
        case .revoked:
            applyRemoteCloudRevocation()
            return true
        case .valid, .indeterminate:
            NSLog("[openflow-session] keeping cloud token; nql-auth did not report active:false")
            return false
        }
    }

    func beginDictation(mode: DictationMode, requestedAt: Date = Date()) {
        guard session == nil, processingSessionID == nil else { return }
        guard isReadyToShowPill else { return }
        guard permissions.microphoneGranted else {
            permissions.refresh()
            permissions.requestMicrophone()
            showError(OpenflowError.microphoneUnavailable)
            return
        }
        guard permissions.accessibilityGranted else {
            permissions.refresh()
            permissions.requestAccessibility()
            showError(OpenflowError.insertionFailed)
            return
        }
        let frontmostApp = NSWorkspace.shared.frontmostApplication
        do {
            let newSession = DictationSession(mode: mode)
            session = newSession
            pillViewModel.state = .recording
            pillViewModel.subtitle = "Listening"
            revealPill()
            let started = try audio.start(deviceID: settings.microphoneDeviceID)
            session?.metrics.hotkeyToRecordingStart = started.timeIntervalSince(requestedAt)
            AudioServicesPlaySystemSound(1104)
            transcription.warmUp(settings: settings)
            scheduleRecordingLimit(for: newSession.id)
            if audioRoute.inputRouteStatus.isFallback {
                pillViewModel.subtitle = "Using \(audioRoute.inputRouteStatus.activeName)"
                log(audioRoute.inputRouteStatus.message ?? "selected microphone unavailable; using system default")
            }
            log("recording started in \(ms(session?.metrics.hotkeyToRecordingStart ?? 0))")
            attachSessionContext(sessionID: newSession.id, frontmostApp: frontmostApp)
        } catch {
            showError(error)
        }
    }

    /// The AX capture hops off the main thread so a slow frontmost app can
    /// never stall hotkey handling; the session fields are committed back on
    /// the main actor once the snapshot lands.
    private func attachSessionContext(sessionID: UUID, frontmostApp: NSRunningApplication?) {
        guard session?.id == sessionID else { return }
        let contextService = context
        let currentSettings = settings
        let contextInput = ContextCaptureInput(settings: currentSettings)
        Task.detached(priority: .userInitiated) { [weak self] in
            let contextSnapshot = contextService.captureSnapshot(input: contextInput,
                                                                 activeApplication: frontmostApp,
                                                                 searchDescendants: false)
            await MainActor.run {
                guard let self, self.session?.id == sessionID else { return }
                self.log("context route: app=\(contextSnapshot.context.activeAppName), category=\(contextSnapshot.context.category.rawValue), canInsert=\(contextSnapshot.canInsertText), fieldBefore=\(contextSnapshot.context.textBefore?.count ?? 0), fieldAfter=\(contextSnapshot.context.textAfter?.count ?? 0))")
                self.session?.context = contextSnapshot.context
                self.session?.focusedElement = contextSnapshot.element
                self.session?.focusedWindow = contextSnapshot.focusedWindow
                self.session?.targetProcessIdentifier = contextSnapshot.processIdentifier
                self.session?.targetCanInsertText = contextSnapshot.canInsertText
                self.session?.selectedRange = contextSnapshot.selectedRange
                self.session?.metrics.activeApp = contextSnapshot.context.activeAppName
                self.session?.metrics.category = contextSnapshot.context.category
                self.session?.metrics.contextAvailable = true
            }
        }
    }

    func refreshAccountState() {
        guard let baseURL = URL(string: settings.cloudBaseURL) else { return }
        guard credentials.hasCloudSessionToken else {
            credentials.setCloudSessionPresent(false)
            cloudAccount.stats = OpenFlowCloudStats()
            cloudAccount.tier = nil
            return
        }
        credentials.setCloudSessionPresent(true)
        Task {
            do {
                async let preferences = cloud.preferences(baseURL: baseURL)
                async let stats = cloud.stats(baseURL: baseURL)
                async let entitlement = cloud.entitlement(baseURL: baseURL)
                let (remotePreferences, remoteStats, remoteEntitlement) = try await (
                    preferences,
                    stats,
                    entitlement
                )
                cloudAccount.tier = remoteEntitlement.tier
                applyingCloudPreferences = true
                if let remotePreferences {
                    settings.applyCloudSnapshot(remotePreferences)
                } else {
                    try await cloud.savePreferences(settings.cloudSnapshot(), baseURL: baseURL)
                }
                applyingCloudPreferences = false
                applyCloudStats(remoteStats)
            } catch {
                applyingCloudPreferences = false
                if await consumeCloudSessionError(error) { return }
                log("account sync unavailable: \(error.localizedDescription)")
            }
        }
    }

    /// Feeds the Home/Apps snapshot builder with fresh inputs; the store
    /// debounces bursts and computes off the main thread.
    private func pushHomeStatsInputs(immediate: Bool = false) {
        homeStats.update(
            input: HomeStatsInput(
                preferCloud: credentials.hasCloudSessionToken,
                items: history.items,
                lifetimeWords: history.lifetimeWords,
                lifetimeAudioSeconds: history.lifetimeAudioSeconds,
                appStats: history.appStats,
                cloudStats: cloudAccount.stats ?? OpenFlowCloudStats()
            ),
            immediate: immediate
        )
    }

    private func startCloudSessionMonitoring() {
        guard sessionObservers.isEmpty else { return }
        let active = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.validateStoredCloudSession()
            }
        }
        let wake = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.validateStoredCloudSession()
            }
        }
        let screensWake = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.validateStoredCloudSession()
            }
        }
        sessionObservers = [active, wake, screensWake]
        // scheduledTimer uses default mode and can stall in accessory until a
        // window appears. Match PermissionsService: Timer + .common.
        let timer = Timer(
            timeInterval: CloudSessionValidator.refreshInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.validateStoredCloudSession()
            }
        }
        timer.tolerance = 60
        RunLoop.main.add(timer, forMode: .common)
        sessionRefreshTimer = timer
    }

    private func stopCloudSessionMonitoring() {
        sessionRefreshTimer?.invalidate()
        sessionRefreshTimer = nil
        for observer in sessionObservers {
            NotificationCenter.default.removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        sessionObservers = []
    }

    private func validateStoredCloudSession() async {
        guard !sessionValidationInFlight else { return }
        sessionValidationInFlight = true
        defer { sessionValidationInFlight = false }
        switch await cloudAuth.validateStoredSession() {
        case .valid, .indeterminate:
            return
        case .revoked:
            applyRemoteCloudRevocation()
        }
    }

    @discardableResult
    private func consumeCloudSessionError(_ error: Error) async -> Bool {
        if let openflowError = error as? OpenflowError, openflowError.isCloudSessionRevoked {
            _ = await confirmRemoteCloudRevocation()
            return true
        }
        if case OpenflowError.cloudAuthenticationRequired = error {
            cloudAccount.stats = OpenFlowCloudStats()
            cloudAccount.tier = nil
            return true
        }
        return false
    }

    private func applyCloudStats(_ stats: OpenFlowCloudStats) {
        let merged = (cloudAccount.stats ?? OpenFlowCloudStats()).mergingIncoming(stats)
        cloudAccount.stats = merged
        history.adoptLifetimeHighWater(
            words: merged.lifetimeWords,
            audioSeconds: merged.lifetimeAudioSeconds
        )
        history.adoptAppHighWater(
            (merged.apps ?? []).map {
                HomeAppStat(
                    appName: $0.appName,
                    bundleID: $0.bundleID,
                    words: $0.words,
                    audioSeconds: $0.audioSeconds ?? 0
                )
            }
        )
    }

    private func refreshCloudStats() {
        Task {
            await refreshCloudStatsIfSignedIn()
        }
    }

    @discardableResult
    private func refreshCloudStatsIfSignedIn() async -> Bool {
        guard let baseURL = URL(string: settings.cloudBaseURL),
              let token = try? KeychainService.shared.cloudSessionToken(),
              !token.isEmpty else { return false }
        do {
            applyCloudStats(try await cloud.stats(baseURL: baseURL))
            return true
        } catch {
            if await consumeCloudSessionError(error) { return false }
            log("stats refresh unavailable: \(error.localizedDescription)")
            return false
        }
    }

    private func pushCloudPreferences() {
        guard !applyingCloudPreferences,
              let baseURL = URL(string: settings.cloudBaseURL) else { return }
        let snapshot = settings.cloudSnapshot()
        Task {
            do {
                try await cloud.savePreferences(snapshot, baseURL: baseURL)
            } catch {
                if await consumeCloudSessionError(error) { return }
                log("preference sync failed: \(error.localizedDescription)")
            }
        }
    }

    @discardableResult
    private func syncLocalProviderActivityIfNeeded(id: UUID,
                                                   text: String,
                                                   audioSeconds: Double,
                                                   audioBytes: Int,
                                                   timestamp: Date,
                                                   provider: String,
                                                   appName: String?,
                                                   bundleID: String?) async -> Bool {
        guard !provider.contains("openflow-pro"),
              let baseURL = URL(string: settings.cloudBaseURL) else { return false }
        let words = text.split(whereSeparator: \.isWhitespace).count
        do {
            try await cloud.recordActivity(
                id: id,
                words: words,
                audioSeconds: audioSeconds,
                audioBytes: audioBytes,
                timestamp: timestamp,
                baseURL: baseURL,
                targetApp: appName,
                bundleID: bundleID
            )
            applyCloudStats(try await cloud.stats(baseURL: baseURL))
            return true
        } catch {
            if await consumeCloudSessionError(error) { return false }
            log("activity sync failed: \(error.localizedDescription)")
            return false
        }
    }

    func endDictation() {
        guard var activeSession = session else { return }
        cancelRecordingLimit()
        session = nil
        processingSessionID = activeSession.id
        hotkeys.markStopped()
        OpenflowSignpost.beginDictationPipeline()
        activeSession.endedAt = Date()
        pillViewModel.state = .processing
        pillViewModel.subtitle = "Polishing"

        Task { [self] in
            // Local refs captured on the main actor so the AX capture and the
            // capture-session teardown can hop off the main thread.
            let audio = self.audio
            let contextService = self.context
            let currentSettings = self.settings
            let contextInput = ContextCaptureInput(settings: currentSettings)
            var transcribedResult: TranscriptionResult?
            var formattingContext: FormattingContext
            if let capturedContext = activeSession.context {
                formattingContext = capturedContext
            } else {
                formattingContext = await Task.detached(priority: .userInitiated) {
                    contextService.capture(input: contextInput)
                }.value
            }
            do {
                let stopAt = Date()
                // Capture teardown stays on the calling actor and is fast; the
                // release chime must not play until capture has stopped. The
                // upload re-encode runs detached because it is the expensive part.
                let captured = try audio.stop()
                AudioServicesPlaySystemSound(1105)
                let prepared = try await Task.detached(priority: .userInitiated) {
                    try audio.prepareForUpload(captured)
                }.value
                defer {
                    try? FileManager.default.removeItem(at: captured.url)
                }
                defer {
                    if prepared.url != captured.url {
                        try? FileManager.default.removeItem(at: prepared.url)
                    }
                }
                activeSession.metrics.audioDuration = captured.duration
                activeSession.metrics.encodingTime = Date().timeIntervalSince(stopAt)
                log("audio gate passed: duration \(ms(captured.duration)), voiced \(ms(captured.voicedDuration)), peak \(String(format: "%.2f", captured.peakLevel)), avg \(String(format: "%.2f", captured.averageLevel))")

                latencyTrace("encode \(ms(activeSession.metrics.encodingTime)) wav \(prepared.url.lastPathComponent)")
                if let capturedContext = activeSession.context {
                    formattingContext = capturedContext
                } else {
                    formattingContext = await Task.detached(priority: .userInitiated) {
                        contextService.capture(input: contextInput)
                    }.value
                }
                applyResolvedStyle(to: &formattingContext)
                await refreshFieldText(into: &formattingContext, session: activeSession)
                let requestInlineCleanup = cleanup.styleRequiresRemoteCleanup(context: formattingContext)
                let transcribed = try await transcription.transcribe(
                    audioURL: prepared.url,
                    settings: settings,
                    needsCleanup: requestInlineCleanup,
                    cleanupContext: requestInlineCleanup
                        ? cloud.encodeCleanupContext(context: formattingContext, settings: settings)
                        : nil,
                    appName: formattingContext.activeAppName,
                    bundleID: formattingContext.bundleID
                )
                transcribedResult = transcribed
                log("raw transcript: \(transcribed.text)")
                activeSession.metrics.uploadAndTranscriptionTime = transcribed.requestTime
                activeSession.metrics.provider = transcribed.provider
                activeSession.metrics.model = transcribed.model
                activeSession.metrics.macToConvexMs = transcribed.macToConvexMs
                activeSession.metrics.convexUntilGroqStartMs = transcribed.convexUntilGroqStartMs
                activeSession.metrics.groqRoundTripMs = transcribed.groqRoundTripMs
                activeSession.metrics.convexToMacMs = transcribed.convexToMacMs
                activeSession.metrics.cerebrasRoundTripMs = transcribed.cerebrasRoundTripMs
                activeSession.metrics.cleanupAuthMs = transcribed.cleanupAuthMs
                activeSession.metrics.transcribeHopBreakdown = transcribed.hopBreakdown
                if let breakdown = transcribed.hopBreakdown {
                    latencyTrace(breakdown)
                } else if let tGroq = transcribed.tGroqHttp {
                    latencyTrace("whisper \(ms(transcribed.requestTime)) ticket \(ms(transcribed.tTicket ?? 0)) groq \(ms(tGroq)) receive \(ms(transcribed.tReceiveAudio ?? 0)) model \(transcribed.model) provider \(transcribed.provider)")
                } else {
                    latencyTrace("whisper \(ms(transcribed.requestTime)) model \(transcribed.model) provider \(transcribed.provider)")
                }

                try await finishInsertion(transcribed: transcribed,
                                          session: activeSession,
                                          formattingContext: formattingContext,
                                          captured: captured)
            } catch {
                guard processingSessionID == activeSession.id else { return }
                if case OpenflowError.noAudioCaptured(let reason) = error {
                    let wallMs = ms(Date().timeIntervalSince(activeSession.startedAt))
                    DiagnosticsLog.shared.write(
                        "ignored empty dictation: reason=\(reason ?? "n/a") wall=\(wallMs)")
                    log("ignored empty dictation: \(reason ?? "no voiced audio captured")")
                    OpenflowSignpost.endDictationPipeline(outcome: "no-audio")
                    processingSessionID = nil
                    diagnostics.currentMetrics = activeSession.metrics
                    resetPillToIdle()
                    pillViewModel.subtitle = "Ready"
                    applyPillVisibility()
                    return
                }
                _ = await consumeCloudSessionError(error)
                let stillSignedIn = ((try? KeychainService.shared.cloudSessionToken()) ?? nil)?.isEmpty == false
                if case OpenflowError.cloudSessionRevoked = error, stillSignedIn {
                    showError(
                        OpenflowError.cloudProviderUnavailable(
                            "Couldn’t connect to openflow right now. Please try again."
                        ),
                        sessionID: activeSession.id
                    )
                } else {
                    showError(error, sessionID: activeSession.id)
                }
                saveFailedDictationHistory(error: error,
                                           session: activeSession,
                                           transcript: transcribedResult,
                                           context: formattingContext)
            }
        }
    }

    /// Cleans up the transcript, inserts it, records metrics/history/stats,
    /// and drives the result pill. Shared by normal dictation and the
    /// launch-arg injection hook.
    private func finishInsertion(transcribed: TranscriptionResult,
                                 session: DictationSession,
                                 formattingContext: FormattingContext,
                                 captured: CapturedAudio) async throws {
        var activeSession = session
        let cleanupStarted = Date()
        let cleaned: CleanupResult
        let usedRemoteCleanup: Bool
        if transcribed.cleanupApplied {
            usedRemoteCleanup = false
            // The backend does not get to decide submission: applyLocalFormatters re-derives
            // pressEnter from the spoken transcript.
            var inline = CleanupResult(text: transcribed.cleanedText ?? transcribed.text,
                                       pressEnter: false,
                                       confidence: transcribed.confidence ?? 0.7,
                                       notes: transcribed.notes ?? "inline cerebras")
            inline = cleanup.applyLocalFormatters(to: inline,
                                                   context: formattingContext,
                                                   settings: settings,
                                                   rawTranscript: transcribed.text)
            cleaned = inline
        } else {
            usedRemoteCleanup = cleanup.requiresRemoteCleanup(rawTranscript: transcribed.text,
                                                              context: formattingContext,
                                                              settings: settings)
            if usedRemoteCleanup {
                cleaned = try await cleanup.clean(rawTranscript: transcribed.text, context: formattingContext, settings: settings)
            } else {
                cleaned = cleanup.fastClean(rawTranscript: transcribed.text, context: formattingContext, settings: settings)
            }
        }
        activeSession.metrics.cleanupTime = Date().timeIntervalSince(cleanupStarted)
        if let cerebrasMs = transcribed.cerebrasRoundTripMs, transcribed.cleanupApplied {
            latencyTrace("cerebrasRoundTripMs=\(cerebrasMs) cleanupAuthMs=\(transcribed.cleanupAuthMs ?? 0) localFormat \(ms(activeSession.metrics.cleanupTime)) style \(formattingContext.stylePreset.rawValue)")
        } else {
            latencyTrace("cleanup \(ms(activeSession.metrics.cleanupTime)) \(usedRemoteCleanup ? "remote gpt-oss" : "local-only") style \(formattingContext.stylePreset.rawValue)")
        }

        let insertionStarted = Date()
        let contextInput = ContextCaptureInput(settings: settings)
        let contextService = context
        let insertionSnapshot = await Task.detached(priority: .userInitiated) {
            contextService.captureSnapshot(input: contextInput)
        }.value
        if let originalPID = activeSession.targetProcessIdentifier,
           insertionSnapshot.processIdentifier != originalPID {
            let raceDescription = "started pid \(originalPID), current pid \(insertionSnapshot.processIdentifier.map(String.init) ?? "none")"
            activeSession.metrics.focusRaceDetected = true
            activeSession.metrics.focusRaceDescription = raceDescription
            log("focus race before insertion: \(raceDescription)")
        }
        if activeSession.focusedElement == nil, insertionSnapshot.canInsertText {
            activeSession.focusedElement = insertionSnapshot.element
            activeSession.focusedWindow = insertionSnapshot.focusedWindow
            activeSession.targetProcessIdentifier = insertionSnapshot.processIdentifier
            activeSession.targetCanInsertText = insertionSnapshot.canInsertText
            activeSession.selectedRange = insertionSnapshot.selectedRange
        }
        var finalText = applyPhrases(to: cleaned.text)
        let emptyFinalText = finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard !emptyFinalText || cleaned.pressEnter else {
            throw OpenflowError.transcriptionFailed("Groq returned an empty transcript.")
        }
        var insertionResult: InsertionResult
        if shouldUseCapturedElement(for: formattingContext.category),
           let focusedElement = activeSession.focusedElement {
            insertionResult = await insertion.insert(finalText,
                                                     into: focusedElement,
                                                     pressEnter: cleaned.pressEnter,
                                                     settings: settings,
                                                     category: formattingContext.category,
                                                     targetProcessIdentifier: activeSession.targetProcessIdentifier)
        } else {
            insertionResult = await insertion.insert(finalText,
                                                     pressEnter: cleaned.pressEnter,
                                                     settings: settings,
                                                     category: formattingContext.category,
                                                     targetProcessIdentifier: activeSession.targetProcessIdentifier)
        }
        if !insertionResult.succeeded,
           activeSession.metrics.focusRaceDetected == true,
           let focusRaceDescription = activeSession.metrics.focusRaceDescription {
            let existing = insertionResult.failureReason ?? "Unknown insertion failure"
            insertionResult.failureReason = "\(existing); focus race before insertion: \(focusRaceDescription)"
        }
        let succeeded = insertionResult.succeeded
        activeSession.metrics.insertionTime = Date().timeIntervalSince(insertionStarted)
        activeSession.metrics.insertionMethod = insertionResult.method.rawValue
        activeSession.metrics.insertionVerified = insertionResult.verified
        activeSession.metrics.insertionAttempts = insertionResult.attemptCount
        activeSession.metrics.insertionFailureReason = insertionResult.failureReason
        activeSession.metrics.totalTime = Date().timeIntervalSince(activeSession.startedAt)
        if !succeeded {
            DiagnosticsLog.shared.write(
                "dictation failed for \(formattingContext.activeAppName) / \(formattingContext.category.rawValue): \(insertionResult.failureReason ?? "unknown")")
            log("insertion failed for \(formattingContext.activeAppName) / \(formattingContext.category.rawValue): \(insertionResult.failureReason ?? "unknown")")
            insertionDiagnostics.writeFailedInsertion(result: insertionResult,
                                                      category: formattingContext.category,
                                                      metrics: activeSession.metrics)
        } else {
            log("inserted via \(insertionResult.method.rawValue), verified \(insertionResult.verified), attempts \(insertionResult.attemptCount)")
        }
        OpenflowSignpost.endDictationPipeline(outcome: succeeded ? "inserted" : "insert-failed")
        diagnostics.currentMetrics = activeSession.metrics

        history.add(DictationHistoryItem(timestamp: Date(),
                                         finalText: finalText,
                                         rawTranscript: transcribed.text,
                                         appName: formattingContext.activeAppName,
                                         bundleID: formattingContext.bundleID,
                                         category: formattingContext.category,
                                         stylePreset: formattingContext.stylePreset,
                                         insertionSucceeded: succeeded,
                                         insertion: insertionResult,
                                         metrics: activeSession.metrics),
                    settings: settings)
        history.recordLifetime(text: finalText,
                               audioSeconds: activeSession.metrics.audioDuration,
                               appName: formattingContext.activeAppName,
                               bundleID: formattingContext.bundleID)
        let audioBytes: Int = {
            if let size = try? FileManager.default.attributesOfItem(atPath: captured.url.path)[.size] as? NSNumber {
                return size.intValue
            }
            return 0
        }()
        let syncedLocalActivity = await syncLocalProviderActivityIfNeeded(
            id: activeSession.id,
            text: finalText,
            audioSeconds: activeSession.metrics.audioDuration,
            audioBytes: audioBytes,
            timestamp: Date(),
            provider: transcribed.provider,
            appName: formattingContext.activeAppName,
            bundleID: formattingContext.bundleID
        )
        if !syncedLocalActivity {
            _ = await refreshCloudStatsIfSignedIn()
        }
        let postRelease = activeSession.metrics.encodingTime
            + activeSession.metrics.uploadAndTranscriptionTime
            + activeSession.metrics.cleanupTime
            + activeSession.metrics.insertionTime
        latencyTrace("insert \(ms(activeSession.metrics.insertionTime)) via \(insertionResult.method.rawValue)")
        latencyTrace("post-release \(ms(postRelease)) encode \(ms(activeSession.metrics.encodingTime)) whisper \(ms(activeSession.metrics.uploadAndTranscriptionTime)) cleanup \(ms(activeSession.metrics.cleanupTime)) \(transcribed.cleanupApplied ? "inline-cerebras" : usedRemoteCleanup ? "remote" : "local") insert \(ms(activeSession.metrics.insertionTime)) app \(formattingContext.activeAppName) style \(formattingContext.stylePreset.rawValue) audio \(ms(activeSession.metrics.audioDuration)) hotkey \(ms(activeSession.metrics.hotkeyToRecordingStart))")
        log("done total \(ms(activeSession.metrics.totalTime)), groq \(ms(activeSession.metrics.uploadAndTranscriptionTime)), cleanup \(ms(activeSession.metrics.cleanupTime))")
        guard processingSessionID == activeSession.id else { return }
        pillViewModel.state = succeeded ? .success : .error("Insertion failed")
        pillViewModel.subtitle = succeeded ? "Inserted" : "Could not insert"
        revealPill()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) { [weak self] in
            guard let self, self.processingSessionID == activeSession.id else { return }
            self.processingSessionID = nil
            self.resetPillToIdle()
            self.pillViewModel.subtitle = "Ready"
            self.applyPillVisibility()
        }
    }

    private func shouldUseCapturedElement(for category: AppCategory) -> Bool {
        category != .terminal && category != .projectManagement
    }

    private func handleAudioUnavailable(_ message: String) {
        guard session != nil || processingSessionID != nil else { return }
        log("audio unavailable: \(message)")
        session = nil
        processingSessionID = nil
        cancelRecordingLimit()
        hotkeys.markStopped()
        pillViewModel.state = .error(message)
        pillViewModel.subtitle = message.localizedCaseInsensitiveContains("no audio") ? "No audio" : "Mic changed"
        revealPill()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in
            guard let self else { return }
            self.resetPillToIdle()
            self.pillViewModel.subtitle = "Ready"
            self.applyPillVisibility()
        }
    }

    func saveAPIKey(_ key: String) throws {
        let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        try KeychainService.shared.saveAPIKey(trimmedKey)
        guard try KeychainService.shared.apiKey() == trimmedKey else {
            KeychainService.shared.deleteAPIKey()
            credentials.setGroqKeyPresent(false)
            throw KeychainError.persistenceVerificationFailed
        }
        credentials.setGroqKeyPresent(true)
        log("saved and verified Groq API key in Keychain")
        settings.providerMode = .localGroq
        applyPillVisibility()
    }

    /// Cached credential presence: refreshed at launch and kept current on
    /// every save/delete/sign-in/sign-out. Safe to call from view bodies.
    func hasAPIKey() -> Bool {
        credentials.hasGroqKey
    }

    /// Deletes the stored Groq key and updates the cached presence flag.
    func deleteAPIKey() {
        KeychainService.shared.deleteAPIKey()
        credentials.setGroqKeyPresent(false)
        noteSetupReadinessChanged()
    }

    func canGenerateStyleWithOpenflow() -> Bool {
        OpenFlowProviderRouting.canGenerateStyleWithOpenflow(
            hasLocalGroqKey: hasAPIKey(),
            cloudTier: cloudAccount.tier
        )
    }

    /// Entitlement fetches hit the network, so callers (window open, tab
    /// visit, app activation) are throttled to one attempt per interval.
    private var lastEntitlementRefreshAt: Date?
    private static let entitlementRefreshInterval: TimeInterval = 300

    func refreshCloudEntitlement(force: Bool = false) async {
        if !force,
           let last = lastEntitlementRefreshAt,
           Date().timeIntervalSince(last) < Self.entitlementRefreshInterval {
            return
        }
        guard let baseURL = URL(string: settings.cloudBaseURL),
              let token = try? KeychainService.shared.cloudSessionToken(),
              !token.isEmpty else {
            cloudAccount.tier = nil
            return
        }
        lastEntitlementRefreshAt = Date()
        do {
            cloudAccount.tier = try await cloud.entitlement(baseURL: baseURL).tier
            credentials.setCloudSessionPresent(true)
        } catch {
            if await consumeCloudSessionError(error) { return }
            log("entitlement refresh unavailable: \(error.localizedDescription)")
        }
    }

    func hasConfiguredProvider() -> Bool {
        credentials.hasConfiguredProvider
    }

    func noteSetupReadinessChanged() {
        applyPillVisibility()
    }

    func refreshPillVisibility() {
        applyPillVisibility()
    }

    private func styleRef(for context: FormattingContext) -> StyleRef {
        let kind: UserSettings.StyleContextKind
        switch context.category {
        case .messages:
            kind = .personal
        case .email:
            kind = .email
        case .projectManagement, .docs, .aiChat:
            kind = .work
        default:
            kind = .other
        }
        return settings.resolvedStyleRef(kind: kind,
                                         appName: context.activeAppName,
                                         bundleID: context.bundleID)
    }

    private func refreshFieldText(into formattingContext: inout FormattingContext, session: DictationSession) async {
        let app = session.targetProcessIdentifier.flatMap { NSRunningApplication(processIdentifier: $0) }
        let contextService = context
        let currentSettings = settings
        let contextInput = ContextCaptureInput(settings: currentSettings)
        let snapshot = await Task.detached(priority: .userInitiated) {
            contextService.captureSnapshot(input: contextInput,
                                           activeApplication: app,
                                           searchDescendants: false)
        }.value
        contextService.mergeFieldText(from: snapshot, into: &formattingContext)
        log("field context: before=\(formattingContext.textBefore?.count ?? 0) after=\(formattingContext.textAfter?.count ?? 0) nearby=\(formattingContext.nearbyText?.count ?? 0)")
    }

    private func applyResolvedStyle(to context: inout FormattingContext) {
        let ref = styleRef(for: context)
        if let customID = ref.customID,
           let custom = settings.customStyles.first(where: { $0.id == customID }) {
            context.stylePreset = .auto
            context.customStyleName = custom.name
            context.customStylePrompt = custom.prompt
            return
        }
        context.stylePreset = ref.preset ?? .auto
        context.customStyleName = nil
        context.customStylePrompt = nil
    }

    private func applyPhrases(to text: String) -> String {
        var result = text
        for phrase in settings.phrases where !phrase.trigger.isEmpty {
            let trigger = phrase.trigger.trimmingCharacters(in: .whitespacesAndNewlines)
            if result.trimmingCharacters(in: CharacterSet(charactersIn: ".!? \n\t")).caseInsensitiveCompare(trigger) == .orderedSame {
                result = phrase.expansion
            } else {
                result = result.replacingOccurrences(of: trigger, with: phrase.expansion, options: [.caseInsensitive])
            }
        }
        return result
    }

    private func showError(_ error: Error, sessionID: UUID? = nil) {
        OpenflowSignpost.endDictationPipeline(outcome: "error")
        log("error: \(error.localizedDescription)")
        DiagnosticsLog.shared.write("error shown: \(String(describing: error))")
        cancelRecordingLimit()
        pillViewModel.state = .error(error.localizedDescription)
        pillViewModel.subtitle = error.localizedDescription
        revealPill()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in
            guard let self else { return }
            if let sessionID, self.processingSessionID != sessionID { return }
            self.processingSessionID = nil
            self.resetPillToIdle()
            self.pillViewModel.subtitle = "Ready"
            self.applyPillVisibility()
        }
        session = nil
    }

    private func saveFailedDictationHistory(error: Error,
                                            session: DictationSession,
                                            transcript: TranscriptionResult?,
                                            context: FormattingContext) {
        guard settings.historyEnabled else { return }
        var failedSession = session
        failedSession.metrics.totalTime = Date().timeIntervalSince(session.startedAt)
        failedSession.metrics.insertionMethod = InsertionMethod.none.rawValue
        failedSession.metrics.insertionVerified = false
        failedSession.metrics.insertionAttempts = 0
        failedSession.metrics.insertionFailureReason = error.localizedDescription
        if let transcript {
            failedSession.metrics.provider = transcript.provider
            failedSession.metrics.model = transcript.model
            failedSession.metrics.uploadAndTranscriptionTime = transcript.requestTime
        }
        diagnostics.currentMetrics = failedSession.metrics

        let text = transcript?.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let visibleText: String
        if let text, !text.isEmpty {
            visibleText = text
        } else {
            visibleText = DictationHistoryItem.consumerFacingText(error.localizedDescription)
        }

        let insertionResult = InsertionResult.failed(reason: error.localizedDescription,
                                                     attemptCount: 0,
                                                     targetApp: context.activeAppName,
                                                     targetBundleID: context.bundleID)
        history.add(DictationHistoryItem(timestamp: Date(),
                                         finalText: visibleText,
                                         rawTranscript: transcript?.text,
                                         appName: context.activeAppName,
                                         bundleID: context.bundleID,
                                         category: context.category,
                                         stylePreset: context.stylePreset,
                                         insertionSucceeded: false,
                                         insertion: insertionResult,
                                         metrics: failedSession.metrics),
                    settings: settings)
        if let text, !text.isEmpty {
            history.recordLifetime(text: text,
                                   audioSeconds: failedSession.metrics.audioDuration,
                                   appName: context.activeAppName,
                                   bundleID: context.bundleID)
        }
        log("saved failed dictation history for \(context.activeAppName): \(error.localizedDescription)")
    }

    private func removeStaleAudioFiles() {
        let fileManager = FileManager.default
        guard let files = try? fileManager.contentsOfDirectory(
            at: fileManager.temporaryDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }
        for file in files where file.lastPathComponent.hasPrefix("openflow-") {
            guard let values = try? file.resourceValues(
                forKeys: [.contentModificationDateKey, .isRegularFileKey]
            ),
                  values.isRegularFile == true,
                  let modificationDate = values.contentModificationDate,
                  modificationDate < processStartDate.addingTimeInterval(-staleAudioMinimumAge) else {
                continue
            }
            try? fileManager.removeItem(at: file)
        }
    }

    private func resetPillToIdle() {
        withAnimation(.easeOut(duration: 0.12)) {
            pillViewModel.state = .resultClearing
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.13) { [weak self] in
            guard let self, self.pillViewModel.state == .resultClearing else { return }
            withAnimation(.spring(response: 0.22, dampingFraction: 0.90)) {
                self.pillViewModel.state = .idle
            }
            self.applyPillVisibility()
        }
    }

    private func applyPillVisibility() {
        syncHotkeysWithReadiness()
        guard isReadyToShowPill else {
            floatingWindow.hide(after: 0)
            return
        }
        switch pillViewModel.state {
        case .recording, .processing, .success, .error:
            floatingWindow.show()
        case .idle, .resultClearing:
            if settings.hideInactivePill {
                floatingWindow.hide(after: 0)
            } else {
                floatingWindow.show()
            }
        }
    }

    private func revealPill() {
        guard isReadyToShowPill else {
            floatingWindow.hide(after: 0)
            return
        }
        floatingWindow.show()
    }

    private func syncHotkeysWithReadiness() {
        guard hasStarted else { return }
        let shouldArm = isReadyToShowPill
        if shouldArm == hotkeysArmed {
            return
        }
        restartHotkeys()
    }

    private var isReadyToShowPill: Bool {
        hasCompletedInteractiveOnboarding
            && permissions.microphoneGranted
            && permissions.accessibilityGranted
            && hasConfiguredProvider()
    }

    private var hasCompletedInteractiveOnboarding: Bool {
        UserDefaults.standard.bool(forKey: OnboardingWindowController.completionKey)
    }

    private func scheduleRecordingLimit(for sessionID: UUID) {
        cancelRecordingLimit()
        recordingWarningTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 19 * 60 * 1_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.session?.id == sessionID else { return }
                self.pillViewModel.subtitle = "1 min left"
                self.log("recording cap warning at 19 minutes")
            }
        }
        recordingLimitTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 20 * 60 * 1_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.session?.id == sessionID else { return }
                self.log("recording cap reached at 20 minutes")
                self.endDictation()
            }
        }
    }

    private func cancelRecordingLimit() {
        recordingWarningTask?.cancel()
        recordingLimitTask?.cancel()
        recordingWarningTask = nil
        recordingLimitTask = nil
    }

    private func log(_ message: String) {
        DiagnosticsLog.shared.write(message)
        guard settings.debugLogsEnabled else { return }
        let line = "\(Date().formatted(date: .omitted, time: .standard))  \(message)"
        diagnostics.entries.insert(line, at: 0)
        diagnostics.entries = Array(diagnostics.entries.prefix(200))
    }

    /// Always prints to Console so a latency breakdown is visible without turning on debug logs.
    private func latencyTrace(_ message: String) {
        NSLog("[openflow-latency] %@", message)
        Logger(subsystem: "com.neuroquestlabs.openflow", category: "openflow-latency")
            .notice("\(message, privacy: .public)")
        log(message)
    }

    private func ms(_ interval: TimeInterval) -> String {
        "\(Int(interval * 1000))ms"
    }

    // MARK: - Mic-free dictation injection (launch-arg test hook)

    /// Feeds canned input through the real processing and insertion path so
    /// main-thread stalls can be measured without a microphone. Launch args:
    ///   openflow --openflow-inject-text="hello world"
    ///   openflow --openflow-inject-wav=/absolute/path/to.wav
    /// Both run once at start(): context capture, cleanup, insertion, and the
    /// stop->insert signpost/log timings are identical to a live dictation.
    private func runDictationInjectionIfRequested() {
        let args = ProcessInfo.processInfo.arguments
        let wavPath = Self.launchArgumentValue("--openflow-inject-wav", in: args)
        let text = Self.launchArgumentValue("--openflow-inject-text", in: args)
        guard wavPath != nil || text != nil else { return }
        DiagnosticsLog.shared.write(
            "inject-dictation hook active (wav: \(wavPath != nil), text: \(text != nil))")
        Task { [self] in
            do {
                try await injectDictation(wavPath: wavPath, text: text)
            } catch {
                log("inject-dictation failed: \(error.localizedDescription)")
                OpenflowSignpost.endDictationPipeline(outcome: "error")
            }
        }
    }

    private static func launchArgumentValue(_ flag: String, in args: [String]) -> String? {
        for (index, arg) in args.enumerated() {
            if arg == flag, index + 1 < args.count { return args[index + 1] }
            if arg.hasPrefix(flag + "=") { return String(arg.dropFirst(flag.count + 1)) }
        }
        return nil
    }

    private func injectDictation(wavPath: String?, text: String?) async throws {
        var activeSession = DictationSession(mode: .dictation)
        OpenflowSignpost.beginDictationPipeline()
        log("inject-dictation started")

        let contextInput = ContextCaptureInput(settings: settings)
        var formattingContext = await Task.detached(priority: .userInitiated) { [context] in
            context.capture(input: contextInput)
        }.value
        applyResolvedStyle(to: &formattingContext)
        await refreshFieldText(into: &formattingContext, session: activeSession)

        let captured: CapturedAudio
        let prepared: CapturedAudio
        var transcribed: TranscriptionResult
        if let wavPath {
            let source = URL(fileURLWithPath: wavPath)
            guard FileManager.default.fileExists(atPath: source.path) else {
                throw OpenflowError.noAudioCaptured(reason: "inject-wav file missing: \(wavPath)")
            }
            captured = CapturedAudio(url: source,
                                     duration: Self.audioFileDuration(source),
                                     voicedDuration: 0,
                                     peakLevel: 0,
                                     averageLevel: 0)
            // prepareForUpload may rewrite to an upload copy; the caller-owned
            // source file is never removed.
            prepared = try await Task.detached(priority: .utility) { [audio] in
                try audio.prepareForUpload(captured)
            }.value
            defer {
                if prepared.url != captured.url {
                    try? FileManager.default.removeItem(at: prepared.url)
                }
            }
            let requestInlineCleanup = cleanup.styleRequiresRemoteCleanup(context: formattingContext)
            transcribed = try await transcription.transcribe(
                audioURL: prepared.url,
                settings: settings,
                needsCleanup: requestInlineCleanup,
                cleanupContext: requestInlineCleanup
                    ? cloud.encodeCleanupContext(context: formattingContext, settings: settings)
                    : nil,
                appName: formattingContext.activeAppName,
                bundleID: formattingContext.bundleID)
        } else {
            // Text injection skips the upload entirely and lands straight in
            // cleanup + insertion, which are the main-thread-sensitive stages.
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("openflow-inject-\(UUID().uuidString).wav")
            FileManager.default.createFile(atPath: tempURL.path, contents: Data())
            defer { try? FileManager.default.removeItem(at: tempURL) }
            captured = CapturedAudio(url: tempURL, duration: 0,
                                     voicedDuration: 0, peakLevel: 0, averageLevel: 0)
            prepared = captured
            transcribed = TranscriptionResult(text: text ?? "",
                                              model: "inject-text",
                                              provider: "inject-text",
                                              requestTime: 0)
        }
        activeSession.metrics.audioDuration = captured.duration
        try await finishInsertion(transcribed: transcribed,
                                  session: activeSession,
                                  formattingContext: formattingContext,
                                  captured: prepared)
        log("inject-dictation finished")
    }

    private static func audioFileDuration(_ url: URL) -> TimeInterval {
        guard let file = try? AVAudioFile(forReading: url) else { return 0 }
        let rate = file.processingFormat.sampleRate
        return rate > 0 ? Double(file.length) / rate : 0
    }
}

@MainActor
final class FloatingPillViewModel: ObservableObject {
    @Published var state: PillState = .idle
    @Published var level: Float = 0
    @Published var subtitle = "Ready"
    @Published var glassIntensity = 0.78
    @Published var tintStrength = 0.48
    @Published var tintColorHex = "#000000"
    @Published var inactiveOpacity = 0.54
    var startContinuousRecording: (() -> Void)?
    var stopRecording: (() -> Void)?
    var openSettings: (() -> Void)?
}
