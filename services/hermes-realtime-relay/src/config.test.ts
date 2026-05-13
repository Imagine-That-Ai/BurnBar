import assert from "node:assert/strict";
import test from "node:test";
import { loadRelayConfig } from "./config.js";
import { redisOptionsForConfig } from "./redisClient.js";

const pem = [
  "-----BEGIN CERTIFICATE-----",
  "MIIDTEST",
  "-----END CERTIFICATE-----",
].join("\n");

test("defaults Redis to local plaintext development", () => {
  const config = loadRelayConfig({});

  assert.equal(config.redisURL, "redis://127.0.0.1:6379");
  assert.equal(config.redisTLSCA, undefined);
  assert.equal(config.redisTLSServername, undefined);
  assert.equal(redisOptionsForConfig(config).tls, undefined);
});

test("configures TLS for rediss Redis URLs with a PEM CA", () => {
  const config = loadRelayConfig({
    REDIS_URL: "rediss://:secret@10.1.2.3:6378",
    REDIS_TLS_CA_PEM: pem.replace(/\n/g, "\\n"),
    REDIS_TLS_SERVERNAME: "redis.internal",
  });
  const options = redisOptionsForConfig(config);

  assert.equal(config.redisTLSCA, pem);
  assert.deepEqual(options.tls, {
    minVersion: "TLSv1.2",
    ca: pem,
    servername: "redis.internal",
  });
});

test("accepts base64 encoded Redis CA material for secret managers", () => {
  const config = loadRelayConfig({
    REDIS_URL: "rediss://10.1.2.3:6378",
    REDIS_TLS_CA_BASE64: Buffer.from(pem).toString("base64"),
  });
  const options = redisOptionsForConfig(config);

  assert.equal(config.redisTLSCA, pem);
  assert.equal(options.tls && "ca" in options.tls ? options.tls.ca : undefined, pem);
});
