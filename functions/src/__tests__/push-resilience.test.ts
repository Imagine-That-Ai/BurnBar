import { describe, expect, it, vi, beforeEach } from "vitest";

const { pushWithResilience } = vi.hoisted(() => ({
  pushWithResilience: vi.fn(async (_label: string, fn: () => Promise<unknown>) => fn()),
}));

vi.mock("../resilienceHelpers.js", () => ({
  pushWithResilience,
}));

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
});
