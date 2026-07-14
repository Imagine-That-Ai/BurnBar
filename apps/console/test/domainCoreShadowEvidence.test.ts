// @vitest-environment jsdom
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const callable = vi.fn();
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
});
