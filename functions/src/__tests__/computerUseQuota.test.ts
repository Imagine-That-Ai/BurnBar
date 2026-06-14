import { describe, expect, it } from "vitest";

import { __testing__ } from "../computerUseQuota.js";

describe("computer use quota recompute", () => {
  it("derives active-user uid from the session document path", () => {
    expect(__testing__.uidFromComputerUseSessionPath("users/alice-uid/computer_use_sessions/session-1")).toBe(
      "alice-uid",
    );
  });

  it("rejects malformed or non-session paths instead of trusting document fields", () => {
    expect(__testing__.uidFromComputerUseSessionPath("users/alice-uid/computer_use_actions/action-1")).toBeNull();
    expect(__testing__.uidFromComputerUseSessionPath("tenants/t1/users/alice-uid/computer_use_sessions/session-1")).toBeNull();
    expect(__testing__.uidFromComputerUseSessionPath("users//computer_use_sessions/session-1")).toBeNull();
  });
});
