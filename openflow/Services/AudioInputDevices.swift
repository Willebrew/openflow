import AVFoundation
import AudioToolbox
import Foundation

struct AudioInputDevice: Hashable, Identifiable {
    let uid: String
    let name: String
    let audioDeviceID: AudioDeviceID
    let inputChannels: Int
    let isBluetooth: Bool

    var id: String { uid }
}

struct MicrophoneRouteStatus: Equatable {
    var preferredUID: String
    var activeUID: String
    var activeName: String
    var isFallback: Bool
    var isBluetooth: Bool
    var message: String?

    static let unknown = MicrophoneRouteStatus(preferredUID: "",
                                               activeUID: "",
                                               activeName: "System Default",
                                               isFallback: false,
                                               isBluetooth: false,
                                               message: nil)
}

enum AudioInputDeviceCatalog {
    static let systemDefaultUID = ""
    static let nameHintDefaultsKey = "microphoneDeviceNameHint"

    static func inputDevices() -> [AudioInputDevice] {
        var devicesByUID: [String: AudioInputDevice] = [:]

        for deviceID in deviceIDs() {
            guard let uid = stringProperty(deviceID, selector: kAudioDevicePropertyDeviceUID),
                  !uid.isEmpty else { continue }
            let channels = inputChannelCount(deviceID)
            let bluetooth = isBluetoothTransport(transportType(deviceID))
            guard channels > 0 || bluetooth else { continue }
            let name = stringProperty(deviceID, selector: kAudioDevicePropertyDeviceNameCFString) ?? uid
            devicesByUID[uid] = AudioInputDevice(uid: uid,
                                                 name: name,
                                                 audioDeviceID: deviceID,
                                                 inputChannels: channels,
                                                 isBluetooth: bluetooth)
        }

        for captureDevice in captureAudioDevices() {
            let uid = captureDevice.uniqueID
            if let existing = devicesByUID[uid] {
                if existing.inputChannels == 0 {
                    devicesByUID[uid] = AudioInputDevice(uid: uid,
                                                         name: existing.name,
                                                         audioDeviceID: existing.audioDeviceID,
                                                         inputChannels: max(existing.inputChannels, 1),
                                                         isBluetooth: existing.isBluetooth || isLikelyHeadsetName(captureDevice.localizedName))
                }
                continue
            }
            if let existingByName = devicesByUID.values.first(where: {
                $0.name.caseInsensitiveCompare(captureDevice.localizedName) == .orderedSame
            }) {
                devicesByUID[existingByName.uid] = AudioInputDevice(uid: existingByName.uid,
                                                                    name: existingByName.name,
                                                                    audioDeviceID: existingByName.audioDeviceID,
                                                                    inputChannels: max(existingByName.inputChannels, 1),
                                                                    isBluetooth: existingByName.isBluetooth || isLikelyHeadsetName(captureDevice.localizedName))
                continue
            }
            devicesByUID[uid] = AudioInputDevice(uid: uid,
                                                 name: captureDevice.localizedName,
                                                 audioDeviceID: kAudioObjectUnknown,
                                                 inputChannels: 1,
                                                 isBluetooth: isLikelyHeadsetName(captureDevice.localizedName))
        }

        return devicesByUID.values.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    static func resolveDevice(preferredUID: String, nameHint: String = "") -> AudioInputDevice? {
        let devices = inputDevices()
        if !preferredUID.isEmpty, let match = devices.first(where: { $0.uid == preferredUID }) {
            return match
        }
        let hint = nameHint.trimmingCharacters(in: .whitespacesAndNewlines)
        if !hint.isEmpty {
            if let exactName = devices.first(where: { $0.name.caseInsensitiveCompare(hint) == .orderedSame }) {
                return exactName
            }
            let hintLower = hint.lowercased()
            if let partial = devices.first(where: {
                $0.name.lowercased().contains(hintLower) || hintLower.contains($0.name.lowercased())
            }) {
                return partial
            }
        }
        return nil
    }

    static func defaultInputDevice() -> AudioInputDevice? {
        guard let deviceID = defaultInputDeviceID() else { return nil }
        let uid = stringProperty(deviceID, selector: kAudioDevicePropertyDeviceUID) ?? ""
        let name = stringProperty(deviceID, selector: kAudioDevicePropertyDeviceNameCFString) ?? "System Default"
        let channels = inputChannelCount(deviceID)
        return AudioInputDevice(uid: uid,
                                name: name,
                                audioDeviceID: deviceID,
                                inputChannels: channels,
                                isBluetooth: isBluetoothTransport(transportType(deviceID)))
    }

    static func defaultInputDeviceID() -> AudioDeviceID? {
        var deviceID = AudioDeviceID()
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        let result = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                                &address,
                                                0,
                                                nil,
                                                &size,
                                                &deviceID)
        guard result == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    static func defaultInputUID() -> String? {
        defaultInputDevice()?.uid
    }

    static func name(forUID uid: String) -> String? {
        guard !uid.isEmpty else { return nil }
        return resolveDevice(preferredUID: uid)?.name
            ?? stringPropertyIfPresent(uid: uid, selector: kAudioDevicePropertyDeviceNameCFString)
    }

    static func name(forDeviceID deviceID: AudioDeviceID) -> String? {
        stringProperty(deviceID, selector: kAudioDevicePropertyDeviceNameCFString)
    }

    static func audioDeviceID(forUID uid: String) -> AudioDeviceID? {
        guard !uid.isEmpty else { return nil }
        if let match = resolveDevice(preferredUID: uid), match.audioDeviceID != kAudioObjectUnknown {
            return match.audioDeviceID
        }
        return deviceIDs().first { stringProperty($0, selector: kAudioDevicePropertyDeviceUID) == uid }
    }

    static func inputChannelCount(_ deviceID: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                                 mScope: kAudioDevicePropertyScopeInput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize) == noErr,
              dataSize > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(dataSize), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, raw) == noErr else {
            return 0
        }
        let audioBufferList = raw.assumingMemoryBound(to: AudioBufferList.self)
        return UnsafeMutableAudioBufferListPointer(audioBufferList).reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    static func setDefaultInputDevice(_ deviceID: AudioDeviceID) -> Bool {
        guard deviceID != kAudioObjectUnknown else { return false }
        var value = deviceID
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        let size = UInt32(MemoryLayout<AudioDeviceID>.size)
        return AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                          &address,
                                          0,
                                          nil,
                                          size,
                                          &value) == noErr
    }

    static func captureDevice(matching uid: String, name: String) -> AVCaptureDevice? {
        let devices = captureAudioDevices()
        if !uid.isEmpty, let match = devices.first(where: { $0.uniqueID == uid }) {
            return match
        }
        if let unique = AVCaptureDevice(uniqueID: uid), !uid.isEmpty {
            return unique
        }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedName.isEmpty {
            if let exact = devices.first(where: { $0.localizedName.caseInsensitiveCompare(trimmedName) == .orderedSame }) {
                return exact
            }
            let lower = trimmedName.lowercased()
            if let partial = devices.first(where: {
                $0.localizedName.lowercased().contains(lower) || lower.contains($0.localizedName.lowercased())
            }) {
                return partial
            }
        }
        return AVCaptureDevice.default(for: .audio)
    }

    static func captureAudioDevices() -> [AVCaptureDevice] {
        let session = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .externalUnknown],
                                                       mediaType: .audio,
                                                       position: .unspecified)
        var devices = session.devices
        if let fallback = AVCaptureDevice.default(for: .audio),
           !devices.contains(where: { $0.uniqueID == fallback.uniqueID }) {
            devices.append(fallback)
        }
        return devices
    }

    static func fallbackMessage(preferredUID: String, activeName: String) -> String {
        let requested = name(forUID: preferredUID) ?? "Selected microphone"
        return "\(requested) isn’t connected. Using \(activeName)."
    }

    static func noAudioMessage(deviceName: String, isBluetooth: Bool) -> String {
        if isBluetooth || isLikelyHeadsetName(deviceName) {
            return "No audio from \(deviceName) — pick Microphone in Settings"
        }
        return "No audio from \(deviceName)."
    }

    static func isLikelyHeadsetName(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower.contains("airpods")
            || lower.contains("headset")
            || lower.contains("hands-free")
            || lower.contains("handsfree")
            || lower.contains("hfp")
    }

    private static func transportType(_ deviceID: AudioDeviceID) -> UInt32 {
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &transport) == noErr else {
            return 0
        }
        return transport
    }

    private static func isBluetoothTransport(_ transport: UInt32) -> Bool {
        transport == kAudioDeviceTransportTypeBluetooth
            || transport == kAudioDeviceTransportTypeBluetoothLE
    }

    private static func stringPropertyIfPresent(uid: String, selector: AudioObjectPropertySelector) -> String? {
        guard let deviceID = deviceIDs().first(where: {
            stringProperty($0, selector: kAudioDevicePropertyDeviceUID) == uid
        }) else { return nil }
        return stringProperty(deviceID, selector: selector)
    }

    private static func deviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),
                                             &address,
                                             0,
                                             nil,
                                             &dataSize) == noErr else { return [] }
        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        guard count > 0 else { return [] }
        var devices = Array(repeating: AudioDeviceID(), count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &address,
                                         0,
                                         nil,
                                         &dataSize,
                                         &devices) == noErr else { return [] }
        return devices
    }

    private static func stringProperty(_ deviceID: AudioDeviceID,
                                       selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let result = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, pointer)
        }
        guard result == noErr else { return nil }
        let string = value as String
        return string.isEmpty ? nil : string
    }
}
