import assert from "node:assert/strict";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import http from "node:http";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import test from "node:test";
import {
  createProxyServer,
  DEFAULT_PROXY_HOST,
  LOCAL_CLIPROXY_KEY,
  REQUEST_TOO_LARGE_MESSAGE,
  runProxyCli,
  sanitizeProcessCommand,
} from "./proxy.js";
import { gatewayPanelHtml, openLoopbackPanel } from "./proxyPanel.js";
import { MAX_PROXY_BODY_BYTES } from "./proxyRelay.js";
import {
  decodeWsFrames,
  encodeWsText,
  websocketAcceptKey,
} from "./proxyWebsocket.js";
import { applyWire, parseWireClient } from "./proxyWire.js";

interface HttpResult {
  status: number;
  headers: http.IncomingHttpHeaders;
  body: string;
}

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
    server.closeAllConnections();
    await new Promise<void>((resolve) => server.close(() => resolve()));
  }
}

test("GET and DELETE /v1/responses/:id relay the stored-response path", async () => {
  const seen: Array<{ method?: string; url?: string }> = [];
  const providerPort = await getFreePort();
  const provider = http.createServer((req, res) => {
    seen.push({ method: req.method, url: req.url });
    res.writeHead(200, { "Content-Type": "application/json" });
    res.end(JSON.stringify({ id: "resp_fixture", object: "response" }));
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
        provider: {
          name: "fixture",
          baseUrl: `http://${DEFAULT_PROXY_HOST}:${providerPort}/v1`,
          apiKey: "provider-secret",
        },
      },
      async () => {
        const got = await request(proxyPort, {
          path: "/v1/responses/resp_fixture",
          headers: { authorization: `Bearer ${LOCAL_CLIPROXY_KEY}` },
        });
        assert.equal(got.status, 200);
        const deleted = await request(proxyPort, {
          method: "DELETE",
          path: "/v1/responses/resp_fixture",
          headers: { authorization: `Bearer ${LOCAL_CLIPROXY_KEY}` },
        });
        assert.equal(deleted.status, 200);
      }
    );
  } finally {
    await new Promise<void>((resolve) => provider.close(() => resolve()));
  }
  assert.deepEqual(seen, [
    { method: "GET", url: "/v1/responses/resp_fixture" },
    { method: "DELETE", url: "/v1/responses/resp_fixture" },
  ]);
});

test("Responses WebSocket upgrades and relays response.create as HTTP POST", { timeout: 8_000 }, async () => {
  const providerPort = await getFreePort();
  const provider = http.createServer((req, res) => {
    const chunks: Buffer[] = [];
    req.on("data", (chunk: Buffer) => chunks.push(chunk));
    req.on("end", () => {
      assert.match(Buffer.concat(chunks).toString("utf8"), /"stream":true/u);
      res.writeHead(200, { "Content-Type": "text/event-stream" });
      res.write('event: response.created\ndata: {"type":"response.created","response":{"id":"resp_ws"}}\n\n');
      res.end('event: response.completed\ndata: {"type":"response.completed","response":{"id":"resp_ws"}}\n\n');
    });
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
        provider: {
          name: "fixture",
          baseUrl: `http://${DEFAULT_PROXY_HOST}:${providerPort}/v1`,
          apiKey: "provider-secret",
        },
      },
      async () => {
        const key = Buffer.from("1234567890abcdef").toString("base64");
        const events = await new Promise<string[]>((resolve, reject) => {
          const req = http.request({
            host: DEFAULT_PROXY_HOST,
            port: proxyPort,
            path: "/v1/responses",
            agent: false,
            headers: {
              authorization: `Bearer ${LOCAL_CLIPROXY_KEY}`,
              connection: "Upgrade",
              upgrade: "websocket",
              "sec-websocket-version": "13",
              "sec-websocket-key": key,
            },
          });
          req.on("response", () => reject(new Error("expected upgrade")));
          req.on("upgrade", (_res, socket) => {
            const received: string[] = [];
            let rest = Buffer.alloc(0);
            socket.on("data", (chunk: Buffer) => {
              const decoded = decodeWsFrames(Buffer.concat([rest, chunk]));
              rest = Buffer.from(decoded.rest);
              for (const frame of decoded.frames) {
                if (frame.opcode === 1) {
                  received.push(frame.payload.toString("utf8"));
                }
              }
              if (received.some((row) => row.includes("response.completed"))) {
                socket.destroy();
                resolve(received);
              }
            });
            socket.write(
              encodeWsText(
                JSON.stringify({
                  type: "response.create",
                  stream_id: "main",
                  model: "grok-4.6",
                  input: "hello",
                }),
                true
              )
            );
          });
          req.on("error", reject);
          req.end();
        });
        assert.match(events.join("\n"), /response\.created/u);
        assert.match(events.join("\n"), /"stream_id":"main"/u);
        assert.equal(websocketAcceptKey(key).length > 10, true);
      }
    );
  } finally {
    provider.closeAllConnections();
    await new Promise<void>((resolve) => provider.close(() => resolve()));
  }
});

