import test from "node:test";
import assert from "node:assert/strict";

import { makeMem0RestClient } from "./mem0-rest-client.mjs";

function jsonResponse(body, status = 200) {
  return {
    ok: status >= 200 && status < 300,
    status,
    async text() {
      return body === undefined ? "" : JSON.stringify(body);
    },
  };
}

test("mem0 REST client URL-encodes memory ids for deletes", async () => {
  const calls = [];
  const client = makeMem0RestClient("test-key", {
    baseUrl: "https://mem0.test",
    fetchImpl: async (url, init) => {
      calls.push({ url, init });
      return jsonResponse(undefined, 204);
    },
  });

  await client.delete("mem/../other?#frag");

  assert.equal(calls.length, 1);
  assert.equal(calls[0].init.method, "DELETE");
  assert.equal(calls[0].url, "https://mem0.test/v1/memories/mem%2F..%2Fother%3F%23frag/");
});

test("mem0 REST client URL-encodes memory ids for reads and treats missing records as null", async () => {
  const calls = [];
  const client = makeMem0RestClient("test-key", {
    baseUrl: "https://mem0.test",
    fetchImpl: async (url, init) => {
      calls.push({ url, init });
      return jsonResponse({ error: "not found" }, 404);
    },
  });

  const result = await client.get("mem/a b");

  assert.equal(result, null);
  assert.equal(calls.length, 1);
  assert.equal(calls[0].init.method, "GET");
  assert.equal(calls[0].url, "https://mem0.test/v1/memories/mem%2Fa%20b/");
});

test("mem0 REST client creates verbatim memories with infer disabled", async () => {
  let requestBody;
  const client = makeMem0RestClient("test-key", {
    baseUrl: "https://mem0.test",
    fetchImpl: async (url, init) => {
      assert.equal(url, "https://mem0.test/v1/memories/");
      assert.equal(init.method, "POST");
      requestBody = JSON.parse(init.body);
      return jsonResponse({ results: [{ id: "mem-created" }] });
    },
  });

  const id = await client.create("exact text", "burnbar", "burnbar", { source: "droid-wiki" });

  assert.equal(id, "mem-created");
  assert.deepEqual(requestBody, {
    messages: [{ role: "user", content: "exact text" }],
    user_id: "burnbar",
    app_id: "burnbar",
    infer: false,
    metadata: { source: "droid-wiki" },
  });
});
