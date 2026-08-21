import { readFileSync } from "node:fs";
import { resolve } from "node:path";

import { describe, expect, it, vi } from "vitest";

import {
  DOMAIN_CORE_SHADOW_OPERATION_SLICES,
  DOMAIN_CORE_SHADOW_RETENTION_MS,
  buildDomainCoreShadowSampleV3,
  domainCoreShadowOperationConsumers,
  enforceDomainCoreShadowChannelClaim,
  parseDomainCoreShadowSampleRequest,
  persistDomainCoreShadowSamples,
  storedDomainCoreShadowSample,
  storedDomainCoreShadowSampleMatches,
} from "../domainCoreShadowEvidence.js";

type DomainCoreShadowStore = Parameters<typeof persistDomainCoreShadowSamples>[0];

type DomainCoreShadowSample = ReturnType<typeof parseDomainCoreShadowSampleRequest>[number];
type DomainCoreShadowSampleV1 = Extract<DomainCoreShadowSample, { schemaVersion: 1 }>;
type DomainCoreShadowSampleV2 = Extract<DomainCoreShadowSample, { schemaVersion: 2 }>;
type DomainCoreShadowSampleV3 = ReturnType<typeof buildDomainCoreShadowSampleV3>;

const NOW = Date.parse("2026-07-13T12:00:00.000Z");
const CANDIDATE_COMMIT = "a".repeat(40);
const CORE_SOURCE_SHA256 = "b".repeat(64);

