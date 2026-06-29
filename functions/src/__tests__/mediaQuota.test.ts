import { describe, expect, it, vi } from "vitest";
import { recomputeQuotaUsageForUid } from "../mediaQuota.js";

type FakeMediaDoc = {
  data: Record<string, unknown>;
};

class FakeMediaQuery {
  constructor(
    private readonly docs: FakeMediaDoc[],
    private readonly filters: Array<{ field: string; op: string; value: string }> = [],
  ) {}

  where(field: string, op: string, value: string): FakeMediaQuery {
    return new FakeMediaQuery(this.docs, [...this.filters, { field, op, value }]);
  }

  async get(): Promise<{
    readonly docs: Array<{ data: () => Record<string, unknown> }>;
  }> {
    return {
      docs: this.docs
        .filter((doc) =>
          this.filters.every((filter) => {
            const value = doc.data[filter.field];
            if (typeof value !== "string") return false;
            if (filter.op === ">=") return value >= filter.value;
            if (filter.op === "<") return value < filter.value;
            return false;
          }),
        )
        .map((doc) => ({ data: () => doc.data })),
    };
  }
}

class FakeMediaCollection extends FakeMediaQuery {
  constructor(
    docs: FakeMediaDoc[],
    private readonly persist?: (id: string, data: unknown, options: unknown) => Promise<void>,
  ) {
    super(docs);
  }

  doc(id: string): { set: (data: unknown, options: unknown) => Promise<void> } {
    return {
      set: async (data, options) => {
        await this.persist?.(id, data, options);
      },
    };
  }
}

class FakeFirestore {
  readonly set = vi.fn();

  constructor(private readonly docs: FakeMediaDoc[]) {}

  collection(path: string): FakeMediaCollection {
    if (path === "users/user-1/media_session_events") {
      return new FakeMediaCollection(this.docs);
    }
    if (path === "users/user-1/media_quota_usage") {
      return new FakeMediaCollection([], async (id, data, options) => {
        this.set(id, data, options);
      });
    }
    throw new Error(`Unexpected collection path: ${path}`);
  }
}

describe("recomputeQuotaUsageForUid", () => {
  it("reconciles quota docs from media session events instead of owner-written quota counters", async () => {
    const firestore = new FakeFirestore([
      {
        data: {
          feature: "fileTransfer",
          startedAt: "2026-06-17T00:10:00.000Z",
          endedAt: "2026-06-17T00:20:00.000Z",
          endReason: "completedSuccess",
          byteCountInbound: 100,
          byteCountOutbound: 50,
        },
      },
      {
        data: {
          feature: "fileTransfer",
          startedAt: "2026-06-17T01:00:00.000Z",
          endedAt: "2026-06-17T01:01:00.000Z",
          endReason: "error",
          byteCountInbound: 20,
          byteCountOutbound: 10,
        },
      },
      {
        data: {
          feature: "screenShare",
          startedAt: "2026-06-17T02:00:00.000Z",
          endedAt: "2026-06-17T02:05:00.000Z",
          endReason: "completedPeerCancel",
          byteCountInbound: 999,
          byteCountOutbound: 888,
        },
      },
      {
        data: {
          feature: "videoCall",
          startedAt: "2026-06-17T03:00:00.000Z",
          endedAt: "2026-06-17T03:03:30.000Z",
          endReason: "completedUserCancel",
          byteCountInbound: -1,
          byteCountOutbound: -1,
        },
      },
      {
        data: {
          feature: "fileTransfer",
          startedAt: "2026-06-18T00:00:00.000Z",
          endedAt: "2026-06-18T00:10:00.000Z",
          endReason: "error",
          byteCountInbound: 1_000_000,
          byteCountOutbound: 1_000_000,
        },
      },
    ]);

    const doc = await recomputeQuotaUsageForUid({
      uid: "user-1",
      dateUTC: new Date("2026-06-17T12:00:00.000Z"),
      firestore,
    });

    expect(doc).toMatchObject({
      id: "2026-06-17",
      bytesUploadedFile: 60,
      bytesDownloadedFile: 120,
      fileTransfersInitiated: 2,
      fileTransfersFailed: 1,
      screenShareSecondsUsed: 300,
      screenShareSessions: 1,
      videoCallSecondsUsed: 210,
      videoCallSessions: 1,
      schemaVersion: 1,
    });
    expect(firestore.set).toHaveBeenCalledWith("2026-06-17", doc, { merge: true });
  });
});
