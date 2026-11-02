# Output Formatting Guards

The cleanup pipeline is trust-but-verify: the model's answer passes through a
deterministic guard layer before it reaches the target field, and any stage can
fall back to local cleanup. This page covers what each guard does and when it
fires; read it before changing `CleanupFormattingService` or the dictation
pipeline in `DictationCoordinator`.

## Silence hallucination filter

Whisper pads near-silent clips with stock phrases ("Thank you.", "Thanks for
watching", "You", "Bye"). `SilenceHallucinationFilter.isSilenceHallucination`
runs in `DictationCoordinator` before cleanup and insertion: when the audio is
under 1.5 seconds and the normalized transcript is one of the stock phrases,
nothing is inserted and the pill shows "No speech detected" for ~1.4s. The
phrase list is deliberately short -- only add a phrase a silent clip could
never plausibly contain.

## Cleanup length guard

Remote cleanup occasionally expands a short utterance into an essay or
collapses a long one to nothing. `CleanupLengthGuard.passes` checks the cleaned
result against the raw transcript:

- Cleaned output may not exceed `raw * 1.5 + 8` words. The expansion check is
  skipped for styles that intentionally rewrite a short utterance into a longer
  document (`.emailLetter` and custom styles -- see
  `allowsExpansion(context:)`).
- Cleaned output may not drop below half the raw word count unless the raw
  transcript carries a self-correction cue that could explain a real rewrite
  (`CleanupLengthGuard.selfCorrectionMarkers`: "scratch that", "i mean",
  "change that to", ...). The same marker list drives
  `CleanupFormattingService`'s own self-correction detection, so both checks
  agree on what counts as a cue.

A failed guard returns `localFallback` (deterministic `fastClean`), not an
error -- the user still gets cleaned text, just not the misbehaving remote
result. The guard applies to all three remote-cleanup outcomes: parsed JSON,
recovered non-JSON content, and the normal path.

## Style resolution: personal messages default to casual

`UserSettings` resolves the effective style per app category. For `.personal`
(personal messages) an `Auto` preset resolves to `.casual` rather than the
global default, so dictated texts are not punctuated like email. An explicit
preset or a custom style stays authoritative -- only `Auto` is remapped.

## Pipeline formatters

`CleanupFormattingService.formatted` runs these in order for every category
except `.terminal` and every preset except `.rawTranscript`:

1. `SelfCorrectionFormatter` -- honors "scratch that" style spoken edits.
2. `ListFormatter` -- list-aware line breaks.
3. `CasualMessagesFormatter` -- a single-sentence reply in a `.messages`
   context with the `.casual` preset drops its trailing period; multi-sentence
   output and abbreviations keep punctuation, and custom styles are untouched.
4. `MidSentenceCasingFormatter` -- when the field's `text_before` ends
   mid-sentence (a letter or a comma), Whisper's leading capital is wrong and
   is lowercased. Protected: "I" and `I'`-contractions, all-caps acronyms
   ("NASA"), names with internal capitals ("iPhone"), and any word capitalized
   again later in the same output (a proper noun, not a sentence start).

`.emailLetter` output then goes through `EmailLetterFormatter` afterwards.

## Transcript privacy

Transcript content never lands in the debug log: `DictationCoordinator`
records word and character counts only, and the silence-hallucination
diagnostic logs audio duration plus character count -- never the text itself.
Keep it that way when adding diagnostics anywhere past the transcription
boundary.

## Verification

The `openflowTests` XCTest target (wired into the shared `openflow` scheme)
covers the silence filter, casual-period stripping, the length guard,
mid-sentence casing, warm-up throttling, and messages style resolution:

```sh
xcodebuild -project openflow.xcodeproj -scheme openflow test
```