test("Responses WebSocket without a loopback key is 401 and does not hang close", { timeout: 3_000 }, async () => {
  const port = await getFreePort();
  await withServer({ port, host: DEFAULT_PROXY_HOST, allowLocalKey: true }, async () => {
    const key = Buffer.from("1234567890abcdef").toString("base64");
    const result = await new Promise<HttpResult>((resolve, reject) => {
      const req = http.request(
        {
          host: DEFAULT_PROXY_HOST,
          port,
          path: "/v1/responses",
          agent: false,
          headers: {
            connection: "Upgrade",
            upgrade: "websocket",
            "sec-websocket-version": "13",
            "sec-websocket-key": key,
          },
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
      req.on("upgrade", () => reject(new Error("unauthorized upgrade")));
      req.on("error", reject);
      req.end();
    });
    assert.equal(result.status, 401);
  });
});

test("413 copy names the 8 MiB cap and refuses to raise it speculatively", async () => {
  const port = await getFreePort();
  await withServer({ port, host: DEFAULT_PROXY_HOST, allowLocalKey: true }, async () => {
    const result = await request(port, {
      method: "POST",
      path: "/v1/chat/completions",
      headers: {
        authorization: `Bearer ${LOCAL_CLIPROXY_KEY}`,
        "content-type": "application/json",
        "content-length": String(MAX_PROXY_BODY_BYTES + 1),
      },
    });
    assert.equal(result.status, 413);
    assert.match(result.body, /request_too_large/u);
    assert.match(result.body, /8 MiB/u);
    assert.match(result.body, /does not raise/u);
    assert.match(REQUEST_TOO_LARGE_MESSAGE, /8 MiB/u);
  });
});

test("loopback HTML panel is unauthenticated and lists snippets", async () => {
  const port = await getFreePort();
  await withServer({ port, host: DEFAULT_PROXY_HOST, allowLocalKey: true }, async () => {
    const result = await request(port, { path: "/gateway" });
    assert.equal(result.status, 200);
    assert.match(result.headers["content-type"] ?? "", /text\/html/u);
    assert.match(result.body, /OpenBurnBar Gateway/u);
    assert.match(result.body, /local-cliproxy/u);
    assert.match(result.body, /wire_api = (&quot;|")responses(&quot;|")/u);
    assert.match(result.body, /Instructions for Agents/u);
    assert.match(result.body, /id="agentModal"/u);
    assert.match(result.body, /id="agentDirectiveCode"/u);
    assert.match(result.body, /data:image\/png;base64/u);
    assert.equal(gatewayPanelHtml(port).includes("localhost"), false);
  });
});

test("openLoopbackPanel prints the URL and invokes the opener", async () => {
  const opened: string[] = [];
  const logs: string[] = [];
  await openLoopbackPanel(8320, {
    opener: async (url) => {
      opened.push(url);
    },
    log: (line) => logs.push(line),
  });
  assert.deepEqual(opened, ["http://127.0.0.1:8320/gateway"]);
  assert.match(logs.join(""), /Gateway panel: http:\/\/127\.0\.0\.1:8320\/gateway/u);
});

test("proxy wire writes a :8320 sentinel without touching Mac :8317 blocks", () => {
  const home = mkdtempSync(join(tmpdir(), "obb-wire-"));
  try {
    const path = join(home, ".codex", "config.toml");
    mkdirSync(dirname(path), { recursive: true });
    writeFileSync(
      path,
      "# openburnbar:routing — start\nbase_url = \"http://127.0.0.1:8317/v1\"\n# openburnbar:routing — end\n"
    );
    const dry = applyWire("codex", { port: 8320, home, write: false });
    assert.match(dry.body, /supports_websockets = false/u);
    assert.match(dry.warning ?? "", /:8317/u);
    const merged = applyWire("codex", { port: 8320, home, write: true });
    assert.equal(merged.wrote, true);
    const text = readFileSync(merged.path, "utf8");
    assert.match(text, /openburnbar:routing/u);
    assert.match(text, /openburnbar:gateway-8320/u);
    assert.match(text, /127\.0\.0\.1:8320\/v1/u);
    applyWire("codex", { port: 8320, home, write: true, unwire: true });
    const after = readFileSync(merged.path, "utf8");
    assert.doesNotMatch(after, /gateway-8320/u);
    assert.match(after, /openburnbar:routing/u);
  } finally {
    rmSync(home, { recursive: true, force: true });
  }
});

test("proxy wire refuses Cursor and dry-runs Claude JSON", async () => {
  assert.throws(() => parseWireClient("cursor"), /Cursor BYOK/u);
  const home = mkdtempSync(join(tmpdir(), "obb-wire-json-"));
  try {
    const result = applyWire("claude", { port: 8320, home, write: true });
    const parsed = JSON.parse(readFileSync(result.path, "utf8")) as {
      env: Record<string, string>;
    };
    assert.equal(parsed.env["ANTHROPIC_BASE_URL"], "http://127.0.0.1:8320");
    assert.equal(parsed.env["OPENBURNBAR_GATEWAY_8320"], "1");
    const code = await runProxyCli(["wire", "--help"]);
    assert.equal(code, 0);
  } finally {
    rmSync(home, { recursive: true, force: true });
  }
});

test("Responses WebSocket accepts CRLF-terminated and EOF-flushed SSE streams", { timeout: 8_000 }, async () => {
  const providerPort = await getFreePort();
  const provider = http.createServer((_req, res) => {
    res.writeHead(200, { "Content-Type": "text/event-stream" });
    res.write("event: response.created\r\ndata: {\"type\":\"response.created\",\"response\":{\"id\":\"resp_crlf\"}}\r\n\r\n");
    // Send EOF terminated event without trailing newline
    res.end("event: response.completed\r\ndata: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp_crlf\"}}");
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
        provider: {
          name: "fixture",
          baseUrl: `http://${DEFAULT_PROXY_HOST}:${providerPort}/v1`,
          apiKey: "provider-secret",
        },
      },
      async () => {
        const key = Buffer.from("1234567890abcdef").toString("base64");
        const events = await new Promise<string[]>((resolve, reject) => {
          const req = http.request({
            host: DEFAULT_PROXY_HOST,
            port: proxyPort,
            path: "/v1/responses",
            agent: false,
            headers: {
              connection: "Upgrade",
              upgrade: "websocket",
              "sec-websocket-version": "13",
              "sec-websocket-key": key,
              authorization: `Bearer ${LOCAL_CLIPROXY_KEY}`,
            },
          });
          req.on("upgrade", (_res, socket) => {
            const received: string[] = [];
            socket.on("data", (chunk: Buffer) => {
              const text = chunk.toString("utf8");
              received.push(text);
              if (received.some((row) => row.includes("response.completed"))) {
                socket.destroy();
                resolve(received);
              }
            });
            socket.write(
              encodeWsText(
                JSON.stringify({
                  type: "response.create",
                  stream_id: "main",
                  model: "grok-4.6",
                  input: "hello",
                }),
                true
              )
            );
          });
          req.on("error", reject);
          req.end();
        });
        assert.match(events.join("\n"), /response\.created/u);
        assert.match(events.join("\n"), /response\.completed/u);
      }
    );
  } finally {
    provider.closeAllConnections();
    await new Promise<void>((resolve) => provider.close(() => resolve()));
  }
});

test("sanitizeProcessCommand strips control characters before redacting and preserves -p port flag", () => {
  const dirty = `node i.js proxy -p 8320 --token${String.fromCharCode(27)}[0m SUPERSECRET`;
  const sanitized = sanitizeProcessCommand(dirty);
  assert.equal(sanitized, "node i.js proxy -p 8320 --token [REDACTED]");

  const nulToken = `openburnbar proxy --token\0SUPERSECRET`;
  assert.equal(sanitizeProcessCommand(nulToken), "openburnbar proxy --token [REDACTED]");
});

test("Responses WebSocket timeout emits 504 upstream_timeout error frame", { timeout: 8_000 }, async () => {
  const providerPort = await getFreePort();
  const provider = http.createServer((_req, _res) => {
    // Hangs indefinitely without responding
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
        nonStreamFetchTimeoutMs: 250, // 250ms fast timeout
        provider: {
          name: "fixture",
          baseUrl: `http://${DEFAULT_PROXY_HOST}:${providerPort}/v1`,
          apiKey: "provider-secret",
        },
      },
      async () => {
        const key = Buffer.from("1234567890abcdef").toString("base64");
        const events = await new Promise<string[]>((resolve, reject) => {
          const req = http.request({
            host: DEFAULT_PROXY_HOST,
            port: proxyPort,
            path: "/v1/responses",
            agent: false,
            headers: {
              connection: "Upgrade",
              upgrade: "websocket",
              "sec-websocket-version": "13",
              "sec-websocket-key": key,
              authorization: `Bearer ${LOCAL_CLIPROXY_KEY}`,
            },
          });
          req.on("upgrade", (_res, socket) => {
            const received: string[] = [];
            socket.on("data", (chunk: Buffer) => {
              const text = chunk.toString("utf8");
              received.push(text);
              if (received.some((row) => row.includes("upstream_timeout"))) {
                socket.destroy();
                resolve(received);
              }
            });
            socket.write(
              encodeWsText(
                JSON.stringify({
                  type: "response.create",
                  stream_id: "main",
                  model: "grok-4.6",
                  input: "hello",
                }),
                true
              )
            );
          });
          req.on("error", reject);
          req.end();
        });
        assert.match(events.join("\n"), /upstream_timeout/u);
        assert.match(events.join("\n"), /504/u);
      }
    );
  } finally {
    provider.closeAllConnections();
    await new Promise<void>((resolve) => provider.close(() => resolve()));
  }
});

