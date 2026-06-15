import { describe, expect, it } from "vitest";

import {
  clientAdvertisesModel,
  effectiveOversightMode,
  isGatewayRelayPublicKeyB64,
  isHermesGatewayApprovalExpired,
  isHermesGatewayClientOnline,
  isHermesGatewayTokenExpired,
  pendingModelSwitchInFlight,
  publicApprovalView,
  sanitizeHermesGatewayApprovalTTL,
  sanitizeHermesGatewayScopes,
  serializeHermesGatewayTypingDoc,
  shouldCoalesceHermesGatewayLastSeen,
  HERMES_GATEWAY_APPROVAL_TTL_MS,
  HERMES_GATEWAY_LAST_SEEN_COALESCE_MS,
  HERMES_GATEWAY_MIN_APPROVAL_TTL_MS,
  HERMES_GATEWAY_PRESENCE_WINDOW_MS,
  HERMES_GATEWAY_PROTOCOL_VERSION,
  HERMES_GATEWAY_RELAY_ENCRYPTION,
  HERMES_GATEWAY_SCHEMA_VERSION,
} from "../hermesGateway.js";

import { RELAY_PUBKEY_B64 } from "./hermesGatewayTestKit.js";

describe("Hermes Gateway helper contracts", () => {
  it("defaults to read/write without manage scope", () => {
    expect(sanitizeHermesGatewayScopes(undefined)).toEqual(["hermes.gateway.read", "hermes.gateway.write"]);
  });

  it("preserves explicit manage scope when the approval flow requests it", () => {
    expect(sanitizeHermesGatewayScopes(["hermes.gateway.read", "hermes.gateway.manage", "not-a-real-scope"])).toEqual([
      "hermes.gateway.read",
      "hermes.gateway.manage",
    ]);
  });
});

describe("Hermes Gateway runtime-state presence (feature 1)", () => {
  const now = Date.parse("2026-06-01T00:01:30.000Z");
  it("is online within the presence window and offline past it", () => {
    expect(isHermesGatewayClientOnline("2026-06-01T00:01:00.000Z", now)).toBe(true);
    expect(isHermesGatewayClientOnline("2026-06-01T00:00:00.000Z", now)).toBe(true);
    expect(isHermesGatewayClientOnline("2026-06-01T00:00:00.000Z", now + 1)).toBe(false);
  });
  it("fails closed to OFFLINE for a stopped/garbage gateway (never fakes online)", () => {
    expect(isHermesGatewayClientOnline(undefined, now)).toBe(false);
    expect(isHermesGatewayClientOnline("", now)).toBe(false);
    expect(isHermesGatewayClientOnline("nope", now)).toBe(false);
    expect(HERMES_GATEWAY_PRESENCE_WINDOW_MS).toBe(90_000);
  });
});

describe("Hermes Gateway lastSeenAt write coalescing", () => {
  const now = Date.parse("2026-06-01T00:01:30.000Z");
  it("skips the bump while lastSeenAt is fresh and resumes at the coalesce boundary", () => {
    expect(shouldCoalesceHermesGatewayLastSeen("2026-06-01T00:01:30.000Z", now)).toBe(true);
    expect(shouldCoalesceHermesGatewayLastSeen("2026-06-01T00:01:29.000Z", now)).toBe(true);
    expect(shouldCoalesceHermesGatewayLastSeen("2026-06-01T00:01:01.000Z", now)).toBe(true);
    expect(shouldCoalesceHermesGatewayLastSeen("2026-06-01T00:01:00.000Z", now)).toBe(false);
    expect(shouldCoalesceHermesGatewayLastSeen("2026-06-01T00:00:00.000Z", now)).toBe(false);
  });
  it("fails open to WRITING on missing, garbage, or future timestamps (self-repairs)", () => {
    expect(shouldCoalesceHermesGatewayLastSeen(undefined, now)).toBe(false);
    expect(shouldCoalesceHermesGatewayLastSeen("", now)).toBe(false);
    expect(shouldCoalesceHermesGatewayLastSeen("nope", now)).toBe(false);
    expect(shouldCoalesceHermesGatewayLastSeen("2026-06-01T00:01:31.000Z", now)).toBe(false);
  });
  it("never flips a fast poller offline: coalesce interval keeps a 2x presence margin", () => {
    // Worst-case staleness for a poller faster than the coalesce interval is
    // just under 2x the interval; presence must still read online there.
    expect(HERMES_GATEWAY_LAST_SEEN_COALESCE_MS * 3).toBeLessThanOrEqual(HERMES_GATEWAY_PRESENCE_WINDOW_MS);
    expect(
      isHermesGatewayClientOnline("2026-06-01T00:01:30.000Z", now + 2 * HERMES_GATEWAY_LAST_SEEN_COALESCE_MS),
    ).toBe(true);
  });
});

