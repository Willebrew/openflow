import AppKit
import Combine
import CryptoKit
import Foundation

private enum UpdateConfiguration {
    nonisolated static let server = URL(string: "https://updates.jottly.ai")!
    nonisolated static let appSlug = "openflow"
    nonisolated static let channel = "stable"
    nonisolated static let platform = "macos-aarch64"
    nonisolated static let publicKeyBase64 = "Xtthrxu0C3E0HYbkMjqGLSOODgIC7YM8m2JeLsoQpis="
    nonisolated static let checkInterval: TimeInterval = 30 * 60
    nonisolated static let bundleIdentifier = "com.neuroquestlabs.openflow"
    nonisolated static let teamID = "PXAS7J4XKW"
    nonisolated static let codeRequirement =
        "anchor apple generic and identifier \"\(bundleIdentifier)\" "
        + "and certificate leaf[subject.OU] = \(teamID)"
}

struct OpenflowUpdateManifest: Codable, Equatable {
    struct Asset: Codable, Equatable {
        let fileName: String
        let url: URL
        let sizeBytes: Int64
        let sha256: String
        let ed25519: String

        enum CodingKeys: String, CodingKey {
            case fileName = "file_name"
            case url
            case sizeBytes = "size_bytes"
            case sha256
            case ed25519
        }
    }

    let app: String
    let channel: String
    let platform: String
    let version: String
    let releasedAt: String
    let rolloutPercent: Int
    let asset: Asset
    let notes: String

    enum CodingKeys: String, CodingKey {
        case app
        case channel
        case platform
        case version
        case releasedAt = "released_at"
        case rolloutPercent = "rollout_percent"
        case asset
        case notes
    }
}

enum UpdateState: Equatable {
    case idle
    case checking
    case available(OpenflowUpdateManifest)
    case downloading(OpenflowUpdateManifest)
    case preparing(OpenflowUpdateManifest)
    case installing(OpenflowUpdateManifest)
    case upToDate
    case failed(String)

    var label: String {
        switch self {
        case .idle:
            return "Ready"
        case .checking:
            return "Checking for updates..."
        case let .available(manifest):
            return "Version \(manifest.version) is available"
        case .downloading:
            return "Downloading update..."
        case .preparing:
            return "Verifying update..."
        case .installing:
            return "Installing update..."
        case .upToDate:
            return "openflow is up to date"
        case let .failed(message):
            return message
        }
    }
}

enum OpenflowUpdateError: LocalizedError {
    case invalidServerResponse
    case manifestMismatch(String)
    case invalidSignature
    case invalidDownloadSize
    case invalidDownloadHash
    case invalidArchive
    case invalidBundle(String)
    case unsupportedInstallLocation
    case helperUnavailable
    case installerLaunchFailed

    var errorDescription: String? {
        switch self {
        case .invalidServerResponse:
            return "The update server returned an invalid response."
        case let .manifestMismatch(reason):
            return "The update manifest was rejected: \(reason)"
        case .invalidSignature:
            return "The update signature could not be verified."
        case .invalidDownloadSize:
            return "The downloaded update size did not match its manifest."
        case .invalidDownloadHash:
            return "The downloaded update failed its SHA-256 check."
        case .invalidArchive:
            return "The update archive did not contain a valid openflow app."
        case let .invalidBundle(reason):
            return "The downloaded app could not be verified: \(reason)"
        case .unsupportedInstallLocation:
            return "Move openflow to Applications before installing updates."
        case .helperUnavailable:
            return "The update installer could not be prepared."
        case .installerLaunchFailed:
            return "The detached update installer could not be started."
        }
    }
}

private struct UpdateInstallPlan: Codable, Sendable {
    let parentPID: Int32
    let currentAppPath: String
    let stagedAppPath: String
    let backupAppPath: String
    let successMarkerPath: String
    let resultPath: String
    let version: String
}

private struct UpdateHeartbeatResponse: Decodable {
    struct Command: Decodable {
        let id: String
        let kind: String
        let payload: String?
    }

    let commands: [Command]
}

private struct UpdateCommandAck: Encodable {
    let id: String
    let success: Bool
    let result: String?
}

