import assert from "node:assert/strict";
import test from "node:test";
import { signCursor, verifyCursor } from "./cursors.js";
import { HttpError } from "./errors.js";

const CURSOR_ENV_KEYS = [
  "MCP_CURSOR_HMAC_SECRET",
  "MCP_TOKEN_HMAC_SECRET",
  "MCP_RUNTIME_ENVIRONMENT",
  "NODE_ENV",
  "K_SERVICE",
] as const;

function withEnv(overrides: Record<string, string | undefined>, fn: () => void): void {
  const previous = new Map<string, string | undefined>();
  for (const key of CURSOR_ENV_KEYS) {
    previous.set(key, process.env[key]);
    delete process.env[key];
  }
  for (const [key, value] of Object.entries(overrides)) {
    if (value === undefined) {delete process.env[key];}
    else {process.env[key] = value;}
  }
  try {
    fn();
  } finally {
    for (const key of CURSOR_ENV_KEYS) {
      const value = previous.get(key);
      if (value === undefined) {delete process.env[key];}
      else {process.env[key] = value;}
    }
  }
}

const payload = () => ({
  uid: "u1",
  tool: "burnbar_search_conversations",
  offset: 10,
  exp: Date.now() + 60_000,
});

test("cursors: production without a cursor secret fails closed on sign", () => {
  withEnv({ MCP_RUNTIME_ENVIRONMENT: "production" }, () => {
    assert.throws(() => signCursor(payload()), (err: unknown) => {
      assert.ok(err instanceof HttpError);
      assert.equal(err.status, 503);
      assert.equal(err.code, "cursor_secret_unconfigured");
      return true;
    });
  });
});

test("cursors: production with the dev-cursor-secret default fails closed on verify", () => {
  // Mint a cursor with the dev default, then attempt to verify it under a
  // production runtime that still only has the dev default — must be rejected.
  let cursor = "";
  withEnv({ MCP_RUNTIME_ENVIRONMENT: "development" }, () => {
    cursor = signCursor(payload());
  });
  withEnv({ MCP_RUNTIME_ENVIRONMENT: "production", MCP_CURSOR_HMAC_SECRET: "dev-cursor-secret" }, () => {
    assert.throws(
      () => verifyCursor(cursor, "u1", "burnbar_search_conversations"),
      (err: unknown) => err instanceof HttpError && err.code === "cursor_secret_unconfigured",
    );
  });
});

test("cursors: production with the token dev-secret default fails closed on sign", () => {
  withEnv({ MCP_RUNTIME_ENVIRONMENT: "production", MCP_CURSOR_HMAC_SECRET: "dev-secret" }, () => {
    assert.throws(
      () => signCursor(payload()),
      (err: unknown) => err instanceof HttpError && err.code === "cursor_secret_unconfigured",
    );
  });
});

test("cursors: production with a real secret signs and verifies", () => {
  withEnv({ MCP_RUNTIME_ENVIRONMENT: "production", MCP_CURSOR_HMAC_SECRET: "real-cursor-secret" }, () => {
    const cursor = signCursor(payload());
    assert.equal(verifyCursor(cursor, "u1", "burnbar_search_conversations").offset, 10);
  });
});

test("cursors: development falls back to the dev default so local tooling works", () => {
  withEnv({ MCP_RUNTIME_ENVIRONMENT: "development" }, () => {
    const cursor = signCursor(payload());
    assert.equal(verifyCursor(cursor, "u1", "burnbar_search_conversations").offset, 10);
  });
});
