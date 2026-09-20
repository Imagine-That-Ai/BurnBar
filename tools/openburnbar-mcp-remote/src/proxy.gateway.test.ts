import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import {
  chmodSync,
  cpSync,
  mkdtempSync,
  mkdirSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import http from "node:http";
import { tmpdir } from "node:os";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import test from "node:test";
import type { ChildProcess } from "node:child_process";
import {
  allProxySnippetText,
  containsUnsafeDisplayText,
  createProxyServer,
  DEFAULT_PROXY_HOST,
  isAuthorized,
  LOCAL_CLIPROXY_KEY,
  parseProxyCliOptions,
  proxySnippets,
} from "./proxy.js";
import { DEFAULT_ANTHROPIC_VERSION } from "./proxyRelay.js";
import {
  TRAY_ACCESSIBILITY_TITLE,
  TRAY_BUNDLE_ID,
  TRAY_MACOS_ONLY,
  TRAY_MISSING_SWIFTC_HINT,
  TRAY_SF_SYMBOL,
  hashTraySources,
  startGatewayTray,
} from "./proxyTray.js";

interface HttpResult {
  status: number;
  headers: http.IncomingHttpHeaders;
  body: string;
}

interface StreamChunk {
  at: number;
  data: string;
}

const PKG_ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");

function getFreePort(): Promise<number> {
  return new Promise((resolve, reject) => {
    const server = http.createServer();
    server.listen(0, DEFAULT_PROXY_HOST, () => {
      const address = server.address();
      if (!address || typeof address === "string") {
        server.close(() => reject(new Error("Unable to allocate a test port")));
        return;
      }
      server.close(() => resolve(address.port));
    });
  });
}

function request(
  port: number,
  options: {
    method?: string;
    path?: string;
    headers?: Record<string, string>;
    body?: string;
  } = {}
): Promise<HttpResult> {
  return new Promise((resolve, reject) => {
    const req = http.request(
      {
        host: DEFAULT_PROXY_HOST,
        port,
        method: options.method ?? "GET",
        path: options.path ?? "/",
        headers: options.headers,
      },
      (res) => {
        const chunks: Buffer[] = [];
        res.on("data", (chunk: Buffer) => chunks.push(chunk));
        res.on("end", () => {
          resolve({
            status: res.statusCode ?? 0,
            headers: res.headers,
            body: Buffer.concat(chunks).toString("utf8"),
          });
        });
      }
    );
    req.on("error", reject);
    if (options.body !== undefined) {
      req.write(options.body);
    }
    req.end();
  });
}

function jsonPost(
  port: number,
  path: string,
  body: unknown,
  headers: Record<string, string> = {}
): Promise<HttpResult> {
  const payload = JSON.stringify(body);
  return request(port, {
    method: "POST",
    path,
    headers: {
      authorization: `Bearer ${LOCAL_CLIPROXY_KEY}`,
      "content-length": String(Buffer.byteLength(payload)),
      "content-type": "application/json",
      ...headers,
    },
    body: payload,
  });
}

function streamPost(
  port: number,
  path: string,
  body: unknown,
  headers: Record<string, string> = {}
): Promise<{ status: number; headers: http.IncomingHttpHeaders; chunks: StreamChunk[] }> {
  const payload = JSON.stringify(body);
  return new Promise((resolve, reject) => {
    const req = http.request(
      {
        host: DEFAULT_PROXY_HOST,
        port,
        method: "POST",
        path,
        headers: {
          authorization: `Bearer ${LOCAL_CLIPROXY_KEY}`,
          "content-length": String(Buffer.byteLength(payload)),
          "content-type": "application/json",
          ...headers,
        },
      },
      (res) => {
        const chunks: StreamChunk[] = [];
        const started = Date.now();
        res.on("data", (chunk: Buffer) => {
          chunks.push({ at: Date.now() - started, data: chunk.toString("utf8") });
        });
        res.on("end", () => {
          resolve({ status: res.statusCode ?? 0, headers: res.headers, chunks });
        });
      }
    );
    req.on("error", reject);
    req.write(payload);
    req.end();
  });
}

async function withServer(
  options: Parameters<typeof createProxyServer>[0],
  operation: (port: number) => Promise<void>
): Promise<void> {
  const server = createProxyServer(options);
  await new Promise<void>((resolve) =>
    server.listen({ host: DEFAULT_PROXY_HOST, port: options.port }, resolve)
  );
  try {
    await operation(options.port);
  } finally {
    await new Promise<void>((resolve) => server.close(() => resolve()));
  }
}

function listenProvider(
  port: number,
  handler: (req: http.IncomingMessage, res: http.ServerResponse, body: string) => void
): Promise<http.Server> {
  const server = http.createServer((req, res) => {
    const chunks: Buffer[] = [];
    req.on("data", (chunk: Buffer) => chunks.push(chunk));
    req.on("end", () => handler(req, res, Buffer.concat(chunks).toString("utf8")));
  });
  return new Promise((resolve) => {
    server.listen({ host: DEFAULT_PROXY_HOST, port }, () => resolve(server));
  });
}

test("status payload includes both URLs and the well-known local key without secrets", async () => {
  const port = await getFreePort();
  await withServer(
    {
      port,
      host: DEFAULT_PROXY_HOST,
      allowLocalKey: true,
      instanceToken: "a".repeat(64),
      provider: { name: "xai", baseUrl: "https://api.x.ai/v1", apiKey: "xai-secret-value" },
    },
    async () => {
      const panel = await request(port, {
        path: "/v1/gateway/panel",
        headers: { authorization: `Bearer ${LOCAL_CLIPROXY_KEY}` },
      });
      assert.equal(panel.status, 200);
      const json = JSON.parse(panel.body) as Record<string, unknown>;
      assert.equal(json["product"], "openburnbar-gateway");
      assert.equal(json["openaiUrl"], `http://${DEFAULT_PROXY_HOST}:${port}/v1`);
      assert.equal(json["anthropicUrl"], `http://${DEFAULT_PROXY_HOST}:${port}`);
      assert.equal(json["localKey"], LOCAL_CLIPROXY_KEY);
      assert.equal(json["ready"], "ready");
      assert.doesNotMatch(panel.body, /xai-secret|sk-/u);
      assert.doesNotMatch(panel.body, /a{64}/u);
    }
  );
});

test("messages relay accepts Bearer and x-api-key, ignores query, and forwards Anthropic headers", async () => {
  const providerPort = await getFreePort();
  const seen: Array<{
    url: string | undefined;
    authorization: string | undefined;
    apiKey: string | undefined;
    version: string | undefined;
    beta: string | undefined;
    body: string;
  }> = [];
  const provider = await listenProvider(providerPort, (req, res, body) => {
    seen.push({
      url: req.url,
      authorization: req.headers["authorization"],
      apiKey: Array.isArray(req.headers["x-api-key"]) ? req.headers["x-api-key"][0] : req.headers["x-api-key"],
      version: Array.isArray(req.headers["anthropic-version"])
        ? req.headers["anthropic-version"][0]
        : req.headers["anthropic-version"],
      beta: Array.isArray(req.headers["anthropic-beta"])
        ? req.headers["anthropic-beta"][0]
        : req.headers["anthropic-beta"],
      body,
    });
    res.writeHead(200, { "Content-Type": "application/json" });
    res.end(JSON.stringify({ id: "msg_fixture", type: "message", content: [] }));
  });

  const proxyPort = await getFreePort();
  try {
    await withServer(
      {
        port: proxyPort,
        host: DEFAULT_PROXY_HOST,
        allowLocalKey: true,
        provider: {
          name: "fixture",
          baseUrl: `http://${DEFAULT_PROXY_HOST}:${providerPort}/v1`,
          apiKey: "provider-secret",
        },
      },
      async () => {
        const original = {
          model: "claude-opus-5",
          messages: [{ role: "user", content: "hello" }],
          max_tokens: 32,
        };
        const viaKey = await jsonPost(proxyPort, "/v1/messages?beta=true", original, {
          authorization: "",
          "x-api-key": LOCAL_CLIPROXY_KEY,
          "anthropic-version": "2023-06-01",
          "anthropic-beta": "fine-grained-tool-streaming-2025-05-14",
        });
        assert.equal(viaKey.status, 200, viaKey.body);

        const missingVersion = await jsonPost(proxyPort, "/v1/messages", original);
        assert.equal(missingVersion.status, 200);

        const noMaxTokens = {
          model: "claude-opus-5",
          messages: [{ role: "user", content: "hello" }],
        };
        const noMaxResult = await jsonPost(proxyPort, "/v1/messages", noMaxTokens);
        assert.equal(noMaxResult.status, 200);
        assert.equal(seen[2]?.body, JSON.stringify(noMaxTokens));
        assert.doesNotMatch(seen[2]?.body ?? "", /max_tokens/u);

        assert.equal(seen[0]?.url, "/v1/messages?beta=true");
        assert.equal(seen[0]?.authorization, "Bearer provider-secret");
        assert.equal(seen[0]?.apiKey, "provider-secret");
        assert.equal(seen[0]?.version, "2023-06-01");
        assert.equal(seen[0]?.beta, "fine-grained-tool-streaming-2025-05-14");
        assert.equal(seen[0]?.body, JSON.stringify(original));
        assert.equal(seen[1]?.version, DEFAULT_ANTHROPIC_VERSION);
        assert.equal(seen[1]?.beta, undefined);
      }
    );
  } finally {
    await new Promise<void>((resolve) => provider.close(() => resolve()));
  }
});

test("messages streaming client sees the first SSE chunk before the delayed second chunk", { timeout: 5_000 }, async () => {
  const providerPort = await getFreePort();
  let releaseSecond: (() => void) | undefined;
  const secondGate = new Promise<void>((resolve) => {
    releaseSecond = resolve;
  });
  const provider = await listenProvider(providerPort, (_req, res) => {
    res.writeHead(200, { "Content-Type": "text/event-stream" });
    res.write(": ping\n\n");
    void secondGate.then(() => {
      res.write('data: {"type":"content_block_delta"}\n\n');
      res.end();
    });
  });
  const proxyPort = await getFreePort();
  try {
    await withServer(
      {
        port: proxyPort,
        host: DEFAULT_PROXY_HOST,
        allowLocalKey: true,
        provider: {
          name: "fixture",
          baseUrl: `http://${DEFAULT_PROXY_HOST}:${providerPort}/v1`,
          apiKey: "provider-secret",
        },
      },
      async () => {
        const payload = JSON.stringify({
          model: "claude-opus-5",
          messages: [{ role: "user", content: "hello" }],
          stream: true,
        });
        const result = await new Promise<{ chunks: StreamChunk[] }>((resolve, reject) => {
          const req = http.request(
            {
              host: DEFAULT_PROXY_HOST,
              port: proxyPort,
              method: "POST",
              path: "/v1/messages",
              headers: {
                authorization: `Bearer ${LOCAL_CLIPROXY_KEY}`,
                "content-length": String(Buffer.byteLength(payload)),
                "content-type": "application/json",
              },
            },
            (res) => {
              const chunks: StreamChunk[] = [];
              const started = Date.now();
              res.on("data", (chunk: Buffer) => {
                chunks.push({ at: Date.now() - started, data: chunk.toString("utf8") });
                if (chunks.length === 1) {
                  assert.match(chunks[0]?.data ?? "", /:\s*ping/u);
                  releaseSecond?.();
                }
              });
              res.on("end", () => resolve({ chunks }));
            }
          );
          req.on("error", reject);
          req.write(payload);
          req.end();
        });
        assert.match(result.chunks[0]?.data ?? "", /:\s*ping/u);
        assert.ok(result.chunks.some((chunk) => chunk.data.includes("content_block_delta")));
      }
    );
  } finally {
    await new Promise<void>((resolve) => provider.close(() => resolve()));
  }
});

test("unconfigured messages and responses return 503; unauthorized messages return 401", async () => {
  const port = await getFreePort();
  await withServer({ port, host: DEFAULT_PROXY_HOST, allowLocalKey: true }, async () => {
    const unauthorized = await request(port, {
      method: "POST",
      path: "/v1/messages",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        model: "claude-opus-5",
        messages: [{ role: "user", content: "hello" }],
      }),
    });
    assert.equal(unauthorized.status, 401);
    assert.match(unauthorized.body, /openburnbar proxy status/u);
    assert.match(unauthorized.body, /x-api-key/u);

    const messages = await jsonPost(port, "/v1/messages", {
      model: "claude-opus-5",
      messages: [{ role: "user", content: "hello" }],
    });
    assert.equal(messages.status, 503);
    assert.match(messages.body, /provider_not_configured/u);
    assert.match(messages.body, /XAI_API_KEY/u);
    assert.match(messages.body, /OPENBURNBAR_UPSTREAM/u);

    const responses = await jsonPost(port, "/v1/responses", {
      model: "grok-4.6",
      input: "hello",
    });
    assert.equal(responses.status, 503);
  });
});

