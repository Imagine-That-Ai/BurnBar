import { describe, expect, it, vi } from "vitest";

import {
  DOMAIN_CORE_SHADOW_RETENTION_MS,
  enforceDomainCoreShadowChannelClaim,
  parseDomainCoreShadowSampleRequest,
  persistDomainCoreShadowSamples,
  storedDomainCoreShadowSample,
  storedDomainCoreShadowSampleMatches,
} from "../domainCoreShadowEvidence.js";

type DomainCoreShadowStore = Parameters<typeof persistDomainCoreShadowSamples>[0];

type DomainCoreShadowSampleV1 = ReturnType<typeof parseDomainCoreShadowSampleRequest>[number];

const NOW = Date.parse("2026-07-13T12:00:00.000Z");

function sample(overrides: Partial<DomainCoreShadowSampleV1> = {}): DomainCoreShadowSampleV1 {
  return {
    schemaVersion: 1,
    sampleId: "00000000-0000-4000-8000-000000000001",
    domain: "quota",
    consumer: "apple",
    channel: "internal",
    operation: "claude_quota",
    coreVersion: "0.3.0",
    observedAt: "2026-07-13T11:59:59.000Z",
    outcome: "match",
    mismatchCategory: null,
    legacyMicros: 120,
    rustMicros: 80,
    ...overrides,
  };
}

describe("domain-core shadow evidence contract", () => {
  it("accepts and canonicalizes the exact privacy-safe schema", () => {
    const parsed = parseDomainCoreShadowSampleRequest({ samples: [sample()] }, NOW);

    expect(parsed).toEqual([sample()]);
    expect(Object.keys(parsed[0] ?? {}).sort()).toEqual([
      "channel",
      "consumer",
      "coreVersion",
      "domain",
      "legacyMicros",
      "mismatchCategory",
      "observedAt",
      "operation",
      "outcome",
      "rustMicros",
      "sampleId",
      "schemaVersion",
    ]);
  });

  it.each([
    ["extra request field", { samples: [sample()], uid: "must-not-be-accepted" }],
    ["extra sample field", { samples: [{ ...sample(), payload: "secret" }] }],
    ["production channel", { samples: [{ ...sample(), channel: "production" }] }],
    ["inconsistent category", { samples: [sample({ mismatchCategory: "result_mismatch" })] }],
    ["unsafe timing", { samples: [sample({ rustMicros: Number.MAX_SAFE_INTEGER + 1 })] }],
    ["non-UTC timestamp", { samples: [sample({ observedAt: "2026-07-13T11:59:59+00:00" })] }],
    ["stale sample", { samples: [sample({ observedAt: "2026-05-01T00:00:00.000Z" })] }],
  ])("rejects %s", (_label, request) => {
    expect(() => parseDomainCoreShadowSampleRequest(request, NOW)).toThrow();
  });

  it("rejects duplicate IDs inside one batch", () => {
    expect(() => parseDomainCoreShadowSampleRequest({ samples: [sample(), sample()] }, NOW)).toThrow(
      "duplicate sampleId",
    );
  });

  it("binds every submitted channel to the server-issued enrollment claim", () => {
    expect(() =>
      enforceDomainCoreShadowChannelClaim(
        { domainCoreShadowChannel: "internal", domainCoreShadowConsumers: ["apple"] },
        [sample()],
      ),
    ).not.toThrow();
    expect(() => enforceDomainCoreShadowChannelClaim({}, [sample()])).toThrow("not enrolled");
    expect(() =>
      enforceDomainCoreShadowChannelClaim({ domainCoreShadowChannel: "beta", domainCoreShadowConsumers: ["apple"] }, [
        sample(),
      ]),
    ).toThrow("not enrolled");
    expect(() =>
      enforceDomainCoreShadowChannelClaim(
        { domainCoreShadowChannel: "internal", domainCoreShadowConsumers: ["windows"] },
        [sample()],
      ),
    ).toThrow("not enrolled");
  });

  it("stores no uid or raw parser material and stamps the declared TTL", () => {
    const stored = storedDomainCoreShadowSample(sample(), NOW);
    const keys = Object.keys(stored);

    expect(keys).not.toContain("uid");
    expect(keys).not.toContain("payload");
    expect(keys).not.toContain("path");
    expect(keys).not.toContain("deviceId");
    expect(stored.receivedAt.toMillis()).toBe(NOW);
    expect(stored.expireAt.toMillis()).toBe(NOW + DOMAIN_CORE_SHADOW_RETENTION_MS);
  });

  it("creates new IDs immutably and treats existing IDs as idempotent duplicates", async () => {
    const create = vi.fn();
    const refs = new Map<string, { path: string }>();
    const firestore: DomainCoreShadowStore = {
      doc: (path: string) => {
        const ref = { path };
        refs.set(path, ref);
        return ref;
      },
      runTransaction: async (body) =>
        body({
          get: async (ref: { path: string }) => ({
            exists: ref.path.endsWith("0002"),
            data: () => storedDomainCoreShadowSample(sample({ sampleId: "00000000-0000-4000-8000-000000000002" }), NOW),
          }),
          create: (ref, data) => {
            create(ref, data);
          },
        }),
    };
    const result = await persistDomainCoreShadowSamples(
      firestore,
      [sample(), sample({ sampleId: "00000000-0000-4000-8000-000000000002" })],
      NOW,
    );

    expect(result).toEqual({ accepted: 1, duplicates: 1 });
    expect(create).toHaveBeenCalledTimes(1);
    expect(create.mock.calls[0]?.[0]).toBe(refs.get("domain_core_shadow_samples/00000000-0000-4000-8000-000000000001"));
  });

  it("rejects an existing UUID whose immutable evidence differs", async () => {
    const existing = sample({ outcome: "mismatch", mismatchCategory: "result_mismatch", rustMicros: 81 });
    expect(storedDomainCoreShadowSampleMatches(storedDomainCoreShadowSample(existing, NOW), sample())).toBe(false);
    const firestore: DomainCoreShadowStore = {
      doc: (path: string) => ({ path }),
      runTransaction: async (body) =>
        body({
          get: async () => ({ exists: true, data: () => storedDomainCoreShadowSample(existing, NOW) }),
          create: () => undefined,
        }),
    };

    await expect(persistDomainCoreShadowSamples(firestore, [sample()], NOW)).rejects.toThrow(
      "conflicts with immutable stored evidence",
    );
  });
});
