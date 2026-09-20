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
import { isRecord } from "../guards.js";
import { LinearClient } from "../linear/linearClient.js";
import { logInfo, logWarn, onCallProduction } from "../logging.js";
import { resilientFetch } from "../resilienceHelpers.js";
import { FUNCTIONS_REGION } from "../runtimeOptions.js";
import { boundedTrimmedString } from "./shared/validators.js";

const LINEAR_API_KEY = defineSecret("LINEAR_API_KEY");
const SLACK_BUG_REPORT_WEBHOOK = defineSecret("SLACK_BUG_REPORT_WEBHOOK");

type BugReportPlatform = "macOS" | "iOS" | "Android" | "cli" | "unknown";

function resolveSecret(secret: ReturnType<typeof defineSecret>, envFallback?: string): string | undefined {
  try {
    const val = secret.value();
    if (val && val.trim().length > 0) return val.trim();
  } catch {
    // .value() throws when not inside a secret-bound request (e.g., local tests)
  }
  return envFallback;
}

function isBugReportPlatform(value: unknown): value is BugReportPlatform {
  return (
    value === "macOS" ||
    value === "iOS" ||
    value === "Android" ||
    value === "cli" ||
    value === "unknown"
  );
}

function parsePlatform(value: unknown): BugReportPlatform {
  return isBugReportPlatform(value) ? value : "unknown";
}

function optionalBoundedString(value: unknown, max: number): string | undefined {
  return typeof value === "string" ? value.slice(0, max) : undefined;
}

function sanitizeDiagnostics(raw: unknown): Record<string, unknown> {
  if (!isRecord(raw)) {
    return {};
  }
  const result: Record<string, unknown> = {};
  for (const [key, value] of Object.entries(raw)) {
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

export const submitBugReport = onCallProduction(
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
    const data = isRecord(request.data) ? request.data : {};

    const rawTitle = boundedTrimmedString(data.title, "title", 300, true);
    if (!rawTitle || rawTitle.trim().length === 0) {
      throw new HttpsError("invalid-argument", "Bug report title cannot be empty.");
    }

    const rawDescription = boundedTrimmedString(data.description, "description", 15000, true);
    if (!rawDescription || rawDescription.trim().length === 0) {
      throw new HttpsError("invalid-argument", "Bug report description cannot be empty.");
    }

    const platform = parsePlatform(data.platform);
    const appVersion = optionalBoundedString(data.appVersion, 100);
    const osVersion = optionalBoundedString(data.osVersion, 100);
    const deviceModel = optionalBoundedString(data.deviceModel, 100);
    const diagnostics = sanitizeDiagnostics(data.diagnostics);
    const logsSnippet = optionalBoundedString(data.logsSnippet, 50000);
    const autoDispenseCLI = data.autoDispenseCLI !== false;
    const requestedRuntime = optionalBoundedString(data.requestedRuntime, 50) ?? "auto";
    const targetProject = optionalBoundedString(data.targetProject, 200);
    const priority = typeof data.priority === "number" ? Math.min(4, Math.max(0, data.priority)) : 2;

    const reportId = `rep_${Date.now()}_${randomUUID().slice(0, 8)}`;

    const apiKey = resolveSecret(LINEAR_API_KEY, process.env.LINEAR_API_KEY || process.env.LINEAR_TOKEN);
    const linearClient = new LinearClient({ apiKey });
    const linearResult = await linearClient.createIssue({
      title: rawTitle,
      description: rawDescription,
      platform,
      appVersion,
      osVersion,
      deviceModel,
      diagnostics,
      logsSnippet,
      priority,
    });

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
      ok: true as const,
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
