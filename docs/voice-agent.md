# Voice Agent (Jev)

Dictating with no text field focused routes the spoken instruction to the Jev
voice agent instead of typing it. The agent serializes the frontmost app's
accessibility tree, asks the openflow backend for the next action, performs
it, and repeats until the goal is done, aborted, or the step cap is hit.

This subsystem is the sanctioned replacement for the removed "operator"
runtime: `scripts/verify-production-readiness.sh` fails the build if the old
route returns. It needs the same Microphone + Accessibility grants as
dictation plus a signed-in openflow account -- every step is a cloud call, so
a missing session aborts the run and recovers the transcript as a normal
dictation (see "Transcript recovery").

The moving parts:

| Piece | Role |
| --- | --- |
| `TextInputFocusProbe` strict probes | Strict AX probes deciding text field vs no text field |
| `VoiceAgentRouting` | Pure dictate-vs-agent policy, unit-testable without AX |
| `ScreenStateService` | Flattens the frontmost app's AX tree into actionable elements |
| `JevAgentService` | Step loop: capture -> ask -> act -> settle |
| `AgentActionExecutor` | Performs one action (AX first, CGEvent fallback) |
| `OpenFlowCloudService.agentStep` | `POST /openflow/agent/step` decision call |

## Routing: two probes, any doubt dictates

`VoiceAgentRouting.decide(voiceAgentEnabled:probeAtStart:probeAtEnd:)` is the
whole policy:

- Settings > Voice agent off (`UserSettings.voiceAgentEnabled`, default on)
  always dictates.
- A `.textInput` start probe always dictates, even if the end probe
  disagrees. The start probe launches at dictation start inside
  `attachSessionContext` via `axStrictDecisionAsync(timeout: 1.5)` so its
  AX tree opt-in has the whole utterance to take effect.
- The end probe (`strictDecisionAsync(timeout: 0.6)`) must answer
  `.noTextInput` to route to the agent. `.inconclusive` -- AX errors,
  timeouts, a refused focused-element read, generic roles -- dictates, so a
  spoken transcript is never fed to the agent by mistake.

The strict probe is deliberately stricter than `isTextInputActive()`: bare
`AXSelectedTextRange`/`AXEditable` only count on roles web content actually
reports them for, because Chromium and Electron expose those attributes on
non-text elements and a loose read would mark every focused window a text
box. The AX half runs off the main thread and races a sleeper task, so a
wedged frontmost app degrades to `.inconclusive` at the bound instead of
stalling dictation.

## The step loop

Each step is `ScreenStateService.capture()` ->
`cloud.agentStep(state:questions:...)` -> `AgentActionExecutor.execute` ->
settle -> repeat.

- `maxSteps = 16`. Per step the model answers eight questions:
  `task_complete`, `action`, `element`, `key`, `direction`, `text`, `app`,
  `url`.
- `task_complete` is a noul score; `>= 0.75` ends the run complete.
- `action` is one of `done`, `click`, `type`, `press_key`, `scroll`,
  `open_app`, `open_url`, `abort`.
- Confidence under `0.5` aborts the step -- except `open_app`/`open_url`,
  which are cheap and reversible. `rescueAction` also overrides a hedged
  abort or low-confidence pick when the goal names a URL or app, or the
  model already picked a concrete element/text target.
- The same action signature three times aborts as "stuck repeating".
  Element ids renumber per capture, so click/type signatures sign on the
  element's serialized form, not the id.
- Steps settle 800 ms; `open_app`/`open_url` settle 1500 ms so the next
  capture sees the newly frontmost window instead of the stale one.

`onProgress` streams "Step N: <detail>" into the pill subtitle.

## Screen capture contract

`ScreenStateService` needs Accessibility only -- it never reads pixels, so no
Screen Recording grant is involved.

- Sets `AXEnhancedUserInterface` + `AXManualAccessibility` on the app
  element so Chromium/Electron populate their web AX tree. A sparse walk
  (fewer than 6 actionable elements) retries once after 400 ms.
