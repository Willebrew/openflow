#!/usr/bin/env node
import fs from "node:fs";
import path from "node:path";

const root = path.resolve(import.meta.dirname, "..");
const insertion = fs.readFileSync(path.join(root, "openflow/Services/TextInsertionService.swift"), "utf8");
const cloud = fs.readFileSync(path.join(root, "openflow/Services/OpenFlowCloudService.swift"), "utf8");
const policy = fs.readFileSync(path.join(root, "openflow/Services/CommandSubmissionPolicy.swift"), "utf8");
const cleanup = fs.readFileSync(path.join(root, "openflow/Services/CleanupFormattingService.swift"), "utf8");
const pressEnter = fs.readFileSync(path.join(root, "openflow/Services/PressEnterCommand.swift"), "utf8");

function fail(message) {
  console.error(`terminal and cleanup safety check failed: ${message}`);
  process.exit(1);
}

function assert(condition, message) {
  if (!condition) fail(message);
}

const typingMarker = "switch await typeTextAsNativeKeyEvents(prepared)";
const confirmationMarker = "await confirmTerminalAutoSubmit(";
const confirmationCount = insertion.match(/await confirmTerminalAutoSubmit\(/g)?.length ?? 0;
assert(confirmationCount === 1, "terminal insertion prompts more than once");

// The confirmation gate must not depend on the app-name allowlist: it runs before the terminal
// branch and covers every category the policy does not positively mark safe.
assert(policy.includes('static func confirmationReason(category: AppCategory,'), "submission policy no longer exposes confirmationReason");
assert(policy.includes('if pressEnter { return .pressEnter }'), "submission policy does not confirm requested auto-submit");
assert(policy.includes("case multilineTyping"), "submission policy dropped the multi-line confirmation reason");
const safeCategories = policy.match(/autoSubmitSafeCategories: Set<AppCategory> = \[([^\]]*)\]/s)?.[1] ?? "";
assert(safeCategories.length > 0, "could not locate autoSubmitSafeCategories");
for (const unsafe of [".terminal", ".ide", ".generic"]) {
  assert(!safeCategories.includes(unsafe), `${unsafe} must never auto-submit without confirmation`);
}
assert(
  insertion.indexOf(confirmationMarker) < insertion.indexOf("if category == .terminal {"),
  "confirmation gate still runs inside the terminal-only branch"
);
assert(
  insertion.includes("let mayPressEnter = pressEnter && (submitConfirmationReason == nil || submitConfirmationShown)"),
  "insertion does not fail closed on an unconfirmed auto-submit"
);
assert(
  !/if pressEnter \{ sendEnter/.test(insertion),
  "an insertion path presses Return without passing the confirmation gate"
);
assert(
  !/if pressEnter \{\n\s+await submitTerminalEnterIfConfirmed/.test(insertion),
  "terminal submit path presses Return without passing the confirmation gate"
);
assert(insertion.includes('text.contains("\\n")'), "run-command confirmation omits embedded line-break detection");
assert(
  insertion.includes("prepared.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty"),
  "insertion no longer detects empty prepared text before pressing Return"
);
assert(insertion.includes("Unconfirmed auto-submit blocked."), "empty-text Return path is not gated");

// Dangerous-command suppression and submit intent must not depend on the category or on backend output.
assert(
  cleanup.includes("CommandSubmissionPolicy.containsDangerousCommand(copy.text)"),
  "cleanup no longer suppresses auto-enter for dangerous commands"
);
assert(
  !cleanup.includes("context.category == .terminal || context.category == .ide"),
  "dangerous-command suppression is still keyed on the app category"
);
assert(
  pressEnter.includes("pressEnter: fromRaw.matched"),
  "submit intent is not derived from the spoken transcript alone"
);
assert(
  !pressEnter.includes("fromCleaned.matched || fromRaw.matched"),
  "cleanup output can still set the submit flag"
);
assert(insertion.includes("embedded line breaks"), "run-command confirmation omits embedded line-break warning");
assert(insertion.includes("each one presses Return"), "run-command confirmation omits embedded Return execution warning");
assert(insertion.indexOf(confirmationMarker) < insertion.indexOf(typingMarker), "terminal confirmation runs after typing");
assert(insertion.indexOf("guard confirmed else") < insertion.indexOf(typingMarker), "terminal cancellation guard runs after typing");
assert(insertion.includes("Terminal insertion canceled by user."), "terminal cancellation does not return an insertion failure");
assert(insertion.includes("var submitConfirmationShown = false"), "submit confirmation state is not tracked");
assert(insertion.includes("guard await waitForTerminalFocus(processIdentifier: targetProcessIdentifier) else"), "terminal typing does not wait for focus after confirmation");
assert(insertion.includes("terminal focus not restored after confirmation"), "terminal focus failure does not fail closed");
assert(insertion.includes("private func waitForTerminalFocus(processIdentifier: pid_t?) async -> Bool"), "terminal focus polling helper is missing");
assert(!insertion.includes("confirmationAlreadyGranted"), "terminal insertion retains a second-prompt bypass");
assert(
  insertion.includes("not retyping to avoid duplicate entry"),
  "unchanged terminal text can be retyped"
);
const nativeTypingSwitchCount =
  insertion.match(/switch await typeTextAsNativeKeyEvents\(prepared\)/g)?.length ?? 0;
assert(nativeTypingSwitchCount === 5, "not every native typing call handles partial posts");
assert(
  !(insertion.match(/typeTextAsNativeKeyEvents\(prepared\)\)\.succeeded/g)?.length ?? 0),
  "native typing results can still collapse partial posts into a fallback"
);
const partialPostCaseCount =
  insertion.match(/case \.failedAfterPosting:/g)?.length ?? 0;
assert(partialPostCaseCount === 5, "partial native posts are not fail-closed at every call site");
assert(insertion.includes("partially posted; not retyping"), "partial native posts do not fail closed");
assert(insertion.includes("case .unreadable, .changedButUnverified:"), "lenient terminal verification cases were not preserved");
assert(cloud.includes("fileExists(atPath: audioURL.path)"), "missing audio files can mint upload reservations");
assert(cloud.includes("pressEnterVoiceCommandEnabled: settings.pressEnterCommandEnabled"), "cloud cleanup does not send the local pressEnter preference");
assert(cloud.includes("pressEnter: settings.pressEnterCommandEnabled && response.pressEnter"), "cloud cleanup response is not gated by the local pressEnter preference");
assert(
  cloud.includes("selectedText: settings.contextAwarenessEnabled ? context.selectedText : nil"),
  "cloud cleanup still uploads caret text when context awareness is off"
);

const context = fs.readFileSync(path.join(root, "openflow/Services/ContextService.swift"), "utf8");
assert(
  !context.includes("useContext ? classify("),
  "safety classification is still skipped when context awareness is off"
);
assert(
  context.includes("selectedText: useContext ? fieldContext.selectedText : nil"),
  "context awareness off still copies caret text into the cleanup context"
);

console.log("terminal and cleanup safety checks passed");
