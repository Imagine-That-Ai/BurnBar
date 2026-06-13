import assert from "node:assert/strict";
import test from "node:test";
import { assertProductionTokenPosture, isProductionRuntime } from "./config.js";

const env = (values: NodeJS.ProcessEnv): NodeJS.ProcessEnv => values;
const BASE_PROD = env({ MCP_RUNTIME_ENVIRONMENT: "production" });

test("isProductionRuntime: explicit, NODE_ENV, and Cloud Run signals", () => {
  assert.equal(isProductionRuntime(env({ MCP_RUNTIME_ENVIRONMENT: "production" })), true);
  assert.equal(isProductionRuntime(env({ MCP_RUNTIME_ENVIRONMENT: "development" })), false);
  assert.equal(isProductionRuntime(env({ NODE_ENV: "production" })), true);
  assert.equal(isProductionRuntime(env({ K_SERVICE: "openburnbar-hosted-mcp" })), true);
  assert.equal(isProductionRuntime(env({ NODE_ENV: "test" })), false);
  assert.equal(isProductionRuntime(env({})), false);
});

test("assertProductionTokenPosture: no-op outside production", () => {
  // Missing Ed25519 key is fine in dev/test — should not throw.
  assert.doesNotThrow(() => assertProductionTokenPosture(env({ NODE_ENV: "test" })));
  assert.doesNotThrow(() => assertProductionTokenPosture(env({})));
});

test("assertProductionTokenPosture: prod without Ed25519 public key refuses to boot", () => {
  assert.throws(
    () => assertProductionTokenPosture({ ...BASE_PROD }),
    /MCP_TOKEN_ED25519_PUBLIC_KEY_BASE64 must be set/,
  );
});

test("assertProductionTokenPosture: prod with legacy HMAC explicitly enabled refuses to boot", () => {
  assert.throws(
    () => assertProductionTokenPosture({
      ...BASE_PROD,
      MCP_TOKEN_ED25519_PUBLIC_KEY_BASE64: "pk",
      MCP_ALLOW_LEGACY_HMAC_TOKENS: "true",
    }),
    /MCP_ALLOW_LEGACY_HMAC_TOKENS must not be 'true' in production/,
  );
});

test("assertProductionTokenPosture: prod with dev-secret HMAC refuses to boot", () => {
  assert.throws(
    () => assertProductionTokenPosture({
      ...BASE_PROD,
      MCP_TOKEN_ED25519_PUBLIC_KEY_BASE64: "pk",
      MCP_TOKEN_HMAC_SECRET: "dev-secret",
    }),
    /insecure development default/,
  );
});

test("assertProductionTokenPosture: prod with Ed25519 key and no legacy HMAC boots", () => {
  assert.doesNotThrow(() => assertProductionTokenPosture({
    ...BASE_PROD,
    MCP_TOKEN_ED25519_PUBLIC_KEY_BASE64: "pk",
  }));
});