@MainActor
final class UpdateService: ObservableObject {
    static let shared = UpdateService()

    @Published private(set) var state: UpdateState = .idle
    @Published private(set) var lastCheckedAt: Date?
    @Published private(set) var previousVersionAvailable = false
    @Published var automaticallyChecksForUpdates: Bool {
        didSet {
            UserDefaults.standard.set(automaticallyChecksForUpdates,
                                      forKey: Self.automaticChecksKey)
        }
    }

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    private static let automaticChecksKey = "updates.automaticallyCheck"
    private static let maxHeartbeatAcknowledgementFollowUps = 3
    private static let maxRemoteTriggeredChecksPerWindow = 3
    private static let remoteCheckWindow: TimeInterval = 60
    private static let minRemoteCheckInterval: TimeInterval = 20
    private static let handledRemoteCommandIDLimit = 64
    private let session: URLSession
    private var backgroundTask: Task<Void, Never>?
    private var pendingAcks: [UpdateCommandAck] = []
    private var hasPresentedAvailableUpdate = false
    private var recentRemoteCheckAt: [Date] = []
    private var handledRemoteCommandIDs: [String] = []

    private init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 10 * 60
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration)
        automaticallyChecksForUpdates =
            UserDefaults.standard.object(forKey: Self.automaticChecksKey) as? Bool ?? true
        refreshRollbackAvailability()
    }

    func start() {
        guard backgroundTask == nil else { return }
        recordCompletedInstallIfNeeded()
        backgroundTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard let self else { return }
            if self.automaticallyChecksForUpdates {
                await self.performCheck(manual: false)
            } else {
                await self.sendHeartbeat(event: nil)
            }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(UpdateConfiguration.checkInterval))
                guard !Task.isCancelled else { return }
                if self.automaticallyChecksForUpdates {
                    await self.performCheck(manual: false)
                } else {
                    await self.sendHeartbeat(event: nil)
                }
            }
        }
    }

    func stop() {
        backgroundTask?.cancel()
        backgroundTask = nil
    }

    func checkForUpdates(manual: Bool = true) {
        Task {
            await performCheck(manual: manual)
        }
    }

    func installAvailableUpdate() {
        guard case let .available(manifest) = state else { return }
        Task {
            await install(manifest)
        }
    }

    func rollbackToPreviousVersion() {
        guard previousVersionAvailable else { return }
        Task {
            do {
                let paths = try UpdatePaths.current()
                let rollbackRoot = paths.root
                    .appendingPathComponent("rollback-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: rollbackRoot,
                                                        withIntermediateDirectories: true)
                let rollbackStage = rollbackRoot
                    .appendingPathComponent("openflow.app", isDirectory: true)
                try FileManager.default.copyItem(at: paths.backupApp, to: rollbackStage)
                let version = Bundle(url: rollbackStage)?
                    .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "previous"
                try UpdatePackagePreparer.validate(app: rollbackStage,
                                                   expectedVersion: version)
                try prepareInstaller(stagedApp: rollbackStage,
                                     version: version,
                                     paths: paths)
            } catch {
                state = .failed(error.localizedDescription)
                showError(error.localizedDescription)
            }
        }
    }

    private func performCheck(manual: Bool) async {
        guard !isBusy else { return }
        state = .checking
        do {
            let manifest = try await fetchManifest()
            lastCheckedAt = Date()
            await sendHeartbeat(event: "check")
            guard let manifest else {
                state = .upToDate
                if manual {
                    showInformation(title: "openflow is up to date",
                                    message: "You’re running version \(currentVersion).")
                }
                return
            }
            state = .available(manifest)
            if manual || !hasPresentedAvailableUpdate {
                hasPresentedAvailableUpdate = true
                presentUpdate(manifest)
            }
        } catch {
            lastCheckedAt = Date()
            state = .failed(error.localizedDescription)
            await sendHeartbeat(event: "fail", detail: error.localizedDescription)
            if manual {
                showError(error.localizedDescription)
            }
        }
    }

    private var isBusy: Bool {
        switch state {
        case .checking, .downloading, .preparing, .installing:
            return true
        default:
            return false
        }
    }

    private func fetchManifest() async throws -> OpenflowUpdateManifest? {
        let url = UpdateConfiguration.server
            .appendingPathComponent("v1/apps")
            .appendingPathComponent(UpdateConfiguration.appSlug)
            .appendingPathComponent(UpdateConfiguration.channel)
            .appendingPathComponent(UpdateConfiguration.platform)
            .appendingPathComponent("latest.json")
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OpenflowUpdateError.invalidServerResponse
        }
        if http.statusCode == 404 {
            return nil
        }
        guard 200..<300 ~= http.statusCode else {
            throw OpenflowUpdateError.invalidServerResponse
        }

        let manifest = try JSONDecoder().decode(OpenflowUpdateManifest.self, from: data)
        try validateManifest(manifest)
        guard UpdateSecurity.isVersion(manifest.version, newerThan: currentVersion) else {
            return nil
        }
        guard UpdateSecurity.isIncludedInRollout(installID: installID,
                                                 version: manifest.version,
                                                 percent: manifest.rolloutPercent) else {
            return nil
        }
        return manifest
    }

    private func validateManifest(_ manifest: OpenflowUpdateManifest) throws {
        guard manifest.app == UpdateConfiguration.appSlug else {
            throw OpenflowUpdateError.manifestMismatch("wrong application")
        }
        guard manifest.channel == UpdateConfiguration.channel else {
            throw OpenflowUpdateError.manifestMismatch("wrong channel")
        }
        guard manifest.platform == UpdateConfiguration.platform else {
            throw OpenflowUpdateError.manifestMismatch("wrong platform")
        }
        guard manifest.rolloutPercent >= 0, manifest.rolloutPercent <= 100 else {
            throw OpenflowUpdateError.manifestMismatch("invalid rollout")
        }
        guard manifest.asset.url.scheme == "https",
              manifest.asset.url.host == UpdateConfiguration.server.host else {
            throw OpenflowUpdateError.manifestMismatch("untrusted download host")
        }
        try UpdateSecurity.verifySignature(manifest,
                                           publicKeyBase64: UpdateConfiguration.publicKeyBase64)
    }

    private func install(_ manifest: OpenflowUpdateManifest) async {
        do {
            let paths = try UpdatePaths.current()
            state = .downloading(manifest)
            await sendHeartbeat(event: "download",
                                fromVersion: currentVersion,
                                toVersion: manifest.version)
            let (temporaryURL, response) = try await session.download(from: manifest.asset.url)
            guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
                throw OpenflowUpdateError.invalidServerResponse
            }

            let archiveURL = paths.root.appendingPathComponent(
                "\(manifest.version)-\(UUID().uuidString).zip"
            )
            try? FileManager.default.removeItem(at: archiveURL)
            try FileManager.default.moveItem(at: temporaryURL, to: archiveURL)

            state = .preparing(manifest)
            let stagedApp = try await Task.detached(priority: .userInitiated) {
                try UpdatePackagePreparer.prepare(archiveURL: archiveURL,
                                                  manifest: manifest,
                                                  root: paths.root)
            }.value
            await sendHeartbeat(event: "verify",
                                fromVersion: currentVersion,
                                toVersion: manifest.version)
            state = .installing(manifest)
            try prepareInstaller(stagedApp: stagedApp,
                                 version: manifest.version,
                                 paths: paths)
        } catch {
            state = .failed(error.localizedDescription)
            await sendHeartbeat(event: "fail",
                                fromVersion: currentVersion,
                                toVersion: manifest.version,
                                detail: error.localizedDescription)
            showError(error.localizedDescription)
        }
    }

    private func prepareInstaller(stagedApp: URL,
                                  version: String,
                                  paths: UpdatePaths) throws {
        guard let helperSource = Bundle.main.url(forResource: "install-update",
                                                 withExtension: "sh") else {
            throw OpenflowUpdateError.helperUnavailable
        }
        let helperURL = paths.root.appendingPathComponent(
            "install-update-\(UUID().uuidString).sh"
        )
        try FileManager.default.copyItem(at: helperSource, to: helperURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o700],
                                              ofItemAtPath: helperURL.path)

        let marker = paths.root.appendingPathComponent(
            "launch-confirmation-\(UUID().uuidString)"
        )
        let result = paths.root.appendingPathComponent("last-install-result.json")
        try? FileManager.default.removeItem(at: marker)
        try? FileManager.default.removeItem(at: result)

        let plan = UpdateInstallPlan(
            parentPID: ProcessInfo.processInfo.processIdentifier,
            currentAppPath: paths.currentApp.path,
            stagedAppPath: stagedApp.path,
            backupAppPath: paths.backupApp.path,
            successMarkerPath: marker.path,
            resultPath: result.path,
            version: version
        )
        let planURL = paths.root.appendingPathComponent(
            "install-plan-\(UUID().uuidString).json"
        )
        try JSONEncoder().encode(plan).write(to: planURL, options: .atomic)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = [
            "submit",
            "-l", "com.neuroquestlabs.openflow.update.\(UUID().uuidString)",
            "--",
            "/bin/zsh", helperURL.path, planURL.path
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw OpenflowUpdateError.installerLaunchFailed
        }

        state = .installing(
            OpenflowUpdateManifest(
                app: UpdateConfiguration.appSlug,
                channel: UpdateConfiguration.channel,
                platform: UpdateConfiguration.platform,
                version: version,
                releasedAt: "",
                rolloutPercent: 100,
                asset: .init(fileName: "", url: UpdateConfiguration.server,
                             sizeBytes: 0, sha256: "", ed25519: ""),
                notes: ""
            )
        )
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            NSApp.terminate(nil)
        }
    }

    private func confirmHeartbeatRollback() -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.icon = NSApp.applicationIconImage
        alert.messageText = "Roll back openflow?"
        alert.informativeText = "A remote update command asked to restore the previous version. The backup is still verified with SHA-256, Developer ID, and Gatekeeper before it is installed."
        alert.addButton(withTitle: "Roll Back")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func presentUpdate(_ manifest: OpenflowUpdateManifest) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.icon = NSApp.applicationIconImage
        alert.messageText = "openflow \(manifest.version) is available"
        alert.informativeText = manifest.notes.isEmpty
            ? "A new signed update is ready to install."
            : manifest.notes
        alert.addButton(withTitle: "Install Update")
        alert.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            installAvailableUpdate()
        }
    }

    private func showInformation(title: String, message: String) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.icon = NSApp.applicationIconImage
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.icon = NSApp.applicationIconImage
        alert.messageText = "Update could not be installed"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private var installID: String {
        UpdateDeviceIdentity.installID()
    }

    private func registerInstallIfNeeded(privateKey: Curve25519.Signing.PrivateKey) async {
        if UpdateDeviceIdentity.isRegistered { return }
        let registered = await postRegister(privateKey: privateKey)
        if registered {
            UpdateDeviceIdentity.markRegistered()
            return
        }
    }

    private func postRegister(privateKey: Curve25519.Signing.PrivateKey,
                              retriedConflict: Bool = false) async -> Bool {
        let url = UpdateConfiguration.server.appendingPathComponent("v1/installs/register")
        let body: [String: Any] = [
            "install_id": installID,
            "app": UpdateConfiguration.appSlug,
            "channel": UpdateConfiguration.channel,
            "platform": UpdateConfiguration.platform,
            "current_version": currentVersion,
            "device_pubkey": UpdateDeviceIdentity.devicePublicKeyBase64(privateKey),
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        guard let (_, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse else {
            return false
        }
        if 200..<300 ~= http.statusCode {
            return true
        }
        if http.statusCode == 409, !retriedConflict {
            _ = UpdateDeviceIdentity.rotateInstallID()
            return await postRegister(privateKey: privateKey, retriedConflict: true)
        }
        return false
    }

    private func sendHeartbeat(event: String?,
                               fromVersion: String? = nil,
                               toVersion: String? = nil,
                               detail: String? = nil,
                               acknowledgementDepth: Int = 0) async {
        guard let privateKey = try? UpdateDeviceIdentity.deviceKeyPair() else { return }
        await registerInstallIfNeeded(privateKey: privateKey)

        let url = UpdateConfiguration.server.appendingPathComponent("v1/heartbeat")
        let acknowledgements: [[String: Any]] = pendingAcks.map { acknowledgement in
            var value: [String: Any] = [
                "id": acknowledgement.id,
                "success": acknowledgement.success,
            ]
            if let result = acknowledgement.result {
                value["result"] = result
            }
            return value
        }
        var body: [String: Any] = [
            "install_id": installID,
            "app": UpdateConfiguration.appSlug,
            "channel": UpdateConfiguration.channel,
            "platform": UpdateConfiguration.platform,
            "current_version": currentVersion,
            "acks": acknowledgements,
        ]
        if let event { body["event"] = event }
        if let fromVersion { body["from_version"] = fromVersion }
        if let toVersion { body["to_version"] = toVersion }
        if let detail { body["detail"] = String(detail.prefix(500)) }
        if let userLabel = UpdateDeviceIdentity.userLabel() {
            body["user_label"] = userLabel
        }

        var signed = false
        var heartbeatTs: Int64?
        if let ts = UpdateDeviceIdentity.nextHeartbeatTimestamp() {
            let payload = UpdateDeviceIdentity.canonicalHeartbeatPayload(
                installID: installID,
                app: UpdateConfiguration.appSlug,
                channel: UpdateConfiguration.channel,
                platform: UpdateConfiguration.platform,
                currentVersion: currentVersion,
                ts: ts
            )
            if let signature = try? UpdateDeviceIdentity.signHeartbeat(privateKey: privateKey,
                                                                       payload: payload) {
                body["ts"] = NSNumber(value: ts)
                body["signature"] = signature
                heartbeatTs = ts
                signed = true
            }
        }

        guard signed else { return }
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        guard let (responseData, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse else {
            return
        }
        if http.statusCode == 401,
           acknowledgementDepth < Self.maxHeartbeatAcknowledgementFollowUps {
            UpdateDeviceIdentity.markUnregistered()
            await registerInstallIfNeeded(privateKey: privateKey)
            await sendHeartbeat(event: event,
                                fromVersion: fromVersion,
                                toVersion: toVersion,
                                detail: detail,
                                acknowledgementDepth: acknowledgementDepth + 1)
            return
        }
        if http.statusCode == 400, let heartbeatTs {
            UpdateDeviceIdentity.recordHeartbeatTimestamp(heartbeatTs)
            return
        }
        guard 200..<300 ~= http.statusCode,
              let heartbeat = try? JSONDecoder().decode(UpdateHeartbeatResponse.self,
                                                        from: responseData) else {
            return
        }
        if let heartbeatTs {
            UpdateDeviceIdentity.recordHeartbeatTimestamp(heartbeatTs)
        }
        pendingAcks.removeAll()
        for command in heartbeat.commands {
            handle(command)
        }
        if !pendingAcks.isEmpty {
            let acknowledgements = pendingAcks
            pendingAcks.removeAll()
            guard acknowledgementDepth < Self.maxHeartbeatAcknowledgementFollowUps else {
                pendingAcks = acknowledgements
                return
            }
            await sendAcknowledgements(acknowledgements,
                                       depth: acknowledgementDepth)
        }
    }

    /// Heartbeat commands are not signed. Bound remote-triggered re-checks so a
    /// compromised update server cannot pin the client in a fetch loop.
    private func acceptRemoteUpdateCommand(_ commandID: String) -> Bool {
        let trimmed = commandID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if handledRemoteCommandIDs.contains(trimmed) { return false }
        let now = Date()
        recentRemoteCheckAt.removeAll { now.timeIntervalSince($0) > Self.remoteCheckWindow }
        if let last = recentRemoteCheckAt.last,
           now.timeIntervalSince(last) < Self.minRemoteCheckInterval {
            return false
        }
        guard recentRemoteCheckAt.count < Self.maxRemoteTriggeredChecksPerWindow else {
            return false
        }
        handledRemoteCommandIDs.append(trimmed)
        if handledRemoteCommandIDs.count > Self.handledRemoteCommandIDLimit {
            handledRemoteCommandIDs.removeFirst(
                handledRemoteCommandIDs.count - Self.handledRemoteCommandIDLimit
            )
        }
        recentRemoteCheckAt.append(now)
        return true
    }

    private func sendAcknowledgements(_ acknowledgements: [UpdateCommandAck],
                                      depth: Int) async {
        pendingAcks = acknowledgements
        await sendHeartbeat(event: nil, acknowledgementDepth: depth + 1)
    }

    private func handle(_ command: UpdateHeartbeatResponse.Command) {
        switch command.kind {
        case "check_now", "install_version":
            guard acceptRemoteUpdateCommand(command.id) else {
                pendingAcks.append(.init(id: command.id, success: false,
                                         result: "Remote update check throttled"))
                return
            }
            pendingAcks.append(.init(id: command.id, success: true,
                                     result: "Update check started"))
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(250))
                await self?.performCheck(manual: false)
            }
        case "rollback":
            guard previousVersionAvailable else {
                pendingAcks.append(.init(id: command.id, success: false,
                                         result: "No previous version is available"))
                return
            }
            if confirmHeartbeatRollback() {
                pendingAcks.append(.init(id: command.id, success: true,
                                         result: "Rollback started"))
                rollbackToPreviousVersion()
            } else {
                pendingAcks.append(.init(id: command.id, success: false,
                                         result: "User declined rollback"))
            }
        default:
            pendingAcks.append(.init(id: command.id, success: false,
                                     result: "Unsupported command"))
        }
    }

    private func refreshRollbackAvailability() {
        guard let paths = try? UpdatePaths.current() else {
            previousVersionAvailable = false
            return
        }
        previousVersionAvailable = FileManager.default.fileExists(
            atPath: paths.backupApp.path
        )
    }

    private func recordCompletedInstallIfNeeded() {
        guard let paths = try? UpdatePaths.current() else { return }
        let resultURL = paths.root.appendingPathComponent("last-install-result.json")
        guard let data = try? Data(contentsOf: resultURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let status = object["status"] as? String else {
            refreshRollbackAvailability()
            return
        }
        try? FileManager.default.removeItem(at: resultURL)
        refreshRollbackAvailability()
        if status == "installed", let version = object["version"] as? String {
            Task {
                await sendHeartbeat(event: "install",
                                    fromVersion: nil,
                                    toVersion: version)
            }
        }
    }
}

private struct UpdatePaths: Sendable {
    let root: URL
    let currentApp: URL
    let backupApp: URL

    static func updatesRoot() throws -> URL {
        try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        )
            .appendingPathComponent("openflow", isDirectory: true)
            .appendingPathComponent("Updates", isDirectory: true)
    }

    static func current() throws -> UpdatePaths {
        let currentApp = Bundle.main.bundleURL.standardizedFileURL
        guard currentApp.pathExtension == "app",
              !currentApp.path.contains("/AppTranslocation/"),
              isSupportedInstallLocation(currentApp) else {
            throw OpenflowUpdateError.unsupportedInstallLocation
        }
        let root = try updatesRoot()
        try FileManager.default.createDirectory(at: root,
                                                withIntermediateDirectories: true)
        let backup = currentApp.deletingLastPathComponent()
            .appendingPathComponent(".openflow.previous.app", isDirectory: true)
        return UpdatePaths(root: root, currentApp: currentApp, backupApp: backup)
    }

    static func isSupportedInstallLocation(_ app: URL) -> Bool {
        let parent = app.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        let systemApplications = URL(fileURLWithPath: "/Applications", isDirectory: true)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let userApplications = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications", isDirectory: true)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        return parent == systemApplications || parent == userApplications
    }
}