test("responses relays string and array input without rewriting the body", async () => {
  const providerPort = await getFreePort();
  const seen: Array<{ body: string; xApiKey: string | string[] | undefined; authorization: string | undefined }> =
    [];
  const provider = await listenProvider(providerPort, (req, res, body) => {
    seen.push({
      body,
      xApiKey: req.headers["x-api-key"],
      authorization: req.headers["authorization"],
    });
    res.writeHead(200, { "Content-Type": "application/json" });
    res.end(JSON.stringify({ id: "resp_fixture", object: "response" }));
  });
  const proxyPort = await getFreePort();
  try {
    await withServer(
      {
        port: proxyPort,
        host: DEFAULT_PROXY_HOST,
        allowLocalKey: true,
        provider: {
          name: "fixture",
          baseUrl: `http://${DEFAULT_PROXY_HOST}:${providerPort}/v1`,
          apiKey: "provider-secret",
        },
      },
      async () => {
        const stringBody = { model: "grok-4.6", input: "hello" };
        const arrayBody = {
          model: "grok-4.6",
          input: [{ role: "user", content: "hello" }],
        };
        const stringResult = await jsonPost(proxyPort, "/v1/responses", stringBody);
        const arrayResult = await jsonPost(proxyPort, "/v1/responses", arrayBody);
        assert.equal(stringResult.status, 200);
        assert.equal(arrayResult.status, 200);
        assert.equal(seen[0]?.body, JSON.stringify(stringBody));
        assert.equal(seen[1]?.body, JSON.stringify(arrayBody));
        assert.equal(seen[0]?.authorization, "Bearer provider-secret");
        assert.equal(seen[0]?.xApiKey, undefined);
        assert.equal(seen[1]?.xApiKey, undefined);
      }
    );
  } finally {
    await new Promise<void>((resolve) => provider.close(() => resolve()));
  }
});

