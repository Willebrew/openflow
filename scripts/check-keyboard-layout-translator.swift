import Carbon.HIToolbox
import Foundation

// Native key insertion uses US ANSI key codes only when the active layout types
// the same character with that key. These fixtures read installed layouts
// directly, so no live keyboard switching is needed.

private var failures: [String] = []

private func expect(_ condition: Bool, _ message: String) {
    if !condition { failures.append(message) }
}

private func layout(_ id: String) -> KeyboardLayoutTranslator {
    guard let layout = KeyboardLayoutTranslator(inputSourceID: id) else {
        fputs("missing keyboard layout \(id)\n", stderr)
        exit(1)
    }
    return layout
}

private let keyA: CGKeyCode = 0
private let keyZ: CGKeyCode = 6
private let keyQ: CGKeyCode = 12
private let keyY: CGKeyCode = 16
private let key1: CGKeyCode = 18
private let keyEquals: CGKeyCode = 24
private let keyLeftBracket: CGKeyCode = 33

@main
struct CheckKeyboardLayoutTranslator {
    static func main() {
        let us = layout("com.apple.keylayout.US")
        expect(us.character(forKeyCode: keyA, shift: false) == "a", "US key A types a")
        expect(us.character(forKeyCode: keyA, shift: true) == "A", "US shift+A types A")
        expect(us.character(forKeyCode: key1, shift: true) == "!", "US shift+1 types !")
        expect(us.character(forKeyCode: keyLeftBracket, shift: false) == "[", "US [ key types [")

        let french = layout("com.apple.keylayout.French")
        expect(french.character(forKeyCode: keyA, shift: false) == "q", "AZERTY: US A position types q")
        expect(french.character(forKeyCode: keyQ, shift: false) == "a", "AZERTY: US Q position types a")
        expect(french.character(forKeyCode: key1, shift: false) == "&", "AZERTY: unshifted 1 key types &")
        expect(french.character(forKeyCode: key1, shift: true) == "1", "AZERTY: shift+1 key types 1")
        expect(french.character(forKeyCode: keyLeftBracket, shift: false) == nil, "AZERTY: circumflex dead key is rejected")

        let german = layout("com.apple.keylayout.German")
        expect(german.character(forKeyCode: keyY, shift: false) == "z", "QWERTZ: US Y position types z")
        expect(german.character(forKeyCode: keyZ, shift: false) == "y", "QWERTZ: US Z position types y")
        expect(german.character(forKeyCode: keyEquals, shift: false) == nil, "QWERTZ: acute dead key is rejected")

        let dvorak = layout("com.apple.keylayout.Dvorak")
        expect(dvorak.character(forKeyCode: keyQ, shift: false) == "'", "Dvorak: US Q position types '")

        expect(KeyboardLayoutTranslator(inputSourceID: "com.example.missing-layout") == nil, "unknown layout is unavailable")

        if failures.isEmpty {
            print("keyboard layout translator checks passed")
        } else {
            failures.forEach { fputs("FAIL: \($0)\n", stderr) }
            exit(1)
        }
    }
}
