import assert from "node:assert/strict";
import test from "node:test";

import { assertOfficialLibsignalReady, LIBSIGNAL_PIN, REQUIRED_SIGNAL_PROTOCOL_SYMBOLS, libsignal } from "./index.js";

test("official libsignal client loads with the pinned Signal Protocol surface", () => {
  const report = assertOfficialLibsignalReady();

  assert.equal(report.ok, true);
  assert.equal(report.pin.version, "0.94.4");
  assert.equal(report.pin.upstreamTagObject, "03c449017b57eccbda715b8b018dce5dff603ac6");
  assert.equal(report.pin.upstreamCommit, "46d867c986f66201e34e7ae20ce423eec742bf3f");
  assert.equal(report.pin.license, "AGPL-3.0-only");
  for (const symbol of REQUIRED_SIGNAL_PROTOCOL_SYMBOLS) {
    assert.notEqual((libsignal as Record<string, unknown>)[symbol], undefined, `${symbol} should be exported`);
  }
});

test("the bridge records the official Signal package identity", () => {
  assert.equal(LIBSIGNAL_PIN.packageName, "@signalapp/libsignal-client");
  assert.equal(LIBSIGNAL_PIN.upstreamRepository, "https://github.com/signalapp/libsignal");
  assert.equal(LIBSIGNAL_PIN.upstreamTag, "v0.94.4");
});