test("responses SSE is not buffered and Codex stream:true is forwarded", { timeout: 5_000 }, async () => {
  const providerPort = await getFreePort();
  let releaseSecond: (() => void) | undefined;
  const secondGate = new Promise<void>((resolve) => {
    releaseSecond = resolve;
  });
  const provider = await listenProvider(providerPort, (_req, res, body) => {
    assert.match(body, /"stream":true/u);
    res.writeHead(200, { "Content-Type": "text/event-stream" });
    res.write('data: {"type":"response.created"}\n\n');
    void secondGate.then(() => {
      res.write("data: [DONE]\n\n");
      res.end();
    });
  });
  const proxyPort = await getFreePort();
  try {
    await withServer(
      {
        port: proxyPort,
        host: DEFAULT_PROXY_HOST,
        allowLocalKey: true,
        provider: {
          name: "fixture",
          baseUrl: `http://${DEFAULT_PROXY_HOST}:${providerPort}/v1`,
          apiKey: "provider-secret",
        },
      },
      async () => {
        const payload = JSON.stringify({
          model: "grok-4.6",
          input: "hello",
          stream: true,
        });
        const result = await new Promise<{ first: string; contentType: string | undefined }>(
          (resolve, reject) => {
            const req = http.request(
              {
                host: DEFAULT_PROXY_HOST,
                port: proxyPort,
                method: "POST",
                path: "/v1/responses",
                headers: {
                  authorization: `Bearer ${LOCAL_CLIPROXY_KEY}`,
                  "content-length": String(Buffer.byteLength(payload)),
                  "content-type": "application/json",
                },
              },
              (res) => {
                let first = "";
                res.on("data", (chunk: Buffer) => {
                  if (!first) {
                    first = chunk.toString("utf8");
                    assert.match(first, /response\.created/u);
                    releaseSecond?.();
                  }
                });
                res.on("end", () => {
                  resolve({
                    first,
                    contentType: Array.isArray(res.headers["content-type"])
                      ? res.headers["content-type"][0]
                      : res.headers["content-type"],
                  });
                });
              }
            );
            req.on("error", reject);
            req.write(payload);
            req.end();
          }
        );
        assert.match(result.first, /response\.created/u);
        assert.match(String(result.contentType), /text\/event-stream/u);
      }
    );
  } finally {
    await new Promise<void>((resolve) => provider.close(() => resolve()));
  }
});

