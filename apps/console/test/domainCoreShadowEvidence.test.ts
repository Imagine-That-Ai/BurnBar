// @vitest-environment jsdom
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { CloudVaultShadowComparison } from "../lib/domainCoreCloudVault";

const callable = vi.fn();
const CANDIDATE_COMMIT = "a".repeat(40);
const SOURCE_SHA256 = "b".repeat(64);
const SAMPLE_PREFIX = "openburnbar.domain-core-shadow.v3.sample.";
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
  runConsoleShadowEvidenceMaintenanceForTests,
  startNewConsoleShadowEvidenceWriterForTests,
} from "../lib/domainCoreShadowEvidence";

function comparison(
  overrides: Partial<CloudVaultShadowComparison> = {},
): CloudVaultShadowComparison {
  return {
    domain: "cloudvault",
    slice: "aes",
    consumer: "console",
    operation: "cloudvault_aes_open_combined",
    loadedCoreVersion: "0.1.0",
    loadedCoreAbiVersion: 3,
    loadedCoreSourceSha256: SOURCE_SHA256,
    outcome: "match",
    mismatchCategory: null,
    legacyMicros: 12,
    rustMicros: 8,
    ...overrides,
  };
}

function storageKeys(prefix = SAMPLE_PREFIX): string[] {
  return Array.from({ length: localStorage.length }, (_, index) =>
    localStorage.key(index),
  ).filter((key): key is string => key?.startsWith(prefix) === true);
}

function sampleKeys(): string[] {
  return storageKeys();
}

function storedSample(key: string): Record<string, unknown> {
  return JSON.parse(localStorage.getItem(key) ?? "null") as Record<
    string,
    unknown
  >;
}

function immutableSampleKey(
  sample: Record<string, unknown>,
  writerID = crypto.randomUUID(),
): string {
  return `${SAMPLE_PREFIX}${sample.channel}.${sample.candidateCommit}.${encodeURIComponent(sample.expectedCoreVersion as string)}.${sample.expectedCoreAbiVersion}.${sample.expectedCoreSourceSha256}.${writerID}.${sample.sampleId}`;
}

function storeImmutableSample(
  sample: Record<string, unknown>,
  writerID = crypto.randomUUID(),
): string {
  const key = immutableSampleKey(sample, writerID);
  localStorage.setItem(key, JSON.stringify(sample));
  return key;
}

function openNewTab(): void {
  startNewConsoleShadowEvidenceWriterForTests();
}

function useCandidate(
  candidateCommit: string,
  channel: "internal" | "beta" = "internal",
): void {
  vi.stubEnv("NEXT_PUBLIC_OPENBURNBAR_DOMAIN_CORE_BUILD_PROFILE", channel);
  vi.stubEnv("NEXT_PUBLIC_OPENBURNBAR_DOMAIN_CORE_DISTRIBUTION", channel);
  vi.stubEnv("NEXT_PUBLIC_OPENBURNBAR_DOMAIN_CORE_ROLLOUT_CHANNEL", channel);
  vi.stubEnv(
    "NEXT_PUBLIC_OPENBURNBAR_DOMAIN_CORE_CANDIDATE_COMMIT",
    candidateCommit,
  );
}

