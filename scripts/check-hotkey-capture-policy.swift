import Foundation

@main
struct CheckHotkeyCapturePolicy {
    static func main() {
        assertPolicy(
            !HotkeyCapturePolicy.shouldSwallow(
                isFlagsChanged: true,
                isTextInputActive: false,
                isRecording: false,
                isMatchedHotkey: true
            ),
            "flagsChanged must never be swallowed"
        )
        assertPolicy(
            !HotkeyCapturePolicy.shouldSwallow(
                isFlagsChanged: true,
                isTextInputActive: true,
                isRecording: false,
                isMatchedHotkey: true
            ),
            "flagsChanged must still be observed when a text field is focused"
        )
        assertPolicy(
            !HotkeyCapturePolicy.shouldSwallow(
                isFlagsChanged: false,
                isTextInputActive: true,
                isRecording: false,
                isMatchedHotkey: true
            ),
            "matched hotkeys must pass through while a text field is focused"
        )
        assertPolicy(
            HotkeyCapturePolicy.shouldSwallow(
                isFlagsChanged: false,
                isTextInputActive: false,
                isRecording: false,
                isMatchedHotkey: true
            ),
            "matched hotkeys must swallow when the user is not typing"
        )
        assertPolicy(
            HotkeyCapturePolicy.shouldSwallow(
                isFlagsChanged: false,
                isTextInputActive: true,
                isRecording: true,
                isMatchedHotkey: true
            ),
            "PTT release may swallow while recording even if a field is focused"
        )
        assertPolicy(
            !HotkeyCapturePolicy.shouldSwallow(
                isFlagsChanged: false,
                isTextInputActive: false,
                isRecording: false,
                isMatchedHotkey: false
            ),
            "unmatched keys must never be swallowed"
        )
        assertPolicy(
            !HotkeyCapturePolicy.shouldBeginAction(isTextInputActive: true, isModifierOnly: false),
            "typed shortcuts must not start while typing"
        )
        assertPolicy(
            HotkeyCapturePolicy.shouldBeginAction(isTextInputActive: false, isModifierOnly: false),
            "typed shortcuts may start when not typing"
        )
        assertPolicy(
            HotkeyCapturePolicy.shouldBeginAction(isTextInputActive: true, isModifierOnly: true),
            "front app text field must still allow Fn flagsChanged to start PTT"
        )
        assertPolicy(
            HotkeyCapturePolicy.shouldBeginAction(isTextInputActive: false, isModifierOnly: true),
            "modifier-only PTT must start when not typing"
        )
        print("hotkey capture policy checks passed")
    }

    static func assertPolicy(_ condition: Bool, _ message: String) {
        if !condition {
            FileHandle.standardError.write(Data("hotkey capture policy check failed: \(message)\n".utf8))
            exit(1)
        }
    }
}