test("non-loopback and off-loopback x-api-key are denied", () => {
  assert.equal(
    isAuthorized(`Bearer ${LOCAL_CLIPROXY_KEY}`, undefined, "8.8.8.8", { allowLocalKey: true }),
    false
  );
  assert.equal(
    isAuthorized(undefined, LOCAL_CLIPROXY_KEY, "8.8.8.8", { allowLocalKey: true }),
    false
  );
});

test("non-stream hung upstream hits the injected timeout path", async () => {
  const providerPort = await getFreePort();
  const provider = http.createServer(() => {
    // Intentionally never respond.
  });
  await new Promise<void>((resolve) =>
    provider.listen({ host: DEFAULT_PROXY_HOST, port: providerPort }, resolve)
  );
  const proxyPort = await getFreePort();
  try {
    await withServer(
      {
        port: proxyPort,
        host: DEFAULT_PROXY_HOST,
        allowLocalKey: true,
        nonStreamFetchTimeoutMs: 50,
        provider: {
          name: "fixture",
          baseUrl: `http://${DEFAULT_PROXY_HOST}:${providerPort}/v1`,
          apiKey: "provider-secret",
        },
      },
      async () => {
        const started = Date.now();
        const result = await jsonPost(proxyPort, "/v1/chat/completions", {
          model: "grok-4.6",
          messages: [{ role: "user", content: "hello" }],
          stream: false,
        });
        assert.equal(result.status, 502);
        assert.ok(Date.now() - started < 5_000);
        assert.match(result.body, /bad_gateway/u);
      }
    );
  } finally {
    await new Promise<void>((resolve) => provider.close(() => resolve()));
  }
});

