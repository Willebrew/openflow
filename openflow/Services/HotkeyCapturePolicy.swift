import Foundation

/// Single swallow decision for the global CGEvent tap.
/// Returning nil from the tap callback consumes the key in every app.
enum HotkeyCapturePolicy {
    static func shouldSwallow(
        isFlagsChanged: Bool,
        isTextInputActive: Bool,
        isRecording: Bool,
        isMatchedHotkey: Bool
    ) -> Bool {
        if isFlagsChanged { return false }
        if !isMatchedHotkey { return false }
        if isTextInputActive && !isRecording { return false }
        return true
    }

    /// Typed shortcuts (Control+Space, Option+Space) must not start while a field is focused.
    /// Modifier-only PTT (Fn, Option hold) is observational and must start in any app.
    static func shouldBeginAction(isTextInputActive: Bool, isModifierOnly: Bool) -> Bool {
        if isModifierOnly { return true }
        return !isTextInputActive
    }
}
