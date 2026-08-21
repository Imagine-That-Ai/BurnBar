import assert from "node:assert/strict";
import { spawn, type ChildProcess } from "node:child_process";
import { fileURLToPath } from "node:url";
import http from "node:http";
import test from "node:test";
import {
  createProxyServer,
  DEFAULT_PROXY_HOST,
  DEFAULT_PROXY_PORT,
  isAuthorized,
  LOCAL_CLIPROXY_KEY,
  MAX_PROXY_BODY_BYTES,
  normalizeLoopbackUpstream,
  parseProxyCliOptions,
} from "./proxy.js";

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
    ["--port", "9999", "--host", "localhost", "--allow-local-key", "--token", "secret"],
    {}
  );
  assert.equal(custom.port, 9999);
  assert.equal(custom.host, DEFAULT_PROXY_HOST);
  assert.equal(custom.token, "secret");

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
  assert.equal(isAuthorized(undefined, "127.0.0.1", { allowLocalKey: true }), false);
  assert.equal(isAuthorized("Basic abc", "127.0.0.1", { allowLocalKey: true }), false);
  assert.equal(
    isAuthorized(`Bearer ${LOCAL_CLIPROXY_KEY}`, "127.0.0.1", { allowLocalKey: true }),
    true
  );
  assert.equal(
    isAuthorized(`Bearer ${LOCAL_CLIPROXY_KEY}`, "192.168.1.5", { allowLocalKey: true }),
    false
  );
  assert.equal(
    isAuthorized(`Bearer ${LOCAL_CLIPROXY_KEY}`, undefined, { allowLocalKey: true }),
    false
  );
  assert.equal(
    isAuthorized("Bearer custom-secret", "::1", {
      allowLocalKey: false,
      token: "custom-secret",
    }),
    true
  );
  assert.equal(
    isAuthorized("Bearer wrong-secret", "127.0.0.1", {
      allowLocalKey: false,
      token: "custom-secret",
    }),
    false
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

test("models require auth and remain available before provider configuration", async () => {
  const port = await getFreePort();
  await withServer(
    { port, host: DEFAULT_PROXY_HOST, allowLocalKey: true },
    async () => {
      const unauthorized = await request(port, { path: "/v1/models" });
      assert.equal(unauthorized.status, 401);

      const authorized = await request(port, {
        path: "/v1/models",
        headers: { authorization: `Bearer ${LOCAL_CLIPROXY_KEY}` },
      });
      assert.equal(authorized.status, 200);
      const json = JSON.parse(authorized.body) as {
        object: string;
        data: Array<{ id: string }>;
      };
      assert.equal(json.object, "list");
      assert.ok(json.data.some((model) => model.id === "grok-4.6"));
      assert.equal(authorized.headers["access-control-allow-origin"], undefined);
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
      assert.equal(result.status, 401);
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
        conversationId: Array.isArray(conversationId) ? conversationId[0] : conversationId,
        body,
      });
      if (req.url === "/v1/models") {
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
          path: "/v1/models",
          headers: { authorization: `Bearer ${LOCAL_CLIPROXY_KEY}` },
        });
        assert.equal(models.status, 200);
        assert.match(models.body, /fixture-model/u);

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