test(
  "stream stays open after 35s of SSE pings with no abort",
  { timeout: 60_000 },
  async () => {
    const providerPort = await getFreePort();
    const provider = await listenProvider(providerPort, (_req, res) => {
      res.writeHead(200, { "Content-Type": "text/event-stream" });
      res.write(": ping\n\n");
      const started = Date.now();
      const timer = setInterval(() => {
        res.write(": ping\n\n");
        if (Date.now() - started >= 35_000) {
          clearInterval(timer);
          res.write("data: [DONE]\n\n");
          res.end();
        }
      }, 5_000);
    });
    const proxyPort = await getFreePort();
    try {
      await withServer(
        {
          port: proxyPort,
          host: DEFAULT_PROXY_HOST,
          allowLocalKey: true,
          provider: {
            name: "fixture",
            baseUrl: `http://${DEFAULT_PROXY_HOST}:${providerPort}/v1`,
            apiKey: "provider-secret",
          },
        },
        async () => {
          const started = Date.now();
          const stream = await streamPost(proxyPort, "/v1/chat/completions", {
            model: "grok-4.6",
            messages: [{ role: "user", content: "hello" }],
            stream: true,
          });
          const elapsed = Date.now() - started;
          assert.equal(stream.status, 200);
          assert.ok(elapsed >= 35_000, `elapsed ${elapsed}`);
          assert.ok(stream.chunks.length >= 2);
          assert.match(stream.chunks.map((chunk) => chunk.data).join(""), /data: \[DONE\]/u);
        }
      );
    } finally {
      await new Promise<void>((resolve) => provider.close(() => resolve()));
    }
  }
);

test("messages 404 becomes dialect_not_supported after exactly one upstream call", async () => {
  const providerPort = await getFreePort();
  let calls = 0;
  const provider = await listenProvider(providerPort, (req, res) => {
    calls += 1;
    assert.equal(req.url, "/v1/messages");
    res.writeHead(404, { "Content-Type": "application/json" });
    res.end(JSON.stringify({ error: { message: "not found" } }));
  });
  const proxyPort = await getFreePort();
  try {
    await withServer(
      {
        port: proxyPort,
        host: DEFAULT_PROXY_HOST,
        allowLocalKey: true,
        provider: {
          name: "xai",
          baseUrl: `http://${DEFAULT_PROXY_HOST}:${providerPort}/v1`,
          apiKey: "provider-secret",
        },
      },
      async () => {
        const result = await jsonPost(proxyPort, "/v1/messages", {
          model: "claude-opus-5",
          messages: [{ role: "user", content: "hello" }],
        });
        assert.equal(result.status, 502);
        assert.match(result.body, /dialect_not_supported/u);
        assert.match(result.body, /OPENBURNBAR_UPSTREAM=http:\/\/127\.0\.0\.1:8317/u);
        assert.equal(calls, 1);
      }
    );
  } finally {
    await new Promise<void>((resolve) => provider.close(() => resolve()));
  }
});

test("redirects fail closed on chat, messages, and responses", async () => {
  const providerPort = await getFreePort();
  const provider = await listenProvider(providerPort, (_req, res) => {
    res.writeHead(307, { Location: "https://example.com/collect" });
    res.end();
  });
  const proxyPort = await getFreePort();
  try {
    await withServer(
      {
        port: proxyPort,
        host: DEFAULT_PROXY_HOST,
        allowLocalKey: true,
        provider: {
          name: "fixture",
          baseUrl: `http://${DEFAULT_PROXY_HOST}:${providerPort}/v1`,
          apiKey: "provider-secret",
        },
      },
      async () => {
        for (const [path, body] of [
          ["/v1/chat/completions", { model: "grok-4.6", messages: [{ role: "user", content: "hello" }] }],
          ["/v1/messages", { model: "claude-opus-5", messages: [{ role: "user", content: "hello" }] }],
          ["/v1/responses", { model: "grok-4.6", input: "hello" }],
        ] as const) {
          const result = await jsonPost(proxyPort, path, body);
          assert.equal(result.status, 502, path);
          assert.equal(result.headers["location"], undefined);
          assert.match(result.body, /unsafe_upstream_redirect/u);
        }
      }
    );
  } finally {
    await new Promise<void>((resolve) => provider.close(() => resolve()));
  }
});

