/**
 * @fileoverview User-level cloud-feature suspension controls.
 *
 * Ops can suspend variable-cost cloud features by writing:
 * `users/{uid}/ops/suspensions/cloudFeatures/current`.
 */

import type { Firestore } from "firebase-admin/firestore";
import { HttpsError } from "firebase-functions/v2/https";

import { isTimestampWithToMillis } from "./guards.js";

export const CLOUD_FEATURE_SUSPENSION_DOC_PATH_TEMPLATE = "users/{uid}/ops/suspensions/cloudFeatures/current";
export const CLOUD_FEATURE_ABUSE_DAILY_REFRESH_LIMIT = 5;

export const REQUIRED_SUSPENDED_USER_DENIED_SURFACES = [
  "hosted_quota",
  "remote_mcp",
  "floo_relay",
  "hosted_agent_control",
] as const;

type RequiredSuspendedUserDeniedSurface = (typeof REQUIRED_SUSPENDED_USER_DENIED_SURFACES)[number];
type CloudFeatureSurface = RequiredSuspendedUserDeniedSurface | "burnbar_cloud" | "burnbar_cloud_pro";

interface ActiveCloudFeatureSuspension {
  pathTemplate: typeof CLOUD_FEATURE_SUSPENSION_DOC_PATH_TEMPLATE;
  deniedSurfaces: CloudFeatureSurface[];
  userQuotaDailyRefreshLimit: number;
  reason?: string;
  expiresAtMillis?: number;
}

const DEFAULT_DENIED_SURFACES: CloudFeatureSurface[] = [
  ...REQUIRED_SUSPENDED_USER_DENIED_SURFACES,
  "burnbar_cloud",
  "burnbar_cloud_pro",
];

export function cloudFeatureSuspensionPath(uid: string): string {
  return `users/${uid}/ops/suspensions/cloudFeatures/current`;
}

export function parseCloudFeatureSuspension(
  raw: Record<string, unknown> | undefined,
  nowMillis = Date.now(),
): ActiveCloudFeatureSuspension | null {
  if (!raw) return null;
  if (raw.active === false || raw.suspended === false || raw.enabled === false) return null;

  const expiresAtMillis = timestampMillis(raw.expiresAt ?? raw.expireAt);
  if (expiresAtMillis !== undefined && expiresAtMillis <= nowMillis) return null;

  const deniedSurfaces = parseDeniedSurfaces(raw.deniedSurfaces);
  const limit = positiveInteger(raw.userQuotaDailyRefreshLimit ?? raw.hostedQuotaDailyRefreshLimit);
  const reason = typeof raw.reason === "string" && raw.reason.trim() ? raw.reason.trim().slice(0, 160) : undefined;

  return {
    pathTemplate: CLOUD_FEATURE_SUSPENSION_DOC_PATH_TEMPLATE,
    deniedSurfaces,
    userQuotaDailyRefreshLimit: limit ?? CLOUD_FEATURE_ABUSE_DAILY_REFRESH_LIMIT,
    reason,
    expiresAtMillis,
  };
}

export function cloudFeatureSuspensionDeniesSurface(
  suspension: ActiveCloudFeatureSuspension | null,
  surface: CloudFeatureSurface,
): boolean {
  if (!suspension) return false;
  if (suspension.deniedSurfaces.includes(surface)) return true;
  if (suspension.deniedSurfaces.includes("burnbar_cloud")) return true;
  return (
    suspension.deniedSurfaces.includes("burnbar_cloud_pro") &&
    (surface === "floo_relay" || surface === "hosted_agent_control")
  );
}

async function loadActiveCloudFeatureSuspension(
  firestore: Firestore,
  uid: string,
): Promise<ActiveCloudFeatureSuspension | null> {
  const snap = await firestore.doc(cloudFeatureSuspensionPath(uid)).get();
  return parseCloudFeatureSuspension(snap.data());
}

export async function assertCloudFeatureNotSuspended(
  firestore: Firestore,
  uid: string,
  surface: CloudFeatureSurface,
): Promise<void> {
  const suspension = await loadActiveCloudFeatureSuspension(firestore, uid);
  if (!cloudFeatureSuspensionDeniesSurface(suspension, surface)) return;
  throw new HttpsError("permission-denied", "Cloud features are suspended for this account.", {
    code: "cloud-features-suspended",
    surface,
    suspensionPath: CLOUD_FEATURE_SUSPENSION_DOC_PATH_TEMPLATE,
    userQuotaDailyRefreshLimit: suspension?.userQuotaDailyRefreshLimit ?? CLOUD_FEATURE_ABUSE_DAILY_REFRESH_LIMIT,
  });
}

export async function hostedQuotaDailyRefreshLimitForUser(
  firestore: Firestore,
  uid: string,
  configuredLimit: number,
): Promise<number> {
  const suspension = await loadActiveCloudFeatureSuspension(firestore, uid);
  if (!suspension) return configuredLimit;
  return Math.max(1, Math.min(configuredLimit, suspension.userQuotaDailyRefreshLimit));
}

function parseDeniedSurfaces(raw: unknown): CloudFeatureSurface[] {
  if (!Array.isArray(raw)) return [...DEFAULT_DENIED_SURFACES];
  const values = raw.filter((item): item is CloudFeatureSurface => isCloudFeatureSurface(item));
  return values.length > 0 ? Array.from(new Set(values)) : [...DEFAULT_DENIED_SURFACES];
}

function isCloudFeatureSurface(raw: unknown): raw is CloudFeatureSurface {
  return (
    raw === "hosted_quota" ||
    raw === "remote_mcp" ||
    raw === "floo_relay" ||
    raw === "hosted_agent_control" ||
    raw === "burnbar_cloud" ||
    raw === "burnbar_cloud_pro"
  );
}

function timestampMillis(raw: unknown): number | undefined {
  if (!raw) return undefined;
  if (isTimestampWithToMillis(raw)) return raw.toMillis();
  const parsed = Date.parse(String(raw));
  return Number.isFinite(parsed) ? parsed : undefined;
}

function positiveInteger(raw: unknown): number | undefined {
  const parsed = Number(raw);
  if (!Number.isFinite(parsed) || parsed < 1) return undefined;
  return Math.floor(parsed);
}
