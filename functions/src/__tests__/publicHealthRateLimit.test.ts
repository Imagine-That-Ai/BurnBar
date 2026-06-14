/**
 * T-AZ-08: per-IP rate gate for the public, unauthenticated pricing/health probe
 * endpoints. The gate MUST fail OPEN — a failure in the rate-limit store itself
 * (Firestore blip) must never make a liveness/readiness probe report the service
 * as down — and MUST return `false` (→ 429) only on a genuine over-limit outcome.
 *
 * The Firestore handle is mocked so these tests are hermetic (no emulator).
 */

import { HttpsError } from "firebase-functions/v2/https";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const runTransaction = vi.fn();

vi.mock("../adminRuntime.js", () => ({
  db: {
    runTransaction: (...args: unknown[]) => runTransaction(...args),
    doc: () => ({ id: "fake" }),
  },
}));

describe("checkPublicHealthRateLimit (T-AZ-08)", () => {
  beforeEach(() => {
    runTransaction.mockReset();
  });
  afterEach(() => {
    vi.resetModules();
  });

  it("allows the probe when within budget", async () => {
    runTransaction.mockResolvedValue(undefined);
    const { checkPublicHealthRateLimit } = await import("../callables/publicRateLimit.js");
    await expect(checkPublicHealthRateLimit("203.0.113.7")).resolves.toBe(true);
  });

  it("blocks (returns false) when the per-IP window is exhausted", async () => {
    runTransaction.mockRejectedValue(new HttpsError("resource-exhausted", "Too many requests."));
    const { checkPublicHealthRateLimit } = await import("../callables/publicRateLimit.js");
    await expect(checkPublicHealthRateLimit("203.0.113.7")).resolves.toBe(false);
  });

  it("fails OPEN (returns true) when the limiter store errors", async () => {
    runTransaction.mockRejectedValue(new Error("firestore unavailable"));
    const { checkPublicHealthRateLimit } = await import("../callables/publicRateLimit.js");
    await expect(checkPublicHealthRateLimit("203.0.113.7")).resolves.toBe(true);
  });

  it("fails OPEN for a non-rate-limit HttpsError too", async () => {
    runTransaction.mockRejectedValue(new HttpsError("internal", "boom"));
    const { checkPublicHealthRateLimit } = await import("../callables/publicRateLimit.js");
    await expect(checkPublicHealthRateLimit("203.0.113.7")).resolves.toBe(true);
  });
});