test("copy-paste snippets pin loopback URLs and required client flags", () => {
  const text = allProxySnippetText(8320);
  assert.match(text, /customModels/u);
  assert.match(text, /ANTHROPIC_BASE_URL=http:\/\/127\.0\.0\.1:8320$/m);
  assert.match(text, /response_type = "OpenAI"/u);
  assert.match(text, /@ai-sdk\/openai-compatible/u);
  assert.doesNotMatch(text, /localhost/u);
  assert.doesNotMatch(text, /CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY/u);
  assert.doesNotMatch(text, /wire_api = "chat"/u);
  const grok = proxySnippets(8320).find((snippet) => snippet.id === "grok");
  assert.ok(grok);
  assert.doesNotMatch(grok.body, /env_key = "XAI_API_KEY"/u);
  assert.match(grok.body, /env_key = "OPENBURNBAR_GATEWAY_TOKEN"/u);
  const codex = proxySnippets(8320).find((snippet) => snippet.id === "codex");
  assert.ok(codex);
  assert.match(codex.body, /wire_api = "responses"/u);
  assert.match(codex.body, /supports_websockets = false/u);
  assert.match(codex.body, /requires_openai_auth = false/u);
  assert.equal(proxySnippets(8320).some((snippet) => snippet.id === "cursor"), true);
  assert.match(proxySnippets(8320).find((snippet) => snippet.id === "cursor")?.body ?? "", /^No\./u);
});

test("loopback display text allows 127.0.0.1 with a port and refuses localhost or foreign hosts", () => {
  assert.equal(containsUnsafeDisplayText("http://127.0.0.1:8320/v1"), false);
  assert.equal(containsUnsafeDisplayText("http://127.0.0.1:8320"), false);
  const codex = proxySnippets(8320).find((snippet) => snippet.id === "codex");
  assert.ok(codex);
  assert.equal(containsUnsafeDisplayText(codex.body), false);
  assert.equal(containsUnsafeDisplayText("http://example.com/v1"), true);
  assert.equal(containsUnsafeDisplayText("http://localhost:8320/v1"), true);
  assert.equal(containsUnsafeDisplayText("https://127.0.0.1:8320/v1"), true);
});

test("--tray parses on every platform", () => {
  assert.equal(parseProxyCliOptions(["--tray"], {}).tray, true);
});

test("ensureGatewayTrayApp stays darwin-only", async () => {
  await assert.rejects(
    () => startGatewayTray({
      port: 8320,
      parentPid: process.pid,
      nodePath: process.execPath,
      cliPath: "/tmp/openburnbar",
      platform: "linux",
    }),
    (error: unknown) => error instanceof Error && error.message === TRAY_MACOS_ONLY
  );
});

test("macos-tray sources ship the gateway mark and LSUIElement app metadata", () => {
  const plist = readFileSync(join(PKG_ROOT, "macos-tray/Info.plist"), "utf8");
  const source = readFileSync(
    join(PKG_ROOT, "macos-tray/Sources/OpenBurnBarGatewayTray/main.swift"),
    "utf8"
  );
  assert.match(plist, /LSUIElement/u);
  assert.match(plist, new RegExp(TRAY_BUNDLE_ID, "u"));
  assert.match(source, new RegExp(TRAY_SF_SYMBOL, "u"));
  assert.match(source, new RegExp(TRAY_ACCESSIBILITY_TITLE, "u"));
  assert.match(source, /NSStatusItem/u);
  assert.match(source, /NSPopover/u);
  assert.doesNotMatch(source, /MenuBarExtra/u);
  assert.doesNotMatch(source, /WKWebView/u);
});

test("TRAY_MACOS_ONLY copy is exact", () => {
  assert.equal(TRAY_MACOS_ONLY, "error: --tray is macOS-only");
});

test("gateway panel requires auth", async () => {
  const port = await getFreePort();
  await withServer({ port, host: DEFAULT_PROXY_HOST, allowLocalKey: true }, async () => {
    const result = await request(port, { path: "/v1/gateway/panel" });
    assert.equal(result.status, 401);
  });
});

test("messages and responses validation mirrors chat and does not invent max_tokens", async () => {
  const port = await getFreePort();
  await withServer({ port, host: DEFAULT_PROXY_HOST, allowLocalKey: true }, async () => {
    const malformed = await request(port, {
      method: "POST",
      path: "/v1/messages",
      headers: {
        authorization: `Bearer ${LOCAL_CLIPROXY_KEY}`,
        "content-type": "application/json",
      },
      body: "{",
    });
    assert.equal(malformed.status, 400);

    const emptyMessages = await jsonPost(port, "/v1/messages", {
      model: "claude-opus-5",
      messages: [],
    });
    assert.equal(emptyMessages.status, 400);

    const badStream = await jsonPost(port, "/v1/responses", {
      model: "grok-4.6",
      input: "hello",
      stream: "true",
    });
    assert.equal(badStream.status, 400);

    const missingInput = await jsonPost(port, "/v1/responses", { model: "grok-4.6" });
    assert.equal(missingInput.status, 400);

    const unsupported = await request(port, {
      method: "POST",
      path: "/v1/messages",
      headers: { authorization: `Bearer ${LOCAL_CLIPROXY_KEY}` },
      body: "{}",
    });
    assert.equal(unsupported.status, 415);
  });
});