describe("console domain-core immutable shadow evidence", () => {
  beforeEach(() => {
    callable.mockReset();
    vi.stubEnv("NEXT_PUBLIC_OPENBURNBAR_DOMAIN_CORE_BUILD_AUTHORITY", "signed");
    vi.stubEnv("NEXT_PUBLIC_OPENBURNBAR_DOMAIN_CORE_BUILD_PROFILE", "internal");
    vi.stubEnv("NEXT_PUBLIC_OPENBURNBAR_DOMAIN_CORE_DISTRIBUTION", "internal");
    vi.stubEnv(
      "NEXT_PUBLIC_OPENBURNBAR_DOMAIN_CORE_ROLLOUT_CHANNEL",
      "internal",
    );
    vi.stubEnv("NEXT_PUBLIC_OPENBURNBAR_DOMAIN_CORE_EVIDENCE_ENABLED", "1");
    vi.stubEnv(
      "NEXT_PUBLIC_OPENBURNBAR_DOMAIN_CORE_CANDIDATE_COMMIT",
      CANDIDATE_COMMIT,
    );
    vi.stubEnv("NEXT_PUBLIC_OPENBURNBAR_DOMAIN_CORE_EXPECTED_VERSION", "0.1.0");
    vi.stubEnv("NEXT_PUBLIC_OPENBURNBAR_DOMAIN_CORE_EXPECTED_ABI_VERSION", "3");
    vi.stubEnv(
      "NEXT_PUBLIC_OPENBURNBAR_DOMAIN_CORE_EXPECTED_SOURCE_SHA256",
      SOURCE_SHA256,
    );
    for (const domain of domains) {
      vi.stubEnv(
        `NEXT_PUBLIC_OPENBURNBAR_DOMAIN_CORE_${domain}_MODE`,
        "shadow",
      );
    }
    callable.mockResolvedValue({ data: { accepted: 1, duplicates: 0 } });
  });

  afterEach(() => {
    resetConsoleShadowEvidenceForTests();
    localStorage.clear();
    sessionStorage.clear();
    vi.useRealTimers();
    vi.unstubAllEnvs();
    vi.restoreAllMocks();
  });

  it("stores one exact candidate-bound V3 sample per immutable key and deletes it only after acknowledgement", async () => {
    recordConsoleCloudVaultShadowComparison(comparison());

    const [key] = sampleKeys();
    const sample = storedSample(key);
    expect(key).toContain(
      `${SAMPLE_PREFIX}internal.${CANDIDATE_COMMIT}.0.1.0.3.${SOURCE_SHA256}.`,
    );
    expect(sample).toEqual({
      schemaVersion: 3,
      sampleId: expect.any(String),
      channel: "internal",
      observedAt: expect.any(String),
      domain: "cloudvault",
      slice: "aes",
      consumer: "console",
      operation: "cloudvault_aes_open_combined",
      candidateCommit: CANDIDATE_COMMIT,
      expectedCoreVersion: "0.1.0",
      expectedCoreAbiVersion: 3,
      expectedCoreSourceSha256: SOURCE_SHA256,
      loadedCoreVersion: "0.1.0",
      loadedCoreAbiVersion: 3,
      loadedCoreSourceSha256: SOURCE_SHA256,
      outcome: "match",
      mismatchCategory: null,
      legacyMicros: 12,
      rustMicros: 8,
    });

    await flushConsoleShadowEvidenceForTests();

    expect(callable).toHaveBeenCalledWith({
      samples: [expect.objectContaining({ sampleId: sample.sampleId })],
    });
    expect(sampleKeys()).toEqual([]);
  });

  it.each([
    { accepted: -1, duplicates: 2 },
    { accepted: 2, duplicates: -1 },
    { accepted: 0.5, duplicates: 0.5 },
    { accepted: 2, duplicates: 0 },
  ])(
    "preserves immutable keys for invalid acknowledgement $accepted/$duplicates",
    async (acknowledgement) => {
      recordConsoleCloudVaultShadowComparison(comparison());
      const [key] = sampleKeys();
      callable.mockResolvedValue({ data: acknowledgement });

      await expect(
        flushConsoleShadowEvidenceForTests(),
      ).resolves.toBeUndefined();

      expect(localStorage.getItem(key)).not.toBeNull();
      expect(pendingConsoleShadowEvidenceForTests()).toHaveLength(1);
    },
  );

  it("normalizes loaded identity outcomes to the exact V3 server contract", () => {
    recordConsoleCloudVaultShadowComparison(
      comparison({
        loadedCoreVersion: null,
        loadedCoreAbiVersion: null,
        loadedCoreSourceSha256: null,
        outcome: "mismatch",
        mismatchCategory: "native_error",
      }),
    );
    expect(pendingConsoleShadowEvidenceForTests()).toEqual([
      expect.objectContaining({
        loadedCoreVersion: null,
        loadedCoreAbiVersion: null,
        loadedCoreSourceSha256: null,
        outcome: "mismatch",
        mismatchCategory: "native_unavailable",
      }),
    ]);

    resetConsoleShadowEvidenceForTests();
    recordConsoleCloudVaultShadowComparison(
      comparison({
        loadedCoreVersion: "0.1.1",
        loadedCoreAbiVersion: 4,
        loadedCoreSourceSha256: "c".repeat(64),
      }),
    );
    expect(pendingConsoleShadowEvidenceForTests()).toEqual([
      expect.objectContaining({
        outcome: "mismatch",
        mismatchCategory: "loaded_identity_mismatch",
      }),
    ]);

    resetConsoleShadowEvidenceForTests();
    recordConsoleCloudVaultShadowComparison(
      comparison({
        outcome: "mismatch",
        mismatchCategory: "native_unavailable",
      }),
    );
    expect(pendingConsoleShadowEvidenceForTests()).toEqual([
      expect.objectContaining({ mismatchCategory: "native_error" }),
    ]);
  });

  it("rejects partial identities and malformed signed profiles", () => {
    recordConsoleCloudVaultShadowComparison(
      comparison({ loadedCoreAbiVersion: null }),
    );
    expect(sampleKeys()).toEqual([]);

    vi.stubEnv("NEXT_PUBLIC_OPENBURNBAR_DOMAIN_CORE_EXPECTED_ABI_VERSION", "");
    recordConsoleCloudVaultShadowComparison(comparison());
    expect(sampleKeys()).toEqual([]);

    vi.stubEnv("NEXT_PUBLIC_OPENBURNBAR_DOMAIN_CORE_EXPECTED_ABI_VERSION", "3");
    vi.stubEnv("NEXT_PUBLIC_OPENBURNBAR_DOMAIN_CORE_HERMES_MODE", "invalid");
    recordConsoleCloudVaultShadowComparison(comparison());
    expect(sampleKeys()).toEqual([]);
  });

  it("keeps candidates and channels separate without relabeling", () => {
    recordConsoleCloudVaultShadowComparison(comparison());
    useCandidate("c".repeat(40), "beta");
    recordConsoleCloudVaultShadowComparison(
      comparison({ legacyMicros: 15, rustMicros: 9 }),
    );

    expect(sampleKeys()).toHaveLength(2);
    expect(pendingConsoleShadowEvidenceForTests()).toEqual([
      expect.objectContaining({
        channel: "beta",
        candidateCommit: "c".repeat(40),
        legacyMicros: 15,
      }),
    ]);

    useCandidate(CANDIDATE_COMMIT, "internal");
    expect(pendingConsoleShadowEvidenceForTests()).toEqual([
      expect.objectContaining({
        channel: "internal",
        candidateCommit: CANDIDATE_COMMIT,
        legacyMicros: 12,
      }),
    ]);
  });

  it("uses independent immutable keys for same-candidate tabs", () => {
    recordConsoleCloudVaultShadowComparison(comparison());
    const firstKey = sampleKeys()[0];
    openNewTab();
    recordConsoleCloudVaultShadowComparison(
      comparison({ legacyMicros: 15, rustMicros: 9 }),
    );

    const keys = sampleKeys();
    expect(keys).toHaveLength(2);
    expect(keys).toContain(firstKey);
    expect(new Set(keys.map((key) => key.split(".").at(-2))).size).toBe(2);
    expect(pendingConsoleShadowEvidenceForTests()).toEqual(
      expect.arrayContaining([
        expect.objectContaining({ legacyMicros: 12 }),
        expect.objectContaining({ legacyMicros: 15 }),
      ]),
    );
  });

  it("ignores opener-cloned sessionStorage and never collides with its immutable key", () => {
    recordConsoleCloudVaultShadowComparison(comparison());
    const firstKey = sampleKeys()[0];
    sessionStorage.setItem(
      "openburnbar.domain-core-shadow.tab-id.v1",
      firstKey.split(".").at(-2) ?? "",
    );
    openNewTab();
    recordConsoleCloudVaultShadowComparison(
      comparison({ legacyMicros: 15, rustMicros: 9 }),
    );

    expect(sampleKeys()).toHaveLength(2);
    expect(sampleKeys()).toContain(firstKey);
    expect(sampleKeys()[0]).not.toBe(sampleKeys()[1]);
  });

  it("lets a new tab flush an orphaned immutable sample", async () => {
    recordConsoleCloudVaultShadowComparison(comparison());
    const orphanedKey = sampleKeys()[0];
    openNewTab();

    await flushConsoleShadowEvidenceForTests();

    expect(callable).toHaveBeenCalledTimes(1);
    expect(localStorage.getItem(orphanedKey)).toBeNull();
  });

  it("keeps concurrent-like samples isolated and deletes only acknowledged batch keys", async () => {
    recordConsoleCloudVaultShadowComparison(comparison());
    openNewTab();
    recordConsoleCloudVaultShadowComparison(
      comparison({ legacyMicros: 15, rustMicros: 9 }),
    );
    const before = sampleKeys().map((key) => [key, localStorage.getItem(key)]);
    callable.mockImplementation(async ({ samples }) => ({
      data: { accepted: samples.length, duplicates: 0 },
    }));

    await flushConsoleShadowEvidenceForTests();

    expect(before).toHaveLength(2);
    expect(sampleKeys()).toEqual([]);
  });

  it("coalesces equal canonical payloads with the same sample ID and deletes both exact keys", async () => {
    recordConsoleCloudVaultShadowComparison(comparison());
    const firstKey = sampleKeys()[0];
    const sample = storedSample(firstKey);
    const reordered = Object.fromEntries(Object.entries(sample).reverse());
    const duplicateKey = storeImmutableSample(reordered);

    await flushConsoleShadowEvidenceForTests();

    expect(callable).toHaveBeenCalledTimes(1);
    expect(callable).toHaveBeenCalledWith({ samples: [sample] });
    expect(localStorage.getItem(firstKey)).toBeNull();
    expect(localStorage.getItem(duplicateKey)).toBeNull();
  });

  it("discards conflicting payloads with the same sample ID before upload", async () => {
    recordConsoleCloudVaultShadowComparison(comparison());
    const firstKey = sampleKeys()[0];
    const sample = storedSample(firstKey);
    const conflictingKey = storeImmutableSample({
      ...sample,
      legacyMicros: 99,
    });

    await flushConsoleShadowEvidenceForTests();

    expect(callable).not.toHaveBeenCalled();
    expect(localStorage.getItem(firstKey)).toBeNull();
    expect(localStorage.getItem(conflictingKey)).toBeNull();
  });

  it("coalesces burst maintenance and keeps the record path to atomic writes", () => {
    vi.useFakeTimers();
    const malformedKey = `${SAMPLE_PREFIX}malformed.${crypto.randomUUID()}`;
    localStorage.setItem(malformedKey, "{broken");
    const getItem = vi.spyOn(Storage.prototype, "getItem");

    recordConsoleCloudVaultShadowComparison(comparison());
    recordConsoleCloudVaultShadowComparison(
      comparison({ legacyMicros: 13, rustMicros: 9 }),
    );
    recordConsoleCloudVaultShadowComparison(
      comparison({ legacyMicros: 14, rustMicros: 10 }),
    );

    expect(getItem).not.toHaveBeenCalled();
    vi.advanceTimersByTime(0);
    expect(getItem).toHaveBeenCalledTimes(4);
    expect(localStorage.getItem(malformedKey)).toBeNull();
    expect(sampleKeys()).toHaveLength(3);
  });

  it("prunes malformed, expired, and far-future immutable samples across foreign candidates", () => {
    recordConsoleCloudVaultShadowComparison(comparison());
    const template = storedSample(sampleKeys()[0]);
    const malformedKey = `${SAMPLE_PREFIX}malformed.${crypto.randomUUID()}`;
    localStorage.setItem(malformedKey, "{broken");
    const expiredKey = storeImmutableSample({
      ...template,
      sampleId: crypto.randomUUID(),
      candidateCommit: "c".repeat(40),
      observedAt: "2020-01-01T00:00:00.000Z",
    });
    const futureKey = storeImmutableSample({
      ...template,
      sampleId: crypto.randomUUID(),
      candidateCommit: "d".repeat(40),
      observedAt: "9999-01-01T00:00:00.000Z",
    });

    void pendingConsoleShadowEvidenceForTests();

    expect(localStorage.getItem(malformedKey)).toBeNull();
    expect(localStorage.getItem(expiredKey)).toBeNull();
    expect(localStorage.getItem(futureKey)).toBeNull();
    expect(pendingConsoleShadowEvidenceForTests()).toHaveLength(1);
  });

  it("bounds the current candidate to the 800 newest immutable samples", () => {
    recordConsoleCloudVaultShadowComparison(comparison());
    const template = storedSample(sampleKeys()[0]);
    localStorage.clear();
    const writer = crypto.randomUUID();
    const now = Date.now();
    for (let index = 0; index < 805; index += 1) {
      storeImmutableSample(
        {
          ...template,
          sampleId: crypto.randomUUID(),
          observedAt: new Date(now - (805 - index) * 1_000).toISOString(),
        },
        writer,
      );
    }

    expect(pendingConsoleShadowEvidenceForTests()).toHaveLength(800);
    expect(sampleKeys()).toHaveLength(800);
  });

  it("globally bounds multiple candidates and writers to the 3,200 newest valid samples", () => {
    recordConsoleCloudVaultShadowComparison(comparison());
    const template = storedSample(sampleKeys()[0]);
    localStorage.clear();
    const now = Date.now();
    const writers = [crypto.randomUUID(), crypto.randomUUID()];
    for (let candidateIndex = 0; candidateIndex < 5; candidateIndex += 1) {
      const commit = (candidateIndex + 1).toString(16).repeat(40);
      for (let index = 0; index < 641; index += 1) {
        storeImmutableSample(
          {
            ...template,
            sampleId: crypto.randomUUID(),
            candidateCommit: commit,
            observedAt: new Date(
              now - (3_205 - (candidateIndex * 641 + index)) * 1_000,
            ).toISOString(),
          },
          writers[index % writers.length],
        );
      }
    }

    useCandidate("1".repeat(40));
    runConsoleShadowEvidenceMaintenanceForTests();

    expect(sampleKeys()).toHaveLength(3_200);
    expect(new Set(sampleKeys().map((key) => key.split(".").at(-2))).size).toBe(
      2,
    );
    expect(
      new Set(sampleKeys().map((key) => storedSample(key).candidateCommit))
        .size,
    ).toBeGreaterThan(1);
  }, 20_000);

  it("preserves an immutable key across a transient localStorage read failure", () => {
    recordConsoleCloudVaultShadowComparison(comparison());
    const key = sampleKeys()[0];
    const before = localStorage.getItem(key);
    vi.spyOn(Storage.prototype, "getItem").mockImplementationOnce(() => {
      throw new DOMException("temporarily unavailable", "SecurityError");
    });

    expect(pendingConsoleShadowEvidenceForTests()).toHaveLength(1);
    expect(localStorage.getItem(key)).toBe(before);
  });

  it("contains storage write failure without changing existing immutable samples", () => {
    recordConsoleCloudVaultShadowComparison(comparison());
    const before = sampleKeys().map((key) => [key, localStorage.getItem(key)]);
    vi.spyOn(Storage.prototype, "setItem").mockImplementationOnce(() => {
      throw new DOMException("quota exceeded", "QuotaExceededError");
    });

    expect(() =>
      recordConsoleCloudVaultShadowComparison(
        comparison({ legacyMicros: 99, rustMicros: 77 }),
      ),
    ).not.toThrow();
    expect(sampleKeys().map((key) => [key, localStorage.getItem(key)])).toEqual(
      before,
    );
  });

  it("does not let an unsigned tab clear signed immutable samples", async () => {
    recordConsoleCloudVaultShadowComparison(comparison());
    const key = sampleKeys()[0];
    vi.stubEnv(
      "NEXT_PUBLIC_OPENBURNBAR_DOMAIN_CORE_BUILD_AUTHORITY",
      "development",
    );

    await flushConsoleShadowEvidenceForTests();

    expect(localStorage.getItem(key)).not.toBeNull();
    expect(callable).not.toHaveBeenCalled();
  });

  it("leaves legacy V2 and shared V3 drain-only queues byte-for-byte untouched", async () => {
    const legacyV2 = '[{"schemaVersion":2,"sampleId":"legacy-v2"}]';
    const sharedV3 = '[{"schemaVersion":3,"sampleId":"shared-v3"}]';
    localStorage.setItem("openburnbar.domain-core-shadow.v2", legacyV2);
    localStorage.setItem("openburnbar.domain-core-shadow.v3", sharedV3);

    recordConsoleCloudVaultShadowComparison(comparison());
    runConsoleShadowEvidenceMaintenanceForTests();
    await flushConsoleShadowEvidenceForTests();

    expect(localStorage.getItem("openburnbar.domain-core-shadow.v2")).toBe(
      legacyV2,
    );
    expect(localStorage.getItem("openburnbar.domain-core-shadow.v3")).toBe(
      sharedV3,
    );
    expect(sampleKeys()).toHaveLength(0);
  });
});