- Walk budget: `maxDepth 22` (Electron buries `AXWebArea` under ~7 levels of
  chrome `AXGroup`s), `maxVisited 1200`, `maxElements 80`, over the focused
  window (or the first two `AXWindows`) plus the menu bar tree.
- Messaging timeouts are 0.15 s on the app element and 0.1 s per element;
  a hung target app yields fewer elements instead of blocking the loop.
- `serialized()` emits `[id] role "title" (desc) value="" focused @(x,y)`
  per element, capped at 60 lines in the request, plus frontmost app,
  window title, and sorted running-app names.

## Execution

`AgentActionExecutor` prefers AX actions and falls back to posted CGEvents:
clicks try `AXPress` then a mouse click at the frame center; `type` focuses
then sets `AXValue`, else posts Unicode key events; `press_key` and
`scroll` are CGEvent-only.

- `open_app` resolves in order: frontmost short-circuit, `appAliases`
  bundle ids, running apps by exact name, running apps by substring
  (>= 4 chars only -- "our" must not match Sourcetree), then the app
  directories exact and substring. "settings"/"preferences" map to System
  Settings; "spotlight" posts Cmd+Space.
- `open_url` prepends `https://` to bare domains. An `open_app` answer that
  looks like a domain is redirected to `open_url`, and an appearance goal
  plus a settings app name deep-links the Appearance pane. A failed
  `x-apple.systempreferences` link falls back to opening System Settings.

### Destructive confirmation

`looksDestructive` regex-matches element text for delete/remove/erase/send/
submit/purchase/buy/pay/checkout/sign out/log out/empty trash/format/
discard/overwrite. A destructive `click` -- or `return`/`delete` while a
destructive element is focused -- first runs an NSAlert ("Allow"/"Stop").
Declining fails the step and aborts the run.

## Cloud call

`agentStep` posts `/openflow/agent/step` with the session `Bearer` token and
`X-Openflow-Device-ID`. The body carries `state` (goal, step number,
previous_actions, serialized screen, running_apps), the `questions` spec,
`model`, `target_app_name`, and `target_bundle_id`; the backend holds
TYPESAFE_API_KEY and proxies the TypeSafe System One decision. A non-empty
`model` in the response updates the next step's model.

`agent_step_unavailable` maps to "The voice agent is unavailable right now."
A 401 throws `cloudSessionRevoked`, which aborts the run from inside
`JevAgentService.run` -- it does not route through
`confirmRemoteCloudRevocation`; it becomes an ordinary abort plus
transcript recovery.

## Transcript recovery and results

`VoiceAgentRouting.needsTranscriptRecovery` is `!completed || steps <= 0`:
the run never consumed the instruction, so the transcript is copied to the
clipboard first, then sent through `finishInsertion` (cleanup, insertion,
history) as an ordinary dictation. The clipboard write comes first so a
failed recovery insertion still cannot lose the transcript.

A completed run writes no `DictationHistoryItem` and never touches
`lifetime.json` -- the agent acted on the instruction, so there is no
transcript to record or count. Metrics still land:
`insertionMethod = "voice-agent"`, `insertionAttempts = steps`,
`insertionVerified = completed`, plus provider/model. The pill runs
"Working" -> step progress -> "Done".

## Field debugging

Grep `DiagnosticsLog` for `routing probe at start|end` (probe reports and
elapsed), `routing to voice agent`, `agent run start`, `agent step N
state:` (the full serialized tree), `agent step N answers:` (complete /
action / confidence / element / key / app / url), `agent step N executed`,
`voice agent finished`, and `voice agent fallback`.

## Verification

`scripts/check-voice-agent-safety.swift` pins the probe timeout bound, the
routing table, the transcript-recovery predicate, and the transcribe-fast
wire contract. `scripts/ci-linux.sh` compiles it against the real sources
on macOS runners; `scripts/verify-production-readiness.sh` requires
the check to exist and bans the removed operator runtime.