interface OperationContractBranch {
  properties: {
    domain: { const: string };
    slice: { const: string };
    consumer: { const?: string; enum?: string[] };
    operation: { const?: string; enum?: string[] };
  };
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function operationContractBranch(value: unknown): OperationContractBranch | undefined {
  if (!isRecord(value) || !isRecord(value.properties)) return undefined;
  const { domain, slice, consumer, operation } = value.properties;
  if (!isRecord(domain) || typeof domain.const !== "string" || !isRecord(slice) || typeof slice.const !== "string") {
    return undefined;
  }
  if (!isRecord(consumer) || !isRecord(operation)) return undefined;
  const consumerConst = typeof consumer.const === "string" ? consumer.const : undefined;
  const consumerEnum =
    Array.isArray(consumer.enum) && consumer.enum.every((item) => typeof item === "string")
      ? consumer.enum.filter((item): item is string => typeof item === "string")
      : undefined;
  const operationConst = typeof operation.const === "string" ? operation.const : undefined;
  const operationEnum =
    Array.isArray(operation.enum) && operation.enum.every((item) => typeof item === "string")
      ? operation.enum.filter((item): item is string => typeof item === "string")
      : undefined;
  if ((!consumerConst && !consumerEnum) || (!operationConst && !operationEnum)) return undefined;
  return {
    properties: {
      domain: { const: domain.const },
      slice: { const: slice.const },
      consumer: { const: consumerConst, enum: consumerEnum },
      operation: { const: operationConst, enum: operationEnum },
    },
  };
}

function mismatchRequirementProperties(schema: unknown, category: string): Record<string, unknown> | undefined {
  if (!isRecord(schema) || !Array.isArray(schema.allOf)) return undefined;
  for (const condition of schema.allOf) {
    if (!isRecord(condition) || !isRecord(condition.if) || !isRecord(condition.if.properties)) continue;
    const mismatchCategory = condition.if.properties.mismatchCategory;
    if (!isRecord(mismatchCategory) || !Array.isArray(mismatchCategory.enum)) continue;
    if (
      !mismatchCategory.enum.includes(category) ||
      !isRecord(condition.then) ||
      !isRecord(condition.then.properties)
    ) {
      continue;
    }
    return condition.then.properties;
  }
  return undefined;
}

function v3OperationContractBranches(): OperationContractBranch[] {
  const schema: unknown = JSON.parse(
    readFileSync(resolve(__dirname, "../../../docs/contracts/domain-core-shadow-sample-v3.schema.json"), "utf8"),
  );
  if (!isRecord(schema) || !Array.isArray(schema.allOf)) throw new Error("V3 shadow schema must define allOf.");
  return schema.allOf.flatMap((condition) => {
    if (!isRecord(condition) || !Array.isArray(condition.oneOf)) return [];
    return condition.oneOf.flatMap((value) => {
      const branch = operationContractBranch(value);
      return branch ? [branch] : [];
    });
  });
}

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

function v3Sample(overrides: Partial<DomainCoreShadowSampleV3> = {}): DomainCoreShadowSampleV3 {
  return {
    schemaVersion: 3,
    sampleId: "00000000-0000-4000-8000-000000000003",
    domain: "quota",
    slice: "claude",
    consumer: "apple",
    channel: "internal",
    operation: "claude_quota",
    candidateCommit: CANDIDATE_COMMIT,
    expectedCoreVersion: "0.3.0",
    expectedCoreAbiVersion: 3,
    expectedCoreSourceSha256: CORE_SOURCE_SHA256,
    loadedCoreVersion: "0.3.0",
    loadedCoreAbiVersion: 3,
    loadedCoreSourceSha256: CORE_SOURCE_SHA256,
    observedAt: "2026-07-13T11:59:59.000Z",
    outcome: "match",
    mismatchCategory: null,
    legacyMicros: 120,
    rustMicros: 80,
    ...overrides,
  };
}

function v3Claims(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    domainCoreShadowChannel: "internal",
    domainCoreShadowConsumers: ["apple"],
    domainCoreShadowCandidateCommit: CANDIDATE_COMMIT,
    domainCoreShadowCoreVersion: "0.3.0",
    domainCoreShadowCoreAbiVersion: 3,
    domainCoreShadowCoreSourceSha256: CORE_SOURCE_SHA256,
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

  it("accepts the exact candidate-bound V3 schema without a legacy coreVersion alias", () => {
    const parsed = parseDomainCoreShadowSampleRequest({ samples: [v3Sample()] }, NOW);

    expect(parsed).toEqual([v3Sample()]);
    expect(parsed[0]).not.toHaveProperty("coreVersion");
    expect(Object.keys(parsed[0] ?? {}).sort()).toEqual([
      "candidateCommit",
      "channel",
      "consumer",
      "domain",
      "expectedCoreAbiVersion",
      "expectedCoreSourceSha256",
      "expectedCoreVersion",
      "legacyMicros",
      "loadedCoreAbiVersion",
      "loadedCoreSourceSha256",
      "loadedCoreVersion",
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

  it("builds a strict candidate-bound V3 producer sample", () => {
    const { schemaVersion: _schemaVersion, sampleId: _sampleId, observedAt: _observedAt, ...comparison } = v3Sample();
    const built = buildDomainCoreShadowSampleV3(comparison, {
      nowMillis: NOW,
      sampleId: "00000000-0000-4000-8000-000000000099",
    });

    expect(built).toEqual({
      ...v3Sample(),
      sampleId: "00000000-0000-4000-8000-000000000099",
      observedAt: new Date(NOW).toISOString(),
    });
    expect(built).not.toHaveProperty("coreVersion");
  });

  it("fails the V3 producer closed for partial or falsely classified loaded identity", () => {
    const { schemaVersion: _schemaVersion, sampleId: _sampleId, observedAt: _observedAt, ...comparison } = v3Sample();

    expect(() => buildDomainCoreShadowSampleV3({ ...comparison, loadedCoreAbiVersion: null })).toThrow();
    expect(() =>
      buildDomainCoreShadowSampleV3({
        ...comparison,
        outcome: "mismatch",
        mismatchCategory: "loaded_identity_mismatch",
      }),
    ).toThrow();
  });

  it("accepts every operation/domain/slice/consumer branch in the authoritative V3 schema", () => {
    const branches = v3OperationContractBranches();
    expect(branches.length).toBeGreaterThan(10);
    const schemaContracts = new Set<string>();

    for (const branch of branches) {
      const operations = branch.properties.operation.enum ?? [branch.properties.operation.const];
      const consumers = branch.properties.consumer.enum ?? [branch.properties.consumer.const];
      for (const operation of operations) {
        for (const consumer of consumers) {
          schemaContracts.add(
            `${branch.properties.domain.const}/${branch.properties.slice.const}/${consumer}/${operation}`,
          );
          expect(typeof operation).toBe("string");
          expect(operation?.length).toBeGreaterThan(0);
          expect(typeof consumer).toBe("string");
          expect(consumer?.length).toBeGreaterThan(0);
          expect(() =>
            parseDomainCoreShadowSampleRequest(
              {
                samples: [
                  {
                    ...v3Sample(),
                    domain: branch.properties.domain.const,
                    slice: branch.properties.slice.const,
                    consumer,
                    operation,
                  },
                ],
              },
              NOW,
            ),
          ).not.toThrow();
        }
      }
    }
    const serverContracts = new Set(
      Object.entries(DOMAIN_CORE_SHADOW_OPERATION_SLICES).flatMap(([domain, operationSlices]) =>
        Object.entries(operationSlices).flatMap(([operation, slice]) =>
          domainCoreShadowOperationConsumers(domain, slice, operation).map(
            (consumer) => `${domain}/${slice}/${consumer}/${operation}`,
          ),
        ),
      ),
    );
    expect(serverContracts).toEqual(schemaContracts);
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
    expect(parsed[0]).not.toHaveProperty("slice");
  });

  it.each([
    ["extra request field", { samples: [sample()], uid: "must-not-be-accepted" }],
    ["extra sample field", { samples: [{ ...sample(), payload: "secret" }] }],
    ["production channel", { samples: [{ ...sample(), channel: "production" }] }],
    ["inconsistent category", { samples: [sample({ mismatchCategory: "result_mismatch" })] }],
    ["unsafe timing", { samples: [sample({ rustMicros: Number.MAX_SAFE_INTEGER + 1 })] }],
    ["non-UTC timestamp", { samples: [sample({ observedAt: "2026-07-13T11:59:59+00:00" })] }],
    ["stale sample", { samples: [sample({ observedAt: "2026-05-01T00:00:00.000Z" })] }],
    ["invented domain", { samples: [sample({ domain: "logs" as "quota" })] }],
    ["invalid slice consumer", { samples: [sample({ domain: "pricing", slice: "legacy-kimi", consumer: "apple" })] }],
    ["quota slice mismatch", { samples: [sample({ slice: "codex" })] }],
    ["uppercase candidate commit", { samples: [v3Sample({ candidateCommit: "A".repeat(40) })] }],
    ["short candidate commit", { samples: [v3Sample({ candidateCommit: "a".repeat(39) })] }],
    ["uppercase source fingerprint", { samples: [v3Sample({ expectedCoreSourceSha256: "B".repeat(64) })] }],
    ["noncanonical core version", { samples: [v3Sample({ expectedCoreVersion: "01.2.3" })] }],
    ["noncanonical numeric prerelease", { samples: [v3Sample({ expectedCoreVersion: "1.2.3-01" })] }],
    ["partial loaded identity", { samples: [v3Sample({ loadedCoreAbiVersion: null })] }],
    [
      "missing loaded match identity",
      {
        samples: [v3Sample({ loadedCoreVersion: null, loadedCoreAbiVersion: null, loadedCoreSourceSha256: null })],
      },
    ],
    [
      "missing loaded result-mismatch identity",
      {
        samples: [
          v3Sample({
            loadedCoreVersion: null,
            loadedCoreAbiVersion: null,
            loadedCoreSourceSha256: null,
            outcome: "mismatch",
            mismatchCategory: "result_mismatch",
          }),
        ],
      },
    ],
    [
      "missing loaded native-error identity",
      {
        samples: [
          v3Sample({
            loadedCoreVersion: null,
            loadedCoreAbiVersion: null,
            loadedCoreSourceSha256: null,
            outcome: "mismatch",
            mismatchCategory: "native_error",
          }),
        ],
      },
    ],
    [
      "loaded native-unavailable identity",
      {
        samples: [v3Sample({ outcome: "mismatch", mismatchCategory: "native_unavailable" })],
      },
    ],
    ["mismatched loaded version", { samples: [v3Sample({ loadedCoreVersion: "0.3.1" })] }],
    ["mismatched loaded ABI", { samples: [v3Sample({ loadedCoreAbiVersion: 4 })] }],
    ["mismatched loaded source", { samples: [v3Sample({ loadedCoreSourceSha256: "c".repeat(64) })] }],
    [
      "false loaded-identity mismatch",
      {
        samples: [v3Sample({ outcome: "mismatch", mismatchCategory: "loaded_identity_mismatch" })],
      },
    ],
    [
      "missing loaded-identity mismatch tuple",
      {
        samples: [
          v3Sample({
            loadedCoreVersion: null,
            loadedCoreAbiVersion: null,
            loadedCoreSourceSha256: null,
            outcome: "mismatch",
            mismatchCategory: "loaded_identity_mismatch",
          }),
        ],
      },
    ],
    ["invented V3 operation", { samples: [v3Sample({ operation: "claude_quota_other" })] }],
    [
      "cross-slice V3 operation",
      {
        samples: [v3Sample({ domain: "cloudvault", slice: "foundation", operation: "aes_gcm_open_combined" })],
      },
    ],
  ])("rejects %s", (_label, request) => {
    expect(() => parseDomainCoreShadowSampleRequest(request, NOW)).toThrow();
  });

  it("accepts unavailable V3 evidence with no loaded identity but never as a match", () => {
    const unavailable = v3Sample({
      loadedCoreVersion: null,
      loadedCoreAbiVersion: null,
      loadedCoreSourceSha256: null,
      outcome: "mismatch",
      mismatchCategory: "native_unavailable",
      rustMicros: 0,
    });

    expect(parseDomainCoreShadowSampleRequest({ samples: [unavailable] }, NOW)).toEqual([unavailable]);
  });

  it("pins the V3 schema to require a loaded tuple for native errors", () => {
    const schema: unknown = JSON.parse(
      readFileSync(resolve(__dirname, "../../../docs/contracts/domain-core-shadow-sample-v3.schema.json"), "utf8"),
    );
    const identityRequired = mismatchRequirementProperties(schema, "native_error");

    expect(identityRequired).toMatchObject({
      loadedCoreVersion: { type: "string" },
      loadedCoreAbiVersion: { type: "integer" },
      loadedCoreSourceSha256: { type: "string" },
    });
  });

  it("records a wrong loaded binary as explicit non-success telemetry", () => {
    const identityMismatch = v3Sample({
      loadedCoreVersion: "0.3.1",
      loadedCoreAbiVersion: 4,
      loadedCoreSourceSha256: "c".repeat(64),
      outcome: "mismatch",
      mismatchCategory: "loaded_identity_mismatch",
    });

    expect(parseDomainCoreShadowSampleRequest({ samples: [identityMismatch] }, NOW)).toEqual([identityMismatch]);
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

  it("binds V3 candidate and expected Rust identity to server-issued claims", () => {
    expect(() => enforceDomainCoreShadowChannelClaim(v3Claims(), [v3Sample()])).not.toThrow();
    expect(() =>
      enforceDomainCoreShadowChannelClaim(v3Claims({ domainCoreShadowCandidateCommit: "c".repeat(40) }), [v3Sample()]),
    ).toThrow("not enrolled for the submitted domain-core candidate");
    expect(() =>
      enforceDomainCoreShadowChannelClaim(v3Claims({ domainCoreShadowCoreVersion: "0.3.1" }), [v3Sample()]),
    ).toThrow("not enrolled for the submitted domain-core candidate");
    expect(() =>
      enforceDomainCoreShadowChannelClaim(v3Claims({ domainCoreShadowCoreVersion: "01.2.3" }), [v3Sample()]),
    ).toThrow("not enrolled for the submitted domain-core candidate");
    expect(() =>
      enforceDomainCoreShadowChannelClaim(v3Claims({ domainCoreShadowCoreAbiVersion: 4 }), [v3Sample()]),
    ).toThrow("not enrolled for the submitted domain-core candidate");
    expect(() =>
      enforceDomainCoreShadowChannelClaim(v3Claims({ domainCoreShadowCoreSourceSha256: "c".repeat(64) }), [v3Sample()]),
    ).toThrow("not enrolled for the submitted domain-core candidate");
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

  it("marks V1/V2 drain records non-promotable and only candidate-bound V3 promotable", () => {
    expect(storedDomainCoreShadowSample(sample(), NOW).promotionEligible).toBe(false);
    expect(storedDomainCoreShadowSample(v3Sample(), NOW).promotionEligible).toBe(true);
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

  it("treats an exact V3 candidate replay as idempotent and rejects identity mutation", async () => {
    const original = v3Sample();
    const exactStore: DomainCoreShadowStore = {
      doc: (path: string) => ({ path }),
      runTransaction: async (body) =>
        body({
          get: async () => ({ exists: true, data: () => storedDomainCoreShadowSample(original, NOW) }),
          create: () => undefined,
        }),
    };
    await expect(persistDomainCoreShadowSamples(exactStore, [original], NOW)).resolves.toEqual({
      accepted: 0,
      duplicates: 1,
    });

    const mutated = v3Sample({ candidateCommit: "c".repeat(40) });
    await expect(persistDomainCoreShadowSamples(exactStore, [mutated], NOW)).rejects.toThrow(
      "conflicts with immutable stored evidence",
    );
  });
});

describe("domain-core shadow evidence hermes payload-keywrap combined ops", () => {
  // Defends the Hermes payload-keywrap seal_combined/open_combined shadow
  // evidence contract on the Functions/server parser. Both combined AEAD
  // operations must pass V3 validation for both apple and android consumers
  // and the parsed operation must be preserved end-to-end. Before the fix the
  // DOMAIN_CORE_SHADOW_OPERATION_SLICES.hermes payload-keywrap slice omitted
  // seal_combined/open_combined, so parseDomainCoreShadowSampleRequest
  // rejected any submitted combined-op sample with an inconsistent
  // operation/slice error and the server never recorded key-wrap AEAD
  // evidence. These cases redden if either combined operation is removed from
  // the operation-slice map (or the authoritative V3 schema oneOf branch).
  it.each([
    ["seal_combined", "apple"],
    ["open_combined", "apple"],
    ["seal_combined", "android"],
    ["open_combined", "android"],
  ] as const)("accepts and preserves V3 hermes payload-keywrap %s for %s", (operation, consumer) => {
    const sample = v3Sample({
      domain: "hermes",
      slice: "payload-keywrap",
      consumer,
      operation,
    });
    const parsed = parseDomainCoreShadowSampleRequest({ samples: [sample] }, NOW);

    expect(parsed).toHaveLength(1);
    const parsedSample = parsed[0];
    if (!parsedSample || parsedSample.schemaVersion !== 3) {
      throw new Error("parser did not preserve the V3 hermes payload-keywrap sample");
    }
    expect(parsedSample).toEqual(sample);
    expect(parsedSample.operation).toBe(operation);
    expect(parsedSample.domain).toBe("hermes");
    expect(parsedSample.slice).toBe("payload-keywrap");
    expect(parsedSample.consumer).toBe(consumer);
  });

  it("builds V3 producer samples for both hermes payload-keywrap combined ops and preserves operation through buildDomainCoreShadowSampleV3", () => {
    for (const operation of ["seal_combined", "open_combined"] as const) {
      const comparison = {
        ...v3Sample({ domain: "hermes", slice: "payload-keywrap", operation }),
      };
      const { schemaVersion: _schemaVersion, sampleId: _sampleId, observedAt: _observedAt, ...rest } = comparison;
      const built = buildDomainCoreShadowSampleV3(rest, {
        nowMillis: NOW,
        sampleId: "00000000-0000-4000-8000-000000000099",
      });

      expect(built.operation).toBe(operation);
      expect(built.domain).toBe("hermes");
      expect(built.slice).toBe("payload-keywrap");
      expect(built.schemaVersion).toBe(3);
    }
  });

  it("authoritative V3 schema admits both hermes payload-keywrap combined ops for apple and android", () => {
    const branches = v3OperationContractBranches();
    const keyWrapBranch = branches.find(
      (branch) => branch.properties.domain.const === "hermes" && branch.properties.slice.const === "payload-keywrap",
    );
    if (!keyWrapBranch) {
      throw new Error("authoritative V3 schema is missing the hermes payload-keywrap branch");
    }
    const operationContract = keyWrapBranch.properties.operation;
    const consumerContract = keyWrapBranch.properties.consumer;
    const operations = operationContract.enum ?? (operationContract.const ? [operationContract.const] : []);
    const consumers = consumerContract.enum ?? (consumerContract.const ? [consumerContract.const] : []);
    expect(operations).toEqual(expect.arrayContaining(["seal_combined", "open_combined"]));
    expect(consumers).toEqual(expect.arrayContaining(["apple", "android"]));
  });

  it("rejects a hermes payload-keywrap combined op placed under the wrong slice", () => {
    expect(() =>
      parseDomainCoreShadowSampleRequest(
        {
          samples: [
            v3Sample({
              domain: "hermes",
              slice: "aad",
              consumer: "apple",
              operation: "seal_combined",
            }),
          ],
        },
        NOW,
      ),
    ).toThrow();
  });
});