describe("console pensieve-vectors canonical operation admission", () => {
  beforeEach(() => {
    callable.mockReset();
    vi.stubEnv("NEXT_PUBLIC_OPENBURNBAR_DOMAIN_CORE_BUILD_AUTHORITY", "signed");
    vi.stubEnv("NEXT_PUBLIC_OPENBURNBAR_DOMAIN_CORE_BUILD_PROFILE", "internal");
    vi.stubEnv("NEXT_PUBLIC_OPENBURNBAR_DOMAIN_CORE_DISTRIBUTION", "internal");
    vi.stubEnv(
      "NEXT_PUBLIC_OPENBURNBAR_DOMAIN_CORE_ROLLOUT_CHANNEL",
      "internal",
    );
    vi.stubEnv("NEXT_PUBLIC_OPENBURNBAR_DOMAIN_CORE_EVIDENCE_ENABLED", "1");
    vi.stubEnv(
      "NEXT_PUBLIC_OPENBURNBAR_DOMAIN_CORE_CANDIDATE_COMMIT",
      CANDIDATE_COMMIT,
    );
    vi.stubEnv("NEXT_PUBLIC_OPENBURNBAR_DOMAIN_CORE_EXPECTED_VERSION", "0.1.0");
    vi.stubEnv("NEXT_PUBLIC_OPENBURNBAR_DOMAIN_CORE_EXPECTED_ABI_VERSION", "3");
    vi.stubEnv(
      "NEXT_PUBLIC_OPENBURNBAR_DOMAIN_CORE_EXPECTED_SOURCE_SHA256",
      SOURCE_SHA256,
    );
    for (const domain of domains) {
      vi.stubEnv(
        `NEXT_PUBLIC_OPENBURNBAR_DOMAIN_CORE_${domain}_MODE`,
        "shadow",
      );
    }
    callable.mockResolvedValue({ data: { accepted: 1, duplicates: 0 } });
  });

  afterEach(() => {
    resetConsoleShadowEvidenceForTests();
    localStorage.clear();
    sessionStorage.clear();
    vi.useRealTimers();
    vi.unstubAllEnvs();
    vi.restoreAllMocks();
  });

  const canonicalPensieveOps = [
    "pensieve_l2_normalize",
    "pensieve_vector_cloak",
    "pensieve_deterministic_embed",
    "pensieve_deterministic_embed_and_cloak",
  ] as const;

  // Each canonical pensieve operation, paired with the pensieve-vectors slice,
  // must be admitted into immutable V3 storage. The pre-fix bug: Console's
  // pensieve-vectors admission map omitted pensieve_l2_normalize, so Apple's
  // canonical l2-normalize comparison records were silently dropped here.
  it.each(canonicalPensieveOps)(
    "admits %s into the pensieve-vectors slice and stores a V3 sample",
    (operation) => {
      recordConsoleCloudVaultShadowComparison(
        comparison({
          slice: "pensieve-vectors",
          operation,
        }),
      );

      const keys = sampleKeys();
      expect(keys).toHaveLength(1);
      expect(storedSample(keys[0]!)).toMatchObject({
        domain: "cloudvault",
        slice: "pensieve-vectors",
        consumer: "console",
        operation,
        outcome: "match",
        mismatchCategory: null,
      });
    },
  );

  // Short aliases (the legacy Apple shadow names) must never be admitted to
  // pensieve-vectors. They are not canonical IDs and Console has no compat shim.
  it.each(["cloak", "l2_normalize", "embed", "embed_and_cloak"])(
    "rejects the short alias %s for the pensieve-vectors slice",
    (operation) => {
      recordConsoleCloudVaultShadowComparison(
        comparison({
          slice: "pensieve-vectors",
          operation,
        }),
      );

      expect(sampleKeys()).toEqual([]);
      expect(pendingConsoleShadowEvidenceForTests()).toHaveLength(0);
    },
  );

  // A canonical operation routed to the wrong slice is a misrouted record and
  // must be rejected — the operation<->slice binding is the contract.
  it.each(canonicalPensieveOps)(
    "rejects %s when routed to a mismatched slice",
    (operation) => {
      recordConsoleCloudVaultShadowComparison(
        comparison({
          slice: "aes",
          operation,
        }),
      );

      expect(sampleKeys()).toEqual([]);
      expect(pendingConsoleShadowEvidenceForTests()).toHaveLength(0);
    },
  );
});
