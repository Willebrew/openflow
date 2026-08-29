import Foundation

/// Decides when openflow may press Return, or type text containing Return, on the user's behalf.
///
/// Both the inserted text and the auto-submit decision are derived from remote cleanup output,
/// which is untrusted: the backend can be compromised and the cleanup model can be prompt-injected
/// through the field text captured around the caret. Confirmation is therefore the default and the
/// app-name allowlist is the exception -- only categories that are positively identified as message,
/// document, or search surfaces submit without asking. Terminal name detection is best-effort help
/// for formatting, never the security boundary.
enum CommandSubmissionPolicy {
    enum ConfirmationReason: Equatable {
        case pressEnter
        case multilineTyping
    }

    /// Categories whose focused field submits content instead of executing it.
    static let autoSubmitSafeCategories: Set<AppCategory> = [
        .messages,
        .email,
        .docs,
        .aiChat,
        .browserSearch,
        .projectManagement
    ]

    /// Command fragments whose unattended execution is destructive or remotely controlled.
    static let dangerousCommandFragments = [
        "rm -rf",
        "diskutil erase",
        "sudo ",
        "chmod -r",
        "chown -r",
        " dd ",
        "curl ",
        "wget ",
        "| bash",
        "| sh",
        "| zsh",
        "mkfs",
        "shutdown ",
        "killall ",
        "launchctl ",
        "osascript",
        "eval "
    ]

    static func allowsUnconfirmedAutoSubmit(category: AppCategory) -> Bool {
        autoSubmitSafeCategories.contains(category)
    }

    /// Shell syntax that a dictated sentence practically never contains, used to spot command text
    /// typed into a target openflow could not identify as a terminal.
    static let shellSyntaxFragments = ["|", "&&", "||", ";", "$(", "`", ">>", "2>", "sudo", "curl", "chmod"]

    static func containsDangerousCommand(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return dangerousCommandFragments.contains(where: { lowered.contains($0) })
    }

    static func looksLikeShellCommand(_ text: String) -> Bool {
        if containsDangerousCommand(text) { return true }
        let lowered = text.lowercased()
        return shellSyntaxFragments.contains(where: { lowered.contains($0) })
    }

    /// The confirmation openflow must show before the insertion can press Return, or `nil` when the
    /// target is a known-safe submit surface and no Return is involved.
    static func confirmationReason(category: AppCategory,
                                   pressEnter: Bool,
                                   text: String) -> ConfirmationReason? {
        guard !allowsUnconfirmedAutoSubmit(category: category) else { return nil }
        if pressEnter { return .pressEnter }
        let containsLineBreak = text.contains("\n")
        guard containsLineBreak else { return nil }
        if category == .terminal || looksLikeShellCommand(text) { return .multilineTyping }
        return nil
    }
}
