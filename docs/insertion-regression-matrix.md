# Insertion Regression Matrix

Use this before any release candidate. A pass means the final text appears in the intended field and history records the insertion method.

Generate a structured local report:

```bash
scripts/insertion-regression-report.mjs init
```

Fill `docs/insertion-regression-report.json` while testing the targets below, then validate it:

```bash
scripts/insertion-regression-report.mjs validate
```

Production release candidates should run the local gate with the report required:

```bash
REQUIRE_MANUAL_INSERTION_REGRESSION=1 scripts/check-local-release-gate.sh
```

| Target | Expected strategy | Verification |
| --- | --- | --- |
| Arc text input | Native key events, Unicode events | Usually unverified |
| Arc textarea | Native key events, Unicode events | Usually unverified |
| ChatGPT/Codex input | Native key events, Unicode events | Usually unverified |
| Google Docs | Native key events, Unicode events | Usually unverified |
| Ghostty CLI | Native key events, Unicode events | Unverified |
| Terminal/iTerm | Native key events, Unicode events | Unverified |
| Messages | Unicode events, AX if available | Verified when readable |
| Notification Center banner reply (Messages/Slack/Reminders/FaceTime inline reply) | Focused AX selected text, then unicode events, then pasteboard swap; never activates the panel owner | Unverified |
| Mail | AX focused/descendant | Verified when readable |
| Notes / TextEdit | Focused AX | Verified. The dictated text appears once. |
| Electron host (Electron Framework.framework, for example Grok Bot) | Native key events, Unicode events | One insert. The captured accessibility value is not read back. |
| Cursor/VS Code editor | Native key events, Unicode events | Usually unverified |

Electron targets are detected by bundle layout, not bundle ID: `ElectronAppDetection`
looks for `Contents/Frameworks/Electron Framework.framework` in the target bundle and
its ancestors (Grok Bot ships as `com.anysphere.sand`). Electron hosts take the keyboard
path and never reach the AX strategies, so their captured nodes are not read back as
proof. For every target, a write call that reports success ends the attempt -- an
unverified or unreadable result does not start another strategy, because the text may
already be in the live field. `scripts/check-ax-insertion-policy.swift` and
`scripts/check-ax-insertion-safety.mjs` pin these rules.

Banner inline replies are owned by Notification Center, which is never
frontmost, so frontmost-app targeting both captures the wrong context and --
worse -- `activate()`ing the previous app at insert time drops key focus and
dismisses the reply panel. `FocusedTargetResolver` + `FocusedTargetPolicy`
read the system-wide focused element at hotkey time: a focused element owned
by a non-frontmost process marks the session as a non-activating-panel target
(Notification Center bundle ids classify as `.messages`; any other
non-frontmost owner only retargets when the element is editable). Context is
captured against the panel owner and the insert-time focus-race check is
skipped, since a panel is never frontmost. `TextInsertionService` then takes
a dedicated route entered before `restoreTargetApplication`: no `activate()`,
no `AXFrontmost`, no chrome clicks, no not-frontmost bail. Insert order is
AX `kAXSelectedTextAttribute` on the focused element, then unicode CGEvents
to the HID tap, then a pasteboard swap with restore. Keyboard fallbacks run
only while the panel still holds system focus, and automatic Return is always
suppressed for panel targets -- a sent reply is irreversible. The dictation
pill itself is a `NonActivatingPanel` (`canBecomeKey`/`canBecomeMain` false)
so it cannot steal the reply's focus. `scripts/check-focused-target-policy.swift`
pins the decision logic (macOS-only) and `scripts/check-notification-reply-insertion.mjs`
the no-activation rules; both run in `scripts/ci-linux.sh`.

Failure criteria:

- History shows transcription success but insertion failure with no method.
- The dictated text appears twice in the target field.
- Pill shows success after `succeeded == false`.
- Clipboard contents change during insertion.
- The second try works but first try fails without a focus-race diagnostic.
- A banner reply panel closes or loses focus during capture or insertion
  (an activation regression -- the panel route must never activate any app).
- Arc, Chrome, Safari, or another browser freezes, beachballs, or becomes unresponsive during context capture or insertion. Browser insertion must not crawl the Accessibility tree; it should use typed-event strategies, then fail visibly.

For each failed target, open Settings -> Diagnostics -> Insertion reports and attach the newest JSON file. Reports must include `targetApp`, `targetBundleID`, `method`, `attemptCount`, `verified`, and `failureReason`, and must not include transcript text or audio bytes.

When a first attempt misses and the second attempt works, check the debug log and failed insertion report for `focus race before insertion`. If both are absent, treat the result as a focus-capture bug rather than an app-specific insertion bug.
