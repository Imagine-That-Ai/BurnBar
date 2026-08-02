import { randomBytes } from "node:crypto";

import { describe, expect, it } from "vitest";

import { base32NoPad } from "./irohControllerRouteTestSupport.js";
import { requireIrohTransportNodeId } from "../callables/irohControllerRouteSecurity.js";

describe("iroh controller route NodeId normalization", () => {
  it("normalizes legacy base32 NodeIds to current lowercase-hex iroh identity", () => {
    const publicKey = randomBytes(32);
    const legacyNodeId = base32NoPad(publicKey);
    expect(requireIrohTransportNodeId(legacyNodeId)).toMatchObject({
      nodeId: publicKey.toString("hex"),
      wireNodeId: legacyNodeId,
      publicKey,
    });
  });
});
