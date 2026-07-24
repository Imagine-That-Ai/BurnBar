import assert from "node:assert/strict";
import fs from "node:fs";
import test from "node:test";
import {
  validateApproval,
  validateReceipt,
  validateRequest,
  validateRevokeReady,
} from "./p16-physical-ipad-coordination.mjs";
import { parseP16Arguments } from "./run-p16-native-cloud-devices-probes.mjs";

const hash = (value) => `sha256:${value.repeat(64).slice(0, 64)}`;
const at = "2026-07-20T20:00:00.000Z";
const request = {
  producer: "openburnbar-p16-linux-trust-cycle-request-v1",
  requestedAt: at,
  targetHead: "a".repeat(40),
  candidate: { runId: "123456", artifactDigest: "b".repeat(64) },
  marker: `p16-${"c".repeat(16)}`,
  challenge: "d".repeat(64),
  linux: { deviceIdHash: hash("e"), safetyFingerprintHash: hash("f") },
};
const physicalDevice = {
  appCheckAttested: true,
  bundleIdentifier: "com.openburnbar.app",
  deviceIdentifierHash: hash("1"),
  platform: "iPadOS",
  simulator: false,
};
const rows = [
  [1, "list", "listLinuxAppCheckDevices", "pending", false],
  [2, "approve", "approveLinuxAppCheckDevice", "approved", true],
  [3, "list", "listLinuxAppCheckDevices", "approved", false],
  [4, "revoke", "revokeLinuxAppCheckDevice", "revoked", true],
  [5, "list", "listLinuxAppCheckDevices", "revoked", false],
].map(([sequence, action, callable, state, signed]) => ({
  action,
  actionNonceHash: signed ? hash(String(sequence)) : null,
  callable,
  nonceBound: signed,
  observedAt: at,
  sequence,
  signedActionProof: signed,
  signedActionProofHash: signed ? hash(String(sequence + 5)) : null,
  state,
}));
const approval = {
  producer: "openburnbar-p16-physical-ipad-approval-checkpoint-v1",
  request,
  physicalDevice,
  events: rows.slice(0, 3),
};
const ready = {
  producer: "openburnbar-p16-linux-revoke-ready-v1",
  observedAt: at,
  targetHead: request.targetHead,
  candidate: request.candidate,
  marker: request.marker,
  challenge: request.challenge,
  linux: request.linux,
  approvedStateObserved: true,
  restartPersistenceObserved: true,
};
const receipt = {
  producer: "openburnbar-p16-physical-ipad-trust-cycle-v1",
  capturedAt: at,
  targetHead: request.targetHead,
  candidate: request.candidate,
  physicalDevice,
  linux: { marker: request.marker, ...request.linux },
  events: rows,
  restoration: {
    createdDeviceRevoked: true,
    noPendingMutation: true,
    trustedDeviceStateRestored: true,
  },
};

test("P-16 coordination binds request, both physical-iPad phases, and Linux acknowledgement", () => {
  assert.equal(validateRequest(request, {
    targetHead: request.targetHead,
    candidateRunId: request.candidate.runId,
    candidateArtifactDigest: request.candidate.artifactDigest,
  }), request);
  assert.equal(validateApproval(approval, request), approval);
  assert.equal(validateRevokeReady(ready, request), ready);
  assert.equal(validateReceipt(receipt, request, approval), receipt);
});

test("P-16 coordination fails closed on substitution, Simulator, early revoke, and replay", () => {
  assert.throws(
    () => validateRequest({ ...request, targetHead: "9".repeat(40) }, { targetHead: request.targetHead }),
    /expected candidate/u,
  );
  assert.throws(
    () => validateApproval({ ...approval, physicalDevice: { ...physicalDevice, simulator: true } }, request),
    /physical iPad identity/u,
  );
  assert.throws(
    () => validateRevokeReady({ ...ready, restartPersistenceObserved: false }, request),
    /not request-bound/u,
  );
  const replay = structuredClone(receipt);
  replay.events[3].actionNonceHash = replay.events[1].actionNonceHash;
  assert.throws(() => validateReceipt(replay, request, approval), /replayed/u);
});

test("P-16 receipt bundle identity matches both OpenBurnBarMobile build configurations", () => {
  const project = fs.readFileSync("OpenBurnBar.xcodeproj/project.pbxproj", "utf8");
  for (const configuration of ["D2BB797D25E72ABA834759CE", "2547F2D70BB3F9FC14B79D2B"]) {
    const start = project.indexOf(`\t\t${configuration} /*`);
    const end = project.indexOf("\n\t\t};", start);
    assert.notEqual(start, -1, `missing OpenBurnBarMobile configuration ${configuration}`);
    assert.match(
      project.slice(start, end),
      /PRODUCT_BUNDLE_IDENTIFIER = com\.openburnbar\.app;/u,
      `P-16 receipt identity drifted from OpenBurnBarMobile ${configuration}`,
    );
  }
});

test("P-16 Linux CLI derives the receipt and accepts the exact compatibility path", () => {
  const coordination = "/tmp/p16-coordination";
  const required = [
    "--raw-output-dir", "/tmp/raw", "--state-home", "/tmp/home",
    "--coordination-dir", coordination, "--environment", "ubuntu-24.04-gnome-x11-x86_64",
    "--target-head", request.targetHead, "--candidate-run-id", request.candidate.runId,
    "--candidate-artifact-digest", request.candidate.artifactDigest,
    "--package-version", "1.0.2", "--manifest-sha256", "1".repeat(64),
    "--manifest-signature-sha256", "2".repeat(64), "--architecture", "x86_64",
    "--package-format", "deb", "--desktop", "GNOME", "--display-server", "X11",
  ];
  assert.equal(
    parseP16Arguments(required).mobileReceipt,
    `${coordination}/p16-mobile-receipt.json`,
  );
  assert.equal(
    parseP16Arguments([
      ...required,
      "--mobile-receipt", `${coordination}/p16-mobile-receipt.json`,
    ]).mobileReceipt,
    `${coordination}/p16-mobile-receipt.json`,
  );
});
