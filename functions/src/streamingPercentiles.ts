/**
 * @fileoverview Bounded-memory streaming percentile sketches.
 *
 * Daily rollups only need dashboard quantiles, not raw samples. This sketch
 * keeps exact counts for known bucket-anchor values and logarithmic buckets for
 * everything else, then emits nearest-rank p50/p95/p99 plus an opaque serialized
 * payload for future merge/backfill jobs.
 */

type PercentileSummary = {
  count: number;
  p50?: number;
  p95?: number;
  p99?: number;
  sketchBase64?: string;
};

type SketchBucket = {
  value: number;
  count: number;
};

const DEFAULT_BUCKET_BASE = 1.1;

function finiteNonNegative(value: number): number | undefined {
  if (!Number.isFinite(value) || value < 0) return undefined;
  return value;
}

function encodeSketch(payload: unknown): string {
  return Buffer.from(JSON.stringify(payload), "utf8").toString("base64");
}

export class StreamingPercentileSketch {
  private readonly exactAnchors: Set<number>;
  private readonly bucketBase: number;
  private readonly buckets = new Map<string, SketchBucket>();
  private total = 0;

  constructor(anchors: readonly number[] = [], bucketBase = DEFAULT_BUCKET_BASE) {
    this.exactAnchors = new Set(anchors.filter((value) => finiteNonNegative(value) !== undefined));
    this.bucketBase = Number.isFinite(bucketBase) && bucketBase > 1 ? bucketBase : DEFAULT_BUCKET_BASE;
  }

  add(rawValue: number | undefined): void {
    if (rawValue === undefined) return;
    const value = finiteNonNegative(rawValue);
    if (value === undefined) return;

    const bucket = this.bucketFor(value);
    const current = this.buckets.get(bucket.key);
    if (current) {
      current.count += 1;
    } else {
      this.buckets.set(bucket.key, { value: bucket.value, count: 1 });
    }
    this.total += 1;
  }

  summary(): PercentileSummary {
    if (this.total === 0) return { count: 0 };
    return {
      count: this.total,
      p50: this.percentile(50),
      p95: this.percentile(95),
      p99: this.percentile(99),
      sketchBase64: this.serialize(),
    };
  }

  private bucketFor(value: number): { key: string; value: number } {
    if (this.exactAnchors.has(value)) return { key: `exact:${value}`, value };
    if (value === 0) return { key: "exact:0", value: 0 };
    const index = Math.ceil(Math.log(value) / Math.log(this.bucketBase));
    const bucketValue = Math.ceil(Math.pow(this.bucketBase, index));
    return { key: `log:${index}`, value: bucketValue };
  }

  private sortedBuckets(): SketchBucket[] {
    return [...this.buckets.values()].sort((left, right) => left.value - right.value);
  }

  private percentile(pct: number): number | undefined {
    if (this.total === 0) return undefined;
    const target = Math.min(this.total, Math.max(1, Math.ceil((pct / 100) * this.total)));
    let seen = 0;
    for (const bucket of this.sortedBuckets()) {
      seen += bucket.count;
      if (seen >= target) return bucket.value;
    }
    return this.sortedBuckets().at(-1)?.value;
  }

  private serialize(): string {
    return encodeSketch({
      v: 1,
      kind: "relative-error-log-histogram",
      bucketBase: this.bucketBase,
      count: this.total,
      buckets: this.sortedBuckets().map((bucket) => [bucket.value, bucket.count]),
    });
  }
}
