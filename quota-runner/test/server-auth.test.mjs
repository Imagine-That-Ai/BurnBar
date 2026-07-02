import test from "node:test";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";

const SHARED_SECRET = "test-shared-secret-value";

function wait(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function post(port, headers, body) {
  const response = await fetch(`http://127.0.0.1:${port}/v1/quota/refresh`, {
    method: "POST",
    headers: { "content-type": "application/json", ...headers },
    body: JSON.stringify(body ?? {}),
  });
  const text = await response.text();
  return { status: response.status, text };
}

async function waitForReady(port, child) {
  const deadline = Date.now() + 5_000;
  while (Date.now() < deadline) {
    if (child.exitCode !== null) {
      throw new Error(`quota runner exited early with code ${child.exitCode}`);
    }
    try {
      const response = await fetch(`http://127.0.0.1:${port}/readyz`);
      if (response.status === 200) return;
    } catch {
      // Keep polling until the HTTP server binds.
    }
    await wait(100);
  }
  throw new Error("timed out waiting for quota runner readiness");
}

test("quota runner enforces the shared-secret bearer token", async () => {
  const port = 28_000 + Math.floor(Math.random() * 10_000);
  const child = spawn(process.execPath, ["src/server.mjs"], {
    cwd: new URL("..", import.meta.url),
    env: {
      ...process.env,
      PORT: String(port),
      RUNNER_HOST: "127.0.0.1",
      RUNNER_SHARED_SECRET: SHARED_SECRET,
    },
    stdio: ["ignore", "pipe", "pipe"],
  });

  try {
    await waitForReady(port, child);

    const missing = await post(port, {}, { provider: "nope" });
    assert.equal(missing.status, 401);

    const wrong = await post(
      port,
      { authorization: "Bearer not-the-secret" },
      { provider: "nope" },
    );
    assert.equal(wrong.status, 401);

    const prefixMatch = await post(
      port,
      { authorization: `Bearer ${SHARED_SECRET.slice(0, 4)}` },
      { provider: "nope" },
    );
    assert.equal(prefixMatch.status, 401);

    // A correct token clears auth and reaches provider dispatch, which rejects
    // the unsupported provider with a 400 rather than a 401.
    const authorized = await post(
      port,
      { authorization: `Bearer ${SHARED_SECRET}` },
      { provider: "nope" },
    );
    assert.equal(authorized.status, 400);
  } finally {
    child.kill("SIGTERM");
  }
});
