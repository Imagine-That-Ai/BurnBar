import assert from "node:assert/strict";
import test from "node:test";
import { loginUrlsForEndpoint, validateVerificationUriComplete } from "./login.js";

function withCustomEndpointAllowed<T>(value: string | undefined, fn: () => T): T {
  const previous = process.env.OPENBURNBAR_MCP_ALLOW_CUSTOM_ENDPOINT;
  if (value === undefined) {
    delete process.env.OPENBURNBAR_MCP_ALLOW_CUSTOM_ENDPOINT;
  } else {
    process.env.OPENBURNBAR_MCP_ALLOW_CUSTOM_ENDPOINT = value;
  }
  try {
    return fn();
  } finally {
    if (previous === undefined) {
      delete process.env.OPENBURNBAR_MCP_ALLOW_CUSTOM_ENDPOINT;
    } else {
      process.env.OPENBURNBAR_MCP_ALLOW_CUSTOM_ENDPOINT = previous;
    }
  }
}

test("login flow derives URLs from the validated hosted MCP endpoint", () => {
  const urls = loginUrlsForEndpoint("https://mcp.burnbar.ai/mcp");
  assert.equal(urls.mcpEndpoint.href, "https://mcp.burnbar.ai/mcp");
  assert.equal(urls.startUrl, "https://mcp.burnbar.ai/api/cli-link/start");
  assert.equal(urls.pollUrl, "https://mcp.burnbar.ai/api/cli-link/poll");
});

test("login flow rejects unapproved custom MCP endpoints", () => {
  withCustomEndpointAllowed(undefined, () => {
    assert.throws(
      () => loginUrlsForEndpoint("https://attacker.example/mcp"),
      /explicitly allowed custom HTTPS/
    );
  });
});

test("hosted login accepts only BurnBar verification origins", () => {
  const { mcpEndpoint } = loginUrlsForEndpoint("https://mcp.burnbar.ai/mcp");
  assert.equal(
    validateVerificationUriComplete("https://burnbar.ai/link?code=ABCD-EFGH", mcpEndpoint).origin,
    "https://burnbar.ai"
  );
  assert.equal(
    validateVerificationUriComplete("https://openburnbar.com/link?code=ABCD-EFGH", mcpEndpoint).origin,
    "https://openburnbar.com"
  );
  assert.throws(
    () => validateVerificationUriComplete("https://attacker.example/link?code=ABCD-EFGH", mcpEndpoint),
    /expected BurnBar\/custom auth origin/
  );
});

test("custom login requires the custom verification origin", () => {
  withCustomEndpointAllowed("true", () => {
    const { mcpEndpoint } = loginUrlsForEndpoint("https://custom.example/mcp");
    assert.equal(
      validateVerificationUriComplete("https://custom.example/link?code=ABCD-EFGH", mcpEndpoint).origin,
      "https://custom.example"
    );
    assert.throws(
      () => validateVerificationUriComplete("https://burnbar.ai/link?code=ABCD-EFGH", mcpEndpoint),
      /expected BurnBar\/custom auth origin/
    );
  });
});

test("local login allows only matching loopback HTTP verification", () => {
  const { mcpEndpoint } = loginUrlsForEndpoint("http://127.0.0.1:8787/mcp");
  assert.equal(
    validateVerificationUriComplete("http://127.0.0.1:8787/link?code=ABCD-EFGH", mcpEndpoint).origin,
    "http://127.0.0.1:8787"
  );
  assert.throws(
    () => validateVerificationUriComplete("http://example.com/link?code=ABCD-EFGH", mcpEndpoint),
    /HTTPS/
  );
  assert.throws(
    () => validateVerificationUriComplete("http://127.0.0.1:9999/link?code=ABCD-EFGH", mcpEndpoint),
    /expected BurnBar\/custom auth origin/
  );
});
