#!/usr/bin/env node
import fs from "node:fs";
import path from "node:path";

const root = path.resolve(import.meta.dirname, "..");
const audio = fs.readFileSync(path.join(root, "openflow/Services/AudioCaptureService.swift"), "utf8");
const devices = fs.readFileSync(path.join(root, "openflow/Services/AudioInputDevices.swift"), "utf8");
const settingsView = fs.readFileSync(path.join(root, "openflow/Views/SettingsView.swift"), "utf8");
const userSettings = fs.readFileSync(path.join(root, "openflow/Models/UserSettings.swift"), "utf8");
const cloud = fs.readFileSync(path.join(root, "openflow/Services/OpenFlowCloudService.swift"), "utf8");
const coordinator = fs.readFileSync(path.join(root, "openflow/Services/DictationCoordinator.swift"), "utf8");
const audioAll = `${audio}\n${devices}`;

function fail(message) {
  console.error(`audio capture safety check failed: ${message}`);
  process.exit(1);
}

function assert(condition, message) {
  if (!condition) fail(message);
}

assert(audio.includes("func start(deviceID: String = \"\") throws -> Date"), "start(deviceID:) entry point is missing");
assert(audio.includes("let abandonedState = takeCaptureState()"), "starting a new capture does not claim prior capture state");
assert(audio.includes("if let outputURL = abandonedState.outputURL"), "prior capture files are not removed before starting a new capture");
assert(audio.includes("func warmUp(deviceID: String = \"\")"), "audio engine warm-up is missing");
assert(audio.includes("configureSession(for: resolved.device"), "start(deviceID:) does not apply the selected input device");
assert(audio.includes("AVCaptureSession"), "Bluetooth-capable AVCaptureSession path is missing");
assert(audio.includes("AVCaptureAudioDataOutput"), "AVCaptureAudioDataOutput tap is missing");
assert(audio.includes("AVCaptureDeviceInput"), "selected microphone is not opened as an AVCaptureDeviceInput");
assert(audioAll.includes("kAudioDevicePropertyDeviceUID"), "selected device UID is not resolved through CoreAudio");
assert(audioAll.includes("kAudioHardwarePropertyDefaultInputDevice"), "system default input is not read from Core Audio");
assert(audioAll.includes("kAudioDeviceTransportTypeBluetooth"), "Bluetooth transport devices are not listed as microphones");
assert(audio.includes("setDefaultInputDevice"), "selected Bluetooth microphones do not force the HAL input device");
assert(audio.includes("AudioObjectAddPropertyListenerBlock"), "default input / device list changes are not observed");
assert(audio.includes("AVCaptureDeviceWasConnected"), "capture device connect events are not observed");
assert(audio.includes("bluetoothReadyTimeout"), "Bluetooth input availability is not bounded before capture");
assert(audio.includes("startSessionWithTimeout"), "AVCaptureSession.startRunning is not timeout-bounded");
assert(audio.includes("scheduleSilenceWatch"), "dead Bluetooth input is not surfaced instead of recording silence");
assert(audio.includes("capture format sampleRate"), "input format sample rate is not logged");
assert(audio.includes("formatChannels"), "input format channel count is not logged");
assert(audio.includes("buffer["), "first capture buffer RMS is not logged");
assert(settingsView.includes("Microphone"), "Settings is missing a microphone input picker");
assert(settingsView.includes("System Default"), "Settings picker is missing the System Default option");
assert(userSettings.includes("microphoneDeviceID: microphoneDeviceID"), "cloud snapshot does not include the selected microphone");
assert(audio.includes("if recordingHasStarted, !captureSession.isRunning || selectedOrDefaultInputMissing()"), "route-change handling should only cancel when capture has actually stopped or the device disappeared");
assert(!audio.includes("kAudioOutputUnitProperty_CurrentDevice"), "AVAudioEngine CurrentDevice hopping should not remain as the capture path");
assert(audio.includes("minimumVoicedDuration"), "no-speech guard is missing");
assert(audio.includes("minimumRecordingDuration"), "minimum recording duration guard is missing");
assert(audio.includes("guard stillCapturing else {\n            stopSessionIfNeeded(reset: false)\n            restoreDefaultInputIfNeeded()\n            let state = takeCaptureState()"), "abandoned audio starts do not tear down capture and restore the previous input");
assert(audio.includes('throw OpenflowError.transcriptionFailed("Could not prepare audio for transcription.")'), "audio conversion failure falls back to the raw microphone file");
assert(audio.includes("throw conversionError ?? OpenflowError.transcriptionFailed("), "audio conversion errors are not surfaced");
assert(audio.includes("self.file = nil\n            self.lock.unlock()\n            if self.captureSession.isRunning"), "WAV writer is not closed before AVCaptureSession.stopRunning");
assert(audio.includes("let state = takeCaptureState()\n        restoreDefaultInputIfNeeded()"), "default input is restored after the WAV file has been claimed");
assert(audio.includes("Converted audio was too short to transcribe."), "empty resampled upload audio is not rejected");
assert(audio.includes("pcmFormatInt16"), "upload WAV is not forced to 16-bit PCM");
assert(audio.includes("sampleRate: uploadSampleRate"), "upload WAV is not resampled to the Whisper sample rate");
assert(coordinator.includes("let captured = try audio.stop()\n                AudioServicesPlaySystemSound(1105)"), "release chime must not play until capture has stopped");
assert(!coordinator.includes("AudioServicesPlaySystemSound(1105)\n\n        Task"), "release chime still plays while AVCaptureSession is running");
assert(audio.includes("source.processingFormat.isEqual(destination.processingFormat)"), "compressed upload helper does not verify matching processing formats");
assert((audio.match(/removeCapturedFile\(at: url\)/g) ?? []).length >= 2, "abandoned start cleanup does not remove the local capture file");
assert(coordinator.includes("defer {\n                    try? FileManager.default.removeItem(at: captured.url)\n                }"), "captured audio is not deleted after transcription");
assert(coordinator.includes("removeStaleAudioFiles()"), "stale captured audio cleanup is not run at startup");
assert(coordinator.includes("forKeys: [.contentModificationDateKey, .isRegularFileKey]"), "stale audio sweep does not load the regular-file resource key");
assert(coordinator.includes("modificationDate < processStartDate"), "stale audio sweep is not limited to files older than process start");
assert(coordinator.includes("staleAudioMinimumAge"), "stale audio sweep has no age floor for another running copy");
assert(audio.includes("kAudioFormatMPEG4AAC"), "recordings above the upload byte ceiling are not re-encoded to AAC");
assert(audio.includes("maxUploadWAVBytes"), "upload byte ceiling for WAV recordings is missing");
assert(audio.includes("return (attributes?[.size] as? NSNumber)?.intValue ?? Int.max"), "unknown upload size does not fail closed");
assert(audio.includes("func discard()"), "recording cancellation has no cheap discard path");
assert(cloud.includes("private func audioDuration(at url: URL) -> Double?"), "cloud duration lookup is not format-aware");
assert(cloud.includes("AVAudioFile(forReading: url)"), "non-WAV duration does not use the audio file metadata");
assert(cloud.includes("reservation.uploadToken"), "staged upload token is not attached to the upload request");
assert(cloud.includes("caseInsensitiveCompare(Self.uploadTokenHeader)"), "upload token header name is not restricted to the expected header");
assert(cloud.includes('private static let uploadTokenHeader = "x-openflow-upload-token"'), "upload token header constant is missing");
assert(cloud.includes("private static let defaultSession"), "cloud service default session is not process-wide");
assert(cloud.includes("self.session = session"), "injected cloud session is not used as-is");
assert(cloud.includes("willPerformHTTPRedirection"), "cloud session does not vet HTTP redirects");
assert(cloud.includes("CloudURLPolicy.validate(\n                destination"), "cloud redirects do not use the URL policy");
assert(cloud.includes("completionHandler(nil)"), "untrusted cloud redirects are not rejected");
assert(cloud.includes("guard let originalHost = originalURL.host,\n              let destinationHost = destination.host,\n              originalHost.caseInsensitiveCompare(destinationHost) == .orderedSame else"), "cloud redirects are not restricted to the original host");
assert(!cloud.includes("credentialedRequest"), "cloud redirects still condition host pinning on credentials");

console.log("audio capture safety checks passed");
