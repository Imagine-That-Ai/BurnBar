import { describe, expect, it, vi, beforeEach } from "vitest";

const { pushWithResilience } = vi.hoisted(() => ({
  pushWithResilience: vi.fn(async (_label: string, fn: () => Promise<unknown>) => fn()),
}));

vi.mock("../resilienceHelpers.js", async (importOriginal) => {
  const actual = await importOriginal<typeof import("../resilienceHelpers.js")>();
  return {
    ...actual,
    pushWithResilience,
  };
});

function makeFakePushRef(initialData: Record<string, unknown>) {
  const state = { data: { ...initialData } };
  const ref = {
    id: "push-1",
    path: "outbound/push-1",
    firestore: {
      async runTransaction<T>(fn: (transaction: unknown) => Promise<T>): Promise<T> {
        const transaction = {
          async get() {
            return {
              exists: true,
              data: () => ({ ...state.data }),
            };
          },
          update(_ref: unknown, patch: Record<string, unknown>) {
            state.data = { ...state.data, ...patch };
          },
        };
        return fn(transaction);
      },
    },
  };
  return { ref: ref as FirebaseFirestore.DocumentReference, state };
}

describe("push resilience wiring", () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  it("pushAndroidFcm uses pushWithResilience", async () => {
    const { pushAndroidFcm } = await import("../fcmAndroidSender.js");
    const result = await pushAndroidFcm({
      fcmToken: "token",
      documentId: "doc-1",
      data: { call_id: "c1" },
      sender: async () => "msg-123",
    });
    expect(pushWithResilience).toHaveBeenCalledWith("fcm.mercury", expect.any(Function));
    expect(result.status).toBe("sent");
    expect(result.messageId).toBe("msg-123");
  });

  it("pushToAPNs uses pushWithResilience", async () => {
    const { pushToAPNs } = await import("../apnsSender.js");
    const result = await pushToAPNs({
      deviceTokenHex: "a".repeat(64),
      documentId: "doc-1",
      payload: { call_id: "c1" },
      hostOverride: "https://127.0.0.1:9",
      topicOverride: "com.test.voip",
    });
    expect(pushWithResilience).toHaveBeenCalledWith("apns.voip", expect.any(Function));
    expect(result.status).toBe("retry");
  });

  it("claimPendingPush serializes duplicate delivery and finish requires the same lease", async () => {
    const { claimPendingPush, finishClaimedPush } = await import("../resilienceHelpers.js");
    const { ref, state } = makeFakePushRef({ status: "pending", attemptCount: 0 });

    const claim = await claimPendingPush(ref, { nowMs: 1_000, leaseMs: 60_000 });
    expect(claim).toBeDefined();
    expect(claim?.attemptCount).toBe(1);
    expect(state.data.status).toBe("sending");

    await expect(claimPendingPush(ref, { nowMs: 2_000, leaseMs: 60_000 })).resolves.toBeUndefined();
    await expect(finishClaimedPush(ref, "wrong-lease", { status: "sent" })).resolves.toBe(false);
    expect(state.data.status).toBe("sending");

    await expect(finishClaimedPush(ref, claim!.leaseId, { status: "sent" })).resolves.toBe(true);
    expect(state.data.status).toBe("sent");
  });

  it("claimPendingPush skips future retryAt and reclaims expired sending leases", async () => {
    const { claimPendingPush, nextPushRetryAt } = await import("../resilienceHelpers.js");
    const future = nextPushRetryAt(1_000, 1);
    const pending = makeFakePushRef({ status: "pending", retryAt: future });

    await expect(claimPendingPush(pending.ref, { nowMs: 2_000 })).resolves.toBeUndefined();

    const expiredSending = makeFakePushRef({
      status: "sending",
      leaseId: "old-lease",
      leaseExpiresAt: nextPushRetryAt(1_000, 1),
      attemptCount: 3,
    });
    const claim = await claimPendingPush(expiredSending.ref, { nowMs: 40_000 });
    expect(claim?.attemptCount).toBe(4);
    expect(expiredSending.state.data.status).toBe("sending");
    expect(expiredSending.state.data.leaseId).not.toBe("old-lease");
  });
});
