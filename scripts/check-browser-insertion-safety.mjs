#!/usr/bin/env node
import fs from "node:fs";
import path from "node:path";

const root = path.resolve(import.meta.dirname, "..");

function read(relativePath) {
  return fs.readFileSync(path.join(root, relativePath), "utf8");
}

function fail(message) {
  console.error(`browser insertion safety check failed: ${message}`);
  process.exit(1);
}

function assert(condition, message) {
  if (!condition) fail(message);
}

const context = read("openflow/Services/ContextService.swift");
const insertion = read("openflow/Services/TextInsertionService.swift");

const focusedElementMarker = "if AXUIElementCopyAttributeValue(axApp, kAXFocusedUIElementAttribute as CFString, &focused) == .success";
assert(context.includes(focusedElementMarker), "context capture does not read the focused AX element");
assert(context.includes("FieldTextWindow.slice"), "context capture does not slice field text around the caret");
assert(context.includes("mergeFieldText"), "context capture cannot refresh field text for cleanup");
assert(
  context.includes("if isBrowser {\n            let range = fallbackElement.flatMap { selectedRange(in: $0) }"),
  "browsers must skip descendant AX walks after the focused element"
);
assert(
  !context.includes("if isBrowser {\n            return (nil, nil, nil, nil, nil, true, nil)\n        }"),
  "browsers still skip focused-field AX context"
);
assert(context.includes("searchDescendants,\n               !isBrowser"), "browser focused context can still walk descendants");

const currentURLStart = context.indexOf("func currentURL(bundleID: String) -> String?");
const currentURLEnd = context.indexOf("private func cachedURL", currentURLStart);
assert(currentURLStart !== -1 && currentURLEnd !== -1, "could not locate BrowserContextService.currentURL");
const currentURLBody = context.slice(currentURLStart, currentURLEnd);
assert(!currentURLBody.includes("executeAndReturnError"), "currentURL runs AppleScript synchronously on the caller path");
assert(currentURLBody.includes("scheduleRefreshIfNeeded"), "currentURL does not schedule async refresh");

const refreshBody = context.slice(context.indexOf("private func scheduleRefreshIfNeeded"), context.indexOf("private func scriptSource"));
assert(refreshBody.includes("DispatchQueue.global"), "browser URL refresh is not offloaded from the caller path");

const preparedMarker = "let browserTarget = isBrowserApp()";
const browserBlockMarker = "if browserTarget {";
const focusedAXMarker = "if let focused {";
const insertionCandidatesMarker = "for candidate in insertionCandidates";
assert(insertion.includes(preparedMarker), "insertion does not classify browser target before spacing adjustment");
assert(insertion.includes("if !browserTarget {\n            focused = focusedElement()\n        }"), "browser insertion can read focused AX element before typed events");
const browserBlockIndex = insertion.indexOf(browserBlockMarker);
const focusedAXIndex = insertion.indexOf(focusedAXMarker);
const insertionCandidatesIndex = insertion.indexOf(insertionCandidatesMarker);
assert(browserBlockIndex !== -1, "browser typed-event block is missing");
assert(focusedAXIndex !== -1, "focused AX fallback block is missing");
assert(browserBlockIndex < focusedAXIndex, "browser path can try focused AX before typed events");
assert(browserBlockIndex < insertionCandidatesIndex, "browser path can reach descendant AX scan before typed events");

const browserBlock = insertion.slice(browserBlockIndex, focusedAXIndex);
assert(browserBlock.includes("typeTextAsNativeKeyEvents"), "browser path does not try native key events");
assert(browserBlock.includes("typeTextWithKeyboardEvents"), "browser path does not try Unicode key events");
assert(browserBlock.includes("return .failed"), "browser path can fall through into descendant AX scanning");

console.log("browser insertion safety checks passed");