test("Responses WebSocket handles CRLF split across TCP chunk boundary", { timeout: 8_000 }, async () => {
  const providerPort = await getFreePort();
  const provider = http.createServer(async (_req, res) => {
    res.writeHead(200, { "Content-Type": "text/event-stream" });
    // Write event with CRLF split: chunk 1 ends with CR
    res.write("event: response.created\r\ndata: {\"type\":\"response.created\"}\r");
    await new Promise((r) => setTimeout(r, 50));
    // Chunk 2 starts with LF
    res.write("\n\r\nevent: response.completed\r\ndata: {\"type\":\"response.completed\"}\r\n\r\n");
    res.end();
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
        provider: {
          name: "fixture",
          baseUrl: `http://${DEFAULT_PROXY_HOST}:${providerPort}/v1`,
          apiKey: "provider-secret",
        },
      },
      async () => {
        const key = Buffer.from("1234567890abcdef").toString("base64");
        const events = await new Promise<string[]>((resolve, reject) => {
          const req = http.request({
            host: DEFAULT_PROXY_HOST,
            port: proxyPort,
            path: "/v1/responses",
            agent: false,
            headers: {
              connection: "Upgrade",
              upgrade: "websocket",
              "sec-websocket-version": "13",
              "sec-websocket-key": key,
              authorization: `Bearer ${LOCAL_CLIPROXY_KEY}`,
            },
          });
          req.on("upgrade", (_res, socket) => {
            const received: string[] = [];
            socket.on("data", (chunk: Buffer) => {
              const text = chunk.toString("utf8");
              received.push(text);
              if (received.some((row) => row.includes("response.completed"))) {
                socket.destroy();
                resolve(received);
              }
            });
            socket.write(
              encodeWsText(
                JSON.stringify({
                  type: "response.create",
                  stream_id: "main",
                  model: "grok-4.6",
                  input: "hello",
                }),
                true
              )
            );
          });
          req.on("error", reject);
          req.end();
        });
        assert.match(events.join("\n"), /response\.created/u);
        assert.match(events.join("\n"), /response\.completed/u);
      }
    );
  } finally {
    provider.closeAllConnections();
    await new Promise<void>((resolve) => provider.close(() => resolve()));
  }
});

