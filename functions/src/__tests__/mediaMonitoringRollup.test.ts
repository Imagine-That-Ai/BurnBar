import { describe, expect, it, vi } from "vitest";
import { rollupMediaSessionsForDay } from "../mediaMonitoring.js";

type FakeMediaDoc = {
  path: string;
  data: Record<string, unknown>;
};

class FakeMediaQuery {
  constructor(
    private readonly docs: FakeMediaDoc[],
    private readonly filters: Array<{ field: string; op: string; value: string }> = [],
    private readonly cursor?: FakeMediaDoc,
    private readonly pageLimit = Number.POSITIVE_INFINITY,
  ) {}

  where(field: string, op: string, value: string): FakeMediaQuery {
    return new FakeMediaQuery(this.docs, [...this.filters, { field, op, value }], this.cursor, this.pageLimit);
  }

  orderBy(_field: string): FakeMediaQuery {
    return this;
  }

  startAfter(cursor: { ref: { path: string } }): FakeMediaQuery {
    const nextCursor = this.docs.find((doc) => doc.path === cursor.ref.path);
    return new FakeMediaQuery(this.docs, this.filters, nextCursor, this.pageLimit);
  }

  limit(limit: number): FakeMediaQuery {
    return new FakeMediaQuery(this.docs, this.filters, this.cursor, limit);
  }

  async get(): Promise<{
    readonly empty: boolean;
    readonly size: number;
    readonly docs: Array<{ ref: { path: string }; data: () => Record<string, unknown> }>;
  }> {
    const filtered = this.docs
      .filter((doc) =>
        this.filters.every((filter) => {
          const value = doc.data[filter.field];
          if (typeof value !== "string") return false;
          if (filter.op === ">=") return value >= filter.value;
          if (filter.op === "<") return value < filter.value;
          return false;
        }),
      )
      .sort((left, right) => String(left.data.startedAt).localeCompare(String(right.data.startedAt)));
    const cursorIndex = this.cursor ? filtered.findIndex((doc) => doc.path === this.cursor?.path) + 1 : 0;
    const page = filtered.slice(cursorIndex, cursorIndex + this.pageLimit);
    const docs = page.map((doc) => ({
      ref: { path: doc.path },
      data: () => doc.data,
    }));
    return { empty: docs.length === 0, size: docs.length, docs };
  }
}

class FakeFirestore {
  readonly set = vi.fn();

  constructor(private readonly docs: FakeMediaDoc[]) {}

  collectionGroup(name: string): FakeMediaQuery {
    expect(name).toBe("media_session_events");
    return new FakeMediaQuery(this.docs);
  }

  doc(path: string): { set: (data: unknown, options: unknown) => Promise<void> } {
    return {
      set: async (data, options) => {
        this.set(path, data, options);
      },
    };
  }
}

describe("rollupMediaSessionsForDay", () => {
  it("writes schema-v2 bounded percentile summaries for media session events", async () => {
    const firestore = new FakeFirestore([
      {
        path: "users/user-1/media_session_events/event-1",
        data: {
          feature: "fileTransfer",
          startedAt: "2026-06-17T00:10:00.000Z",
          endedAt: "2026-06-17T00:20:00.000Z",
          endReason: "completedSuccess",
          p95RoundTripMillisBucket: "lt_50ms",
          p95BitsPerSecondBucket: "1_2mbps",
          freezeCount: 2,
          byteCountInbound: 100,
          byteCountOutbound: 50,
        },
      },
      {
        path: "users/user-2/media_session_events/event-2",
        data: {
          feature: "fileTransfer",
          startedAt: "2026-06-17T01:00:00.000Z",
          endedAt: "2026-06-17T01:30:00.000Z",
          endReason: "networkFailure",
          p95RoundTripMillisBucket: "gte_400ms",
          p95BitsPerSecondBucket: "gte_8mbps",
          freezeCount: 9,
          byteCountInbound: 200,
          byteCountOutbound: 300,
        },
      },
      {
        path: "users/user-1/media_session_events/event-3",
        data: {
          feature: "screenShare",
          startedAt: "2026-06-17T02:00:00.000Z",
          endedAt: "2026-06-17T02:05:00.000Z",
          endReason: "completedSuccess",
          p95RoundTripMillisBucket: "50_150ms",
          p95BitsPerSecondBucket: "600kbps_1mbps",
          freezeCount: 0,
        },
      },
      {
        path: "users/user-9/media_session_events/event-outside-window",
        data: {
          feature: "videoCall",
          startedAt: "2026-06-18T00:00:00.000Z",
          endedAt: "2026-06-18T00:10:00.000Z",
        },
      },
    ]);

    const rollup = await rollupMediaSessionsForDay({
      dateUTC: new Date("2026-06-17T12:00:00.000Z"),
      firestore,
    });

    expect(rollup).toMatchObject({
      id: "2026-06-17",
      date: "2026-06-17",
      windowStart: "2026-06-17T00:00:00.000Z",
      windowEnd: "2026-06-18T00:00:00.000Z",
      totalEvents: 3,
      uniqueUsers: 2,
      schemaVersion: 2,
    });
    expect(rollup.perFeature.fileTransfer).toMatchObject({
      sessionCount: 2,
      successRate: 0.5,
      totalSeconds: 2400,
      totalBytes: 650,
      rttMillis: { count: 2, p50: 25, p95: 600, p99: 600 },
      bitsPerSecond: { count: 2, p50: 1_500_000, p95: 12_000_000, p99: 12_000_000 },
      freezeCount: { count: 2, p50: 2, p95: 9, p99: 9 },
    });
    expect(rollup.perFeature.fileTransfer.rttMillis.sketchBase64).toBeTruthy();
    expect(rollup.perFeature.fileTransfer.freezeCount.sketchBase64).toBeTruthy();
    expect(rollup.perFeature.screenShare.rttMillis).toMatchObject({ count: 1, p50: 100, p95: 100, p99: 100 });
    expect(rollup.perFeature.videoCall.rttMillis).toEqual({ count: 0 });
    expect(firestore.set).toHaveBeenCalledWith("ops/media_session_daily_rollups/days/2026-06-17", rollup, {
      merge: true,
    });
  });
});
