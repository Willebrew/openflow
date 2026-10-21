import AppKit
import Combine
import Foundation

/// Polls `GET <cloud base>/status/load` while openflow is awake.
/// Failures, 404, and bad JSON never surface as errors.
@MainActor
final class BackendLoadMonitor: ObservableObject {
    static let shared = BackendLoadMonitor()
    static let overrideDefaultsKey = "openflowBackendLoadStatusOverrideURL"

    @Published private(set) var notice: BackendLoadNotice = .hidden

    private var baseURLProvider: () -> String = { "" }
    private var timer: Timer?
    private var asleep = false
    private var started = false
    private var isPolling = false
    private var refreshWhenAwake = false
    private var lastActivity = Date()
    private var lastFetchAt: Date?
    private var observers: [NSObjectProtocol] = []
    private let session: URLSession

    init(session: URLSession = BackendLoadMonitor.makeSession()) {
        self.session = session
    }

    func start(cloudBaseURL: @escaping () -> String) {
        guard !started else { return }
        started = true
        baseURLProvider = cloudBaseURL
        lastActivity = Date()
        installObservers()
        BackendLoadSignals.register {
            Task { @MainActor in
                BackendLoadMonitor.shared.refreshOpportunistically()
            }
        }
        schedule(after: BackendLoadSchedule.initialDelay)
    }

    func stop() {
        guard started else { return }
        started = false
        timer?.invalidate()
        timer = nil
        asleep = false
        refreshWhenAwake = false
        baseURLProvider = { "" }
        BackendLoadSignals.register(nil)
        let center = NSWorkspace.shared.notificationCenter
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
            center.removeObserver(observer)
        }
        observers.removeAll()
    }

    /// Dictation and waking the app count as activity so an idle backoff
    /// returns to the 60s poll. This does not move keyboard focus.
    func noteUserActivity() {
        guard started else { return }
        let wasIdle = Date().timeIntervalSince(lastActivity) >= BackendLoadSchedule.idleAfter
        lastActivity = Date()
        guard wasIdle, !asleep else { return }
        if refreshOpportunistically() { return }
        scheduleNext()
    }

    @discardableResult
    func refreshOpportunistically() -> Bool {
        guard started else { return false }
        if asleep {
            refreshWhenAwake = true
            return false
        }
        guard !isPolling else { return false }
        if let lastFetchAt,
           Date().timeIntervalSince(lastFetchAt) < BackendLoadSchedule.opportunisticCooldown {
            return false
        }
        timer?.invalidate()
        timer = nil
        Task { [weak self] in
            await self?.poll()
            self?.scheduleNext()
        }
        return true
    }

    private func installObservers() {
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleSleep() }
        })
        observers.append(workspace.addObserver(
            forName: NSWorkspace.screensDidSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleSleep() }
        })
        observers.append(workspace.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleWake() }
        })
        observers.append(workspace.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleWake() }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.noteUserActivity() }
        })
    }

    private func handleSleep() {
        asleep = true
        timer?.invalidate()
        timer = nil
    }

    private func handleWake() {
        asleep = false
        lastActivity = Date()
        let pending = refreshWhenAwake
        refreshWhenAwake = false
        guard started else { return }
        if pending || isStale {
            if refreshOpportunistically() { return }
        }
        scheduleNext()
    }

    private var isStale: Bool {
        guard let lastFetchAt else { return true }
        return Date().timeIntervalSince(lastFetchAt) >= BackendLoadSchedule.activeInterval
    }

    private func scheduleNext() {
        let idleFor = Date().timeIntervalSince(lastActivity)
        guard let interval = BackendLoadSchedule.pollInterval(idleFor: idleFor, asleep: asleep) else {
            timer?.invalidate()
            timer = nil
            return
        }
        schedule(after: interval)
    }

    private func schedule(after interval: TimeInterval) {
        timer?.invalidate()
        timer = nil
        guard started, !asleep else { return }
        let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in
                await self?.poll()
                self?.scheduleNext()
            }
        }
        timer.tolerance = min(10, interval * 0.15)
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func poll() async {
        guard started, !asleep, !isPolling else { return }
        guard let url = requestURL() else { return }
        isPolling = true
        defer { isPolling = false }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 8
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let outcome: BackendLoadFetchOutcome
        do {
            let (data, response) = try await session.data(for: request)
            if Task.isCancelled || !started { return }
            let code = (response as? HTTPURLResponse)?.statusCode
            outcome = BackendLoadStatusDecoder.interpret(
                statusCode: code,
                data: data,
                transportFailed: false
            )
        } catch {
            if Task.isCancelled || !started || BackendLoadSignals.isCancellation(error) { return }
            outcome = .unchanged
        }
        lastFetchAt = Date()
        publish(BackendLoadReducer.apply(current: notice, outcome: outcome))
    }

    private func requestURL() -> URL? {
        let overrideRaw = UserDefaults.standard.string(forKey: Self.overrideDefaultsKey)
        if let override = BackendLoadEndpoint.overrideURL(from: overrideRaw),
           (try? CloudURLPolicy.validate(override, usage: .serviceBase, baseURL: override)) != nil {
            return override
        }
        guard let base = URL(string: baseURLProvider()),
              let trusted = try? CloudURLPolicy.validateServiceBaseURL(base) else {
            return nil
        }
        return BackendLoadEndpoint.url(cloudBase: trusted)
    }

    private func publish(_ updated: BackendLoadNotice) {
        guard updated != notice else { return }
        notice = updated
        if let text = updated.text {
            DiagnosticsLog.shared.write("backend load notice: \(text)")
        } else {
            DiagnosticsLog.shared.write("backend load notice cleared")
        }
    }

    private static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 8
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }
}
