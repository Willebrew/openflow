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
| Mail | AX focused/descendant | Verified when readable |
| Cursor/VS Code editor | Native key events, Unicode events | Usually unverified |

Failure criteria:

- History shows transcription success but insertion failure with no method.
- Pill shows success after `succeeded == false`.
- Clipboard contents change during insertion.
- The second try works but first try fails without a focus-race diagnostic.
- Arc, Chrome, Safari, or another browser freezes, beachballs, or becomes unresponsive during context capture or insertion. Browser insertion must not crawl the Accessibility tree; it should use typed-event strategies, then fail visibly.

For each failed target, open Settings -> Diagnostics -> Insertion reports and attach the newest JSON file. Reports must include `targetApp`, `targetBundleID`, `method`, `attemptCount`, `verified`, and `failureReason`, and must not include transcript text or audio bytes.

When a first attempt misses and the second attempt works, check the debug log and failed insertion report for `focus race before insertion`. If both are absent, treat the result as a focus-capture bug rather than an app-specific insertion bug.
