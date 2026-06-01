import { describe, expect, it } from "vitest";

import { IROH_PAIRING_FRESHNESS_MS } from "../types/legacy.js";

/** Keep in sync with `IrohPairingFreshness.maximumAgeSeconds` (Swift) and `IrohPairingFreshness.MAXIMUM_AGE_MILLIS` (Kotlin). */
const EXPECTED_MS = 3 * 60 * 1000;

describe("iroh pairing freshness contract", () => {
  it("matches the 3-minute cross-platform policy", () => {
    expect(IROH_PAIRING_FRESHNESS_MS).toBe(EXPECTED_MS);
  });
});