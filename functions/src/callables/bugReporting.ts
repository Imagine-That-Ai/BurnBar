/**
 * @fileoverview Bug Reporting callable for OpenBurnBar.
 *
 * Receives bug reports from macOS, iOS, and Android clients, creates a Linear issue,
 * records the report in Firestore, and auto-queues a CLI agent mission on the developer's Mac.
 */

import { FieldValue } from "firebase-admin/firestore";
import { defineSecret } from "firebase-functions/params";
import { HttpsError } from "firebase-functions/v2/https";
import { randomUUID } from "node:crypto";

import { db } from "../adminRuntime.js";
import { getConfig } from "../config.js";
import { LinearClient, LinearIssueInput } from "../linear/linearClient.js";
import { logInfo, logWarn, onCallProduction } from "../logging.js";
import { resilientFetch } from "../resilienceHelpers.js";
import { boundedTrimmedString } from "./shared/validators.js";

const FUNCTIONS_REGION = "us-central1";
const LINEAR_API_KEY = defineSecret("LINEAR_API_KEY");
const SLACK_BUG_REPORT_WEBHOOK = defineSecret("SLACK_BUG_REPORT_WEBHOOK");

function resolveSecret(secret: ReturnType<typeof defineSecret>, envFallback?: string): string | undefined {
  try {
    const val = secret.value();
    if (val && val.trim().length > 0) return val.trim();
  } catch {
    // .value() throws when not inside a secret-bound request (e.g., local tests)
  }
  return envFallback;
}

export interface SubmitBugReportRequest {
  title: string;
  description: string;
  platform?: "macOS" | "iOS" | "Android" | "cli" | "unknown";
  appVersion?: string;
  osVersion?: string;
  deviceModel?: string;
  diagnostics?: Record<string, unknown>;
  logsSnippet?: string;
  screenshotBase64?: string;
  autoDispenseCLI?: boolean;
  requestedRuntime?: string;
  targetProject?: string;
  priority?: number;
}

export interface SubmitBugReportResponse {
  ok: true;
  reportId: string;
  linearIssue: {
    id: string;
    identifier: string;
    url: string;
    mock?: boolean;
  };
  missionId?: string;
}

function sanitizeDiagnostics(raw: unknown): Record<string, unknown> {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) {
    return {};
  }
  const result: Record<string, unknown> = {};
  for (const [key, value] of Object.entries(raw as Record<string, unknown>)) {
    const lower = key.toLowerCase();
    if (
      lower.includes("secret") ||
      lower.includes("token") ||
      lower.includes("password") ||
      (lower.includes("key") && lower !== "teamkey" && lower !== "itemkey")
    ) {
      result[key] = "[REDACTED]";
      continue;
    }
    if (typeof value === "string" && value.length > 5000) {
      result[key] = value.slice(0, 5000) + "... [truncated]";
    } else {
      result[key] = value;
    }
  }
  return result;
}

interface FormatPromptParams {
  platform: string;
  rawTitle: string;
  rawDescription: string;
  linearIdentifier: string;
  linearUrl: string;
  appVersion?: string;
  osVersion?: string;
  deviceModel?: string;
  targetProject?: string;
  diagnostics: Record<string, unknown>;
  logsSnippet?: string;
}

