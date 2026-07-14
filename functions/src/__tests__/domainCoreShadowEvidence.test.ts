import type { Firestore } from "firebase-admin/firestore";
import { describe, expect, it, vi } from "vitest";

import {
  DOMAIN_CORE_SHADOW_RETENTION_MS,
  buildDomainCoreShadowSampleV2,
  enforceDomainCoreShadowChannelClaim,
  parseDomainCoreShadowSampleRequest,
  persistDomainCoreShadowSamples,
  storedDomainCoreShadowSample,
  storedDomainCoreShadowSampleMatches,
  type DomainCoreShadowSample,
  type DomainCoreShadowSampleV1,
  type DomainCoreShadowSampleV2,
} from "../domainCoreShadowEvidence.js";

const NOW = Date.parse("2026-07-13T12:00:00.000Z");

function sample(overrides: Partial<DomainCoreShadowSampleV2> = {}): DomainCoreShadowSampleV2 {
  return {
    schemaVersion: 2,
    sampleId: "00000000-0000-4000-8000-000000000001",
    domain: "quota",
    slice: "claude",
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
      "slice",
    ]);
  });

  it("keeps V1 quota samples readable without converting them into V2 coverage", () => {
    const { slice: _slice, ...legacyBase } = sample();
    const legacy: DomainCoreShadowSampleV1 = {
      ...legacyBase,
      schemaVersion: 1,
      domain: "quota",
      consumer: "apple",
      operation: "claude_quota",
    };
    const parsed = parseDomainCoreShadowSampleRequest({ samples: [legacy] }, NOW);

    expect(parsed).toEqual([legacy]);
    expect("slice" in (parsed[0] as DomainCoreShadowSample)).toBe(false);
  });

  it.each([
    ["quota", "claude", "apple", "claude_quota"],
    ["cloudvault", "foundation", "console", "cloudvault_aad_v2"],
    ["hermes", "ratchet", "android", "ratchet_kdf"],
    ["pricing", "token-cost", "functions", "calculate_token_cost"],
  ] as const)("builds a validated generic V2 %s collector sample", (domain, slice, consumer, operation) => {
    const built = buildDomainCoreShadowSampleV2(
      {
        domain,
        slice,
        consumer,
        channel: "internal",
        operation,
        coreVersion: "0.3.0",
        outcome: "match",
        mismatchCategory: null,
        legacyMicros: 10,
        rustMicros: 8,
      },
      { nowMillis: NOW, sampleId: "00000000-0000-4000-8000-000000000099" },
    );
    expect(built).toMatchObject({ schemaVersion: 2, domain, slice, consumer, operation });
  });

  it.each([
    ["extra request field", { samples: [sample()], uid: "must-not-be-accepted" }],
    ["extra sample field", { samples: [{ ...sample(), payload: "secret" }] }],
    ["production channel", { samples: [sample({ channel: "production" as "internal" })] }],
    ["inconsistent category", { samples: [sample({ mismatchCategory: "result_mismatch" })] }],
    ["unsafe timing", { samples: [sample({ rustMicros: Number.MAX_SAFE_INTEGER + 1 })] }],
    ["non-UTC timestamp", { samples: [sample({ observedAt: "2026-07-13T11:59:59+00:00" })] }],
    ["stale sample", { samples: [sample({ observedAt: "2026-05-01T00:00:00.000Z" })] }],
    ["invented domain", { samples: [sample({ domain: "logs" as "quota" })] }],
    ["invalid slice consumer", { samples: [sample({ domain: "pricing", slice: "legacy-kimi", consumer: "apple" })] }],
    ["quota slice mismatch", { samples: [sample({ slice: "codex" })] }],
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
    const firestore = {
      doc: (path: string) => {
        const ref = { path };
        refs.set(path, ref);
        return ref;
      },
      runTransaction: async (body: (transaction: unknown) => Promise<unknown>) =>
        body({
          get: async (ref: { path: string }) => ({
            exists: ref.path.endsWith("0002"),
            data: () => storedDomainCoreShadowSample(sample({ sampleId: "00000000-0000-4000-8000-000000000002" }), NOW),
          }),
          create,
        }),
    } as unknown as Firestore;
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
    const firestore = {
      doc: (path: string) => ({ path }),
      runTransaction: async (body: (transaction: unknown) => Promise<unknown>) =>
        body({
          get: async () => ({ exists: true, data: () => storedDomainCoreShadowSample(existing, NOW) }),
          create: vi.fn(),
        }),
    } as unknown as Firestore;

    await expect(persistDomainCoreShadowSamples(firestore, [sample()], NOW)).rejects.toThrow(
      "conflicts with immutable stored evidence",
    );
  });
});
