import test from "node:test";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";

function wait(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function request(port, path) {
  const response = await fetch(`http://127.0.0.1:${port}${path}`);
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
      const response = await request(port, "/readyz");
      if (response.status === 200) return;
    } catch {
      // Keep polling until the HTTP server binds.
    }
    await wait(100);
  }
  throw new Error("timed out waiting for quota runner readiness");
}

test("quota runner exposes health and readiness probes", async () => {
  const port = 18_000 + Math.floor(Math.random() * 10_000);
  const child = spawn(process.execPath, ["src/server.mjs"], {
    cwd: new URL("..", import.meta.url),
    env: { ...process.env, PORT: String(port) },
    stdio: ["ignore", "pipe", "pipe"],
  });

  try {
    await waitForReady(port, child);

    const health = await request(port, "/healthz");
    assert.equal(health.status, 200);
    assert.deepEqual(JSON.parse(health.text), { ok: true });

    const readiness = await request(port, "/readyz");
    assert.equal(readiness.status, 200);
    assert.deepEqual(JSON.parse(readiness.text), { ok: true });

    const root = await request(port, "/");
    assert.equal(root.status, 404);
  } finally {
    child.kill("SIGTERM");
  }
});
