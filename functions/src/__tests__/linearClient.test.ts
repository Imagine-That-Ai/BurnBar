import { beforeEach, describe, expect, it, vi } from "vitest";

import { LinearClient, LinearIssueInput } from "../linear/linearClient.js";

const mocks = vi.hoisted(() => ({
  resilientFetch: vi.fn(),
}));

vi.mock("../resilienceHelpers.js", () => ({
  resilientFetch: mocks.resilientFetch,
}));

describe("LinearClient", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    delete process.env.LINEAR_API_KEY;
    delete process.env.LINEAR_TOKEN;
    delete process.env.LINEAR_TEAM_KEY;
  });

  it("generates structured markdown with diagnostics and logs", () => {
    const client = new LinearClient();
    const input: LinearIssueInput = {
      title: "UI crash on tapping sync",
      description: "App freezes when tapping quota sync button in settings.",
      platform: "iOS",
      appVersion: "1.4.0 (82)",
      osVersion: "iOS 18.2",
      deviceModel: "iPhone 16 Pro",
      diagnostics: {
        activeProviders: ["codex", "claude"],
        memoryUsageMB: 142.5,
        networkConnected: true,
      },
      logsSnippet: "[ERROR] QuotaSyncWorker: Socket timed out after 5000ms\n[INFO] Retrying in 2s",
    };

    const markdown = client.formatMarkdownDescription(input);
    expect(markdown).toContain("### Description");
    expect(markdown).toContain("App freezes when tapping quota sync button in settings.");
    expect(markdown).toContain("### Environment");
    expect(markdown).toContain("- **Platform:** `iOS`");
    expect(markdown).toContain("- **App Version:** `1.4.0 (82)`");
    expect(markdown).toContain("- **OS Version:** `iOS 18.2`");
    expect(markdown).toContain("- **Device Model:** `iPhone 16 Pro`");
    expect(markdown).toContain("<details>");
    expect(markdown).toContain("System Diagnostics");
    expect(markdown).toContain('"activeProviders"');
    expect(markdown).toContain("Recent Logs & Breadcrumbs");
    expect(markdown).toContain("QuotaSyncWorker: Socket timed out");
  });

  it("returns a mock issue when no API key is configured", async () => {
    const client = new LinearClient();
    const result = await client.createIssue({
      title: "Test Bug",
      description: "Test description",
      platform: "macOS",
    });

    expect(result.mock).toBe(true);
    expect(result.identifier).toMatch(/^BB-\d+/);
    expect(result.url).toContain("https://linear.app/openburnbar/issue/");
    expect(mocks.resilientFetch).not.toHaveBeenCalled();
  });

  it("queries teams and creates issue when API key is provided", async () => {
    // 1. Mock teams query response
    mocks.resilientFetch.mockResolvedValueOnce({
      ok: true,
      status: 200,
      json: async () => ({
        data: {
          teams: {
            nodes: [
              { id: "team-eng-id", key: "ENG", name: "Engineering" },
              { id: "team-bb-id", key: "BB", name: "BurnBar" },
            ],
          },
        },
      }),
    });

    // 2. Mock issueCreate mutation response
    mocks.resilientFetch.mockResolvedValueOnce({
      ok: true,
      status: 200,
      json: async () => ({
        data: {
          issueCreate: {
            success: true,
            issue: {
              id: "issue-123",
              identifier: "BB-42",
              title: "Fix crash in menu bar",
              url: "https://linear.app/openburnbar/issue/BB-42",
            },
          },
        },
      }),
    });

    const client = new LinearClient({
      apiKey: "test-linear-key",
      teamKey: "BB",
    });

    const result = await client.createIssue({
      title: "Fix crash in menu bar",
      description: "Crash occurs when clicking status item under low memory.",
      platform: "macOS",
    });

    expect(result.mock).toBe(false);
    expect(result.id).toBe("issue-123");
    expect(result.identifier).toBe("BB-42");
    expect(result.url).toBe("https://linear.app/openburnbar/issue/BB-42");
    expect(mocks.resilientFetch).toHaveBeenCalledTimes(2);
  });

  it("handles GraphQL errors gracefully and falls back to structured mock", async () => {
    mocks.resilientFetch.mockResolvedValueOnce({
      ok: true,
      status: 200,
      json: async () => ({
        errors: [{ message: "Unauthorized token" }],
      }),
    });

    const client = new LinearClient({
      apiKey: "test-linear-invalid-key",
      teamKey: "BB",
    });

    const result = await client.createIssue({
      title: "Issue with invalid auth",
      description: "Some bug description",
      platform: "Android",
    });

    expect(result.mock).toBe(true);
    expect(result.identifier).toMatch(/^BB-FALLBACK-\d+/);
    expect(result.error).toContain("Unauthorized token");
  });
});
