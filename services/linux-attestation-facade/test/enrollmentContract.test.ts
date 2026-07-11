import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { parseBeginEnrollment, parseCompleteEnrollment } from "../src/requestParsers.js";
import { PublicError } from "../src/errors.js";

describe("enrollment HTTP contract", () => {
  it("requires AK, EK TPM2B and EK certificate without accepting client agent ID", () => {
    const valid = { deviceId: `ak-sha256:${"a".repeat(64)}`, akTpmBase64: "YWs=", ekTpmBase64: "ZWs=", ekCertificateBase64: "Y2VydA==" };
    assert.deepEqual(parseBeginEnrollment(valid), valid);
    assert.throws(() => parseBeginEnrollment({ ...valid, agentId: "client-controlled" }), (error: unknown) => error instanceof PublicError && error.code === "bad_request");
  });
  it("completes by server-owned device lookup only", () => {
    const valid = { deviceId: `ak-sha256:${"a".repeat(64)}`, activationProof: "cHJvb2Y=" };
    assert.deepEqual(parseCompleteEnrollment(valid), valid);
    assert.throws(() => parseCompleteEnrollment({ ...valid, agentId: "client-controlled" }), PublicError);
  });
});