function formatBugInvestigationPrompt(params: FormatPromptParams): string {
  const sections = [
    `You are investigating a bug report filed on ${params.platform} and tracked in Linear as [${params.linearIdentifier}](${params.linearUrl}).`,
    ``,
    `### Issue Details`,
    `- **Title:** ${params.rawTitle}`,
    `- **Linear Key:** ${params.linearIdentifier}`,
    `- **Platform:** ${params.platform}`,
    params.appVersion ? `- **App Version:** ${params.appVersion}` : null,
    params.osVersion ? `- **OS Version:** ${params.osVersion}` : null,
    params.deviceModel ? `- **Device:** ${params.deviceModel}` : null,
    params.targetProject ? `- **Target Project:** ${params.targetProject}` : null,
    ``,
    `### User Report`,
    params.rawDescription,
    ``,
    Object.keys(params.diagnostics).length > 0
      ? `### System Diagnostics\n\`\`\`json\n${JSON.stringify(params.diagnostics, null, 2)}\n\`\`\`\n`
      : null,
    params.logsSnippet
      ? `### Recent Stack Trace / Logs\n\`\`\`log\n${params.logsSnippet}\n\`\`\`\n`
      : null,
    `### Action Plan`,
    `1. Locate relevant components in the repository associated with this ${params.platform} issue.`,
    `2. Analyze the bug report and diagnostics to determine the exact failure mode.`,
    `3. Write a reproduction or regression unit test.`,
    `4. Implement the fix cleanly, preserving existing contracts, tests, and documentation.`,
    `5. Run relevant test suites and verify complete resolution.`,
  ];

  return sections.filter((s): s is string => s !== null).join("\n");
}

async function notifySlackBugReport(params: {
  reportId: string;
  linearIdentifier: string;
  linearUrl: string;
  title: string;
  description: string;
  platform: string;
  missionId?: string;
}): Promise<void> {
  const webhookUrl = resolveSecret(SLACK_BUG_REPORT_WEBHOOK, process.env.SLACK_BUG_REPORT_WEBHOOK || process.env.SLACK_WEBHOOK_URL);
  if (!webhookUrl) {
    return;
  }

  const text =
    `🚨 *New Bug Report Filed* [${params.platform}]\n` +
    `*Issue:* <${params.linearUrl}|${params.linearIdentifier}> — ${params.title}\n` +
    `*Details:* ${params.description.slice(0, 300)}\n` +
    (params.missionId
      ? `*CLI Agent:* Dispensed mission \`${params.missionId}\` on Mac`
      : `*CLI Agent:* Manual triage`);

  try {
    await resilientFetch("slack:notifyBugReport", webhookUrl, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ text }),
    });
    logInfo({
      event: "slack_bug_report_notified",
      report_id: params.reportId,
      linear_identifier: params.linearIdentifier,
    });
  } catch (err) {
    logWarn({
      event: "slack_bug_report_notify_failed",
      error: String(err),
    });
  }
}