private enum UpdateSecurity {
    nonisolated static func canonicalPayload(_ manifest: OpenflowUpdateManifest) -> Data {
        let fields = [
            "app=\(manifest.app)",
            "channel=\(manifest.channel)",
            "version=\(manifest.version)",
            "platform=\(manifest.platform)",
            "file_name=\(manifest.asset.fileName)",
            "size=\(manifest.asset.sizeBytes)",
            "sha256=\(manifest.asset.sha256.lowercased())",
        ]
        return Data(fields.joined(separator: "\n").utf8)
    }

    nonisolated static func verifySignature(_ manifest: OpenflowUpdateManifest,
                                            publicKeyBase64: String) throws {
        guard let publicKeyData = Data(base64Encoded: publicKeyBase64),
              let signature = Data(base64Encoded: manifest.asset.ed25519),
              signature.count == 64,
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData),
              key.isValidSignature(signature, for: canonicalPayload(manifest)) else {
            throw OpenflowUpdateError.invalidSignature
        }
    }

    nonisolated static func isVersion(_ candidate: String, newerThan current: String) -> Bool {
        let candidateParts = numericVersion(candidate)
        let currentParts = numericVersion(current)
        let count = max(candidateParts.count, currentParts.count)
        for index in 0..<count {
            let lhs = index < candidateParts.count ? candidateParts[index] : 0
            let rhs = index < currentParts.count ? currentParts[index] : 0
            if lhs != rhs { return lhs > rhs }
        }
        return false
    }

    nonisolated static func isIncludedInRollout(installID: String,
                                                version: String,
                                                percent: Int) -> Bool {
        if percent >= 100 { return true }
        if percent <= 0 { return false }
        let digest = SHA256.hash(data: Data("\(installID):\(version)".utf8))
        let bucket = digest.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) } % 100
        return bucket < UInt32(percent)
    }

    nonisolated private static func numericVersion(_ value: String) -> [Int] {
        value.split(separator: ".", omittingEmptySubsequences: false).map { component in
            Int(component.prefix { $0.isNumber }) ?? 0
        }
    }
}

