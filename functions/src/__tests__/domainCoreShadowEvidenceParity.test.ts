import { readFileSync } from "node:fs";
import { resolve } from "node:path";

import { describe, expect, it } from "vitest";

import {
  DOMAIN_CORE_SHADOW_OPERATION_SLICES,
  domainCoreShadowOperationConsumers,
  parseDomainCoreShadowSampleRequest,
} from "../domainCoreShadowEvidence.js";
import { buildDomainCoreShadowSampleV3 } from "../domainCoreShadowEvidence.js";

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

describe("domain-core shadow evidence opaque-identifier and schema-parity contract", () => {
  it.each([
    ["apple", "project_memory_doc_id"],
    ["apple", "pensieve_dedup_hash"],
    ["apple", "pensieve_slug_hmac"],
    ["apple", "subscription_doc_id"],
    ["android", "subscription_doc_id"],
    ["remote-mcp", "pensieve_dedup_hash"],
    ["windows", "pensieve_dedup_hash"],
    ["windows", "pensieve_slug_hmac"],
    ["remote-mcp", "pensieve_provenance_hash"],
    ["remote-mcp", "pensieve_slug_hmac"],
    ["local-mcp", "project_memory_doc_id"],
  ])("opaque-identifier producer tuple %s/%s passes server-side V3 parsing", (consumer, operation) => {
    expect(() =>
      parseDomainCoreShadowSampleRequest(
        {
          samples: [
            v3Sample({
              domain: "cloudvault",
              slice: "opaque-identifiers",
              consumer: consumer as "apple",
              operation,
            }),
          ],
        },
        NOW,
      ),
    ).not.toThrow();
  });

  it.each([
    ["android", "project_memory_doc_id"],
    ["android", "pensieve_dedup_hash"],
    ["android", "pensieve_provenance_hash"],
    ["windows", "subscription_doc_id"],
    ["console", "project_memory_doc_id"],
    ["remote-mcp", "project_memory_doc_id"],
    ["remote-mcp", "subscription_doc_id"],
    ["local-mcp", "subscription_doc_id"],
    ["local-mcp", "pensieve_dedup_hash"],
  ])("opaque-identifier wrong consumer %s for %s is rejected by server-side V3 parsing", (consumer, operation) => {
    expect(() =>
      parseDomainCoreShadowSampleRequest(
        {
          samples: [
            v3Sample({
              domain: "cloudvault",
              slice: "opaque-identifiers",
              consumer: consumer as "apple",
              operation,
            }),
          ],
        },
        NOW,
      ),
    ).toThrow();
  });

  it("opaque-identifier wrong slice is rejected by server-side V3 parsing", () => {
    expect(() =>
      parseDomainCoreShadowSampleRequest(
        {
          samples: [
            v3Sample({
              domain: "cloudvault",
              slice: "foundation",
              consumer: "apple",
              operation: "subscription_doc_id",
            }),
          ],
        },
        NOW,
      ),
    ).toThrow();
  });

  it("shadow operation consumers map mirrors the canonical v3 schema oneOf branches exactly", () => {
    const branches = v3OperationContractBranches();
    const schemaConsumers = new Set<string>();
    for (const branch of branches) {
      const operations = branch.properties.operation.enum ?? [branch.properties.operation.const!];
      const consumers = branch.properties.consumer.enum ?? [branch.properties.consumer.const!];
      for (const operation of operations) {
        for (const consumer of consumers) {
          schemaConsumers.add(
            `${branch.properties.domain.const}/${branch.properties.slice.const}/${operation}/${consumer}`,
          );
        }
      }
    }
    const serverConsumers = new Set<string>();
    for (const [domain, slices] of Object.entries(DOMAIN_CORE_SHADOW_OPERATION_SLICES)) {
      for (const [operation, slice] of Object.entries(slices)) {
        for (const consumer of domainCoreShadowOperationConsumers(domain, slice, operation)) {
          serverConsumers.add(`${domain}/${slice}/${operation}/${consumer}`);
        }
      }
    }
    expect(serverConsumers).toEqual(schemaConsumers);
  });
});
