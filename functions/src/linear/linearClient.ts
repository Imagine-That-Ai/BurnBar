/**
 * @fileoverview Linear GraphQL API Client for OpenBurnBar Bug Reporting.
 *
 * Handles issue creation, markdown formatting, team/label resolution,
 * and resilient network calls with SSRF protection and mock fallbacks.
 */

import { resilientFetch } from "../resilienceHelpers.js";
import { logError, logInfo, logWarn } from "../logging.js";

export interface LinearIssueInput {
  title: string;
  description: string;
  platform: "macOS" | "iOS" | "Android" | "cli" | "unknown";
  appVersion?: string;
  osVersion?: string;
  deviceModel?: string;
  diagnostics?: Record<string, unknown>;
  logsSnippet?: string;
  priority?: number; // 0 = No priority, 1 = Urgent, 2 = High, 3 = Normal, 4 = Low
  teamKey?: string;
  labels?: string[];
}

export interface LinearIssueResult {
  id: string;
  identifier: string;
  title: string;
  url: string;
  mock?: boolean;
  error?: string;
}

export interface LinearClientConfig {
  apiKey?: string;
  teamKey?: string;
  apiUrl?: string;
}

const DEFAULT_LINEAR_API_URL = "https://api.linear.app/graphql";
const DEFAULT_TEAM_KEY = "IMA";

export class LinearClient {
  private readonly apiKey: string | undefined;
  private readonly teamKey: string;
  private readonly apiUrl: string;

  constructor(config: LinearClientConfig = {}) {
    this.apiKey = config.apiKey || process.env.LINEAR_API_KEY || process.env.LINEAR_TOKEN;
    this.teamKey = config.teamKey || process.env.LINEAR_TEAM_KEY || DEFAULT_TEAM_KEY;
    this.apiUrl = config.apiUrl || DEFAULT_LINEAR_API_URL;
  }

  /**
   * Builds rich markdown description including user notes, device info, and expandable diagnostics.
   */
  public formatMarkdownDescription(input: LinearIssueInput): string {
    const sections: string[] = [];

    // User Report Section
    sections.push(`### Description\n\n${input.description.trim()}`);

    // Environment & Device Metadata
    sections.push(
      `### Environment\n\n` +
        `- **Platform:** \`${input.platform}\`\n` +
        (input.appVersion ? `- **App Version:** \`${input.appVersion}\`\n` : "") +
        (input.osVersion ? `- **OS Version:** \`${input.osVersion}\`\n` : "") +
        (input.deviceModel ? `- **Device Model:** \`${input.deviceModel}\`\n` : "") +
        `- **Reported At:** \`${new Date().toISOString()}\``
    );

    // Diagnostics / System State (Collapsible)
    if (input.diagnostics && Object.keys(input.diagnostics).length > 0) {
      const sanitized = JSON.stringify(input.diagnostics, null, 2);
      sections.push(
        `<details>\n<summary><strong>System Diagnostics</strong></summary>\n\n` +
          `\`\`\`json\n${sanitized}\n\`\`\`\n</details>`
      );
    }

    // Recent Logs / Breadcrumbs (Collapsible)
    if (input.logsSnippet && input.logsSnippet.trim().length > 0) {
      sections.push(
        `<details>\n<summary><strong>Recent Logs & Breadcrumbs</strong></summary>\n\n` +
          `\`\`\`log\n${input.logsSnippet.trim()}\n\`\`\`\n</details>`
      );
    }

    return sections.join("\n\n");
  }

