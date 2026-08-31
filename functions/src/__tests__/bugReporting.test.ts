import { beforeEach, describe, expect, it, vi } from "vitest";

import { ALICE_UID, callableRunner, pathKeyedFirestore } from "./bola/callableBolaHarness.js";

const mocks = vi.hoisted(() => ({
  store: new Map<string, Record<string, unknown>>(),
  resilientFetch: vi.fn(async () => ({ ok: true, status: 200 })),
  createIssue: vi.fn(async (input: { title: string }) => ({
    id: "linear-issue-999",
    identifier: "BB-999",
    title: input.title,
    url: "https://linear.app/openburnbar/issue/BB-999",
    mock: true,
  })),
}));

vi.mock("../resilienceHelpers.js", () => ({
  resilientFetch: mocks.resilientFetch,
}));
vi.mock("../adminRuntime.js", () => ({ db: pathKeyedFirestore(mocks.store) }));
vi.mock("../config.js", () => ({
  getConfig: () => ({ enforceAppCheck: false }),
}));
vi.mock("../linear/linearClient.js", () => ({
  LinearClient: class {
    createIssue = mocks.createIssue;
    formatMarkdownDescription = vi.fn(() => "Formatted markdown");
  },
}));

import { submitBugReport, type SubmitBugReportResponse } from "../callables/bugReporting.js";

const run = callableRunner(submitBugReport);

function authed(data: Record<string, unknown>, uid = ALICE_UID) {
  return {
    auth: { uid, token: {} },
    app: { appId: "test-app" },
    rawRequest: { headers: {} },
    data,
  };
}

describe("submitBugReport callable", () => {
  beforeEach(() => {
    mocks.store.clear();
    vi.clearAllMocks();
  });

  it("rejects unauthenticated requests", async () => {
    await expect(
      run({
        data: { title: "Crash on startup", description: "Crashed immediately" },
        rawRequest: { headers: {} },
      }),
    ).rejects.toMatchObject({ code: "unauthenticated" });
  });

  it("rejects empty title or description", async () => {
    await expect(
      run(authed({ title: "   ", description: "Valid description" })),
    ).rejects.toMatchObject({ code: "invalid-argument" });

    await expect(
      run(authed({ title: "Valid title", description: "   " })),
    ).rejects.toMatchObject({ code: "invalid-argument" });
  });

  it("submits bug report, creates Linear issue, and queues CLI agent mission", async () => {
    const payload = {
      title: "Broken quota widget on macOS",
      description: "Widget shows 0% even with active Claude and Codex subscriptions.",
      platform: "macOS",
      appVersion: "1.2.0",
      osVersion: "macOS 15.3",
      deviceModel: "MacBookPro18,1",
      diagnostics: {
        activeProviders: ["claude", "codex"],
        secretApiKey: "super-secret-token",
        memoryMB: 120,
      },
      logsSnippet: "[ERROR] QuotaParser: invalid date format",
      requestedRuntime: "claude",
      autoDispenseCLI: true,
    };

    const res = (await run(authed(payload))) as SubmitBugReportResponse;
    expect(res.ok).toBe(true);
    expect(res.reportId).toMatch(/^rep_\d+_/);
    expect(res.linearIssue).toEqual({
      id: "linear-issue-999",
      identifier: "BB-999",
      url: "https://linear.app/openburnbar/issue/BB-999",
      mock: true,
    });
    expect(res.missionId).toBe(`mission_bug_${res.reportId}`);

    // Check Firestore bug_reports doc
    const reportDoc = mocks.store.get(`users/${ALICE_UID}/bug_reports/${res.reportId}`);
    expect(reportDoc).toBeDefined();
    expect(reportDoc?.title).toBe("Broken quota widget on macOS");
    expect(reportDoc?.platform).toBe("macOS");
    expect(reportDoc?.status).toBe("submitted");
    // Ensure sensitive fields were redacted
    const diag = reportDoc?.diagnostics as Record<string, unknown>;
    expect(diag?.secretApiKey).toBe("[REDACTED]");
    expect(diag?.memoryMB).toBe(120);

    // Check Firestore cli_agent_mission_requests doc
    const missionDoc = mocks.store.get(`users/${ALICE_UID}/cli_agent_mission_requests/${res.missionId!}`);
    expect(missionDoc).toBeDefined();
    expect(missionDoc?.missionKind).toBe("bug_investigation");
    expect(missionDoc?.requestedRuntime).toBe("claude");
    expect(missionDoc?.status).toBe("pending");
    expect(missionDoc?.title).toContain("[Bug BB-999] Broken quota widget on macOS");
    expect(missionDoc?.prompt).toContain("https://linear.app/openburnbar/issue/BB-999");
    expect(missionDoc?.prompt).toContain("Broken quota widget on macOS");
    expect(missionDoc?.prompt).toContain("QuotaParser: invalid date format");
    expect(missionDoc?.commandsAllowed).toBe(true);
    expect(missionDoc?.fileEditsAllowed).toBe(true);
  });

  it("respects autoDispenseCLI: false and does not queue a mission", async () => {
    const payload = {
      title: "Minor typo in settings",
      description: "Settings label has a misspelling.",
      platform: "iOS",
      autoDispenseCLI: false,
    };

    const res = (await run(authed(payload))) as SubmitBugReportResponse;
    expect(res.ok).toBe(true);
    expect(res.missionId).toBeUndefined();
    expect(mocks.store.get(`users/${ALICE_UID}/bug_reports/${res.reportId}`)).toBeDefined();
    expect(
      [...mocks.store.keys()].some((k) => k.includes("cli_agent_mission_requests")),
    ).toBe(false);
  });

  it("posts to Slack webhook when SLACK_BUG_REPORT_WEBHOOK is configured", async () => {
    process.env.SLACK_BUG_REPORT_WEBHOOK = "https://hooks.slack.com/services/T00/B00/X00";

    const payload = {
      title: "Critical quota freeze",
      description: "App freezes on opening quota dashboard.",
      platform: "macOS",
    };

    const res = (await run(authed(payload))) as SubmitBugReportResponse;
    expect(res.ok).toBe(true);
    expect(mocks.resilientFetch).toHaveBeenCalledWith(
      "slack:notifyBugReport",
      "https://hooks.slack.com/services/T00/B00/X00",
      expect.objectContaining({
        method: "POST",
        body: expect.stringContaining("Critical quota freeze"),
      }),
    );

    delete process.env.SLACK_BUG_REPORT_WEBHOOK;
  });
});
