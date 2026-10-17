import { createHmac } from "node:crypto";
import { describe, expect, it } from "vitest";
import {
  ATTRIBUTE_NAMES,
  EDGE_CONTRACT_ID,
  SUPPORTED_EVENT_TYPES,
  parseAfarEvent,
  parseLinqAfarEdgeConfig,
  type LinqAfarEdgeConfig,
} from "../domains/linq/afarEdgeContract.js";
import {
  buildEdgeAttributes,
  formatReceivedAt,
  isFresh,
  readWebhookHeaders,
  verifySignature,
  type WebhookHeaders,
} from "../domains/linq/standardWebhooks.js";

// Reference vector published with the Standard Webhooks specification.
const SPEC_SECRET = "whsec_MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw";
const SPEC_HEADERS: WebhookHeaders = {
  id: "msg_p5jXN8AQM9LWM0D4loKWxJek",
  timestamp: "1614265330",
  signature: "v1,g0hM9SsE+OTPJTGt/tmIKtSyZlE3uFJELVlNIOLJ1OE=",
};
const SPEC_BODY = Buffer.from('{"test": 2432232314}', "utf8");
const LINE = "+14155550100";

function config(overrides: Record<string, unknown> = {}): LinqAfarEdgeConfig {
  const result = parseLinqAfarEdgeConfig({
    topic: "projects/burnbar-test/topics/linq-afar",
    signingSecret: SPEC_SECRET,
    approvedLines: [LINE],
    ...overrides,
  });
  if (!result.ok) throw new Error(result.error);
  return result.config;
}

function sign(key: Buffer, id: string, timestamp: string, body: Buffer): string {
  return createHmac("sha256", key).update(`${id}.${timestamp}.`).update(body).digest("base64");
}

function event(fields: Record<string, unknown>): Buffer {
  return Buffer.from(
    JSON.stringify({ event_id: "evt_1", webhook_version: "2026-02-03", created_at: "2026-10-17T01:20:00Z", data: {}, ...fields }),
    "utf8",
  );
}

describe("Standard Webhooks signature", () => {
  const key = config().signingKey;

  it("accepts the specification reference vector", () => {
    expect(verifySignature(SPEC_HEADERS, SPEC_BODY, key)).toBe(true);
  });

  it("rejects one changed body byte, id or timestamp", () => {
    expect(verifySignature(SPEC_HEADERS, Buffer.from('{"test": 2432232315}'), key)).toBe(false);
    expect(verifySignature({ ...SPEC_HEADERS, id: "msg_p5jXN8AQM9LWM0D4loKWxJel" }, SPEC_BODY, key)).toBe(false);
    expect(verifySignature({ ...SPEC_HEADERS, timestamp: "1614265331" }, SPEC_BODY, key)).toBe(false);
  });

  it("accepts any matching v1 entry during secret rotation and ignores other versions", () => {
    const rotated = `v1,${Buffer.alloc(32, 7).toString("base64")} v1a,abc ${SPEC_HEADERS.signature}`;
    expect(verifySignature({ ...SPEC_HEADERS, signature: rotated }, SPEC_BODY, key)).toBe(true);
    expect(verifySignature({ ...SPEC_HEADERS, signature: "v1a,g0hM9SsE+OTPJTGt/tmIKtSyZlE3uFJELVlNIOLJ1OE=" }, SPEC_BODY, key)).toBe(false);
  });

  it("rejects truncated or non-canonical base64", () => {
    expect(verifySignature({ ...SPEC_HEADERS, signature: "v1,g0hM9SsE+OTPJTGt/tmIKtSyZlE3uFJELVlNIOLJ1OE" }, SPEC_BODY, key)).toBe(false);
    expect(verifySignature({ ...SPEC_HEADERS, signature: "v1,g0hM9SsE+OTPJTGt/tmIKtSyZlE3uFJELVlNIOLJ1O" }, SPEC_BODY, key)).toBe(false);
  });

  it("signs ids that contain periods, as the canonical pattern allows", () => {
    const id = "msg.with.dots";
    const signature = `v1,${sign(key, id, SPEC_HEADERS.timestamp, SPEC_BODY)}`;
    expect(verifySignature({ id, timestamp: SPEC_HEADERS.timestamp, signature }, SPEC_BODY, key)).toBe(true);
  });
});

