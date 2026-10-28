import Foundation

@main
struct CheckFocusedTargetPolicy {
    static func main() {
        testFocusedElementInFrontmostAppStaysFrontmost()
        testMissingFocusedElementStaysFrontmost()
        testFocusedElementInOwnProcessStaysFrontmost()
        testNotificationCenterReplyRetargets()
        testUserNotificationCenterReplyRetargets()
        testNotificationCenterBundleIDIsCaseInsensitive()
        testEditableFocusInAnotherProcessRetargets()
        testNonEditableFocusInAnotherProcessStaysFrontmost()
        testNotificationReplyNeverAutoEnters()
        print("focused target policy checks passed")
    }

    private static func testFocusedElementInFrontmostAppStaysFrontmost() {
        let decision = FocusedTargetPolicy.decide(frontmostPID: 100,
                                                  ownPID: 999,
                                                  focusedElementPID: 100,
                                                  focusedElementBundleID: "com.apple.notificationcenterui",
                                                  focusedElementIsEditable: true)
        expect(!decision.isNonActivatingPanel, "focus inside the frontmost app must not retarget")
        expect(decision.retargetedProcessIdentifier == nil, "frontmost focus keeps the frontmost target")
        expect(!decision.suppressAutoEnter, "frontmost focus does not suppress Return")
    }

    private static func testMissingFocusedElementStaysFrontmost() {
        let decision = FocusedTargetPolicy.decide(frontmostPID: 100,
                                                  ownPID: 999,
                                                  focusedElementPID: nil,
                                                  focusedElementBundleID: nil,
                                                  focusedElementIsEditable: false)
        expect(!decision.isNonActivatingPanel, "no focused element means the frontmost app stays the target")
    }

    private static func testFocusedElementInOwnProcessStaysFrontmost() {
        let decision = FocusedTargetPolicy.decide(frontmostPID: 100,
                                                  ownPID: 999,
                                                  focusedElementPID: 999,
                                                  focusedElementBundleID: "com.neuroquestlabs.openflow",
                                                  focusedElementIsEditable: true)
        expect(!decision.isNonActivatingPanel, "openflow's own focused element must not retarget")
    }

    private static func testNotificationCenterReplyRetargets() {
        let decision = FocusedTargetPolicy.decide(frontmostPID: 100,
                                                  ownPID: 999,
                                                  focusedElementPID: 555,
                                                  focusedElementBundleID: "com.apple.notificationcenterui",
                                                  focusedElementIsEditable: true)
        expect(decision.isNonActivatingPanel, "a Notification Center reply field must retarget away from frontmost")
        expect(decision.retargetedProcessIdentifier == 555, "the retargeted pid must be Notification Center's")
        expect(decision.suppressAutoEnter, "notification replies must never receive an automatic Return")
    }

    private static func testUserNotificationCenterReplyRetargets() {
        let decision = FocusedTargetPolicy.decide(frontmostPID: 100,
                                                  ownPID: 999,
                                                  focusedElementPID: 556,
                                                  focusedElementBundleID: "com.apple.usernotificationcenter",
                                                  focusedElementIsEditable: true)
        expect(decision.isNonActivatingPanel, "the UserNotificationCenter process must retarget too")
        expect(decision.suppressAutoEnter, "UserNotificationCenter replies must never receive an automatic Return")
    }

    private static func testNotificationCenterBundleIDIsCaseInsensitive() {
        expect(FocusedTargetPolicy.isNotificationCenter(bundleID: "Com.Apple.NotificationCenterUI"),
               "bundle id matching must be case-insensitive")
        expect(FocusedTargetPolicy.isNonActivatingPanelOwner(bundleID: "com.apple.notificationcenterui"),
               "notificationcenterui must be a known panel owner")
        expect(!FocusedTargetPolicy.isNotificationCenter(bundleID: "com.apple.MobileSMS"),
               "the Messages app itself is not a panel owner")
        expect(!FocusedTargetPolicy.isNotificationCenter(bundleID: nil),
               "a missing bundle id is not a panel owner")
    }

    private static func testEditableFocusInAnotherProcessRetargets() {
        let decision = FocusedTargetPolicy.decide(frontmostPID: 100,
                                                  ownPID: 999,
                                                  focusedElementPID: 777,
                                                  focusedElementBundleID: "com.example.agentpanel",
                                                  focusedElementIsEditable: true)
        expect(decision.isNonActivatingPanel, "an editable system-focused element in a non-frontmost process is a panel target")
        expect(decision.retargetedProcessIdentifier == 777, "the retargeted pid must be the element owner's")
        expect(decision.suppressAutoEnter, "unidentified panel surfaces get the same no-Return policy")
    }

    private static func testNonEditableFocusInAnotherProcessStaysFrontmost() {
        let decision = FocusedTargetPolicy.decide(frontmostPID: 100,
                                                  ownPID: 999,
                                                  focusedElementPID: 777,
                                                  focusedElementBundleID: "com.example.agentpanel",
                                                  focusedElementIsEditable: false)
        expect(!decision.isNonActivatingPanel, "a non-editable element in another process must not retarget")
    }

    private static func testNotificationReplyNeverAutoEnters() {
        // Sending a text is irreversible, so notification panel targets
        // suppress Return even when the policy input claims editability and a
        // known messaging surface. Every panel decision must suppress it.
        let nc = FocusedTargetPolicy.decide(frontmostPID: 100,
                                            ownPID: 999,
                                            focusedElementPID: 555,
                                            focusedElementBundleID: "com.apple.notificationcenterui",
                                            focusedElementIsEditable: true)
        let generic = FocusedTargetPolicy.decide(frontmostPID: nil,
                                                 ownPID: 999,
                                                 focusedElementPID: 555,
                                                 focusedElementBundleID: nil,
                                                 focusedElementIsEditable: true)
        expect(nc.suppressAutoEnter && generic.suppressAutoEnter,
               "no non-activating panel target may ever receive an automatic Return")
        expect(nc.isNonActivatingPanel && generic.isNonActivatingPanel,
               "panel decisions must be marked non-activating")
    }

    private static func expect(_ condition: Bool, _ message: String) {
        guard condition else {
            FileHandle.standardError.write(Data("focused target policy check failed: \(message)\n".utf8))
            exit(1)
        }
    }
}
