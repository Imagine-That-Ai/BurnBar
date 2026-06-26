#!/usr/bin/env node
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { createServer } from "node:http";
import {
  parseComputerUseOpenTimestampsValidationRequest,
  runOtsVerify,
  validateComputerUseOpenTimestampsProofForRequest,
} from "../lib/computerUseOpenTimestamps.js";

const proofBase64 = Buffer.from("proof").toString("base64");

function sha256Hex(value) {
  return createHash("sha256").update(value).digest("hex");
}

function auditChainLine(entry) {
  return JSON.stringify(Object.fromEntries(Object.entries(entry).sort(([a], [b]) => a.localeCompare(b))));
}

function buildManifest(sessionId, userId = "user_123") {
  return auditChainLine({
    actionCap: 10,
    entitlementProductId: "computer-use",
    mode: "browser",
    scopeRuleIds: [],
    scopeRules: [],
    sessionId,
    sessionTimeoutSeconds: 300,
    startedAt: 1781699696000,
    trustMode: "step",
    userId,
  });
}

function buildChain(sessionId, manifestText = buildManifest(sessionId)) {
  const first = auditChainLine({
    entryIndex: 0,
    parentEntryHashHex: sha256Hex(Buffer.from(manifestText)),
    schemaVersion: 1,
    sessionId,
  });
  const firstHead = sha256Hex(Buffer.from(first));
  const second = auditChainLine({
    entryIndex: 1,
    parentEntryHashHex: firstHead,
    schemaVersion: 1,
    sessionId,
  });
  return {
    chainText: `${first}\n${second}\n`,
    head: sha256Hex(Buffer.from(second)),
    manifestText,
    manifestHash: sha256Hex(Buffer.from(manifestText)),
  };
}

const validChain = buildChain("cu_session");
const unrelatedChain = buildChain("cu_session_unrelated");
const badManifestForValidChain = buildManifest("cu_session", "different_user");
const chainFileBase64 = Buffer.from(validChain.chainText).toString("base64");
const manifestFileBase64 = Buffer.from(validChain.manifestText).toString("base64");

const parsed = parseComputerUseOpenTimestampsValidationRequest({
  uid: "user_123",
  sessionId: "cu_session",
  auditHeadHashHex: validChain.head,
  proofBase64,
  manifestFileBase64,
  chainFileBase64,
});

assert.equal(parsed.uid, "user_123");
assert.equal(parsed.sessionId, "cu_session");
assert.equal(parsed.auditHeadHashHex, validChain.head);
assert.equal(parsed.proofBase64, "cHJvb2Y=");
assert.equal(parsed.manifestFileBase64, manifestFileBase64);
assert.equal(parsed.chainFileBase64, chainFileBase64);

assert.throws(
  () =>
    parseComputerUseOpenTimestampsValidationRequest({
      uid: "user_123",
      sessionId: "cu_session",
      proofBase64: "cHJvb2Y=",
    }),
  /auditHeadHashHex is required/,
);

assert.throws(
  () =>
    parseComputerUseOpenTimestampsValidationRequest({
      uid: "user_123",
      sessionId: "cu_session",
      auditHeadHashHex: "abc123",
      proofBase64: "cHJvb2Y=",
      manifestFileBase64: 42,
    }),
  /manifestFileBase64 must be a string/,
);

