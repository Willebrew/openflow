#!/usr/bin/env node
import fs from "node:fs";
import path from "node:path";

const root = path.resolve(import.meta.dirname, "..");

function read(relativePath) {
  return fs.readFileSync(path.join(root, relativePath), "utf8");
}

function fail(message) {
  console.error(`ax insertion safety check failed: ${message}`);
  process.exit(1);
}

function assert(condition, message) {
  if (!condition) fail(message);
}

const insertion = read("openflow/Services/TextInsertionService.swift");
const policy = read("openflow/Services/AXInsertionPolicy.swift");

const start = insertion.indexOf("private func tryAXInsertion");
const end = insertion.indexOf("private func spacingAdjusted", start);
assert(start !== -1 && end !== -1, "could not locate tryAXInsertion");
const body = insertion.slice(start, end);

assert(body.includes("await AXInsertionPolicy.resolveTracing"), "selected-text insertion does not consult the delayed-apply policy");
assert(
  body.indexOf("await AXInsertionPolicy.resolveTracing") < body.lastIndexOf("replaceAXValue"),
  "AXValue replacement can run before the delayed readback"
);
assert(
  body.indexOf("acceptWithoutProof") < body.indexOf("await AXInsertionPolicy.resolveTracing"),
  "a successful Electron write can still reread and replace AXValue"
);
assert(
  body.includes("AXInsertionPolicy.shouldReplaceWholeValue"),
  "a late apply is not checked before the second write"
);
assert(
  !body.includes("before == nil || stringValue(in: element) != before"),
  "immediate readback is still trusted as proof the write was dropped"
);
assert(policy.includes("case recheckLater"), "delayed recheck decision is missing");
assert(policy.includes("maxDelayedSamples"), "delayed recheck budget is missing");
assert(
  policy.includes('if valueAfter != valueBefore { return .acceptSelectedText }'),
  "a changed value must accept the selected-text write"
);
assert(
  policy.includes("if sampleIndex < maxDelayedSamples { return .recheckLater }"),
  "an unchanged readback must recheck before replacing the whole value"
);
assert(
  policy.includes("case .unreadable, .unverified:\n            return .stop(verified: false)"),
  "an unverified successful write must not start another strategy"
);
assert(policy.includes("trustSuccessDespiteUnchangedReadback"), "stale captured readback is not handled");
assert(
  read("openflow/Services/ElectronAppDetection.swift").includes("Electron Framework.framework"),
  "Electron detection does not look for Electron Framework.framework"
);

const capturedStart = insertion.indexOf("func insert(_ text: String,\n                into element: AXUIElement");
const capturedEnd = insertion.indexOf("private func result(method:", capturedStart);
assert(capturedStart !== -1 && capturedEnd !== -1, "could not locate captured insertion");
const captured = insertion.slice(capturedStart, capturedEnd);
assert(
  captured.indexOf("electronTarget || shouldPreferKeyboardInsertion") < captured.indexOf("tryAXInsertion"),
  "Electron can write the captured element before the keyboard route"
);
assert(
  captured.includes("label: \"captured\""),
  "captured insertion does not log the attempt"
);
assert(
  insertion.includes("selectedText=\\(attempt.selectedText) decision=\\(attempt.decision) rereads=\\(attempt.rereadCount) replace=\\(attempt.replaceRan) verify=\\(verifyLog) fallback="),
  "insertion diagnostics omit the write, decision, reread count, replace flag, verify result, or fallback reason"
);
assert(!insertion.includes("logInsertion(text"), "insertion diagnostics can log dictated text");
assert(!captured.includes("case .unverified:\n                    break"), "unverified captured writes still fall through to a second insert");

const candidatesStart = insertion.indexOf("private func insertionCandidates");
const candidatesEnd = insertion.indexOf("private func editableDescendants", candidatesStart);
assert(candidatesStart !== -1 && candidatesEnd !== -1, "could not locate insertionCandidates");
const candidates = insertion.slice(candidatesStart, candidatesEnd);
assert(
  candidates.includes("!isFocusedElement(element)"),
  "descendant scan outside the focused element can write into unfocused toolbar or sidebar fields"
);

const refocusStart = insertion.indexOf("private func refocusCapturedElement");
const refocus = insertion.slice(refocusStart, insertion.indexOf("\n    }\n", refocusStart));
assert(
  refocus.indexOf("selectedRange(in: element) != nil") !== -1
    && refocus.indexOf("selectedRange(in: element) != nil") < refocus.indexOf("kAXPressAction"),
  "captured element refocus can press a non-text control such as a color well"
);

const contextService = read("openflow/Services/ContextService.swift");
for (const root of ["window", "axApp"]) {
  assert(
    contextService.includes(`descendantSelectionSnapshot(from: ${root}, requireFocus: true)`),
    `context capture can take an unfocused ${root} control as the dictation target`
  );
}
const focusedStart = contextService.indexOf("private func focusedTextContext");
const focusedBody = contextService.slice(focusedStart, contextService.indexOf("private func usableFieldSnapshot", focusedStart));
assert(
  focusedBody.indexOf("let range = selectedRange(in: element)") !== -1
    && focusedBody.indexOf("let range = selectedRange(in: element)") < focusedBody.indexOf("descendantSelectionSnapshot(from: window"),
  "an empty focused text field falls through to a window-wide search"
);

console.log("ax insertion safety checks passed");
