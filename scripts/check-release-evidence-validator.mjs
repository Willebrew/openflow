#!/usr/bin/env node
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";

const root = path.resolve(import.meta.dirname, "..");
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "openflow-release-evidence-"));

function fail(message) {
  console.error(`release evidence validator self-check failed: ${message}`);
  process.exit(1);
}

try {
  const appPath = path.join(tmp, "openflow.app");
  const zipPath = path.join(tmp, "openflow.zip");
  const shaPath = path.join(tmp, "openflow.zip.sha256");
  fs.mkdirSync(appPath);
  fs.writeFileSync(zipPath, "zip");
  fs.writeFileSync(shaPath, "sha");

  const matrixPath = path.join(tmp, "insertion-regression-report.json");
  const matrixCases = [
    ["arc-input", "Arc website text input", "nativeKeyEvents"],
    ["arc-textarea", "Arc website textarea", "nativeKeyEvents"],
    ["chatgpt-codex-input", "ChatGPT or Codex input", "nativeKeyEvents"],
    ["google-docs-editor", "Google Docs or custom web editor", "nativeKeyEvents"],
    ["ghostty-cli", "Ghostty CLI prompt", "nativeKeyEvents"],
    ["terminal-iterm", "Terminal or iTerm prompt", "nativeKeyEvents"],
    ["messages", "Messages compose field", "unicodeKeyEvents"],
    ["mail", "Mail composer", "focusedAX"],
    ["cursor-vscode-editor", "Cursor or VS Code editor", "nativeKeyEvents"],
    ["windsurf-devin-ide", "Windsurf or Devin-style IDE input", "nativeKeyEvents"]
  ].map(([id, target, method]) => ({
    id,
    target,
    expectedStrategies: [method],
    verification: "self_check",
    status: "pass",
    insertionSucceeded: true,
    verified: false,
    method,
    attemptCount: 1,
    failureReason: "",
    clipboardChanged: false,
    secondTryRequired: false,
    focusRaceDiagnosticPresent: false,
    diagnosticsPath: "",
    notes: ""
  }));
  fs.writeFileSync(matrixPath, `${JSON.stringify({
    schemaVersion: 1,
    generatedAt: "2026-06-29T00:00:00.000Z",
    releaseCandidate: "self-check",
    tester: "automated",
    notes: "Self-check fixture with no transcript or audio payloads.",
    cases: matrixCases
  }, null, 2)}\n`);

  const validEvidence = {
    schemaVersion: 1,
    releaseCandidate: "self-check",
    date: "2026-06-29",
    reviewer: "automated",
    localGate: { passed: true, command: "scripts/check-local-release-gate.sh", notes: "" },
    convexCloud: { deployment: "prod:test", verifyCloudBackendPassedWithDeployment: true, notes: "" },
    manualInsertionMatrix: { reportPath: matrixPath, validated: true, notes: "" },
    cloudEndToEnd: {
      convexSiteURL: "https://example.invalid",
      stripeWebhookVerified: true,
      nqlAuthSubscriptionSyncVerified: true,
      convexEntitlementSyncVerified: true,
      cloudTranscriptionWithoutLocalKeyVerified: true,
      cloudCleanupWithoutLocalKeyVerified: true,
      expiredSubscriptionBlocksGroqVerified: true,
      serverPayloadRetentionChecked: true,
      notes: ""
    },
    cleanInstall: {
      onboardingOpened: true,
      microphonePermissionRecoveredWithoutRelaunch: true,
      accessibilityPermissionRecoveredWithoutRelaunch: true,
      inputMonitoringNotRequired: true,
      settingsPersistedAfterRestart: true,
      notes: ""
    },
    releaseArtifact: {
      appPath,
      zipPath,
      sha256Path: shaPath,
      signed: true,
      notarized: true,
      stapled: true,
      spctlAccepted: true,
      notes: ""
    }
  };

  const evidencePath = path.join(tmp, "release-evidence.json");
  fs.writeFileSync(evidencePath, `${JSON.stringify(validEvidence, null, 2)}\n`);
  const valid = spawnSync(process.execPath, [path.join(root, "scripts/verify-release-evidence.mjs"), evidencePath], {
    encoding: "utf8"
  });
  if (valid.status !== 0) fail(`valid evidence was rejected: ${valid.stderr || valid.stdout}`);

  fs.writeFileSync(matrixPath, "{}\n");
  fs.writeFileSync(evidencePath, `${JSON.stringify(validEvidence, null, 2)}\n`);
  const invalidMatrix = spawnSync(process.execPath, [path.join(root, "scripts/verify-release-evidence.mjs"), evidencePath], {
    encoding: "utf8"
  });
  if (invalidMatrix.status === 0) fail("invalid manual insertion matrix was accepted");
  if (!String(invalidMatrix.stderr).includes("manualInsertionMatrix.reportPath")) {
    fail(`invalid matrix failed for the wrong reason: ${invalidMatrix.stderr || invalidMatrix.stdout}`);
  }
  fs.writeFileSync(matrixPath, `${JSON.stringify({
    schemaVersion: 1,
    generatedAt: "2026-06-29T00:00:00.000Z",
    releaseCandidate: "self-check",
    tester: "automated",
    notes: "Self-check fixture with no transcript or audio payloads.",
    cases: matrixCases
  }, null, 2)}\n`);

  validEvidence.releaseArtifact.notarized = false;
  fs.writeFileSync(evidencePath, `${JSON.stringify(validEvidence, null, 2)}\n`);
  const invalid = spawnSync(process.execPath, [path.join(root, "scripts/verify-release-evidence.mjs"), evidencePath], {
    encoding: "utf8"
  });
  if (invalid.status === 0) fail("invalid evidence was accepted");
  if (!String(invalid.stderr).includes("releaseArtifact.notarized")) {
    fail(`invalid evidence failed for the wrong reason: ${invalid.stderr || invalid.stdout}`);
  }

  console.log("release evidence validator self-check passed");
} finally {
  fs.rmSync(tmp, { recursive: true, force: true });
}
