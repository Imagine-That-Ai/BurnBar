import { describe, expect, it } from "vitest";

import {
  PUSH_DISPLAY_NAME_MAX_CHARS,
  parseTriggerRequest,
  pushCallerInitial,
  sanitizePushDisplayName,
} from "../voipPush.js";

describe("VoIP/FCM push metadata minimization", () => {
  it("normalizes, control-scrubs, and caps caller display names", () => {
    const raw = `  Alberto\u0000\u001b\u202e ${"x".repeat(200)}  `;
    const sanitized = sanitizePushDisplayName(raw);

    expect(sanitized).not.toMatch(/[\u0000-\u001f\u202a-\u202e]/u);
    expect(Array.from(sanitized)).toHaveLength(PUSH_DISPLAY_NAME_MAX_CHARS);
    expect(sanitized.startsWith("Alberto")).toBe(true);
    expect(pushCallerInitial(sanitized)).toBe("A");
  });

  it("rejects overlong or control-bearing routing ids before they reach push payloads", () => {
    expect(
      parseTriggerRequest({
        callId: "c".repeat(161),
        connectionId: "conn-1",
        pairedDeviceId: "phone-1",
        displayName: "Mac",
      }),
    ).toBeUndefined();

    expect(
      parseTriggerRequest({
        callId: "call-1",
        connectionId: "conn-\u0007",
        pairedDeviceId: "phone-1",
        displayName: "Mac",
      }),
    ).toBeUndefined();
  });

  it("returns sanitized payload metadata for valid trigger requests", () => {
    expect(
      parseTriggerRequest({
        callId: "call-1",
        connectionId: "conn-1",
        pairedDeviceId: "phone-1",
        displayName: "  Mac\u200bBook  ",
        isVideo: true,
      }),
    ).toMatchObject({
      callId: "call-1",
      connectionId: "conn-1",
      pairedDeviceId: "phone-1",
      displayName: "Mac Book",
      isVideo: true,
    });
  });
});
