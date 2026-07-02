import assert from "node:assert/strict";
import test from "node:test";
import { isSafeBrowserUrl, runLoginFlow } from "./login.js";

test("isSafeBrowserUrl allows https and loopback http verification URLs", () => {
  assert.equal(isSafeBrowserUrl("https://mcp.burnbar.ai/link?code=123"), true);
  assert.equal(isSafeBrowserUrl("https://example.com/verify"), true);
  assert.equal(isSafeBrowserUrl("http://127.0.0.1:8080/verify"), true);
  assert.equal(isSafeBrowserUrl("http://localhost:3000/verify"), true);
  assert.equal(isSafeBrowserUrl("http://[::1]:3000/verify"), true);
});

test("isSafeBrowserUrl refuses non-browser scheme handlers", () => {
  assert.equal(isSafeBrowserUrl("file:///etc/passwd"), false);
  assert.equal(isSafeBrowserUrl("openburnbar://link-cli"), false);
  assert.equal(isSafeBrowserUrl("evil-scheme://run/rce"), false);
  assert.equal(isSafeBrowserUrl("javascript:alert(1)"), false);
  assert.equal(isSafeBrowserUrl("http://example.com/verify"), false);
  assert.equal(isSafeBrowserUrl("not a url"), false);
  assert.equal(isSafeBrowserUrl(""), false);
});

test("runLoginFlow refuses an untrusted OPENBURNBAR_MCP_ENDPOINT before any network call", async () => {
  const priorEndpoint = process.env.OPENBURNBAR_MCP_ENDPOINT;
  const priorAllow = process.env.OPENBURNBAR_MCP_ALLOW_CUSTOM_ENDPOINT;
  process.env.OPENBURNBAR_MCP_ENDPOINT = "https://evil.example.com/mcp";
  delete process.env.OPENBURNBAR_MCP_ALLOW_CUSTOM_ENDPOINT;
  try {
    await assert.rejects(runLoginFlow(), /mcp\.burnbar\.ai|HTTPS|loopback/);
  } finally {
    if (priorEndpoint === undefined) {
      delete process.env.OPENBURNBAR_MCP_ENDPOINT;
    } else {
      process.env.OPENBURNBAR_MCP_ENDPOINT = priorEndpoint;
    }
    if (priorAllow === undefined) {
      delete process.env.OPENBURNBAR_MCP_ALLOW_CUSTOM_ENDPOINT;
    } else {
      process.env.OPENBURNBAR_MCP_ALLOW_CUSTOM_ENDPOINT = priorAllow;
    }
  }
});