enum UpdateLaunchConfirmation {
    static func confirmIfNeeded() {
        let arguments = ProcessInfo.processInfo.arguments
        guard let flagIndex = arguments.firstIndex(of: "--openflow-update-complete"),
              arguments.indices.contains(flagIndex + 1) else {
            return
        }
        let markerURL = URL(fileURLWithPath: arguments[flagIndex + 1])
            .standardizedFileURL
        guard let updatesRoot = try? UpdatePaths.updatesRoot() else {
            return
        }
        let updatesRootURL = updatesRoot.standardizedFileURL
        guard isInsideUpdatesRoot(markerURL, root: updatesRootURL) else {
            return
        }
        FileManager.default.createFile(
            atPath: markerURL.path,
            contents: Data("launch confirmed".utf8)
        )
        confirmInstall(markerURL: markerURL, updatesRoot: updatesRootURL)
    }

    private static func confirmInstall(markerURL: URL, updatesRoot: URL) {
        let fileManager = FileManager.default
        guard let planURLs = try? fileManager.contentsOfDirectory(
            at: updatesRoot,
            includingPropertiesForKeys: nil
        ).filter({ $0.lastPathComponent.hasPrefix("install-plan-") }),
              let match = planURLs.compactMap({ url -> (URL, UpdateInstallPlan)? in
                  guard let data = try? Data(contentsOf: url),
                        let plan = try? JSONDecoder().decode(UpdateInstallPlan.self, from: data),
                        isInsideUpdatesRoot(
                            URL(fileURLWithPath: plan.resultPath),
                            root: updatesRoot
                        ),
                        URL(fileURLWithPath: plan.successMarkerPath).standardizedFileURL
                            == markerURL.standardizedFileURL else {
                      return nil
                  }
                  return (url, plan)
              }).first else {
            return
        }

        let result: [String: String] = [
            "status": "installed",
            "detail": "launch confirmed",
            "version": match.1.version,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: result) {
            try? data.write(
                to: URL(fileURLWithPath: match.1.resultPath).standardizedFileURL,
                options: .atomic
            )
        }

        let planURL = match.0
        let stagedRoot = URL(fileURLWithPath: match.1.stagedAppPath)
            .deletingLastPathComponent()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5) {
            let manager = FileManager.default
            try? manager.removeItem(at: markerURL)
            try? manager.removeItem(at: planURL)
            if (try? manager.contentsOfDirectory(atPath: stagedRoot.path).isEmpty) == true {
                try? manager.removeItem(at: stagedRoot)
            }
            if let artifacts = try? manager.contentsOfDirectory(
                at: updatesRoot,
                includingPropertiesForKeys: nil
            ) {
                for artifact in artifacts
                    where artifact.lastPathComponent.hasPrefix("install-update-") {
                    try? manager.removeItem(at: artifact)
                }
            }
            try? manager.removeItem(
                at: updatesRoot.appendingPathComponent("last-install-result.json")
            )
        }
    }

    private static func isInsideUpdatesRoot(_ url: URL, root: URL) -> Bool {
        let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
        let candidatePath = url.resolvingSymlinksInPath().standardizedFileURL.path
        return candidatePath.hasPrefix(rootPath + "/")
    }
}

