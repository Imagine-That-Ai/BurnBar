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
  "LINUX_APP_CHECK_APP_ID",
] as const;
const VALID_LINUX_APP_CHECK_APP_ID = "1:246956661961:web:ab19bc3a6f6d4580480118";

describe("L-3 App Check production fail-closed", () => {
  const saved: Record<string, string | undefined> = {};

  beforeEach(() => {
    vi.resetModules();
    for (const k of TOUCHED) {
      saved[k] = process.env[k];
      delete process.env[k];
    }
    process.env.LINUX_APP_CHECK_APP_ID = VALID_LINUX_APP_CHECK_APP_ID;
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

  it("REFUSES to start production when the Linux App Check app id is absent", async () => {
    process.env.GCLOUD_PROJECT = "openburnbar-prod";
    delete process.env.LINUX_APP_CHECK_APP_ID;
    const { getConfig } = await import("../config.js");
    expect(() => getConfig()).toThrow(/Linux App Check app id is missing or malformed/);
  });

  it("REFUSES to start production when the Linux App Check app id is not a real Web app id", async () => {
    process.env.GCLOUD_PROJECT = "openburnbar-prod";
    process.env.LINUX_APP_CHECK_APP_ID = "1:000000000000:linux:placeholder";
    const { getConfig } = await import("../config.js");
    expect(() => getConfig()).toThrow(/Linux App Check app id is missing or malformed/);
  });
});

/**
 * F-RR04-002 requireHighRiskNonce production default (B-SEC-4 / M-002):
 * verifies that requireHighRiskNonce defaults to `looksProd` so a production
 * deployment with no env var or Firebase config flag set is fail-closed (nonce
 * required), while emulator and demo projects default to false (local dev
 * stays unblocked). An explicit REQUIRE_HIGH_RISK_NONCE=false in production
 * must still be accepted (operator opts out explicitly), but an unset env var
 * in production must resolve to true.
 *
 * Also covers the toBool empty-string bypass loophole (discovered during audit):
 * REQUIRE_HIGH_RISK_NONCE="" previously resolved to false (String("").toLowerCase()
 * === "true" is false) which would silently disable nonce defense in production.
 * The fix treats empty/whitespace strings as absent → secure default applies.
 */
const NONCE_TOUCHED = [
  "GCLOUD_PROJECT",
  "GOOGLE_CLOUD_PROJECT",
  "ENFORCE_APP_CHECK",
  "REQUIRE_HIGH_RISK_NONCE",
  "FUNCTIONS_EMULATOR",
  "FIRESTORE_EMULATOR_HOST",
  "FIREBASE_CONFIG",
  "LINUX_APP_CHECK_APP_ID",
] as const;

describe("F-RR04-002 requireHighRiskNonce production default", () => {
  const saved: Record<string, string | undefined> = {};

  beforeEach(() => {
    vi.resetModules();
    for (const k of NONCE_TOUCHED) {
      saved[k] = process.env[k];
      delete process.env[k];
    }
    process.env.LINUX_APP_CHECK_APP_ID = VALID_LINUX_APP_CHECK_APP_ID;
  });
  afterEach(() => {
    for (const k of NONCE_TOUCHED) {
      if (saved[k] === undefined) delete process.env[k];
      else process.env[k] = saved[k];
    }
  });

  it("defaults requireHighRiskNonce to TRUE in production when env var is unset", async () => {
    process.env.GCLOUD_PROJECT = "openburnbar-prod";
    // REQUIRE_HIGH_RISK_NONCE intentionally not set — must resolve to looksProd=true
    const { getConfig } = await import("../config.js");
    expect(getConfig().requireHighRiskNonce).toBe(true);
  });

  it("defaults requireHighRiskNonce to FALSE in emulator (local dev stays unblocked)", async () => {
    process.env.FUNCTIONS_EMULATOR = "true";
    process.env.GCLOUD_PROJECT = "openburnbar-prod";
    const { getConfig } = await import("../config.js");
    expect(getConfig().requireHighRiskNonce).toBe(false);
  });

  it("defaults requireHighRiskNonce to FALSE for demo/test projects (CI stays unblocked)", async () => {
    process.env.GCLOUD_PROJECT = "demo-project";
    const { getConfig } = await import("../config.js");
    expect(getConfig().requireHighRiskNonce).toBe(false);
  });

  it("honours explicit REQUIRE_HIGH_RISK_NONCE=true in any project", async () => {
    process.env.GCLOUD_PROJECT = "demo-project";
    process.env.REQUIRE_HIGH_RISK_NONCE = "true";
    const { getConfig } = await import("../config.js");
    expect(getConfig().requireHighRiskNonce).toBe(true);
  });

  it("honours explicit REQUIRE_HIGH_RISK_NONCE=false in production (operator opt-out path)", async () => {
    // Explicit opt-out is allowed (operator accepts the warning). The key
    // invariant is that NOT setting the flag resolves to true in production;
    // setting it to "false" explicitly is a deliberate operator action.
    process.env.GCLOUD_PROJECT = "openburnbar-prod";
    process.env.REQUIRE_HIGH_RISK_NONCE = "false";
    const { getConfig } = await import("../config.js");
    expect(getConfig().requireHighRiskNonce).toBe(false);
  });

  it("defaults requireHighRiskNonce to TRUE for production-looking projects and FALSE for test projects", async () => {
    // Production-looking project, no explicit flag -> fail-closed (true).
    process.env.GCLOUD_PROJECT = "openburnbar-prod";
    delete process.env.REQUIRE_HIGH_RISK_NONCE;
    const { getConfig: getConfigProd } = await import("../config.js");
    expect(getConfigProd().requireHighRiskNonce).toBe(true);

    // Demo/test project, no explicit flag -> permissive (false) for CI/local dev.
    vi.resetModules();
    process.env.GCLOUD_PROJECT = "demo-project";
    delete process.env.REQUIRE_HIGH_RISK_NONCE;
    const { getConfig: getConfigTest } = await import("../config.js");
    expect(getConfigTest().requireHighRiskNonce).toBe(false);
  });

  // ──────────────────────────────────────────────────────────────────────────
  // toBool empty-string bypass tests (loophole discovered in post-implementation audit)
  // Before the fix: String("").toLowerCase() === "true" → false, so an empty
  // GitHub Actions secret silently disabled nonce replay protection in production.
  // After the fix: empty/whitespace string → use the secure default.
  // ──────────────────────────────────────────────────────────────────────────

  it("treats empty REQUIRE_HIGH_RISK_NONCE string as unset (secure default=true in production)", async () => {
    process.env.GCLOUD_PROJECT = "openburnbar-prod";
    process.env.REQUIRE_HIGH_RISK_NONCE = ""; // operator sets secret to empty string
    const { getConfig } = await import("../config.js");
    expect(getConfig().requireHighRiskNonce).toBe(true); // must still be the secure default
  });

  it("treats whitespace-only REQUIRE_HIGH_RISK_NONCE as unset (secure default=true in production)", async () => {
    process.env.GCLOUD_PROJECT = "openburnbar-prod";
    process.env.REQUIRE_HIGH_RISK_NONCE = "   ";
    const { getConfig } = await import("../config.js");
    expect(getConfig().requireHighRiskNonce).toBe(true);
  });
});

/**
 * F-RR04-002 / L-3 co-loophole: toBool empty-string bypass for ENFORCE_APP_CHECK.
 * Before the fix: ENFORCE_APP_CHECK="" → toBool("", true) → false → bypasses the
 * App Check fail-closed throw in production. After the fix: "" is treated as absent
 * → default is true → App Check enforced → the secure state is restored.
 */
describe("L-3 / F-RR04-002 empty-string env var bypass (toBool fix)", () => {
  const KEYS = [
    "GCLOUD_PROJECT",
    "ENFORCE_APP_CHECK",
    "REQUIRE_HIGH_RISK_NONCE",
    "FUNCTIONS_EMULATOR",
    "FIRESTORE_EMULATOR_HOST",
    "FIREBASE_CONFIG",
    "LINUX_APP_CHECK_APP_ID",
  ] as const;
  const saved: Record<string, string | undefined> = {};

  beforeEach(() => {
    vi.resetModules();
    for (const k of KEYS) {
      saved[k] = process.env[k];
      delete process.env[k];
    }
    process.env.LINUX_APP_CHECK_APP_ID = VALID_LINUX_APP_CHECK_APP_ID;
  });
  afterEach(() => {
    for (const k of KEYS) {
      if (saved[k] === undefined) delete process.env[k];
      else process.env[k] = saved[k];
    }
  });

  it("empty ENFORCE_APP_CHECK in production resolves to default=true (App Check ON, no throw)", async () => {
    // Before fix: ENFORCE_APP_CHECK="" → false → did NOT throw (silent bypass of
    // the App Check fail-closed guard). After fix: "" → default true → no throw.
    process.env.GCLOUD_PROJECT = "openburnbar-prod";
    process.env.ENFORCE_APP_CHECK = "";
    const { getConfig } = await import("../config.js");
    expect(() => getConfig()).not.toThrow(); // App Check ON → no throw
    expect(getConfig().enforceAppCheck).toBe(true);
  });

  it("explicit ENFORCE_APP_CHECK=false in production still fails closed (throws)", async () => {
    process.env.GCLOUD_PROJECT = "openburnbar-prod";
    process.env.ENFORCE_APP_CHECK = "false";
    const { getConfig } = await import("../config.js");
    expect(() => getConfig()).toThrow(/App Check enforcement is DISABLED/);
  });

  it("empty ENFORCE_APP_CHECK in emulator does not throw (emulator exempt from App Check)", async () => {
    process.env.FUNCTIONS_EMULATOR = "true";
    process.env.GCLOUD_PROJECT = "openburnbar-prod";
    process.env.ENFORCE_APP_CHECK = "";
    const { getConfig } = await import("../config.js");
    expect(() => getConfig()).not.toThrow();
    expect(getConfig().enforceAppCheck).toBe(true); // default, but emulator so no throw
  });
});
