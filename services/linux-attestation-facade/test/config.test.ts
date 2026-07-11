import assert from "node:assert/strict";
import { afterEach, describe, it } from "node:test";
import { ingressConfig } from "../src/config.js";

const environmentKeys = [
  "GOOGLE_CLOUD_PROJECT",
  "KEYLIME_MTLS_CA_FILE",
  "KEYLIME_MTLS_CERT_FILE",
  "KEYLIME_MTLS_KEY_FILE",
  "KEYLIME_REGISTRAR_URL",
  "EVIDENCE_BUCKET",
  "EVIDENCE_MAX_BYTES",
  "UPLOAD_MAX_ATTEMPTS",
  "KEYLIME_TIMEOUT_MILLIS",
  "ENROLLMENT_LEASE_MILLIS",
  "ACTIVATION_LEASE_MILLIS",
] as const;
const originalEnvironment = new Map(environmentKeys.map(key => [key, process.env[key]]));

afterEach(() => {
  for (const key of environmentKeys) {
    const value = originalEnvironment.get(key);
    if (value === undefined) Reflect.deleteProperty(process.env, key);
    else process.env[key] = value;
  }
});

function configureIngress(): void {
  Object.assign(process.env, {
    GOOGLE_CLOUD_PROJECT: "project",
    KEYLIME_MTLS_CA_FILE: "/secrets/ca",
    KEYLIME_MTLS_CERT_FILE: "/secrets/cert",
    KEYLIME_MTLS_KEY_FILE: "/secrets/key",
    KEYLIME_REGISTRAR_URL: "https://keylime.internal",
    EVIDENCE_BUCKET: "evidence",
  });
}

describe("ingressConfig", () => {
  it("defaults the enrollment lease beyond the Keylime timeout", () => {
    configureIngress();
    const config = ingressConfig();
    assert.equal(config.keylimeTimeoutMillis, 45_000);
    assert.equal(config.enrollmentLeaseMillis, 75_000);
    assert.equal(config.activationLeaseMillis, 105_000);
  });

  it("fails startup when activation can be reclaimed during mutation reconciliation", () => {
    configureIngress();
    process.env.ACTIVATION_LEASE_MILLIS = "90000";
    assert.throws(() => ingressConfig(), /must exceed twice KEYLIME_TIMEOUT_MILLIS/);
  });

  it("fails startup when enrollment can be reclaimed before Keylime times out", () => {
    configureIngress();
    process.env.KEYLIME_TIMEOUT_MILLIS = "60000";
    process.env.ENROLLMENT_LEASE_MILLIS = "60000";
    assert.throws(() => ingressConfig(), /must exceed KEYLIME_TIMEOUT_MILLIS/);
  });

  it("refuses evidence bodies above the Cloud Run HTTP/1-safe ceiling", () => {
    configureIngress();
    process.env.EVIDENCE_MAX_BYTES = String(16 * 1024 * 1024 + 1);
    assert.throws(() => ingressConfig(), /EVIDENCE_MAX_BYTES/);
  });
});
