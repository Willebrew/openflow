# Voice Agent (Jev)

## Goal

Dictation normally ends by typing the cleaned transcript into a focused text
field. When no text input is focused -- both at the start of dictation and
again when transcription finishes -- openflow treats the transcript as an
instruction instead and hands it to the Jev voice agent: a local loop that
drives the frontmost app through the accessibility (AX) tree. Jev (TypeSafe
System One) decides each step; the openflow backend holds `TYPESAFE_API_KEY`
and proxies the calls, so no agent credential lives on the Mac.

The feature is on by default via `UserSettings.voiceAgentEnabled` (Settings ->
"Voice agent"). The flag is deliberately not part of
`CloudPreferencesSnapshot`, so a synced preferences payload cannot enable it
remotely -- the same treatment as `contextAwarenessEnabled` and
`pressEnterCommandEnabled`.

## Routing

`DictationCoordinator` decides per dictation:

- `attachSessionContext` records `session.textInputWasFocused` using
  `TextInputFocusProbe.strictDecision()` when dictation starts and writes the
  probe report to the diagnostics log.
- After transcription, `shouldRunVoiceAgent` returns false when the toggle is
  off or a text input was focused at the start. Otherwise it probes again:
  if a text input is focused now, the session continues down the normal
  cleanup/insertion path; if not, `runVoiceAgent` takes over and the
  transcript is never cleaned up or inserted.

The strict probe is intentionally narrower than `isTextInputActive()`, the
loose hotkey probe. The loose probe accepts a bare `AXSelectedTextRange` or
`AXEditable` on any element, which Chromium and Electron apps expose on
non-text controls -- for routing, that would send every browser window to the
agent. The strict probe requires a text role (`AXTextField`, `AXTextArea`,
`AXComboBox`, `AXSearchField`, `AXSecureTextField`, `AXTextView`), the
search-field subrole, marked (IME) text, or `AXEditable` on a small allowlist
of editable-capable roles (`AXWebArea`, `AXGroup`, `AXScrollArea`,
`AXUnknown`, `AXTextField`, `AXTextArea`). `strictDecision()` also returns a
one-line signal dump (`strict=no-text appKit=0 axTrusted=1 app=Arc
role=AXWebArea ...`) so the log shows exactly why routing decided what it
did.

## The step loop

`JevAgentService.run(instruction:settings:baseURL:)` runs at most
`maxSteps` (16) iterations:

1. `ScreenStateService.capture()` serializes the frontmost app's AX tree
   into numbered actionable elements plus the list of running apps.
2. `OpenFlowCloudService.agentStep` `POST`s `/openflow/agent/step` with
   `{state, questions, model, target_app_name, target_bundle_id}`. `state`
   carries the goal, the step counter ("n of 16"), the action log so far, the
   serialized screen, and running apps; `questions` is the typed question map
   described below.
3. The answers are gated (below), then `AgentActionExecutor` performs the
   chosen action.
4. The loop sleeps 800 ms between steps -- 1500 ms after `open_app` /
   `open_url`, which take longer to land -- and repeats.

A run ends when `task_complete` scores >= 0.75, the model chooses `done` or
`abort`, a gate fails, an action reports failure, or the 16-step cap is
reached. `AgentRunResult` reports `completed`, a human-readable `summary`,
the step count, provider `typesafe`, and the model name (`jev-latest` unless
the response overrides it).

Per step the request evaluates eight questions: `task_complete` (a `noul`
score), `action` (choice over `done` / `click` / `type` / `press_key` /
`scroll` / `open_app` / `open_url` / `abort`), plus `element`, `key`,
`direction`, `text`, `app`, and `url` as `choice` questions whose criteria
list the legal answers. Criteria keys carry the answer itself -- for `text`
the candidates are a quoted span from the instruction, the text after a
typing verb, or the whole instruction, so Jev picks from what the user said
and cannot generate free text.

### Gates and bailouts

- `task_complete.noul >= 0.75`: done.
- `action == done`: done. `action == abort`: abort, unless rescued.
- `action.confidence < 0.5`: abort as "not confident enough", unless rescued.
  `open_app` and `open_url` are exempt from the confidence floor because
  they are cheap and reversible.
- Rescue: when the model hedges (abort, or under the confidence floor) the
  loop still takes a cheap reversible step itself when the goal names a URL
  (rescues to `open_url`), names an app (`open_app`), or when the model
  already chose a concrete element (`type` when text was picked, otherwise
  `click`).
- Repeat guard: proposing an identical action signature three steps in a row
  aborts as "stuck repeating". Element ids renumber each capture, so click
  and type signatures use the element's serialized form, not its id.
- Any `!outcome.ok` from the executor aborts with its detail string.

## Screen state

`ScreenStateService.capture()` requires `AXIsProcessTrusted()`; without it
the run aborts immediately as "Accessibility permission is off". It needs no
Screen Recording grant -- only the AX tree is read, never pixels.

- Sets `AXEnhancedUserInterface` and `AXManualAccessibility` on the target
  app: Chromium and Electron apps withhold their web AX tree until an
  assistive client opts in. If the first walk finds fewer than 6 elements
  (the withheld-tree signature), it retries once after 400 ms.
