#!/usr/bin/env node
import fs from "node:fs";
import path from "node:path";
import { spawnSync } from "node:child_process";

const root = path.resolve(import.meta.dirname, "..");
const evidencePath = process.argv[2]
  ? path.resolve(process.argv[2])
  : path.join(root, "release", "release-evidence.json");

function fail(message) {
  console.error(`release evidence check failed: ${message}`);
  process.exit(1);
}

function requireString(value, label) {
  if (typeof value !== "string" || value.trim() === "") fail(`${label} is required`);
}

function requireTrue(value, label) {
  if (value !== true) fail(`${label} must be true`);
}

function requireFile(value, label) {
  requireString(value, label);
  const filePath = path.isAbsolute(value) ? value : path.join(root, value);
  if (!fs.existsSync(filePath)) fail(`${label} does not exist: ${value}`);
  return filePath;
}

function validateInsertionMatrix(reportPath) {
  const validator = path.join(root, "scripts", "insertion-regression-report.mjs");
  const result = spawnSync(process.execPath, [validator, "validate", reportPath], {
    cwd: root,
    encoding: "utf8"
  });
  if (result.status !== 0) {
    fail(`manualInsertionMatrix.reportPath did not validate: ${result.stderr || result.stdout}`);
  }
}

if (!fs.existsSync(evidencePath)) {
  fail(`missing evidence manifest: ${path.relative(root, evidencePath)}. Start from release/release-evidence.template.json`);
}

const evidence = JSON.parse(fs.readFileSync(evidencePath, "utf8"));
if (evidence.schemaVersion !== 1) fail("unsupported evidence schema");

requireString(evidence.releaseCandidate, "releaseCandidate");
requireString(evidence.date, "date");
requireString(evidence.reviewer, "reviewer");

requireTrue(evidence.localGate?.passed, "localGate.passed");
requireTrue(evidence.convexCloud?.verifyCloudBackendPassedWithDeployment, "convexCloud.verifyCloudBackendPassedWithDeployment");
requireString(evidence.convexCloud?.deployment, "convexCloud.deployment");

requireTrue(evidence.manualInsertionMatrix?.validated, "manualInsertionMatrix.validated");
const manualInsertionReportPath = requireFile(evidence.manualInsertionMatrix?.reportPath, "manualInsertionMatrix.reportPath");
validateInsertionMatrix(manualInsertionReportPath);

for (const [key, value] of Object.entries(evidence.cloudEndToEnd ?? {})) {
  if (key === "notes" || key === "convexSiteURL") continue;
  requireTrue(value, `cloudEndToEnd.${key}`);
}
requireString(evidence.cloudEndToEnd?.convexSiteURL, "cloudEndToEnd.convexSiteURL");

for (const [key, value] of Object.entries(evidence.cleanInstall ?? {})) {
  if (key === "notes") continue;
  requireTrue(value, `cleanInstall.${key}`);
}

requireFile(evidence.releaseArtifact?.appPath, "releaseArtifact.appPath");
requireFile(evidence.releaseArtifact?.zipPath, "releaseArtifact.zipPath");
requireFile(evidence.releaseArtifact?.sha256Path, "releaseArtifact.sha256Path");
requireTrue(evidence.releaseArtifact?.signed, "releaseArtifact.signed");
requireTrue(evidence.releaseArtifact?.notarized, "releaseArtifact.notarized");
requireTrue(evidence.releaseArtifact?.stapled, "releaseArtifact.stapled");
requireTrue(evidence.releaseArtifact?.spctlAccepted, "releaseArtifact.spctlAccepted");

console.log(`validated ${path.relative(root, evidencePath)}`);
