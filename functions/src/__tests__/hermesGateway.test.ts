import { describe, expect, it } from "vitest";

import {
  clientAdvertisesModel,
  effectiveOversightMode,
  isHermesGatewayApprovalExpired,
  isHermesGatewayClientOnline,
  pendingModelSwitchInFlight,
  publicApprovalView,
  sanitizeHermesGatewayScopes,
  HERMES_GATEWAY_PRESENCE_WINDOW_MS,
} from "../hermesGateway.js";

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
});