describe("freshness", () => {
  const ts = 1_792_000_000;
  it("allows exactly ±300 s and rejects beyond", () => {
    expect(isFresh(String(ts), (ts + 300) * 1000 + 999)).toBe(true);
    expect(isFresh(String(ts), (ts - 300) * 1000)).toBe(true);
    expect(isFresh(String(ts), (ts + 301) * 1000)).toBe(false);
    expect(isFresh(String(ts), (ts - 301) * 1000)).toBe(false);
  });
});

describe("header bounds", () => {
  const base = ["webhook-id", "msg_1", "webhook-timestamp", "1792000000", "webhook-signature", "v1,AAAA"];

  it("reads the three headers case-insensitively", () => {
    const result = readWebhookHeaders(["Webhook-Id", "msg_1", "WEBHOOK-TIMESTAMP", "1792000000", "Webhook-Signature", "v1,AAAA"]);
    expect(result).toEqual({ ok: true, headers: { id: "msg_1", timestamp: "1792000000", signature: "v1,AAAA" } });
  });

  it("rejects duplicates, missing headers and out-of-bound values", () => {
    expect(readWebhookHeaders([...base, "webhook-id", "msg_2"]).ok).toBe(false);
    expect(readWebhookHeaders(base.slice(0, 4)).ok).toBe(false);
    const withValue = (name: string, value: string) => base.map((item, index) => (index > 0 && base[index - 1] === name ? value : item));
    expect(readWebhookHeaders(withValue("webhook-id", "x".repeat(256))).ok).toBe(true);
    expect(readWebhookHeaders(withValue("webhook-id", "x".repeat(257))).ok).toBe(false);
    expect(readWebhookHeaders(withValue("webhook-id", "msg 1")).ok).toBe(false);
    expect(readWebhookHeaders(withValue("webhook-id", "msgé1")).ok).toBe(false);
    expect(readWebhookHeaders(withValue("webhook-id", "msg\u00011")).ok).toBe(false);
    expect(readWebhookHeaders(withValue("webhook-timestamp", "1".repeat(12))).ok).toBe(true);
    expect(readWebhookHeaders(withValue("webhook-timestamp", "1".repeat(13))).ok).toBe(false);
    expect(readWebhookHeaders(withValue("webhook-timestamp", "-1")).ok).toBe(false);
    expect(readWebhookHeaders(withValue("webhook-signature", `v1,${"A".repeat(1021)}`)).ok).toBe(true);
    expect(readWebhookHeaders(withValue("webhook-signature", `v1,${"A".repeat(1022)}`)).ok).toBe(false);
    expect(readWebhookHeaders(withValue("webhook-signature", "v1,a  v1,b")).ok).toBe(false);
  });
});

describe("edge attributes", () => {
  it("publishes exactly the five contract attributes with a strict ISO millisecond receipt time", () => {
    const result = buildEdgeAttributes(SPEC_HEADERS, Date.UTC(2026, 9, 17, 1, 20, 1, 0));
    if (!result.ok) throw new Error(result.reason);
    expect(Object.keys(result.attributes)).toEqual([...ATTRIBUTE_NAMES]);
    expect(result.attributes["edge-contract"]).toBe(EDGE_CONTRACT_ID);
    expect(result.attributes["edge-received-at"]).toBe("2026-10-17T01:20:01.000Z");
    expect(result.attributes["edge-received-at"]).toMatch(/^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{3}Z$/);
    expect(formatReceivedAt(0)).toBe("1970-01-01T00:00:00.000Z");
  });

  it("stays within 1536 bytes at the largest allowed header values", () => {
    const result = buildEdgeAttributes({ id: "x".repeat(256), timestamp: "9".repeat(12), signature: "v".repeat(1024) }, 0);
    expect(result.ok).toBe(true);
  });
});

describe("configuration", () => {
  it("rejects incomplete or invalid bindings with no defaults", () => {
    expect(parseLinqAfarEdgeConfig(null).ok).toBe(false);
    expect(parseLinqAfarEdgeConfig({}).ok).toBe(false);
    expect(parseLinqAfarEdgeConfig({ topic: "linq-afar", signingSecret: SPEC_SECRET, approvedLines: [LINE] }).ok).toBe(false);
    expect(parseLinqAfarEdgeConfig({ topic: "projects/burnbar-test/topics/linq-afar", signingSecret: "MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw", approvedLines: [LINE] }).ok).toBe(false);
    expect(parseLinqAfarEdgeConfig({ topic: "projects/burnbar-test/topics/linq-afar", signingSecret: "whsec_c2hvcnQ=", approvedLines: [LINE] }).ok).toBe(false);
    expect(parseLinqAfarEdgeConfig({ topic: "projects/burnbar-test/topics/linq-afar", signingSecret: SPEC_SECRET, approvedLines: [] }).ok).toBe(false);
    expect(parseLinqAfarEdgeConfig({ topic: "projects/burnbar-test/topics/linq-afar", signingSecret: SPEC_SECRET, approvedLines: ["4155550100"] }).ok).toBe(false);
    expect(parseLinqAfarEdgeConfig({ topic: "projects/burnbar-test/topics/linq-afar", signingSecret: SPEC_SECRET, approvedLines: [LINE, LINE] }).ok).toBe(false);
  });
});

