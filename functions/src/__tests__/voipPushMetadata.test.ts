import { describe, expect, it } from "vitest";

import {
  PUSH_DISPLAY_NAME_MAX_CHARS,
  buildFcmCallPayload,
  buildVoipApnsPayload,
  ephemeralCallCorrelationId,
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

  it("omits connectionId, pairedDeviceId, and real displayName in APNs and FCM payloads (F-RR09-008)", () => {
    const correlationId = ephemeralCallCorrelationId();

    const apnsPayload = buildVoipApnsPayload({
      callId: "call-123",
      isVideo: true,
      correlationId,
      uid: "user-123",
      expiresAtMillis: 1_700_000_100_000,
    });

    const fcmPayload = buildFcmCallPayload({
      callId: "call-123",
      isVideo: true,
      correlationId,
      uid: "user-123",
      expiresAtMillis: 1_700_000_100_000,
    });

    // Verify APNs payload shape and omissions
    expect(apnsPayload).toHaveProperty("callId", "call-123");
    expect(apnsPayload).toHaveProperty("correlationId", correlationId);
    expect(apnsPayload).toHaveProperty("isVideo", true);
    expect(apnsPayload).not.toHaveProperty("connectionId");
    expect(apnsPayload).not.toHaveProperty("connection_id");
    expect(apnsPayload).not.toHaveProperty("pairedDeviceId");
    expect(apnsPayload).not.toHaveProperty("paired_device_id");
    expect(apnsPayload).not.toHaveProperty("displayName");
    expect(apnsPayload).not.toHaveProperty("display_name");

    // Verify Android FCM payload shape and privacy-preserving omissions.
    expect(fcmPayload).toHaveProperty("call_id", "call-123");
    expect(fcmPayload).toHaveProperty("correlation_id", correlationId);
    expect(fcmPayload).toHaveProperty("caller_name", "Incoming call"); // generic display name
    expect(fcmPayload).toHaveProperty("caller_initial", "I");
    expect(fcmPayload).not.toHaveProperty("connectionId");
    expect(fcmPayload).not.toHaveProperty("connection_id");
    expect(fcmPayload).not.toHaveProperty("pairedDeviceId");
    expect(fcmPayload).not.toHaveProperty("paired_device_id");
    expect(fcmPayload).not.toHaveProperty("displayName");
    expect(fcmPayload).not.toHaveProperty("display_name");
    expect(apnsPayload).toHaveProperty("uid", "user-123");
    expect(apnsPayload).toHaveProperty("expires_at_millis", "1700000100000");
    expect(fcmPayload).toHaveProperty("uid", "user-123");
    expect(fcmPayload).toHaveProperty("expires_at_millis", "1700000100000");
  });

  it("ephemeralCallCorrelationId returns a fresh UUID on every invocation", () => {
    const ids = Array.from({ length: 20 }, () => ephemeralCallCorrelationId());
    const unique = new Set(ids);
    expect(unique.size).toBe(ids.length);
    for (const id of ids) {
      expect(id).toMatch(/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i);
    }
  });
});
