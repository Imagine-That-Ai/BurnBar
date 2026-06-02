import { describe, expect, it } from "vitest";

import { sanitizeHermesGatewayScopes } from "../hermesGateway.js";

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
