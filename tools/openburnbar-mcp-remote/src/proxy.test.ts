import assert from "node:assert/strict";
import { spawn, type ChildProcess } from "node:child_process";
import {
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import http from "node:http";
import { connect as netConnect } from "node:net";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";
import {
  createProxyServer,
  DEFAULT_PROXY_HOST,
  DEFAULT_PROXY_PORT,
  isAuthorized,
  LOCAL_CLIPROXY_KEY,
  MAX_PROXY_BODY_BYTES,
  normalizeLoopbackUpstream,
  parseProxyCliOptions,
  sanitizeProcessCommand,
} from "./proxy.js";
import { isAllowedOrigin, isLoopbackHost } from "./proxyAuth.js";
import { decodeWsFrames, encodeWsFrame } from "./proxyWebsocket.js";
import {
  applyWire,
  GATEWAY_SENTINEL_END,
  GATEWAY_SENTINEL_START,
} from "./proxyWire.js";

interface HttpResult {
  status: number;
  headers: http.IncomingHttpHeaders;
  body: string;
}

interface CliResult {
  code: number | null;
  stdout: string;
  stderr: string;
}

const ENTRY = fileURLToPath(new URL("./index.js", import.meta.url));
const PROXY_ENV_KEYS = [
  "OPENBURNBAR_GATEWAY_TOKEN",
  "OPENBURNBAR_PROVIDER_API_KEY",
  "OPENBURNBAR_PROVIDER_BASE_URL",
  "OPENBURNBAR_UPSTREAM",
  "XAI_API_KEY",
];

function cleanProxyEnv(extra: NodeJS.ProcessEnv = {}): NodeJS.ProcessEnv {
  const env = { ...process.env };
  for (const key of PROXY_ENV_KEYS) {
    delete env[key];
  }
  return { ...env, ...extra };
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

function chatRequest(
  port: number,
  body: unknown,
  headers: Record<string, string> = {}
): Promise<HttpResult> {
  const payload = JSON.stringify(body);
  return request(port, {
    method: "POST",
    path: "/v1/chat/completions",
    headers: {
      authorization: `Bearer ${LOCAL_CLIPROXY_KEY}`,
      "content-length": String(Buffer.byteLength(payload)),
      "content-type": "application/json",
      ...headers,
    },
    body: payload,
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

function runCli(args: string[], env: NodeJS.ProcessEnv = cleanProxyEnv()): Promise<CliResult> {
  return new Promise((resolve, reject) => {
    const child = spawn(process.execPath, [ENTRY, ...args], {
      env,
      stdio: ["ignore", "pipe", "pipe"],
    });
    let stdout = "";
    let stderr = "";
    const timeout = setTimeout(() => {
      child.kill("SIGKILL");
      reject(new Error(`CLI timed out: ${args.join(" ")}`));
    }, 8_000);
    child.stdout.setEncoding("utf8");
    child.stderr.setEncoding("utf8");
    child.stdout.on("data", (chunk: string) => {
      stdout += chunk;
    });
    child.stderr.on("data", (chunk: string) => {
      stderr += chunk;
    });
    child.on("error", reject);
    child.on("close", (code) => {
      clearTimeout(timeout);
      resolve({ code, stdout, stderr });
    });
  });
}

function waitForExit(child: ChildProcess): Promise<number | null> {
  if (child.exitCode !== null) {
    return Promise.resolve(child.exitCode);
  }
  return new Promise((resolve, reject) => {
    child.once("error", reject);
    child.once("close", resolve);
  });
}

async function waitForHealth(port: number): Promise<void> {
  const deadline = Date.now() + 5_000;
  while (Date.now() < deadline) {
    try {
      const result = await request(port, { path: "/health" });
      if (result.status === 200) {
        return;
      }
    } catch {
      // The detached child may still be binding.
    }
    await new Promise((resolve) => setTimeout(resolve, 50));
  }
  throw new Error(`Proxy did not start on port ${port}`);
}

test("CLI parsing freezes the loopback-only surface and strict values", () => {
  const defaults = parseProxyCliOptions([], {});
  assert.equal(defaults.command, "start");
  assert.equal(defaults.port, DEFAULT_PROXY_PORT);
  assert.equal(defaults.host, DEFAULT_PROXY_HOST);
  assert.equal(defaults.allowLocalKey, true);

  const custom = parseProxyCliOptions(
    ["--port", "9999", "--host", "localhost", "--allow-local-key", "--token", "secret", "--tray"],
    {}
  );
  assert.equal(custom.port, 9999);
  assert.equal(custom.host, DEFAULT_PROXY_HOST);
  assert.equal(custom.token, "secret");
  assert.equal(custom.tray, true);

  assert.equal(parseProxyCliOptions(["status", "-p", "8320"], {}).command, "status");
  assert.equal(parseProxyCliOptions(["stop", "--port", "8320"], {}).command, "stop");

  assert.throws(() => parseProxyCliOptions(["start"], {}), /unknown proxy argument/u);
  assert.throws(() => parseProxyCliOptions(["--upstream", "http://127.0.0.1:8317"], {}), /unknown/u);
  assert.throws(() => parseProxyCliOptions(["--port", "8320junk"], {}), /invalid port/u);
  assert.throws(() => parseProxyCliOptions(["--port", "0"], {}), /invalid port/u);
  assert.throws(() => parseProxyCliOptions(["--host", "0.0.0.0"], {}), /must be loopback/u);
  assert.throws(() => parseProxyCliOptions(["status", "--token", "secret"], {}), /only accepts --port/u);
});

test("environment selects honest standalone and loopback-forward modes", () => {
  const xai = parseProxyCliOptions([], { XAI_API_KEY: "xai-secret" });
  assert.deepEqual(xai.provider, {
    name: "xai",
    baseUrl: "https://api.x.ai/v1",
    apiKey: "xai-secret",
  });

  const custom = parseProxyCliOptions([], {
    OPENBURNBAR_PROVIDER_BASE_URL: "http://127.0.0.1:9999/v1",
    OPENBURNBAR_PROVIDER_API_KEY: "provider-secret",
  });
  assert.equal(custom.provider?.name, "custom");
  assert.equal(custom.provider?.baseUrl, "http://127.0.0.1:9999/v1");

  const forward = parseProxyCliOptions([], {
    OPENBURNBAR_GATEWAY_TOKEN: "daemon-secret",
    OPENBURNBAR_UPSTREAM: "http://127.0.0.1:8317",
  });
  assert.equal(forward.upstream, "http://127.0.0.1:8317");
  assert.equal(forward.upstreamToken, "daemon-secret");

  assert.throws(
    () => parseProxyCliOptions([], { OPENBURNBAR_PROVIDER_BASE_URL: "https://example.com/v1" }),
    /must be set together/u
  );
  assert.throws(
    () =>
      parseProxyCliOptions([], {
        OPENBURNBAR_PROVIDER_BASE_URL: "http://example.com/v1",
        OPENBURNBAR_PROVIDER_API_KEY: "secret",
      }),
    /must be HTTPS/u
  );
});

test("forward upstream validation prevents credential exfiltration", () => {
  assert.equal(
    normalizeLoopbackUpstream("http://127.0.0.1:8317/"),
    "http://127.0.0.1:8317"
  );
  assert.throws(() => normalizeLoopbackUpstream("https://127.0.0.1:8317"), /origin-only/u);
  assert.throws(() => normalizeLoopbackUpstream("http://example.com:8317"), /origin-only/u);
  assert.throws(() => normalizeLoopbackUpstream("http://127.0.0.1:8317/base"), /origin-only/u);
  assert.throws(
    () => normalizeLoopbackUpstream("http://user:secret@127.0.0.1:8317"),
    /origin-only/u
  );
});

test("authorization is loopback-only and uses explicit bearer tokens", () => {
  assert.equal(isAuthorized(undefined, undefined, "127.0.0.1", { allowLocalKey: true }), false);
  assert.equal(isAuthorized("Basic abc", undefined, "127.0.0.1", { allowLocalKey: true }), false);
  assert.equal(
    isAuthorized(`Bearer ${LOCAL_CLIPROXY_KEY}`, undefined, "127.0.0.1", { allowLocalKey: true }),
    true
  );
  assert.equal(
    isAuthorized(`Bearer ${LOCAL_CLIPROXY_KEY}`, undefined, "192.168.1.5", { allowLocalKey: true }),
    false
  );
  assert.equal(
    isAuthorized(`Bearer ${LOCAL_CLIPROXY_KEY}`, undefined, undefined, { allowLocalKey: true }),
    false
  );
  assert.equal(
    isAuthorized("Bearer custom-secret", undefined, "::1", {
      allowLocalKey: false,
      token: "custom-secret",
    }),
    true
  );
  assert.equal(
    isAuthorized("Bearer wrong-secret", undefined, "127.0.0.1", {
      allowLocalKey: false,
      token: "custom-secret",
    }),
    false
  );
  assert.equal(
    isAuthorized(undefined, LOCAL_CLIPROXY_KEY, "127.0.0.1", { allowLocalKey: true }),
    true
  );
  assert.equal(
    isAuthorized(undefined, LOCAL_CLIPROXY_KEY, "10.0.0.2", { allowLocalKey: true }),
    false
  );
  assert.equal(
    isAuthorized(`Bearer ${LOCAL_CLIPROXY_KEY}`, undefined, "::ffff:127.0.0.1", {
      allowLocalKey: true,
    }),
    true
  );
});

test("health proves service identity without exposing the control token", async () => {
  const port = await getFreePort();
  await withServer(
    {
      port,
      host: DEFAULT_PROXY_HOST,
      allowLocalKey: true,
      instanceToken: "a".repeat(64),
    },
    async () => {
      const result = await request(port, { path: "/health" });
      assert.equal(result.status, 200);
      const json = JSON.parse(result.body) as Record<string, unknown>;
      assert.equal(json["service"], "openburnbar-proxy");
      assert.equal(json["pid"], process.pid);
      assert.equal(json["port"], port);
      assert.equal(json["mode"], "standalone");
      assert.equal(json["instance"], false);
      assert.doesNotMatch(result.body, /a{32}/u);
    }
  );
});

test("models require auth and fail honestly when unconfigured", async () => {
  const port = await getFreePort();
  await withServer(
    { port, host: DEFAULT_PROXY_HOST, allowLocalKey: true },
    async () => {
      const unauthorized = await request(port, { path: "/v1/models" });
      assert.equal(unauthorized.status, 401);

      const unconfigured = await request(port, {
        path: "/v1/models",
        headers: { authorization: `Bearer ${LOCAL_CLIPROXY_KEY}` },
      });
      assert.equal(unconfigured.status, 503);
      assert.match(unconfigured.body, /provider_not_configured/u);
      assert.equal(unconfigured.headers["access-control-allow-origin"], undefined);
    }
  );
});

test("browser preflight is denied without enabling cross-origin access", async () => {
  const port = await getFreePort();
  await withServer(
    { port, host: DEFAULT_PROXY_HOST, allowLocalKey: true },
    async () => {
      const result = await request(port, {
        method: "OPTIONS",
        path: "/v1/chat/completions",
        headers: {
          "access-control-request-headers": "authorization,content-type",
          "access-control-request-method": "POST",
          origin: "https://example.com",
        },
      });
      assert.equal(result.status, 403);
      assert.match(result.body, /cross_origin_forbidden/u);
      assert.equal(result.headers["access-control-allow-origin"], undefined);
      assert.equal(result.headers["access-control-allow-credentials"], undefined);
    }
  );
});

test("unconfigured standalone chat fails honestly instead of fabricating a completion", async () => {
  const port = await getFreePort();
  await withServer(
    { port, host: DEFAULT_PROXY_HOST, allowLocalKey: true },
    async () => {
      const result = await chatRequest(port, {
        model: "grok-4.6",
        messages: [{ role: "user", content: "ping" }],
        stream: false,
      });
      assert.equal(result.status, 503);
      const json = JSON.parse(result.body) as { error: { code: string; message: string } };
      assert.equal(json.error.code, "provider_not_configured");
      assert.match(json.error.message, /XAI_API_KEY/u);
      assert.doesNotMatch(result.body, /pong|proxy response for/iu);
    }
  );
});

test("standalone provider relays models, JSON completions, and SSE with safe headers", async () => {
  const providerPort = await getFreePort();
  const seen: Array<{
    url: string;
    authorization: string | undefined;
    xApiKey: string | string[] | undefined;
    conversationId: string | undefined;
    body: string;
  }> = [];
  const provider = http.createServer((req, res) => {
    const chunks: Buffer[] = [];
    req.on("data", (chunk: Buffer) => chunks.push(chunk));
    req.on("end", () => {
      const body = Buffer.concat(chunks).toString("utf8");
      const conversationId = req.headers["x-grok-conv-id"];
      seen.push({
        url: req.url ?? "",
        authorization: req.headers["authorization"],
        xApiKey: req.headers["x-api-key"],
        conversationId: Array.isArray(conversationId) ? conversationId[0] : conversationId,
        body,
      });
      if ((req.url ?? "").startsWith("/v1/models")) {
        res.writeHead(200, { "Content-Type": "application/json" });
        res.end(JSON.stringify({ object: "list", data: [{ id: "fixture-model" }] }));
        return;
      }
      const parsed = JSON.parse(body) as { stream?: boolean };
      if (parsed.stream) {
        res.writeHead(200, { "Content-Type": "text/event-stream" });
        res.write('data: {"choices":[{"delta":{"content":"fixture"}}]}\n\n');
        res.end("data: [DONE]\n\n");
        return;
      }
      res.writeHead(200, { "Content-Type": "application/json" });
      res.end(
        JSON.stringify({
          id: "chatcmpl-fixture",
          object: "chat.completion",
          choices: [{ message: { role: "assistant", content: "fixture" } }],
        })
      );
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
        const models = await request(proxyPort, {
          path: "/v1/models?beta=true",
          headers: { authorization: `Bearer ${LOCAL_CLIPROXY_KEY}` },
        });
        assert.equal(models.status, 200);
        assert.match(models.body, /fixture-model/u);
        assert.equal(seen[0]?.url, "/v1/models?beta=true");

        const completion = await chatRequest(
          proxyPort,
          {
            model: "fixture-model",
            messages: [{ role: "user", content: "hello" }],
            stream: false,
          },
          { "x-grok-conv-id": "conversation-fixture" }
        );
        assert.equal(completion.status, 200);
        assert.match(completion.body, /chatcmpl-fixture/u);

        const stream = await chatRequest(proxyPort, {
          model: "fixture-model",
          messages: [{ role: "user", content: "hello" }],
          stream: true,
        });
        assert.equal(stream.status, 200);
        assert.match(String(stream.headers["content-type"]), /text\/event-stream/u);
        assert.match(stream.body, /data: \[DONE\]/u);
      }
    );
  } finally {
    await new Promise<void>((resolve) => provider.close(() => resolve()));
  }

  assert.equal(seen.length, 3);
  assert.ok(seen.every((entry) => entry.authorization === "Bearer provider-secret"));
  assert.ok(seen.every((entry) => entry.xApiKey === undefined));
  assert.equal(seen[1]?.conversationId, "conversation-fixture");
});

test("upstream redirects fail closed without exposing a Location header", async () => {
  const providerPort = await getFreePort();
  const provider = http.createServer((_req, res) => {
    res.writeHead(307, { Location: "https://example.com/collect" });
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
        const result = await chatRequest(proxyPort, {
          model: "fixture-model",
          messages: [{ role: "user", content: "hello" }],
        });
        assert.equal(result.status, 502);
        assert.equal(result.headers["location"], undefined);
        assert.match(result.body, /unsafe_upstream_redirect/u);
      }
    );
  } finally {
    await new Promise<void>((resolve) => provider.close(() => resolve()));
  }
});

test("forward mode maps local auth to the configured daemon token and preserves errors", async () => {
  const upstreamPort = await getFreePort();
  const seenAuth: Array<string | undefined> = [];
  const upstream = http.createServer((req, res) => {
    seenAuth.push(req.headers["authorization"]);
    res.writeHead(429, {
      "Content-Type": "application/json",
      "Retry-After": "7",
    });
    res.end(JSON.stringify({ error: { code: "rate_limited" } }));
  });
  await new Promise<void>((resolve) =>
    upstream.listen({ host: DEFAULT_PROXY_HOST, port: upstreamPort }, resolve)
  );

  const proxyPort = await getFreePort();
  try {
    await withServer(
      {
        port: proxyPort,
        host: DEFAULT_PROXY_HOST,
        allowLocalKey: true,
        upstream: `http://${DEFAULT_PROXY_HOST}:${upstreamPort}`,
        upstreamToken: "daemon-secret",
      },
      async () => {
        const result = await chatRequest(proxyPort, {
          model: "grok-4.6",
          messages: [{ role: "user", content: "hello" }],
          stream: false,
        });
        assert.equal(result.status, 429);
        assert.equal(result.headers["retry-after"], "7");
        assert.match(result.body, /rate_limited/u);
      }
    );
  } finally {
    await new Promise<void>((resolve) => upstream.close(() => resolve()));
  }
  assert.deepEqual(seenAuth, ["Bearer daemon-secret"]);
});

test("unavailable upstream returns a recoverable 502 without a fake fallback", async () => {
  const unavailablePort = await getFreePort();
  const proxyPort = await getFreePort();
  await withServer(
    {
      port: proxyPort,
      host: DEFAULT_PROXY_HOST,
      allowLocalKey: true,
      upstream: `http://${DEFAULT_PROXY_HOST}:${unavailablePort}`,
    },
    async () => {
      const models = await request(proxyPort, {
        path: "/v1/models",
        headers: { authorization: `Bearer ${LOCAL_CLIPROXY_KEY}` },
      });
      assert.equal(models.status, 502);
      assert.match(models.body, /bad_gateway/u);
      assert.doesNotMatch(models.body, /grok-composer/u);
    }
  );
});

test("malformed, invalid, unsupported, and oversized chat requests fail clearly", async () => {
  const port = await getFreePort();
  await withServer(
    { port, host: DEFAULT_PROXY_HOST, allowLocalKey: true },
    async () => {
      const malformed = await request(port, {
        method: "POST",
        path: "/v1/chat/completions",
        headers: {
          authorization: `Bearer ${LOCAL_CLIPROXY_KEY}`,
          "content-type": "application/json",
        },
        body: "{",
      });
      assert.equal(malformed.status, 400);
      assert.match(malformed.body, /bad_request/u);

      const missingMessages = await chatRequest(port, {
        model: "grok-4.6",
        messages: [],
      });
      assert.equal(missingMessages.status, 400);
      assert.match(missingMessages.body, /messages array/u);

      const invalidStream = await chatRequest(port, {
        model: "grok-4.6",
        messages: [{ role: "user", content: "hello" }],
        stream: "false",
      });
      assert.equal(invalidStream.status, 400);
      assert.match(invalidStream.body, /stream must be a boolean/u);

      const unsupported = await request(port, {
        method: "POST",
        path: "/v1/chat/completions",
        headers: { authorization: `Bearer ${LOCAL_CLIPROXY_KEY}` },
        body: "{}",
      });
      assert.equal(unsupported.status, 415);

      const oversized = await request(port, {
        method: "POST",
        path: "/v1/chat/completions",
        headers: {
          authorization: `Bearer ${LOCAL_CLIPROXY_KEY}`,
          "content-length": String(MAX_PROXY_BODY_BYTES + 1),
          "content-type": "application/json",
        },
      });
      assert.equal(oversized.status, 413);
      assert.match(oversized.body, /request_too_large/u);
    }
  );
});

test("status identifies foreign listeners and stop refuses to kill them", async () => {
  const port = await getFreePort();
  const foreign = http.createServer((_req, res) => {
    res.writeHead(200, { "Content-Type": "application/json" });
    res.end(JSON.stringify({ status: "ok" }));
  });
  await new Promise<void>((resolve) =>
    foreign.listen({ host: DEFAULT_PROXY_HOST, port }, resolve)
  );
  try {
    const status = await runCli(["proxy", "status", "--port", String(port)]);
    assert.equal(status.code, 1);
    const json = JSON.parse(status.stdout) as Record<string, unknown>;
    assert.equal(json["listening"], false);
    assert.equal(json["occupied"], true);
    assert.equal(json["pid"], process.pid);
    assert.doesNotMatch(status.stdout, /"listening":true/u);

    const stop = await runCli(["proxy", "stop", "--port", String(port)]);
    assert.equal(stop.code, 1);
    assert.match(stop.stderr, /Refusing to stop/u);
    const stillAlive = await request(port);
    assert.equal(stillAlive.status, 200);
  } finally {
    await new Promise<void>((resolve) => foreign.close(() => resolve()));
  }
});

test("EADDRINUSE exits 1 with the holding PID and never falls back to 8317", async () => {
  const port = await getFreePort();
  const blocker = http.createServer();
  await new Promise<void>((resolve) =>
    blocker.listen({ host: DEFAULT_PROXY_HOST, port }, resolve)
  );
  try {
    const result = await runCli(["proxy", "--port", String(port)]);
    assert.equal(result.code, 1);
    assert.match(result.stderr, new RegExp(`Port ${port} is already in use`, "u"));
    assert.match(result.stderr, new RegExp(`PID ${process.pid}`, "u"));
    assert.match(result.stderr, /pass --port/u);
    assert.match(result.stderr, /will not bind 8317/u);
  } finally {
    await new Promise<void>((resolve) => blocker.close(() => resolve()));
  }
});

test("status and stop operate only on the pid-file-owned proxy", async () => {
  const port = await getFreePort();
  const child = spawn(process.execPath, [ENTRY, "proxy", "--port", String(port)], {
    env: cleanProxyEnv(),
    stdio: ["ignore", "ignore", "pipe"],
  });
  let childError = "";
  child.stderr.setEncoding("utf8");
  child.stderr.on("data", (chunk: string) => {
    childError += chunk;
  });
  try {
    await waitForHealth(port);
    const status = await runCli(["proxy", "status", "--port", String(port)]);
    assert.equal(status.code, 0, status.stderr);
    const json = JSON.parse(status.stdout) as Record<string, unknown>;
    assert.equal(json["listening"], true);
    assert.equal(json["pid"], child.pid);
    assert.equal(json["mode"], "standalone");
    assert.equal(json["product"], "openburnbar-gateway");
    assert.equal(json["openaiUrl"], `http://${DEFAULT_PROXY_HOST}:${port}/v1`);
    assert.equal(json["anthropicUrl"], `http://${DEFAULT_PROXY_HOST}:${port}`);
    assert.equal(json["localKey"], LOCAL_CLIPROXY_KEY);
    assert.doesNotMatch(status.stdout, /xai-|sk-/u);
    assert.doesNotMatch(status.stdout, /"[a-f0-9]{64}"/u);

    const stop = await runCli(["proxy", "stop", "--port", String(port)]);
    assert.equal(stop.code, 0, stop.stderr);
    assert.match(stop.stdout, /proxy stopped/u);
    assert.equal(await waitForExit(child), 0, childError);

    const down = await runCli(["proxy", "status", "--port", String(port)]);
    assert.equal(down.code, 1);
    assert.equal((JSON.parse(down.stdout) as { listening: boolean }).listening, false);
  } finally {
    if (child.exitCode === null) {
      child.kill("SIGTERM");
      await waitForExit(child);
    }
  }
});

test("detached and unref spawn leaves the proxy listening after its parent exits", async () => {
  const port = await getFreePort();
  const parentScript = [
    'const { spawn } = require("node:child_process");',
    "const [entry, port] = process.argv.slice(1);",
    "const child = spawn(process.execPath, [entry, \"proxy\", \"--port\", port], {",
    "  detached: true,",
    "  env: process.env,",
    "  stdio: \"ignore\",",
    "});",
    "child.unref();",
  ].join("\n");
  const parent = await new Promise<CliResult>((resolve, reject) => {
    const child = spawn(process.execPath, ["-e", parentScript, ENTRY, String(port)], {
      env: cleanProxyEnv(),
      stdio: ["ignore", "pipe", "pipe"],
    });
    let stdout = "";
    let stderr = "";
    child.stdout.setEncoding("utf8");
    child.stderr.setEncoding("utf8");
    child.stdout.on("data", (chunk: string) => {
      stdout += chunk;
    });
    child.stderr.on("data", (chunk: string) => {
      stderr += chunk;
    });
    child.on("error", reject);
    child.on("close", (code) => resolve({ code, stdout, stderr }));
  });
  assert.equal(parent.code, 0, parent.stderr);

  try {
    await waitForHealth(port);
    const status = await runCli(["proxy", "status", "--port", String(port)]);
    assert.equal(status.code, 0, status.stderr);
    assert.equal((JSON.parse(status.stdout) as { listening: boolean }).listening, true);
  } finally {
    const stop = await runCli(["proxy", "stop", "--port", String(port)]);
    assert.equal(stop.code, 0, stop.stderr);
  }
});

test("proxy CLI help and invalid arguments preserve the frozen contract", async () => {
  const help = await runCli(["proxy", "--help"]);
  assert.equal(help.code, 0, help.stderr);
  assert.match(help.stdout, /openburnbar proxy \[--port <8320>\]/u);
  assert.match(help.stdout, /app install puts OpenBurnBar\.app on disk/u);
  assert.match(help.stdout, /npm i never starts either/u);

  const invalid = await runCli(["proxy", "--unknown"]);
  assert.equal(invalid.code, 2);
  assert.equal(invalid.stdout, "");
  assert.match(invalid.stderr, /unknown proxy argument "--unknown"/u);
});

test("loopback Host and Origin validation rejects DNS rebinding and external sites", async () => {
  assert.equal(isLoopbackHost("127.0.0.1"), true);
  assert.equal(isLoopbackHost("127.0.0.1:8320"), true);
  assert.equal(isLoopbackHost("localhost:8320"), true);
  assert.equal(isLoopbackHost("[::1]:8320"), true);
  assert.equal(isLoopbackHost("attacker.example.com"), false);
  assert.equal(isLoopbackHost("192.168.1.100:8320"), false);
  assert.equal(isLoopbackHost(undefined), false);

  assert.equal(isAllowedOrigin(undefined), true);
  assert.equal(isAllowedOrigin("null"), false);
  assert.equal(isAllowedOrigin("vscode-webview://something"), true);
  assert.equal(isAllowedOrigin("http://127.0.0.1:8320"), true);
  assert.equal(isAllowedOrigin("http://localhost:3000"), true);
  assert.equal(isAllowedOrigin("https://evil.com"), false);
  assert.equal(isAllowedOrigin("http://attacker.example.com"), false);

  const port = await getFreePort();
  await withServer(
    { port, host: DEFAULT_PROXY_HOST, allowLocalKey: true },
    async () => {
      const rebinding = await request(port, {
        path: "/v1/models",
        headers: {
          Host: "evil-rebinding.com",
          authorization: `Bearer ${LOCAL_CLIPROXY_KEY}`,
        },
      });
      assert.equal(rebinding.status, 403);
      assert.match(rebinding.body, /invalid_host_header/u);

      const badOrigin = await request(port, {
        path: "/v1/models",
        headers: {
          Host: `127.0.0.1:${port}`,
          Origin: "https://attacker.com",
          authorization: `Bearer ${LOCAL_CLIPROXY_KEY}`,
        },
      });
      assert.equal(badOrigin.status, 403);
      assert.match(badOrigin.body, /cross_origin_forbidden/u);
    }
  );
});

test("process command sanitization strips control characters and redacts tokens", () => {
  assert.equal(
    sanitizeProcessCommand("node /path/index.js proxy --port 8320 --token secret123"),
    "node /path/index.js proxy --port 8320 --token [REDACTED]"
  );
  assert.equal(
    sanitizeProcessCommand("proxy --bearer-token s3cr3t-value"),
    "proxy --bearer-token [REDACTED]"
  );
  assert.equal(
    sanitizeProcessCommand("proxy --gateway-token s3cr3t-value"),
    "proxy --gateway-token [REDACTED]"
  );
  assert.equal(
    sanitizeProcessCommand("proxy --token\ts3cr3t-value"),
    "proxy --token [REDACTED]"
  );
  assert.equal(
    sanitizeProcessCommand("OPENBURNBAR_GATEWAY_TOKEN=s3cr3t node proxy"),
    "OPENBURNBAR_GATEWAY_TOKEN=[REDACTED] node proxy"
  );
  assert.equal(
    sanitizeProcessCommand("proxy -t my-secret-token"),
    "proxy -t [REDACTED]"
  );

  const withAnsi = sanitizeProcessCommand("\x1b[31mDangerous\x1b[0m Command\x00");
  assert.match(withAnsi, /Dangerous Command/u);
});

test("WebSocket frame decoder handles fragmentation and unmasked frame detection", () => {
  // Unmasked frame (masked: false)
  const unmasked = encodeWsFrame(0x1, Buffer.from("hello"), false);
  const decodedUnmasked = decodeWsFrames(unmasked);
  assert.equal(decodedUnmasked.frames.length, 1);
  assert.equal(decodedUnmasked.frames[0]?.masked, false);

  // Masked frame (masked: true)
  const masked = encodeWsFrame(0x1, Buffer.from("world"), true);
  const decodedMasked = decodeWsFrames(masked);
  assert.equal(decodedMasked.frames.length, 1);
  assert.equal(decodedMasked.frames[0]?.masked, true);
  assert.equal(decodedMasked.frames[0]?.fin, true);
  assert.equal(decodedMasked.frames[0]?.payload.toString("utf8"), "world");
});

test("WebSocket frame decoder enforces RFC 6455 RSV bits, opcodes, and control frame limits", () => {
  // RSV1 bit set (0x40 | 0x80 | 0x01 = 0xc1)
  assert.throws(
    () => decodeWsFrames(Buffer.from([0xc1, 0x00])),
    (err: unknown) => (err as { code?: string }).code === "ws_protocol_error"
  );

  // Reserved opcode 0x3
  assert.throws(
    () => decodeWsFrames(Buffer.from([0x83, 0x00])),
    (err: unknown) => (err as { code?: string }).code === "ws_protocol_error"
  );

  // Control frame (ping 0x89) with payload > 125 bytes
  assert.throws(
    () => decodeWsFrames(Buffer.from([0x89, 126, 0x00, 126])),
    (err: unknown) => (err as { code?: string }).code === "ws_protocol_error"
  );

  // Control frame (close 0x08) with fin = false (0x08)
  assert.throws(
    () => decodeWsFrames(Buffer.from([0x08, 0x00])),
    (err: unknown) => (err as { code?: string }).code === "ws_protocol_error"
  );
});

test("unwire dry run never leaks full configuration file body containing secrets", () => {
  const fakeHome = mkdtempSync(join(tmpdir(), "obb-wire-test-"));
  try {
    const grokConfig = join(fakeHome, ".grok", "config.toml");
    mkdirSync(dirname(grokConfig), { recursive: true });
    writeFileSync(grokConfig, `api_key = "super-secret-key-12345"\n${GATEWAY_SENTINEL_START}\nfoo = "bar"\n${GATEWAY_SENTINEL_END}\n`);

    const result = applyWire("grok", { port: 8320, home: fakeHome, write: false, unwire: true });
    assert.equal(result.body, "");
    assert.equal(result.removed, true);
    assert.equal(result.wrote, false);

    // Apply with write
    const writeResult = applyWire("grok", { port: 8320, home: fakeHome, write: true, unwire: true });
    assert.equal(writeResult.wrote, true);
    assert.equal(readFileSync(grokConfig, "utf8").trim(), 'api_key = "super-secret-key-12345"');
  } finally {
    rmSync(fakeHome, { recursive: true, force: true });
  }
});

test("OPENBURNBAR_UPSTREAM requires OPENBURNBAR_GATEWAY_TOKEN at CLI parse time", () => {
  assert.throws(
    () =>
      parseProxyCliOptions(
        [],
        { OPENBURNBAR_UPSTREAM: "http://127.0.0.1:8317" }
      ),
    /OPENBURNBAR_UPSTREAM requires OPENBURNBAR_GATEWAY_TOKEN/u
  );

  const valid = parseProxyCliOptions(
    [],
    {
      OPENBURNBAR_UPSTREAM: "http://127.0.0.1:8317",
      OPENBURNBAR_GATEWAY_TOKEN: "valid-secret-token",
    }
  );
  assert.equal(valid.upstream, "http://127.0.0.1:8317");
  assert.equal(valid.upstreamToken, "valid-secret-token");
});

test("response ID validation rejects directory traversals and malformed characters", async () => {
  const port = await getFreePort();
  await withServer(
    { port, host: DEFAULT_PROXY_HOST, allowLocalKey: true },
    async () => {
      const traversal = await request(port, {
        path: "/v1/responses/..%2f..%2fetc%2fpasswd",
        headers: {
          Host: `127.0.0.1:${port}`,
          authorization: `Bearer ${LOCAL_CLIPROXY_KEY}`,
        },
      });
      assert.equal(traversal.status, 400);
      assert.match(traversal.body, /bad_request/u);

      const invalidChars = await request(port, {
        path: "/v1/responses/resp$<script>",
        headers: {
          Host: `127.0.0.1:${port}`,
          authorization: `Bearer ${LOCAL_CLIPROXY_KEY}`,
        },
      });
      assert.equal(invalidChars.status, 400);
      assert.match(invalidChars.body, /bad_request/u);
    }
  );
});

test("gateway panel sets protective security headers and escapes HTML content", async () => {
  const port = await getFreePort();
  await withServer(
    { port, host: DEFAULT_PROXY_HOST, allowLocalKey: true },
    async () => {
      const panel = await request(port, {
        path: "/gateway",
        headers: {
          Host: `127.0.0.1:${port}`,
        },
      });
      assert.equal(panel.status, 200);
      assert.equal(panel.headers["x-frame-options"], "DENY");
      const csp = panel.headers["content-security-policy"];
      assert.match(typeof csp === "string" ? csp : "", /frame-ancestors 'none'/u);
    }
  );
});

test("token file reading securely loads token and validates CLI options", () => {
  const tempDir = mkdtempSync(join(tmpdir(), "obb-token-file-"));
  try {
    const tokenFile = join(tempDir, "secret.token");
    writeFileSync(tokenFile, "  file-based-secret-token-32-chars-long  \n", {
      mode: 0o600,
    });
    const parsed = parseProxyCliOptions(["--token-file", tokenFile], {});
    assert.equal(parsed.token, "file-based-secret-token-32-chars-long");

    assert.throws(
      () => parseProxyCliOptions(["--token-file", join(tempDir, "nonexistent.token")], {}),
      /could not read token file/u
    );
  } finally {
    rmSync(tempDir, { recursive: true, force: true });
  }
});

test("WebSocket handshake validates Sec-WebSocket-Version and Sec-WebSocket-Key format", async () => {
  const port = await getFreePort();
  await withServer(
    { port, host: DEFAULT_PROXY_HOST, allowLocalKey: true },
    async () => {
      // Version != 13 returns 426 Upgrade Required
      const badVersion = await new Promise<{ status: number; headers: string }>((resolve, reject) => {
        const sampleKey = Buffer.from("the sample nonce").toString("base64");
        const client = netConnect({ host: DEFAULT_PROXY_HOST, port }, () => {
          client.write(
            `GET /v1/responses HTTP/1.1\r\nHost: 127.0.0.1:${port}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: ${sampleKey}\r\nSec-WebSocket-Version: 8\r\nAuthorization: Bearer ${LOCAL_CLIPROXY_KEY}\r\n\r\n`
          );
        });
        let raw = "";
        client.on("data", (chunk: Buffer) => {
          raw += chunk.toString("utf8");
        });
        client.on("end", () => {
          const statusMatch = /^HTTP\/1\.1\s+(\d+)/u.exec(raw);
          resolve({ status: Number(statusMatch?.[1] ?? 0), headers: raw });
        });
        client.on("error", reject);
      });
      assert.equal(badVersion.status, 426);
      assert.match(badVersion.headers, /Sec-WebSocket-Version:\s*13/iu);

      // Invalid Sec-WebSocket-Key (not 16-byte base64) returns 400
      const badKey = await new Promise<{ status: number }>((resolve, reject) => {
        const client = netConnect({ host: DEFAULT_PROXY_HOST, port }, () => {
          client.write(
            `GET /v1/responses HTTP/1.1\r\nHost: 127.0.0.1:${port}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: not-valid-base64\r\nSec-WebSocket-Version: 13\r\nAuthorization: Bearer ${LOCAL_CLIPROXY_KEY}\r\n\r\n`
          );
        });
        let raw = "";
        client.on("data", (chunk: Buffer) => {
          raw += chunk.toString("utf8");
        });
        client.on("end", () => {
          const statusMatch = /^HTTP\/1\.1\s+(\d+)/u.exec(raw);
          resolve({ status: Number(statusMatch?.[1] ?? 0) });
        });
        client.on("error", reject);
      });
      assert.equal(badKey.status, 400);
    }
  );
});

test("unclosed wire TOML sentinel block throws clear error", () => {
  const fakeHome = mkdtempSync(join(tmpdir(), "obb-wire-err-"));
  try {
    const grokConfig = join(fakeHome, ".grok", "config.toml");
    mkdirSync(dirname(grokConfig), { recursive: true });
    // Write corrupted config with start sentinel but missing end sentinel
    writeFileSync(grokConfig, `api_key = "123"\n${GATEWAY_SENTINEL_START}\nfoo = "bar"\n`);
    assert.throws(
      () => applyWire("grok", { port: 8320, home: fakeHome, write: false, unwire: false }),
      /unclosed OpenBurnBar sentinel block/u
    );
  } finally {
    rmSync(fakeHome, { recursive: true, force: true });
  }
});

test("require-token option is propagated into health and panel payloads", async () => {
  const port = await getFreePort();
  const token = "custom-private-token-12345678901234567890";
  await withServer(
    { port, host: DEFAULT_PROXY_HOST, allowLocalKey: false, requireToken: true, token },
    async () => {
      const healthRes = await request(port, { path: "/health" });
      assert.equal(healthRes.status, 200);
      const healthJson = JSON.parse(healthRes.body) as Record<string, unknown>;
      assert.equal(healthJson["requireToken"], true);

      const panelRes = await request(port, {
        path: "/v1/gateway/panel",
        headers: { authorization: `Bearer ${token}` },
      });
      assert.equal(panelRes.status, 200);
      const panelJson = JSON.parse(panelRes.body) as Record<string, unknown>;
      assert.equal(panelJson["requiresPrivateToken"], true);
      assert.equal(panelJson["localKey"], null);
    }
  );
});


