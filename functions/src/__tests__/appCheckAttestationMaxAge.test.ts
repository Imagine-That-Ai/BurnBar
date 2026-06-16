import { describe, expect, it } from "vitest";

import {
  APP_CHECK_ATTESTATION_MAX_AGE_MS,
  isAppCheckAttestationClaimFresh,
  resolveAppCheckAttestationMaxAgeMs,
} from "../appCheckAttestation.js";

const SEVEN_DAYS_MS = 7 * 24 * 60 * 60 * 1000;
const THIRTY_DAYS_MS = 30 * 24 * 60 * 60 * 1000;

describe("V-16 App Check attestation max-age", () => {
  it("defaults to 7 days (tightened from the former 30)", () => {
    expect(resolveAppCheckAttestationMaxAgeMs(undefined)).toBe(SEVEN_DAYS_MS);
    expect(resolveAppCheckAttestationMaxAgeMs("")).toBe(SEVEN_DAYS_MS);
    expect(resolveAppCheckAttestationMaxAgeMs("   ")).toBe(SEVEN_DAYS_MS);
    // The module-level constant reflects the default in a clean test env.
    expect(APP_CHECK_ATTESTATION_MAX_AGE_MS).toBeLessThanOrEqual(THIRTY_DAYS_MS);
  });

  it("honors a valid positive operator override", () => {
    expect(resolveAppCheckAttestationMaxAgeMs(String(THIRTY_DAYS_MS))).toBe(THIRTY_DAYS_MS);
    expect(resolveAppCheckAttestationMaxAgeMs("3600000")).toBe(3_600_000);
  });

  it("falls back to the secure default for non-finite / non-positive / junk values (freshness can never be disabled)", () => {
    for (const bad of ["0", "-1", "-99999", "NaN", "abc", "Infinity", "1e999"]) {
      expect(resolveAppCheckAttestationMaxAgeMs(bad), `value=${bad}`).toBe(SEVEN_DAYS_MS);
    }
  });

  it("rejects an attestation older than the window and accepts a fresh one", () => {
    const now = 1_900_000_000_000;
    const fresh = { v: 1 as const, appId: "app-1", boundAtMillis: now - 60_000 };
    const stale = { v: 1 as const, appId: "app-1", boundAtMillis: now - APP_CHECK_ATTESTATION_MAX_AGE_MS - 1 };
    expect(isAppCheckAttestationClaimFresh(fresh, now)).toBe(true);
    expect(isAppCheckAttestationClaimFresh(stale, now)).toBe(false);
  });
});
