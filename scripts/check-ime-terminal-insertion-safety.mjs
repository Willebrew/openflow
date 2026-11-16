#!/usr/bin/env node
import assert from "node:assert/strict";
import fs from "node:fs";

const read = (path) => fs.readFileSync(new URL(`../${path}`, import.meta.url), "utf8");
const layout = read("openflow/Services/KeyboardLayoutTranslator.swift");
const insertion = read("openflow/Services/TextInsertionService.swift");
const section = (start, end) => insertion.slice(insertion.indexOf(start), insertion.indexOf(end, insertion.indexOf(start)));

for (const property of ["kTISPropertyInputSourceCategory", "kTISPropertyInputSourceType", "kTISPropertyInputSourceIsASCIICapable"]) {
  assert(layout.includes(property), `input-source decision must check ${property}`);
}
assert(layout.includes("kTISCategoryKeyboardInputSource"));
assert(layout.includes("TISCopyCurrentASCIICapableKeyboardLayoutInputSource"), "preserve the user's ASCII layout, not a hardcoded US layout");
assert(layout.includes("TISSelectInputSource(original)"), "restore the retained original source");
const scope = section("private func withKeyboardInputSource", "private func typeTextWithKeyboardEvents");
assert.match(scope, /defer\s*\{[\s\S]*inputSource\.restore\(\)/, "restore on all operation exits");
assert(scope.indexOf("settle") < scope.indexOf("await operation()"), "settle before posting");
assert(scope.indexOf("await operation()") < scope.lastIndexOf("settle"), "drain before deferred restore");
assert(scope.includes("Task.detached"), "cancellation must not skip settling/draining");
assert(!scope.includes("sendEnter") && !scope.includes("keyCode: 36") && !scope.includes("keyCode: 53"), "never use Return or Escape to commit composition");
assert.match(scope, /if inputSource\.commitsWithEisu\s*\{\s*sendKey\(\.init\(keyCode: 0x66, flags: \[\]\)\)/, "Eisu must be gated to measured input methods");
assert(scope.indexOf("keyCode: 0x66") < scope.indexOf("inputSource.select()"), "commit before switching sources");
assert(scope.indexOf("inputSource.select()") < scope.indexOf("await operation()"));
for (const [name, end] of [["typeTextWithKeyboardEvents", "postTextWithKeyboardEvents"], ["typeTextAsNativeKeyEvents", "postTextAsNativeKeyEvents"]]) {
  const body = section(`private func ${name}`, `private func ${end}`);
  assert(body.includes("withKeyboardInputSource"), `${name} must guard its entire posting operation`);
  assert(body.indexOf("!text.isEmpty") < body.indexOf("withKeyboardInputSource"), "empty text must not commit composition or switch sources");
}
const terminal = section("if category == .terminal {", "await prepareTargetForKeyboardInput(processIdentifier: targetProcessIdentifier, clickWindowChrome: true)");
assert(terminal.includes("case .unchanged, .unreadable, .changedButUnverified:"), "unchanged must share uncertain-success handling");
assert(terminal.includes("targetIsFrontmost"), "uncertain success still requires target focus");
assert(terminal.includes("verified: false"));
assert(terminal.includes("failedAfterPosting"), "partial posting must fail without retry");
const poll = section("private func terminalTypingVerification", "private func terminalTextSnapshot");
assert(poll.includes("async -> TerminalTypingVerification"));
assert(poll.includes("0.5") && poll.includes("Task.sleep"), "readback polling must be bounded and yield");
assert(!/typeText|sendKey|sendEnter|postUnicode/.test(poll), "polling must never retype");
console.log("IME and terminal insertion safety checks passed");