private enum UpdatePackagePreparer {
    nonisolated static func prepare(archiveURL: URL,
                                    manifest: OpenflowUpdateManifest,
                                    root: URL) throws -> URL {
        let attributes = try FileManager.default.attributesOfItem(
            atPath: archiveURL.path
        )
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? -1
        guard size == manifest.asset.sizeBytes else {
            throw OpenflowUpdateError.invalidDownloadSize
        }
        guard sha256(of: archiveURL) == manifest.asset.sha256.lowercased() else {
            throw OpenflowUpdateError.invalidDownloadHash
        }
        try UpdateSecurity.verifySignature(
            manifest,
            publicKeyBase64: UpdateConfiguration.publicKeyBase64
        )

        let extractionRoot = root.appendingPathComponent(
            "staged-\(manifest.version)-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: extractionRoot,
                                                withIntermediateDirectories: true)
        let ditto = try run("/usr/bin/ditto",
                            arguments: ["-x", "-k", archiveURL.path,
                                        extractionRoot.path])
        guard ditto.status == 0 else {
            throw OpenflowUpdateError.invalidArchive
        }
        try? FileManager.default.removeItem(at: archiveURL)

        guard let app = FileManager.default.enumerator(
            at: extractionRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )?.compactMap({ $0 as? URL })
            .first(where: { $0.pathExtension == "app" && $0.lastPathComponent == "openflow.app" })
        else {
            throw OpenflowUpdateError.invalidArchive
        }
        try validate(app: app, expectedVersion: manifest.version)
        return app
    }