test("dialect_not_supported covers messages/responses 404/405 once; chat 404 stays 404", async () => {
  for (const [path, status, body] of [
    ["/v1/messages", 404, { model: "claude-opus-5", messages: [{ role: "user", content: "hello" }] }],
    ["/v1/messages", 405, { model: "claude-opus-5", messages: [{ role: "user", content: "hello" }] }],
    ["/v1/responses", 404, { model: "grok-4.6", input: "hello" }],
    ["/v1/responses", 405, { model: "grok-4.6", input: "hello" }],
  ] as const) {
    const providerPort = await getFreePort();
    let calls = 0;
    const provider = await listenProvider(providerPort, (_req, res) => {
      calls += 1;
      res.writeHead(status, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ error: { message: "missing" } }));
    });
    const proxyPort = await getFreePort();
    try {
      await withServer(
        {
          port: proxyPort,
          host: DEFAULT_PROXY_HOST,
          allowLocalKey: true,
          provider: {
            name: "xai",
            baseUrl: `http://${DEFAULT_PROXY_HOST}:${providerPort}/v1`,
            apiKey: "provider-secret",
          },
        },
        async () => {
          const result = await jsonPost(proxyPort, path, body);
          assert.equal(result.status, 502, `${path} ${status}`);
          assert.match(result.body, /dialect_not_supported/u);
          assert.equal(calls, 1);
        }
      );
    } finally {
      await new Promise<void>((resolve) => provider.close(() => resolve()));
    }
  }

  const chatPort = await getFreePort();
  let chatCalls = 0;
  const chatUpstream = await listenProvider(chatPort, (_req, res) => {
    chatCalls += 1;
    res.writeHead(404, { "Content-Type": "application/json" });
    res.end(JSON.stringify({ error: { code: "not_found" } }));
  });
  const proxyPort = await getFreePort();
  try {
    await withServer(
      {
        port: proxyPort,
        host: DEFAULT_PROXY_HOST,
        allowLocalKey: true,
        provider: {
          name: "fixture",
          baseUrl: `http://${DEFAULT_PROXY_HOST}:${chatPort}/v1`,
          apiKey: "provider-secret",
        },
      },
      async () => {
        const result = await jsonPost(proxyPort, "/v1/chat/completions", {
          model: "grok-4.6",
          messages: [{ role: "user", content: "hello" }],
        });
        assert.equal(result.status, 404);
        assert.doesNotMatch(result.body, /dialect_not_supported/u);
        assert.equal(chatCalls, 1);
      }
    );
  } finally {
    await new Promise<void>((resolve) => chatUpstream.close(() => resolve()));
  }
});

test("relay allowlists hop-safe response headers and strips ACAO/Location on 200", async () => {
  const providerPort = await getFreePort();
  const provider = await listenProvider(providerPort, (_req, res) => {
    res.writeHead(200, {
      "Content-Type": "application/json",
      "Access-Control-Allow-Origin": "*",
      Location: "https://example.com/collect",
      "Set-Cookie": "session=evil",
      Authorization: "Bearer leaked",
      "Retry-After": "7",
    });
    res.end(JSON.stringify({ id: "ok" }));
  });
  const proxyPort = await getFreePort();
  try {
    await withServer(
      {
        port: proxyPort,
        host: DEFAULT_PROXY_HOST,
        allowLocalKey: true,
        provider: {
          name: "fixture",
          baseUrl: `http://${DEFAULT_PROXY_HOST}:${providerPort}/v1`,
          apiKey: "provider-secret",
        },
      },
      async () => {
        const result = await jsonPost(proxyPort, "/v1/chat/completions", {
          model: "grok-4.6",
          messages: [{ role: "user", content: "hello" }],
        });
        assert.equal(result.status, 200);
        assert.equal(result.headers["access-control-allow-origin"], undefined);
        assert.equal(result.headers["location"], undefined);
        assert.equal(result.headers["set-cookie"], undefined);
        assert.equal(result.headers["authorization"], undefined);
        assert.equal(result.headers["retry-after"], "7");
        assert.equal(result.headers["cache-control"], "no-store");
        assert.equal(result.headers["x-content-type-options"], "nosniff");
      }
    );
  } finally {
    await new Promise<void>((resolve) => provider.close(() => resolve()));
  }
});

