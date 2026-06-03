import { describe, expect, it, vi } from "vitest";
import { Timestamp } from "firebase-admin/firestore";
import type { QueryDocumentSnapshot } from "firebase-admin/firestore";
import {
  MAX_VOIP_RETRY_ATTEMPTS,
  nextVoIPRetryDelayMs,
  processStuckVoIPPush,
  sweepStuckVoIPPushes,
} from "../apnsSender.js";
import type { SendResult } from "../apnsSender.js";

// `firebase-functions/logger` calls `console.*` under the hood; silence it so a
// rejected/swept document does not spam the test reporter.
vi.mock("firebase-functions/logger", () => ({
  info: vi.fn(),
  error: vi.fn(),
  warn: vi.fn(),
  debug: vi.fn(),
}));

const NOW = new Date("2026-06-02T12:00:00.000Z");

/**
 * Build a fake `voip_outbound` snapshot. `ref.update` records the committed
 * patch so each test can assert the document's next state without Firestore.
 */
function fakeSnapshot(
  id: string,
  data: Record<string, unknown>,
): { snapshot: QueryDocumentSnapshot; updates: Record<string, unknown>[] } {
  const updates: Record<string, unknown>[] = [];
  const snapshot = {
    id,
    data: () => data,
    ref: {
      path: `users/u1/voip_outbound/${id}`,
      update: vi.fn(async (patch: Record<string, unknown>) => {
        updates.push(patch);
      }),
    },
  } as unknown as QueryDocumentSnapshot;
  return { snapshot, updates };
}

function pushReturning(result: SendResult) {
  return vi.fn(async () => result);
}

describe("nextVoIPRetryDelayMs", () => {
  it("doubles from a 30s base and caps at 15 minutes", () => {
    expect(nextVoIPRetryDelayMs(1)).toBe(30_000);
    expect(nextVoIPRetryDelayMs(2)).toBe(60_000);
    expect(nextVoIPRetryDelayMs(3)).toBe(120_000);
    // 30s * 2^7 = 64 min → capped at 15 min.
    expect(nextVoIPRetryDelayMs(8)).toBe(15 * 60_000);
  });
});

describe("processStuckVoIPPush", () => {
  it("(a) re-pushes a due pending doc and transitions it to 'sent'", async () => {
    const { snapshot, updates } = fakeSnapshot("doc-sent", {
      status: "pending",
      voipDeviceToken: "a".repeat(64),
      payload: { call_id: "c1" },
      retryAt: Timestamp.fromDate(new Date(NOW.getTime() - 30_000)),
      attemptCount: 1,
    });
    const push = pushReturning({ status: "sent", apnsStatusCode: 200 });

    const outcome = await processStuckVoIPPush(snapshot, push, NOW);

    expect(outcome).toBe("sent");
    expect(push).toHaveBeenCalledWith({
      deviceTokenHex: "a".repeat(64),
      payload: { call_id: "c1" },
      documentId: "doc-sent",
    });
    expect(updates).toHaveLength(1);
    expect(updates[0]).toMatchObject({ status: "sent", apnsStatusCode: 200 });
    expect(updates[0].deliveredAt).toBeInstanceOf(Timestamp);
  });

  it("(b1) seals to 'rejected' on a permanent 410 reject", async () => {
    const { snapshot, updates } = fakeSnapshot("doc-410", {
      status: "pending",
      voipDeviceToken: "b".repeat(64),
      retryAt: Timestamp.fromDate(new Date(NOW.getTime() - 1_000)),
      attemptCount: 0,
    });
    const push = pushReturning({ status: "rejected", apnsStatusCode: 410, reason: "BadDeviceToken" });

    const outcome = await processStuckVoIPPush(snapshot, push, NOW);

    expect(outcome).toBe("rejected");
    expect(updates[0]).toMatchObject({
      status: "rejected",
      apnsStatusCode: 410,
      reason: "BadDeviceToken",
    });
  });

  it("(b2) seals to 'rejected' once attempts reach MAX_VOIP_RETRY_ATTEMPTS even on a transient failure", async () => {
    const { snapshot, updates } = fakeSnapshot("doc-exhausted", {
      status: "pending",
      voipDeviceToken: "c".repeat(64),
      retryAt: Timestamp.fromDate(new Date(NOW.getTime() - 1_000)),
      // One short of the cap; the failure we observe bumps it to the cap.
      attemptCount: MAX_VOIP_RETRY_ATTEMPTS - 1,
    });
    const push = pushReturning({ status: "retry", reason: "503 service unavailable" });

    const outcome = await processStuckVoIPPush(snapshot, push, NOW);

    expect(outcome).toBe("rejected");
    expect(updates[0]).toMatchObject({
      status: "rejected",
      attemptCount: MAX_VOIP_RETRY_ATTEMPTS,
    });
    expect(updates[0].rejectedAt).toBeInstanceOf(Timestamp);
  });

  it("reschedules with exponential backoff on a transient failure under the cap", async () => {
    const { snapshot, updates } = fakeSnapshot("doc-retry", {
      status: "pending",
      voipDeviceToken: "d".repeat(64),
      retryAt: Timestamp.fromDate(new Date(NOW.getTime() - 1_000)),
      attemptCount: 1,
    });
    const push = pushReturning({ status: "retry", reason: "429 too many requests" });

    const outcome = await processStuckVoIPPush(snapshot, push, NOW);

    expect(outcome).toBe("rescheduled");
    expect(updates[0]).toMatchObject({ status: "pending", attemptCount: 2 });
    const retryAt = updates[0].retryAt as Timestamp;
    // attemptCount 2 → 60s backoff.
    expect(retryAt.toMillis()).toBe(NOW.getTime() + 60_000);
  });

  it("skips a doc whose status already advanced past 'pending' (double-processing guard)", async () => {
    const { snapshot, updates } = fakeSnapshot("doc-already-sent", {
      status: "sent",
      voipDeviceToken: "e".repeat(64),
      retryAt: Timestamp.fromDate(new Date(NOW.getTime() - 1_000)),
    });
    const push = pushReturning({ status: "sent", apnsStatusCode: 200 });

    const outcome = await processStuckVoIPPush(snapshot, push, NOW);

    expect(outcome).toBe("skipped");
    expect(push).not.toHaveBeenCalled();
    expect(updates).toHaveLength(0);
  });
});

