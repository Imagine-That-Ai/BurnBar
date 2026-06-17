import { describe, expect, it } from "vitest";
import { StreamingPercentileSketch } from "../streamingPercentiles.js";

function decodeSketch(summary: ReturnType<StreamingPercentileSketch["summary"]>): {
  kind: string;
  count: number;
  buckets: Array<[number, number]>;
} {
  expect(summary.sketchBase64).toBeTruthy();
  return JSON.parse(Buffer.from(summary.sketchBase64 ?? "", "base64").toString("utf8"));
}

describe("StreamingPercentileSketch", () => {
  it("preserves nearest-rank percentiles for exact bucket anchors", () => {
    const sketch = new StreamingPercentileSketch([25, 100, 275, 600]);
    for (const value of [25, 25, 100, 275, 600]) {
      sketch.add(value);
    }

    const summary = sketch.summary();
    expect(summary).toMatchObject({ count: 5, p50: 100, p95: 600, p99: 600 });
    expect(decodeSketch(summary)).toMatchObject({
      kind: "relative-error-log-histogram",
      count: 5,
      buckets: [
        [25, 2],
        [100, 1],
        [275, 1],
        [600, 1],
      ],
    });
  });

  it("keeps high-cardinality values bounded with logarithmic buckets", () => {
    const sketch = new StreamingPercentileSketch();
    for (let value = 1; value <= 100_000; value += 1) {
      sketch.add(value);
    }

    const decoded = decodeSketch(sketch.summary());
    expect(decoded.count).toBe(100_000);
    expect(decoded.buckets.length).toBeLessThan(130);
  });

  it("omits sketch payloads for empty summaries", () => {
    expect(new StreamingPercentileSketch().summary()).toEqual({ count: 0 });
  });
});