    nonisolated static func validate(app: URL, expectedVersion: String) throws {
        guard let bundle = Bundle(url: app),
              bundle.bundleIdentifier == UpdateConfiguration.bundleIdentifier,
              bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
                == expectedVersion else {
            throw OpenflowUpdateError.invalidBundle("bundle identity mismatch")
        }
        let codesign = try run("/usr/bin/codesign",
                               arguments: ["--verify", "--deep", "--strict",
                                           "--verbose=2", app.path])
        guard codesign.status == 0 else {
            throw OpenflowUpdateError.invalidBundle(
                String(codesign.error.prefix(300))
            )
        }
        let requirement = try run("/usr/bin/codesign",
                                  arguments: ["--verify",
                                              "-R=\(UpdateConfiguration.codeRequirement)",
                                              "--verbose=2", app.path])
        guard requirement.status == 0 else {
            throw OpenflowUpdateError.invalidBundle(
                String(requirement.error.prefix(300))
            )
        }
        let gatekeeper = try run("/usr/sbin/spctl",
                                 arguments: ["--assess", "--type", "execute",
                                             "--verbose=2", app.path])
        guard gatekeeper.status == 0 else {
            throw OpenflowUpdateError.invalidBundle(
                String(gatekeeper.error.prefix(300))
            )
        }
    }

    nonisolated private static func sha256(of url: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        var hash = SHA256()
        while autoreleasepool(invoking: {
            let data = try? handle.read(upToCount: 1024 * 1024)
            guard let data, !data.isEmpty else { return false }
            hash.update(data: data)
            return true
        }) {}
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    nonisolated private static func run(_ executable: String,
                                        arguments: [String]) throws
        -> (status: Int32, output: String, error: String) {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        return (
            process.terminationStatus,
            String(data: stdout.fileHandleForReading.readDataToEndOfFile(),
                   encoding: .utf8) ?? "",
            String(data: stderr.fileHandleForReading.readDataToEndOfFile(),
                   encoding: .utf8) ?? ""
        )
    }
}
