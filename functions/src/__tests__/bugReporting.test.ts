import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import type { LinearCreateIssueResult } from "../../../functions-sync/src/linear/linearClient.js";
import { ALICE_UID, callableRunner, pathKeyedFirestore } from "./bola/callableBolaHarness.js";

const mocks = vi.hoisted(() => ({
  store: new Map<string, Record<string, unknown>>(),
  resilientFetch: vi.fn(async (_name: string, _url: string, _init?: { body?: string }) => ({ ok: true, status: 200 })),
  createIssue: vi.fn(
    async (input: { title: string }): Promise<LinearCreateIssueResult> => ({
      status: "created",
      id: "linear-issue-999",
      identifier: "BB-999",
      title: input.title,
      url: "https://linear.app/openburnbar/issue/BB-999",
    }),
  ),
}));

const defaultCreateIssue = async (input: { title: string }) => ({
  status: "created" as const,
  id: "linear-issue-999",
  identifier: "BB-999",
  title: input.title,
  url: "https://linear.app/openburnbar/issue/BB-999",
});

vi.mock("../../../packages/functions-shared/src/resilienceHelpers.js", () => ({
  resilientFetch: mocks.resilientFetch,
}));
vi.mock("../../../packages/functions-shared/src/adminRuntime.js", () => ({ db: pathKeyedFirestore(mocks.store) }));
vi.mock("../../../packages/functions-shared/src/config.js", () => ({
  getConfig: () => ({ enforceAppCheck: false }),
}));
vi.mock("../../../functions-sync/src/linear/linearClient.js", () => ({
  LinearClient: class {
    createIssue = mocks.createIssue;
    formatMarkdownDescription = vi.fn(() => "Formatted markdown");
  },
}));

import { submitBugReport } from "../../../functions-sync/src/domains/support/bugReporting.js";

const run = callableRunner(submitBugReport);

