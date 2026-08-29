import AppKit

final class HotkeyService {
    var onBegin: ((DictationMode, Date) -> Void)?
    var onEnd: (() -> Void)?
    var onToggle: ((DictationMode) -> Void)?
    var onAccessChanged: ((Bool) -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var modifierPollTimer: Timer?
    private var isRecording = false
    private var lastOptionDown = false
    private var lastFnDown = false
    private var lastControlDown = false
    private var lastSpaceDown = false
    private var lastControlOptionDown = false
    private var pendingOptionStart: DispatchWorkItem?
    private var pendingOptionDownAt: Date?
    private var settingsProvider: (() -> UserSettings)?

    func start(settingsProvider: @escaping () -> UserSettings) {
        stop()
        self.settingsProvider = settingsProvider
        let settings = settingsProvider()
        // Only a swallowing tap needs Input Monitoring. Hold Fn is observational, so a
        // failed tap must not install keyDown monitors that trigger the TCC prompt.
        if settings.usesSwallowingHotkey {
            installEventTapIfPossible()
        }
        if eventTap == nil {
            onAccessChanged?(false)
            startModifierPolling()
        }
    }

    private func installEventTapIfPossible() {
        let mask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let service = Unmanaged<HotkeyService>.fromOpaque(refcon).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                DispatchQueue.main.async { [weak service] in
                    service?.enableEventTap()
                }
                return Unmanaged.passUnretained(event)
            }
            // Returning nil from this callback swallows the key for every app.
            if service.handle(type: type, event: event) {
                return nil
            }
            return Unmanaged.passUnretained(event)
        }
        eventTap = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                     place: .headInsertEventTap,
                                     options: .defaultTap,
                                     eventsOfInterest: CGEventMask(mask),
                                     callback: callback,
                                     userInfo: Unmanaged.passUnretained(self).toOpaque())
        guard let eventTap else { return }
        onAccessChanged?(true)
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        enableEventTap()
    }

    private func enableEventTap() {
        guard let eventTap else { return }
        CGEvent.tapEnable(tap: eventTap, enable: true)
    }

    func stop() {
        pendingOptionStart?.cancel()
        pendingOptionStart = nil
        pendingOptionDownAt = nil
        modifierPollTimer?.invalidate()
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFMachPortInvalidate(eventTap)
        }
        eventTap = nil
        runLoopSource = nil
        modifierPollTimer = nil
        settingsProvider = nil
        isRecording = false
        lastOptionDown = false
        lastFnDown = false
        lastControlDown = false
        lastSpaceDown = false
        lastControlOptionDown = false
    }

    private func startModifierPolling() {
        modifierPollTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.pollModifierState()
        }
        RunLoop.main.add(timer, forMode: .common)
        modifierPollTimer = timer
    }

    private func pollModifierState() {
        guard let settings = settingsProvider?() else { return }
        let optionDown = CGEventSource.keyState(.combinedSessionState, key: 58)
            || CGEventSource.keyState(.combinedSessionState, key: 61)
        let fnDown = CGEventSource.keyState(.combinedSessionState, key: 63)
        let controlDown = CGEventSource.keyState(.combinedSessionState, key: 59)
            || CGEventSource.keyState(.combinedSessionState, key: 62)
        let spaceDown = CGEventSource.keyState(.combinedSessionState, key: 49)
        let controlSpaceDown = controlDown && spaceDown
        let optionSpaceDown = optionDown && spaceDown
        let lastControlSpaceDown = lastControlDown && lastSpaceDown
        let lastOptionSpaceDown = lastOptionDown && lastSpaceDown

        let textActive = TextInputFocusProbe.isTextInputActive()
        let canBeginTyped = HotkeyCapturePolicy.shouldBeginAction(
            isTextInputActive: textActive,
            isModifierOnly: false
        )
        let canBeginModifier = HotkeyCapturePolicy.shouldBeginAction(
            isTextInputActive: textActive,
            isModifierOnly: true
        )

        if settings.pushToTalkHotkey == .optionHold {
            if optionDown && !lastOptionDown && !isRecording && canBeginModifier {
                scheduleOptionHoldStart(requestedAt: Date())
            } else if !optionDown && lastOptionDown {
                pendingOptionStart?.cancel()
                pendingOptionStart = nil
                pendingOptionDownAt = nil
                if isRecording {
                    isRecording = false
                    onEnd?()
                }
            }
        }

        if settings.pushToTalkHotkey == .fnHold {
            if fnDown && !lastFnDown && !isRecording && canBeginModifier {
                isRecording = true
                onBegin?(.dictation, Date())
            } else if !fnDown && lastFnDown && isRecording {
                isRecording = false
                onEnd?()
            }
        }

        if controlSpaceDown && !lastControlSpaceDown && canBeginTyped {
            if settings.toggleHotkey == .controlSpace {
                onToggle?(.dictation)
            } else if settings.pushToTalkHotkey == .controlSpace, !isRecording {
                isRecording = true
                onBegin?(.dictation, Date())
            }
        } else if settings.pushToTalkHotkey == .controlSpace, isRecording, lastSpaceDown, !spaceDown {
            isRecording = false
            onEnd?()
        }

        if optionSpaceDown && !lastOptionSpaceDown && canBeginTyped {
            if settings.pushToTalkHotkey == .optionSpace, !isRecording {
                isRecording = true
                onBegin?(.dictation, Date())
            }
        } else if settings.pushToTalkHotkey == .optionSpace, isRecording, lastSpaceDown, !spaceDown {
            isRecording = false
            onEnd?()
        }

        lastOptionDown = optionDown
        lastFnDown = fnDown
        lastControlDown = controlDown
        lastSpaceDown = spaceDown
    }

    private func handle(type: CGEventType, event: CGEvent) -> Bool {
        guard let settings = settingsProvider?() else { return false }
        if type == .flagsChanged {
            return handleFlagChange(event: event, settings: settings)
        } else if type == .keyDown {
            return handleKeyDown(event: event, settings: settings)
        } else if type == .keyUp {
            return handleKeyUp(event: event, settings: settings)
        }
        return false
    }

    private func handleFlagChange(event: CGEvent, settings: UserSettings) -> Bool {
        let flags = event.flags
        let optionDown = flags.contains(.maskAlternate)
        let fnDown = flags.contains(.maskSecondaryFn)
        let controlOptionDown = flags.contains(.maskControl) && flags.contains(.maskAlternate)
        let textActive = TextInputFocusProbe.isTextInputActive()
        let canBeginModifier = HotkeyCapturePolicy.shouldBeginAction(
            isTextInputActive: textActive,
            isModifierOnly: true
        )
        let shouldStart = (settings.pushToTalkHotkey == .fnHold && fnDown && !lastFnDown)
        let shouldEnd = (settings.pushToTalkHotkey == .fnHold && !fnDown && lastFnDown)
            || (settings.pushToTalkHotkey == .optionHold && !optionDown && lastOptionDown)
        if settings.pushToTalkHotkey == .optionHold && optionDown && !lastOptionDown && !isRecording && canBeginModifier {
            scheduleOptionHoldStart(requestedAt: Date())
        }
        if settings.pushToTalkHotkey == .optionHold && !optionDown {
            pendingOptionStart?.cancel()
            pendingOptionStart = nil
            pendingOptionDownAt = nil
        }
        if shouldStart && !isRecording && canBeginModifier {
            isRecording = true
            onBegin?(.dictation, Date())
        } else if shouldEnd && isRecording {
            isRecording = false
            onEnd?()
        }
        lastOptionDown = optionDown
        lastFnDown = fnDown
        lastControlOptionDown = controlOptionDown
        // Modifier-only push-to-talk is observational. Swallowing flagsChanged can
        // leave Command, Option, or Fn in a stale state for the rest of macOS.
        return HotkeyCapturePolicy.shouldSwallow(
            isFlagsChanged: true,
            isTextInputActive: textActive,
            isRecording: isRecording,
            isMatchedHotkey: false
        )
    }

    private func handleKeyDown(event: CGEvent, settings: UserSettings) -> Bool {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        if isRepeat { return false }
        let textActive = TextInputFocusProbe.isTextInputActive()
        let canBeginTyped = HotkeyCapturePolicy.shouldBeginAction(
            isTextInputActive: textActive,
            isModifierOnly: false
        )
        var matched = false
        if keyCode == 49 && flags.contains(.maskControl), settings.toggleHotkey == .controlSpace {
            if canBeginTyped {
                onToggle?(.dictation)
                matched = true
            }
        } else if keyCode == 49 && flags.contains(.maskControl), settings.pushToTalkHotkey == .controlSpace, !isRecording {
            if canBeginTyped {
                isRecording = true
                onBegin?(.dictation, Date())
                matched = true
            }
        } else if keyCode == 49 && flags.contains(.maskAlternate), settings.pushToTalkHotkey == .optionSpace, !isRecording {
            if canBeginTyped {
                isRecording = true
                onBegin?(.dictation, Date())
                matched = true
            }
        }
        return HotkeyCapturePolicy.shouldSwallow(
            isFlagsChanged: false,
            isTextInputActive: textActive,
            isRecording: isRecording,
            isMatchedHotkey: matched
        )
    }

    private func scheduleOptionHoldStart(requestedAt: Date) {
        pendingOptionStart?.cancel()
        pendingOptionDownAt = requestedAt
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.isRecording, self.lastOptionDown else { return }
            let textActive = TextInputFocusProbe.isTextInputActive()
            guard HotkeyCapturePolicy.shouldBeginAction(isTextInputActive: textActive, isModifierOnly: true) else { return }
            self.isRecording = true
            self.onBegin?(.dictation, self.pendingOptionDownAt ?? requestedAt)
            self.pendingOptionDownAt = nil
        }
        pendingOptionStart = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.035, execute: work)
    }

    private func handleKeyUp(event: CGEvent, settings: UserSettings) -> Bool {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags
        let textActive = TextInputFocusProbe.isTextInputActive()
        var matched = false
        if keyCode == 49 && settings.pushToTalkHotkey == .controlSpace && isRecording {
            isRecording = false
            onEnd?()
            matched = true
        } else if keyCode == 49 && settings.pushToTalkHotkey == .optionSpace && isRecording {
            isRecording = false
            onEnd?()
            matched = true
        }
        _ = flags
        return HotkeyCapturePolicy.shouldSwallow(
            isFlagsChanged: false,
            isTextInputActive: textActive,
            isRecording: matched || isRecording,
            isMatchedHotkey: matched
        )
    }

    func markStopped() {
        isRecording = false
        lastFnDown = false
        lastOptionDown = false
        lastControlDown = false
        lastSpaceDown = false
        lastControlOptionDown = false
        pendingOptionStart?.cancel()
        pendingOptionStart = nil
        pendingOptionDownAt = nil
    }
}
