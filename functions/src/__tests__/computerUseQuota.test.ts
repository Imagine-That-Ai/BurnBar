import { describe, expect, it } from "vitest";
import { Timestamp } from "firebase-admin/firestore";

import { __testing__ } from "../computerUseQuota.js";

describe("computer use quota recompute", () => {
  it("derives active-user uid from the session document path", () => {
    expect(__testing__.uidFromComputerUseSessionPath("users/alice-uid/computer_use_sessions/session-1")).toBe(
      "alice-uid",
    );
  });

  it("rejects malformed or non-session paths instead of trusting document fields", () => {
    expect(__testing__.uidFromComputerUseSessionPath("users/alice-uid/computer_use_actions/action-1")).toBeNull();
    expect(
      __testing__.uidFromComputerUseSessionPath("tenants/t1/users/alice-uid/computer_use_sessions/session-1"),
    ).toBeNull();
    expect(__testing__.uidFromComputerUseSessionPath("users//computer_use_sessions/session-1")).toBeNull();
  });

  it("derives active-user uid from action paths without trusting document fields", () => {
    expect(__testing__.uidFromComputerUseActionPath("users/alice-uid/computer_use_actions/action-1")).toBe("alice-uid");
    expect(__testing__.uidFromComputerUseActionPath("users/alice-uid/computer_use_sessions/session-1")).toBeNull();
    expect(__testing__.uidFromComputerUseActionPath("users//computer_use_actions/action-1")).toBeNull();
  });

  it("reconstructs action counters from immutable headers", () => {
    const counters = __testing__.emptyCounters("2026-07-10", new Date("2026-07-10T12:00:00Z"));
    __testing__.recordActionCounters(counters, {
      status: "executed",
      toolKind: "browser_click",
      approvedBy: "phone",
      visionTokensCostUSD: 0.25,
    });
    __testing__.recordActionCounters(counters, {
      status: "error",
      toolKind: "mac_input_click",
      approvedBy: "phone",
      visionTokensCostUSD: 900,
    });

    expect(counters.browserActionsExecuted).toBe(1);
    expect(counters.systemActionsRejected).toBe(1);
    expect(counters.phoneControlIntentsExecuted).toBe(0);
    expect(counters.phoneControlIntentsRejected).toBe(0);
    expect(counters.visionModelSpendUSD).toBe(25.25);
  });

  it("reconstructs completed session counters and clamps negative durations", () => {
    const counters = __testing__.emptyCounters("2026-07-10");
    __testing__.recordSessionCompletionCounters(counters, {
      startedAt: Timestamp.fromDate(new Date("2026-07-10T12:00:00Z")),
      endedAt: Timestamp.fromDate(new Date("2026-07-10T12:02:30Z")),
    });
    __testing__.recordSessionCompletionCounters(counters, {
      startedAt: Timestamp.fromDate(new Date("2026-07-10T13:00:00Z")),
      endedAt: Timestamp.fromDate(new Date("2026-07-10T12:59:00Z")),
    });

    expect(counters.sessionsCompleted).toBe(2);
    expect(counters.totalSessionSeconds).toBe(150);
  });
});