export const submitBugReport = onCallProduction<SubmitBugReportRequest, SubmitBugReportResponse>(
  "submitBugReport",
  {
    region: FUNCTIONS_REGION,
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 50,
    secrets: [LINEAR_API_KEY, SLACK_BUG_REPORT_WEBHOOK],
  },
  async (request) => {
    const uid = request.auth?.uid;
    if (!uid) {
      throw new HttpsError("unauthenticated", "Authentication is required.");
    }
    const data = request.data ?? {};

    const rawTitle = boundedTrimmedString(data.title, "title", 300, true);
    if (!rawTitle || rawTitle.trim().length === 0) {
      throw new HttpsError("invalid-argument", "Bug report title cannot be empty.");
    }

    const rawDescription = boundedTrimmedString(data.description, "description", 15000, true);
    if (!rawDescription || rawDescription.trim().length === 0) {
      throw new HttpsError("invalid-argument", "Bug report description cannot be empty.");
    }

    const platform = (data.platform ?? "unknown") as "macOS" | "iOS" | "Android" | "cli" | "unknown";
    const appVersion = typeof data.appVersion === "string" ? data.appVersion.slice(0, 100) : undefined;
    const osVersion = typeof data.osVersion === "string" ? data.osVersion.slice(0, 100) : undefined;
    const deviceModel = typeof data.deviceModel === "string" ? data.deviceModel.slice(0, 100) : undefined;
    const diagnostics = sanitizeDiagnostics(data.diagnostics);
    const logsSnippet = typeof data.logsSnippet === "string" ? data.logsSnippet.slice(0, 50000) : undefined;
    const autoDispenseCLI = data.autoDispenseCLI !== false;
    const requestedRuntime = typeof data.requestedRuntime === "string" ? data.requestedRuntime.slice(0, 50) : "auto";
    const targetProject = typeof data.targetProject === "string" ? data.targetProject.slice(0, 200) : undefined;
    const priority = typeof data.priority === "number" ? Math.min(4, Math.max(0, data.priority)) : 2;

    const reportId = `rep_${Date.now()}_${randomUUID().slice(0, 8)}`;

    // 1. Create Linear Issue
    const apiKey = resolveSecret(LINEAR_API_KEY, process.env.LINEAR_API_KEY || process.env.LINEAR_TOKEN);
    const linearClient = new LinearClient({ apiKey });
    const linearInput: LinearIssueInput = {
      title: rawTitle,
      description: rawDescription,
      platform,
      appVersion,
      osVersion,
      deviceModel,
      diagnostics,
      logsSnippet,
      priority,
    };

    const linearResult = await linearClient.createIssue(linearInput);

    // 2. Write Bug Report document to Firestore
    const reportRef = db.doc(`users/${uid}/bug_reports/${reportId}`);
    await reportRef.set({
      id: reportId,
      uid,
      title: rawTitle,
      description: rawDescription,
      platform,
      appVersion: appVersion ?? null,
      osVersion: osVersion ?? null,
      deviceModel: deviceModel ?? null,
      diagnostics,
      hasLogs: !!logsSnippet,
      linearIssue: {
        id: linearResult.id,
        identifier: linearResult.identifier,
        url: linearResult.url,
        mock: !!linearResult.mock,
        error: linearResult.error ?? null,
      },
      status: "submitted",
      createdAt: FieldValue.serverTimestamp(),
      updatedAt: FieldValue.serverTimestamp(),
    });

    let missionId: string | undefined;

    // 3. Auto-dispense CLI Guy on developer's Mac if enabled
    if (autoDispenseCLI) {
      missionId = `mission_bug_${reportId}`;
      const missionRef = db.doc(`users/${uid}/cli_agent_mission_requests/${missionId}`);
      const prompt = formatBugInvestigationPrompt({
        platform,
        rawTitle,
        rawDescription,
        linearIdentifier: linearResult.identifier,
        linearUrl: linearResult.url,
        appVersion,
        osVersion,
        deviceModel,
        targetProject,
        diagnostics,
        logsSnippet,
      });

      await missionRef.set({
        id: missionId,
        uid,
        status: "pending",
        missionKind: "bug_investigation",
        source: `${platform.toLowerCase()}-bug-report`,
        requestedRuntime,
        title: `[Bug ${linearResult.identifier}] ${rawTitle}`,
        prompt,
        targetProject: targetProject ?? "Mac current workspace",
        linearIssue: {
          id: linearResult.id,
          identifier: linearResult.identifier,
          url: linearResult.url,
        },
        reportId,
        commandsAllowed: true,
        fileEditsAllowed: true,
        createdAt: FieldValue.serverTimestamp(),
        updatedAt: FieldValue.serverTimestamp(),
      });

      logInfo({
        event: "bug_report_mission_queued",
        mission_id: missionId,
        linear_identifier: linearResult.identifier,
      });
    }

    logInfo({
      event: "bug_report_created",
      report_id: reportId,
      linear_identifier: linearResult.identifier,
    });

    // 4. Out-of-band Slack notification (if webhook configured)
    await notifySlackBugReport({
      reportId,
      linearIdentifier: linearResult.identifier,
      linearUrl: linearResult.url,
      title: rawTitle,
      description: rawDescription,
      platform,
      missionId,
    });

    return {
      ok: true,
      reportId,
      linearIssue: {
        id: linearResult.id,
        identifier: linearResult.identifier,
        url: linearResult.url,
        mock: linearResult.mock,
      },
      missionId,
    };
  },
);