- AX messaging timeouts: 0.15 s on the app element and 0.1 s per element, so
  a hung app cannot stall the main thread for the ~6 s AX default.
- Walks the focused window -- or the first two windows when none is focused
  (common on Electron) -- plus the menu bar, which is a separate tree.
- Budget: depth <= 14, <= 1200 nodes visited, <= 80 elements collected,
  deduplicated on `role|title|center x|center y`; `serialized()` sends at
  most 60 lines to the model and summarizes the rest as
  `... N more elements not listed`.
- Only actionable roles are kept (buttons, checkboxes, radio and pop-up
  buttons, menu items and menu buttons, links, text fields and areas,
  sliders, combo and search boxes, tabs, cells, rows, disclosure triangles,
  incrementors, switches). Each
  renders as `[id] AXRole "title" (description) value="..." focused @(x,y)`
  with text truncated at 80 characters.

## Executing actions

`AgentActionExecutor` prefers direct AX calls and falls back to posting
`CGEvent` input at the element's frame center:

| Action | AX path | CGEvent / fallback |
| --- | --- | --- |
| `click` | `AXUIElementPerformAction(kAXPressAction)` | left down/up at center |
| `type` | set `AXFocused`, then write `AXValue` | Unicode key events |
| `press_key` | -- | key-code down/up |
| `scroll` | -- | scroll-wheel event at the element, focused element, or screen center |
| `open_app` | -- | `NSWorkspace` activate/launch |
| `open_url` | -- | `NSWorkspace.open` |

`press_key` maps these names: `return`/`enter`, `tab`, `escape`/`esc`,
`space`, `delete`/`backspace`, the four arrows, `home`, `end`, `pageup`,
`pagedown`.

`open_app` resolution, in order: already frontmost (short-circuit) -> known
bundle id (`appAliases` maps 51 spoken names like "imessage", "arc",
"ghostty") -> running-app name match (exact, then substring on 4+
characters) -> installed `.app` search across `/Applications`,
`/Applications/Utilities`, `/System/Applications`,
`/System/Applications/Utilities`, and `~/Applications`. The name "spotlight"
posts Cmd+Space instead. A domain-looking answer (e.g. "google" parsed from
"go to google.com") reroutes to `open_url`, and a settings target in an
appearance instruction ("dark mode") opens the Appearance pane deep link
directly. `open_url` adds `https://` to bare domains and falls back to
launching System Settings when an `x-apple.systempreferences:` deep link
fails.

## Destructive-action confirm

`AgentActionExecutor.looksDestructive` matches an element's title,
description, and role against `delete|remove|erase|send|submit|purchase|buy|
pay|checkout|sign out|log out|empty trash|format|discard|overwrite`. A click
on a matching element -- or a `return`/`delete` keypress while a matching
element is focused -- first shows a modal `NSAlert` ("Allow" / "Stop").
Declining aborts that step, which ends the run as a failure.

## Cloud call

`agentStep` goes through the shared `post` helper, so it requires a stored
NQL Auth session: the request carries `Authorization: Bearer` plus
`X-Openflow-Device-ID`, and the base URL passes
`CloudURLPolicy.validateServiceBaseURL`. With no signed-in session it throws
`cloudAuthenticationRequired` before any network call; a 401 throws
`cloudSessionRevoked` (see `docs/cloud-mode.md`). Any step-request error,
including those two, aborts the run with the error's localized description as
the summary shown on the pill. The server error code
`agent_step_unavailable` maps to "The voice agent is unavailable right now.
Please try again shortly."

Provider mode does not gate routing: a bring-your-own-Groq user still routes
out-of-field dictation to the agent, but the step call fails without a
signed-in openflow session.

## Results, history, and the pill

- `agent.onProgress` writes each step's detail into the pill subtitle
  ("Step n: ..."); the pill shows "Working" during the run, then "Done" or
  "Stopped", and resets to "Ready" about a second later.
- Session metrics record `insertionMethod = "voice-agent"`,
  `insertionVerified = result.completed`, `insertionAttempts = result.steps`,
  `provider`, `model`, and `insertionFailureReason = result.summary` on
  abort.
- Runs never call `history.add` / `recordLifetime`: they produced no text
  insertion, so they must not appear in transcription history or skew
  lifetime stats.

## Diagnostics

`DiagnosticsLog` is a separate always-on log -- unlike the in-memory
`debugLog` (200 lines, gated on the Debug logs toggle), every line lands in
`~/Library/Application Support/openflow/openflow-debug.log`, rotating by
keeping the newest ~256 KB tail once the file passes ~512 KB. Settings ->
Diagnostics has an "Open Log File" button that reveals it in Finder.

Useful greps:

- `focus probe at dictation start:` and `routing:` -- the routing verdict
  with the strict-probe signal dump.
- `agent run start` and `agent step` -- per-step frontmost app, element
  count, serialized state, raw answers, and the executed outcome.
- `voice agent finished` -- `completed`, step count, and the summary shown
  on the pill.