function isRecord(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function expectBugReportResult(value: unknown): asserts value is {
  ok: true;
  reportId: string;
  linearIssue: unknown;
  linearStatus: string;
  missionId?: string;
} {
  if (!isRecord(value) || value.ok !== true || typeof value.reportId !== "string") {
    throw new Error("expected submitBugReport result");
  }
}

function authed(data: Record<string, unknown>, uid = ALICE_UID) {
  return {
    auth: { uid, token: {} },
    app: { appId: "test-app" },
    rawRequest: { headers: {} },
    data,
  };
}

const VALID_PAYLOAD = {
  title: "Broken quota widget on macOS",
  description: "Widget shows 0% even with active Claude and Codex subscriptions.",
  platform: "macOS",
};

function bugReportDocPaths(): string[] {
  return [...mocks.store.keys()].filter((k) => k.includes("/bug_reports/"));
}

function missionDocPaths(): string[] {
  return [...mocks.store.keys()].filter((k) => k.includes("cli_agent_mission_requests"));
}

function slackBodies(): string[] {
  return mocks.resilientFetch.mock.calls
    .filter(([name]) => name === "slack:notifyBugReport")
    .map(([, , init]) => String(init?.body ?? ""));
}

describe("submitBugReport callable", () => {
  beforeEach(() => {
    mocks.store.clear();
    vi.clearAllMocks();
    mocks.createIssue.mockImplementation(defaultCreateIssue);
  });
  afterEach(() => vi.useRealTimers());

  it("rejects unauthenticated requests", async () => {
    await expect(
      run({
        data: { title: "Crash on startup", description: "Crashed immediately" },
        rawRequest: { headers: {} },
      }),
    ).rejects.toMatchObject({ code: "unauthenticated" });
    expect(mocks.createIssue).not.toHaveBeenCalled();
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

    const res = await run(authed(payload));
    expectBugReportResult(res);
    expect(res.ok).toBe(true);
    expect(res.reportId).toMatch(/^rep_\d+_/);
    expect(res.linearIssue).toEqual({
      id: "linear-issue-999",
      identifier: "BB-999",
      url: "https://linear.app/openburnbar/issue/BB-999",
    });
    expect(res.linearStatus).toBe("created");
    expect(res.missionId).toBe(`mission_bug_${res.reportId}`);
    const missionId = res.missionId;
    expect(missionId).toEqual(expect.stringMatching(/^mission_bug_/));

    // Check Firestore bug_reports doc
    const reportDoc = mocks.store.get(`users/${ALICE_UID}/bug_reports/${res.reportId}`);
    expect(reportDoc).toBeDefined();
    expect(reportDoc?.title).toBe("Broken quota widget on macOS");
    expect(reportDoc?.platform).toBe("macOS");
    expect(reportDoc?.status).toBe("submitted");
    expect(reportDoc?.linearStatus).toBe("created");
    expect(reportDoc?.linearIssue).toEqual({
      id: "linear-issue-999",
      identifier: "BB-999",
      url: "https://linear.app/openburnbar/issue/BB-999",
    });
    // Ensure sensitive fields were redacted
    expect(JSON.stringify(reportDoc?.diagnostics)).toContain('"secretApiKey":"[REDACTED]"');
    expect(JSON.stringify(reportDoc?.diagnostics)).toContain('"memoryMB":120');

    // Check Firestore cli_agent_mission_requests doc
    const missionDoc = mocks.store.get(`users/${ALICE_UID}/cli_agent_mission_requests/${missionId}`);
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

    const res = await run(authed(payload));
    expectBugReportResult(res);
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

    const res = await run(authed(payload));
    expectBugReportResult(res);
    expect(res.ok).toBe(true);
    expect(mocks.resilientFetch).toHaveBeenCalledWith(
      "slack:notifyBugReport",
      "https://hooks.slack.com/services/T00/B00/X00",
      expect.objectContaining({
        method: "POST",
        body: expect.stringContaining("Critical quota freeze"),
      }),
    );
    expect(slackBodies()[0]).toContain("<https://linear.app/openburnbar/issue/BB-999|BB-999>");

    delete process.env.SLACK_BUG_REPORT_WEBHOOK;
  });

  it("files an honest report when Linear is unconfigured — no fabricated identifier anywhere", async () => {
    mocks.createIssue.mockImplementation(async () => ({ status: "unconfigured" as const }));
    process.env.SLACK_BUG_REPORT_WEBHOOK = "https://hooks.slack.com/services/T00/B00/X00";

    const res = await run(authed({ ...VALID_PAYLOAD, autoDispenseCLI: true }));
    expectBugReportResult(res);
    expect(res.ok).toBe(true);
    expect(res.linearIssue).toBeNull();
    expect(res.linearStatus).toBe("unconfigured");

    const reportDoc = mocks.store.get(`users/${ALICE_UID}/bug_reports/${res.reportId}`);
    expect(reportDoc).toBeDefined();
    expect(reportDoc?.linearIssue).toBeNull();
    expect(reportDoc?.linearStatus).toBe("unconfigured");
    expect(reportDoc?.linearError).toBeNull();

    // The mission still queues — titled by reportId, with no Linear line.
    const missionDoc = mocks.store.get(
      `users/${ALICE_UID}/cli_agent_mission_requests/mission_bug_${res.reportId}`,
    );
    expect(missionDoc).toBeDefined();
    expect(missionDoc?.title).toBe(`[Bug ${res.reportId}] Broken quota widget on macOS`);
    expect(missionDoc?.linearIssue).toBeNull();
    const prompt = String(missionDoc?.prompt);
    expect(prompt).toContain(res.reportId);
    expect(prompt).not.toContain("linear.app");
    expect(prompt).not.toContain("Linear Key");
    expect(prompt).not.toMatch(/BB-\d+/);

    // Slack says the report was not filed to Linear instead of linking a fake issue.
    const body = slackBodies()[0];
    expect(body).toContain("*Linear:* not filed (unconfigured)");
    expect(body).not.toContain("linear.app");

    delete process.env.SLACK_BUG_REPORT_WEBHOOK;
  });

  it("files an honest report when Linear fails — linearStatus failed, no fabricated identifier", async () => {
    mocks.createIssue.mockImplementation(async () => ({
      status: "failed" as const,
      error: "GraphQL 502 bad gateway",
    }));
    process.env.SLACK_BUG_REPORT_WEBHOOK = "https://hooks.slack.com/services/T00/B00/X00";

    const res = await run(authed({ ...VALID_PAYLOAD, autoDispenseCLI: true }));
    expectBugReportResult(res);
    expect(res.ok).toBe(true);
    expect(res.linearIssue).toBeNull();
    expect(res.linearStatus).toBe("failed");

    const reportDoc = mocks.store.get(`users/${ALICE_UID}/bug_reports/${res.reportId}`);
    expect(reportDoc?.linearIssue).toBeNull();
    expect(reportDoc?.linearStatus).toBe("failed");
    expect(reportDoc?.linearError).toBe("GraphQL 502 bad gateway");

    const missionDoc = mocks.store.get(
      `users/${ALICE_UID}/cli_agent_mission_requests/mission_bug_${res.reportId}`,
    );
    expect(missionDoc).toBeDefined();
    expect(missionDoc?.title).toBe(`[Bug ${res.reportId}] Broken quota widget on macOS`);
    expect(String(missionDoc?.prompt)).not.toContain("linear.app");
    expect(String(missionDoc?.prompt)).not.toMatch(/BB-(?:\d+|FALLBACK)/);

    const body = slackBodies()[0];
    expect(body).toContain("*Linear:* not filed (failed)");
    expect(body).not.toContain("linear.app");

    delete process.env.SLACK_BUG_REPORT_WEBHOOK;
  });

  it("rate-limits the 4th submit in 10 minutes before any side effect runs", async () => {
    for (let i = 0; i < 3; i += 1) {
      const res = await run(authed({ ...VALID_PAYLOAD, autoDispenseCLI: false }));
      expectBugReportResult(res);
    }
    const reportsBefore = bugReportDocPaths().length;
    expect(reportsBefore).toBe(3);
    mocks.createIssue.mockClear();

    await expect(run(authed({ ...VALID_PAYLOAD, autoDispenseCLI: false }))).rejects.toMatchObject({
      code: "resource-exhausted",
    });

    // The rejection happens inside wrapCallableHandler before the handler: no
    // Linear call, no new bug_reports doc, no mission doc, no Slack post.
    expect(mocks.createIssue).not.toHaveBeenCalled();
    expect(bugReportDocPaths().length).toBe(reportsBefore);
    expect(missionDocPaths().length).toBe(0);
  });

  it("does not rate-limit a different uid", async () => {
    for (let i = 0; i < 3; i += 1) {
      await run(authed({ ...VALID_PAYLOAD, autoDispenseCLI: false }));
    }
    await expect(run(authed({ ...VALID_PAYLOAD, autoDispenseCLI: false }))).rejects.toMatchObject({
      code: "resource-exhausted",
    });
    const res = await run(authed({ ...VALID_PAYLOAD, autoDispenseCLI: false }, "bob-other-uid"));
    expectBugReportResult(res);
    expect(res.ok).toBe(true);
  });

  it("allows submits again after the 600-second burst window expires", async () => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date("2026-09-05T00:00:00Z"));

    for (let i = 0; i < 3; i += 1) {
      await run(authed({ ...VALID_PAYLOAD, autoDispenseCLI: false }));
    }
    await expect(run(authed({ ...VALID_PAYLOAD, autoDispenseCLI: false }))).rejects.toMatchObject({
      code: "resource-exhausted",
    });

    vi.advanceTimersByTime(601_000);
    const res = await run(authed({ ...VALID_PAYLOAD, autoDispenseCLI: false }));
    expectBugReportResult(res);
    expect(res.ok).toBe(true);
  });
});
