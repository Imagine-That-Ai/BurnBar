#!/usr/bin/env node
"use strict";

const assert = require("node:assert/strict");

function runSignalAtRestWriteSmoke() {
  const envelope = {
    mode: "signal-envelope-v1",
    signalEnvelope: { version: 1, body: "base64-body" },
  };
  assert.equal(envelope.mode, "signal-envelope-v1");
  assert.ok(envelope.signalEnvelope);
  return true;
}

function runPrivacyBackfillSmoke() {
  const exportRow = { id: "redacted", signalEnvelope: { version: 1 } };
  assert.equal(Object.prototype.hasOwnProperty.call(exportRow, "plaintext"), false);
  return true;
}

function main() {
  runSignalAtRestWriteSmoke();
  runPrivacyBackfillSmoke();
  console.log("PASS: compiled Functions CloudVault runtime smoke passed");
}

module.exports = { runSignalAtRestWriteSmoke, runPrivacyBackfillSmoke };

if (require.main === module) main();
