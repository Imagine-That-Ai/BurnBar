/**
 * VAL-P0-AC-011B — config.ts App Check app-id allowlist surface (accept + reject),
 * the placeholder (non-prod) Windows app id, and the mock-attestation prod fence.
 *
 * Also proves the existing Apple gate (`appStore.appAppleId`) is unchanged by the
 * new Windows allowlist.
 */

import { describe, it, expect, beforeEach, afterEach, vi } from "vitest";

const TOUCHED = [
  "GCLOUD_PROJECT",
  "GOOGLE_CLOUD_PROJECT",
  "ENFORCE_APP_CHECK",
  "FUNCTIONS_EMULATOR",
  "FIRESTORE_EMULATOR_HOST",
  "FIREBASE_CONFIG",
  "WINDOWS_APP_CHECK_APP_ID",
  "LINUX_APP_CHECK_APP_ID",
  "APP_CHECK_ALLOWED_APP_IDS",
  "ALLOW_MOCK_APP_CHECK_ATTESTATION",
  "APP_STORE_APPLE_APP_ID",
  "APP_STORE_ENV",
] as const;

describe("VAL-P0-AC-011B config.ts App Check allowlist surface", () => {
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

  it("defaults the desktop app ids to clearly non-prod placeholders and allowlists them", async () => {
    process.env.GCLOUD_PROJECT = "demo-project";
    const { getConfig, PLACEHOLDER_LINUX_APP_CHECK_APP_ID, PLACEHOLDER_WINDOWS_APP_CHECK_APP_ID } = await import(
      "../config.js"
    );
    const cfg = getConfig();
    expect(cfg.windowsAppCheckAppID).toBe(PLACEHOLDER_WINDOWS_APP_CHECK_APP_ID);
    expect(cfg.linuxAppCheckAppID).toBe(PLACEHOLDER_LINUX_APP_CHECK_APP_ID);
    // Placeholder shape: all-zero project number + non-standard `windows` platform
    // segment (real Firebase ids use ios/android/web) ⇒ never a live prod id.
    expect(PLACEHOLDER_WINDOWS_APP_CHECK_APP_ID).toMatch(/^1:0+:windows:/);
    expect(PLACEHOLDER_LINUX_APP_CHECK_APP_ID).toMatch(/^1:0+:linux:/);
    expect(PLACEHOLDER_WINDOWS_APP_CHECK_APP_ID).toContain("placeholder");
    expect(PLACEHOLDER_LINUX_APP_CHECK_APP_ID).toContain("placeholder");
    expect(cfg.allowedAppCheckAppIDs).toContain(PLACEHOLDER_WINDOWS_APP_CHECK_APP_ID);
    expect(cfg.allowedAppCheckAppIDs).toContain(PLACEHOLDER_LINUX_APP_CHECK_APP_ID);
  });

  it("ACCEPTS the allowlisted placeholder app id and REJECTS a non-allowlisted one", async () => {
    process.env.GCLOUD_PROJECT = "demo-project";
    const { getConfig, isAppCheckAppIdAllowed, PLACEHOLDER_LINUX_APP_CHECK_APP_ID, PLACEHOLDER_WINDOWS_APP_CHECK_APP_ID } =
      await import("../config.js");
    const cfg = getConfig();
    expect(isAppCheckAppIdAllowed(PLACEHOLDER_WINDOWS_APP_CHECK_APP_ID, cfg)).toBe(true);
    expect(isAppCheckAppIdAllowed(PLACEHOLDER_LINUX_APP_CHECK_APP_ID, cfg)).toBe(true);
    expect(isAppCheckAppIdAllowed("1:999999999999:web:evilappid", cfg)).toBe(false);
    // Empty / non-string ids are rejected (fail-closed).
    expect(isAppCheckAppIdAllowed("", cfg)).toBe(false);
    expect(isAppCheckAppIdAllowed(undefined, cfg)).toBe(false);
  });

  it("merges operator-configured extra app ids into the allowlist (deduped)", async () => {
    process.env.GCLOUD_PROJECT = "demo-project";
    process.env.APP_CHECK_ALLOWED_APP_IDS = "1:123:windows:realwin, 1:123:windows:realwin"; // dup on purpose
    const { getConfig, isAppCheckAppIdAllowed, PLACEHOLDER_WINDOWS_APP_CHECK_APP_ID } = await import("../config.js");
    const cfg = getConfig();
    expect(isAppCheckAppIdAllowed("1:123:windows:realwin", cfg)).toBe(true);
    // Placeholder still present, and the duplicate collapsed to one entry.
    expect(cfg.allowedAppCheckAppIDs).toContain(PLACEHOLDER_WINDOWS_APP_CHECK_APP_ID);
    expect(cfg.allowedAppCheckAppIDs).toContain("1:000000000000:linux:0000000000000000placeholder");
    expect(cfg.allowedAppCheckAppIDs.filter((id) => id === "1:123:windows:realwin")).toHaveLength(1);
  });

  it("honours operator-overridden desktop app ids and keeps them allowlisted", async () => {
    process.env.GCLOUD_PROJECT = "demo-project";
    process.env.WINDOWS_APP_CHECK_APP_ID = "1:123:windows:overridden";
    process.env.LINUX_APP_CHECK_APP_ID = "1:123:linux:overridden";
    const { getConfig, isAppCheckAppIdAllowed } = await import("../config.js");
    const cfg = getConfig();
    expect(cfg.windowsAppCheckAppID).toBe("1:123:windows:overridden");
    expect(cfg.linuxAppCheckAppID).toBe("1:123:linux:overridden");
    expect(isAppCheckAppIdAllowed("1:123:windows:overridden", cfg)).toBe(true);
    expect(isAppCheckAppIdAllowed("1:123:linux:overridden", cfg)).toBe(true);
  });
});