describe("Hermes Gateway model switching (feature 2)", () => {
  const client = {
    runtimeModelOptions: [
      { providerId: "hermes", providerName: "Hermes", modelId: "minimax-m2.7-highspeed", displayName: "MiniMax" },
    ],
  };
  it("validates a requested model against the advertised catalog (case-insensitive)", () => {
    expect(clientAdvertisesModel(client, "MiniMax-M2.7-Highspeed")).toBe(true);
    expect(clientAdvertisesModel(client, "gpt-5")).toBe(false);
    expect(clientAdvertisesModel({ runtimeModelOptions: [] }, "x")).toBe(false);
  });
  it("settles the pending marker once the runtime reports the applied model", () => {
    const at = "2026-06-01T00:00:00.000Z";
    const t = Date.parse("2026-06-01T00:00:30.000Z");
    expect(
      pendingModelSwitchInFlight({ pendingModelId: "m", pendingModelRequestedAt: at, runtimeModelId: "old" }, t),
    ).toBe(true);
    expect(
      pendingModelSwitchInFlight({ pendingModelId: "m", pendingModelRequestedAt: at, runtimeModelId: "M" }, t),
    ).toBe(false);
  });
});

describe("Hermes Gateway oversight (feature 3)", () => {
  it("defaults to the safe option (supervised) when unset/invalid", () => {
    expect(effectiveOversightMode(undefined)).toBe("supervised");
    expect(effectiveOversightMode("bogus")).toBe("supervised");
    expect(effectiveOversightMode("autonomous")).toBe("autonomous");
  });
  it("fails closed on expiry so an unanswered gate never blocks forever", () => {
    expect(isHermesGatewayApprovalExpired(undefined)).toBe(true);
    expect(isHermesGatewayApprovalExpired("2000-01-01T00:00:00.000Z")).toBe(true);
    expect(isHermesGatewayApprovalExpired(new Date(Date.now() + 60_000).toISOString())).toBe(false);
  });
  it("derives an expired status in the public view for a stale waiting gate", () => {
    const gate = {
      id: "g",
      clientId: "c",
      destinationId: "d",
      actionId: "a",
      summary: "s",
      status: "waiting_for_approval" as const,
      requestedAt: "2026-06-01T00:00:00.000Z",
      expiresAt: "2000-01-01T00:00:00.000Z",
      schemaVersion: 1,
    };
    expect(publicApprovalView(gate).status).toBe("expired");
  });
  it("bounds optional short live-proof TTLs without changing the production default", () => {
    expect(sanitizeHermesGatewayApprovalTTL(undefined)).toBe(HERMES_GATEWAY_APPROVAL_TTL_MS);
    expect(sanitizeHermesGatewayApprovalTTL("bad")).toBe(HERMES_GATEWAY_APPROVAL_TTL_MS);
    expect(sanitizeHermesGatewayApprovalTTL(1)).toBe(HERMES_GATEWAY_MIN_APPROVAL_TTL_MS);
    expect(sanitizeHermesGatewayApprovalTTL(30)).toBe(30_000);
    expect(sanitizeHermesGatewayApprovalTTL(60 * 60)).toBe(HERMES_GATEWAY_APPROVAL_TTL_MS);
  });
});

describe("Hermes Gateway bearer token expiry", () => {
  it("treats missing legacy expiresAt as expired", () => {
    expect(isHermesGatewayTokenExpired(undefined)).toBe(true);
    expect(isHermesGatewayTokenExpired("")).toBe(true);
    expect(isHermesGatewayTokenExpired("2000-01-01T00:00:00.000Z")).toBe(true);
    expect(isHermesGatewayTokenExpired(new Date(Date.now() + 60_000).toISOString())).toBe(false);
  });
});

describe("Hermes Gateway E2EE — schema/protocol bump (gateway-wire)", () => {
  it("bumps both versions to 2 so /state advertises the sealed contract", () => {
    expect(HERMES_GATEWAY_SCHEMA_VERSION).toBe(2);
    expect(HERMES_GATEWAY_PROTOCOL_VERSION).toBe(2);
    expect(HERMES_GATEWAY_RELAY_ENCRYPTION).toBe("p256-hkdf-sha256-aesgcm");
  });
});

describe("serializeHermesGatewayTypingDoc", () => {
  it("stores typing presence without private thread routing metadata", () => {
    const doc = serializeHermesGatewayTypingDoc({
      clientId: "hgw_abc",
      destinationId: "burnbar:home",
      createdAt: "2026-06-01T00:00:00.000Z",
      expiresAt: "2026-06-01T00:00:15.000Z",
    });

    expect(doc).toMatchObject({
      id: "hgw_abc",
      clientId: "hgw_abc",
      kind: "typing",
      destinationId: "burnbar:home",
      schemaVersion: HERMES_GATEWAY_SCHEMA_VERSION,
    });
    expect(doc).not.toHaveProperty("threadId");
  });
});

describe("isGatewayRelayPublicKeyB64", () => {
  it("accepts a base64 X9.63 uncompressed P-256 key (65 bytes, 0x04)", () => {
    expect(isGatewayRelayPublicKeyB64(RELAY_PUBKEY_B64)).toBe(RELAY_PUBKEY_B64);
  });
  it("rejects the wrong length, the wrong point format, and non-base64", () => {
    // 64 bytes (too short).
    expect(isGatewayRelayPublicKeyB64(Buffer.alloc(64, 4).toString("base64"))).toBeUndefined();
    // 65 bytes but first byte is not 0x04 (not uncompressed).
    expect(
      isGatewayRelayPublicKeyB64(Buffer.concat([Buffer.from([0x02]), Buffer.alloc(64, 1)]).toString("base64")),
    ).toBeUndefined();
    expect(isGatewayRelayPublicKeyB64("not base64 !!")).toBeUndefined();
    expect(isGatewayRelayPublicKeyB64(undefined)).toBeUndefined();
    expect(isGatewayRelayPublicKeyB64("")).toBeUndefined();
  });
});