assert.throws(
  () =>
    parseComputerUseOpenTimestampsValidationRequest({
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
  auditHeadHashHex: validChain.head,
  proofBase64,
  manifestFileBase64,
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
      otsVerifierOutput: [proofBytes.toString("utf8"), chainBytes?.toString("utf8") ?? ""].join("|"),
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
    auditHeadHashHex: validChain.head,
    serverAuditHeadHashHex: validChain.head,
    manifestHashHex: validChain.manifestHash,
    chainHeadHashHex: validChain.head,
    proofSizeBytes: 5,
    checkedAt: "2026-05-17T12:34:56.000Z",
    otsVerifierOutput: `proof|${validChain.chainText}`,
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
  let verifierCalled = false;
  const response = await validateComputerUseOpenTimestampsProofForRequest(
    {
      ...validRequest,
      manifestFileBase64: undefined,
    },
    {
      now: () => fixedNow,
      serverHeadStatus: async (_uid, _sessionId, claimedHead) => ({
        status: "server_head_matched",
        serverAuditHeadHashHex: claimedHead,
      }),
      verifyProof: async () => {
        verifierCalled = true;
        throw new Error("verifyProof should not run without manifest bytes");
      },
    },
  );
  assert.equal(verifierCalled, false);
  assert.equal(response.status, "manifest_file_required");
  assert.equal(response.verified, false);
  assert.equal(
    response.otsVerifierOutput,
    "manifestFileBase64 is required to bind the audit chain to the session manifest.",
  );
}

{
  let verifierCalled = false;
  const response = await validateComputerUseOpenTimestampsProofForRequest(
    {
      ...validRequest,
      chainFileBase64: undefined,
    },
    {
      now: () => fixedNow,
      serverHeadStatus: async (_uid, _sessionId, claimedHead) => ({
        status: "server_head_matched",
        serverAuditHeadHashHex: claimedHead,
      }),
      verifyProof: async () => {
        verifierCalled = true;
        throw new Error("verifyProof should not run without chain bytes");
      },
    },
  );
  assert.equal(verifierCalled, false);
  assert.equal(response.status, "chain_file_required");
  assert.equal(response.verified, false);
  assert.equal(
    response.otsVerifierOutput,
    "chainFileBase64 is required to bind the OpenTimestamps proof to the audit chain head.",
  );
}

{
  let verifierCalled = false;
  const response = await validateComputerUseOpenTimestampsProofForRequest(
    {
      ...validRequest,
      manifestFileBase64: Buffer.from(badManifestForValidChain).toString("base64"),
    },
    {
      now: () => fixedNow,
      serverHeadStatus: async (_uid, _sessionId, claimedHead) => ({
        status: "server_head_matched",
        serverAuditHeadHashHex: claimedHead,
      }),
      verifyProof: async () => {
        verifierCalled = true;
        throw new Error("verifyProof should not run on manifest-chain mismatch");
      },
    },
  );
  assert.equal(verifierCalled, false);
  assert.equal(response.status, "chain_head_mismatch");
  assert.equal(response.verified, false);
  assert.equal(response.otsVerifierOutput, "parent_hash_mismatch");
}

{
  let verifierCalled = false;
  const response = await validateComputerUseOpenTimestampsProofForRequest(
    {
      ...validRequest,
      chainFileBase64: Buffer.from(unrelatedChain.chainText).toString("base64"),
    },
    {
      now: () => fixedNow,
      serverHeadStatus: async (_uid, _sessionId, claimedHead) => ({
        status: "server_head_matched",
        serverAuditHeadHashHex: claimedHead,
      }),
      verifyProof: async () => {
        verifierCalled = true;
        throw new Error("verifyProof should not run on chain-head mismatch");
      },
    },
  );
  assert.equal(verifierCalled, false);
  assert.equal(response.status, "chain_head_mismatch");
  assert.equal(response.verified, false);
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
  () =>
    validateComputerUseOpenTimestampsProofForRequest({
      ...validRequest,
      proofBase64: "",
    }),
  /proofBase64 decoded to empty bytes/,
);

{
  const server = createServer((req, res) => {
    let body = "";
    req.setEncoding("utf8");
    req.on("data", (chunk) => {
      body += chunk;
    });
    req.on("end", () => {
      const parsedBody = JSON.parse(body);
      assert.equal(Buffer.from(parsedBody.proofBase64, "base64").toString("utf8"), "proof");
      assert.equal(Buffer.from(parsedBody.chainFileBase64, "base64").toString("utf8"), validChain.chainText);
      res.writeHead(200, { "content-type": "application/json" });
      res.end(
        JSON.stringify({
          verified: true,
          output: "Success! Bitcoin block header verified.",
        }),
      );
    });
  });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  const { port } = server.address();
  const prior = process.env.OPENBURNBAR_OTS_VERIFY_URL;
  process.env.OPENBURNBAR_OTS_VERIFY_URL = `http://127.0.0.1:${port}/verify`;
  try {
    const response = await runOtsVerify(Buffer.from("proof"), Buffer.from(validChain.chainText));
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

{
  const priorURL = process.env.OPENBURNBAR_OTS_VERIFY_URL;
  const priorAudience = process.env.OPENBURNBAR_OTS_VERIFY_AUDIENCE;
  const priorFetch = globalThis.fetch;
  process.env.OPENBURNBAR_OTS_VERIFY_URL = "https://openburnbar-ots-verifier.example/verify";
  process.env.OPENBURNBAR_OTS_VERIFY_AUDIENCE = "https://openburnbar-ots-verifier.example";
  let sawMetadataRequest = false;
  let sawAuthorizedVerifyRequest = false;
  globalThis.fetch = async (url, init = {}) => {
    const href = String(url);
    if (href.startsWith("http://metadata.google.internal/computeMetadata")) {
      sawMetadataRequest = true;
      assert.equal(init.headers?.["Metadata-Flavor"], "Google");
      assert.ok(href.includes("audience=https%3A%2F%2Fopenburnbar-ots-verifier.example"));
      return new Response("signed-id-token", { status: 200 });
    }
    assert.equal(href, "https://openburnbar-ots-verifier.example/verify");
    assert.equal(init.headers.authorization, "Bearer signed-id-token");
    sawAuthorizedVerifyRequest = true;
    return new Response(
      JSON.stringify({
        verified: true,
        output: "Private Cloud Run verifier accepted ID token.",
      }),
      {
        status: 200,
        headers: { "content-type": "application/json" },
      },
    );
  };
  try {
    const response = await runOtsVerify(Buffer.from("proof"));
    assert.equal(response.status, "verified");
    assert.equal(response.verified, true);
    assert.equal(response.otsVerifierOutput, "Private Cloud Run verifier accepted ID token.");
    assert.equal(sawMetadataRequest, true);
    assert.equal(sawAuthorizedVerifyRequest, true);
  } finally {
    globalThis.fetch = priorFetch;
    if (priorURL == null) {
      delete process.env.OPENBURNBAR_OTS_VERIFY_URL;
    } else {
      process.env.OPENBURNBAR_OTS_VERIFY_URL = priorURL;
    }
    if (priorAudience == null) {
      delete process.env.OPENBURNBAR_OTS_VERIFY_AUDIENCE;
    } else {
      process.env.OPENBURNBAR_OTS_VERIFY_AUDIENCE = priorAudience;
    }
  }
}

console.log("computer-use OpenTimestamps validation tests: OK");
