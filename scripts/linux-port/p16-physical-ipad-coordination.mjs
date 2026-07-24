#!/usr/bin/env node
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const SHA = /^[a-f0-9]{64}$/u;
const HASH = /^sha256:[a-f0-9]{64}$/u;
const MARKER = /^p16-[a-f0-9]{16}$/u;
const HEAD = /^[a-f0-9]{40}$/u;

function fail(message) {
  throw new Error(message);
}
function exact(value, keys, label) {
  if (!value || typeof value !== "object" || Array.isArray(value))
    fail(`${label} must be an object`);
  const actual = Object.keys(value).sort();
  const expected = [...keys].sort();
  if (JSON.stringify(actual) !== JSON.stringify(expected))
    fail(`${label} keys are invalid`);
}
function secureFile(file, label) {
  const absolute = path.resolve(file);
  const stat = fs.lstatSync(absolute);
  if (
    !stat.isFile() ||
    stat.isSymbolicLink() ||
    stat.uid !== process.getuid?.() ||
    stat.nlink !== 1 ||
    (stat.mode & 0o077) !== 0 ||
    fs.realpathSync(absolute) !== absolute
  )
    fail(`${label} must be an owner-only regular file`);
  return absolute;
}
function readJson(file, label) {
  return JSON.parse(fs.readFileSync(secureFile(file, label), "utf8"));
}
export function validateRequest(value, bindings = {}) {
  exact(
    value,
    ["candidate", "challenge", "linux", "marker", "producer", "requestedAt", "targetHead"],
    "P-16 coordination request",
  );
  exact(value.candidate, ["artifactDigest", "runId"], "P-16 request candidate");
  exact(value.linux, ["deviceIdHash", "safetyFingerprintHash"], "P-16 request Linux identity");
  if (
    value.producer !== "openburnbar-p16-linux-trust-cycle-request-v1" ||
    !HEAD.test(value.targetHead) ||
    !MARKER.test(value.marker) ||
    !SHA.test(value.challenge) ||
    !HASH.test(value.linux.deviceIdHash) ||
    !HASH.test(value.linux.safetyFingerprintHash) ||
    !Number.isFinite(Date.parse(value.requestedAt))
  )
    fail("P-16 coordination request is invalid");
  if (
    (bindings.targetHead && value.targetHead !== bindings.targetHead) ||
    (bindings.candidateRunId && String(value.candidate.runId) !== String(bindings.candidateRunId)) ||
    (bindings.candidateArtifactDigest && value.candidate.artifactDigest !== bindings.candidateArtifactDigest)
  )
    fail("P-16 coordination request does not match the expected candidate");
  return value;
}
function event(value, expected, label) {
  exact(
    value,
    ["action", "actionNonceHash", "callable", "nonceBound", "observedAt", "sequence", "signedActionProof", "signedActionProofHash", "state"],
    label,
  );
  const signed = expected[4];
  if (
    value.sequence !== expected[0] ||
    value.action !== expected[1] ||
    value.callable !== expected[2] ||
    value.state !== expected[3] ||
    value.nonceBound !== signed ||
    value.signedActionProof !== signed ||
    !Number.isFinite(Date.parse(value.observedAt)) ||
    (signed
      ? !HASH.test(value.actionNonceHash) || !HASH.test(value.signedActionProofHash)
      : value.actionNonceHash !== null || value.signedActionProofHash !== null)
  )
    fail(`${label} is invalid`);
}
function tagged(logFile, name) {
  const text = fs.readFileSync(secureFile(logFile, "P-16 XCTest log"), "utf8");
  const matches = [...text.matchAll(new RegExp(`^${name}=([A-Za-z0-9+/=]+)$`, "gmu"))];
  if (matches.length !== 1) fail(`P-16 XCTest emitted ${matches.length} ${name} records`);
  return JSON.parse(Buffer.from(matches[0][1], "base64").toString("utf8"));
}
export function validateApproval(value, request) {
  exact(value, ["events", "physicalDevice", "producer", "request"], "P-16 approval checkpoint");
  if (
    value.producer !== "openburnbar-p16-physical-ipad-approval-checkpoint-v1" ||
    JSON.stringify(value.request) !== JSON.stringify(request)
  )
    fail("P-16 approval checkpoint is not request-bound");
  validatePhysical(value.physicalDevice);
  const expected = [
    [1, "list", "listLinuxAppCheckDevices", "pending", false],
    [2, "approve", "approveLinuxAppCheckDevice", "approved", true],
    [3, "list", "listLinuxAppCheckDevices", "approved", false],
  ];
  if (!Array.isArray(value.events) || value.events.length !== expected.length)
    fail("P-16 approval checkpoint is incomplete");
  value.events.forEach((row, index) => event(row, expected[index], `P-16 approval event ${index + 1}`));
  return value;
}
function validatePhysical(value) {
  exact(value, ["appCheckAttested", "bundleIdentifier", "deviceIdentifierHash", "platform", "simulator"], "P-16 physical iPad");
  if (
    value.appCheckAttested !== true || value.bundleIdentifier !== "com.openburnbar.app" ||
    !HASH.test(value.deviceIdentifierHash) || value.platform !== "iPadOS" || value.simulator !== false
  ) fail("P-16 physical iPad identity is invalid");
}
export function validateRevokeReady(value, request) {
  exact(value, ["approvedStateObserved", "candidate", "challenge", "linux", "marker", "observedAt", "producer", "restartPersistenceObserved", "targetHead"], "P-16 revoke-ready acknowledgement");
  if (
    value.producer !== "openburnbar-p16-linux-revoke-ready-v1" ||
    value.approvedStateObserved !== true || value.restartPersistenceObserved !== true ||
    value.targetHead !== request.targetHead || value.marker !== request.marker ||
    value.challenge !== request.challenge || JSON.stringify(value.candidate) !== JSON.stringify(request.candidate) ||
    JSON.stringify(value.linux) !== JSON.stringify(request.linux) || !Number.isFinite(Date.parse(value.observedAt))
  ) fail("P-16 revoke-ready acknowledgement is not request-bound");
  return value;
}
export function validateReceipt(value, request, approval) {
  exact(value, ["candidate", "capturedAt", "events", "linux", "physicalDevice", "producer", "restoration", "targetHead"], "P-16 physical-iPad receipt");
  if (
    value.producer !== "openburnbar-p16-physical-ipad-trust-cycle-v1" ||
    value.targetHead !== request.targetHead || JSON.stringify(value.candidate) !== JSON.stringify(request.candidate) ||
    !Number.isFinite(Date.parse(value.capturedAt)) || JSON.stringify(value.physicalDevice) !== JSON.stringify(approval.physicalDevice)
  ) fail("P-16 receipt is not request-bound");
  exact(value.linux, ["deviceIdHash", "marker", "safetyFingerprintHash"], "P-16 receipt Linux identity");
  if (value.linux.marker !== request.marker || value.linux.deviceIdHash !== request.linux.deviceIdHash || value.linux.safetyFingerprintHash !== request.linux.safetyFingerprintHash)
    fail("P-16 receipt targets another Linux identity");
  const expected = [
    [1, "list", "listLinuxAppCheckDevices", "pending", false],
    [2, "approve", "approveLinuxAppCheckDevice", "approved", true],
    [3, "list", "listLinuxAppCheckDevices", "approved", false],
    [4, "revoke", "revokeLinuxAppCheckDevice", "revoked", true],
    [5, "list", "listLinuxAppCheckDevices", "revoked", false],
  ];
  if (!Array.isArray(value.events) || value.events.length !== expected.length || JSON.stringify(value.events.slice(0, 3)) !== JSON.stringify(approval.events))
    fail("P-16 receipt event chain is incomplete");
  value.events.forEach((row, index) => event(row, expected[index], `P-16 receipt event ${index + 1}`));
  if (new Set([value.events[1].actionNonceHash, value.events[3].actionNonceHash]).size !== 2 || new Set([value.events[1].signedActionProofHash, value.events[3].signedActionProofHash]).size !== 2)
    fail("P-16 receipt replayed a nonce or proof");
  exact(value.restoration, ["createdDeviceRevoked", "noPendingMutation", "trustedDeviceStateRestored"], "P-16 receipt restoration");
  if (!Object.values(value.restoration).every((entry) => entry === true)) fail("P-16 receipt restoration is incomplete");
  return value;
}
function atomicWrite(file, value) {
  const absolute = path.resolve(file);
  const parent = fs.realpathSync(path.dirname(absolute));
  if (path.dirname(absolute) !== parent || fs.existsSync(absolute)) fail("P-16 receipt output must be new in a canonical directory");
  const temporary = `${absolute}.tmp-${process.pid}`;
  fs.writeFileSync(temporary, `${JSON.stringify(value, null, 2)}\n`, { flag: "wx", mode: 0o600 });
  fs.renameSync(temporary, absolute);
}