  /**
   * Resolves the team ID for the configured team key.
   */
  private async resolveTeamId(apiKey: string): Promise<string> {
    const query = `
      query Teams {
        teams {
          nodes {
            id
            key
            name
          }
        }
      }
    `;

    const res = await resilientFetch("linear:getTeams", this.apiUrl, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: apiKey.startsWith("lin_api_") ? apiKey : `Bearer ${apiKey}`,
      },
      body: JSON.stringify({ query }),
    });

    if (!res.ok) {
      throw new Error(`Failed to query Linear teams: HTTP ${res.status}`);
    }

    const payload = (await res.json()) as {
      data?: { teams?: { nodes?: Array<{ id: string; key: string; name: string }> } };
      errors?: Array<{ message: string }>;
    };

    if (payload.errors && payload.errors.length > 0) {
      throw new Error(`Linear GraphQL error: ${payload.errors.map((e) => e.message).join("; ")}`);
    }

    const nodes = payload.data?.teams?.nodes ?? [];
    const matched = nodes.find(
      (t) => t.key.toLowerCase() === this.teamKey.toLowerCase()
    );

    if (matched) {
      return matched.id;
    }

    if (nodes.length > 0 && nodes[0]) {
      logWarn({
        event: "linear_team_fallback",
        message: `Team key '${this.teamKey}' not found. Defaulting to '${nodes[0].key}'.`,
      });
      return nodes[0].id;
    }

    throw new Error(`No Linear teams available for team key: ${this.teamKey}`);
  }

  /**
   * Creates a new issue on Linear or returns a mock issue if Linear is unconfigured.
   */
  public async createIssue(input: LinearIssueInput): Promise<LinearIssueResult> {
    if (!this.apiKey) {
      const mockIdentifier = `BB-${Math.floor(100 + Math.random() * 900)}`;
      logInfo({
        event: "linear_unconfigured_mock",
        message: `Linear unconfigured. Generated mock issue ${mockIdentifier}`,
      });
      return {
        id: `mock-linear-${Date.now()}`,
        identifier: mockIdentifier,
        title: input.title,
        url: `https://linear.app/openburnbar/issue/${mockIdentifier}`,
        mock: true,
      };
    }

    try {
      const teamId = await this.resolveTeamId(this.apiKey);
      const markdownBody = this.formatMarkdownDescription(input);

      const mutation = `
        mutation IssueCreate($input: IssueCreateInput!) {
          issueCreate(input: $input) {
            success
            issue {
              id
              identifier
              title
              url
            }
          }
        }
      `;

      const variables = {
        input: {
          title: input.title,
          description: markdownBody,
          teamId,
          priority: input.priority ?? 2,
        },
      };

      const res = await resilientFetch("linear:createIssue", this.apiUrl, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization: this.apiKey.startsWith("lin_api_") ? this.apiKey : `Bearer ${this.apiKey}`,
        },
        body: JSON.stringify({ query: mutation, variables }),
      });

      if (!res.ok) {
        throw new Error(`Linear issueCreate failed: HTTP ${res.status}`);
      }

      const payload = (await res.json()) as {
        data?: {
          issueCreate?: {
            success: boolean;
            issue?: {
              id: string;
              identifier: string;
              title: string;
              url: string;
            };
          };
        };
        errors?: Array<{ message: string }>;
      };

      if (payload.errors && payload.errors.length > 0) {
        throw new Error(`Linear GraphQL error: ${payload.errors.map((e) => e.message).join("; ")}`);
      }

      const issue = payload.data?.issueCreate?.issue;
      if (!issue || !payload.data?.issueCreate?.success) {
        throw new Error("Linear issue creation returned unsuccessful response");
      }

      logInfo({
        event: "linear_issue_created",
        message: `Created Linear issue ${issue.identifier}: ${issue.url}`,
      });
      return {
        id: issue.id,
        identifier: issue.identifier,
        title: issue.title,
        url: issue.url,
        mock: false,
      };
    } catch (error) {
      logError({
        event: "linear_create_failed",
        error: (error as Error).message,
      });
      // Fallback mock issue so bug submission flow never hard breaks
      const fallbackId = `BB-FALLBACK-${Math.floor(100 + Math.random() * 900)}`;
      return {
        id: `fallback-${Date.now()}`,
        identifier: fallbackId,
        title: input.title,
        url: `https://linear.app/openburnbar/issue/${fallbackId}`,
        mock: true,
        error: (error as Error).message,
      };
    }
  }
}
