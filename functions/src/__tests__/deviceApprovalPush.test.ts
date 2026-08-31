import { describe, expect, it, vi } from "vitest";
import { fanoutDeviceApprovalRequest } from "../deviceApprovalPush.js";

describe("deviceApprovalPush", () => {
  it("fans out push notification to companion devices excluding the requesting device", async () => {
    const sentMessages: unknown[] = [];
    const mockMessaging = {
      send: vi.fn(async (msg: unknown) => {
        sentMessages.push(msg);
        return "msg-123";
      }),
    };

    const mockDocs = [
      {
        id: "web_requesting_123",
        data: () => ({
          platform: "Web",
          fcmToken: "token_requesting",
        }),
        ref: { set: vi.fn() },
      },
      {
        id: "mac_companion_456",
        data: () => ({
          platform: "macOS",
          fcmToken: "token_mac",
        }),
        ref: { set: vi.fn() },
      },
      {
        id: "ios_companion_789",
        data: () => ({
          platform: "iOS",
          fcmToken: "token_ios",
        }),
        ref: { set: vi.fn() },
      },
      {
        id: "android_companion_999",
        data: () => ({
          platform: "Android",
          fcmToken: "token_android",
        }),
        ref: { set: vi.fn() },
      },
    ];

    const mockFirestore = {
      collection: vi.fn().mockReturnValue({
        doc: vi.fn().mockReturnValue({
          collection: vi.fn().mockReturnValue({
            get: vi.fn().mockResolvedValue({ docs: mockDocs }),
          }),
        }),
      }),
    } as unknown as FirebaseFirestore.Firestore;

    const result = await fanoutDeviceApprovalRequest({
      uid: "user_test_123",
      deviceId: "web_requesting_123",
      deviceName: "Chrome on macOS",
      platform: "Web",
      safetyCode: "4A7B9C1D",
      firestore: mockFirestore,
      messaging: mockMessaging,
    });

    expect(result.sent).toBe(3);
    expect(result.skipped).toBe(1);
    expect(result.failed).toBe(0);
    expect(sentMessages).toHaveLength(3);

    // Verify APNs payload for Apple platforms and FCM data payload
    const macMsg = sentMessages.find((m: any) => m.token === "token_mac") as any;
    expect(macMsg).toBeDefined();
    expect(macMsg.notification.title).toBe("New Device Approval Request");
    expect(macMsg.data.type).toBe("device_approval_request");
    expect(macMsg.data.device_id).toBe("web_requesting_123");
    expect(macMsg.data.safety_code).toBe("4A7B9C1D");
    expect(macMsg.apns.payload.aps.category).toBe("DEVICE_APPROVAL_REQUEST");

    // Android payload should have high priority and data envelope
    const androidMsg = sentMessages.find((m: any) => m.token === "token_android") as any;
    expect(androidMsg).toBeDefined();
    expect(androidMsg.android.priority).toBe("high");
    expect(androidMsg.data.type).toBe("device_approval_request");
  });
});
