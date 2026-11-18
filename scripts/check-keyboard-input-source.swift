@main
struct CheckKeyboardInputSource {
    static func main() {
        for keyboard in [false, true] {
            for layout in [false, true] {
                for ascii in [false, true] {
                    precondition(KeyboardInputSourcePolicy.requiresOverride(isKeyboard: keyboard,
                                                                            isLayout: layout,
                                                                            isASCII: ascii) == !(keyboard && layout && ascii))
                }
            }
        }
        precondition(KeyboardInputSourcePolicy.commitsWithEisu(sourceID: "com.apple.inputmethod.Kotoeri.RomajiTyping.Japanese"))
        precondition(KeyboardInputSourcePolicy.commitsWithEisu(sourceID: "com.apple.inputmethod.SCIM.ITABC"))
        for sourceID in ["", "com.apple.keylayout.German", "com.apple.keylayout.ABC", "com.apple.inputmethod.SCIM.WBX", "third.party.IME"] {
            precondition(!KeyboardInputSourcePolicy.commitsWithEisu(sourceID: sourceID))
        }
        print("keyboard input source policy checks passed")
    }
}
