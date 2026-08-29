import AVFoundation
import AudioToolbox
import Combine
import CoreMedia
import os

nonisolated final class AudioCaptureService: NSObject, ObservableObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    private struct CaptureState {
        let outputURL: URL?
        let didCaptureAudio: Bool
        let startTime: Date?
        let maxInputLevel: Float
        let voicedDuration: TimeInterval
        let levelSum: Float
        let levelSampleCount: Int
    }

    @Published var inputLevel: Float = 0
    @Published var inputRouteStatus = MicrophoneRouteStatus.unknown
    @Published var availableMicrophones: [AudioInputDevice] = []
    var onAudioUnavailable: ((String) -> Void)?
    var onDiagnostic: ((String) -> Void)?

    private let captureSession = AVCaptureSession()
    private let audioOutput = AVCaptureAudioDataOutput()
    private let captureQueue = DispatchQueue(label: "openflow.audio.capture")
    private let captureQueueKey = DispatchSpecificKey<Bool>()
    private var currentInput: AVCaptureDeviceInput?
    private var file: AVAudioFile?
    private var startTime: Date?
    private var outputURL: URL?
    private var didCaptureAudio = false
    private var maxInputLevel: Float = 0
    private var maxRawRMS: Float = 0
    private var voicedDuration: TimeInterval = 0
    private var levelSum: Float = 0
    private var levelSampleCount = 0
    private var bufferCount = 0
    private var isCapturing = false
    private var isFinalizing = false
    private var preferredDeviceUID = ""
    private var nameHint = ""
    private var restoredDefaultInputID: AudioDeviceID?
    private var didChangeSystemDefaultInput = false
    private var silenceWatchItem: DispatchWorkItem?
    private var loggedBufferReports = 0
    private let lock = NSLock()
    private var defaultInputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    private var devicesAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    private var defaultInputListener: AudioObjectPropertyListenerBlock?
    private var devicesListener: AudioObjectPropertyListenerBlock?
    private let speechLevelThreshold: Float = 0.026
    private let minimumVoicedDuration: TimeInterval = 0.12
    private let minimumRecordingDuration: TimeInterval = 0.25
    private let uploadSampleRate: Double = 16_000
    private let maxUploadWAVBytes = 7_500_000
    private let compressedUploadBitRate = 32_000
    private let bluetoothReadyTimeout: TimeInterval = 1.0
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "openflow", category: "audio")

    override init() {
        super.init()
        nameHint = UserDefaults.standard.string(forKey: AudioInputDeviceCatalog.nameHintDefaultsKey) ?? ""
        captureQueue.setSpecific(key: captureQueueKey, value: true)
        audioOutput.setSampleBufferDelegate(self, queue: captureQueue)
        installHardwareListeners()
        refreshAvailableMicrophones()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        removeHardwareListeners()
        silenceWatchItem?.cancel()
    }

    func availableMicrophonesSnapshot() -> [AudioInputDevice] {
        AudioInputDeviceCatalog.inputDevices()
    }

    func warmUp(deviceID: String = "") {
        lock.lock()
        let capturing = isCapturing
        lock.unlock()
        guard !capturing,
              AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { return }
        preferredDeviceUID = deviceID
        refreshAvailableMicrophones()
        let resolved = resolveRoute(preferredUID: deviceID)
        publishRouteStatus(preferredUID: deviceID,
                           active: resolved.device,
                           isFallback: resolved.isFallback)
        log("warmup uid=\(deviceID.isEmpty ? "system-default" : deviceID) active=\(resolved.device.name) hal=\(resolved.device.audioDeviceID) channels=\(resolved.device.inputChannels) bt=\(resolved.device.isBluetooth)")
    }

    func start(deviceID: String = "") throws -> Date {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            throw OpenflowError.microphoneUnavailable
        }
        lock.lock()
        let alreadyCapturing = isCapturing
        lock.unlock()
        if alreadyCapturing || captureSession.isRunning {
            stopSessionIfNeeded(reset: false)
        }
        let abandonedState = takeCaptureState()
        if let outputURL = abandonedState.outputURL {
            removeCapturedFile(at: outputURL)
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("openflow-\(UUID().uuidString).wav")
        lock.lock()
        outputURL = url
        file = nil
        didCaptureAudio = false
        maxInputLevel = 0
        maxRawRMS = 0
        voicedDuration = 0
        levelSum = 0
        levelSampleCount = 0
        bufferCount = 0
        loggedBufferReports = 0
        isCapturing = true
        preferredDeviceUID = deviceID
        lock.unlock()

        let deadline = Date().addingTimeInterval(bluetoothReadyTimeout)
        let resolved = resolveRoute(preferredUID: deviceID, deadline: deadline)
        publishRouteStatus(preferredUID: deviceID,
                           active: resolved.device,
                           isFallback: resolved.isFallback)
        rememberNameHint(resolved.device.name)

        do {
            try configureSession(for: resolved.device, preferredUID: deviceID, deadline: deadline)
        } catch {
            stopSessionIfNeeded(reset: true)
            restoreDefaultInputIfNeeded()
            let state = takeCaptureState()
            if let outputURL = state.outputURL {
                removeCapturedFile(at: outputURL)
            } else {
                removeCapturedFile(at: url)
            }
            throw error
        }

        startSessionWithTimeout(timeout: max(0.15, deadline.timeIntervalSinceNow))
        scheduleSilenceWatch(deviceName: resolved.device.name, isBluetooth: resolved.device.isBluetooth)

        let started = Date()
        lock.lock()
        let stillCapturing = isCapturing
        if stillCapturing {
            startTime = started
        }
        lock.unlock()
        guard stillCapturing else {
            stopSessionIfNeeded(reset: false)
            restoreDefaultInputIfNeeded()
            let state = takeCaptureState()
            if let outputURL = state.outputURL {
                removeCapturedFile(at: outputURL)
                if outputURL != url {
                    removeCapturedFile(at: url)
                }
            } else {
                removeCapturedFile(at: url)
            }
            throw OpenflowError.noAudioCaptured
        }
        return started
    }

    func stop() throws -> CapturedAudio {
        silenceWatchItem?.cancel()
        stopSessionIfNeeded(reset: false)
        let state = takeCaptureState()
        restoreDefaultInputIfNeeded()
        guard let outputURL = state.outputURL else {
            throw OpenflowError.noAudioCaptured
        }
        guard state.didCaptureAudio else {
            removeCapturedFile(at: outputURL)
            throw OpenflowError.noAudioCaptured
        }
        let duration = state.startTime.map { Date().timeIntervalSince($0) } ?? 0
        let averageLevel = state.levelSampleCount > 0
            ? state.levelSum / Float(state.levelSampleCount)
            : 0
        guard duration >= minimumRecordingDuration,
              state.maxInputLevel >= speechLevelThreshold,
              state.voicedDuration >= minimumVoicedDuration else {
            removeCapturedFile(at: outputURL)
            throw OpenflowError.noAudioCaptured
        }
        var uploadURL: URL
        do {
            uploadURL = try makeUploadAudio(from: outputURL)
        } catch {
            removeCapturedFile(at: outputURL)
            throw error
        }
        if uploadURL != outputURL {
            removeCapturedFile(at: outputURL)
        }
        if uploadByteCount(of: uploadURL) > maxUploadWAVBytes {
            do {
                let compressedURL = try makeCompressedUploadAudio(from: uploadURL)
                removeCapturedFile(at: uploadURL)
                uploadURL = compressedURL
            } catch {
                removeCapturedFile(at: uploadURL)
                throw error
            }
        }
        return CapturedAudio(url: uploadURL,
                             duration: duration,
                             voicedDuration: state.voicedDuration,
                             peakLevel: state.maxInputLevel,
                             averageLevel: averageLevel)
    }

    private func uploadByteCount(of url: URL) -> Int {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.intValue ?? Int.max
    }

    func discard() {
        silenceWatchItem?.cancel()
        stopSessionIfNeeded(reset: false)
        restoreDefaultInputIfNeeded()
        let state = takeCaptureState()
        if let outputURL = state.outputURL {
            removeCapturedFile(at: outputURL)
        }
    }

    nonisolated func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        lock.lock()
        guard isCapturing else {
            lock.unlock()
            return
        }
        lock.unlock()
        guard let pcmBuffer = pcmBuffer(from: sampleBuffer) else {
            log("dropped buffer: could not convert sample buffer to PCM")
            return
        }
        if pcmBuffer.format.channelCount == 0 || pcmBuffer.format.sampleRate <= 0 {
            handleAudioUnavailable("Microphone input has no usable audio format.")
            return
        }

        lock.lock()
        guard isCapturing else {
            lock.unlock()
            return
        }
        bufferCount += 1
        let reportIndex = loggedBufferReports
        let activeFile: AVAudioFile?
        if let file {
            activeFile = file
        } else if let outputURL {
            do {
                let file = try AVAudioFile(forWriting: outputURL, settings: pcmBuffer.format.settings)
                self.file = file
                activeFile = file
                log("capture format sampleRate=\(pcmBuffer.format.sampleRate) channels=\(pcmBuffer.format.channelCount)")
            } catch {
                log("wav create failed: \(error.localizedDescription)")
                activeFile = nil
            }
        } else {
            activeFile = nil
        }
        guard let activeFile else {
            lock.unlock()
            return
        }
        var writeError: Error?
        do {
            try activeFile.write(from: pcmBuffer)
            didCaptureAudio = true
        } catch {
            writeError = error
            log("wav write failed: \(error.localizedDescription)")
        }
        if reportIndex < 6 {
            loggedBufferReports += 1
        }
        lock.unlock()
        if writeError != nil {
            handleAudioUnavailable("Microphone changed while recording.")
            return
        }
        let rms = rawRMS(buffer: pcmBuffer)
        if reportIndex < 6 {
            log("buffer[\(reportIndex)] frames=\(pcmBuffer.frameLength) rms=\(rms)")
        }
        publishLevel(rms: rms, buffer: pcmBuffer)
    }

    private func configureSession(for device: AudioInputDevice, preferredUID: String, deadline: Date) throws {
        activateBluetoothInputIfNeeded(device, deadline: deadline)
        let captureDevice = waitForCaptureDevice(uid: device.uid, name: device.name, deadline: deadline)
        guard let captureDevice else {
            throw OpenflowError.microphoneInputFailed(
                AudioInputDeviceCatalog.noAudioMessage(deviceName: device.name, isBluetooth: device.isBluetooth)
            )
        }
        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: captureDevice)
        } catch {
            throw OpenflowError.microphoneInputFailed(
                AudioInputDeviceCatalog.noAudioMessage(deviceName: device.name, isBluetooth: device.isBluetooth)
            )
        }
        guard captureSession.canAddInput(input) else {
            throw OpenflowError.microphoneInputFailed("Could not open \(device.name).")
        }

        captureSession.beginConfiguration()
        if let currentInput {
            captureSession.removeInput(currentInput)
        }
        if captureSession.outputs.contains(audioOutput) {
            captureSession.removeOutput(audioOutput)
        }
        captureSession.addInput(input)
        currentInput = input
        if captureSession.canAddOutput(audioOutput) {
            captureSession.addOutput(audioOutput)
        }
        captureSession.commitConfiguration()

        let format = captureDevice.formats.first?.formatDescription
        let asbd = format.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee }
        let channels = asbd.map { Int($0.mChannelsPerFrame) } ?? 0
        let sampleRate = asbd?.mSampleRate ?? 0
        log("selected uid=\(preferredUID.isEmpty ? "system-default" : preferredUID) captureUID=\(captureDevice.uniqueID) name=\(captureDevice.localizedName) AudioDeviceID=\(device.audioDeviceID) formatRate=\(sampleRate) formatChannels=\(channels)")
        if channels == 0 && device.inputChannels == 0 && asbd != nil {
            throw OpenflowError.microphoneInputFailed(
                AudioInputDeviceCatalog.noAudioMessage(deviceName: device.name, isBluetooth: device.isBluetooth)
            )
        }
    }

    private func startSessionWithTimeout(timeout: TimeInterval) {
        let group = DispatchGroup()
        group.enter()
        captureQueue.async { [weak self] in
            self?.captureSession.startRunning()
            group.leave()
        }
        let result = group.wait(timeout: .now() + timeout)
        if result == .timedOut {
            log("AVCaptureSession.startRunning still settling after \(timeout)s; continuing")
        } else {
            log("AVCaptureSession running=\(captureSession.isRunning)")
        }
    }

    private func activateBluetoothInputIfNeeded(_ device: AudioInputDevice, deadline: Date) {
        guard device.audioDeviceID != kAudioObjectUnknown else { return }
        guard device.isBluetooth || device.inputChannels == 0 else { return }
        let currentDefault = AudioInputDeviceCatalog.defaultInputDeviceID()
        if currentDefault != device.audioDeviceID {
            restoredDefaultInputID = currentDefault
            let changed = AudioInputDeviceCatalog.setDefaultInputDevice(device.audioDeviceID)
            didChangeSystemDefaultInput = changed
            log("set default input to \(device.name) hal=\(device.audioDeviceID) success=\(changed)")
        }
        waitWhile(deadline: deadline) {
            AudioInputDeviceCatalog.inputChannelCount(device.audioDeviceID) > 0
                || AudioInputDeviceCatalog.captureDevice(matching: device.uid, name: device.name) != nil
        }
    }

    private func waitForCaptureDevice(uid: String, name: String, deadline: Date) -> AVCaptureDevice? {
        if let existing = AudioInputDeviceCatalog.captureDevice(matching: uid, name: name) {
            return existing
        }
        waitWhile(deadline: deadline) {
            AudioInputDeviceCatalog.captureDevice(matching: uid, name: name) != nil
        }
        return AudioInputDeviceCatalog.captureDevice(matching: uid, name: name)
            ?? AVCaptureDevice.default(for: .audio)
    }

    @discardableResult
    private func waitWhile(deadline: Date, condition: () -> Bool) -> Bool {
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return condition()
    }

    private func resolveRoute(preferredUID: String, deadline: Date? = nil) -> (device: AudioInputDevice, isFallback: Bool) {
        if !preferredUID.isEmpty {
            if let deadline, let waited = waitForPreferredDevice(uid: preferredUID, deadline: deadline) {
                return (waited, waited.uid != preferredUID)
            }
            if let selected = AudioInputDeviceCatalog.resolveDevice(preferredUID: preferredUID, nameHint: nameHint) {
                return (selected, selected.uid != preferredUID)
            }
        }
        if let systemDefault = AudioInputDeviceCatalog.defaultInputDevice() {
            return (systemDefault, !preferredUID.isEmpty)
        }
        let fallback = AudioInputDevice(uid: "",
                                        name: "System Default",
                                        audioDeviceID: kAudioObjectUnknown,
                                        inputChannels: 0,
                                        isBluetooth: false)
        return (fallback, !preferredUID.isEmpty)
    }

    private func waitForPreferredDevice(uid: String, deadline: Date) -> AudioInputDevice? {
        if let selected = AudioInputDeviceCatalog.resolveDevice(preferredUID: uid, nameHint: nameHint) {
            return selected
        }
        waitWhile(deadline: deadline) {
            AudioInputDeviceCatalog.resolveDevice(preferredUID: uid, nameHint: nameHint) != nil
        }
        return AudioInputDeviceCatalog.resolveDevice(preferredUID: uid, nameHint: nameHint)
    }

    private func makeCompressedUploadAudio(from wavURL: URL) throws -> URL {
        let source = try AVAudioFile(forReading: wavURL)
        let destinationURL = wavURL
            .deletingPathExtension()
            .appendingPathExtension("m4a")
        try? FileManager.default.removeItem(at: destinationURL)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: uploadSampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: compressedUploadBitRate
        ]
        do {
            let destination = try AVAudioFile(forWriting: destinationURL, settings: settings)
            guard source.processingFormat.isEqual(destination.processingFormat) else {
                throw OpenflowError.transcriptionFailed(
                    "Audio source and destination formats do not match."
                )
            }
            let framesPerBuffer: AVAudioFrameCount = 8_192
            guard let buffer = AVAudioPCMBuffer(pcmFormat: destination.processingFormat,
                                                frameCapacity: framesPerBuffer) else {
                throw OpenflowError.transcriptionFailed("Could not prepare audio for transcription.")
            }
            while source.framePosition < source.length {
                try source.read(into: buffer, frameCount: framesPerBuffer)
                guard buffer.frameLength > 0 else { break }
                try destination.write(from: buffer)
            }
        } catch {
            try? FileManager.default.removeItem(at: destinationURL)
            throw error
        }
        return destinationURL
    }

    private func makeUploadAudio(from sourceURL: URL) throws -> URL {
        let source = try AVAudioFile(forReading: sourceURL)
        let sourceRate = source.processingFormat.sampleRate
        let sourceDuration = sourceRate > 0 ? Double(source.length) / sourceRate : 0
        log("source wav frames=\(source.length) sampleRate=\(sourceRate) channels=\(source.processingFormat.channelCount) duration=\(String(format: "%.3f", sourceDuration))")
        guard source.length > 0, sourceDuration > 0 else {
            throw OpenflowError.transcriptionFailed("Captured audio file was empty after recording stopped.")
        }
        guard let targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                               sampleRate: uploadSampleRate,
                                               channels: 1,
                                               interleaved: true),
              let converter = AVAudioConverter(from: source.processingFormat, to: targetFormat) else {
            throw OpenflowError.transcriptionFailed("Could not prepare audio for transcription.")
        }

        let destinationURL = sourceURL
            .deletingPathExtension()
            .appendingPathExtension("upload.wav")
        do {
            let destination = try AVAudioFile(forWriting: destinationURL,
                                              settings: targetFormat.settings,
                                              commonFormat: .pcmFormatInt16,
                                              interleaved: true)
            let sourceFramesPerBuffer: AVAudioFrameCount = 8_192
            let ratio = targetFormat.sampleRate / max(source.processingFormat.sampleRate, 1)
            let outputCapacity = AVAudioFrameCount(ceil(Double(sourceFramesPerBuffer) * max(ratio, 1))) + 32
            guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat,
                                                      frameCapacity: outputCapacity) else {
                throw OpenflowError.transcriptionFailed("Could not prepare audio for transcription.")
            }

            var reachedEnd = false
            var readError: Error?
            var outputFrames: AVAudioFramePosition = 0
            while !reachedEnd {
                outputBuffer.frameLength = 0
                var conversionError: NSError?
                let status = converter.convert(to: outputBuffer, error: &conversionError) { _, inputStatus in
                    let remaining = source.length - source.framePosition
                    guard remaining > 0 else {
                        inputStatus.pointee = .endOfStream
                        return nil
                    }
                    let frameCount = AVAudioFrameCount(min(Int64(sourceFramesPerBuffer), remaining))
                    guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: source.processingFormat,
                                                             frameCapacity: frameCount) else {
                        inputStatus.pointee = .noDataNow
                        return nil
                    }
                    do {
                        try source.read(into: inputBuffer, frameCount: frameCount)
                        inputStatus.pointee = .haveData
                        return inputBuffer
                    } catch {
                        readError = error
                        inputStatus.pointee = .endOfStream
                        return nil
                    }
                }
                if let readError { throw readError }
                if let conversionError {
                    log("wav convert failed: \(conversionError.localizedDescription)")
                    throw conversionError
                }
                if outputBuffer.frameLength > 0 {
                    try destination.write(from: outputBuffer)
                    outputFrames += AVAudioFramePosition(outputBuffer.frameLength)
                }
                reachedEnd = status == .endOfStream
                if status == .error {
                    throw conversionError ?? OpenflowError.transcriptionFailed(
                        "Could not convert audio for transcription."
                    )
                }
            }
            let uploadDuration = Double(outputFrames) / uploadSampleRate
            log("upload wav frames=\(outputFrames) sampleRate=\(uploadSampleRate) duration=\(String(format: "%.3f", uploadDuration))")
            guard outputFrames > 0, uploadDuration >= minimumRecordingDuration else {
                throw OpenflowError.transcriptionFailed("Converted audio was too short to transcribe.")
            }
        } catch {
            removeCapturedFile(at: destinationURL)
            throw error
        }
        return destinationURL
    }

    private func stopSessionIfNeeded(reset: Bool) {
        silenceWatchItem?.cancel()
        lock.lock()
        isCapturing = false
        isFinalizing = true
        lock.unlock()
        let teardown = { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.file = nil
            self.lock.unlock()
            if self.captureSession.isRunning {
                self.captureSession.stopRunning()
            }
            if reset {
                self.captureSession.beginConfiguration()
                if let currentInput = self.currentInput {
                    self.captureSession.removeInput(currentInput)
                }
                if self.captureSession.outputs.contains(self.audioOutput) {
                    self.captureSession.removeOutput(self.audioOutput)
                }
                self.captureSession.commitConfiguration()
                self.currentInput = nil
            }
        }
        if DispatchQueue.getSpecific(key: captureQueueKey) == true {
            teardown()
        } else {
            let group = DispatchGroup()
            group.enter()
            captureQueue.async {
                teardown()
                group.leave()
            }
            _ = group.wait(timeout: .now() + bluetoothReadyTimeout)
        }
        lock.lock()
        isFinalizing = false
        file = nil
        lock.unlock()
        DispatchQueue.main.async { self.inputLevel = 0 }
    }

    private func restoreDefaultInputIfNeeded() {
        guard didChangeSystemDefaultInput, let restoredDefaultInputID else {
            didChangeSystemDefaultInput = false
            return
        }
        _ = AudioInputDeviceCatalog.setDefaultInputDevice(restoredDefaultInputID)
        didChangeSystemDefaultInput = false
        self.restoredDefaultInputID = nil
        log("restored previous default input hal=\(restoredDefaultInputID)")
    }

    private func removeCapturedFile(at url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    private func takeCaptureState() -> CaptureState {
        lock.lock()
        defer { lock.unlock() }
        let state = CaptureState(
            outputURL: outputURL,
            didCaptureAudio: didCaptureAudio,
            startTime: startTime,
            maxInputLevel: maxInputLevel,
            voicedDuration: voicedDuration,
            levelSum: levelSum,
            levelSampleCount: levelSampleCount
        )
        outputURL = nil
        didCaptureAudio = false
        startTime = nil
        maxInputLevel = 0
        maxRawRMS = 0
        voicedDuration = 0
        levelSum = 0
        levelSampleCount = 0
        bufferCount = 0
        return state
    }

    private func scheduleSilenceWatch(deviceName: String, isBluetooth: Bool) {
        silenceWatchItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let capturing = self.isCapturing
            let buffers = self.bufferCount
            let rms = self.maxRawRMS
            self.lock.unlock()
            guard capturing else { return }
            if buffers == 0 || rms < 0.0000001 {
                let message = AudioInputDeviceCatalog.noAudioMessage(deviceName: deviceName, isBluetooth: isBluetooth)
                self.log("silence watch fired buffers=\(buffers) maxRMS=\(rms) \(message)")
                self.handleAudioUnavailable(message)
            }
        }
        silenceWatchItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
    }

    private func publishRouteStatus(preferredUID: String,
                                    active: AudioInputDevice,
                                    isFallback: Bool) {
        let message = isFallback
            ? AudioInputDeviceCatalog.fallbackMessage(preferredUID: preferredUID, activeName: active.name)
            : nil
        let status = MicrophoneRouteStatus(preferredUID: preferredUID,
                                           activeUID: active.uid,
                                           activeName: active.name,
                                           isFallback: isFallback,
                                           isBluetooth: active.isBluetooth,
                                           message: message)
        if Thread.isMainThread {
            inputRouteStatus = status
        } else {
            DispatchQueue.main.async { self.inputRouteStatus = status }
        }
    }

    private func refreshAvailableMicrophones() {
        let devices = AudioInputDeviceCatalog.inputDevices()
        if Thread.isMainThread {
            availableMicrophones = devices
        } else {
            DispatchQueue.main.async { self.availableMicrophones = devices }
        }
    }

    private func rememberNameHint(_ name: String) {
        guard !name.isEmpty else { return }
        nameHint = name
        UserDefaults.standard.set(name, forKey: AudioInputDeviceCatalog.nameHintDefaultsKey)
    }

    private func installHardwareListeners() {
        let defaultBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.handleHardwareRouteChange()
        }
        let devicesBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.handleHardwareRouteChange()
        }
        defaultInputListener = defaultBlock
        devicesListener = devicesBlock
        _ = AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject),
                                                &defaultInputAddress,
                                                DispatchQueue.main,
                                                defaultBlock)
        _ = AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject),
                                                &devicesAddress,
                                                DispatchQueue.main,
                                                devicesBlock)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(handleCaptureDeviceChange),
                                               name: .AVCaptureDeviceWasConnected,
                                               object: nil)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(handleCaptureDeviceChange),
                                               name: .AVCaptureDeviceWasDisconnected,
                                               object: nil)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(handleCaptureRuntimeError),
                                               name: .AVCaptureSessionRuntimeError,
                                               object: captureSession)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(handleCaptureInterruption),
                                               name: .AVCaptureSessionWasInterrupted,
                                               object: captureSession)
    }

    private func removeHardwareListeners() {
        if let defaultInputListener {
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject),
                                                   &defaultInputAddress,
                                                   DispatchQueue.main,
                                                   defaultInputListener)
        }
        if let devicesListener {
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject),
                                                   &devicesAddress,
                                                   DispatchQueue.main,
                                                   devicesListener)
        }
    }

    @objc private func handleCaptureDeviceChange() {
        handleHardwareRouteChange()
    }

    @objc private func handleCaptureRuntimeError() {
        lock.lock()
        let active = isCapturing
        let finalizing = isFinalizing
        lock.unlock()
        guard active, !finalizing else {
            log("ignored capture runtime error during stop")
            return
        }
        handleAudioUnavailable("Microphone device changed.")
    }

    @objc private func handleCaptureInterruption() {
        lock.lock()
        let active = isCapturing
        let finalizing = isFinalizing
        lock.unlock()
        guard active, !finalizing else {
            log("ignored capture interruption during stop")
            return
        }
        handleAudioUnavailable("Microphone device changed.")
    }

    private func handleHardwareRouteChange() {
        refreshAvailableMicrophones()
        lock.lock()
        let active = isCapturing
        let recordingHasStarted = startTime != nil
        lock.unlock()
        if active {
            if recordingHasStarted, !captureSession.isRunning || selectedOrDefaultInputMissing() {
                handleAudioUnavailable("Microphone device changed.")
            }
            return
        }
        let resolved = resolveRoute(preferredUID: preferredDeviceUID)
        publishRouteStatus(preferredUID: preferredDeviceUID,
                           active: resolved.device,
                           isFallback: resolved.isFallback)
    }

    private func selectedOrDefaultInputMissing() -> Bool {
        if preferredDeviceUID.isEmpty {
            return AudioInputDeviceCatalog.defaultInputDeviceID() == nil
        }
        return AudioInputDeviceCatalog.resolveDevice(preferredUID: preferredDeviceUID, nameHint: nameHint) == nil
            && AudioInputDeviceCatalog.defaultInputDeviceID() == nil
    }

    private func handleAudioUnavailable(_ message: String) {
        lock.lock()
        let active = isCapturing
        let finalizing = isFinalizing
        lock.unlock()
        guard active, !finalizing else {
            log("ignored audio unavailable after capture stopped: \(message)")
            return
        }
        log("audio unavailable: \(message)")
        stopSessionIfNeeded(reset: true)
        restoreDefaultInputIfNeeded()
        let state = takeCaptureState()
        if let outputURL = state.outputURL {
            removeCapturedFile(at: outputURL)
        }
        DispatchQueue.main.async { [weak self] in
            self?.onAudioUnavailable?(message)
        }
    }

    private func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              var asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)?.pointee,
              asbd.mChannelsPerFrame > 0,
              asbd.mSampleRate > 0,
              let format = AVAudioFormat(streamDescription: &asbd) else {
            return nil
        }
        let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frameCount > 0 else { return nil }

        var bufferListSize = 0
        CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &bufferListSize,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: nil
        )
        guard bufferListSize > 0 else { return nil }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: bufferListSize, alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        let audioBufferList = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        var blockBuffer: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: audioBufferList,
            bufferListSize: bufferListSize,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer
        )
        defer { blockBuffer = nil }
        guard status == noErr,
              let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            return nil
        }
        pcm.frameLength = frameCount
        let source = UnsafeMutableAudioBufferListPointer(audioBufferList)
        let destination = UnsafeMutableAudioBufferListPointer(pcm.mutableAudioBufferList)
        let count = min(source.count, destination.count)
        for index in 0..<count {
            guard let sourceData = source[index].mData, let destinationData = destination[index].mData else {
                continue
            }
            let bytes = Int(min(source[index].mDataByteSize, destination[index].mDataByteSize))
            destinationData.copyMemory(from: sourceData, byteCount: bytes)
            destination[index].mDataByteSize = source[index].mDataByteSize
        }
        return pcm
    }

    private func rawRMS(buffer: AVAudioPCMBuffer) -> Float {
        let count = Int(buffer.frameLength)
        guard count > 0 else { return 0 }
        var sum: Float = 0
        if let data = buffer.floatChannelData {
            let channel = data[0]
            for index in 0..<count {
                sum += channel[index] * channel[index]
            }
        } else if let data = buffer.int16ChannelData {
            let channel = data[0]
            let scale = Float(Int16.max)
            for index in 0..<count {
                let sample = Float(channel[index]) / scale
                sum += sample * sample
            }
        } else {
            return 0
        }
        return sqrt(sum / Float(count))
    }

    private func publishLevel(rms: Float, buffer: AVAudioPCMBuffer) {
        let normalized = min(max(rms * 24, 0), 1)
        let bufferDuration = Double(buffer.frameLength) / max(buffer.format.sampleRate, 1)
        lock.lock()
        guard isCapturing else {
            lock.unlock()
            return
        }
        maxRawRMS = max(maxRawRMS, rms)
        maxInputLevel = max(maxInputLevel, normalized)
        levelSum += normalized
        levelSampleCount += 1
        voicedDuration += normalized >= speechLevelThreshold ? bufferDuration : 0
        lock.unlock()
        DispatchQueue.main.async { self.inputLevel = normalized }
    }

    private func log(_ message: String) {
        logger.info("\(message, privacy: .public)")
        if Thread.isMainThread {
            onDiagnostic?(message)
        } else {
            DispatchQueue.main.async { self.onDiagnostic?(message) }
        }
    }
}

struct CapturedAudio {
    var url: URL
    var duration: TimeInterval
    var voicedDuration: TimeInterval
    var peakLevel: Float
    var averageLevel: Float
}
