#!/usr/bin/env node
import fs from "node:fs";
import path from "node:path";

const root = path.resolve(import.meta.dirname, "..");
const hotkey = fs.readFileSync(path.join(root, "openflow/Services/HotkeyService.swift"), "utf8");
const policy = fs.readFileSync(path.join(root, "openflow/Services/HotkeyCapturePolicy.swift"), "utf8");
const probe = fs.readFileSync(path.join(root, "openflow/Services/TextInputFocusProbe.swift"), "utf8");
const flowUI = fs.readFileSync(path.join(root, "openflow/Views/FlowUI.swift"), "utf8");
const pill = fs.readFileSync(path.join(root, "openflow/App/FloatingDictationWindow.swift"), "utf8");
const sources = `${hotkey}\n${policy}\n${probe}\n${flowUI}\n${pill}`;

function fail(message) {
  console.error(`hotkey text-input safety check failed: ${message}`);
  process.exit(1);
}

function assert(condition, message) {
  if (!condition) fail(message);
}

assert(policy.includes("enum HotkeyCapturePolicy"), "HotkeyCapturePolicy is missing");
assert(policy.includes("if isFlagsChanged { return false }"), "policy must never swallow flagsChanged");
assert(policy.includes("if isTextInputActive && !isRecording { return false }"), "policy must not swallow while a text field is focused");
assert(policy.includes("static func shouldBeginAction(isTextInputActive: Bool, isModifierOnly: Bool)"), "policy must distinguish typed shortcuts from modifier-only PTT");
assert(policy.includes("if isModifierOnly { return true }"), "modifier-only PTT must start even when a text field is focused");
assert(probe.includes("enum TextInputFocusProbe"), "TextInputFocusProbe is missing");
assert(probe.includes("hasMarkedText()"), "probe must treat IME marked text as typing");
assert(probe.includes("kAXTextFieldRole"), "probe must check AX text field roles");
assert(probe.includes("kAXTextAreaRole"), "probe must check AX text area roles");
assert(hotkey.includes("HotkeyCapturePolicy.shouldSwallow"), "event tap must swallow only via HotkeyCapturePolicy");
assert(hotkey.includes("HotkeyCapturePolicy.shouldBeginAction"), "hotkey actions must consult HotkeyCapturePolicy");
assert(hotkey.includes("isModifierOnly: true"), "Fn/Option hold must begin via modifier-only policy");
assert(hotkey.includes("isModifierOnly: false"), "typed shortcuts must still respect text focus");
assert(hotkey.includes("TextInputFocusProbe.isTextInputActive()"), "hotkeys must probe text-input focus");
assert(hotkey.includes("Returning nil from this callback swallows the key for every app"), "tap callback must document that nil swallows globally");
assert(hotkey.includes("// Modifier-only push-to-talk is observational"), "flagsChanged path must stay observational");
assert(!sources.includes("RegisterEventHotKey"), "Carbon RegisterEventHotKey cannot respect text focus");
const textFieldBody = flowUI.slice(flowUI.indexOf("private struct FlowTextFieldBody"));
assert(!textFieldBody.includes("@FocusState"), "FlowTextFieldBody must not wrap fields in extra FocusState");
assert(flowUI.includes("Do not wrap in extra FocusState"), "FlowTextFieldStyle must keep the NQL-206 field-editor warning");
assert(pill.includes("becomesKeyOnlyIfNeeded = true"), "idle pill must not steal key status");
assert(pill.includes("ignoresMouseEvents = true"), "pill must default to click-through");

console.log("hotkey text-input safety checks passed");
