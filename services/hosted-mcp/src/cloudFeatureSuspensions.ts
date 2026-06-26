import { HttpError } from "./errors.js";
import type { RemoteMcpClientFirestore } from "./firestoreTypes.js";

const CLOUD_FEATURE_SUSPENSION_DOC_PATH_TEMPLATE = "users/{uid}/ops/suspensions/cloudFeatures/current";

type CloudFeatureSurface =
  | "hosted_quota"
  | "remote_mcp"
  | "floo_relay"
  | "hosted_agent_control"
  | "elder_wand_search"
  | "burnbar_cloud"
  | "burnbar_cloud_pro";

interface ActiveCloudFeatureSuspension {
  deniedSurfaces: CloudFeatureSurface[];
  expiresAtMillis?: number;
}

const DEFAULT_DENIED_SURFACES: CloudFeatureSurface[] = [
  "hosted_quota",
  "remote_mcp",
  "floo_relay",
  "hosted_agent_control",
  "elder_wand_search",
  "burnbar_cloud",
  "burnbar_cloud_pro",
];

function cloudFeatureSuspensionPath(uid: string): string {
  return `users/${uid}/ops/suspensions/cloudFeatures/current`;
}

function parseCloudFeatureSuspension(
  raw: Record<string, unknown> | undefined,
  nowMillis = Date.now(),
): ActiveCloudFeatureSuspension | null {
  if (!raw) {return null;}
  if (raw.active === false || raw.suspended === false || raw.enabled === false) {return null;}

  const expiresAtMillis = timestampMillis(raw.expiresAt ?? raw.expireAt);
  if (expiresAtMillis !== undefined && expiresAtMillis <= nowMillis) {return null;}

  return {
    deniedSurfaces: parseDeniedSurfaces(raw.deniedSurfaces),
    expiresAtMillis,
  };
}

function cloudFeatureSuspensionDeniesSurface(
  suspension: ActiveCloudFeatureSuspension | null,
  surface: CloudFeatureSurface,
): boolean {
  if (!suspension) {return false;}
  if (suspension.deniedSurfaces.includes(surface)) {return true;}
  if (suspension.deniedSurfaces.includes("burnbar_cloud")) {return true;}
  return (
    suspension.deniedSurfaces.includes("burnbar_cloud_pro") &&
    (surface === "floo_relay" || surface === "hosted_agent_control" || surface === "elder_wand_search")
  );
}

export async function assertRemoteMcpNotSuspended(
  db: RemoteMcpClientFirestore,
  uid: string,
): Promise<void> {
  const snap = await db.doc(cloudFeatureSuspensionPath(uid)).get();
  const suspension = parseCloudFeatureSuspension(snap.data());
  if (!cloudFeatureSuspensionDeniesSurface(suspension, "remote_mcp")) {return;}
  throw new HttpError(403, "Cloud features are suspended for this account.", "cloud_features_suspended");
}

function parseDeniedSurfaces(raw: unknown): CloudFeatureSurface[] {
  if (!Array.isArray(raw)) {return [...DEFAULT_DENIED_SURFACES];}
  const values = raw.filter((item): item is CloudFeatureSurface => isCloudFeatureSurface(item));
  return values.length > 0 ? Array.from(new Set(values)) : [...DEFAULT_DENIED_SURFACES];
}

function isCloudFeatureSurface(raw: unknown): raw is CloudFeatureSurface {
  return (
    raw === "hosted_quota" ||
    raw === "remote_mcp" ||
    raw === "floo_relay" ||
    raw === "hosted_agent_control" ||
    raw === "elder_wand_search" ||
    raw === "burnbar_cloud" ||
    raw === "burnbar_cloud_pro"
  );
}

function timestampMillis(raw: unknown): number | undefined {
  if (!raw) {return undefined;}
  if (raw instanceof Date) {return raw.getTime();}
  if (typeof raw === "number") {return raw;}
  const toMillis = typeof raw === "object" && raw !== null ? Reflect.get(raw, "toMillis") : undefined;
  if (typeof toMillis === "function") {
    const millis = toMillis.call(raw);
    return typeof millis === "number" ? millis : undefined;
  }
  const parsed = Date.parse(String(raw));
  return Number.isFinite(parsed) ? parsed : undefined;
}

export { CLOUD_FEATURE_SUSPENSION_DOC_PATH_TEMPLATE };