describe("signed body scope", () => {
  const cfg = config();
  const chat = (handle: unknown) => ({ chat: { owner_handle: { handle } } });

  it("supports exactly the thirteen frozen event types", () => {
    expect(SUPPORTED_EVENT_TYPES).toHaveLength(13);
  });

  it.each(["message.received", "message.sent", "message.delivered", "message.read", "message.edited", "chat.background_updated"])(
    "%s is scoped to the chat owner's line",
    (type) => {
      expect(parseAfarEvent(event({ event_type: type, data: chat(LINE) }), cfg)).toEqual({
        kind: "accepted",
        eventId: "evt_1",
        eventType: type,
        scopeKey: `line:${LINE}`,
      });
      expect(parseAfarEvent(event({ event_type: type, data: chat("+14155550199") }), cfg).kind).toBe("unbound");
      expect(parseAfarEvent(event({ event_type: type, data: chat("4155550100") }), cfg).kind).toBe("malformed");
      expect(parseAfarEvent(event({ event_type: type, data: {} }), cfg).kind).toBe("malformed");
    },
  );

  it("phone_number.status_updated is scoped to the E.164 string in data.phone_number", () => {
    expect(parseAfarEvent(event({ event_type: "phone_number.status_updated", data: { phone_number: LINE } }), cfg)).toMatchObject({
      kind: "accepted",
      scopeKey: `line:${LINE}`,
    });
    expect(parseAfarEvent(event({ event_type: "phone_number.status_updated", data: { phone_number: { number: LINE } } }), cfg).kind).toBe("malformed");
    expect(parseAfarEvent(event({ event_type: "phone_number.status_updated", data: { phone_number: "+14155550199" } }), cfg).kind).toBe("unbound");
  });

  it.each(["message.failed", "reaction.added", "reaction.removed", "chat.background_update_failed", "api_token.expiry_scheduled", "api_token.expired"])(
    "%s is product scope with no invented line",
    (type) => {
      expect(parseAfarEvent(event({ event_type: type, data: chat("+19995550000") }), cfg)).toMatchObject({ kind: "accepted", scopeKey: "product" });
    },
  );

  it("enforces the envelope fields", () => {
    const ok = { event_type: "message.failed" };
    expect(parseAfarEvent(event(ok), cfg).kind).toBe("accepted");
    expect(parseAfarEvent(event({ ...ok, api_version: "v3" }), cfg).kind).toBe("accepted");
    expect(parseAfarEvent(event({ ...ok, api_version: "v2" }), cfg).kind).toBe("malformed");
    expect(parseAfarEvent(event({ ...ok, webhook_version: "2025-01-01" }), cfg).kind).toBe("malformed");
    expect(parseAfarEvent(event({ ...ok, event_type: "message.deleted" }), cfg).kind).toBe("malformed");
    expect(parseAfarEvent(event({ ...ok, event_id: "" }), cfg).kind).toBe("malformed");
    expect(parseAfarEvent(event({ ...ok, event_id: "é".repeat(128) }), cfg).kind).toBe("accepted");
    expect(parseAfarEvent(event({ ...ok, event_id: "é".repeat(129) }), cfg).kind).toBe("malformed");
    expect(parseAfarEvent(event({ ...ok, data: [] }), cfg).kind).toBe("malformed");
    expect(parseAfarEvent(event({ ...ok, created_at: "" }), cfg).kind).toBe("malformed");
    // created_at format belongs to the Node adapter; any non-empty string passes the edge.
    expect(parseAfarEvent(event({ ...ok, created_at: "yesterday" }), cfg).kind).toBe("accepted");
    expect(parseAfarEvent(Buffer.from("[]"), cfg).kind).toBe("malformed");
    expect(parseAfarEvent(Buffer.from("{"), cfg).kind).toBe("malformed");
    expect(parseAfarEvent(Buffer.from([0x7b, 0xff, 0x7d]), cfg).kind).toBe("malformed");
  });
});
