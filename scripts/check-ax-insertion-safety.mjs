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

assert(body.includes("await AXInsertionPolicy.resolve"), "selected-text insertion does not consult the delayed-apply policy");
assert(
  body.indexOf("await AXInsertionPolicy.resolve") < body.lastIndexOf("return replaceAXValue"),
  "AXValue replacement can run before the delayed readback"
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

console.log("ax insertion safety checks passed");