test("stream fetch is not aborted by the non-stream timeout cap", async () => {
  const providerPort = await getFreePort();
  const provider = await listenProvider(providerPort, (_req, res) => {
    res.writeHead(200, { "Content-Type": "text/event-stream" });
    res.write(": ping\n\n");
    setTimeout(() => {
      res.write("data: [DONE]\n\n");
      res.end();
    }, 120);
  });
  const proxyPort = await getFreePort();
  try {
    await withServer(
      {
        port: proxyPort,
        host: DEFAULT_PROXY_HOST,
        allowLocalKey: true,
        nonStreamFetchTimeoutMs: 50,
        provider: {
          name: "fixture",
          baseUrl: `http://${DEFAULT_PROXY_HOST}:${providerPort}/v1`,
          apiKey: "provider-secret",
        },
      },
      async () => {
        const started = Date.now();
        const stream = await streamPost(proxyPort, "/v1/chat/completions", {
          model: "grok-4.6",
          messages: [{ role: "user", content: "hello" }],
          stream: true,
        });
        assert.equal(stream.status, 200);
        assert.ok(Date.now() - started >= 100);
        assert.match(stream.chunks.map((chunk) => chunk.data).join(""), /data: \[DONE\]/u);
      }
    );
  } finally {
    await new Promise<void>((resolve) => provider.close(() => resolve()));
  }
});

function fakeChildProcess(): ChildProcess {
  const child = new EventEmitter() as ChildProcess;
  Object.defineProperty(child, "pid", { value: 4242, configurable: true });
  Object.defineProperty(child, "exitCode", { value: null, writable: true });
  Object.defineProperty(child, "killed", { value: false, writable: true, configurable: true });
  child.kill = (signal?: NodeJS.Signals | number) => {
    Object.defineProperty(child, "killed", { value: true, configurable: true });
    child.emit("exit", 0, typeof signal === "string" ? signal : "SIGTERM");
    return true;
  };
  return child;
}

test("tray compile uses Sources swift only, hash hits skip compile, missing swiftc is headless", async () => {
  const root = mkdtempSync(join(tmpdir(), "obb-tray-"));
  const sourceDir = join(root, "macos-tray");
  const home = join(root, "home");
  mkdirSync(home, { recursive: true });
  cpSync(join(PKG_ROOT, "macos-tray"), sourceDir, { recursive: true });
  writeFileSync(join(sourceDir, "Package.swift"), 'import PackageDescription\nlet package = Package(name: "x")\n');

  const compiles: string[][] = [];
  const spawns: Array<{ file: string; args: readonly string[]; detached: boolean | undefined }> = [];
  const logs: string[] = [];
  try {
    const first = await startGatewayTray({
      port: 8320,
      parentPid: 99,
      nodePath: process.execPath,
      cliPath: "/tmp/index.js",
      platform: "darwin",
      homedir: () => home,
      sourceDir,
      findSwiftc: () => "/usr/bin/swiftc",
      compile: ({ sources, output }) => {
        compiles.push(sources);
        writeFileSync(output, "#!/bin/sh\nexit 0\n");
        chmodSync(output, 0o755);
      },
      spawnImpl: ((file, args, options) => {
        spawns.push({
          file: String(file),
          args: args ?? [],
          detached: options?.detached,
        });
        return fakeChildProcess();
      }) as typeof import("node:child_process").spawn,
      log: (message) => logs.push(message),
    });
    assert.ok(first);
    assert.equal(compiles.length, 1);
    assert.equal(compiles[0]?.length, 1);
    assert.ok(compiles[0]?.[0]?.endsWith("main.swift"));
    assert.ok(compiles[0]?.every((file) => !file.endsWith("Package.swift")));
    assert.equal(spawns[0]?.detached, false);
    assert.ok(spawns[0]?.args.includes("--port"));
    assert.ok(spawns[0]?.args.includes("8320"));

    const hash = hashTraySources(sourceDir);
    assert.equal(hashTraySources(sourceDir), hash);

    const second = await startGatewayTray({
      port: 8320,
      parentPid: 99,
      nodePath: process.execPath,
      cliPath: "/tmp/index.js",
      platform: "darwin",
      homedir: () => home,
      sourceDir,
      findSwiftc: () => "/usr/bin/swiftc",
      compile: () => {
        throw new Error("compile should be skipped on hash hit");
      },
      spawnImpl: ((file, args, options) => {
        spawns.push({
          file: String(file),
          args: args ?? [],
          detached: options?.detached,
        });
        return fakeChildProcess();
      }) as typeof import("node:child_process").spawn,
      log: (message) => logs.push(message),
    });
    assert.ok(second);
    assert.equal(compiles.length, 1);
    assert.equal((second as ChildProcess).killed, false);
    assert.equal(second.kill("SIGTERM"), true);
    assert.equal((second as ChildProcess).killed, true);

    const missing = await startGatewayTray({
      port: 8321,
      parentPid: 99,
      nodePath: process.execPath,
      cliPath: "/tmp/index.js",
      platform: "darwin",
      homedir: () => join(root, "home-missing"),
      sourceDir,
      findSwiftc: () => null,
      log: (message) => logs.push(message),
    });
    assert.equal(missing, null);
    assert.match(logs.join(""), new RegExp(TRAY_MISSING_SWIFTC_HINT.slice(0, 40), "u"));
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

