/**
 * @fileoverview Bug Reporting TypeScript schemas for OpenBurnBar.
 *
 * Types for bug report requests, Firestore documents, Linear issues, and diagnostics.
 */

export type BugReportPlatform = "macOS" | "iOS" | "Android" | "cli" | "unknown";

export interface LinearIssueMetadata {
  id: string;
  identifier: string;
  url: string;
  mock?: boolean;
  error?: string | null;
}

export interface BugReportDoc {
  id: string;
  uid: string;
  title: string;
  description: string;
  platform: BugReportPlatform;
  appVersion?: string | null;
  osVersion?: string | null;
  deviceModel?: string | null;
  diagnostics?: Record<string, unknown>;
  hasLogs?: boolean;
  linearIssue: LinearIssueMetadata;
  status: "submitted" | "investigating" | "resolved" | "closed";
  createdAt: unknown; // Firestore Timestamp / FieldValue
  updatedAt: unknown;
}

export interface BugReportRequest {
  title: string;
  description: string;
  platform?: BugReportPlatform;
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

export interface BugReportResponse {
  ok: true;
  reportId: string;
  linearIssue: LinearIssueMetadata;
  missionId?: string;
}
