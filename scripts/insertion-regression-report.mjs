#!/usr/bin/env node
import fs from "node:fs";
import path from "node:path";
import process from "node:process";

const root = path.resolve(import.meta.dirname, "..");
const reportPath = path.join(root, "docs", "insertion-regression-report.json");

const targets = [
  {
    id: "arc-input",
    target: "Arc website text input",
    expectedStrategies: ["nativeKeyEvents", "unicodeKeyEvents"],
    verification: "best_effort_unverified_allowed"
  },
  {
    id: "arc-textarea",
    target: "Arc website textarea",
    expectedStrategies: ["nativeKeyEvents", "unicodeKeyEvents"],
    verification: "best_effort_unverified_allowed"
  },
  {
    id: "chatgpt-codex-input",
    target: "ChatGPT or Codex input",
    expectedStrategies: ["nativeKeyEvents", "unicodeKeyEvents"],
    verification: "best_effort_unverified_allowed"
  },
  {
    id: "google-docs-editor",
    target: "Google Docs or custom web editor",
    expectedStrategies: ["nativeKeyEvents", "unicodeKeyEvents"],
    verification: "best_effort_unverified_allowed"
  },
  {
    id: "ghostty-cli",
    target: "Ghostty CLI prompt",
    expectedStrategies: ["nativeKeyEvents", "unicodeKeyEvents"],
    verification: "best_effort_unverified_allowed"
  },
  {
    id: "terminal-iterm",
    target: "Terminal or iTerm prompt",
    expectedStrategies: ["nativeKeyEvents", "unicodeKeyEvents"],
    verification: "best_effort_unverified_allowed"
  },
  {
    id: "messages",
    target: "Messages compose field",
    expectedStrategies: ["unicodeKeyEvents", "capturedAX", "focusedAX"],
    verification: "verified_when_readable"
  },
  {
    id: "mail",
    target: "Mail composer",
    expectedStrategies: ["capturedAX", "focusedAX", "descendantAX"],
    verification: "verified_when_readable"
  },
  {
    id: "cursor-vscode-editor",
    target: "Cursor or VS Code editor",
    expectedStrategies: ["nativeKeyEvents", "unicodeKeyEvents"],
    verification: "best_effort_unverified_allowed"
  },
  {
    id: "windsurf-devin-ide",
    target: "Windsurf or Devin-style IDE input",
    expectedStrategies: ["nativeKeyEvents", "unicodeKeyEvents"],
    verification: "best_effort_unverified_allowed"
  }
];

const usage = `Usage:
  scripts/insertion-regression-report.mjs init
  scripts/insertion-regression-report.mjs validate [path]

The report is local release evidence. Fill every case with:
  status: "pass" | "fail"
  insertionSucceeded: boolean
  method: one of the expected methods
  attemptCount: number
  clipboardChanged: false
  secondTryRequired: false unless a focus-race diagnostic is recorded
  diagnosticsPath: required for failures
`;

const command = process.argv[2];

if (command === "init") {
  if (fs.existsSync(reportPath) && !process.argv.includes("--force")) {
    fail(`${relative(reportPath)} already exists. Use --force to overwrite.`);
  }
  const now = new Date().toISOString();
  const report = {
    schemaVersion: 1,
    generatedAt: now,
    releaseCandidate: "",
    tester: "",
    notes: "Do not include transcript text or audio. Attach only local diagnostic metadata paths for failures.",
    cases: targets.map((target) => ({
      ...target,
      status: "untested",
      insertionSucceeded: null,
      verified: null,
      method: "",
      attemptCount: null,
      failureReason: "",
      clipboardChanged: null,
      secondTryRequired: null,
      focusRaceDiagnosticPresent: null,
      diagnosticsPath: "",
      notes: ""
    }))
  };
  fs.writeFileSync(reportPath, `${JSON.stringify(report, null, 2)}\n`);
  console.log(`created ${relative(reportPath)}`);
} else if (command === "validate") {
  validate(process.argv[3] ? path.resolve(process.argv[3]) : reportPath);
} else {
  console.log(usage);
  process.exit(command ? 1 : 0);
}

function validate(filePath) {
  if (!fs.existsSync(filePath)) fail(`missing report: ${relative(filePath)}`);
  const report = JSON.parse(fs.readFileSync(filePath, "utf8"));
  if (report.schemaVersion !== 1) fail("unsupported report schema");
  if (!report.releaseCandidate) fail("releaseCandidate is required");
  if (!Array.isArray(report.cases)) fail("cases array is required");

  const byID = new Map(report.cases.map((item) => [item.id, item]));
  for (const target of targets) {
    const item = byID.get(target.id);
    if (!item) fail(`missing case: ${target.id}`);
    if (item.status !== "pass" && item.status !== "fail") fail(`${target.id} is not tested`);
    if (item.clipboardChanged !== false) fail(`${target.id} changed the clipboard or did not record clipboard status`);
    if (!Number.isInteger(item.attemptCount) || item.attemptCount < 1) fail(`${target.id} has invalid attemptCount`);
    if (!target.expectedStrategies.includes(item.method)) {
      fail(`${target.id} used unexpected method '${item.method}'`);
    }
    if (item.status === "pass") {
      if (item.insertionSucceeded !== true) fail(`${target.id} passed without insertionSucceeded=true`);
      if (item.secondTryRequired === true && item.focusRaceDiagnosticPresent !== true) {
        fail(`${target.id} required a second try without focus-race diagnostic`);
      }
    } else {
      if (!item.failureReason) fail(`${target.id} failed without failureReason`);
      if (!item.diagnosticsPath) fail(`${target.id} failed without diagnosticsPath`);
      if (/transcript|audioBase64|rawTranscript/i.test(JSON.stringify(item))) {
        fail(`${target.id} failure report appears to include transcript/audio data`);
      }
    }
  }
  console.log(`validated ${relative(filePath)}`);
}

function relative(filePath) {
  return path.relative(root, filePath);
}

function fail(message) {
  console.error(`insertion regression report failed: ${message}`);
  process.exit(1);
}
