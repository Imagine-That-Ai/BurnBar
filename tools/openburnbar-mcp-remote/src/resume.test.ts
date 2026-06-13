import assert from "node:assert/strict";
import { createCipheriv, createHash, randomBytes } from "node:crypto";
import test from "node:test";
import { buildResumeSpawnCommand, renderHostedResumeResponse, runResumeCli } from "./resume.js";
import { forwardMcpMessage, validatedMcpEndpoint } from "./shim.js";

function seal(text: string, key: Buffer) {
  const nonce = randomBytes(12);
  const cipher = createCipheriv("aes-256-gcm", key, nonce);
  const ciphertext = Buffer.concat([cipher.update(text, "utf8"), cipher.final()]);
  return {
    algorithm: "AES-256-GCM",
    keyVersion: 1,
    nonce: nonce.toString("base64"),
    ciphertext: ciphertext.toString("base64"),
    tag: cipher.getAuthTag().toString("base64")
  };
}

function stableJson(value: Record<string, unknown>): string {
  return JSON.stringify(Object.fromEntries(Object.keys(value).sort().map((key) => [key, value[key]])));
}

test("hosted sealed resume response decrypts and renders locally", () => {
  const key = Buffer.alloc(32, 7);
  process.env.OPENBURNBAR_ALLOW_INSECURE_VAULT_KEY_SOURCE = "true";
  process.env.OPENBURNBAR_CLOUD_VAULT_KEY_BASE64 = key.toString("base64");
  const chunk = seal("**[USER]**\nPlease continue the auth work.", key);
  const rendered = renderHostedResumeResponse({
    kind: "ported_sealed",
    target_harness: "claude_code",
    header_plain: {
      provider: "Goose",
      model: "gpt-5.1",
      project_name: "FixtureApp",
      started_at: "2026-05-01T10:00:00Z",
      last_message_at: "2026-05-01T11:00:00Z"
    },
    sealed: {
      summary_title: seal("Auth handoff", key),
      summary: seal("Middleware was updated.", key),
      context: seal("- `src/auth.ts`", key),
      trail_chunks: [chunk],
      hand_off: seal("Next, add a 401 test.", key)
    },
    body_hashes: [createHash("sha256").update(stableJson(chunk)).digest("hex")]
  });

  assert.equal(rendered.kind, "ported_sealed");
  assert.match(rendered.text, /# BurnBar Resume: Auth handoff/);
  assert.match(rendered.text, /Middleware was updated/);
  assert.match(rendered.text, /Please continue the auth work/);
});

test("hosted sealed resume response rejects tampered chunk hashes", () => {
  const key = Buffer.alloc(32, 9);
  process.env.OPENBURNBAR_ALLOW_INSECURE_VAULT_KEY_SOURCE = "true";
  process.env.OPENBURNBAR_CLOUD_VAULT_KEY_BASE64 = key.toString("base64");
  const chunk = seal("trail", key);

  assert.throws(() => renderHostedResumeResponse({
    kind: "ported_sealed",
    header_plain: {},
    sealed: {
      summary_title: seal("Title", key),
      summary: seal("Summary", key),
      context: seal("Context", key),
      trail_chunks: [chunk],
      hand_off: seal("Hand off", key)
    },
    body_hashes: ["bad"]
  }), /integrity check/);
});

test("resume CLI checks local vault key before hosted network call", async () => {
  delete process.env.OPENBURNBAR_CLOUD_VAULT_KEY_BASE64;
  delete process.env.OPENBURNBAR_ALLOW_INSECURE_VAULT_KEY_SOURCE;
  process.env.OPENBURNBAR_MCP_ACCESS_TOKEN = "test-token";
  const originalFetch = globalThis.fetch;
  let called = false;
  globalThis.fetch = (() => {
    called = true;
    throw new Error("network should not be called");
  }) as typeof fetch;
  try {
    const code = await runResumeCli({ sessionId: "session-1", targetHarness: "claudeCode", endpoint: "https://example.invalid/mcp" });
    assert.equal(code, 3);
    assert.equal(called, false);
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test("resume CLI sends local opaque query hashes for fuzzy OBB Resume", async () => {
  const key = Buffer.alloc(32, 11);
  process.env.OPENBURNBAR_ALLOW_INSECURE_VAULT_KEY_SOURCE = "true";
  process.env.OPENBURNBAR_CLOUD_VAULT_KEY_BASE64 = key.toString("base64");
  process.env.OPENBURNBAR_MCP_ACCESS_TOKEN = "test-token";
  const originalFetch = globalThis.fetch;
  let capturedArgs: Record<string, unknown> | undefined;
  let capturedTool: string | undefined;
  const previousAllowCustomEndpoint = process.env.OPENBURNBAR_MCP_ALLOW_CUSTOM_ENDPOINT;
  const previousAllowInsecureTokenSource = process.env.OPENBURNBAR_ALLOW_INSECURE_MCP_TOKEN_SOURCE;
  process.env.OPENBURNBAR_MCP_ALLOW_CUSTOM_ENDPOINT = "true";
  process.env.OPENBURNBAR_ALLOW_INSECURE_MCP_TOKEN_SOURCE = "true";
  globalThis.fetch = (async (_url, init) => {
    const body = JSON.parse(String(init?.body)) as {
      params?: { name?: string; arguments?: Record<string, unknown> };
    };
    capturedTool = body.params?.name;
    capturedArgs = body.params?.arguments;
    return new Response(JSON.stringify({
      result: {
        content: [{
          type: "text",
          text: JSON.stringify({
            hits: [{
              documentID: "doc-1",
              sessionID: "goose-1",
              sourceID: "Goose:goose-1",
              provider: "Goose",
              model: "gpt-5.1",
              projectName: "FixtureApp",
              lastMessageAt: "2026-05-01T11:00:00Z",
              sealedTitle: seal("Auth handoff", key),
              sealedSnippet: seal("Middleware was updated. Next, add a 401 test.", key),
              score: 0.82,
              matchKind: "hybrid"
            }]
          })
        }]
      }
    }));
  }) as typeof fetch;
  try {
    const code = await runResumeCli({
      query: "auth refactor last week",
      targetHarness: "claudeCode",
      endpoint: "https://example.invalid/mcp"
    });
    assert.equal(code, 0);
    assert.ok(capturedArgs);
    assert.equal(capturedTool, "burnbar_search_conversations");
    assert.equal(capturedArgs.session_id, undefined);
    assert.ok(Array.isArray(capturedArgs.tokenHashes));
    assert.ok(Array.isArray(capturedArgs.semanticHashes));
    assert.ok((capturedArgs.tokenHashes as unknown[]).length > 0);
  } finally {
    globalThis.fetch = originalFetch;
    if (previousAllowCustomEndpoint === undefined) {
      delete process.env.OPENBURNBAR_MCP_ALLOW_CUSTOM_ENDPOINT;
    } else {
      process.env.OPENBURNBAR_MCP_ALLOW_CUSTOM_ENDPOINT = previousAllowCustomEndpoint;
    }
    if (previousAllowInsecureTokenSource === undefined) {
      delete process.env.OPENBURNBAR_ALLOW_INSECURE_MCP_TOKEN_SOURCE;
    } else {
      process.env.OPENBURNBAR_ALLOW_INSECURE_MCP_TOKEN_SOURCE = previousAllowInsecureTokenSource;
    }
  }
});

test("MCP endpoint validation rejects token exfiltration targets", () => {
  assert.equal(validatedMcpEndpoint("https://mcp.burnbar.ai/mcp").href, "https://mcp.burnbar.ai/mcp");
  assert.equal(validatedMcpEndpoint("http://127.0.0.1:8080/mcp").href, "http://127.0.0.1:8080/mcp");
  assert.throws(() => validatedMcpEndpoint("https://example.com/mcp"), /explicitly allowed custom HTTPS/);
  assert.throws(() => validatedMcpEndpoint("http://example.com/mcp"), /HTTPS/);
  assert.throws(() => validatedMcpEndpoint("https://token@example.com/mcp"), /credentials/);
});

test("MCP refresh refuses custom endpoints even when custom HTTPS is allowed", async () => {
  const previousAllowCustomEndpoint = process.env.OPENBURNBAR_MCP_ALLOW_CUSTOM_ENDPOINT;
  const previousAllowInsecureTokenSource = process.env.OPENBURNBAR_ALLOW_INSECURE_MCP_TOKEN_SOURCE;
  const previousAccessToken = process.env.OPENBURNBAR_MCP_ACCESS_TOKEN;
  const previousRefreshToken = process.env.OPENBURNBAR_MCP_REFRESH_TOKEN;
  const originalFetch = globalThis.fetch;
  const urls: string[] = [];
  process.env.OPENBURNBAR_MCP_ALLOW_CUSTOM_ENDPOINT = "true";
  process.env.OPENBURNBAR_ALLOW_INSECURE_MCP_TOKEN_SOURCE = "true";
  process.env.OPENBURNBAR_MCP_ACCESS_TOKEN = "expired-access";
  process.env.OPENBURNBAR_MCP_REFRESH_TOKEN = "durable-refresh";
  globalThis.fetch = (async (url) => {
    urls.push(String(url));
    return new Response(JSON.stringify({ error: "expired" }), { status: 401 });
  }) as typeof fetch;

  try {
    const result = await forwardMcpMessage(
      { jsonrpc: "2.0", id: 7, method: "tools/list", params: {} },
      "https://example.invalid/mcp",
    ) as { error?: { code?: number } };
    assert.equal(result.error?.code, -32001);
    assert.deepEqual(urls, ["https://example.invalid/mcp"]);
  } finally {
    globalThis.fetch = originalFetch;
    if (previousAllowCustomEndpoint === undefined) {
      delete process.env.OPENBURNBAR_MCP_ALLOW_CUSTOM_ENDPOINT;
    } else {
      process.env.OPENBURNBAR_MCP_ALLOW_CUSTOM_ENDPOINT = previousAllowCustomEndpoint;
    }
    if (previousAllowInsecureTokenSource === undefined) {
      delete process.env.OPENBURNBAR_ALLOW_INSECURE_MCP_TOKEN_SOURCE;
    } else {
      process.env.OPENBURNBAR_ALLOW_INSECURE_MCP_TOKEN_SOURCE = previousAllowInsecureTokenSource;
    }
    if (previousAccessToken === undefined) {
      delete process.env.OPENBURNBAR_MCP_ACCESS_TOKEN;
    } else {
      process.env.OPENBURNBAR_MCP_ACCESS_TOKEN = previousAccessToken;
    }
    if (previousRefreshToken === undefined) {
      delete process.env.OPENBURNBAR_MCP_REFRESH_TOKEN;
    } else {
      process.env.OPENBURNBAR_MCP_REFRESH_TOKEN = previousRefreshToken;
    }
  }
});

test("spawn command uses detached target mapping without hosted plaintext persistence", () => {
  const command = buildResumeSpawnCommand({
    kind: "ported_sealed",
    text: "# BurnBar Resume\n\nContinue this work.",
    targetHarness: "codex",
    targetModel: "gpt-5.1",
    workingDirectory: "/tmp/project"
  });

  assert.equal(command.command, "codex");
  assert.deepEqual(command.args.slice(0, 4), ["--model", "gpt-5.1", "-C", "/tmp/project"]);
  assert.match(command.args.at(-1) ?? "", /# BurnBar Resume/);
  assert.equal(command.cwd, "/tmp/project");
});