describe("sweepStuckVoIPPushes", () => {
  /**
   * Build a fake Firestore whose collection-group query returns `docs`. The
   * chained `.where().where().orderBy().limit().get()` mirrors the real query
   * builder so we exercise the exact call shape the sweeper uses.
   */
  function fakeDb(docs: QueryDocumentSnapshot[]) {
    const query = {
      where: vi.fn(() => query),
      orderBy: vi.fn(() => query),
      limit: vi.fn(() => query),
      get: vi.fn(async () => ({ docs })),
    };
    const collectionGroup = vi.fn(() => query);
    return { db: { collectionGroup } as never, collectionGroup, query };
  }

  it("(a) re-pushes a due pending doc to 'sent' and (c) leaves a not-yet-due doc untouched", async () => {
    const due = fakeSnapshot("due", {
      status: "pending",
      voipDeviceToken: "a".repeat(64),
      retryAt: Timestamp.fromDate(new Date(NOW.getTime() - 5_000)),
      attemptCount: 1,
    });
    // A future-`retryAt` doc would not be returned by the real query at all, so
    // simulate the query already filtering it out: it is absent from `docs`.
    const future = fakeSnapshot("future", {
      status: "pending",
      voipDeviceToken: "f".repeat(64),
      retryAt: Timestamp.fromDate(new Date(NOW.getTime() + 600_000)),
      attemptCount: 0,
    });

    const { db, query } = fakeDb([due.snapshot]);
    const push = pushReturning({ status: "sent", apnsStatusCode: 200 });

    const tally = await sweepStuckVoIPPushes(db, push, NOW);

    expect(tally).toEqual({ sent: 1, rejected: 0, rescheduled: 0, skipped: 0 });
    // The query filtered to status == pending AND retryAt <= now, ordered + bounded.
    expect(query.where).toHaveBeenCalledWith("status", "==", "pending");
    expect(query.where).toHaveBeenCalledWith("retryAt", "<=", expect.any(Timestamp));
    expect(query.orderBy).toHaveBeenCalledWith("retryAt", "asc");
    expect(query.limit).toHaveBeenCalled();
    // Due doc was pushed + committed; the not-yet-due doc never reached us.
    expect(due.updates[0]).toMatchObject({ status: "sent" });
    expect(push).toHaveBeenCalledTimes(1);
    expect(future.updates).toHaveLength(0);
  });

  it("counts a continued-failure-at-cap document as rejected", async () => {
    const exhausted = fakeSnapshot("exhausted", {
      status: "pending",
      voipDeviceToken: "c".repeat(64),
      retryAt: Timestamp.fromDate(new Date(NOW.getTime() - 5_000)),
      attemptCount: MAX_VOIP_RETRY_ATTEMPTS - 1,
    });
    const { db } = fakeDb([exhausted.snapshot]);
    const push = pushReturning({ status: "retry", reason: "503" });

    const tally = await sweepStuckVoIPPushes(db, push, NOW);

    expect(tally).toEqual({ sent: 0, rejected: 1, rescheduled: 0, skipped: 0 });
    expect(exhausted.updates[0]).toMatchObject({ status: "rejected" });
  });
});
