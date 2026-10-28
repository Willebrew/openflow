#!/usr/bin/env node
import fs from "node:fs";
import path from "node:path";

const root = path.resolve(import.meta.dirname, "..");

function read(relativePath) {
  return fs.readFileSync(path.join(root, relativePath), "utf8");
}

function fail(message) {
  console.error(`notification reply insertion check failed: ${message}`);
  process.exit(1);
}

function assert(condition, message) {
  if (!condition) fail(message);
}

const policy = read("openflow/Services/FocusedTargetPolicy.swift");
const resolver = read("openflow/Services/FocusedTargetResolver.swift");
const insertion = read("openflow/Services/TextInsertionService.swift");
const coordinator = read("openflow/Services/DictationCoordinator.swift");
const context = read("openflow/Services/ContextService.swift");
const models = read("openflow/Models/DictationModels.swift");
const pill = read("openflow/App/FloatingDictationWindow.swift");

// Policy covers both Notification Center process identities.
assert(policy.includes("enum FocusedTargetPolicy"), "FocusedTargetPolicy is missing");
assert(policy.includes("com.apple.notificationcenterui"), "notificationcenterui bundle id missing");
assert(policy.includes("com.apple.usernotificationcenter"), "usernotificationcenter bundle id missing");
assert(policy.includes("suppressAutoEnter"), "policy must carry a suppressAutoEnter decision");
assert(policy.includes("isNonActivatingPanel"), "policy must carry an isNonActivatingPanel decision");
assert(!policy.includes("import AppKit"), "FocusedTargetPolicy must stay Foundation-only so it compiles in contract checks");

// Resolver reads the system-wide focused element and its pid.
assert(resolver.includes("AXUIElementCreateSystemWide"), "resolver must read the system-wide AX element");
assert(resolver.includes("kAXFocusedUIElementAttribute"), "resolver must read the system focused element");
assert(resolver.includes("AXUIElementGetPid"), "resolver must identify the focused element's owning pid");
assert(resolver.includes("AXUIElementSetMessagingTimeout"), "resolver AX reads must carry messaging timeouts");

// Insertion routes panel targets before any activation can happen.
const insertStart = insertion.indexOf("func insert(_ text: String,\n                pressEnter: Bool,");
assert(insertStart !== -1, "could not locate primary insert overload");
assert(
  insertion.indexOf("nonActivatingPanelTarget(preferredProcessIdentifier:", insertStart) <
    insertion.indexOf("restoreTargetApplication", insertStart),
  "the non-activating panel route must run before restoreTargetApplication"
);
const capturedStart = insertion.indexOf("func insert(_ text: String,\n                into element: AXUIElement");
assert(capturedStart !== -1, "could not locate captured-element insert overload");
assert(
  insertion.indexOf("nonActivatingPanelTarget(preferredProcessIdentifier:", capturedStart) <
    insertion.indexOf("restoreTargetApplication", capturedStart),
  "the captured-element overload must also route panels before activation"
);

const panelStart = insertion.indexOf("private func insertIntoNonActivatingPanel");
const panelEnd = insertion.indexOf("private func pasteTextViaPasteboardSwap");
assert(panelStart !== -1 && panelEnd !== -1 && panelEnd > panelStart, "panel insert body is missing");
const panel = insertion.slice(panelStart, panelEnd);
assert(!panel.includes("restoreTargetApplication"), "panel insert must never reactivate the previous app");
assert(!panel.includes("activate("), "panel insert must never call activate()");
assert(!panel.includes("kAXFrontmostAttribute"), "panel insert must never set AXFrontmost");
assert(!panel.includes("clickWindowContent"), "panel insert must never click window chrome");
assert(!panel.includes("prepareTargetForKeyboardInput"), "panel insert must not run the activation prep path");
assert(!panel.includes("sendEnter"), "panel insert must never send Return");
assert(panel.includes("mayPressEnter: false"), "AX finish path must disable Enter for panel targets");
assert(panel.includes("tryAXInsertion"), "panel insert must try AX selected-text first");
assert(panel.includes("typeTextWithKeyboardEvents"), "panel insert must fall back to unicode CGEvents");
assert(!panel.includes("postToPid"), "panel events must go to the HID tap, not a pid");
assert(panel.includes("systemFocusedElement(forProcess:"), "keyboard fallback must confirm the panel still holds focus");

const pasteStart = insertion.indexOf("private func pasteTextViaPasteboardSwap");
const pasteEnd = insertion.indexOf("private func targetDescription", pasteStart);
assert(pasteStart !== -1 && pasteEnd !== -1, "pasteboard fallback is missing");
const paste = insertion.slice(pasteStart, pasteEnd);
assert(paste.includes("clearContents()") && paste.includes("setString(text, forType: .string)"),
  "pasteboard swap must write the text");
assert(paste.includes("writeObjects(savedItems)"), "pasteboard swap must restore the previous contents");
assert(paste.includes(".cghidEventTap"), "paste Cmd+V must go to the HID tap");
assert(paste.includes("maskCommand"), "paste must post Cmd+V");
assert(!paste.includes("postToPid"), "paste must not target a pid");

// Coordinator resolves the real keyboard target at hotkey time and keeps it.
assert(coordinator.includes("FocusedTargetResolver.resolve(frontmostApp:"), "hotkey-time capture must resolve the system focused element");
assert(coordinator.includes("targetIsNonActivatingPanel"), "the session must remember panel targets");
assert(models.includes("var targetIsNonActivatingPanel: Bool"), "DictationSession needs the panel flag");
assert(coordinator.includes("context route: app="), "the context route log line is missing");
assert(!coordinator.includes("context route: app=\\(contextSnapshot.context.textBefore"), "context route must not log field text");

// Notification Center classifies as a casual message surface.
assert(
  context.indexOf('haystack.contains("notificationcenter")') < context.indexOf('haystack.contains("messages")'),
  "notification center must classify before the generic messages check"
);
assert(
  context.includes('haystack.contains("notificationcenter") || haystack.contains("usernotificationcenter") { return .messages }'),
  "notification center targets must classify as .messages"
);

// The pill can never take key status.
assert(pill.includes("final class NonActivatingPanel: NSPanel"), "pill must use a non-activating panel subclass");
assert(pill.includes("override var canBecomeKey: Bool { false }"), "pill panel must report canBecomeKey false");
assert(pill.includes(".nonactivatingPanel"), "pill must keep the nonactivatingPanel style mask");

console.log("notification reply insertion checks passed");
