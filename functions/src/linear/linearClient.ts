/**
 * @fileoverview Linear GraphQL API Client for OpenBurnBar Bug Reporting.
 *
 * Handles issue creation, markdown formatting, team/label resolution,
 * and resilient network calls with SSRF protection and mock fallbacks.
 */

import { errorMessage, isRecord } from "../guards.js";
import { logError, logInfo, logWarn } from "../logging.js";
import { resilientFetch } from "../resilienceHelpers.js";

interface LinearClientConfig {
  apiKey?: string;
  teamKey?: string;
  apiUrl?: string;
}

interface LinearTeamNode {
  id: string;
  key: string;
  name: string;
}

interface LinearCreatedIssue {
  id: string;
  identifier: string;
  title: string;
  url: string;
}

const DEFAULT_LINEAR_API_URL = "https://api.linear.app/graphql";
const DEFAULT_TEAM_KEY = "IMA";

function graphqlErrorMessages(value: unknown): string[] {
  if (!isRecord(value) || !Array.isArray(value.errors)) {
    return [];
  }
  return value.errors
    .filter(isRecord)
    .map((item) => item.message)
    .filter((message): message is string => typeof message === "string");
}

function parseTeamNode(value: unknown): LinearTeamNode | undefined {
  if (!isRecord(value)) return undefined;
  const { id, key, name } = value;
  if (typeof id !== "string" || typeof key !== "string" || typeof name !== "string") {
    return undefined;
  }
  return { id, key, name };
}

function parseCreatedIssue(value: unknown): LinearCreatedIssue | undefined {
  if (!isRecord(value)) return undefined;
  const { id, identifier, title, url } = value;
  if (
    typeof id !== "string" ||
    typeof identifier !== "string" ||
    typeof title !== "string" ||
    typeof url !== "string"
  ) {
    return undefined;
  }
  return { id, identifier, title, url };
}

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
  public formatMarkdownDescription(input: {
    title: string;
    description: string;
    platform: "macOS" | "iOS" | "Android" | "cli" | "unknown";
    appVersion?: string;
    osVersion?: string;
    deviceModel?: string;
    diagnostics?: Record<string, unknown>;
    logsSnippet?: string;
    priority?: number;
    teamKey?: string;
    labels?: string[];
  }): string {
    const sections: string[] = [];

    sections.push(`### Description\n\n${input.description.trim()}`);

    sections.push(
      `### Environment\n\n` +
        `- **Platform:** \`${input.platform}\`\n` +
        (input.appVersion ? `- **App Version:** \`${input.appVersion}\`\n` : "") +
        (input.osVersion ? `- **OS Version:** \`${input.osVersion}\`\n` : "") +
        (input.deviceModel ? `- **Device Model:** \`${input.deviceModel}\`\n` : "") +
        `- **Reported At:** \`${new Date().toISOString()}\``,
    );

    if (input.diagnostics && Object.keys(input.diagnostics).length > 0) {
      const sanitized = JSON.stringify(input.diagnostics, null, 2);
      sections.push(
        `<details>\n<summary><strong>System Diagnostics</strong></summary>\n\n` +
          `\`\`\`json\n${sanitized}\n\`\`\`\n</details>`,
      );
    }

    if (input.logsSnippet && input.logsSnippet.trim().length > 0) {
      sections.push(
        `<details>\n<summary><strong>Recent Logs & Breadcrumbs</strong></summary>\n\n` +
          `\`\`\`log\n${input.logsSnippet.trim()}\n\`\`\`\n</details>`,
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

    const payload: unknown = await res.json();
    const errors = graphqlErrorMessages(payload);
    if (errors.length > 0) {
      throw new Error(`Linear GraphQL error: ${errors.join("; ")}`);
    }

    const data = isRecord(payload) && isRecord(payload.data) ? payload.data : undefined;
    const teams = data && isRecord(data.teams) ? data.teams : undefined;
    const nodes = Array.isArray(teams?.nodes) ? teams.nodes.map(parseTeamNode).filter((node): node is LinearTeamNode => node !== undefined) : [];
    const matched = nodes.find((t) => t.key.toLowerCase() === this.teamKey.toLowerCase());

    if (matched) {
      return matched.id;
    }

    const fallback = nodes[0];
    if (fallback) {
      logWarn({
        event: "linear_team_fallback",
        message: `Team key '${this.teamKey}' not found. Defaulting to '${fallback.key}'.`,
      });
      return fallback.id;
    }

    throw new Error(`No Linear teams available for team key: ${this.teamKey}`);
  }

  /**
   * Creates a new issue on Linear or returns a mock issue if Linear is unconfigured.
   */
  public async createIssue(input: {
    title: string;
    description: string;
    platform: "macOS" | "iOS" | "Android" | "cli" | "unknown";
    appVersion?: string;
    osVersion?: string;
    deviceModel?: string;
    diagnostics?: Record<string, unknown>;
    logsSnippet?: string;
    priority?: number;
    teamKey?: string;
    labels?: string[];
  }): Promise<{
    id: string;
    identifier: string;
    title: string;
    url: string;
    mock?: boolean;
    error?: string;
  }> {
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

      const payload: unknown = await res.json();
      const errors = graphqlErrorMessages(payload);
      if (errors.length > 0) {
        throw new Error(`Linear GraphQL error: ${errors.join("; ")}`);
      }

      const data = isRecord(payload) && isRecord(payload.data) ? payload.data : undefined;
      const issueCreate = data && isRecord(data.issueCreate) ? data.issueCreate : undefined;
      const issue = parseCreatedIssue(issueCreate?.issue);
      if (!issue || issueCreate?.success !== true) {
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
      const message = errorMessage(error);
      logError({
        event: "linear_create_failed",
        error: message,
      });
      const fallbackId = `BB-FALLBACK-${Math.floor(100 + Math.random() * 900)}`;
      return {
        id: `fallback-${Date.now()}`,
        identifier: fallbackId,
        title: input.title,
        url: `https://linear.app/openburnbar/issue/${fallbackId}`,
        mock: true,
        error: message,
      };
    }
  }
}
