import Foundation

/// Pure decision layer for "which process owns the dictation target".
///
/// Notification Center inline replies (and other non-activating panels) hold
/// the system focused element without ever becoming frontmost. Frontmost-app
/// targeting both captures the wrong context and, worse, `activate()`ing the
/// previous app at insert time drops key focus and dismisses the reply panel.
///
/// This type only decides; `FocusedTargetResolver` performs the AX reads that
/// feed it, which keeps the policy unit-testable without AppKit.
enum FocusedTargetPolicy {
    struct Decision: Equatable {
        /// True when the dictation target lives in a non-activating panel
        /// owned by a process other than the frontmost app. Such targets must
        /// never be activated, raised, or sent `AXFrontmost`.
        var isNonActivatingPanel: Bool
        /// True when an automatic Return must never be posted. A notification
        /// reply is an irreversible send, so panel targets always suppress it;
        /// the same conservative rule covers unidentified panel owners.
        var suppressAutoEnter: Bool
        /// The process the insert should target. `nil` means keep the
        /// frontmost app.
        var retargetedProcessIdentifier: pid_t?
    }

    /// Notification Center owns the banner inline-reply field. The process
    /// name has changed across macOS releases; cover both.
    static let notificationCenterBundleIDs: Set<String> = [
        "com.apple.notificationcenterui",
        "com.apple.usernotificationcenter"
    ]

    static func isNotificationCenter(bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return notificationCenterBundleIDs.contains(bundleID.lowercased())
    }

    /// Process identities that are known to host non-activating reply UI.
    static func isNonActivatingPanelOwner(bundleID: String?) -> Bool {
        isNotificationCenter(bundleID: bundleID)
    }

    /// Decide whether the system focused element redirects the dictation
    /// target away from the frontmost app.
    ///
    /// - Parameters:
    ///   - frontmostPID: `NSWorkspace.shared.frontmostApplication` pid.
    ///   - ownPID: openflow's own pid; its windows must never become targets.
    ///   - focusedElementPID: pid owning the system-wide focused element, if any.
    ///   - focusedElementBundleID: bundle id of that process, when known.
    ///   - focusedElementIsEditable: whether that element accepts text input.
    /// - Returns: The routing decision for capture and insertion.
    static func decide(frontmostPID: pid_t?,
                       ownPID: pid_t,
                       focusedElementPID: pid_t?,
                       focusedElementBundleID: String?,
                       focusedElementIsEditable: Bool) -> Decision {
        let frontmost = Decision(isNonActivatingPanel: false,
                                 suppressAutoEnter: false,
                                 retargetedProcessIdentifier: nil)
        guard let focusedPID = focusedElementPID,
              focusedPID != frontmostPID,
              focusedPID != ownPID else {
            return frontmost
        }
        if isNotificationCenter(bundleID: focusedElementBundleID) {
            return Decision(isNonActivatingPanel: true,
                            suppressAutoEnter: true,
                            retargetedProcessIdentifier: focusedPID)
        }
        // Any other process that holds the system focused element without
        // being frontmost is a non-activating panel too (Spotlight-style
        // fields, other agents' reply UI). Only retarget when the element is
        // actually editable, and apply the same no-Return policy since the
        // surface cannot be positively identified as safe to submit.
        guard focusedElementIsEditable else { return frontmost }
        return Decision(isNonActivatingPanel: true,
                        suppressAutoEnter: true,
                        retargetedProcessIdentifier: focusedPID)
    }
}
