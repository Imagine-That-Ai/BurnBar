import { describe, it, expect, beforeEach, afterEach, vi } from "vitest";

/**
 * Security remediation L-3: App Check enforcement must fail CLOSED in
 * production. getConfig() (backed by buildConfig()) refuses to start a
 * production project that has App Check disabled, while emulator/demo/test
 * projects stay permissive for local dev and CI.
 */
const TOUCHED = [
  "GCLOUD_PROJECT",
  "GOOGLE_CLOUD_PROJECT",
  "ENFORCE_APP_CHECK",
  "FUNCTIONS_EMULATOR",
  "FIRESTORE_EMULATOR_HOST",
  "FIREBASE_CONFIG",
] as const;

describe("L-3 App Check production fail-closed", () => {
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

  it("REFUSES to start a production project with App Check disabled", async () => {
    process.env.GCLOUD_PROJECT = "openburnbar-prod";
    process.env.ENFORCE_APP_CHECK = "false";
    const { getConfig } = await import("../config.js");
    expect(() => getConfig()).toThrow(/App Check enforcement is DISABLED/);
  });

  it("allows the emulator with App Check disabled (local dev)", async () => {
    process.env.FUNCTIONS_EMULATOR = "true";
    process.env.GCLOUD_PROJECT = "openburnbar-prod";
    process.env.ENFORCE_APP_CHECK = "false";
    const { getConfig } = await import("../config.js");
    expect(() => getConfig()).not.toThrow();
    expect(getConfig().enforceAppCheck).toBe(false);
  });

  it("allows demo/test projects with App Check disabled (CI)", async () => {
    process.env.GCLOUD_PROJECT = "demo-project";
    process.env.ENFORCE_APP_CHECK = "false";
    const { getConfig } = await import("../config.js");
    expect(() => getConfig()).not.toThrow();
  });

  it("allows production with App Check enabled (the default)", async () => {
    process.env.GCLOUD_PROJECT = "openburnbar-prod";
    const { getConfig } = await import("../config.js");
    expect(() => getConfig()).not.toThrow();
    expect(getConfig().enforceAppCheck).toBe(true);
  });
});
