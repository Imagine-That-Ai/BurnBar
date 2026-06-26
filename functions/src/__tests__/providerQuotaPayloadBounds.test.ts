import { describe, expect, it } from "vitest";

import { __testing__ as minimaxTesting } from "../providers/minimax.js";
import { QUOTA_PAYLOAD_MAX_BUCKETS, QUOTA_PAYLOAD_MAX_LABEL_LENGTH } from "../providers/quotaPayloadWalker.js";
import { __testing__ as zaiTesting } from "../providers/zai.js";

function deeplyNestedPayload(depth: number): Record<string, unknown> {
  const root: Record<string, unknown> = {};
  let cursor = root;
  for (let index = 0; index < depth; index += 1) {
    const next: Record<string, unknown> = {};
    cursor.next = next;
    cursor = next;
  }
  cursor.bucket = {
    name: "deep_bucket",
    used: 1,
    limit: 10,
    remaining: 9,
    window: "monthly",
  };
  return root;
}

function manyNestedBuckets(count: number): Record<string, unknown> {
  const root: Record<string, unknown> = {};
  for (let index = 0; index < count; index += 1) {
    root[`bucket_${index}`] = {
      name: `${"oversized-provider-quota-label-".repeat(12)}${index}`,
      used: index + 1,
      limit: count + 10,
      remaining: count - index,
      window: "monthly",
    };
  }
  return root;
}

describe("provider quota payload bounds", () => {
  it("keeps MiniMax fallback harvesting bounded for deeply nested payloads", () => {
    const buckets = minimaxTesting.extractBuckets(deeplyNestedPayload(5_000));

    expect(buckets).toEqual([]);
  });

  it("keeps Z.ai fallback harvesting bounded for deeply nested payloads", () => {
    const buckets = zaiTesting.bucketsFromMonitorQuota(deeplyNestedPayload(5_000));

    expect(buckets).toEqual([]);
  });

  it("caps fallback bucket output and oversized labels", () => {
    const minimaxBuckets = minimaxTesting.extractBuckets(manyNestedBuckets(QUOTA_PAYLOAD_MAX_BUCKETS + 40));
    const zaiBuckets = zaiTesting.bucketsFromMonitorQuota(manyNestedBuckets(QUOTA_PAYLOAD_MAX_BUCKETS + 40));

    expect(minimaxBuckets).toHaveLength(QUOTA_PAYLOAD_MAX_BUCKETS);
    expect(zaiBuckets).toHaveLength(QUOTA_PAYLOAD_MAX_BUCKETS);
    expect(minimaxBuckets[0].name.length).toBeLessThanOrEqual(QUOTA_PAYLOAD_MAX_LABEL_LENGTH);
    expect(zaiBuckets[0].name.length).toBeLessThanOrEqual(QUOTA_PAYLOAD_MAX_LABEL_LENGTH);
  });

  it("caps documented provider bucket arrays before normalizing them", () => {
    const rows = Array.from({ length: QUOTA_PAYLOAD_MAX_BUCKETS + 8 }, (_, index) => ({
      model_name: `model_${index}`,
      used: index,
      total: 100,
      remains: 100 - index,
      period: "monthly",
    }));
    const quotaList = rows.map((row) => ({
      window: row.model_name,
      used: row.used,
      limit: row.total,
      remaining: row.remains,
    }));

    expect(minimaxTesting.extractBuckets({ model_remains: rows })).toHaveLength(QUOTA_PAYLOAD_MAX_BUCKETS);
    expect(zaiTesting.bucketsFromMonitorQuota({ data: { quotaList } })).toHaveLength(QUOTA_PAYLOAD_MAX_BUCKETS);
  });

  it("does not scan MiniMax rows beyond the bucket cap", () => {
    const rows = Array.from({ length: QUOTA_PAYLOAD_MAX_BUCKETS }, (_, index) => ({
      model_name: `model_${index}`,
      used: index,
      total: 100,
      remains: 100 - index,
      period: "monthly",
    }));
    Object.defineProperty(rows, QUOTA_PAYLOAD_MAX_BUCKETS + 4, {
      get() {
        throw new Error("uncapped MiniMax row traversal");
      },
    });

    expect(minimaxTesting.extractBuckets({ model_remains: rows })).toHaveLength(QUOTA_PAYLOAD_MAX_BUCKETS);
  });

  it("preserves full Z.ai diagnostic messages while bounding quota labels", () => {
    const longMessage = `  ${"quota diagnostic with internal spacing  ".repeat(12)}  `;

    expect(zaiTesting.inlineErrorMessage({ success: false, msg: longMessage })).toBe(longMessage.trim());
    expect(
      zaiTesting.bucketsFromMonitorQuota({
        data: {
          quotaList: [{ window: longMessage, used: 1, limit: 2, remaining: 1 }],
        },
      })[0].name.length,
    ).toBeLessThanOrEqual(QUOTA_PAYLOAD_MAX_LABEL_LENGTH);
  });
});
