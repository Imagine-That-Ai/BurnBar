import assert from "node:assert/strict";
import test from "node:test";
import { assertProductionTokenPosture, isProductionRuntime } from "./config.js";

const BASE_PROD = { MCP_RUNTIME_ENVIRONMENT: "production" } as NodeJS.ProcessEnv;

test("isProductionRuntime: explicit, NODE_ENV, and Cloud Run signals", () => {
  assert.equal(isProductionRuntime({ MCP_RUNTIME_ENVIRONMENT: "production" } as NodeJS.ProcessEnv), true);
  assert.equal(isProductionRuntime({ MCP_RUNTIME_ENVIRONMENT: "development" } as NodeJS.ProcessEnv), false);
  assert.equal(isProductionRuntime({ NODE_ENV: "production" } as NodeJS.ProcessEnv), true);
  assert.equal(isProductionRuntime({ K_SERVICE: "openburnbar-hosted-mcp" } as NodeJS.ProcessEnv), true);
  assert.equal(isProductionRuntime({ NODE_ENV: "test" } as NodeJS.ProcessEnv), false);
  assert.equal(isProductionRuntime({} as NodeJS.ProcessEnv), false);
});

test("assertProductionTokenPosture: no-op outside production", () => {
  // Missing Ed25519 key is fine in dev/test — should not throw.
  assert.doesNotThrow(() => assertProductionTokenPosture({ NODE_ENV: "test" } as NodeJS.ProcessEnv));
  assert.doesNotThrow(() => assertProductionTokenPosture({} as NodeJS.ProcessEnv));
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
    } as NodeJS.ProcessEnv),
    /MCP_ALLOW_LEGACY_HMAC_TOKENS must not be 'true' in production/,
  );
});

test("assertProductionTokenPosture: prod with dev-secret HMAC refuses to boot", () => {
  assert.throws(
    () => assertProductionTokenPosture({
      ...BASE_PROD,
      MCP_TOKEN_ED25519_PUBLIC_KEY_BASE64: "pk",
      MCP_TOKEN_HMAC_SECRET: "dev-secret",
    } as NodeJS.ProcessEnv),
    /insecure development default/,
  );
});

test("assertProductionTokenPosture: prod with Ed25519 key and no legacy HMAC boots", () => {
  assert.doesNotThrow(() => assertProductionTokenPosture({
    ...BASE_PROD,
    MCP_TOKEN_ED25519_PUBLIC_KEY_BASE64: "pk",
  } as NodeJS.ProcessEnv));
});
