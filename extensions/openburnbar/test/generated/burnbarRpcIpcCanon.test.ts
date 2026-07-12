import { describe, expect, it } from "vitest";

import { burnBarRpcIpcCanon } from "../../src/generated/burnbar-rpc-ipc-canon.generated.js";

describe("burnBarRpcIpcCanon generated table", () => {
  it("includes the mission remote authorization RPC", () => {
    expect(burnBarRpcIpcCanon).toContainEqual({
      id: "daemon.mission.authorizeRemote",
      caseName: "missionAuthorizeRemote",
      domain: "mission_control",
      capability: "mission_control",
      owner: "OpenBurnBarDaemon",
      params: "BurnBarRPCRequestEnvelopeWithParams<Codable request>",
      result: "Codable response for daemon.mission.authorizeRemote",
      error: "BurnBarRPCError",
    });
  });
});
