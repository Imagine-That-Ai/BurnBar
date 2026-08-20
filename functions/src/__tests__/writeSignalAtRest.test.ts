import { describe, expect, it, vi } from "vitest";

process.env.ENFORCE_APP_CHECK = "false";

vi.mock("../adminRuntime.js", () => ({ db: { doc: () => ({ get: async () => ({ exists: false }) }) } }));
vi.mock("../config.js", () => ({
  getConfig: () => ({ enforceAppCheck: false }),
}));

import { callableRunner } from "./bola/callableBolaHarness.js";
import { writeSignalAtRestDocument } from "../callables/writeSignalAtRestDocument.js";

const run = callableRunner(writeSignalAtRestDocument);

function authed(data: Record<string, unknown>) {
  return {
    auth: { uid: "alice-bola-uid", token: {} },
    app: { appId: "test-app" },
    rawRequest: { headers: {} },
    data,
  };
}

describe("writeSignalAtRestDocument", () => {
  it("refuses a claimed mission without mutating it", async () => {
    const claimed = { id: "claimed-mission", status: "accepted", claimedBy: "mac-1" };
    await expect(
      run(
        authed({
          collection: "cli_agent_mission_requests",
          docId: "claimed-mission",
          data: { ...claimed, status: "failed", claimedBy: "attacker" },
        }),
      ),
    ).rejects.toMatchObject({
      code: "failed-precondition",
      message: expect.stringMatching(/createCliAgentMission/),
    });
  });

  it("refuses cli_agent_mission_requests in favor of createCliAgentMission", async () => {
    await expect(
      run(
        authed({
          collection: "cli_agent_mission_requests",
          docId: "live-mission",
          data: { id: "live-mission", status: "pending" },
        }),
      ),
    ).rejects.toMatchObject({
      code: "failed-precondition",
      message: expect.stringMatching(/createCliAgentMission/),
    });
  });

  it("still requires authentication", async () => {
    await expect(
      run({
        auth: undefined,
        app: { appId: "test-app" },
        rawRequest: { headers: {} },
        data: { collection: "cli_agent_mission_requests", docId: "x" },
      }),
    ).rejects.toMatchObject({ code: "unauthenticated" });
  });
});