function main(argv) {
  const [command, requestFile, ...args] = argv;
  const request = validateRequest(readJson(requestFile, "P-16 coordination request"),
    command === "request-base64" ? { targetHead: args[0], candidateRunId: args[1], candidateArtifactDigest: args[2] } : {});
  if (command === "request-base64") return process.stdout.write(`${Buffer.from(JSON.stringify(request)).toString("base64")}\n`);
  if (command === "approval-base64") {
    const approval = validateApproval(tagged(args[0], "OPENBURNBAR_P16_APPROVAL_RESULT_BASE64"), request);
    return process.stdout.write(`${Buffer.from(JSON.stringify(approval)).toString("base64")}\n`);
  }
  if (command === "validate-ready") {
    validateRevokeReady(readJson(args[0], "P-16 revoke-ready acknowledgement"), request);
    return;
  }
  if (command === "publish-receipt") {
    const approval = validateApproval(tagged(args[0], "OPENBURNBAR_P16_APPROVAL_RESULT_BASE64"), request);
    const receipt = validateReceipt(tagged(args[1], "OPENBURNBAR_P16_RECEIPT_BASE64"), request, approval);
    atomicWrite(args[2], receipt);
    return;
  }
  fail(`unknown P-16 coordination command: ${command ?? "missing"}`);
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try { main(process.argv.slice(2)); } catch (error) {
    process.stderr.write(`P-16 physical-iPad coordination failed: ${error.message}\n`);
    process.exitCode = 1;
  }
}