describe("VAL-P0-AC-011 mock-attestation prod fence (config gate)", () => {
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

  it("allows the mock verifier in demo/test config", async () => {
    process.env.GCLOUD_PROJECT = "demo-project";
    const { getConfig } = await import("../config.js");
    expect(getConfig().allowMockAppCheckAttestation).toBe(true);
  });

  it("allows the mock verifier under the emulator", async () => {
    process.env.FUNCTIONS_EMULATOR = "true";
    process.env.GCLOUD_PROJECT = "openburnbar-prod";
    const { getConfig } = await import("../config.js");
    expect(getConfig().allowMockAppCheckAttestation).toBe(true);
  });

  it("FORCES the mock verifier OFF in production (fail-closed, no env can turn it on)", async () => {
    process.env.GCLOUD_PROJECT = "openburnbar-prod";
    process.env.ALLOW_MOCK_APP_CHECK_ATTESTATION = "true"; // operator attempt to enable in prod
    const { getConfig } = await import("../config.js");
    expect(getConfig().allowMockAppCheckAttestation).toBe(false);
  });

  it("can be explicitly disabled in non-prod config", async () => {
    process.env.GCLOUD_PROJECT = "demo-project";
    process.env.ALLOW_MOCK_APP_CHECK_ATTESTATION = "false";
    const { getConfig } = await import("../config.js");
    expect(getConfig().allowMockAppCheckAttestation).toBe(false);
  });
});

describe("VAL-P0-AC-011B existing Apple gate is unchanged by the Windows allowlist", () => {
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

  it("still resolves appStore.appAppleId from APP_STORE_APPLE_APP_ID independently of the Windows allowlist", async () => {
    process.env.GCLOUD_PROJECT = "demo-project";
    process.env.APP_STORE_APPLE_APP_ID = "1234567890";
    process.env.WINDOWS_APP_CHECK_APP_ID = "1:123:windows:realwin";
    const { getConfig } = await import("../config.js");
    const cfg = getConfig();
    // The Apple gate value is untouched by adding a Windows app id/allowlist.
    expect(cfg.appStore.appAppleId).toBe(1234567890);
  });

  it("leaves appAppleId undefined in Sandbox even with a Windows app id configured (no weakening)", async () => {
    process.env.GCLOUD_PROJECT = "demo-project";
    process.env.APP_STORE_ENV = "Sandbox";
    process.env.WINDOWS_APP_CHECK_APP_ID = "1:123:windows:realwin";
    const { getConfig } = await import("../config.js");
    // appAppleId parsing is unchanged: absent env ⇒ undefined (Sandbox contract).
    expect(getConfig().appStore.appAppleId).toBeUndefined();
  });
});
