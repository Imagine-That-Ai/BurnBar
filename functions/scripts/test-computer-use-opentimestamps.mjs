#!/usr/bin/env node
import assert from "node:assert/strict";
import { createServer } from "node:http";
import {
  parseComputerUseOpenTimestampsValidationRequest,
  runOtsVerify,
  validateComputerUseOpenTimestampsProofForRequest,
} from "../lib/computerUseOpenTimestamps.js";

const proofBase64 = Buffer.from("proof").toString("base64");
const chainFileBase64 = Buffer.from("{}\n").toString("base64");

const parsed = parseComputerUseOpenTimestampsValidationRequest({
  uid: "user_123",
  sessionId: "cu_session",
  auditHeadHashHex: "abc123",
  proofBase64,
  chainFileBase64,
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

const fixedNow = new Date("2026-05-17T12:34:56.000Z");
const validRequest = {
  uid: "user_123",
  sessionId: "cu_session",
  auditHeadHashHex: "abc123",
  proofBase64,
  chainFileBase64,
};

async function validate(overrides = {}) {
  return validateComputerUseOpenTimestampsProofForRequest(validRequest, {
    now: () => fixedNow,
    serverHeadStatus: async (_uid, _sessionId, claimedHead) => ({
      status: "server_head_matched",
      serverAuditHeadHashHex: claimedHead,
    }),
    verifyProof: async (proofBytes, chainBytes) => ({
      status: "verified",
      verified: true,
      otsVerifierOutput: [
        proofBytes.toString("utf8"),
        chainBytes?.toString("utf8") ?? "",
      ].join("|"),
    }),
    ...overrides,
  });
}

{
  const response = await validate();
  assert.deepEqual(response, {
    status: "verified",
    verified: true,
    sessionId: "cu_session",
    auditHeadHashHex: "abc123",
    serverAuditHeadHashHex: "abc123",
    proofSizeBytes: 5,
    checkedAt: "2026-05-17T12:34:56.000Z",
    otsVerifierOutput: "proof|{}\n",
  });
}

{
  let verifierCalled = false;
  const response = await validate({
    serverHeadStatus: async () => ({
      status: "head_mismatch",
      serverAuditHeadHashHex: "server-head",
    }),
    verifyProof: async () => {
      verifierCalled = true;
      throw new Error("verifyProof should not run on head mismatch");
    },
  });

  assert.equal(verifierCalled, false);
  assert.equal(response.status, "head_mismatch");
  assert.equal(response.verified, false);
  assert.equal(response.serverAuditHeadHashHex, "server-head");
  assert.equal(response.checkedAt, "2026-05-17T12:34:56.000Z");
}

{
  const response = await validate({
    serverHeadStatus: async () => ({ status: "server_head_missing" }),
  });
  assert.equal(response.status, "server_head_missing");
  assert.equal(response.verified, false);
  assert.equal(response.serverAuditHeadHashHex, undefined);
}

{
  const response = await validate({
    verifyProof: async () => ({
      status: "ots_verify_failed",
      verified: false,
      otsVerifierOutput: "detached digest mismatch",
    }),
  });
  assert.equal(response.status, "ots_verify_failed");
  assert.equal(response.verified, false);
  assert.equal(response.otsVerifierOutput, "detached digest mismatch");
}

{
  const response = await validate({
    verifyProof: async () => ({
      status: "ots_verifier_unavailable",
      verified: false,
    }),
  });
  assert.equal(response.status, "ots_verifier_unavailable");
  assert.equal(response.verified, false);
}

assert.rejects(
  () => validateComputerUseOpenTimestampsProofForRequest({
    ...validRequest,
    proofBase64: "",
  }),
  /proofBase64 decoded to empty bytes/,
);

{
  const server = createServer((req, res) => {
    let body = "";
    req.setEncoding("utf8");
    req.on("data", (chunk) => { body += chunk; });
    req.on("end", () => {
      const parsedBody = JSON.parse(body);
      assert.equal(Buffer.from(parsedBody.proofBase64, "base64").toString("utf8"), "proof");
      assert.equal(Buffer.from(parsedBody.chainFileBase64, "base64").toString("utf8"), "{}\n");
      res.writeHead(200, { "content-type": "application/json" });
      res.end(JSON.stringify({
        verified: true,
        output: "Success! Bitcoin block header verified.",
      }));
    });
  });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  const { port } = server.address();
  const prior = process.env.OPENBURNBAR_OTS_VERIFY_URL;
  process.env.OPENBURNBAR_OTS_VERIFY_URL = `http://127.0.0.1:${port}/verify`;
  try {
    const response = await runOtsVerify(
      Buffer.from("proof"),
      Buffer.from("{}\n"),
    );
    assert.equal(response.status, "verified");
    assert.equal(response.verified, true);
    assert.equal(response.otsVerifierOutput, "Success! Bitcoin block header verified.");
  } finally {
    if (prior == null) {
      delete process.env.OPENBURNBAR_OTS_VERIFY_URL;
    } else {
      process.env.OPENBURNBAR_OTS_VERIFY_URL = prior;
    }
    await new Promise((resolve) => server.close(resolve));
  }
}

console.log("computer-use OpenTimestamps validation tests: OK");
