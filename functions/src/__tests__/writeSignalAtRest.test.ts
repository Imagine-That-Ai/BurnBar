import { describe, expect, it, vi } from "vitest";

process.env.ENFORCE_APP_CHECK = "false";

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
