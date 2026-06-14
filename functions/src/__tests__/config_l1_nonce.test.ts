import { describe, it, expect, beforeEach, afterEach, vi } from "vitest";

/**
 * Security remediation L1: high-risk single-use nonce replay defense must
 * default ON (fail-closed) in production, matching App Check's posture, so
 * replay protection for high-risk callables is no longer contingent on an
 * operator flipping a flag. An explicit REQUIRE_HIGH_RISK_NONCE=false escape
 * hatch is preserved for a controlled staged ramp; emulator/demo/test projects
 * default OFF so local flows without nonce minting keep working.
 */
const TOUCHED = [
  "GCLOUD_PROJECT",
  "GOOGLE_CLOUD_PROJECT",
  "ENFORCE_APP_CHECK",
  "REQUIRE_HIGH_RISK_NONCE",
  "FUNCTIONS_EMULATOR",
  "FIRESTORE_EMULATOR_HOST",
  "FIREBASE_CONFIG",
] as const;

describe("L1 high-risk nonce production fail-closed default", () => {
  const saved: Record<string, string | undefined> = {};

  beforeEach(() => {
    vi.resetModules();
    for (const k of TOUCHED) {
      saved[k] = process.env[k];
      delete process.env[k];
    }
  });
  afterEach(() => {
    for (const k of TOUCHED) {
      if (saved[k] === undefined) delete process.env[k];
      else process.env[k] = saved[k];
    }
  });

  it("defaults requireHighRiskNonce ON for a production project (the secure default)", async () => {
    process.env.GCLOUD_PROJECT = "openburnbar-prod";
    const { getConfig } = await import("../config.js");
    expect(getConfig().requireHighRiskNonce).toBe(true);
  });

  it("honours the explicit REQUIRE_HIGH_RISK_NONCE=false escape hatch in production", async () => {
    process.env.GCLOUD_PROJECT = "openburnbar-prod";
    process.env.REQUIRE_HIGH_RISK_NONCE = "false";
    const { getConfig } = await import("../config.js");
    // App Check stays enforced (its prod fail-closed default is untouched).
    expect(getConfig().enforceAppCheck).toBe(true);
    expect(getConfig().requireHighRiskNonce).toBe(false);
  });

  it("defaults requireHighRiskNonce OFF in the emulator (local dev)", async () => {
    process.env.FUNCTIONS_EMULATOR = "true";
    process.env.GCLOUD_PROJECT = "openburnbar-prod";
    const { getConfig } = await import("../config.js");
    expect(getConfig().requireHighRiskNonce).toBe(false);
  });

  it("defaults requireHighRiskNonce OFF for demo/test projects (CI)", async () => {
    process.env.GCLOUD_PROJECT = "demo-project";
    const { getConfig } = await import("../config.js");
    expect(getConfig().requireHighRiskNonce).toBe(false);
  });

  it("allows an operator to force the nonce ON in a non-prod project", async () => {
    process.env.GCLOUD_PROJECT = "demo-project";
    process.env.REQUIRE_HIGH_RISK_NONCE = "true";
    const { getConfig } = await import("../config.js");
    expect(getConfig().requireHighRiskNonce).toBe(true);
  });
});
