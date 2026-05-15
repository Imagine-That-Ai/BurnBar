import test from "node:test";
import assert from "node:assert/strict";
import { fetchKimiQuota } from "../src/providers/kimi.mjs";

test("fetchKimiQuota rejects empty credential", async () => {
  await assert.rejects(
    fetchKimiQuota({ credential: "", accountID: "hosted" }),
    /Kimi quota requires an API key credential/
  );
});

test("fetchKimiQuota rejects whitespace-only credential", async () => {
  await assert.rejects(
    fetchKimiQuota({ credential: "   ", accountID: "hosted" }),
    /Kimi quota requires an API key credential/
  );
});

test("fetchKimiQuota throws on invalid API key", async () => {
  await assert.rejects(
    fetchKimiQuota({ credential: "sk-invalid-key-12345", accountID: "hosted" }),
    /Could not authenticate with any Kimi\/Moonshot endpoint/
  );
});