test("applyWire handles JSONC configs with comments and creates backup file", () => {
  const home = mkdtempSync(join(tmpdir(), "obb-wire-jsonc-"));
  try {
    const claudeDir = join(home, ".claude");
    mkdirSync(claudeDir, { recursive: true });
    const settingsPath = join(claudeDir, "settings.json");
    writeFileSync(
      settingsPath,
      `{\n  // User comments\n  /* Multi-line\n comment */\n  "existing": "val",\n}\n`,
      "utf8"
    );
    const result = applyWire("claude", { port: 8320, home, write: true, token: "custom-token" });
    assert.equal(result.wrote, true);
    assert.equal(existsSync(`${settingsPath}.openburnbar.bak`), true);
    const parsed = JSON.parse(readFileSync(settingsPath, "utf8")) as Record<string, unknown>;
    assert.equal(parsed["existing"], "val");
    assert.equal((parsed["env"] as Record<string, string>)["ANTHROPIC_AUTH_TOKEN"], "custom-token");
  } finally {
    rmSync(home, { recursive: true, force: true });
  }
});

test("decodeWsFrames rejects non-minimal length encodings with 400 ws_protocol_error", () => {
  // 126 used for 10 bytes payload (should have used 7-bit length)
  const nonMinimal126 = Buffer.concat([
    Buffer.from([0x81, 0x7e, 0x00, 0x0a]),
    Buffer.alloc(10, 0x41),
  ]);
  assert.throws(
    () => decodeWsFrames(nonMinimal126),
    (err: unknown) => (err as { status: number }).status === 400
  );

  // 127 used for 100 bytes payload (should have used 16-bit length)
  const nonMinimal127 = Buffer.concat([
    Buffer.from([0x81, 0x7f, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x64]),
    Buffer.alloc(100, 0x41),
  ]);
  assert.throws(
    () => decodeWsFrames(nonMinimal127),
    (err: unknown) => (err as { status: number }).status === 400
  );
});

