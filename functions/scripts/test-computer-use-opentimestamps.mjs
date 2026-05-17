#!/usr/bin/env node
import assert from "node:assert/strict";
import {
  parseComputerUseOpenTimestampsValidationRequest,
} from "../lib/computerUseOpenTimestamps.js";

const parsed = parseComputerUseOpenTimestampsValidationRequest({
  uid: "user_123",
  sessionId: "cu_session",
  auditHeadHashHex: "abc123",
  proofBase64: Buffer.from("proof").toString("base64"),
  chainFileBase64: Buffer.from("{}\n").toString("base64"),
});

assert.equal(parsed.uid, "user_123");
assert.equal(parsed.sessionId, "cu_session");
assert.equal(parsed.auditHeadHashHex, "abc123");
assert.equal(parsed.proofBase64, "cHJvb2Y=");
assert.equal(parsed.chainFileBase64, "e30K");

assert.throws(
  () => parseComputerUseOpenTimestampsValidationRequest({
    uid: "user_123",
    sessionId: "cu_session",
    proofBase64: "cHJvb2Y=",
  }),
  /auditHeadHashHex is required/,
);

assert.throws(
  () => parseComputerUseOpenTimestampsValidationRequest({
    uid: "user_123",
    sessionId: "cu_session",
    auditHeadHashHex: "abc123",
    proofBase64: "cHJvb2Y=",
    chainFileBase64: 42,
  }),
  /chainFileBase64 must be a string/,
);

console.log("computer-use OpenTimestamps validation parser tests: OK");
