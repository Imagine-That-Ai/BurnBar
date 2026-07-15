// @vitest-environment jsdom
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const callable = vi.fn();
const domains = [
  "QUOTA",
  "CLOUDVAULT",
  "CLOUDVAULT_REWRAP",
  "CLOUDVAULT_SEARCH",
  "HERMES",
  "PRICING",
];
vi.mock("firebase/auth", () => ({ onAuthStateChanged: vi.fn() }));
vi.mock("firebase/functions", () => ({ httpsCallable: () => callable }));
vi.mock("../lib/firebaseClient", () => ({
  auth: () => ({ currentUser: { uid: "user" } }),
  functions: () => ({}),
}));

import {
  flushConsoleShadowEvidenceForTests,
  pendingConsoleShadowEvidenceForTests,
  recordConsoleCloudVaultShadowComparison,
  resetConsoleShadowEvidenceForTests,
} from "../lib/domainCoreShadowEvidence";

describe("console domain-core shadow evidence", () => {
  beforeEach(() => {
    vi.stubEnv("NEXT_PUBLIC_OPENBURNBAR_DOMAIN_CORE_BUILD_AUTHORITY", "signed");
    vi.stubEnv("NEXT_PUBLIC_OPENBURNBAR_DOMAIN_CORE_BUILD_PROFILE", "internal");
    vi.stubEnv("NEXT_PUBLIC_OPENBURNBAR_DOMAIN_CORE_DISTRIBUTION", "internal");
    vi.stubEnv("NEXT_PUBLIC_OPENBURNBAR_DOMAIN_CORE_ROLLOUT_CHANNEL", "internal");
    vi.stubEnv("NEXT_PUBLIC_OPENBURNBAR_DOMAIN_CORE_EVIDENCE_ENABLED", "1");
    for (const domain of domains) {
      vi.stubEnv(`NEXT_PUBLIC_OPENBURNBAR_DOMAIN_CORE_${domain}_MODE`, "shadow");
    }
    callable.mockResolvedValue({ data: { accepted: 1, duplicates: 0 } });
  });

  afterEach(() => {
    resetConsoleShadowEvidenceForTests();
    vi.unstubAllEnvs();
    vi.clearAllMocks();
  });

  it("durably queues the exact V2 DTO and removes it only after acknowledgement", async () => {
    recordConsoleCloudVaultShadowComparison({
      domain: "cloudvault",
      slice: "aes",
      consumer: "console",
      operation: "cloudvault_aes_open",
      coreVersion: "0.1.0",
      outcome: "match",
      mismatchCategory: null,
      legacyMicros: 12,
      rustMicros: 8,
    });

    expect(pendingConsoleShadowEvidenceForTests()).toHaveLength(1);
    await flushConsoleShadowEvidenceForTests();
    expect(callable).toHaveBeenCalledWith({
      samples: [expect.objectContaining({ schemaVersion: 2, consumer: "console", slice: "aes" })],
    });
    expect(pendingConsoleShadowEvidenceForTests()).toEqual([]);
  });

  it("queues a sanitized native-unavailable V2 sample with the canonical version sentinel", () => {
    recordConsoleCloudVaultShadowComparison({
      domain: "cloudvault",
      slice: "foundation",
      consumer: "console",
      operation: "base64_encode",
      coreVersion: "0.0.0-native-unavailable",
      outcome: "mismatch",
      mismatchCategory: "native_unavailable",
      legacyMicros: 12,
      rustMicros: 0,
    });

    expect(pendingConsoleShadowEvidenceForTests()).toEqual([
      {
        schemaVersion: 2,
        sampleId: expect.any(String),
        channel: "internal",
        observedAt: expect.any(String),
        domain: "cloudvault",
        slice: "foundation",
        consumer: "console",
        operation: "base64_encode",
        coreVersion: "0.0.0-native-unavailable",
        outcome: "mismatch",
        mismatchCategory: "native_unavailable",
        legacyMicros: 12,
        rustMicros: 0,
      },
    ]);
  });

  it("rejects evidence when any signed mode is malformed", () => {
    vi.stubEnv("NEXT_PUBLIC_OPENBURNBAR_DOMAIN_CORE_HERMES_MODE", "invalid");

    recordConsoleCloudVaultShadowComparison({
      domain: "cloudvault",
      slice: "aes",
      consumer: "console",
      operation: "cloudvault_aes_open",
      coreVersion: "0.1.0",
      outcome: "match",
      mismatchCategory: null,
      legacyMicros: 12,
      rustMicros: 8,
    });

    expect(pendingConsoleShadowEvidenceForTests()).toEqual([]);
  });

  it("drops evidence from a different signed rollout channel", () => {
    recordConsoleCloudVaultShadowComparison({
      domain: "cloudvault",
      slice: "aes",
      consumer: "console",
      operation: "cloudvault_aes_open",
      coreVersion: "0.1.0",
      outcome: "match",
      mismatchCategory: null,
      legacyMicros: 12,
      rustMicros: 8,
    });
    vi.stubEnv("NEXT_PUBLIC_OPENBURNBAR_DOMAIN_CORE_BUILD_PROFILE", "beta");
    vi.stubEnv("NEXT_PUBLIC_OPENBURNBAR_DOMAIN_CORE_DISTRIBUTION", "beta");
    vi.stubEnv("NEXT_PUBLIC_OPENBURNBAR_DOMAIN_CORE_ROLLOUT_CHANNEL", "beta");

    recordConsoleCloudVaultShadowComparison({
      domain: "cloudvault",
      slice: "aes",
      consumer: "console",
      operation: "cloudvault_aes_open",
      coreVersion: "0.1.0",
      outcome: "match",
      mismatchCategory: null,
      legacyMicros: 15,
      rustMicros: 9,
    });

    expect(pendingConsoleShadowEvidenceForTests()).toEqual([
      expect.objectContaining({ channel: "beta", legacyMicros: 15 }),
    ]);
  });
});