test("Responses WebSocket closes binary frames with 1003", { timeout: 8_000 }, async () => {
  const proxyPort = await getFreePort();
  await withServer(
    {
      port: proxyPort,
      host: DEFAULT_PROXY_HOST,
      allowLocalKey: true,
    },
    async () => {
      const key = Buffer.from("1234567890abcdef").toString("base64");
      const closeCode = await new Promise<number>((resolve, reject) => {
        const req = http.request({
          host: DEFAULT_PROXY_HOST,
          port: proxyPort,
          path: "/v1/responses",
          agent: false,
          headers: {
            connection: "Upgrade",
            upgrade: "websocket",
            "sec-websocket-version": "13",
            "sec-websocket-key": key,
            authorization: `Bearer ${LOCAL_CLIPROXY_KEY}`,
          },
        });
        req.on("upgrade", (_res, socket) => {
          socket.on("data", (chunk: Buffer) => {
            const { frames } = decodeWsFrames(chunk);
            for (const f of frames) {
              if (f.opcode === 0x8 && f.payload.length >= 2) {
                socket.destroy();
                resolve(f.payload.readUInt16BE(0));
              }
            }
          });
          // Send binary masked frame
          const binaryPayload = Buffer.from([0x01, 0x02, 0x03]);
          const mask = Buffer.from([0x12, 0x34, 0x56, 0x78]);
          const masked = Buffer.alloc(binaryPayload.length);
          for (let i = 0; i < binaryPayload.length; i += 1) {
            const b0 = binaryPayload[i] ?? 0;
            const m0 = mask[i % 4] ?? 0;
            masked[i] = b0 ^ m0;
          }
          const frame = Buffer.concat([
            Buffer.from([0x82, 0x80 | binaryPayload.length]),
            mask,
            masked,
          ]);
          socket.write(frame);
        });
        req.on("error", reject);
        req.end();
      });
      assert.equal(closeCode, 1003);
    }
  );
});



